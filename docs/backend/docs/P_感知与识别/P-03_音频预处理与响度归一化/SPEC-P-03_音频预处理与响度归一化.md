# SPEC-P-03 音频预处理与响度归一化

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.7（降噪为实验开关）、§4.1.2；`API-01` §2.3（`enableDenoise`）；`SPEC-00` §3.1（FF-02 时域门限参数为 **FF-28**）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-P-01`（样本来源）、`SPEC-P-04`（下游消费者）、`SPEC-T-08`（跨语言数值对齐，**本功能的任何滤波都会进入对齐口径**） |

## 1. 目标与范围

### 1.1 一句话目标
在 Mel 计算之前对 65536 样本做预加重（FF-02）**与 FF-08 归一化**。**高通滤波器已于 v1.0 移除（`ADR-17` / FF-08c）**；**LUFS 响度归一化仅用于训练侧增强**（`ADR-17` / FF-08b），推理侧不做；谱减法**仅作实验开关，默认关闭**。

### 1.2 范围内（In Scope）
- 预加重 `y[n] = x[n] − 0.97·x[n−1]`（FF-02），**边界约定已由 `ADR-21`（2026-09-12）修订为流式**：当前 patch 的首样本用「**该 patch 开始前的最后一个原始（未预加重）样本**」，源起点用 `0` → `feature_config.preemphasis_boundary = "continuous_stream_previous_raw_sample_or_zero_at_source_start"`。~~`x[−1] = x[0]`（首样本原样通过，`"first_sample_passthrough"`）~~ —— 旧规则只在「每个 patch 都从录音开头开始」时自洽，而 patch 以 0.5 s 步长滑动、**每个 patch 有 87.8% 的音频已在上一 patch 被预加重过**，逐 patch 重启滤波器会把不连续点放在模型最爱看的位置。
- ~~高通滤波~~ **已于 v1.0 移除**（`ADR-17` / FF-08c）：主方案 §3.7 只保留「预加重 + 响度归一化」，且 `fmin = 20 Hz` 的 Mel 滤波器组已丢弃 20 Hz 以下。
- 响度归一化：**推理侧只做 RMS 路径**（交付必做）；**LUFS(K-weighting) 仅用于训练侧**（`target_lufs = -23.0`，FF-08b / `ADR-17`），推理侧不做。
- 归一化的**逐 patch 独立性**约束：不得使用跨 patch 的全局统计量（防止域偏移，主方案 §4.1.2 与 FF-08 的同类陷阱）。
- 第 3 阶段时域瞬态保护门限实验开关（`ADR-56`）：默认 `false`；开启时由 `startSession.enableDenoise` 传入（`API-01` §2.3），仅用于消融对照。参数冻结在 SSOT 的 `denoise` 块（FF-28）。
- 预处理链的**确定性**：同一输入必须产出逐元素相同的输出（对齐测试的前提）。
- PCM16 → `float32` 的定点换算（统一按 int16 满量程归一化）。
- ~~去直流：减去**本 patch 内**均值，不使用跨 patch 累计均值。~~ **已于 `ADR-21`（2026-09-12）从链路中移除**：交付侧的 `operation_order` 里**没有** DC 去除这一步，保留它等于在麦克风与模型之间插一个**训练时不存在**的变换。本功能**不做去直流**。
- 输出契约：只输出时域波形 `float32`，**不输出任何频谱量**（频谱属 P-04）。
- 参数来源约束：**一律读自 `feature_config` 的顶层键**（`preemphasis` / `preemphasis_boundary` / `loudness_normalization` / `target_lufs`），代码只读不写。**注意：SSOT 里没有 `preprocess` 对象**，不要按它实现。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| 分帧、Hann 窗、FFT、Mel 滤波器组、对数压缩、per-patch min-max 归一化 | P-04（FF-03/FF-05/FF-06/FF-07/FF-08） |
| 频谱侧 `power_to_db`（patch 相对）与 per-patch min-max | P-04（FF-07/FF-08，`ADR-21`）；与本文的**时域响度归一化**是两个不同步骤，不得合并 |
| **去直流** | **链路中不存在**（`ADR-21` 删除）；本功能与 P-04 均**不做**（交付侧 `operation_order` 无此步） |
| VAD / 静默判定 | P-02 |
| ~~降噪模型、神经网络降噪、Wiener 滤波~~ **已由 `ADR-56` 有条件放开**：仅允许第 3 阶段的**时域瞬态保护门限**（FF-28），**默认关闭**，且必须通过 §7 判据 14 的实测门槛 | 见 §1.4。**仍然不做**：神经网络降噪、Wiener/谱门限等**逐频带**降噪（`ADR-53` 实测为负收益，见 §1.4） |
| 重采样 | 不做：采样率已由 FF-01 固定，若输入不符则报 `ACD-MEL-002` 而非重采样 |
| 动态范围压缩 / AGC 闭环 | 不做：会引入与训练侧不一致的非线性 |
| 声道混合 / 去混响 | 不做：FF-01 为单声道；RIR 增强已裁（`X-06`） |
| ~~降噪默认开启~~ **已由 `ADR-57` 修订**：**API 默认值**仍必须是 `false`（未传参者拿到逐位相同、不含门限的 patch，见判据 5），但**产品默认值**由 SSOT `denoise.gate_enabled_by_default` 决定，当前为 **`true`** —— 即**检测会话会主动开启**门限。这是一个**产品决定**（用户明确要求），不是实现方自由发挥；改回 `false` 即一键回退 |
| 频域处理（STFT 域的滤波、谱门限、谱平坦化） | 不做：全部属 P-04 的下游，混入本功能会破坏对齐口径。**注意**：第一代谱减法即属此类，已被 `ADR-56` 取代 |
| 削顶还原 / 峰值限幅（limiter） | 不做：会引入非线性，且训练侧无对应处理 |
| **放大（任何 make-up gain）** | **不做**：第 3 阶段的增益**必须 ≤ 1**，只减不增。这是 `ADR-53` 的教训——第一代配方在纯噪音输入上把能量放大了 9.5 dB，机制上就不可能再发生 |

### 1.4 第 3 阶段的降噪：`ADR-56` 的有条件放开与它的实测依据
第 3 阶段原本是「实验性谱减法」，`ADR-52`/`ADR-53` 用出厂模型 + 真实噪声做了两轮实测，结论是**谱减法这一族不能用**：

| 配方（10 dB 混合，`test_mobile`） | 纯噪音上 | 干净信号上 | 增益匹配 SSNR | top1 |
|---|---|---|---|---|
| `noisy`（不降噪） | — | — | 9.22 | 0.1215 |
| 第一代谱减（`augment.py`） | **+9.48 dB（噪音变大）** | +8.76 | 0.21 | 0.0382 |
| 第二代（最小统计量 + 判决引导 Wiener） | −14.37 | −4.92 | 2.69 | 0.0694 |
| **时域瞬态保护门限（本 SPEC 采纳，FF-28）** | **−16.20** | **−1.86** | **4.75** | **0.2014** |

**为什么时域这一族可以，频域那两族不行**：六个类别的判别信息主要在**宽频瞬态**（脆/酥）上，而**逐频带**增益必然在瞬态的低能量段（起振/衰减沿）把增益压下去；时域门限每个时刻只有**一个宽带增益**，只能缩放不能改变频谱形状，因此不会产生 musical noise，也无法放大。前瞻峰值保持使门限在起振**之前**就打开，所以也不会削掉瞬态。

因此本 SPEC 的范围从「谱减法实验开关」改为「**时域瞬态保护实验开关**」，并且：
1. 开关仍是 `startSession.enableDenoise`；**API 默认 `false`**，而检测会话按 SSOT 的 `gate_enabled_by_default`（`ADR-57` 起为 `true`）主动传入；
2. 参数冻结在 SSOT 的 `denoise` 块（§5），实现只读不写；其中 `gate_enabled_by_default` 是**产品默认值**，`ADR-57` 起为 `true`（检测会话会主动开启）；
3. **任何**逐频带/谱域降噪仍然**不做**（`ADR-53` 的实测就是这条禁令的依据，而不是"没时间做"）。

## 2. 功能行为

### 2.1 触发与前置条件
1. 会话 `RUNNING`，且已取得完整 65536 样本快照（`SPEC-P-01` §2.2 步骤 6）。
2. `feature_config` 的预处理相关顶层键（`preemphasis` / `preemphasis_boundary` / `loudness_normalization` / `target_lufs`）随握手校验通过（`API-00` §3.6）；**SSOT 中没有 `preprocess` 对象**（见 §4/§5）。
3. 输入样本数必须等于 FF-09；不等 → `ACD-MEL-002`（输入采样数不符）。

### 2.2 主流程（编号步骤）
1. 接收 `ShortArray`（PCM16，65536 样本，FF-09）与本 patch 的 `seq`。
2. 转 `FloatArray` 并按 int16 满量程归一化到 `[−1, 1)`。
3. **（已移除）** 原第 3 步「去直流：减去本 patch 内均值」**已于 `ADR-21`（2026-09-12）删除** —— 交付侧 `operation_order` 无此步。步骤号保留以维持后续步骤编号稳定，实现时**直接跳过**（`ADR-17` 只移除了高通，**DC 的移除是 `ADR-21`**，不要混记）。
4. **（已移除）** 原第 4 步「高通滤波」已于 v1.0 删除（`ADR-17` / FF-08c）—— 步骤号保留，实现时**直接跳过**。
5. 预加重（FF-02）：按 `y[n] = x[n] − 0.97·x[n−1]` 逐样本计算；**`n=0` 的 `x[−1]` 取「本 patch 开始前的最后一个原始样本」，源起点取 `0.0`**（流式边界，`ADR-21`；实现上取 `patch_samples + 1` 个样本，`buf[0]` 即前驱样本 —— 见 `feature_config.preemphasis_boundary`）。~~原约定 `x[−1] = x[0]`（首样本原样通过）~~ 已由 `ADR-21` 取代。
6. 若 `enableDenoise == true` → 执行第 3 阶段的**时域瞬态保护门限**（`NoiseGate`，FF-28）；否则**完全跳过**（默认路径，逐位不变）。
7. 响度归一化：计算本 patch 的 RMS，按目标响度求增益并施加；增益设上限钳制，防止把静默段放大到噪声爆音。
8. 输出 `FloatArray(65536)` 交 P-04；**本功能不返回任何频谱量**。

### 2.3 状态与状态迁移
**无状态。** 每一步都是逐 patch 的纯函数（输入 65536 样本 → 输出 65536 样本），不保留跨 patch 状态。
唯一的例外说明：第 3 阶段若启用，其噪声底估计**必须同样逐 patch 独立**（用本 patch 内**包络的最小值统计**估计，而不是用上一 patch 的静默段），以保持「无状态」性质；否则须在 §10 声明为有状态功能并补充状态迁移。**已关闭**：`ADR-56` 的实现取本 patch 内的包络最小值统计（滑窗 500 ms），`NoiseGate` 无任何可变状态。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 全零输入（麦克风被遮挡） | 输出全零；不做任何增益放大（增益上限钳制生效），避免放大数值噪声 |
| 输入含 int16 满量程削顶 | 不还原，直接进入链路；削顶只影响本 patch |
| 输入首样本 `x[0]` | 预加重按**流式**约定处理：**取「本 patch 开始前的最后一个原始样本」，源起点取 `0.0`**，与 Python 侧必须一致（`ADR-21` / FF-02；见 §7 判据 4）。~~原 `x[−1] = x[0]`（首样本原样通过）~~ |
| `enableDenoise=true` 但配置缺门限参数 | 抛 `ACD-CFG-001`，不得静默降级为关闭。**`ADR-56` 后此情形在结构上不可能发生**：参数由 SSOT 生成为编译期常量（`DENOISE_GATE_*`），缺一个键就编译不过，因此「不静默降级」由生成器保证，而不是由运行时分支保证 |
| 输入样本数 ≠ FF-09 | 立即 `ACD-MEL-002`，不进入 Mel |
| 会话重建后同一音频 | 输出逐元素相同（确定性） |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Kotlin 内部（P-01 → 本功能） | `Preprocess.apply(pcm16, seq, enableDenoise)` | `ShortArray(65536)`（FF-09）、`seq`、开关 | `FloatArray(65536)` | `ACD-MEL-002`、`ACD-CFG-001` |
| Kotlin 内部（本功能 → P-04） | `MelFrontend.compute(FloatArray)` | 预处理后样本 | `Float32List(128 × n_frames)` | `ACD-MEL-001` |
| Dart → Kotlin | `startSession.enableDenoise` | `bool` | `SessionSummary` / `appliedConfig.denoiseEnabled` | `ACD-CFG-001` |
| Kotlin → Dart | `getCapabilities.preemphasis` / `preemphasisBoundary` / `normalization` | — | `0.97` / `"continuous_stream_previous_raw_sample_or_zero_at_source_start"` / `"per_patch_minmax"` | — |
| 离线 ↔ 端侧 | 预处理链等效性 | 同一 wav | Python 与 Kotlin 两侧中间量 | 对齐不通过即 `PLAN-T-08` 失败 |

> 完整的 Mel 相关签名以 `API-01` 与 `SPEC-P-04` 为准；本功能只定义预处理段。

## 4. 数据契约
| 结构 | 字段 | 类型 | 值域 / 约束 |
|---|---|---|---|
| 预处理输入 | 样本 | `int16` | `[−32768, 32767]`，单声道，长度 == FF-09 |
| 预处理输出 | 样本 | `float32` | `[−1, 1]` 附近，允许增益后短暂越界（不钳制到 `[−1,1]`，避免引入非线性） |
| 中间量（仅离线对齐用） | `pre_wav` | `float32` | 落盘**仅允许在离线测试产物目录**，不得进 App（FF-24 §1 约束 App 内不落盘） |
| 配置项 | `feature_config` 顶层键：`preemphasis` · `preemphasis_boundary` · `loudness_normalization` · `target_lufs` | — | 全部定义在 `feature_config`；代码只读不写（`SPEC-C-03`）。**高通相关键不适用（v1.0 已移除，`ADR-17`）** |
| 预处理后波形（离线对齐用） | `Float32List(65536)` | 值域无硬钳制 | 仅测试产物目录可比对；**App 内不落盘** |
| 增益 | `double` | `> 0`，受 `gainCapDb` 上限约束 | 纯静音时为 1.0（不放大） |
| 预加重 / 归一化状态 | — | **不是跨 patch 的业务状态** | `ADR-21` 的流式预加重需读取前一 patch 的最后一个原始样本：实现上由环形缓冲多取 1 个样本得到该输入前驱（`patch_samples + 1`），**零跨 patch 记账**，**不得**据此把本功能改为有状态 |
| 错误 detail | `{expectedSamples, actualSamples}` | `int` | 随 `ACD-MEL-002` 返回（`API-00` §3.5） |

## 5. 参数与常量
> 一律引用 `SPEC-00 §3`；本功能新增的参数已冻结在 `SPEC-00` §3（FF-02 首样本约定 / FF-08b 响度归一化 / FF-08c 高通移除）及 `feature_config` 对应键（`ADR-17`，见 §10）。

| 项 | 引用 / 来源 |
|---|---|
| 预加重系数 | FF-02（冻结，`0.97`，不得改动） |
| 采样率 / 声道 | FF-01 |
| patch 采样数（输入长度） | FF-09 |
| 下游 `n_frames` | FF-11（**`n_frames = 128`**；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 频谱侧 `power_to_db`（**不属本功能**，列出以免混淆） | FF-07（`ref = "patch_max"`，`ADR-21`；旧值 ~~`ref = 1.0` 绝对刻度~~） |
| 归一化策略（**不属本功能**，列出以免混淆） | FF-08（`normalization = "per_patch_minmax"`，`ADR-21`；旧值 ~~固定 dB 截断 `clip(x,−80,0)`、`db_clip_range`~~ 已删除） |
| 高通截止频率 / 阶数 | **不适用（v1.0 已移除，`ADR-17` / FF-08c）**：主方案 §3.7 只保留「预加重 + 响度归一化」，高通从来不在冻结计划里；且 `fmin = 20 Hz` 的 Mel 滤波器组已丢弃 20 Hz 以下，预加重也已抑制低频 |
| 目标响度（LUFS，仅训练侧） | **已冻结（`ADR-17` / FF-08b）**：`loudness_normalization = "training_only"`、`target_lufs = -23.0`；**推理侧不做 LUFS** —— FF-07/FF-08 的 patch 相对 dB + 逐 patch min-max 已提供尺度不变性（`ADR-21` 修订后的链路） |
| 预加重首样本约定 | **已由 `ADR-21`（2026-09-12）修订为流式**：`preemphasis_boundary = "continuous_stream_previous_raw_sample_or_zero_at_source_start"`（取前一**原始**样本，源起点 `0.0`）。~~`"first_sample_passthrough"`（`x[−1] = x[0]`，`ADR-17`）~~ |
| 增益上限（推理侧 RMS 路径） | 实测产出，标定记录写 `records/reports/p03_preprocess.md`（**数值为 D2/D3 实测产出**）；若需两侧同源，以 `SPEC-C-03` 变更传播补入 `feature_config` |
| 第 3 阶段门限的 **API** 默认值 | `false`（主方案 §3.7；`API-01` §2.3）——未传参者拿到不含门限的 patch |
| 第 3 阶段门限的 **产品** 默认值 | `denoise.gate_enabled_by_default = true`（`ADR-57`，由用户拍板；检测会话主动开启）。**改回 `false` 即回退**，无需改代码 |
| 阈值口径标定批次 | FF-20b（同批自采跨域测试集） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 输入样本数不符 | 长度断言 | `ACD-MEL-002`，丢弃本 patch，会话不中断 | 无（连续出现则 `droppedPatches` 上升，自检面板可见） |
| 配置缺预处理顶层键（`preemphasis` / `preemphasis_boundary` / `loudness_normalization` / `target_lufs`） | 启动加载断言 | `ACD-CFG-001`，禁止进入检测页 | 「配置不一致，请重装应用」 |
| 门限开启但参数缺失 | 键存在性检查（生成期） | `ACD-CFG-001`，**不得静默关闭**；`ADR-56` 后为编译期保证 | 同上 |
| 增益计算得到非有限值（NaN/Inf，纯静音） | `isFinite` 检查 | 增益置 1.0（跳过归一化） | 无 |
| 预处理耗时超 hop 预算 | 实测（JVM：`preprocess_withGate_fitsTheHopBudget`，2.14 ms vs 500 ms） | 默认路径本已远低于预算，门限实测占 0.43%；真机复测待补 | 无 |
| 与 Python 侧对齐失败 | `PLAN-T-08` 的 `atol` 断言 | **硬闸门**：`PLAN-T-08` 不通过则不得进入 D4；先定位是滤波还是归一化差异 | 无（开发期可见） |
| 预加重边界约定两侧不一致 | `preprocess_parity_test.py` 首样本差异 > 1e-3 | 以**已冻结**的 `preemphasis_boundary`（**流式取前一原始样本**，`ADR-21` / FF-02；~~`x[−1] = x[0]`~~）为准统一两侧；**不得只改一侧**。⚠️ 该测试必须覆盖**非零 offset 的中间 patch** —— 只在源起点比对无法区分流式与旧规则 | 无（开发期可见） |
| 预加重/归一化输出 NaN（极低电平） | `isFinite` 全量检查 | 该 patch 置零并记录一次诊断，继续进入 Mel | 无 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 预加重系数等于 FF-02 | `grep -n "0.97" android/app/src/main/kotlin/com/acoudiet/app/audio/Preprocess.kt` + `python ai/scripts/assert_no_hardcoded_preprocess.py` | 系数只来自生成常量；脚本命中硬编码数 == 0 |
| 2 | 预加重公式正确 | `PreprocessTest.kt` 的 `preemphasis_matchesFormula`（输入脉冲信号） | 输出与 `y[n]=x[n]−0.97·x[n−1]` 逐元素差 < 1e-6 |
| 3 | 预处理链确定性 | `PreprocessTest.kt` 的 `deterministic_sameInputSameOutput` | 同一输入跑 10 次输出逐元素相等 |
| 4 | 跨语言预处理对齐 | `ai/scripts/preprocess_parity_test.py --wav <f> --n 20` | 退出码 0；stdout 含 `allclose_ok=true`，`np.allclose(kotlin, python, atol=1e-3)` 为真 |
| 5 | 门限的 **API** 默认关闭 | `grep -rn "enableDenoise" app/android/app/src/main` 与 `PreprocessTest.kt` 的 `denoise_defaultOff` | **API** 默认值 `false`：`enableDenoise` 未传入时 100% 走不含门限的分支（逐位相同）。<br>⚠️ **注意与产品默认值区分**：`ADR-57` 起检测会话会主动传 `true`（`denoise.gate_enabled_by_default`），因此**默认路径的"逐位相同"只对未传参者成立**，不再等于"成品包的默认行为" |
| 18 | **产品默认值必须可断言、可回退（`ADR-57`）** | `dart run tool/session_tests.dart` 的 `ADR-57: the detection session asks the bridge for the noise gate` + `and the SSOT product default is ON` | 会话启动时 `FakeAudioBridge.lastEnableDenoise == FeatureConfig.denoiseGateEnabledByDefault == true`。**负例对照实测**：把 `DetectionSession.start` 里的 `enableDenoise:` 参数注释掉 → 该断言立刻红（`actual=false expected=true`） |
| 6 | 无跨 patch 全局统计 | 代码审查 + `PreprocessTest.kt` 的 `noCrossPatchState` | 单例对象无可变字段（反射断言 `Preprocess` 无 `var` 静态字段） |
| 7 | 纯静音不放大 | `PreprocessTest.kt` 的 `allZeroInput_staysZero` | 输出 RMS == 0；无 NaN |
| 8 | 输入长度校验 | `PreprocessTest.kt` 的 `wrongLength_throwsACD_MEL_002` | 抛出错误码 `ACD-MEL-002` |
| 9 | App 内不落盘 | `python ai/scripts/forbid_audio_write.py` | 命中数 == 0（FF-24 §1） |
| 10 | 输出为时域波形而非频谱 | `PreprocessTest.kt` 的 `output_isTimeDomainOnly` | 输出长度 == FF-09 的样本数；不存在长度为 `128 × n_frames` 的返回值 |
| 11 | **预加重沿流连续（非逐 patch 重启）** | `PreprocessTest.kt` 的 `preemphasis_usesPreviousRawSample`（**必须用非零 offset 的中间 patch**，源起点另有一例） | 中间 patch 的首样本 `y[0] = x[0] − 0.97·x_prev`，其中 `x_prev` 为 patch 开始前的最后一个**原始**样本；与「取 0.0」的结果差 > 1e-3（证明测试有区分力）；源起点则等价于 `x[−1] = 0.0`。~~原判据 11「去直流逐 patch 独立」~~ 已随 `ADR-21` 删除 DC 去除而替换 |
| 12 | 增益上限生效 | `PreprocessTest.kt` 的 `gainCap_limitsAmplification` | 极低电平输入下输出峰值 ≤ `gainCapDb` 对应的上限 |
| 13 | **谱减法开启前必须先有实测依据（`ADR-52`）** | `python tool/measure_denoise.py --snr 20 10 5 0` + 读 `ai/reports/denoise_effect.md` | 报告必须显示：① `clean` 行的 top1 与 `verify_artifacts.py` 独立测得的出厂模型 top1 **一致**（测量链自检）；② 若 `denoise_*` 行在 **≥10 dB** 时低于 `noisy` 行，则该配方**禁止**被设为默认或现场开启。<br>**当前实测（2026-09-15）**：`noisy` 在 20/10/5 dB 分别为 0.1667/0.1181/0.1111，而 `denoise_ref` 为 0.0069/0.0347/0.0347 —— **按现状接上谱减法会让识别显著变差**，因此开关必须保持 `false`（本判据与 §1.3「谱减法默认开启 | 禁止」互为印证）。 |
| 14 | **第 3 阶段时域门限的跨语言一致性（`ADR-56`）** | `powershell -File tool/jvm_build.ps1 -Run` 的 `golden_parity_withPythonReference` + `golden_is_not_a_noOp` | Kotlin 与 Python 参考实现在同一 golden 向量上逐元素差 ≤ `1e-6`（实测 `9.3e-10`）；且 golden **不得**等于其输入（实测 `max|expected-input| = 0.009`）。**生成器自身必须有这条自检**：首版输入把瞬态排得太密（相隔 6 帧而前瞻 ±4 帧），前瞻把每一帧都保护住了，golden 退化成输入的副本——那样的断言必然通过却什么都没验证 |
| 15 | **门限只减不增、且不改变瞬态频谱（`ADR-54`）** | `NoiseGateParityTest` 的 `gate_neverAmplifies_onNoiseOnlyInput` / `tone_aboveThreshold_passesThrough` / `noise_only_input_is_attenuated` | 逐样本 `|out| ≤ |in|`；纯噪音输入实测衰减 **−12.12 dB**（第一代配方是 **+9.5 dB**）；阈值以上的纯音最坏增益 ≤ 1.0 |
| 16 | **第 3 阶段必须落在 hop 预算内（§8 首次产出实测）** | `NoiseGateParityTest` 的 `preprocess_withGate_fitsTheHopBudget` | 实测 **2.14 ms/patch** 对 FF-12 的 **500 ms** 预算（**0.43%**）；预算取自 `FeatureConfig.INFERENCE_HOP_SECONDS`，**不得写成字面量**——首版误用 `PATCH_SECONDS × 500 = 2048 ms`，等于把预算放宽 4 倍，是一个必过而不验任何东西的闸门 |
| 17 | **行为指标不被降噪破坏（`FF-21g`）** | `python tool/check_chew_preservation.py` | 时域门限下咀嚼次数 MAE **5.6%**，对 `FF-21g` 的 **25%** 降级线余量 4.5 倍；`noisy` 基线 2.0%（详见 `ai/reports/chew_preservation.md`） |

## 8. 非功能约束
- **实时性**：预处理链（**预加重（流式边界）+ RMS 响度归一化**；**不含去直流**（`ADR-21` 删除）、不含高通，LUFS 不在推理侧）必须完成在 FF-12 对应的 hop 预算内。**✅ 实测已产出（`ADR-56`，本 SPEC 欠此项自 v1.0 起）**：`enableDenoise = true` 时整链 **2.14 ms/patch**（其中门限本身 1.99 ms），对 FF-12 的 **500 ms** 预算占 **0.43%**，在 JVM 上测得（`NoiseGateParityTest` 的 `preprocess_withGate_fitsTheHopBudget`）。**设备实测仍欠**：JVM 的 JIT 与 ART 不同，真机数字待现场补。
- **内存**：全链路原地/双缓冲处理，峰值额外内存 ≤ 2 × 65536 × 4 B；允许复用 `FloatArray`，不得每 patch 新增大数组。
- **确定性**：这是 `PLAN-T-08` 对齐测试能够存在的前提；任何引入随机性或跨 patch 状态的改动都属契约变更（`API-00` §3.9）。
- **隐私**：预处理只在内存中进行，中间量不得写 App 可读目录（FF-24 §1）。
- **可单测性**：`Preprocess` 不得依赖 Android API，必须可以在 JVM 单测中以纯数组调用（§7 判据 2/3/7/11 的前提）。
- **数值范围**：输出允许轻微越界 `[−1, 1]`（不钳制），但必须全为有限值（无 NaN/Inf）；下游 P-04 负责功率谱与 dB 截断。
- **可观测性**：本功能不产生用户可见输出；异常只通过错误码与诊断暴露，避免在检测页弹出技术性提示。
- **无障碍**：无 UI，不适用。

## 9. 裁剪与未做
- **本功能服务于「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）**（`00_功能清单` §6）：预处理是闭环中的一环，**不得裁剪**；但其中的 **LUFS 增强（仅训练侧，`ADR-17`）**与谱减法实验开关**属可裁剪的增强项**（推理侧的 RMS 归一化必做）。
- 第 3 阶段时域瞬态保护门限：**不做默认路径**，只保留实验开关，默认关闭（主方案 §3.7；`ADR-56`）。
- `X-06` RIR 混响 + Mixup 增强：**不做**（训练侧 `T-03`，与本功能无关，列出防止实现方顺手加混响）。
- **任何逐频带/谱域降噪**（神经降噪、Wiener、谱门限、第一代谱减法）：**不做**。此禁令不是"没时间做"，而是 `ADR-52`/`ADR-53` 的**实测结论**：三档 SNR 下每一族都把识别压到还不如不降噪。
- 重采样、AGC、动态范围压缩、去混响、声道混合：**不做**。
- ~~不使用 FF-08 的逐 patch `ref=np.max` 归一化思路（域偏移陷阱，`SPEC-00` §3.1 FF-08 备注）。~~ → **已失效**（`ADR-21`，2026-09-12）：频谱侧现在**就是**用 patch 相对刻度（`power_to_db_ref = "patch_max"`）。本行的原始意图仍成立 —— **本功能（时域预处理）不得做任何频谱归一化**，那是 P-04 的职责。
- `X-02` 手动修正、`X-05` 识别历史：与本功能无关，**不做**。
- 把预处理参数做成 UI 可调项（用户可调增益/滤波）：**不做**（参数只来自 `feature_config`，避免现场配置漂移）。

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-17`）**：**高通滤波器从 v1.0 移除**（`highpass = removed_in_v1`）。理由：主方案 §3.7 只保留「预加重 + 响度归一化」，高通**从来不在冻结计划里**；且 `fmin = 20 Hz` 的 Mel 滤波器组已经丢弃 20 Hz 以下，预加重也已抑制低频 —— **增加一个必须在两种语言里逐位对齐的滤波器是纯风险**。被否决备选：`2 阶 Butterworth @ 20 Hz`（两侧同时实现）。§5 的「高通截止频率 / 阶数」已改记「不适用（v1.0 已移除，`ADR-17`）」。
1b. **✅ 已关闭（依据 `ADR-21`，2026-09-12）**：**逐 patch 去直流已从链路中删除** —— 交付侧 `operation_order` 无 DC 阶段，保留它等于在麦克风与模型之间插一个训练时不存在的变换。本功能与 P-04 均**不做**去直流；原 §7 判据 11（`dcRemoval_isPerPatch`）已替换为流式预加重判据。
2. **✅ 已关闭（依据 `ADR-17`）→ ⚠️ 已由 `ADR-21`（2026-09-12）修订**：预加重首样本约定原冻结为 ~~`x[−1] = x[0]`（首样本原样通过）~~，理由是与 librosa `lfilter` 的初始条件一致。**该理由只在「每个 patch 都从录音开头开始」时成立**，而 patch 以 0.5 s 步长在 4.096 s 窗口上滑动，**每个 patch 有 87.8% 的音频已在上一 patch 被预加重过** —— 逐 patch 重启滤波器等于把不连续点放在模型最爱看的位置。**现行值：`preemphasis_boundary = "continuous_stream_previous_raw_sample_or_zero_at_source_start"`**（取前一**原始**样本，源起点 `0.0`）；两侧同读该键、不得各写常量，并纳入 §7 判据 4 与判据 11。
3. **✅ 已关闭（依据 `ADR-17`）**：**LUFS 只用于训练侧**：`feature_config.loudness_normalization = "training_only"`、`target_lufs = -23.0`（`T-03` 增强）；**推理侧不做 LUFS** —— FF-07/FF-08 的 patch 相对 dB + 逐 patch min-max 已提供尺度不变性（`ADR-21` 修订后的链路），现场做 LUFS 只增加开销。
4. **✅ 已关闭（依据 `ADR-P1`，2026-09-10；后经 `ADR-21`（2026-09-12）修订）**：`n_frames` 原冻结为 ~~`129`~~ → 现为 **`n_frames = 128`**（`129` 现为 `raw_mel_frames`，见 FF-11 / `ADR-21`）。
5. **谱减法的噪声估计方式未定**：若启用实验开关，噪声谱用「本 patch 内低能量段」还是「上一 patch 的静默段」会决定本功能是否仍为无状态。当前按「本 patch 内低能量段」实现以保持无状态；**需 B 确认**（若改为跨 patch，则 §2.3 必须改写为有状态并补状态迁移表）。
6. **预处理是否会进入 `SessionSummary` 的 `rmsStats`**：`API-01` §2.5 的 `rmsStats` 取自原始 PCM 还是预处理后波形未明确。本 SPEC 按「取原始 PCM」处理（与 `P-02` 的 VAD 口径一致），**需 B 确认后写入 `API-01`**。

**文档结束**

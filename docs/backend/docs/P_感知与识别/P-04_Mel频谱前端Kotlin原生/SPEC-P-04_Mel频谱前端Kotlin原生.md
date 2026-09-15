# SPEC-P-04 Mel 频谱前端（Kotlin 原生）

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付（**硬闸门**；不过则全项目退回） |
| 上游依据 | 主方案 §3.3/§4.1.2；`API-01` §2.1、§3.2、§5 第 1/3/4 项；`SPEC-00` §3.1 全段（FF-01~FF-12）、§3.5、§3.10（FF-25）、§7 |
| 依赖的 SPEC | `SPEC-P-03`（输入）、`SPEC-T-08`（跨语言对齐，**验收在本功能**）、`SPEC-P-05`（下游消费者） |

## 1. 目标与范围

### 1.1 一句话目标
在 Kotlin 原生实现「分帧 / Hann 窗 / FFT / Mel 滤波器组 / 对数压缩（patch 相对）/ 丢尾帧 / per-patch min-max」，输出 `Float32List`，长度 `128 × n_frames`，行主序 `mel[m * nFrames + t]`，并与 librosa 逐元素对齐（`atol=1e-3`）；若 D2 结束仍未产出 `[128,128]` 数组（`n_frames = 128`，`ADR-21`），立即执行 §6 的 Plan-S 兜底。

### 1.2 范围内（In Scope）
- 分帧与 `center=True` 的边界填充（FF-10）。
- Hann 窗，`win_length = n_fft`（FF-03）。
- 实数 FFT（`n_fft`，FF-03）与功率谱（FF-06）。
- Mel 滤波器组（`n_mels`/`fmin`/`fmax`，FF-05）。
- 对数压缩 `power_to_db`（`ref = "patch_max"`，`top_db = 80`）→ **丢弃尾帧** → **per-patch min-max** 到 `[0,1]`（FF-07 / FF-08，`ADR-21` 修订；顺序不可调换，见 §2.2 步骤 7–8）。
- 行主序内存布局 `mel[m * n_frames + t]`（`SPEC-00` §3.1，**全项目最易错点**）。
- `melVersion` 的维护与握手（`API-01` §2.1）。
- `Float32List` 载荷的组装与投递（`API-01` §3.2）。
- **Plan-S 兜底路径**（§6）与代价/验收方式的书面化。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| 预处理（去直流**已删除**、高通**已移除**、预加重流式、响度） | P-03（`ADR-21` 删除去直流、`ADR-17` 移除高通） |
| VAD、静默判定 | P-02 |
| 推理与聚合 | P-05 / P-06 |
| **Dart 侧再实现一份 Mel** | `API-00` §1 的关键裁定：Mel 只在 L1（Kotlin），Dart 只收结果 |
| 原生侧推理 | `API-01` §6：会让 `P-06` 的聚合状态分裂 |
| 用 `hop = 160` / `帧移 10 ms` / 帧长 25 ms | **术语与参数禁令**（FF-04 备注、`SPEC-00` §3.10） |
| 用 `3 s` / `3 秒` 作为音频窗长 | **禁令**：唯一合法窗长为 FF-09 |
| ~~逐 patch `ref=np.max` 归一化~~ | **已反转**：本行原写「**禁止**（FF-08 备注，主方案 §4.1.2 域偏移陷阱）」。`ADR-21`（2026-09-12）**正式采纳** patch 相对刻度 —— 交付模型的 `power_to_db_ref = "patch_max"`，禁止它等于让推理与训练不一致。**现行规则以 FF-07 / FF-08 为准** |
| iOS / 桌面端 Mel 实现 | 推迟第二阶段（`00_功能清单` §5） |
| Mel 张量落盘 | FF-24 §1：特征张量不落盘（离线对齐产物除外，且只能在测试产物目录） |

## 2. 功能行为

### 2.1 触发与前置条件
1. 收到 P-03 输出的 `FloatArray(65536)`（FF-09）。
2. `feature_config` 的 Mel 段随握手校验通过（`API-00` §3.6）。
3. 输入长度必须等于 FF-09，否则 `ACD-MEL-002`。
4. **`n_frames` 已修订（`ADR-21`，2026-09-12；原 `ADR-P1`，2026-09-10 冻结为 ~~`129`~~）**：FF-11 = **`n_frames = 128`**（另有 `raw_mel_frames = 129`，即 STFT 原始帧数）；**已拍板，D2 训练可直接开工**（`PLAN-00` §1 D1/D2）。

### 2.2 主流程（编号步骤）
1. 接收 `FloatArray(65536)`。
2. `center=True`（FF-10）：两端按配置的填充模式补齐，使 STFT 原始帧数等于 `65536 // hop + 1`（= FF-11 的 `raw_mel_frames` = 129，`ADR-21`）；随后按 `frame_selection` 丢弃尾帧，保留 `[0, 128)`，只把 128 帧喂给模型。
3. 分帧：帧长 `n_fft`（FF-03）、帧移 `hop_length`（FF-04）；STFT 原始帧数必须等于 FF-11 的 `raw_mel_frames`（129，`ADR-21`），不等则抛 `ACD-MEL-001`（**最高频的联调错误**，`API-00` §3.5）。
4. 逐帧加 Hann 窗（FF-03）。
5. 逐帧实数 FFT → 功率谱 `|X|^power`，`power = 2.0`（FF-06）。
6. 功率谱过 Mel 滤波器组 → `n_mels` 个频带（FF-05）。
7. 对数压缩 `power_to_db`：**`ref` 取本 patch 的最大值**（`power_to_db_ref = "patch_max"`）、`amin = 1e-10`、`top_db = 80`（FF-07，`ADR-21` 修订）。⚠️ **dB 参考与 `top_db` 下限算在全部 129 帧上**。
8. **丢弃尾帧**：按 `frame_selection = {drop_tail, [0,128)}` 从 129 帧里保留 `[0, 128)`（FF-11 / FF-08，`ADR-21`）。
9. **per-patch min-max**：在**保留下来的 128 帧**上做 min-max 到 `[0,1]`（`normalization = "per_patch_minmax"`，`epsilon = 1e-08`，输出区间 `[0.0, 1.0]`，FF-08，`ADR-21`）。**~~固定 dB 截断 `clip(x, −80.0, 0.0)`~~ 已取消**（`db_clip_range` 键已删除）；**~~不得使用逐 patch 的 `ref=np.max`~~ 该禁令已由 `ADR-21` 反转** —— 上面的第 7 步就是它。
10. 按行主序写入 `Float32List(128 × n_frames)`：`mel[m * nFrames + t]`，`m` 为频带、`t` 为 Mel 时间帧（`SPEC-00` §3.1）。
11. 组装 `patch` 事件的 `mel` / `nMels` / `nFrames` / `melVersion` 字段并投递（`API-01` §3.2）。
12. 每次改动数值行为（窗边界、`ref`、归一化、填充模式）必须递增 `melVersion`，否则握手无法捕获漂移。

> ⚠️ **步骤 7–9 的顺序是承重的**（`ADR-21` 裁定 4）：先 `power_to_db`（参考值取自 129 帧）、再丢尾帧、最后在 128 帧上 min-max。**"先 min-max 再丢帧"会得到不同的数**，不得重新推导所谓等价写法。完整顺序见 `feature_config.operation_order`。

### 2.3 状态与状态迁移
**无状态**：逐 patch 纯计算。唯一跨 patch 的持久物是 `melVersion`（编译期常量，不随会话变化）与滤波器组（会话内只构建一次并缓存，**但缓存不得改变数值结果**）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| STFT 原始帧数不等于 `raw_mel_frames`（129，`ADR-21`） | 抛 `ACD-MEL-001`，detail 带 `{expectedFrames, actualFrames}`；**不得静默截断或补帧**（唯一允许的丢弃是 `frame_selection` 规定的尾帧） |
| 输入含 NaN/Inf | 抛 `ACD-MEL-001`（在分帧前做 `isFinite` 全量检查） |
| 全零输入 | 输出全 `0.0`（per-patch min-max 的确定结果），不得 NaN |
| 会话内滤波器组缓存 | 只允许缓存，不允许因缓存而复用上一 patch 的中间数组导致数值差异 |
| Demo Mode B 注入的同一 wav | 与 mic 路径产出逐元素一致的 Mel（同一函数、同一参数） |
| `n_frames` 修订值被改动 | 本 SPEC 所有判据以 `128 × n_frames` 表达，**仅需改常量**；`atol` 判据不变。现值为 `n_frames = 128`（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值 ~~129~~），改动须走 `SPEC-C-03` 变更传播 |
| `melVersion` 未随数值改动递增 | 视为缺陷；握手测试用「故意改一位数值」的注入用例捕获 |

## 3. 接口契约
> 权威定义：`API-01` §2.1、§3.2、§5。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Kotlin 内部（P-03 → 本功能） | `MelFrontend.compute(samples)` | `FloatArray(65536)`（FF-09） | `Float32List(128 × n_frames)` | `ACD-MEL-001`、`ACD-MEL-002` |
| Dart → Kotlin | `getCapabilities` | `{}` | `melVersion`、`sampleRate`、`nFft`、`hopLength`、`nMels`、`rawMelFrames`、`nFrames`、`fmin`、`fmax`、`preemphasis`、`preemphasisBoundary`、`powerToDbRef`、`topDb`、`normalization`、`patchSamples` 共 **15 字段**（`ADR-21`；原 ~~12 字段~~，含已出列的 ~~`dbClipMin`/`dbClipMax`~~） | 无 |
| Kotlin → Dart | 事件 `patch` | — | `{seq, tStartMs, tEndMs, melVersion, nMels, nFrames, mel, rms, voiced, source}` | — |
| Dart → Kotlin | `ackPatch` | `{sessionId, seq}` | `{ok: true}` | 无 |
| 离线 ↔ 端侧 | 跨语言对齐 | 同一 wav | `mel.npy`（Python）/ `mel.bin`（Kotlin） | 对齐失败即 `PLAN-T-08` 不通过 |

**`mel` 传输硬约束**（`API-01` §3.2）：
- 必须用 `Float32List`（`StandardMessageCodec` 原生类型）；**不得**用 `List<double>`（逐元素装箱）、**不得**用 Base64。
- 必须能被 Python 侧 `np.frombuffer(buf, '<f4').reshape(nMels, nFrames)` 直接还原。

## 4. 数据契约
> ⚠️ **本契约没有 JSON Schema**：schema 集**固定为 6 份**且**不覆盖原生桥接载荷**。
> - `NativeCapabilities` 的 **15 个字段**（`ADR-21`；原 ~~12 个~~）由**启动握手逐字段比对**保证（`API-00` §3.6），不符即 `ACD-CFG-001`；
> - `patch.rmsEnvelope` 与 `patch.mel` 的形状由 `API-01` §5 一致性测试的第 3/4/9 条保证，其中**第 4 条是跨语言数值对齐**（Kotlin `mel.bin` vs Python `mel.npy`，`np.allclose(atol < 1e-3)`），**JSON Schema 根本无法表达这类约束**。

| 项 | 类型 | 值域 / 约束 |
|---|---|---|
| `mel` | `Float32List` | 长度 `nMels × nFrames`；`[0.0, 1.0]`；行主序 `mel[m * nFrames + t]` |
| 张量形状（喂给模型时） | — | `[1, 128, n_frames, 1]`（FF-14 的输入形状与之必须一致） |
| `nMels` | `int` | 来自 FF-05 |
| `nFrames` | `int` | **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| `melVersion` | `String` | 语义化版本；**当且仅当 Mel 数值行为变化时递增** |
| `mel[m*nFrames+t]` 索引方向 | — | `m` = Mel 频带（慢变维），`t` = Mel 时间帧（快变维） |
| Mel/STFT 数值参数 | — | **`pad_mode = "constant"` · `power_to_db_ref = "patch_max"` · `power_to_db_amin = 1e-10` · `top_db = 80.0` · `mel_htk = false` · `mel_norm = "slaney"` · `normalization = "per_patch_minmax"`**（值见 `feature_config` 的对应键）。⚠️ 其中 `power_to_db_ref` 与 `normalization` 已由 **`ADR-21`（2026-09-12）修订**：原冻结值为 ~~`power_to_db_ref = 1.0`（绝对刻度，`ADR-16`）~~ 与 ~~`normalization = "fixed_db_clip"` + `db_clip_range = [-80.0, 0.0]`（FF-08 原文）~~；`db_clip_range` 键**已删除**。Python 训练侧与 Kotlin 侧**必须同时读取 `feature_config` 的同一组键，不得各写常量** —— 它们是 `PLAN-T-08` 的 `atol=1e-3` 能否通过的直接决定因素 |

## 5. 参数与常量
> 全部引用 `SPEC-00 §3`；本处不复制可能漂移的字面值。

| 项 | 引用 |
|---|---|
| 采样率 / 声道 / 位深 | FF-01 |
| 窗函数与 `win_length = n_fft` | FF-03 |
| `hop_length` | FF-04（**不是 160**） |
| `n_mels` / `fmin` / `fmax` | FF-05 |
| 功率谱指数 | FF-06 |
| `power_to_db` 的 `ref` / `amin` | FF-07（**`ref = "patch_max"`**、`amin = 1e-10`；旧值 ~~`ref = 1.0` 绝对刻度（`ADR-16`）~~ → 已由 `ADR-21`（2026-09-12）修订，见 FF-07 / `ADR-21`） |
| 归一化策略与 min-max | FF-08（**`normalization = "per_patch_minmax"`**、`epsilon = 1e-08`、输出 `[0.0, 1.0]`；旧值 ~~固定 dB 截断 `clip(x,−80,0)`（`db_clip_range` 键）~~ → **`db_clip_range` 已删除**，见 FF-08 / `ADR-21`） |
| patch 采样数 | FF-09 |
| `center` | FF-10 |
| `n_frames` / `raw_mel_frames` | FF-11（**`n_frames = 128`**（张量宽度）+ **`raw_mel_frames = 129`**（STFT 原始帧数）+ `frame_selection = {drop_tail, [0,128)}`；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，见 FF-11 / `ADR-21`） |
| 推理滑窗步长 | FF-12 |
| 模型输入形状 | FF-14 |
| 填充模式、`power_to_db` 的 `ref`、Mel 滤波器的 `htk`/`norm`、归一化 | **已冻结（`ADR-16`，其中 `power_to_db_ref` 与 `normalization` 经 `ADR-21`（2026-09-12）修订；`SPEC-00` §3 的 FF-03 / FF-05 / FF-07 / FF-08，值见 `feature_config` 对应键）**：`pad_mode = "constant"` · **`power_to_db_ref = "patch_max"`**（旧 ~~`1.0`~~） · `mel_htk = false` · `mel_norm = "slaney"` · **`normalization = "per_patch_minmax"`**（旧 ~~`"fixed_db_clip"`~~，其 `db_clip_range` 键已删除）；两侧同读同一组键，不得各写常量（见 §10） |

## 6. 异常与降级

**异常表**
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 帧数不符 | `frames != FF-11` | `ACD-MEL-001`，丢弃本 patch；连续出现则暴露诊断 | 无（自检面板可见 `droppedPatches`） |
| 输入样本数不符 | 长度断言 | `ACD-MEL-002` | 无 |
| 输入含 NaN/Inf | 全量 `isFinite` 检查 | `ACD-MEL-001` | 无 |
| 与 librosa 对齐失败（`atol > 1e-3`） | `mel_parity_test.py` | **硬闸门失败**：不得进入 D4；先判定是填充模式、dB 口径还是滤波器组口径 | 无（开发期） |
| 单 patch Mel 耗时超 hop 预算 | D2 实测 | 缓存滤波器组、复用缓冲区；仍超则交由 `PLAN-P-05` 提高推理步长 | 无 |
| `melVersion` 与实际数值不符 | 握手 + 注入用例 | `ACD-CFG-001`，禁止进入检测页 | 「配置不一致，请重装应用」 |

**Plan-S 兜底（必须实现，不得只写在计划里）**
**触发条件（硬性）**：**D2 结束仍未产出 `[128,128]` 数组**（`n_frames = 128`，`ADR-21`；`PLAN-00` §1 D2 硬验收、§3.1）。

**动作**：放弃自写 Kotlin Mel，立即改用 **TFLite Task Library `AudioClassifier` + `TensorAudio`**，其内置 Mel 前端默认参数（16 kHz / n_fft 1024 / hop 512 / n_mels 128）与 FF-01~FF-05 一致。

**Plan-S 的代价（必须如实记录，不得隐瞒）**：
1. **失去逐元素对齐能力**：Task Library 的特征化与归一化在库内部完成，本 SPEC §2.2 步骤 7–9 的「`power_to_db(patch_max)` → 丢尾帧 → per-patch min-max」**不可干预**；因此 `PLAN-T-08` 的 Mel 逐元素 `atol=1e-3` 判据**不适用于 Plan-S**。
2. **对齐口径必须降级为端到端标签级**：以 `PLAN-T-08` 的 `parity_test.py`（标签一致率 + 置信度偏差）作为替代判据；**该降级必须写进模型卡与测试报告**。
3. **训练侧需同步**：若 Task Library 的特征与训练侧 `librosa` 特征不等价，则须以「Task Library 特征」重训或至少重做评估（`T-04`/`T-05` 追加一次），可能影响 D3 CP1 的时间点。
4. **引入额外依赖与体积**：APK 体积增量在 D4 实测产出，本 SPEC 不预设数字；`C-04` 的体积复核须重跑。
5. **Dart 侧契约不变**：仍以 `Float32List` 形式产出 patch（由 Task Library 的 `TensorAudio` 取特征后转换），`API-01` §3.2 与 `SPEC-P-06` 不受影响。

**Plan-S 的验收方式**：
| # | 判据 | 验证方式 | 通过阈值 |
|---|---|---|---|
| S1 | 特征形状与冻结值一致 | `getCapabilities()` 与 `feature_config.json` 全等；`patch.nFrames == FF-11` | 一致；否则 `ACD-CFG-001` |
| S2 | 端到端标签级一致 | `python ai/scripts/parity_test.py --n 50` | 退出码 0；stdout 含「标签一致率 ≥ 0.98」「最大置信度偏差 ≤ 0.05」 |
| S3 | 端到端可用 | 真机连续进食 30 s，`U-02` 出现确认卡片 | 人工核对表逐项通过（`records/reports/p04_plan_s.md`） |
| S4 | 降级已留痕 | 模型卡与测试报告中出现 Plan-S 声明 | 文本存在性断言（脚本 `grep`） |

**Plan-S 的可行性必须在 D0 调研清楚，不得等到 D2 临时找**（`PLAN-00` §3.1）。

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 输出形状正确 | `android/app/src/test/kotlin/com/acoudiet/app/audio/MelFrontendTest.kt` 的 `shape_is128xNFrames` | `mel.size == 128 × n_frames`；`n_frames` 取自 FF-11 常量 |
| 2 | 行主序布局正确 | `MelFrontendTest.kt` 的 `rowMajorIndex_isMelBandMajor`（构造可区分频带与时间的输入） | `mel[m * nFrames + t]` 与参考实现逐元素相等 |
| 3 | Python 侧可直接还原 | `python ai/scripts/mel_parity_test.py --n 20 --shape-only` | 退出码 0；`np.frombuffer(buf, '<f4').reshape(128, n_frames)` 成功且无剩余字节 |
| 4 | 与 librosa 逐元素对齐（**硬闸门**） | `python ai/scripts/mel_parity_test.py --n 20` | 退出码 0；stdout 含 `allclose_ok=true`；`np.allclose(py, kt, atol=1e-3)` 为真（20 个 wav 全部满足） |
| 5 | 值域在 `[0,1]` | `MelFrontendTest.kt` 的 `range_within01` | `min ≥ 0.0` 且 `max ≤ 1.0` |
| 6 | 帧数不符抛错 | `MelFrontendTest.kt` 的 `wrongFrameCount_throwsACD_MEL_001` | 错误码 `ACD-MEL-001`，detail 含 `expectedFrames`/`actualFrames` |
| 7 | **patch 相对 dB 参考（`ref` = 本 patch 最大值）** | `python ai/scripts/mel_parity_test.py --n 20 --probe-ref` | 构造含极强脉冲的 wav：Python 侧与 Kotlin 侧**各自**对同一 patch 取 `ref = max`，输出逐元素 `atol=1e-3` 相等；且**绝不允许**出现跨 patch 的绝对刻度参考（旧口径的 ~~固定 dB 截断 `clip(x,−80,0)` + `ref=1.0`~~ 已由 `ADR-21`（2026-09-12）**反转**，本判据随之反转 —— 它现在要求"就是用 patch 相对刻度"）。`mel.max() == 1.0` 与 `mel.min() == 0.0` 由 per-patch min-max 保证 |
| 8 | 确定性 | `MelFrontendTest.kt` 的 `deterministic_sameInputSameOutput` | 同一输入 10 次逐元素相等 |
| 9 | 握手字段一致 | `flutter test test/native/capabilities_handshake_test.dart` | `melVersion`/`rawMelFrames`/`nFrames`/`nMels`/`hopLength`/`nFft`/`preemphasisBoundary`/`powerToDbRef`/`topDb`/`normalization` 等 **15 字段**与 `feature_config.json` 全等（`ADR-21`；原 ~~12 字段~~） |
| 10 | `melVersion` 递增可被捕获 | `CapabilitiesDriftTest`（注入改一位数值的假实现） | 必须抛 `ACD-CFG-001` |
| 11 | 载荷类型为 `Float32List` | `flutter test test/native/patch_payload_type_test.dart` | 运行时类型为 `Float32List`，不是 `List<double>`/`String` |
| 12 | 性能预算 | `MelFrontendTest.kt` 的 `bench_singlePatch`（仅记录，不设通过线） | 输出耗时日志；**数值为 D2 实测产出**，写入 `records/reports/p04_mel_bench.md` |
| 13 | Plan-S 触发时可切换 | `flutter test test/native/mel_backend_switch_test.dart`（`MelBackend` 抽象） | 两种后端均可编译并产出同形状 `Float32List` |
| 14 | 术语禁令零命中 | `python ai/scripts/assert_terms.py`（全仓库搜 `hop.*160`、`帧移 10`、`3s 窗`） | 命中数 == 0（`SPEC-C-03`） |

## 8. 非功能约束
- **实时性**：单 patch 全链路（分帧→FFT→滤波器组→dB→布局）必须落在 FF-04 对应的 hop 预算内；实测耗时在 **D2 实测产出**，写入 `records/reports/p04_mel_bench.md`，本 SPEC 不预设数字。
- **内存**：滤波器组与窗函数会话内构建一次并复用；每 patch 的临时数组复用，峰值额外内存 ≤ 65536 × 4 B 的常数倍。
- **确定性**：同输入必同输出，是 `PLAN-T-08` 存在的前提；任何随机化（如 Mel 抖动）都属契约变更。
- **隐私**：Mel 张量只存在于内存与事件载荷中，**不落盘**；离线对齐产出的 `mel.bin` 只能放在测试产物目录，不得进 App 资源（FF-24 §1）。
- **线程**：`MelFrontend.compute` 运行在原生后台线程（`API-00` §3.7）。
- **无障碍**：无 UI，不适用。

## 9. 裁剪与未做
- **本功能属「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）**（`00_功能清单` §6），且其自身是**四项硬闸门之首**（`00_功能清单` §1、`docs/README.md` §6）。**不得裁剪。**
- iOS / 跨平台 Mel 前端：**不做**（推迟第二阶段；需重做整套 FFT 与滤波器组）。
- 蓝牙耳机 / 手表采集路径的 Mel：**不做**（推迟第三阶段）。
- 15–20 类扩展所需的 Mel 参数改动：**不做**（会改 FF-05 与模型输入形状，须走 `SPEC-C-03` 传播）。
- Dart 侧第二份 Mel 实现：**不做**（`API-00` §1 关键裁定）。
- ~~逐 patch `ref=np.max` 归一化：**不做**（FF-08 备注，域偏移陷阱）~~ → **已反转**（`ADR-21`，2026-09-12）：patch 相对 `ref` **现在是冻结链路的一环**，见 §2.2 步骤 7 与 §7 判据 7。本 SPEC **必须**实现它，实现方不得援引本行拒绝。
- 因果/流式 Mel（逐帧增量计算）：**不做**（`center=True` 已要求整段补齐，FF-10）。

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`，2026-09-10；后经 `ADR-21`（2026-09-12）修订）**：原问题「`n_frames` 未拍板」**已冻结为 ~~`n_frames = 129`~~（选项 B，保留 4.096 s 窗口）、并已修订为 **`n_frames = 128` + `raw_mel_frames = 129`**，D2 训练可直接开工，**不存在"改选项即已训练权重全部作废"的悬置风险**。选项 A（128 / 4.064 s / 65024 样本）**已否决**；`ADR-21` 的修订不改变窗口长度，故任何改动仍须走 `SPEC-C-03` 变更传播并重跑 `T-08` 对齐。
2. **✅ 已关闭（依据 `ADR-16` / FF-03）**：STFT 填充模式**已冻结为 `pad_mode = "constant"`**（**零填充**，librosa `center=True` 的默认）；`reflect` **已否决** —— 它会改变前若干 Mel 帧的数值，直接决定 `atol=1e-3` 能否通过。
3. **✅ 已关闭（依据 `ADR-16` / FF-07）→ ⚠️ 已由 `ADR-21`（2026-09-12）正式反转**：本项原冻结为 ~~`power_to_db_ref = 1.0`（绝对刻度）~~，理由是"使 FF-08 的固定 dB 截断作用在绝对标度上、避免 patch 相对量"。**该理由对 ADR-16 当时要冻结的链路成立，但对交付制品不成立** —— 交付的模型是**按 patch 相对刻度训练**的（`ref = patch_max`），此时"推理与训练不一致"是**更大的**误差。**现行值：`power_to_db_ref = "patch_max"`**，且 `normalization` 同步由 ~~`fixed_db_clip`~~ 改为 `per_patch_minmax`（`db_clip_range` 键已删除）。完整裁定见 `ADR-21` 裁定 2/3。
4. **✅ 已关闭（依据 `ADR-16` / FF-05）**：Mel 滤波器组**已冻结为 `mel_htk = false` + `mel_norm = "slaney"`**（**Slaney 刻度与 Slaney 面积归一化**，librosa 默认）；`htk=True` **已否决**（滤波器形状不同，是本项目第二个高危数值分歧点）。
5. **Plan-S 的 D0 调研结论未归档**：`PLAN-00` §3.1 要求在 D0 调研清楚，但当前仓库 `records/reports/` 下无该记录。**需 B 在 D0 补齐并在本 SPEC §6.2 回填结论。**
6. **Plan-S 与 FF-08 存在不可调和的冲突**：Task Library 内部特征化不接受本 SPEC §2.2 步骤 7–9 的链路干预（见 §6.2 代价 1）。触发 Plan-S 时必须同步修改 `SPEC-T-08` 的判据口径，**需 A/B 三方确认**。

> **第 2、3、4 条的共同硬性约束（`ADR-16`；第 3 条的取值经 `ADR-21` 修订）**：**`pad_mode` / `power_to_db_ref` / `mel_htk` / `mel_norm`** 这四个值（`ADR-21` 之后还应加上 `power_to_db_amin` / `top_db` / `normalization` 及其 min-max 三键）**必须由 Python 训练侧与 Kotlin 侧同时读取 `feature_config` 的同一组键，不得各写常量** —— 它们是 `PLAN-T-08` 的 `atol=1e-3` 能否通过的直接决定因素。

**文档结束**

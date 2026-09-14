# SPEC-C-03 `feature_config` 单一真源与变更传播

| 项 | 值 |
|---|---|
| 域 | `C` · 合规与工程基础 |
| 归属 | A+B |
| 状态 | ✅ v1.0 交付（**硬闸门**） |
| 上游依据 | 主方案 §3.1、§4.1.1（变更传播表 P-1~P-9）、§4.1.2、§5.1；`shared/feature_config.json`；`SPEC-00` §3（FF-01~FF-22）、§3.5；`API-00` §3.1/§3.6/§3.9；`API-01` §2.1；`API-05` §7.1 |
| 依赖的 SPEC | 无（被 `SPEC-P-04`、`SPEC-T-08`、`SPEC-P-05`、`SPEC-C-05` 依赖） |

## 1. 目标与范围

### 1.1 一句话目标

让 `shared/feature_config.json` 成为**训练侧与 App 侧唯一可写数值的地方**：两侧都从它派生常量、启动时逐字段握手校验，任何参数变更必须走 14 项传播单（P-1~P-9 + A-1/A-2/ADR-05/ADR-07/ADR-09）并在全项目留下零旧值残留。

### 1.2 范围内（In Scope）

| # | 内容 |
|---|---|
| 1 | `shared/feature_config.json` 的**管理与版本化**（**49 键**；`ADR-21`（2026-09-12）由 41 键扩至 49 键，见 §4 与 §10 #5；本功能**只管理、不重写数值**） |
| 2 | Dart 侧**代码生成** camelCase 常量（禁止在业务代码手写字符串键名，`API-00` §3.1） |
| 3 | Kotlin 侧**编译期固化**同一组值并由 `getCapabilities()` 暴露（`API-01` §2.1）；**启动握手**逐字段比对 `API-00` §3.6 的 **15 字段**（`ADR-21`（2026-09-12）由 12 字段扩至 15 字段，见 §3），任一不符 → 抛 `ACD-CFG-001` 并**禁止进入检测页** |
| 5 | 参数变更传播单（主方案 §4.1.1 的 P-1~P-9，v1.0 修订后为 **14 项**：P-1~P-9 + A-1/A-2/ADR-05/ADR-07/ADR-09）逐项打勾 + 机械验收搜索 |
| 6 | **已修订** `n_frames = 128`（`ADR-21`，2026-09-12；原 ADR-P1 冻结值 ~~`n_frames = 129`~~ → 128）的四处同步管理（`SPEC-00` §3.5）；与 `model_card.json` 的 hash 闭环（`API-05` §7.1） |

### 1.3 范围外（Out of Scope）

| 不做 | 归属 |
|---|---|
| 修改任一冻结数值（含 `n_frames` 的最终取值） | `SPEC-00` §3 + A 拍板 |
| Mel 前端实现（分帧/FFT/滤波器组） | `SPEC-P-04` |
| Python 侧特征实现、跨语言数值对齐测试本身 | `SPEC-T-03`/`SPEC-T-08`（本功能只管"两侧同源"） |
| 模型训练/量化/导出 | `SPEC-T-04`/`SPEC-T-07` （运行时从网络拉配置亦永久禁止，见 §9） |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 变更触发 | 任何人要改动 SSOT 的任一数值 → 必须先提交变更传播单（§2.2 步骤 3） |
| 握手触发 | App **冷启动时一次**，成功后缓存 `NativeCapabilities`，整个生命周期不重复握手（`API-00` §3.6） |
| 前置 | `feature_config.json` 已被构建期同步到 `app/assets/`（`API-05` §7）；生成器可运行；Kotlin 侧常量由生成/同步机制产出，**不得手写第二份**（否则 R-20 必然发生） |

### 2.2 主流程（编号步骤）

1. **读取**：训练侧（Python）直接读 `shared/feature_config.json`；App 侧读 `app/assets/feature_config.json`（构建期同步产物）。
2. **生成双侧常量**：① Dart 生成器产出 camelCase 常量文件；② Kotlin 侧从同一份 JSON 产出编译期常量（生成或构建期同步，二选一由 `PLAN-C-03` §3 定）。生成产物**必须带"禁止手改"标记**。
3. **变更登记**：任何数值变更 → 在 `PLAN-C-03` §3 的变更传播单登记 → 逐项打勾 → 跑 §7 的机械验收搜索。
4. **启动握手与放行/拦截**：Dart 读 assets 配置 → 调 `native.getCapabilities()` → 按 §3 的 **15 字段**逐字段比对（`ADR-21`）；全等 → 缓存并放行；任一不符 → 抛 `ACD-CFG-001`，**禁止进入检测页**（fail fast，禁止静默垃圾输出，`API-05` §8）。
6. **制品闭环与已拍板决策跟踪**：`model_card.nFrames` / `melVersion` / `featureConfigSha256` 与 SSOT/APK 三方核对（`API-05` §7.1）；`n_frames` **已按 §10 #1 完成四处同步**（`ADR-P1`，2026-09-10；该值后由 **`ADR-21`（2026-09-12）修订为 128**，同步已重做）并重跑 §7 判据。

### 2.3 状态与状态迁移

握手是**有状态**的（仅两个稳定态 + 一个拦截态）：

| 状态 | 含义 | 允许的下一状态 |
|---|---|---|
| `CFG_UNVERIFIED` | 冷启动后、握手完成前 | `CFG_OK`、`CFG_MISMATCH` |
| `CFG_OK` | **15 字段**全等，能力已缓存 | 终态（至进程结束） |
| `CFG_MISMATCH` | 任一字段不符，已抛 `ACD-CFG-001` | 无（**禁止进入检测页**；需修代码重启） |

### 2.4 边界条件

- **数值不可就近取整、两侧常量必须同源**：SSOT 是唯一真源（`SPEC-00` 开篇裁定）；训练脚本与 App 端都读它，禁止各写一份常量（主方案 §4.1.2）。
- **`n_frames` 已修订为 128**（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~；`SPEC-00` §3.5 / FF-11）：所有文档一律写 `n_frames = 128`（`raw_mel_frames` 才是 129），**不得再拿 129 当张量宽度**（129 是 STFT 原始帧数；128 也已不再是「已被否决的选项 A」）。⚠️ `ADR-21` 把这一概念**拆成两个键**，故握手清单里 `rawMelFrames` 与 `nFrames` **同时存在**（见 §3）—— 把两个数合成一个数正是 `ADR-21` 所修缺陷的成因。
- **握手只在启动时比对**：不做运行时热更新（无网络，`API-05` §1）；生成产物不得手改，手改即在制造第二份真相。
- **`melVersion` 不在 SSOT 的 49 键内**，却出现在 15 字段握手清单中 → 期望值来源需拍板，见 §10 #2。

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Dart → Kotlin | `getCapabilities()`（`API-01` §2.1） | `{}` | `NativeCapabilities`（握手取其中 **15** 字段） | 无（**此方法必须永不失败**） |
| Dart 内部 | 握手比对（`API-00` §3.6） | assets 配置 + 上者 | `CFG_OK` / 异常 | `ACD-CFG-001`（不重试，禁止进入检测页） |
| 出网 | **不存在** | — | — | 配置不得从网络获取（`R-OUT-3`） |

**握手 15 字段（逐字段比对，一项不符即抛 `ACD-CFG-001`）**（`ADR-21`（2026-09-12）由 12 字段扩至 15 字段）：

| # | 字段 | SSOT 对应键 |
|---|---|---|
| 1–2 | `melVersion` · `sampleRate` | **无对应键**（§10 #2） · `sample_rate` |
| 3–4 | `nFft` · `hopLength` | `n_fft` · `hop_length` |
| 5–6 | `nMels` · `rawMelFrames` | `n_mels` · `raw_mel_frames`（**新增**，= 129；`ADR-21`） |
| 7–8 | `nFrames` · `fmin` | `n_frames`（**已修订 = 128**，`ADR-21`；~~已冻结 = 129~~） · `fmin` |
| 9–10 | `fmax` · `preemphasis` | `fmax` · `preemphasis` |
| 11–12 | `preemphasisBoundary` · `powerToDbRef` | `preemphasis_boundary`（**新增**） · `power_to_db_ref`（**新增**） |
| 13–15 | `topDb` · `normalization` · `patchSamples` | `top_db`（**新增**） · `normalization`（**新增**） · `patch_samples` |

> **`ADR-21` 的入列/出列**：入列 `rawMelFrames`、`preemphasisBoundary`、`powerToDbRef`、`topDb`、`normalization`（5 个）；出列 ~~`dbClipMin`~~、~~`dbClipMax`~~（2 个，对应已删除的 `db_clip_range` 键）—— 12 + 5 − 2 = **15**。逐字顺序以 `API-00` §3.6 与 `API-01` §2.1 的 `getCapabilities` 出参为准。

## 4. 数据契约

**`shared/feature_config.json` 键值表（**49 键**，逐字照抄；`snake_case` 为 Python 侧可读优先，`API-00` §3.1。~~旧口径：41 键~~ —— `ADR-21`（2026-09-12）由 41 键扩至 49 键）**：

| # | 键 | 值（逐字） | 含义 | FF 事实 / 冻结状态 |
|---|---|---|---|---|
| 1–5 | `_comment` · `_comment_2` · `_comment_3` · `_comment_4` · `project` | "AcouDiet frozen feature spec -- SINGLE SOURCE OF TRUTH for both training and app side." · "Any change here MUST be mirrored via the change-propagate list in SPEC-C-03 section 7 (14 items)." · "All values are FROZEN as of 2026-09-10, REVISED 2026-09-12 by ADR-21 (Mel front-end v1.1) after the delivered model proved the training-side chain differed. See _decisions for the recorded choices and their rationale." · "ADR-21 note: preemphasis_boundary / power_to_db_ref / normalization / n_frames / input_shape were REVISED in place. The superseded values live in _decisions.mel_frontend_v1_1.supersedes, not deleted, so the change stays auditable." · "AcouDiet" | 真源与传播声明、冻结声明、`ADR-21` 修订说明、项目名 | 非 FF（元数据） · 已冻结（`_comment_3` / `_comment_4` 文本随 `ADR-21` 更新） |
| 5 | `sample_rate` | 16000 | 采样率 Hz | FF-01 · 已冻结 |
| 6 | `channels` | 1 | 声道数 | FF-01 · 已冻结 |
| 7 | `bit_depth` | 16 | PCM 位深 | FF-01 · 已冻结 |
| 8 | `preemphasis` | 0.97 | 预加重系数 | FF-02 · 已冻结 |
| 9 | `preemphasis_boundary` | "continuous_stream_previous_raw_sample_or_zero_at_source_start" | 预加重首样本约定 | `ADR-17` → **`ADR-21`（2026-09-12）修订 · 已冻结**（沿流取前一**原始**样本；源起点用 `0`。~~`"first_sample_passthrough"`（`x[−1] = x[0]`，首样本原样通过）~~ —— 旧规则只在"每个 patch 都从录音开头开始"时自洽，而 patch 以 0.5 s 步长滑动、**每个 patch 有 87.8% 的音频已在上一 patch 被预加重过**，逐 patch 重启滤波器会把不连续点放在模型最爱看的位置） |
| 10 | `window` | "hann" | 窗函数 | FF-03 · 已冻结 |
| 11 | `n_fft` | 1024 | FFT 点数 | FF-03 · 已冻结 |
| 12 | `win_length` | 1024 | 窗长 | FF-03 · 已冻结 |
| 13 | `hop_length` | 512 | 帧移 | FF-04 · 已冻结 |
| 14 | `pad_mode` | "constant" | STFT 填充模式 | `ADR-16` · 已冻结（零填充，librosa 默认；`reflect` 已否决） |
| 15 | `n_mels` | 128 | Mel 频带数 | FF-05 · 已冻结 |
| 16 | `mel_htk` | false | Mel 滤波器组刻度（`false` = Slaney） | `ADR-16` · 已冻结（`htk=True` 已否决） |
| 17 | `mel_norm` | "slaney" | Mel 滤波器组面积归一化 | `ADR-16` · 已冻结（Slaney，不是 `htk`） |
| 18 | `fmin` | 20 | 最低频率 Hz | FF-05 · 已冻结 |
| 19 | `fmax` | 8000 | 最高频率 Hz | FF-05 · 已冻结 |
| 20 | `power` | 2.0 | 功率谱指数 | FF-06 · 已冻结 |
| 21 | `compression` | "power_to_db" | 压缩方式 | FF-07 · 已冻结 |
| 22 | `power_to_db_ref` | "patch_max" | `power_to_db` 的 `ref`（本 patch 最大值） | `ADR-16` → **`ADR-21`（2026-09-12）修订 · 已冻结**（~~`1.0`（绝对刻度，`ADR-16`）~~ —— ADR-16 否决 `ref=np.max` 的理由**对 ADR-16 当时要冻结的链路成立**；但交付的模型**已按 patch 相对刻度训练**，此时"推理与训练不一致"是更大的误差） |
| 23 | `power_to_db_amin` | 1e-10 | `power_to_db` 的 `amin` 下限 | **`ADR-21` 新增 · 已冻结** |
| 24 | `top_db` | 80.0 | 动态范围 dB | FF-07 · 已冻结（`ADR-21` 起，dB 参考与 `top_db` 下限**算在全部 129 帧上**，见下表 `operation_order`） |
| 25 | `normalization` | "per_patch_minmax" | 归一化策略 | FF-08 → **`ADR-21` 修订 · 已冻结**（~~`"fixed_db_clip"`~~） |
| 26 | `normalization_epsilon` | 1e-08 | min-max 分母保护 | **`ADR-21` 新增 · 已冻结** |
| 27 | `normalization_output_min` | 0.0 | min-max 输出下界 | **`ADR-21` 新增 · 已冻结**（取代旧 `db_clip_range[0]`） |
| 28 | `normalization_output_max` | 1.0 | min-max 输出上界 | **`ADR-21` 新增 · 已冻结**（取代旧 `db_clip_range[1]`） |
| ~~25~~ | ~~`db_clip_range`~~ | ~~[-80.0, 0.0]~~ | ~~dB 截断区间~~ | ~~FF-08 · 已冻结~~ → **`ADR-21`（2026-09-12）已删除**：固定 dB 截断取消，改为上面的 `normalization_output_min` / `normalization_output_max` 两个普通键（生成器原有的"1 键拆 2 字段"特例随之拆除，见 §10 #3） |
| 29 | `loudness_normalization` | "training_only" | 响度归一化的作用域 | `ADR-17` · 已冻结（只在训练侧 `T-03`；推理侧不做 LUFS） |
| 30 | `target_lufs` | -23.0 | 训练侧 LUFS 目标 | `ADR-17` · 已冻结（`T-03`；推理侧不读取） |
| 31 | `patch_samples` | 65536 | patch 采样数 | FF-09 · 已冻结（`ADR-21` 未改此值） |
| 32 | `patch_seconds` | 4.096 | patch 时长 s | FF-09 · 已冻结（`ADR-21` 未改此值） |
| 33 | `center` | true | 居中分帧 | FF-10 · 已冻结 |
| 34 | `raw_mel_frames` | 129 | **原始 STFT 帧数**（`n_samples // hop + 1`） | **`ADR-21` 新增 · 已冻结**。⚠️ 这个 129 **不是**张量宽度 —— 把两个概念合成一个数正是 `ADR-21` 所修缺陷的成因 |
| 35 | `n_frames` | 128 | 喂给模型的时间帧数（张量宽度；`raw_mel_frames = 129` 是 STFT 原始帧数） | FF-11 · ~~已冻结 129（`ADR-P1`）~~ → 已由 `ADR-21`（2026-09-12）修订；四处同步口径见 §10 #1 |
| 36 | `frame_selection` | {"strategy": "drop_tail", "start_inclusive": 0, "end_exclusive": 128} | 从 129 帧里取哪 128 帧 | **`ADR-21` 新增 · 已冻结**（丢尾帧，取左闭右开的 `[0, 128)`） |
| 37 | `inference_hop_seconds` | 0.5 | 推理滑窗步长 s | FF-12 · 已冻结 |
| 38 | `operation_order` | ["mono", "resample_16000hz", "pre_emphasis", "crop_or_pad_65536_samples", "mel_power_spectrogram_centered", "power_to_db_patch_max", "drop_tail_to_128_frames", "per_patch_minmax", "append_channel_axis"] | **链路顺序（承重）** | **`ADR-21` 新增 · 已冻结**。⚠️ 顺序不可"重新推导等价写法"：`power_to_db(patch_max)` 与 `top_db` 下限算在**全部 129 帧**上，`per_patch_minmax` 的窗口是**留下的 128 帧** —— 先 minmax 再丢帧会得到**不同的数** |
| 39 | `input_shape` | [1, 128, 128, 1] | 模型输入形状 | FF-14 · ~~已冻结（与 FF-11 同步）~~ → 已由 `ADR-21`（2026-09-12）修订（原 ~~`[1,128,129,1]`~~） |
| 40 | `num_classes` | 6 | 类别数 | FF-19 · 已冻结 |
| 41 | `class_labels` | ["chips", "cabbage", "gummies", "noodles", "carrot", "drink"] | 类别英文名 | FF-19 · 已冻结 |
| 42 | `model_internal_preprocessing` | {"rescaling_scale": 2.0, "rescaling_offset": -1.0, "channel_adapter": "concatenate_input_three_times"} | **模型内部**做的预处理（本仓前端**不重复**做） | **`ADR-21` 新增 · 已冻结**（交付 fp32 计算图的前三个算子为 `MUL(×2) → ADD(−1) → CONCATENATION(输入, 输入, 输入)`，与发布说明 §2 一致） |
| 43 | `_decisions` | **6 项决策记录**（`n_frames` / `mel_numerics` / `preprocess_scope` / `vad_parameters` / `class_table` / `mel_frontend_v1_1`），逐字内容以 `shared/feature_config.json` 为准 | 已拍板决策的登记块 | **`ADR-21` 新增第 6 项 `mel_frontend_v1_1`**（2026-09-12），并在 `n_frames` / `mel_numerics` / `preprocess_scope` 三条上标注**部分被取代**及其取代范围。**不删旧文** —— 故该块里出现的 `129` / `1.0` / ~~`fixed_db_clip`~~ / ~~`first_sample_passthrough`~~ 都是**历史记录，不是当前值**；当前值只看上表的顶层键 |
| 44 | `behavior` | {"meal_end_silence_seconds": 90, "chew_min_peak_distance_ms": 200, "chew_max_peak_width_ms": 150, "chew_isolated_gap_ms": 300, "chew_peak_threshold_k": 0.5, "smoothing_window_ms": 50, "envelope_frame_ms": 10, "envelope_hop_ms": 5, "envelope_length": 819, "noise_floor_init": 0.001, "noise_floor_min": 0.0003, "voiced_margin_db": 6.0, "noise_floor_alpha": 0.95, "chew_count_mae_degrade_ratio": 0.25, "speed_thresholds_seconds": {"fast": 0.5, "normal": 0.8}} | 行为分析 **+ VAD** 的共同参数块（**4 键 → 15 键**；VAD 四键见 ADR-18 / FF-21k） | FF-21a~h + **FF-21k** · 已冻结 |
| 45 | `voting` | {"ema_window": 5, "ema_alpha": 0.4, "confirm_consecutive_patches": 4, "tau_confirm": 0.7, "tau_low": 0.45} | 三级聚合参数 | FF-20 · 已冻结 |
| 46 | `meal_windows` | {"units": "minutes_of_local_day; half-open [start, end); late_night wraps past midnight", "breakfast": [300, 600], "lunch": [660, 840], "dinner": [1020, 1260], "late_night": [1200, 300], "snack_is_complement_of_meals": true} | 餐次窗口：本地日分钟数、左闭右开 `[start, end)`、`late_night` 跨午夜；零食 = 三个正餐窗口的补集 | ADR-09（修订 A-2）· 已冻结 |
| 47 | `health_score_weights` | {"regularity": 30, "structure": 30, "snack": 20, "speed": 20} | 四维满分权重 | FF-22 · 已冻结 |
| 48 | `health_score_formula` | {"regularity": {"sigma_at_zero_score_minutes": 90}, "structure": {"healthy_ratio_at_full_score": 0.4, "healthy_labels": ["cabbage", "carrot", "noodles"]}, "snack": {"count_at_zero_score": 10}, "speed": {"seconds_at_full_score": 0.8, "seconds_at_zero_score": 0.4}, "evaluation_order": "literal_expression", "rounding": "per_dimension_round_then_sum", "grade_thresholds": {"good_min": 80, "fair_min": 60}} | 四维评分公式参数与求值约定（`ADR-15` 字面表达式求值、逐维取整后求和、`ADR-P2` 评级分档） | FF-22 / ADR-05 / ADR-15 / ADR-P2 · 已冻结 |

> **`ADR-21` 后的键数**：顶层 **41 → 49**（新增 `raw_mel_frames` / `power_to_db_amin` / `normalization_epsilon` / `normalization_output_min` / `normalization_output_max` / `frame_selection` / `operation_order` / `model_internal_preprocessing` 共 **8** 个 + `_comment_4` **1** 个 = +9；删除 `db_clip_range` **1** 个 —— 41 + 9 − 1 = **49**）。上表 1–48 行逐字展开 48 个键（含 `_decisions` 的 43 行），加上与 `_comment` / `_comment_2` / `_comment_3` 同列的 `_comment_4`（`ADR-21` 的"数值已在原位修订、旧值见 `_decisions`"提示，属元数据）= **49**。~~旧口径：41 键~~。
>
> **嵌套子键（45 个 leaf）**：`behavior` 12 个（11 键，其中 `speed_thresholds_seconds` 展开为 `fast` / `normal` 两个 leaf）、`voting` 5 个、`health_score_weights` 4 个、`meal_windows` 6 个、`health_score_formula` 10 个 = **37**，加 `ADR-16`/`ADR-17` 新增的 **7 个顶层 leaf**（`preemphasis_boundary` / `pad_mode` / `mel_htk` / `mel_norm` / `power_to_db_ref` / `loudness_normalization` / `target_lufs`）= **44**。⚠️ `ADR-21` 新增的 8 个顶层键里，`frame_selection` 与 `model_internal_preprocessing` 是**对象**：前者 3 个 leaf（`strategy` / `start_inclusive` / `end_exclusive`）、后者 3 个 leaf（`rescaling_scale` / `rescaling_offset` / `channel_adapter`），故 leaf 增量需按 §4 行的真实结构展开，**不要把它当成 8 个平 leaf**；`operation_order` 是数组、`raw_mel_frames` / `power_to_db_amin` / `normalization_epsilon` / `normalization_output_min` / `normalization_output_max` 各 1 个 leaf。`_decisions` 是**决策记录**（`ADR-P1` 的 `n_frames`、`ADR-16` 的 `mel_numerics`、`ADR-17` 的 `preprocess_scope`、`ADR-18` 的 `vad_parameters`、`ADR-19` 的 `class_table`、`ADR-21` 的 `mel_frontend_v1_1` 及各自的 `rejected_alternative`），**不计入数值 leaf**。
>
> **口径订正（按真实 JSON 复算）**：本注原记「38 个 leaf / `health_score_formula` 11 个」，与该块真实结构不符 —— 它只有 **10 个 leaf**（`regularity` 1 + `structure` 2 + `snack` 1 + `speed` 2 + `evaluation_order` 1 + `rounding` 1 + `grade_thresholds` 2），故原 38 应为 **37**。
>
> **结构校验**：`docs/common/docs_api/schemas/feature_config.schema.json` 只约束结构与枚举、不重复冻结数值，SSOT 仍是唯一**可写**真源（契约与同步规则见 `API-06` §2）。⚠️ **本行原称「schema 与真实 JSON 的 `required` / `properties` 双向差集已核为 0（41 = 41 = 41）」，该结论属 `ADR-21` 之前的旧口径，本次未复核**：`ADR-21` 增删的 9 个键是否已同步进该 schema 须由 schema 维护方重新核验（登记为 §10 #5）。本 SPEC 不代该 schema 声明其状态。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 全部数值的权威定义 | `SPEC-00` §3（FF-01~FF-22）+ 本文档 §4 的键值表（FF-11 已修订为 128，见 §3.5 / `ADR-21`）；**49 键**口径见 §4 注 |
| 命名规范（JSON `snake_case`、Dart/Kotlin `lowerCamelCase`、常量 `SCREAMING_SNAKE_CASE`） | `API-00` §3.1 |
| 变更流程与错误码 `ACD-CFG-001` | `API-00` §3.9、§3.5；`API-01` §2.1 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| **15 字段**任一不符（`ADR-21`；原 ~~12 字段~~） | 握手比对 | 抛 `ACD-CFG-001`，**禁止进入检测页**，不重试 | 首页提示「配置不一致，请更新应用」 |
| 生成产物与 SSOT 不一致（含 assets 缺失/损坏） | 生成器校验 + §7 判据 + 启动加载断言 | 判不通过并重新生成；assets 问题在**构建期**拦截 | 无 |
| Kotlin 常量手写漂移（R-20） | `getCapabilities()` 与 assets 比对 | 由握手在**启动时**捕获（唯一运行时防线） | 同第 1 行 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | Dart 常量由生成器产出、与 SSOT 逐字段相等，且业务代码不手写字符串键名 | `dart run tool/gen_feature_config.dart` + `flutter test test/cfg/generated_constants_test.dart` + `rg -n "feature_config\[|'n_frames'|\"n_frames\"" app/lib` | 退出码 0；差异字段数 == 0；搜索命中行数 == 0 |
| 2 | 握手 **15 字段**全等，失败路径必须拦截 | `flutter test test/cfg/handshake_test.dart`（含人为改 1 个字段的构造用例） | 退出码 0；比对字段数 == **15** 且全等；构造用例抛 `ACD-CFG-001`、检测页入口不可达 |
| 3 | **旧值零残留**（机械验收） | `rg -n --glob '!**/build/**' --glob '!**/.dart_tool/**' --glob '!_toolchain/**' --glob '!AcouDiet_项目实现计划方案_v3.md' --glob '!docs/**/SPEC-C-03_*.md' -e '(^|[^0-9.])3s' -e '(^|[^0-9])3 秒' -e 'hop.*160' -e '帧移 10' docs shared app ai` | **命中行数 == 0**（`_toolchain/` 第三方文件与形如 `4 分 23 秒` 的合法值必须先排除；本 SPEC 自身含变更单，故排除 `docs/**/SPEC-C-03_*.md`） |
| 4 | 制品闭环三 hash | 校验 `model_card` 的 `nFrames` / `melVersion` / `tfliteSha256`（`API-05` §7.1） | 三项全等 |
| 5 | 变更传播单已逐项打勾 | 下表 14 行的「✅」列 | 14/14 打勾，负责人签名齐全 |

> **判据 #3 的授权例外与已知假阳性**：例外为 `AcouDiet_项目实现计划方案_v3.md`（其 §4.1.1 历史对比表）与本文档 §7 附表；`_toolchain/`（第三方，必须排除）、`SPEC-00` §3.10 等**禁令条款本身**，以及形如 `4 分 23 秒`、`0.3s` 的合法值都会误伤，故上式加了 glob 排除与左边界守卫 `(^|[^0-9.])`。**该细化必须先写入 `API-00` §3.9 再执行**（见 §10 #4）。

**§7 附表：参数变更传播单（主方案 §4.1.1 的 P-1~P-9 + A-1/A-2/ADR-05/ADR-07/ADR-09 落地版 · 历史对比表）**

| # | 位置 | 旧值（错误） | 新值（冻结） | 负责人 | ✅ |
|---|---|---|---|---|---|
| P-1 | 计划书 §5.1.1 步骤 2 | hop 10ms / 帧移 160 | `hop_length = 512`（FF-04） | A | ☐ |
| P-2 | 计划书 §5.1.1 步骤 4 | 「128×128 Mel 频谱图」 | 128 帧 × 4.096 s（FF-09/FF-11；`n_frames = 128` **已修订**，旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，见 `SPEC-00` §3.5 / `ADR-21`） | A | ☐ |
| P-3 | 计划书 §6.3.2 | 帧长 25ms / 帧移 10ms | `win_length = n_fft = 1024` / `hop_length = 512`（FF-03/FF-04） | A | ☐ |
| P-4 | 计划书 §6.3.3 | 「连续 128 帧拼接」 | 128 帧 = 4.096 s（FF-09） | A | ☐ |
| P-5 | `执行规划草稿.txt` D1 | `duration=3s`（hop 原本就对） | `patch_seconds = 4.096`（FF-09） | A | ☐ |
| P-6 | 主方案 §5.4 行为分析 | 4.096 s patch 时域 | 与 Mel **共用同一环形缓冲** | B | ☐ |
| P-7 | 主方案 §8.3 D5 描述 | 「录 3 秒声音」 | 「录 4.096 s（或连续流）」（FF-09） | B | ☐ |
| P-8 | 主方案 §14 P0 B 技能预演 | 「Kotlin 录 3 秒 PCM」 | 「Kotlin 录 4.096 s PCM」（FF-09） | B | ☐ |
| P-9 | `feature_config.json` | —（原先分散在多份材料） | 单一真源，含全部上述参数（本文档 §4 的 **49 键**；`ADR-21` 由 41 键扩至 49 键） | A+B | ☐ |
| A-1 | `API-03` §4/§5 | `DietRepo` 6 方法、`StatsRepo` 4 方法，无参数化窗口 | 新增 `metricsByRecordId` / `summary` / `chewStats` / `mealTimeSamples` / `activeDays` + `ChewStats` | B | ☐ |
| A-2 | `API-03` §5 | 餐次窗口 早`[05,11)`/午`[11,16)`/晚`[16,23)`，晚间`[23,05)` | 早`[05,10)`/午`[11,14)`/晚`[17,21)`，晚间`[20:00,05:00)`；零食 = 其余时段 | B | ☐ |
| ADR-05 | `SPEC-00` §3.7 FF-22 | 「σ≤30min 满分」（与公式矛盾） | 以公式 `30 × max(0, 1 − σ/90min)` 为准；σ=30 → **20** 分 | C | ☐ |
| ADR-07 | `docs/common/docs_api/schemas/feature_config.schema.json`、`metrics.schema.json` | `"const": 129` | `"enum": [128, 129]`；拍板后再改回 `const <选定值>` | A | ☐ |
| ADR-09 | `SPEC-D-03` §4.1 | 与 A-2 相同的旧窗口 | 与 A-2 相同的新窗口 | B | ☐ |

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 一致性 | 两侧常量**同源**是硬约束；违反后果是精度异常且**不报错**（主方案 §4.1.2），比崩溃更危险 |
| 失败语义 | 配置不符必须 fail fast，**禁止**降级为"用默认值继续跑"（`API-05` §8） |
| 性能与依赖 | 握手仅冷启动一次，**15 字段**比对为常量级；本功能不引入运行时开销，不新增第三方依赖 |

## 9. 裁剪与未做

> 🔴 **本功能不可裁剪。** SSOT 与变更传播是**硬闸门**（`00_功能清单` §1 的 4 项硬闸门之一）；它一旦缺失，"改了 Python 忘改 Kotlin"类错误（风险 R-20）将无任何防线。**任何裁剪本功能的提议一律否决。**

| 项 | 决定 |
|---|---|
| 运行时从网络更新配置 | ❌ 永久禁止（`R-OUT-3`） |
| 为 SSOT 再写一份 JSON Schema 副本 | ❌ 不做（避免第二份真相） |
| 配置的多版本/灰度/回滚机制 | ❌ 不交付（无网络，无灰度场景） |
| 自动检测"文档里的旧值"（除 §7 #3 的机械搜索外） | ⚠️ 仅做 §7 #3；不做语义级文档校验 |

## 10. 开放问题

| # | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| 1 | **✅ 已关闭（依据 `ADR-P1`）** —— 历史原记录：「**`n_frames` 未拍板**：当前选 B（4.096 s / 65536 样本 → 129 帧）；备选 A（4.064 s / 65024 样本 → 128 帧）。**必须在 D2 训练前拍板**」。**结论**：已选定**选项 B** —— ~~`n_frames = 129`、`input_shape = [1,128,129,1]`~~ → 后经 **`ADR-21`（2026-09-12）修订为 `n_frames = 128` / `input_shape = [1,128,128,1]` + `raw_mel_frames = 129`**，`patch_seconds = 4.096`、`patch_samples = 65536` 不变；选项 A（128 / 4.064 s / 65024 样本）**已否决**。四处同步（`feature_config` / `model_card.nFrames` / Kotlin 常量 / Dart 常量）已完成。 | 改用另一选项 = **已训练权重全部作废**；需同步四处：`feature_config`（`n_frames`+`input_shape`）、`model_card.json`（`nFrames`/`inputShape`）、Kotlin 常量、Dart 常量 | —（已随 `ADR-P1` 关闭，2026-09-10） |
| 2 | 握手含 `melVersion`，但 SSOT 的 **49 键**中**无 `mel_version` 键**；Dart 侧期望值来源未定（候选：`model_card.json` 注入 / 生成器常量 / 给 SSOT 加第 50 键）。⚠️ 该字段本身**未受 `ADR-21` 影响**，只是键数口径随之由 41 变 49 | 影响 **15 字段**握手能否实现；加键会变动「49 键」口径 | A+B |
| 3 | **✅ 已关闭（依据 `ADR-21`，2026-09-12）** —— 历史原记录：「`db_clip_range` → `dbClipMin`/`dbClipMax` 是 **1 键对 2 字段**的特例映射」。**结论**：`db_clip_range` 键**已删除**、`dbClipMin`/`dbClipMax` **已出列**，该特例映射随之**不存在**；取而代之的是 `normalization_output_min` / `normalization_output_max` 两个**普通键**（1 键对 1 字段，无特例）。生成器里的对应特例代码已拆除 | ~~影响生成器规则与 `API-00` §3.1 的说明~~ → 特例已消除，`API-00` §3.1 不再需要为该映射留说明 | —（已随 `ADR-21` 关闭） |
| 4 | 机械验收需同时排除 `_toolchain/` 与禁令条款自身，`3s` 模式还需左边界守卫（否则误伤 `0.3s`、`4 分 23 秒`）；且变更传播单 P-2 的新值写「128 帧」与当时 FF-11 的 ~~`n_frames = 129`~~ → 128（`ADR-P1`；该值已由 `ADR-21`（2026-09-12）修订）**字面冲突** | 前者决定判据 #3 能否真正做到 0 命中；后者已随 `ADR-P1` 关闭 —— P-2 措辞已回改（本文件 §7 附表 P-2 行），不再由本项目自己制造旧值残留 | A+B |
| 5 | **`ADR-21` 增删的 9 个键（+8 顶层 + `_comment_4`，−`db_clip_range`）是否已同步进 `docs/common/docs_api/schemas/feature_config.schema.json` 的 `required` / `properties`** —— 本 SPEC 只发现自己 §4 旧注的「41 = 41 = 41」口径已过期，**未复核 schema 本身**（`ADR-21` 的"已写入"清单只登记了 `shared/feature_config.json` 侧） | 决定 `C-03` 的"单一真源"是否真的闭合：若 schema 仍是旧的 41 键 `required`，则它既会**拒绝**合法的新键、又**允许**已删除的 `db_clip_range`，与 SSOT 直接矛盾；`verify_docs.py` 当前**不**做这项交叉校验（本文件 §7 判据也不覆盖） | schema 维护方 + A |

**文档结束**

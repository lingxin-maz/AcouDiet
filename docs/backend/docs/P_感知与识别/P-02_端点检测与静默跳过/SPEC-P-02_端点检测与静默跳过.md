# SPEC-P-02 端点检测与静默跳过

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4/§3.7；`API-01` §2.3（`includeEnvelope`）、§2.8（`getEnvelopeCapability`）、§3.2（`patch.voiced` / `patch.rmsEnvelope` / `envelopeHopMs`）、§7（**包络下沉原生的架构裁定**）、§2.5（`SessionSummary`）；`API-00` §3.8；`SPEC-00` §3.6（FF-21a、**FF-21h / FF-21i**）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-P-01`（采样与缓冲）、`SPEC-P-06`（静默 patch 必须进入 EMA，故两侧判据须一致） |

## 1. 目标与范围

### 1.1 一句话目标
在**同一次分帧遍历**中用能量阈值 VAD 判定每个 patch 的 `voiced`，**并同时产出该 patch 的 819 点 RMS 包络 `rmsEnvelope`**（FF-21h），维护自适应噪声底，标记静默 patch —— **静默 patch 不触发推理但仍要投递并进入 EMA** —— 并在连续静默达 FF-21a 时自动结束会话。

### 1.2 范围内（In Scope）
- 逐 patch 的能量统计（RMS）与 `voiced` 二值判定。
- 自适应噪声底的初始化、更新与下限保护。
- 静默 patch 的标记方式（`patch.voiced = false`）与**投递义务**（不得丢弃）。
- 静默累计计时与 FF-21a 触发 `sessionEnded(reason = "silence90s")`。
- 静默期间的 `level` 事件语义（`voiced=false`，波形动画仍可绘制）。
- VAD 阈值常量的来源约束：**必须读自 `feature_config` 的 `behavior` 块（4 个 VAD 键：`noise_floor_init` / `noise_floor_min` / `voiced_margin_db` / `noise_floor_alpha`，`ADR-18`/FF-21k），不得硬编码**（`SPEC-C-03`）。**SSOT 里没有 `vad` 对象** —— VAD 参数与包络帧长/hop 同在 `behavior` 块内，因为同一趟分帧同时产出 VAD 判定与 819 点 RMS 包络（FF-21h）。
- `patch.voiced` 与 `level.voiced` 两个字段的**口径一致性**（同一判定函数产出，不得两套阈值）。
- 会话级 `patchesVoiced` 计数（写入 `SessionSummary`，`API-01` §2.5）与 `getDiagnostics` 暴露。
- 判定输入为**预处理前的原始 RMS**（避免 P-03 的归一化抬高静默段）。
- **在一次分帧遍历里同时产出两样东西**（FF-21h）：① 每帧能量 → 汇总为 patch 级 `rms` 与 `voiced` 判定；② **819 点短时 RMS 包络**（`rmsEnvelope`，帧长/hop 见 FF-21h）。
- **与 `SPEC-P-07` 共用同一份分帧实现**（FF-21h/FF-21i，`API-01` §7）：hop 与帧长**只允许定义一次**，`P-02`（产出方）与 `P-07`（消费方）**不得各写一遍**；包络只随事件下发，不在 Dart 侧重算。
- 包络的下发与开关：`startSession({includeEnvelope: true})`（默认 `true`）时 `patch` 事件携带 `rmsEnvelope` / `envelopeHopMs`（`API-01` §2.3/§3.2）；关闭时不携带，由 `P-07` 抛 `ACD-BEH-001`。
- `getEnvelopeCapability()` 的 `supported` / `envelopeHopMs` / `envelopeLength` 由本功能的分帧参数决定（`API-01` §2.8）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| 降噪、谱减法、自适应滤波 | P-03（谱减法**默认关闭**，主方案 §3.7） |
| 预加重、高通、响度归一化 | P-03 |
| Mel 计算 | P-04 |
| 推理触发决策的**业务层**逻辑（EMA 更新、确认判据） | P-06；本功能只产出 `voiced` 标记 |
| 丢弃或压缩静默 patch | **禁止**：静默 patch 必须投递（`API-01` §3.2） |
| 关键词识别 / 语音识别 / 说话人识别 | 本项目只识别**进食声音**，不做语音内容理解 |
| 静音段的样本级裁剪（剪掉静音再送 Mel） | 禁止：会破坏 4.096 s（FF-09）时间连续性与 patch 时序 |
| 多阈值 hangover / 复杂状态机 | 不做；本功能保持二值判定 + 静默计时 |
| 包络的**平滑、峰值检测与咀嚼计数** | `SPEC-P-07`（FF-21i：分帧与 RMS 在 Kotlin，平滑与峰值检测在 Dart）；本功能只产出包络，不做行为判定 |
| **第二套分帧 / hop 实现** | **禁止**：与 `SPEC-P-07` 共用同一份分帧实现（FF-21h，`API-01` §7） |

## 2. 功能行为

### 2.1 触发与前置条件
1. 会话处于 `RUNNING`（`SPEC-P-01` §2.3）。
2. 缓冲区已填满一个完整 patch（65536 样本，FF-09），即会话已运行 ≥ 4.096 s。
3. `feature_config` 的 **`behavior` 块 4 个 VAD 键**已随握手校验通过（`API-00` §3.6）；缺失或字段不符 → `ACD-CFG-001`。

### 2.2 主流程（编号步骤）
1. 每到一个 patch 边界（FF-12 的 2 Hz 节拍），对当前 65536 样本快照（FF-09）做**一次分帧遍历**：按 FF-21h 的帧长/hop 求逐帧短时 RMS，**同时**得到 (a) patch 级能量统计（RMS 与峰值，供 VAD 判定）与 (b) **819 点 `rmsEnvelope`**（供 `P-07`，FF-21h）。
2. 用当前自适应噪声底 `noise_floor` 与配置的判定边距 `voiced_margin_db` 计算判定门限：**`rms > noise_floor × 10^(voiced_margin_db / 20)`** → `voiced = true`（4 个键均来自 `feature_config.behavior`，`ADR-18`/FF-21k）。**判定是相对自适应噪声底的比较，不是固定绝对阈值** —— 手机麦克风增益跨机型差异大，绝对 RMS 阈值无法迁移。
3. `rms > 门限` → `voiced = true`，**重置静默计时**；否则 `voiced = false`，**静默计时累加一个 patch 时长**。
4. 更新噪声底：仅用 `voiced = false` 的 patch 以慢速一阶 EMA（`noise_floor_alpha`）更新；`voiced = true` 的 patch 不参与，避免把进食声学进噪声底。
5. 噪声底设下限保护（`noise_floor_min`）与更新速率上限，避免长时间静默后门限塌陷到 0 而把底噪判成进食声（`noise_floor_init` 为会话初值）。
6. 组装 `patch` 事件（含 `voiced`，以及 `includeEnvelope=true` 时的 `rmsEnvelope` / `envelopeHopMs`）并**无条件投递**（`voiced` 只作标记，不作丢包依据）。
7. 静默计时 ≥ FF-21a → 由本功能请求结束会话，`endReason = "silence90s"`，投递 `sessionEnded`。
8. Dart 侧对 `voiced = true` 的 patch 触发推理；对 `voiced = false` 的 patch **跳过推理但仍调用聚合器**（见 §3 与 `SPEC-P-06`）。

### 2.3 状态与状态迁移
VAD 内部为二值状态 + 静默计时器（无独立公开状态机；会话状态机权威定义在 `SPEC-P-01` §2.3）：

| 内部状态 | 迁移条件 | 效果 |
|---|---|---|
| `SILENT` → `VOICED` | 本 patch `rms > 门限` | 静默计时清零；`firstVoicedAtMs` 若为空则写入 |
| `VOICED` → `SILENT` | 本 patch `rms ≤ 门限` | 静默计时从 0 开始累加；`lastVoicedAtMs` 已更新 |
| `SILENT` → `SESSION_END` | 静默计时 ≥ FF-21a | `sessionEnded(reason="silence90s")` |
| `PAUSED`（会话级） | `pauseSession` | 静默计时**不计入**且不累加（`API-01` §2.4） |

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 会话开始即静默 | 静默计时从第一个 patch 起累加；`firstVoicedAtMs = null` |
| 静默门槛附近抖动（±1 dB 来回穿越） | 允许抖动，但**不因抖动重置噪声底**；抖动只影响 `patchesVoiced` 统计 |
| 突然的大声环境噪声（关门、说话） | 判为 `voiced = true`，交 P-05/P-06 处理；VAD 不做「是不是食物声」判断 |
| 持续底噪抬高（风扇/空调） | 噪声底缓慢上移，门限随之抬升 |
| 暂停期间 | 不发 patch，也不累加静默计时 |
| `voiced = false` 的 patch 堆积 | 不得丢弃；仍受 `API-01` §3.3 背压规则约束（dart 侧未 ack 才丢） |
| 单侧耳/麦克风被遮挡导致 RMS ≈ 0 | 静默计时照常累加 → 90 s 后自动结束，`endReason = silence90s` |
| 会话刚开始且首个 patch 即 `voiced=true` | 静默计时从 0 起；`firstVoicedAtMs` = 该 patch 的 `tStartMs` |
| 连续静默跨越 `pauseSession` 边界 | 暂停期间不累加；恢复后从暂停前的累计值继续（不重置、不清零） |
| 同一会话内噪声水平突然大幅变化（从安静房间到嘈杂餐厅） | 噪声底按慢速 EMA 逐步跟上；**不因单次大噪声跳变**，避免门限震荡 |

## 3. 接口契约
> 权威定义见 `API-01`。本功能为事件字段的**生产者**，也是 Dart 侧「是否调用推理」的判据来源。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Kotlin 内部 | `Vad.evaluate(rms, patchDurationMs)` | 线性 RMS `[0,1]`、patch 时长 | `voiced: Boolean` | — |
| Kotlin → Dart | 事件 `patch` | 65536 样本 / Mel | `voiced`（**本功能产出**）、`rmsEnvelope` + `envelopeHopMs`（**本功能产出**，FF-21h）、`mel`（P-04 产出） | — |
| Kotlin → Dart | 事件 `level` | 100 ms 电平 | `{rms, peak, voiced}` | — |
| Kotlin → Dart | 事件 `sessionEnded` | 静默触发 | `{reason: "silence90s", summary}` | — |
| Kotlin → Dart | `getEnvelopeCapability` | `{}` | `supported` / `envelopeHopMs` / `envelopeLength`（由本功能的分帧参数决定，`API-01` §2.8） | 无 |
| Dart → Kotlin | `getDiagnostics` | `{}` | `patchesVoiced`、`droppedPatches` | 无 |
| Dart → Kotlin | `startSession` | `silenceEndSeconds`、`includeEnvelope` | 生效值记入 `appliedConfig`，另出参 `envelopeHopMs` / `envelopeLength` | `ACD-CFG-001` |

**Dart 侧调用约定（硬约束，防实现方写反）**：
```
onPatch(patch):
  if (patch.voiced) last = await engine.run(patch.mel, nFrames: patch.nFrames)
  else              last = last                       // 静默：不触发推理，沿用最近结果
  aggregator.add(last, seq: patch.seq, voiced: patch.voiced)   // 两种情况都必须调用
```
> `API-02` §4 已裁定：`voiced = false` 的 patch **必须仍进入 EMA**（否则平滑断档），但因该接口的 `r` 是非空 `InferenceResult`，调用方只能**沿用最近一次结果**调用；且静默 patch **不参与连续计数**——既不递增也不清零。
> FF-20c 要求 EMA 与连续计数**跨 patch 保持状态**，静默 patch 同样必须推进聚合器状态，**不得**跳过调用（详见 `SPEC-P-06` §2.2 与 §10 开放问题 1）。

## 4. 数据契约
> 字段权威定义见 `API-01` §3.2。
> ⚠️ **本契约没有 JSON Schema**：schema 集**固定为 6 份**且**不覆盖原生桥接载荷**。`patch` 事件的形状（`mel` 的 `128 × n_frames` 行主序布局、`rmsEnvelope` 的 819 点、`seq` 单调）由 `API-01` §5 一致性测试的第 3/9 条机械保证 —— **这比 schema 更强**，因为它同时约束了内存布局与数值口径。

| 字段 | 类型 | 值域 | 备注 |
|---|---|---|---|
| `voiced` | `bool` | — | `false` 的 patch **仍要投递**，不得省略事件 |
| `rms` | `double` | `[0,1]` | 线性幅度；业务判定只用 `voiced`，`rms` 仅供诊断与波形动画 |
| `rmsEnvelope` | `Float32List` | 长度 == FF-21h 的公式值 | **本功能产出**（与 VAD 判定**同一次分帧**）：逐帧短时 RMS；**仅** `includeEnvelope = true` 时存在；供 `P-07` 做平滑与峰检测（`API-01` §3.2）。**行为分析不得读取 `rms` 标量** |
| `envelopeHopMs` | `int` | 正数 | 包络帧移，随事件下发以便 `P-07` 不硬编码（FF-21h）；须与 `getEnvelopeCapability()` 出参一致 |
| `SessionSummary.patchesVoiced` | `int` | `[0, patchesEmitted]` | 由本功能计数 |
| `SessionSummary.firstVoicedAtMs` / `lastVoicedAtMs` | `int?` | epoch 毫秒 | 无 `voiced` patch 时为 `null` |
| 噪声底（内部态） | `double` | `> 0` | **不跨会话持久化**，不写数据库、不落盘 |

## 5. 参数与常量
> 一律引用 `SPEC-00 §3`；VAD 阈值已由 `ADR-18` 冻结在 `feature_config` 的 **`behavior` 块**（FF-21k），见 §10 第 1 条。

| 项 | 引用 |
|---|---|
| 静默自动结束秒数 | FF-21a（**不是 30 s**） |
| patch 采样数 / 时长 | FF-09 |
| patch 事件频率 | FF-12 |
| `n_frames`（构造事件时使用） | FF-11（**`n_frames = 128`**；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 判定门限、噪声底初始值、更新速率、下限 | **FF-21k · 已冻结**（`ADR-18`）：`behavior` 块的 4 个 VAD 键 —— `noise_floor_init = 0.001`、`noise_floor_min = 0.0003`、`voiced_margin_db = 6.0`、`noise_floor_alpha = 0.95`（前两个为线性 RMS、第三个为分贝、第四个为无量纲一阶更新系数）；判定式 **`rms > noise_floor × 10^(voiced_margin_db / 20)`**。代码只读不写；**SSOT 里没有 `vad` 对象**。D3 自采跨域集仅做实测复核，若需改值须经 `SPEC-C-03` 变更传播登记 |
| **包络帧长 / 帧移 / 长度公式** | **FF-21h**（帧长与 hop **只允许定义在这一次**；本 SPEC 不复制字面值） |
| **包络计算的位置** | **FF-21i**：分帧与 RMS 计算在 Kotlin（L1），平滑与峰值检测在 Dart（`SPEC-P-07`）；架构裁定见 `API-01` §7 |
| 包络长度 `envelopeLength` | 由 FF-21h 的公式给出；运行时真值以 `API-01` §2.3 出参与 `getEnvelopeCapability()` 为准 |
| 平台与包名 | FF-23 |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `feature_config` 缺 `behavior` 块的 4 个 VAD 键 | 启动加载断言 | 抛 `ACD-CFG-001`，禁止进入检测页 | 「配置不一致，请重装应用」 |
| 噪声底被更新到 0（长时间纯静音） | 单测 + 断言下限保护 | 钳制到配置下限 | 无 |
| 门限高于实录音量导致全程 `voiced=false` | 会话 90 s 内 `patchesVoiced == 0` 且用户确有进食 | **不自动改阈值**；`getDiagnostics` 暴露 `patchesVoiced`，由 M-04 面板暴露问题 | 会话 90 s 后自动结束；自检面板显示 `patchesVoiced = 0` |
| 噪声底过高导致全程 `voiced=true` | `patchesVoiced / patchesEmitted ≈ 1` 且置信度长期 < 0.45 | 交 P-06 Level 3 判定为「未识别」，不写日志 | 「未识别到明确食物」 |
| 静默计时与 `endReason` 不一致 | 单测断言 | 断言失败即打回 | 无 |
| 会话被 `pauseSession` 打断静默计时 | 单测 | 暂停期间不累加 | 无 |
| `includeEnvelope = false`（仅诊断 / 压测场景） | 出参 `appliedConfig.includeEnvelope == false` | 事件不含 `rmsEnvelope`；`P-07` 将收到 `ACD-BEH-001`（`API-01` §2.3）——**本功能自身的 VAD 行为不受影响** | 「行为指标不可用」（自检面板 `envelope` 项） |
| 分帧参数被复制成第二份实现 | 静态扫描（§7 判据 10 同批） | 视为缺陷：hop / 帧长只允许来自 FF-21h 的单一实现 | 无 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 静默 patch 必须投递 | `flutter test test/native/silent_patch_delivered_test.dart` | 静默 30 s 内事件数 == 静默时长 / patch 时长（允许 ±1）；无事件缺失 |
| 2 | 静默 patch 必须进入聚合 | `flutter test test/domain/vote_aggregator_silent_test.dart` | `voiced=false` 调用后 EMA 照常更新（未断档）、`consecutiveCount` **不变**（`API-02` §4）；`reset()` 未被调用 |
| 3 | 静默 patch 不触发推理 | `flutter test test/domain/inference_skip_test.dart`（mock `InferenceEngine` 计数 `run()` 调用） | `voiced=false` 时 `run()` 调用次数增量 == 0 |
| 4 | 90 s 静默自动结束 | `android/app/src/test/kotlin/com/acoudiet/app/audio/VadSilenceEndTest.kt` 的 `silenceTriggersEnd_afterFF21a` | 静默计到 FF-21a 时发 `sessionEnded` 且 `reason == "silence90s"`；差 1 个 patch 时不触发 |
| 5 | 阈值不硬编码 | `grep -rnE "(0\.[0-9]+|threshold|noiseFloor)" android/app/src/main/kotlin/com/acoudiet/app/audio/Vad.kt` 比对 `feature_config` **`behavior` 块的 4 个 VAD 键名**（`noise_floor_init` / `noise_floor_min` / `voiced_margin_db` / `noise_floor_alpha`） | 脚本 `python ai/scripts/assert_no_hardcoded_vad.py` 退出码 0，命中数 0 |
| 6 | 噪声底单调保护 | `VadNoiseFloorTest.kt` 的 `noiseFloor_neverBelowFloor_andNotUpdatedOnVoiced` | 输入 200 个全静音 patch 后 `noiseFloor ≥ 下限`；`voiced=true` 的 patch 不改变 `noiseFloor` |
| 7 | `patchesVoiced` 一致性 | `flutter test test/native/session_summary_voiced_count_test.dart` | `patchesVoiced ==` 事件流中 `voiced=true` 的计数 |
| 8 | 暂停不计静默 | `VadSilenceEndTest.pause_doesNotAccumulateSilence` | 暂停期间静默计时不变 |
| 9 | `level` 事件带 `voiced` | `patch_stream_shape_test.dart` 的 `level_hasVoicedFlag` | 每个 `level` 事件含 `voiced` 且为 `bool` |
| 10 | **包络形状（FF-21h）** | `flutter test test/native/envelope_shape_test.dart` | `includeEnvelope = true` 时**连续 20 个 `patch`** 的 `rmsEnvelope.length == 819` 且 `envelopeHopMs == 5`（与 `API-01` §5 清单第 9 条同判据） |

## 8. 非功能约束
- **实时性**：VAD 判定为 patch 内的整段 RMS 计算，位于原生后台线程；其耗时必须包含在 `SPEC-P-01` §8 的 hop 预算内，实测值在 D6 产出，本 SPEC 不预设数字。
- **状态隔离**：噪声底为会话级内存态，**不落盘、不入库、不跨会话复用**（避免用户更换环境后门限失真）。
- **隐私**：VAD 只输出布尔与标量，不产生任何可在设备外重构音频的信息（配合 FF-24 §1）。
- **能耗**：每 patch 一次 `O(N)` 遍历，无额外线程、无 FFT；**包络与 VAD 判定共用这同一次分帧遍历**，不新增第二次遍历、不新增线程（FF-21h/FF-21i）。
- **可单测性**：`Vad` 不得依赖 Android `Context`/`AudioRecord`，必须可以纯数值输入单测（这也是 §7 判据 6 能成立的前提）。
- **可观测性**：`patchesVoiced` 与 `noiseFloor`（脱敏后的标量）必须进 `getDiagnostics`，供 `M-04` 现场自检判断「是麦克风问题还是模型问题」。
- **无障碍**：无 UI，不适用。

## 9. 裁剪与未做
- **本功能属于「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）**（`00_功能清单` §6）。**不得裁剪。**
- **不做降噪**：谱减法与任何降噪均属 `SPEC-P-03`，且**默认关闭**（主方案 §3.7）。本功能不得顺手加滤波器。
- `X-05` 检测页「识别历史」列表：**不做**。
- 静音样本裁剪、静默 patch 丢弃、无界静默队列：**不做**（违反 `API-01` §3.2/§3.3 与 FF-09 时间连续性）。
- 语音识别 / 关键词唤醒 / 说话人识别：**不做**（超出 6 类食物识别范围，FF-19）。
- 多阈值 hangover 状态机与基于机器学习的 VAD：**不做**（10 天窗口内无验证成本预算）。
- 说话人识别与「是否真人进食」的反作弊判定：**不做**（v1.0 不引入任何生物特征处理，FF-24）。
- 按环境自适应切换多套阈值配置文件：**不做**（只维护 `behavior` 块的一套 4 个 VAD 键，避免现场行为不可预测）。
- 原生侧做**峰值检测 / 咀嚼计数**：**不做**（FF-21i；`API-01` §6「明确不做」——阈值需在 D7 现场调参，放 Kotlin 意味着每次调参重编译 APK）。本功能止步于「分帧 + RMS + VAD 判定」。
- **在 Dart 侧或第二个类里重算包络**：**不做**（FF-21h/FF-21i）；分帧实现唯一，见 §1.2 与 `SPEC-P-07` §1.3。

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-18`）** —— 历史原记录：「**VAD 阈值三件套（门限边距、噪声底初值、更新速率）未在 FF 中冻结**：本 SPEC 只规定「必须来自 `feature_config` 并读自配置」。标定时间与方式建议与 FF-20b 同批（D3），**需 A/B 确认**后经 `SPEC-C-03` 登记」。**结论**：4 个参数已冻结为 SSOT **`behavior` 块**的子键（FF-21k，2026-09-10）—— `noise_floor_init = 0.001`、`noise_floor_min = 0.0003`、`voiced_margin_db = 6.0`、`noise_floor_alpha = 0.95`；判定式为 **`rms > noise_floor × 10^(voiced_margin_db / 20)`**。**为何自适应而非固定阈值**：手机麦克风增益跨机型差异很大，固定绝对 RMS 阈值无法在换机后迁移；以自适应噪声底 + 6 dB 边距判定，同一组常量才能在各类手机间成立（`ADR-18` 已否决「固定绝对阈值」方案）。**SSOT 里没有 `vad` 对象**。
2. 🔴 **`VoteAggregator.add` 的非空参数与静默 patch 的数据来源**：`API-02`（现已定稿）§4 规定 `voiced=false` **必须仍进入 EMA**、且**不参与连续计数**（不递增也不清零）；但 `r` 为非空 `InferenceResult`，静默 patch 只能**沿用最近一次结果**。`API-02` §9 第 2 条已把该问题挂为待拍板项。**需 A/B 确认「沿用规则」写入 `API-02`，或把 `r` 改为可空**；`SPEC-P-02`、`SPEC-P-06` 与 `API-02` 三处必须同时一致。
3. **✅ 已关闭（依据 `ADR-P1`；后经 `ADR-21` 修订）**：`n_frames` 原为 ~~`129`~~ → 现为 **`n_frames = 128`**（`129` 现为 `raw_mel_frames`，见 FF-11 / `ADR-21`，2026-09-12）。

**文档结束**

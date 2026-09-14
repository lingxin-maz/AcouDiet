# API-02 推理与聚合引擎接口

| 项 | 值 |
|---|---|
| 上游依据 | `SPEC-00` §3.1（FF-01~FF-12）、§3.2（FF-13~FF-18）、§3.3（FF-19）、§3.4（FF-20）、§3.6（FF-21）、§3.10（FF-25）；`API-00` §1/§3；`API-01` §3.2/§3.3；`shared/feature_config.json` |
| 层级位置 | `API-00` §1 分层图中的 **L4 域层**（`InferenceEngine` / `VoteAggregator` / `BehaviorAnalyzer` / `FoodKnowledgeBase`；内嵌 L0 运行时 `tflite_flutter`） |
| 适用功能编号 | `P-05`（TFLite 端侧推理）、`P-06`（三级结果聚合）、`P-07`（行为分析）、`P-08`（食物知识库查表侧） |
| 权威定义 | **本文件是下列接口的唯一权威定义**：`AcouDietError`、`InferenceResult`、`InferenceEngine`、`VoteStage`、`AggregatedDecision`、`VoteAggregator`、`VotingConfig`、`BehaviorMetrics`、`BehaviorAnalyzer`、`BehaviorConfig`、`FoodInfo`、`FoodKnowledgeBase` 的 Dart 签名、参数语义、错误语义与线程语义。`SPEC-P-05`~`SPEC-P-08`、`PLAN-P-05`~`PLAN-P-07`、`U-02` 只能**引用编号**，不得复制签名。 |
| 非权威（只引用） | `DietRecord` 入库形态见 `API-03`；`HealthScore*` 见 `API-04`；patch 事件载荷与背压见 `API-01` §3.2/§3.3；`foods.json` 字段映射见 `API-04` §2 与 `docs/common/docs_api/schemas/foods.schema.json` |
| 实现计划 | `PLAN-P-05`（引擎）、`PLAN-P-06`（聚合）、`PLAN-P-07`（行为）、`PLAN-P-08`（知识库） |

## 1. 数据流与本层硬约束

```
API-01 patch 事件 → InferenceEngine.run() → InferenceResult → VoteAggregator.add() → AggregatedDecision ─┐
                  └→ BehaviorAnalyzer.feedEnvelope() → BehaviorMetrics ───────────────────────────────────┴→ API-03 insertSession()
FoodKnowledgeBase.byClassId() → FoodInfo → L5 渲染 / API-04 建议文案
```
1. L4 **不得** import Flutter widget（`API-00` §1 规则 2），全部类必须可在纯 Dart 单测中构造。
2. **状态跨 patch 保持**（FF-20c）：`VoteAggregator` / `BehaviorAnalyzer` 的 EMA、连续计数、峰值统计不得逐 patch 重置，只允许会话边界 `reset()`。
3. 本层**不落盘、不发网络**：`InferenceResult.probs`、Mel 张量、`feedEnvelope` 的 RMS 包络只存在于进程内存（FF-24 第 1 条 / `API-05` §3.1 R-OUT-1）。

## 2. `AcouDietError`（本层统一异常类型）

```dart
class AcouDietError implements Exception {
  String code; String message; Map<String, Object?>? detail; bool retryable;
}
```
| 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|
| `code` | `String` | 否 | — | 取自 `API-00` §3.5 或本文件 §8 的新增码，格式 `ACD-<AREA>-<NNN>` |
| `message` | `String` | 否 | — | 面向用户的中文短句（≤40 字），不含堆栈、文件路径、英文错误原文 |
| `detail` | `Map<String,Object?>` | 是 | — | 仅可机读诊断值（如 `expectedFrames` / `actualFrames`），键名 `lowerCamelCase` |
| `retryable` | `bool` | 否 | — | 与 `API-05` §8 重试表逐条一致；仅 `true` 时 L5 展示「重试」 |
- 抛出（线程）语义：本层全部方法在**调用方 isolate 内**抛出；不做跨 isolate 对象序列化，跨边界只传 `code`（`PLAN-P-05`）。`API-01` 的 `PlatformException` 由桥接适配器转换为 `AcouDietError`（转换点归 `PLAN-P-01`）。
- 单元测试要点：① `code` 与 `API-00` §3.5 表逐条一致；② `detail` 可 JSON 序列化；③ `retryable` 与 `API-05` §8 逐行一致。

## 3. `InferenceEngine`（P-05）

```dart
class InferenceResult { int classId; String label; double confidence; Float32List probs; int latencyMs; }
abstract class InferenceEngine {
  Future<void> load({required String assetPath});
  Future<InferenceResult> run(Float32List mel, {required int nFrames});
  Future<void> dispose();
  bool get isLoaded;
  String get delegateInUse; // 'xnnpack' | 'nnapi' | 'cpu'
}
```
| `load` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `assetPath` | `String` | 否 | — | — | Flutter asset 路径，取值来自 `API-06` §1/§5；**不得**传绝对文件路径（`API-05` §3.1 R-OUT-3：制品只在 APK 内） |
| `InferenceResult` 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|
| `classId` | `int` | 否 | — | `[0, numClasses)`；`numClasses = 6`（FF-14/FF-19） |
| `label` | `String` | 否 | — | 必须 `== feature_config.class_labels[classId]`（FF-19） |
| `confidence` | `double` | 否 | — | `== probs[classId]`，值域 `[0,1]`；本层**不转百分比、不取整**（`API-00` §3.3） |
| `probs` | `Float32List` | 否 | — | 长度 `== numClasses` 的 Softmax 输出，和 ≈ 1.0 |
| `latencyMs` | `int` | 否 | 毫秒 | 仅 `Interpreter.run()` 墙钟耗时，不含 Mel 拷贝与后处理；D4 实测产出，供 `M-04` 自检与 `API-01` §3.3 背压判据使用 |
| `run` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `mel` | `Float32List` | 否 | — | — | 长度必须 `== 128 × nFrames`（即 `nMels × n_frames`）；**行主序 `mel[m * nFrames + t]`**（`m` = Mel 频带，`t` = 时间帧，`SPEC-00` §3.1）；值域 `[0,1]`，**per-patch min-max 归一化**（FF-08）。**`ADR-21` 反转**：本格原写「固定 dB 截断归一化（FF-08），**禁止逐 patch `ref=np.max`**」，其中"固定 dB 截断"与"禁止 `ref=np.max`"两条**均已失效** —— 交付模型就是按 patch 相对刻度（`power_to_db_ref = "patch_max"`）训练的，继续禁止它等于让推理与训练不一致。**现行规则**：`power_to_db(ref = patch max, top_db=80)` → 丢尾帧 → per-patch min-max；顺序见 `feature_config.operation_order`，与 FF-07/FF-08 一致 |
| `nFrames` | `int` | 否 | — | 帧 | 必须 `== feature_config.n_frames`，即 **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`），且等于模型输入张量第 3 维 |
- `load` 语义：加载**按 `model_card.quantization` 申报档位交付的模型**（FF-16 的 fp32 / int8 **两档都可交付**；`ADR-21` 纠正了"交付 App 的必须是 int8"这一误读，**本次实际投放的是 fp32**）、绑定输入张量 `[1, 128, n_frames, 1]`（FF-14，`n_frames = 128`）；**重复调用幂等**（先释放旧 `Interpreter` 再建新的，失败保留旧实例）。委托：优先 XNNPACK，NNAPI 初始化失败**静默回退 CPU 且不抛出**（FF-18 / `ACD-INF-003`）。~~加载 INT8 模型~~ —— I/O 仍是 float32（`ADR-20`），"INT8"只指数值权重档位。
- `load` 错误码：`ACD-INF-001`（加载失败，`retryable=true`，允许重试 1 次）、`ACD-INF-002`（模型输入形状与 FF-14 不符，`false`）、`ACD-IO-002`（asset 缺失，见 §8）。线程：**推理 isolate 内**（`API-00` §3.7），禁止在 UI isolate 执行。
- `run` 语义与线程：同步阻塞式单 patch 推理，内部不排队——排队与丢旧策略属调用方（`API-01` §3.3「最多 1 个待处理 patch」）；必须在**独立 isolate** 执行，单 patch 目标 < 100 ms（**目标值，非承诺值**，实测出自 D4）。
- `run` 错误码：`ACD-INF-002`（`mel.length` 或 `nFrames` 不符）、`ACD-INF-004`（未 `load` 即 `run`，见 §8）、`ACD-UNK-000`。`ACD-MEL-001`（帧数不符）由 `API-01` 侧抛出，本层不重复抛。
| 成员 | 返回 | 约束 |
|---|---|---|
| `dispose()` | `Future<void>` | 释放 `Interpreter`；**幂等**；调用后 `isLoaded == false`，再 `run` → `ACD-INF-004` |
| `isLoaded` | `bool` | 只读；`load` 成功且未 `dispose` 时为 `true` |
| `delegateInUse` | `String` | 枚举 **`'xnnpack'` / `'nnapi'` / `'cpu'`**；未加载时返回 `'cpu'`；NNAPI 失败回退后必须为 `'cpu'`（FF-18） |
- 单元测试要点：① `128×128` 与 `128×127` 两种输入下 `ACD-INF-002` 的 `detail` 含期望/实际帧数（`ADR-21` 后张量宽度为 128）；② 同一输入连跑 5 次 `classId` 稳定、`probs.length == 6`；③ `label` 与 `class_labels` 全等；④ NNAPI 不可用设备上 `load` 不抛且 `delegateInUse == 'cpu'`。

## 4. `VoteAggregator`（P-06）

```dart
enum VoteStage { observing, unconfirmed, lowConfidence, confirmed, none }
class AggregatedDecision {
  VoteStage stage; int? classId; String? label; double smoothedConfidence;
  int consecutiveCount; bool shouldAskUser; Float32List? smoothedProbs;
}
class VoteAggregator {
  VoteAggregator({required VotingConfig cfg});
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced});
  void reset();
}
class VotingConfig { int emaWindow; double emaAlpha; int confirmConsecutivePatches; double tauConfirm; double tauLow; }
```
| `VotingConfig` 字段 | 类型 | 真源（**不在此复制字面值**） |
|---|---|---|
| `emaWindow` | `int` | FF-20 Level 1 的 `N`（`feature_config.voting.ema_window`） |
| `emaAlpha` | `double` | FF-20 Level 1 的 `α` |
| `confirmConsecutivePatches` | `int` | FF-20 Level 2 的 `M` |
| `tauConfirm` | `double` | FF-20 Level 2 的 `τ_confirm` |
| `tauLow` | `double` | FF-20 Level 3 的 `τ_low` |
> `cfg` 由 `feature_config.voting.*` 经生成器注入（`API-00` §1/§4）；**禁止在业务代码里手写数字**。`τ_confirm` / `τ_low` 属 FF-20b：须在 **D3** 用自采跨域测试集置信度分布直方图标定并写进测试报告，本文件只冻结语义。
| `add` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `r` | `InferenceResult` | 否 | — | — | 必须来自 §3 `run()`；`probs.length == numClasses` |
| `seq` | `int` | 否 | — | — | 取自 `API-01` §3.2 patch 事件 `seq`（会话内自 0 起单调递增）。本次与上次之差 `> 1` → 判定 drop-oldest 丢包：**连续计数清零、EMA 保留** |
| `voiced` | `bool` | 否 | — | — | 取自同一事件。`false` 的 patch **必须仍进入 EMA**（否则平滑断档，`API-01` §3.2），但**不参与连续计数**（既不递增也不清零） |
`VoteStage` 权威判定表（**按序判定，先命中者胜**）：
| `stage` | 判定条件 | `classId` | `shouldAskUser` | 依据 | L5 语义（`U-02`） |
|---|---|---|---|---|---|
| `none` | 有效样本数 `== 0`（会话开始或 `reset()` 后） | `null` | `false` | — | 「正在感知…」 |
| `observing` | EMA 样本数 `< emaWindow`；**或** EMA 已成形但 `smoothedConfidence < tauLow` | 最近 Top-1（可 `null`） | `false` | FF-20 Level 1 / Level 3 第二档 | 灰色实时预测；后者显示「未识别到明确食物」，**不写日志** |
| `unconfirmed` | EMA 已成形且 `smoothedConfidence ≥ tauConfirm`，但连续计数 `< confirmConsecutivePatches` | Top-1 | `false` | FF-20 Level 2 | 灰色实时预测（接近确认） |
| `lowConfidence` | EMA 已成形且 `tauLow ≤ smoothedConfidence < tauConfirm` | Top-1 | **`true`** | FF-20 Level 3 第一档 | 「疑似 X，请确认？」二选一（`X-02` 降级形态） |
| `confirmed` | 连续 `confirmConsecutivePatches` 个 patch Top-1 不变 **且** `smoothedConfidence ≥ tauConfirm` | Top-1 | `false` | FF-20 Level 2 | 确认卡片，随后由 L3 落库 |
| `AggregatedDecision` 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|
| `stage` | `VoteStage` | 否 | — | 上表五值，**不得新增枚举值** |
| `classId` / `label` | `int` / `String` | 是 | — | `null` 当且仅当 `stage == none`；非空时与 FF-19 一致 |
| `smoothedConfidence` | `double` | 否 | — | EMA 后 Top-1 概率，`[0,1]`；`none` 时为 `0.0` |
| `consecutiveCount` | `int` | 否 | 个 patch | 当前 Top-1 连续计数；`≥ confirmConsecutivePatches` 是 `confirmed` 的必要条件 |
| `shouldAskUser` | `bool` | 否 | — | **仅** `lowConfidence` 为 `true`（唯一允许弹二选一的入口） |
| `smoothedProbs` | `Float32List` | 是 | — | 长度 `== 6`；`none` 时为 `null`；仅供 `U-02` 可视化，**不得**入库存档 |
- 错误码：本方法**不抛错**；`probs.length` 不符 → `ACD-INF-002`（fail fast，说明上游 `run()` 已违约）。
- 线程：**必须与 `run()` 在同一 isolate 内调用**（`API-00` §3.7）；本类**非线程安全**，不加锁。状态跨 patch 保持（FF-20c）；首次确认耗时 ≈ 4–5 s（FF-20a），**禁止**对外写成「2 秒内出结果」（FF-25）。
- 单元测试要点：① 连续 4 个同 Top-1 且 EMA 概率 ≥ `tauConfirm` → `confirmed`；② 概率落在 `[tauLow, tauConfirm)` → `lowConfidence` 且 `shouldAskUser == true`；③ 概率 `< tauLow` → `observing` 且 `shouldAskUser == false`；④ `seq` 跳号 → `consecutiveCount` 归零；⑤ `voiced=false` 改变 `smoothedConfidence` 但不改变 `consecutiveCount`；⑥ `reset()` 后首次 `add` 返回 `none`。

## 5. `BehaviorAnalyzer`（P-07）

```dart
class BehaviorMetrics { int? chewCount; double? avgChewIntervalSeconds; int? durationSeconds; String? speedGrade; }
abstract class BehaviorAnalyzer {
  void feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs});
  BehaviorMetrics? finish({required int endMs});
  void reset();
}
class BehaviorConfig { int mealEndSilenceSeconds; int chewMinPeakDistanceMs; int chewMaxPeakWidthMs;
                       int smoothWindowMs; int isolationGapMs;
                       double speedFastSeconds; double speedNormalSeconds; }
```
| `feedEnvelope` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `rmsEnvelope` | `Float32List` | 否 | — | 线性幅度 | **原生侧算好的短时 RMS 包络**（FF-21h），取自 `API-01` §3.2 的 `patch.rmsEnvelope`；长度**必须** `== envelopeLength`（FF-21h；由 `API-01` §2.3 出参与 `getEnvelopeCapability()` 给出一致值）；本层**不得**从 PCM 重算包络、**不得**用 `patch.rms` 标量代替（`API-01` §3.2/§7）；内存内传递，**禁止落盘**（FF-24 第 1 条） |
| `hopMs` | `int` | 否 | — | 毫秒 | 包络帧移，取自同一 `patch` 事件的 `envelopeHopMs`（FF-21h）；**禁止硬编码**；非正数或与 `rmsEnvelope.length` 不自洽 → `ACD-BEH-001` |
| `tStartMs` | `int` | 否 | — | epoch 毫秒（UTC） | 该 patch 区间起始墙钟时刻，取自 `API-01` §3.2；**不得回退**（非单调 → `ACD-BEH-001`） |
| `finish` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `endMs` | `int` | 否 | — | epoch 毫秒（UTC） | 会话结束时刻，`≥` 最后一次 `feedEnvelope` 的 `tStartMs`；`durationSeconds = (endMs − 首个进食 patch 的 tStartMs) / 1000` 取整，**不含** `pauseSession` 期间（`API-01` §2.4） |
| `BehaviorMetrics` 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|
| `chewCount` | `int` | 是 | 次 | 峰值检测 + 伪峰过滤（FF-21d）后的计数；证据不足时为 `null`，由 L5 按 FF-21g 降级文案 |
| `avgChewIntervalSeconds` | `double` | 是 | 秒 | 相邻有效咀嚼峰均值；有效峰 `< 2` 时为 `null` |
| `durationSeconds` | `int` | 是 | 秒 | 进食时长；无有效证据时为 `null` |
| `speedGrade` | `String` | 是 | — | 枚举 **`'偏快'` / `'正常'` / `'偏慢'`**（FF-21e，由 `speedFastSeconds` / `speedNormalSeconds` 划界）；间隔为 `null` 时也为 `null` |
> ✅ **输入来源缺口已关闭（依据 ADR-01）**：本签名原先接收 4.096 s patch 的**时域 PCM**（`feedPatch`），但 `API-01` §3.2 的 `patch` 事件只携带 `mel` / `rms` / `voiced`，本接口当时**没有合法数据源**（原 §9 第 1 条，三条候选见 `API-01` §7）。ADR-01 裁定采用候选 B —— **包络由原生侧计算**（FF-21h）并随 `patch` 事件下发，**输入据此改为 `rmsEnvelope`**；分工为「包络计算在 Kotlin（L1），平滑与峰值检测在本层（Dart/L4）」（FF-21i）。完整架构裁定与代价缓解见 `API-01` §7（其中 `FakeEnvelopeSource` 写入 `PLAN-P-07` §4）。
- 输入可用性：`rmsEnvelope` **仅当** `startSession({includeEnvelope: true})`（默认 `true`）时存在（`API-01` §2.3）；字段缺失时本层抛 `ACD-BEH-001`。启动时应先以 `getEnvelopeCapability()`（`API-01` §2.8）断言通道可用。
- `finish` 返回 `null` 表示无任何有效进食证据；**返回 `null` 不等于可以不落库**——L3 仍必须写一行占位指标（强 1:1，`API-03` §2.3）。`reset()` 清空包络与峰值统计，跨会话必须调用，**幂等**。
- 阈值真源（**不复制字面值**）：`mealEndSilenceSeconds` ← FF-21a；`chewMinPeakDistanceMs` ← FF-21b；`chewMaxPeakWidthMs` ← FF-21d（宽峰上限）；`isolationGapMs` ← FF-21d（孤立峰邻域半径）；`smoothWindowMs` ← 主方案 §5.4 步骤 2（滑动平均窗长）；`speedFastSeconds` / `speedNormalSeconds` ← FF-21e；动态阈值 `μ + 0.5σ` ← FF-21c；`hopMs` ← FF-21h（取 `API-01` §2.3 出参 `envelopeHopMs`）。
  > 📌 **`smoothWindowMs` 与 `isolationGapMs` 是本版补齐的两个字段**（`SPEC-P-07` 交叉评审发现）：原 `BehaviorConfig` 只有 5 个字段，但 `P-07` 的算法步骤明确需要**平滑窗长**（第 2 步）与**孤立峰邻域半径**（FF-21d 的 300 ms），二者缺一则该步骤无法参数化、只能硬编码 —— 而硬编码正是 `SPEC-C-03` 要消灭的东西。**✅ 已补入（依据 `ADR-P3`，2026-09-10）**：`feature_config.json` 已补全为真正的 SSOT —— 顶层 **31 → 41 键**（`ADR-P3` 到 34，`ADR-16`/`ADR-17` 再加 7 个音频键）、`behavior` **4 → 11 键**（含 `smoothing_window_ms`、`chew_isolated_gap_ms`），并新增 `meal_windows`、`health_score_formula`；原 `_pending_decision` 块已替换为 **`_decisions`**。本层字段与配置键一一对应，**不再有硬编码**。
- 错误码：`ACD-BEH-001`（**包络缺失或长度不符**：`rmsEnvelope.length ≠ envelopeLength` / `hopMs` 非法 / `tStartMs` 非单调 / `endMs < tStartMs`；`retryable=false`；定义见 `API-00` §3.5）。
- 线程：与推理同一后台 isolate（包络是 FF-21h 定义的**定长小数组**，跨 isolate 拷贝成本可忽略）；单次 `feedEnvelope` 目标 < 16 ms（**目标值**，实测出自 D7）。
- 单元测试要点：① 用 `FakeEnvelopeSource`（固定包络数组，`PLAN-P-07` §4）合成「每 0.7 s 一个峰」→ `avgChewIntervalSeconds ≈ 0.7` 且 `speedGrade == '正常'`；② 宽峰（> `chewMaxPeakWidthMs`）与孤立峰被过滤；③ 全静音 → `finish()` 返回 `null`；④ `reset()` 后统计归零；⑤ **断言输出不存在「咀嚼节律 σ」字段**（`X-07` 已裁剪）；⑥ `rmsEnvelope.length` 不符 / `hopMs` 非法 / 字段缺失 → `ACD-BEH-001`。

## 6. `FoodKnowledgeBase`（P-08 查表侧）

```dart
class FoodInfo { String label; String zhName; String attribute; String category; String portionDesc;
                 int portionKcal; List<String> nutritionTags; String riskNote; }
class FoodKnowledgeBase {
  Future<void> load({required String assetPath});
  FoodInfo byClassId(int classId);
  FoodInfo byLabel(String label);
  List<FoodInfo> get all;
}
```
| 方法 | 参数 | 返回 | 约束 |
|---|---|---|---|
| `load` | `assetPath`（`String`，非空；生产值 `'assets/foods.json'`） | `Future<void>` | 按 `docs/common/docs_api/schemas/foods.schema.json`（draft-07）校验后建索引；**原子替换**（校验失败保留旧表）；重复调用幂等 |
| `byClassId` | `classId`（`int`，非空，`[0,6)`） | `FoodInfo`（非空） | 映射顺序 = `feature_config.class_labels`（FF-19）；越界 → `ACD-KB-001` |
| `byLabel` | `label`（`String`，非空） | `FoodInfo`（非空） | 未注册 label（含储备类别 `nuts`）→ `ACD-KB-001`；**不得**回退默认条目 |
| `all` | — | `List<FoodInfo>` | 长度 `== 6`；不可变只读视图，调用方修改必须抛错 |
- 字段语义与文案约束的权威表在 `API-04` §2（本文件不重复）；`portionKcal` **禁止单独上 UI**，必须与 `portionDesc` 同屏并带「估算」（FF-25）。
- 错误码：`ACD-IO-002`（asset 缺失 / JSON 解析失败 / Schema 校验不通过）、`ACD-KB-001`（查询键非法）。
- 线程：`load` 在启动阶段于 Dart 主 isolate 完成（文件 < 10 KB）；加载后查表为**纯内存只读**，可跨 isolate 共享只读副本。
- 单元测试要点：① `foods.json` 键集合与 `class_labels` **完全相等**（储备类别不得混入）；② 每条 `label` 与其键名一致；③ `byClassId(0..5)` 与 FF-19 逐行一致；④ `byLabel('nuts')` 抛 `ACD-KB-001`；⑤ 破坏 JSON → `load` 抛 `ACD-IO-002` 且旧表仍可用。

## 7. `n_frames` 修订值（FF-11 = 128，`ADR-21`）对本层的影响

本文件涉及处一律写 **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`）。选项 A（128 / 4.064 s / 65024 样本）**已否决**；任何改动必须**同时**修改三处：`InferenceEngine` 输入张量第 3 维、`run()` 的 `mel.length` 断言、`VoteAggregator` 的输入长度期望；并重跑 `PLAN-T-08` 对齐测试（`API-06` §9）。参数真源一律来自 FF 编号与 `feature_config`（经 `PLAN-C-03` 生成 Dart 常量），本层**不得**硬编码。

## 8. 错误码清单（本层全部可能抛出项）

| 错误码 | 触发 | `retryable` | 来源 |
|---|---|---|---|
| `ACD-INF-001` | 模型加载失败（缺失、格式非法、sha 与 `model_card` 不符） | `true` | `API-00` §3.5 |
| `ACD-INF-002` | 输入张量形状不符（`mel.length` 或 `nFrames` 与 FF-14 不一致） | `false` | `API-00` §3.5 |
| `ACD-INF-003` | 委托（NNAPI）初始化失败 | —（**不抛出**，静默回退 CPU，FF-18） | `API-00` §3.5 |
| `ACD-INF-004` | 未 `load()` 即 `run()`；或 `dispose()` 后 `run()`；或 `Interpreter.run()` 执行异常 | `false` | `API-00` §3.5（**已对齐**：`API-00` 侧措辞已扩为「推理**调用**失败 —— 覆盖未 `load()` 即 `run()` 与 `Interpreter.run()` 执行异常两种情形」，两侧语义一致） |
| `ACD-IO-002` | assets 资源缺失 / JSON 解析失败 / Schema 校验不通过 | `false` | `API-00` §3.5（ADR-08 已登记） |
| `ACD-BEH-001` | 行为分析输入非法（**包络缺失或长度不符**、`hopMs` 非法、`tStartMs` 单调性、`endMs` 顺序） | `false` | `API-00` §3.5（`ACD-BEH` 区域，ADR-08 已登记） |
| `ACD-KB-001` | 知识库查询键非法（`classId` 越界 / `label` 未注册） | `false` | `API-00` §3.5（ADR-08 已登记） |
| `ACD-UNK-000` | TFLite 运行时未分类异常 | `false` | `API-00` §3.5 |
> 本文件**未修改** `API-00`（其 §3.5 是错误码权威表）。上表 4 个码已由 **ADR-08** 登记进 `API-00` §3.5。其中 `ACD-INF-004` 原两侧措辞不一致（`API-00` 写「推理执行异常」、本文件写「未 `load()` 即 `run()`」）—— **已裁定：以 `API-00` 为登记处，把它的措辞扩为覆盖两种情形**（推理**调用**失败），使两侧语义一致。**不需要新增错误码。**

## 9. 开放问题（需人工拍板）

| # | 问题 | 影响 | 建议处置 |
|---|---|---|---|
| 1 | ✅ **已关闭（依据 ADR-01）**：`feedPatch` 无合法数据源（`API-01` 的 `patch` 事件原不含 `pcm`，见 §5） | 结论：**输入改为 `feedEnvelope`** —— 包络由原生侧计算（FF-21h），随 `patch` 事件下发 `rmsEnvelope` / `envelopeHopMs`，平滑与峰值检测留在本层（FF-21i）；`P-07` 解除阻塞，D7 硬验收可达成 | 三选一已由 ADR-01 定为候选 B，**无需再拍板**；变更已落入 `API-01` §2.3/§3.2/§7 与 §5；登记走 `PLAN-C-03` |
| 2 | `voiced=false` 对连续计数的语义（本文定为「不递增也不清零」） | `P-06` 确认时机；静音期会被"冻结"而非重置 | 由 `SPEC-P-06` 确认；若改为清零需同步改 §4 |
| 3 | `VoteStage` 无 `rejected` 值，「`p < tauLow` 且 EMA 已成形」只能表达为 `observing` | `U-02` 需靠 `smoothedConfidence < tauLow` 二次判断才能显示「未识别到明确食物」 | 确认是否新增枚举值（会破坏 §4「不得新增枚举值」） |
| 4 | ✅ **已关闭（依据 `ADR-P1`；后经 `ADR-21`（2026-09-12）修订）**：~~`n_frames = 129`（选项 B，输入 `[1, 128, 129, 1]`）~~ → `n_frames = 128`（`raw_mel_frames = 129`，输入 `[1, 128, 128, 1]`），**已修订**（FF-11 / `SPEC-00` §3.5） | 输入张量第 3 维、制品、Kotlin 常量、`model_card` 四处耦合 —— **四处已全部同步为 128 / 129 两个数** | 无需再拍板；选项 A（128 / 4.064 s / 65024 样本）**已否决**，任何改动须走 `SPEC-C-03` 变更传播并重跑 `PLAN-T-08` |
| 5 | `FoodInfo` 无 `classId` 字段，`byClassId` 依赖 `class_labels` 顺序隐式映射 | 知识库与类别表顺序耦合，无编译期保护 | §6 测试要点 ① 已覆盖；如需显式字段须新开契约 |

## 变更影响

| 类型 | 受影响对象 |
|---|---|
| SPEC | `SPEC-P-05`（引擎验收）、`SPEC-P-06`（聚合状态机）、`SPEC-P-07`（行为字段）、`SPEC-P-08`（知识库查表）、`SPEC-U-02`（展示字段）、`SPEC-T-08`（仅在动 Mel 形状时） |
| PLAN | `PLAN-P-05` `PLAN-P-06` `PLAN-P-07` `PLAN-P-08`；变更登记归 `PLAN-C-03` |
| 上游需同步 | 动 §5 输入源 → 必须同步 `API-01` §3.2 与 `API-00` §3.8；动 Mel 形状 → 必须重跑 `PLAN-T-08` 对齐测试 |
| 测试 | `PLAN-C-05` 单元套件、`PLAN-P-05`~`PLAN-P-07` 接口测试、`M-04` 自检面板字段来源 |
| 下游数据 | `smoothedProbs` 若被要求入库 → 违反 FF-24 第 3 条（无 BLOB 音频列），必须拒绝 |

## 明确不做

| 不做 | 理由 |
|---|---|
| 原生侧推理 | Mel 在原生、推理在 Dart 是刻意分工（`API-01` §6）；会让 `P-06` 聚合状态分裂成两份 |
| 任意更改类别（`X-02` 全量形态） | v1.0 只允许 A/B 二选一确认，`lowConfidence` 之外无交互式改类别 |
| 咀嚼节律标准差 σ（`X-07`） | 已裁剪；`BehaviorMetrics` **不得**新增该字段 |
| 储备类别 `nuts` | FF-19 明确不进 v1.0；`foods.schema.json` 以 `additionalProperties:false` 结构性禁止 |
| 多 patch 批推理 / 动态 batch | 实时语义是「当前在吃什么」；FF-14 固定输入形状 |
| 模型热更新 / 从网络加载 `.tflite` | 违反 FF-24 第 4 条与 `API-05` §3.1 R-OUT-3 |
| 在 L4 做单位换算与展示格式化 | `API-00` §3.2：展示格式化归 `U-*` 层 |
| 音频 / Mel 的任何落盘或缓存 | 违反 FF-24 第 1 条 |

**文档结束**

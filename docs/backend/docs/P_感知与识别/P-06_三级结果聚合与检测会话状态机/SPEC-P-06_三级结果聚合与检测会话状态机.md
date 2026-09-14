# SPEC-P-06 三级结果聚合与检测会话状态机

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4/§3.6；**`API-02` §4（`VoteStage` 判定表与 `add` 语义的权威定义）**、§9；`API-00` §3.7/§3.8；`API-01` §3.2/§4；`SPEC-00` §3.4（FF-20/FF-20a/FF-20b/FF-20c）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-P-05`（推理结果）、`SPEC-P-02`（`voiced` 标记）、`SPEC-P-01`（会话生命周期）、`SPEC-D-01`/`SPEC-D-02`（记录落库）、`SPEC-U-02`（低置信度确认交互） |

## 1. 目标与范围

### 1.1 一句话目标
实现三级聚合机制 —— Level 1 EMA 平滑（N=5、α=0.4）、Level 2 确认判据（Top-1 连续 M=4 且平滑概率 ≥ τ_confirm=0.70）、Level 3 低置信度人机协同（0.45 ≤ p < 0.70 → 二选一确认；p < 0.45 → 不写日志）—— 并维护检测会话状态机；聚合状态必须跨 patch 保持（FF-20c）。

### 1.2 范围内（In Scope）
- `VoteAggregator` 的逐类 EMA（FF-20 Level 1）与 `smoothedProbs` 产出。
- 连续计数与确认判据（FF-20 Level 2）；`VoteStage` 五值的**按序判定**（以 `API-02` §4 判定表为权威）。
- 低置信度二选一确认的**决策产出**（`shouldAskUser`）与用户答复后的最终裁定（呈现由 `SPEC-U-02` 负责）。
- `AggregatedDecision` 的字段填充与 `reset()` 语义；状态跨 patch 保持（FF-20c）与会话结束释放。
- 丢包语义：`seq` 跳号（本次与上次之差 `> 1`）→ 连续计数清零、EMA 保留（`API-02` §4）。
- 检测会话状态机（Dart 侧镜像 `API-01` §4 的 L1 状态机）与会话收尾事务触发。
- 阈值标定：`VotingConfig` 的 `tauConfirm` / `tauLow` 须在 D3 用自采跨域测试集置信度分布直方图标定，过程写进测试报告（FF-20b）。
- 会话内同类去重（去重键 = `sessionId + classId`）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| 推理与 Mel | `SPEC-P-05` / `SPEC-P-04` |
| VAD、静默判定与 90 s 结束判据 | `SPEC-P-02` |
| 行为分析 | `SPEC-P-07` |
| 数据库写入的具体实现（表结构、DAO、事务） | `D-01` / `D-02` |
| UI 呈现（确认卡片、二选一弹窗样式） | `U-02` |
| **「手动修正」= 任意更改类别 / 删除误报** | **`X-02` 已降级**：v1.0 只允许**二选一确认**，不得写成「可任意更改类别」（`SPEC-00` §3.10 术语禁令；`API-02`「明确不做」） |
| 检测页「识别历史」列表 / 登录账号体系 | `X-05` / `X-01`：不做 |
| 新增 `VoteStage` 枚举值（如 `rejected`） | **不做**：`API-02` §4 规定「不得新增枚举值」 |
| 多食物并发识别、概率校准训练、云端二次判定 | 不做：单会话单 Top-1（FF-19 六类互斥）；FF-24 §4 禁止网络 |
| 在 UI isolate 中执行聚合 | `API-00` §3.7：聚合必须与 `run()` 同 isolate |
| `smoothedProbs` 入库存档 | 禁止：违反 FF-24 第 3 条（无 BLOB 音频列），`API-02` 变更影响表已明确拒绝 |

## 2. 功能行为

### 2.1 触发与前置条件
1. 会话处于 `RUNNING`（`SPEC-P-01` §2.3）。
2. 每个 `patch` 事件都会调用一次 `add()`，**无论 `voiced` 为何值**（`SPEC-P-02` §3）。
3. `VotingConfig` 由 `feature_config` 经生成器注入（`API-02` §4）；缺字段 → `ACD-CFG-001`。
4. D9 演示前 `tauConfirm` / `tauLow` 必须已完成 FF-20b 标定。

### 2.2 主流程（编号步骤）
**Level 1 · EMA 平滑（FF-20）**
1. `voiced = true`：对新推理结果 `r.probs`（长度 6，`API-02` §3）逐类 EMA：`ema[c] ← α · r.probs[c] + (1 − α) · ema[c]`；会话首个 `voiced = true` 的 patch 直接 `ema ← r.probs`（避免用 0 初始化引入偏置）。
2. `voiced = false`（静默 patch）：**必须仍进入 EMA**（否则平滑断档，`API-01` §3.2），即沿用最近一次 `InferenceResult` 照常更新 EMA；但**不参与连续计数**——既不递增也不清零（`API-02` §4）。
3. `smoothedConfidence = max(ema)`，`top1 = argmax(ema)`，`smoothedProbs = ema`（`Float32List`，长度 6）。
4. `seq` 跳号（本次与上次之差 `> 1`）→ **连续计数清零、EMA 保留**；`seq` 重复 → 幂等，不改变任何状态。

**Level 2 · 确认判据（FF-20）**
5. `top1` 与上一次 `voiced = true` 的 `top1` 相同 → `consecutiveCount++`；否则 `consecutiveCount = 1`。
6. `consecutiveCount ≥ M` 且 `smoothedConfidence ≥ tauConfirm` → `stage = confirmed`，锁定 `classId`/`label`；`smoothedConfidence ≥ tauConfirm` 但连续不足 → `stage = unconfirmed`。

**Level 3 · 低置信度人机协同（FF-20）**
7. `tauLow ≤ smoothedConfidence < tauConfirm` → `stage = lowConfidence`，`shouldAskUser = true`，`classId`/`label` 取当前 `top1`。
8. `smoothedConfidence < tauLow` 且 EMA 已成形 → `stage = observing`，`shouldAskUser = false`，**不写日志**（`API-02` §4 判定表第二行）。
9. 有效样本数 `== 0`（会话开始或 `reset()` 后）→ `stage = none`，`classId = null`、`label = null`、`smoothedProbs = null`、`shouldAskUser = false`。EMA 样本数 `< emaWindow` 而有效样本数 `> 0` → `stage = observing`（UI 只显示灰色实时预测）。
10. **二选一确认（`X-02` 降级后的唯一「手动」能力）**：UI 呈现「疑似 X，请确认？」，用户只能选「是 / 否」。选「是」→ 该 `classId` 视为 `confirmed` 并触发记录生成；选「否」→ 不改类别、不写日志；**不得弹出类别选择列表**。
11. `confirmed` 一旦达成，在会话内保持，直到会话结束或出现不同 `top1` 连续 M 次（后者按步骤 6 重新裁定）；同一会话同一 `classId` 只生成一条记录。
12. 会话结束时 `reset()`；下一次会话必须从 `none` 起步。

**检测会话状态机（Dart 侧）**
13. Dart 侧镜像 `API-01` §4 的状态；`sessionEnded` 到达后执行收尾：若存在未落库的 `confirmed`，由 `D-01`/`D-02` 在**一个事务**内提交（`API-00` §3.8）。

### 2.3 状态与状态迁移
按 `API-02` §4 判定表**按序判定，先命中者胜**：

| `stage` | 判定条件 | `classId` | `shouldAskUser` |
|---|---|---|---|
| `none` | 有效样本数 `== 0` | `null` | `false` |
| `observing` | EMA 样本数 `< emaWindow`；**或** EMA 已成形但 `smoothedConfidence < tauLow` | 最近 Top-1（可 `null`） | `false` |
| `unconfirmed` | EMA 已成形且 p ≥ `tauConfirm`，但连续计数 `< M` | Top-1 | `false` |
| `lowConfidence` | EMA 已成形且 `tauLow ≤ p < tauConfirm` | Top-1 | **`true`** |
| `confirmed` | 连续 M 个 patch Top-1 不变且 p ≥ `tauConfirm` | Top-1 | `false` |

**迁移触发**：`observing → unconfirmed/lowConfidence/observing`（EMA 成形时按 p 再判定）；`unconfirmed → confirmed`（连续达 M）；`lowConfidence → confirmed`（用户选「是」或 p 回升且连续达 M）；`lowConfidence → unconfirmed`（用户选「否」）；`confirmed → unconfirmed`（Top-1 变化）；`任意 → none`（`reset()` / 会话结束）。

**会话级状态机**（权威定义在 `API-01` §4，L1）：
- 收到 `patch(seq)` 且 `seq` 与上一次不连续 → 连续计数清零、EMA 保留，并记诊断；**不得**自行补号。
- 收到 `sessionEnded` → 立即停止 `add()` 调用并 `reset()`；此后再来的 patch 一律丢弃。
- `pauseSession` 期间无 patch 到达；恢复后聚合状态**继续保留**（暂停不重置 EMA）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 会话时长 < 4.096 s | 无 patch，`stage == none`；结束时无记录 |
| 全程静默 | EMA 因沿用最近结果而可能成形，但连续计数不变；FF-21a 到达后 `sessionEnded(silence90s)`，无记录 |
| p 长期在 `[tauLow, tauConfirm)` 抖动 | `shouldAskUser` 反复置真；由 `U-02` 去重呈现（同一 `classId` 只问一次），**聚合器不负责去重** |
| `r.probs.length ≠ 6` | `ACD-INF-002`（fail fast，说明上游 `run()` 已违约，`API-02` §4） |
| 同一 `seq` 重复投递 / `reset()` 在会话中调用 | 幂等 / 状态断言 | 重复 `seq` 不改变 EMA 与计数；`reset()` 仅允许会话边界调用，会话中调用视为缺陷（测试断言） |

## 3. 接口契约
> 权威定义：`API-02` §4。**类名、字段名、方法签名不得改动**；本 SPEC 只引用，不新增成员。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L4 内部（P-05 → 本功能） | `VoteAggregator.add(InferenceResult r, {required int seq, required bool voiced})` | 最近一次推理结果、`seq`、`voiced` | `AggregatedDecision` | `ACD-INF-002`（`probs` 长度不符） |
| L4 内部 | `VoteAggregator({required VotingConfig cfg})` / `reset()` | 配置 / — | 实例 / `void` | `ACD-CFG-001`（配置缺字段） |
| 本功能 → 诊断 | 诊断记录（`seq` 跳号、重复 `seq`） | — | 内存环形缓冲 | — |
| 本功能 → L5 | `AggregatedDecision` | — | `stage`/`classId`/`label`/`smoothedConfidence`/`consecutiveCount`/`shouldAskUser`/`smoothedProbs` | — |
| 本功能 → L4（记录生成） | 确认信号 | `sessionId`、`classId`、`label` | 触发 `D-01`/`D-02` 落库 | `ACD-DB-002`（冲突时去重） |
| L5 → 本功能 | 二选一答复 | 「是 / 否」 | 最终 `stage = confirmed` 或维持 | — |

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

## 4. 数据契约
| 项 | 类型 | 值域 / 约束 |
|---|---|---|
| `ema`（内部态） | `List<double>(6)` | `[0,1]`；会话内跨 patch 保持（FF-20c）；**不落盘、不入库** |
| `consecutiveCount` | `int` | `≥ 0`；Top-1 变化置 1；`seq` 跳号清零；`voiced=false` 时不变 |
| `smoothedConfidence` | `double` | `[0,1]`；等于 `max(ema)`；`none` 时为 `0.0` |
| `smoothedProbs` | `Float32List?` | 长度 6；`none` 时为 `null`；仅供 `U-02` 可视化，**禁止入库** |
| `classId` / `label` | `int?` / `String?` | **`null` 当且仅当 `stage == none`**；非空时与 FF-19 一致 |
| `shouldAskUser` | `bool` | **仅** `lowConfidence` 为 `true`（唯一允许弹二选一的入口） |
| 确认产出的记录字段 | — | 由 `D-01` 的 `DietRecord` 定义；本功能只提供 `sessionId`/`classId`/`label`/时间 |
| 三档阈值 | `double` | 来自 `VotingConfig`（FF-20b 标定后写入）；代码只读不写 |
| 标定产物 | 文件 | `docs/reports/p06_threshold_calibration.md`（直方图 + 标定过程，**D3 实测产出**） |

## 5. 参数与常量
| 项 | 引用 |
|---|---|
| EMA 窗口 `N`（`emaWindow`）、`α`（`emaAlpha`）；连续判据 `M`（`confirmConsecutivePatches`）、`τ_confirm`（`tauConfirm`） | FF-20（Level 1 / Level 2） |
| 低置信度下界 `τ_low`（`tauLow`） | FF-20（Level 3，`0.45`）；**必须取自配置，不得硬编码** |
| 首次确认耗时口径 | FF-20a（≈4–5 s；**禁止对外宣称「2 秒内出结果」**，FF-25） |
| 三档阈值标定要求 | FF-20b（D3，自采跨域测试集，直方图标定，过程入测试报告） |
| 跨 patch 状态保持 | FF-20c |
| 推理滑窗步长（默认 / 降级） | FF-12 / FF-12 的 2 倍（`SPEC-P-05` §6） |
| 静默结束 / 类别表 | FF-21a（由 `SPEC-P-02` 判定）/ FF-19 |
| `n_frames` | FF-11（**`n_frames = 128`**；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 宣传口径 | FF-25（「典型食物类别」「零录入操作」「约 4–5 秒」） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `seq` 跳号 | 本次与上次之差 `> 1` | 连续计数清零、EMA 保留；记诊断 | 无 |
| `seq` 重复 | 与上次相等 | 幂等忽略 | 无 |
| `probs.length ≠ 6` | 长度断言 | `ACD-INF-002`（fail fast） | 无（开发期可见） |
| 静默 patch | `voiced = false` | 仍更新 EMA；连续计数不变 | 无 |
| 长时间停在 `lowConfidence` | `shouldAskUser` 持续为真 | 聚合器不强推；由 `U-02` 控制询问频次 | 「疑似 X，请确认？」（仅二选一） |
| p 长期 < `tauLow` | `stage == observing` 持续 | **不写日志**；会话结束只留 `SessionSummary` | 「未识别到明确食物」（`U-02` 依 `smoothedConfidence < tauLow` 二次判断） |
| 配置缺三档阈值 | 启动加载断言 | `ACD-CFG-001`，禁止进入检测页 | 「配置不一致，请重装应用」 |
| 落库唯一约束冲突 | `ACD-DB-002` | 按 `sessionId + classId` 去重后忽略 | 无 |
| 推理降级（步长 → 1.0 s） | `SPEC-P-05` 的降级信号 | 聚合语义**不变**；确认耗时增加（属 FF-20a 口径范围） | 无提示；不得承诺固定秒数 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | EMA 公式与首个 patch 初始化 | `flutter test test/domain/vote_aggregator_ema_test.dart` 的 `ema_matchesFormula` / `firstVoicedPatch_initializesFromProbs` | 逐元素差 < 1e-9；首 patch `ema == probs`，非 0 初始化 |
| 2 | 连续计数与 Level 2 确认判据 | `vote_aggregator_confirm_test.dart` 的 `consecutiveCount_resetsOnTop1Change` / `confirms_only_when_M_consecutive_and_tau` | Top-1 变化置 1；连续 `M−1` 次不确认；第 `M` 次且 p ≥ `tauConfirm` → `confirmed` |
| 3 | `VoteStage` 五值按序判定 | `vote_aggregator_stage_table_test.dart`（对 `API-02` §4 判定表逐行参数化） | 5 行判定条件各自命中对应 `stage`；无新增枚举值 |
| 4 | Level 3 两档边界 | `vote_aggregator_level3_test.dart` 的 `level3_boundaries` | `p == tauLow` → `lowConfidence` 且 `shouldAskUser == true`；`p < tauLow` → `observing` 且 `shouldAskUser == false` |
| 5 | `p < tauLow` 不写日志 | `flutter test test/domain/no_log_when_low_test.dart`（mock 记录仓储计数） | 记录仓储 `insert` 调用次数 == 0 |
| 6 | 跨 patch 状态保持（FF-20c） | `vote_aggregator_state_test.dart` 的 `state_persistsAcrossPatches` | 连续 10 次 `add()` 后 `ema` 未被重置；`reset()` 调用次数 == 0 |
| 7 | 静默 patch 语义 | `vote_aggregator_silent_test.dart` | `voiced=false` 改变 `smoothedConfidence` 但 `consecutiveCount` **不变**（不递增也不清零） |
| 8 | 幂等与跳号 | `vote_aggregator_seq_test.dart` | 重复 `seq` 不改变状态；跳号使 `consecutiveCount == 0` 且 `smoothedProbs` 保留 |
| 9 | 字段一致性 | `vote_aggregator_decision_test.dart` | `classId == null && label == null` **当且仅当** `stage == none`；`shouldAskUser == (stage == lowConfidence)`；`none` 时 `smoothedProbs == null` |
| 10 | 二选一确认语义（X-02 降级） | `flutter test test/domain/binary_confirm_test.dart` | 答复接口只接受「是/否」；**不存在**可传入任意 `classId` 的 API（签名/反射断言） |
| 11 | 会话内同类去重 | `flutter test test/domain/confirm_dedup_test.dart` | 同一 `sessionId + classId` 只触发 1 次落库 |
| 12 | 首次确认不早于物理下界 | `vote_aggregator_timing_test.dart` | `confirmed` 时刻 ≥ 第 `M` 个 `voiced=true` patch 的 `tStartMs + 4.096 s`；**实测中位数在 D6 产出**并写入报告，不写预测值 |
| 13 | 阈值标定已完成 | `python ai/scripts/check_thresholds_calibrated.py` | `tauConfirm`/`tauLow` 来自 `feature_config.voting`，且 `docs/reports/p06_threshold_calibration.md` 存在并含直方图文件引用 |
| 14 | 无硬编码阈值 / 会话结束释放状态 | `python ai/scripts/assert_no_hardcoded_thresholds.py` + `vote_aggregator_lifecycle_test.dart` | 命中数 == 0；`sessionEnded` 后拒绝 `add()`，`reset()` 后首次 `add()` 返回 `none` |

## 8. 非功能约束
- **线程**：聚合必须与 `run()` 在**同一 isolate**（`API-00` §3.7）；本类非线程安全、不加锁（`API-02` §4）。
- **实时性**：单次 `add()` 为 `O(6)` 向量运算，必须远低于 patch 间隔（FF-12）；实测值在 D6 产出。
- **内存与隐私**：内部态为常量大小（6 个 double + 3 个计数器）；不落盘、不入库、无网络（FF-24）；`smoothedProbs` 禁止入库。
- **可单测性**：聚合器不得 import Flutter widget（`API-00` §1 第 2 条）；二选一交互的无障碍要求由 `U-02`/`U-06` 承担。

## 9. 裁剪与未做
- **本功能属「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）与 ②自动生成记录（`D-01`~`D-03`、`P-06`）**（`00_功能清单` §6）。**两条都指向本功能，不得裁剪。**
- `X-02` 手动修正（改类别、删误报）：**降级为 A/B 二选一确认**，由 `P-06` Level 3 承接。**任何「可任意更改类别」的描述或 API 都不做**（同时见 `API-02`「明确不做」）。
- `X-05` 检测页「识别历史」列表、`X-01` 登录 / 账号体系：**不做**。
- 多类并发识别、概率校准训练、云端二次判定、检测历史回放、把三档阈值做成 UI 可调项：**不做**（阈值只来自标定后的 `feature_config.voting`）。
- 新增 `VoteStage` 枚举值：**不做**（`API-02` §4 明文禁止）。

## 10. 开放问题
1. 🔴 **`add()` 的非空参数与静默 patch 的数据来源**：`API-02` §4 已裁定静默 patch **必须仍进入 EMA** 且「不参与连续计数（既不递增也不清零）」，但 `r` 为非空类型——因此调用方只能**沿用最近一次 `InferenceResult`** 调用。**该沿用规则需写入 `API-02`（或把 `r` 改为 `InferenceResult?`）**；`API-02` §9 第 2 条已挂起此问题，**需 A/B 确认**并同步 `SPEC-P-02` §3 与本文 §2.2 步骤 2。
2. **`VoteStage` 无 `rejected` 值**：`p < tauLow` 且 EMA 已成形只能表达为 `observing`，`U-02` 需依 `smoothedConfidence < tauLow` 二次判断才显示「未识别到明确食物」（`API-02` §9 第 3 条）。**需 A/C 确认是否新增枚举值**（新增会破坏 `API-02` §4「不得新增枚举值」）。
3. **`tauLow` 是否恒等于 `0.45`**：FF-20 给的是 `0.45`，`API-02` 用符号 `tauLow` 表达；若 FF-20b 标定后 `tauLow` 调整，Level 3 的两档边界随之变化。**需 A 确认 `tauLow` 是否允许偏离 FF-20 的 `0.45`。**
4. **二选一确认「选是」后是否仍需满足 `tauConfirm`**：本 SPEC 按「用户答复即裁定」处理，是否需要二次平滑保护**需 B/C 确认**（涉及 `U-02` 交互设计）；`n_frames` 已修订为 **`n_frames = 128`**（`ADR-21`，2026-09-12；旧值 ~~`129`~~，`129` 现为 `raw_mel_frames`），对本功能无直接数值影响。

**文档结束**

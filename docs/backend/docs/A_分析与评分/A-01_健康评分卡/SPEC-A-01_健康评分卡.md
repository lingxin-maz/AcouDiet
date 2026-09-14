# SPEC-A-01 健康评分卡

| 项 | 值 |
|---|---|
| 域 | A · 分析与评分 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.8（评分卡设计）、§3.4.1（UI 数据契约表）、§9.1（双轨 Demo）；`SPEC-00 §3.7 FF-22`、`§3.6 FF-21e/FF-21f/FF-21g`、`§3.10 FF-25`；**`API-04 §3`（签名与 `evidence` 键集权威）**、`API-03 §4/§5`（聚合输入与餐次窗口权威）、`API-05 §6.1/§6.2`（可复现与舍入）、`docs/common/docs_api/schemas/health_score.schema.json`（`healthScore` 子模式） |
| 依赖的 SPEC | `SPEC-D-03`（聚合查询，`API-03 §5` 的实现侧）、`SPEC-D-01` `SPEC-D-02`（表与 DAO）；下游 `SPEC-A-02`、`SPEC-A-03`、`SPEC-U-01`、`SPEC-U-04`；测试 `SPEC-C-05` |

## 1. 目标与范围

### 1.1 一句话目标

把给定时间窗的本地饮食记录聚合值按 FF-22 换算成**公式完全公开、逐维可下钻、同库同窗可复现**的四维 100 分健康评分卡（`HealthScore`）。

### 1.2 范围内（In Scope）

- 四维打分 `regularity` / `structure` / `snack` / `speed`：**公式属本域**，满分与解析式见 FF-22 与 §5 表 A-01-T1。
- `totalScore` = 四维**各自 `round()` 后**求和（`API-05 §6.2`；根治主方案 §3.8 已知缺口 D-1）。
- 评级 `grade` 三值枚举的分档阈值（§5 A-01-K1，**已冻结**：`总分 ≥ 80 → 良好`；`60–79 → 一般`；`总分 < 60 → 需改善`；依据 `ADR-P2`（2026-09-10），已登记为 `SPEC-00` §3.7 **FF-22b**）。
- `deltaVsYesterday`：与评分窗**前一个本地日历日**的总分之差。
- 按 `API-04 §3` 的键集填充每维 `evidence`（下钻依据 + 答辩解释「85 是怎么算的」）。
- 数据不足时的**确定性**降级（§2.4、§6）：禁止随机、禁止使用「当前时间」。
- 纯函数内核 `ScoreFormulas.compute(ScoreInputs)` 与下钻公式串常量 `ScoreFormulas.formulaOf`。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

- **不写 SQL、不做聚合**：`snackCount` / `lateNightCount` / `mealTimeStdDevMinutes` / `classCounts` / 估算热量一律取自 `StatsRepo`（`SPEC-D-03`、`API-03 §5`）。
- **不重算 σ**：`σ = WeekSummary.mealTimeStdDevMinutes`，口径权威在 `API-03 §5.3`；L4 不得自行分餐、换算分钟数或重算标准差。
- 不产出格式化字符串（`API-00 §3.2`；`summaryText` 的唯一例外属 `A-03`）。
- 不做知识库热量查表（`P-08`）、不做趋势序列与周报（`A-03`）、不做建议文案（`A-02`）、不做行为速度评级文案（`P-07`）。
- **不得新增 `evidence` 键**：`health_score.schema.json` 对每个维度设 `additionalProperties: false`，多一个键即契约违约。
- 不做手工改分/改类别（`X-02`）、不做导出（`X-03`）、不引入咀嚼节律 σ（`X-07`）、无任何网络调用（`FF-24`）。

## 2. 功能行为

### 2.1 触发与前置条件

| # | 前置条件 | 来源 |
|---|---|---|
| 1 | 本地库已初始化且迁移到当前 `version` | `D-01` `D-02` |
| 2 | 调用方（`U-01`/`U-04`）传入 `DateRange`（**左闭右开**，本地日历日边界，epoch ms） | `API-03 §4` |
| 3 | `StatsRepo.week()` 可返回含 `mealTimeStdDevMinutes` / `classCounts` / `snackCount` / `lateNightCount` 的 `WeekSummary` | `API-03 §5`（`SPEC-D-03`） |
| 4 | 有效数据集已确定：`A-04` 载入演示数据时，聚合只含 `source == 'demo'` 的记录 | `SPEC-A-04` |
| 5 | `behavior_metrics` 占位行存在但字段可为 `NULL`；判定「有无指标」看**行**而非字段 | `API-03 §2.3` |

### 2.2 主流程（编号步骤）

1. 校验 `range`：`endMs > startMs`；越界 → `ACD-DB-004`（入参非法，`API-04 §3` 错误表）；本流程**不读系统时钟**。
2. 经 `StatsRepo.week()` 取本窗口聚合（**同一窗口只读一次**）；不写库、不缓存。
3. **regularity**：`σ = mealTimeStdDevMinutes`。`σ == null` → 该维 `score = 0`、`evidence.sigmaMinutes = null`；否则 `raw = 30 × max(0, 1 − σ/90)`（σ 单位分钟，FF-22）。
4. **structure**：`healthyCount = Σ classCounts[cabbage, carrot, noodles]`（FF-22 指定类别）；`totalCount = recordCount`；`healthyRatio = totalCount == 0 ? 0.0 : healthyCount / totalCount`；`raw = 30 × min(1, healthyRatio / 0.4)`。
5. **snack**：`n = snackCount`（**本周**口径；零食窗口见 `API-03 §5`，`ADR-09`）；`raw = 20 × max(0, 1 − n/10)`。
6. **speed**：`t` = 窗口内以 `durationSeconds` 为权的加权平均咀嚼间隔（秒，采纳 `API-04 §9` OQ-3）；`t == null` → `score = 0`；`t ≥ 0.8 → 20`；`t ≤ 0.4 → 0`；中间 `raw = 20 × (t − 0.4) / 0.4`。
7. 四维各自 `round()`（半值远离零）后 `clamp(0, max)` 写入 `DimensionScore.score`；`max` 取自 FF-22 权重（`feature_config.health_score_weights`）；`label` 取固定中文名；`evidence` **严格按 `API-04 §3` 的键集逐维填充**（不增不减）。
8. `totalScore = regularity.score + structure.score + snack.score + speed.score`。
9. `grade` 按 §5 A-01-K1 判定。
10. `deltaVsYesterday`：由 `range` **纯算术**推出前一本地日历日窗口并复用步骤 2–8；该日无有效数据 → `null`（**不得**用 0 顶替，`API-04 §3`）。
11. 返回 `HealthScore`。全程无随机、无时钟读取、无 IO 写。

### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）

**无状态**。`HealthScoreService` 不持有跨调用状态、不做缓存；同一 `range` 重复调用必须逐字段相同（`API-05 §6.1`）。

### 2.4 边界条件

| # | 场景 | 处理（确定性） |
|---|---|---|
| 1 | 窗口内记录数 = 0 | `structure.totalCount == 0` → 该维 0 分；`sigmaMinutes == null` → `regularity` 0 分；`speed` 0 分；`snack` 按 `n = 0` 得满分；`totalScore` 仍为四维之和（**不是** null）；`U-01`/`U-04` 显示 `--`（§4 UI 判定） |
| 2 | 窗口内无有效餐类（`mealTimeStdDevMinutes == null`） | `regularity.score = 0` 且 `evidence.sigmaMinutes = null`；UI 该维 `--`、总分 `--` |
| 3 | 窗口内全部为占位指标行（`avgChewIntervalSeconds == null`） | `speed.score = 0`、`evidence.avgChewIntervalSeconds = null`、`sampleCount = 0`、`missingMetricsCount > 0` |
| 4 | σ = 0（每日固定时刻用餐） | `regularity = 30`（FF-22 公式口径） |
| 5 | `t` 恰为 0.4 / 0.8 | 0 / 20 |
| 6 | `n ≥ 10` | `max(0, …)` 保证 0，不得为负 |
| 7 | `healthyRatio ≥ 0.4` | `min(1, …)` 保证 30，不得超满分 |
| 8 | 半值（如 22.5、7.5） | `round()` 半值远离零 → 23、8（`API-05 §6.2` 未规定则按 Dart `round()` 语义，测试锁定） |
| 9 | 4 类降级模式（FF-19 降级开关生效） | `structure` 分子/`snack` 口径不变（脆性 = chips + gummies；结构类 = cabbage + carrot + noodles） |
| 10 | 昨日有数据但不可算 | `deltaVsYesterday = null`；UI 隐藏该行 |

## 3. 接口契约

> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准，此处给「本功能用到的部分」并标注 API 编号。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5 → L4 | `HealthScoreService.score` | `DateRange range`（`{int startMs, int endMs}`） | `Future<HealthScore>` | `ACD-DB-003` / `ACD-DB-004` / `ACD-SCORE-001` / `ACD-KB-001` |
| L4 内部 | `ScoreFormulas.compute` | `ScoreInputs`（本域私有入参） | `HealthScore`（同步纯函数） | 无（入参由步骤 2 保证合法） |
| L4 常量 | `ScoreFormulas.formulaOf(dimension)` | 维度键 | `String`（展示用公式串） | 无 |
| L4 → L3 | `StatsRepo.week()` | — | `WeekSummary` | `ACD-DB-003` `ACD-DB-004` `ACD-KB-001` 透传不吞 |
| L4 → L5 | `HealthScore` / `DimensionScore` | — | 见 §4 | — |

**权威归属**：类名、字段、`evidence` 键集与错误码的**唯一权威是 `API-04 §3` + `docs/common/docs_api/schemas/health_score.schema.json`**；本 SPEC 不复制签名，只补充公式、常量与验收。两者冲突时以 `API-04`/schema 为准并登记 §10。

## 4. 数据契约

> 涉及的字段、类型、单位、值域、可空性。引用 `docs/common/docs_api/schemas/` 中的 schema 文件名。

- **输出结构**：`docs/common/docs_api/schemas/health_score.schema.json` 的 `healthScore` 子模式（`additionalProperties: false`，六个必填键 `totalScore`/`grade`/四维/`deltaVsYesterday`）。
- **`evidence` 键集**：逐维以 `API-04 §3` 的权威键表为准（`regularity`：`sigmaMinutes`/`mealTimeSamples`/`windowDays`；`structure`：`healthyRatio`/`healthyCount`/`totalCount`；`snack`：`snackCount`/`lateNightCount`；`speed`：`avgChewIntervalSeconds`/`sampleCount`/`missingMetricsCount`）。**本 SPEC 不重抄该表**（`SPEC-00 §5` 只写一次原则）。
- **`label` 固定值**（schema `enum`，四维不得改名）：`饮食规律性` / `食物结构` / `零食控制` / `进食速度`（与 `U-01`/`U-04` 雷达轴一致）。
- **UI `--` 判定（本域对 `U-01`/`U-04` 的行为约定，可机器判定）**：满足任一即该维显示 `--`，且**总分与评级也显示 `--`**（主方案 §3.4.1、`SPEC-U-01 §2.4`）：

| 触发条件（用 `evidence` 值判定，无需新增字段） | 对应维度 |
|---|---|
| `regularity.evidence['sigmaMinutes'] == null` | 饮食规律性 |
| `structure.evidence['totalCount'] == 0` | 食物结构 |
| `speed.evidence['avgChewIntervalSeconds'] == null` | 进食速度 |

- **本域私有入参 `ScoreInputs`**：`{double? sigmaMinutes, Map<String,int> classCounts, int recordCount, int snackCount, int lateNightCount, double? avgChewIntervalSeconds, int sampleCount, int missingMetricsCount, int windowDays}` —— 仅用于把 `WeekSummary` 与内核解耦以便单测；**不是**跨层契约，不得被 `U-*` 引用。
- `Δ = deltaVsYesterday`：`int?`；昨日无有效数据 → `null`；`0` 表示**确实持平**。

## 5. 参数与常量

> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。

**FF / API 引用表**

| 引用 | 用途 |
|---|---|
| `FF-22` | 四维满分、三条解析式与端点（**本域公式的唯一权威来源**） |
| `FF-21e` | 「偏快 / 正常 / 偏慢」速度评级阈值 —— 只属 `P-07` 文案，**不是**评分端点，二者不得合并为同一常量 |
| `FF-21f` | 咀嚼次数文案必须带「约」 |
| `FF-21g` | MAE 降级线：触发时文案降级，**分数不变** |
| `FF-19` | 类别表与 4 类降级开关（决定 `structure` 分子与 `classCounts` 键集） |
| `FF-24` / `FF-25` | 无网络；文案口径（分数本身不含热量表述） |
| `API-03 §4/§5/§5.3` | `DateRange` 左闭右开；`WeekSummary` 字段；餐次窗口（`ADR-09` 新窗口）；σ 口径 |
| `API-05 §6.1/§6.2` | 纯函数可复现；四维各自取整后求和 |
| `feature_config.health_score_weights` | 四维满分（须与 FF-22 一致，`C-03` 校验） |

**表 A-01-T1 完整评分表（四维 × 公式 × 端点 × 满分）**

| 维度 | 满分（FF-22） | 公式（FF-22） | 端点（FF-22） | 取整 | 聚合输入（`API-03`） |
|---|---|---|---|---|---|
| 饮食规律性 `regularity` | 30 | `30 × max(0, 1 − σ/90min)` | **σ=0 → 30；σ=30 → 20；σ=60 → 10；σ≥90 → 0**（连续线性衰减，**无平台段**；依据 `ADR-05`：**以公式为准，散文作废**） | `round` → `clamp(0,30)` | `mealTimeStdDevMinutes`（§5.3；三餐窗口见 `API-03 §5`，`ADR-09`） |
| 食物结构 `structure` | 30 | `30 × min(1, p/0.4)`，`p` = (cabbage + carrot + noodles) 占比 | p≥40% 满分 | `round` → `clamp(0,30)` | `classCounts` + `recordCount` |
| 零食控制 `snack` | 20 | `20 × max(0, 1 − n/10)`，`n` = 本周零食次数 | n=0 满分；n≥10 零分 | `round` → `clamp(0,20)` | `snackCount`（零食窗口见 `API-03 §5`，`ADR-09`） |
| 进食速度 `speed` | 20 | `t ≥ 0.8s → 20`；`t ≤ 0.4s → 0`；中间 `20 × (t − 0.4)/0.4` | — | `round` → `clamp(0,20)` | `avgChewIntervalSeconds`（按 `durationSeconds` 加权） |

> ✅ **已关闭（依据 `ADR-05`，`SPEC-00 §3.7`）**：**以公式为准，散文作废。** 主方案 §3.8 同一格里的散文「σ≤30 min 满分」**不再具有约束力**；`regularity` 端点统一为 `σ=0 → 30`、`σ=30 → 20`、`σ=60 → 10`、`σ≥90 → 0`，连续线性衰减、**无平台段**。本 SPEC 的 §7 算例与 `ScoreFormulas.formulaOf` 下钻公式串一律按此口径，**不存在第二种解释**（`σ=30` 断言 `20`，禁止断言 `30`）。

**表 A-01-T2 本域新增/冻结常量（FF 未定义者；`A-01-K1` 已由 `ADR-P2` 登记为 `SPEC-00` §3.7 **FF-22b**，其余见 §10）**

| 编号 | 常量 | 取值 | 说明 |
|---|---|---|---|
| A-01-K1 | 评级阈值 | ✅ **已冻结（`ADR-P2`，2026-09-10）**：`totalScore ≥ 80 → 良好`；`60 ≤ x ≤ 79 → 一般`；`x < 60 → 需改善`（登记为 `SPEC-00` §3.7 **FF-22b**；机器可读值 = `feature_config.health_score_formula.grade_thresholds` 的 `good_min = 80` / `fair_min = 60`） | FF-22 只给枚举未给阈值；`API-04 §9` OQ-1 建议同值，**已由 `ADR-P2` 采纳并冻结**，不再待确认 |
| A-01-K2 | `speed` 评分端点 | 0.4 s / 0.8 s（与 `FF-21e` 的 0.50/0.80 **不同**） | 评分与文案是两套阈值，禁止合并 |
| A-01-K3 | `speed` 聚合口径 | 以 `durationSeconds` 为权的加权平均（采纳 `API-04 §9` OQ-3） | 权重为 0 的记录不计入 `sampleCount` |
| A-01-K4 | 数据不足阈值 | `recordCount < 3` → 报告/首页进入空态（**与 `SPEC-A-03 §5` A-03-K4 同值同源**，`SPEC-U-04 §6` 要求「阈值与 A-03 对齐」） | 只影响 UI 空态，不改变四维与总分计算 |
| A-01-K5 | 公式串单一来源 | `ScoreFormulas.formulaOf` 返回的串**必须**与 `U-01`/`U-04` 下钻展示的串同一常量 | 禁止在页面里再写一份公式字面量 |
| A-01-K6 | `range` 跨度上限 | 1–31 天；越界 → `ACD-DB-004` | 与 `API-04 §3` 的错误表一致 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `range` 非法（`endMs ≤ startMs` 或跨度 > 31 天） | 入参校验 | 抛 `ACD-DB-004`，不查库 | 页面错误态（`U-01`） |
| 窗口内无记录 | `structure.totalCount == 0` | 四维按 §2.4 #1 确定性计算；`totalScore` 仍为四维之和 | 总分/评级/雷达 `--`；`delta` 行隐藏 |
| 无有效餐类 → σ 不可得 | `mealTimeStdDevMinutes == null` | `regularity.score = 0` + `evidence.sigmaMinutes = null` | 该维 `--`，总分 `--` |
| 无有效行为指标 → `t` 不可得 | `avgChewIntervalSeconds == null` | `speed.score = 0` + 对应证据键为 `null`/`0` | 该维 `--`，总分 `--` |
| 无法给出确定值（输入自相矛盾或依赖缺失） | 内核前置断言失败 | 抛 `ACD-SCORE-001`，`detail.dimension` 指明维度 | 页面错误态，不显示编造分数 |
| `classId` 未注册（估算热量/知识库） | `ACD-KB-001` | 透传不吞，**不得**静默按 0 计 | 页面错误态 |
| 数据库读失败 | `ACD-DB-003` | 透传不吞，由 L5 `AsyncValue.error` 承接 | 页面错误态 + 重试入口 |
| `FF-21g` 触发（咀嚼 MAE 超线） | `BehaviorMetrics` 标记 | **分数不变**，仅 `P-07`/`A-02` 文案降级 | 速度维度证据区显示「咀嚼节奏：较快」 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 算例 A（四维全满分）逐字段正确 | `flutter test app/test/domain/health_score_formula_test.dart` → `算例A_满分基准` | 6 条记录（早餐 07:00 ×2、午餐 12:00 ×2、晚餐 18:30 ×2，类别全为 `noodles`/`carrot`/`cabbage`）→ σ=0、`healthyRatio`=1.00（6/6）、`n`=0、`t`=0.80 → 30/30/20/20，`totalScore == 100`，`grade == '良好'`，昨日 92 → `deltaVsYesterday == 8` |
| 2 | 算例 B（下午加餐：新窗口生效） | 同上 → `算例B_下午加餐新窗口生效` | 10 条记录（早餐 07:00 ×3 + 07:40 ×1；**15:40 薯片 ×6**）→ σ=20、`healthyRatio`=0.20（2/10）、`n`=6、`t`=0.70 → 23、15、8、15，`totalScore == 61`，`grade == '一般'`；**15:40 必须计入 `snackCount`（`API-03 §5`，`ADR-09`）——若误用已作废的旧窗口则 `n`=0、`snack`=20、总分 73，测试须锁定 61** |
| 3 | 算例 C（σ=30 争议点 + 两个零分端点） | 同上 → `算例C_端点与空delta` | 20 条记录（早餐 07:00 ×2；晚餐 17:00 ×3 + 19:00 ×1；**15:40 薯片 ×14**）→ σ=30 → **20**（依据 `ADR-05`：公式为准，散文作废；**不得断言 30**）、`healthyRatio`=0.10（2/20）→ 8（7.5）、`n`=14 → 0、`t`=0.40 → 0，`totalScore == 28`，`grade == '需改善'`，`deltaVsYesterday == null` |
| 4 | 算例 D（数据不足的确定性降级） | 同上 → `算例D_不足数据的确定性` | 8 条记录（早餐 07:00 ×1、午餐 12:00 ×1、晚餐 18:00 ×1、**15:40 薯片 ×5**）→ 早/午/晚样本数均 <2 → σ=null；`healthyCount`=2/`totalCount`=8、`n`=5、`t`=null → 四维 0/19（18.75）/10/0，`totalScore == 29`；`sigmaMinutes == null`、`avgChewIntervalSeconds == null`；UI 呈 `--` |
| 5 | `evidence` 键集与 schema 全等 | 同上 → `evidence键集_无多键缺键` | 对四维分别断言键集合 == `API-04 §3` 键集；多键/缺键均失败（`additionalProperties:false`） |
| 6 | 总分等于四维之和（根治缺口 D-1） | 同上 → `总分等于四维之和` | 4 组算例 + 演示数据集：`totalScore == Σ四维 score`，差异字段数 == 0 |
| 7 | **跨功能一致性（PLAN-C-05）**：评分卡数字 == UI 显示数字 | `flutter test app/test/domain/health_score_consistency_test.dart`（`SPEC-C-05` §5 表 #1 权威测试名） | 同一 `HealthScore` 经 `U-01`/`U-04` presenter 与 `app/test/ui/score_card_render_test.dart` 渲染后，总分、四维 `score/max`、`grade`、下钻文本中的每个数字**逐字段相等**；差异字段数 == 0 |
| 8 | 可复现（纯函数） | `flutter test app/test/domain/score_reproducibility_test.dart`（`SPEC-C-05` §5 表 #18） | 同库同窗连跑两次逐字段相等；源文本断言 `app/lib/domain/health/**.dart` 中 `DateTime.now`、`Random(`、`http`、`dio` 命中数各为 **0** |
| 9 | 公式串单一来源 | `flutter test app/test/domain/health_score_formula_test.dart` → `公式串唯一来源` | `ScoreFormulas.formulaOf` 与本 SPEC 表 A-01-T1 公式串逐字相等；页面源码中公式字面量命中数为 0 |
| 10 | 阈值/端点不混用 | 同上 → `速度端点不混用` | `score_formulas.dart` 中出现 `0.50` / `0.80`（FF-21e）的命中数为 **0** |

**表 A-01-T3 算例输入记录与逐步推导（口径 = `FF-22` 公式 + `API-03 §5` 窗口，依据 `ADR-05` / `ADR-09`）**

> **可逐条核对**：每格给出记录 → 中间量 → 代入公式 → 四维分 → 总分。四维**先各自 `round()`（半值远离零）再求和**（`API-05 §6.2`），**不是先求和再取整**。
> 餐次归属按 `API-03 §5`：早餐 `[05:00,10:00)`、午餐 `[11:00,14:00)`、晚餐 `[17:00,21:00)`；**不落入任一正餐窗口**的记录计入 `snackCount`。
> `σ` 由 `API-03 §5.3` 给出（三餐各自**样本标准差**后取算术平均，样本数 <2 的餐类不采纳），**本域不重算**；下表给出该口径下的手算过程仅供核对。
> **夹具的比值刻意取浮点安全值**（`healthyRatio ∈ {0.10, 0.20, 0.25, 1.00}`）：`30 × min(1, p/0.4)` 在 `p = 0.30` 处受 IEEE-754 影响得到 `22.499999999999996`（`→ 22`），而 `30 × p / 0.4` 得到 `22.5`（`→ 23`）——**同一公式的两种等价写法会给出不同分数**，故算例一律避开 `.5` 边界，使断言与求值顺序无关。

**算例 A（四维全满分）——窗口 7 个本地日历日，共 6 条记录**

| 日期 | 本地时刻 | 类别 | 条数 | 餐次归属 |
|---|---|---|---|---|
| D1、D2 | 07:00 | `noodles` 面条 | 2 | 早餐（正餐） |
| D1、D2 | 12:00 | `carrot` 胡萝卜 | 2 | 午餐（正餐） |
| D1、D2 | 18:30 | `cabbage` 卷心菜 | 2 | 晚餐（正餐） |

- **σ**：早餐样本 `{420, 420}` → 标准差 `0`；午餐 `{720, 720}` → `0`；晚餐 `{1110, 1110}` → `0`。三样本数均 ≥2 → 全部采纳，`σ = (0 + 0 + 0) / 3 = 0`。
  → `regularity = 30 × max(0, 1 − 0/90) = 30` → `round(30) = 30`。
- **`p`**：`healthyCount = noodles 2 + carrot 2 + cabbage 2 = 6`，`totalCount = recordCount = 6` → `p = 6/6 = 1.00`。
  → `structure = 30 × min(1, 1.00/0.4) = 30 × min(1, 2.5) = 30` → `30`。
- **`n`**：正餐窗口外记录 `0` 条 → `n = 0`。→ `snack = 20 × max(0, 1 − 0/10) = 20` → `20`。
- **`t`**：`chewStats` 加权均值 `= 0.80 s`（命中 `t ≥ 0.8` 端点）→ `speed = 20` → `20`。
- **合计**：`totalScore = 30 + 30 + 20 + 20 = 100`；`grade = 良好`（`≥ 80` → 良好，`ADR-P2` / FF-22b）；`deltaVsYesterday = 100 − 92 = 8`。
- **证据**：`lateNightCount = 0`（无记录落在 `[20:00,05:00)`）。

**算例 B（下午加餐：`ADR-09` 新窗口生效）——窗口 7 个本地日历日，共 10 条记录**

| 日期 | 本地时刻 | 类别 | 条数 | 新窗口归属（`API-03 §5`） | 旧窗口（**已作废**） |
|---|---|---|---|---|---|
| D1、D2 | 07:00 | `noodles` 面条 | 2 | 早餐 | 早餐 |
| D3 | 07:00 | `gummies` 软糖 | 1 | 早餐 | 早餐 |
| D4 | 07:40 | `gummies` 软糖 | 1 | 早餐 | 早餐 |
| D1…D6 | 15:40 | `chips` 薯片 | 6 | **零食** `[14:00,17:00)` | 午餐正餐 `[11:00,16:00)` |

- **σ**：早餐样本 `{420, 420, 420, 460}` → 均值 `(420×3 + 460)/4 = 430`；离差 `−10, −10, −10, +30`；样本方差 `(100×3 + 900)/(4−1) = 400` → 标准差 `20`。午餐、晚餐各 `0` 条（<2）→ 不采纳。`σ = 20`。
  → `regularity = 30 × max(0, 1 − 20/90) = 30 × 70/90 = 23.333…` → `round(23.333…) = 23`。
- **`p`**：`healthyCount = noodles 2`（`gummies`、`chips` 不在 FF-22 的 `cabbage + carrot + noodles` 之内），`totalCount = 10` → `p = 2/10 = 0.20`。
  → `structure = 30 × min(1, 0.20/0.4) = 30 × min(1, 0.5) = 15` → `15`。
- **`n`**：15:40 的 6 条不落入任一正餐窗口 → `n = 6`。→ `snack = 20 × max(0, 1 − 6/10) = 20 × 0.4 = 8` → `8`。
  > 🔴 **这一格就是 `ADR-09` 要修的点**：按**已作废**的旧窗口（午 `[11:00,16:00)`），这 6 条会被判为午餐正餐 → `n = 0` → `snack = 20`，总分变成 `23+15+20+15 = 73`。验收必须锁定 `n = 6`、总分 `61`。
- **`t`**：加权均值 `= 0.70 s`（落在 `0.4 < t < 0.8`）→ `speed = 20 × (0.70 − 0.40)/0.4 = 15` → `15`。
- **合计**：`totalScore = 23 + 15 + 8 + 15 = 61`；`grade = 一般`（`60–79` → 一般，`ADR-P2` / FF-22b）。
- **证据**：`lateNightCount = 0`。

**算例 C（σ=30 的争议点 + 两个零分端点）——窗口 7 个本地日历日，共 20 条记录**

| 日期 | 本地时刻 | 类别 | 条数 | 餐次归属 |
|---|---|---|---|---|
| D1、D2 | 07:00 | `noodles` 面条 | 2 | 早餐（正餐） |
| D1、D2、D3 | 17:00 | `chips` 薯片 | 3 | 晚餐（正餐） |
| D4 | 19:00 | `chips` 薯片 | 1 | 晚餐（正餐） |
| D1…D7 各 2 条 | 15:40 | `chips` 薯片 | 14 | **零食** |

- **σ**：早餐样本 `{420, 420}` → 标准差 `0`；晚餐样本 `{1020, 1020, 1020, 1140}` → 均值 `(1020×3 + 1140)/4 = 1050`；离差 `−30, −30, −30, +90`；样本方差 `(900×3 + 8100)/(4−1) = 3600` → 标准差 `60`。午餐 `0` 条 → 不采纳。`σ = (0 + 60)/2 = 30`。
  → `regularity = 30 × max(0, 1 − 30/90) = 30 × 60/90 = 20` → **`20`**（`ADR-05`：**以公式为准**；旧散文「σ≤30 min 满分」作废。若断言 `30` 即为不符合本 SPEC）。
- **`p`**：`healthyCount = noodles 2`，`totalCount = 20` → `p = 2/20 = 0.10`。
  → `structure = 30 × min(1, 0.10/0.4) = 30 × 0.25 = 7.5` → `round(7.5) = 8`（半值远离零）。
- **`n`**：15:40 的 14 条 → `n = 14`。→ `snack = 20 × max(0, 1 − 14/10) = 20 × max(0, −0.4) = 0` → `0`（`max` 保证非负，§2.4 #6）。
- **`t`**：`= 0.40 s`（命中 `t ≤ 0.4` 端点）→ `speed = 0` → `0`。
- **合计**：`totalScore = 20 + 8 + 0 + 0 = 28`；`grade = 需改善`（`< 60` → 需改善，`ADR-P2` / FF-22b）；`deltaVsYesterday = null`（前一日无有效数据，**不得**用 `0` 顶替，`API-04 §3`）。
- **证据**：`lateNightCount = 0`（17:00 与 19:00 均早于 `20:00`）。

**算例 D（数据不足的空态：σ 与 t 均不可得）——窗口 7 个本地日历日，共 8 条记录**

| 日期 | 本地时刻 | 类别 | 条数 | 餐次归属 |
|---|---|---|---|---|
| D1 | 07:00 | `noodles` 面条 | 1 | 早餐（正餐） |
| D2 | 12:00 | `carrot` 胡萝卜 | 1 | 午餐（正餐） |
| D3 | 18:00 | `chips` 薯片 | 1 | 晚餐（正餐） |
| D1…D5 | 15:40 | `chips` 薯片 | 5 | **零食** |

- **σ**：早餐样本数 `1`、午餐样本数 `1`、晚餐样本数 `1` —— 三类**均 < 2** → **无采纳餐类** → `σ = null`（`API-03 §5.3`）。
  → `regularity = 0`（σ 不可得即 0 分，**不得**填 `0` 冒充 σ 后按满分算）；`evidence.sigmaMinutes = null`。
- **`p`**：`healthyCount = noodles 1 + carrot 1 = 2`，`totalCount = 8` → `p = 2/8 = 0.25`。
  → `structure = 30 × min(1, 0.25/0.4) = 30 × 0.625 = 18.75` → `round(18.75) = 19`。
- **`n`**：15:40 的 5 条 → `n = 5`。→ `snack = 20 × max(0, 1 − 5/10) = 20 × 0.5 = 10` → `10`。
- **`t`**：窗口内指标行全为占位（`avgChewIntervalSeconds == null`）→ `speed = 0`；`sampleCount = 0`、`missingMetricsCount = 8`。
- **合计**：`totalScore = 0 + 19 + 10 + 0 = 29`（**不是** `null`，§2.4 #1）；`grade = 需改善`；`deltaVsYesterday = null`。
- **UI**：`sigmaMinutes == null` 与 `avgChewIntervalSeconds == null` 同时成立 → 该两维**与总分/评级**均显示 `--`（§4 UI 判定表），**不显示 29**。

## 8. 非功能约束

> 性能 / 内存 / 功耗 / 隐私 / 无障碍，只写与本功能相关的。

- **性能**：Dart 主 isolate（`API-00 §3.7`「评分 / 报告计算」行）；单窗口只查一次聚合，遵守 `API-03 §5`「单次聚合查询 < 20 ms」与「禁止 N+1」。端到端耗时为**实测产出**（D7 起记录），本 SPEC 不预设数字。
- **内存**：只持有窗口级聚合对象与四维结果，无大数组、无音频缓冲。
- **隐私**：只读结构化字段；不接触音频、不写文件、无网络（`FF-24`、`API-05 §3` R-OUT-1/2）。
- **可复现**：`API-05 §6.1` 保命条款 —— 同一数据库 + 同一时间窗 → 同一分数；唯一时间依赖是**调用方传入的 `range`**。
- **无障碍**：四维必须带 `label` 供读屏；页面语义标签形如「今日健康评分 85 分，评级良好」（由 `U-01` 执行，本域只保证 `label` 与数值来源一致）。

## 9. 裁剪与未做

> 显式列出本功能相关的 `X-*` 裁剪项与推迟项，避免实现方"顺手也做了"。

| 项 | 决定 |
|---|---|
| **本功能不可裁剪** | 健康报告 + 评分卡是主方案 §8.2.1 五项「不可砍」之一（`00_功能清单` §6 ③）。**任何排期压力下不得降级为静态图片或写死数字。** |
| `X-02` 手动修正 | 不做。评分不接受用户手工改分/改类别；低置信度只走 `P-06` 二选一确认。 |
| `X-03` CSV 导出 | 不做。评分明细不导出，入口置灰标「v1.1」。 |
| `X-07` 咀嚼节律标准差 σ | 不做。`speed` 只用平均间隔 `t`。**注意**：本 SPEC 的 σ 是「三餐时间标准差」，与 `X-07` 的「咀嚼节律 σ」不是同一量，禁止实现方顺手把后者加进 `speed` 或 `evidence`。 |
| `X-06` RIR / Mixup | 不适用（训练侧 `T-03`）。 |
| 推迟项 | 营养素维度评分、长期趋势预测、LLM 健康助手：**不做**（`00_功能清单` §5；`API-05 §9` 状态 `DISABLED`，不得作为任务来源）。 |

## 10. 开放问题

> 本节只登记**仍开放**的事项；已冻结项不再列入（`FF-11` 的 `n_frames` 于 **2026-09-10** 由 `ADR-P1` 冻结为 ~~`129`~~ → **`ADR-21`（2026-09-12）已修订为 `n_frames = 128`**，`129` 现为 `raw_mel_frames`，故不再作为本节示例）。无则写「无」。

| 编号 | 问题 | 影响 | 谁拍板 / 截止 |
|---|---|---|---|
| OQ-A01-1 | ✅ **已关闭（依据 `ADR-05`；`ADR` §2.1 已复核签字）**：FF-22 的 `regularity` **公式**（σ=30 → 20 分）与同行散文**端点描述**（σ≤30 → 满分）矛盾一事已有裁定 —— **以公式为准、散文作废**，端点统一为 `σ=0→30`、`σ=30→20`、`σ=60→10`、`σ≥90→0`（连续线性衰减、无平台段）。**结论：`σ=30` 得 20 分**，§7 算例 C 与下钻公式串按此冻结 | 决定 §7 算例 C 期望值与下钻公式串 | ✅ 已裁定（`ADR-05`），无需再签字 |
| OQ-A01-2 | ✅ **已关闭（依据 `ADR-06` 修订 A-1）**：`StatsRepo` 已**纯新增** `summary(DateRange)` / `chewStats(DateRange)` → `ChewStats{sampleCount, meanChewIntervalSeconds}` / `mealTimeSamples(DateRange)` / `activeDays()`（`API-03` §4/§5/§11.1），且 `DietRepo` 已新增 `metricsByRecordId`。**`speed` 与 `regularity` 的证据填充由此获得数据源**；`missingMetricsCount` 由 `ChewStats.sampleCount` 与窗口记录数之差推出 | 曾阻断 `speed` 与 `regularity` 证据填充 | ✅ 已裁定（`ADR-06` 修订 A-1），无需再签字 |
| OQ-A01-3 | ✅ **已关闭（`ADR-P2`，2026-09-10）**：分档阈值曾无 FF 依据（`API-04 §9` OQ-1 建议同值）。**裁定：`总分 ≥ 80 → 良好`；`60–79 → 一般`；`总分 < 60 → 需改善`** —— 已登记为 `SPEC-00` §3.7 **FF-22b**，机器可读值在 `feature_config.health_score_formula.grade_thresholds`（`good_min = 80` / `fair_min = 60`），消费方为 `API-04` 的 `HealthScore.grade` 与 `U-01`/`U-04` 的评级展示（与 `1.png` 的「85 分 = 良好」一致）。§5 A-01-K1 与 §7 算例按此冻结 | 影响 `grade` 与 UI 颜色 | ✅ 已裁定（`ADR-P2`），无需再签字 |
| OQ-A01-4 | ✅ **已关闭（依据 `ADR-10`）**：`deltaVsYesterday` 的三态语义已冻结 —— `null` = 昨日**无有效数据**（**隐藏该行**）；**`0` = 昨日有数据且确实持平（必须显示「持平」，不得隐藏）**；其余为实际差值。`SPEC-U-01` / `SPEC-U-04` / `SPEC-U-06` 已同步；`API-04` §3 的字段定义已写明三态 | 曾为语义不一致 | ✅ 已裁定（`ADR-10`），无需再签字 |
| OQ-A01-5 | `speed` 加权口径（A-01-K3）采纳 `API-04 §9` OQ-3 的「按 `durationSeconds` 加权」——`API-04` 声明须由本 SPEC 确认 | 影响 `t` 与 `speed` 分 | 本 SPEC 已确认采纳；若 `P-07` 另有口径须在 D6 前提出 |
| OQ-A01-6 | ✅ **已关闭（依据 `ADR-09`；`ADR` §2.1 已复核签字）**：餐次窗口以 `API-03 §5` 为**唯一权威** —— 早餐 `[05:00,10:00)` / 午餐 `[11:00,14:00)` / 晚餐 `[17:00,21:00)`（正餐）；零食 = 其余时段 `[10:00,11:00)` ∪ `[14:00,17:00)` ∪ `[21:00,05:00)`（计入 `snackCount`）；晚间 = `[20:00,05:00)`（计入 `lateNightCount`）。**零食与晚间刻意允许重叠，不得「去重」**。原窗口（早 `[05,11)` / 午 `[11,16)` / 晚 `[16,23)`）**已作废**：它使零食窗口只剩 `[23,05)`、与晚间完全重合，令 `snack` 维度失去区分度，且会把 15:40 的下午加餐判为午餐正餐。**结论：σ 与 `snackCount` 均按新窗口口径**，§7 算例 B/C/D 已按此重算 | `snack`/`regularity` 分数随窗口改变 | ✅ 已裁定（`ADR-09`），无需再签字 |

**文档结束**

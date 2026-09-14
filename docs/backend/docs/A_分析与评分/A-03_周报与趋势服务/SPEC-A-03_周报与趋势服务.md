# SPEC-A-03 周报与趋势服务

| 项 | 值 |
|---|---|
| 域 | A · 分析与评分 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1（报告页数据源：7 天趋势折线、四维下钻、本周小结）、§3.4.2（「近 7 天」改「本周」）、§9.1（周报文案与数据吻合）；`SPEC-00 §3.10 FF-25`、`§3.9 FF-24`；**`API-04 §5`（`WeeklyReport`/`ReportService` 权威）**、`API-03 §4/§5`（`DateRange`、`TrendPoint`、聚合权威）、`API-05 §6.1/§6.2`、`docs/common/docs_api/schemas/health_score.schema.json`（`weeklyReport`/`trendPoint` 子模式） |
| 依赖的 SPEC | `SPEC-A-01`（四维评分）、`SPEC-A-02`（建议）、`SPEC-D-03`（聚合实现）、`SPEC-C-05`；下游 `SPEC-U-04`、`SPEC-M-03` |

## 1. 目标与范围

### 1.1 一句话目标

提供 `ReportService.weekly()` 与 `ReportService.trend()`：前者输出**环比数字全部由真实数据算出**的小结文案 + 四维下钻 + 建议列表 + 环比差值；后者输出**连续、可空、可上屏**的 N 天趋势序列并在 L4 补齐每日总分。

### 1.2 范围内（In Scope）

- `WeeklyReport{range, summaryText, advices, score, deltas}` 的组装与 `summaryText` 生成（含环比百分比）。
- `TrendSeries{points[]}`：`date` / `estimatedKcal?` / `totalScore?`，序列**连续补点**、按日升序，`totalScore` 由本服务在 L4 填充（`API-03 §5` 的 L3 恒为 `null`）。
- 四维下钻数据：直接透传 `SPEC-A-01` 的 `HealthScore`（含 `evidence`）。
- 无数据时的**确定性**空态：空图 + 全 `null` 点序列 + 冻结提示语（`API-04 §5`）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

- **不写 SQL、不做聚合**：日分组、估算热量、记录数、类别计数一律来自 `StatsRepo`（`SPEC-D-03`、`API-03 §5`）。
- **不重算评分**：四维分与总分只来自 `SPEC-A-01`；本域不得出现 FF-22 公式的第二次实现。
- **不重算建议**：`advices` 只来自 `SPEC-A-02`（含 `general` 免责声明项）；本域不新增规则、不改写文案。
- 不做知识库热量查表（`P-08`）、不做日期/数字格式化（`U-04` 负责，`summaryText` 是 `API-00 §3.2` 的唯一例外）、不做导出（`X-03`）。
- 不做趋势预测 / 时序模型 / 云端同步（`00_功能清单` §5 推迟项；`API-05 §9` 状态 `DISABLED`，不得作为任务来源）。
- 不产出任何网络调用（`FF-24` 第 4 条）。

## 2. 功能行为

### 2.1 触发与前置条件

| # | 前置条件 | 来源 |
|---|---|---|
| 1 | 有效数据集已确定（演示模式下聚合只含 `source == 'demo'`） | `SPEC-A-04` |
| 2 | `weekly(range)`：`range` 由 `U-04` 传入（左闭右开，本地日历日边界） | `API-03 §4` |
| 3 | `trend(days)`：页面固定 `days = 7`；契约允许 `[1,365]` | `API-04 §5` |
| 4 | 上一等长窗口的聚合可经 `StatsRepo` 取得（`ADR-06` 修订 A-1 新增 `summary(DateRange)`；§10 OQ-A03-1 已关闭） | `API-03 §5` |

### 2.2 主流程（编号步骤）

**A. `weekly(range)`**

1. 校验 `range`：`endMs > startMs`、跨度 ∈ [1, 31] 天；越界 → `ACD-DB-004`；**不读系统时钟**。
2. 求上一窗口 `prevRange`：与 `range` **等长**、紧邻其前（A-03-K1，纯算术）。
3. 取本周聚合与评分：`agg = StatsRepo.summary(range)`（`ADR-06` 修订 A-1；`week()` 为无参便捷包装，**不接受 `DateRange`**。**同一窗口只读一次**，`API-04 §5`）、`score = HealthScoreService.score(range)`（`SPEC-A-01`）。
4. 取上周聚合 `prevAgg`；不可得 → `prevAgg = null`（触发 §2.4 #2 分支）。
5. 计算 `deltas`：**恰含 A-03-K2 的 7 个键**；某项无对比基准 → 该键值 `0`（数值型，**不是** `null`，`API-04 §5`）。
6. 生成 `summaryText`：按 A-03-T1 模板拼接；环比子句仅在 `prevAgg != null` 且对应字段 > 0 时出现，百分比按 A-03-K1 计算并 `round`。
7. `advices = AdviceEngine.generate(score: score, agg: agg)`（`SPEC-A-02`；含 `general` 项）。
8. 组装并返回 `WeeklyReport`。无随机、无时钟读取。

**B. `trend(days)`**

1. 校验 `days` ∈ [1, 365]；越界 → `ACD-DB-004`。
2. 经 `StatsRepo.trend(days)` 取日聚合（`estimatedKcal` 与 `date`）。
3. 对**每个有记录的日期**在 L4 填充 `totalScore`（调用 `SPEC-A-01` 对该日窗口评分）；不可计算 → `null`（`API-03 §5`：L3 不填充）。
4. 组装 `TrendPoint{date, estimatedKcal, totalScore}`；无记录的日期两个值均为 `null`（**不得**填 0：`0` 与「无记录」语义不同）。
5. 序列必须覆盖连续 `days` 个本地日历日（由 `date` 连续性保证），按日升序。
6. 返回 `TrendSeries`。

### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）

**无状态**。同一入参重复调用必须返回逐字段（含 `summaryText` 字符串）相同结果（`API-05 §6.1`）。

### 2.4 边界条件

| # | 场景 | 处理（确定性） |
|---|---|---|
| 1 | 本周无记录 | `score` 按 `SPEC-A-01 §2.4` 确定性给出；`summaryText = A-03-K4`；`deltas` 仍含 7 键（值为 0）；`trend` 全 `null` 点 |
| 2 | 上周不可得或为 0 记录 | `deltas` 全 0（无对比基准）；`summaryText` **不含任何 `%`** |
| 3 | 上周某字段为 0（但窗口非空） | 该子句按 A-03-K1 分支写「上周无同类记录可比」，**不除零** |
| 4 | 某日只有占位指标行 | 该日 `totalScore` 按 `SPEC-A-01` 计算（该维可能为空态）；`estimatedKcal` 照常 |
| 5 | 估算热量 | `estimatedKcal` 为知识库估算合计（点估计）；`U-04` **必须**渲染为区间并标注「估算」（`API-05 §6.2`、`FF-25`） |
| 6 | 演示数据集生效 | 报告页必须同时显示「演示数据」标识（`SPEC-A-04`） |
| 7 | 7 天趋势 vs 自然周 | 取**滚动 N 天**数据，`U-04` 标题统一为「本周」（采纳 `SPEC-U-04 §10` OQ-1 的处置，本 SPEC 与之保持一致） |

## 3. 接口契约

> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准，此处给「本功能用到的部分」并标注 API 编号。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5 → L4 | `ReportService.weekly` | `{required DateRange range}` | `Future<WeeklyReport>` | `ACD-DB-003/004`、`ACD-SCORE-001`、`ACD-UNK-000` |
| L5 → L4 | `ReportService.trend` | `{required int days}`（`[1,365]`） | `Future<TrendSeries>` | `ACD-DB-003/004`、`ACD-SCORE-001` |
| L4 → L4 | `HealthScoreService.score` | `DateRange` | `HealthScore` | 见 `SPEC-A-01 §3` |
| L4 → L4 | `AdviceEngine.generate` | `HealthScore` + `WeekSummary` | `List<Advice>`（含 `general`） | 见 `SPEC-A-02 §3` |
| L4 → L3 | `StatsRepo.trend(days)` / `StatsRepo.summary(range)` | `int` / `DateRange` | `List<TrendPoint>` / `WeekSummary` | `ACD-DB-003/004` 透传不吞 |
| L4 → L5 | `WeeklyReport` / `TrendSeries` | — | 见 §4 | — |

**权威归属**：`WeeklyReport`/`TrendSeries` 字段、`deltas` 键集与 `summaryText` 语义以 `API-04 §5` + `health_score.schema.json` 为准；本 SPEC 只补充文案模板、常量与验收。`weekly` **单次调用内只读一次库**（不得对同窗口重复查询）。

## 4. 数据契约

> 涉及的字段、类型、单位、值域、可空性。引用 `docs/common/docs_api/schemas/` 中的 schema 文件名。

- **输出结构**：`docs/common/docs_api/schemas/health_score.schema.json` 的 `weeklyReport` 与 `trendPoint` 子模式（`additionalProperties: false`）。
- **`deltas`（`API-04 §5` 冻结，恰 7 键，全部为数值）**：`totalScore`、`regularity`、`structure`、`snack`、`speed`、`recordCount`、`estimatedKcal`；语义 = 本期 − 上一等长窗口的**差值（不是比率）**；无对比基准 → `0`。
  > ⚠️ 与 `SPEC-U-04 §2.2`（「`deltas` 为空时隐藏环比」「显示`零食次数 ↓20%`」）**不一致**：schema 不允许 `deltas` 为空，且 `snackCount` 不是 `deltas` 键。冲突处置见 §10 OQ-A03-2（✅ 已关闭，`ADR-10`）。
- **`TrendPoint`**：`date`（`yyyy-MM-dd`，设备本地时区）、`estimatedKcal`（`int?`，无记录为 `null`）、`totalScore`（`int?`，L4 填充，不可计算为 `null`）。
- **`summaryText`**：`String`，≤ 60 字，域层**唯一允许产出**的文案字段（`API-00 §3.2` 例外）；数据不足时**必须**逐字等于 A-03-K4，不得编造数字。
- **`advices`**：直接来自 `SPEC-A-02`，含恰好一条 `dimension == 'general'` 的免责声明项（`API-04 §4`）；本域不得增删或改写。
- **`score`**：直接来自 `SPEC-A-01`，本域不得改写任何分数（含四维与 `evidence`）。

**表 A-03-T1 `summaryText` 模板（唯一来源）**

| # | 子句 | 触发 | 示例（数字来自真实字段） |
|---|---|---|---|
| 1 | `本周记录 {recordCount} 次` | `recordCount > 0` | `本周记录 21 次` |
| 2 | `，零食 {snackCount} 次` | `snackCount > 0` | `，零食 6 次` |
| 3 | `，较上周 +{pct}%` / `，较上周 −{pct}%` | 上周同字段 > 0 | `，较上周 +20%` |
| 4 | `，上周无同类记录可比` | 上周该字段为 0 | `，上周无同类记录可比` |
| 5 | `，本周评分 {totalScore} 分（{grade}）` | 四维有可用数据 | `，本周评分 61 分（一般）`（`ADR-09` 新窗口；旧窗口下为 73，已作废） |
| 6 | A-03-K4 固定提示语 | 本周 `recordCount == 0` | 见 §5 A-03-K4 |

> **`snackCount` 的口径**：一律取 `API-03 §5` 的**零食窗口**（`ADR-09` 新窗口；**本 SPEC 不复制边界值**，边界只在 `API-03 §5` 定义一次）；本表与 `summary_text.dart` **均不得自带一份窗口常量**。典型后果：**15:40 的下午加餐计入零食**（已作废的旧窗口会把它判为午餐正餐 → `snackCount` 恒为 0）。
> **禁止**：任何硬编码展示数字、任何不在本表内的子句、任何未由 `deltas`/`WeekSummary`/`HealthScore` 推出的百分比。

## 5. 参数与常量

> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。

**FF / API 引用表**

| 引用 | 用途 |
|---|---|
| `FF-25` | 热量只能以**估算区间**出现并标注「估算」；禁止孤立精确热量数字 |
| `FF-24` | 无网络、无音频、只读结构化字段 |
| `FF-19` | 类别表（估算热量与类别计数映射） |
| `API-05 §6.2` | 估算能量 ±20% 区间与 `int` kcal 舍入；四维各自 `round` 后求和 |
| `API-05 §6.1` | 可复现：同库同窗 → 同结果；禁止「当前时间」判据 |
| `API-00 §3.2` | 日期分组按设备本地时区日历日 `yyyy-MM-dd` |
| `API-04 §5` | `deltas` 7 键与 0 默认；`summaryText` 空态文案；`weekly` 单次只读一次库；L4 填充 `totalScore` |
| `API-03 §5`（`ADR-09`） | 零食 / 晚间餐次窗口的**唯一权威**；`WeekSummary.snackCount` 与子句 2/3 的口径来源 |

**表 A-03-T2 本域新增/冻结常量（FF 未定义者，待 A/B/C 确认，见 §10）**

| 编号 | 常量 | 取值 | 说明 |
|---|---|---|---|
| A-03-K1 | 环比公式与窗口 | `pct = round((cur − prev) / prev × 100)`；`prev == 0` → 走模板子句 4，**不除零**；`prevRange` 与 `range` 等长紧邻 | 数字由真实数据算出（主方案 §9.1） |
| A-03-K2 | `deltas` 键集 | 恰 7 键（§4），无基准 → `0` | 直接采纳 `API-04 §5`，本 SPEC 不扩展 |
| A-03-K3 | `days` 值域 | `[1, 365]`（页面固定用 7） | 与 `API-04 §5`、`API-03 §5` 一致；越界 `ACD-DB-004` |
| A-03-K4 | 空态文案（**冻结**） | `数据不足，继续记录即可看到趋势` | 逐字来自 `API-04 §5` |
| A-03-K5 | 序列补点规则 | 连续 `days` 日、升序、缺失日 `null` 点 | 保证折线 x 轴等距、无跳日 |
| A-03-K6 | 估算热量上屏口径 | 点估计 `x` → `U-04` 渲染 `约 {round(0.8x)}–{round(1.2x)} kcal`（`API-05 §6.2`） | `FF-25` 硬要求；区间拼装属展示层 |
| A-03-K7 | 数据不足阈值 | `recordCount < 3` → 报告页 `insufficient` | **与 `SPEC-A-01 §5` A-01-K4 同值同源**（`SPEC-U-04 §6` 要求「阈值与 A-03 对齐」） |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `range` / `days` 非法 | 入参校验 | 抛 `ACD-DB-004`，不查库 | 页面错误态 |
| 本周无记录 | `recordCount == 0` | `summaryText = A-03-K4`；`deltas` 全 0；`trend` 全 `null` | 空图 + 提示文案 |
| 上周聚合不可得（`summary(prevRange)` 空窗口） | `prevAgg == null` | `deltas` 全 0；文案不含 `%` | 环比区块显示 `--`（`U-04`） |
| 上周某字段为 0 | `prev == 0` | 用模板子句 4 | `上周无同类记录可比` |
| 某日评分不可算 | `SCORE` 抛错/返回空态 | 该点 `totalScore = null`，其余点照常 | 折线断点（不整页失败） |
| 每日评分抛错 | `ACD-SCORE-001` | 该点 `null`，不中断整条序列 | 同上 |
| 数据库读失败 | `ACD-DB-003` | 透传不吞 | 页面错误态 + 重试入口 |
| 演示数据集生效 | 载入演示数据 | 只统计 `source == 'demo'` | 页面顶部「演示数据」标识 |
| 估算热量缺失 | `estimatedKcal == null` | 该点 `null` | 该点只显示分数，不显示能量 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 环比百分比由真实数据算出 | `flutter test app/test/domain/weekly_report_test.dart` → `环比_零食5到6为加20` | **夹具按 `API-03 §5` 新窗口构造（`ADR-09`）**：上周 **5 条 15:40 加餐** → `prev.snackCount = 5`；本周 **6 条 15:40 加餐** → `cur.snackCount = 6`。`pct = round((6 − 5)/5 × 100) = 20` → `summaryText` 含 `+20%`（**该数字必须由 A-03-K1 算式得出，禁止硬编码**）；`deltas` 7 键齐全。⚠️ 若误用已作废的旧窗口（午 `[11:00,16:00)`），15:40 会被判为午餐正餐 → 两周 `snackCount` 均为 0 → 子句 2/3 都不出现，本判据必须失败 |
| 2 | 无基准时不用百分比且不除零 | 同上 → `无基准_不用百分比` | `prevAgg == null` 或上周该字段为 0 → `summaryText` 不含 `%`；`deltas` 全部键存在且值为 `0`（**不是** `null`） |
| 3 | 20 组固定输入的文案逐字一致 | 同上 → `文案逐字_20组` | 20 组预置输入（含 3 组负向环比、2 组「上周为 0」、2 组空态）全部逐字相等；差异字段数 == 0 |
| 4 | `deltas` 键集恰为 7 个 | 同上 → `deltas键集_恰七键` | 键集合 == A-03-K2；多键/缺键均失败（schema `additionalProperties:false`） |
| 5 | 趋势序列长度、连续性、格式 | `flutter test app/test/domain/trend_series_test.dart` → `七天序列_连续升序` | `days = 7` → `points.length == 7`；日期两两相差 1 天；全部匹配 `^\d{4}-\d{2}-\d{2}$` |
| 6 | `totalScore` 由 L4 填充、无记录日为 `null` | 同上 → `L4填充总分与空日` | `StatsRepo.trend` 原值 `totalScore == null`；本服务输出中**有记录的日** `totalScore != null` 且等于 `SPEC-A-01` 对该日的评分；无记录日两字段均 `null` |
| 7 | 四维下钻数据 == `SPEC-A-01` 输出 | `flutter test app/test/domain/report_down_drill_test.dart` | `report.score` 与直接调用 `HealthScoreService.score(range)` 的结果逐字段（含 `evidence` 键集）相等 |
| 8 | **跨功能一致性（PLAN-C-05）**：报告数字 == UI 显示数字 | `flutter test app/test/domain/health_score_consistency_test.dart` + `app/test/ui/report_render_test.dart`（`SPEC-C-05 §5` #1/#3） | `U-04` presenter 输出的总分、四维 `score/max`、`deltas`、`summaryText` 中每个数字与 `WeeklyReport` 字段**逐字段相等**，差异字段数 == 0 |
| 9 | 热量不孤立出现 | 同上 → `热量必须是估算区间` | UI 字符串匹配 `约 \d+–\d+ kcal` 且含「估算」；裸 `\d+ kcal` 命中 0 |
| 10 | 无硬编码展示数字 | `flutter test app/test/domain/report_no_hardcode_test.dart` | `app/lib/domain/report/**.dart` 源文本中不存在三位以上数字字面量（`yyyy-MM-dd` 与 `±20%` 常量白名单除外） |
| 11 | 纯函数性 | `flutter test app/test/domain/score_reproducibility_test.dart`（`SPEC-C-05 §5` #18） | 同库同参两次结果全等（含 `summaryText`）；源文本中 `DateTime.now`/`Random(`/`http`/`dio` 命中数各为 **0** |
| 12 | 免责声明随 `advices` 传递且不重复注入 | `flutter test app/test/domain/report_advice_passthrough_test.dart` | `advices` 与 `AdviceEngine.generate` 输出逐字段相等；恰 1 条 `general` 项且位于末位 |

## 8. 非功能约束

> 性能 / 内存 / 功耗 / 隐私 / 无障碍，只写与本功能相关的。

- **性能**：Dart 主 isolate（`API-00 §3.7`「评分 / 报告计算」行）；`weekly` 触发 1 次本周评分（+ 上周，经 `summary(DateRange)`，`ADR-06` 修订 A-1）+ 1 次建议生成，`trend(7)` 触发最多 7 次日内评分；遵守 `API-03 §5` 的单次聚合查询约束与「禁止 N+1」。端到端耗时为**实测产出**，本 SPEC 不预设数字。
- **内存**：仅持有 N 个趋势点与窗口级聚合对象；不缓存历史报告。
- **隐私**：只读结构化字段；报告不含音频、不含定位、无网络（`FF-24`、`API-05 §3` R-OUT-2）。
- **可复现**：同库同窗同 `days` → 同文本同数字；`summaryText` 必须在测试中逐字锁定。
- **无障碍**：`TrendSeries` 必须提供逐点 `date` + 数值供 `U-04` 生成文本替代（形如「本周趋势：周一 1100 千卡，周二 1200 千卡，周三无数据……」）；折线不得是唯一信息载体。

## 9. 裁剪与未做

> 显式列出本功能相关的 `X-*` 裁剪项与推迟项，避免实现方"顺手也做了"。

| 项 | 决定 |
|---|---|
| **本功能不可裁剪** | 健康报告（周报 + 趋势）是主方案 §8.2.1 第 ③ 项「不可砍」范围（`00_功能清单` §6 列 `A-01`~`A-03`）。**不得把趋势图降级为静态截图、不得写死周报文案。** |
| `X-03` CSV 导出 | 不做。周报与趋势不导出，入口置灰标「v1.1」。 |
| `X-05` 检测页识别历史列表 | 不做。趋势数据只服务报告页，不得被检测页复用为历史列表。 |
| `X-07` 咀嚼节律 σ | 不做。周报不展示节律类统计。 |
| 推迟项 | 趋势预测 / 时序模型 / 健康数据融合（运动、睡眠、体重）/ 云端同步一律**不做**（`00_功能清单` §5；`API-05 §9` `DISABLED`）。 |

## 10. 开放问题

> 本节只登记**仍开放**的事项；已冻结项不再列入（`FF-11` 的 `n_frames` 于 **2026-09-10** 由 `ADR-P1` 冻结为 ~~`129`~~ → **`ADR-21`（2026-09-12）已修订为 `n_frames = 128`**，`129` 现为 `raw_mel_frames`，故不再作为本节示例）。无则写「无」。

| 编号 | 问题 | 影响 | 谁拍板 / 截止 |
|---|---|---|---|
| OQ-A03-1 | ✅ **已关闭（`ADR-06` 修订 A-1）**：原问题为 `StatsRepo.week()` 不接受 `DateRange`、`weekly(range)`/`trend(days)`/`score(range)` 取不到任意窗口与上一窗口。**结论**：`StatsRepo` 已新增 `summary(DateRange)`；`week()` 定义为 `summary(最近 7 个本地日历日窗口)` 的便捷包装（签名不变），并补等价性断言 | `deltas` 的 7 键与 `totalScore` 填充**均可由冻结接口推出**，无需降级为全 0 | ✅ 已冻结于 `API-03` §4/§5/§11.1 |
| OQ-A03-1b | ✅ **已关闭（`ADR-10`）**：原问题为 `days` 值域三处不一致（`API-04 §5`/`API-03 §5` 为 `[1,365]`，`SPEC-D-03 §3` 为 `[1,90]`）。**结论**：跨层契约以接口层为准，`days ∈ [1,365]`，越界抛 `ACD-DB-004`（**不是** `ArgumentError`） | 越界行为与测试期望已统一 | ✅ 已冻结（`API-04 §5`/`API-03 §5` 为准） |
| OQ-A03-2 | ✅ **已关闭（`ADR-10`）**：原问题为 `SPEC-U-04 §2.2` 的「`deltas` 为空时隐藏环比」与 schema/`API-04 §5` 冲突。**结论**：`deltas` **恒含 7 键**，无基准填 `0`（不是 `null`、不缺键）；`TrendPoint.totalScore` 由 L4 的 `ReportService` 填充，**L3 恒为 `null`** | 报告页环比区块与趋势纵轴的实现方式已确定 | ✅ 已冻结（`API-04 §5`/`API-03 §5`） |
| OQ-A03-3 | 「上周」定义：等长紧邻窗口（A-03-K1）还是自然周 | 影响环比数字与 `U-04` 文案 | C 主提，B 确认，D8 前 |
| OQ-A03-4 | 7 天趋势 vs 自然周的措辞：已按 `SPEC-U-04 §10` OQ-1 的处置取滚动 N 天 + 标题「本周」 | 若无异议则关闭 | C，D8 前 |
| OQ-A03-5 | `trend(7)` 每日各调一次评分（最多 7 次）在真机上的实际耗时未测 | 若超预期需改契约（只算 `totalScore`、不生成 `evidence`） | C，D8 实测后 |
| OQ-A03-6 | `estimatedKcal` 的 `KcalResolver`（`API-03 §3.2`）在按窗口聚合时的注入路径未在 `SPEC-D-03` 冻结 | 影响 `deltas.estimatedKcal` 与趋势纵轴 | B，D6 前 |

**文档结束**

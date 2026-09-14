# PLAN-A-03 周报与趋势服务

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-A-03 |
| 负责 | **C（主责）**；B 协助（`StatsRepo` 的 `summary(DateRange)` 按窗口聚合与日序列，`ADR-06` 修订 A-1；`SPEC-A-03 §10` OQ-A03-6） |
| 目标日 | **D8**（CP4 判据在 D7 晚先做一次预检） |
| 前置依赖 | `PLAN-A-01`（四维评分）、`PLAN-A-02`（建议）、`PLAN-D-03`（按窗口聚合与 `trend`）、`PLAN-U-04`（报告页 presenter）、`PLAN-U-06`（折线组件）；签字项：无（`SPEC-A-03 §10` OQ-A03-1/1b/2 已关闭，`ADR-06` 修订 A-1 / `ADR-10`） |
| 预估工时 | **5 人时**（0.6 人日） |

## 1. 交付物（Deliverables）

> 逐项列出**文件路径级**的产物，能点开验收。

| # | 产物 | 验收方式 |
|---|---|---|
| 1 | `app/lib/domain/report/report_models.dart` | `WeeklyReport` / `TrendSeries` + JSON 往返；对 `docs/common/docs_api/schemas/health_score.schema.json` 的 `weeklyReport`/`trendPoint` 子模式校验通过 |
| 2 | `app/lib/domain/report/summary_text.dart` | A-03-T1 模板与 A-03-K1/K2/K4 常量（文案唯一来源） |
| 3 | `app/lib/domain/report/report_service.dart` | `ReportService.weekly` / `ReportService.trend`（含 L4 填充 `totalScore`） |
| 4 | `app/test/domain/weekly_report_test.dart` | 环比 5→6 = +20%（夹具为 15:40 加餐，按 `API-03 §5` 新窗口计入 `snackCount`，`ADR-09`）、无基准不除零、20 组逐字、`deltas` 恰 7 键 |
| 5 | `app/test/domain/trend_series_test.dart` | 7 点连续升序、L4 填充总分、空日两字段 `null` |
| 6 | `app/test/domain/report_down_drill_test.dart` | 四维下钻 == `HealthScoreService` 输出（含 `evidence`） |
| 7 | `app/test/domain/report_no_hardcode_test.dart` | 源文本无三位以上数字字面量 |
| 8 | `app/test/domain/report_advice_passthrough_test.dart` | `advices` 与 `A-02` 输出逐字段相等、`general` 项恰 1 条且末位 |
| 9 | `app/test/ui/report_render_test.dart` | 报告页 widget 渲染 == 服务值（`SPEC-C-05 §5` #3 同源） |
| 10 | `docs/evidence/PLAN-A-03_周报自检.md` | 逐条贴命令与输出；真机耗时标注「实测产出」 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 冻结 `WeeklyReport`/`TrendSeries` 模型与 `deltas` 7 键（对齐 `API-04 §5`） | 交付物 1 | 0.5 h | `API-04 §5` |
| 2 | 实现 `summaryText` 模板与环比（含不除零/无基准分支） | 交付物 2 | 1.0 h | OQ-A03-3 |
| 3 | 实现 `trend`：连续补点 + L4 填充 `totalScore` | 交付物 3（trend） | 1.0 h | `PLAN-D-03` |
| 4 | 实现 `weekly` 组装（本周/上周聚合 + 评分 + 建议 + deltas） | 交付物 3（weekly） | — | 任务 1、2 |
| 5 | 写单元/补点/下钻/无硬编码/透传测试 | 交付物 4~8 | 1.5 h | 任务 2、3 |
| 6 | `U-04` 报告页联调与渲染测试、证据归档 | 交付物 9、10 | 1.0 h | `PLAN-U-04` |

## 3. 技术方案

> 实现路径、关键代码骨架、算法步骤。**必须与 SPEC 的契约一致，不得另立参数。**

**分层**：`ReportService` 只做「取数 → 组装 → 拼文案」，**不含聚合 SQL、不含评分公式、不改写建议**。文案拼装独立成 `summary_text.dart`（纯函数、可单测），便于 `summaryText` 逐字锁定。

```dart
// summary_text.dart —— 文案唯一来源（模板子句见 SPEC-A-03 §4 表 A-03-T1）
String buildSummaryText({
  required WeekSummary cur,
  required WeekSummary? prev,
  required HealthScore score,
}) {
  if (cur.recordCount == 0) return kEmptySummaryText;         // A-03-K4：API-04 §5 逐字
  final b = StringBuffer('本周记录 ${cur.recordCount} 次');
  if (cur.snackCount > 0) b.write('，零食 ${cur.snackCount} 次');
  b.write(_deltaClause(cur.snackCount, prev?.snackCount));     // 子句 3/4，prev<=0 时禁用百分比
  if (score.sufficientForDisplay) b.write('，本周评分 ${score.totalScore} 分（${score.grade}）');
  return b.toString();
}

// report_service.dart
class ReportService {
  Future<WeeklyReport> weekly({required DateRange range}) async { /* 本周/上周各读一次 summary(range) + 评分 + 建议 */ }
  Future<TrendSeries> trend({required int days}) async { /* 日序列补点 + L4 填充 totalScore */ }
}
```

**实现要点**：
1. 环比百分比只允许在 `_deltaClause` 一处计算；`prev == null || prev <= 0` → 返回子句 4，**不得**出现除法。
2. `prevRange` 与 `range` **等长紧邻**（A-03-K1），由 `range` 纯算术推出；禁止读系统时钟。
3. `deltas` **恒含 7 键**，无基准写 `0`（不是 `null`、不是缺键）；键集与 `API-04 §5` 逐字一致。
4. `trend` 的日期序列由 `days` 与窗口终点纯算术推出；缺失日生成 `null` 点，**不得**跳过或填 0；`totalScore` 在 L4 逐日填充（`API-03 §5` 的 L3 恒 `null`）。
5. 报告层**禁止**出现 `estimatedKcal` 的 UI 格式化（区间拼装属 `U-04`；本域只给点估计 + `API-05 §6.2` 引用）。
6. `weekly` 对同一窗口**只读一次库**（`API-04 §5`）；跨窗口读取次数 ≤ 2。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `weekly_report_test.dart` | 单元 | 5→6 得 `+20%`（两周夹具均为 15:40 加餐，`snackCount` 由 `API-03 §5` **新窗口**计得；旧窗口下两周均为 0，测试须锁定新值，`ADR-09`）；无基准/上周为 0 不用 `%`；20 组逐字；`deltas` 恰 7 键且无基准为 0 | 每次改文案模板后 |
| `trend_series_test.dart` | 单元 | 7 点连续升序；L4 填充 `totalScore` 且与 `SPEC-A-01` 一致；空日两字段 `null` | 同上 |
| `report_down_drill_test.dart` | 单元 | 四维下钻逐字段等于 `HealthScoreService` 输出（含 `evidence` 键集） | D8 |
| `report_no_hardcode_test.dart` | 静态 | `app/lib/domain/report/**.dart` 无三位以上数字字面量 | 提交前 |
| `report_advice_passthrough_test.dart` | 单元 | `advices` 与 `A-02` 输出全等；`general` 项恰 1 条且末位 | D8 |
| `report_render_test.dart` | Widget | 渲染数字 == 服务值；`--` 与空态文案符合 `SPEC-U-04 §2.4` | 提交前 / D8 |
| `health_score_consistency_test.dart` | **跨功能** | 报告/首页/下钻三处数字逐字段相等（差异字段数 == 0） | D7 预检、D8、D9 |
| `flutter test` 全量 | 回归 | 退出码 0 | D7、D8、D9 |

## 5. 完成定义（DoD）

> 逐条可勾选；必须至少包含「对应 SPEC 第 7 节全部判据通过」。

- [ ] `SPEC-A-03 §7` 全部 12 条判据通过（贴命令与输出到交付物 10）。
- [ ] `summaryText` 的每条子句都能追到 §4 表 A-03-T1 的编号；无表外子句、无字面百分比。
- [ ] `deltas` 键集恰为 `API-04 §5` 的 7 键；无基准时为 `0` 而非 `null`/缺键。
- [ ] 环比数字在真机报告页与 `deltas`、记录页统计三处一致（截图）。
- [ ] 趋势图在「有 7 天数据 / 部分天无数据 / 完全无数据」三种状态下各截图一张。
- [ ] 估算热量全部以「约 A–B kcal（估算）」形式上屏，裸 `kcal` 数字命中 0。
- [ ] 报告页顶部在演示数据集生效时显示「演示数据」标识（与 `PLAN-A-04` 联验）。
- [ ] `SPEC-A-03 §10` 的 OQ-A03-1/1b/2 已关闭（`ADR-06` 修订 A-1 / `ADR-10`）；`summary(DateRange)` 已就位，且 `week() == summary(最近 7 个本地日历日窗口)` 的等价性断言在 `PLAN-D-03` 落地。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **`StatsRepo.summary(DateRange)` 未按修订 A-1 落地**（原 OQ-A03-1，已由 `ADR-06` 关闭） | D6 结束 `summary(DateRange)` 仍缺失（`API-03` §5/§11.1 已冻结该方法；`week()` 保持无参签名属**预期**） | 升级到 D6 站会：按 `API-03` §11.1 补齐 `summary(DateRange)`（B 主，落在 `PLAN-D-03`）；**在补齐前** `deltas` 全 0 + 文案不含环比（确定性、不编造），并在 PPT 与证据文件中如实登记 |
| 上周无数据导致环比子句消失 | 真机文案只剩「本周记录 N 次」 | 属预期降级（`SPEC-A-03 §2.4` #2）；演示改用 `PLAN-A-04` 的 7 天数据集，保证有环比 |
| `StatsRepo.trend` 不返回空日 | 折线 x 轴跳日 | 在 A-03 内补点（纯算术，不查库）；登记 `PLAN-D-03` 缺陷 |
| `trend(7)` 逐日评分耗时超预期 | D8 实测报告页打开明显卡顿 | 按 OQ-A03-5 走变更流程：只算 `totalScore`、不生成 `evidence`；**不得**在 UI 层另写一套简化评分 |
| `SPEC-U-04` 与 schema 对 `deltas` 的语义冲突（原 OQ-A03-2，已由 `ADR-10` 关闭） | 报告页环比区块显示规则不一致 | 以 `API-04 §5` + schema 为准（`SPEC-00 §5` 权威归属）；同步修 `SPEC-U-04` 并登记变更 |
| 报告层被要求"顺手把 SQL 写进来" | 代码审查发现 `ReportService` 内含 `sqflite` 查询 | 立即回退到 `StatsRepo`；A 域不得复制 D 域聚合（`SPEC-A-03 §1.3`） |
| `PLAN-A-01`/`A-02` 延迟 | D8 报告页无分数/无建议 | 用 `FakeScore` + 固定建议列表先完成文案与折线；接通后重跑一致性测试 |
| 有人把趋势预测/云端同步排进来 | 出现 `http`/时序模型依赖 | 立即移除（`00_功能清单` §5 推迟项；`API-05 §9` `DISABLED`） |

## 7. 与检查点的关系

> 本功能是哪个 CP 的组成部分，未完成时 CP 如何处置。

- 与 `PLAN-A-01` 共同构成 **CP4（D7 晚「报告页数据已接通真实记录」）** 的判据；D7 晚先跑一次一致性测试作为预检。
- 本功能是 **D8 完整闭环**（吃 → 识别 → 记录 → 报告）的最后一环，也是 `PLAN-M-03`（Demo Mode C 报告演示）的唯一数据源。
- 属主方案 §8.2.1 第 ③ 项「不可砍」范围：**CP4 未过时按 `PLAN-00 §2` 切 `PLAN-A-04` 数据集，而不是把报告页做简或写死。**
- CP3（D9 午三模式 Demo）要求 Mode C 可用：若本功能未完成，CP3 只能降级为 A+B 两种模式，须在 PPT「后续工作」中如实登记。

**文档结束**

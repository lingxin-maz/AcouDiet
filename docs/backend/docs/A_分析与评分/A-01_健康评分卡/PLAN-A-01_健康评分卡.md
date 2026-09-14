# PLAN-A-01 健康评分卡

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-A-01 |
| 负责 | **C（主责）**；B 协助（`StatsRepo`/`WeekSummary` 字段补齐，见 `SPEC-A-01 §10` OQ-A01-2） |
| 目标日 | **D7**（D8 随 `U-01`/`U-04` 接通真实数据后回归一次） |
| 前置依赖 | `PLAN-D-01` `PLAN-D-02`（表/DAO）、`PLAN-D-03`（`WeekSummary` 字段）、`PLAN-C-03`（`feature_config` → Dart 常量生成）、`PLAN-U-06`（雷达组件）、`PLAN-U-01`（presenter）；签字项：**无**（`SPEC-A-01 §10` 的 OQ-A01-1 已由 `ADR-05`、**OQ-A01-3 已由 `ADR-P2`**、OQ-A01-6 已由 `ADR-09` 关闭，均无需再签字） |
| 预估工时 | **7 人时**（0.9 人日；A 域 4 项合计 22 h 见 `PLAN-00 §5`） |

## 1. 交付物（Deliverables）

> 逐项列出**文件路径级**的产物，能点开验收。

| # | 产物 | 验收方式 |
|---|---|---|
| 1 | `app/lib/domain/health/health_score.dart` | `HealthScore` / `DimensionScore` + `toJson`/`fromJson`；对 `docs/common/docs_api/schemas/health_score.schema.json` 的 `healthScore` 子模式校验通过 |
| 2 | `app/lib/domain/health/score_formulas.dart` | 四维纯函数、A-01-K1~K6 常量、`formulaOf` 公式串（单一来源） |
| 3 | `app/lib/domain/health/health_score_service.dart` | `HealthScoreService.score({required DateRange range})` + `ScoreInputs` 适配 |
| 4 | `app/test/domain/health_score_formula_test.dart` | 算例 A/B/C/D、键集、公式串唯一、端点不混用 |
| 5 | `app/test/domain/health_score_consistency_test.dart` | **PLAN-C-05 跨功能一致性（评分卡数字 == UI 数字）**，`SPEC-C-05 §5` #1 权威测试名 |
| 6 | `app/test/domain/score_reproducibility_test.dart` | 同库同窗两次逐字段相等 + 无时钟/随机（`SPEC-C-05 §5` #18） |
| 7 | `app/test/ui/score_card_render_test.dart` | 渲染文本 == 服务值（`SPEC-C-05 §5` #3） |
| 8 | `docs/evidence/PLAN-A-01_评分卡自检.md` | 逐条贴命令与输出；性能数字标注「实测产出」 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 模型 + JSON 往返 + schema 键集校验 | 交付物 1 | 1.0 h | `API-04 §3` |
| 2 | 四维纯函数 + 常量 + 公式串 | 交付物 2 | 1.5 h | `regularity`/`snack` 口径已由 `ADR-05`/`ADR-09` 冻结；OQ-A01-3 已由 `ADR-P2` 关闭 |
| 3 | `WeekSummary → ScoreInputs` 适配与服务装配 | 交付物 3 | 1.0 h | OQ-A01-2 字段补齐（`SPEC-D-03 §3` 四方法签名） |
| 4 | 算例 A/B/C/D 与边界/键集测试 | 交付物 4 | 1.5 h | 任务 2 |
| 5 | 一致性、可复现、渲染测试 | 交付物 5、6、7 | 1.5 h | `PLAN-U-01` presenter |
| 6 | `U-01`/`U-04` 下钻联调（公式串、`--` 判定）与证据归档 | 交付物 8 | 0.5 h | `PLAN-U-01` `PLAN-U-04` |

## 3. 技术方案

> 实现路径、关键代码骨架、算法步骤。**必须与 SPEC 的契约一致，不得另立参数。**

**分层**：`HealthScoreService`（有 IO，读 `StatsRepo`）→ `ScoreInputs`（纯数据）→ `ScoreFormulas.compute`（纯函数，测试直接打这一层）。**公式与常量只在 `score_formulas.dart` 出现一次**；`evidence` 键集只在 `health_score.dart` 的构造处出现一次。

```dart
// score_formulas.dart —— 纯函数内核（无 IO / 无时钟 / 无随机）
class ScoreInputs {
  final double? sigmaMinutes;              // WeekSummary.mealTimeStdDevMinutes（API-03 §5.3）
  final Map<String, int> classCounts;      // 6 键，FF-19
  final int recordCount;                   // 分母
  final int snackCount;                    // 本周零食次数（API-03 §5 窗口，ADR-09；旧窗口已作废）
  final int lateNightCount;
  final double? avgChewIntervalSeconds;    // 按 durationSeconds 加权（A-01-K3）
  final int sampleCount;
  final int missingMetricsCount;
  final int windowDays;
}

abstract final class ScoreFormulas {
  static int regularity(ScoreInputs i) => i.sigmaMinutes == null
      ? 0
      : _round(_clamp(30 * (1 - i.sigmaMinutes! / 90.0), 0, 30));
  static int structure(ScoreInputs i) { /* healthyCount/recordCount -> 30*min(1,p/0.4) */ }
  static int snack(ScoreInputs i)     { /* 20*max(0,1-n/10) */ }
  static int speed(ScoreInputs i)     { /* t>=0.8->20; t<=0.4->0; else 20*(t-0.4)/0.4 */ }

  static String formulaOf(String dimension);       // A-01-K5：UI 下钻的唯一公式来源
  static HealthScore compute(ScoreInputs i);       // 四维各自 round 后求和 -> grade -> delta
}
```

**实现要点**：
1. `evidence` 严格按 `API-04 §3` 键集填充；多键/缺键都会被 `health_score.schema.json` 的 `additionalProperties:false` 拒绝，测试必须直接跑 schema 校验。
2. 四维**先各自 `round` 再求和**；`totalScore` 绝不「先求和再取整」（`API-05 §6.2`，消除缺口 D-1）。
3. `sigmaMinutes` / `avgChewIntervalSeconds` 为 `null` 时该维 `score = 0` 且证据键保留 `null`；**不得**填 0 冒充。
4. 前一日窗口由 `range` **纯算术**推出并复用同一条计算路径；禁止 `DateTime.now()`。
5. 下钻展示的公式串来自 `formulaOf`；页面中不得出现公式字面量（测试断言命中 0）。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `health_score_formula_test.dart` | 单元 | 算例 A/B/C/D 四维分、总分、`grade`、`delta` 逐字段相等（**A 100 / B 61 / C 28 / D 29**，与 `SPEC-A-01 §7` 表 A-01-T3 逐值一致）；半值 `7.5→8`（`18.75→19` 同理）；**σ=30 → `regularity` 20**（`ADR-05` 公式口径，不得断言 30）；**15:40 加餐计入 `snackCount`**（`ADR-09`，B 的 `n`=6 而非 0）；`evidence` 键集全等；公式串唯一；FF-21e 端点未混用 | 每次改 `score_formulas.dart` |
| `health_score_consistency_test.dart` | **跨功能** | 四维与总分逐字段等于 `U-01`/`U-04` 显示值（差异字段数 == 0）；`totalScore == Σ四维` | 提交前 / D5 / D8 / D9 前 |
| `score_card_render_test.dart` | Widget | 渲染文本 == 服务值按 `API-05 §6.2` 舍入后的结果；`--` 判定按 `SPEC-A-01 §4` 三条件 | 提交前 / D8 |
| `score_reproducibility_test.dart` | 单元 + 静态 | 两次运行逐字段相等；`app/lib/domain/health/**.dart` 中 `DateTime.now`/`Random(`/`http`/`dio` 命中 0 | 提交前 / D8 |
| `flutter test` 全量 | 回归 | 退出码 0 | D7、D8、D9 |

## 5. 完成定义（DoD）

> 逐条可勾选；必须至少包含「对应 SPEC 第 7 节全部判据通过」。

- [ ] `SPEC-A-01 §7` 全部 10 条判据通过（贴命令与输出到交付物 8）。
- [ ] `HealthScore`/`DimensionScore` 与 `API-04 §3`、`health_score.schema.json` 逐字一致（无新增键、无改名）。
- [ ] 四维公式、常量、`evidence` 键集、公式串各自只有一处定义（grep 命中数为 1）。
- [ ] `U-01` 首页与 `U-04` 报告页的下钻数字与引擎输出一致（截图 + 一致性测试）。
- [ ] 空态（0 条 / 无有效餐类 / 全占位指标行）三条路径在真机上各截图一张，均呈 `--` 且非 0 分。
- [ ] OQ-A01-3 已由 `ADR-P2` 关闭并回写 `SPEC-A-01 §5`（A-01-K1 = `总分 ≥ 80 → 良好` / `60–79 → 一般` / `< 60 → 需改善`，登记为 `SPEC-00` §3.7 **FF-22b**）；OQ-A01-1 已由 `ADR-05` 关闭、OQ-A01-6 已由 `ADR-09` 关闭，**均无需再签字**；OQ-A01-2 若未解决，`speed` 维度必须有书面降级决定（见 §6）。
- [ ] 算例断言与 `SPEC-A-01 §7` 表 A-01-T3 的 `σ / p / n / t → 四维 → 总分` 逐值一致（差异字段数 == 0）。
- [ ] 性能与耗时数字全部标注「实测产出」，文档中无预测值。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **`WeekSummary` 缺 `avgChewIntervalSeconds` / `mealTimeSamples`**（OQ-A01-2） | D6 检查 `API-03`/`SPEC-D-03` 仍无该字段 | 升级到 D6 站会：按 `API-00 §3.9` 为 `API-03` 增补聚合字段（B 主，1–2 h）；**在补齐前不得在 A 域内自行读 `behavior_metrics` 聚合**（违反 L3/L4 边界） |
| OQ-A01-1 曾使 `regularity` 有两种解释 | ✅ **已关闭**（`ADR-05`，已写入 `SPEC-00 §3.7`） | 一律按 FF-22 **公式口径**：`σ=30 → 20`，散文「σ≤30 min 满分」作废；§7 算例 C 与下钻公式串须断言 `20`，**断言 `30` 视为缺陷** |
| 实现方沿用**已作废**的旧餐次窗口（午 `[11:00,16:00)` 等） | 算例 B 的 15:40 加餐被算成正餐 → `n` 变 0、`snack` 变 20、总分由 61 变 73；或 σ 分餐结果与 `API-03 §5.3` 不一致 | 立即改回 `API-03 §5` 的窗口（`ADR-09`）；窗口常量**只允许在 L3 定义一处**（`API-03 §5`），A 域不得自带副本 |
| σ 无法定义导致 `regularity` 为空 | 真实累积不足 3 天（`SPEC-A-01 §5` A-01-K4） | 属确定性降级；若影响演示，切 `PLAN-A-04` 的 Track 2 数据集，**评分卡本身不降级** |
| `U-01` presenter 未就位 | 一致性测试无法编译 | 先断言 `HealthScore` 与服务值相等；presenter 就位后补 UI 层断言（`score_card_render_test.dart`） |
| 有人"顺手"加 `evidence` 键或做 `X-07` 咀嚼 σ | schema 校验失败 / 代码审查发现额外键 | 立即移除；键集权威是 `API-04 §3`，变更须走 `API-00 §3.9` |
| 有人把 FF-21e 的 0.50/0.80 当评分端点 | 测试 #10 失败 | 立即修正：评分端点 0.4/0.8，文案阈值属 `P-07` |

## 7. 与检查点的关系

> 本功能是哪个 CP 的组成部分，未完成时 CP 如何处置。

- 本功能是 **CP4（D7 晚「报告页数据已接通真实记录」）** 的组成部分，并与 `PLAN-A-03` 共享该判据。
- 属主方案 §8.2.1 五项「不可砍」的 ③（健康报告 + 评分卡），**不得因 CP 未过而降级为静态图或写死数字**。
- CP4 未过时的规定动作（`PLAN-00 §2`）：启用 `PLAN-A-04` 的预置演示数据集，放弃真实累积；评分卡与四维下钻仍须真实计算。
- D8 完整闭环（吃 → 识别 → 记录 → 报告）验收前，本 PLAN 的一致性、可复现与渲染测试必须全绿，否则 D9 现场数字对不上（风险 R-10）。

**文档结束**

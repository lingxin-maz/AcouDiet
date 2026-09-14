# PLAN-A-02 规则引擎健康建议

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-A-02 |
| 负责 | **C（主责）**；B 协助（`WeekSummary` 的 `lateNightCount` / `classCounts` 与按 `source` 过滤） |
| 目标日 | **D7** |
| 前置依赖 | `PLAN-A-01`（同日交付 `HealthScore`，本 PLAN 用 `FakeScore` 解耦）、`PLAN-D-03`（`WeekSummary` 聚合）、`PLAN-U-04`（建议区与免责声明渲染）；签字项：`SPEC-A-02 §10` OQ-A02-1/2/3 |
| 预估工时 | **4 人时**（0.5 人日） |

## 1. 交付物（Deliverables）

> 逐项列出**文件路径级**的产物，能点开验收。

| # | 产物 | 验收方式 |
|---|---|---|
| 1 | `app/lib/domain/health/advice.dart` | `Advice` 类 + `dimension` 枚举常量、`general` 项构造器（单一来源） |
| 2 | `app/lib/domain/health/advice_rules.dart` | 五条规则、文案模板、A-02-K1~K11 常量（含冻结的免责声明文案） |
| 3 | `app/lib/domain/health/advice_engine.dart` | `AdviceEngine.generate`（排序、截断、跳过、`general` 项） |
| 4 | `app/test/domain/advice_rules_test.dart` | 五规则、`general` 唯一/末位、红线、排序截断、不足降级、null 跳过 |
| 5 | `app/test/domain/advice_purity_test.dart` | 100 次一致 + 源文本禁令 |
| 6 | `app/test/domain/advice_ui_consistency_test.dart` | **PLAN-C-05 跨功能一致性（文案数字 == 评分卡/聚合数字）** |
| 7 | `app/test/ui/report_advice_widget_test.dart` | 空态「暂不生成建议」与免责声明两态渲染 |
| 8 | `docs/evidence/PLAN-A-02_建议规则自检.md` | 逐条贴命令与输出 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 五条规则的条件/模板/优先级定稿，逐条过 `FF-25` 红线自查；冻结免责声明文案 | 交付物 2（常量部分） | 1.0 h | OQ-A02-2 拍板 |
| 2 | 实现规则求值与引擎（排序、截断、`general` 项唯一、跳过） | 交付物 1、2、3 | 1.5 h | 任务 1 |
| 3 | 写规则/纯度测试 | 交付物 4、5 | 1.0 h | 任务 2 |
| 4 | `U-04` 建议区与免责声明联调 + 一致性/Widget 测试 | 交付物 6、7、8 | 0.5 h | `PLAN-U-04` 骨架 |

## 3. 技术方案

> 实现路径、关键代码骨架、算法步骤。**必须与 SPEC 的契约一致，不得另立参数。**

**结构**：规则表（数据）与求值器（逻辑）分离。规则表是 `const List<AdviceRule>`，模板串集中在表里；求值器只做「判条件 → 填占位符 → 排序 → 截断」。**阈值不得出现在求值器里**（必须来自 `advice_rules.dart` 常量，便于 OQ-A02-2 拍板后一处修改）。

```dart
// advice_rules.dart —— 规则表（数据），阈值集中在 A-02-K*
class AdviceRule {
  final String dimension;                 // 'snack' | 'regularity' | 'speed' | 'structure'
  final int priority;                     // 1 / 2 / 3（general 项固定 kGeneralPriority）
  final bool Function(HealthScore, WeekSummary) hit;
  final String Function(HealthScore, WeekSummary) text;   // 占位符白名单见 SPEC §4
  const AdviceRule({required this.dimension, required this.priority,
                    required this.hit, required this.text});
}

// advice_engine.dart —— 求值器（逻辑），无 IO / 无时钟 / 无随机
abstract final class AdviceEngine {
  static const String disclaimer =
      '提供日常健康管理建议，不进行疾病诊断，不替代专业医疗意见';   // A-02-K6，全仓唯一来源

  Future<List<Advice>> generate({required HealthScore score, required WeekSummary agg}) async {
    final general = Advice(dimension: 'general', text: disclaimer, priority: kGeneralPriority);
    if (agg.recordCount < kMinRecordCount) return <Advice>[general];      // A-02-K4
    final hit = kAdviceRules.where((r) => r.hit(score, agg)).toList()
      ..sort(compareByPriorityThenDimension);                            // A-02-K3
    return <Advice>[...hit.take(kMaxAdvices).map(build), general];        // general 恒末位
  }
}
```

**实现要点**：
1. 占位符只接受 §4 白名单字段；填充后若仍残留 `{x}` → 抛 `StateError`（测试兜底，杜绝漏填上屏）。
2. 字段为 `null` → 该规则 `hit` 返回 `false`，**不得**代入 0。
3. `general` 项在函数入口先构造，任何 early-return 分支都必须包含它（`API-04 §4` 强制）。
4. 排序用「`priority` → `dimension` 固定序 → 规则表声明序」三级稳定键，禁止依赖 `List.sort` 的不稳定实现细节（用 `sortedBy` 复合键）。
5. 文案长度断言放测试里，不放在运行期（避免现场抛错）。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `advice_rules_test.dart` | 单元 | 五规则逐条全等；`general` 唯一/最大 `priority`/末位；禁用词命中 0；排序+截断确定；不足时仅 `general` | 每次改规则表后 |
| `advice_purity_test.dart` | 单元 + 静态 | 100 次输出全等；`DateTime.now`/`Random(`/`http`/`dio` 命中 0 | 提交前 |
| `advice_ui_consistency_test.dart` | **跨功能** | 文案数字全部能在 `HealthScore`/`WeekSummary` 找到；UI 文案与引擎输出逐字相等 | D7、D8、D9 |
| `report_advice_widget_test.dart` | Widget | 空态「暂不生成建议」命中 1；免责声明在 `ready`/`insufficient` 两态均命中 1 | D7、D8 |
| `flutter test` 全量 | 回归 | 退出码 0 | D7、D8、D9 |

## 5. 完成定义（DoD）

> 逐条可勾选；必须至少包含「对应 SPEC 第 7 节全部判据通过」。

- [ ] `SPEC-A-02 §7` 全部 10 条判据通过（贴命令与输出到交付物 8）。
- [ ] 免责声明字符串全仓定义处命中数为 1，且与 `API-04 §4` 的 `general` 项语义一致、逐字等于 A-02-K6。
- [ ] 五条规则的阈值与文案全部集中在 `advice_rules.dart`，求值器中无数字阈值。
- [ ] 禁用词测试覆盖 `FF-25` 全部红线词，命中数为 0。
- [ ] `U-04` 在「有建议 / 无建议（仅免责声明）」两种状态下各截图一张，免责声明均可见。
- [ ] OQ-A02-2 的四个阈值与 OQ-A02-3 的维度映射已拍板并回写 `SPEC-A-02 §5`。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `PLAN-A-01` 同日未交付 | `HealthScore` 类型不可用 | 用 `FakeScore`（按 `API-04 §3` 手工构造四维 + `evidence`）先完成规则与文案；类型就位后只换构造来源 |
| 规则 3（速度）无数据源 | `speed.evidence['avgChewIntervalSeconds']` 恒为 null（同 `SPEC-A-01 §10` OQ-A01-2） | 该规则自动跳过（`hit` 为 false），不产生错误建议；**不得**在 A 域内自行聚合 `behavior_metrics` |
| `WeekSummary` 未按 `source` 过滤 | 演示模式下数字与真实用量混杂 | 在 `SPEC-D-03` 修；A 域只消费，不私加过滤 |
| 阈值未拍板导致建议过量/过少 | 报告页建议塞满或永远为空 | 按 `SPEC-A-02 §5` 常量冻结；调整只改常量 + 对应测试期望 |
| 建议文案与 `U-04` 展示不一致 | 一致性测试失败 | 冻结 UI，以引擎输出为准（风险 R-10 同源处置） |
| 免责声明被漏渲染 | `report_advice_widget_test` 失败 | 视为阻断缺陷，D8 前必修；免责声明是产品合规项 |
| 有人把 LLM / 网络建议接进来 | 代码审查发现 `http`/`dio` 依赖 | 立即移除（违反 `FF-24`；`API-05 §9` 为 `DISABLED`） |

## 7. 与检查点的关系

> 本功能是哪个 CP 的组成部分，未完成时 CP 如何处置。

- 本功能是 **CP4（D7 晚「报告页数据已接通真实记录」）** 的组成部分，判据与 `PLAN-A-01`、`PLAN-A-03` 共用。
- 属主方案 §8.2.1 第 ③ 项「不可砍」范围，**不因 CP 未过而降级为静态文案**；CP4 未过时按 `PLAN-00 §2` 切 `PLAN-A-04` 的演示数据集。
- D8 报告页收口（`U-04`）前，免责声明 Widget 测试必须全绿，否则答辩时合规表述缺位。

**文档结束**

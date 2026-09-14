# PLAN-U-04 健康报告页

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-04` |
| 负责 | C（主责页面与下钻交互）；B 协助 `A-04` 演示数据接入与 `D-03` 趋势查询 |
| 目标日 | D8（D6 起骨架，D7 接评分，D8 收口） |
| 前置依赖 | `PLAN-U-06`（折线/雷达/空态）、`PLAN-A-01`（评分卡 D7）、`PLAN-A-02`（建议 D7）、`PLAN-A-03`（周报 D8）、`PLAN-D-03`（聚合 D7）、`PLAN-A-04`（演示数据 D8） |
| 预估工时 | 11 h（D6 3h 骨架 + D7 3h 评分与建议 + D8 5h 收口与一致性核对） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/report/report_page.dart` | 页面骨架与三区块布局 |
| 2 | `app/lib/presentation/pages/report/widgets/trend_section.dart` | 折线 + 口径切换（复用 `TrendLineChart`） |
| 3 | `app/lib/presentation/pages/report/widgets/dimension_drill.dart` | 四维逐项 + `evidence` 展开 |
| 4 | `app/lib/presentation/pages/report/widgets/advice_list.dart` | 建议列表（按 `priority` 排序） |
| 5 | `app/lib/presentation/pages/report/widgets/week_summary_banner.dart` | 小结 + 环比 |
| 6 | `app/lib/presentation/pages/report/widgets/disclaimer_footer.dart` | 常驻免责声明 |
| 7 | `app/lib/presentation/pages/report/insufficient_view.dart` | 数据不足的确定性降级视图 |
| 8 | `app/lib/presentation/providers/report_providers.dart` | 报告/趋势/建议/评分 4 个 Provider |
| 9 | `app/test/widget/report_page_test.dart` | `SPEC-U-04` §7 判据 1–9、11 |
| 10 | `app/test/unit/report_consistency_test.dart` | 四维之和 == 总分；首页 == 报告页分数（`SPEC-C-05` 联动） |
| 11 | 人工核对记录（`8.png`/`9.png` 比对 + 11 项核对表） | `docs/review/U-04_核对表.md`（评审附件） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 页面骨架 + 4 个 Provider（`FakeRepo` 占位） | `report_page.dart`、`report_providers.dart` | 2.0 h | U-06 |
| 2 | 折线区（≤7 点、空洞不插值、口径切换） | `trend_section.dart` | 2.0 h | U-06 |
| 3 | 四维下钻（`label score/max` + `evidence`） | `dimension_drill.dart` | 1.5 h | `A-01` 接口冻结（D1） |
| 4 | 建议列表（`priority` 排序、空态文案） | `advice_list.dart` | 1.0 h | `A-02`（D7） |
| 5 | 小结 + 环比区 | `week_summary_banner.dart` | 1.0 h | `A-03`（D8） |
| 6 | 免责声明 + 演示数据标识 | `disclaimer_footer.dart` | 0.5 h | `A-04` |
| 7 | 数据不足降级视图 | `insufficient_view.dart` | 1.0 h | `A-03` 阈值对齐 |
| 8 | 评分/建议真实接通（`A-01`/`A-02`） | Provider 切换 | 1.5 h | D7 |
| 9 | 一致性核对（首页 vs 报告页、四维 vs 总分） | 单测 + 截图 | 1.5 h | 8 |
| 10 | 测试 + 人工核对表 | 2 个测试文件 | 2.0 h | 1–9 |

## 3. 技术方案

- **数据来源双轨**（主方案 §9.1）：优先 Track 1 真实累积；不足 20 条时启用 Track 2 预置数据集，并显示「演示数据」标识。
- **确定性降级**：数据不足时渲染 `insufficient_view`，**折线 spot 数为 0**，禁止用 0 值或插值填充（`SPEC-U-04` §2.4）。
- **可复现性**：页面不做任何计算，只渲染 `A-01`/`A-02`/`A-03` 的返回值；四维取整与求和在域层完成（`API-05` §6.2）；`TrendPoint.totalScore` 由 `ReportService.trend()` 在 **L4 填充**（`StatsRepo.trend()` 恒 `null`，`API-03` §5），页面不得把 `null` 当作 0。
- **`deltas` 恒 7 键**（`API-04` §5、`ADR-10`）：无对比基准时值为 `0`（数值型，非缺键、非 `null`）；环比是**差值**不是比率。因此**不能再用 `deltas.isEmpty` 作为降级判据**（该条件恒为 `false`）。
- **下钻只读**：`evidence` 直接渲染 `DimensionScore.evidence` 的键值对，不在 UI 里重算公式。
- **免责声明常驻**：`ready` 与 `insufficient` 两态都必须渲染（判据 9）。
- **骨架示意（≤30 行）**：

```dart
final trendProvider = FutureProvider<TrendSeries>(
    (ref) => ref.watch(reportServiceProvider).trend(days: 7));   // API-04 §5 冻结签名
final reportProvider = FutureProvider<WeeklyReport>(
    (ref) => ref.watch(reportServiceProvider).weekly(range: TimeRange.last7Days()));

class ReportPage extends ConsumerStatefulWidget {
  @override
  ConsumerState<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends ConsumerState<ReportPage> {
  ChartAxis _axis = ChartAxis.score;                       // 口径切换不重新请求

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(reportProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('本周')),           // 2.png「近 7 天」→「本周」
      body: report.when(
        loading: () => const StateView(status: ViewStatus.loading),
        error: (e, _) => const StateView(status: ViewStatus.error),
        data: (r) => r.advices.isEmpty              // deltas 恒 7 键（API-04 §5），不能再用 deltas.isEmpty 作降级判据
            ? const InsufficientView()                     // 数据不足：空图 + 提示
            : _ReportBody(report: r, axis: _axis,
                onAxisChanged: (a) => setState(() => _axis = a))),
    );
  }
}
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `report_page_test.dart` | widget test | `SPEC-U-04` §7 判据 2–9、11 全通过 | 每次提交 |
| 折线空洞 | widget test | spot 数 == 非空点数；`null` 日不画 0 | D7 |
| `score` 口径数据源 | unit test | `TrendPoint.totalScore` 由 L4（`ReportService.trend()`）填充，L3 为 `null` 时页面不当作 0（`API-03` §5） | D7 |
| 环比键集 | unit test | `deltas` 键集恰为 7 个；无基准时值为 `0`（非 `null`、非缺键）；**不得**用 `deltas.isEmpty` 作降级判据（`API-04` §5） | D8 |
| 口径切换 | widget test | 切换后 Provider 请求次数不变 | D7 |
| 四维求和 | unit test（`SPEC-C-05`） | 四维各自取整后之和 == `totalScore` | D7、D8 |
| 首页一致性 | unit test | 同一数据集下首页分数 == 报告页分数 | D8 |
| 数据不足降级 | widget test | 页面无折线 spot、无 kcal 数值，提示与 `暂不生成建议` 存在 | D8 |
| 免责声明 | widget test | `ready` 与 `insufficient` 两态均存在声明 widget | D8 |
| 禁用词扫描 | shell | 营养素/目标热量/FF-25 词命中数 == 0 | D8、D9 |
| 演示数据自洽 | 手测（`PLAN-M-03`） | 预置 7 天数据下页面数字与 `A-04` 数据集算出的一致 | D9（CP3） |
| 人工核对表 | 人工 | `SPEC-U-04` §7 的 11 项全 ✓ | D8 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-04` 第 7 节 13 项判据全部通过（含 11 项人工核对表逐项打钩）。
- [ ] 11 项交付物落盘可点开。
- [ ] 四维之和 == 总分；首页 == 报告页分数；两处均由 `SPEC-C-05` 单测断言通过（D-1 缺口关闭）。
- [ ] 数据不足分支确定性可复现：同一数据集下页面输出逐字段相同。
- [ ] 页面标题为「本周」；无「近 7 天」「2000 kcal」等残留。
- [ ] 免责声明与演示数据标识按态正确出现。
- [ ] 全仓扫描：表外字段、营养素词、FF-25 禁用词、网络依赖均 0 命中。
- [ ] 无障碍：折线与雷达文本等价物可被 TalkBack 完整朗读，口径切换有状态朗读。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `A-01`/`A-02` 延期到 D8 | D7 晚仍无评分与建议返回值 | 报告页先只上折线；评分与建议区显示 `--` / `暂不生成建议`，**不得用假数据填** |
| 真实累积数据不足 20 条 | D8 记录数 < 20 | 启用 `A-04` Track 2 预置数据集并显示「演示数据」标识（`PLAN-00` CP4 降级动作） |
| 趋势口径争议导致返工 | `D-03` 与 UI 口径不一致 | 先按滚动 7 天实现 + 标题「本周」，口径拍板后只改 `D-03` 参数（UI 不动） |
| 报告与首页数字对不上 | 核对表第 2 项不通过 | 立即统一为单套生效数据集；`SPEC-C-05` 一致性测试设为合并门禁 |
| 数据不足阈值与 `A-03` 不一致 | 页面与服务的判据不同 | 阈值只保留一处（域层），UI 只读服务返回的降级标志 |
| 建议文案被写成医学结论 | 人工核对第 6 项不通过 | 由 `A-02` 统一改为生活方式建议口径，UI 不自行改写文案 |

## 7. 与检查点的关系
- **CP4（D7 晚）**：判据即「报告页数据已接通真实记录」。未通 → 启用 `A-04` 预置演示数据集（Track 2），放弃真实累积；本页是该 CP 的直接判据载体。
- **CP3（D9 午）**：Demo Mode C（报告演示）必须展示本页，且数字自洽（`PLAN-M-03`）。
- 本功能属主方案 §8.2.1 不可砍项③，**CP 失败时的降级清单不得包含本页**；只允许削减 `evidence` 下钻与环比区块。

**文档结束**

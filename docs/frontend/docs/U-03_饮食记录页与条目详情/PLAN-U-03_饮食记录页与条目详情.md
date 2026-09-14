# PLAN-U-03 饮食记录页与条目详情

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-03` |
| 负责 | C（主责）；B 协助 `D-03` 聚合查询接口与真数据接通 |
| 目标日 | D8（D3 起占位版，D8 收口） |
| 前置依赖 | `PLAN-U-06`（条目卡片/图标/空态）、`PLAN-D-02`（DAO）、`PLAN-D-03`（聚合查询）、`PLAN-A-03`（本周小结）、`PLAN-P-08`（`foods.json`） |
| 预估工时 | 10 h（D3 3h 占位版 + D4 2h 详情页 + D8 5h 收口与接通） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/records/records_page.dart` | 时间轴页面骨架 |
| 2 | `app/lib/presentation/pages/records/widgets/summary_bar.dart` | 顶部汇总条（`估算总热量 / 已记录次数 / 零食次数`） |
| 3 | `app/lib/presentation/pages/records/widgets/week_summary_card.dart` | 本周小结卡片 |
| 4 | `app/lib/presentation/pages/records/widgets/day_group_header.dart` | 今天 / 昨天 / M月d日 分组头 |
| 5 | `app/lib/presentation/pages/records/record_detail_page.dart` | 条目详情衍生页 |
| 6 | `app/lib/presentation/pages/records/widgets/detail_sections.dart` | 详情页四个区块（基本/识别/行为/知识库） |
| 7 | `app/lib/presentation/providers/records_providers.dart` | 汇总、分组记录、小结、详情 Provider |
| 8 | `app/lib/presentation/pages/records/empty_records_view.dart` | 确定性空态 |
| 9 | `app/test/widget/records_page_test.dart` | `SPEC-U-03` §7 判据 1–7 |
| 10 | `app/test/unit/record_grouping_test.dart` | 跨天分组、排序、空值渲染 |
| 11 | 人工核对记录（`8.png` 逐项比对截图） | `docs/review/U-03_核对表.md`（评审附件） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 页面骨架 + 三个 Provider（先接 `FakeRepo`） | `records_page.dart`、`records_providers.dart` | 2.0 h | U-06 |
| 2 | 汇总条（三项 + 空值 `0`） | `summary_bar.dart` | 1.0 h | 1 |
| 3 | 时间轴分组与分组头 | `day_group_header.dart` | 1.5 h | 1 |
| 4 | 条目卡片接入（复用 `RecordCard`，校验标准模板三行） | `records_page.dart` | 1.5 h | U-06、`FoodInfo` |
| 5 | 本周小结卡片 | `week_summary_card.dart` | 0.5 h | `A-03` 接口 |
| 6 | 空态与错误态 | `empty_records_view.dart` | 0.5 h | U-06 |
| 7 | 条目详情页四区块 | `record_detail_page.dart`、`detail_sections.dart` | 1.5 h | `D-02` |
| 8 | 首页「查看全部」与检测页「已自动记录」跳转承接 | 路由入参 | 0.5 h | `U-01`、`U-02` |
| 9 | 来源与演示标识（`mic`/`inject`/演示数据） | 条目与详情 | 0.5 h | `A-04` |
| 10 | D8 切真实实现（`RealDietRepo` 等）+ 汇总与小数字一致性核对 | Provider 切换 | 1.5 h | `D-03`、`A-03` |
| 11 | 测试 + 人工核对表 | 2 个测试文件 | 2.0 h | 1–10 |

## 3. 技术方案

- **占位数据解耦**：D3–D7 用 `FakeRepo implements DietRepo, StatsRepo, ProfileRepo`（`API-03` §8），只填契约表内字段（`time/food/kcalRange/confidence/attribute` + 汇总三项 + `summaryText`）；B 就绪后换真实实现，页面零改动。
- **分组在 Provider 层完成**：`DietRepo.byRange(DateRange)` 一次查出 7 天记录（返回 `eatenAtMs ASC`），Provider 只做**按日历日切桶**，页面只渲染分组结果；**组内顺序不重排**（`API-03` §3.1）；**域层不产出格式化字符串**。
- **条目模板强制**：三行布局封装在 `RecordCard` 内（`U-06` 交付），本页不得另写一套条目布局，避免粒度失控。
- **详情为衍生页**：`push` 进入，不占底栏 Tab，页面总数仍为 4（FF-23）。
- **无写入入口**：本页只读；记录的产生只发生在检测页（`P-06` 确认后落库），保证 `X-02` 不被顺手实现。
- **骨架示意（≤30 行）**：

```dart
final recordsProvider = FutureProvider<List<DietRecord>>((ref) {
  final repo = ref.watch(dietRepoProvider);                       // FakeRepo → 真实实现
  final now = DateTime.now();
  return repo.byRange(DateRange(                              // 半开区间，API-03 §4
      startMs: now.subtract(const Duration(days: 6)).millisecondsSinceEpoch,
      endMs: now.add(const Duration(days: 1)).millisecondsSinceEpoch));
});                                                              // 返回 eatenAtMs ASC，不重排

class RecordsPage extends ConsumerWidget {
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(recordsProvider);
    final summary = ref.watch(todayProvider);                     // StatsRepo.today()
    return Scaffold(
      appBar: AppBar(title: const Text('饮食记录')),
      body: Column(children: [
        summary.when(
          data: (s) => SummaryBar(summary: s),                  // 估算 315 kcal / 3 次 / 1 次
          loading: () => const SummaryBar.placeholder(),
          error: (_, __) => const SummaryBar.unknown()),        // -- / -- / --
        records.when(
          data: (d) => d.isEmpty
              ? const EmptyRecordsView()                        // 空状态
              : _Timeline(groups: d),
          loading: () => const StateView(status: ViewStatus.loading),
          error: (e, _) => const StateView(status: ViewStatus.error)),
      ]),
    );
  }
}
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `records_page_test.dart` | widget test | `SPEC-U-03` §7 判据 2–10 全通过 | 每次提交 |
| 标准模板三行 | widget test | 时间/食物名/热量 + 属性·份量（估算）+ 置信度 + 箭头 | D4、D8 |
| 跨天分组 | unit test | 23:59 与 00:01 落不同分组；**组内顺序 == `byRange` 返回顺序（ASC，不重排）** | D4 |
| 汇总条格式 | widget test | 正则 `\d+ kcal / \d+ 次 / \d+ 次`；无数据三值为 `0` | D4 |
| 详情字段完整性 | widget test | 置信度/时长/咀嚼次数/属性/来源各存在；缺值 `--` | D8 |
| 只读校验 | shell 断言 | `rg` 在 records 目录命中 CSV/改类别/删除 == 0 | D8、D9 |
| 数字一致性 | unit test（`SPEC-C-05`） | 汇总条 kcal == `StatsRepo.today().estimatedKcal`；小结文本与 `ReportService.weekly().summaryText` 一致 | D8 |
| 真机联调 | 手测 | 检测一条 → 记录页出现新条目并高亮 → 汇总 +1 | D8（CP4） |
| 人工核对表 | 人工 | `SPEC-U-03` §7 的 8 项全 ✓ | D8 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-03` 第 7 节 11 项判据全部通过（含 10 项人工核对表逐项打钩）。
- [ ] 11 项交付物落盘可点开。
- [ ] 条目卡片与 §4.2 标准模板**逐行一致**；全页无孤立 kcal 数字。
- [ ] 记录页与详情页均**只读**：无导出、无改类别、无删除入口。
- [ ] D8 完成 `FakeRepo` → 真实实现切换，页面代码无 diff。
- [ ] 详情页字段与 `DietRecord` / `BehaviorMetrics` / `FoodInfo` 一一对应；缺值一律 `--`，无 `0` 兜底。
- [ ] 无障碍：条目与汇总条语义标签可被 TalkBack 完整朗读。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `D-03` 聚合查询延期 | D7 仍无汇总接口 | 汇总条用页面内临时聚合（仅 7 天数据）顶替，**契约不变**，D8 必换回 `D-03` |
| `A-03` 周报接口延期 | D8 无 `summaryText` | 小结卡显示 `数据不足`，不伪造文案 |
| 行为指标空行导致详情页报错 | 详情页 NPE / 空白 | 全字段按 `null` 渲染 `--`；按 `API-05` §5.5 保证空指标占位行不缺失 |
| 真数据量与设计稿差距大 | 真实记录 < 20 条 | 启用 `A-04` Track 2 预置数据集并显示「演示数据」标识 |
| 条目模板被实现方自由发挥 | 出现「全麦面条」「纯牛奶」等 | 立刻按 §4.2 重写；命名集合由 `FoodClassId` 枚举约束，禁止字符串拼接食物名 |
| 详情页被做成独立 Tab | 底栏多出第 5 项 | 立刻回退（页面数冻结为 4，FF-23） |

## 7. 与检查点的关系
- **CP2（D5）**：记录页不是 D5 判据项，但 D5 闭环的落库结果需要本页可见（`PLAN-U-02` 的"已自动记录"跳转指向本页详情）。
- **CP4（D7 晚）**：报告页数据接通依赖记录数据的真实累积；本页是 Track 1 真实累积的载体（D6 起全队每天 3–4 次真实检测），未达 20 条则转 Track 2。
- 本功能属主方案 §8.2.1 不可砍项②的用户可见面，**CP 失败时的降级清单不得包含本页**；只允许削减详情页的知识库区块与演示标识完善度。

**文档结束**

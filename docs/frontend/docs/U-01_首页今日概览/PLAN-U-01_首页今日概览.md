# PLAN-U-01 首页 · 今日概览

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-01` |
| 负责 | C（主责）；B 协助 D8 数据接通 |
| 目标日 | D3 起（骨架）→ D8 收口 |
| 前置依赖 | `PLAN-U-06`（D3 组件签名冻结）；`PLAN-D-02`（DAO 可用）或 `FakeRepo`；`PLAN-A-01`（评分服务接口冻结）；`PLAN-P-08`（`foods.json` 定稿） |
| 预估工时 | 9 h（D2 2h 骨架 + D3 2h 占位版 + D4 2h 细节 + D8 3h 接通与收口） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/home/home_page.dart` | 首页骨架与布局 |
| 2 | `app/lib/presentation/pages/home/widgets/score_card.dart` | 评分 + 评级 + 较昨日 + 四维雷达 |
| 3 | `app/lib/presentation/pages/home/widgets/energy_card.dart` | 估算能量参考（区间） |
| 4 | `app/lib/presentation/pages/home/widgets/week_count_card.dart` | 本周记录次数 |
| 5 | `app/lib/presentation/pages/home/widgets/today_records_section.dart` | 今日记录列表（≤3 条 + 查看全部） |
| 6 | `app/lib/presentation/pages/home/widgets/start_detect_button.dart` | 「开始 AI 检测」主按钮 |
| 7 | `app/lib/presentation/providers/home_providers.dart` | 4 个 Riverpod Provider（`todaySummary` / `healthScore` / `weekSummary` / `todayRecords`） |
| 8 | `app/lib/data/repositories/fake_repo.dart` | 契约内字段的占位实现（D3–D7 用） |
| 9 | `app/test/widget/home_page_test.dart` | `SPEC-U-01` §7 判据 1–5、7–9 |
| 10 | `app/test/unit/home_format_test.dart` | 格式化与降级文案单测 |
| 11 | 人工核对记录（截图 + 12 项核对表打钩） | `docs/review/U-01_核对表.md`（评审附件，不计入 SPEC/PLAN 文档数） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 建首页路由与四区布局骨架 | `home_page.dart` | 2.0 h | U-06 主题 |
| 2 | 定义 4 个 Provider（先接 `FakeRepo`） | `home_providers.dart` | 1.0 h | `DietRecord` / `HealthScore` 契约冻结（D1） |
| 3 | 评分卡 + 评级 + 较昨日（`0` → 「持平」，仅 `null` 隐藏） | `score_card.dart` | 1.5 h | 2 |
| 4 | 四维雷达接入（复用 `FourDimRadar`） | `score_card.dart` | 0.5 h | U-06 |
| 5 | 能量区间卡 + 本周次数卡 | 两个卡片 | 1.0 h | `AcouFormat` |
| 6 | 今日记录列表（`RecordCard` 复用 + 「查看全部」） | `today_records_section.dart` | 1.5 h | U-06 |
| 7 | 「开始 AI 检测」主按钮 + 跳转 | `start_detect_button.dart` | 0.5 h | 路由 |
| 8 | 右上角「我的」入口 | `home_page.dart` | 0.5 h | 路由 |
| 9 | 空/加载/错误三态与局部降级 | 各区 | 1.0 h | U-06 `StateView` |
| 10 | D8 切真实实现（`RealDietRepo` 等）并做数字一致性核对 | Provider 切换 | 1.5 h | `D-03`、`A-04` |
| 11 | 测试 + 人工核对表 | 2 个测试文件 | 1.5 h | 3–10 |

## 3. 技术方案

- **占位数据解耦（`PLAN-00` §4）**：页面只依赖 `API-03` 冻结的 `StatsRepo` / `DietRepo` / `ProfileRepo` 抽象；D3–D7 注入 `FakeRepo implements DietRepo, StatsRepo, ProfileRepo`（`API-03` §8），B 就绪后换真实实现（`RealDietRepo` 等），**页面代码零改动**（只换 Provider override）。
- **字段准入**：`FakeRepo` 只允许填 `SPEC-U-01` §4 契约表内的字段；**表外字段一律不造**，避免 D8 发现无数据源（风险 R-19）。
- **降级为局部**：单区失败只降级该区，不做整页白屏。
- **较昨日的格式唯一真源在 `AcouFormat.delta`**（`SPEC-U-06` §4.3）：`0` → `持平`，`null` → 隐藏该行；页面不得自拼字符串（`ADR-10`）。

```dart
// 骨架示意（≤30 行）
final repoProvider = Provider<StatsRepo>((ref) => FakeRepo());        // D8 换真实实现
final healthScoreProvider = FutureProvider<HealthScore>(
    (ref) => ref.watch(scoreServiceProvider).score(range: TimeRange.today()));
final todayProvider = FutureProvider<TodaySummary>(
    (ref) => ref.watch(repoProvider).today());                       // API-03 §5 冻结签名

class HomePage extends ConsumerWidget {
  Widget build(BuildContext context, WidgetRef ref) {
    final score = ref.watch(healthScoreProvider);      // AsyncValue<HealthScore>
    return Scaffold(
      appBar: AppBar(title: const Text('AcouDiet · 声膳'),
          actions: [IconButton(icon: const Icon(Icons.person_outline),
              tooltip: '我的', onPressed: () => context.push('/profile'))]),
      body: score.when(
        loading: () => const StateView(status: ViewStatus.loading),
        error: (e, _) => StateView(status: ViewStatus.error, onRetry: () => ref.invalidate(healthScoreProvider)),
        data: (s) => _HomeBody(score: s)),               // 各卡片内部再各自判空
    );
  }
}
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `home_page_test.dart` | widget test | `SPEC-U-01` §7 判据 2 的 6 元素全部存在且格式匹配 | 每次提交 |
| 空态测试 | widget test | `--` / `暂无数据` / `0 次` / `今天还没有记录` 四项逐字一致 | D4、D8 |
| delta 持平 / 隐藏 | widget test | `deltaVsYesterday == 0` → 文本逐字为「持平」；`null` → 该行 widget 数 == 0（`ADR-10`） | D4 |
| 格式化 | unit test | `kcalRange(1250)` == `估算能量参考 约 1000–1500 kcal` | D3 |
| 数字一致性 | unit test（`SPEC-C-05`） | 首页显示总分 == `HealthScoreService` 对同一数据集的计算结果 | D7、D8 |
| 禁用词扫描 | shell | 表外字段/营养素/FF-25 词命中数 == 0 | D8、D9 |
| 真机联调 | 手测 | 检测一条 → 返回首页 → 列表与本周次数 +1，分数刷新 | D8（CP4） |
| 人工核对表 | 人工 | `SPEC-U-01` §7 的 12 项全 ✓ | D8 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-01` 第 7 节 10 项判据全部通过（含 12 项人工核对表逐项打钩）。
- [ ] 11 项交付物落盘可点开；`fake_repo.dart` 在 D8 后仅用于演示模式与测试，不参与主流程。
- [ ] D8 完成 `FakeRepo` → 真实实现 切换，页面代码无 diff（仅 Provider override 变化）。
- [ ] 首页分数与报告页分数为同一套数据，四维之和 == 总分（`SPEC-C-05` 断言通过）。
- [ ] 表外字段、营养素、FF-25 禁用词、网络依赖四项扫描均 0 命中。
- [ ] 无障碍：评分卡与雷达的语义标签可从读屏逐字读出。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| D8 才接通真数据，字段对不上 | 某元素真数据为空 | 按 `SPEC-U-01` §4「无数据时」列确定性降级；**不得临时改契约** |
| `A-01` 评分接口延期（D7） | D5 仍无 `HealthScore` | 首页用 `FakeRepo` 的 `HealthScore` 继续开发，评分卡标 `--` 上线前必通 |
| 首页信息过密导致首屏超 2 s | 冷启动实测 > 2 s | 砍四维下钻弹层，保留主卡片三要素 |
| Demo 数据与真实数据分数不一致 | 核对表第 6 项不通过 | 统一为 `A-04` 预置数据集（Track 2），真实数据仅作 Track 1 |
| 设计稿底栏含「我的」Tab | 底栏结构与 FF-23 冲突 | **已裁定（`ADR-12`）**：底栏 4 Tab = 首页/检测/记录/报告；「我的」为首页右上角入口（本页 §1 交付物 8），**不再需要确认** |

## 7. 与检查点的关系
- **CP2（D5）**：首页不是 D5 闭环的判据项，但 D5 端到端打通后**必须能在首页看到新记录**（闭环可见性）。
- **CP4（D7 晚）**：报告页与首页均须接通真实记录；未通则按 `PLAN-00` §2 启用 `A-04` 预置演示数据集，首页数字随之切换并显示演示标识。
- 本功能属主方案 §8.2.1 不可砍项①③的用户入口，**CP 未过时优先保首页与检测页，砍 D6–D8 增强功能**。

**文档结束**

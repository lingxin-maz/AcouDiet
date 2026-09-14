# PLAN-D-03 统计聚合查询

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-D-03 |
| 负责 | B（主责）；C 协助确认时段边界与趋势图空值口径（`PLAN-U-04`） |
| 目标日 | D7 |
| 前置依赖 | `PLAN-D-01` 的索引（必须已建立）；`PLAN-D-02` 的 `AppDatabase` 句柄与 `DietRepo`；`PLAN-P-08` 的 `foods.json` 已定稿并完成 `food_kcal` 镜像；`SPEC-D-03` §10 问题 1（时段边界）与问题 2（`source` 分流）已有书面结论 |
| 预估工时 | **11–12 h**（`API-03` §11.1 修订 A-1 的冻结工时；原估算 5 h 只覆盖 4 条 SQL + σ，**未包含 A-1 新增的 5 个方法**） |

## 1. 交付物（Deliverables）
| # | 路径 | 验收方式 |
|---|---|---|
| 1 | `app/lib/data/stats/date_range_calculator.dart` | **本地日历日**（今日 / 最近 7 个本地日历日窗口 / 近 `days` 天）的半开区间计算；**非 ISO 周**（ADR-10，见 §6 末行）；纯函数，可注入时钟与时区 |
| 2 | `app/lib/data/stats/stats_repo.dart` | `abstract class StatsRepo`（4 个既有方法 + A-1 新增 5 个方法，签名逐字照抄 `API-03` §5） |
| 3 | `app/lib/data/stats/real_stats_repo.dart` | `RealStatsRepo implements StatsRepo`：4 条既有聚合 SQL + A-1 新增的 4 条聚合查询 |
| 4 | `app/lib/data/stats/meal_time_rules.dart` | 时段判定常量与 `isSnack(hour)` / `isLateNight(hour)` / `mealSlot(hour)`（`SPEC-D-03` §4.1 的唯一实现处） |
| 5 | `app/lib/data/stats/sigma_calculator.dart` | `SPEC-D-03` §4.3 的池化标准差，纯函数（输入 `List<(slot, tMin)>`） |
| 6 | `app/test/stats/stats_repo_test.dart` | 承载 `SPEC-D-03` §7 判据 1~7、10、11、12 |
| 7 | `app/test/stats/query_plan_test.dart` | 判据 8（`EXPLAIN QUERY PLAN` 索引命中） |
| 8 | `app/test/stats/query_budget_test.dart` | 判据 9（1000 行夹具 × 100 次） |
| 9 | `app/test/stats/fixtures/stats_fixture.dart` | 固定夹具生成器（含 §7 判据 2 的 13 个边界时刻） |

> `app/` 目录由 B 在 D1 初始化（`PLAN-00` §1）；路径全部相对该根目录。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 区间计算（含时钟注入，保证测试可复现） | 交付物 1 | 0.5 h | — |
| 2 | 时段规则常量与四个判定函数 | 交付物 4 | 0.5 h | `SPEC-D-03` §10 问题 1 结论 |
| 3 | `today()` / `week()` 两条 SQL | 交付物 3 | 0.75 h | 1、2、`PLAN-D-02` |
| 4 | σ 计算（两级聚合） | 交付物 5 | 0.5 h | 2 |
| 5 | `trend(days)`（`GROUP BY` 日 + Dart 补齐） | 交付物 3 | 0.75 h | 1 |
| 6 | `mealTimes(days)`（`GROUP BY` 小时 + 24 键补齐） | 交付物 3 | 0.5 h | 1 |
| 7 | 夹具与全部测试 | 交付物 6~9 | 1.5 h | 3~6 |
| 8 | `StatsRepo.summary(DateRange)`：任意左闭右开窗口的聚合；`week()` 收敛为 `summary(最近 7 个本地日历日窗口)` 的便捷包装，两者**共用同一实现**。**纯新增，不改任何既有签名** | 交付物 2、3 | 0.5 h | 3 |
| 9 | `StatsRepo.chewStats(DateRange)`：一条 `GROUP BY` 聚合 `avg_chew_interval_seconds`（FF-22 `speed` 维的直接输入）。**纯新增，不改任何既有签名** | 交付物 2、3 | 0.5 h | 8 |
| 10 | `StatsRepo.mealTimeSamples(DateRange)`：一条 `GROUP BY` 出三餐窗口原始样本。**纯新增，不改任何既有签名** | 交付物 2、3 | 0.5 h | 8 |
| 11 | `StatsRepo.activeDays()`：一条 `COUNT(DISTINCT date(eaten_at_ms/1000,'unixepoch','localtime'))`。**纯新增，不改任何既有签名** | 交付物 2、3 | 0.5 h | 8 |
| 12 | `DietRepo.metricsByRecordId(String recordId)`：一次主键查询（占位行返回全 `null` 的 `BehaviorMetrics`，不是 `null`）。**纯新增，不改任何既有签名** | 交付物 3 | 0.5 h | `PLAN-D-02` |
| 13 | A-1 新增部分的测试：`week() ≡ summary(最近 7 个本地日历日窗口)` 逐字段等价性断言 + 5 个新方法单测 | 交付物 6 | 1 h | 8~12 |
| **合计** | **11–12 h**（修订 A-1 冻结值，`API-03` §11.1） | | **11–12 h** | |

> ⚠️ **工时口径差异登记（不自行调和，待 A/B 复核）**：本表逐项相加为 **8.5 h**，而 ADR-06 / `API-03` §11.1 冻结的 `PLAN-D-03` 工时是 **11–12 h**；且两处权威文档记的原基线是 **8 h**，与本 PLAN 原记的 **5 h** 不符。**处置：以 `API-03` §11.1 的 11–12 h 为准**（跨层契约以接口层为准），本表只补出 A-1 的 5 个方法与配套测试的拆解；**基线差异不做算术改写**。

## 3. 技术方案

### 3.1 关键骨架（≤30 行，**不写完整实现**）
```dart
// app/lib/data/stats/meal_time_rules.dart —— 时段口径的唯一实现处
const int kBreakfastStartHour = 5,  kBreakfastEndHour = 10;
const int kLunchStartHour     = 11, kLunchEndHour     = 14;
const int kDinnerStartHour    = 17, kDinnerEndHour    = 20;
const int kLateNightStartHour = 20, kLateNightEndHour = 5;   // [20,23] ∪ [0,4]

String? mealSlot(int hour) {                       // 返回正餐 slot，非正餐返回 null
  if (hour >= kBreakfastStartHour && hour < kBreakfastEndHour) return 'breakfast';
  if (hour >= kLunchStartHour     && hour < kLunchEndHour)     return 'lunch';
  if (hour >= kDinnerStartHour    && hour < kDinnerEndHour)    return 'dinner';
  return null;
}
bool isSnack(int hour)     => mealSlot(hour) == null;
bool isLateNight(int hour) => hour >= kLateNightStartHour || hour < kLateNightEndHour;
```
```dart
// app/lib/data/stats/sigma_calculator.dart —— SPEC-D-03 §4.3 的唯一实现处
double? sigmaMinutesOf(List<({String slot, int tMin})> meals) {
  if (meals.isEmpty) return null;
  final slots = meals.map((e) => e.slot).toSet();
  final n = meals.length, k = slots.length;
  if (n - k < 1) return null;                       // 分母非正 → null，绝不返回 0
  var ss = 0.0;
  for (final s in slots) {
    final g = meals.where((e) => e.slot == s).map((e) => e.tMin).toList();
    final mu = g.reduce((a, b) => a + b) / g.length;
    for (final t in g) { ss += (t - mu) * (t - mu); }
  }
  return math.sqrt(ss / (n - k));
}
```
**硬性要求**：时段窗口常量只允许出现在 `meal_time_rules.dart`；σ 公式只允许出现在 `sigma_calculator.dart`。SQL 的 `CASE` 时段判定必须与之逐值一致，并由判据 2 交叉验证。

### 3.2 实现步骤
1. `DateRangeCalculator`：以注入的 `DateTime Function()` 为"现在"，算出 `[startMs, endMs)`；**本周窗口 = 最近 7 个设备本地日历日（含今日）**，即本地今日 `00:00:00.000` 往前推 6 日的 `00:00` → 次日 `00:00`（`API-03` §5，ADR-10；**不是 ISO 周，不得以周一为周首**）；`days` 天窗口含今日。
2. `today()`：先跑计数 SQL（§4.5 骨架），再 `DietRepo.byRange(todayRange)` 填 `records`。**注意**：`records` 用 `byRange` 而不是再写一条 SQL，避免两份真相。
3. `week()`：一条 SQL 出四个计数；σ 用单独一条 SQL 取出 `(slot, t_min)` 列表后在 Dart 侧调 `sigmaMinutesOf` —— 之所以不在 SQL 里算完，是为了让 σ 有唯一实现处并可直接单测。
4. `trend(days)`：SQL `GROUP BY date(eaten_at_ms/1000,'unixepoch','localtime')` → Dart 用区间生成 `days` 个日期键逐一对齐，缺日填 `estimatedKcal: null`、`totalScore: null`。
5. `mealTimes(days)`：SQL `GROUP BY CAST(strftime('%H', …) AS INTEGER)` → Dart 补齐 `0..23`。
6. 全部 SQL 用 `?` 占位符；`WHERE` 只出现 `eaten_at_ms >= ? AND eaten_at_ms < ?`。
7. 完成后立即跑判据 8（查询计划）与判据 9（性能），**先过索引再谈性能**。

### 3.3 禁止事项（与 SPEC 同步冻结）
1. 不得实现任何评分公式、评级枚举、`HealthScore`（`SPEC-A-01`）。
2. 不得产出格式化字符串（`"85 分"` / `"约 1100 kcal"`）。
3. 不得在 `WHERE` 中对 `eaten_at_ms` 做函数包装（会破坏索引）。
4. 不得为 `source` 自行加过滤（冻结签名无该参数；分流方案见 `SPEC-D-03` §10 问题 2）。
5. 不得因 `X-07`（咀嚼节律 σ 已裁剪）而删除三餐时间 σ（同名不同物，`SPEC-D-03` §9 第 2 条）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `stats_repo_test.dart -t "stats: 空库零值"` | 单元 | 四方法返回零值/`null`/空列表，不抛异常 | 每次改 SQL |
| `stats_repo_test.dart -t "stats: 时段口径"` | 单元 | 13 个边界时刻夹具下 `snackCount` / `lateNightCount` 与独立期望值逐值相等 | 每次改 `meal_time_rules.dart` |
| `stats_repo_test.dart -t "stats: 本周汇总"` | 单元 | 四计数与热量为确切整数 | 每次改 SQL |
| `stats_repo_test.dart -t "stats: week ≡ summary"` | 单元 | 同一夹具下 `week()` 与 `summary(最近 7 个本地日历日窗口)` **逐字段相等**（`API-03` §5/§11.1 的等价性断言；`week()` 是 `summary` 的便捷包装） | 每次改 `week()` 或 `summary` |
| `stats_repo_test.dart -t "stats: A-1 新方法"` | 单元 | `chewStats`（`sampleCount==0` → `meanChewIntervalSeconds==null`）、`mealTimeSamples`（升序、值域 `0..1439`）、`activeDays()`（库内**有记录**的本地日历日数）；`metricsByRecordId` 占位行返回**全 `null` 的 `BehaviorMetrics`** 而非 `null` | 每次改这 5 个方法 |
| `stats_repo_test.dart -t "stats: sigma 公式"` | 单元 | 与测试内独立参考实现之差 `< 1e-6` | 每次改 `sigma_calculator.dart` |
| `stats_repo_test.dart -t "stats: sigma 无数据为 null"` | 单元 | `N − K == 0` 时 `isNull` 且 `!= 0` | 同上 |
| `stats_repo_test.dart -t "stats: trend 形状"` | 单元 | 长度 == `days`、`date` 严格升序、无记录日 `estimatedKcal == null`、`totalScore` 全 `null` | 每次改 `trend` |
| `stats_repo_test.dart -t "stats: mealTimes 键集合"` | 单元 | 键集合 == `{0..23}` 且计数和 == `recordCount` | 每次改 `mealTimes` |
| `stats_repo_test.dart -t "stats: 可复现"` | 单元 | 连续两次查询逐字段相等 | D7、D8 |
| `stats_repo_test.dart -t "stats: 指标占位不影响聚合"` | 单元 | 指标行全 `NULL` 前后输出逐字段相等 | D7（验证 1:1 硬约束的价值） |
| `stats_repo_test.dart -t "stats: days 越界"` | 单元 | 4 个越界调用全部抛 `ACD-DB-004`（ADR-10：跨层契约以接口层为准，`API-03` §5 冻结为 `ACD-DB-004`；**不是 `ArgumentError`**） | 每次改签名 |
| `query_plan_test.dart -t "stats: 索引命中"` | 单元 | 4/4 查询含 `USING INDEX idx_diet_record_` 且不含 `SCAN diet_record` | 每次改 SQL 或索引 |
| `query_budget_test.dart -t "stats: 查询预算"` | 单元 | 1000 行夹具下平均耗时 < 20 ms（`API-00` §3.7） | D7、D9 |
| 静态检查 `grep -rnE "分\"\|kcal\"\|良好\|需改善" app/lib/data/stats/` | 脚本 | 命中 0 | D7、D9 回归 |

## 5. 完成定义（DoD）
- [ ] `SPEC-D-03` §7 全部 14 条判据通过，证据落在上表对应测试名上。
- [ ] 时段窗口常量只存在于 `meal_time_rules.dart`，σ 公式只存在于 `sigma_calculator.dart`（评审：全局搜索无第二处）。
- [ ] `SPEC-D-03` §10 问题 1（时段边界）与问题 2（`source` 分流）已有书面结论并回填文档。
- [ ] 四条查询的 `EXPLAIN QUERY PLAN` 输出已归档为证据（判据 8），并附在 `PLAN-C-05` 的回归清单里。
- [ ] 四个方法的返回值已交付给 `PLAN-A-01`（σ 与计数）与 `PLAN-U-03` / `PLAN-U-04`（记录列表与趋势点），接口形状与 `SPEC-D-03` §3 一致。
- [ ] `trend` 的 `totalScore` 归属问题（§10 问题 4）有 A+C 结论，避免 `A-03` 与本功能各写一份填充逻辑。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 时段边界**已拍板**（`ADR-09` 修订 A-2；`API-03` §5 为唯一权威），§10 问题 1 已关闭 | 有人改回旧窗口 | **✅ 已关闭**：现行值为 早 `[05,10)` / 午 `[11,14)` / 晚 `[17,21)`、晚间 `[20:00,05:00)`（`ADR-09` 修订 A-2；`SPEC-D-03` §10 问题 1 已关闭）。**任何改动都会使 `snackCount` 与 σ 变化**，需重跑判据 2、3、4，并走 `SPEC-C-03` 变更传播 |
| 索引未被采用（判据 8 红） | 计划含 `SCAN diet_record` | 先检查 `WHERE` 是否被函数包装；再检查 `sqlite_autoindex`；仍不行则与 `PLAN-D-01` 一起调整索引，**禁止为过测试而放宽断言** |
| 性能超 20 ms（判据 9 红） | 平均耗时 ≥ 20 ms | ① 确认在 release/真机而非 debug 下测量；② 把 `trend` 的多次查询合并为一条 `GROUP BY`；③ 仍超则上报 `SPEC-D-03` §8 并走 `PLAN-C-03` 变更单，**不得**自行调大预算 |
| `source` 分流最终要求加参数 | §10 问题 2 结论为「加可选 `source`」 | 加**可选**参数（默认 `null` = 不过滤）以保持向后兼容；改 `SPEC-D-03` §3 与 `API-03` 并走 `PLAN-C-03` 变更单 |
| 无记录日 `null` 与 UI 期望不一致 | `PLAN-U-04` 反馈折线无法渲染 | 由 C 决定图表现形；若改 0，只改 `trend` 的补齐分支，**不动** SQL |
| `food_kcal` 镜像未就绪 | `estimatedKcal` 全为 0 | 先用 `source='demo'` 的预置数据验证口径；真实热量待 `PLAN-P-08` 完成后回归，**不得**在 SQL 里硬编码热量 |
| **A-1 新增方法工时不足（`API-03` §11.1）** | D7 工时不足 / `summary` / `chewStats` / `mealTimeSamples` / `activeDays` / `metricsByRecordId` 无法按期交付 | **降级顺序（照抄 `API-03` §11.1，不得调整）**：先砍 `mealTimeSamples`（改为 UI 不展示原始样本，`evidence` 留空）→ 再砍 `activeDays`（`SPEC-U-05` 显示 `-- 天`）→ **绝不砍 `chewStats` 与 `summary`**（它们直接决定分数与环比能否算出） |
| 「ISO 周」措辞残留 | 文档 / 代码评审 | ✅ **已按 ADR-10 收敛**：`week()` = **最近 7 个设备本地日历日（含今日）**，**非 ISO 周**、不得以周一为周首；本 PLAN §1 交付物 1 与本 §3.2 步骤 1 已改写，全仓不得再出现「ISO 周」提法（权威定义在 `API-03` §5） |

## 7. 与检查点的关系
- 本功能是 **CP4（D7 晚：报告页数据已接通真实记录）** 的直接判据来源之一：CP4 判据「能输出『约 45 次，偏快』（`PLAN-00` §1 的 D7 行）」依赖本功能提供的计数与时长口径，σ 则直接喂给 `SPEC-A-01` 的规律性维度。
- 本功能**不参与** CP1（D3）与 CP2（D5）：CP2 只要求 1 条记录能写入并读回，不要求聚合。
- 若 CP4 未通过：`PLAN-00` §2 的处置是「启用预置演示数据集（`A-04`），放弃真实累积」。此时本功能**照常可用**——演示数据同样落在 `diet_record` 里，四条查询不需要改动（这也是 §10 问题 2 必须在 D7 前拍板的现实原因）。
- 本功能是 `PLAN-A-01`（D7 同日晚）的硬前置：σ 与计数拿不到，评分卡无法产出数字。

---
**文档结束**
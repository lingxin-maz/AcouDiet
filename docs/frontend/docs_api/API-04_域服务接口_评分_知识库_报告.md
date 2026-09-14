# API-04 域服务接口：评分 / 知识库 / 报告 / 演示 / 自检

| 项 | 值 |
|---|---|
| 上游依据 | `SPEC-00` §3.7（FF-22 健康评分卡）、§3.9（FF-24）、§3.10（FF-25 文案红线）；`API-00` §1/§3.2/§3.3/§3.5/§3.7；`API-05` §3（数据流向）/§6（分析平面规范、可复现性、舍入）；`API-01` §2.2/§2.6/§2.8 |
| 层级位置 | `API-00` §1 分层图中的 **L4 域层 ↔ L5 表现层**（`HealthScoreService` / `AdviceEngine` / `ReportService` / `DemoController` / `DemoDataController`）；知识库查表侧归 L4 |
| 适用功能编号 | `A-01`（健康评分卡）、`A-02`（规则引擎建议）、`A-03`（周报与趋势）、`A-04`（演示数据双轨）、`M-03`（报告演示）、`M-04`（现场自检与降级面板）、`P-08`（知识库**消费**侧） |
| 权威定义 | **本文件是下列接口的唯一权威定义**：`DimensionScore`、`HealthScore`、`HealthScoreService`、`Advice`、`AdviceEngine`、`WeeklyReport`、`TrendSeries`、`ReportService`、`DemoDataController`、`DemoMode`、`SelfCheckItem`、`SelfCheckReport`、`DemoController` 的 Dart 签名与语义，以及 **`foods.json` ↔ `FoodInfo` 的字段映射与知识库消费语义**（P-08 的文案与校验规则）。 |
| 非权威（只引用，不复制签名） | `FoodInfo` / `FoodKnowledgeBase` 签名见 `API-02` §6；`DietRecord` / `UserProfile` / `TodaySummary` / `WeekSummary` / `TrendPoint` / `MealTimeDistribution` 与各 `Repo` 见 `API-03`；patch 事件、`startSession` / `injectPcm` / `getDiagnostics` 见 `API-01`；评分公式口径见 FF-22，本文件只冻结返回结构与证据键 |
| 实现计划 | `PLAN-A-01` `PLAN-A-02` `PLAN-A-03` `PLAN-A-04`、`PLAN-M-03`、`PLAN-M-04`、`PLAN-P-08` |

## 1. 分层规则与可复现性（本层两条硬闸门）
1. **L5 只能调 L4**：`U-01`/`U-04`/`U-05` 通过 Riverpod 调本层服务，**不得**直接查 SQLite，也不得直接调 `API-01` 的 MethodChannel（`API-00` §1）。
2. **纯函数语义**（`API-05` §6.1，答辩保命条款）：同一份数据库 + 同一个时间范围 → **逐字段相同**的输出。**禁止**把「当前时间」当判据（如「是否已过晚饭时间」）、禁止随机采样或近似算法、禁止 `DateTime.now()` 参与结果；输出**不含**格式化字符串（日期/百分比/时长文案由 `U-*` 层格式化，`API-00` §3.2），`summaryText` 是唯一例外（§5）。
3. **舍入**（`API-05` §6.2）：四维**各自 `round()` 为 `int` 后再求和**得 `totalScore`；**禁止**先求和再取整（否则 `26+24+15+17` 可能与总分对不上）。

## 2. 知识库消费契约（P-08；签名见 `API-02` §6）
Schema 权威文件：`docs/common/docs_api/schemas/foods.schema.json`（draft-07，`additionalProperties:false`）。
| `foods.json` 字段 | 类型 | 可空 | 映射到 `FoodInfo` | 约束 |
|---|---|---|---|---|
| 顶层键（6 个） | `String` | 否 | — | **必须恰好等于** `feature_config.class_labels` 的 6 值（FF-19）；储备类别 `nuts` **不得出现** |
| `label` | `String` | 否 | `label` | 必须与所在键名**逐字相等**（加载器断言，Schema 无法表达） |
| `zhName` | `String` | 否 | `zhName` | 必须与 FF-19 中文名逐字一致 |
| `attribute` | `String` | 否 | `attribute` | 必须与 FF-19「知识库属性」列逐字一致；该值会被**快照**进 `diet_record.attribute`（`API-03` §2） |
| `category` | `String` | 否 | `category` | 记录页次级标签（如「高加工零食」） |
| `portionDesc` | `String` | 否 | `portionDesc` | 标准份量描述（如「1 小包（约 30g）」）；**唯一合法的热量搭配** |
| `portionKcal` | `int` | 否 | `portionKcal` | 标准份量对应的估算热量（kcal），`> 0` |
| `unit` | `String` | 否 | `unit` | **`ADR-23`**：`g` 或 `ml`（桶装/瓶装液体用 `ml`）。单位是知识库事实，**不得由类别名推断**；`ml` 同时使该类别成为"液体"（既不计零食次数、也不作为三餐样本进入 σ） |
| `standardAmount` | `int` | 否 | `standardAmount` | **`ADR-23`**：`portionDesc`/`portionKcal` 所描述的量（单位见 `unit`），`> 0`。是热量按量等比缩放的分母 |
| `amountPerSecond` | `double` | 否 | `amountPerSecond` | **`ADR-23`**：整段进食的平均摄入速率（单位/秒，**含进食间停顿**），`> 0`。`PortionEstimator` 用它把本次时长换成量。**工程估计，不是营养学测量值** |
| `minAmount` / `maxAmount` | `int` | 否 | `minAmount` / `maxAmount` | **`ADR-23`**：一次进食的合理下限/上限（单位见 `unit`）。必须满足 `0 < minAmount <= standardAmount <= maxAmount`；上下限用来**夹住外推**（会话忘停不会算出五公斤的午饭） |
| `nutritionTags` | `List<String>` | 否 | `nutritionTags` | 值来自知识库，**不是**模型输出 |
| `riskNote` | `String` | 否 | `riskNote` | 建议文案素材（`A-02` 引用） |
| `icon` | `String` | 否 | —（UI 专用） | `assets/icons/` 下的文件名；**不进 `FoodInfo`**（以 `API-02` §6 的签名为准） |
**展示与文案禁令（FF-25 的结构性落地）**：① `portionKcal` **禁止孤立出现**，必须与份量说明同屏并带「估算」字样（❌ `160 kcal`；✅ `约 150 g（估算）≈120 kcal`）；**`ADR-23`**：单条记录展示的是**本次估算用量与等比热量**（`PortionEstimator`：`amount = clamp(rate × durationSeconds)`、`kcal = round(portionKcal × amount / standardAmount)`），知识库的**标准份量**另起一行（详情页「标准份量」），两者不得混为一谈；`durationSeconds <= 0` 时回退标准份量并置 `durationBased = false`（**不发明时长**）；② 食物粒度**必须落在 6 类内**，不得出现「全麦面条」「番茄」「鸡翅」；③ 不得声称测量热量/营养素，只能表述为「知识库 + 用量模型的估算」；④ 知识库查表失败**不得**静默回退默认条目。
- 错误码：`ACD-IO-002`（asset 缺失 / Schema 校验不通过，定义见 `API-02` §6）、`ACD-KB-001`（查询键非法）。线程：`load` 在启动阶段于 Dart 主 isolate 完成；查表为纯内存只读，无锁。
- 单元测试要点：① `foods.json` 键集合 `== class_labels`；② 每条 `label` `==` 键名；③ `attribute` 与 FF-19 逐行一致；④ 6 条记录的 `portionDesc` 非空且 `portionKcal > 0`；⑤ 断言 JSON 中不出现 `nuts`。

## 3. `HealthScoreService`（A-01）

```dart
class DimensionScore { int score; int max; String label; Map<String, Object?> evidence; }
class HealthScore {
  int totalScore; String grade; // '良好' | '一般' | '需改善'
  DimensionScore regularity; DimensionScore structure; DimensionScore snack; DimensionScore speed;
  int? deltaVsYesterday;
}
class HealthScoreService { Future<HealthScore> score({required DateRange range}); }
```
| `score` 参数 | 类型 | 可空 | 默认 | 单位 | 约束 |
|---|---|---|---|---|---|
| `range` | `DateRange` | 否 | — | epoch 毫秒 | 左闭右开（`API-03` §4）；跨日换算由调用方完成 |
| `HealthScore` 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|
| `totalScore` | `int` | 否 | 分 | `[0,100]` = 四维**各自 `round()` 后**之和；满分与公式见 FF-22，本文件不复制字面值 |
| `grade` | `String` | 否 | — | 枚举 **`'良好'` / `'一般'` / `'需改善'`**（FF-22）；**不得**新增第四值 |
| `regularity` / `structure` / `snack` / `speed` | `DimensionScore` | 否 | — | 四维齐全，**不允许**缺维度或 `null`；`max` 取自 FF-22 权重 |
| `deltaVsYesterday` | `int` | **是** | 分 | **`ADR-23`：本窗口 − 上一等长窗口**的 `totalScore`（1 天窗口 = 前一天；首页与报告页的 7 天窗口 = 前 7 天，由 `DateRange.previous` 决定，**不再写死"窗口前一天"**）。**三种取值语义严格区分，不得混用**：`null` = 上一窗口**无有效数据**（`U-01`/`U-04` **隐藏该行**）；`0` = 上一窗口有数据且**确实持平**（`U-01`/`U-04` **必须显示「持平」**，**不得隐藏、不得省略**）；其余 = 实际差值。**不得**用 `0` 代替 `null`（ADR-10） |
| `DimensionScore` 字段 | 类型 | 可空 | 约束 |
|---|---|---|---|
| `score` | `int` | 否 | `[0, max]`，由 FF-22 公式计算后 `round()` |
| `max` | `int` | 否 | FF-22 权重（`feature_config.health_score_weights`） |
| `label` | `String` | 否 | 中文维度名，**四维固定**：「饮食规律性」「食物结构」「零食控制」「进食速度」（与 `U-01`/`U-04` 雷达轴一致） |
| `evidence` | `Map<String,Object?>` | 否 | 下钻依据，**键集必须与下表逐维完全一致**（`U-04` 下钻与 `PLAN-A-01` 单测依赖） |
`evidence` 权威键集（**键集即契约，缺键/多键均为违约**）：
| 维度 | 键（类型，可空） | 说明 |
|---|---|---|
| `regularity` | `sigmaMinutes`（`double?`）、`mealTimeSamples`（`int`）、`windowDays`（`int`） | `sigmaMinutes` = `WeekSummary.mealTimeStdDevMinutes`（口径权威在 `API-03` §5.3）；另两键为有效餐次样本数与窗口天数 |
| `structure` | `healthyRatio`（`double`）、`healthyCount`（`int`）、`totalCount`（`int`） | 分子为 FF-22 指定的三类（`cabbage` + `carrot` + `noodles`）；分母为 0 时 `healthyRatio = 0.0` |
| `snack` | `snackCount`（`int`）、`lateNightCount`（`int`） | 取 `WeekSummary` 的**本周**口径（FF-22） |
| `speed` | `avgChewIntervalSeconds`（`double?`）、`sampleCount`（`int`）、`missingMetricsCount`（`int`） | 无有效指标为 `null`；`missingMetricsCount` 统计指标为占位行（全 `NULL`）的记录数，**必须暴露**否则无法解释分母 |
- 错误码：`ACD-DB-003` / `ACD-DB-004`（`API-03` §9，读路径失败）、`ACD-KB-001`（热量查表失败）、`ACD-SCORE-001`（新增：输入不足以按 FF-22 给出某一维确定值 → `retryable=false`，`detail.dimension` 指明维度）。
- 线程：Dart 主 isolate（`API-00` §3.7：周级聚合数据量小，无需 isolate）。
- 单元测试要点：① 四维 `score ≤ max` 且 `totalScore ==` 四维 round 后之和；② 预置演示数据集算出的分数**逐字段等于** `U-01`/`U-04` 显示的数字（FF-22 硬约束，`SPEC-C-05` 断言）；③ 同库连跑两次输出逐字段相等；④ `evidence` 键集与上表全等（多键/缺键均失败）；⑤ 昨日无数据时 `deltaVsYesterday == null`（不是 `0`）。

## 4. `AdviceEngine`（A-02）

```dart
class Advice { String dimension; String text; int priority; }
class AdviceEngine { Future<List<Advice>> generate({required HealthScore score, required WeekSummary agg}); }
```
| `generate` 参数 | 类型 | 可空 | 默认 | 约束 |
|---|---|---|---|---|
| `score` | `HealthScore` | 否 | — | 必须来自 §3；**不得**在建议引擎内重算分数 |
| `agg` | `WeekSummary` | 否 | — | 来自 `API-03` §5，用于取原始计数（规则引擎不查库） |
| `Advice` 字段 | 类型 | 可空 | 约束 |
|---|---|---|---|
| `dimension` | `String` | 否 | 枚举 **`'regularity'` / `'structure'` / `'snack'` / `'speed'` / `'general'`**；前四值必须与 `HealthScore` 四维键同名 |
| `text` | `String` | 否 | 中文正文；**不得**含绝对化表述（FF-25），不得含诊断/治疗语句 |
| `priority` | `int` | 否 | `≥ 1`，**数值越小越靠前**；同 `priority` 时按 `dimension` 固定顺序（四维顺序 + `general` 最后）稳定排序 |
- 返回：`Future<List<Advice>>`，可为空列表（数据不足时不编造建议）。**免责声明强制项**：列表**必须恰好包含一条** `dimension == 'general'` 的免责声明项，且其 `priority` 为全表最大（排最后），**不因数据不足而省略**。
- 错误码：`ACD-SCORE-001`（`score` 为不可计算的残缺对象）、`ACD-KB-001`（引用 `riskNote` 时知识库未加载）。线程：Dart 主 isolate。
- 单元测试要点：① 恰好一条 `general` 且排最后；② 任一维度低于满分时至少产出该维度一条建议（判定阈值由 `SPEC-A-02` 冻结）；③ 同输入两次输出顺序与文本完全一致（无随机）；④ 断言文案不含 FF-25 禁用词（`准确识别`/`零操作`/`完全无感`/`测热量`）。

## 5. `ReportService`（A-03）

```dart
class WeeklyReport { DateRange range; String summaryText; List<Advice> advices; HealthScore score; Map<String, num> deltas; }
class TrendSeries { List<TrendPoint> points; }   // TrendPoint 定义见 API-03 §5
class ReportService {
  Future<WeeklyReport> weekly({required DateRange range});
  Future<TrendSeries> trend({required int days});
}
```
| 方法 | 参数 | 返回 | 约束 |
|---|---|---|---|
| `weekly` | `range`（`DateRange`，非空） | `WeeklyReport` | 单次调用内**只读一次库**（不得对同窗口重复查询） |
| `trend` | `days`（`int`，非空，`[1,365]`） | `TrendSeries` | 从 `StatsRepo.trend(days)` 取序列，并**在 L4 填充** `TrendPoint.totalScore`（`API-03` §5 明确 L3 恒为 `null`） |
| `WeeklyReport` 字段 | 类型 | 可空 | 约束 |
|---|---|---|---|
| `range` | `DateRange` | 否 | 原样回传入参，便于 UI 标注窗口 |
| `summaryText` | `String` | 否 | **允许的唯一文案字段**（`API-00` §3.2 例外）：一句中文小结，≤60 字；数据不足时写「数据不足，继续记录即可看到趋势」，**不得**编造数字 |
| `advices` | `List<Advice>` | 否 | 直接来自 §4，含免责声明项 |
| `score` | `HealthScore` | 否 | 直接来自 §3，**不得**在报告层改写任何分数 |
| `deltas` | `Map<String,num>` | 否 | 环比差值（本期 − 上一等长窗口），**必须包含全部 7 个键**：`totalScore`、`regularity`、`structure`、`snack`、`speed`、`recordCount`、`estimatedKcal`；无对比基准时值为 `0`（数值型，非 `null`）；是差值不是比率 |
- `TrendSeries.points`：长度 `== days`，按日期**升序**且连续无缺口（`API-03` §5）；`estimatedKcal == null` 表示该日无记录。
- 错误码：`ACD-DB-003` / `ACD-DB-004`（`API-03` §9）、`ACD-SCORE-001`（内部评分失败）、`ACD-UNK-000`。线程：Dart 主 isolate；**禁止**在 `build()` 中调用（由 Riverpod `AsyncNotifier` 承载，`PLAN-A-03`）。
- 单元测试要点：① `deltas` 键集恰为 7 个；② `points.length == days` 且日期连续升序；③ 无记录日的 `estimatedKcal == null` 而非 `0`；④ 同库两次 `weekly` 输出逐字段相等；⑤ `trend` 的 `totalScore` 与 `HealthScoreService.score` 对同一日的结果一致。

## 6. `DemoDataController`（A-04，⚠️ 降级交付：演示数据双轨）

```dart
class DemoDataController {
  Future<void> loadDemoDataset();
  Future<void> clearDemoDataset();
  bool get isDemoActive;
}
```
| 方法 | 返回 | 语义（本文件冻结） |
|---|---|---|
| `loadDemoDataset` | `Future<void>` | 读 `app/assets/demo_dataset.json`（登记于 `API-05` §7）→ 校验（`docs/common/docs_api/schemas/diet_record.schema.json` + 自洽性）→ 以 `source == 'demo'` **单事务批量**写入（复用 `DietRepo.insertSession`，`API-03` §4；指标行遵守 1:1，缺指标写占位行）。重复调用幂等（先清后写） |
| `clearDemoDataset` | `Future<void>` | **只删除 `source == 'demo'` 的行**，真实累积数据（`source == 'real'`）一条不动。**只能在 `API-03` §4 的冻结方法内实现**（建议：`byRange` 全量扫描 → 过滤 `source == 'demo'` → 逐条 `deleteById`）；**不得**为此新增 `DietRepo` 方法（如需新增须走 `API-00` §3.9 变更流程） |
| `isDemoActive` | `bool` | `true` ⇔ 库内存在 `source == 'demo'` 的记录。**同步 getter**：只读已缓存状态，不得在 getter 内发起查询（由 `load`/`clear` 或页面进入时刷新缓存） |
- 记录自洽性硬要求（校验必须覆盖）：`eatenAtMs ≤ endedAtMs`；`durationSeconds` 与两者之差一致；`classLabel` 与 `classId` 在 FF-19 中同序；`confidence ∈ [0,1]`。
- 错误码：`ACD-DEMO-002`（**新增**：演示数据集缺失/校验失败/自洽性不通过）、`ACD-DB-003`、`ACD-DB-004`、`ACD-IO-002`。
- 单元测试要点：① `loadDemoDataset()` 后 `isDemoActive == true` 且记录数等于数据集条目数；② `clearDemoDataset()` 后 `source == 'real'` 的行数**不变**；③ 二次 `loadDemoDataset()` 不重复 `recordId`（不触发 `ACD-DB-002`）；④ 演示数据算出的评分与 UI 数字一致（FF-22 硬约束）。

## 7. `DemoController` 与现场自检（`M-01`~`M-04`）

```dart
enum DemoMode { realtime, sampleAudio, reportOnly }
class SelfCheckItem { String key; String label; bool passed; String observed; String? hint; }
class SelfCheckReport { bool allPassed; List<SelfCheckItem> items; }
class DemoController {
  DemoMode get currentMode;
  Future<void> switchTo(DemoMode mode);
  Future<SelfCheckReport> runSelfCheck();
  Future<void> startRealtimeSession();
  Future<void> startSamplePlayback({required String assetPath});
  Future<void> loadReportDemo();
}
```
- `currentMode`：只读，默认 `realtime`；**会话运行中不得切换** → `ACD-DEMO-003`。`switchTo`：按 §7.2 表判定，非法迁移 → `ACD-DEMO-003`（`retryable=false`）。
- `runSelfCheck`：见 §7.1；**任何单点失败都不得抛出**（由返回值承载），只有严重不可恢复错误才抛异常。
- `startRealtimeSession`：生成 `sessionId`（规则见 `API-00` §3.4，**Dart 侧生成**）→ `API-01` §2.3 `startSession` → 进入 `P-05`/`P-06` 管线；错误码透传 `ACD-PERM-001` / `ACD-PERM-002` / `ACD-AUD-001` / `ACD-AUD-002` / `ACD-SESS-002`。
- `startSamplePlayback`：`assetPath`（`String`，非空）**必须**走 `API-01` §2.6 `injectPcm(feedRealtime: true)` 注入环形缓冲，**禁止**「播放音箱 → 麦克风回收」（`API-01` §2.6 硬约束）；解码失败 → `ACD-DEMO-001`。
- `loadReportDemo`：等价 `DemoDataController.loadDemoDataset()` + `switchTo(DemoMode.reportOnly)`；数据集校验失败 → `ACD-DEMO-002`。

### 7.1 自检项（`key` / `label` 权威清单，`M-04` 面板按此顺序渲染 **14 项**）
| # | `key` / `label` | 判定依据 | 失败时 `hint` |
|---|---|---|---|
| 1 | `permission` / 录音权限 | `API-01` §2.2 的 `granted` | 永久拒绝 → 「去设置」；否则「重试授权」 |
| 2 | `mic` / 麦克风可用 | `API-01` §2.8 `micAvailable == true && micInUse == false`；`micInUseKnown == false` 时 `observed = '未启用麦克风'` 且**不判失败** | 「关闭其他录音应用」 |
| 3 | `model` / 模型已加载 | `InferenceEngine.isLoaded == true` | 「重试加载模型」（对应 `ACD-INF-001`） |
| 4 | `delegate` / 推理后端 | `delegateInUse ∈ {'xnnpack','nnapi','cpu'}`；`cpu` **仍算通过**（FF-18 允许回退），但 `observed` 必须显示实际值 | —（回退不是失败） |
| 5 | `featureConfig` / 特征配置一致 | `API-00` §3.6 握手已缓存且一致；不一致 → `ACD-CFG-001`，**禁止进入检测页** | 「重启应用；仍失败则禁止演示」 |
| 6 | `db` / 数据库可用 | `DietRepo.countAll()` 不抛错 | 「重启应用」 |
| 7 | `knowledge` / 知识库已加载 | `FoodKnowledgeBase.all.length == 6` | 「检查 assets/foods.json」 |
| 8 | `tempAudio` / 临时音频残留 | `MaintenanceRepo.countTempAudioFiles() == 0`（返回 `-1` → `passed=false`，`observed` 标「不可判定」） | 「手动清理或重启」 |
| 9 | `sampleAudio` / 示例音频可用 | 当前模式为 `sampleAudio` 时校验 `assetPath` 可解码；**其他模式下 `passed=true` 且 `observed='未启用'`** | 「改用实时模式」 |
| 10 | `session` / 当前会话状态 | `API-01` §2.8 的 `sessionState`；运行中为 `RUNNING`，无会话为 `IDLE` | 「先停止当前会话」 |
| 11 | `modelInfo` / 模型版本与 `n_frames` | `getDiagnostics().modelVersion` 与 `modelNFrames` 均非 `null`，且 `modelNFrames` **等于握手实际值**（**不得硬编码 129**，见 `SPEC-00` §3.5） | 「重试加载模型」 |
| 12 | `envelope` / 行为包络通道 | `getEnvelopeCapability().supported == true`，且 `envelopeLength` 与 `startSession` 出参一致（FF-21h） | 「行为指标将不可用」（`ACD-BEH-001`） |
| 13 | `dropRate` / 推理丢帧比例 | `patchesEmitted > 0` 时 `droppedPatches / patchesEmitted ≤ 0.05`（`API-01` §3.3）；`patchesEmitted == 0` 时 `passed=true`、`observed='无会话数据'` | 「提高推理步长至 1.0 s」（`PLAN-P-05`） |
| 14 | `demoData` / 预置演示数据就绪 | `SPEC-A-04` 的 `app/assets/demo_dataset.json` 可解析且标识与库内状态一致 | 「改用实时模式」（Mode C 兜底失效） |

- `SelfCheckReport.allPassed` ⇔ `items` 中**每一项** `passed == true`；`items` 必须包含上表**全部 14 项**且顺序一致。`observed` 为可机读观测值（如 `'xnnpack'`、`'granted'`），**不得**为空字符串；`hint` 可空，仅失败项必须给出可执行动作。
- **第 1–9 项是基础集，第 10–14 项是 `SPEC-M-04` 现场判定所必需**。第 10/11/12/13/14 项的引入原因是：主方案 §9 的现场降级判据需要「会话状态 / 模型版本与 `n_frames` / 丢帧比例 / 演示数据就绪」四类信息，而基础集覆盖不到。**这 5 项不是可选扩展** —— `SPEC-M-04` 的现场 SOP 依赖它们来区分「麦克风问题」与「模型问题」。
- 第 3 与第 11 项分工：第 3 项判「模型能否用」，第 11 项判「用的是哪一个模型、输入形状对不对」。**两者都要有**，因为它们失败时的现场动作不同（前者切 Mode C，后者禁止演示）。

### 7.2 模式状态机（`M-01`~`M-03`）
| 迁移 | 触发 | 允许 | 前置条件 |
|---|---|---|---|
| `realtime → sampleAudio` | `switchTo` | ✅ | 无活跃会话 |
| `realtime → reportOnly` | `switchTo` / `loadReportDemo` | ✅ | 演示数据集已加载 |
| `sampleAudio → realtime` / `→ reportOnly` | `switchTo` | ✅ | 注入管线已停止 |
| `reportOnly → realtime` | `switchTo` | ✅ | 无 |
| 任意 → `reportOnly` | `switchTo` | ❌ | 数据集未加载 → `ACD-DEMO-003` |
| `X → X`（同模式） | `switchTo` | ✅ | 幂等空操作 |
| 会话运行中 → 任意模式 | `switchTo` | ❌ | `ACD-DEMO-003`；须先 `stopSession`（`API-01` §2.5） |
- 错误码：`ACD-DEMO-001`（`API-00` §3.5）、`ACD-DEMO-002`（新增）、`ACD-DEMO-003`（**新增**：模式切换非法）、`ACD-CFG-001`、`ACD-INF-001`、`ACD-PERM-001/002`、`ACD-IO-001`。
- 线程：控制面在 Dart 主 isolate；模式切换**必须 `await` 会话停止完成**，不得乐观切换（否则保留两份聚合状态，而 `API-01` §3.1 只允许一个活跃订阅）。
- 单元测试要点：① `runSelfCheck()` 返回 **14 项**且顺序一致；② 人为断开模型 → `model.passed == false` 且 `hint` 非空、`allPassed == false`，**但不抛异常**；③ 会话运行中 `switchTo` → `ACD-DEMO-003`；④ `delegate == 'cpu'` 时 `passed == true`；⑤ 示例音频缺失 → `ACD-DEMO-001`；⑥ `skipAudioRecord=true` 的会话下 `mic` 项 `passed == true` 且 `observed == '未启用麦克风'`（**不得判失败**）；⑦ 未调用 `setDiagnosticsModelInfo` 时 `modelInfo.passed == false` 而非抛异常；⑧ 把推理延迟人为调到 2 s → `dropRate.passed == false` 且 `hint` 指向提高推理步长。

## 8. 错误码清单（本层全部可能抛出项）

| 错误码 | 触发 | `retryable` | 来源 |
|---|---|---|---|
| `ACD-PERM-001` / `ACD-PERM-002` | 录音权限被拒绝 / 被永久拒绝 | `false` | `API-00` §3.5 |
| `ACD-AUD-001` / `ACD-AUD-002` | `AudioRecord` 初始化失败 / 设备被占用 | `true`（重试 1 次）/ `false` | `API-00` §3.5 |
| `ACD-SESS-002` | 会话状态迁移非法 | `false` | `API-00` §3.5 |
| `ACD-CFG-001` | 原生端与 Dart 端 `feature_config` 不匹配（**fail fast**，禁止进入检测页） | `false` | `API-00` §3.5 |
| `ACD-INF-001` / `ACD-INF-004` | 模型加载失败 / 未加载即推理（定义见 `API-02` §8） | `true` / `false` | `API-02` §8 |
| `ACD-DB-003` / `ACD-DB-004` | 事务失败 / 入参非法或表列缺失（定义见 `API-03` §9） | `true` / `false` | `API-03` §9 |
| `ACD-KB-001` | 知识库查询键非法（定义见 `API-02` §6） | `false` | `API-02` §8 |
| `ACD-IO-001` / `ACD-IO-002` | 临时音频清理失败（不阻断）/ assets 资源缺失或 Schema 校验失败 | `false` | `API-00` §3.5 / `API-02` §8 |
| `ACD-DEMO-001` | 示例音频缺失或损坏 | `false` | `API-00` §3.5 |
| `ACD-DEMO-002` | 演示数据集缺失 / 字段校验或自洽性校验失败 | `false` | ⚠️ **新增，需补登 `API-00` §3.5** |
| `ACD-DEMO-003` | 演示模式切换非法（会话运行中 / 前置数据未就绪） | `false` | ⚠️ **新增，需补登 `API-00` §3.5** |
| `ACD-SCORE-001` | 评分输入不足以按 FF-22 给出确定值（`detail.dimension` 指明维度） | `false` | ⚠️ **新增区域 `ACD-SCORE`，需补登 `API-00` §3.5** |
| `ACD-UNK-000` | 未分类 | `false` | `API-00` §3.5 |
> 本文件**未修改** `API-00`（其 §3.5 是错误码权威表）；上表 3 个新增码须先补登 `API-00` §3.5 才生效。

## 9. 开放问题（拍板状态）

| # | 问题 | 影响 | 结论 |
|---|---|---|---|
| 1 | ✅ **已关闭（依据 `ADR-P2`）** 原问题「FF-22 只冻结 `grade` 三值枚举，**未冻结分档阈值**」 | `HealthScoreService` 无法实现，UI 评级文案无依据 | **已裁定**：`总分 ≥ 80 → 良好`、`60–79 → 一般`、`< 60 → 需改善`，登记为 `SPEC-00` §3.7 **FF-22b**；机器可读值在 `feature_config.health_score_formula.grade_thresholds`。**本文件照此实现，不再是缺口** |
| 2 | `structure` 的分子类别集与 `speed` 的聚合方式（窗口内多餐如何加权） | 直接影响两维分数 | 分子以 FF-22 的 `cabbage + carrot + noodles` 为准；`speed` 建议按记录级加权（以 `durationSeconds` 为权）；均须 `SPEC-A-01` 确认 |
| 3 | 免责声明的具体文案 | `A-02` 的 `general` 项文本 | 由 `SPEC-A-02` 冻结；本文件只冻结「恰好一条 + 排最后」的结构约束 |
| 4 | `A-04` 演示数据集的条目数；`clearDemoDataset` 无专用 Repository 方法 | 加载与清除的实现规模 | 条目数由 `SPEC-A-04` 冻结（本文件不写数字，避免破坏 FF-22 一致性测试）；若演示记录规模增大，应按 `API-00` §3.9 为 `API-03` 增加 `deleteBySource` |

## 变更影响

| 类型 | 受影响对象 |
|---|---|
| SPEC | `SPEC-A-01`（四维公式与 `evidence` 键）、`SPEC-A-02`（建议规则与免责声明）、`SPEC-A-03`（周报/趋势字段）、`SPEC-A-04`（演示数据集）、`SPEC-M-03`/`SPEC-M-04`（自检 14 项）、`SPEC-P-08`（`foods.json` 字段与文案）、`SPEC-U-01`/`SPEC-U-04`/`SPEC-U-05`（展示字段来源）、`SPEC-D-04`（档案与开关） |
| PLAN | `PLAN-A-01`~`PLAN-A-04`、`PLAN-M-03`、`PLAN-M-04`、`PLAN-P-08`、`PLAN-U-01`、`PLAN-U-04`；变更登记归 `PLAN-C-03` |
| Schema | `docs/common/docs_api/schemas/health_score.schema.json`（五结构必须同步）、`docs/common/docs_api/schemas/foods.schema.json`、`docs/common/docs_api/schemas/diet_record.schema.json`（演示数据集复用） |
| 测试 | `SPEC-C-05` 的「预置演示数据分数 == UI 数字」断言、`PLAN-A-01` 可复现性测试、`API-05` §12 判据 7（同库两次评分相等） |
| 上游需同步 | 动 §7.1 自检项清单 → 同步 `API-01` §2.8 的 `getDiagnostics` 字段；动知识库字段 → 同步 `API-02` §6 与 `SPEC-P-08` |

## 明确不做

| 不做 | 理由 |
|---|---|
| 在 L4 产出格式化字符串（除 `summaryText`） | `API-00` §3.2：日期/百分比/时长格式化归 `U-*` |
| 任意更改类别（`X-02` 全量形态） | v1.0 仅 A/B 二选一确认（FF-25 术语禁令） |
| 成就解锁系统（`X-04`） | 降级为静态展示；本层**不提供**任何解锁判定接口 |
| 咀嚼节律 σ（`X-07`） | 已裁剪；`evidence` 中**不得**新增该键 |
| 医疗/诊断类建议、疾病风险预测 | FF-25 与 `A-02` 边界；只做生活方式提示 |
| 使用「当前时间」作为评分判据 | 违反 `API-05` §6.1 可复现性 |
| 「播放音箱 → 麦克风回收」式示例演示 | `API-01` §2.6 硬性禁止（二次采集不可控） |
| 云端 LLM 健康助手 | 唯一需要云端的项，属 `API-05` §9 预留（状态 `DISABLED`） |
| CSV 导出 / 分享（`X-03`） | 已裁剪，入口置灰标「v1.1」 |
| 把「营养素/热量测量」写进任何返回字段或文案 | FF-25：只能表述为「知识库 + 标准份量的估算」 |

**文档结束**

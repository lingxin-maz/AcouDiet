# SPEC-U-06 设计系统与图表组件

| 项 | 值 |
|---|---|
| 域 | `U` · 界面 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1 §3.4.2 §8.2；`docs/00_功能清单与数量分析.md` §2 域 U / §3；`SPEC-00` §3.3/§3.7/§3.8/§3.10 |
| 依赖的 SPEC | 无（本功能是 `SPEC-U-01`~`SPEC-U-05` 的共同前置） |

## 1. 目标与范围
### 1.1 一句话目标
冻结 v1.0 全部页面共用的主题、色板、6 类食物图标与四类图表 + 三类状态 + 条目卡片组件的**构造签名与状态枚举**，使 `U-01`~`U-05` 可并行实现且视觉一致。

### 1.2 范围内（In Scope）

| # | 交付组件 | 用途 | 消费者 |
|---|---|---|---|
| 1 | `AcouTheme`（MD3 主题 + 语义色 + 间距/圆角/字号 token） | 全局外观 | `U-01`~`U-05` |
| 2 | `FoodIcon`（6 类食物图标映射） | 记录条目、检测卡片 | `U-01` `U-02` `U-03` |
| 3 | `FourDimRadar` / `TrendLineChart` / `WaveformView` | 四维雷达 / 趋势折线 / 实时波形 | `U-01` `U-04` / `U-04` / `U-02` |
| 4 | `StateView`（空 / 加载 / 错误三合一） | 全部页面的无数据分支 | `U-01`~`U-05` |
| 5 | `RecordCard`（含标准模板三行布局） | 今日记录列表、时间轴 | `U-01` `U-03` |
| 6 | `ConfidenceChip`（按置信度档位上色） | 记录条目、检测页 | `U-02` `U-03` |
| 7 | `AcouFormat`（纯格式化工具，不产数据） | 分数/热量/时长/时间/百分比 | `U-01`~`U-05` |
| 8 | 组件级 widget test（6 类图标全覆盖、四轴标签、营养素词零命中） | 验收 | 全员 |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
- **不承载任何业务逻辑与数据获取**：组件只接收已算好的值，不调用 Repository、不调 MethodChannel（`API-00` §1 分层规则）。
- **不做营养素可视化**：蛋白质 / 脂肪 / 碳水化合物 / 膳食纤维的任何图表、进度条、徽章一律不做（主方案 §3.4）。
- **不做热量目标进度条**（`1.png` 的 `1286/2000 kcal` 进度条删除，见 §9）。
- **不做**成就解锁动画或进度环（`X-04`）、检测页识别历史列表组件（`X-05`）、CSV / 文件导出组件（`X-03`）。
- **不新增 App 内页面**（页面数冻结为 4，FF-23）；组件预览一律通过 `flutter test` 的 widget test 完成。

## 2. 功能行为
### 2.1 触发与前置条件
- 全部组件：`AcouTheme` 已在 `MaterialApp` 根注入；字号缩放（`textScaler`）不导致溢出。
- `FourDimRadar`：收到 4 个 `DimensionScore`，`score` ∈ [0, `max`]（`max` 见 FF-22）。
- `TrendLineChart`：收到 `List<TrendPoint>`，每点 `estimatedKcal` 与 `totalScore` 至少一项非空。
- `WaveformView`：收到 `level` 事件的 `rms`（`API-00` §3.3）；无事件时进入静默态。
- `RecordCard`：收到 1 条 `DietRecord` + 对应 `FoodInfo`。

### 2.2 主流程（编号步骤）
1. 页面从 Riverpod Provider 取到已算好的值（分数 / 趋势 / 记录列表）。
2. 页面按「有数据 / 无数据 / 加载中 / 出错」四选一分派到具体组件或 `StateView`。
3. `AcouFormat` 把数值转成冻结格式的字符串（§4.3），**不在页面内散写格式化逻辑**。
4. 组件渲染并按 §2.3 的枚举切换内部状态，同时为图表构造**文本等价物**交给 `Semantics`（§8）。

### 2.3 状态与状态迁移
```dart
enum ViewStatus { idle, loading, ready, empty, error }   // U-01~U-05 共用
enum ChartAxis { score, kcal }                            // TrendLineChart 纵轴口径
enum ConfidenceTier { high, medium, low, none }            // 阈值见 FF-20
enum FoodClassId { chips, cabbage, gummies, noodles, carrot, drink }  // 与 FF-19 逐字一致
```
| 当前态 | 事件 | 下一态 | 说明 |
|---|---|---|---|
| `idle` → `loading` | 首次请求发起 | `loading` | `StateView(loading)` |
| `loading` | 返回空集合 / 非空 / 抛 `AcouDietError` | `empty` / `ready` / `error` | 空态显示文案而非 0 值骨架；错误态显示 `code` 对应的可读文案 |
| `ready` | 数据被清空（`D-05`） | `empty` | 不得残留上一份数据 |
| `empty` | 新数据写入 | `ready` | — |

### 2.4 边界条件
- `totalScore = 0` 或 `100` 时雷达不塌陷为一点、不超出外框。
- 单日只有 1 个趋势点：折线退化为单点标记 + 数值，不画线；空洞日（`null`）**断线不插值**（插值等于编造数据）。
- `confidence` 恰为 0.45 或 0.70：按 FF-20 闭区间判定为 `medium`（0.45 ≤ p < 0.70）；边界须有 widget test。
- 食物名超长：单行省略号截断，完整名称放语义标签，禁止换行撑破卡片。
- 系统字号 200%：卡片高度自适应，不出现文字裁切。
- 无 `FoodInfo` 命中（`classId` 越界）：占位图标 + `未知类别`，**不得猜测名称**。

## 3. 接口契约
> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 组件 ← 页面 | `FourDimRadar({required HealthScore score})` | `HealthScore` | `Widget` | 无 |
| 组件 ← 页面 | `TrendLineChart({required List<TrendPoint> points, required ChartAxis axis})` | 趋势点、轴口径 | `Widget` | 无 |
| 组件 ← 页面 | `WaveformView({required Stream<double> rms, double barCount})` | 电平流（0–1 线性幅度） | `Widget` | 无 |
| 组件 ← 页面 | `StateView({required ViewStatus status, String? message, VoidCallback? onRetry})` | 状态、文案、重试 | `Widget` | 无 |
| 组件 ← 页面 | `RecordCard({required DietRecord record, required FoodInfo food, VoidCallback? onTap})` | 记录 + 知识库（`byClassId` 返回**非空** `FoodInfo`） | `Widget` | 无 |
| 组件 ← 页面 | `FoodIcon({required int classId, double size})` / `ConfidenceChip({required double confidence})` | 类别 ID（FF-19）/ `[0,1]` | `Widget` | 无（越界回退占位图标） |
| 工具（纯函数） | `AcouFormat.kcalRange(int) / score(int) / duration(int) / clock(int) / percent(double) / delta(int?)` | 见 §4.3 | `String` / `null` | 无 |
| 页面 ← 域层 | `HealthScoreService.score({required DateRange range})`（`API-04` §3）/ `ReportService.trend({required int days})`（`API-04` §5，返回 `TrendSeries`）/ `FoodKnowledgeBase.byClassId(int)`（`API-02` §6） | `range` / `days` / `classId ∈ [0,6)` | `HealthScore` / `TrendSeries` / `FoodInfo`（**非空**） | `ACD-DB-*`；知识库越界抛 `ACD-KB-001` |

## 4. 数据契约
### 4.1 组件消费的冻结类（类名与字段名不得改动）
```dart
class HealthScore { int totalScore; String grade; DimensionScore regularity, structure, snack, speed; int? deltaVsYesterday; }
class DimensionScore { int score; int max; String label; Map<String, Object?> evidence; }
class DietRecord { String recordId; int eatenAtMs; int endedAtMs; String classLabel; int classId; String attribute; double confidence; int durationSeconds; String source; bool correctedByUser; }
class BehaviorMetrics { int? chewCount; double? avgChewIntervalSeconds; int? durationSeconds; String? speedGrade; }
class TodaySummary { int recordCount; int estimatedKcal; int snackCount; List<DietRecord> records; }
class WeekSummary { int recordCount; int estimatedKcal; int snackCount; int lateNightCount; double? mealTimeStdDevMinutes; }
class TrendPoint { String date; int? estimatedKcal; int? totalScore; }
class FoodInfo { String label; String zhName; String attribute; String category; String portionDesc; int portionKcal; List<String> nutritionTags; String riskNote; }
class WeeklyReport { DateRange range; String summaryText; List<Advice> advices; HealthScore score; Map<String, num> deltas; }
class Advice { String dimension; String text; int priority; }
class AggregatedDecision { VoteStage stage; int? classId; String? label; double smoothedConfidence; int consecutiveCount; bool shouldAskUser; }
enum VoteStage { observing, unconfirmed, lowConfidence, confirmed, none }
```

### 4.2 字段准入红线
- 上述类字段即**主方案 §3.4.1 UI 数据契约表**的落地形态；**表外字段不得出现在任何 widget 的构造参数、文案或语义标签中**（风险 R-19）。
- `FoodInfo.nutritionTags` 与 `riskNote` **仅在知识库详情语境（`U-03` 条目详情）可读**，且必须与模型置信度视觉分离；`U-06` 不为它们提供任何图表或徽章组件。
- `BehaviorMetrics` 的 `null` 一律渲染为 `--`，禁止用 `0` 兜底（`0` 与「未测到」语义不同）。

### 4.3 格式化规则（唯一真源，页面不得另行实现）

| 量 | 规则 | 例 |
|---|---|---|
| 总分 / 维度分 | 整数；维度先各自取整再求和（`API-05` §6.2） | `85`、`饮食规律 26/30` |
| 估算能量 | `estimatedKcal` 的 `±20%`，文案含「估算能量参考」与「约」 | `约 1100–1400 kcal` |
| 单条热量 | **必须**同时出现份量描述与「估算」字样 | `软性主食 · 1 片（估算）≈120 kcal` |
| 置信度 / 时长 | `round(p × 100)` 加 `%`；`X 分 Y 秒`（< 60 s 时 `Y 秒`） | `91%`、`4 分 23 秒` |
| 咀嚼次数 / 时钟 | 次数必须带「约」；24 小时制 `HH:mm`（设备本地时区） | `约 45 次`、`12:20` |
| 日期分组 / 变化量 | `yyyy-MM-dd` 分组，显示 `今天 / 昨天 / M月d日`；`↑12 分`；**差为 0 时返回「持平」**，仅 `null`（无昨日数据）时隐藏该行（`ADR-10`、`API-04` §3） | `今天`、`↑12 分`、`持平` |
| 无数据 | 数值类 `--`；列表类空态文案 | `--`、`今天还没有记录` |

## 5. 参数与常量
- 类别集合与顺序：`SPEC-00` §3.3 **FF-19**（6 类）；四维名称与满分：§3.7 **FF-22**（满分 30/30/20/20）。
- 置信度分档阈值：`SPEC-00` §3.4 **FF-20**（确认 ≥ 0.70；二选一 0.45–0.70；< 0.45 不记录）。
- 咀嚼次数文案与速度分级：`SPEC-00` §3.6 **FF-21e** / **FF-21f** / **FF-21g**。
- 平台与依赖：`SPEC-00` §3.8 **FF-23**（Flutter 3.24.5 / Dart 3.5.4 / `fl_chart` / Riverpod / 4 页面）；**不引入第二套图表库**。
- 文案红线：`SPEC-00` §3.10 **FF-25**；隐私约束：§3.9 **FF-24**。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `classId` 越界（脏数据） | `byClassId` 抛 `ACD-KB-001` | 捕获后占位渲染并记日志 | 灰底占位图标 + `未知类别` |
| 趋势数据点全为 `null` | 过滤后为空 | 不渲染折线 | `StateView(empty)` + `暂无足够数据` |
| 单维 `score > max`（上游脏数据） | 构造时断言 | 夹到 `[0, max]` 并记日志 | 雷达不越界 |
| 页面 Provider 抛错 | `AsyncValue.error` | 按 `AcouDietError.code` 映射文案 | `StateView(error)` + 「重试」 |
| 波形流中断 | 超过 2 s 无 `level` 事件 | 进入静默态 | 波形静止为水平线，文案切回待机 |
| 字体缺失导致方框 | 人工核对 | 回退系统字体 | 中文正常显示 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 设计系统测试全通过 | `flutter test test/widget/design_system_test.dart` | 退出码 0 |
| 2 | 雷达恰为 4 轴且标签取自 FF-22 | `test('four dim radar renders exactly 4 FF-22 axes')` | 轴数 == 4，标签集合 == {饮食规律性, 食物结构, 零食控制, 进食速度} |
| 3 | 6 类图标全覆盖、无第 7 类 | `test('FoodIcon covers exactly 6 FF-19 classes')` | 覆盖 6 类；越界入参渲染占位图标 |
| 4 | 营养素与表外字段零命中 | `rg -n "蛋白质\|脂肪\|碳水化合物\|膳食纤维\|全麦\|纯牛奶\|番茄\|鸡翅\|面条" lib/presentation/` | 命中数 == 0 |
| 5 | 热量文案必带份量与「估算」 | `test('RecordCard kcal text always has portion and estimate marker')` | 含 `（估算）` 且含 `FoodInfo.portionDesc` |
| 6 | 置信度分档边界 | `test('ConfidenceTier boundary 0.45 and 0.70')` | 0.45→medium；0.699→medium；0.70→high；0.449→low |
| 7 | 四态可渲染 | `test('StateView renders idle/loading/empty/error')` | 4 态各有独立语义标签，无异常 |
| 8 | 趋势空洞不插值 | `test('TrendLineChart does not interpolate null points')` | 渲染 spot 数 == 非空点数 |
| 9 | 无网络依赖代码 | `rg -n "http\|dio\|socket\|WebSocket\|url_launcher" lib/` | 命中数 == 0 |
| 10 | 文案红线零命中 | `rg -n "零操作\|完全无感\|识别所有食物\|准确识别食物\|2 秒内出结果" lib/` | 命中数 == 0 |
| 11 | 视觉与文案人工核对 | 见下表逐项核对表 | 全部 ✓ |

**人工核对表（`U-06` 组件层，8 项）**

| # | 核对项 | 期望 |
|---|---|---|
| 1 | 主题色板 | Material Design 3 语义色；正文对比度 ≥ 4.5:1 |
| 2 | 雷达四轴 | 四轴等分 90°，标签不重叠、不出框，且与 FF-22 四维中文名逐字一致 |
| 3 | 折线图 | 纵轴刻度单位随 `ChartAxis` 变化；**不显示热量目标线** |
| 4 | 波形组件 | 静默态为水平基线，不闪烁、不残留上一会话波形 |
| 5 | 图标风格 | 6 类图标同风格、同尺寸基线 |
| 6 | 条目卡片 | 三行结构与主方案 §3.4.1 标准模板逐行一致 |
| 7 | 空态文案 | 与各页 SPEC 指定文案逐字一致 |
| 8 | 品牌与红线 | Logo/标题为 `AcouDiet` / `声膳`；无 `EatSense` / `ChewSense`；无 FF-25 禁用词 |

## 8. 非功能约束

| 类别 | 约束 |
|---|---|
| 无障碍 | 所有可点击元素必须有 `Semantics` 标签（含动作词）；`FourDimRadar` 与 `TrendLineChart` **必须**提供文本等价物（如「饮食规律性 26 分，满分 30 分；……总分 82 分」「本周 7 天趋势：周一 1100 千卡，……，周三无数据」）；最小点击区 48×48 dp；不依赖颜色单独传达状态 |
| 性能 | 动画 60 fps；`WaveformView` 单帧重绘 ≤ 16 ms 且**只重绘自绘层**，不得整页 `setState`；`TrendLineChart` 点数 ≤ 7 |
| 内存 | 组件无长生命周期订阅；`StreamSubscription` 在 `dispose` 中取消 |
| 隐私 | 组件层不发起任何网络请求、不打点、不写文件（FF-24） |
| 包体 | 图标优先矢量（`CustomPainter` / `IconData`），位图合计 ≤ 200 KB |
| 可测性 | 全部组件可在无插件环境下用 `flutter test` 渲染（不依赖 SQLite / 麦克风） |

## 9. 裁剪与未做
- `X-03` CSV 导出：**不做**，`U-06` 不提供导出按钮组件。
- `X-04` 成就解锁：**不做**解锁进度组件与动画，`U-05` 仅静态展示。
- `X-05` 检测页识别历史列表：**不做**该列表组件（`3.png` / `10.png` 的「识别历史」模块整体删除）。
- `1.png` 的「已摄入能量 1286/2000 kcal」进度条：**不做**（营养素与热量目标均不可从模型推导）。
- 营养素图表（蛋白质 / 脂肪 / 碳水化合物 / 膳食纤维）：**不做**；四轴雷达为**行为维度**雷达。
- `3.png` / `10.png` 历史列表数值错位：模块已删除，**无需修正，也不许实现**。
- `4.png` / `5.png` 旧版稿：**作废**，以 `8.png` / `9.png` / `10.png` 为准。

## 10. 开放问题
1. ✅ **已裁定（ADR-12）**：`1.png` / `9.png` / `10.png` 底栏为「首页 / 检测 / 记录 / **我的**」，缺「健康报告」Tab，**与 `FF-23` 冲突**。**裁定：以 `FF-23` 为准** —— 底栏 **4 Tab = 首页 / 检测 / 记录 / 报告**；「**我的**」放**首页右上角入口，不做独立 Tab**。理由：① `FF-23` 是冻结事实，设计稿只是素材 ② 健康报告 + 评分卡是主方案 §8.2.1 五项「不可砍」之一，藏进二级入口会削弱其定位 ③ 主方案 §8.2.3 明确「「我的」并入首页右上角入口，不做独立 Tab」。自检面板（`M-04`）同样不得成为第 5 个页面（`SPEC-M-04` §10）。
2. **暗色主题与中文字体**：v1.0 默认仅浅色、使用系统字体（`9.png` 的加粗圆体标题无法完全复现）；是否处理需确认。
3. **`1.png` 雷达为五轴且含重复「脂肪」标签**：修正为四轴后视觉比例会变化，需确认接受与设计稿的差异（以 FF-22 为准）。

**文档结束**

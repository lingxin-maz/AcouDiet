# API-03 数据访问层接口

| 项 | 值 |
|---|---|
| 上游依据 | `SPEC-00` §3.7（FF-22 评分输入量）、§3.9（FF-24 隐私硬约束）；`API-00` §1（分层规则）/§3.2/§3.3/§3.4/§3.5/§3.7/§3.8；`API-01` §2.7/§2.8；`API-05` §3（数据分类与流向）/§5（持久平面规范） |
| 层级位置 | `API-00` §1 分层图中的 **L3 数据层**（`AppDatabase` / DAO / Repo / `FakeRepo`）；上游为 L4 域层，下游为本地 SQLite 单文件 |
| 适用功能编号 | `D-01`（数据模型与 Schema）、`D-02`（DAO 与迁移）、`D-03`（统计聚合查询）、`D-04`（本地档案与设置）、`D-05`（数据清除与残留清理） |
| 权威定义 | **本文件是下列接口的唯一权威定义**：`DateRange`、`DietRecord`、`UserProfile`、`TodaySummary`、`WeekSummary`、`TrendPoint`、`MealTimeDistribution`、`DietRepo`、`StatsRepo`、`ProfileRepo`、`MaintenanceRepo`、`FakeRepo`，以及 L3 内部 DAO 与 `KcalResolver` 端口的访问语义、事务边界与错误语义。`SPEC-D-01`~`SPEC-D-05`、`U-01`、`U-03` 只能引用编号，不得复制签名。 |
| 非权威（只引用） | **DDL（建表语句、列类型、索引、外键、`user_version`）权威归属 `SPEC-D-01`**；迁移脚本实现归 `PLAN-D-02`；`BehaviorMetrics` 签名见 `API-02` §5；`HealthScore*` 见 `API-04`；`foods.json` 见 `API-04` §2 |
| 实现计划 | `PLAN-D-01`（模型与表）、`PLAN-D-02`（DAO/迁移/FakeRepo）、`PLAN-D-03`（聚合）、`PLAN-D-04`（档案）、`PLAN-D-05`（清除） |

## 1. 四条不可违反的不变量

| # | 不变量 | 依据 | 违反后果 |
|---|---|---|---|
| **I-1** | `diet_record` 与 `behavior_metrics` **严格 1:1**：每条记录必须有且仅有一行指标；**无指标时必须写占位行**（字段为 `NULL`），**不允许缺行** | `API-05` §5「一致性红线」 | 报告页 `LEFT JOIN` 分母忽大忽小 → 四维评分不可复现 |
| **I-2** | **禁止任何 BLOB 音频列**；库内不得出现 PCM、Mel 张量、波形、音频文件路径 | FF-24 第 3 条；`API-05` §3.1 R-OUT-2 | 隐私主张崩塌 |
| **I-3** | 一次检测会话的写入 = **单事务**（1 行记录 + 1 行指标），失败整体回滚 | `API-05` §5.3/§5.5；`API-00` §3.8 | 出现「有记录无指标」脏状态 |
| **I-4** | L3 **不含业务规则**：不做评分、不生成建议、不做速度评级 | `API-00` §1 规则 3 | 评分口径分裂成两份 |

数据流向（`API-05` §3 落地）：原始 PCM 与 Mel 张量**永不进入 L3**（类别 1、2）；L3 只接收类别 4–6 的结构化字段。**线程与事务**：`sqflite` 全部在 Dart 主 isolate（`API-00` §3.7）；`Database` 句柄由 Riverpod 单例持有，`openDatabase` 全仓**只允许一处**（`API-05` §5.2）；页面查询按需进行、不预加载全表（`API-05` §5.4）；`onUpgrade` 必须**幂等且可重复执行**、升级前不得丢数据（`API-05` §5.6）；单次聚合查询目标 < 20 ms；写时机为**会话结束一次性提交**。

## 2. 模型 ↔ 表映射（`fromMap` / `toMap` 双向往返的唯一说明）

下表是本文件与 `SPEC-D-01` 的接口面：**列名与字段名一一对应，不许多列、不许空映射**；SQLite 列名 `snake_case`，Dart 字段 `lowerCamelCase`（`API-00` §3.1）。

```dart
class DietRecord {
  String recordId; int eatenAtMs; int endedAtMs; String classLabel; int classId;
  String attribute; double confidence; int durationSeconds; String source; // 'real' | 'demo'
  bool correctedByUser; bool confirmedByUser;
}
```
| 表 | Dart 字段 | 类型 | 可空 | SQLite 列 | 单位 | 约束 |
|---|---|---|---|---|---|---|
| `diet_record` | `recordId` | `String` | 否 | `record_id` | — | 主键；UUID v4（`API-00` §3.4）；重复插入 → `ACD-DB-002` |
| `diet_record` | `eatenAtMs` | `int` | 否 | `eaten_at_ms` | epoch 毫秒（UTC） | 进食**开始**时刻；`≤ endedAtMs` |
| `diet_record` | `endedAtMs` | `int` | 否 | `ended_at_ms` | epoch 毫秒（UTC） | 会话结束时刻（`API-01` §2.5 `stoppedAtMs`） |
| `diet_record` | `classLabel` | `String` | 否 | `class_label` | — | 取值 ⊆ FF-19 英文类名；**不存中文名**（展示时查知识库） |
| `diet_record` | `classId` | `int` | 否 | `class_id` | — | `[0,6)`；与 `classLabel` 在 `class_labels` 中同序（FF-19） |
| `diet_record` | `attribute` | `String` | 否 | `attribute` | — | **写入时快照**（如「脆性高加工零食」）：知识库更新后历史记录不得改口径；取值源 `FoodInfo.attribute`（`API-04` §2） |
| `diet_record` | `confidence` | `double` | 否 | `confidence` | — | `[0,1]`，来自 `AggregatedDecision.smoothedConfidence`（`API-02` §4）；**不存百分比** |
| `diet_record` | `durationSeconds` | `int` | 否 | `duration_seconds` | 秒 | `≥ 0`；无有效进食证据为 `0` |
| `diet_record` | `source` | `String` | 否 | `source` | — | 枚举 **`'real'` / `'demo'`**；Demo 预置数据必须为 `'demo'` |
| `diet_record` | `correctedByUser` | `bool` | 否 | `corrected_by_user` | — | `0/1`；`X-02` 二选一确认时置 `1`（**仅**二选一，不是任意改类别）。**✅ `ADR-P6`（2026-09-10）：本列入库保留**（Dart 侧 `DietRecord` 仍暴露 `correctedByUser`），但 **UI 不呈现「已修正」** |
| `diet_record` | `confirmedByUser` | `bool` | 否 | `confirmed_by_user` | — | `0/1`；用户点「是」为 `true`，自动确认为 `false`。**✅ `ADR-P6`（2026-09-10）：本列同样入库保留**，作分析字段（统计低置信度占比、供模型迭代）；**UI 只呈现「已确认」标记**（对应 Level-3 二选一确认过的记录），**不呈现「已修正」** |
| `behavior_metrics` | `recordId` | `String` | 否 | `record_id` | — | 主键兼外键 → `diet_record.record_id`，**`UNIQUE`**（I-1 的结构性保证）；级联删除 |
| `behavior_metrics` | `chewCount` | `int` | **是** | `chew_count` | 次 | 占位行 `NULL`；文案必须带「约」（FF-21f） |
| `behavior_metrics` | `avgChewIntervalSeconds` | `double` | **是** | `avg_chew_interval_seconds` | 秒 | 占位行 `NULL` |
| `behavior_metrics` | `durationSeconds` | `int` | **是** | `duration_seconds` | 秒 | 占位行 `NULL`；与 `diet_record.duration_seconds` 是两张表的两列 |
| `behavior_metrics` | `speedGrade` | `String` | **是** | `speed_grade` | — | 枚举 `'偏快'` / `'正常'` / `'偏慢'`（FF-21e）；**不得**新增「咀嚼节律 σ」列（`X-07`） |
**占位行规则（I-1 落地）**：`insertSession` 在 `metrics == null`、或 `metrics` 全字段为 `null` 时，**必须**写入一行全 `NULL` 指标行（`INSERT` 而非省略），且与记录行**同事务**提交。判定标准是「行是否存在」，不是「字段是否有值」。
**其余表（DDL 权威 `SPEC-D-01`）**：`user_profile` 为**单行表**（固定主键 `1`）——`load()` 在无行时返回默认档案且**不抛错**，`save()` 用 `INSERT OR REPLACE` 语义；`app_meta` 为键值表（`key TEXT PRIMARY KEY` / `value TEXT` / `updated_at_ms INTEGER`），用于 `schemaVersion`、演示数据集指纹、首次启动标记，**不得**存个人数据或音频派生量（FF-24）。
**禁止入表字段**：`zhName`、`portionDesc`、`portionKcal`、`nutritionTags`、`riskNote`（渲染时查 `foods.json`，避免知识库漂移）、任何 Mel/PCM 形态、`smoothedProbs`（`API-02` §4）。**v1.0 不设 `session_id` 列**：会话标识只存在于运行期事件与日志（`API-01` §3.2）；若 `SPEC-D-01` 要求入库，须走 `PLAN-C-03` 变更传播并在 `DietRecord` 增加同名字段。

## 3. L3 内部契约（DAO 与端口；不跨层，`U-*` 不得引用）

```dart
abstract class DietDao {
  Future<void> insert(DietRecord r, {required DatabaseExecutor txn});
  Future<List<DietRecord>> selectByRange(DateRange r);
  Future<DietRecord?> selectById(String recordId);
  Future<int> deleteById(String recordId);
  Future<int> deleteAll();
  Future<int> countAll();
}
abstract class MetricsDao {
  Future<void> insertPlaceholder({required String recordId, required DatabaseExecutor txn});
  Future<void> insert({required BehaviorMetrics m, required String recordId, required DatabaseExecutor txn});
  Future<BehaviorMetrics?> selectByRecordId(String recordId);
}
abstract class ProfileDao {
  Future<UserProfile> select();
  Future<void> upsert(UserProfile p);
}
abstract class MetaDao {
  Future<String?> get(String key);
  Future<void> put({required String key, required String value, required int updatedAtMs});
}
```
- 事务：所有写方法**必须**接收 `txn`（`DatabaseExecutor`），**不得**自行 `openDatabase`。
- 行序：`selectByRange` **必须**按 `eaten_at_ms ASC` 返回（`U-03` 时间轴依赖，不得由 UI 再排序）。
- 空态：`selectById` / `ProfileDao.select` 未命中时返回 `null` 或默认档案，**不抛错**（属正常空态）。
- 计数语义：`deleteById` / `deleteAll` / `countAll` 返回受影响行数；`deleteAll` 不触碰 `user_profile` / `app_meta`。

```dart
abstract class KcalResolver { int kcalFor(int classId); }
```
`TodaySummary.estimatedKcal` 必须在 L3 填充，但 L3 不得依赖 L4 的知识库类（`API-00` §1 规则 3），故由装配层用 `FoodKnowledgeBase`（`API-02` §6）实现本端口并注入 `StatsRepo` 实现类。`kcalFor` 对 `[0,6)` 之外或未注册的 `classId` **不得返回兜底值**，必须抛 `ACD-KB-001`（静默按 0 计会让估算热量失真且无法察觉）。

## 4. `DietRepo`（`D-01`/`D-02` 的跨层入口）

```dart
abstract class DietRepo {
  Future<void> insertSession({required DietRecord record, required BehaviorMetrics? metrics});
  Future<List<DietRecord>> byRange(DateRange r);
  Future<DietRecord?> byId(String recordId);
  Future<int> deleteById(String recordId);
  Future<int> deleteAll();
  Future<int> countAll();
  // --- v1.0 修订 A-1 新增（裁定见 §11.1）---
  Future<BehaviorMetrics?> metricsByRecordId(String recordId);
}
class DateRange { int startMs; int endMs; }
```
| 方法 | 参数（名/类型/可空/单位） | 返回 | 约束与错误码 |
|---|---|---|---|
| `insertSession` | `record`（`DietRecord`，非空）；`metrics`（`BehaviorMetrics?`，**可空**，默认 `null`） | `Future<void>` | **单事务**写 1+1 行（I-1/I-3）；`metrics == null` → 写占位行。`ACD-DB-002`（`recordId` 重复）、`ACD-DB-003`（事务失败并已回滚）、`ACD-DB-004`（表/列缺失） |
| `byRange` | `r`（`DateRange`，非空） | `Future<List<DietRecord>>` | 半开区间 `[startMs, endMs)`；空结果返回空列表**不抛错**；`startMs > endMs` → `ACD-DB-004` |
| `byId` | `recordId`（`String`，非空） | `Future<DietRecord?>` | 未命中 `null`（非错误） |
| `deleteById` | 同上 | `Future<int>` | 返回受影响行数（0 = 未命中，非错误）；指标行**级联删除** |
| `deleteAll` | — | `Future<int>` | 返回删除的记录行数（不含级联的指标行） |
| `countAll` | — | `Future<int>` | `== diet_record` 行数；Demo 与真实记录**一并计数** |
| **`metricsByRecordId`** | `recordId`（`String`，非空） | `Future<BehaviorMetrics?>` | 按 1:1 关联取行为指标；行存在但指标为占位（`chewCount == null`）→ 返回**全 null 的 `BehaviorMetrics`**（不是 `null`，以区分「无记录」与「有记录无指标」）；记录不存在 → `null`。`ACD-DB-004`（表/列缺失） |

`DateRange` 两字段均为 epoch 毫秒（UTC），语义为**左闭右开** `[startMs, endMs)`。**跨日窗口换算（设备本地时区日历日 → ms）由 L4 调用方完成**（`API-00` §3.2），L3 只做区间过滤。

## 5. `StatsRepo`（`D-03`）

```dart
class ChewStats { int sampleCount; double? meanChewIntervalSeconds; }

abstract class StatsRepo {
  // --- 原有四个方法：签名不变，语义不变（todays/week 是 summary 的特例） ---
  Future<TodaySummary> today();
  Future<WeekSummary> week();
  Future<List<TrendPoint>> trend(int days);
  Future<MealTimeDistribution> mealTimes(int days);

  // --- v1.0 修订 A-1 新增（裁定见 §11.1）---
  Future<WeekSummary> summary(DateRange range);
  Future<ChewStats> chewStats(DateRange range);
  Future<List<int>> mealTimeSamples(DateRange range);
  Future<int> activeDays();
}
```

**新增四方法的语义（`SPEC-A-01` / `SPEC-A-03` / `SPEC-U-05` 的数据源缺口修补）**

| 方法 | 返回 | 语义与约束 |
|---|---|---|
| `summary(DateRange)` | `WeekSummary` | **任意左闭右开窗口**的聚合，字段与约束与 `week()` 完全相同。`week()` **必须**实现为 `summary(最近 7 个本地日历日窗口)`，两者结果逐字段一致（单元测试断言）。**`summary` 的存在是为了让 L4 能取「上一个等长窗口」以计算环比** —— `week()` 无参数，因此无法自行推出上一窗口 |
| `chewStats(DateRange)` | `ChewStats` | 窗口内 `behavior_metrics.avg_chew_interval_seconds` 的样本聚合。`sampleCount` = 非占位且 `durationSeconds` 有效（`> 0`）的行数；`meanChewIntervalSeconds` = 这些行的均值；`sampleCount == 0` → `meanChewIntervalSeconds = null`。**FF-22 `speed` 维度的直接输入**（`SPEC-A-01`） |
| `mealTimeSamples(DateRange)` | `List<int>` | 窗口内**三餐窗口**（见本节餐次窗口）记录的「本地当日 00:00 起分钟数」（`0..1439`），升序。**供 L4 校验/展示 `mealTimeStdDevMinutes` 的原始样本**；`σ` 本身仍由 `mealTimeStdDevMinutes` 给出（§5.3），**L4 不得用它重算 σ** |
| `activeDays()` | `int` | 库内**存在至少一条记录**的设备本地日历日数量（跨全部历史，不分 real/demo）。供 `SPEC-U-05` 的「已坚持 N 天」动态计数。**无参数、不随窗口变化**是刻意的：该文案的语义是累计天数 |

- `ChewStats.sampleCount` 为非负 `int`；`meanChewIntervalSeconds` 可空、单位秒、值域 `(0, ∞)`。
- 新增方法的错误码与 `days` 参数约束沿用本节既有条目（`ACD-DB-003` / `ACD-DB-004` / `ACD-KB-001`）。
- `mealTimeSamples` 与 `chewStats` **不得** N+1 查询；`activeDays` 允许等价于 `COUNT(DISTINCT date(eaten_at_ms, 'localtime'))` 的一次查询。

| 结构 | 字段 | 类型 | 可空 | 单位 | 约束 |
|---|---|---|---|---|---|
| `TodaySummary` | `recordCount` | `int` | 否 | 条 | 今日（设备本地日历日）行数 |
| | `estimatedKcal` | `int` | 否 | kcal | `Σ KcalResolver.kcalFor(classId)`；**估算值**，渲染时必须与标准份量共同出现并标注估算（FF-25） |
| | `snackCount` | `int` | 否 | 次 | 落在三餐窗口之外（见本节餐次窗口）的今日记录数 |
| | `records` | `List<DietRecord>` | 否 | — | 按 `eatenAtMs ASC`；空则空列表 |
| `WeekSummary` | `recordCount` / `estimatedKcal` / `snackCount` | `int` | 否 | 条 / kcal / 次 | 窗口 = 最近 7 个设备本地日历日（含今日） |
| | `lateNightCount` | `int` | 否 | 次 | `eatenAtMs` 本地钟点落在 `[20:00, 05:00)` 的记录数（口径依据：`计划书 v1.txt` §5.3.5「晚间进食 = 20:00 以后的进食记录」） |
| | `mealTimeStdDevMinutes` | `double` | **是** | 分钟 | §5.3 口径；无有效餐类为 `null`。**FF-22 `regularity` 的直接输入** |
| | `classCounts` | `Map<String,int>` | 否 | 次 | 键 = FF-19 英文类名，**必须包含全部 6 个键**（缺失补 0） |
| `TrendPoint` | `date` | `String` | 否 | — | `yyyy-MM-dd`，**设备本地时区**日历日（`API-00` §3.2） |
| | `estimatedKcal` | `int` | **是** | kcal | 无记录为 `null`（**不写 `0`**：`0` 表示有记录但热量为 0，语义不同） |
| | `totalScore` | `int` | **是** | 分 | ⚠️ **L3 不填充，恒为 `null`**；由 `API-04` 的 `ReportService.trend()` 在 L4 合并（`API-00` §1 规则 3） |
| `MealTimeDistribution` | `byHour` | `Map<int,int>` | 否 | 次 | 键 = 本地时区整点 `0..23`，**必须具备全部 24 个键**（缺补 0） |
- 参数 `days`：`int`，非空，`[1,365]`，越界 → `ACD-DB-004`。
- 错误码（读路径）：`ACD-DB-001`（迁移失败导致表不可用）、`ACD-DB-003`（查询事务失败）、`ACD-DB-004`（入参非法 / 表列缺失）、`ACD-KB-001`（`estimatedKcal` 计算中 `classId` 未注册）。
- 实现要求：`trend` / `mealTimes` **不得** N+1 查询，**必须**用 `GROUP BY` 一次查出（`D-03`）；线程为主 isolate，单次聚合目标 < 20 ms。

**时区与可复现性**：「今日」「本周」「整点」全部按**设备本地时区的日历日/钟点**换算；同一份数据库在同一天内任意时刻查询必须**逐字段相同**（`API-05` §6.1）。**禁止**在查询中使用「当前时刻是否已过某时段」这类判据。
**餐次窗口（`snackCount` / `lateNightCount` 判定依据）—— 🔴 本表是全部窗口常量的唯一权威定义**

| 餐次 | 本地钟点窗口 | 计入 |
|---|---|---|
| 早餐 | `[05:00, 10:00)` | 正餐 |
| 午餐 | `[11:00, 14:00)` | 正餐 |
| 晚餐 | `[17:00, 21:00)` | 正餐 |
| **零食 / 加餐** | 不落入上述任一正餐窗口的其余时段，即 `[10:00,11:00)` ∪ `[14:00,17:00)` ∪ `[21:00,05:00)` | `snackCount` |
| **晚间进食** | `[20:00, 05:00)` | `lateNightCount` |

- 判定只依赖记录的 `eatenAtMs` 换算到**设备本地时区**的钟点，**与系统当前时间无关**（可复现性要求见 §5）。
- **零食与晚间刻意允许重叠**：`[21:00,05:00)` 同时计入两者。**这不是缺陷** —— 它们是两个不同的产品指标（"加餐频率" vs "夜间进食"），不是互斥分类，**不得"去重"**。
- `SPEC-D-03`、`SPEC-A-01`、`SPEC-A-03` **只能引用本节，不得另立一套窗口常量**（`SPEC-00` §5 规则 2）。

> 🔴 **本节窗口值已于 v1.0 修订 A-2 修正，必须知悉（原值会让评分卡的一个维度失效）**
> **原冻结值**为 早 `[05,11)` / 午 `[11,16)` / 晚 `[16,23)`。
> **后果一（评分失效）**：零食窗口被压缩到仅剩 `[23:00, 05:00)`，与 `lateNightCount` **完全重合**。绝大多数用户该时段进食次数为 0–1，于是 FF-22 的 `snack` 维度 `20 × max(0, 1 − n/10)` 几乎恒为 18–20 分 —— **该维度彻底失去区分度**，而它是 100 分制的 20%。
> **后果二（与材料矛盾）**：`软件UI界面设计图/3.png` 把 **15:40 薯片**标为「下午零食」，主方案 §5.4.1 的周报示例也写「近期**下午零食**频率较高」—— 但 15:40 落在原午餐窗口 `[11,16)` 内，会被计为**午餐正餐**，产品叙事与数据口径直接冲突。
> **后果三（与原始材料不一致）**：`计划书 v1.txt` §5.3.5 明确定义「晚间进食 = **20:00** 以后的进食记录」，原值 `[23:00, 05:00)` 则要求到 23 点才算晚间。
> **裁定**：采用上表新值。它同时满足 ① 让 `snack` 维度真正可变（下午加餐进入分母）② 与 UI 稿与主方案的「下午零食」叙事一致 ③ 与 `计划书 v1` 的 20:00 口径一致。**这是修正一处会使评分维度失效的设计缺陷，不是偏好调整。**
> **受影响的产物**：`SPEC-D-03` §4.1 的窗口表、§7 判据 2 的时段边界测试夹具，以及 `SPEC-A-01` 的算例期望值。
> **夹具钟点（与 `SPEC-D-03` §7 判据 2 逐字一致，14 个边界点）**：`04:59, 05:00, 09:59, 10:00, 10:59, 11:00, 13:59, 14:00, 16:59, 17:00, 19:59, 20:00, 20:59, 21:00`。
> —— 由 7 个边界点（`05:00` 早始 / `10:00` 早末＝零食始 / `11:00` 午始 / `14:00` 午末＝零食始 / `17:00` 晚始 / `20:00` 晚间始 / `21:00` 晚末＝零食与晚间始）加各自的「前一分钟」组成，覆盖全部窗口的**左闭右开**边界。
> **工时影响**：无新增工作量（窗口常量与测试夹具本来就存在），仅需改值。

### 5.3 `mealTimeStdDevMinutes` 口径（FF-22 的唯一入口）
① 按 §5 的餐次窗口把窗口内记录分入 早餐/午餐/晚餐（零食不计入）；② 每类内把 `eatenAtMs` 换算为**本地当日 00:00 起的分钟数**，跨日历日计算**样本标准差**（`n−1` 分母）；③ 仅采纳样本数 `≥ 2` 的餐类；④ 结果为采纳餐类标准差的**算术平均**，无采纳餐类 → `null`。
> ⚠️ 口径必须与 `SPEC-A-01`（FF-22 `regularity`）完全一致：本文件是 `mealTimeStdDevMinutes` 的权威定义，`A-01` 只能消费该字段，**不得**在 L4 重算。

## 6. `ProfileRepo`（`D-04`，⚠️ 降级交付：无登录、无账号）

```dart
class UserProfile { String? nickname; int targetMealsPerDay; bool reminderEnabled; bool privacyBannerEnabled; }
abstract class ProfileRepo {
  Future<UserProfile> load();
  Future<void> save(UserProfile p);
}
```
| 字段 | 类型 | 可空 | 默认 | 约束 |
|---|---|---|---|---|
| `nickname` | `String?` | **是** | `null` | 本地自由文本，**不上传、不参与任何键**（FF-24）；长度上限由 `SPEC-D-04` 冻结 |
| `targetMealsPerDay` | `int` | 否 | 由 `SPEC-D-04` 冻结 | `[1,6]`；越界 → `ACD-DB-004` |
| `reminderEnabled` | `bool` | 否 | 由 `SPEC-D-04` 冻结 | 仅存用户意愿；**v1.0 不实现系统级定时提醒与后台常驻 Service**（FF-24 第 6 条） |
| `privacyBannerEnabled` | `bool` | 否 | 由 `SPEC-D-04` 冻结 | 隐私提示横幅开关，纯 UI 行为 |
`load()` 表为空时返回**默认档案**（不抛错、不自动建行）；`save()` 整行 `upsert`、单事务。错误码：`ACD-DB-003`、`ACD-DB-004`。

## 7. `MaintenanceRepo`（`D-05`）

```dart
abstract class MaintenanceRepo {
  Future<int> clearAllData();       // 返回清除的行数
  Future<int> clearTempAudio();     // 返回删除的文件数
  Future<int> countTempAudioFiles();
}
```
| 方法 | 返回 | 语义（本文件冻结） | 错误码 |
|---|---|---|---|
| `clearAllData` | `int` | **单事务**删除 `diet_record` + `behavior_metrics` 全部行，并把 `user_profile` 重置为默认值（保留该行）；`app_meta` 的 `schemaVersion` 保留、演示数据指纹清除。返回值 = 删除的记录行数 + 删除的指标行数 + 被重置的档案行数（0 或 1）。**不删除** APK 内 assets | `ACD-DB-003` |
| `clearTempAudio` | `int` | **必须委托** `API-01` §2.7 的原生 `clearTempAudio`，返回值即其 `filesDeleted`。**禁止在 Dart 侧另写一套 `audio_*` 匹配与删除逻辑**（否则出现两套匹配规则与两份计数） | 不抛错：失败按 `ACD-IO-001` 只记日志（`retryable=false`），返回值如实反映实际删除数 |
| `countTempAudioFiles` | `int` | 读 `API-01` §2.8 `getDiagnostics().tempAudioFiles`，供 `M-04` 自检与 `PLAN-C-01` 验收断言 | 不抛错；不可读时返回 `-1`，由 `M-04` 标记「不可判定」而非「通过」 |
**调用时机**（FF-24 第 2 条 + `API-01` §2.7）：App 冷启动一次 + 每次会话结束一次。验收断言：`clearAllData()` 后 `DietRepo.countAll() == 0`；`clearTempAudio()` 后 `countTempAudioFiles() == 0`。

## 8. `FakeRepo`（占位数据解耦，`PLAN-00` §4）

```dart
class FakeRepo implements DietRepo, StatsRepo, ProfileRepo { /* ... */ }
```
| 约束 | 内容 |
|---|---|
| 实现范围 | **只实现 `DietRepo` / `StatsRepo` / `ProfileRepo`**；**不实现 `MaintenanceRepo`**（避免 UI 出现"假清空"按钮） |
| 数据来源 | 进程内固定夹具（内存 `List<DietRecord>`），**不打开 SQLite、不读写任何文件** |
| 确定性 | 所有时间戳基于**固定基准日**生成；同一次运行内多次 `today()` / `week()` / `trend()` 返回逐字段相同结果；**禁止**使用 `DateTime.now()` |
| 自洽性 | `today()` / `week()` / `trend()` / `mealTimes()` 必须由同一份内存记录**派生**（不得各自硬编码数字），并满足 §5 键集完整性（`classCounts` 6 键、`byHour` 24 键） |
| 标识与指标 | 产出 `DietRecord.source == 'demo'`；`insertSession` 同样遵守 I-1（写占位行），让 UI 在假数据上就暴露「缺行」问题 |
| 装配 | 仅通过 Riverpod override 在开发/占位阶段注入；**release 装配不得引用**（`PLAN-D-02` 需静态断言） |

## 9. 错误码清单（本层全部可能抛出项）

| 错误码 | 触发 | `retryable` | 来源 |
|---|---|---|---|
| `ACD-DB-001` | 迁移失败（`onUpgrade` 异常、`user_version` 不可推进） | `false`（fail fast，`API-05` §5.6） | `API-00` §3.5 |
| `ACD-DB-002` | 唯一约束冲突（`record_id` 重复） | `false` | `API-00` §3.5 |
| `ACD-DB-003` | 事务提交失败并已回滚（写路径统一包装） | `true`（`API-05` §8：重试 1 次，仍失败则内存暂存 + 提示） | ⚠️ **新增，需补登 `API-00` §3.5** |
| `ACD-DB-004` | 入参非法（`DateRange` 反序、`days` 越界、`targetMealsPerDay` 越界）或表/列缺失（库 schema 与代码不一致） | `false` | ⚠️ **新增，需补登 `API-00` §3.5** |
| `ACD-KB-001` | `KcalResolver` 收到未注册的 `classId`（定义见 `API-02` §6） | `false` | ⚠️ **新增区域 `ACD-KB`，需补登 `API-00` §3.5** |
| `ACD-IO-001` | 临时音频清理失败（**不阻断主流程**，仅记日志并计入 `M-04` 自检） | `false` | `API-00` §3.5 |
> 本文件**未修改** `API-00`（其 §3.5 是错误码权威表）；上表 3 个新增码须先补登 `API-00` §3.5 才生效。

## 10. 单元测试要点（写入 `PLAN-D-01`~`PLAN-D-05` §4）

| # | 测试 | 断言 |
|---|---|---|
| 1 | `toMap → fromMap` 往返 | 对全部字段（含 `null` 指标行）逐字段相等；不允许映射缺列 |
| 2 | 1:1 不变量 | `insertSession(metrics: null)` 后指标表行数 `== 1` 且四字段全 `NULL`；不存在只有记录没有指标的记录 |
| 3 | 单事务 | 人为让指标插入失败 → 记录行也不存在（`COUNT(*) == 0`） |
| 4 | 无 BLOB | 读 `sqlite_master` 全部列定义，断言无 `BLOB` 类型、无含 `audio`/`mel`/`pcm`/`wav` 的列名（对应 `API-05` §12 判据 5） |
| 5 | 区间语义 | `byRange([a,b))` 恰含 `eatenAtMs == a`，不含 `eatenAtMs == b` |
| 6 | 键集完整 | `classCounts` 恒 6 键、`byHour` 恒 24 键，缺失小时/类别补 0 |
| 7 | 可复现性 | 同一库连续两次 `today()` / `week()` / `trend(7)` 逐字段相等（`API-05` §12 判据 7） |
| 8 | `mealTimeStdDevMinutes` | 构造已知时刻序列，断言与 §5.3 手算一致；样本 < 2 的餐类不采纳 |
| 9 | 清除 | `clearAllData()` 后 `countAll() == 0`；`clearTempAudio()` 返回 `API-01` 的 `filesDeleted`（用 mock 通道断言**只调用一次**原生方法） |
| 10 | `FakeRepo` 一致性 | `today()`/`week()`/`trend()` 互相自洽（`recordCount` 与 `records.length`、`estimatedKcal` 与逐条求和一致）；全仓断言 release 装配不引用 `FakeRepo` |

## 11. 开放问题（需人工拍板）

| # | 问题 | 影响 | 建议 |
|---|---|---|---|
| 1 | `diet_record` 是否需要 `session_id` 列 | 本文件按 `DietRecord` 冻结字段判定为**不需要**（会话标识只在运行期事件与日志） | 由 `SPEC-D-01` 确认；若需入库，必须同时给 `DietRecord` 加字段并走 `PLAN-C-03` |
| 2 | ✅ **已关闭（ADR-09 修订 A-2）**：三餐时段窗口边界的**唯一权威就是本文件 §5**（不再"未在上游冻结"）。原值 早 `[05,11)` / 午 `[11,16)` / 晚 `[16,23)` 已作废，现行值为 早 `[05,10)` / 午 `[11,14)` / 晚 `[17,21)`、晚间 `[20:00,05:00)`。这些常量直接决定 `snackCount` / `lateNightCount` / `mealTimeStdDevMinutes`，进而决定 FF-22 的 `regularity` 与 `snack` 两维，因此**任何改动都必须走 `SPEC-C-03` 的变更传播（A-2 行）** | 同上 | ✅ 已冻结于本文件 §5 |
| 3 | `clearAllData` 是否重置 `user_profile`（本文件定为「重置为默认值并保留行」） | 影响返回值计数与「一键清除」的用户预期 | 由 `SPEC-D-05` 确认 |
| 4 | `attribute` 采用写入时快照（冗余存储） | 库内出现与知识库可能不一致的历史值 | 建议保留快照并保证 `foods.json` 变更走 `PLAN-C-03`；由 `SPEC-D-01` 确认 |

## 变更影响

| 类型 | 受影响对象 |
|---|---|
| SPEC | `SPEC-D-01`（表结构字段）、`SPEC-D-02`（DAO/迁移）、`SPEC-D-03`（聚合口径）、`SPEC-D-04`（档案字段）、`SPEC-D-05`（清除计数语义）、`SPEC-A-01`（`mealTimeStdDevMinutes` + `chewStats` 消费）、`SPEC-A-03`（`summary` 双窗口）、`SPEC-U-01`/`SPEC-U-03`/`SPEC-U-05`（展示字段来源）、`SPEC-P-08`（`KcalResolver` 依赖知识库） |
| PLAN | `PLAN-D-01`~`PLAN-D-05`、`PLAN-A-01`、`PLAN-A-03`、`PLAN-U-01`、`PLAN-U-03`、`PLAN-U-05`；变更登记归 `PLAN-C-03` |
| Schema | `docs/common/docs_api/schemas/diet_record.schema.json`（字段一一对应，必须同步） |
| 测试 | `PLAN-C-05` 回归套件、`PLAN-D-0x` 单测、`API-05` §12 判据 4/5/7/8（直接依赖本层） |
| 隐私 | 任何新增列都需过 **I-2** 审查（无 BLOB、无音频派生量）；`app_meta` 不得成为第二份数据源 |

### 修订记录

| 修订 | 内容 | 触发 | 状态 |
|---|---|---|---|
| **A-1** | `DietRepo` 新增 `metricsByRecordId`；`StatsRepo` 新增 `summary` / `chewStats` / `mealTimeSamples` / `activeDays`，并新增 `ChewStats` | `SPEC-A-01`、`SPEC-A-03`、`SPEC-U-03`、`SPEC-U-05` 交叉评审指出**四处无数据源**（见 §11.1） | ✅ **已冻结**（纯新增，未改动任何既有签名） |
| **A-2** | 修正餐次窗口：早 `[05,10)` / 午 `[11,14)` / 晚 `[17,21)`；零食 = 其余时段；晚间 = `[20:00, 05:00)` | `SPEC-D-03` §10 问题 1 指出原窗口使 `snackCount ≡ lateNightCount ≡ [23,05)`，导致 FF-22 的 `snack` 维度（占 20 分）**恒为满分、失去区分度**；且与 UI 稿「15:40 下午零食」及 `计划书 v1` §5.3.5「20:00 以后」相矛盾 | ✅ **已冻结**（见 §5 的完整裁定与受影响产物） |

### 11.1 修订 A-1 的完整裁定（**先看这里再看 §11 开放问题**）

四个被交叉评审发现的「无数据源」缺口与它们的处置：

| # | 缺口 | 提出方 | 处置 | 为何是纯新增 |
|---|---|---|---|---|
| 1 | `SPEC-A-01` 的 `speed` 维需要**平均咀嚼间隔**，但 `StatsRepo` 只有 `today/week/trend/mealTimes` | `SPEC-A-01` | 新增 `chewStats(DateRange)` | 不修改既有四方法 |
| 2 | `SPEC-A-03` 的环比需要**上一个等长窗口**，但 `week()` **无参数**，推不出上一窗口 | `SPEC-A-03` | 新增 `summary(DateRange)`；`week()` 定义为 `summary(本周窗口)` 的便捷包装 | 不修改 `week()` 签名，只补一条「`week()` 必须等于 `summary(对应窗口)`」的断言 |
| 3 | `SPEC-A-01` 的 `regularity.evidence.mealTimeSamples` 需要原始样本 | `SPEC-A-01` | 新增 `mealTimeSamples(DateRange)` | 纯新增；明确 **σ 本身不在 L4 重算**，仍取 `mealTimeStdDevMinutes`（§5.3 唯一权威） |
| 4 | `SPEC-U-03` 的条目详情页需要**按记录取行为指标**，而 `MetricsDao.selectByRecordId` 属 L3 内部（`U-*` 不得引用） | `SPEC-U-03` | 在 `DietRepo` 新增 `metricsByRecordId`（`SPEC-U-05` 的「已坚持 N 天」同批新增 `activeDays()`） | 纯新增 |

> **为什么不在 L4 用既有方法凑出来**：①「上一等长窗口」需要参数化窗口，`week()` 无参数；②「按记录取指标」需要 `recordId` 精确匹配，`byRange` 只能按时间窗模糊取，会出现同分钟多条记录时的歧义。两者都是**接口能力缺失**，不是调用方式问题。
>
> **对 `PLAN-D-03` 的工时影响**：`summary` 与 `week` 共用实现，`chewStats`/`mealTimeSamples`/`activeDays` 各为一次 `GROUP BY` 查询，`metricsByRecordId` 是一次主键查询。**合计新增约 4 小时**（`PLAN-D-03` 由 **5 h** 调整为 **11–12 h**；逐项相加约 8.5 h，余量留给并发与联调缓冲）。若工时不足，**降级顺序**：先砍 `mealTimeSamples`（改为 UI 不展示原始样本，`evidence` 留空）→ 再砍 `activeDays`（`SPEC-U-05` 显示 `-- 天`）→ **绝不砍 `chewStats` 与 `summary`**（它们直接决定分数与环比能否算出）。
>
> 📌 **勘误（2026-09-10）**：本行原写「由 **8 h** 调整为 11–12 h」。经核对，`PLAN-D-03` 的**原工时是 5 h**（不是 8 h）——「8 h」是笔误，已更正。冻结**目标值 11–12 h 不变**（含缓冲）；`PLAN-D-03` 表头与 WBS 已在同步中改为该值。

## 明确不做

| 不做 | 理由 |
|---|---|
| 云端后端 / 网络同步 / 导出上传 | `API-05` §1 裁定：v1.0 无任何网络出口（FF-24 第 4 条） |
| CSV / 文件导出（`X-03`） | 已裁剪，入口置灰标「v1.1」 |
| 登录 / 账号体系（`X-01`） | 改本地档案（`D-04`），库内无用户标识 |
| 存音频、Mel 张量、波形或音频文件路径 | I-2；`API-05` §3.1 R-OUT-1/2 |
| 数据库加密 | `API-05` §5.7：v1.0 不做（依赖设备级 FBE） |
| 分页 / 归档 / 增量同步队列 | `API-05` §5.8：无容量压力 |
| 在 L3 内做评分、建议或速度评级 | I-4（`API-00` §1 规则 3）；`TrendPoint.totalScore` 恒为 `null` |
| 咀嚼节律 σ 列（`X-07`） | 已裁剪，不得新增 |
| `FakeRepo` 进入 release 装配 | 占位数据只服务 UI 并行开发（`PLAN-00` §4） |

**文档结束**

# SPEC-D-01 数据模型与 SQLite Schema

| 项 | 值 |
|---|---|
| 域 | D · 数据与本地后端 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §6.1；`计划书文本提取件/v1.txt` §5.2.1 日志字段表；API-05 §5；API-00 §3.1/§3.2；**API-03 §2/§3（模型↔表映射与 DAO 契约为权威）**；SPEC-00 §3.9 FF-24 |
| 依赖的 SPEC | 无（本域根节点）；`API-02` §5 定义 `BehaviorMetrics`、`API-03` §2 定义列映射，本 SPEC **不复制签名** |

## 1. 目标与范围
### 1.1 一句话目标
定义本地单文件数据库 `acoudiet.db` 的**表、列、约束与索引**：4 张表（`diet_record` / `behavior_metrics` / `user_profile` / `app_meta`），使一次检测会话产生的记录与行为指标严格 **1:1**、**无任何 BLOB 音频列**、表列命名与时间单位符合 API-00 §3.1/§3.2。
### 1.2 范围内（In Scope）
1. 4 张表的列名、类型、可空性、默认值、`CHECK` 约束、外键与外键动作；建表 DDL 草案（§4.1）、索引 DDL 草案与逐索引用途说明（§4.5）。
2. 列 ↔ Dart 模型的对应关系（§4.6）；**方向与措辞服从 API-03 §2**，本 SPEC 只负责列与约束。
4. 表级不变量：记录与指标 1:1、`user_profile` 单行、`app_meta` 必需键齐全。
5. 索引与查询计划的可用性要求（供 `SPEC-D-03` 命中）。
### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
1. **不写 DAO 实现、事务边界、`onUpgrade` 脚本、写入重试** —— 属 `SPEC-D-02`；**不写聚合查询 SQL、不定义「零食/正餐」口径与 σ** —— 属 `SPEC-D-03`。
2. **不定义健康评分公式与 `HealthScore` / `DimensionScore`** —— 属 `SPEC-A-01` / `API-04`。
3. **不定义「类别 → 属性/标准份量/热量」的知识库内容** —— 属 `SPEC-P-08`；估算热量经 `API-03` §3 的 `KcalResolver` 端口注入，**本 Schema 不建热量表**。
4. **不做**数据库加密（API-05 §5.7）、不做分页归档、不做多用户/多档案、不做任何数据导出。
5. **不建**任何音频、波形、频谱、Mel 的数据列或表（FF-24 第 1、3 条）。

## 2. 功能行为
### 2.1 触发与前置条件
| 触发 | 前置条件 |
|---|---|
| App 冷启动、库不存在 | `openDatabase(path: 'acoudiet.db', version: kDbVersion)`；`path` 由 `getDatabasesPath()` 给出 |
| App 冷启动、库已存在 | 版本等于 `kDbVersion` 则不执行任何 DDL；`PRAGMA foreign_keys` 必须**每个连接**重新开启（SQLite 该 PRAGMA 逐连接生效） |
### 2.2 主流程（编号步骤）
1. `onConfigure`：执行 `PRAGMA foreign_keys = ON`；失败即抛 `ACD-DB-001`。
2. `onCreate`（**单个事务内完成**）：按 §4.1 建 4 张表 → 按 §4.5 建 3 个索引 → 写 `app_meta` 必需键（§4.3） → 写 `user_profile` 默认单行（§4.2）。
3. 每次会话结束由 `SPEC-D-02` 在**一个事务**内写 1 行 `diet_record` + 1 行 `behavior_metrics`（无指标时写全 `NULL` 占位行，API-03 不变量 I-1）；列值来源：`attribute` 为**写入时快照**（`FoodInfo.attribute`，API-03 §2），`confidence` 取聚合后的置信度，`source` 由调用方按真实/演示标注。
### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）
无状态。表结构在 `kDbVersion` 生命周期内不可变；任何变更只允许经 `SPEC-D-02` 的 `onUpgrade` 迁移链发生。
### 2.4 边界条件
| 边界 | 规定 |
|---|---|
| 有 `diet_record`、无 `behavior_metrics` 行 | **禁止**。由外键 + `SPEC-D-02` 同事务写入共同保证；查询侧也**不得**依赖缺行语义（API-05 §5 一致性红线、API-03 I-1） |
| `behavior_metrics` 四列全 `NULL` | **合法**，语义是「本会话未取得行为指标」，必须写占位行而不是不写行 |
| `class_id` 越界、`confidence` 越界、`source` 非 `real`/`demo`、`ended_at_ms < eaten_at_ms`、`user_profile` 出现第 2 行 | 一律拒绝写入：`CHECK` / `PRIMARY KEY` 违反 → `ACD-DB-004`（表列/入参非法）；`record_id` 重复 → `ACD-DB-002`（API-03 §9） |
| **`session_id` 不入库** | v1.0 **不设该列**（API-03 §2 明确）。会话标识只存在于运行期事件与日志（API-01 §3.2）；若日后要求入库，须同时给 `DietRecord` 加字段并走 `PLAN-C-03` 变更传播 |
| CP1 降级为 4 类（FF-19 降级开关） | **不改变 Schema**，仅减少 `class_id` 实际取值 |
| 数据库被外部工具新增列 | 不处理。`fromMap` 只读已知列，未知列被忽略 |
| 演示数据集批量导入中途失败（`API-04` §6） | **原子性硬约束**：一批演示数据集的**所有行必须在同一事务内提交**；任一行写入失败 → 整体回滚并清理，**不留半套 `source='demo'` 数据**；`app_meta` 的三个演示标识只在事务提交成功后写入（见 §4.3 第 3 条、§10 问题 6） |

## 3. 接口契约
> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准（本域为 **API-03**），此处给「本功能用到的部分」并标注 API 编号。
| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L3 内部 | `openDatabase(...)`（`sqflite`，API-05 §5.1/§5.2） | `path='acoudiet.db'`, `version=kDbVersion` | 唯一 `Database` 句柄 | `ACD-DB-001` |
| L3 → L4 | `DietRecord.fromMap` / `toMap`、`BehaviorMetrics.fromMap` / `toMap`（API-03 §2） | §4.6 列映射 | §4.6 列映射 | 无 |
| L4 → L3 | 约束违反（`CHECK` / `PRIMARY KEY` / `FOREIGN KEY`） | — | — | `ACD-DB-002` / `ACD-DB-004` |
| L4 装配层 → L3 | `KcalResolver`（API-03 §3） | `classId` | `int kcal` | `ACD-KB-001`（未注册类） |
> ⚠️ **接口签名的权威在 `API-03`**：本 SPEC 只定义 DDL 与列约束（API-03 首部已把 DDL 权威归属本 SPEC）。`session_id`、`classCounts`、`KcalResolver` 三项以 API-03 为准。

## 4. 数据契约
> 涉及的字段、类型、单位、值域、可空性；逐字段映射见 **API-03 §2**（权威），本节只给 DDL 与列约束。
### 4.1 建表 DDL 草案（**完整，可直接执行**）
```sql
-- acoudiet.db   schema_version = 1   （kDbVersion = 1）
PRAGMA foreign_keys = ON;   -- 每个连接都要执行一次
CREATE TABLE diet_record (
  record_id         TEXT    PRIMARY KEY NOT NULL,   -- UUID v4（API-00 §3.4）
  eaten_at_ms       INTEGER NOT NULL,               -- epoch ms UTC，进食起始
  ended_at_ms       INTEGER NOT NULL,               -- epoch ms UTC，进食结束
  class_id          INTEGER NOT NULL CHECK (class_id >= 0 AND class_id < 6),
  class_label       TEXT    NOT NULL,               -- FF-19 英文键 chips…drink；不存中文名
  attribute         TEXT    NOT NULL,               -- 写入时快照（API-03 §2）
  confidence        REAL    NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
  duration_seconds  INTEGER NOT NULL CHECK (duration_seconds >= 0),
  source            TEXT    NOT NULL CHECK (source IN ('real','demo')),
  corrected_by_user INTEGER NOT NULL DEFAULT 0 CHECK (corrected_by_user IN (0,1)),
  confirmed_by_user INTEGER NOT NULL DEFAULT 0 CHECK (confirmed_by_user IN (0,1)),
  created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
  CHECK (ended_at_ms >= eaten_at_ms)
);
CREATE TABLE behavior_metrics (
  record_id                 TEXT    PRIMARY KEY NOT NULL          -- UNIQUE 由主键提供
                                    REFERENCES diet_record(record_id) ON DELETE CASCADE,
  chew_count                INTEGER,          -- 可空：占位行为 NULL
  avg_chew_interval_seconds REAL,             -- 可空，单位秒
  duration_seconds          INTEGER,          -- 可空，单位秒
  speed_grade               TEXT CHECK (speed_grade IS NULL
                                        OR speed_grade IN ('偏快','正常','偏慢')),  -- FF-21e / API-02 §5
  created_at_ms             INTEGER NOT NULL
);
CREATE TABLE user_profile (
  profile_id             INTEGER PRIMARY KEY CHECK (profile_id = 1),
  nickname               TEXT,                -- 可空；空白串一律存 NULL
  target_meals_per_day   INTEGER NOT NULL DEFAULT 3
                         CHECK (target_meals_per_day BETWEEN 1 AND 6),
  reminder_enabled       INTEGER NOT NULL DEFAULT 0 CHECK (reminder_enabled IN (0,1)),
  privacy_banner_enabled INTEGER NOT NULL DEFAULT 1 CHECK (privacy_banner_enabled IN (0,1)),
  updated_at_ms          INTEGER NOT NULL
);
CREATE TABLE app_meta (                -- 键值表，不映射为 Dart 模型（API-03 §2）
  key           TEXT PRIMARY KEY NOT NULL,
  value         TEXT,
  updated_at_ms INTEGER NOT NULL
);
```
> **本 Schema 无热量表**：`estimatedKcal` 由 `API-03` §3 的 `KcalResolver` 端口在 L3 计算，`classId` 未注册时抛 `ACD-KB-001`，**不得**用兜底 0 静默失真。
### 4.2 `user_profile` 默认单行（`onCreate` 内写入）
`profile_id=1`；`nickname=NULL`；`target_meals_per_day=3`（值域 `[1,6]`）；`reminder_enabled=0`（默认关）；`privacy_banner_enabled=1`（隐私告知优先）；`updated_at_ms` = 建库时刻 epoch ms UTC。取值与 `SPEC-D-04` §4.1 必须一致（唯一来源 `profile_defaults.dart`）。
### 4.3 `app_meta` 必需键（`onCreate` 内写入；缺键即视为 Schema 缺陷）
1. `schema_version`=`'1'`（十进制字符串，与 `PRAGMA user_version` 双写，便于人工核对）；`demo_data_enabled`=`'0'`（`'0'`/`'1'`，演示数据标识，`SPEC-A-04` 读写）；`demo_dataset_id`=`NULL`、`demo_data_loaded_at_ms`=`NULL`（预置数据集标识与装载时刻）。
2. `last_cleanup_at_ms`=`NULL`（录音残留清理最后成功时刻）、`last_cleanup_failed_count`=`'0'`（失败计数，计入 `M-04` 自检面板）—— `SPEC-D-05` 使用。
3. **演示状态的双载体一致性（ADR-10，硬约束）**：库内演示数据的**真值**是「`diet_record` 中存在 `source='demo'` 的行」；上述三个 `app_meta` 演示标识（`demo_data_enabled` / `demo_dataset_id` / `demo_data_loaded_at_ms`）**只是真值的索引**，必须与之**始终一致**——`demo_data_enabled == '1'` ⇔ `COUNT(*) WHERE source='demo' > 0`，且 `demo_dataset_id` / `demo_data_loaded_at_ms` 非 `NULL` ⇔ 同一条件。**批量导入演示数据集必须所有行同事务提交**，失败则整体回滚并清理，**不留半套数据**（`API-04` §6 要求批内原子；与 `API-03` §4 只有逐条 `insertSession` 的口径差异见 §10 问题 6，**以 `API-03` 为准**）。机械验收见 §7 判据 10、11。
> `app_meta` **不得**成为第二份数据源：不存个人数据、不存音频派生量（API-03 §2）。
### 4.4 `attribute` 与 `class_label` 的入表口径
- `class_label` 存 **FF-19 英文键**，**不存中文名**（API-03 §2）；中文展示由 `U-*` 查知识库得到。`attribute` 存**写入时快照**（如「脆性高加工零食」）：知识库更新后历史记录不得改口径（API-03 §2 / §11 问题 4）。
- **禁止入表字段**：`zhName` / `portionDesc` / `portionKcal` / `nutritionTags` / `riskNote`（渲染时查 `foods.json`）、任何 Mel/PCM 形态、`smoothedProbs`（API-03 §2）。
### 4.5 索引 DDL 草案与逐索引用途
```sql
CREATE INDEX idx_diet_record_eaten_at     ON diet_record(eaten_at_ms);
CREATE INDEX idx_diet_record_source_eaten ON diet_record(source, eaten_at_ms);
CREATE INDEX idx_diet_record_class_eaten  ON diet_record(class_id, eaten_at_ms);
```
| 索引 | 服务的查询（`SPEC-D-03`） | 为什么需要 |
|---|---|---|
| `idx_diet_record_eaten_at` | 今日汇总、本周汇总、`trend(days)`、`mealTimes(days)` 的时间范围过滤 | 四类聚合的唯一过滤条件就是 `eaten_at_ms` 区间；无此索引将 `SCAN diet_record` |
| `idx_diet_record_source_eaten` | 真实/演示数据分流（`source='real'` 时排除预置演示行） | `source` 前置先定分支再扫时间区间，且避免对列做函数包装 |
| `idx_diet_record_class_eaten` | `WeekSummary.classCounts`（6 键）与食物结构维度的按类计数 | 计数同样只发生在时间区间内，`class_id` 前置可与之共用一次索引扫描 |
**明确不建的索引（防止"顺手加"）**：① `behavior_metrics` 不建二级索引 —— 所有指标访问都经 `record_id` 主键或与 `diet_record` 连接，多余索引会拖慢每次会话写事务；② 不建 `local_day` 冗余列及其索引 —— 日历日按设备本地时区计算（API-00 §3.2），冗余列跨时区/夏令时后会失真（§10 问题 3）；③ 不建任何触发器 —— 1:1 由外键 + 同事务写入保证，触发器会让写入路径不可预测。
### 4.6 列 ↔ Dart 模型映射（方向与措辞服从 API-03 §2）
| SQLite 列（`diet_record`） | Dart 字段 | 类型 | 单位/值域 |
|---|---|---|---|
| `record_id` | `DietRecord.recordId` | `String` | UUID v4 |
| `eaten_at_ms` / `ended_at_ms` | `eatenAtMs` / `endedAtMs` | `int` | epoch ms UTC |
| `class_label` / `class_id` / `attribute` | `classLabel` / `classId` / `attribute` | `String` / `int` / `String` | FF-19 英文键；`0..5`；属性快照 |
| `confidence` / `duration_seconds` | `confidence` / `durationSeconds` | `double` / `int` | `[0,1]`；秒 |
| `source` / `corrected_by_user` / `confirmed_by_user` | `source` / `correctedByUser` / `confirmedByUser` | `String` / `bool` / `bool` | `'real'`/`'demo'`；`0`/`1` ↔ `false`/`true` |
| `behavior_metrics.chew_count` | `BehaviorMetrics.chewCount` | `int?` | 次 |
| `avg_chew_interval_seconds` / `duration_seconds` | `avgChewIntervalSeconds` / `durationSeconds` | `double?` / `int?` | 秒 |
| `speed_grade` | `speedGrade` | `String?` | `'偏快'`/`'正常'`/`'偏慢'`（FF-21e，API-02 §5） |
| `user_profile.*` | `UserProfile.*` | 见 `SPEC-D-04` §4.1 | `nickname` 可空，其余非空 |
- 除 `behavior_metrics` 的后四列外，`diet_record` 全部列**均非空**；`behavior_metrics` 后四列全 `NULL` 即占位行语义。
- `app_meta` 由 `SPEC-D-02` 的 `MetaDao` 以 `Map<String, String?>` 读写，不建模型；布尔列在 SQLite 一律 `INTEGER 0/1`（`toMap` 写 `v ? 1 : 0`，`fromMap` 读 `(v as int) == 1`）。
- Schema 文件引用：**只有 `docs/common/docs_api/schemas/diet_record.schema.json`** 与本功能直接对应（它同时覆盖 `diet_record` 与 `behavior_metrics` 两个结构，见其 `description`）。
  > 🔴 **勘误**：本行原写还引用 `docs/common/docs_api/schemas/behavior_metrics.schema.json` 与 `docs/common/docs_api/schemas/user_profile.schema.json` —— **这两份文件不存在**，已落盘的 6 份是 `feature_config` / `diet_record` / `health_score` / `foods` / `metrics` / `sync_envelope`。`behavior_metrics` 与 `user_profile` **没有独立 schema，也无需新增**：它们的权威定义是本文档 §4 的表结构 + `API-03` §2 的「模型 ↔ 表映射」。已改为指向该权威，**不新增 schema 文件**（schema 集保持 6 份）。

## 5. 参数与常量
> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。
| 项 | 引用 |
|---|---|
| 识别类别集合、`class_id` 值域、降级开关 | SPEC-00 §3.3 FF-19 |
| 速度评级三档（`speed_grade` 取值） | SPEC-00 §3.6 FF-21e（中文枚举，API-02 §5） |
| 数据库仅存结构化字段、无 BLOB 音频列；音频只存在于内存环形缓冲、不落盘；APK 不申请 `INTERNET` 权限 | SPEC-00 §3.9 FF-24 第 3、1、4 条 |
| 表列 `snake_case`、字段后缀 `_ms` / `_seconds` | API-00 §3.1 / §3.2 |
| 库文件名 `acoudiet.db`、单例句柄、写时机、事务边界、迁移幂等、大小预算 | API-05 §5.1 / §5.2 / §5.3 / §5.5 / §5.6 / §5.8 |
| 四条 L3 不变量（I-1 1:1、I-2 无 BLOB、I-3 单事务、I-4 无业务规则）与全部列映射 | **API-03 §1 / §2**（权威，本 SPEC 不复制） |
| 错误码 `ACD-DB-001`/`002`/`003`/`004`、`ACD-KB-001` | API-03 §9（其中 `003`/`004`/`KB-001` 待补登 API-00 §3.5，见 §10 问题 5） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 建库/迁移失败（`ACD-DB-001`） | `openDatabase` 或 `onUpgrade` 抛异常 | 抛 `AcouDietError(retryable:false)`；不得进入记录/报告页 | 全页错误态：「本地数据库初始化失败」 |
| 唯一约束冲突（`ACD-DB-002`） | `record_id` 重复 | 抛 `ACD-DB-002`；**不覆盖**已有记录 | 提示「本次记录未保存」，不静默丢弃 |
| 入参非法 / 表列缺失（`ACD-DB-004`） | 反序区间、越界值、`CHECK` 违反、库 schema 与代码不一致 | 抛 `ACD-DB-004`（`retryable:false`） | 提示「数据校验失败」 |
| `KcalResolver` 收到未注册 `classId` | 端口抛错 | 抛 `ACD-KB-001`（API-03 §3） | 首页/报告页错误态，**不显示 0 热量** |
| `foreign_keys` 未生效 | 启动自检 `PRAGMA foreign_keys` 返回 `1` | 重设一次；仍为 `0` 则计入 `M-04` 自检面板**失败项** | 自检面板显示「数据库外键：关闭」 |
| `app_meta` 必需键缺失 | `onCreate` 后遍历 §4.3 键集合 | 幂等补齐缺失键并记日志 | 无 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 4 张表、全部列存在且命名合规、无 BLOB 列、无 `session_id` 列 | `flutter test app/test/db/schema_test.dart -t "schema: 表与列齐全"`：表集合 ⊇ {`diet_record`,`behavior_metrics`,`user_profile`,`app_meta`}；每表列名集合逐项相等且不含 `session_id`；表名/列名匹配 `^[a-z][a-z0-9_]*$`；`PRAGMA table_info` 无 `BLOB` 类型；列名不含 `audio`/`mel`/`pcm`/`wav` | 0 差异 / 0 处违规 |
| 2 | `.schema` 文本不含 BLOB | `sqlite3 acoudiet.db ".schema" \| grep -ci blob` | == 0 |
| 3 | `app_meta` 必需键齐全 | `-t "schema: app_meta 必需键"`：§4.3 六个 key 的 `SELECT COUNT(*)` | == 6 |
| 4 | 记录与指标 1:1 无缺行 | `-t "schema: 1:1 无缺行"`：`SELECT COUNT(*) FROM diet_record r LEFT JOIN behavior_metrics m ON m.record_id=r.record_id WHERE m.record_id IS NULL` == 0，且反向孤儿数 == 0 | 两向均为 0 |
| 5 | 外键级联与单行约束真实生效 | `-t "schema: 约束生效"`：插 1 记录 + 1 指标 → `DELETE FROM diet_record` → 指标行数 == 0；`INSERT INTO user_profile(profile_id,…) VALUES(2,…)` 抛错 | 0 行 / 抛 `ACD-DB-004` |
| 7 | 索引存在且被查询计划使用 | `-t "schema: 索引被使用"`：§4.5 三条索引各跑一次 `EXPLAIN QUERY PLAN`，输出含对应索引名，且四条 D-03 查询计划中**不含** `SCAN diet_record` | 全部命中 |
| 8 | 模型 ↔ 行双向往返一致 | `-t "schema: fromMap/toMap 往返"`：`DietRecord` 与 `BehaviorMetrics` 各构造含极值样本（`confidence=0.0/1.0`、指标全 `NULL`、`speedGrade='偏慢'`），断言 `fromMap(toMap(x))` 逐字段相等 | 全部字段相等 |
| 9 | 无网络权限（与 `SPEC-C-01` 共用证据） | `aapt dump badging app-release.apk \| findstr uses-permission` | 输出不含 `android.permission.INTERNET` |
| 10 | **演示状态双载体一致**（真值 = 行存在，`app_meta` 仅索引；ADR-10） | `flutter test app/test/db/demo_state_consistency_test.dart -t "demo: 双载体一致"`：对**当前生效数据集**（Track 1 真实累积或 Track 2 预置，`SPEC-A-04`）在 ① 导入演示数据后 ② 清除演示数据后 **两个状态各断言一次**，每次**双向**断言 `(app_meta.demo_data_enabled == '1')` ⇔ `(SELECT COUNT(*) FROM diet_record WHERE source='demo') > 0`，且 `demo_dataset_id` / `demo_data_loaded_at_ms` 非 `NULL` ⇔ 同一条件 | 2 状态 × 双向，全部成立 |
| 11 | **导入演示数据集原子性**（不留半套数据） | `-t "demo: 导入原子性"`：构造批量导入在第 `k` 条失败 → 断言 `(SELECT COUNT(*) FROM diet_record WHERE source='demo') == 0`、`behavior_metrics` 无孤儿行、`app_meta` 三个演示标识回到导入前值 | 三项全部成立 |

## 8. 非功能约束
| 项 | 约束 | 依据 |
|---|---|---|
| 存储形态与并发 | 单文件 `acoudiet.db`；进程内唯一 `Database` 句柄（Riverpod 单例），**禁止多处 `openDatabase`**；无网络访问、无导出通道 | API-05 §5.1 / §5.2 |
| 写入原子性与性能 | 记录 + 指标同事务；迁移幂等可重复；单次查询 < 20 ms（本功能负责让索引可用，测量归 `SPEC-D-03`） | API-05 §5.3 / §5.5 / §5.6；API-00 §3.7 |
| 容量 | 不做分页、不做归档；**具体字节数按实测记录，此处不写预测值** | API-05 §5.8 |
| 隐私 | 表中不得出现音频/波形/Mel 任何形式的列；不得把 ISO 时间字符串作为主存储格式 | FF-24 第 1、3 条；API-00 §3.2 |
| 无障碍 | 无（与 Schema 无关） | — |

## 9. 裁剪与未做
1. **本功能不可裁剪**：`docs/00_功能清单与数量分析.md` §6 不可砍项 ②「自动生成记录（`D-01`~`D-03`、`P-06`）」依赖本 Schema。
2. `X-02` 手动修正（改类别、删误报）**已降级**为 A/B 二选一确认；只保留 `corrected_by_user` / `confirmed_by_user` 两个布尔位，**不得**为「任意改类别」预留 `correction` 文本列（属 v1.1）。**✅ 两列的入库与展示边界已冻结（依据 `ADR-P6`，2026-09-10）**：**两列都保留入库**（`confirmed_by_user` 作分析字段，用于统计低置信度占比与模型迭代）；`DietRecord` 的 Dart 侧暴露保持 `correctedByUser` 不变；**UI 只呈现「已确认」**（对应 Level-3 二选一确认过的记录），**不呈现「已修正」**。
3. `X-03` CSV 导出、`X-05` 检测页历史列表、`X-07` 咀嚼节律 σ **均已删除**：不得为导出预留视图/临时表/状态列，不得新增 `chew_stddev_seconds` 类列，不得新增「按会话聚合」视图；亦不建 `DailyAggregate` 物化表（§10 问题 1）、不做数据库加密（API-05 §5.7）与多档案支持。不建 `food_kcal` 之类热量表（§4.1 注）；不存 `zhName`/`portionDesc`/`portionKcal` 等知识库渲染字段（API-03 §2）。

## 10. 开放问题
| # | 问题 | 影响面 | 谁拍板 | 截止 |
|---|---|---|---|---|
| 1 | `00_功能清单与数量分析.md` 的 `D-01` 行写有「`DailyAggregate` 表」，本 SPEC 未建实体表，改由 `SPEC-D-03` 实时 `GROUP BY`（依据 API-05 §5.8「无容量压力，不做分页/归档」）。是命名笔误还是要求物化表？ | 若要求物化表，需新增刷新时机与失效策略，并改 `SPEC-D-03` | B + C | D5（`PLAN-D-01` 开工前） |
| 2 | 本 SPEC 依 `API-03` §2 裁定「**v1.0 不设 `session_id` 列**」，并确认 `attribute` 为**写入时快照**（回应 API-03 §11 问题 1、4）。若 `P-06` 或 `A-03` 要求按会话聚合，需走 `PLAN-C-03` 变更单并同时给 `DietRecord` 加字段 | 表结构与 `DietRecord` 字段集 | B + C | D5 |
| 3 | 日历日不建 `local_day` 冗余列，改用 `date(eaten_at_ms/1000,'unixepoch','localtime')` 或由 Dart 传区间。`localtime` 依赖设备时区，跨时区测试须固定时区 | 影响 `SPEC-D-03` 的区间计算与测试可复现性 | B | D5 |
| 4 | ✅ **已关闭（依据 ADR-10）**：`docs/common/docs_api/schemas/` 目录与 **6 份 Schema 均已落盘**（`feature_config` / `diet_record` / `health_score` / `foods` / `metrics` / `sync_envelope`），本 SPEC §4.6 的 `diet_record.schema.json` 引用**有效**；Schema 集合的收口方为 `SPEC-C-03` §4 与 `API-00` §4。**结论：无未落盘契约，本条不再需要拍板** | 机器可校验的 Schema 一致性 | A + B | ✅ 已关闭 |
| 5 | `ACD-DB-003`（事务提交失败已回滚）、`ACD-DB-004`（入参非法/表列缺失）、`ACD-KB-001`（未注册 `classId`）由 `API-03` §9 新增并**自述尚未补登 `API-00` §3.5**；本 SPEC 已引用这三个码，需先补登错误码权威表 | 错误码权威表一致性 | A + C | D5 |
| 6 | ✅ **已关闭（依据 ADR-10）**：`API-04` §6 的 `loadDemoDataset` 自述「**单事务批量**写入（复用 `DietRepo.insertSession`）」，而 `API-03` §4 只有**逐条** `insertSession`（单条自带 1 记录 + 1 指标的事务）——两者口径不一致：**整批原子 vs 单条原子** | 按 `API-03` 逐条调用时，导入中途失败会留下**半套** `source='demo'` 数据，§7 判据 10 的双载体一致性将天然失败 | **以 `API-03` 为准**（ADR-10：跨层契约一律以接口层为准）。`loadDemoDataset` 必须在**一个外层事务**内完成整批写入，任一失败整体回滚**并清理已写入行**，不留半套；`app_meta` 的演示标识只在提交成功后写入。**失败清理语义由 §7 判据 11 机械验收** | B（A 会签） | ✅ 已关闭 |

---
**文档结束**
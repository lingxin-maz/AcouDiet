# PLAN-D-01 数据模型与 SQLite Schema

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-D-01 |
| 负责 | B（主责）；C 协助列映射与 `API-03` §2 的一致性评审 |
| 目标日 | D5 |
| 前置依赖 | **`API-03` §2（列映射权威）已落盘**（D5 前）；`assets/foods.json` 定稿（`PLAN-P-08`，D1）供 `KcalResolver` 使用；`shared/feature_config.json` 可读；D1 三方接口冻结（`PLAN-00` §4） |
| 预估工时 | 6 h（建表 DDL 2 h + 模型映射 2 h + 测试 2 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 验收方式 |
|---|---|---|
| 1 | `app/lib/data/db/schema.dart` | 导出 `kDbVersion` 与 §4.1 建表 + §4.5 索引的 DDL 常量；被 `SPEC-D-02` 的 `AppDatabase` 引用 |
| 2 | `app/lib/data/model/diet_record.dart` | `DietRecord` + `fromMap` / `toMap`（字段名与任务书冻结类名一致） |
| 3 | `app/lib/data/model/behavior_metrics.dart` | `BehaviorMetrics` + `fromMap` / `toMap` |
| 4 | `app/lib/data/model/user_profile.dart` | `UserProfile` + `fromMap` / `toMap`（`SPEC-D-04` 共用） |
| 5 | `app/lib/data/kcal_resolver.dart` | `KcalResolver` 端口的装配接线（实现由 `FoodKnowledgeBase` 提供，API-03 §3）；未注册 `classId` 必须抛 `ACD-KB-001` |
| 6 | `app/test/db/schema_test.dart` | 承载 `SPEC-D-01` §7 判据 1、3、4、5、7、8 全部测试名 |
| 7 | `app/test/db/column_map_test.dart` | 逐列比对 `schema.dart` 与 **API-03 §2** 的映射表，差异数 0 |
| 8 | `app/scripts/schema_dump.ps1` | 生成 `acoudiet.db` 的 `.schema` 文本，供判据 2 与 `PLAN-C-05` 回归使用 |
| 9 | `PLAN-D-01` §3 的 DDL 与本文档一致 | 评审：逐行比对，禁止文档与代码出现两份 DDL |

> **说明**：`app/` 目录由 B 在 D1 初始化 Flutter 工程时创建（`PLAN-00` §1 的 D1 行）；本 PLAN 的所有路径都相对该根目录。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 落 DDL 常量（**4 表 + 3 索引**；无 `session_id`、无热量表） | `app/lib/data/db/schema.dart` | 2 h | 无 |
| 2 | 写 3 个模型的 `fromMap` / `toMap` | §1 交付物 2–4 | 1 h | 1 |
| 3 | `KcalResolver` 端口接线（实现来自 `FoodKnowledgeBase`） | `app/lib/data/kcal_resolver.dart` | 0.5 h | 1；`PLAN-P-08` 的 `foods.json` |
| 4 | 写 schema 测试套件（6 组断言） | `app/test/db/schema_test.dart` | 1.5 h | 2、3 |
| 5 | 写 `EXPLAIN QUERY PLAN` 索引断言 + 列映射比对 | 同上（判据 7）+ 交付物 7 | 0.5 h | 4 |
| 6 | 产出 `.schema` 文本证据并入回归清单 | `app/scripts/schema_dump.ps1` + 截图 | 0.5 h | 4 |
| **合计** | | | **6 h** | |

## 3. 技术方案

### 3.1 建表入口（≤30 行骨架，**不写完整实现**）
```dart
// app/lib/data/db/schema.dart
const int kDbVersion = 1;

const List<String> kCreateTableStatements = <String>[
  '''
  CREATE TABLE diet_record (
    record_id TEXT PRIMARY KEY NOT NULL,
    eaten_at_ms INTEGER NOT NULL, ended_at_ms INTEGER NOT NULL,
    class_id INTEGER NOT NULL CHECK (class_id >= 0 AND class_id < 6),
    class_label TEXT NOT NULL, attribute TEXT NOT NULL,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    duration_seconds INTEGER NOT NULL CHECK (duration_seconds >= 0),
    source TEXT NOT NULL CHECK (source IN ('real','demo')),
    corrected_by_user INTEGER NOT NULL DEFAULT 0 CHECK (corrected_by_user IN (0,1)),
    confirmed_by_user INTEGER NOT NULL DEFAULT 0 CHECK (confirmed_by_user IN (0,1)),
    created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
    CHECK (ended_at_ms >= eaten_at_ms));''',
  // behavior_metrics / user_profile / app_meta 同表单列，逐字照抄 SPEC-D-01 §4.1
  // 注意：v1.0 无 session_id 列、无热量表（API-03 §2/§3）
];

const List<String> kCreateIndexStatements = <String>[
  'CREATE INDEX idx_diet_record_eaten_at ON diet_record(eaten_at_ms);',
  'CREATE INDEX idx_diet_record_source_eaten ON diet_record(source, eaten_at_ms);',
  'CREATE INDEX idx_diet_record_class_eaten ON diet_record(class_id, eaten_at_ms);',
];
```
**硬性要求**：`schema.dart` 与 `SPEC-D-01` §4.1 必须逐字一致，且列集合与 **API-03 §2** 的映射表逐列相等（判据由交付物 7 覆盖）。DDL 的权威文本是 `SPEC-D-01`，改 DDL 必须先改 SPEC（走 `API-00` §3.9 变更流程）。

### 3.2 实现步骤
1. `onConfigure` 内先 `await db.execute('PRAGMA foreign_keys = ON')`，**不要**只写在 `onCreate` 里（PRAGMA 逐连接生效，`SPEC-D-01` §2.1）。
2. 依次执行 `kCreateTableStatements`（顺序：`diet_record` 必须早于 `behavior_metrics`，因为有外键引用）。
3. 依次执行 `kCreateIndexStatements`。
4. 写入 `app_meta` 六个必需键（`SPEC-D-01` §4.3）与 `user_profile` 默认单行（§4.2），全部在 `onCreate` 事务内。
5. `KcalResolver` 接线：装配层用 `FoodKnowledgeBase`（`PLAN-P-08` 的 `foods.json`）实现 `KcalResolver`（API-03 §3），注入 `StatsRepo` 实现类；`kcalFor` 对未注册 `classId` **必须抛 `ACD-KB-001`**，禁止兜底 0。
6. `toMap` / `fromMap`：布尔列写 `v ? 1 : 0`、读 `(v as int) == 1`；时间列全部 `int`（epoch ms UTC），禁止 `DateTime` 直存（`API-00` §3.2）。

### 3.3 禁止事项（与实现同步冻结）
1. 不得新增 `BLOB` 列、不得新增音频相关表（FF-24 第 1、3 条）。
2. 不得新增 `session_id` 列（API-03 §2 裁定 v1.0 不入库）；不得新增热量表（API-03 §3 用 `KcalResolver` 端口）。
3. 不得为 `X-02` / `X-03` / `X-05` / `X-07` 预留任何列或视图（`SPEC-D-01` §9）。
4. 不得新增 `behavior_metrics` 的二级索引（`SPEC-D-01` §4.5 已给出理由）。
5. 不得写入 `zhName` / `portionDesc` / `portionKcal` / `nutritionTags` / `riskNote`（API-03 §2 禁止入表）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `schema_test.dart -t "schema: 表与列齐全"` | 单元 | 表集合 ⊇ 4 表；每表列名集合逐项相等且**不含 `session_id`**；命名正则全通过；无 `BLOB` | 每次改动 `schema.dart` 后 |
| `schema_test.dart -t "schema: app_meta 必需键"` | 单元 | 6 个 key 的 `COUNT(*) == 6` | 同上 |
| `schema_test.dart -t "schema: 1:1 无缺行"` | 单元 | 缺行数 == 0 且孤儿数 == 0 | 每次改动写入路径后 |
| `schema_test.dart -t "schema: 约束生效"` | 单元 | 级联删除后 `behavior_metrics` 行数 == 0；`profile_id=2` 抛 `ACD-DB-004` | 同上 |
| `schema_test.dart -t "schema: 索引被使用"` | 单元 | 三条 `EXPLAIN QUERY PLAN` 含索引名；四条 D-03 查询计划不含 `SCAN diet_record` | 每次改动索引后（D5 与 D7 各一次） |
| `schema_test.dart -t "schema: fromMap/toMap 往返"` | 单元 | 含极值样本（含 `speedGrade='偏慢'`）逐字段相等 | 每次改动模型后 |
| `column_map_test.dart -t "schema: 列映射与 API-03 一致"` | 单元 | `schema.dart` 的列集合与 API-03 §2 映射表逐列相等，差异数 == 0 | D5、D8 各一次 |
| `kcal_resolver_test.dart -t "kcal: 未注册类抛错"` | 单元 | 未注册 `classId` → 抛 `ACD-KB-001`，**不返回 0** | D5、D8 |
| `schema_dump.ps1` → `grep -ci blob` | 脚本 | 退出码 0 且命中数 == 0 | D5、D9 回归清单 |
| `aapt dump badging` 权限复核 | 脚本 | 输出不含 `android.permission.INTERNET` | 与 `PLAN-C-01` 合并执行 |

## 5. 完成定义（DoD）
- [ ] `SPEC-D-01` §7 全部 9 条判据通过，证据落在 `app/test/db/schema_test.dart` 的对应测试名上。
- [ ] `app/lib/data/db/schema.dart` 与 `SPEC-D-01` §4.1 逐字一致，且列集合与 **API-03 §2** 逐列相等（评审签字）。
- [ ] 连续执行两次 `onCreate`（删库重建）结果一致；`PRAGMA user_version == kDbVersion`。
- [ ] `KcalResolver` 已接线且未注册类抛 `ACD-KB-001`（判据「kcal: 未注册类抛错」）；`/10_功能清单` 的 `D-01` 行提到的 `DailyAggregate` 已按 `SPEC-D-01` §10 问题 1 获得 B+C 书面结论。
- [ ] `.schema` 文本证据已归档，进入 `PLAN-C-05` 的演示前回归清单。
- [ ] DDL 冻结后，任何改动均已在 `PLAN-C-03` 的变更传播单登记。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `foods.json` D1 未定稿，`KcalResolver` 无数据 | 端口无法为全部 6 类返回热量 | 装配层先对未开放类抛 `ACD-KB-001`（**不得**填 0），并在 `app_meta` 记待办；D8 前必须补齐，否则 `estimatedKcal` 不可用 |
| `API-03` 再次修订导致列映射漂移 | `column_map_test.dart` 红 | **以 API-03 为准**改 `schema.dart`，同时回改 `SPEC-D-01` §4.1/§4.6 并登记 `PLAN-C-03` 变更单 |
| `DailyAggregate` 结论要求物化表 | B+C 结论为「要求物化」 | D5 前追加 1 张聚合表 + 刷新时机，工时 +2 h，从 D-03 预算调拨；**须走 `PLAN-C-03` 变更单** |
| 索引不被查询计划采用 | 判据 7 出现 `SCAN diet_record` | 先核对 `WHERE` 是否对 `eaten_at_ms` 做了函数包装；仍不采用则与 `PLAN-D-03` 一起重写查询，**不允许**为了过测试而删断言 |
| 模型输入帧数修订值被改动（FF-11 = **`n_frames = 128`**，`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~） | 有人改 FF-11 或缩短窗口 | 与本 Schema **无关**（本域不存 Mel 张量），不阻塞 D5；但 `PLAN-C-03` 的常量生成会随之变化，须上报并走 `SPEC-C-03` 变更传播 |

## 7. 与检查点的关系
- 本功能是 **CP2（D5 晚：端到端闭环跑通）** 的组成部分：闭环要求「录音 → Mel → 推理 → 落库 → 显示」，其中「落库」即本 PLAN 的交付物。
- CP2 判据不要求聚合查询（`SPEC-D-03`，D7），只要求 **1 条记录能正确写入并读回**。
- 若 D5 晚 CP2 未通过且定位到本功能：`PLAN-00` §2 的处置是「D6 全天扑联调，UI 与报告页砍到最简」。本功能的**最小可交付子集**为：4 张表 + 3 索引 + `DietRecord`/`BehaviorMetrics` 双向往返（WBS 任务 1、2）；`KcalResolver` 接线与 `app_meta` 演示键可推迟到 D8。
- 本功能**不参与** CP1（D3）与 CP3（D9）的判据，但 `P-06` 的写入依赖本 Schema 冻结，故 D5 是硬底线。

---
**文档结束**
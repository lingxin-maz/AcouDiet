# SPEC-D-02 DAO 与数据库迁移

| 项 | 值 |
|---|---|
| 域 | D · 数据与本地后端 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | API-03 §1/§3/§4/§8/§9/§10（L3 契约与不变量，**权威**）；API-05 §5.2/§5.3/§5.5/§5.6/§8；API-00 §3.5/§3.7；PLAN-00 §4「占位数据解耦」；API-01 §2.5/§2.7 |
| 依赖的 SPEC | SPEC-D-01（表与索引定义） |

## 1. 目标与范围
### 1.1 一句话目标
给出 `sqflite` 的 DAO 与 `onUpgrade` 迁移链，把「会话结束 → **一个事务**写 1 行 `diet_record` + 1 行 `behavior_metrics`」固化为 `DietRepo` 抽象，并提供 `FakeRepo` 占位实现；写失败时**重试 1 次**、仍失败则**内存暂存并提示**，**绝不静默丢记录**。
### 1.2 范围内（In Scope）
1. `AppDatabase` 单例的打开 / 关闭 / `onConfigure` / `onCreate` 委托 / `onUpgrade` 迁移链。
2. DAO：`DietDao`、`MetricsDao`、`ProfileDao`、`MetaDao`（**仅 L3 内部**，L4/L5 不得直接调；契约以 **API-03 §3** 为准，本 SPEC 不复制方法表）。
3. `DietRepo` 抽象（6 个方法，签名以 **API-03 §4** 为准）与 `RealDietRepo` 实现；`insertSession` 的事务边界。
4. `FakeRepo`：纯内存占位实现，**同时实现 `DietRepo` / `StatsRepo` / `ProfileRepo`，不实现 `MaintenanceRepo`**（API-03 §8），供 C 在 B 就绪前开发 UI（PLAN-00 §4）。
5. 写失败的重试、内存暂存队列 `PendingWriteQueue` 与 `pendingWrite` 提示状态。
6. 迁移框架：`_migrations` 列表、版本单调递增、逐个版本升序执行、失败整体回滚。
### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
1. **不定义表、列、约束、索引** —— 属 `SPEC-D-01`；本功能只**执行**那份 DDL。
2. **不写任何聚合查询、不定义零食/正餐口径** —— 属 `SPEC-D-03`。
3. **不做评分、建议、报告** —— 属 `SPEC-A-01`~`A-03`。
4. **不做演示数据双轨**（`SPEC-A-04`）。`FakeRepo` 只是 UI 占位，**不是**演示数据集；演示数据走 `RealDietRepo` + `source='demo'` + `app_meta.demo_data_enabled`。
5. **不做**数据库加密、不做多连接/连接池、不做 ORM 代码生成、不做 upsert/合并语义。
6. **不做**任何网络同步、冲突解决、离线队列（API-05 §1、§8）。

## 2. 功能行为
### 2.1 触发与前置条件
| 触发 | 前置条件 |
|---|---|
| 首次访问数据层 | Riverpod 单例首次读取 `AppDatabase` 时打开；`onCreate` 已按 `SPEC-D-01` 建表 |
| 一次检测会话结束（`sessionEnded` 事件或用户手动停止，API-01 §2.5） | `P-06` 已产出最终 `DietRecord` 与非空的 `BehaviorMetrics?`（可为 `null`） |
| 音频残留清理（`SPEC-D-05`） | **必须在本功能的事务提交之后触发**，不得反向依赖 |
| 返回前台 / 数据库重新打开 | `flushPending()` 尝试重放内存暂存队列 |
### 2.2 主流程（编号步骤）
1. `AppDatabase.open()`：`openDatabase(path: 'acoudiet.db', version: kDbVersion, onConfigure: …, onCreate: …, onUpgrade: …)`；句柄进程内缓存，**禁止重复 open**（API-05 §5.2）。
2. 会话结束 → 调用 `DietRepo.insertSession(record: r, metrics: m)`。
3. `insertSession` 开事务 → `INSERT INTO diet_record` → `m ?? BehaviorMetrics.placeholder(r.recordId)` 写 `behavior_metrics` → `commit`。
4. 事务抛异常 → 整体回滚 → 等待**重试间隔** → 用同一事务**完整重试 1 次**。
5. 重试仍失败 → `(record, metrics)` 入内存 `PendingWriteQueue`，`pendingWriteProvider` 置 `hasPending` + `count`，UI 提示；**不抛出到 UI 崩溃**。
6. `flushPending()`：逐条重放；成功则出队并更新 `pendingWriteProvider`；仍失败则保留在队列。
7. `FakeRepo`：全部方法只读写内存 `List<DietRecord>`（固定种子数据），**不触碰 SQLite**，行为与 `RealDietRepo` 由同一套契约测试覆盖。
### 2.3 状态与状态迁移（有状态的功能必填）
写入侧状态机：`IDLE → WRITING → (COMMITTED | RETRYING → WRITING) → (COMMITTED | PENDING)`。
- `RETRYING` 仅允许 **1 次**（API-05 §8）。
- `PENDING` 不是丢失态；`flushPending()` 成功后回到 `COMMITTED`。
- **不存在「丢弃」终态** —— 这是本功能的硬不变量。
### 2.4 边界条件
| 边界 | 规定 |
|---|---|
| `metrics == null` | 写占位行（`chew_count` 等四列全 `NULL`），**不得**少写行（API-05 §5 一致性红线） |
| 同一 `recordId` 重复 `insertSession` | `PRIMARY KEY` 冲突 → `ACD-DB-002`；**不覆盖**已有记录（幂等由调用方 `P-06` 保证，本功能不做 upsert） |
| 迁移脚本中途抛异常 | `onUpgrade` 事务整体回滚，`PRAGMA user_version` **不前进**；App 停留在旧版本可用状态，记日志并计入 `M-04` 自检面板 |
| `oldVersion` 跨多个版本 | 按版本号**升序逐个**执行迁移（1→2→3），**禁止**一步到位的合并脚本 |
| 内存暂存队列超过 50 条 | 保留并记日志（**不丢弃**）；提示文案不变，但 `pendingWriteProvider.count` 如实上报 |
| 数据库文件被外部删除 | 下次 `open()` 走 `onCreate`；内存队列仍尝试重放 |
| 约束冲突（非瞬时错误） | 重试无意义 → **不重试**，直接进 `PENDING` + 提示（仍不丢记录） |

## 3. 接口契约
> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准，此处给「本功能用到的部分」并标注 API 编号。
| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L4 → L3 | `DietRepo.insertSession({required DietRecord record, required BehaviorMetrics? metrics})` | 见左 | `Future<void>` | `ACD-DB-001` / `ACD-DB-002` |
| L4 → L3 | `DietRepo.byRange(DateRange r)` | `startMs`（含）/ `endMs`（不含）；`startMs > endMs` → `ACD-DB-004` | `Future<List<DietRecord>>`，按 `eatenAtMs` 升序 | `ACD-DB-001` / `ACD-DB-004` |
| L4 → L3 | `DietRepo.byId(String recordId)` | 记录 ID | `Future<DietRecord?>`（不存在返回 `null`，**不抛异常**） | — |
| L4 → L3 | `DietRepo.deleteById(String recordId)` | 记录 ID | `Future<int>` 受影响行数（`0` 或 `1`） | `ACD-DB-001` |
| L4 → L3 | `DietRepo.deleteAll()` | 无 | `Future<int>` 删除的记录行数 | 见 `SPEC-D-05` |
| L4 → L3 | `DietRepo.countAll()` | 无 | `Future<int>` | `ACD-DB-001` |
| L3 内部 | `AppDatabase.open()` / `onUpgrade` / `flushPending()` | `kDbVersion` | `Database` / `void` | `ACD-DB-001` |
| L5 ← L4 | `pendingWriteProvider` | 无 | `{hasPending: bool, count: int, lastError: AcouDietError?}` | — |
- `DietDao` / `MetricsDao` / `ProfileDao` / `MetaDao` 是 **L3 内部细节**；L5 不得直接调用（API-00 §1 耦合规则 1），测试可用 `@visibleForTesting`。
- 接口名、参数名、返回类型以 **API-03 §3/§4** 为准；本表只给「本功能用到的部分」，**不得**在此复制完整签名。

## 4. 数据契约
### 4.1 内存暂存队列条目（`PendingWriteQueue` 的元素）
| 字段 | 类型 | 说明 |
|---|---|---|
| `record` | `DietRecord` | 原始记录（含 `recordId`） |
| `metrics` | `BehaviorMetrics?` | 可为 `null`，重放时按 §2.4 写占位行 |
| `attempts` | `int` | 已尝试事务次数（1 或 2） |
| `lastError` | `AcouDietError?` | 最近一次失败原因，用于提示与诊断 |
| `queuedAtMs` | `int` | 入队时刻 epoch ms UTC |
> 队列为**纯内存**结构，进程被杀即丢失（见 §10 问题 2）；**禁止**为它建表（会引入一份类记录数据，触碰 FF-24 边界）。
### 4.2 迁移元数据（`_migrations`）
| 字段 | 类型 | 说明 |
|---|---|---|
| `fromVersion` | `int` | 起始版本（含） |
| `toVersion` | `int` | 目标版本（通常是 `fromVersion + 1`） |
| `statements` | `List<String>` | 该步的 SQL 语句（幂等：`CREATE TABLE IF NOT EXISTS` / `ALTER TABLE` 前先探测） |
> 版本单步递增；不写「降级迁移」（v1.0 无回滚需求）。`kDbVersion` 与 `app_meta.schema_version` 必须一致。
### 4.3 关键 SQL（DAO 层，参数化绑定，禁止字符串拼接）
```sql
-- insertSession（同一事务内两条）
INSERT INTO diet_record (record_id, session_id, eaten_at_ms, ended_at_ms, class_id,
  class_label, attribute, confidence, duration_seconds, source, corrected_by_user,
  confirmed_by_user, created_at_ms, updated_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
INSERT INTO behavior_metrics (record_id, chew_count, avg_chew_interval_seconds,
  duration_seconds, speed_grade, created_at_ms) VALUES (?,?,?,?,?,?);
-- byRange：半开区间，靠 SPEC-D-01 的 idx_diet_record_eaten_at
SELECT * FROM diet_record WHERE eaten_at_ms >= ? AND eaten_at_ms < ? ORDER BY eaten_at_ms ASC;
```

## 5. 参数与常量
> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。
| 项 | 引用 |
|---|---|
| 表、列、索引、约束、1:1 不变量 | SPEC-D-01 §4.1 / §4.5 / §2.4 |
| 进程内唯一 `Database` 句柄；写时机；事务边界；迁移幂等 | API-05 §5.2 / §5.3 / §5.5 / §5.6 |
| 「数据库写入失败 → 重试 1 次；仍失败则内存暂存 + 提示」 | API-05 §8 |
| SQLite 读写线程与单次查询预算 | API-00 §3.7 |
| 错误码：`ACD-DB-001`（迁移/打开失败）、`ACD-DB-002`（唯一约束）、`ACD-DB-003`（事务提交失败已回滚，`retryable=true`）、`ACD-DB-004`（入参非法/表列缺失） | **API-03 §9**（`003`/`004` 待补登 API-00 §3.5） |
| 会话结束事件与 `endReason` 枚举 | API-01 §2.5 |
| 重试间隔 `300 ms`（本 SPEC 为 DB 重试固定，取值沿用 API-05 §8 中 `ACD-AUD-001` 的既有间隔） | 见 §10 问题 1 |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 打开/迁移失败（`ACD-DB-001`） | `openDatabase` 或 `onUpgrade` 抛异常 | **不重试**（无处暂存）；fail fast，保持旧版本可用 | 全页错误态：「本地数据库不可用」 |
| 事务提交失败并已回滚（`ACD-DB-003`） | 写路径统一包装捕获（`retryable=true`） | `RETRYING` 等 **300 ms** 重试 1 次；仍失败入队 | 重试期间无提示（<1 s），耗尽后出提示卡 |
| 入参非法 / 表列缺失（`ACD-DB-004`） | `DateRange` 反序、`days` 越界、库 schema 与代码不一致 | **不重试**（`retryable=false`），抛给 L4 | 提示「数据校验失败」，页面错误态 |
| 重试仍失败 | 第 2 次事务抛异常 | 入 `PendingWriteQueue`，`pendingWriteProvider` 置 `hasPending` | 顶部提示卡「本次记录已暂存，将在稍后重试」 |
| 唯一约束冲突（`ACD-DB-002`） | `record_id` 重复 | **不重试**，直接入队 + 记 `lastError` | 同上（文案一致，避免暴露内部错误码） |
| 事务后出现半写（理论不可能） | 启动自检：`SPEC-D-01` §7 判据 4 的缺行/孤儿行计数 | 计数 > 0 → 记日志 + 计入 `M-04` 自检面板**失败项** | 自检面板显示「数据一致性：异常」 |
| 队列非空且进程被杀 | 无法在进程内检测 | 记录丢失（内存态）；下次启动 `countAll()` 不包含这些记录 | 用户已在上一次提示中被告知「暂存」 |
| `FakeRepo` 被误用于生产 | 代码审查 + `grep -rn "FakeRepo" app/lib/main.dart` | release 构建不得引用 `FakeRepo` | 无 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 会话写入是单事务（无半写） | `flutter test app/test/repo/insert_session_test.dart -t "repo: 事务原子性"`：注入使 `behavior_metrics` 插入失败，断言 `countAll() == 0` 且 `SELECT COUNT(*) FROM behavior_metrics == 0` | 两表均 0 行 |
| 2 | 无指标时写占位行 | `-t "repo: 占位行"`：`insertSession(r, null)` → `behavior_metrics` 行数 == 1，且四列 `IS NULL` | 1 行 / 四列 NULL |
| 3 | 重试语义正确 | `-t "repo: 重试 1 次成功"`：mock 第 1 次抛、第 2 次成功 → 断言 `attempts == 2`、写入成功、`countAll() == 1` | `attempts == 2` |
| 4 | 重试耗尽后进入内存暂存 | `-t "repo: 暂存不丢记录"`：mock 连续 2 次抛 → 断言 `PendingWriteQueue.length == 1`、`pendingWrite.hasPending == true`、无异常逃逸 | 全部成立 |
| 5 | **记录守恒律**（绝不静默丢） | `-t "repo: 守恒律"`：对 1000 次写入随机注入失败（含约束冲突），断言 `countAll() + pendingQueue.length == 1000` | 等式成立 |
| 6 | 迁移幂等 | `-t "repo: 迁移幂等"`：连续执行同一 `onUpgrade(from, to)` 三次，每次后取 `sqlite_master` 快照，断言三次快照字符串相等 | 三次相等 |
| 7 | 跨版本按序执行 | `-t "repo: 迁移升序"`：`onUpgrade(1, 3)` 断言迁移日志为 `['1->2','2->3']`（顺序与内容） | 顺序断言通过 |
| 8 | 迁移失败整体回滚 | `-t "repo: 迁移回滚"`：令 `2->3` 抛异常 → 断言 `PRAGMA user_version == 2` 且 `diet_record` 可读 | 版本停在 2 |
| 9 | 两个 Repo 实现契约一致 | `flutter test app/test/repo/diet_repo_contract_test.dart`（对 `RealDietRepo` 与 `FakeRepo` 参数化执行同一套 `DietRepo` 用例） | 两实现全通过，0 差异 |
| 10 | `FakeRepo` 实现范围正确 | `-t "repo: FakeRepo 范围"`：断言 `FakeRepo is DietRepo && is StatsRepo && is ProfileRepo`，且 `FakeRepo is! MaintenanceRepo`（API-03 §8） | 全部成立 |
| 10 | 参数化 SQL，无字符串拼接 | `grep -rnE "rawQuery\(.*\\\$|execute\(.*\\\$" app/lib/data/` | 命中数 == 0 |
| 11 | 推理 isolate 不碰数据库 | `grep -rn "sqflite" app/lib/domain/inference/` | 命中数 == 0 |
| 12 | 查询预算 | `-t "repo: 查询预算"`：1000 行夹具下 `byRange` 连续 100 次，平均耗时 | < 20 ms（API-00 §3.7） |
| 13 | release 不引用 `FakeRepo` | `grep -rn "FakeRepo" app/lib/main.dart app/lib/app.dart` | 命中数 == 0 |

## 8. 非功能约束
| 项 | 约束 | 依据 |
|---|---|---|
| 线程 | SQLite 读写全部在 Dart 主 isolate；**不得**在推理 isolate 触发任何 DB 调用 | API-00 §3.7 |
| 性能 | 单次查询 < 20 ms；会话结束的写事务为批量提交（一次事务两行） | API-00 §3.7 / API-05 §5.3 |
| 错误处理 | 数据层异常一律转 `AcouDietError`（API-00 §3.5），不得让 `DatabaseException` 逃逸到 L5 | API-00 §3.5 |
| 隐私 | 暂存队列只在内存；表内不得出现音频列（继承 `SPEC-D-01`） | FF-24 第 1、3 条 |
| 无障碍 | 无（数据层无 UI） | — |

## 9. 裁剪与未做
1. **本功能不可裁剪**：`00_功能清单与数量分析.md` §6 不可砍项 ②「自动生成记录（`D-01`~`D-03`、`P-06`）」的落库环节即本功能。
2. `X-02` 手动修正已降级：`insertSession` **不接受**「更新已有记录类别」的语义；`byId`/`deleteById` 只服务二选一确认与删除误报，**不提供** `updateClass()` 之类的方法。
3. `X-03` CSV 导出**已删除**：`DietRepo` **不得**提供 `export*` 方法或返回全表快照的便捷方法（`byRange` 的最大区间由 D-03 的报表需求决定）。
4. 不做 ORM 代码生成（`build_runner` 生成 DAO）、不做连接池、不做多数据库分库、不做数据加密（API-05 §5.7）。

## 10. 开放问题
| # | 问题 | 影响面 | 谁拍板 | 截止 |
|---|---|---|---|---|
| 1 | DB 写重试间隔取 `300 ms`（沿用 API-05 §8 中 `ACD-AUD-001` 的既有间隔）。是否需要为 DB 另定值？ | 重试总时长与 UI 提示时延 | B + C | D5 |
| 2 | 内存暂存队列**不落盘** → 进程被杀则丢。若要落盘，需要一张「待写队列表」，本质是第二份记录数据，须重新评估 FF-24 边界与 `SPEC-D-01` 的表清单 | 数据可靠性 vs 隐私边界 | A + B | D5 |
| 3 | v1.0 只有 `kDbVersion = 1`，**`onUpgrade` 在真实运行中无路径可走**。判据 6/7/8 只能用「测试专用注入迁移」覆盖，是否接受？还是要求 D5 前先造一个 `version=2` 的真实迁移？ | 迁移链的可验证性 | B + C | D5 |
| 4 | `FakeRepo` 在 D8 真实数据接通后是否保留？建议保留（离线单测），并以 release 构建不引用作为唯一约束 | 包体与测试策略 | C | D8 |
| 5 | `pendingWriteProvider` 的提示是否需要「立即重试」按钮（触发 `flushPending()`）？属 `SPEC-U-05` 的交互，本 SPEC 只暴露状态 | UI 交互范围 | C | D8 |

---
**文档结束**
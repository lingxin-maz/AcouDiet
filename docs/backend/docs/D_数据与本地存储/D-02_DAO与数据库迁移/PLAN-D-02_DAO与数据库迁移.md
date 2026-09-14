# PLAN-D-02 DAO 与数据库迁移

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-D-02 |
| 负责 | B（主责）；C 协助 `FakeRepo` 的占位数据形态与 UI 提示文案 |
| 目标日 | D5 |
| 前置依赖 | `PLAN-D-01` 的 `schema.dart` 与三个模型（D5 同日前半段完成）；`PLAN-P-06` 提供的会话结束回调形态；Riverpod 环境（`PLAN-C-03` 的常量生成不阻塞本项） |
| 预估工时 | 7 h（AppDatabase + 迁移 2 h + 4 个 DAO 1.5 h + Repo 与占位 1.5 h + 重试与暂存 1 h + 测试 1 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 验收方式 |
|---|---|---|
| 1 | `app/lib/data/db/app_database.dart` | `AppDatabase`：单例句柄、`onConfigure`（`PRAGMA foreign_keys=ON`）、`onCreate` 委托 `SPEC-D-01`、`onUpgrade` 调用迁移链 |
| 2 | `app/lib/data/db/migrations.dart` | `Migration` 数据类 + `_migrations` 列表 + `runUpgrade(Database, int from, int to)`（升序逐个、单事务、失败整体回滚） |
| 3 | `app/lib/data/dao/diet_dao.dart` | `DietDao`（**API-03 §3** 命名）：insert / selectByRange / selectById / deleteById / deleteAll / countAll，全部参数化 SQL |
| 4 | `app/lib/data/dao/metrics_dao.dart` | `MetricsDao`：insertPlaceholder / insert / selectByRecordId |
| 5 | `app/lib/data/dao/profile_dao.dart` | `ProfileDao`：select / upsert（`SPEC-D-04` 复用） |
| 6 | `app/lib/data/dao/meta_dao.dart` | `MetaDao`：get / put；键集合见 `SPEC-D-01` §4.3 |
| 7 | `app/lib/data/repo/diet_repo.dart` | `abstract class DietRepo`（6 个方法，签名以 **API-03 §4** 为准） |
| 8 | `app/lib/data/repo/real_diet_repo.dart` | `insertSession` 单事务 + 重试 1 次 + 入队；`flushPending()` |
| 9 | `app/lib/data/repo/fake_repo.dart` | `class FakeRepo implements DietRepo, StatsRepo, ProfileRepo`（**API-03 §8**，**不实现** `MaintenanceRepo`）；纯内存、固定基准日、`source='demo'`；**不被 `main.dart` 引用** |
| 10 | `app/lib/data/pending_write_queue.dart` | 队列 + `pendingWriteProvider`（`hasPending` / `count` / `lastError`） |
| 11 | `app/test/repo/insert_session_test.dart` | 承载 `SPEC-D-02` §7 判据 1~5 |
| 12 | `app/test/repo/migration_test.dart` | 承载判据 6~8 |
| 13 | `app/test/repo/diet_repo_contract_test.dart` | 参数化跑 `RealDietRepo` 与 `FakeRepo`（判据 9） |
| 14 | `app/test/repo/query_budget_test.dart` | 判据 12 |

> `app/` 目录由 B 在 D1 初始化（`PLAN-00` §1）；路径全部相对该根目录。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | `AppDatabase` 单例 + `onConfigure` + `onCreate` 委托 | 交付物 1 | 1 h | `PLAN-D-01` 交付物 1 |
| 2 | 迁移框架与 `runUpgrade`（升序、事务、回滚） | 交付物 2 | 1 h | 1 |
| 3 | 4 个 DAO（全参数化 SQL，命名照 API-03 §3） | 交付物 3~6 | 1.5 h | 2 |
| 4 | `DietRepo` 抽象 + `RealDietRepo.insertSession` 事务 | 交付物 7、8 | 1 h | 3 |
| 5 | 重试 1 次 + `PendingWriteQueue` + provider | 交付物 10、8 | 1 h | 4 |
| 6 | `FakeRepo`（三接口内存实现） | 交付物 9 | 0.5 h | 7（抽象） |
| 7 | 三套测试（事务/暂存/迁移/契约/预算） | 交付物 11~14 | 1 h | 5、6 |
| **合计** | | | **7 h** | |

## 3. 技术方案

### 3.1 关键骨架（≤30 行，**不写完整实现**）
```dart
// app/lib/data/repo/real_diet_repo.dart
class RealDietRepo implements DietRepo {
  RealDietRepo(this._db, this._queue);

  @override
  Future<void> insertSession({required DietRecord record, required BehaviorMetrics? metrics}) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _db.transaction((txn) async {
          await DietDao(txn).insert(record);                   // 1) 记录
          await MetricsDao(txn).insert(                          // 2) 指标（无则占位行）
              metrics: metrics ?? BehaviorMetrics.placeholder(record.recordId),
              recordId: record.recordId, txn: txn);
        });
        return;                        // COMMITTED
      } on DatabaseException catch (e) {
        final err = AcouDietError.fromDb(e);        // → ACD-DB-002 / ACD-DB-003 / ACD-DB-004
        if (err.code == 'ACD-DB-002' || err.code == 'ACD-DB-004') {
          _enqueue(record, metrics, attempt, err); return;   // 重试无意义
        }
        if (attempt == 2) { _enqueue(record, metrics, attempt, err); return; }  // 重试耗尽
        await Future<void>.delayed(kDbRetryDelay);  // 300 ms，见 SPEC-D-02 §5
      }
    }
  }
}
```
**硬性要求**：`DietRepo` 的 6 个方法签名以 **API-03 §4** 为准（本 PLAN 不复制签名）；`RealDietRepo` 与 `FakeRepo` 必须能被同一套契约测试参数化执行。

### 3.2 实现步骤
1. `onConfigure` 内 `PRAGMA foreign_keys = ON`（**每个连接**；仅写 `onCreate` 不算完成）。
2. `onCreate` 逐条执行 `SPEC-D-01` 的 `kCreateTableStatements` → `kCreateIndexStatements` → 六个 `app_meta` 键 → `user_profile` 默认单行，全部包在同一事务内。
3. `runUpgrade(db, from, to)`：取 `_migrations.where(m => m.fromVersion >= from && m.toVersion <= to)`，按 `fromVersion` 升序执行；整体包在 `db.transaction` 内；任一语句抛异常即抛出以触发回滚。
4. DAO 全部使用 `?` 占位符；**禁止**字符串拼接（判据 10 静态检查）。
5. `insertSession` 的重试只针对 `ACD-DB-003`（事务提交失败已回滚）；`ACD-DB-002` / `ACD-DB-004` 重试无意义，直接入队或抛出。
6. `PendingWriteQueue` 为纯内存 `List<QueueEntry>`；`pendingWriteProvider` 用 Riverpod `StateNotifier` 暴露 `hasPending` / `count` / `lastError`（`SPEC-U-05` 消费）。
7. `flushPending()`：按入队顺序逐条重放；成功出队；失败保留并更新 `attempts`、`lastError`。**`MaintenanceRepo.clearAllData()` 必须先清空本队列**（`SPEC-D-05` §2.2 D，防止幽灵记录）。
8. `FakeRepo`：`implements DietRepo, StatsRepo, ProfileRepo`（API-03 §8），构造时注入固定种子、时间戳基于**固定基准日**（禁止 `DateTime.now()`），产出 `source='demo'`；`insertSession` 同样写占位行；**不写库、不实现 `MaintenanceRepo`**。

### 3.3 禁止事项（与 SPEC 同步冻结）
1. 不得新增 `DietRepo` 方法（尤其 `updateClass()` / `exportCsv()`）。
2. 不得让 `sqflite` 依赖出现在 `app/lib/domain/` 下。
3. 不得为 `PendingWriteQueue` 建表（`SPEC-D-02` §4.1）。
4. 不得把 `FakeRepo` 作为演示数据（`SPEC-A-04` 的职责，走 `RealDietRepo` + `source='demo'`）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `insert_session_test.dart -t "repo: 事务原子性"` | 单元 | 指标插入失败时 `diet_record` 与 `behavior_metrics` 均 0 行 | 每次改 `insertSession` 后 |
| `insert_session_test.dart -t "repo: 占位行"` | 单元 | `metrics=null` → 指标行数 1 且四列 `IS NULL` | 同上 |
| `insert_session_test.dart -t "repo: 重试 1 次成功"` | 单元 | `attempts == 2` 且写入成功 | 同上 |
| `insert_session_test.dart -t "repo: 暂存不丢记录"` | 单元 | 连续失败后队列长度 1、`hasPending == true`、无异常逃逸 | 同上 |
| `insert_session_test.dart -t "repo: 守恒律"` | 单元 | 1000 次随机失败注入：`countAll() + queue.length == 1000` | D5、D8 各一次 |
| `migration_test.dart -t "repo: 迁移幂等"` | 单元 | 同一迁移执行 3 次，`sqlite_master` 快照相等 | 每次改 `_migrations` |
| `migration_test.dart -t "repo: 迁移升序"` | 单元 | `1->3` 的迁移日志顺序为 `['1->2','2->3']` | 同上 |
| `migration_test.dart -t "repo: 迁移回滚"` | 单元 | `2->3` 抛异常后 `user_version == 2` 且表可读 | 同上 |
| `diet_repo_contract_test.dart` | 契约 | 两实现全部用例通过，0 差异 | D5、D8 |
| `query_budget_test.dart -t "repo: 查询预算"` | 单元 | 1000 行夹具下 `byRange` 平均耗时 < 20 ms（`API-00` §3.7） | D5、D7 |
| 静态检查 `grep -rn "sqflite" app/lib/domain/inference/` | 脚本 | 命中 0 | D5、D9 回归 |
| 静态检查 `grep -rn "FakeRepo" app/lib/main.dart app/lib/app.dart` | 脚本 | 命中 0 | D8、D9 |

## 5. 完成定义（DoD）
- [ ] `SPEC-D-02` §7 全部 13 条判据通过，证据落在上表对应测试名或脚本命中数上。
- [ ] `DietRepo` 抽象与 `SPEC-D-02` §3 的 6 个方法签名逐字一致（评审签字）。
- [ ] `RealDietRepo` 与 `FakeRepo` 由同一套契约测试覆盖且全绿。
- [ ] 守恒律测试（判据 5）在 D5 与 D8 各跑一次并留档 —— 这是「绝不静默丢记录」的唯一机器证据。
- [ ] `onUpgrade` 的开放问题（`SPEC-D-02` §10 问题 3：v1.0 无真实升级路径）已有 B+C 书面结论。
- [ ] `pendingWriteProvider` 的 `hasPending` / `count` / `lastError` 已交付给 C，并在 `SPEC-U-05` 的提示文案中落地。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 迁移框架在 v1.0 无真实路径，测试自证不足 | `SPEC-D-02` §10 问题 3 无结论 | 保留框架 + 测试专用迁移；把「真实升级演练」列进 v1.1 待办，并在 `PLAN-C-05` 回归清单中标注「未覆盖」 |
| 500 次以上写入时事务重试与 UI 提示互相干扰 | 守恒律测试出现偶发不等 | 队列改为 `synchronized` 串行化；提示改为「累计 N 条」，不逐条弹窗 |
| `FakeRepo` 与 `RealDietRepo` 语义漂移 | 契约测试红 | **以 `RealDietRepo` 为准**修 `FakeRepo`；禁止为迁就 UI 而改契约 |
| `PLAN-D-01` 延期导致 DAO 无表可依 | D5 上午 `schema.dart` 未交付 | 本 PLAN 任务 3~7 可先按冻结的 `SPEC-D-01` §4.1 手写 SQL 常量并行开发；**不得**自行改动 DDL |

## 7. 与检查点的关系
- 本功能是 **CP2（D5 晚：端到端闭环跑通）** 的核心判据环节：「录音 → Mel → 推理 → **落库** → 显示」。
- CP2 的最小可交付子集 = WBS 任务 1、3、4（能写入 1 条记录并读回）；重试、暂存、迁移框架可推迟到 D6 上午，**但守恒律与占位行两项判据不得推迟**（它们是 `SPEC-D-01` 1:1 不变量的唯一运行时保证）。
- 若 CP2 未通过且定位到本功能：`PLAN-00` §2 处置为「D6 全天扑联调，UI 与报告页砍到最简」；本功能的降级顺序为 ①先保 `insertSession` 直写（去掉暂存）②再保 `byRange`（供记录页）③最后才允许降级迁移框架。
- 本功能是 **CP4（D7 晚：报告页接通真实数据）** 的前置：`PLAN-D-03` 的聚合查询建立在 `RealDietRepo` 之上。

---
**文档结束**
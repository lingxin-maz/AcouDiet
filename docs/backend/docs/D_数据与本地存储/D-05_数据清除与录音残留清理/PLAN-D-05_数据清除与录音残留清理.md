# PLAN-D-05 数据清除与录音残留清理

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-D-05 |
| 负责 | B（主责）；C 协助 `U-05` 的二次确认文案与「数据仅存于本机」告知 |
| 目标日 | D8 |
| 前置依赖 | `PLAN-D-02` 的 `AppDatabase`、`DietRepo.deleteAll()`、`PendingWriteQueue`；`PLAN-D-04` 的 `profile_defaults.dart`（默认档案值的唯一来源）；`PLAN-P-01`/`PLAN-P-04` 的 `clearTempAudio` 原生通道（API-01 §2.7）必须已在 D5 前可用 |
| 预估工时 | 4 h（清空事务 1 h + 清理器与触发点 1 h + 诊断上报 0.5 h + 测试 1.5 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 验收方式 |
|---|---|---|
| 1 | `app/lib/data/wipe/data_wipe_service.dart` | `clearAllData()` 单事务 + `WipeResult`（字段逐项照抄 `SPEC-D-05` §3） |
| 2 | `app/lib/data/wipe/audio_residue_cleaner.dart` | `AudioResidueCleaner.run(reason)`；匹配规则见 `SPEC-D-05` §4.2；**永不抛异常** |
| 3 | `app/lib/data/wipe/residue_cleanup_provider.dart` | `residueCleanupProvider`（`lastCleanupAtMs` / `failedCount` / `lastResult`） |
| 4 | `app/lib/app_startup.dart`（清理挂钩，**仅新增调用点**） | 冷启动时调 `run(coldStart)`；不阻塞首帧 |
| 5 | `app/lib/domain/session/session_end_hook.dart`（清理挂钩） | 会话结束：**先** `insertSession` 提交、**后** `run(sessionEnd)` |
| 6 | `app/test/wipe/data_wipe_test.dart` | 承载 `SPEC-D-05` §7 判据 1~7 |
| 7 | `app/test/wipe/audio_residue_test.dart` | 判据 8~11 |
| 8 | `app/test/wipe/wipe_e2e_test.dart` | 判据 12、13（含 `filesDir` 检查） |

> `app/` 目录由 B 在 D1 初始化（`PLAN-00` §1）；路径相对该根目录。交付物 4、5 是**新增调用点**，需与 `PLAN-P-01` / `PLAN-P-06` 的会话状态机文件对齐归属（见 §6 风险）。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | `clearAllData()` 单事务（含档案复位与 `app_meta` 复位） | 交付物 1 | 1 h | `PLAN-D-04` 交付物 4 |
| 2 | `VACUUM` 与 `WipeResult` 组装（`vacuumOk` 不阻断） | 交付物 1 | 0.25 h | 1 |
| 3 | `AudioResidueCleaner`（匹配规则 + 结果上报 + 永不抛异常） | 交付物 2 | 0.75 h | API-01 §2.7 已可用 |
| 4 | 两个触发点（冷启动 / 会话结束，顺序硬约束） | 交付物 4、5 | 0.5 h | 3、`PLAN-D-02` |
| 5 | 诊断与 `app_meta` 计数器上报 | 交付物 3 | 0.5 h | 3 |
| 6 | 三套测试 | 交付物 6~8 | 1 h | 1~5 |
| **合计** | | | **4 h** | |

## 3. 技术方案

### 3.1 关键骨架（≤30 行，**不写完整实现**）
```dart
// app/lib/data/wipe/data_wipe_service.dart
class DataWipeService {
  Future<WipeResult> clearAllData() async {
    final deleted = await _db.transaction((txn) async {          // 单事务：要么全成要么全不成
      final m = await BehaviorMetricsDao(txn).deleteAll();       // 先指标
      final r = await DietRecordDao(txn).deleteAll();            // 后记录
      await UserProfileDao(txn).resetToDefaults(               // 复位默认单行（复用 D-04 的默认值）
            defaults: kDefaultProfile, nowMs: _clock());
      await AppMetaDao(txn).setAll(<String, String?>{           // 复位演示标识与清理计数
        'demo_data_enabled': '0', 'demo_dataset_id': null,
        'demo_data_loaded_at_ms': null, 'last_cleanup_failed_count': '0',
      });                                                        // schema_version 不动
      return (metrics: m, records: r);
    });
    _pendingQueue.clear();                                       // 清内存暂存，避免幽灵记录
    final vacuumOk = await _tryVacuum();                         // 失败只记日志
    final cleanup  = await _cleaner.run(CleanupReason.afterWipe);
    return WipeResult(recordsDeleted: deleted.records, /* … 其余字段见 SPEC-D-05 §3 */);
  }
}
```
```dart
// app/lib/data/wipe/audio_residue_cleaner.dart —— 匹配规则唯一实现处
bool matchesResidue(String fileName) {
  final n = fileName.toLowerCase();
  return n.startsWith('audio_') || n.endsWith('.wav') || n.endsWith('.pcm');
}
```
**硬性要求**：匹配规则只允许出现在 `audio_residue_cleaner.dart`；默认档案值只允许来自 `profile_defaults.dart`。

### 3.2 实现步骤
1. 先落清理器的匹配规则与「不匹配文件绝不删除」的保护（判据 8 是唯一证据）。
2. `clearAllData()`：**显式**删除 `behavior_metrics` 再删 `diet_record`（外键级联会删，但显式删除才能让计数准确）。
3. 档案复位必须调用 `PLAN-D-04` 的 `profile_defaults.dart`；**禁止**在本文件里再写一份 `3 / false / true`。
4. `app_meta` 复位 4 个键，`schema_version` 必须保留（判据 3）。
5. 清理器：捕获所有异常 → 记日志 → 返回 `CleanupResult(failed: …)`，**签名上不抛异常**（`SPEC-D-05` §3）。
6. 触发点顺序（`SPEC-D-05` §2.2 B）：`insertSession` 的 `await` 完成之后**才**调 `run(sessionEnd)`；清理失败**不得**影响已提交的记录，也**不得**触发写入重试。
7. 清空流程末尾**再跑一次** `run(afterWipe)`。
8. 全部完成后跑判据 12（`cacheDir` 与 `filesDir` 匹配文件数为 0）与判据 13（失败计数为 0）。

### 3.3 禁止事项（与 SPEC 同步冻结）
1. 不得提供 `export()` / `backup()` / `undo()` / `restore()` / 回收站（`SPEC-D-05` §9 第 1 条）。
2. 不得清空 `food_kcal`。
3. 不得把 `clearTempAudio` 放进任何 `transaction(` 闭包内。
4. 不得删除 cacheDir 中不匹配 `audio_*` / `*.wav` / `*.pcm` 的文件，不得递归删除目录。
5. 不得因清理失败而重试记录写入或回滚已提交事务（`ACD-IO-001` 语义：不重试、只记日志）。
6. 不得申请存储权限（只访问应用私有 `cacheDir`）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `data_wipe_test.dart -t "wipe: 表已清空"` | 单元 | `diet_record` 与 `behavior_metrics` 行数均为 0 | 每次改清空逻辑 |
| `data_wipe_test.dart -t "wipe: 档案复位"` | 单元 | `user_profile` 行数 1 且四字段等于 `SPEC-D-04` §4.1 默认值 | 同上 |
| `data_wipe_test.dart -t "wipe: app_meta 复位"` | 单元 | 4 个键复位 + `schema_version == '1'` | 同上 |
| `data_wipe_test.dart -t "wipe: 保留参考镜像"` | 单元 | `food_kcal` 清空前后逐行相等 | 同上 |
| `data_wipe_test.dart -t "wipe: 幂等"` | 单元 | 第二次调用删除计数全 0、无异常 | 同上 |
| `data_wipe_test.dart -t "wipe: 事务原子性"` | 单元 | 注入档案复位失败 → `diet_record` 行数不变 | D8 |
| `data_wipe_test.dart -t "wipe: 暂存清空"` | 单元 | 预置 3 条 pending → 清空后队列 0 且 `countAll() == 0` | D8 |
| `audio_residue_test.dart -t "wipe: 匹配规则"` | 单元 | `audio_x.pcm` / `a.wav` / `b.PCM` 被删；`note.txt` 与 `audio_dir` 目录保留；`failed == 1` | 每次改匹配规则 |
| `audio_residue_test.dart -t "wipe: 清理失败不阻断"` | 单元 | mock `failed:1` → 记录写入成功、无异常逃逸、计数 +1、诊断可见 | D8 |
| `audio_residue_test.dart -t "wipe: 触发时机"` | 单元 | 1 次冷启动 + 3 次会话结束 → `clearTempAudio` 调用 4 次 | D8、D9 |
| 静态检查 `clearTempAudio` 调用点 | 脚本 | 调用点不在任何 `transaction(` 闭包内（0 处） | D8、D9 回归 |
| `wipe_e2e_test.dart -t "wipe: 无音频落盘"` | 集成 | 会话结束后 `cacheDir` 与 `filesDir` 匹配文件数均为 0 | D8、D9 |
| 自检面板读取 `last_cleanup_failed_count` | 人工核对 | D9 现场 == 0 | D9（`PLAN-M-04` 联动） |

## 5. 完成定义（DoD）
- [ ] `SPEC-D-05` §7 全部 13 条判据通过，证据落在上表对应测试名或脚本命中数上。
- [ ] `SPEC-D-05` §10 **问题 1（数据可携带性缺口）**已登记，并在 `U-05` 落地「数据仅存于本机，卸载即丢失」的明确告知（与 `PLAN-U-05` 联合核对）。
- [ ] 匹配规则只存在于 `audio_residue_cleaner.dart`；默认档案值只来自 `profile_defaults.dart`（评审：全局搜索无第二处）。
- [ ] `clearTempAudio` 的调用点**不在**任何 DB 事务内，且「先提交、后清理」的顺序在代码中可见。
- [ ] `cacheDir` 与 `filesDir` 的匹配文件数在会话结束后为 0 的证据已归档（截图或测试输出），进入 `PLAN-C-05` 的演示前回归清单。
- [ ] 判据 13（D9 前 `last_cleanup_failed_count == 0`）已在 `PLAN-M-04` 的现场自检面板上可读。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 原生 `clearTempAudio` 未按 D5 可用 | 调用返回 `PlatformException` / 方法未实现 | 清理器已设计为永不抛异常 → 记日志 + 计数 +1，**不阻断**；但判据 12 会红，必须上报 `PLAN-P-01` 在 D8 前补齐 |
| 清理挂钩文件与 `PLAN-P-01` / `PLAN-P-06` 的文件冲突 | 同一文件被两人修改 | 挂钩点写成独立的 `session_end_hook.dart`，由 B 在 D8 统一接线；`PLAN-00` §4「不许跨人改代码」 |
| `filesDir` 出现音频文件 | 判据 12 红 | 立即定位写入方（`cacheDir` 之外的 `File.write` 属 R-OUT-1 违规）；本功能**不**静默删除，保留证据并上报 `PLAN-C-01` |
| 清空误伤参考数据 | 判据 4 红（`food_kcal` 被清） | 回滚改动；`food_kcal` 是只读镜像，清空后 `estimatedKcal` 全归零，属功能回归 |
| D8 资源被 `A-04` / `U-03` / `U-04` 收口挤占 | D8 中午未完成 | 降级顺序：①先保 **会话结束清理**（FF-24 第 2 条的直接要求，判据 12）②再保清空事务（判据 1~3）③`VACUUM`、`WipeResult` 细节、诊断计数最后 |
| 二次确认文案未含「不可恢复」 | 与 `PLAN-U-05` 核对失败 | 文案硬性要求（`SPEC-D-05` §10 问题 4）；本功能不提供撤销能力，文案必须诚实 |

## 7. 与检查点的关系
- 本功能**不是** CP1/CP2/CP4 的判据，但对 **CP3（D9 午：三种 Demo 模式全部可用）** 有直接影响：`M-04` 现场自检面板的两项（`last_cleanup_failed_count`、`tempAudioFiles`）由本功能提供，且 **D9 前必须为 0**（`SPEC-D-05` §7 判据 13）。
- 若 CP3 未通过：`PLAN-00` §2 处置为「停止一切新功能，3 人扑 Demo 稳定性」。此时本功能的清理链路**正是稳定性的一部分**（音频落盘会直接摧毁隐私主张），不得降级。
- 本功能在 D8 与 `SPEC-A-04`（演示数据）同日：**`A-04` 的装载动作必须在本功能清空之后**执行，否则装载的演示数据会被清空流程抹掉。这条跨功能顺序需在 D8 站会上确认。
- `SPEC-D-05` §7 判据 12（无音频落盘）与 `PLAN-C-01` 的权限/隐私判据共用证据，须在 D9 现场实测前合并执行一次。

---
**文档结束**
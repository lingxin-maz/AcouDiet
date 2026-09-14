# SPEC-D-05 数据清除与录音残留清理

| 项 | 值 |
|---|---|
| 域 | D · 数据与本地后端 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | **API-03 §7（`MaintenanceRepo` 的权威定义）**、API-03 §9；API-01 §2.7/§2.8；API-05 §8/§11/§12；SPEC-00 §3.9 FF-24 第 1/2/3/7 条；SPEC-D-01 §4.3 |
| 依赖的 SPEC | SPEC-D-01（表与 `app_meta` 键）、SPEC-D-02（事务与 `PendingWriteQueue`）、SPEC-D-04（默认档案值的唯一来源）、`PLAN-P-01`（原生清理实现） |

## 1. 目标与范围
### 1.1 一句话目标
提供两件事：①**一键清空全部数据**（单事务删除记录与指标、把档案重置为默认值、复位演示数据标识与诊断计数）；②**录音临时文件清理** —— `cacheDir` 中匹配 `audio_*` / `*.wav` / `*.pcm` 的文件在 **App 冷启动时 + 每次会话结束后**清除；清理失败只记日志、不阻断主流程（`ACD-IO-001`，`retryable=false`），但**必须**出现在自检面板并计入诊断。
### 1.2 范围内（In Scope）
1. `MaintenanceRepo` 的 3 个方法（`clearAllData()` / `clearTempAudio()` / `countTempAudioFiles()`，签名以 **API-03 §7** 为准）。
2. 清空的范围、顺序、返回值计数与 `app_meta` 复位口径（§4.1、§4.3）。
3. 清空后**内存暂存队列** `PendingWriteQueue` 的处置（防止已删除记录被重放）。
4. 音频残留清理的**要求与匹配规则**（§4.2）—— **规则实现在原生侧，Dart 侧只委托**（API-03 §7 明令禁止另写一套匹配与删除逻辑）。
5. 触发时机（冷启动一次 + 每次会话结束一次）与结果上报（`app_meta` 计数 + `M-04` 自检面板）。
6. 与 `U-05` 的交互边界：本功能提供 service 与结果，二次确认对话框与文案属 `U-05`。
### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
1. **不定义表、约束、索引** —— 属 `SPEC-D-01`；**不写迁移与事务框架** —— 属 `SPEC-D-02`。
2. **不做聚合查询** —— 属 `SPEC-D-03`；**不定义档案字段与默认值** —— 属 `SPEC-D-04`（本功能只在其复位时**引用同一份默认值常量**）。
3. **不在 Dart 侧实现 `audio_*` / `*.wav` / `*.pcm` 的匹配与删除** —— 必须委托 `API-01` §2.7 的原生 `clearTempAudio`（API-03 §7）。
4. **不做任何数据导出 / 备份 / 迁移 / 撤销**：`X-03` 已裁剪，v1.0 无导出途径（API-05 §11）—— 详见 §9 第 1 条与 §10 问题 1。
5. **不做卸载残留清理**（超出 App 能力）、不做系统文件管理器集成、不做按日期的增量清理。
6. **不把 `filesDir` 中的匹配文件当作「清理对象」** —— 那是**违规落盘**（R-OUT-1）的证据，只记日志、不静默删除（§2.4）。

## 2. 功能行为
### 2.1 触发与前置条件
| 触发 | 前置条件 |
|---|---|
| App 冷启动 | `AppDatabase.open()` 完成后调用一次 `clearTempAudio()`（FF-24 第 2 条） |
| 每次会话结束（`sessionEnded` 事件或 `stopSession` 返回，API-01 §2.5） | **必须先完成** `SPEC-D-02` 的记录写入（提交或入暂存），**再**调用清理 |
| 用户点「清空全部数据」并二次确认 | `U-05` 提供二次确认，文案必须含「不可恢复」 |
| 清空完成后 | 同一流程内**再调用一次** `clearTempAudio()`（清空 = 抹掉一切痕迹） |
### 2.2 主流程（编号步骤）
**A. 冷启动清理**：① DB `open()` 完成 → ② `clearTempAudio()` → ③ 成功则写 `app_meta.last_cleanup_at_ms`，失败则累加 `last_cleanup_failed_count` → ④ 结果进诊断（`API-01` §2.8 的 `tempAudioFiles`）。
**B. 会话结束清理**：① `insertSession` 事务提交（成功，或失败后进入 `PendingWriteQueue`）→ ② `clearTempAudio()` → ③ 更新 `app_meta` 与诊断。**清理失败不得回滚、也不得重试记录写入**（`ACD-IO-001`，`retryable=false`）。
**C. 一键清空（`clearAllData()`，单事务，API-03 §7）**：① `DELETE FROM behavior_metrics` → ② `DELETE FROM diet_record` → ③ 把 `user_profile` **重置为默认值并保留该行**（默认值取自 `SPEC-D-04` 的 `profile_defaults.dart`，**不得**另写一份）→ ④ 复位 `app_meta`：`demo_data_enabled='0'`、`demo_dataset_id=NULL`、`demo_data_loaded_at_ms=NULL`、`last_cleanup_failed_count='0'`（`schema_version` **保留**）→ ⑤ 提交 → ⑥ `VACUUM`（尽力而为，失败只记日志）→ ⑦ `clearTempAudio()` → ⑧ 返回**清除的行数**＝记录行数 + 指标行数 + 档案重置行数（0 或 1）。
**D. 内存态清理**：清空数据的同一流程内清空 `PendingWriteQueue` —— 否则清空后「暂存重放」会把已删除的记录写回，形成**幽灵记录**（本 SPEC 追加要求，API-03 §7 未涉及，见 §10 问题 5）。
### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）
**无状态服务，且幂等**。`clearAllData()` 可重复调用：第二次返回 0（记录、指标均无行，档案行仍被重置故计数为 1），不抛异常。清理器不保存跨调用状态（唯一持久状态是 `app_meta` 的两个计数器）。
### 2.4 边界条件
| 边界 | 规定 |
|---|---|
| 空库清空 | 返回档案重置行数（`1`）；不报错 |
| `user_profile` 被清空 | 必须**重置为默认值并保留该行**（API-03 §7），不得留空表 |
| `PendingWriteQueue` 非空 | 一并清空（§2.2 D） |
| `assets/` 内制品 | **不删除**（API-03 §7） |
| `cacheDir` 不存在或不可读 | 委托调用失败 → `ACD-IO-001` 只记日志，**不抛异常** |
| 原生返回值与预期不符 | 以**原生返回值**为准（`clearTempAudio()` 返回其 `filesDeleted`），Dart 侧不得自行改算 |
| 清理时存在活跃会话 | 跳过并记日志，**不打断录音** |
| `filesDir` 出现匹配文件 | 判为 R-OUT-1 违规 → 记日志 + 自检面板失败项；**不静默删除**，保留证据 |
| `VACUUM` 失败 | 只记日志；「数据已被清空」这一事实不受影响 |
| 清空事务中途失败 | 整体回滚（`ACD-DB-003`）→ 数据保持原样（要么全成、要么全不成） |
| `countTempAudioFiles()` 不可读 | 返回 **`-1`**，`M-04` 必须标「不可判定」而**不是**「通过」（API-03 §7） |
| 二次确认被取消 | 不执行任何操作，不写任何计数器 |

## 3. 接口契约
> 只写与本功能直接相关的契约；**完整签名以 `API-03` §7 为准**，此处只给「本功能用到的部分」。
| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5 → L4 | `MaintenanceRepo.clearAllData()` | 无 | `Future<int>`（清除的行数 = 记录 + 指标 + 档案重置行数） | `ACD-DB-003` |
| L5 → L4 | `MaintenanceRepo.clearTempAudio()` | 无 | `Future<int>`（原生 `filesDeleted`） | **不抛错**（失败按 `ACD-IO-001` 只记日志） |
| L5 → L4 | `MaintenanceRepo.countTempAudioFiles()` | 无 | `Future<int>`（`getDiagnostics().tempAudioFiles`；不可读返回 `-1`） | **不抛错** |
| L4 → L3 | `DietRepo.deleteAll()` / `ProfileRepo.save(kDefaultProfile)` / `MetaDao.put` | 见 API-03 §3/§4/§6 | `Future<int>` / `Future<void>` | `ACD-DB-003` |
| L4 → L1 | 原生 `clearTempAudio()`（API-01 §2.7） | `{}` | `{filesDeleted, bytesFreed, failed}` | 无 |
| L5 ← L4 | `residueCleanupProvider` | 无 | `{lastCleanupAtMs, failedCount, tempAudioFiles}` | — |
- 本功能**不提供** `export()` / `backup()` / `undo()` / `restore()`，也**不提供** `WipeResult` 之类的自定义返回结构（API-03 §7 冻结为 `int`）。
- `clearAllData()` 返回值语义是**行数之和**，不是「操作是否成功」的布尔量。

## 4. 数据契约
### 4.1 清空范围（**逐资源明确，防止"顺手"扩大或漏掉**）
| 表 / 资源 | 动作 | 结果 |
|---|---|---|
| `diet_record` | `DELETE FROM`（含 `source='demo'` 的行） | 清空 |
| `behavior_metrics` | `DELETE FROM`（外键级联也会删，但**显式删除**以保证返回计数准确） | 清空 |
| `user_profile` | 重置为默认值并**保留该行**（`upsert(profile_id=1)`） | 复位 |
| `app_meta` | 复位 §2.2 C④ 的 4 个键；`schema_version` **保留** | 部分复位 |
| `PendingWriteQueue`（内存） | 清空 | 清空 |
| `assets/` 内制品（模型/知识库/配置） | **不动** | 保留 |
### 4.2 音频残留清理的**要求**与匹配规则
| 项 | 规定 |
|---|---|
| 实现位置 | **原生侧**（`API-01` §2.7 的 `clearTempAudio`）。**Dart 侧只委托调用，禁止自行列出目录、匹配文件名或删除文件**（API-03 §7） |
| 目录 | Android `context.cacheDir`（应用私有，**无需任何存储权限**） |
| 匹配 | 文件名以 `audio_` 开头 **或** 以 `.wav` 结尾 **或** 以 `.pcm` 结尾（扩展名**大小写不敏感**） |
| 非匹配 | 一律不删、不改名、不移动 |
| 目录对象 | 不递归；匹配到目录时计入 `failed`，不删除 |
| 清理后断言 | `countTempAudioFiles() == 0`（`API-05` §12 判据 4） |
| 触发时机 | 冷启动一次 + 每次会话结束一次（FF-24 第 2 条）；调用次数可被断言（判据 9） |
| Dart 侧可验证的部分 | 只能验证「委托调用发生了几次」「返回值如实透传」，匹配规则本身由 `PLAN-P-01` 的原生单测与判据 8 覆盖 |
### 4.3 `app_meta` 复位与写入的键
| key | 本功能的动作 |
|---|---|
| `demo_data_enabled` | 清空时置 `'0'` |
| `demo_dataset_id` / `demo_data_loaded_at_ms` | 清空时置 `NULL`（演示数据指纹清除，API-03 §7） |
| `last_cleanup_at_ms` | 每次**成功**清理后写当前 epoch ms UTC |
| `last_cleanup_failed_count` | 清空时置 `'0'`；此后每次清理按失败的 `failed` 值累加 |
| `schema_version` | **不修改**（API-03 §7：清空不改变 Schema） |
### 4.4 诊断与自检面板字段
本功能必须把以下三项暴露给 `M-04` 现场自检面板：`last_cleanup_at_ms`、`last_cleanup_failed_count`、`countTempAudioFiles()` 的返回值。**判据 11 要求 D9 前失败计数为 0**，且 `-1` 必须显示为「不可判定」。

## 5. 参数与常量
> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。
| 项 | 引用 |
|---|---|
| 音频只存在于内存环形缓冲、不落盘 | SPEC-00 §3.9 FF-24 第 1 条 |
| `cacheDir` 中 `audio_*` 临时文件「启动时 + 会话结束时」强制清理 | SPEC-00 §3.9 FF-24 第 2 条 |
| 数据库仅存结构化字段、无 BLOB 音频列 | SPEC-00 §3.9 FF-24 第 3 条 |
| 一键清除全部数据 | SPEC-00 §3.9 FF-24 第 7 条 |
| `clearTempAudio` 的入参、出参、委托要求与调用时机 | **API-01 §2.7**；**API-03 §7** |
| `getDiagnostics` 的 `tempAudioFiles`（自检面板数据源）与「不可读返回 `-1`」 | API-01 §2.8；API-03 §7 |
| `ACD-IO-001` 语义：**不重试、只记日志、不阻断主流程**；`ACD-DB-003` 语义：事务失败已回滚 | API-00 §3.5；API-05 §8；API-03 §9 |
| 「会话结束后 `cacheDir` 匹配文件数 == 0」「无音频入库」两条验证判据 | API-05 §12 判据 4、5 |
| 数据可携带性缺口 | API-05 §11（**本 SPEC §10 问题 1 为登记位置**） |
| 默认档案值的唯一来源 | SPEC-D-04 §4.1 + `profile_defaults.dart` |
| `app_meta` 键集合 | SPEC-D-01 §4.3 |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 清理失败（`ACD-IO-001`） | 原生返回 `failed > 0`，或委托调用抛异常 | **不重试、不阻断**；只记日志；`last_cleanup_failed_count` 累加；进自检面板 | 无弹窗；面板显示「音频残留清理：N 失败」 |
| 清空事务失败（`ACD-DB-003`） | `transaction` 抛异常并已回滚 | 整体回滚，数据保持原样；抛 `AcouDietError(retryable:true)` | 提示「清空失败，数据未改变」 |
| `VACUUM` 失败 | 抛异常 | 只记日志；清空仍算成功（返回计数不变） | 无 |
| 活跃会话中收到清理请求 | 检测 `activeSessionId != null` | 跳过 + 记日志 | 无 |
| `filesDir` 命中匹配文件 | 会话结束后的校验 | 记日志 + 自检面板**失败项**；**不删除** | 面板显示「检测到音频落盘（异常）」 |
| `countTempAudioFiles()` 返回 `-1` | 诊断不可读 | `M-04` 标「不可判定」（**不得**当作通过） | 面板显示「音频文件计数：不可判定」 |
| 破坏性操作未确认 | `U-05` 未收到二次确认 | 不执行任何操作 | 对话框关闭，无变化 |
| 清空后 `estimatedKcal` 全为 0 | 用户反馈「热量没了」 | 属预期（记录已清空）；新记录仍按知识库估热量 | 空态文案（`U-06` 承接） |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 清空后两张数据表为空 | `flutter test app/test/wipe/data_wipe_test.dart -t "wipe: 表已清空"`：`SELECT COUNT(*) FROM diet_record` 与 `FROM behavior_metrics` | 均为 0 |
| 2 | 档案复位且**保留行** | `-t "wipe: 档案复位"`：`user_profile` 行数 == 1 且四字段等于 `SPEC-D-04` §4.1 默认值 | 成立 |
| 3 | `app_meta` 键复位正确 | `-t "wipe: app_meta 复位"`：`demo_data_enabled=='0'`、`demo_dataset_id IS NULL`、`demo_data_loaded_at_ms IS NULL`、`last_cleanup_failed_count=='0'`、`schema_version=='1'` | 5/5 成立 |
| 4 | 返回值 = 行数之和 | `-t "wipe: 返回值"`：预置 3 记录 + 3 指标 → 断言 `clearAllData()` 返回 `3 + 3 + 1`；随后再调一次断言返回 `0 + 0 + 1`（API-03 §7） | 计数精确 |
| 5 | 清空是单事务（可回滚） | `-t "wipe: 事务原子性"`：注入使档案复位失败 → `diet_record` 行数 == 清空前，且抛 `ACD-DB-003` | 不变 / 抛出 |
| 6 | 内存暂存被清空（无幽灵记录） | `-t "wipe: 暂存清空"`：预置 3 条 pending → 清空后 `queue.length == 0` 且 `DietRepo.countAll() == 0` | 成立 |
| 7 | **只委托一次原生方法** | `-t "wipe: 只调用原生一次"`：用 mock 通道断言一次 `clearTempAudio()` 只发出 **1** 次平台调用，且返回值等于通道返回的 `filesDeleted` | 调用次数 == 1 |
| 8 | Dart 侧无自写匹配/删除逻辑 | `grep -rnE "listSync\|\.delete\(|audio_\|\.endsWith\('\.wav'\)\|\.endsWith\('\.pcm'\)" app/lib/data/wipe/` | 命中数 == 0（API-03 §7） |
| 9 | 触发时机覆盖正确 | `-t "wipe: 触发时机"`：1 次冷启动 + 3 次会话结束 → 断言 `clearTempAudio` 被调用 4 次 | 次数相等 |
| 10 | 清理失败不阻断主流程 | `-t "wipe: 清理失败不阻断"`：mock 返回 `failed:1` → 断言记录写入成功、无异常逃逸、`last_cleanup_failed_count == 1`、诊断可见 | 成立 |
| 11 | D9 前清理失败计数为 0 | 自检面板读取 `last_cleanup_failed_count` | == 0 |
| 12 | 无音频落盘（与 `SPEC-C-01` 共用） | 会话结束后 `countTempAudioFiles() == 0`；并检查 `filesDir` 匹配文件数 | 均为 0（API-05 §12 判据 4/5） |
| 13 | 清理不在 DB 事务内 | `grep -n "clearTempAudio" app/lib/` 后静态断言：调用点不在任何 `transaction(` 闭包内 | 0 处 |

## 8. 非功能约束
| 项 | 约束 | 依据 |
|---|---|---|
| 权限 | 只访问应用私有 `cacheDir`，**不需要任何存储权限**；不得申请 `WRITE_EXTERNAL_STORAGE` | FF-24 第 5 条 |
| 启动路径 | 冷启动清理**异步**执行，不阻塞首帧；失败不得影响启动 | FF-24 第 2 条 |
| 线程 | 清空与委托调用都在 Dart 主 isolate（数据量小）；不进 isolate | API-00 §3.7 |
| 顺序 | 「先提交记录、后清理临时文件」为硬约束；清理永不参与 DB 事务 | API-05 §8 |
| 隐私 | 清空即抹除；**不承诺物理擦除**（见 §10 问题 2）；无导出途径 | API-05 §11 |
| 无障碍 | 无（UI 归 `SPEC-U-05`） | — |

## 9. 裁剪与未做
1. `X-03` CSV 导出**已删除** → v1.0 **没有任何导出途径**：本功能**不得**提供「清空前导出/备份」，**不得**提供 `undo()` / `restore()` / 回收站。数据可携带性缺口已在 §10 问题 1 登记（依据 API-05 §11）。
2. `X-02` 手动修正只保留删除误报（`DietRepo.deleteById`）与二选一确认；本功能不参与类别修改。
3. 不做卸载残留清理、不做系统文件管理器集成、不做按日期增量清理（属 v1.1）。
4. 不做数据库加密与安全擦除（`PRAGMA secure_delete`）：FF/API 未授权，本 SPEC **明确不承诺物理擦除**。
5. 不在 Dart 侧复刻音频匹配规则（API-03 §7 明令）；不新增 `WipeResult` 之类返回结构（API-03 §7 冻结为 `int`）。
6. 不做「清空后自动重启 App」；不做「清空即重置演示数据集」（`SPEC-A-04` 负责装载，本功能只复位标识）。

## 10. 开放问题
| # | 问题 | 影响面 | 谁拍板 | 截止 |
|---|---|---|---|---|
| 1 | ✅ **已关闭（依据 `ADR-P4`，2026-09-10）**：**数据可携带性缺口（`API-05` §11，本 SPEC 为登记位置）** —— v1.0 无任何**文件**导出途径（`X-03` 已裁剪），因此按 `ADR-P4` **采纳「复制为文本」**：`U-05` 增加一个按钮，把当前记录序列化为纯文本写入**系统剪贴板**（**不走网络、不落文件、不外发**，约 20 行，**不新增范围**，故不触发 `R-14` 等额删除）；同时**明确告知**「数据仅存于本机，卸载即丢失」。SAF 文件导出仍留在 v1.1 的「后续工作」 | 合规表述与 PPT 口径（不得自称「完全合规」） | ✅ 已裁定（`ADR-P4`） | 无需再签字（原 D8） |
| 2 | SQLite 删除后**页可能残留在文件中**，只能靠设备级 FBE（API-05 §5.7）提供基础保护。是否追加 `PRAGMA secure_delete = ON`？本 SPEC 取「VACUUM（尽力）+ 明确不承诺物理擦除」 | 隐私主张的措辞强度 | A + B | D8 |
| 3 | `filesDir` 命中匹配文件时，除「记日志 + 面板失败项」外，是否需要在 `M-04` 阻断 Demo 模式？ | 现场保障策略 | B + `SPEC-M-04` 负责人 | D9 |
| 4 | 清空操作的二次确认对话框文案与位置属 `SPEC-U-05`；本 SPEC 只要求文案包含「不可恢复」，具体字符串需对齐 | 文案与合规 | C | D8 |
| 5 | **本 SPEC 追加**：`clearAllData()` 之后必须清空 `SPEC-D-02` 的 `PendingWriteQueue`，否则暂存重放会写回已删除记录（幽灵记录）。API-03 §7 **未规定**该步骤，需回填 `API-03` §7 或确认由 `PLAN-D-02` 单方面保证 | 清空的完整性 | B + C | D8 |
| 6 | 演示数据集是否需要保留一份「清空后可重新装载」的入口？装载动作属 `SPEC-A-04`，本功能只复位标识，接口归属需确认 | 演示模式的恢复路径 | B + C | D8 |
| 7 | `clearTempAudio()` 返回的 `filesDeleted` 与 `countTempAudioFiles()` 的读数在**并发**（清理中又产生新文件）时可能不一致，本 SPEC 取「以原生返回值为准、不做二次校验」；若 `M-04` 需要强一致，需再设计 | 自检面板可信度 | B + `SPEC-M-04` 负责人 | D9 |

---
**文档结束**
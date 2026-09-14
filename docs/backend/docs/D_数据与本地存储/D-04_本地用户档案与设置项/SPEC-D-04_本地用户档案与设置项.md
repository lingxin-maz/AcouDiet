# SPEC-D-04 本地用户档案与设置项

| 项 | 值 |
|---|---|
| 域 | D · 数据与本地后端 |
| 归属 | C |
| 状态 | ⚠️ 降级交付 —— **替代被裁剪的 `X-01` 登录 / 账号体系**（见 §9） |
| 上游依据 | **API-03 §6（`ProfileRepo` 与 `UserProfile` 的权威定义）**、API-03 §7（复位归 `MaintenanceRepo`）；`docs/00_功能清单与数量分析.md` §4 `X-01`；API-05 §3 数据分类第 6 行与 R-OUT-2；SPEC-00 §3.9 FF-24；SPEC-D-01 §4.2 |
| 依赖的 SPEC | SPEC-D-01（`user_profile` 表与单行不变量）、SPEC-D-02（DAO 与唯一 `Database` 句柄）、SPEC-D-05（`clearAllData()` 负责复位） |

## 1. 目标与范围
### 1.1 一句话目标
在**没有账号体系**的前提下，用一个本地单行档案（昵称可选、每日目标正餐数、提醒开关、隐私开关）承接「用户是谁、想要什么」的全部需求：**无账号、无同步、无网络**。
### 1.2 范围内（In Scope）
1. `UserProfile` 的字段语义、默认值与取值域（表结构本身属 `SPEC-D-01` §4.2）。
2. `ProfileRepo`（**API-03 §6** 的 `load()` / `save()` 两个方法）与单行不变量的维护；**「复位到默认值」不在本接口内** —— 由 `SPEC-D-05` 的 `MaintenanceRepo.clearAllData()` 承担（API-03 §7）。
3. 四个设置项的校验与归一化规则（§2.4）。
4. 设置的读写时机与 Riverpod 暴露形状（`userProfileProvider`）。
5. 与 `U-05` 设置页的数据契约：本功能提供**状态与操作**，不提供 UI。
### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
1. **不做注册、登录、Token、会话、密码、第三方登录、账号绑定**（`X-01` 已裁剪；§9 第 1 条）。
2. **不做任何云端同步、账号绑定、跨设备迁移**（API-05 §9 状态 `DISABLED`）。
3. **不定义表、列、约束** —— 属 `SPEC-D-01`；**不写 DAO 与迁移** —— 属 `SPEC-D-02`。
4. **不做评分 / 建议 / 报告** —— 属 `SPEC-A-01`~`A-03`。
5. **不做**成就系统（`X-04` 降级为静态展示，属 `U-05`）；**不做**身高/体重/年龄/性别/疾病史等健康档案字段（无 FF 授权）。
6. **不做**系统级提醒调度（`AlarmManager` / `WorkManager` / 通知渠道）—— FF-24 第 6 条禁止后台常驻 Service。

## 2. 功能行为
### 2.1 触发与前置条件
| 触发 | 前置条件 |
|---|---|
| App 冷启动读取档案 | `user_profile` 默认单行已由 `SPEC-D-01` 的 `onCreate` 写入 |
| 用户进入设置页（`U-05`） | 调 `load()`，**不写库** |
| 用户修改任一设置项 | 构造新的不可变 `UserProfile` → `save(p)`；写库成功后才更新 provider |
| 一键清空全部数据（`SPEC-D-05`） | 由 `MaintenanceRepo.clearAllData()` 把档案重置为默认值并保留该行（API-03 §7） |
### 2.2 主流程（编号步骤）
1. `load()`：`SELECT * FROM user_profile WHERE profile_id = 1`。
2. 表为空时**返回默认档案**（§4.1），**不抛错、不自动建行**（API-03 §6）；默认值取自 `profile_defaults.dart`。
3. 用户在 `U-05` 修改 → 由 `U-05` 构造新的 `UserProfile` → `save(p)`。
4. `save(p)`：先校验并归一化（§2.4）→ **整行 `upsert`、单事务**（API-03 §6）：`INSERT OR REPLACE INTO user_profile(profile_id, nickname, target_meals_per_day, reminder_enabled, privacy_banner_enabled, updated_at_ms) VALUES (1, ?, ?, ?, ?, ?)`。
5. `updated_at_ms` 由数据层写为当前 epoch ms UTC；**`UserProfile` 不含该字段，调用方也不得传入**。
6. 供 `U-05` 的「恢复默认设置」使用的语义不是新接口，而是 `save(kDefaultProfile)`（`SPEC-D-05` 的复位复用同一份默认值常量）。
7. Riverpod：`userProfileProvider`（`AsyncNotifier<UserProfile>`）暴露 `profile` / `save()` / `restoreDefaults()`（内部即 `save(kDefaultProfile)`）；**禁止乐观更新**（先写库成功，再更新状态）。
### 2.3 状态与状态迁移（有状态的功能必填）
- 状态：`loading → data(UserProfile) | error(AcouDietError)`；`save()` 期间停留在 `data`（旧值），成功后整体替换。
- **迁移：无登录态迁移。** 不存在「未登录 → 已登录」、也不存在「已登出」状态（§9 第 1 条）。
### 2.4 边界条件
| 边界 | 规定 |
|---|---|
| `nickname` 为 `null` / 空串 / 纯空白 / 超长 | 归一化：`trim()` 后为空 → 存 `NULL`；`trim()` 后长度 > 12 个字符 → **截断到 12** 并记日志（不报错）。输入框的长度提示属 `U-05` |
| `targetMealsPerDay` 越界（`<1` 或 `>6`） | **必须拒绝**：抛 `ACD-DB-004`（入参非法，`retryable:false`，API-03 §6/§9），**不静默 clamp**；`U-05` 的步进器在 UI 层限制取值，DB 的 `CHECK` 是最后防线 |
| `reminderEnabled` | 只驱动**应用内**提示卡显示；**不得**注册任何系统级调度；**不得**申请通知权限（FF-24 第 6 条） |
| `privacyBannerEnabled = false` | 允许，但隐私声明入口在 `U-05` **始终可见**，不受此开关影响（合规底线） |
| 表内出现多行 | 理论上不可能（`profile_id = 1` 的 `CHECK`）；若自检发现行数 > 1 → 记日志 + 计入 `M-04` 自检面板失败项 + 只保留 `profile_id = 1` 的行 |
| 数据库不可用 | `ACD-DB-001` → provider 进入 `error` 态；设置页显示错误态，**不得**用内存默认值冒充已保存值 |
| 同一秒多次 `save` | 后者覆盖前者；单行数据无并发冲突问题，不引入锁 |

## 3. 接口契约
> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准，此处给「本功能用到的部分」并标注 API 编号。
| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5 → L4 | `userProfileProvider` | 无 | `AsyncValue<UserProfile>` + `save(UserProfile)` + `restoreDefaults()` | `ACD-DB-003` / `ACD-DB-004` |
| L4 → L3 | `ProfileRepo.load()`（API-03 §6） | 无 | `Future<UserProfile>`（表空时返回默认档案，**不抛错、不建行**） | `ACD-DB-003` / `ACD-DB-004` |
| L4 → L3 | `ProfileRepo.save(UserProfile p)`（API-03 §6） | 归一化后的 `p` | `Future<void>`（整行 upsert，单事务） | `ACD-DB-003` / `ACD-DB-004` |
| L4 → L3 | `ProfileDao.select / upsert`（API-03 §3） | `Map<String,Object?>` | `Map<String,Object?>` | `ACD-DB-004` |
| L4 → L3 | `MaintenanceRepo.clearAllData()`（`SPEC-D-05`） | 无 | `Future<int>`（复位档案并保留该行） | `ACD-DB-003` |
- **本接口不存在**：`register()` / `login()` / `logout()` / `token` / `session` / `sync()`，也不存在 `resetToDefaults()`（复位归 `MaintenanceRepo`）。`grep` 命中必须为 0（判据 9）。
- 接口名、方法名与可空性**以 API-03 §6 为准**；本 SPEC 只冻结**默认值**与**归一化规则**（API-03 §6 明确把这两项交给本 SPEC）。

## 4. 数据契约
### 4.1 `UserProfile` 字段、默认值与值域
| Dart 字段 | SQLite 列 | 类型 | 默认值 | 值域 / 归一化 | 可空 |
|---|---|---|---|---|---|
| `nickname` | `nickname` | `String?` | `NULL` | `NULL`，或 `trim()` 后 1–12 个字符 | 是 |
| `targetMealsPerDay` | `target_meals_per_day` | `int` | `3` | `[1,6]` | 否 |
| `reminderEnabled` | `reminder_enabled` | `bool` | `false` | `0` / `1` | 否 |
| `privacyBannerEnabled` | `privacy_banner_enabled` | `bool` | `true` | `0` / `1` | 否 |
| （固定） | `profile_id` | `int` | `1` | 恒为 `1`，不暴露给用户 | 否 |
| （数据层写） | `updated_at_ms` | `int` | 建库时刻 | epoch ms UTC，**调用方不得传入** | 否 |
### 4.2 与 `U-05` 的 UI 数据契约（本功能提供的状态）
| `U-05` 的控件 | 唯一数据来源 | 本功能提供 |
|---|---|---|
| 昵称输入框 + 保存 | `UserProfile.nickname` | `save()` + 归一化 |
| 每日目标正餐数步进器 | `UserProfile.targetMealsPerDay` | `save()`（越界由 `ACD-DB-004` 拒绝，UI 层限制取值） |
| 提醒开关 | `UserProfile.reminderEnabled` | `save()`（仅应用内提示卡） |
| 隐私告知横幅开关 | `UserProfile.privacyBannerEnabled` | `save()` |
| 「恢复默认设置」 | 默认值集合（§4.1） | `restoreDefaults()`（内部即 `save(kDefaultProfile)`） |
> ⚠️ **表中没有的控件，`U-05` 不得出现**（`00_功能清单` §3 的 UI 数据契约原则）：具体指**登录 / 注册 / 账号 / 头像上传 / 数据同步 / 退出登录**。这六个控件的唯一数据来源是 `X-01`，而 `X-01` 已裁剪。

## 5. 参数与常量
> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。
| 项 | 引用 |
|---|---|
| 四个设置项、默认值与值域 | 本 SPEC §4.1（**FF-24 未规定这些默认值，属本 SPEC 首次固定**，见 §10 问题 2、3） |
| 「无后台常驻 Service」 | SPEC-00 §3.9 FF-24 第 6 条 |
| 「APK 不申请 `INTERNET` 权限」 | SPEC-00 §3.9 FF-24 第 4 条 |
| 本地档案/设置只存本地 SQLite、无任何导出通道 | API-05 §3 数据分类第 6 行 + 规则 R-OUT-2 |
| 单行不变量、列定义与 `CHECK` | SPEC-D-01 §4.2 / §2.4 |
| 错误码 `ACD-DB-003`（事务失败）、`ACD-DB-004`（入参非法/表列缺失） | API-03 §9（`003`/`004` 待补登 API-00 §3.5） |
| 裁剪依据与释放工时 | `00_功能清单` §4 `X-01`（释放 0.5 人日） |
| 云同步协议状态 | API-05 §9（`DISABLED`，**不得作为任务来源**） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 表不可读（`ACD-DB-003`） | DAO 抛异常 | provider 进 `error` 态，不使用内存默认值冒名 | 设置页错误态 + 重试按钮 |
| 入参非法 / 约束违反（`ACD-DB-004`） | `target_meals_per_day` 越界、`CHECK` 违反 | 抛 `ACD-DB-004`（不重试），provider 进 `error` 态 | 提示「设置未保存」，步进器回滚到旧值 |
| 表为空 | `load()` 返回 0 行 | 返回**默认档案**，**不建行、不抛错**（API-03 §6） | 无感知（显示默认设置） |
| 检测到多行 | 自检 `SELECT COUNT(*) FROM user_profile` > 1 | 记日志 + 保留 `profile_id=1` 的行 + 计入 `M-04` 面板 | 自检面板显示「用户档案：异常」 |
| 昵称超长 | `trim().length > 12` | 截断到 12 并记日志（不阻断保存） | 输入框显示截断后的值 |
| 提醒开关打开但无系统调度 | 代码审查（判据 10） | 开关只驱动应用内提示卡；**禁止**文案「已设置系统提醒」（FF-25 口径红线） | 提示卡在 App 内出现 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 表空返回默认档案且**不建行** | `flutter test app/test/profile/profile_repo_test.dart -t "profile: 空表返回默认"`：清空 `user_profile` 后 `load()`，断言返回默认值且 `COUNT(*) == 0` | 成立 |
| 2 | 默认值正确 | `-t "profile: 默认值"`：断言 `nickname == null`、`targetMealsPerDay == 3`、`reminderEnabled == false`、`privacyBannerEnabled == true` | 4/4 相等 |
| 3 | 读写往返一致 | `-t "profile: 往返"`：`save(p)` 后 `load()` 逐字段等于 `p`（`updated_at_ms` 除外） | 逐字段相等 |
| 4 | 昵称归一化 | `-t "profile: 昵称归一化"`：`""` / `"   "` → `nickname == null`；`"张三"` 保留；13 字符串 → `length == 12` | 全部成立 |
| 5 | 越界必须拒绝（不 clamp） | `-t "profile: 目标正餐数"`：`save(targetMealsPerDay: 99)` 与 `0` 均抛 `ACD-DB-004`，且落库值不变 | 抛出 / 值不变 |
| 6 | 单行不变量 | `-t "profile: 单行"`：`save()` 为 upsert 语义，`saves` 任意次后 `COUNT(*) == 1` | == 1 |
| 7 | `updated_at_ms` 由数据层写 | `-t "profile: 时间戳"`：`save()` 后断言落库 `updated_at_ms` ≥ 调用前时刻（`UserProfile` 不含该字段） | 成立 |
| 8 | 恢复默认设置（`save(kDefaultProfile)`） | `-t "profile: 恢复默认"`：provider 的 `restoreDefaults()` 后 `load()` 等于 §4.1 默认值集合 | 4/4 相等 |
| 9 | **无任何登录/账号 API** | `grep -rniE "login\|signin\|sign_in\|logout\|token\|account\|oauth\|password" app/lib/` | 命中数 == 0 |
| 10 | 无系统级提醒调度 | `grep -rniE "AlarmManager\|WorkManager\|NotificationChannel\|flutter_local_notifications" app/` | 命中数 == 0 |
| 11 | 无网络依赖（与 API-05 §12 判据 3 共用） | `grep -rniE "http\|dio\|socket\|WebSocket\|url_launcher" app/lib/` | 命中数 == 0 |
| 12 | 真机端到端持久化 | 手动核对清单：改昵称 → 杀进程 → 重启 → 昵称仍在 | 逐项通过 |
| 13 | 与 `SPEC-D-05` 联动 | `-t "profile: 清空后复位"`：`MaintenanceRepo.clearAllData()` 后 `load()` 返回默认值且 `COUNT(*) == 1`（保留行，API-03 §7） | 成立 |

## 8. 非功能约束
| 项 | 约束 | 依据 |
|---|---|---|
| 性能 | 单行读/写 < 20 ms；不进 isolate | API-00 §3.7 |
| 网络 | **零网络调用**；无 `INTERNET` 权限；无任何上报 | FF-24 第 4 条；API-05 §1 |
| 后台 | 无后台常驻 Service、无定时任务、无通知渠道 | FF-24 第 6 条 |
| 隐私 | 档案只存本机 SQLite；`privacyBannerEnabled = false` **不得**隐藏隐私声明入口 | API-05 §11 |
| 并发 | 单行、单句柄、无锁；不做乐观更新 | API-05 §5.2 |
| 无障碍 | 本功能只提供状态；每个控件必须带可读标签，由 `SPEC-U-05` 承接 | — |

## 9. 裁剪与未做
1. ⚠️ **必须显式声明**：**`X-01` 登录 / 账号体系已裁剪**（`docs/00_功能清单与数量分析.md` §4），**本功能是其替代物；不得实现注册、登录、Token、会话、密码、找回密码、第三方登录、账号绑定中的任何一项。** 本 SPEC 不存在登录态，也不存在「未登录」分支，更不得为「将来接账号」预留 `userId` / `accountId` 列或接口。
2. **不得**引入任何网络调用；`API-05` §9 的云同步协议状态为 `DISABLED`，**不得作为本功能的任务来源**（API-05 §9 阅读须知明确禁止）。
3. **不得**为健康档案（身高/体重/年龄/性别/疾病史）建档 —— 无 FF 授权，属范围外。
4. `X-04` 成就解锁系统已降级为静态展示（`U-05` 承接）；本功能不存储任何成就状态。
5. **不做**系统级提醒调度（FF-24 第 6 条），提醒开关仅驱动应用内提示卡。
6. 对外表述**不得**称「已实现账号体系」（FF-25 口径红线）。降级事实必须写进 `/10_功能清单` §4 与 PPT 的「后续工作」（`PLAN-00` §6）。

## 10. 开放问题
| # | 问题 | 影响面 | 谁拍板 | 截止 |
|---|---|---|---|---|
| 1 | `reminderEnabled` 在「无后台常驻 Service」（FF-24 第 6 条）约束下**只能驱动应用内提示卡**。是否允许 `AlarmManager` 的一次性本地通知（非常驻）？若允许，是否触碰 FF-24 第 6 条需先裁定 | 提醒功能的真实能力与答辩口径 | A + C | D5 |
| 2 | 昵称长度上限 **12 字符**为本 SPEC 首次固定（API-03 §6 明确把上限交给本 SPEC），需与 `U-05` 输入框的 `maxLength` 一致 | 输入校验与截断行为 | C | D5 |
| 3 | `targetMealsPerDay` 默认 `3` 与值域 `[1,6]` 为本 SPEC 首次固定（API-03 §6 明确把默认值交给本 SPEC）。若 `SPEC-A-01` 的规律性维度要按「目标正餐数」加权，需回填本 SPEC | 评分卡输入 | A + C | D7 |
| 4 | 「`privacyBannerEnabled = false` 时隐私声明入口仍可见」是本 SPEC 的合规底线判断，需确认不与 `U-05` 的设计冲突 | 设置页布局 | C | D8 |
| 5 | 是否需要在首次启动时引导用户填写目标正餐数？本 SPEC 取**不做**（默认值即可用，零录入操作优先） | 首次启动流程 | C | D8 |
| 6 | `D-04` 归属 C，但表结构与 `ProfileRepo` 契约由 B 侧文档（`SPEC-D-01` / `API-03` §6）定义。`ProfileRepo` 实现类的代码落点（`app/lib/data/` 归 B，还是 `app/lib/features/profile/` 归 C）需在 D5 前明确，否则两人会改同一文件（`PLAN-00` §4「不许跨人改代码」） | 分工与合并冲突 | B + C | D5 |

---
**文档结束**
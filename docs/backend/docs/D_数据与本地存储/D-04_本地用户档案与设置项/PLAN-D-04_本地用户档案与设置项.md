# PLAN-D-04 本地用户档案与设置项

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-D-04 |
| 负责 | C（主责）；B 协助 `UserProfileDao` 与表访问（`SPEC-D-02` 交付物 5） |
| 目标日 | D5 |
| 前置依赖 | `PLAN-D-01` 的 `user_profile` 表（含默认单行）与 `UserProfile` 模型；`PLAN-D-02` 的 `UserProfileDao`；`SPEC-D-04` §10 问题 6（代码落点）与问题 1（提醒能力）已有结论 |
| 预估工时 | 4 h（Repo 与归一化 1.5 h + provider 0.5 h + 与 `U-05` 对接 0.5 h + 测试 1.5 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 验收方式 |
|---|---|---|
| 1 | `app/lib/features/profile/user_profile_repo.dart` | `UserProfileRepo`：`get()` / `save()` / `resetToDefaults()`（落点待 §10 问题 6 拍板） |
| 2 | `app/lib/features/profile/user_profile_provider.dart` | `userProfileProvider`（`AsyncNotifier<UserProfile>`），暴露 `save()` / `resetToDefaults()`；**禁止乐观更新** |
| 3 | `app/lib/features/profile/profile_normalizer.dart` | 昵称归一化（trim → 空转 `null` → 超 12 字符截断）与 `targetMealsPerDay` 的 clamp，**唯一实现处** |
| 4 | `app/lib/features/profile/profile_defaults.dart` | 默认值常量（`null` / `3` / `false` / `true`），供 Repo、`SPEC-D-05` 复位、测试三方共用 |
| 5 | `app/test/profile/user_profile_repo_test.dart` | 承载 `SPEC-D-04` §7 判据 1~8、13 |
| 6 | `app/test/profile/no_account_guard_test.dart` | 判据 9、10、11 的静态扫描断言（与 `PLAN-C-05` 共用实现） |
| 7 | `app/lib/features/settings/settings_page.dart`（仅绑定层） | 与 `PLAN-U-05` 对接：把 provider 状态绑定到 4 个控件；**页面视觉与布局归 `PLAN-U-05`** |

> `app/` 目录由 B 在 D1 初始化（`PLAN-00` §1）；路径相对该根目录。交付物 7 的归属需与 `PLAN-U-05` 明确切分（见 §6 风险）。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 归一化与默认值常量 | 交付物 3、4 | 0.5 h | `SPEC-D-04` §4.1 |
| 2 | `UserProfileRepo`（get 自愈 / save / reset） | 交付物 1 | 1 h | 1、`PLAN-D-02` |
| 3 | `userProfileProvider` | 交付物 2 | 0.5 h | 2 |
| 4 | 与 `U-05` 绑定（4 个控件，无登录控件） | 交付物 7 | 0.5 h | 3、`PLAN-U-05` |
| 5 | 测试（8 组行为 + 3 组静态扫描） | 交付物 5、6 | 1.5 h | 4 |
| **合计** | | | **4 h** | |

## 3. 技术方案

### 3.1 关键骨架（≤30 行，**不写完整实现**）
```dart
// app/lib/features/profile/profile_normalizer.dart —— 归一化唯一实现处
const int kNicknameMaxChars = 12;
const int kTargetMealsMin = 1, kTargetMealsMax = 6;

String? normalizeNickname(String? raw) {
  final t = raw?.trim() ?? '';
  if (t.isEmpty) return null;                       // 空白串一律存 NULL
  return t.length <= kNicknameMaxChars ? t : t.substring(0, kNicknameMaxChars);
}
int clampTargetMeals(int v) => v.clamp(kTargetMealsMin, kTargetMealsMax);
```
```dart
// app/lib/features/profile/user_profile_repo.dart
class UserProfileRepo {
  UserProfileRepo(this._db);
  Future<UserProfile> get() async {
    final rows = await UserProfileDao(_db).get();            // SELECT … WHERE profile_id = 1
    if (rows.isNotEmpty) return UserProfile.fromMap(rows.first);
    await UserProfileDao(_db).insertDefault(nowMs());        // 缺行自愈，不抛异常
    return UserProfile.defaults();
  }
  Future<void> save(UserProfile p) async { /* UPDATE … WHERE profile_id = 1；受影响行 0 → 插默认行后重试一次 */ }
  Future<void> resetToDefaults() async { /* 写回 kDefaultProfile；updated_at_ms 由数据层写 */ }
}
```
**硬性要求**：归一化与 clamp 只允许出现在 `profile_normalizer.dart`；默认值只允许出现在 `profile_defaults.dart`（`SPEC-D-05` 复位同一份来源）。

### 3.2 实现步骤
1. 先落 `profile_defaults.dart`（默认值 = `SPEC-D-04` §4.1 的四个值）。
2. `UserProfileRepo.get()` 必须实现「缺行自愈」：`SELECT` 为空 → `insertDefault` → 返回默认值；**不抛异常**（避免设置页整页报错）。
3. `save()`：`UPDATE … WHERE profile_id = 1`；`updatedRows == 0` 时插默认行再重试一次；**调用方传入的 `updatedAtMs` 一律忽略**，由数据层写入当前 epoch ms UTC。
4. `userProfileProvider`：`build()` 调 `get()`；`save()` 内部先 `await repo.save(p)`，成功后再 `state = AsyncData(p)`；**禁止**先改 state 再写库。
5. 与 `U-05` 对接时只绑 4 个控件（昵称、目标正餐数、提醒、隐私横幅）；**页面上不得出现**登录/注册/账号/头像/同步/退出登录（`SPEC-D-04` §4.2）。
6. `resetToDefaults()` 复用 `profile_defaults.dart`，与 `SPEC-D-05` 的「清空后 seed」调用同一函数，避免两份默认值。

### 3.3 禁止事项（与 SPEC 同步冻结）
1. 不得实现注册/登录/Token/会话/第三方登录（`X-01` 已裁剪）。
2. 不得新增 `userId` / `accountId` / `email` / `authToken` 列或字段（连「为将来预留」都不允许）。
3. 不得引入网络依赖（`http` / `dio` / `socket` / `url_launcher`）或任何上报。
4. 不得注册系统级提醒（`AlarmManager` / `WorkManager` / 通知渠道）。
5. 不得为健康档案（身高/体重/年龄/性别）加字段。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `user_profile_repo_test.dart -t "profile: 缺行自愈"` | 单元 | 删空表后 `get()` 返回默认值且 `COUNT(*) == 1` | 每次改 Repo |
| `user_profile_repo_test.dart -t "profile: 默认值"` | 单元 | 4 个默认值与 `SPEC-D-04` §4.1 逐项相等 | 同上 |
| `user_profile_repo_test.dart -t "profile: 往返"` | 单元 | `save(p)` → `get()` 逐字段等于 `p` | 同上 |
| `user_profile_repo_test.dart -t "profile: 昵称归一化"` | 单元 | `""`/`"   "` → `null`；`"张三"` 保留；13 字符 → 长度 12 | 每次改归一化 |
| `user_profile_repo_test.dart -t "profile: 目标正餐数"` | 单元 | provider 传 `99` 落库值 ∈ `[1,6]`；SQL 直写 `0` 抛 `ACD-DB-002` | 同上 |
| `user_profile_repo_test.dart -t "profile: 单行"` | 单元 | 多行注入后 `COUNT(*) == 1` 且自检项为失败 | 每次改 Repo |
| `user_profile_repo_test.dart -t "profile: 时间戳"` | 单元 | 传入 `updatedAtMs = 0` 被忽略，落库值 ≥ 调用前时刻 | 同上 |
| `user_profile_repo_test.dart -t "profile: 复位"` | 单元 | `resetToDefaults()` 后等于默认值集合 | 每次改默认值 |
| `user_profile_repo_test.dart -t "profile: 清空后复位"` | 集成 | 调 `SPEC-D-05` 的清空后再 `get()`：默认值且 `COUNT(*) == 1` | D8（与 `PLAN-D-05` 联合） |
| `no_account_guard_test.dart` 静态扫描 | 脚本 | `login\|signin\|token\|account\|oauth\|password` 命中 0；`AlarmManager\|WorkManager\|NotificationChannel` 命中 0；`http\|dio\|socket\|url_launcher` 命中 0 | D5、D8、D9 回归 |
| 真机手动核对（判据 12） | 人工核对表 | 改昵称 → 杀进程 → 重启 → 昵称仍在（4 项逐条勾选） | D5、D9 |

## 5. 完成定义（DoD）
- [ ] `SPEC-D-04` §7 全部 13 条判据通过；判据 9、10、11 由 `no_account_guard_test.dart` 与 `PLAN-C-05` 共用实现并留档。
- [ ] 归一化逻辑只存在于 `profile_normalizer.dart`，默认值只存在于 `profile_defaults.dart`（评审：全局搜索无第二处）。
- [ ] `SPEC-D-04` §9 第 1 条的裁剪声明已由 B/C 双方确认，且代码中**无**任何账号相关标识符（判据 9 命中 0）。
- [ ] `U-05` 的设置页只出现 §4.2 表中的 4 个控件 + 「恢复默认设置」，**无**登录类控件（与 `PLAN-U-05` 联合核对）。
- [ ] `SPEC-D-04` §10 问题 6（`UserProfileRepo` 落点）已有 B+C 书面结论，并记录在 `PLAN-00` §4 的分工规则下。
- [ ] 真实持久化已验（判据 12 的人工核对表已签字）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 与 `PLAN-U-05` 的职责边界重叠（页面文件双方都改） | 同一文件被两人修改 | 以「provider 与 Repo 归 D-04、页面 widget 与布局归 U-05」切分；页面只允许调用 provider，不写 SQL |
| 提醒开关能力被误解为系统提醒 | 出现「已设置系统提醒」文案 | 立即改为「应用内提醒」；文案核对表见 `PLAN-U-05`；FF-25 口径红线 |
| 有人「顺手」加账号相关字段 | 判据 9 命中非 0 | 删除字段并回退；该项为 `SPEC-D-04` §9 的硬裁剪，不进入讨论 |
| 默认值被两处硬编码（本功能与 `SPEC-D-05` 各一份） | 全局搜索出现第二份 `3 / false / true` 常量 | 统一引用 `profile_defaults.dart`；`PLAN-D-05` 的清空复位必须调用同一函数 |
| `D-04` 排在 D5（与 CP2 同日），资源被联调挤占 | D5 中午 Repo 未完成 | 降级顺序：①先保 `get()`/`save()`（`U-05` 能用）②`resetToDefaults()` 推迟到 D8 与 `D-05` 一起做 ③归一化的截断规则最后补 |

## 7. 与检查点的关系
- 本功能**不是任何 CP 的直接判据**（CP1/D3、CP2/D5、CP3/D9、CP4/D7 的判据均不含设置项）。
- 本功能是 `U-05`（我的 / 设置页，D8 收口）与 `D-05`（一键清空，D8）的前置；D5 完成即可让 `U-05` 不再依赖占位状态。
- CP2（D5 晚）当天若联调吃紧：本功能可整项推迟到 D6 —— `U-05` 在 D8 才收口，且默认值让「不配置也能用」，**这是本功能唯一的降级弹性**。但判据 9（无账号 API）**不得**推迟，它是 `X-01` 裁剪的机器证据。
- 未完成时的连带影响：`D-05` 的「清空后复位」依赖 `profile_defaults.dart`，若本功能未交付，`D-05` 需自带默认值常量 —— 会形成两份真相，**禁止**，故 D-05 开工前本功能至少须交付 WBS 任务 1。

---
**文档结束**
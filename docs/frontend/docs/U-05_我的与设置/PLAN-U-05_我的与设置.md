# PLAN-U-05 我的 / 设置

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-05` |
| 负责 | C（主责；`D-04` 本地档案亦归 C）；B 协助 `D-05` 清空与音频残留清理 |
| 目标日 | D8（D5 起做 `D-04` 档案，D8 收口） |
| 前置依赖 | `PLAN-D-04`（本地档案，D5）、`PLAN-D-05`（清空 + 残留清理，D8）、`PLAN-D-02`（DAO）、`PLAN-D-03`（`StatsRepo.activeDays()`，D8 切换）、`PLAN-U-06`（空态/图标）；`API-05` §11 缺口的登记已完成 |
| 预估工时 | 9 h（D5 3h 档案 + D8 6h 设置页与收口） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/profile/profile_page.dart` | 「我的」页面骨架与入口列表 |
| 2 | `app/lib/presentation/pages/profile/widgets/profile_header.dart` | 头像 + 昵称 + `已坚持 N 天`（动态） |
| 3 | `app/lib/presentation/pages/profile/widgets/achievements_static.dart` | 成就静态展示（无解锁逻辑） |
| 4 | `app/lib/presentation/pages/profile/widgets/entry_list.dart` | 健康报告 / 数据导出（置灰 v1.1）/ 隐私设置 / 关于 |
| 5 | `app/lib/presentation/pages/profile/widgets/clear_data_sheet.dart` | 清空数据二次确认弹层 |
| 6 | `app/lib/presentation/pages/profile/privacy_notice_page.dart` | 隐私声明（无网络权限、音频不落盘、可携带性告知） |
| 7 | `app/lib/presentation/pages/profile/about_page.dart` | 关于 AcouDiet（版本号读构建常量） |
| 8 | `app/lib/data/profile/profile_dao.dart` | `D-04` 本地档案 DAO（`UserProfile`） |
| 9 | `app/lib/presentation/providers/profile_providers.dart` | 档案 / 天数 / 演示标识 3 个 Provider |
| 10 | `app/test/widget/profile_page_test.dart` | `SPEC-U-05` §7 判据 1–6、8–11 |
| 11 | 清空数据仪器测试（含 `cacheDir/audio_*` 计数） | `app/test/integration/clear_data_test.dart` |
| 12 | 人工核对记录（`9.png` 比对 + 10 项核对表） | `docs/review/U-05_核对表.md`（评审附件） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | `UserProfile` 模型 + DAO（C 承接 `D-04`） | `profile_dao.dart` | 1.5 h | `D-01` Schema |
| 2 | 页面骨架 + 3 个 Provider（`activeDays` 取 `D-03` 的 `StatsRepo.activeDays()`，`API-03` §5） | `profile_providers.dart` | 1.5 h | 1 |
| 3 | 头部：头像 / 昵称 / `已坚持 N 天`（动态，非硬编码；就绪前 `-- 天`） | `profile_header.dart` | 1.0 h | 2 |
| 4 | 成就静态展示（常量徽章，无解锁） | `achievements_static.dart` | 0.5 h | U-06 |
| 5 | 入口列表（报告跳转 / 导出置灰 v1.1 / 隐私 / 关于） | `entry_list.dart` | 1.0 h | 路由 |
| 6 | 隐私声明页（三条要点 + 可携带性告知，文案逐字） | `privacy_notice_page.dart` | 1.0 h | `SPEC-U-05` §4.3 |
| 7 | 清空数据二次确认 + `D-05` 接入 + `clearTempAudio` | `clear_data_sheet.dart` | 1.5 h | `PLAN-D-05` |
| 8 | 关于页（版本号读 `pubspec`，改名 AcouDiet） | `about_page.dart` | 0.5 h | — |
| 9 | 无障碍语义标签（含置灰入口的语义朗读） | 全页 | 1.0 h | 3–8 |
| 10 | 「复制为文本」按钮（`ADR-P4`）：契约表内字段序列化为纯文本 → `Clipboard.setData` 写**系统剪贴板**；**不落文件 / 不走网络 / 不外发 / 不申请新权限**；隐私声明补「数据仅存于本机，卸载即丢失」 | `profile_page.dart`、`privacy_notice_page.dart` | 0.1 人日（**由本页既有预算吸收，总工时不变**） | 5 |
| 11 | 测试 + 人工核对表 | 2 个测试文件 | 2.0 h | 1–10 |

## 3. 技术方案

- **替代登录（`X-01`）**：`user_profile` 单行记录，`ProfileRepo.load()` 表空时返回默认档案（不抛错、不自动建行，`API-03` §6）；无账号、无网络、无密码字段。
- **天数动态且不硬编码**：口径 = **累计有记录天数**（非连续），来源 `StatsRepo.activeDays()`（`API-03` §5，`ADR-06` 修订 A-1 新增；**无参数、不随窗口变化**，跨全部历史不分 real/demo）。**切换顺序**：`PLAN-D-03` 的 `activeDays()` **就绪前**，Provider 返回 `null` → 渲染 `已坚持 -- 天`；**就绪后（D8）改为该方法返回的真实值**（`0` → `已坚持 0 天`）。**页面不得自行扫描全表**（违反 `API-00` §1 规则 1）。
- **成就静态**：徽章与文案为 `const` 列表，**不做**达成判定、进度、动画（`X-04`）。
- **导出入口置灰**：`ListTile(enabled: false)` + `v1.1` 角标；`onTap` 为空实现，**不引入任何导出依赖**（避免 `X-03` 被顺手实现）。
- **清空为事务**：`MaintenanceRepo.clearAllData()`（单事务清两表 + 重置档案行，`API-03` §7）+ `MaintenanceRepo.clearTempAudio()`（**必须委托**原生 `API-01` §2.7，禁止在 Dart 侧另写匹配逻辑）。
- **可达性真实**：如果 v1.0 不提供**文件**导出，就不写「支持导出」的文案，也不做假按钮。
- **「复制为文本」的实现边界（`ADR-P4`）**：只调用 `Clipboard.setData`，纯文本**只由契约表内字段**序列化；**不走网络、不落文件、不外发、不申请新权限** —— Manifest 权限集合**不变**（仍只有 `RECORD_AUDIO`，仍无 `INTERNET`）。上一条「不引入任何导出依赖」对本按钮同样有效：不得引入 `share_plus` / `path_provider` / `dart:io` 写文件。
- **骨架示意（≤30 行）**：

```dart
// SPEC-U-05 §10 问题 1 已关闭（ADR-06 修订 A-1）：
//   PLAN-D-03 的 activeDays() 就绪前（D3–D7）恒为 null → 显示「已坚持 -- 天」
//   就绪后（D8）改为 ref.watch(statsRepoProvider).activeDays() 的真实值
final activeDaysProvider = FutureProvider<int?>((ref) => null);

class ProfilePage extends ConsumerWidget {
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(activeDaysProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(children: [
        ProfileHeader(
          nickname: ref.watch(profileProvider).valueOrNull?.nickname ?? '未设置昵称',
          activeDays: days.valueOrNull,                     // null → 「已坚持 -- 天」
        ),
        const AchievementsStatic(),                         // X-04：静态，无解锁逻辑
        EntryList(items: [
          EntryItem('健康报告', () => context.push('/report')),
          const EntryItem('数据导出', null, enabled: false, badge: 'v1.1'), // X-03 置灰
          EntryItem('隐私设置', () => context.push('/privacy')),
          EntryItem('关于 AcouDiet', () => context.push('/about')),
        ]),
        TextButton(
          onPressed: () => showModalBottomSheet(
              context: context, builder: (_) => const ClearDataSheet()),
          child: const Text('清空全部数据')),
      ]),
    );
  }
}
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `profile_page_test.dart` | widget test | `SPEC-U-05` §7 判据 2–6、8–13 全通过 | 每次提交 |
| 天数动态 | widget test | `activeDays()` 就绪前 → `已坚持 -- 天`；就绪后 0 天 → `已坚持 0 天`、3 天 → `已坚持 3 天`（`ADR-06` 修订 A-1）；**页面内无 "7 天" 常量** | D7（占位）、D8（切换后） |
| 导出入口 | widget test | `enabled == false`、文本含 `v1.1`、点击无任何出口调用（mock 校验） | D8 |
| 「复制为文本」 | widget test | 点击后剪贴板内容**非空**且**包含记录时间与类别**；序列化只含契约表内字段（零表外字段，R-19） | D8 |
| 复制动作的隐私约束 | widget test + shell | **全程无网络调用、无文件写入**（`rg` 在 profile 目录命中 `http` / `dio` / `HttpClient` / `writeAsString` / `openWrite` == 0）；不新增权限，Manifest 仍只有 `RECORD_AUDIO`、仍无 `INTERNET`（`ADR-P4`） | D8、D9 |
| 成就静态 | widget test | 无进度条 widget、无「已解锁」文本 | D8 |
| 清空数据 | integration test | 确认后 `diet_record` / `behavior_metrics` / `user_profile` 行数 == 0 | D8 |
| 音频残留 | integration test（`PLAN-D-05` 联动） | 清空后 `cacheDir` 中 `audio_*` 文件数 == 0 | D8、D9 |
| 文案逐字 | widget test | 可携带性告知、隐私要点、清空确认、导出提示、「复制为文本」按钮与结果提示与 `SPEC-U-05` §4.3 逐字一致 | D8 |
| 禁用词扫描 | shell | 登录/网络/表外数值区块/FF-25 词命中数 == 0 | D8、D9 |
| 飞行模式 | 手测 | 本页全部功能（含清空）在飞行模式下工作 | D9 |
| 人工核对表 | 人工 | `SPEC-U-05` §7 的 9 项全 ✓ | D8 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-05` 第 7 节 13 项判据全部通过（含 9 项人工核对表逐项打钩）。
- [ ] 12 项交付物落盘可点开。
- [ ] 「复制为文本」按钮已落地（`ADR-P4`）：点击后系统剪贴板收到**非空纯文本**（含记录时间与类别），**不走网络、不落文件、不外发**、**不申请任何新权限**、**不改变 Manifest 的权限集合**（仍只有 `RECORD_AUDIO`，仍无 `INTERNET`）；隐私声明**明确写出**「数据仅存于本机，卸载即丢失」。
- [ ] 「已坚持 N 天」为**动态计数**且无硬编码 7，来源 `StatsRepo.activeDays()`（`API-03` §5）；`PLAN-D-03` 就绪前显示 `-- 天`、就绪后切换为真实值；成就为**静态展示**且无解锁逻辑。
- [ ] 导出入口置灰并标 `v1.1`，代码中不存在任何**文件导出**实现；「复制为文本」**只允许**调用 `Clipboard`（`ADR-P4`），**不得**引入 `share_plus` / `path_provider` / `dart:io` 文件写入。
- [ ] 隐私声明与可携带性告知文案与 §4.3 逐字一致；PPT 若强调合规，已按 §10 开放问题 3 的口径回避「完全合规」表述。
- [ ] 清空数据成功路径与失败路径都可复现；失败时不谎报成功。
- [ ] `API-05` §11 的缺口已在本 SPEC 与 `SPEC-D-05` §9 双处登记，并已按 `ADR-P4` 关闭（`SPEC-U-05` §10 已写明结论）。
- [ ] 无障碍：置灰导出入口可被朗读为「v1.1 提供，当前不可用」；确认弹层焦点顺序为「取消」→「确认」。

> **范围口径（`ADR-P4`，评审会问）**：本项**不新增范围**（约 20 行，由 `U-05` 既有预算吸收），因此**不需要等额删除其他功能**（风险 `R-14` 不触发）。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `9.png` 的「本周健康数据概览」被顺手实现 | 页面上出现「平均咀嚼速度」等表外项 | 按 `SPEC-U-05` §4.1 C 类**立刻删除**；如需保留先走 `PLAN-C-03` 变更传播并入契约表 |
| `X-04` 成就被做成解锁系统 | 出现进度条/解锁弹窗 | 立刻回退为 `const` 静态展示 |
| `X-03` 被实现成真导出 | 依赖里出现 `share_plus` / `path_provider` 导出用法，或剪贴板动作开始落文件 | 立刻回退；导出入口保持置灰；「复制为文本」只允许用 `Clipboard`，不得引入 `share_plus` / `path_provider` / `dart:io` 写文件（`ADR-P4` 硬约束） |
| 天数口径争议（连续 vs 累计） | 现场被问「漏记一天怎么算」 | 采用累计口径（本 SPEC §2.4），答辩时主动说明该口径的选择理由 |
| `PLAN-D-03` 工时不足砍掉 `activeDays()` | D8 时该方法仍不可用 | 按 `API-03` §11.1 的降级顺序，本页**长期显示 `已坚持 -- 天`**；**不得**改用「页面自行扫全表」的粗口径（`API-00` §1 规则 1） |
| `D-05` 清空不彻底 | 残留 `audio_*` 或孤儿行 | 由 `PLAN-D-05` 的集成测试拦截，D9 前残留必须为 0 |
| 可携带性缺口被评委追问 | 问「数据怎么带走」 | 已按 `ADR-P4` 落地「复制为文本」（写系统剪贴板，**不走网络、不落文件、不外发、不申请新权限**）：现场在飞行模式下点击 → 粘贴出纯文本即可作答；**文件导出（SAF）仍按 `X-03` 留 v1.1**，**不得**临时承诺已有文件导出 |

## 7. 与检查点的关系
- 本功能**不属于任何 CP 的硬判据项**（CP1–CP4 均不依赖本页）。
- 但它是 **FF-24 隐私主张的展示面**：D9 现场 SOP 中「飞行模式全流程可用」的说明与「一键清除全部数据」的演示（FF-24 第 7 条）都在本页完成，属 `PLAN-C-01` 权限复核与 `PLAN-D-05` 清理验收的现场证据来源。
- 未完成时：CP 判据不变；本页可延至 D8 晚，但**隐私声明与清空数据两项不可延到 D9**（现场演示需要）。

**文档结束**

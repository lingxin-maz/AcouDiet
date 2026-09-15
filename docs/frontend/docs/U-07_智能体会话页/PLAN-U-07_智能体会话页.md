# PLAN-U-07 智能体会话页

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-U-07 |
| 负责 | C（主责）；B 协助 `SPEC-G-02` 的事件流对接与 `SPEC-G-03` 的桥接 |
| 目标日 | v2.0-第 2 日 ～ v2.0-第 5 日（第 5 日必须出包） |
| 前置依赖 | `SPEC-G-01` 的 `AgentCredentialsStore` 可读；`SPEC-G-02` 的 `AgentSession` 事件流接口冻结；`SPEC-C-06` §4.3 同意门文案定稿；`SPEC-U-06` 令牌已就绪 |
| 预估工时 | 32 人时 |

## 1. 交付物（Deliverables）
| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/agent/agent_page.dart` | 本页骨架：八个状态的派发 + 空/错误/截断三态 |
| 2 | `app/lib/presentation/pages/agent/agent_consent_gate.dart` | 同意门与 Key 缺位门 |
| 3 | `app/lib/presentation/pages/agent/agent_tool_cards.dart` | 四类工具卡片 + 外卖交接卡片（平台诚实性三分支） |
| 4 | `app/lib/presentation/presenters/agent_presenter.dart` | 纯 Dart 视图模型：状态→文案、卡片槽位填充 |
| 5 | `app/lib/presentation/presenters/ui_strings.dart` | 新增 `SPEC-U-07` §4.3 的逐字常量 |
| 6 | `app/lib/presentation/pages/shell/app_shell.dart` | `ShellTab.agent` 加入 `tabs`（index 2）；改注释、`AcouNavBar.labels/icons/activeIcons` |
| 7 | `app/test/ui/app_shell_layout_test.dart`、`app/test/ui/agent_page_test.dart`、`app/test/ui/agent_consent_test.dart` | 5 Tab 断言（`记录` 序号 2→3）、页面与零请求用例（含负控） |
| 8 | `app/tool/ui_presenter_tests.dart` | 新文案加入字符串采集；隐私声明断言改为按风味参数化 |
| 9 | `app/lib/presentation/presenters/settings_presenter.dart`、`presenters/ui_strings.dart`、`pages/profile/privacy_notice_page.dart` | `privacyNotice` / `privacyEntrySpoken` / `privacyEntrySubtitle` 按风味组装；`Icons.wifi_off_outlined` 条目按风味分支 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 底栏改造：5 Tab + 注释 + 序号断言 | 交付物 6/7 | 4h | — |
| 2 | 隐私文案按风味重构（含被打破的 5 处） | 交付物 5/9 | 4h | 1 |
| 3 | `AgentPresenter` 状态→文案纯函数 | 交付物 4 | 4h | — |
| 4 | 同意门 + Key 缺位门 | 交付物 2 | 4h | 3 |
| 5 | 会话区（`ListView.builder` + 流式追加） | 交付物 1 | 6h | 3 |
| 6 | 工具卡片与交接卡片（三分支） | 交付物 3 | 5h | 3 |
| 7 | 无障碍标签与点击区核对 | 交付物 1/3 | 2h | 4,5,6 |
| 8 | 测试与负控（含红线采集） | 交付物 7/8 | 3h | 全部 |

## 3. 技术方案
**状态派发（`SPEC-U-07` §2.3 的八个状态，一个 `switch` 收敛）**
```dart
Widget build(BuildContext context) => switch (session.state) {
  AgentUiState.unconsented => const AgentConsentGate(),
  AgentUiState.keyMissing  => const AgentKeyMissingGate(),
  AgentUiState.offline     => StateView(status: ViewStatus.empty, message: AgentPresenter.degradedText),
  AgentUiState.idle        => _Conversation(empty: AgentPresenter.emptyCopy),
  AgentUiState.sending     => _Conversation(busy: true),
  AgentUiState.streaming   => _Conversation(streaming: true),
  AgentUiState.toolRunning => _Conversation(cards: session.cards),
  AgentUiState.failed      => _FailurePanel(reason: session.failureReason),
};
```
**页面骨架复用 `SPEC-U-06`**：`AcouPageHeader(title: Text(UiStrings.agentTabTitle), centerTitle: true)` + `AcouScrollEdge` 包住 `RefreshableBody`；三态一律走 `state_view.dart` 的 `StateView`，**不新增**第三套样式常量。
**交接按钮是唯一触发点**（`API-07` §13.4.4）：
```dart
FilledButton(
  onPressed: card.openable ? () => launcher.openSearch(
        platformId: card.platformId, keyword: card.keyword) : null,   // enabled==false → null
  child: Text(UiStrings.handoffButton(card.platformLabel)),
)
```
平台诚实性由 presenter 计算：`card.openable = p.enabled`，`card.unverifiedHint = p.verifiedOn == null`（`SPEC-U-07` §2.4）。工具执行路径**只**产出卡片，绝不调用 `openSearch`。
**请求体不在此层**：本页不 import `dart:io`、不 `utf8.encode`；一切出网经 `SPEC-G-02`（`API-05` §13.2）。
**无障碍**：卡片外包 `Semantics(label: card.semanticsLabel, container: true)`；可点元素最小尺寸取 `AcouTheme.minTapTarget`。

## 4. 测试与验证
| SPEC §7 # | 测试（命名断言） | 类型 | 断言 | 何时跑 |
|---|---|---|---|---|
| 1 | `the shell has five tabs and 智能体 is the third` | widget | `tabs.length == 5`、`indexOf(agent) == 2`、`labels[2] == '智能体'`；负控去一项变红 | 每次提交 |
| 2 | `the recorded tab index follows the amended order` | widget | `记录` 点击后 `currentIndex == 3`；`rg` 旧注释命中 0 | 每次提交 |
| 3 | `with consent withheld the agent issues zero requests` | widget | `enabled == false` 且 `requestCount == 0`；负控置真变红 | 每次提交 |
| 4 | `no FF-25 banned wording in any produced string` | 工具脚本 | 新文案在采集清单内，命中 0 | 每次提交 |
| 5 | `the handoff button is the only caller of openSearch` | widget + rg | 工具调用后调用计数 0；`presentation/` 下 rg 命中 0 | 每次提交 |
| 6 | `no accessibility automation string exists` | rg | 命中 0；负控变红 | 每次提交 |
| 7 | `empty, error and truncated states match §4.3 verbatim` | widget | 三态文本逐字符相等 | 每次提交 |
| 8 | `a disabled platform is not tappable and an unverified one says so` | widget | 三分支文案与 `onPressed` 状态正确 | 每次提交 |
| 9 | `every agent surface is reachable and sized` | widget | 语义标签非空；尺寸 ≥ `minTapTarget` | 每次提交 |
| 10 | `the key is only ever shown masked` | widget + rg | 只出现 `keyMask`；`sk-` 命中 0 | 每次提交 |
| 11 | `the page never constructs a request body` | rg | `presentation/pages/agent/` 命中 0 | 每次提交 |
| 12 | `flutter test test/ui/` | 回归 | 退出码 0 | 每次提交 |
| 13 | `the privacy notice claims no network permission only in the offline flavour` | 工具脚本 + widget | 两风味断言如上；五处旧实现 `rg` 命中 0；负控变红 | 每次提交 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-07` §7 全部 12 条判据通过，其中 #1/#3/#6 的负控**已实际跑红过一次**并留痕。
- [ ] 底栏 5 项在两处（`AppShell.tabs`、`AcouNavBar.labels/icons/activeIcons`）一致，无遗留「four」措辞。
- [ ] `privacyNotice` / `privacyEntrySpoken` / `privacyEntrySubtitle` / `privacy_notice_page.dart` / `ui_presenter_tests.dart` 的隐私断言 5 处全部按风味更新，`offline` 仍含「不申请网络权限」，`agent` 不含。
- [ ] 交接卡片对三平台的三分支均有用例。
- [ ] 本页任一降级态下 `P-*`/`D-*`/`A-*`/`M-01`~`M-04`/`U-01`~`U-06` 回归全绿（`FF-26f`）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `SPEC-G-02` 事件流未就绪 | 第 3 日仍无 `AgentSession` 接口 | 本页先用内存假事件流跑通 UI；`sending/streaming/toolRunning` 用夹具驱动，接口到位后只换装配 |
| 第 3 个 Tab 挤压底栏造成溢出 | `app_shell_layout_test.dart` 的「底栏不吃屏」变红 | 先按 `AcouNavBar.tileWidth` 收窄并加横向滚动；**不得**通过删 Tab 解决 |
| 隐私文案改动牵连 `U-05` 回归 | `test/ui/mockup_layout_test.dart` 变红 | 同步更新 `privacyEntrySpoken`/`privacyEntrySubtitle` 常量对；不得改断言迁就代码 |
| 流式渲染掉帧【待实测】 | 现场滚动卡顿 | 降级为分批追加（每 ≥100 ms 合并一次 delta） |

## 7. 与检查点的关系
本页是 v2.0 的**演示面**：CP 前必须能演示「未同意 → 同意 → 对话 → 工具卡片 → 交接按钮」全链路。未完成时，CP 处置为**只演示 `offline` 风味的 4 Tab 链路**并把云端能力从 PPT 主叙事移入「后续工作」；**不得**用一个未过同意门的假入口充当交付。

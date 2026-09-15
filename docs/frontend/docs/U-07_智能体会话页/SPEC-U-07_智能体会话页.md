# SPEC-U-07 智能体会话页

| 项 | 值 |
|---|---|
| 域 | `U` · 界面 |
| 归属 | C |
| 状态 | ✅ v2.0 交付 |
| 上游依据 | `SPEC-00` §3.8 FF-23（`ADR-44` 修订）、§3.9 FF-24 第 4/5/8/9 条、§3.10 FF-25、§3.11 FF-26（a~j）；`ADR-44`；`API-07` §1/§2/§3/§4/§5/§7；`API-05` §10/§11/§13；`API-00` §1 |
| 依赖的 SPEC | `SPEC-U-06`（设计系统，唯一 UI 组件来源）、`SPEC-U-05`（设置与隐私文案）、`SPEC-G-01`（连接层与凭据）、`SPEC-G-02`（编排循环）、`SPEC-G-03`（工具与交接）、`SPEC-C-06`（同意门与出境规则）、`SPEC-C-01` §7（按风味的权限判据）、`SPEC-C-02`（同意归档体例） |

## 1. 目标与范围
### 1.1 一句话目标
在 App 的第 3 个 Tab 上提供智能体会话界面：先过**同意门**、再过**Key 缺位门**，然后才允许对话；工具结果一律渲染为**本页自己的卡片文案**，其中外卖卡片是**唯一**能离开 App 的入口，且**必须由用户按下按钮**。

### 1.2 范围内（In Scope）
| # | 内容 | 说明 |
|---|---|---|
| 1 | **第 3 个 Tab（index 2）**，标签逐字为 `智能体` | FF-23 经 `ADR-44` 修订为 5 页；本页插在 `检测` 与 `记录` 之间 |
| 2 | **同意门**（未同意态的全屏门） | 文案、按钮、记录与撤回入口统一按 `SPEC-C-06` §2；本页只负责呈现 |
| 3 | **Key 缺位门** | 未配置或形状非法时显示入口文案 + 跳设置页；**不**在本页采集 Key |
| 4 | 会话流 | 用户输入、流式回复、`role:tool` 结果不直接展示，只转成卡片 |
| 5 | **工具卡片**（四类，见 §4.2） | 卡片文案由本页 `UiStrings` 常量生成，工具返回值**只填数值槽位**（`API-07` §4.3） |
| 6 | **外卖交接卡片** | 名称、检索词、平台按钮；按钮是本页**唯一**调用 `AgentPlatformLauncher.openSearch` 的位置（`API-07` §3.2、§13.4.4）。<br>🆕 **`ADR-45`**：卡片上还有**第二个、语义不同**的按钮「看带图片的选项」，它**不离开 App**，而是推入 `TakeoutBrowserPage` —— 用 `WebViewWidget` 加载该平台的**网页搜索 URL**，让用户看到真菜真图真价。两个按钮并存而非二选一：一个离开、一个不离开，合并它们等于替用户决定了他要哪一种。<br>该按钮整块包在 **`!acouIsOffline`** 的**编译期**分支里：`offline` 包**不得**包含任何 WebView（那是「本包不申请联网权限」的那个包）。 |
| 7 | 降级态 | 六种离线情境下显示可解释的降级态，`FF-26f`；**不阻断**任何其他页面 |
| 8 | 空态 / 错误态 / 回复截断态的**逐字文案** | 见 §4.3 |
| 9 | 无障碍 | 每张卡片与交接按钮的 `Semantics` 标签；点击区 ≥ `AcouTheme.minTapTarget` |

### 1.3 范围外（Out of Scope）
- **不做**任何自动下单、自动跳转、自动填地址、代付（`FF-26i`）。交接卡片不点击时**不产生任何外部可见副作用**。
- **不做**多会话、会话列表、会话重命名、跨启动的会话历史（`X-*` 未登记项按 §9 处置）；本页默认**不落盘**任何对话文本。
- **不做**模型选择、温度/输出长度等推理参数 UI；这些键的唯一真源是 `feature_config.agent`（`API-07` §6）。
- **不做**图片/文件/语音输入；本页输入控件**只有**文本。
- **不做** Key 的代购、共享额度、内置试用 Key（`FF-26b`）。
- **不做**工具结果的原文渲染（`API-07` §4.3 已判为提示注入面）。
- **不做** `offline` 风味的入口：`offline` 风味**没有**第 3 个 Tab（`FF-24` 第 4 条，见 §2.1）。

## 2. 功能行为
### 2.1 触发与前置条件
| 项 | 要求 |
|---|---|
| 触发 | 底栏点击 index 2（标签 `智能体`） |
| 风味 | 仅 **`agent` 风味**存在本页与第 3 个 Tab；`offline` 风味底栏仍为 4 项，本页**不构建**（编译期 `const` 分支，不是运行期隐藏） |
| 前置 | `SPEC-C-06` 的同意记录可读；`AgentCredentialsStore.read()`（`API-07` §2）可读（失败按 `null` = 未配置） |
| 不变量 | `FF-26f`：本页任一态都不得抛异常、不得阻断 `P-*`/`D-*`/`A-*`/`M-01`~`M-04`/`U-01`~`U-06` |

### 2.2 主流程（编号步骤）
1. 切到 index 2 → 立即读同意记录；未同意 → 进 `unconsented`，**只渲染同意门**，不发任何请求（`FF-24` 第 9 条）。
2. 用户读同意门文案（`SPEC-C-06` §2.1 的逐字副本）→ 勾选确认 → 点主按钮 → 写同意记录 → 进入下一步；点次按钮 → 回 index 0，同意记录不变。
3. 读凭据：`null` 或形状非法 → `keyMissing`，显示入口文案 + 「去设置填入 Key」按钮（跳 `U-05`）。
4. 凭据就绪 → 构造一次连通性判定（`SPEC-G-01`）：不可达 → `offline`（降级态）；可达 → `idle`。
5. `idle`：渲染空态或既有内存消息；用户键入文本并提交（空串/纯空白**不提交**）。
6. `sending`：发请求（请求体由 `SPEC-G-02` 的 `AgentPromptBuilder` 单点构造，`API-05` §13.2），本页**不参与**构造。
7. `streaming`：增量追加 `delta.content`；不得在每个分片单独 `jsonDecode`（`API-07` §5.3）。
8. `finish_reason == tool_calls` → `toolRunning`：由 `SPEC-G-02` 执行工具；本页把 `AgentObservation.artifacts` 转成卡片，**只填槽位**。
9. `propose_takeout_search` 的产物 → **外卖交接卡片**（`proposalOnly == true`，`API-07` §4.1）；卡片渲染平台名、`label`、检索词，以及 `enabled`/`verifiedOn` 的诚实提示（§2.4）。
10. 用户点交接卡片按钮 → 调 `canOpen(platformId)` → 可唤起则 `openSearch(...)`，否则显示「该平台入口打不开」并**不**跳转；**这是本页唯一离开 App 的路径**（`API-05` §13.4.4）。
11. 服务端 `finish_reason == stop` → 回 `idle`；`length` → `failed(truncated)`（§4.3）；异常按 §6 映射。
12. 任何时刻用户可点顶栏的「关闭云端智能」→ 转 `unconsented` 并触发 `SPEC-C-06` §2.4 的撤回动作（含删除本机 Key）。

### 2.3 状态与状态迁移
```dart
/// 本页唯一状态机。八个状态，不得增删（SPEC-U-07 §2.3）。
enum AgentUiState {
  unconsented, keyMissing, offline, idle, sending, streaming, toolRunning, failed,
}

/// `failed` 的子原因；不进状态机，只决定文案与「重试」是否可用。
enum AgentFailureReason {
  network, invalidKey, rateLimited, serverError, timeout, streamBroken, truncated,
  toolUnparsable, toolRoundsExceeded,
}
```
| 当前态 | 事件 | 下一态 | 说明 |
|---|---|---|---|
| `unconsented` | 用户点主按钮 | `keyMissing` 或 `offline`/`idle` | 先写同意记录，**此时才允许**首次请求 |
| `unconsented` | 用户点次按钮 | `unconsented`（并切回 index 0） | 不写记录、不发请求 |
| `keyMissing` | 凭据写入成功（返回本页） | `offline` 或 `idle` | 形状校验由 `SPEC-G-01` 负责；本页**不做**在线校验 |
| `offline` | 网络恢复且用户下拉重试 | `idle` | 无自动轮询；重试由用户发起（`FF-24` 第 6 条的精神） |
| `idle` | 提交非空输入 | `sending` | 输入框置忙，禁重复提交 |
| `sending` | 首帧 delta | `streaming` | |
| `sending`/`streaming` | `finish_reason == tool_calls` | `toolRunning` | 卡片渲染与工具执行同轮 |
| `toolRunning` | 工具轮次 < `FF-26g` 上限 | `sending` | 回灌观察后继续 |
| `toolRunning` | 达到上限 | `failed(toolRoundsExceeded)` | 如实告知，**不静默续跑** |
| `streaming` | `finish_reason == stop` | `idle` | |
| `streaming` | 流中断 | `failed(streamBroken)` | **保留已收内容**（`API-07` §7 `ACD-AGENT-008`） |
| 任意态 | 用户撤回同意 | `unconsented` | 进行中的请求**立即取消**，不重试 |
| `failed` | 用户点「重试」 | `sending` | 仅当 `retryable == true`（`API-00` §1 / `ACD-AGENT-007` 已收内容后**不**重试） |

### 2.4 边界条件
- **空输入**：提交按钮在纯空白输入下 `enabled == false`；不触发 `sending`。
- **回复截断**（`finish_reason == length`）：进 `failed(truncated)`，**保留**已收文本并追加截断提示（§4.3）；**不得**把截断文本渲染成完整回答。
- **平台诚实性（硬要求，不是润色）**：交接卡片逐个平台读 `feature_config.agent` 的 `enabled` 与 `verifiedOn`（`API-07` §3.3）：
  - `enabled == false` → 该平台按钮**不渲染为可点**，并显示 §4.3 的「已关闭」文案；
  - `verifiedOn == null` → 按钮可点，但**必须**并列显示 §4.3 的「尚未核实」次要提示；
  - `enabled == true` 且 `verifiedOn != null` → 正常渲染，无次要提示。
  - **不得**因模板好看而省略上述提示；`SPEC-G-03` §7 负责把核实日期写回 SSOT。
- **历史裁剪**：超过 `FF-26g` 的 `max_history_messages` 时由 `SPEC-G-02` 裁剪最旧的**非 system** 消息；本页**只显示**，不自行裁剪。
- **请求体上限**：超 `FF-26g` 的 `max_request_bytes` 时由连接层裁剪历史并**不**放宽上限；本页显示「本轮上下文已裁剪」的次要提示（一次，不重复弹）。
- **Key 生命周期**：本页**只**显示 `mask(apiKey)`（`API-07` §2）；永不显示明文、不写入日志、不进入诊断快照与截图（`FF-26b`）。
- **撤回同意后**：`AgentService.enabled == false`，本机 Key 已被删除（`SPEC-C-06` §2.4），本页回到 `unconsented`；已渲染的内存消息清空。
- **切走再切回 Tab**：不得自动重新发起上一轮请求；状态保留，`streaming` 中的流**继续**（不退订），但**不**因切 Tab 触发新请求。
- **`offline` 风味**：本页与第 3 个 Tab 均不存在；底栏 `AppShell.tabs` 仍为 4 项，且 `AcouNavBar.labels` 与之等长。

## 3. 接口契约
> 完整签名以 `API-07` / `API-04` / `API-03` 为准；本表只列本页**用到**的部分。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 本页 ← `SPEC-C-06` | `AgentConsentStore.read()` / `grant(scopeVersion)` / `revoke()` | 版本号 | `bool` / `Future<void>` | `ACD-AGENT-002` |
| 本页 ← `SPEC-G-02` | `AgentService.enabled`（`bool`，未同意恒 `false`） | — | `bool` | — |
| 本页 ← `SPEC-G-02` | `AgentSession.state` / `AgentSession.messages` | — | `AgentUiState` / `List<AgentMessage>` | — |
| 本页 → `SPEC-G-02` | `AgentSession.send(String userText)` | 用户键入文本 | `Stream<AgentEvent>`（delta / toolCall / done / error） | `ACD-AGENT-001`~`010`（`API-07` §7） |
| 本页 → `SPEC-G-02` | `cancelCurrentTurn()` | — | `Future<void>` | — |
| 本页 ← `SPEC-G-01` | `AgentCredentialsStore.read()`（`API-07` §2） | — | `AgentCredentials?`（损坏 → `null`，**不抛**） | — |
| 本页 → `SPEC-G-03` | `AgentPlatformLauncher.canOpen(platformId)`（`API-07` §3.2） | 平台 id | `bool` | — |
| 本页 → `SPEC-G-03` | `AgentPlatformLauncher.openSearch({platformId, keyword})` | 供用户阅读过的检索词 | `bool`（是否离开本 App） | `ACD-AGENT-010` 无关；失败仅提示 |
| 本页 ← `SPEC-C-06` | 交接卡片的 `enabled` / `verifiedOn` 判定 | 平台对象 | 三种呈现分支（§2.4） | — |
| 本页 → `U-05` | 路由 push `ProfilePage()`（填 Key 入口） | — | — | — |
| 本页 → 外部 App | **无直接接口**：只能经 `SPEC-G-03` 的桥接层；本页**不得**引用 `MethodChannel` 或 Android Intent | — | — | — |

## 4. 数据契约
### 4.1 本页持有的内存模型
| 字段 | 类型 | 单位/值域 | 可空 | 说明 |
|---|---|---|---|---|
| `messages[].role` | enum | `user` / `assistant` / `tool` | 否 | `system` **不**进本列表 |
| `messages[].text` | string | 用户文本或模型文本 | 是（`tool` 行为空） | 默认**不落盘**；无会话记录开关时退出即失效 |
| `messages[].atMs` | int64 | epoch 毫秒（UTC，`API-00` §3.2） | 否 | |
| `cards[]` | `AgentCardView` | 由 `artifacts` 映射，见 §4.2 | 否 | **卡片 = 视图模型**，不是服务端文本 |
| `keyMask` | string | `mask(apiKey)`；长度 < 8 → `****` | 否 | `API-07` §2；**永不**出现明文 |
| `usageInMemory` | object | `prompt_tokens` / `completion_tokens` | 是 | 只进内存诊断（`API-05` §13.3.4），**不外发、不落盘** |

> 本页**不新增任何数据库表、不新增 Schema 文件**（`API-03` 不因本页扩表）；凭据与同意记录的载体见 `SPEC-C-06` §4。

### 4.2 卡片视图模型（四类，逐槽位）
| 卡片 | 来源工具（`API-07` §4.1） | 渲染槽位（只填数值） | 文案来源 |
|---|---|---|---|
| 健康摘要卡 | `get_health_summary` | 四维分数、总分、评级、聚合计数 | 本页 `UiStrings` 常量 |
| 近期记录卡 | `get_recent_meals` | 类别、时间、置信度 | 同上 |
| 建议卡 | `recommend_food` | 建议条目与其理由 | 同上 |
| **外卖交接卡** | `propose_takeout_search` | 平台名、检索词、`enabled`、`verifiedOn` | 同上 |

> 工具返回的 `summary` 文本**不得**直接进入 UI（`API-07` §4.3）：`summary` 只用于内存日志与 `M-04` 自检面板。

### 4.3 文案契约（逐字，冻结）
| 场景 | 文案（不得改写） |
|---|---|
| Tab 标签 / 页面标题 | `智能体` |
| **空态**（`idle` 且无消息） | `还没有对话。问它「今天吃得怎么样」，或让它帮你想一顿饭。` |
| **错误态（网络）** `network` | `当前离线，核心功能可正常使用。恢复网络后可继续对话。` |
| **错误态（Key）** `invalidKey` | `Key 无效或额度不足。请在设置中检查你自己的 API Key。` |
| **错误态（限流/服务/超时）** | `服务暂时不可用，请稍后再试。` |
| **回复截断态** `truncated` | `回复不完整（已达输出上限）。` |
| **流中断态** `streamBroken` | `回复不完整（连接已断开）。` |
| 工具轮次超限 | `本轮工具调用已达上限，已停止继续尝试。` |
| Key 缺位门 | `请先填入你自己的 API Key。AcouDiet 不提供额度，Key 只保存在本机。` |
| 同意门标题 / 主按钮 / 次按钮 | `开启云端智能前，请先读这段` / `我已了解，开启云端智能` / `暂不开启` |
| 撤回入口 | `关闭云端智能并删除本机保存的 Key` |
| 交接卡片标题 | `帮你想好了，去 {platform} 搜「{keyword}」` |
| 交接按钮 | `打开 {platform} 搜索` |
| **未核实平台的次要提示** | `该平台入口尚未在真机上核实，可能打不开。` |
| **已关闭平台** | `该平台入口已关闭。` |
| 上下文裁剪提示 | `本轮上下文已裁剪。` |

**被 `ADR-44` 推翻的既有隐私文案：新措辞在此冻结（逐字）**

`FF-24` 第 4 条修订后，「不申请网络权限」**只对 `offline` 风味成立**，因此原措辞必须按风味重写。

| 常量 / 位置 | 新值（逐字） |
|---|---|
| `UiStrings.privacyNoticeBase` | `音频永不离开设备；音频只在内存中处理，不写入存储；核心功能离线可用；云端智能默认关闭，仅在你同意后使用你自己的 API Key。` |
| `UiStrings.privacyNoticeOfflineSuffix` | `本应用不申请网络权限。` |
| `UiStrings.privacyNotice`（`offline`） | `privacyNoticeBase + privacyNoticeOfflineSuffix` |
| `UiStrings.privacyNotice`（`agent`） | `= privacyNoticeBase`（**不得**追加 `privacyNoticeOfflineSuffix`） |
| `UiStrings.privacyEntrySubtitle`（`offline`） | `查看音频不出设备与无网络权限说明` |
| `UiStrings.privacyEntrySubtitle`（`agent`） | `查看音频不出设备与云端智能的数据出境范围` |
| `UiStrings.privacyEntrySpoken`（两风味） | 逐字等于 `'$privacyTitle，$privacyEntrySubtitle'`（`ADR-38` 的配对规则，随副标题按风味取值） |

> 六处**必然被打破**的既有实现必须在**同一次变更**内一并更新，缺一即回归变红：
> ①`UiStrings.privacyNotice`（`app/lib/presentation/presenters/ui_strings.dart`）；
> ②`UiStrings.privacyEntrySpoken`（同文件）；③`UiStrings.privacyEntrySubtitle`（同文件）；
> ④**`UiStrings.privacyDialogBody`（同文件）** —— ⚠️ **`ADR-44` 实施时补上的第六处，原清单漏了它**。它是检测页首次进入时的一次性提示（`FF-24`），**第二句同样是在陈述"这个包声明了哪些权限"**，因此与 `privacyNotice` 一样必须按风味取值：`offline` → 「…本应用不申请网络权限。」，`agent` → 「…云端智能默认关闭，只在你同意后使用。」。**漏掉它等于把同一条主张留了第二个可以漂移的副本**，而本项目反复修的就是这一类缺陷（`ADR-19` 的属性硬编码、`ADR-21` 的双帧数）。
> ⑤`app/lib/presentation/pages/profile/privacy_notice_page.dart` 的 `Icons.wifi_off_outlined` /「无网络权限」条目——`agent` 风味改为出境范围条目，`offline` 风味保持原条目；
> ⑥`app/tool/ui_presenter_tests.dart` 中 `the privacy notice says there is no network permission` 的断言，改为**按风味参数化**：`offline` → `contains('不申请网络权限')` 为真；`agent` → 该子串**必须不存在**，且两风味都必须含 `音频永不离开设备` 与 `云端智能默认关闭`。
> 上述新措辞已通过 `FF-25` 禁用表述扫描（§7 #4），且**不**引入任何「已合规」类主张。
>
> ⚠️ **为什么 ① 和 ④ 是两条不同的字符串而不是一条**：这是一处**既有的**重复（本轮之前就存在），不是本轮引入的。本轮**没有**把它合并成一个常量 —— 合并会改动 `privacyDialogBody` 的既有措辞（它刻意更短），属于另一次变更。**如实记下来**：同一条隐私主张在本文件里有两个独立副本，二者的风味分支必须**同时**改。合并它可作为后续清理项（§10）。

> 上表每一句都进入 `app/tool/ui_presenter_tests.dart` 的字符串采集，从而被 FF-25 红线扫描覆盖（§7 #4）。

## 5. 参数与常量
| 项 | 引用 |
|---|---|
| 页面数为 5、第 3 页为智能体、设置非独立 Tab | `SPEC-00` §3.8 **FF-23**（`ADR-44` 修订） |
| 云端默认关闭、关闭态与 `offline` 等价 | `SPEC-00` §3.9 **FF-24** 第 9 条；§3.11 **FF-26c** |
| 音频永不离开设备、无 BLOB、无后台 Service | `SPEC-00` §3.9 **FF-24** 第 3/6/8 条 |
| 两个风味与权限集合 | `SPEC-00` §3.9 **FF-24** 第 4/5 条 |
| 外发白名单 / 禁止清单 | `SPEC-00` §3.11 **FF-26d** / **FF-26e** |
| 编排上限（工具轮数、超时、历史条数、请求体上限） | `SPEC-00` §3.11 **FF-26g** |
| 模型名不得硬编码 | `SPEC-00` §3.11 **FF-26h** |
| 交接而非代下单 | `SPEC-00` §3.11 **FF-26i**；`API-07` §3.1 |
| 平台恰好三个 | `SPEC-00` §3.11 **FF-26j** |
| 文案红线与术语禁令 | `SPEC-00` §3.10 **FF-25** |
| 点击区下限 | `AcouTheme.minTapTarget`（`SPEC-U-06` §3） |
| 首次确认耗时口径（对话中若提及检测结果） | `SPEC-00` §3.4 **FF-20a** |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 无网络 / DNS 失败 | `ACD-AGENT-001` | 进 `offline`，不重试 | `当前离线，核心功能可正常使用。恢复网络后可继续对话。` |
| 未同意 | `ACD-AGENT-002` | 进 `unconsented`，**零请求** | 同意门 |
| 无 Key / 形状非法 | `ACD-AGENT-003` | 进 `keyMissing` | Key 缺位门 + 去设置按钮 |
| 401 / 403 | `ACD-AGENT-004` | `failed(invalidKey)`，**不**重试 | `Key 无效或额度不足。…`（不回显 Key） |
| 429 | `ACD-AGENT-005` | 退避至多 1 次，仍失败转 `failed` | `服务暂时不可用，请稍后再试。` |
| 5xx | `ACD-AGENT-006` | 退避至多 1 次 | 同上 |
| 超时 | `ACD-AGENT-007` | 已收内容后**不重试** | `服务暂时不可用，请稍后再试。` + 保留已收内容 |
| 流中途断开 | `ACD-AGENT-008` | 保留已收内容 | `回复不完整（连接已断开）。` |
| 工具不可解析 / 未知工具名 | `ACD-AGENT-009` | 回灌一次解析错误；再失败终止本轮 | `本轮工具调用已达上限，已停止继续尝试。`（终止分支） |
| 超 `max_tool_rounds` | `ACD-AGENT-010` | 终止本轮 | 同上 |
| `finish_reason == length` | 响应字段 | `failed(truncated)` | `回复不完整（已达输出上限）。` |
| 平台不可唤起 | `canOpen == false` | **不**调 `openSearch` | `该平台入口打不开。` |
| 平台 `enabled == false` | SSOT 字段 | 按钮不可点 | `该平台入口已关闭。` |
| 平台 `verifiedOn == null` | SSOT 字段 | 正常渲染 + 次要提示 | `该平台入口尚未在真机上核实，可能打不开。` |
| 凭据文件损坏 | `read() == null` | 视为未配置 | Key 缺位门（**不**崩溃） |
| 用户撤回同意 | 用户点击 | `cancelCurrentTurn()` + 清本机 Key | 回到同意门 |
| 其他页面在用 | — | 本页任一降级**不得**触及 `P-*`/`D-*`/`A-*`/`M-01`~`M-04`/`U-01`~`U-06` | 其他页面行为不变（`FF-26f`） |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 底栏项数**按风味**且 `agent` 风味下 index 2 的标签是 `智能体` | `flutter test test/ui/app_shell_layout_test.dart` 的 `the shell has five tabs and 智能体 is the third` | **默认（`agent`）风味**：`AppShell.tabs.length == 5`；`indexOf(ShellTab.agent) == 2`；`AcouNavBar.labels[2] == '智能体'`；`ShellTab.values.length == 5`。**`offline` 风味**：`AppShell.tabs.length == 4` 且 `tabs` **不含** `ShellTab.agent`、`AcouNavBar.labels.length == 4`（`FF-24` 第 4 条：`offline` 连这个 Tab 都不存在）。**负控（两向）**：把 `tabs` 去掉一项 → 变红；把 `offline` 分支改成 `agent` 的 5 项列表 → 变红。<br>⚠️ **实现约束（`ADR-44` 实施时确定）**：`tabs` 必须是 **`AppShell` 上的公开静态成员**，不能只挂在私有 `_AppShellState` 上 —— 否则这条判据写不出来，而"写不出来的判据"在本项目里等于没有。同时它必须是 **`const`**，因为风味分支要在编译期决定，好让 tree-shaker 把 `offline` 包里整个 agent 页与它的 Tab 一起删掉（`flavour.dart` 的 `acouIsOffline`）。<br>⚠️ **`offline` 那一半必须用第二条命令跑**：`flutter test --dart-define=ACOUDIET_FLAVOUR=offline`。`acouIsOffline` 是**编译期**常量，默认那次 `flutter test` **根本不会编译这个分支** —— 实测：这条分支第一次被编译时，有 **3 个**测试（本文件的两条 + `refresh_and_tab_test` 的一条）无条件假设了 `agent` 风味而失败。`verify_all.ps1` 的那一步与 CI 现在**都跑两遍**。**一条从没被编译过的分支，不算已交付。** |
| 2 | `ADR-44` 修订同一变更内落地（注释 + 断言） | `rg -n "Adding a fifth tab would break a frozen fact\|four-tab shell\|The frozen tab set. Four" app/lib/presentation/pages/shell/app_shell.dart`；`rg -n "is the third tab\|currentIndex,\s*2" app/test/ui/` | 旧注释命中数 **== 0**；`app_shell_layout_test.dart` 的 `记录` 断言由 `currentIndex == 2` 改为 **`== 3`** 且通过；`apple_style_test.dart` 与 `refresh_and_tab_test.dart` 中依赖 Tab 序号的用例同步更新且全绿。**负控**：只改代码不改断言 → 该断言必须变红 |
| 3 | 未同意时 `enabled == false` **且零请求** | `flutter test test/ui/agent_consent_test.dart` 的 `with consent withheld the agent issues zero requests` | `AgentService.enabled == false`；注入的 `FakeTransport.requestCount == 0`。**负控（必须已实测变红）**：把同意态强行置真后同一断言必须失败 |
| 4 | 新字符串进入红线扫描且无禁用表述 | `dart run tool/ui_presenter_tests.dart` | §4.3 的每一句都在采集清单内；`no FF-25 banned wording in any produced string` 通过（命中 `0`）；`app/tool/ui_presenter_tests.dart` 的剪辑形状检查通过 |
| 5 | 交接按钮是**唯一**外部跳转触发点（`ADR-44` 修正） | `test('the handoff button is the only caller of openSearch')` + `flutter test test/ui/agent_consent_test.dart` | ① **运行时语义（这条才是判据）**：跑完一整轮工具调用（含 `propose_takeout_search`）后 `openSearch` 计数 **== 0**；随后**只**点交接卡片按钮一次 → **== 1**。<br>② 文本判据（较弱，仅供参考）：`app/lib/presentation/` 中对 `AgentPlatformLauncher` 的引用只出现在交接按钮的 handler 内。<br>⚠️ **原判据写错了**：它要求 `rg -n "openSearch\|startActivity\|MethodChannel" app/lib/presentation/` 命中 **== 0**。这条**不可能满足** —— 按钮 handler **就是** `agent.launcher.openSearch(...)`，任何调用这个端口的地方都要写出 `openSearch`。把「调用了这个端口」当成违规，等于把「这个功能存在」当成违规。这与 `SPEC-C-06` §7 #12 是**同一个错**（把机制本身当成违规），因此两处都改成**问"从哪里调用、调用了几次"，而不是问"这个词出现过没有"**。<br>**两向负控**：把按钮接线改成工具返回时自动调用 → ① 的 `== 0` 必须变红；把按钮删掉 → `== 1` 必须变红 |
| 6 | 禁止代下单可机械判定 | `rg -n "AccessibilityService\|BIND_ACCESSIBILITY_SERVICE\|performGlobalAction" app/` | 命中数 **== 0**（`FF-26i`）。**负控**：加一行该字符串必须变红 |
| 7 | 三态文案逐字 | `test('empty, error and truncated states match §4.3 verbatim')` | 三个态各自渲染出的文本与 §4.3 逐字符相等 |
| 8 | 平台诚实性三分支 | `test('a disabled platform is not tappable and an unverified one says so')` | `enabled == false` → 按钮 `onPressed == null` 且含 `该平台入口已关闭。`；`verifiedOn == null` → 含 `该平台入口尚未在真机上核实，可能打不开。`；两者均真时不出现上述两句 |
| 9 | 无障碍 | `flutter test test/ui/accessibility_test.dart` 的 agent 段 | 每张卡片有非空 `Semantics` 标签；交接按钮标签含平台名；所有可点元素尺寸 ≥ `AcouTheme.minTapTarget`；焦点顺序 = 渲染顺序 |
| 10 | Key 只以掩码出现 | `rg -n "apiKey" app/lib/presentation/` 与 `test('the key is only ever shown masked')` | 出现位置只允许 `${keyMask}`；`rg -n "sk-" app/lib/presentation/` 命中 **== 0** |
| 11 | 本页不构造请求体 | `rg -n "HttpClient\|dart:io\|utf8.encode" app/lib/presentation/pages/agent/` | 命中数 **== 0**（请求体构造点唯一，`API-05` §13.2） |
| 12 | 回归：其他页面不受影响 | `flutter test test/ui/` 全套 | 退出码 `0`；`test/ui/app_shell_layout_test.dart` 的「底栏不吃屏」用例仍通过（5 项后每格宽度按 `AcouNavBar.tileWidth` 布局，若溢出则该用例变红） |
| 13 | 隐私文案按风味**且五处同步更新** | `dart run app/tool/ui_presenter_tests.dart` 的 `the privacy notice claims no network permission only in the offline flavour` + `flutter test test/ui/mockup_layout_test.dart` | `offline`：含 `不申请网络权限` 且含 `音频永不离开设备`；`agent`：**不含** `不申请网络权限`，且含 `音频永不离开设备` 与 `云端智能默认关闭`；§4.3 的五处旧实现 `rg` 命中数 **== 0**。**负控**：把 `agent` 也拼接 `privacyNoticeOfflineSuffix` 后该断言必须变红 |

## 8. 非功能约束
| 类别 | 约束 |
|---|---|
| 隐私 | 本页**是** `FF-26d`/`FF-26e` 的用户可见面：外发字段仅七类，禁止清单七类；UI 不出现任何音频数值、`cacheDir` 路径、设备标识（`FF-26e`）；不采集位置与网络信息 |
| 合规告知 | 同意门文案与撤回入口由 `SPEC-C-06` 冻结；**不得**把云端说成默认开启，**不得**承诺额度或代购（`FF-26b`） |
| 无障碍 | 每张卡片与交接按钮 `Semantics` 标签；点击区 ≥ `AcouTheme.minTapTarget`；流式追加文本用 `liveRegion` 语义但**必须**节流（避免读屏逐字刷屏） |
| 性能 | 首帧渲染只读同意记录与凭据（不下发请求）；SSE 增量渲染不重建整列表（`ListView.builder` + 按 `index` 定位）【待实测：滚动掉帧率】 |
| 内存 | 会话消息上限按 `FF-26g` 的 `max_history_messages`；`usageInMemory` 不落盘 |
| 设计系统 | 一律复用 `SPEC-U-06` 的 `AcouTheme` 令牌、`AcouPageHeader`/`AcouBrandMark`（顶栏唯一实现）、`AcouScrollEdge`（滚动边缘雾化）与 `state_view.dart` 的 `StateView`/`RefreshableBody` 空/加载/错误模式；**不得**新增第三套样式常量 |

## 9. 裁剪与未做
| 项 | 决定 | 依据 |
|---|---|---|
| 代下单 / 模拟点击 / 代填地址 / 代付 | ❌ **明文禁止**（不是「未实现」）。App 在交接点停止 | `FF-26i` |
| 无障碍服务（`AccessibilityService`） | ❌ 禁止 | `FF-26i`；`FF-24` 第 5 条 |
| 逆向平台私有接口 | ❌ 禁止（违法且随版本失效） | `API-07` §3.1 |
| 第四家及以上外卖平台 | ❌ 不做；平台集合恰好三个 | `FF-26j` |
| 多会话 / 会话列表 / 跨启动会话历史 | ❌ 不做（本页默认不落盘对话文本） | 本 SPEC §1.3 |
| 图片 / 文件 / 语音输入 | ❌ 不做；输入只有文本 | 本 SPEC §1.3 |
| 云端同步 / 埋点上报 / 崩溃上报 / 账号体系 | ❌ 全部不做 | `API-05` §9；`SPEC-C-06` §9 |
| 模型热更新、推理参数 UI、模型选择器 | ❌ 不做 | `API-05` §3.1 |
| `offline` 风味中的本页 | ❌ 不构建（编译期常量分支） | `FF-24` 第 4 条 |
| 反馈打分、点赞点踩、会话导出 | ❌ 不做 | 本 SPEC §1.3 |

## 10. 开放问题
1. **会话文本是否允许本地留存**：本期默认**不落盘**（最小面）。若要加「保留最近 N 轮」开关，需明确它是否属于 `FF-26d` 白名单之外的新存储面，并走 `SPEC-C-03` 变更传播。**待 A+B+C 拍板**。
2. **`记录` Tab 的序号位移对示意图的影响**：`ADR-44` 后底栏为 5 项，早期示意图（`1.png` 等）仍是 4 项。本 SPEC 以 FF-23 修订后的 5 项为准；示意图是否需要出修订版 **待文档负责人确认**。
3. **交接卡片的平台排序**：三个平台的展示顺序（`enabled` 优先？`verifiedOn` 非空优先？）未冻结。本期按 `feature_config.agent` 的数组顺序渲染（确定性、可断言）；**若要改为排序，需先把规则写进 SSOT**。
4. **流式渲染的读屏节流阈值**：【待实测】。设一个节流窗口（如每 ≥500 ms 触发一次 `liveRegion` 更新）需要有真机 TalkBack 实测依据，本期先按「每次 delta 更新但不主动播报」实现。
5. **`base_url` 用户自定义的 UI 边界**：本页不提供该设置项；`SPEC-G-01` §10 #2 登记的安全边界若拍板收紧，本页需同步在 Key 缺位门增加一句说明。**待 A+B+C 拍板**。

**文档结束**

# API-07 智能体与云端接口契约

**上游**：`SPEC-00` §3.11（`FF-26`，`ADR-44`）、§3.9（`FF-24` 第 8/9 条）、§3.10（`FF-25`）；`API-05` §13；`API-00`（跨层约定）；`API-03`（数据访问层）；`API-04`（域服务）
**性质**：本文件同时是**接口规范**与**架构裁定记录**。它回答三个必须先回答的问题：
① **云端走出去的到底是什么数据？** ② **Agent 能做什么、不能做什么？** ③ **工具调用的词表长什么样？**

---

## 1. 分层与所有权（`ADR-44`）

| 层 | 位置 | 职责 | 允许依赖 |
|---|---|---|---|
| **连接层** `G-01` | `app/lib/data/net/**` | 唯一出网点。HTTP/SSE、凭据读写、错误映射 | `dart:io`、`dart:convert`、`dart:async`、`dart:typed_data`。🚫 **不得** import `package:flutter` |
| **编排层** `G-02` | `app/lib/domain/agent/**` | 有界工具循环、注册表、提示词装配、观察格式 | 纯 Dart（`check_l4_usage.py` 会拦 `package:flutter`）。🚫 不得直接引用 `HttpClient`，只能经 `AgentTransport` 端口 |
| **工具层** `G-03` | `app/lib/domain/agent/tools/**` | 四个工具的实现；读 `API-03`/`API-04` 的既有域服务 | 纯 Dart |
| **桥接层** | `app/lib/data/native/agent_bridge.dart` + Kotlin `.../agent/AgentChannelHostAndroid.kt` | 唤起外部 App、查询可唤起性 | `MethodChannel` |
| **表现层** `U-07` | `app/lib/presentation/**` | 对话、卡片、同意门、降级态 | 按 `API-00` §1 |

> 🔴 **单点出网（`R-OUT-4`）**：`app/lib/**` 中只有 `app/lib/data/net/**` 允许出现 `HttpClient` / `Socket` / `WebSocket`。
> `tool/check_network_boundary.py --strict` 是这条的机械判据，**白名单外命中数必须为 0**。

---

## 2. 凭据契约（`FF-26b`）

```dart
abstract class AgentCredentialsStore {
  Future<AgentCredentials?> read();
  Future<void> write(AgentCredentials creds);
  Future<void> clear();
}
```

| 项 | 契约 |
|---|---|
| 载体 | `<filesDir>/agent/credentials.json`，POSIX 模式 `0600`；**不进 SQLite**（`API-03` 不新增表）、**不进 `SharedPreferences`**、**不进 assets** |
| 结构 | `{"apiKey": "<string>", "baseUrl": "<string, 可选>", "savedAtMs": <int>}` |
| 读取失败 | 返回 `null`，**不抛**。原因：损坏的凭据文件必须表现为「未配置」，不能把 App 卡在启动异常上 |
| 掩码 | 任何 UI/日志/诊断只允许出现 `mask(apiKey)` = 前 3 位 + `…` + 后 4 位；`apiKey.length < 8` 时整体显示为 `****` |
| 清除 | `MaintenanceRepo.clearAllData`（`API-03` §7）**必须**一并删除该文件——判据：清除后 `read() == null` |
| 校验 | 写入前做**形状**校验（非空、无空白、长度 ≥ 16、无换行）；**不**做在线校验（在线校验要发一次请求，等于在用户点保存时花他的钱） |

---

## 3. 平台交接契约（`FF-26i`：**不做代下单**）

### 3.1 为什么是「交接」而不是「代下单」

| 路径 | 可行性 | 裁定 |
|---|---|---|
| 三家开放平台的**下单 API** | ❌ 不面向消费端 App：美团/饿了么/淘宝开放平台都要求 ISV 或商家资质与商业合作 | ❌ 不可达 |
| **无障碍服务（AccessibilityService）代操作** | ⚠️ 技术上可行 | ❌ **禁止**。它要求用户授予远超录音的高危权限，与 `FF-24` 第 5 条冲突，且违反三家平台用户协议 |
| **逆向客户端私有接口** | ❌ 违法，随版本失效 | ❌ 禁止 |
| **检索 URL 交接**（本契约采用） | ✅ 无需任何额外权限、不违反任何协议、随平台改版只会「跳首页」而不是「崩溃」 | ✅ **采用** |

> **结论：AcouDiet 的 Agent 在「下单」这一步主动停在交接点，并把这件事做成用户可见的能力，而不是未实现的承诺。**
> 任何对外文案**不得**写「自动下单」「帮你点单」。允许的说法：**「帮你想好点什么，并一键跳到外卖 App 的搜索结果」**。

### 3.2 交接接口

```dart
abstract class AgentPlatformLauncher {
  /// 目标 App 是否可被唤起（Android 11+ 需要 <queries> 声明，见 §3.4）。
  Future<bool> canOpen(String platformId);

  /// 用给定检索词唤起；返回是否成功离开本 App。**必须由 UI 层在用户点击后调用。**
  Future<bool> openSearch({required String platformId, required String keyword});
}
```

### 3.3 平台表（**值在 `feature_config.agent`，此处不复制数字**）

| 字段 | 含义 | 约束 |
|---|---|---|
| `id` | `meituan` / `eleme` / `taobao` | **恰好三个**（`FF-26j`） |
| `label` | 中文名 | 用于按钮 |
| `httpsTemplate` | 检索 URL 模板（**网页**形态），含占位符 `{q}` | **回落路径**。`{q}` 必须 `Uri.encodeComponent` 后替换 |
| `schemeTemplate` | 检索 URL 模板（**App scheme** 形态），含占位符 `{q}` | 🆕 `ADR-45`：**优先**尝试，用来直接唤起已安装的目标 App 而不是落到浏览器。`canOpenUrl` 答否、或 `openUrl` 返回否，都回落 `httpsTemplate`。**未在真机核实过**，`verifiedOn` 同时管辖两条 |
| `enabled` | 是否在 UI 上显示 | 模板在真机上核实失败时置 `false`，**不需要改代码** |
| `verifiedOn` | 真机核实日期（ISO）或 `null` | `null` 表示**未核实**，UI 必须显示「可能打不开」的次要提示 |

**核实义务（`SPEC-G-03` §7 的判据）**：模板必须在一台**真机**上逐条点过，并把日期写回 `feature_config.agent[].verifiedOn`。
**不得**把未核实的模板当成可用功能对外宣称。本契约已知的实测情况：

| 平台 | 本次可得的证据 | 状态 |
|---|---|---|
| `meituan` | `https://i.meituan.com/s/<关键词>` 从开发机请求返回 **HTTP 200**（响应体是风控 JSON，说明路由真实存在，只是拒绝非浏览器 UA） | 路由存在，**真机未核实** |
| `taobao` | `https://s.taobao.com/search?q=<关键词>` 是长期稳定的公开 H5 检索路由 | **真机未核实** |
| `eleme` | `https://www.ele.me/search?keyword=<关键词>` 从开发机请求**跨域跳转到 `taobaoshangou.ele.me`** —— 说明饿了么的 H5 入口已在阿里体系内改道 | ⚠️ **很可能不可用**，`enabled` 默认 `false`，待真机核实后再开 |

### 3.4 Android `<queries>`（package visibility）

Android 11（API 30）起，**查询**目标 App 是否可处理某 URL 需要 `<queries>` 声明；`startActivity` 本身不需要，但「按钮该不该显示」需要。

```xml
<queries>
    <intent><action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" android:host="i.meituan.com" /></intent>
    <intent><!-- ele.me … --></intent>
    <intent><!-- s.taobao.com … --></intent>
</queries>
```

> **`<queries>` 不是权限。** 它不进入 `uses-permission`，因此**不影响** `SPEC-C-01` §7 #1b/#2 的权限集合等式。这条必须写清，否则下一个人会以为它破坏了权限最小化。
> 它只放在 **`agent` 风味**的 manifest overlay 里：`offline` 风味**不查询、不唤起任何外部 App**，因此 `SPEC-C-01` 对 `offline` 的「零外部交互」主张保持不变。

---

## 4. 工具契约（`FF-26i` 的机制落点）

### 4.1 注册表

```dart
abstract class AgentTool {
  String get name;                       // 稳定、显式（技能：Action Space Design）
  String get description;                // 给模型看的、面向选择的说明
  Map<String, Object?> get parameters;   // JSON Schema object
  bool get proposalOnly;                 // true = 只产出卡片，绝不自行执行
  Future<AgentObservation> run(Map<String, Object?> args);
}
```

**词表是闭集**：`G-02` 的注册表**恰好**注册下列四个工具。**未注册的工具在模型侧不存在**——这是「禁止代下单」能成立的机制，而不是靠提示词请求模型别那么做。

| 工具名 | 输入 | 输出 `summary` | 副作用 | `proposalOnly` |
|---|---|---|---|---|
| `get_health_summary` | `{range: "today"｜"week"}` | 四维分数、总分、评级、聚合计数 | 无 | 否 |
| `get_recent_meals` | `{limit: int(1..20)}` | 最近 N 条记录的类别/时间/置信度 | 无 | 否 |
| `recommend_food` | `{avoid?: string[]}` | 基于 `A-02` 规则与 `D-03` 聚合的**建议及其理由** | 无 | 否 |
| `propose_takeout_search` | `{keyword: string, platforms?: string[]}` | 生成 **0..3** 张**待用户点击**的交接卡片；**0 张是合法且诚实的结果**（全部平台在配置中被禁用时），此时 `status` 必须是 `warning` 而不是 `success`——报 `success` 会让模型去提一张不存在的卡片，报 `error` 会让它重试一个不可能成功的请求 | **无**（只产出卡片） | ✅ **是** |

### 4.2 观察格式（固定形状，`API-05` §13.4.2）

每个工具结果回灌给模型时，`content` **必须**是同一形状的 JSON：

```json
{
  "status": "success" | "warning" | "error",
  "summary": "<一行的结果说明>",
  "next_actions": ["<可继续做的事，自然语言>"],
  "artifacts": { "<键>": "<值或 id>" }
}
```

错误时必须额外带三个字段（技能：**Error Recovery Contract**）：

```json
{ "status": "error",
  "summary": "...",
  "next_actions": [],
  "artifacts": {},
  "root_cause_hint": "<为什么会这样>",
  "safe_retry": "<可以安全重试什么，或明确写 'do not retry'>",
  "stop_condition": "<什么情况下必须停止尝试>" }
```

> **为什么形状要固定**：① 模型能稳定解析；② 测试能逐字段断言；③ **只有** `summary` 会进入用户可见的文本，因此「工具说了什么」与「工具返回了什么」可以被分开审查（这是防提示注入进 UI 的一种廉价手段）。

### 4.3 提示注入的处置

`get_recent_meals` 的 `summary` 里会回显**数据库中的字段**——那在本项目里是 App 自己写的枚举类别，风险低；
但 `U-07` **绝不允许**把工具返回的任意文本当作 UI 文案直接渲染：卡片文案由 `U-07` 自己的 `UiStrings` 常量生成，工具返回值只填数值槽位。判据见 `SPEC-U-07` §7。

---

## 5. 云端请求/响应契约（`FF-26a`/`FF-26g`，`API-05` §13）

### 5.1 请求

```
POST {base_url}/chat/completions
Authorization: Bearer <apiKey>
Content-Type: application/json
Accept: text/event-stream
User-Agent: AcouDiet/<versionText>

{
  "model": "<feature_config.agent.model>",     // 代码里不得出现字面量（FF-26h）
  "messages": [ {"role":"system", ...}, {"role":"user", ...}, ... ],
  "tools": [ ...由注册表生成... ],
  "tool_choice": "auto",
  "stream": true,
  "max_tokens": <feature_config.agent.max_output_tokens>,
  "temperature": <feature_config.agent.temperature>
}
```

### 5.2 消息角色

🆕 **`ADR-45`：每一次请求都被包装。** 用户那句话**从不裸发**，而是被 `AgentPromptBuilder.renderBrief()` 包进一份结构化简报：

```
【本轮任务】
<用户原话>

【本地数据（唯一可引用的事实）】
key=value；…（无数据时写「（本轮没有本地数据…）」）

【回答格式】
1) 评估：一句结论（良好 / 需注意 / 需改善）。
2) 建议：1–3 条，每条都能照着做。
3) 数据不足时，只说还需要记录什么。
```

**数据围栏是承重属性**：用户文字在数据段**之前**，App 的聚合在段**之后**，所以用户输入里写的 `totalScore=999` 不可能冒充 App 提供的事实。系统提示词同时**要求**做饮食健康评估（这是这道 App 的职责），七条边界作为**评估范围**而非拒绝理由（`ADR-45`）。

| role | 内容来源（**这是 `FF-26d`/`FF-26e` 的执行点**） | 允许 |
|---|---|---|
| `system` | 代码中的**常量**（`AgentSystemPrompt.text`） | 冻结提示词 + `FF-25` 红线 |
| `user` | ① 用户在 `U-07` 键入的文字；② `G-02` 拼装的白名单结构化摘要 | ✅ |
| `assistant` | 服务端返回 | ✅（回灌历史） |
| `tool` | §4.2 的固定形状 JSON | ✅ |

🚫 **禁止进入任何 message**：PCM 样本、Mel 张量、`Float32List`、`Uint8List`、音频文件路径、设备标识、位置。
构造点**唯一**（`G-02` 的 `AgentPromptBuilder`），因此这条可以被单点审查与单点测试。

### 5.3 响应（SSE）

| 帧 | 处理 |
|---|---|
| `data: {"choices":[{"delta":{"content":"…"}}]}` | 追加显示 |
| `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":…,"function":{"name":…,"arguments":"…"}}]}}]}` | 按 `index` **累积** `arguments` 字符串；**不得**对分片单独 `jsonDecode` |
| `data: {"choices":[{"finish_reason":"tool_calls"}]}` | 执行工具，回灌，进入下一轮 |
| `data: [DONE]` | 结束 |
| `: ` 开头的行 / 空行 | 忽略 |

**字符编码**：SSE 行流必须**跨 TCP 分片缓冲 UTF-8**。逐 chunk `utf8.decode` 会在中文字符被切断时抛 `FormatException`。

### 5.4 上限（`FF-26g`）

单轮工具调用 ≤ `max_tool_rounds`；单请求 `connect/read` 超时见 `FF-26g`；历史 ≤ `max_history_messages`；请求体 ≤ `max_request_bytes`（超出**裁剪历史**，**不放宽上限**）。

---

## 6. 配置契约（SSOT）

`shared/feature_config.json` 新增两个顶层段；`app/assets/feature_config.json` 由 `tool/gen_feature_config.dart` 同步；Dart 常量在 `app/lib/core/feature_config.g.dart`。

| 段 | 键 | 说明 |
|---|---|---|
| `agent` | `enabled_by_default`、`base_url`、`model`、`connect_timeout_ms`、`read_timeout_ms`、`max_tool_rounds`、`max_history_messages`、`max_request_bytes`、`max_output_tokens`、`temperature`、`recommend_keyword_max_chars`、以及**三平台 × 四字段**的展平键（`platform_<id>_label` / `_url` / `_enabled` / `_verified_on`，`<id>` ∈ {`meituan`,`eleme`,`taobao`}） | `model` 是**唯一**允许出现模型名标识符的地方（`FF-26h`）。平台之所以是**展平键而不是对象数组**，见 `SPEC-G-03` §5 的映射表与理由 |

> ⚠️ **这两个段**不参与**启动握手**（`API-00` §3.6 的 15 字段闭集）。原因：`check_bridge_symmetry.py` 把握手字段集断言为**恰好那 15 个**，加字段会红；而这两个段**不改变任何张量语义**，本来就不该进握手。这是一次有意的边界划分，不是遗漏。

---

## 7. 错误码

| 码 | 含义 | 用户可见 |
|---|---|---|
| `ACD-AGENT-001` | 无网络 / DNS 失败 | 「当前离线，核心功能可正常使用」 |
| `ACD-AGENT-002` | 未同意 | 同意门 |
| `ACD-AGENT-003` | 无 Key / Key 形状非法 | 「请先填入你自己的 API Key」+ 入口 |
| `ACD-AGENT-004` | 401 / 403 | 「Key 无效或额度不足」（不回显 Key） |
| `ACD-AGENT-005` | 429 | 「请求过于频繁，请稍后再试」（退避 2 s，至多 1 次） |
| `ACD-AGENT-006` | 5xx | 「服务暂时不可用」（退避 1 s，至多 1 次） |
| `ACD-AGENT-007` | 超时 | 同上；**已收到部分内容后不重试** |
| `ACD-AGENT-008` | 流中途断开 | 保留已收内容 + 「回复不完整」 |
| `ACD-AGENT-009` | 工具调用不可解析 / 未知工具名 | 回灌一次解析错误；仍失败则终止本轮 |
| `ACD-AGENT-010` | 超过 `max_tool_rounds` | 终止本轮并如实告知 |

---

## 8. 版本与兼容

| 项 | 规则 |
|---|---|
| 未知响应字段 | **忽略**（前向兼容）。因服务端新增字段而崩溃，等于把「服务端升级」变成「App 崩溃」 |
| 未知 `finish_reason` | 按 `stop` 处理，并把原文记入内存诊断 |
| 未知工具名 | `ACD-AGENT-009`，**不执行** |
| 服务端改模型名 | 改 `feature_config.agent.model` 即可，**不需要发新版代码**（`FF-26h` 的存在理由） |
| 本契约的破坏性变更 | 走 `SPEC-C-03` 变更传播 |

---

**文档结束**

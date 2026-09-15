# SPEC-G-01 云端连接层与凭据管理

| 项 | 值 |
|---|---|
| 域 | `G` · 智能体与云端智能 |
| 归属 | B |
| 状态 | ✅ v2.0 交付 |
| 上游依据 | `SPEC-00` §3.11（`FF-26a`/`FF-26b`/`FF-26g`/`FF-26h`）、§3.9（`FF-24` 第 8/9 条）；`API-05` §13；`API-07` §1/§2/§5/§7/§8；`ADR-44` |
| 依赖的 SPEC | 无（`SPEC-G-02` 依赖本 SPEC 定义的 `AgentTransport` 端口；`SPEC-C-06` 依赖本 SPEC 的凭据边界） |

## 1. 目标与范围

### 1.1 一句话目标

把「向 DeepSeek 发一次带工具定义的流式对话请求」这件事，收进 `app/lib/data/net/` 一个目录、一个 `dart:io` 实现里，并把 API Key 关进应用私有的 `0600` 文件；**除本 SPEC 之外，全仓不得出现第二个出网点**（`API-05` §3.1 `R-OUT-4`）。

### 1.2 范围内（In Scope）

| # | 内容 | 产物 |
|---|---|---|
| 1 | `AgentTransport` 端口（纯 Dart 接口），G-02 只依赖它 | `app/lib/data/net/agent_transport.dart` |
| 2 | DeepSeek 客户端：`POST {base_url}/chat/completions`、SSE 解析、工具调用分片累积 | `app/lib/data/net/deepseek_client.dart` |
| 3 | 错误映射（`ACD-AGENT-001`~`010`）与**有界**重试（至多 1 次，按 `API-05` §8 第二张表） | 同上 |
| 4 | 凭据存储：`<filesDir>/agent/credentials.json`，模式 `0600`，掩码工具 | `app/lib/data/net/agent_credentials.dart` |
| 5 | 连通性探测（`ACD-AGENT-001` 的判定） | 同上 |
| 6 | 离线套件与负控 | `app/tool/agent_tests.dart` |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

| 不做 | 归属 |
|---|---|
| 工具循环、注册表、提示词装配、历史裁剪 | `SPEC-G-02` |
| 四个工具的实现、检索 URL 的构造 | `SPEC-G-03` |
| 页面、按钮、同意门 UI | `SPEC-U-07` |
| 同意态的判定与合规归档 | `SPEC-C-06` |
| **云同步、账号体系、崩溃上报、分析埋点** | ❌ 不做（`API-05` §9 仍 `DISABLED`） |
| **运行时从网络更新模型 / 知识库 / SSOT** | ❌ 禁（`R-OUT-3`） |
| **引入 `http` / `dio` / `url_launcher` 依赖** | ❌ 禁。`tool/run_offline_tests.py` 的 `PUB_CACHE` 里没有它们，且依赖最小化是 `FF-23` 的设计选择 |
| 代理、中转、自建服务端 | ❌ 禁（`FF-26a`） |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 触发 | 仅由 `G-02` 的编排循环调用 `AgentTransport.send(...)` |
| 前置 | ① `SPEC-C-06` 的同意态为真；② `read()` 返回非空且形状合法的凭据。二者缺一，**不构造请求**，直接返回对应错误 |
| 前置 | `base_url` 取自 `feature_config.agent.base_url`；用户可在设置覆盖，覆盖值同样存于凭据文件 |
| 不触发 | `offline` 风味：本 SPEC 的实现不参与装配（`AgentService.enabled` 恒 `false`） |

### 2.2 主流程（编号步骤）

1. 组装请求体（`messages` / `tools` 由 `G-02` 传入；`model` / `max_tokens` / `temperature` 由本层从 SSOT 常量填入）。
2. 断言 `utf8.encode(body).length <= max_request_bytes`；超限 → 由 `G-02` 负责裁剪历史，本层**直接抛 `AgentError`**（不放宽上限）。
3. 解析 `base_url`，`HttpClient` 设置 `connectionTimeout`；发 `POST`，设 `Authorization` / `Content-Type` / `Accept: text/event-stream` / `User-Agent: AcouDiet/<versionText>`。
4. 逐 `HttpClientResponse` chunk 累积到 `List<int>` 缓冲区；按 `\n` 切行；**行不完整则留到下一 chunk**。
5. 每行：空行或 `:` 开头 → 忽略；以 `data: ` 开头 → 取 `[5..]`；`[DONE]` → 结束。
6. 对 payload 做 `jsonDecode`；`utf8` 解码**在完整行上做**，不是逐 chunk 做（`API-05` §13.1.6）。
7. 累积 `delta.content` → 以 `Stream<String>` 的语义交给 `G-02`；累积 `delta.tool_calls[i]` 的 `id`/`name`/`arguments` 字符串（**按 `index` 合并，不逐片解析**）。
8. 见 `finish_reason`：`tool_calls` → 产出完整工具调用列表；`stop` → 正常结束；`length` → 标记截断。
9. 关闭连接（`client.close(force: true)`），释放缓冲区。

### 2.3 状态与状态迁移

| 状态 | 含义 | 允许的下一状态 |
|---|---|---|
| `idle` | 无在途请求 | `connecting` |
| `connecting` | 已建立 socket，等首个字节 | `streaming` / `failed` |
| `streaming` | 收到过至少一个 `data:` 帧 | `completed` / `failed`（部分保留） |
| `completed` | 收到 `[DONE]` 或 `finish_reason` | `idle` |
| `failed` | 映射为某个 `ACD-AGENT-*` | `idle` |

**不变量**：`streaming` 之后**不得**触发任何重试（`API-05` §13.1.8）——已收到的 delta 若重放会导致重复扣费与重复输出。

### 2.4 边界条件

- `base_url` 结尾的 `/` 必须归一化（`https://api.deepseek.com/` 与 `https://api.deepseek.com` 等价）。
- 用户把 `base_url` 填成非 `https` → **拒绝**，报 `ACD-AGENT-003`。理由：`usesCleartextTraffic="false"`，明文请求在真机上必然失败，报一个可解释的形状错误好过报一个网络错误。
- 单行超过 `max_request_bytes`（服务端可能返回超长行）→ 中止并列 `ACD-AGENT-008`，**不得**无限增长缓冲区。
- 响应头 `Content-Type` 不是 SSE → 仍尝试按 SSE 解析，全无 `data:` 行时按 `ACD-AGENT-008` 处理。
- 凭据文件损坏 / 非法 JSON → `read()` 返回 `null`（**不抛**），表现为「未配置」。
- 凭据文件权限位无法设置（Windows / 某些真机）→ **不失败**，但记入内存诊断并在 `SPEC-C-06` 的自检项里如实报告。

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| G-02 → G-01 | `AgentTransport.send(AgentRequest)` | `{messages, tools, signal}` | `Stream<AgentDelta>` | `ACD-AGENT-001`~`008` |
| G-01 → 磁盘 | `AgentCredentialsStore.read()` | — | `AgentCredentials?`（`null` = 未配置） | 无（损坏即 `null`） |
| G-01 → 磁盘 | `AgentCredentialsStore.write(creds)` | 形状合法的凭据 | `void` | `ACD-AGENT-003`（形状非法时抛） |
| G-01 → 磁盘 | `AgentCredentialsStore.clear()` | — | `void` | 无 |
| G-01 → 网络 | `AgentConnectivity.probe()` | — | `bool` | 无（探测失败即 `false`） |
| 工具 | `maskApiKey(String)` | Key | 前 3 + `…` + 后 4；长度 `< 8` 时 `****` | 无 |

`AgentDelta` 是闭集，**恰好**四个成员（`sealed class` + `switch` 穷尽）：
`AgentTextDelta(String text)` ｜ `AgentToolCallDelta(AgentToolCall call)` ｜ `AgentFinished(AgentFinishReason reason)` ｜ `AgentFailed(AcouDietError error)`。

## 4. 数据契约

| 载体 | 字段 | 约束 |
|---|---|---|
| `credentials.json` | `apiKey` | `String`，非空、无空白符、无换行、长度 ≥ 16 |
| | `baseUrl` | `String?`；非空时必须 `https://` 开头 |
| | `savedAtMs` | `int` |
| 无 SQLite 表 | — | 本 SPEC **不新增**任何表、不改 `API-03`（判据：`SPEC-D-01` 的 Schema 断言不变） |
| 无新 schema 文件 | — | `docs/common/docs_api/schemas/` 不新增文件；凭据不是可校验契约 |

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 端点、模型标识、超时、上限 | `SPEC-00` §3.11（`FF-26a`/`FF-26g`/`FF-26h`）+ `feature_config.agent` |
| 重试语义与退避 | `API-05` §8 第二张表 |
| SSE 帧与消息角色 | `API-07` §5 |
| 错误码 | `API-07` §7 |

> 本文档**不复写任何数值**。需要数字时引用上表。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 无网络 / DNS | `SocketException` | 不重试 | `ACD-AGENT-001`：「当前离线，核心功能可正常使用」 |
| 未同意 | `SPEC-C-06` 的同意态 | 不构造请求 | 同意门（`U-07`） |
| 无 Key / 形状非法 | `read()` 为 `null`，或 `write` 校验失败 | 不构造请求 | `ACD-AGENT-003` + 设置入口 |
| 401 / 403 | HTTP 状态码 | 不重试 | `ACD-AGENT-004`「Key 无效或额度不足」；**不回显 Key、不写日志** |
| 429 | HTTP 状态码 | 退避 1 次（±`Retry-After`） | 第二次仍 429 → `ACD-AGENT-005` |
| 5xx | HTTP 状态码 | 退避 1 次 | `ACD-AGENT-006`「服务暂时不可用」 |
| 超时 | `TimeoutException` | 仅 `streaming` 之前重试 1 次 | `ACD-AGENT-007` |
| 流中途断开 | chunk 结束但无 `[DONE]` | 不重试 | `ACD-AGENT-008`「回复不完整」，保留已收内容 |
| UTF-8 跨片截断 | 解码前的行缓冲 | 缓冲到完整行再解码 | 无（这是实现正确性，不是用户可见异常） |
| 工具调用 JSON 不完整 | `jsonDecode` 抛 | 抛给 `G-02` | `ACD-AGENT-009` |

**核心链路不受影响**：本 SPEC 的任何失败路径都**不得**抛出到 `P-*`/`D-*`/`A-*`/`M-*`/`U-01`~`U-06` 的调用栈上（`FF-26f`）。

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 出网单点 | `python tool/check_network_boundary.py --strict` | 白名单外命中 `0`；负控（白名单外放 `HttpClient`）必须变红 |
| 2 | SSE 跨片 UTF-8 正确 | `app/tool/agent_tests.dart` 的 `sse splits a multibyte character across chunks` | 拼接结果逐字符等于期望；**负控**：改成逐 chunk 解码后该用例必须抛 `FormatException` |
| 3 | 工具调用按 `index` 合并且不逐片解析 | 同文件 `tool_calls fragment accumulation` | 得到一个 `name` 与一条完整 `arguments` JSON；**负控**：对每片单独 `jsonDecode` 必须失败 |
| 4 | 不在 `streaming` 后重试 | 同文件 `no retry after first delta` | 计数器 == 1；**负控**：允许重试后计数器变 2，用例变红 |
| 5 | 重试次数有界 | 同文件 `retries are bounded` | 429/5xx 各至多 1 次 |
| 6 | 超限请求体被拒 | 同文件 `request over the byte cap is refused` | 抛 `AgentError`；**负控**：放宽上限后该用例变红 |
| 7 | 明文 `base_url` 被拒 | 同文件 `http base url is refused` | `ACD-AGENT-003` |
| 8 | 凭据损坏表现为未配置 | 同文件 `corrupt credentials read as null` | `read() == null`，不抛 |
| 9 | Key 掩码 | 同文件 `mask` 的三个分支 | `sk-abcdef1234` → `sk-…1234`；长度 7 → `****`；长度 0 → `****` |
| 10 | 凭据不落 SQLite | `python tool/verify_artifacts.py` 与 `SPEC-D-01` 的 Schema 断言 | Schema 与 `ADR-44` 之前逐字相等 |
| 11 | 模型名不硬编码 | 搜索 `deepseek-flash` 于 `app/lib/**` | 命中 `0`（`FF-26h`） |
| 12 | 音频类型不出现在网络层 | `python tool/check_audio_egress.py --strict` | 静态命中 `0`；负控必须变红 |

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 隐私 | `FF-24` 第 8 条对本地是**无条件**的：本层**只**发送 JSON 文本，不接受任何二进制入参（类型签名即约束：`AgentRequest.messages` 的元素类型不含 `Uint8List`） |
| 依赖 | **零新增 pub 依赖**。`dart:io` + `dart:convert` + `dart:async` |
| 层纯净 | `app/lib/data/net/**` 不得 import `package:flutter`（`check_l4_usage.py` 只查 L3/L4，本目录不在其管辖内，但这条由 `check_network_boundary.py` 的白名单语义与代码审查共同保证） |
| 内存 | 单请求缓冲区上限 `max_request_bytes`；超出即中止（`§2.4`） |
| 功耗 | 无轮询、无后台常驻。请求只在用户按下发送时发生（`FF-24` 第 6 条） |
| 无障碍 | 不涉及（UI 在 `SPEC-U-07`） |

## 9. 裁剪与未做

| 项 | 决定 | 依据 |
|---|---|---|
| 云同步 | ❌ 不交付 | `API-05` §9 仍 `DISABLED` |
| 账号体系 | ❌ 不交付 | `X-01` 仍在裁剪登记里 |
| 崩溃上报 / 分析埋点 | ❌ 不交付 | `ADR-44` 未放开这一条 |
| 模型热更新 | ❌ 不交付 | `R-OUT-3` |
| 流式函数调用之外的**非流式**模式 | ⚠️ 实现保留 `stream=false` 分支仅为测试可注入，**生产只走 `stream=true`** | 判据 #2/#3 需要可控帧序列 |

## 10. 开放问题

| # | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| 1 | 真机 TLS 证书链与代理环境下的行为【待实测】 | 现场演示（`M-*`）失败风险 | B |
| 2 | `base_url` 允许用户自定义，等于允许把 Key 发到任意主机——是否应限制为白名单域名 | 安全 | A+B+C（本 SPEC 取「允许 + 显式警示」，见 `U-07` 文案） |
| 3 | DeepSeek 的 `strict` 模式需要 `/beta` base 与 `additionalProperties:false` 的全 `required` 对象；是否采用 | 工具参数可靠性 vs 与 beta 端点的耦合 | B（本 SPEC 取「不采用」，理由：`strict` 属于 beta，不稳定契约不应进入交付路径） |

**文档结束**

# SPEC-G-02 智能体编排与工具契约

| 项 | 值 |
|---|---|
| 域 | `G` · 智能体与云端智能 |
| 归属 | B |
| 状态 | ✅ v2.0 交付 |
| 上游依据 | `SPEC-00` §3.11（`FF-26d`/`FF-26e`/`FF-26g`/`FF-26h`/`FF-26i`/`FF-26j`）、§3.9（`FF-24` 第 8/9 条）、§3.10（`FF-25`）；`API-07` §1/§4/§5/§7/§8；`API-05` §13；`ADR-44`；`ADR-26`（`has_number` 护栏族） |
| 依赖的 SPEC | `SPEC-G-01`（`AgentTransport` 端口与错误码来源）、`SPEC-G-03`（四个工具的实现）；下游 `SPEC-U-07` |

## 1. 目标与范围

### 1.1 一句话目标

在 `SPEC-G-01` 的 `AgentTransport` 端口之上实现一个**有界的** ReAct / 函数调用编排循环：**恰好四个工具的闭集注册表**、**全仓唯一的消息装配点**、固定形状的观察回灌、可逐条枚举的状态机；「不代下单」由**注册表闭集**保证，而不是靠提示词请求模型自觉。

### 1.2 范围内（In Scope）

| # | 内容 | 权威依据 |
|---|---|---|
| 1 | 工具循环与轮次上限 | `FF-26g`（`max_tool_rounds`） |
| 2 | 工具注册表：**恰好四个工具名**；未注册的工具在模型侧不存在 | `API-07` §4.1 |
| 3 | `AgentPromptBuilder`：唯一装配 `messages` 的位置；`FF-26d` 白名单断言 + `FF-26e` 禁止清单断言 + 数值数组长度护栏 | `API-07` §5.2 |
| 4 | 系统提示词常量（含 `FF-25` 红线）与 `has_number` 护栏 | `ADR-26` 判据族 |
| 5 | 历史裁剪到 `max_history_messages`，**丢弃最旧的非 system 消息** | `FF-26g` |
| 6 | 观察形状 `{status, summary, next_actions, artifacts}` + 三个错误字段 | `API-07` §4.2 |
| 7 | 状态机 `idle → building → awaitingModel → toolCalls →（循环）→ rendering → idle ｜ failed` | 本 SPEC §2.3 |
| 8 | 离线纯 Dart 套件 `app/tool/agent_tests.dart` 及其负控 | `SPEC-C-05` |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

| 不做 | 归属 |
|---|---|
| 出网、SSE 解析、超时、重试、凭据读写 | `SPEC-G-01`。**本 SPEC 的任何文件都不得出现 `HttpClient` / `Socket` / `WebSocket`**，只依赖 `AgentTransport` |
| 四个工具的业务实现、检索 URL 的构造与编码 | `SPEC-G-03` |
| 页面、气泡、卡片渲染、同意门、平台按钮 | `SPEC-U-07` |
| 同意态判定与合规归档 | `SPEC-C-06` |
| 重算四维分数、总分、评级、聚合 | ❌ 一律读 `API-04`/`API-03` 既有输出；本 SPEC 不得出现 `FF-22` 的任一公式 |
| 代下单及其四条禁用路径（无障碍代操作、模拟点击、代填地址、代扣款） | ❌ 禁（`FF-26i`） |
| 多智能体、规划器、长期记忆库、向量检索、代码执行、任意 URL 抓取 | ❌ 不做（`ADR-44` 未放开） |
| 在代码中出现模型标识符字面量 | ❌ 禁（`FF-26h`） |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 触发 | 仅由 `SPEC-U-07` 的一次**用户轮次**发起；不存在定时、后台或重连触发的轮次 |
| 前置 ① | `SPEC-C-06` 的同意态为真 |
| 前置 ② | `SPEC-G-01` 的 `read()` 返回**非空且形状合法**的凭据 |
| 前置 ③ | 四个工具的注册表**已完成且恰好四项**；少于/多于四项 → 构造期失败，循环不启动 |
| 前置 ④ | 系统提示词为**编译期常量**，非运行时拼接 |
| 不触发 | `offline` 风味：本 SPEC 的实现不参与装配（`FF-24` 第 4/9 条） |

> 前置 ①② 不满足时**不构造请求**，直接以 `SPEC-G-01` 的错误码结束本轮；本 SPEC 不重复判断网络与凭据。

### 2.2 主流程（编号步骤）

1. 进入 `building`：调用 `AgentPromptBuilder.build(userText, history, tools)` 装配 `messages` 与 `tools[]`。
2. **装配期断言**（任一失败 → `failed`，不发出请求）：① 每条消息的字段名 ∈ `FF-26d` 白名单；② 不出现 `FF-26e` 禁止清单的任何载体类型与路径字符串；③ **任何消息字段不得含长度 ≥ `G-02-K1` 的 `List<num>`**；④ 系统提示词通过 `has_number` 护栏。
3. 断言最终请求体 `utf8.encode(body).length <= max_request_bytes`（`FF-26g`）；超限先**裁剪历史**（丢最旧非 system），裁剪后仍超限 → 终止本轮并如实告知，**不放宽上限**。
4. 进入 `awaitingModel`：调用 `AgentTransport.send(...)`，累积文本 delta 与工具调用分片（分片合并在 `SPEC-G-01` 内完成）。
5. `finish_reason == tool_calls` → 进入 `toolCalls`：对**累积完成**的 `arguments` 做 `jsonDecode`。
6. 逐个工具名查注册表：**未注册的名字一律不执行**，返回 `ACD-AGENT-009` 并把固定形状的错误观察回灌**一次**；仍不可解析 → 终止本轮。
7. 执行已注册工具（`proposalOnly == true` 的工具**只产出卡片**，见 `FF-26i`）→ 得到观察 JSON → 追加 `role:"tool"` 消息 → `round++`。
8. `round > max_tool_rounds` → `ACD-AGENT-010`，终止本轮并如实告知（`FF-26g`：不得静默续跑）。
9. `finish_reason == stop` → 进入 `rendering`，把文本与卡片交 `SPEC-U-07` → `idle`。
10. 任一 `AgentFailed` → `failed`，错误码透传，随后回 `idle`；**不得**把异常抛到 `P-*`/`D-*`/`A-*`/`M-*`/`U-01`~`U-06` 的调用栈上（`FF-26f`）。

### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）

**有状态**（一个用户轮次 = 一次状态机实例；实例之间不复用）。

| 当前状态 | 事件 | 下一状态 | 副作用 |
|---|---|---|---|
| `idle` | 用户轮次开始且前置全部满足 | `building` | 新建实例 |
| `idle` | 任一前置不满足 | `failed` | 置错误码，不构造请求 |
| `building` | 装配期断言全部通过 | `awaitingModel` | 发出请求 |
| `building` | 任一条断言失败 | `failed` | 错误码 + 内存诊断 |
| `awaitingModel` | `AgentTextDelta` | `awaitingModel` | 追加已显示文本 |
| `awaitingModel` | `finish_reason == tool_calls` | `toolCalls` | 固定 `arguments` |
| `awaitingModel` | `finish_reason == stop` | `rendering` | 收束文本 |
| `awaitingModel` | `AgentFailed` | `failed` | 错误码透传 |
| `toolCalls` | 工具名已注册且执行成功 | `awaitingModel` | `round++`；回灌观察 |
| `toolCalls` | 工具名未注册 / 参数不可解析（首次） | `awaitingModel` | `ACD-AGENT-009` 回灌一次解析错误 |
| `toolCalls` | 同上（第二次） | `failed` | `ACD-AGENT-009` |
| `toolCalls` | `round >= max_tool_rounds` 后仍需调用工具 | `failed` | `ACD-AGENT-010` |
| `rendering` | 交付完成 | `idle` | 释放实例（含已收文本） |
| `failed` | 交付错误态完成 | `idle` | 释放实例 |

**不变量**：① `rendering` 与 `failed` 是**本轮唯一两个终态**，二者互斥；② `toolCalls` **只能**由 `awaitingModel` 进入，因此不可能出现工具循环脱离模型响应自发继续；③ `round` 单调递增，**不存在重置路径**；④ 任何终态之后不得再产生工具调用。

### 2.4 边界条件

| # | 场景 | 处理（确定性） |
|---|---|---|
| 1 | 模型连续 7 轮都请求工具 | 执行第 `max_tool_rounds` 轮后以 `ACD-AGENT-010` 终止；**多余的工具调用不执行**（`FF-26g`） |
| 2 | 同一轮返回多个 `tool_calls` | **串行**执行，按模型给出的 `index` 升序；本轮整体只计 1 轮 |
| 3 | 工具调用 `arguments` 为 `""` 或 `null` | 按「无参对象」处理；若该工具必填参数缺失 → 固定形状的 `status:"error"` 观察，**不抛异常** |
| 4 | 历史已达 `max_history_messages` | 追加新消息前先丢**最旧的**非 system 消息；**system 消息永不被裁剪**（`FF-26g`） |
| 5 | 历史中只剩 system 消息且请求体仍超限 | 终止本轮并如实告知；**不得**截断 system 提示词 |
| 6 | 消息字段中出现数值数组 | 长度 `< G-02-K1` 允许；`>= G-02-K1` → 装配期失败（该数组只可能是张量/波形，属 `FF-26e`） |
| 7 | 工具返回 `summary` 含用户可见文本 | 只回灌给模型；**`SPEC-U-07` 不得直接渲染**（`API-07` §4.3） |
| 8 | `finish_reason` 为未知值 | 按 `stop` 处理，原文记入**内存**诊断（`API-07` §8） |
| 9 | 服务端返回未知响应字段 | 忽略（前向兼容，`API-07` §8） |

## 3. 接口契约

> 只写与本功能直接相关的契约；完整签名以对应 `API-0x` 为准（见 `docs/*/docs_api/`），此处给「本功能用到的部分」并标注 API 编号。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| G-02 → G-01 | `AgentTransport.send(AgentRequest)` | `{messages, tools, signal}` | `Stream<AgentDelta>` | `ACD-AGENT-001`~`008` 透传（`API-07` §7） |
| G-02 → 注册表 | `AgentToolRegistry.register(AgentTool)` | 工具实例 | `void` | 名字不在闭集 / 重复注册 → 抛（构造期） |
| G-02 → 注册表 | `AgentToolRegistry.toJsonSchemas()` | — | `List<Map>`（**恰好 4 项**，供 `tools[]`） | 无 |
| G-02 → 工具 | `AgentTool.run(args)` | `Map<String, Object?>` | `AgentObservation` | `ACD-AGENT-009` |
| G-02 → L5 | `AgentTurnResult` | — | `{text, cards, error, rounds}` | `ACD-AGENT-010` |
| L5 → G-02 | `AgentSession.send(String userText)` | 用户键入文本 | `Future<AgentTurnResult>` | 同上 |

- `AgentToolRegistry` 的 `register` 对**闭集之外的名字**与**重复名字**都必须在构造期失败：这是「不代下单」的**机制**（`API-07` §4.1），不是一条约束语句。
- `AgentDelta` 是 `SPEC-G-01` 定义的 sealed 闭集（恰好四个成员），本 SPEC 用穷尽 `switch` 消费，**不得**新增成员。

## 4. 数据契约

| 载体 | 字段 | 类型 / 约束 |
|---|---|---|
| 消息 | `role` | 闭集：`system` / `user` / `assistant` / `tool`（`API-07` §5.2） |
| 消息 | `content` | **`String` only**；不得为 `Uint8List` / `Float32List` / 文件路径 |
| 工具定义 | `name` / `description` / `parameters` / `proposalOnly` | `String` / `String` / JSON Schema object / `bool`（`API-07` §4.1） |
| 观察 | `status` | 闭集：`success` / `warning` / `error` |
| 观察 | `summary` | `String`，单行 |
| 观察 | `next_actions` | `List<String>`，可为空 |
| 观察 | `artifacts` | `Map<String, Object?>` |
| 观察（仅 `error`） | `root_cause_hint` / `safe_retry` / `stop_condition` | `String`；三者**必须同时出现**（`API-07` §4.2） |
| `AgentTurnResult` | `rounds` | `int`，`0 <= rounds <= max_tool_rounds` |

- **不新增 schema 文件**：`docs/common/docs_api/schemas/` 不新增文件；观察与卡片结构不是可校验契约。
- **不新增 SQLite 表**：本 SPEC 不触碰 `API-03` 的 Schema。
- **外发字段白名单**（`FF-26d`）：装配进 `messages` 的结构化字段名必须落在 `FF-26d` 七类之中；`FF-26e` 的任何载体类型与路径字符串在装配期即被拒绝。

## 5. 参数与常量

> 逐项引用 `SPEC-00` §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。

| 引用 | 用途 |
|---|---|
| `FF-26g` | 工具轮次上限、连接/读超时、历史条数上限、请求体字节上限；**超限即终止并如实告知** |
| `FF-26d` | 外发数据白名单（七类）——装配期字段名判据 |
| `FF-26e` | 外发数据禁止清单——装配期类型/路径判据 |
| `FF-26h` | 模型标识符不得出现在 Dart/Kotlin 源码 |
| `FF-26i` | `proposalOnly` 语义；代下单四条禁用路径 |
| `FF-25` | 系统提示词与全部用户可见文案的红线词表 |
| `API-07` §4.2 | 观察 JSON 的固定形状与三个错误字段 |
| `API-07` §4.1 | 四个工具名（**闭集**）与各自参数 |
| `API-07` §7 | `ACD-AGENT-*` 错误码 |

**表 G-02-T1 本域新增常量（`FF` 未定义；`G-02-K1` 与 `G-02-K2` 在此冻结，其余为工程常量）**

| 编号 | 常量 | 取值 | 理由 / 约束 |
|---|---|---|---|
| `G-02-K1` | 单条消息数值数组长度上限 | `1024`（**在此冻结**） | 长度 ≥ 1024 的 `List<num>` 只可能是 Mel 张量、包络或波形（`FF-26e`）；合法业务数组（四维分数 4 项、聚合计数 6 项）远低于该值，误杀风险为零 |
| `G-02-K2` | 工具注册表项数 | **恰好 4**（在此冻结为该值的**等式判据**） | `API-07` §4.1 的闭集；工具名不在此冻结（名字权威在 `API-07` §4.1） |
| `G-02-K3` | 解析错误观察回灌次数 | `1` | `API-07` §7 `ACD-AGENT-009` 的「回灌一次」 |
| `G-02-K4` | 系统提示词字符数上限 | `4000` | 提示词是编译期常量，超长即装配缺陷；由构建期测试断言 |
| `G-02-K5` | 同轮多 `tool_calls` 的执行顺序 | `index` 升序、**串行** | 避免同一轮内对同一域服务产生并发写入；见 §10 OQ-G02-2 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 未同意 | `SPEC-C-06` 同意态为假 | 不启动循环 | 同意门（`SPEC-U-07`） |
| 无 Key / Key 形状非法 | `SPEC-G-01` 错误码 | 不启动循环 | 「请先填入你自己的 API Key」+ 入口 |
| 无网络 / DNS 失败 | `ACD-AGENT-001` 透传 | 终止本轮 | 「当前离线，核心功能可正常使用」 |
| 401/403/429/5xx/超时 | `ACD-AGENT-004`~`007` 透传 | 终止本轮 | `API-07` §7 对应文案 |
| 流中途断开 | `ACD-AGENT-008` | 保留已收文本 + 标注不完整 | 「回复不完整」 |
| 工具名未注册 / 参数不可解析 | 注册表查询 / `jsonDecode` 抛 | 回灌一次解析错误；仍失败 → 终止 | 终止时如实告知，**不执行未注册工具** |
| 超 `max_tool_rounds` | `round` 计数 | 终止本轮 | 「本轮请求步骤过多，已停止」 |
| 请求体超字节上限 | `utf8.encode(body).length` 判定 | 先裁历史；仍超 → 终止 | 「对话过长，请开启新一轮」 |
| 装配期出现禁止载体 / 超长数值数组 | 装配期断言 | 终止本轮，记内存诊断 | 与「本轮无法完成」一致的降级态 |
| 系统提示词触发 `has_number` 护栏 | 构建期测试 | **构建失败**（视为实现缺陷） | 不进入现场 |

**核心链路不受影响**：本 SPEC 的全部失败路径都**不得**抛出到 `P-*`/`D-*`/`A-*`/`M-*`/`U-01`~`U-06`（`FF-26f`）。

## 7. 验收标准（可机器判定）

**统一入口**：`app/tool/agent_tests.dart`（纯 Dart 离线套件，任一断言失败即 **exit 非 0**），并作为**一个步骤**加入 `tool/verify_all.ps1`。
每条**新闸门**都带负控，且负控必须被证明**会变红**（本项目规则：**不会红的闸门不是闸门**）。

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 注册表是闭集 | `agent_tests.dart` → `registry has exactly four tools` | `toJsonSchemas().length == 4` 且名字集合逐字等于 `API-07` §4.1 四名。**负控**：注入名为 `place_order` 的工具 → `register` 必须拒绝；放开闭集校验后该工具会出现在 `tools[]`，用例变红 |
| 2 | 未注册工具不被执行 | 同文件 → `unknown tool name is not executed` | 执行计数 `0`，返回 `ACD-AGENT-009`。**负控**：把注册表查询改成「未命中则跳过校验直接执行」→ 计数变 1，用例变红 |
| 3 | 外发白名单断言 | 同文件 → `builder rejects a field outside FF-26d` | 白名单外字段名 → `build` 抛；**负控**：删掉白名单断言 → 该输入构造成功，用例变红 |
| 4 | 外发禁止清单断言 | 同文件 → `builder rejects FF-26e carriers` | 含 `Float32List`/音频路径/设备标识形状的输入 → 抛；**负控**：删掉禁止清单断言 → 用例变红 |
| 5 | 超长数值数组被拒 | 同文件 → `builder rejects a 4096-length List<double>` | 长度 `4096` 的 `List<double>` → 抛；长度 `4` 的 `List<double>`（四维分数）→ **正常通过**。**负控**：把 `G-02-K1` 判据删掉 → 4096 用例变红 |
| 6 | 系统提示词数字护栏 | 同文件 → `system prompt has no invented number` | `has_number(AgentSystemPrompt.text) == false`；含数字的提示词变体 → 校验失败。**负控**：往提示词塞一个凭空数字 → 用例变红 |
| 7 | 历史裁剪保留 system | 同文件 → `history trimming drops oldest non-system` | 灌入 `max_history_messages + 5` 条 → 结果条数恰为上限，且 `role == "system"` 的消息**全部保留**。**负控**：改成裁剪最旧消息（含 system）→ system 计数下降，用例变红 |
| 8 | 轮次上限是硬终止 | 同文件 → `tool loop stops at max_tool_rounds` | 桩模型每轮都请求工具 → 实际执行轮数 **恰为上限**，终态 `failed` 且错误码为 `ACD-AGENT-010`。**负控**：把上限判断删掉 → 轮数 > 上限，用例变红 |
| 9 | 请求体上限只裁历史不放宽 | 同文件 → `oversized body trims history and never exceeds the cap` | 构造超限输入 → 发出的 `body` 字节数 `<= max_request_bytes`；不可裁剪到合规时 → 终止且**未发出**请求 |
| 10 | 状态机迁移穷尽且无非法边 | 同文件 → `state machine transitions are exhaustive` | 逐条断言 §2.3 表中每个「当前状态 × 事件」的下一状态；未列出的组合一律进入 `failed`。**负控**：允许 `toolCalls → toolCalls` 自环 → 用例变红 |
| 11 | 观察形状固定 | 同文件 → `observation shape is fixed` | 四个必需字段齐全；`status=="error"` 时三个错误字段同时存在；非 `error` 时三者不得出现 |
| 12 | 模型标识符不硬编码 | `python tool/` 下的文本检索步骤（并入 `verify_all.ps1`） | `FF-26h` 的标识符在 `app/lib/**` 命中 **0**（`SPEC-G-01` §7 #11 同判据） |
| 13 | 层纯净（L4 无 Flutter） | `python tool/check_l4_usage.py --strict` | exit `0`；`app/lib/domain/agent/**` 中 `package:flutter` 命中 `0`。**负控**：加一行 `import 'package:flutter/material.dart';` → 该步必须 exit 非 0 |
| 14 | 网络单点 | `python tool/check_network_boundary.py --strict` | 白名单外命中 `0`；`app/lib/domain/agent/**` 中 `HttpClient`/`Socket`/`WebSocket` 命中 `0` |
| 15 | 红线词表 | `agent_tests.dart` → `prompt and card strings avoid FF-25 terms` | 系统提示词与 `proposalOnly` 工具产出的卡片文案对 `FF-25` 词表命中 `0`。**负控**：往卡片文案塞入词表内一个词 → 用例变红 |
| 16 | 套件确实接在总闸门上 | `pwsh -File tool/verify_all.ps1` | stdout 出现该套件的步骤名且**步骤总数 +1**；该套件失败时总闸门 exit 非 0。**负控**：把该步骤的 `Invoke-Step` 注释掉 → 步骤总数回到旧值，用例（步骤清单断言）变红 |

> 判据 #16 是**对闸门自身的闸门**：本项目已两次出现「检查器假阳性 / 闸门从不运行」的缺陷（`ADR-31`、`ADR-35`），因此「套件被接进总闸门」必须有可判定的证据，而不是写在文档里的承诺。

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 语言与层 | **纯 Dart**。`app/lib/domain/agent/**` 不得 import `package:flutter`；不得直接引用 `HttpClient`（只经 `AgentTransport`） |
| 依赖 | **零新增 pub 依赖**（`FF-23` 的依赖最小化；`SPEC-G-01` §1.3 已禁 `http`/`dio`/`url_launcher`） |
| 线程 | 全部在主 isolate 串行执行；不新建 isolate、不使用 `compute` |
| 内存 | 单轮上限由 `FF-26g` 的历史条数与请求体字节上限界定；实例在终态释放 |
| 功耗 | 无轮询、无定时器、无后台常驻（`FF-24` 第 6 条） |
| 隐私 | 装配期即拒绝 `FF-26e` 载体；本层不读磁盘、不读音频、不读设备标识 |
| 可测试性 | 循环、注册表、提示词装配、历史裁剪四者都必须可在**无网络、无 Key、无 Flutter** 的条件下纯函数式驱动 |
| 性能 | 单轮编排耗时【待实测】；本 SPEC 不预设数字 |

## 9. 裁剪与未做

| 项 | 决定 |
|---|---|
| 代下单（含无障碍代操作、模拟点击、代填地址、代扣款） | ❌ 不做（`FF-26i`）。**不得**以「提示词已禁止」替代注册表闭集 |
| 多智能体 / 规划器 / 任务分解树 | ❌ 不做 |
| 长期记忆库、向量检索、跨会话记忆 | ❌ 不做。对话历史只在单轮内存中，不入库（`API-03` 不新增表） |
| 代码执行 / 文件读写 / 任意 URL 抓取工具 | ❌ 不做。注册表是四元闭集 |
| 工具并发执行 | ❌ 不做，见 `G-02-K5` |
| 云端会话持久化与断点续传 | ❌ 不做（`API-05` §9 仍 `DISABLED`） |
| 崩溃上报 / 分析埋点 | ❌ 不做（`ADR-44` 未放开） |
| 流式之外的**非流式**编排路径 | ⚠️ 仅为测试可注入而保留，生产只走流式（与 `SPEC-G-01` §9 一致） |

## 10. 开放问题

| 编号 | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| OQ-G02-1 | 本 SPEC 的 `has_number` 护栏按 `ADR-26` 的**判据语义**独立实现：实测当前工作区 `app/lib/domain/service/` 下 11 个文件中无 `guard` 命中，`ADR-26` 记录的护栏实现文件不在此 checkout 内。若该实现回归，应改为**引用同一实现**而不是保留第二份数字判据 | 同一判据存在两份实现 → 漂移风险（`ADR-26` 已记录过一次「两种相反判据不能共用一个方法」的教训） | B，`SPEC-G-03` 开工前 |
| OQ-G02-2 | 同一轮多个 `tool_calls` 是否应并发执行（当前串行）。串行简单、无并发写；并发可缩短单轮墙钟时间，但会与 `StatsRepo` 的读一致性假设交互 | 单轮延迟【待实测】 | B 主提，A/C 确认 |
| OQ-G02-3 | 未知 `finish_reason` 与服务端未知字段的原文诊断目前只在**内存**中；是否进入 `SPEC-M-04` 自检面板需先走 `ADR-14` 的 15 项闭集变更 | 现场可诊断性 | B + C，`SPEC-M-04` 同步前 |
| OQ-G02-4 | `G-02-K4`（系统提示词字符上限）为工程提案，无 `FF` 依据；`FF-25` 红线与四工具说明的实际字数【待实测】后可能需调整 | 构建期断言阈值 | B |

**文档结束**

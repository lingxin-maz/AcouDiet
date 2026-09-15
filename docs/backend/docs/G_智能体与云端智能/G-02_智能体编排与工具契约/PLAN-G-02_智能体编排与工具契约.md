# PLAN-G-02 智能体编排与工具契约

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-G-02 |
| 负责 | B |
| 目标日 | v2.0-第 7 日 |
| 前置依赖 | `SPEC-G-01` 的 `AgentTransport` 端口；`SPEC-G-03` 的四工具（先用桩）；`shared/feature_config.json` 的 `agent` 段；`. D:\Desktop\Food\_toolchain\acoudiet-env.ps1` 已激活 |
| 预估工时 | 20 人时 |

## 1. 交付物（Deliverables）

| # | 路径（前缀 `app/lib/domain/agent/`，除注明外） | 内容 |
|---|---|---|
| 1 | `agent_tool.dart` / `agent_tool_registry.dart` | `AgentTool`/`AgentObservation` + 四元闭集注册表 |
| 2 | `agent_system_prompt.dart` | 编译期常量提示词（含 `FF-25` 红线） |
| 3 | `agent_prompt_builder.dart` | 唯一装配点 + `FF-26d`/`FF-26e`/`G-02-K1` 断言 |
| 4 | `agent_history.dart` | 裁剪到 `FF-26g` 条数上限，保 system |
| 5 | `agent_state.dart` / `agent_loop.dart` | 状态机与有界 ReAct 循环 |
| 6 | `app/tool/agent_tests.dart`；`tool/verify_all.ps1`（+1 步）；`app/tool/probe_agent_prompt.dart` | 离线套件；接入总闸门；探针（提示词字数与红线命中） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 值类型 + 闭集注册表 + 构造期校验 | 交付物 1 | 4h | `API-07` §4.1/§4.2 |
| 2 | 提示词常量与 `has_number` 护栏 | 交付物 2 | 3h | `ADR-26` 判据族 |
| 3 | 装配点断言（白名单 / 禁止清单 / 数值长度） | 交付物 3 | 3h | 1、2 |
| 4 | 历史裁剪 | 交付物 4 | 2h | 3 |
| 5 | 状态机与迁移表 + 循环与轮次上限 | 交付物 5 | 5h | 1、4 |
| 6 | 套件 16 条判据 + 逐条负控 | 交付物 6 | 3h | 1–5 |
| 7 | 接入总闸门并核对步骤数 + 探针 | 交付物 7 | 2h | 6 |

## 3. 技术方案

循环只依赖 `SPEC-G-01` 的纯 Dart 端口，桩实现即可离线驱动全部判据；**全仓唯一的 `messages` 装配点**在交付物 3。

```dart
// agent_prompt_builder.dart（唯一装配点）
static const int maxNumericArrayLength = 1024;   // G-02-K1（SPEC-G-02 冻结）
static const Set<String> egressFields = {...};   // FF-26d 七类字段名，不复制数值
List<Map<String, Object?>> build({required String userText,
    required List<Map<String, Object?>> history, required List<Map<String, Object?>> tools});
// 断言 ①字段名 ②载体类型/路径 ③数值数组长度 ④提示词 has_number

// agent_loop.dart（无 HttpClient，只有 AgentTransport）
while (state != AgentState.idle) { switch (state) {
  case AgentState.building:       // 装配 + 断言 -> awaitingModel | failed
  case AgentState.awaitingModel:  // 消费 AgentDelta 闭集
  case AgentState.toolCalls:      // round >= FF-26g 上限 -> ACD-AGENT-010
                                  // 串行、index 升序；未注册名 -> ACD-AGENT-009，不执行
  case AgentState.rendering:      // 交 SPEC-U-07
  case AgentState.failed:         // 错误码透传
  case AgentState.idle: } }
```

**纪律**：未注册名在**查表阶段**被拦下，令牌永不进入执行函数；`round` 无重置路径；模型标识符从 SSOT 常量读取（`FF-26h`）；观察 JSON 由单一构造函数产出。

## 4. 测试与验证

| 测试 | 类型 | 断言（映射 `SPEC-G-02` §7） | 何时跑 |
|---|---|---|---|
| `registry has exactly four tools` / `unknown tool name is not executed` | 单元 | #1 名字集合逐字等于 `API-07` §4.1，负控 `place_order` 被拒；#2 执行计数 0 + `ACD-AGENT-009` | `agent_tests.dart` |
| `builder rejects a field outside FF-26d` / `... FF-26e carriers` / `... a 4096-length List<double>` | 单元 | #3/#4/#5 各自抛、长度 4 通过；负控删断言即红 | 同上 |
| `system prompt has no invented number` / `history trimming drops oldest non-system` | 单元 | #6 `has_number == false`（负控塞数字即红）；#7 条数 == 上限且 system 全保留（负控裁 system 即红） | 构建期 + 套件 |
| `tool loop stops at max_tool_rounds` / `oversized body trims history...` | 单元 | #8 轮数 == `FF-26g` 上限且 `ACD-AGENT-010`（负控删上限即红）；#9 字节数 ≤ 上限或未发出 | 同上 |
| `state machine transitions are exhaustive` / `observation shape is fixed` / `prompt and card strings avoid FF-25 terms` | 单元 | #10 §2.3 逐行断言（负控放开自环即红）；#11 四字段齐全 + error 三字段同现；#15 词表命中 0（负控写入即红） | 同上 |
| 模型标识符检索 / `check_l4_usage.py --strict` / `check_network_boundary.py --strict` | 静态 | #12 `app/lib/**` 命中 0；#13 exit 0（负控 import flutter 即非 0）；#14 白名单外命中 0 | `verify_all.ps1` |
| `verify_all.ps1` 步骤清单 | 集成 | #16 含本套件且步骤总数 +1，套件失败时总闸门 exit 非 0 | 每次总闸门 |

## 5. 完成定义（DoD）

- [ ] `SPEC-G-02` §7 的 16 条判据全部通过，每条新闸门的负控**已实测变红**并留证。
- [ ] `pwsh -File tool/verify_all.ps1` exit `0`，步骤总数比接入前 +1。
- [ ] `app/lib/domain/agent/**` 无 `package:flutter`、无 `HttpClient`/`Socket`/`WebSocket`；`FF-26h` 标识符命中 0；装配点静态检索命中**恰 1 处**。
- [ ] `SPEC-G-02` §10 OQ-G02-1 已给出结论（护栏改为引用 `ADR-26` 实现，或保留自研并写明理由）。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 桩与真实 `AgentTransport` 语义漂移（`AgentDelta` 成员不一致） | 接入真实现时套件变红 | 以 `SPEC-G-01` 的 sealed 闭集为准修桩，**不改**本 SPEC 判据 |
| 裁剪历史后请求体仍超限的分支未被覆盖 | 判据 #9 该分支失败 | 保留「终止并如实告知」路径，**不放宽** `FF-26g` 上限 |
| 模型持续请求工具／负控无法变红 | 判据 #8 反复触发 `ACD-AGENT-010`；删掉判据后套件仍绿 | 显示可解释的终止态，**不得**静默截断；负控不变红的闸门视为**未完成**，先修闸门再接总闸门 |

## 7. 与检查点的关系

- 本功能是 v2.0 **Agent 链路闸门**的组成部分，与 `SPEC-G-01`/`SPEC-G-03` 同批验收；三者缺一，`SPEC-U-07` 不得开工。未完成时 Agent 页降级为**只读展示**（`FF-26f`），`P-*`/`D-*`/`A-*`/`M-*`/`U-01`~`U-06` 不受影响；不得以「提示词已约束」为由放行代下单路径。

**文档结束**

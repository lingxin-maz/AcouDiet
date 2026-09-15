# PLAN-G-01 云端连接层与凭据管理

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-G-01 |
| 负责 | B |
| 目标日 | v2.0-D1 |
| 前置依赖 | `ADR-44` 宪法修订已落地（`SPEC-00` §3.11、`API-05` §1/§13、`API-07`）；`shared/feature_config.json` 的 `agent` 段已生成常量 |
| 预估工时 | 20 h（B 12 h / A 4 h / C 4 h） |

## 1. 交付物（Deliverables）

| # | 文件 | 说明 |
|---|---|---|
| 1 | `app/lib/data/net/agent_transport.dart` | `AgentTransport` / `AgentRequest` / `AgentDelta` / `AgentToolCall` 四个纯 Dart 声明 |
| 2 | `app/lib/data/net/deepseek_client.dart` | `DeepSeekClient implements AgentTransport`：`dart:io HttpClient`、SSE 行解析、分片累积、错误映射、有界重试 |
| 3 | `app/lib/data/net/sse_decoder.dart` | 纯函数 `SseDecoder`：`feed(List<int>) -> List<String>` 完整 `data:` 载荷。**单独成文件是为了可被纯 Dart 套件直接测试** |
| 4 | `app/lib/data/net/agent_credentials.dart` | `AgentCredentials` / `AgentCredentialsStore`（`read`/`write`/`clear`）+ `maskApiKey` |
| 5 | `app/lib/data/net/agent_connectivity.dart` | `AgentConnectivity.probe()` |
| 6 | `app/tool/agent_tests.dart` | 离线纯 Dart 套件；失败时 `exit(1)`；**自带负控开关** `--with-negative-controls` |
| 7 | `tool/check_network_boundary.py` | 出网白名单判据 + `--selftest` 负控 |
| 8 | `tool/check_audio_egress.py` | 音频出境静态判据 + `--selftest` 负控 |
| 9 | `shared/feature_config.json` / `app/assets/feature_config.json` / `app/lib/core/feature_config.g.dart` | `agent` 段（`FF-26a`/`FF-26g`/`FF-26h` 的机器可读值） |
| 10 | `tool/verify_all.ps1` | 新增两步：`agent_tests.dart`、两个 checker（`--strict`） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | SSOT 定稿 `agent` 段并重生成三份常量 | 交付物 9 | 3 h | 宪法修订 |
| 2 | `SseDecoder`（纯函数，先写测试） | 交付物 3 | 3 h | 1 |
| 3 | `DeepSeekClient`：请求组装 + 错误映射 + 有界重试 | 交付物 2 | 5 h | 2 |
| 4 | 凭据存储 + 掩码 | 交付物 4 | 2 h | 1 |
| 5 | 连通性探测 | 交付物 5 | 1 h | 3 |
| 6 | `agent_tests.dart` 与全部负控 | 交付物 6 | 3 h | 2–5 |
| 7 | 两个 checker 与其 `--selftest` | 交付物 7/8 | 3 h | 6 |
| 8 | 接入 `verify_all.ps1` 并全绿 | 交付物 10 | 1 h | 7 |

## 3. 技术方案

### 3.1 端口（G-02 只看这三个类型）

```dart
// app/lib/data/net/agent_transport.dart  —— 纯 Dart，无 Flutter、无 dart:io
sealed class AgentDelta {}
final class AgentTextDelta extends AgentDelta { final String text; ... }
final class AgentToolCallDelta extends AgentDelta { final AgentToolCall call; ... }
final class AgentFinished extends AgentDelta { final AgentFinishReason reason; ... }
final class AgentFailed extends AgentDelta { final AcouDietError error; ... }

abstract class AgentTransport {
  Stream<AgentDelta> send(AgentRequest request);
  void cancel();
}
```

> `AgentTransport` **不暴露** `HttpClient`，因此 `G-02` 在 `app/lib/domain/agent/**` 下不可能写出网代码——`check_network_boundary.py` 的白名单因此是**结构性**成立的，不只是约定。

### 3.2 SSE 解码（本 PLAN 最要紧的一处）

```dart
class SseDecoder {
  final List<int> _buf = <int>[];          // 原始字节，不是字符串
  final List<String> _payloads = <String>[];

  List<String> feed(List<int> chunk) {
    _buf.addAll(chunk);
    // 只在最后一个 '\n' 之前切；余下字节留到下一 chunk。
    // 关键：切的是 BYTES，解码在完整行上做 —— 否则一个中文字符被
    // TCP 分片切断时 utf8.decode 会抛 FormatException（API-05 §13.1.6）。
    ...
  }
}
```

**为什么单独一个类**：这是全层唯一有真实分片状态的地方，把它做成纯函数对象，就能用 `dart` 单独跑 `agent_tests.dart`（`run_offline_tests.py` 的约束：没有可用 pub 依赖）。

### 3.3 工具调用累积

```dart
final Map<int, _PartialCall> _calls = {};
// delta.tool_calls[i] 形如 {"index":0,"id":"call_x","function":{"name":"...","arguments":"{\"a\""}}
// 合并规则：id/name 非空则覆盖；arguments 一律 APPEND。
// 严禁对单片 arguments 调 jsonDecode —— 它天然是分片的 JSON 文本。
```

到 `finish_reason == "tool_calls"` 时，对每个 `index` 按序 `jsonDecode(arguments)`；任一抛错 → `AgentFailed(ACD-AGENT-009)`。

### 3.4 重试矩阵（照 `API-05` §8 第二张表实现，不自行发挥）

```dart
int attempts = 0;
while (true) {
  try { await for (final d in _oneShot(req)) { if (d is AgentTextDelta) receivedDelta = true; yield d; } return; }
  on AcouDietError catch (e) {
    attempts++;
    final retryable = e.code == Codes.agent429 || e.code == Codes.agent5xx || e.code == Codes.agentTimeout;
    if (!retryable || attempts > 1 || receivedDelta) rethrow;   // ← 重试闸门，判据 #4
    await Future<void>.delayed(_backoffFor(e));
  }
}
```

### 3.5 凭据文件

`filesDir` 由既有的原生 SQLite 通道给出父目录（不新增 MethodChannel，避免 `check_bridge_symmetry.py` 的字段集断言受影响）。写入用「先写临时文件再 `rename`」，避免半截文件被读成损坏凭据。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `sse splits a multibyte character across chunks` | 单元（纯 Dart） | 判据 #2 | 每次 `verify_all` |
| `tool_calls fragment accumulation` | 单元 | 判据 #3 | 同上 |
| `no retry after first delta` | 单元 | 判据 #4 | 同上 |
| `retries are bounded` | 单元 | 判据 #5 | 同上 |
| `request over the byte cap is refused` | 单元 | 判据 #6 | 同上 |
| `http base url is refused` | 单元 | 判据 #7 | 同上 |
| `corrupt credentials read as null` | 单元 | 判据 #8 | 同上 |
| `mask` 三分支 | 单元 | 判据 #9 | 同上 |
| `check_network_boundary.py --selftest` | checker | 判据 #1（负控在白名单外放 `HttpClient`，必须 exit 1） | 同上 |
| `check_audio_egress.py --selftest` | checker | 判据 #12（负控把 `Float32List` 塞进请求体，必须 exit 1） | 同上 |
| 全仓搜索 `deepseek-flash` | 文本判据 | 判据 #11 | `check_network_boundary.py` 内实现 |

**负控纪律**（本项目的复发主题）：上表中每条「负控」都必须**实际跑过一次变红**，并把那次输出记入 `PLAN-G-01` 的完成记录。删掉负控后退出码仍为 0 的判据**不算判据**。

## 5. 完成定义（DoD）

- [ ] `SPEC-G-01` §7 的 12 条判据全部通过
- [ ] `python tool/check_network_boundary.py --strict` → exit 0，且 `--selftest` → exit 0
- [ ] `python tool/check_audio_egress.py --strict` → exit 0，且 `--selftest` → exit 0
- [ ] `dart app/tool/agent_tests.dart` → `AGENT: all N checks passed`
- [ ] `tool/verify_all.ps1` → `ALL SUITES PASSED (22 steps)`（原 20 + 本 PLAN 的 2 步）
- [ ] 零新增 pub 依赖（`app/pubspec.yaml` 的 `dependencies:` 段与 `ADR-44` 之前逐字相等）
- [ ] 每条负控都有一次「变红」的实测记录

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 服务端 SSE 实际帧格式与 `API-07` §5 不符 | 真机联调出现 `ACD-AGENT-008` | 用真实抓包更新 `API-07` §5，并补一条以真实帧为夹具的用例 |
| TLS / 代理导致真机连不通 | `ACD-AGENT-001` 恒成立 | `U-07` 显示可解释降级；核心链路不受影响（`FF-26f`）；现场演示切 `offline` 风味 |
| `dart:io` 在 Flutter Android 上的 `HttpClient` 与 app 生命周期耦合 | 后台被系统回收时 socket 被断 | 已有 `AgentFailed(ACD-AGENT-008)` 路径；不做重连（本 SPEC 无长连接） |
| 敏感信息误入日志 | 代码审查 | `check_audio_egress.py` 增加「日志不得含 `sk-`」一条 |

## 7. 与检查点的关系

本功能是 v2.0 的**关键路径起点**（`G-02`/`G-03`/`U-07` 全部依赖它），但**不在** v1.0 的任何 CP（CP1–CP4）里，也不影响它们。
未完成时：`G-02`/`G-03`/`U-07` 整体不排期；`offline` 风味的全部 v1.0 交付物**不受影响**。

**文档结束**

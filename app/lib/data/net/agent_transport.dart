// app/lib/data/net/agent_transport.dart
//
// ADR-44 -- the cloud egress PORT. Pure Dart: no `dart:io`, no `package:flutter`.
//
// SPEC-G-01 section 3.1. `G-02` (app/lib/domain/agent/**) depends on THIS file and on
// nothing else network-shaped, so the network boundary is structural rather than a
// convention: `AgentTransport` never exposes an `HttpClient`, so a caller physically cannot
// issue a request from a directory outside `app/lib/data/net/`.
//
// `R-OUT-4` (API-05 section 3.1): there is exactly ONE egress point in the whole app, and it
// is the implementation of this interface. `tool/check_network_boundary.py` enforces it.
//
// FF-26e is expressed in the types: nothing in `AgentMessage` or `AgentToolDefinition` can
// carry binary audio. There is no `Uint8List` member anywhere in this file, and that is a
// deliberate design constraint, not an accident.

import '../../core/errors.dart';

/// One message in the conversation sent to the model.
///
/// `content` is always text. That is the whole point: `FF-26e` forbids PCM, Mel tensors,
/// audio files, device identifiers and location from ever being serialised, and the cheapest
/// way to keep that promise is to make it impossible to express them here.
class AgentMessage {
  const AgentMessage.system(this.content)
      : role = 'system',
        toolCallId = null,
        toolCalls = const <AgentToolCall>[];

  const AgentMessage.user(this.content)
      : role = 'user',
        toolCallId = null,
        toolCalls = const <AgentToolCall>[];

  const AgentMessage.assistant(this.content,
      {this.toolCalls = const <AgentToolCall>[]})
      : role = 'assistant',
        toolCallId = null;

  const AgentMessage.tool(this.content, {required String this.toolCallId})
      : role = 'tool',
        toolCalls = const <AgentToolCall>[];

  final String role;
  final String content;
  final String? toolCallId;
  final List<AgentToolCall> toolCalls;

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'content': content,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((c) => c.toRequestJson()).toList(),
      };
}

/// A tool definition as the model sees it (`API-07` section 4.1).
class AgentToolDefinition {
  const AgentToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// A JSON-Schema object. Kept as a plain map so the registry stays data, not code.
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'function',
        'function': <String, Object?>{
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// A tool call, either partially accumulated (during streaming) or complete.
class AgentToolCall {
  const AgentToolCall({required this.id, required this.name, required this.argumentsJson});

  final String id;
  final String name;

  /// The raw JSON text of the arguments. While streaming this is a PREFIX: the API sends it
  /// in fragments and it must be concatenated, never parsed per fragment (`API-05` 13.3.2).
  final String argumentsJson;

  Map<String, Object?> toRequestJson() => <String, Object?>{
        'id': id,
        'type': 'function',
        'function': <String, Object?>{'name': name, 'arguments': argumentsJson},
      };
}

/// Why the stream ended.
enum AgentFinishReason { stop, toolCalls, length, unknown }

/// One increment of the response stream. A closed set, so every consumer's `switch` is
/// exhaustive and a new case cannot be added without breaking the build.
sealed class AgentDelta {
  const AgentDelta();
}

final class AgentTextDelta extends AgentDelta {
  const AgentTextDelta(this.text);
  final String text;
}

final class AgentToolCallDelta extends AgentDelta {
  const AgentToolCallDelta(this.call);
  final AgentToolCall call;
}

final class AgentFinished extends AgentDelta {
  const AgentFinished(this.reason, {this.truncated = false});
  final AgentFinishReason reason;
  final bool truncated;
}

final class AgentFailed extends AgentDelta {
  const AgentFailed(this.error);
  final AcouDietError error;
}

/// Everything one request needs. Assembled by `G-02`, never by a page.
class AgentRequest {
  const AgentRequest({required this.messages, required this.tools});

  final List<AgentMessage> messages;
  final List<AgentToolDefinition> tools;
}

/// The gate. `FF-26f`: when [enabled] is false the whole agent path is inert -- no request is
/// constructed, and the user is not asked for a credential the app has no permission to use.
abstract class AgentGate {
  bool get consented;
  bool get hasKey;

  /// Declared abstract on purpose: the two concrete gates below must each spell out the
  /// conjunction, so that weakening it (say, dropping the consent term) is a visible diff in
  /// the file that owns the gate rather than an inherited accident.
  bool get enabled;
}

/// A plain immutable gate for the offline wiring and for tests.
class AgentGateState implements AgentGate {
  const AgentGateState({required this.consented, required this.hasKey});

  @override
  final bool consented;
  @override
  final bool hasKey;

  @override
  bool get enabled => consented && hasKey;
}

/// The port. `DeepSeekClient` is the only implementation that talks to the network;
/// `FakeAgentTransport` (in `agent_tests.dart`) is the only other one, and it never does.
abstract class AgentTransport {
  /// Streams one completion. The stream always terminates: exactly one `AgentFinished` or
  /// one `AgentFailed` is the last event (`SPEC-G-01` section 2.3).
  Stream<AgentDelta> send(AgentRequest request);

  /// Abandons an in-flight request. Safe to call when nothing is in flight.
  void cancel();

  /// Releases sockets. Called on disposal.
  void dispose();
}

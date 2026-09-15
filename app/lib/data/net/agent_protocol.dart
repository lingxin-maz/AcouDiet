// app/lib/data/net/agent_protocol.dart
//
// ADR-44 -- the PURE part of the cloud protocol. No sockets here, so every rule below is
// directly testable from `app/tool/agent_tests.dart` with no network and no mock server.
//
// `SPEC-G-01` section 3 puts four decisions in this file rather than inside `DeepSeekClient`,
// for one reason: they are the four that can be wrong without anything failing loudly.
//
//   1. `maskApiKey`        -- a key that leaks into a screenshot or a log is gone forever.
//   2. `normalizeBaseUrl` / `isSecureBaseUrl` -- `usesCleartextTraffic="false"` means a
//      plain-`http` base URL can never work on device; reporting a SHAPE error is honest,
//      reporting a network error is not.
//   3. `shouldRetry`       -- the retry that duplicates a billed request, or replays half a
//      stream, is strictly worse than not retrying. `API-05` section 13.1.8.
//   4. `buildRequestBody` + the byte cap -- the cap exists to stop a large object being
//      carried into a request by accident. Widening it deletes the guard.
//
// It also owns the SSE-payload -> `AgentDelta` translation, so `DeepSeekClient` is left with
// sockets, timeouts and nothing else.

import 'dart:convert';

import '../../core/errors.dart';
import 'agent_transport.dart';
import 'sse_decoder.dart';

/// Shows at most 3 leading and 4 trailing characters of a credential (`FF-26b`).
///
/// Anything shorter than 8 characters is masked entirely: `sk-1` revealed as `sk-…1` would
/// give away 3 of its 4 characters, and "masked" would become a lie.
String maskApiKey(String key) {
  if (key.length < 8) return '****';
  return '${key.substring(0, 3)}…${key.substring(key.length - 4)}';
}

/// Trims the trailing slash so `https://host/` and `https://host` are the same endpoint.
/// Getting this wrong yields `//chat/completions`, which some edges 404 on.
String normalizeBaseUrl(String baseUrl) {
  var v = baseUrl.trim();
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

/// `FF-26a` / `SPEC-G-01` section 2.4: only https is acceptable.
bool isSecureBaseUrl(String baseUrl) =>
    normalizeBaseUrl(baseUrl).toLowerCase().startsWith('https://');

/// The retry gate. `attempts` counts attempts ALREADY made for this request.
///
/// `receivedDelta` is the load-bearing parameter. Once the model has streamed any text, a
/// retry would re-run a request that has already been billed and would splice a second answer
/// onto the first one. There is no correct way to merge that, so there is no retry.
bool shouldRetry({
  required String code,
  required int attempts,
  required bool receivedDelta,
}) =>
    isRetryable(code) && attempts < 1 && !receivedDelta;

/// Builds the JSON request body (`API-07` section 5.1) and enforces the byte cap.
///
/// Throws [AcouDietError] `ACD-AGENT-003` when the body is over `maxRequestBytes`. It does NOT
/// truncate: the caller (`G-02`) owns history trimming, and silently shrinking a body here
/// would hide the fact that trimming did not happen.
String buildRequestBody({
  required String model,
  required List<AgentMessage> messages,
  required List<AgentToolDefinition> tools,
  required int maxTokens,
  required double temperature,
  required int maxRequestBytes,
}) {
  final body = <String, Object?>{
    'model': model,
    'messages': messages.map((m) => m.toJson()).toList(),
    'tools': tools.map((t) => t.toJson()).toList(),
    'tool_choice': 'auto',
    'stream': true,
    'max_tokens': maxTokens,
    'temperature': temperature,
  };
  final text = jsonEncode(body);
  final bytes = utf8.encode(text).length;
  if (bytes > maxRequestBytes) {
    throw Errors.agent(Codes.agentNoKey, detail: <String, Object?>{
      'reason': 'request body over the frozen byte cap',
      'bytes': bytes,
      'max_request_bytes': maxRequestBytes,
    });
  }
  return text;
}

/// Parses one `data:` payload into zero or more deltas.
///
/// Returns an empty list for a payload that carries nothing useful. An unknown field is
/// IGNORED rather than fatal (`API-07` section 8): turning a server-side addition into an app
/// crash is how a routine upgrade becomes an outage.
///
/// Throws [FormatException] when the payload is not JSON at all -- that is a broken stream,
/// and `DeepSeekClient` maps it to `ACD-AGENT-008`.
List<AgentDelta> parseSsePayload(
  String payload, {
  required Map<int, AgentPartialToolCall> partials,
}) {
  final decoded = jsonDecode(payload);
  if (decoded is! Map) return const <AgentDelta>[];
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return const <AgentDelta>[];
  final first = choices.first;
  if (first is! Map) return const <AgentDelta>[];

  final out = <AgentDelta>[];
  final delta = first['delta'];

  if (delta is Map) {
    final content = delta['content'];
    if (content is String && content.isNotEmpty) out.add(AgentTextDelta(content));

    final toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      for (final raw in toolCalls) {
        if (raw is! Map) continue;
        final index = (raw['index'] as num?)?.toInt() ?? 0;
        final fn = raw['function'];
        final partial = partials.putIfAbsent(index, () => AgentPartialToolCall(index: index));
        partial.merge(
          id: raw['id'] as String?,
          name: fn is Map ? fn['name'] as String? : null,
          // APPEND, never re-parse: this string is a JSON document arriving in pieces.
          argumentsFragment: fn is Map ? fn['arguments'] as String? : null,
        );
      }
    }
  }

  final finish = first['finish_reason'];
  if (finish is String && finish.isNotEmpty) {
    final reason = switch (finish) {
      'stop' => AgentFinishReason.stop,
      'tool_calls' => AgentFinishReason.toolCalls,
      'length' => AgentFinishReason.length,
      _ => AgentFinishReason.unknown,
    };
    if (reason == AgentFinishReason.toolCalls) {
      out.addAll(completeToolCalls(partials));
    }
    out.add(AgentFinished(reason, truncated: reason == AgentFinishReason.length));
  }
  return out;
}

/// Turns the accumulated fragments into complete tool calls, in `index` order.
///
/// Throws [AcouDietError] `ACD-AGENT-009` when a fragment set cannot be completed. That is the
/// *only* reading of the fragments: an incomplete `arguments` string is not a partial answer,
/// it is an unusable one, and rendering it as though it succeeded would be a lie.
List<AgentDelta> completeToolCalls(Map<int, AgentPartialToolCall> partials) {
  final indices = partials.keys.toList()..sort();
  final out = <AgentDelta>[];
  for (final i in indices) {
    final p = partials[i]!;
    if (!p.isComplete) {
      throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
        'reason': 'tool call fragment set is incomplete',
        'index': i,
        'has_id': p.id.isNotEmpty,
        'has_name': p.name.isNotEmpty,
      });
    }
    // Validate the accumulated JSON here, once, rather than at the call site. A malformed
    // document must become a typed error before it can be mistaken for a successful result.
    try {
      jsonDecode(p.arguments.isEmpty ? '{}' : p.arguments);
    } on FormatException {
      throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
        'reason': 'accumulated arguments are not valid JSON',
        'index': i,
        'name': p.name,
      });
    }
    out.add(AgentToolCallDelta(AgentToolCall(
      id: p.id,
      name: p.name,
      argumentsJson: p.arguments.isEmpty ? '{}' : p.arguments,
    )));
  }
  return out;
}

/// Maps an HTTP status to the frozen error code (`API-07` section 7).
AcouDietError httpStatusError(int status) {
  final code = switch (status) {
    401 || 403 => Codes.agentUnauthorized,
    429 => Codes.agentRateLimited,
    >= 500 => Codes.agentServerError,
    >= 400 => Codes.agentStreamBroken,
    _ => Codes.agentStreamBroken,
  };
  return Errors.agent(code, detail: <String, Object?>{'status': status});
}

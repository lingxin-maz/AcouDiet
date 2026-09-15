// app/lib/domain/agent/agent_service.dart
//
// ADR-44 -- the agent's public face: the bounded turn loop (`G-02`) plus the state the UI reads.
// Pure Dart.
//
// THE BOUNDED LOOP (`FF-26g`)
// ---------------------------
// A model that can call tools can call them forever. The bound is not a nicety: without it a
// single "我饿了" can bill an unbounded number of requests. When the bound is reached the turn
// STOPS and says so. It does not silently continue, and it does not silently truncate either --
// both would hide the fact that the answer is incomplete.
//
// THE GATE ORDER MATTERS
// ----------------------
// consented -> key present -> network. Checking them in this order means a user who has not
// consented generates NO request and NO key prompt: the app must not ask for a credential it
// has no permission to use (`FF-24` item 9).

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../data/net/agent_transport.dart';
import 'agent_prompt.dart';
import 'agent_tool.dart';
import 'agent_tools.dart';

/// What the UI receives while a turn runs.
sealed class AgentEvent {
  const AgentEvent();
}

final class AgentTextEvent extends AgentEvent {
  const AgentTextEvent(this.text);
  final String text;
}

final class AgentToolEvent extends AgentEvent {
  const AgentToolEvent({
    required this.toolName,
    required this.observation,
    required this.proposalOnly,
  });
  final String toolName;
  final AgentObservation observation;
  final bool proposalOnly;
}

final class AgentDoneEvent extends AgentEvent {
  const AgentDoneEvent({required this.toolRounds, this.truncated = false});
  final int toolRounds;

  /// `true` when the model stopped because it ran out of output budget
  /// (`finish_reason == "length"`, `API-07` section 5.3).
  ///
  /// This is a flag on the DONE event rather than a separate event variant for a concrete
  /// reason: an answer that hit the token ceiling is still a *finished* turn, and modelling it
  /// as a failure would make the UI discard or degrade a reply that is mostly usable.
  ///
  /// ⚠️ It was **previously swallowed entirely** -- `runTurn` matched `AgentFinished()` with an
  /// empty case, so `finish_reason == "length"` produced a normally-completed turn and the user
  /// read a sentence cut off mid-clause as a complete answer. The UI had a state, a frozen
  /// sentence and tests for it; none of them could ever run. That is the failure mode this
  /// project keeps recording: a state that exists but is unreachable is not a feature.
  final bool truncated;
}

final class AgentErrorEvent extends AgentEvent {
  const AgentErrorEvent(this.error);
  final AcouDietError error;
}

// `AgentGate` / `AgentGateState` live in `data/net/agent_transport.dart` alongside the other
// ports. Keeping them there (rather than here) is what lets the FILE-BACKED implementation
// live in `data/net/` without importing this file -- a `data -> domain` import would close a
// cycle for no benefit.

class AgentService {
  AgentService({
    required this.transport,
    required this.registry,
    required this.gate,
    required this.platforms,
    this.promptBuilder = const AgentPromptBuilder(),
    this.maxToolRounds,
    this.maxHistoryMessages,
    this.launcher,
  });

  final AgentTransport transport;
  final AgentToolRegistry registry;
  final AgentGate gate;
  final List<TakeoutPlatform> platforms;
  final AgentPromptBuilder promptBuilder;
  final AgentPlatformLauncher? launcher;

  final int? maxToolRounds;
  final int? maxHistoryMessages;

  final List<AgentMessage> _history = <AgentMessage>[];

  int get _rounds => maxToolRounds ?? cfg.FeatureConfig.agentMaxToolRounds;
  int get _historyCap => maxHistoryMessages ?? cfg.FeatureConfig.agentMaxHistoryMessages;

  /// A COUNT, never the messages: a message may quote the user, so the diagnostics panel gets
  /// the length and nothing else.
  int get historyLength => _history.length;

  void clearHistory() => _history.clear();

  static final AgentErrorEvent unconsentedEvent =
      AgentErrorEvent(Errors.agent(Codes.agentUnconsented));
  static final AgentErrorEvent noKeyEvent = AgentErrorEvent(Errors.agent(Codes.agentNoKey));
  static final AgentErrorEvent roundsExceededEvent =
      AgentErrorEvent(Errors.agent(Codes.agentToolRoundsExceeded));

  /// Runs one user turn.
  ///
  /// The returned stream always terminates with exactly one [AgentDoneEvent] or one
  /// [AgentErrorEvent]. `FF-26f`: every failure is reported, never thrown at the caller.
  Stream<AgentEvent> runTurn({
    required String userText,
    Map<String, Object?> facts = const <String, Object?>{},
  }) async* {
    if (!gate.consented) {
      yield unconsentedEvent;
      return;
    }
    if (!gate.hasKey) {
      yield noKeyEvent;
      return;
    }

    List<AgentMessage> messages;
    try {
      messages = promptBuilder.build(
        history: _history,
        userText: userText,
        contextFacts: facts,
        maxHistoryMessages: _historyCap,
      );
    } on AcouDietError catch (e) {
      yield AgentErrorEvent(e);
      return;
    }

    var rounds = 0;
    while (true) {
      final buf = StringBuffer();
      final calls = <AgentToolCall>[];
      AcouDietError? failure;
      // Read from every `AgentFinished` and OR-ed: a tool round may complete normally while the
      // FINAL round is the one that hit the token ceiling, and only the final one is reported.
      var wasTruncated = false;

      await for (final delta in transport.send(
        AgentRequest(messages: messages, tools: registry.definitions),
      )) {
        switch (delta) {
          case AgentTextDelta(:final text):
            buf.write(text);
            yield AgentTextEvent(text);
          case AgentToolCallDelta(:final call):
            calls.add(call);
          case AgentFinished(:final truncated):
            wasTruncated = wasTruncated || truncated;
          case AgentFailed(:final error):
            failure = error;
        }
        if (failure != null) break;
      }

      if (failure != null) {
        // Keep whatever the model already said so the user is not left with an empty screen,
        // then report why the turn stopped.
        _remember(userText, buf.toString(), calls, const <AgentObservation>[]);
        yield AgentErrorEvent(failure);
        return;
      }

      if (calls.isEmpty) {
        _remember(userText, buf.toString(), calls, const <AgentObservation>[]);
        yield AgentDoneEvent(toolRounds: rounds, truncated: wasTruncated);
        return;
      }

      if (rounds >= _rounds) {
        yield roundsExceededEvent; // reported, not hidden
        return;
      }

      final assistantTurn = <AgentMessage>[
        AgentMessage.assistant(buf.toString(), toolCalls: calls),
      ];
      final observations = <AgentObservation>[];
      for (final call in calls) {
        final observation = await _invoke(call);
        observations.add(observation);
        yield AgentToolEvent(
          toolName: call.name,
          observation: observation,
          proposalOnly: registry.lookup(call.name)?.proposalOnly ?? false,
        );
        assistantTurn.add(AgentMessage.tool(_encode(observation), toolCallId: call.id));
      }
      messages = <AgentMessage>[...messages, ...assistantTurn];
      rounds++;
    }
  }

  Future<AgentObservation> _invoke(AgentToolCall call) async {
    final tool = registry.lookup(call.name);
    if (tool == null) {
      // The model produced a name that was never declared. Because the registry is closed, this
      // is exactly the case `FF-26i` depends on: a `place_order` tool does not exist, so it can
      // never run -- and the observation says so in a form the model can act on.
      return AgentObservation.failed(
        summary: '未注册的工具：${call.name}',
        rootCauseHint: '本 App 只提供 ${AgentToolNames.all.length} 个工具，且不提供下单或支付能力',
        safeRetry: '改用 ${AgentToolNames.all.join(" / ")} 之一',
        stopCondition: '不要再调用这个工具名',
      );
    }
    Map<String, Object?> args;
    try {
      args = _decode(call.argumentsJson);
    } on AcouDietError catch (e) {
      return AgentObservation.failed(
        summary: '参数无法解析',
        rootCauseHint: e.message,
        safeRetry: '按工具 schema 重新给出参数',
        stopCondition: '连续两次解析失败则放弃该工具',
      );
    }
    try {
      return await tool.run(args);
    } on AcouDietError catch (e) {
      return AgentObservation.failed(
        summary: '工具执行失败',
        rootCauseHint: e.message,
        safeRetry: '检查参数后重试一次',
        stopCondition: '同一工具失败两次则停止调用',
      );
    }
  }

  Map<String, Object?> _decode(String json) {
    if (json.trim().isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw Errors.agent(Codes.agentToolCallUnparsable,
          detail: <String, Object?>{'reason': 'tool arguments are not an object'});
    }
    return decoded.cast<String, Object?>();
  }

  String _encode(AgentObservation o) => jsonEncode(o.toJson());

  void _remember(String userText, String assistantText, List<AgentToolCall> calls,
      List<AgentObservation> observations) {
    _history.add(AgentMessage.user(userText));
    if (assistantText.isNotEmpty || calls.isNotEmpty) {
      _history.add(AgentMessage.assistant(assistantText, toolCalls: calls));
    }
    for (var i = 0; i < calls.length && i < observations.length; i++) {
      _history.add(AgentMessage.tool(_encode(observations[i]), toolCallId: calls[i].id));
    }
  }
}

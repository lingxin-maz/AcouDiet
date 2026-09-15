// app/lib/domain/agent/agent_tool.dart
//
// ADR-44 -- the tool contract (`API-07` section 4). Pure Dart: `check_l4_usage.py` forbids
// `package:flutter` under `app/lib/domain/**`, and this layer must stay runnable under a plain
// Dart VM so the offline suite can exercise it.
//
// THE MECHANISM THAT MAKES "NO ORDERING" TRUE
// -------------------------------------------
// `FF-26i` forbids placing a takeout order for the user. The tempting implementation is to
// write that rule into the system prompt and ask the model to obey. This project does not do
// that, because a rule the model can ignore is not a guarantee.
//
// Instead the registry is a CLOSED SET of exactly four tools. There is no `place_order` tool
// to call. The model cannot call a function that was never declared in `tools[]`, so the
// guarantee is structural -- and `agent_tests.dart` has a negative control that registers a
// fifth tool and asserts the registry refuses it.

import '../../core/errors.dart';
import '../../data/net/agent_transport.dart';

/// The four names, frozen. `FF-26i`'s proposer is the only one with an external side effect,
/// and it does not perform it -- it returns a card for the user to press.
abstract final class AgentToolNames {
  static const healthSummary = 'get_health_summary';
  static const recentMeals = 'get_recent_meals';
  static const recommendFood = 'recommend_food';
  static const proposeTakeout = 'propose_takeout_search';

  static const Set<String> all = <String>{
    healthSummary,
    recentMeals,
    recommendFood,
    proposeTakeout,
  };
}

/// A tool result, in the FIXED shape from `API-07` section 4.2.
///
/// The shape is fixed for three reasons, all of them practical: the model parses it reliably;
/// the tests assert it field by field; and only [summary] can reach the user, so "what the
/// tool said" and "what the tool returned" can be reviewed separately.
class AgentObservation {
  const AgentObservation({
    required this.status,
    required this.summary,
    this.nextActions = const <String>[],
    this.artifacts = const <String, Object?>{},
    this.rootCauseHint,
    this.safeRetry,
    this.stopCondition,
  });

  const AgentObservation.ok(this.summary,
      {this.nextActions = const <String>[], this.artifacts = const <String, Object?>{}})
      : status = 'success',
        rootCauseHint = null,
        safeRetry = null,
        stopCondition = null;

  /// The error path carries the three extra fields (the "Error Recovery Contract"): a bare
  /// error string makes the model retry the same broken call until the round budget is gone.
  const AgentObservation.failed({
    required this.summary,
    required String this.rootCauseHint,
    required String this.safeRetry,
    required String this.stopCondition,
  })  : status = 'error',
        nextActions = const <String>[],
        artifacts = const <String, Object?>{};

  final String status;
  final String summary;
  final List<String> nextActions;
  final Map<String, Object?> artifacts;
  final String? rootCauseHint;
  final String? safeRetry;
  final String? stopCondition;

  Map<String, Object?> toJson() => <String, Object?>{
        'status': status,
        'summary': summary,
        'next_actions': nextActions,
        'artifacts': artifacts,
        if (rootCauseHint != null) 'root_cause_hint': rootCauseHint,
        if (safeRetry != null) 'safe_retry': safeRetry,
        if (stopCondition != null) 'stop_condition': stopCondition,
      };
}

/// A tool. `proposalOnly` is the flag the UI reads to decide that the result must become a
/// button rather than an action (`API-05` section 13.4.4).
abstract class AgentTool {
  String get name;
  String get description;
  Map<String, Object?> get parameters;
  bool get proposalOnly;
  Future<AgentObservation> run(Map<String, Object?> args);
}

/// The closed registry. Registering a name outside [AgentToolNames.all] throws -- at
/// construction time, not at call time, so a forbidden tool cannot even reach `tools[]`.
class AgentToolRegistry {
  AgentToolRegistry(List<AgentTool> tools) {
    for (final t in tools) {
      if (!AgentToolNames.all.contains(t.name)) {
        throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
          'reason': 'tool name is not in the frozen closed set',
          'name': t.name,
        });
      }
      if (_byName.containsKey(t.name)) {
        throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
          'reason': 'duplicate tool name',
          'name': t.name,
        });
      }
      _byName[t.name] = t;
    }
    // The set must be COMPLETE: a registry that silently offers three of the four tools would
    // pass every individual test and still be wrong.
    final missing = AgentToolNames.all.difference(_byName.keys.toSet());
    if (missing.isNotEmpty) {
      throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
        'reason': 'registry is missing frozen tools',
        'missing': missing.toList()..sort(),
      });
    }
  }

  final Map<String, AgentTool> _byName = <String, AgentTool>{};

  List<AgentTool> get tools => AgentToolNames.all.map((n) => _byName[n]!).toList();

  List<AgentToolDefinition> get definitions => tools
      .map((t) => AgentToolDefinition(
            name: t.name,
            description: t.description,
            parameters: t.parameters,
          ))
      .toList();

  AgentTool? lookup(String name) => _byName[name];

  bool get hasProposalOnlyTool => tools.any((t) => t.proposalOnly);
}

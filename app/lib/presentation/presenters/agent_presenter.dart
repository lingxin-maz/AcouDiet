// app/lib/presentation/presenters/agent_presenter.dart
//
// U-07 -- the PURE half of the agent page. No Flutter import, so `tool/ui_presenter_tests.dart`
// can exercise the whole state machine and every produced sentence against the Dart SDK alone.
//
// WHY THE COPY IS BUILT HERE AND NOT IN THE WIDGET
// -----------------------------------------------
// `API-07` section 4.3 rules that a tool's own `summary` text must never reach the UI: it is
// model-visible text, and letting it through would make the tool output a prompt-injection
// surface that also renders. The card copy therefore comes from `UiStrings`, and a tool result
// only fills NUMERIC/NAME SLOTS. That rule is checkable only if the slot-filling lives in one
// pure function -- which is this file.
//
// The eight states are frozen (`SPEC-U-07` section 2.3): no state may be added or removed. The
// failure sub-reasons do NOT enter the state machine; they only decide the sentence and whether
// the retry affordance is offered.

import '../../core/errors.dart';
import '../../data/net/agent_protocol.dart' show maskApiKey;
import '../../domain/agent/agent_tool.dart';
import '../../domain/agent/agent_tools.dart';
import 'ui_strings.dart';

/// The page's ONLY state machine. Eight states, frozen by `SPEC-U-07` section 2.3.
enum AgentUiState {
  unconsented,
  keyMissing,
  offline,
  idle,
  sending,
  streaming,
  toolRunning,
  failed,
}

/// The sub-reason of `failed`. Not part of the state machine: it only picks the sentence and
/// whether 「重试」 is offered.
enum AgentFailureReason {
  network,
  invalidKey,
  rateLimited,
  serverError,
  timeout,
  streamBroken,
  truncated,
  toolUnparsable,
  toolRoundsExceeded,
}

/// Who wrote one in-memory line. `system` and `tool` are deliberately absent: neither ever
/// reaches this list (`SPEC-U-07` section 4.1).
enum AgentSpeaker { user, assistant }

/// One rendered line of the conversation.
class AgentMessageView {
  const AgentMessageView({
    required this.speaker,
    required this.text,
    required this.atMs,
  });

  final AgentSpeaker speaker;
  final String text;

  /// epoch milliseconds (UTC), `API-00` section 3.2.
  final int atMs;

  bool get isUser => speaker == AgentSpeaker.user;

  /// U-07 section 9: every message carries an accessible name that says WHO said it -- a screen
  /// reader otherwise reads a transcript as one undifferentiated wall of text.
  String get semanticsLabel =>
      isUser ? '我说：$text' : '智能体回答：$text';
}

/// The four card kinds (`SPEC-U-07` section 4.2).
enum AgentCardKind { health, meals, advice, handoff, toolFailed }

/// One delivery-platform handoff (`API-07` section 3.2/3.3).
///
/// The honesty rules live here, not in the widget: a disabled platform is not tappable and says
/// so, and an unverified one is tappable but MUST carry the second sentence. `SPEC-U-07` section
/// 2.4 calls this a hard requirement rather than a nicety, because a button that silently does
/// nothing is indistinguishable from a broken app.
class AgentHandoffView {
  const AgentHandoffView({
    required this.platformId,
    required this.label,
    required this.keyword,
    required this.enabled,
    required this.verified,
    this.url = '',
  });

  final String platformId;
  final String label;
  final String keyword;
  final bool enabled;

  /// The **web** search URL for this platform + keyword (`ADR-45`). It is what the in-app
  /// browser loads, so the user can see the platform's own result page -- real dishes, real
  /// photos, live prices -- without the app needing a data source it does not have.
  ///
  /// Empty on the "platform disabled" card, which has no keyword and therefore nothing to show.
  final String url;

  /// `true` only when the SSOT carries a real-device verification date (`verifiedOn`).
  final bool verified;

  /// Whether the in-app browser can be offered for this card.
  bool get canBrowse => enabled && url.isNotEmpty;

  String get title => UiStrings.agentHandoffTitle(label, keyword);
  String get buttonLabel => UiStrings.agentHandoffButton(label);

  /// The caveats the card must render, in reading order. Empty means "nothing to be honest
  /// about" -- which is a real state, not an omission.
  List<String> get caveats => <String>[
        if (!enabled) UiStrings.agentHandoffClosed,
        if (enabled && !verified) UiStrings.agentHandoffUnverified,
      ];

  String get semanticsLabel => '$title。$buttonLabel';
}

/// One card. A handoff card is the only kind that carries a button.
class AgentCardView {
  const AgentCardView({
    required this.kind,
    required this.title,
    this.lines = const <String>[],
    this.handoff,
  });

  final AgentCardKind kind;
  final String title;
  final List<String> lines;

  /// Non-null only for [AgentCardKind.handoff].
  final AgentHandoffView? handoff;

  String get semanticsLabel {
    final h = handoff;
    if (h != null) return h.semanticsLabel;
    if (lines.isEmpty) return title;
    return '$title：${lines.join('；')}';
  }
}

abstract final class AgentPresenter {
  AgentPresenter._();

  // ------------------------------------------------------------------ failure mapping

  /// Maps an `AcouDietError` code onto the page's sub-reason. A code outside the agent path
  /// returns `null`, which the page treats as `streamBroken` -- an honest "something broke"
  /// rather than a wrong claim about why.
  static AgentFailureReason? failureOf(AcouDietError error) => switch (error.code) {
        Codes.agentOffline => AgentFailureReason.network,
        Codes.agentUnauthorized => AgentFailureReason.invalidKey,
        Codes.agentRateLimited => AgentFailureReason.rateLimited,
        Codes.agentServerError => AgentFailureReason.serverError,
        Codes.agentTimeout => AgentFailureReason.timeout,
        Codes.agentStreamBroken => AgentFailureReason.streamBroken,
        Codes.agentToolCallUnparsable => AgentFailureReason.toolUnparsable,
        Codes.agentToolRoundsExceeded => AgentFailureReason.toolRoundsExceeded,
        _ => null,
      };

  /// The frozen sentence of each sub-reason (`SPEC-U-07` section 4.3). `truncated` is produced
  /// by the transport's `finish_reason == length`, which never arrives as an exception.
  static String failureText(AgentFailureReason reason) => switch (reason) {
        AgentFailureReason.network => UiStrings.agentErrorNetwork,
        AgentFailureReason.invalidKey => UiStrings.agentErrorInvalidKey,
        AgentFailureReason.rateLimited ||
        AgentFailureReason.serverError ||
        AgentFailureReason.timeout =>
          UiStrings.agentErrorService,
        AgentFailureReason.streamBroken => UiStrings.agentErrorStreamBroken,
        AgentFailureReason.truncated => UiStrings.agentErrorTruncated,
        AgentFailureReason.toolUnparsable => UiStrings.agentErrorToolUnparsable,
        AgentFailureReason.toolRoundsExceeded => UiStrings.agentErrorToolRounds,
      };

  /// `truncated` and `streamBroken` keep whatever the model already said (`ACD-AGENT-008`), so
  /// the page must NOT clear the transcript when it enters those failures. The same two are the
  /// ones a retry cannot fix: a second answer cannot be spliced onto the first.
  static bool keepsPartialText(AgentFailureReason reason) =>
      reason == AgentFailureReason.truncated || reason == AgentFailureReason.streamBroken;

  /// The degraded state that replaces the agent when the network is unreachable. Per `FF-26f`
  /// nothing else in the app is touched.
  static bool degradesToOffline(AgentFailureReason reason) =>
      reason == AgentFailureReason.network;

  // ------------------------------------------------------------------ card construction

  /// Turns one `AgentToolEvent`'s observation into cards.
  ///
  /// Delegates by TOOL NAME, never by sniffing the artifact shape: two tools could legitimately
  /// publish a `cards` key, and a shape-based dispatcher would silently render one as the other.
  static List<AgentCardView> cardsFrom({
    required String toolName,
    required AgentObservation observation,
    required List<TakeoutPlatform> platforms,
  }) {
    if (observation.status != 'success') {
      return const <AgentCardView>[
        AgentCardView(kind: AgentCardKind.toolFailed, title: UiStrings.agentCardFailedTitle),
      ];
    }
    switch (toolName) {
      case AgentToolNames.healthSummary:
        return <AgentCardView>[_healthCard(observation)];
      case AgentToolNames.recentMeals:
        return <AgentCardView>[_mealsCard(observation)];
      case AgentToolNames.recommendFood:
        return <AgentCardView>[_adviceCard(observation)];
      case AgentToolNames.proposeTakeout:
        return _handoffCards(observation, platforms);
      default:
        return const <AgentCardView>[
          AgentCardView(kind: AgentCardKind.toolFailed, title: UiStrings.agentCardFailedTitle),
        ];
    }
  }

  static AgentCardView _healthCard(AgentObservation o) {
    final a = o.artifacts;
    final range = a['range'] == 'today' ? UiStrings.agentRangeToday : UiStrings.agentRangeWeek;
    final lines = <String>[
      UiStrings.agentCardRangeLine(
        range,
        _intOf(a['record_count']),
        _intOf(a['snack_count']),
      ),
    ];
    final dims = <String>[
      if (a['regularity'] != null) '规律性 ${_intOf(a['regularity'])}',
      if (a['structure'] != null) '结构 ${_intOf(a['structure'])}',
      if (a['snack'] != null) '零食 ${_intOf(a['snack'])}',
      if (a['speed'] != null) '速度 ${_intOf(a['speed'])}',
    ];
    if (dims.isNotEmpty) lines.add(UiStrings.agentCardDimensionLine(dims.join('、')));
    final total = a['total_score'];
    final grade = a['grade'];
    if (total is num && grade is String && grade.isNotEmpty) {
      lines.add(UiStrings.agentCardScoreLine('${total.toInt()}', grade));
    }
    return AgentCardView(
      kind: AgentCardKind.health,
      title: UiStrings.agentCardHealthTitle,
      lines: lines,
    );
  }

  static AgentCardView _mealsCard(AgentObservation o) {
    final raw = o.artifacts['records'];
    final lines = <String>[];
    if (raw is List) {
      for (final row in raw) {
        if (row is! Map) continue;
        final label = row['class_label'];
        final atMs = row['eaten_at_ms'];
        final confidence = row['confidence'];
        if (label is! String || atMs is! num) continue;
        lines.add(UiStrings.agentCardRecordLine(
          label,
          _clock(atMs.toInt()),
          confidence is num ? '置信度 ${(confidence * 100).round()}%' : UiStrings.empty,
        ));
      }
    }
    return AgentCardView(
      kind: AgentCardKind.meals,
      title: UiStrings.agentCardRecentTitle,
      lines: lines,
    );
  }

  static AgentCardView _adviceCard(AgentObservation o) {
    final raw = o.artifacts['advice'];
    return AgentCardView(
      kind: AgentCardKind.advice,
      title: UiStrings.agentCardAdviceTitle,
      lines: <String>[
        if (raw is List) ...raw.whereType<String>(),
      ],
    );
  }

  /// Builds the handoff card(s). A platform the SSOT disables arrives in `skipped`, NOT in
  /// `cards` (`ProposeTakeoutSearchTool` refuses to build a URL for it), so the disabled card is
  /// reconstructed here from the platform table **and its own title says so**. Dropping it would
  /// hide the fact that the platform exists and is currently off (`API-07` section 3.3).
  static List<AgentCardView> _handoffCards(
    AgentObservation o,
    List<TakeoutPlatform> platforms,
  ) {
    final byId = <String, TakeoutPlatform>{for (final p in platforms) p.id: p};
    final out = <AgentCardView>[];

    final cards = o.artifacts['cards'];
    if (cards is List) {
      for (final row in cards) {
        if (row is! Map) continue;
        final id = row['platformId'];
        final label = row['label'];
        final keyword = row['keyword'];
        if (id is! String || label is! String || keyword is! String) continue;
        final platform = byId[id];
        out.add(AgentCardView(
          kind: AgentCardKind.handoff,
          title: UiStrings.agentHandoffTitle(label, keyword),
          handoff: AgentHandoffView(
            platformId: id,
            label: label,
            keyword: keyword,
            enabled: true,
            // The tool publishes `verified`; the platform table is the fallback so a card can
            // never look verified merely because a field was missing.
            verified: row['verified'] == true || (platform?.isVerified ?? false),
            // The web url the tool built. Taken from the card rather than re-derived here: a
            // second construction site for a URL template is a second place for it to drift.
            url: row['url'] is String ? row['url']! as String : '',
          ),
        ));
      }
    }

    final skipped = o.artifacts['skipped'];
    if (skipped is List) {
      for (final row in skipped) {
        if (row is! Map) continue;
        final id = row['id'];
        final reason = row['reason'];
        if (id is! String || reason != 'disabled_in_config') continue;
        final platform = byId[id];
        final label = platform?.label ?? id;
        out.add(AgentCardView(
          kind: AgentCardKind.handoff,
          title: UiStrings.agentHandoffTitle(label, ''),
          handoff: AgentHandoffView(
            platformId: id,
            label: label,
            keyword: '',
            enabled: false,
            verified: platform?.isVerified ?? false,
          ),
        ));
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ key masking

  /// The ONLY thing the UI may ever show of a credential (`FF-26b`): `maskApiKey` output, or the
  /// empty marker when there is nothing stored.
  static String maskedKey(String? storedKey) =>
      (storedKey == null || storedKey.isEmpty) ? UiStrings.apiKeyNone : maskApiKey(storedKey);

  static int _intOf(Object? v) => v is num ? v.toInt() : 0;

  /// `12:20` in local time -- the same shape the records page shows.
  static String _clock(int atMs) {
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

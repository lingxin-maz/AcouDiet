// app/lib/presentation/pages/agent/agent_page.dart
//
// U-07 · 智能体 -- the third tab (`ADR-44` amending `FF-23`). This page is the user-visible面 of
// `FF-26d`/`FF-26e`: what leaves the device, what never does, and where the app stops.
//
// THE THREE RULES THAT SHAPE THIS FILE
// ------------------------------------
//  1. THE GATE ORDER (`SPEC-U-07` section 2.2). Consent -> key -> network. A user who has not
//     consented generates ZERO requests and is not even asked for a credential (`FF-24` item 9),
//     which is why `_init` reads the consent record before it mentions the key at all.
//  2. THE TOOL'S OWN TEXT NEVER RENDERS (`API-07` section 4.3). Tool results become cards whose
//     copy comes from `UiStrings` and whose slots are filled with numbers and names only.
//  3. THE HANDOFF BUTTON IS THE ONLY WAY OUT (`SPEC-U-07` section 2.2 step 10, `FF-26i`). No
//     code path in this file opens anything on its own; `propose_takeout_search` returns a card
//     and then stops.
//
// It renders, it does not decide: every sentence and every failure mapping lives in
// `presenters/agent_presenter.dart`, where `tool/ui_presenter_tests.dart` can read it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/flavour.dart' show acouIsOffline;
import '../../../domain/agent/agent_service.dart';
import '../../presenters/agent_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/app_services.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/acou_app_bar.dart';
import '../profile/profile_page.dart';
import 'takeout_browser_page.dart';

class AgentPage extends StatefulWidget {
  const AgentPage({super.key, this.onDeclineConsent});

  /// `SPEC-U-07` section 2.2 step 2: 「暂不开启」 writes nothing, sends nothing and returns the
  /// user to index 0. The shell owns the index, so it owns this callback.
  final VoidCallback? onDeclineConsent;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  AgentUiState _state = AgentUiState.unconsented;
  AgentFailureReason? _failure;
  bool _retryable = false;

  final List<AgentMessageView> _messages = <AgentMessageView>[];
  final List<AgentCardView> _cards = <AgentCardView>[];
  String _streaming = '';
  String? _handoffMessage;
  bool _contextTrimmed = false;

  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  bool _consentChecked = false;
  String _keyMask = UiStrings.apiKeyNone;

  AgentRuntime? _agent;
  StreamSubscription<AgentEvent>? _turn;
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _agent = AcouScope.readServices(context).agent;
    if (_initialised) return;
    _initialised = true;
    // SYNCHRONOUS on purpose: the composition root has already refreshed the gate
    // (`AgentRuntime.refresh`), so the first frame of this page performs no I/O at all -- and a
    // page whose `build` can await is a page that can rebuild twice for one answer.
    _applyGate();
  }

  @override
  void dispose() {
    unawaited(_turn?.cancel());
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ gates

  /// Decides which of the three gates the page shows. It reads ONLY the cached flags: no request
  /// is built, let alone sent (`SPEC-U-07` section 8).
  void _applyGate() {
    final agent = _agent;
    if (agent == null) {
      // No runtime was wired (the offline/test placeholder wiring). The eight-state machine has no
      // "unavailable" state, so this maps onto the degraded `offline` state -- which is exactly
      // what an unwired agent is -- and issues nothing.
      setState(() => _state = AgentUiState.offline);
      return;
    }
    setState(() {
      _keyMask = agent.keyMask.isEmpty ? UiStrings.apiKeyNone : agent.keyMask;
      if (!agent.gate.consented) {
        _state = AgentUiState.unconsented;
      } else if (!agent.gate.hasKey) {
        _state = AgentUiState.keyMissing;
      } else {
        _state = AgentUiState.idle;
      }
    });
  }

  /// Re-reads the gate from disk. ONLY called from a path that already performed real I/O (the
  /// return from `U-05`, consent grant, revoke), never from `build`.
  Future<void> _refreshGate() async {
    final agent = _agent;
    if (agent == null) return;
    await agent.refresh();
    if (!mounted) return;
    _applyGate();
  }

  Future<void> _grantConsent() async {
    final agent = _agent;
    if (agent == null || !_consentChecked) return;
    await agent.consent.write(true, decidedAtMs: DateTime.now().millisecondsSinceEpoch);
    await _refreshGate();
  }

  /// Revoke (`SPEC-C-06` section 2.4). Cancel first, then delete, then re-gate: the order matters
  /// because a turn that is still streaming would otherwise land its `delta`s in a page the user
  /// believes is closed.
  Future<void> _revokeConsent() async {
    final agent = _agent;
    if (agent == null) return;
    await _turn?.cancel();
    _turn = null;
    await agent.revoke();
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _cards.clear();
      _streaming = '';
      _handoffMessage = null;
      _contextTrimmed = false;
      _consentChecked = false;
      _failure = null;
    });
    _applyGate();
  }

  // ------------------------------------------------------------------ the turn

  bool get _busy =>
      _state == AgentUiState.sending ||
      _state == AgentUiState.streaming ||
      _state == AgentUiState.toolRunning;

  bool get _canSubmit => !_busy && _input.text.trim().isNotEmpty;

  Future<void> _send() async {
    final agent = _agent;
    final text = _input.text.trim();
    if (agent == null || text.isEmpty || _busy) return;
    _input.clear();
    _inputFocus.requestFocus();
    setState(() {
      _messages.add(AgentMessageView(
        speaker: AgentSpeaker.user,
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
      ));
      _streaming = '';
      _cards.clear();
      _handoffMessage = null;
      _failure = null;
      _state = AgentUiState.sending;
    });
    _turn = agent.service.runTurn(userText: text).listen(_onEvent);
  }

  void _onEvent(AgentEvent event) {
    if (!mounted) return;
    switch (event) {
      case AgentTextEvent(:final text):
        setState(() {
          _streaming += text;
          _state = AgentUiState.streaming;
        });
      case AgentToolEvent(
          :final toolName,
          :final observation,
          :final proposalOnly,
        ):
        setState(() {
          _cards.addAll(AgentPresenter.cardsFrom(
            toolName: toolName,
            observation: observation,
            platforms: _agent?.platforms ?? const [],
          ));
          _state = AgentUiState.toolRunning;
          // `proposalOnly` is the flag that makes a result a BUTTON rather than an action
          // (`API-05` section 13.4.4). It is read, never acted on.
          _handoffMessage = proposalOnly ? null : _handoffMessage;
        });
      case AgentDoneEvent(:final truncated):
        setState(() {
          if (_streaming.isNotEmpty) {
            _messages.add(AgentMessageView(
              speaker: AgentSpeaker.assistant,
              text: _streaming,
              atMs: DateTime.now().millisecondsSinceEpoch,
            ));
            _streaming = '';
          }
          // A turn that ran out of output budget still FINISHED, so the state stays `idle` and
          // the user can keep going -- but the partial answer is labelled (`API-07` section 5.3).
          // Silently showing a sentence cut off mid-clause as a complete reply is the defect this
          // flag exists to prevent, and until `AgentDoneEvent` carried it the label was dead code.
          if (truncated) {
            _failure = AgentFailureReason.truncated;
            _retryable = true;
          }
          _state = AgentUiState.idle;
        });
      case AgentErrorEvent(:final error):
        final reason = AgentPresenter.failureOf(error) ?? AgentFailureReason.streamBroken;
        setState(() {
          _failure = reason;
          _retryable = error.retryable;
          // A truncated answer and a dropped stream KEEP what was received (`ACD-AGENT-008`):
          // discarding the model's own sentence would leave the user with less than they had.
          if (_streaming.isNotEmpty) {
            _messages.add(AgentMessageView(
              speaker: AgentSpeaker.assistant,
              text: _streaming,
              atMs: DateTime.now().millisecondsSinceEpoch,
            ));
            _streaming = '';
          }
          _state = AgentPresenter.degradesToOffline(reason)
              ? AgentUiState.offline
              : AgentUiState.failed;
        });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _failure = null;
      _state = AgentUiState.idle;
    });
  }

  // ------------------------------------------------------------------ the ONLY way out

  /// The takeout handoff. Called by the card's button and by nothing else.
  ///
  /// `canOpen` is asked first, and a `false` answer is REPORTED rather than ignored: a button
  /// that silently does nothing is indistinguishable from a broken app (`SPEC-U-07` section 6).
  Future<void> _launchHandoff(AgentHandoffView handoff) async {
    final agent = _agent;
    if (agent == null || !handoff.enabled) return;
    final reachable = await agent.launcher.canOpen(handoff.platformId);
    if (!mounted) return;
    if (!reachable) {
      setState(() => _handoffMessage = UiStrings.agentHandoffUnopenable);
      return;
    }
    final opened =
        await agent.launcher.openSearch(platformId: handoff.platformId, keyword: handoff.keyword);
    if (!mounted) return;
    if (!opened) setState(() => _handoffMessage = UiStrings.agentHandoffUnopenable);
  }

  /// ADR-45: show the platform's OWN result page inside the App, so the user can see real dishes
  /// with real photos without the App pretending to have a menu it does not have.
  ///
  /// This is a second, independent way OUT of the conversation, and it is deliberately NOT the
  /// same as `_launchHandoff`: one leaves the App, the other does not. Both are started by a real
  /// tap and by nothing else (`API-05` section 13.4.4).
  Future<void> _openTakeoutBrowser(AgentHandoffView handoff) async {
    if (!handoff.canBrowse) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TakeoutBrowserPage(
          platformLabel: handoff.label,
          url: handoff.url,
        ),
      ),
    );
    if (!mounted) return;
    // The user may have ended up in the platform's app from inside the browser (a page link can
    // hand off too), so the page's own state is refreshed rather than assumed unchanged.
    setState(() {});
  }

  /// `SPEC-U-07` section 3: the key gate's button pushes `U-05` (`ProfilePage`). The agent page
  /// deliberately does NOT collect the credential itself -- one screen writes it, and it is the
  /// settings row.
  Future<void> _openKeySettings() async {    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
    );
    if (!mounted) return;
    await _refreshGate();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (_state != AgentUiState.unconsented)
        IconButton(
          icon: const Icon(Icons.cloud_off_outlined),
          // The frozen revoke wording doubles as the accessible name: an icon-only control with
          // no name is the classic TalkBack dead end.
          tooltip: UiStrings.agentRevokeAction,
          onPressed: () => unawaited(_revokeConsent()),
        ),
    ];
    return AcouScrollEdge(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AcouPageHeader(title: UiStrings.agentTitle, actions: actions),
        body: DecoratedBox(
          decoration: AcouTheme.pageGradientDecoration(),
          child: SafeArea(
            top: false,
            child: switch (_state) {
              AgentUiState.unconsented => _consentGate(context),
              AgentUiState.keyMissing => _keyGate(context),
              AgentUiState.offline => _degraded(context, UiStrings.agentErrorNetwork, false),
              AgentUiState.failed =>
                _degraded(context, AgentPresenter.failureText(_failure!), _retryable),
              _ => _conversation(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _padded(Widget child) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: kToolbarHeight + MediaQuery.paddingOf(context).top + AcouTheme.spaceMd,
          left: AcouTheme.spacePage,
          right: AcouTheme.spacePage,
          bottom: AcouTheme.spaceXl + AcouTheme.bottomInset(context),
        ),
        children: [child],
      );

  Widget _gateCard({required String title, required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceSm),
            ...children,
          ],
        ),
      );

  Widget _clause(String heading, String body) => Padding(
        padding: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(heading, style: AcouTheme.metric),
            const SizedBox(height: AcouTheme.spaceXs),
            Text(body, style: AcouTheme.bodyMuted),
          ],
        ),
      );

  /// The consent gate (`SPEC-C-06` section 2.1/2.2). All five disclosures are rendered; the
  /// primary button stays disabled until the box is ticked -- there is no "dismiss = consent".
  Widget _consentGate(BuildContext context) => _padded(
        Semantics(
          container: true,
          label: UiStrings.agentConsentTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _gateCard(
                title: UiStrings.agentConsentTitle,
                children: [
                  Text(UiStrings.agentConsentLead, style: AcouTheme.body),
                  const SizedBox(height: AcouTheme.spaceSm),
                  _clause(UiStrings.agentConsentSendTitle, UiStrings.agentConsentSendBody),
                  _clause(UiStrings.agentConsentNotSendTitle, UiStrings.agentConsentNotSendBody),
                  _clause(UiStrings.agentConsentLossTitle, UiStrings.agentConsentLossBody),
                  _clause(UiStrings.agentConsentCostTitle, UiStrings.agentConsentCostBody),
                  _clause(UiStrings.agentConsentRevokeTitle, UiStrings.agentConsentRevokeBody),
                ],
              ),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: CheckboxListTile(
                  value: _consentChecked,
                  onChanged: (v) => setState(() => _consentChecked = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(UiStrings.agentConsentCheckbox, style: AcouTheme.bodyMuted),
                ),
              ),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: FilledButton(
                  onPressed: _consentChecked ? () => unawaited(_grantConsent()) : null,
                  child: const Text(UiStrings.agentConsentConfirm),
                ),
              ),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: OutlinedButton(
                  onPressed: () {
                    // Writes nothing and sends nothing (SPEC-U-07 section 2.2 step 2).
                    setState(() => _consentChecked = false);
                    widget.onDeclineConsent?.call();
                  },
                  child: const Text(UiStrings.agentConsentDecline),
                ),
              ),
            ],
          ),
        ),
      );

  /// The key gate. The key is never entered here: the button pushes `U-05`, which is the only
  /// screen that writes the credential file (`SPEC-U-07` section 3).
  Widget _keyGate(BuildContext context) => _padded(
        _gateCard(
          title: UiStrings.agentKeyMissing,
          children: [
            if (_keyMask != UiStrings.apiKeyNone) ...[
              Text('${UiStrings.apiKeyTitle}：$_keyMask', style: AcouTheme.bodyMuted),
              const SizedBox(height: AcouTheme.spaceSm),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              child: FilledButton(
                onPressed: () => unawaited(_openKeySettings()),
                child: const Text(UiStrings.agentGoSettings),
              ),
            ),
            const SizedBox(height: AcouTheme.spaceSm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              child: OutlinedButton(
                onPressed: () => unawaited(_revokeConsent()),
                child: const Text(UiStrings.agentRevokeAction),
              ),
            ),
          ],
        ),
      );

  /// A degraded state. It never blocks anything else (`FF-26f`) -- it is this page and only this
  /// page that changes.
  Widget _degraded(BuildContext context, String message, bool canRetry) => _padded(
        _gateCard(
          title: message,
          children: [
            if (canRetry)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: FilledButton(
                  onPressed: () => unawaited(_retry()),
                  child: const Text(UiStrings.agentRetry),
                ),
              ),
            const SizedBox(height: AcouTheme.spaceSm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              child: OutlinedButton(
                onPressed: () => unawaited(_openKeySettings()),
                child: const Text(UiStrings.agentGoSettings),
              ),
            ),
          ],
        ),
      );

  Widget _conversation(BuildContext context) => Column(
        children: [
          Expanded(
            child: ListView.builder(
              // ADR-24/`SPEC-U-07` section 8: a builder with index-keyed children, so an incoming
              // `delta` does not rebuild the whole transcript.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                top: kToolbarHeight + MediaQuery.paddingOf(context).top + AcouTheme.spaceMd,
                left: AcouTheme.spacePage,
                right: AcouTheme.spacePage,
                bottom: AcouTheme.spaceMd,
              ),
              itemCount: _messageCount,
              itemBuilder: _itemBuilder,
            ),
          ),
          _composer(context),
        ],
      );

  int get _messageCount {
    var n = _messages.length + _cards.length;
    if (_streaming.isNotEmpty) n++;
    if (_messages.isEmpty && _cards.isEmpty && _streaming.isEmpty) n = 1;
    if (_state == AgentUiState.failed) n = n + 1;
    if (_contextTrimmed) n = n + 1;
    if (_handoffMessage != null) n = n + 1;
    return n;
  }

  Widget _itemBuilder(BuildContext context, int index) {
    var i = index;
    if (_messages.isEmpty && _cards.isEmpty && _streaming.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceXl),
        child: Text(UiStrings.agentEmpty, style: AcouTheme.bodyMuted),
      );
    }
    if (i < _messages.length) return _bubble(_messages[i]);
    i -= _messages.length;
    if (i < _cards.length) return _card(_cards[i]);
    i -= _cards.length;
    if (_streaming.isNotEmpty) {
      if (i == 0) {
        return Semantics(
          container: true,
          liveRegion: _state == AgentUiState.streaming,
          label: '智能体正在回答',
          child: Text(_streaming, style: AcouTheme.body),
        );
      }
      i -= 1;
    }
    if (_state == AgentUiState.failed) {
      if (i == 0) {
        return _gateCard(
          title: AgentPresenter.failureText(_failure ?? AgentFailureReason.streamBroken),
          children: [
            if (_retryable)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: FilledButton(
                  onPressed: () => unawaited(_retry()),
                  child: const Text(UiStrings.agentRetry),
                ),
              ),
          ],
        );
      }
      i -= 1;
    }
    if (_contextTrimmed) {
      if (i == 0) return Text(UiStrings.agentContextTrimmed, style: AcouTheme.caption);
      i -= 1;
    }
    return Text(_handoffMessage ?? '', style: AcouTheme.bodyMuted);
  }

  Widget _bubble(AgentMessageView m) => Semantics(
        container: true,
        label: m.semanticsLabel,
        child: Align(
          alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
            padding: const EdgeInsets.all(AcouTheme.spaceSm),
            decoration: AcouTheme.cardDecoration(
              fill: m.isUser ? AcouTheme.mintSoft : AcouTheme.surface,
            ),
            child: Text(m.text, style: AcouTheme.body),
          ),
        ),
      );

  Widget _card(AgentCardView card) {
    final handoff = card.handoff;
    return Semantics(
      container: true,
      label: card.semanticsLabel,
      child: Container(
        margin: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.title, style: AcouTheme.metric),
            for (final line in card.lines) ...[
              const SizedBox(height: AcouTheme.spaceXs),
              Text(line, style: AcouTheme.bodyMuted),
            ],
            if (handoff != null) ...[
              const SizedBox(height: AcouTheme.spaceXs),
              // The two honesty branches (SPEC-U-07 section 2.4). A disabled platform is not
              // tappable, and an unverified one says so NEXT TO the button rather than in a note
              // the user will never read.
              for (final caveat in handoff.caveats)
                Text(caveat, style: AcouTheme.caption),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: FilledButton(
                  onPressed:
                      handoff.enabled ? () => unawaited(_launchHandoff(handoff)) : null,
                  child: Text(handoff.buttonLabel),
                ),
              ),
              // ADR-45 (user requirement 「显示带有图片的外卖选项」): a second, clearly different
              // route -- stay in the App and look at the platform's own result page, which carries
              // the real dishes and the real photos.
              //
              // It is a SEPARATE button rather than a replacement, because the two answers are
              // different answers: "open the app" leaves, "browse here" does not. Collapsing them
              // would decide for the user which one they wanted.
              //
              // The whole block is inside a compile-time flavour branch: the `offline` build must
              // contain no web view at all (`FF-24` item 4 -- it is the build whose claim is "this
              // package declares no network permission").
              if (!acouIsOffline && handoff.canBrowse) ...[
                const SizedBox(height: AcouTheme.spaceXs),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                  child: OutlinedButton(
                    onPressed: () => unawaited(_openTakeoutBrowser(handoff)),
                    child: const Text(UiStrings.agentHandoffBrowse),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: AcouTheme.spacePage,
          right: AcouTheme.spacePage,
          top: AcouTheme.spaceSm,
          bottom: AcouTheme.spaceSm + AcouTheme.bottomInset(context),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => unawaited(_send()),
                decoration: const InputDecoration(hintText: UiStrings.agentInputHint),
              ),
            ),
            const SizedBox(width: AcouTheme.spaceSm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              child: FilledButton(
                // Empty or whitespace-only input cannot submit (SPEC-U-07 section 2.4).
                onPressed: _canSubmit ? () => unawaited(_send()) : null,
                child: const Text(UiStrings.agentSend),
              ),
            ),
          ],
        ),
      );
}

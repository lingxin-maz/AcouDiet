// app/lib/presentation/pages/detect/detect_page.dart
//
// U-02 · AI 检测页 -- the page the on-site demonstration depends on.
//
// What this page deliberately does **not** do:
//  * it does not start a session on its own: detection is user-initiated (FF-24 item 6);
//  * it does not show a detection history list (X-05) or any free-form class editing (X-02);
//  * it never promises a faster result than FF-20a's 4-5 second window.
//
// The C-03 gate is enforced here as well as in the shell: when the start-up handshake has not
// passed, the page renders the explanation and **no start button** (SPEC-U-02 section 6).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../presenters/detect_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/async_value.dart';
import '../../state/notifiers.dart';
import '../../theme/acou_theme.dart';
import '../../theme/food_class.dart';
import '../../widgets/acou_app_bar.dart';
import '../../widgets/demo_banner.dart';
import '../../widgets/food_icon.dart';
import '../../widgets/state_view.dart';
import '../../widgets/waveform_view.dart';

class DetectPage extends StatelessWidget {
  const DetectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    final services = scope.services;
    final notifier = scope.notifiers.detect;

    if (services.detectionBlocked) {
      // Fail fast: a configuration mismatch keeps this page unreachable and says so.
      //
      // ADR-24: the gate is blocked, but it is still a page of this app -- it paints the same
      // gradient as every other page, so "the whole app moved to the mockups' background" has no
      // exception and `test/ui/page_chrome_test.dart` can assert it without special-casing.
      return Scaffold(
        // ADR-38: this branch used to build a bare `AppBar` with no `extendBodyBehindAppBar`,
        // so the gate screen alone showed an opaque bar sitting on the scaffold colour with the
        // gradient starting underneath it. It is a page of this app like any other.
        extendBodyBehindAppBar: true,
        appBar: const AcouPageHeader(title: UiStrings.detectTabTitle),
        body: DecoratedBox(
          decoration: AcouTheme.pageGradientDecoration(),
          child: StateView(
            status: ViewStatus.error,
            message: services.detectionBlockedMessage,
            code: services.handshakeError?.code,
          ),
        ),
      );
    }

    return AcouScrollEdge(
      child: Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const AcouPageHeader(title: UiStrings.detectTabTitle),
      body: DecoratedBox(
        decoration: AcouTheme.pageGradientDecoration(),
        child: AcouBuilder<DetectPredictionView>(
          notifier: notifier,
          builder: (context, value) => ListView(
            padding: EdgeInsets.only(
              top: kToolbarHeight + MediaQuery.paddingOf(context).top,
              left: AcouTheme.spacePage,
              right: AcouTheme.spacePage,
              bottom: AcouTheme.spaceXl + AcouTheme.bottomInset(context),
            ),
            children: [
            // The injection badge is driven only by `patch.source == "inject"`.
            if (DetectPresenter.injectionBadge(notifier.uiState, injected: notifier.injected)
                .isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
                child: DemoTag(text: UiStrings.sampleDemoBadge),
              ),
            const _WaveCircle(),
            const SizedBox(height: AcouTheme.spaceMd),
            Text(
              DetectPresenter.statusText(notifier.uiState),
              style: AcouTheme.sectionTitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AcouTheme.spaceXs),
            Text(
              // FF-20a: the only legal latency sentence.
              DetectPresenter.firstConfirmHint,
              style: AcouTheme.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AcouTheme.spaceLg),
            _PredictionCard(notifier: notifier, value: value),
            const SizedBox(height: AcouTheme.spaceMd),
            _BehaviorRows(notifier: notifier),
            const SizedBox(height: AcouTheme.spaceLg),
            _PrimaryButton(notifier: notifier),
            if (notifier.lastError != null) ...[
              const SizedBox(height: AcouTheme.spaceSm),
              _ErrorNotice(notifier: notifier),
            ],
            if (notifier.savedRecord != null) ...[
              const SizedBox(height: AcouTheme.spaceMd),
              _SavedBanner(notifier: notifier),
            ],
          ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The waveform circle: a pure visualisation of the `level` stream (silence is a flat line).
///
/// ADR-24: one large mint disc with the waveform inside it, as the mockups draw the detection
/// screen. The disc is still driven by the same `level` notifier and still says nothing numeric.
class _WaveCircle extends StatelessWidget {
  const _WaveCircle();

  @override
  Widget build(BuildContext context) {
    final notifier = AcouScope.notifiersOf(context).detect;
    return Column(
      children: [
        WaveCircle(level: notifier.level, size: 220),
        const SizedBox(height: AcouTheme.spaceMd),
        ValueListenableBuilder<double>(
          valueListenable: notifier.level,
          builder: (context, level, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LevelIndicator(level: level),
              const SizedBox(width: AcouTheme.spaceSm),
              Text(
                level > 0.02 ? '正在采集进食声音' : '当前静默',
                style: AcouTheme.bodyMuted,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The prediction area: the grey unconfirmed chip, the two-choice question, or the confirmed
/// three-element card.
class _PredictionCard extends StatelessWidget {
  const _PredictionCard({required this.notifier, required this.value});

  final DetectNotifier notifier;
  final AsyncValue<DetectPredictionView> value;

  @override
  Widget build(BuildContext context) {
    final view = value.data ?? DetectPredictionView.sensing;
    final confirmed = view.confirmed;
    final border = confirmed ? AcouTheme.mint : AcouTheme.outline;
    // ADR-24: the card is laid out the way the mockups draw it -- a mint food tile, the
    // knowledge-base name, the attribute as a chip, and the confidence large on the right. It
    // shows the same three elements the frozen template carries; only their arrangement moved.
    final catalog = AcouScope.servicesOf(context).catalog;
    final classId = _classIdOfLabel(view.labelText);
    final name = view.visible ? view.labelText : UiStrings.detectSensing;
    return Semantics(
      label: view.semanticsText,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  confirmed ? '确认结果' : UiStrings.detectUnconfirmedHint,
                  style: AcouTheme.caption,
                ),
                const Spacer(),
                if (confirmed)
                  const Icon(Icons.verified_outlined, size: 18, color: AcouTheme.mintDeep),
              ],
            ),
            const SizedBox(height: AcouTheme.spaceSm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (view.visible && classId != null)
                  FoodIconBadge(classId: classId, size: 52)
                else if (view.visible)
                  const FoodIconBadge(classId: -1, size: 52),
                if (view.visible) const SizedBox(width: AcouTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: (confirmed || view.visible)
                            ? AcouTheme.headline.copyWith(color: AcouTheme.ink)
                            : AcouTheme.sectionTitle.copyWith(color: AcouTheme.inkMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (view.attributeText.isNotEmpty) ...[
                        const SizedBox(height: AcouTheme.spaceXs),
                        _AttributeChip(text: view.attributeText),
                      ],
                      if (!view.visible)
                        Text('正在感知…', style: AcouTheme.caption),
                    ],
                  ),
                ),
                if (view.visible && view.confidenceText.isNotEmpty)
                  Text(
                    view.confidenceText,
                    style: AcouTheme.scoreLarge.copyWith(
                      color: confirmed ? AcouTheme.gradeGood : AcouTheme.inkMuted,
                      fontSize: 34,
                    ),
                  ),
              ],
            ),
            if (view.shouldAskUser) ...[
              const SizedBox(height: AcouTheme.spaceSm),
              _AskUserRow(notifier: notifier, view: view),
            ],
          ],
        ),
      ),
    );
  }

  /// The card is given the Chinese name; the tile needs the class id, so the name is mapped back
  /// through the same frozen table the knowledge base is keyed by. An unknown name yields `null`
  /// and the card renders the placeholder tile instead of guessing a food.
  static int? _classIdOfLabel(String label) {
    if (label.isEmpty) return null;
    for (final c in FoodClassId.values) {
      if (c.zhName == label) return c.id;
    }
    return null;
  }
}

/// The knowledge-base attribute as a soft chip (「脆性高加工零食」).
class _AttributeChip extends StatelessWidget {
  const _AttributeChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AcouTheme.spaceSm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: AcouTheme.mintSoft,
          borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
        ),
        child: Text(
          text,
          style: AcouTheme.caption.copyWith(color: AcouTheme.gradeGood),
        ),
      );
}

/// X-02's degraded form: exactly two answers, no free-form editing.
class _AskUserRow extends StatelessWidget {
  const _AskUserRow({required this.notifier, required this.view});

  final DetectNotifier notifier;
  final DetectPredictionView view;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              // Focus order is yes -> no (SPEC-U-02 section 8).
              child: FilledButton(
                onPressed: () => notifier.answerConfirmation(accepted: true),
                child: const Text(UiStrings.askUserYes),
              ),
            ),
          ),
          const SizedBox(width: AcouTheme.spaceSm),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
              child: OutlinedButton(
                // 「否」= reject the suggestion. It deliberately does NOT call
                // `answerConfirmation(accepted: false)`: that path requires an
                // `alternativeClassId`, and v1.0 has no class picker, so every tap used to throw
                // (`ACD-DB-004`) and drop the page into its error state.
                onPressed: () => notifier.rejectSuggestion(),
                child: const Text(UiStrings.askUserNo),
              ),
            ),
          ),
        ],
      );
}

/// The four behaviour rows. A missing metric renders the empty marker, never a zero.
class _BehaviorRows extends StatelessWidget {
  const _BehaviorRows({required this.notifier});

  final DetectNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final b = notifier.behavior;
    final rows = <(String, String)>[
      (UiStrings.behaviorChewLabel, b.chewText),
      (UiStrings.behaviorIntervalLabel, b.intervalText),
      (UiStrings.behaviorDurationLabel, b.durationText),
      (UiStrings.behaviorSpeedLabel, b.speedText),
    ];
    return Container(
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(row.$1, style: AcouTheme.bodyMuted)),
                  Text(row.$2, style: AcouTheme.metric),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.notifier});

  final DetectNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final state = notifier.uiState;
    // The label and the action come from the same predicate, so the button can never announce
    // one thing and do another (`confirmed` is a running state: see
    // `DetectPresenter.primaryActionIsStop`).
    final running = DetectPresenter.primaryActionIsStop(state);
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget + 8),
          child: FilledButton.icon(
            onPressed: () {
              // ADR-39: starting and stopping a capture is the one action in this app whose effect
              // the finger cannot see -- the microphone opens and the disc starts moving later.
              // Apple's rule (`inter-haptic-feedback`) is to spend a haptic exactly there, and not
              // on ordinary navigation. `mediumImpact` is the weight Apple uses for a control that
              // changes what the device is doing.
              unawaited(HapticFeedback.mediumImpact());
              unawaited(running ? notifier.stop() : notifier.startRealtime());
            },
            icon: Icon(running ? Icons.stop_circle_outlined : Icons.graphic_eq),
            label: Text(DetectPresenter.primaryActionLabel(state)),
          ),
        ),
        const SizedBox(height: AcouTheme.spaceSm),
        // Mode B is the documented fallback when the room is too noisy or the microphone is
        // busy; it never becomes the default (FF-24 item 6).
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
          child: TextButton.icon(
            onPressed: running ? null : notifier.startSample,
            icon: const Icon(Icons.science_outlined),
            label: const Text(UiStrings.sampleDemoBadge),
          ),
        ),
      ],
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.notifier});

  final DetectNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final error = notifier.lastError!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.cardDecoration(fill: AcouTheme.demoBanner),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(DetectPresenter.errorText(error),
              style: AcouTheme.body.copyWith(color: AcouTheme.demoBannerInk)),
          const SizedBox(height: AcouTheme.spaceXs),
          Text('${error.code}${error.retryable ? ' · 可重试' : ''}',
              style: AcouTheme.caption.copyWith(color: AcouTheme.demoBannerInk)),
        ],
      ),
    );
  }
}

/// `已自动记录` plus the record summary and a way into the detail page.
class _SavedBanner extends StatelessWidget {
  const _SavedBanner({required this.notifier});

  final DetectNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final record = notifier.savedRecord!;
    final food = AcouScope.servicesOf(context).catalog.byClassId(record.classId);
    final text = DetectPresenter.savedBanner(record, food);
    return Container(
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.cardDecoration(fill: AcouTheme.surfaceMuted),
      child: Row(
        children: [
          FoodIconBadge(classId: record.classId),
          const SizedBox(width: AcouTheme.spaceSm),
          Expanded(child: Text(text, style: AcouTheme.body)),
        ],
      ),
    );
  }
}

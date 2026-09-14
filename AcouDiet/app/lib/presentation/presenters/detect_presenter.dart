// app/lib/presentation/presenters/detect_presenter.dart
//
// U-02 (AI detection page) display logic. PURE DART (no Flutter import).
//
// The five -- and only five -- `VoteStage` renderings (API-02 section 4, FF-20):
//   none          -> the sensing placeholder;
//   observing     -> the grey unconfirmed prediction, or the "no clear food" wording once the
//                    EMA has formed but stayed below `tauLow`;
//   unconfirmed   -> the grey prediction with its percentage;
//   lowConfidence -> the two-choice question (X-02's degraded form: exactly two answers);
//   confirmed     -> the three-element result card.
//
// FF-20a is honoured here and nowhere else: the page may state the 4-5 second window and may
// never claim a faster one. FF-21f/FF-21g govern the behaviour row: the chew count carries the
// "about" hedge, the degraded copy carries no digit, and a missing value is the empty marker.

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/demo.dart';
import '../../domain/model/diet_record.dart';
import '../../domain/model/food_info.dart';
import '../../domain/model/inference.dart';
import '../../domain/service/portion_estimator.dart';
import '../theme/acou_format.dart';
import 'food_catalog.dart';
import 'ui_strings.dart';

/// The page's own state machine (SPEC-U-02 section 2.3), kept separate from `VoteStage`.
enum DetectUiState {
  idle,
  requestingPermission,
  starting,
  listening,
  unconfirmed,
  confirmed,
  askingUser,
  ending,
  ended,
  error,
}

/// The prediction card in either of its two shapes.
class DetectPredictionView {
  const DetectPredictionView({
    required this.visible,
    required this.confirmed,
    required this.confidenceHigh,
    required this.text,
    required this.labelText,
    required this.confidenceText,
    required this.attributeText,
    required this.askUserText,
    required this.shouldAskUser,
    required this.semanticsText,
  });

  /// `false` for the `none` stage: nothing to show yet beyond the sensing placeholder.
  final bool visible;

  /// `true` for the result card, `false` for the grey unconfirmed chip.
  final bool confirmed;

  /// Whether the confidence reached the confirmation threshold (colour is never the only cue).
  final bool confidenceHigh;

  /// `薯片 62%` / `薯片 / 91% / 脆性高加工零食` / `正在感知…` / `未识别到明确食物`.
  final String text;

  final String labelText;
  final String confidenceText;
  final String attributeText;

  /// Empty unless the two-choice question is on screen.
  final String askUserText;
  final bool shouldAskUser;

  final String semanticsText;

  static const DetectPredictionView sensing = DetectPredictionView(
    visible: false,
    confirmed: false,
    confidenceHigh: false,
    text: UiStrings.detectSensing,
    labelText: '',
    confidenceText: '',
    attributeText: '',
    askUserText: '',
    shouldAskUser: false,
    semanticsText: UiStrings.detectSensing,
  );

  static const DetectPredictionView unrecognised = DetectPredictionView(
    visible: true,
    confirmed: false,
    confidenceHigh: false,
    text: UiStrings.detectUnrecognised,
    labelText: '',
    confidenceText: '',
    attributeText: '',
    askUserText: '',
    shouldAskUser: false,
    semanticsText: UiStrings.detectUnrecognised,
  );
}

/// The four behaviour rows of API-04 section 4 (X-07's rhythm sigma is not among them).
class DetectBehaviorView {
  const DetectBehaviorView({
    required this.chewText,
    required this.intervalText,
    required this.durationText,
    required this.speedText,
    required this.combinedText,
    required this.degraded,
  });

  final String chewText;
  final String intervalText;
  final String durationText;
  final String speedText;

  /// `约 45 次 / 0.7 秒 / 4 分 23 秒 / 偏快` (SPEC-U-02 section 4), or the degraded form.
  final String combinedText;
  final bool degraded;

  static const DetectBehaviorView empty = DetectBehaviorView(
    chewText: AcouFormat.noValue,
    intervalText: AcouFormat.noValue,
    durationText: AcouFormat.noValue,
    speedText: AcouFormat.noValue,
    combinedText: '${AcouFormat.noValue} / ${AcouFormat.noValue} / ${AcouFormat.noValue} / ${AcouFormat.noValue}',
    degraded: false,
  );

  /// [degraded] carries FF-21g: no frozen field stores the chew-count MAE state, so the
  /// assembly layer injects it (an interpretation recorded in the delivery report).
  static DetectBehaviorView of(BehaviorMetrics? m, {bool degraded = false}) {
    if (m == null) return DetectBehaviorView.empty;
    final chew = DetectPresenter.chewText(m.chewCount, degraded: degraded);
    final interval = DetectPresenter.intervalText(m.avgChewIntervalSeconds);
    final duration = AcouFormat.durationText(m.durationSeconds);
    final speed = AcouFormat.speedGradeText(m.speedGrade);
    return DetectBehaviorView(
      chewText: chew,
      intervalText: interval,
      durationText: duration,
      speedText: speed,
      combinedText: '$chew / $interval / $duration / $speed',
      degraded: degraded,
    );
  }
}

/// The session timeline row (start / end / end reason).
class DetectTimelineView {
  const DetectTimelineView({
    required this.startedText,
    required this.endedText,
    required this.endReasonText,
    required this.patchesText,
  });

  final String startedText;
  final String endedText;
  final String endReasonText;
  final String patchesText;

  static const DetectTimelineView empty = DetectTimelineView(
    startedText: AcouFormat.noValue,
    endedText: AcouFormat.noValue,
    endReasonText: UiStrings.detectEnded,
    patchesText: AcouFormat.noValue,
  );

  /// `endReason` is a machine token (`silence` / `user` / `error`); the UI maps it to words and
  /// never prints the raw token.
  static DetectTimelineView of(SessionSummary? summary) {
    if (summary == null) return empty;
    return DetectTimelineView(
      startedText: AcouFormat.clock(summary.startedAtMs),
      endedText: AcouFormat.clock(summary.stoppedAtMs),
      endReasonText: switch (summary.endReason) {
        'silence' => '静默结束',
        'user' => '已手动停止',
        'error' => '异常结束',
        _ => UiStrings.detectEnded,
      },
      patchesText: '${summary.patchesEmitted}',
    );
  }
}

abstract final class DetectPresenter {
  DetectPresenter._();

  /// FF-20a: the only latency wording the page may show. Exposed as a named constant so a copy
  /// change cannot silently drop the hedge.
  static const String firstConfirmHint = UiStrings.firstConfirmHint;

  /// The percentage a grey prediction chip shows, e.g. `薯片 62%`.
  static String greyPredictionText(String label, double confidence) =>
      '$label ${AcouFormat.percent(confidence)}';

  /// The three-element result card, e.g. `薯片 / 91% / 脆性高加工零食`.
  static String confirmedText(String label, double confidence, String attribute) =>
      '$label / ${AcouFormat.percent(confidence)} / $attribute';

  /// The single entry point of the two-choice question (X-02 degraded form).
  static String askUserText(String label) => UiStrings.askUserText(label);

  /// FF-21f / FF-21g.
  static String chewText(int? chewCount, {bool degraded = false}) {
    if (degraded) return UiStrings.chewRhythmDegraded;
    return AcouFormat.chewCountText(chewCount);
  }

  /// `0.7 秒` / `--`.
  static String intervalText(double? seconds) => seconds == null
      ? AcouFormat.noValue
      : '${seconds.toStringAsFixed(1)} 秒';

  /// The level-2 progress line: how many consecutive windows have agreed so far. The
  /// denominator is the frozen `confirmConsecutivePatches` (FF-20), never a literal.
  static String progressText(AggregatedDecision decision) =>
      '连续一致 ${decision.consecutiveCount}/${cfg.FeatureConfig.votingConfirmConsecutivePatches} 个窗口';

  /// The status sentence of the waveform area.
  static String statusText(DetectUiState state) => switch (state) {
        DetectUiState.idle => UiStrings.detectWaiting,
        DetectUiState.requestingPermission => UiStrings.detectWaiting,
        DetectUiState.starting => UiStrings.detectWaiting,
        DetectUiState.listening => UiStrings.detectWaiting,
        DetectUiState.unconfirmed => UiStrings.detectListening,
        DetectUiState.askingUser => UiStrings.detectListening,
        DetectUiState.confirmed => UiStrings.detectSaved,
        DetectUiState.ending => UiStrings.detectListening,
        DetectUiState.ended => UiStrings.detectEnded,
        DetectUiState.error => UiStrings.detectEnded,
      };

  /// The Chinese display name of the class the decision points at.
  ///
  /// `SPEC-U-02` section 4 writes the card as `薯片 / 91% / 脆性高加工零食`, and U-06 section 2.4
  /// forbids showing a raw class token. `decision.label` is the frozen FF-19 **token**
  /// (`chips`), so the name must come from the knowledge base exactly like the record card's
  /// does. The token is only used when the catalogue cannot resolve the id -- a degraded state
  /// that stays visible rather than being guessed at.
  static String displayNameOf(AggregatedDecision decision, FoodCatalog? catalog) {
    final id = decision.classId;
    if (id != null) {
      final info = catalog?.byClassId(id);
      if (info != null) return info.zhName;
    }
    return decision.label ?? UiStrings.unknownCategory;
  }

  /// The stage -> card projection.
  ///
  /// [heldConfirmed] is the previous confirmed decision: SPEC-U-02 section 2.3 states that the
  /// result card **keeps its previous state** until a *new* confirmation arrives, so a later
  /// lower-confidence patch must not wipe it (acceptance criterion 6, "30 patches must not
  /// flicker"). The sheet of the two-choice question still opens while a card is held, because
  /// `shouldAskUser` is taken from the fresh decision, not from the held card.
  static DetectPredictionView predictionOf(
    AggregatedDecision? decision, {
    DetectPredictionView? heldConfirmed,
    FoodCatalog? catalog,
  }) {
    if (decision == null || decision.stage == VoteStage.none) {
      return heldConfirmed ?? DetectPredictionView.sensing;
    }

    final held = heldConfirmed;
    // The raw FF-19 token decides *whether* a class is known; the displayed name comes from the
    // knowledge base below.
    final rawLabel = decision.label;
    final confidence = decision.smoothedConfidence;

    // `observing` covers two very different situations: the EMA has not formed yet, and the
    // EMA has formed but stayed under `tauLow`. Only the second one is a result ("no clear
    // food"); the first stays a grey prediction. `VoteStage` deliberately has no `rejected`
    // value (API-02 section 4), so the distinction is drawn from the threshold here.
    final unrecognised =
        decision.stage == VoteStage.observing && confidence < cfg.FeatureConfig.votingTauLow;

    if (held != null && held.confirmed && decision.stage != VoteStage.confirmed) {
      // Hold the card, but keep the fresh confirmation question visible.
      final asked = decision.shouldAskUser && rawLabel != null;
      return DetectPredictionView(
        visible: true,
        confirmed: true,
        confidenceHigh: true,
        text: held.text,
        labelText: held.labelText,
        confidenceText: held.confidenceText,
        attributeText: held.attributeText,
        askUserText: asked ? askUserText(displayNameOf(decision, catalog)) : '',
        shouldAskUser: asked,
        semanticsText: held.semanticsText,
      );
    }

    if (decision.stage == VoteStage.confirmed) {
      if (rawLabel == null) return DetectPredictionView.sensing;
      final label = displayNameOf(decision, catalog);
      final attribute = catalog?.byClassId(decision.classId ?? -1)?.attribute ?? '';
      final text = attribute.isEmpty
          ? greyPredictionText(label, confidence)
          : confirmedText(label, confidence, attribute);
      return DetectPredictionView(
        visible: true,
        confirmed: true,
        confidenceHigh: true,
        text: text,
        labelText: label,
        confidenceText: AcouFormat.percent(confidence),
        attributeText: attribute,
        askUserText: '',
        shouldAskUser: false,
        semanticsText: '确认结果 $label，置信度 ${AcouFormat.percent(confidence)}'
            '${attribute.isEmpty ? '' : '，$attribute'}',
      );
    }

    if (unrecognised && !decision.shouldAskUser) {
      return DetectPredictionView.unrecognised;
    }

    if (rawLabel == null) return DetectPredictionView.sensing;
    final label = displayNameOf(decision, catalog);

    if (decision.stage == VoteStage.lowConfidence || decision.shouldAskUser) {
      return DetectPredictionView(
        visible: true,
        confirmed: false,
        confidenceHigh: false,
        text: askUserText(label),
        labelText: label,
        confidenceText: AcouFormat.percent(confidence),
        attributeText: '',
        askUserText: askUserText(label),
        shouldAskUser: true,
        semanticsText: '${askUserText(label)}${UiStrings.askUserYes}或${UiStrings.askUserNo}',
      );
    }

    // observing (EMA still forming) and unconfirmed both render the grey chip.
    return DetectPredictionView(
      visible: true,
      confirmed: false,
      confidenceHigh: false,
      text: greyPredictionText(label, confidence),
      labelText: label,
      confidenceText: AcouFormat.percent(confidence),
      attributeText: '',
      askUserText: '',
      shouldAskUser: false,
      semanticsText: '未确认预测 $label ${AcouFormat.percent(confidence)}',
    );
  }

  /// The demonstration badge of the detection page: `patch.source == "inject"` is the **only**
  /// trigger (API-01 section 3.2) -- `DietRecord.source` is never consulted here.
  static String injectionBadge(DetectUiState state, {required bool injected}) =>
      injected && state != DetectUiState.idle ? UiStrings.sampleDemoBadge : '';

  /// `已自动记录` plus the four-row summary, or empty while nothing has been saved.
  ///
  /// ADR-23: the kilocalorie belongs to **this** record's duration, so it is estimated here
  /// rather than read off the knowledge-base standard portion.
  static String savedBanner(DietRecord? saved, FoodInfo? food) {
    if (saved == null) return '';
    final name = food?.zhName ?? UiStrings.unknownCategory;
    final time = AcouFormat.clock(saved.eatenAtMs);
    if (food == null) return '${UiStrings.detectSaved} · $time $name';
    final portion = PortionEstimator.of(food, durationSeconds: saved.durationSeconds);
    return '${UiStrings.detectSaved} · $time $name '
        '${AcouFormat.recordKcalCombined(saved.attribute, portion)}';
  }

  /// The user-facing error line: the domain message plus an actionable second half. The
  /// permission branch distinguishes a retryable rejection from a permanent one.
  static String errorText(AcouDietError error) => switch (error.code) {
        Codes.permPermanentlyDenied => '${error.message}（请前往系统设置）',
        Codes.permDenied => '${error.message}（可再次授权）',
        Codes.audioDeviceBusy => '${error.message}，请先关闭录音类应用',
        Codes.cfgMismatch => error.message,
        _ => error.message,
      };

  /// `去设置` for a permanent rejection, `授权` otherwise.
  static String permissionActionLabel(AcouDietError error) =>
      error.code == Codes.permPermanentlyDenied ? '去设置' : '授权';

  /// The primary button's label, including its action word for screen readers.
  static String primaryActionLabel(DetectUiState state) => primaryActionIsStop(state)
      ? UiStrings.detectStop
      : (state == DetectUiState.ended ? UiStrings.detectAgain : UiStrings.startDetect);

  /// Whether the primary button **stops** the session, as opposed to starting one.
  ///
  /// `confirmed` and `ending` belong to the running set (`SPEC-U-02` section 2.3): the session
  /// behind the confirmed card is still live, so the same button must stay "停止检测". Treating
  /// `confirmed` as idle made the result card offer a second "开始 AI 检测" while the first
  /// `AudioRecord` was still open -- a start the native side refuses (`maxConcurrentSessions =
  /// 1`) and which stranded the live session with no way left to stop it.
  static bool primaryActionIsStop(DetectUiState state) => switch (state) {
        DetectUiState.listening ||
        DetectUiState.unconfirmed ||
        DetectUiState.askingUser ||
        DetectUiState.confirmed ||
        DetectUiState.ending =>
          true,
        _ => false,
      };

  /// Whether the detection page may be reached at all: a handshake failure with
  /// `ACD-CFG-001` blocks it outright (SPEC-U-02 section 6, fail fast).
  static bool pageReachable({required AcouDietError? handshakeError}) =>
      handshakeError == null || !handshakeError.isConfigMismatch;
}

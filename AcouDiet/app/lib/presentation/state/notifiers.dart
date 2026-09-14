// app/lib/presentation/state/notifiers.dart
//
// The Riverpod replacement: one small `ChangeNotifier` per page, all published as
// `AsyncValue<T>` so the widgets render loading / empty / error / ready through the single
// `StateView` (see README section 1 and `docs/reports/c04_dependency_deviation.md`).
//
// Every notifier follows the same shape, which is why the base class exists:
//   * it never touches a DAO or a channel -- only `AppServices` members (API-00 section 1);
//   * a refresh keeps the previous value while loading, so a page dims its content instead of
//     flashing white (SPEC-U-01 section 8 "刷新"); 
//   * a failure becomes `AsyncValue.error` carrying the `AcouDietError`, and a retry affordance
//     appears only when the code is retryable;
//   * a state update after `dispose()` is dropped, because a page can be popped while a query
//     is still in flight.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/time.dart';
import '../../domain/model/demo.dart';
import '../../domain/model/diet_record.dart';
import '../../domain/model/health_score.dart';
import '../../domain/model/inference.dart';
import '../../domain/model/summaries.dart';
import '../../domain/service/detection_session.dart';
import '../presenters/detect_presenter.dart';
import '../presenters/home_presenter.dart';
import '../presenters/records_presenter.dart';
import '../presenters/report_presenter.dart';
import '../presenters/selfcheck_presenter.dart';
import '../presenters/settings_presenter.dart';
import '../presenters/ui_strings.dart';
import '../theme/acou_format.dart' show ChartAxis;
import 'app_services.dart';
import 'async_value.dart';

/// Shared plumbing: a mounted flag, the guarded async call and the error mapping.
abstract class AcouNotifier<T> extends ChangeNotifier {
  AcouNotifier(this.services) : _state = AsyncValue<T>.idle();

  final AppServices services;
  AsyncValue<T> _state;
  bool _disposed = false;

  AsyncValue<T> get state => _state;

  /// `true` once [dispose] ran; guards every asynchronous continuation.
  bool get mounted => !_disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @protected
  void publish(AsyncValue<T> next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @protected
  void publishValue(T value) => publish(AsyncValue<T>.ready(value));

  @protected
  void publishError(AcouDietError e) =>
      publish(AsyncValue<T>.error(e, _state.data));

  /// Marks the value as "empty" without inventing a placeholder value; the widget layer reads
  /// the status, not `data`.
  @protected
  void publishEmpty() => publish(AsyncValue<T>.error(
        AcouDietError(Codes.unknown, '暂无数据'),
        _state.data,
      ));

  /// Runs [body], mapping a domain failure to the error state and re-throwing anything else
  /// (a non-domain exception is a defect, not a user-facing state).
  @protected
  Future<void> guard(Future<void> Function() body) async {
    publish(AsyncValue<T>.loading(_state.data));
    try {
      await body();
    } on AcouDietError catch (e) {
      publishError(e);
    } on StateError catch (e) {
      publishError(AcouDietError(Codes.unknown, e.message));
    }
  }

  /// A refresh that refuses to show stale data (ADR-23): the page renders its **loading** state
  /// until the new value is in hand.
  ///
  /// `reload()` keeps the previous value while loading (`AsyncValue.loading(previous)`), which
  /// is right for a pull-to-refresh -- the content dims instead of flashing white -- but wrong
  /// when the user has just switched to another tab and is looking at numbers they did not ask
  /// for. Dropping the previous value first makes the loading branch of every page take over.
  Future<void> reloadFresh() async {
    publish(AsyncValue<T>.loading());
    await reload();
  }

  /// The default retry entry point the pages wire to `StateView.onRetry`.
  Future<void> reload();
}

/// Convenience for every page that needs "the last N local days".
DateRange lastLocalDaysWindow(AppServices services, int days) {
  final (start, end) = TimeUtil.lastLocalDays(days, nowMsOverride: services.nowMsOverride);
  return DateRange(start, end);
}

/// U-01: today's score, energy band, week counter and record list.
class HomeNotifier extends AcouNotifier<HomeView> {
  HomeNotifier(super.services);

  /// ADR-23: the score card's window. The energy row, the week counter and the record list
  /// below it stay "today"; the four-dimension score uses the same seven local days as the
  /// 本周 counter and the report, which is why the two pages can no longer disagree.
  /// ADR-34: the「AI 周综述」card and the on-device advice polish layer were REMOVED at the
  /// user's request. Nothing here depends on a language model any more; this class is back to
  /// the plain four-dimension home view.
  static const int scoreWindowDays = 7;

  @override
  Future<void> reload() async {
    await guard(() async {
      final today = await services.stats.today();
      final week = await services.stats.week();
      HealthScore? score;
      try {
        // The previous equal-length window is what `deltaVsYesterday` compares against.
        final (start, end) =
            TimeUtil.lastLocalDays(scoreWindowDays, nowMsOverride: services.nowMsOverride);
        score = await services.scores.score(range: DateRange(start, end));
      } on AcouDietError {
        // Local degradation only: the score card shows the empty markers while the rest of the
        // page keeps working (SPEC-U-01 section 6).
        score = null;
      }
      final demoActive = await services.refreshDemoActive();
      publishValue(HomeView.of(
        today: today,
        week: week,
        score: score,
        catalog: services.catalog,
        demoActive: demoActive,
        recordsUnavailable: false,
      ));
    });
  }
}

/// U-03: the timeline, the summary bar, the weekly sentence and one record's detail.
class RecordsNotifier extends AcouNotifier<RecordsView> {
  RecordsNotifier(super.services);

  /// The first-screen window; SPEC-U-03 section 2.1 fixes it at the recent seven days and
  /// section 10 #3 leaves 7 vs 3 to a later measurement.
  static const int windowDays = 7;

  @override
  Future<void> reload() async {
    await guard(() async {
      final range = lastLocalDaysWindow(services, windowDays);
      final records = await services.diet.byRange(range);

      TodaySummary? today;
      var summaryUnavailable = false;
      try {
        today = await services.stats.today();
      } on AcouDietError {
        summaryUnavailable = true;
      }

      String? summaryText;
      var summaryFailed = false;
      try {
        final report = await services.reports.weekly(range: range);
        summaryText = report.summaryText;
      } on AcouDietError {
        summaryFailed = true;
      }

      publishValue(RecordsView.of(
        records: records,
        today: today,
        summaryText: summaryText,
        summaryUnavailable: summaryUnavailable || summaryFailed,
        catalog: services.catalog,
        nowMs: services.nowMs(),
      ));
    });
  }

  /// The detail page's data, fetched on demand from the frozen repository methods.
  Future<(DietRecord?, BehaviorMetrics?)> detail(String recordId) async {
    final record = await services.diet.byId(recordId);
    if (record == null) return (null, null);
    final metrics = await services.diet.metricsByRecordId(recordId);
    return (record, metrics);
  }
}

/// U-04: the report. The axis toggle changes the chart only; it never refetches.
class ReportNotifier extends AcouNotifier<ReportView> {
  ReportNotifier(super.services);

  static const int trendDays = 7;

  /// ADR-24: how many rows the 最近识别记录 tiles show. A cap, not a window -- the tiles are a
  /// glance at the newest records, and the records page remains the complete history.
  static const int recentRecordCount = 6;

  ChartAxis _axis = ChartAxis.score;
  ChartAxis get axis => _axis;

  /// Switching the calibre redraws the chart from the data already in hand
  /// (SPEC-U-04 acceptance 3: the request count must not change).
  void setAxis(ChartAxis axis) {
    if (_axis == axis) return;
    _axis = axis;
    notifyListeners();
  }

  @override
  Future<void> reload() async {
    await guard(() async {
      final range = lastLocalDaysWindow(services, trendDays);
      final report = await services.reports.weekly(range: range);
      // ADR-23: ONE per-day pass feeds both the trend chart and the new 「每日四维评分」 list,
      // so the two can never disagree and the day's score is computed only once.
      final daily = await services.reports.dailyScores(days: trendDays);
      final trendPoints = <TrendPoint>[
        for (final d in daily)
          TrendPoint(
            date: d.date,
            estimatedKcal: d.estimatedKcal,
            totalScore: d.score?.totalScore,
          ),
      ];
      final agg = await services.stats.week();

      // ADR-24: two extra reads for the blocks the mockups draw, both on the **same** frozen
      // window and both degrading to "no data" rather than failing the page -- a report that
      // cannot list the newest records is still a report.
      double? meanChewInterval;
      try {
        meanChewInterval =
            (await services.stats.chewStats(range)).meanChewIntervalSeconds;
      } on AcouDietError {
        meanChewInterval = null;
      }
      var recent = const <RecordCardText>[];
      try {
        final records = await services.diet.byRange(range);
        recent = records
            .reversed
            .take(recentRecordCount)
            .map((r) => RecordsView.cardOf(r, services.catalog))
            .toList(growable: false);
      } on AcouDietError {
        recent = const <RecordCardText>[];
      }

      final demoActive = await services.refreshDemoActive();

      // ADR-34: advices are the rule engine's output, verbatim. The optional on-device polish
      // layer (and its cache) was removed with the language model; there is nothing here that
      // can fail or need a timeout any more.
      publishValue(ReportView.of(
        score: report.score,
        summaryText: report.summaryText,
        deltas: report.deltas,
        advices: report.advices,
        trendPoints: trendPoints,
        dailyScores: daily,
        agg: agg,
        meanChewIntervalSeconds: meanChewInterval,
        recentRecords: recent,
        demoActive: demoActive,
      ));
    });
  }
}

/// U-05: the local profile, the day count, and the two data actions.
class ProfileNotifier extends AcouNotifier<SettingsView> {
  ProfileNotifier(super.services);

  bool _copied = false;
  String? _actionMessage;

  /// The transient line shown after "copy as text" or a failed clear.
  bool get copied => _copied;
  String? get actionMessage => _actionMessage;

  @override
  Future<void> reload() async {
    await guard(() async {
      final profile = await services.profile.load();
      int? activeDays;
      try {
        activeDays = await services.stats.activeDays();
      } on AcouDietError {
        // SPEC-U-05 section 6: a failed day aggregate degrades to the empty marker only.
        activeDays = null;
      }
      final demoActive = await services.refreshDemoActive();
      final count = await services.diet.countAll();

      // ADR-24: the three-up 「本周健康数据概览」 panel. Deliberately the **same** seven-day window
      // the report page calls 「本周」, so the two pages cannot show two different weeks; and one
      // failed query degrades the whole panel to `--` instead of mixing a live tile with a dead
      // one (SPEC-U-05 section 6 already does this for `activeDays`).
      int? weekRecords;
      int? weekSnacks;
      double? meanChewInterval;
      var overviewUnavailable = false;
      try {
        final range = lastLocalDaysWindow(services, ReportNotifier.trendDays);
        final week = await services.stats.week();
        weekRecords = week.recordCount;
        weekSnacks = week.snackCount;
        meanChewInterval =
            (await services.stats.chewStats(range)).meanChewIntervalSeconds;
      } on AcouDietError {
        overviewUnavailable = true;
      }

      publishValue(SettingsView.of(
        nickname: profile.nickname,
        activeDays: activeDays,
        versionText: services.versionText,
        demoActive: demoActive,
        recordCount: count,
        weekRecordCount: weekRecords,
        weekSnackCount: weekSnacks,
        meanChewIntervalSeconds: meanChewInterval,
        overviewUnavailable: overviewUnavailable,
      ));
    });
  }

  Future<void> saveProfile(UserProfile profile) async {
    try {
      await services.profile.save(profile);
      _actionMessage = null;
      await reload();
    } on AcouDietError {
      _actionMessage = UiStrings.saveFailed;
      if (mounted) notifyListeners();
    }
  }

  /// SPEC-U-05 section 2.2 step 5 / FF-24 item 7: a transaction that clears every table, then
  /// the one native temporary-audio cleanup path. A failure is reported, never swallowed.
  Future<bool> clearAllData() async {
    try {
      await services.maintenance.clearAllData();
      await services.maintenance.clearTempAudio();
      _actionMessage = null;
      await reload();
      return true;
    } on AcouDietError {
      _actionMessage = UiStrings.clearFailed;
      if (mounted) notifyListeners();
      return false;
    }
  }

  Future<bool> clearDemoData() async {
    try {
      await services.demoData.clearDemoDataset();
      _actionMessage = null;
      await reload();
      return true;
    } on AcouDietError {
      _actionMessage = UiStrings.clearFailed;
      if (mounted) notifyListeners();
      return false;
    }
  }

  /// ADR-P4: the portability action writes **only** the system clipboard. No file, no share
  /// intent, no network, no new permission.
  Future<bool> copyAsText() async {
    final records = await services.diet.byRange(DateRange(0, 1 << 62));
    final text = SettingsPresenter.clipboardText(records, services.catalog);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _copied = true;
      _actionMessage = UiStrings.copiedToClipboard;
      if (mounted) notifyListeners();
      return true;
    } catch (_) {
      // A clipboard failure must never fall back to writing a file: the contract forbids it.
      _copied = false;
      _actionMessage = UiStrings.copyFailed;
      if (mounted) notifyListeners();
      return false;
    }
  }
}

/// U-02: the detection session state machine, driven by `DetectionSession`.
class DetectNotifier extends AcouNotifier<DetectPredictionView> {
  DetectNotifier(super.services) : _prediction = DetectPredictionView.sensing {
    publish(AsyncValue<DetectPredictionView>.ready(_prediction));
  }

  final ValueNotifier<double> level = ValueNotifier<double>(0);

  DetectUiState _uiState = DetectUiState.idle;
  DetectPredictionView _prediction;
  DetectPredictionView? _heldConfirmed;
  DetectBehaviorView _behavior = DetectBehaviorView.empty;
  DietRecord? _savedRecord;
  bool _injected = false;
  AcouDietError? _lastError;
  bool _sessionRunning = false;

  DetectUiState get uiState => _uiState;
  DetectPredictionView get prediction => _prediction;
  DetectBehaviorView get behavior => _behavior;
  DietRecord? get savedRecord => _savedRecord;
  bool get injected => _injected;
  AcouDietError? get lastError => _lastError;
  DetectionSessionHandle? _handle;

  @override
  Future<void> reload() async {
    // The detection page has no "load": it waits for the user to start a session.
    publish(AsyncValue<DetectPredictionView>.ready(_prediction));
  }

  bool get blocked => services.detectionBlocked;

  /// `true` while a session is live or on its way in or out. The primary button must never be
  /// able to open a second `AudioRecord`: the native side admits one session at a time
  /// (`maxConcurrentSessions = 1`), so the second `startSession` is rejected while the first
  /// one keeps the microphone -- leaving a live session with no UI left to stop it.
  bool get _busy =>
      _sessionRunning ||
      _uiState == DetectUiState.requestingPermission ||
      _uiState == DetectUiState.starting ||
      _uiState == DetectUiState.ending;

  void _setState(DetectUiState next) {
    _uiState = next;
    if (mounted) notifyListeners();
  }

  /// Waveform level tap (`API-01` section 3.2 `level` events, 10 Hz).
  ///
  /// The `mounted` check is load-bearing, not decoration: [dispose] calls `level.dispose()`,
  /// and these events come from the **real platform channel** (`AudioBridgeAndroid.emit`), so one
  /// can land after the notifier is gone. Assigning to a disposed `ValueNotifier` throws
  /// `A ValueNotifier<double> was used after being disposed` as an *uncaught async* error.
  void _onLevel(double v) {
    if (mounted) level.value = v;
  }

  /// Starts Mode A. Permission is requested first; a rejection is a state, not an exception.
  Future<void> startRealtime() async {
    if (blocked || _busy) return;
    _lastError = null;
    _setState(DetectUiState.requestingPermission);
    final (granted, permanentlyDenied) = await services.bridge.requestPermission();
    if (!granted) {
      _lastError = AcouDietError(
        permanentlyDenied ? Codes.permPermanentlyDenied : Codes.permDenied,
        permanentlyDenied ? '需要录音权限才能开始检测（已永久拒绝）' : '需要录音权限才能开始检测',
      );
      _setState(DetectUiState.error);
      return;
    }
    _setState(DetectUiState.starting);
    try {
      final handle = await DetectionSessionHandle.open(
        services: services,
        onState: _onSessionState,
        onLevel: _onLevel,
      );
      _handle = handle;
      _sessionRunning = true;
      _setState(DetectUiState.listening);
    } on AcouDietError catch (e) {
      _lastError = e;
      _sessionRunning = false;
      _setState(DetectUiState.error);
    }
  }

  /// Starts Mode B (injected sample) -- the fallback when the microphone or the room fails.
  Future<void> startSample() async {
    if (blocked || _busy) return;
    _lastError = null;
    _setState(DetectUiState.starting);
    try {
      final handle = await DetectionSessionHandle.open(
        services: services,
        onState: _onSessionState,
        onLevel: _onLevel,
      );
      _handle = handle;
      _sessionRunning = true;
      _injected = true;
      _setState(DetectUiState.listening);
    } on AcouDietError catch (e) {
      _lastError = e;
      _sessionRunning = false;
      _setState(DetectUiState.error);
    }
  }

  void _onSessionState(DetectionState s) {
    _injected = false;
    // ADR-23: the behaviour rows follow the session live (chew count / eating duration / speed),
    // instead of staying placeholders until `stop()`. A reading with no evidence yet keeps the
    // empty markers rather than zeroes.
    _behavior = DetectBehaviorView.of(s.metrics);
    final view = DetectPresenter.predictionOf(
      s.decision,
      heldConfirmed: _heldConfirmed,
      catalog: services.catalog,
    );
    if (view.confirmed) _heldConfirmed = view;
    _prediction = view;
    publish(AsyncValue<DetectPredictionView>.ready(view));
    _setState(switch (s.decision.stage) {
      VoteStage.confirmed => DetectUiState.confirmed,
      VoteStage.lowConfidence => DetectUiState.askingUser,
      VoteStage.observing => DetectUiState.unconfirmed,
      VoteStage.unconfirmed => DetectUiState.unconfirmed,
      // `none` is the first patch of a session (or just after a reset): the page keeps
      // listening, it does not fall back to idle.
      VoteStage.none => DetectUiState.listening,
    });
  }

  /// Answers the Level-3 two-choice question (X-02's degraded form: exactly two answers).
  void answerConfirmation({required bool accepted, int? alternativeClassId}) {
    try {
      _handle?.session.answerConfirmation(
        accepted: accepted,
        alternativeClassId: alternativeClassId,
      );
      _setState(DetectUiState.listening);
    } on AcouDietError catch (e) {
      _lastError = e;
      _setState(DetectUiState.error);
    }
  }

  /// The 「否」button: dismiss the suggestion without naming a replacement class.
  ///
  /// It must NOT go through [answerConfirmation] — see the defect write-up on
  /// `DetectionSession.rejectSuggestion`: v1.0 has no class-picker, so `accepted: false` had no
  /// `alternativeClassId` to send and therefore threw on **every** tap.
  void rejectSuggestion() {
    try {
      _handle?.session.rejectSuggestion();
      _setState(DetectUiState.listening);
    } on AcouDietError catch (e) {
      _lastError = e;
      _setState(DetectUiState.error);
    }
  }

  /// Records the current confirmation manually (the record button of U-02).
  void acceptCurrentAsRecord() {
    try {
      _handle?.session.acceptCurrentAsRecord();
    } on AcouDietError catch (e) {
      _lastError = e;
      _setState(DetectUiState.error);
    }
  }

  Future<void> stop() async {
    // `ending` refuses a second `stopSession` (SPEC-U-02 section 2.3): the native state machine
    // has already left RUNNING and a repeat would surface `ACD-SESS-001` to the user.
    if (_uiState == DetectUiState.ending) return;
    final handle = _handle;
    if (handle == null) return;
    _setState(DetectUiState.ending);
    try {
      final outcome = await handle.session.stop();
      _behavior = DetectBehaviorView.of(outcome.metrics);
      _savedRecord = outcome.records.isEmpty ? null : outcome.records.last;
      await services.bridge.clearTempAudio();
    } on AcouDietError catch (e) {
      _lastError = e;
    } finally {
      _sessionRunning = false;
      _handle = null;
      // Both taps on the native event stream are released **here**, not at app teardown. The
      // native side owns a single sink and only re-arms it when the channel reports `cancel`
      // (API-01 section 3.1); a level tap left alive would keep the broadcast controller from
      // ever reaching zero listeners, so the *next* session would inherit the previous
      // subscription -- that is the "the microphone opens but nothing works" defect.
      // Disposing first also drops any in-flight `DetectionState` from `session.stop()`, which
      // would otherwise flip the page back to `listening` after `ended`. A teardown failure must
      // not strand the page in `ending` either (that state owns the only button there is).
      try {
        await handle.dispose();
      } catch (_) {
        // The subscriptions are already unusable; the state transition below is what matters.
      }
      _setState(DetectUiState.ended);
    }
  }

  /// `true` while a session runs: the mode switch refuses to move (API-04 section 7.2).
  bool get sessionRunning => _sessionRunning;

  /// Cancels the subscriptions and releases the session. Called by the scope on teardown.
  Future<void> disposeHandle() async {
    await _handle?.dispose();
    _handle = null;
    _sessionRunning = false;
  }

  @override
  void dispose() {
    level.dispose();
    super.dispose();
  }
}

/// Thin wrapper so the notifier holds one object instead of two subscriptions.
class DetectionSessionHandle {
  DetectionSessionHandle._(this.session, this._stateSub, this._levelSub);

  final DetectionSession session;
  final StreamSubscription<DetectionState>? _stateSub;
  final StreamSubscription<Map<Object?, Object?>>? _levelSub;

  /// Opens a session and wires both halves of the native event stream: `patch` events drive the
  /// session (inference + aggregation) and `level` events drive the waveform animation only.
  /// `DetectionSession` deliberately ignores `level`, so the level tap is separate here.
  ///
  /// Both taps come from the same `bridge.events(sessionId:)` stream -- the bridge hands out one
  /// stream per session id -- and **both** must be cancelled for the channel to report `cancel`
  /// to the native side and let it bind the next session (see [dispose]).
  static Future<DetectionSessionHandle> open({
    required AppServices services,
    required void Function(DetectionState state) onState,
    required void Function(double level) onLevel,
  }) async {
    final session = services.newDetectionSession();
    final stateSub = session.states.listen(onState);
    final id = _newSessionId();
    final levelSub = services.bridge.events(sessionId: id).listen((event) {
      if (event['type'] != 'level') return;
      final rms = (event['rms'] as num?)?.toDouble() ?? 0;
      onLevel(rms.clamp(0.0, 1.0));
    });
    await session.start(sessionId: id);
    services.registry?.register(session);
    return DetectionSessionHandle._(session, stateSub, levelSub);
  }

  static String _newSessionId() {
    // API-00 section 3.4: `S-<epochMs>-<4 hex>`, generated on the Dart side.
    final ms = DateTime.now().millisecondsSinceEpoch;
    final hex = (ms % 0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'S-$ms-$hex';
  }

  /// Releases both taps. This is what makes the native side see `onCancel` and drop its single
  /// event subscription, so the next `startSession` starts from a clean binding; it is also
  /// idempotent, because the page and the scope can both reach the end of a session.
  Future<void> dispose() async {
    await _levelSub?.cancel();
    await _stateSub?.cancel();
    await session.dispose();
  }
}

/// M-04: the self-check panel and its three mode buttons.
class SelfCheckNotifier extends AcouNotifier<SelfCheckView> {
  SelfCheckNotifier(super.services) {
    publish(const AsyncValue<SelfCheckView>.ready(SelfCheckView.idle));
  }

  DemoMode _mode = DemoMode.realtime;
  bool _running = false;
  String? _switchFailure;

  DemoMode get mode => _mode;
  bool get running => _running;

  /// `code + reason + suggested action` after a failed switch (SPEC-M-04 section 2.2 step 7).
  String? get switchFailure => _switchFailure;

  @override
  Future<void> reload() async {
    if (_running) return; // a concurrent check is refused: the button is disabled
    _running = true;
    _switchFailure = null;
    publish(AsyncValue<SelfCheckView>.loading(state.data));
    try {
      final controller = services.demoController;
      _mode = controller.currentMode;
      final report = await controller.runSelfCheck();
      publishValue(SelfCheckView.of(report));
    } on AcouDietError catch (e) {
      publishError(e);
    } finally {
      _running = false;
    }
  }

  /// Switches the demonstration mode; a failure keeps the current mode and reports why.
  Future<bool> switchMode(DemoMode target) async {
    _switchFailure = null;
    try {
      final controller = services.demoController;
      await controller.switchTo(target);
      _mode = controller.currentMode;
      if (mounted) notifyListeners();
      return true;
    } on AcouDietError catch (e) {
      _switchFailure =
          '${e.code} · ${e.message} · ${SelfCheckPresenter.switchActionFor(e.code)}';
      if (mounted) notifyListeners();
      return false;
    }
  }

  /// Loads the Track 2 dataset (Mode C's prerequisite) and reports the reason on failure.
  Future<bool> loadReportDemo() async {
    _switchFailure = null;
    try {
      await services.demoController.loadReportDemo();
      _mode = services.demoController.currentMode;
      if (mounted) notifyListeners();
      return true;
    } on AcouDietError catch (e) {
      _switchFailure =
          '${e.code} · ${e.message} · ${SelfCheckPresenter.switchActionFor(e.code)}';
      if (mounted) notifyListeners();
      return false;
    }
  }
}

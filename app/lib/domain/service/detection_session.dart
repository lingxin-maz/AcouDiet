import 'dart:async';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../core/time.dart';
import '../../data/native/audio_bridge.dart';
import '../model/demo.dart';
import '../model/diet_record.dart';
import '../model/inference.dart';
import '../repository/repositories.dart';
import 'behavior_analyzer.dart';
import 'inference_engine.dart';

/// What one detection session produced, for the page and for logging.
class SessionOutcome {
  const SessionOutcome({
    required this.sessionId,
    required this.records,
    required this.metrics,
    required this.summary,
    required this.patchesEmitted,
    required this.droppedPatches,
    required this.confirmations,
  });

  final String sessionId;
  final List<DietRecord> records;
  final BehaviorMetrics? metrics;
  final SessionSummary summary;
  final int patchesEmitted;
  final int droppedPatches;
  final int confirmations;

  double get dropRate =>
      patchesEmitted == 0 ? 0 : droppedPatches / patchesEmitted;

  /// `API-01` section 3.3: above 5 % the inference step should be lengthened.
  bool get dropRateExceeded => dropRate > 0.05;
}

/// The live state `U-02` renders.
class DetectionState {
  const DetectionState({
    required this.decision,
    required this.patchesEmitted,
    required this.patchesVoiced,
    required this.droppedPatches,
    required this.startedAtMs,
    required this.running,
    this.metrics,
  });

  static const DetectionState idle = DetectionState(
    decision: AggregatedDecision.idle,
    patchesEmitted: 0,
    patchesVoiced: 0,
    droppedPatches: 0,
    startedAtMs: 0,
    running: false,
  );

  final AggregatedDecision decision;
  final int patchesEmitted;
  final int patchesVoiced;
  final int droppedPatches;
  final int startedAtMs;
  final bool running;

  /// ADR-23: the behaviour metrics **as they stand right now** (`BehaviorAnalyzer.snapshot`),
  /// so `U-02` can render the chew count / eating duration / eating speed live instead of only
  /// after the session ends. `null` while there is no chewing evidence yet.
  final BehaviorMetrics? metrics;

  /// FF-20a in one place: the first confirmation takes about 4-5 s. Nothing here may ever
  /// claim "within 2 seconds" (FF-25).
  Duration get elapsed =>
      Duration(milliseconds: (TimeUtil.nowMs() - startedAtMs).clamp(0, 1 << 40));
}

/// Session orchestrator: the single place where the native event stream, the inference
/// engine, the vote aggregator, the behaviour analyzer and the repository meet.
///
/// It implements the Dart-side calling convention fixed by `SPEC-P-02` section 3:
///
/// ```
/// onPatch(patch):
///   if (patch.voiced) last = await engine.run(patch.mel, nFrames: patch.nFrames)
///   else              last = last                       // silent: reuse the last result
///   aggregator.add(last, seq: patch.seq, voiced: patch.voiced)   // BOTH cases
/// ```
///
/// A silent patch therefore never triggers inference (saving battery) but still advances the
/// EMA, so the smoothing never breaks (FF-20c).
class DetectionSession {
  DetectionSession({
    required this.bridge,
    required this.engine,
    required this.diet,
    required this.votingConfig,
    required this.behaviorConfig,
    this.attributeResolver,
    this.decoder,
    this.clock,
  });

  final AudioBridge bridge;
  final InferenceEngine engine;
  final DietRepo diet;
  final VotingConfig votingConfig;
  final BehaviorConfig behaviorConfig;

  /// FF-20d mute-window clock. Injectable **only** so the acceptance test can step three minutes
  /// without sleeping for three minutes; production passes `null` and gets wall-clock epoch ms.
  /// Every time source in this class is this one function, so the window cannot be measured
  /// against two different clocks.
  final int Function()? clock;
  int _nowMs() => (clock ?? TimeUtil.nowMs)();

  /// ADR-41: the decision point over per-patch posteriors. `null` -- the only thing any production
  /// wiring passes -- builds [ThresholdVoteDecoder], i.e. the frozen hand-tuned rule to the byte.
  /// A caller may inject another [SequenceDecoder] to *compare* decoders without editing this file;
  /// the frozen acceptance criteria are about the default, and the default did not change.
  final SequenceDecoder? decoder;

  /// Supplies the knowledge-base attribute to snapshot into `diet_record.attribute`
  /// (API-03 section 2: the value is frozen at write time so later knowledge-base edits
  /// cannot silently re-word history).
  final String Function(int classId)? attributeResolver;

  SequenceDecoder? _aggregator;
  BehaviorAnalyzer? _analyzer;
  StreamSubscription<Map<Object?, Object?>>? _subscription;

  String? _sessionId;
  int _patchesEmitted = 0;
  int _patchesVoiced = 0;
  int _droppedPatches = 0;
  int _startedAtMs = 0;
  InferenceResult? _lastResult;
  AggregatedDecision _decision = AggregatedDecision.idle;

  /// Confirmations recorded this session, in order, de-duplicated by class and by the
  /// confirmed→unconfirmed transition (a class that stays confirmed for twenty patches is
  /// still one eating event).
  final List<_Confirmation> _confirmations = [];
  final Set<String> _confirmedLabels = {};

  /// Patches whose `mel` or `nFrames` failed validation; counted for diagnostics.
  int _rejectedPatches = 0;

  /// FF-20d · 「同一 `classId` 只问一次」的可执行形态.
  ///
  /// SPEC-P-06 section 2.4 has always *required* the two-choice question to be asked at most once
  /// per class ("由 `U-02` 去重呈现（同一 `classId` 只问一次）"), but nothing ever implemented it:
  /// the aggregator re-enters `lowConfidence` on the very next patch and the page asked again one
  /// second later. The user's report — 「点了否，同一条判断马上又问一遍」 — is that missing piece,
  /// with the window the user asked for (three minutes, `FF-20d`).
  ///
  /// Scope is **this session only**: the map lives on this instance and is cleared in [start],
  /// so 「同一次检测中的三分钟内」 is exactly what it implements, and the next detection starts
  /// with a clean slate.
  final Map<int, _ClassMute> _mutes = {};

  /// How long 「是 / 否」 silences its class. `0` would mean "ask again immediately", which is
  /// the defect this field exists to remove; the value comes from the SSOT (`FF-20d`), never
  /// from a literal here.
  int get muteWindowMs => cfg.FeatureConfig.votingConfirmationMuteSeconds * 1000;

  final _states = StreamController<DetectionState>.broadcast();

  Stream<DetectionState> get states => _states.stream;

  /// ADR-23: how often the live behaviour metrics are recomputed, in patches. Patches arrive at
  /// 2 Hz (`FF-12`) and the snapshot is linear in the frames collected so far, so this keeps the
  /// UI at about 1 Hz without re-running the whole peak pipeline on every single patch.
  static const int liveMetricsEveryPatches = 2;

  int _patchesSinceMetrics = 0;
  BehaviorMetrics? _liveMetrics;

  DetectionState get state => DetectionState(
        decision: _decision,
        patchesEmitted: _patchesEmitted,
        patchesVoiced: _patchesVoiced,
        droppedPatches: _droppedPatches,
        startedAtMs: _startedAtMs,
        running: _sessionId != null,
        metrics: _liveMetrics,
      );

  bool get isRunning => _sessionId != null;

  /// The active session id (`S-<epochMs>-<4 hex>`), or `null` when idle.
  String? get sessionId => _sessionId;

  int get rejectedPatches => _rejectedPatches;

  /// Starts a session on the native side and begins consuming events.
  Future<void> start({
    required String sessionId,
    bool skipAudioRecord = false,
    bool includeEnvelope = true,
  }) async {
    if (_sessionId != null) {
      throw AcouDietError(Codes.illegalTransition, 'a session is already running',
          detail: {'sessionId': _sessionId});
    }
    await bridge.startSession(
      sessionId: sessionId,
      skipAudioRecord: skipAudioRecord,
      includeEnvelope: includeEnvelope,
    );

    _sessionId = sessionId;
    _startedAtMs = TimeUtil.nowMs();
    _aggregator = decoder ?? ThresholdVoteDecoder(cfg: votingConfig);
    _analyzer = BehaviorAnalyzer(config: behaviorConfig);
    _confirmations.clear();
    _confirmedLabels.clear();
    _mutes.clear();
    _lastResult = null;
    _decision = AggregatedDecision.idle;
    _patchesEmitted = 0;
    _patchesVoiced = 0;
    _droppedPatches = 0;
    _rejectedPatches = 0;
    _patchesSinceMetrics = 0;
    _liveMetrics = null;

    _subscription = bridge.events(sessionId: sessionId).listen(_onEvent);
    _publish();
  }

  Future<void> pause() async {
    final id = _sessionId;
    if (id == null) throw AcouDietError(Codes.sessionNotFound, 'no active session');
    await bridge.pauseSession(id);
    // The behavior analyzer simply is not fed while paused, so paused time never counts
    // toward `durationSeconds` (API-01 section 2.4 / SPEC-P-07 acceptance 9).
  }

  Future<void> resume() async {
    final id = _sessionId;
    if (id == null) throw AcouDietError(Codes.sessionNotFound, 'no active session');
    await bridge.resumeSession(id);
  }

  /// Stops the session, computes behaviour metrics and writes the records (single
  /// transaction per record, invariant I-3).
  Future<SessionOutcome> stop() async {
    final id = _sessionId;
    if (id == null) throw AcouDietError(Codes.sessionNotFound, 'no active session');

    await _subscription?.cancel();
    _subscription = null;

    final summary = await bridge.stopSession(id);
    final endMs = summary.stoppedAtMs == 0 ? TimeUtil.nowMs() : summary.stoppedAtMs;
    final metrics = _analyzer?.finish(endMs: endMs);
    // The final reading replaces the live one, so a state published after `stop()` still carries
    // the same metrics the outcome does.
    _liveMetrics = metrics;

    final records = await _persist(endMs: endMs, metrics: metrics);

    _sessionId = null;
    _publish();

    return SessionOutcome(
      sessionId: id,
      records: records,
      metrics: metrics,
      summary: summary,
      patchesEmitted: _patchesEmitted,
      droppedPatches: _droppedPatches,
      confirmations: records.length,
    );
  }

  /// The user answered the Level-3 two-choice confirmation (X-02's degraded form).
  ///
  /// [accepted] means the suggestion was right; otherwise [alternativeClassId] must name the
  /// class the user picked instead. There is no free-form class editing in v1.0.
  ///
  /// ⚠️ **实测缺陷（已修）**：U-02 只提供「是 / 否」两个按钮，而「否」按钮**无法**提供
  /// `alternativeClassId`（v1.0 裁剪了选类别 UI）。于是 `accepted: false` 走进
  /// `alternativeClassId == null` 分支 → 抛 [Codes.dbInvalid] → 页面被打进错误态。
  /// **点「否」100% 必然报错**，这不是边界情况。
  ///
  /// 修法：把"拒绝一个低置信建议"与"改判成另一个类别"拆成两个方法。前者走
  /// [rejectSuggestion]（不记录、不抛错），后者仍走本方法并要求带 `alternativeClassId`。
  /// 这样既保住了"不猜类别"的原则，也不再让一个正常操作产生错误界面。
  ///
  /// ⚠️ **实测缺陷（已修）**：即使答复成功，页面**一秒钟后又问同一句** —— 聚合器下一个 patch
  /// 就重新进入 `lowConfidence`，而「同一 `classId` 只问一次」（SPEC-P-06 §2.4）从来没有人实现。
  /// 现在两个答复都会按 `FF-20d` 把该类别静默 `confirmation_mute_seconds`，见 [_mutes]。
  void answerConfirmation({required bool accepted, int? alternativeClassId}) {
    // 顺序很重要：**先**检查会话是否真的在问，**再**检查参数。
    // 反过来的话，空会话下会报出一个参数错误码（`ACD-DB-004`），
    // 而那正是本次缺陷的症状 —— 让"状态不对"看起来像"调用方参数写错"。
    _requirePendingConfirmation();
    if (!accepted && alternativeClassId == null) {
      // Fail loudly at the API boundary rather than silently recording a wrong class:
      // a caller that wants to reject must say so through rejectSuggestion().
      throw Errors.dbInvalid(
          'rejecting a suggestion needs alternativeClassId; use rejectSuggestion() to dismiss');
    }
    final suggested = _decision.classId;
    final classId = accepted ? _decision.classId : alternativeClassId;
    if (classId == null) {
      throw Errors.dbInvalid('no class chosen for the confirmation');
    }
    _recordConfirmation(
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      confidence: _decision.smoothedConfidence,
      confirmedByUser: accepted,
      correctedByUser: !accepted,
    );
    // 「是」settles the suggestion as `confirmed`; a correction settles the *suggested* class as
    // rejected (the user said it was not that) and the chosen one as affirmed.
    if (accepted) {
      _mute(classId, verdict: _MuteVerdict.affirmed);
    } else {
      if (suggested != null) _mute(suggested, verdict: _MuteVerdict.denied);
      _mute(classId, verdict: _MuteVerdict.affirmed);
    }
    _dismissedConfirmation = true;
    // `SPEC-P-06` section 2.3 settles the answer **synchronously** (`lowConfidence → confirmed`),
    // so the session's own state must say so before the caller even returns: the page repaints from
    // this decision, and a half-second lag (`FF-12` is 2 Hz) left the answered question on screen
    // for a second tap that then failed its precondition.
    _decision = AggregatedDecision(
      stage: VoteStage.confirmed,
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      smoothedConfidence: _decision.smoothedConfidence,
      consecutiveCount: _decision.consecutiveCount,
      shouldAskUser: false,
    );
  }

  /// The user tapped 「否」: the suggestion is rejected **without** naming a replacement class.
  ///
  /// Why this exists instead of overloading [answerConfirmation] with `accepted: false`:
  /// v1.0 has no class-picker UI, so "no" carries no replacement class. It must therefore
  /// **not create a record** (inventing one would be exactly the "never guess a food name"
  /// rule violation), and it must **not throw** either.
  ///
  /// Effect: the suggestion is dropped, the question stops asking, and the class is silenced for
  /// `FF-20d` (`confirmation_mute_seconds`). This is the user-requested behaviour: 「点了否，
  /// 同一次检测的三分钟内不再出现该判断结果」.
  ///
  /// The landing value is `observing` with **no** class — "the app has nothing to claim here" —
  /// which is a row `SPEC-P-06` section 2.3's own table already allows (`observing` with
  /// `classId = null`). Keeping the class name instead would mean the card went on asserting the
  /// very food the user just denied.
  ///
  /// The hold is deliberately **per class and per session**: a different class can still be
  /// confirmed and recorded during the window, and a brand new detection starts unmuted.
  void rejectSuggestion() {
    _requirePendingConfirmation();
    final classId = _decision.classId;
    _dismissedConfirmation = true;
    if (classId != null) {
      _mute(classId, verdict: _MuteVerdict.denied);
    }
    _decision = AggregatedDecision(
      stage: VoteStage.observing,
      smoothedConfidence: _decision.smoothedConfidence,
      consecutiveCount: _decision.consecutiveCount,
      shouldAskUser: false,
    );
  }

  /// Remembers the user's answer about `classId` for `FF-20d`.
  void _mute(int classId, {required _MuteVerdict verdict}) {
    _mutes[classId] = _ClassMute(
      untilMs: _nowMs() + muteWindowMs,
      verdict: verdict,
    );
  }

  /// Shared precondition for both answers: there must be a pending question.
  void _requirePendingConfirmation() {
    if (_decision.stage != VoteStage.lowConfidence) {
      throw AcouDietError(Codes.illegalTransition,
          'there is no pending confirmation to answer',
          detail: {'stage': _decision.stage.name});
    }
  }

  /// `true` once the current question has been answered (either way), cleared by the next patch.
  ///
  /// `DetectPresenter` reads it so the two buttons disappear after a tap; without it a slow
  /// session would keep offering a question that was already answered, and the second tap would
  /// hit the precondition above.
  bool get confirmationDismissed => _dismissedConfirmation;
  bool _dismissedConfirmation = false;

  /// Force-finishes a confirmed eating event manually (the record button in `U-02`).
  ///
  /// Tapping it is also an affirmative answer about the current class, so it silences that class
  /// for `FF-20d` exactly like 「是」 does — otherwise the page would immediately ask about the
  /// food the user just recorded.
  void acceptCurrentAsRecord() {
    final decision = _decision;
    final classId = decision.classId;
    if (classId == null) {
      throw Errors.dbInvalid('nothing recognised yet');
    }
    _recordConfirmation(
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      confidence: decision.smoothedConfidence,
      confirmedByUser: true,
      correctedByUser: false,
    );
    _mute(classId, verdict: _MuteVerdict.affirmed);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _states.close();
  }

  // ------------------------------------------------------------------ event handling

  void _onEvent(Map<Object?, Object?> raw) {
    final type = raw['type'];
    switch (type) {
      case 'patch':
        _onPatch(PatchEvent(raw.cast<String, Object?>()));
      case 'level':
        break; // waveform animation only; `rms` never drives a business decision
      case 'sessionEnded':
        break; // `stop()` owns the teardown path
      default:
        break;
    }
  }

  Future<void> _onPatch(PatchEvent patch) async {
    final id = _sessionId;
    if (id == null) return;

    _patchesEmitted++;
    if (patch.voiced) _patchesVoiced++;

    final mel = patch.mel;
    final nFrames = patch.nFrames;
    if (mel is! Float32List || mel.length != cfg.FeatureConfig.nMels * nFrames) {
      // A malformed payload must not poison the aggregator; count it and move on so the
      // recognition/record pipeline keeps working (SPEC-P-07 acceptance 15).
      _rejectedPatches++;
      await bridge.ackPatch(id, patch.seq);
      return;
    }

    InferenceResult? result;
    if (patch.voiced) {
      result = await engine.run(mel, nFrames: nFrames);
      _lastResult = result;
    } else {
      // Silent patch: reuse the most recent result. It still enters the EMA, but it can
      // neither increment nor clear the consecutive counter (API-02 section 4).
      result = _lastResult;
    }

    final analyzer = _analyzer;
    final envelope = patch.rmsEnvelope;
    if (analyzer != null && envelope is Float32List) {
      analyzer.feedEnvelope(
        envelope,
        hopMs: patch.envelopeHopMs ?? behaviorConfig.envelopeHopMs,
        tStartMs: patch.tStartMs,
      );
      // ADR-23: a live reading for the detection page's behaviour rows. Same pipeline as the
      // final `finish()`, just not sealed -- and computed on a stride so a long session does
      // not re-run the peak detection on every patch.
      _patchesSinceMetrics++;
      if (_patchesSinceMetrics >= liveMetricsEveryPatches) {
        _patchesSinceMetrics = 0;
        try {
          _liveMetrics = analyzer.snapshot(endMs: patch.tEndMs);
        } on AcouDietError {
          // A snapshot whose clock is behind the newest frame is a defect, not a user-facing
          // state: keep the previous reading rather than failing the whole recognition path.
        }
      }
    }

    final aggregator = _aggregator;
    if (aggregator == null || result == null) {
      // Nothing recognised yet: still acknowledge so the native side does not drop patches.
      await bridge.ackPatch(id, patch.seq);
      return;
    }

    final previous = _decision;
    final raw = aggregator.add(result, seq: patch.seq, voiced: patch.voiced);
    final decision = _applyMute(raw);
    _decision = decision;
    // A new patch re-opens the question: whatever the user answered before applied to the
    // evidence as it stood then. Clearing here is what makes 「否」 a dismissal rather than a
    // permanent mute, and it is also what keeps the two buttons from sticking around after a tap.
    _dismissedConfirmation = false;

    // Persist on the *transition* into `confirmed` only.
    if (decision.stage == VoteStage.confirmed &&
        previous.stage != VoteStage.confirmed &&
        decision.classId != null) {
      _recordConfirmation(
        classId: decision.classId!,
        label: decision.label ?? cfg.FeatureConfig.classLabels[decision.classId!],
        confidence: decision.smoothedConfidence,
        confirmedByUser: false,
        correctedByUser: false,
        atMs: patch.tStartMs,
      );
    }

    await bridge.ackPatch(id, patch.seq);
    _publish();
  }

  /// FF-20d · holds a muted class at the verdict the user settled it to.
  ///
  /// Two things are suppressed, and only two:
  /// * **the question** — `lowConfidence`/`shouldAskUser` on a muted class is reported as the
  ///   settled verdict instead, so 「疑似 X，请确认？」 cannot reappear and the 是/否 row stays hidden;
  /// * **the auto-record of a denied class** — a 「否」 makes the class produce no result at all, so a
  ///   later run of `confirmed` patches is clamped too. Recording 软糖 seconds after the user said
  ///   「不是软糖」 would make the 否 button meaningless.
  ///
  /// Everything else is left untouched: a genuinely different class is unaffected, `observing`
  /// and `unconfirmed` readings pass through (they ask nothing and record nothing), and once the
  /// window expires the raw verdict is returned verbatim, so evidence can win again.
  AggregatedDecision _applyMute(AggregatedDecision d) {
    final classId = d.classId;
    if (classId == null) return d;
    final mute = _mutes[classId];
    if (mute == null) return d;

    final now = _nowMs();
    if (now >= mute.untilMs) {
      // The window is over: the raw verdict comes back verbatim, so new evidence can win again.
      _mutes.remove(classId);
      return d;
    }

    final asking = d.shouldAskUser || d.stage == VoteStage.lowConfidence;
    final recording = d.stage == VoteStage.confirmed;
    if (!asking && !recording) return d;

    if (mute.verdict == _MuteVerdict.affirmed) {
      // 「是」: the user's own answer **is** the result, so keep it and its name. The record is
      // already written (and `_confirmedLabels` keeps it to one per class per session).
      return AggregatedDecision(
        stage: VoteStage.confirmed,
        classId: classId,
        label: d.label,
        smoothedConfidence: d.smoothedConfidence,
        consecutiveCount: d.consecutiveCount,
        shouldAskUser: false,
        smoothedProbs: d.smoothedProbs,
      );
    }

    // 「否」: the app has nothing left to claim about this class. No question, **no name** — a grey
    // 「疑似 软糖」 chip would be the app still asserting the very thing the user denied — and no
    // record, because a record named 软糖 is that same denied claim stored permanently.
    //
    // `observing` is the only frozen value that means "no result": `VoteStage` has no `rejected`
    // value by design (API-02 section 4), and SPEC-P-06 section 2.3's own table lists `observing`
    // with `classId = null` as a legal row, while every other stage requires a Top-1.
    return AggregatedDecision(
      stage: VoteStage.observing,
      smoothedConfidence: d.smoothedConfidence,
      consecutiveCount: d.consecutiveCount,
      shouldAskUser: false,
      smoothedProbs: d.smoothedProbs,
    );
  }

  void _recordConfirmation({
    required int classId,
    required String label,
    required double confidence,
    required bool confirmedByUser,
    required bool correctedByUser,
    int? atMs,
  }) {
    if (!_confirmedLabels.add(label)) {
      // One record per class per session: an eating event does not repeat every patch.
      return;
    }
    _confirmations.add(_Confirmation(
      classId: classId,
      label: label,
      confidence: confidence,
      confirmedByUser: confirmedByUser,
      correctedByUser: correctedByUser,
      atMs: atMs ?? TimeUtil.nowMs(),
    ));
  }

  /// Writes one diet record per confirmed class. The session-level behaviour metrics go on
  /// the first record; the others get a placeholder row so invariant I-1 holds for every
  /// record without inventing a second metrics source.
  Future<List<DietRecord>> _persist({
    required int endMs,
    required BehaviorMetrics? metrics,
  }) async {
    if (_confirmations.isEmpty) return const [];

    final out = <DietRecord>[];
    for (var i = 0; i < _confirmations.length; i++) {
      final c = _confirmations[i];
      final record = DietRecord(
        recordId: 'R-${_sessionId ?? "session"}-$i',
        eatenAtMs: c.atMs,
        endedAtMs: endMs < c.atMs ? c.atMs : endMs,
        classLabel: c.label,
        classId: c.classId,
        attribute: attributeResolver?.call(c.classId) ?? c.attributeFallback,
        confidence: c.confidence,
        durationSeconds: i == 0 ? (metrics?.durationSeconds ?? 0) : 0,
        source: _source,
        correctedByUser: c.correctedByUser,
        confirmedByUser: c.confirmedByUser,
      );
      await diet.insertSession(record: record, metrics: i == 0 ? metrics : null);
      out.add(record);
    }
    return out;
  }

  String _source = 'real';

  /// Demo Mode B records are flagged so they can be cleared independently (API-01 section
  /// 2.6 / SPEC-A-04).
  set source(String value) => _source = value;

  void _publish() {
    if (!_states.isClosed) _states.add(state);
  }
}

/// FF-20d · one class the user has already answered about, held until [untilMs] (wall-clock epoch
/// ms) so the two-choice question cannot be asked about it again inside the same detection.
///
/// It is deliberately **not** persisted and **not** part of `AggregatedDecision` or `VoteStage`:
/// `SPEC-P-06` section 2.4 keeps the aggregator a pure function with no de-duplication
/// ("聚合器不负责去重"), so the memory of "the user already answered" belongs to the session state
/// machine — the component that owns the 「是 / 否」 transitions.
class _ClassMute {
  _ClassMute({required this.untilMs, required this.verdict});

  final int untilMs;
  final _MuteVerdict verdict;
}

/// Which answer the user gave. The two are not symmetric:
///
/// * [affirmed] (`是`) keeps the class **confirmed** for the window — the user asserted it, and the
///   record is already written;
/// * [denied] (`否`) makes the class produce **no result at all** for the window — nothing to ask,
///   nothing to name, nothing to record.
enum _MuteVerdict { affirmed, denied }

class _Confirmation {
  _Confirmation({
    required this.classId,
    required this.label,
    required this.confidence,
    required this.confirmedByUser,
    required this.correctedByUser,
    required this.atMs,
  });

  final int classId;
  final String label;
  final double confidence;
  final bool confirmedByUser;
  final bool correctedByUser;
  final int atMs;

  /// Used only when the knowledge base has not been injected (tests, placeholder mode).
  /// The real app always goes through [DetectionSession.attributeResolver].
  ///
  /// ADR-19: FF-19's 知识库属性 column, in class-id order. The previous switch
  /// (`0 || 2 => 脆性食品`) stopped being expressible, because id 2 is now `gummies`
  /// (黏弹性零食) while id 0 `chips` is 脆性高加工零食.
  /// An out-of-range id yields the empty string rather than a plausible-looking wrong
  /// attribute: the old `_ => '液体'` arm silently labelled an unknown class as a drink, which
  /// is the "never guess a food name" rule (U-06 section 2.4) applied to the attribute too.
  String get attributeFallback =>
      (classId >= 0 && classId < _classAttributes.length)
          ? _classAttributes[classId]
          : '';

  static const List<String> _classAttributes = [
    '脆性高加工零食',
    '脆爽蔬菜',
    '黏弹性零食',
    '软性主食',
    '脆爽蔬菜',
    '液体',
  ];
}

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
  });

  final AudioBridge bridge;
  final InferenceEngine engine;
  final DietRepo diet;
  final VotingConfig votingConfig;
  final BehaviorConfig behaviorConfig;

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
  }

  /// The user tapped 「否」: the suggestion is rejected **without** naming a replacement class.
  ///
  /// Why this exists instead of overloading [answerConfirmation] with `accepted: false`:
  /// v1.0 has no class-picker UI, so "no" carries no replacement class. It must therefore
  /// **not create a record** (inventing one would be exactly the "never guess a food name"
  /// rule violation), and it must **not throw** either.
  ///
  /// Effect: the suggestion is dropped and the question stops asking. `/regen`-style re-asking
  /// happens naturally on the next patches, because the aggregator keeps running and will
  /// re-enter `lowConfidence` if the evidence still says so.
  void rejectSuggestion() {
    _requirePendingConfirmation();
    _dismissedConfirmation = true;
    _decision = AggregatedDecision(
      stage: VoteStage.observing,
      smoothedConfidence: _decision.smoothedConfidence,
      consecutiveCount: _decision.consecutiveCount,
      shouldAskUser: false,
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
    final decision = aggregator.add(result, seq: patch.seq, voiced: patch.voiced);
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

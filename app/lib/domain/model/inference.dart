import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;

/// One inference result for one patch (`API-02` section 3).
class InferenceResult {
  const InferenceResult({
    required this.classId,
    required this.label,
    required this.confidence,
    required this.probs,
    required this.latencyMs,
  });

  final int classId;
  final String label;

  /// `== probs[classId]`, `[0,1]`. Never converted to a percentage here (API-00 section 3.3).
  final double confidence;

  /// Softmax output, length `numClasses`.
  final Float32List probs;

  /// Wall-clock `Interpreter.run()` duration only (measured on device, D4).
  final int latencyMs;
}

/// The five -- and only five -- vote stages (`API-02` section 4).
enum VoteStage { observing, unconfirmed, lowConfidence, confirmed, none }

/// Stage output of the three-level aggregation.
class AggregatedDecision {
  const AggregatedDecision({
    required this.stage,
    this.classId,
    this.label,
    required this.smoothedConfidence,
    required this.consecutiveCount,
    required this.shouldAskUser,
    this.smoothedProbs,
  });

  static const AggregatedDecision idle = AggregatedDecision(
    stage: VoteStage.none,
    smoothedConfidence: 0,
    consecutiveCount: 0,
    shouldAskUser: false,
  );

  final VoteStage stage;
  final int? classId;
  final String? label;
  final double smoothedConfidence;
  final int consecutiveCount;

  /// `true` only for [VoteStage.lowConfidence] -- the single entry point of the two-choice
  /// confirmation (X-02's degraded form).
  final bool shouldAskUser;

  /// Visualisation only; must never be persisted (API-02 section 4 / FF-24 item 3).
  final Float32List? smoothedProbs;

  bool get isConfirmed => stage == VoteStage.confirmed;
}

/// Three-level voting configuration, projected from the SSOT.
class VotingConfig {
  const VotingConfig({
    required this.emaWindow,
    required this.emaAlpha,
    required this.confirmConsecutivePatches,
    required this.tauConfirm,
    required this.tauLow,
  });

  final int emaWindow;
  final double emaAlpha;
  final int confirmConsecutivePatches;
  final double tauConfirm;
  final double tauLow;

  factory VotingConfig.fromFeatureConfig() => VotingConfig(
        emaWindow: cfg.FeatureConfig.votingEmaWindow,
        emaAlpha: cfg.FeatureConfig.votingEmaAlpha,
        confirmConsecutivePatches:
            cfg.FeatureConfig.votingConfirmConsecutivePatches,
        tauConfirm: cfg.FeatureConfig.votingTauConfirm,
        tauLow: cfg.FeatureConfig.votingTauLow,
      );
}

/// The pluggable decision point over a stream of per-patch posteriors (ADR-41).
///
/// Why this interface exists: the three-level rule in [ThresholdVoteDecoder] is a **hand-tuned
/// posterior decoder** -- an EMA, two fixed thresholds and a consecutive-patch counter. It is a
/// perfectly good decoder and it stays the default, verbatim. But because it was welded into the
/// only class that could decode anything, there was no way to *compare* it against another one
/// without editing the session. The objective's item (1) is exactly that comparison, so the
/// decision is now an injected collaborator.
///
/// `DetectionSession` takes a `SequenceDecoder`; when none is given it builds
/// [ThresholdVoteDecoder], which is today's behaviour to the byte. The frozen acceptance criteria
/// (`FF-20a`/`FF-20b`/`FF-20c`) are therefore untouched: nothing about the *default* changed, and
/// `test/domain/decoder_equivalence_test.dart` pins that.
///
/// Contract, all of it already true of the default decoder:
///  * state lives across patches (FF-20c) and is cleared only by [reset];
///  * `voiced == false` still advances the smoothing but does not advance the run counter;
///  * a `seq` gap restarts the run counter but keeps the smoothing;
///  * the first call after construction or [reset] reports [VoteStage.none].
abstract class SequenceDecoder {
  /// Patches incorporated so far (the "effective sample count" of API-02 section 4).
  int get sampleCount;

  /// How many consecutive patches the current top-1 has held.
  int get consecutiveCount;

  void reset();

  /// Folds one patch in. [seq] is the monotonic patch sequence from API-01 section 3.2.
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced});
}

/// Three-level result aggregation (P-06, `API-02` section 4).
///
/// **This is the hand-tuned baseline decoder**, moved here unchanged by ADR-41. The body below is
/// the same code that used to live in `VoteAggregator`; see [VoteAggregator] for the compatibility
/// name.
///
/// State deliberately lives across patches (FF-20c): the EMA and the consecutive counter are
/// *not* reset per patch, only at a session boundary via [reset].
///
/// Semantics fixed by the contract:
///  * `voiced == false` still updates the EMA (otherwise smoothing would break) but neither
///    increments nor clears the consecutive counter;
///  * a `seq` gap (drop-oldest) clears the consecutive counter but keeps the EMA;
///  * the first call after construction or [reset] yields [VoteStage.none] -- there is no
///    evidence yet, so no class is reported;
///  * the first confirmation takes about 4-5 s (FF-20a); "results within 2 s" is a banned
///    claim (FF-25).
class ThresholdVoteDecoder implements SequenceDecoder {
  ThresholdVoteDecoder({required this.cfg});

  final VotingConfig cfg;

  Float32List? _ema;
  int _emaSamples = 0;
  int? _lastTop1;
  int _consecutive = 0;
  int _lastSeq = -1;
  bool _hasSamples = false;

  /// Patches incorporated into the EMA.
  int get sampleCount => _emaSamples;
  int get consecutiveCount => _consecutive;

  void reset() {
    _ema = null;
    _emaSamples = 0;
    _lastTop1 = null;
    _consecutive = 0;
    _lastSeq = -1;
    _hasSamples = false;
  }

  /// Feeds one patch. `seq` is the monotonic patch sequence from `API-01` section 3.2.
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) {
    final expected = cfg.numClasses;
    if (r.probs.length != expected) {
      // Fail fast: an upstream contract violation, not a runtime condition.
      throw Errors.shapeMismatch(expectedFrames: expected, actualFrames: r.probs.length);
    }

    // Drop-oldest detection: a seq gap means the "unchanged for N patches" evidence is no
    // longer contiguous, so the counter restarts. The EMA is intentionally kept.
    if (_lastSeq >= 0 && seq - _lastSeq > 1) {
      _consecutive = 0;
    }
    _lastSeq = seq;

    final firstEver = !_hasSamples;
    _hasSamples = true;
    _emaSamples++;
    _updateEma(r.probs);

    final smoothed = _ema!;
    final top1 = _argmax(smoothed);
    final top1Confidence = smoothed[top1].toDouble();

    if (voiced) {
      if (_lastTop1 == top1) {
        _consecutive++;
      } else {
        _lastTop1 = top1;
        _consecutive = 1;
      }
    }

    final label = cfg.labelOf(top1);

    if (firstEver) {
      // "有效样本数 == 0" before this patch: report nothing (API-02 section 4, test 6).
      return AggregatedDecision(
        stage: VoteStage.none,
        smoothedConfidence: 0,
        consecutiveCount: 0,
        shouldAskUser: false,
      );
    }

    final formed = _emaSamples >= cfg.emaWindow;

    if (!formed || top1Confidence < cfg.tauLow) {
      return AggregatedDecision(
        stage: VoteStage.observing,
        classId: top1,
        label: label,
        smoothedConfidence: top1Confidence,
        consecutiveCount: _consecutive,
        shouldAskUser: false,
        smoothedProbs: Float32List.fromList(smoothed),
      );
    }

    if (top1Confidence >= cfg.tauConfirm) {
      final confirmed = _consecutive >= cfg.confirmConsecutivePatches;
      return AggregatedDecision(
        stage: confirmed ? VoteStage.confirmed : VoteStage.unconfirmed,
        classId: top1,
        label: label,
        smoothedConfidence: top1Confidence,
        consecutiveCount: _consecutive,
        shouldAskUser: false,
        smoothedProbs: Float32List.fromList(smoothed),
      );
    }

    // tauLow <= confidence < tauConfirm: the only path that may ask the user.
    return AggregatedDecision(
      stage: VoteStage.lowConfidence,
      classId: top1,
      label: label,
      smoothedConfidence: top1Confidence,
      consecutiveCount: _consecutive,
      shouldAskUser: true,
      smoothedProbs: Float32List.fromList(smoothed),
    );
  }

  void _updateEma(Float32List probs) {
    final alpha = cfg.emaAlpha;
    final e = _ema;
    if (e == null) {
      _ema = Float32List.fromList(probs);
      return;
    }
    for (var i = 0; i < e.length; i++) {
      e[i] = alpha * probs[i] + (1 - alpha) * e[i];
    }
  }

  static int _argmax(Float32List v) {
    var best = 0;
    for (var i = 1; i < v.length; i++) {
      if (v[i] > v[best]) best = i;
    }
    return best;
  }
}

/// The compatibility name for the default decoder (ADR-41).
///
/// Every existing call site, every offline assertion and `session_tests` talk to `VoteAggregator`,
/// and none of them should have to change to learn that the decision point is now pluggable. This
/// class is a **pure delegation** to [ThresholdVoteDecoder]: there is no second copy of the rule,
/// so the two can never disagree.
///
/// ⚠️ It is not `extends` but a delegation on purpose. Inheriting would leave a subclass that could
/// override half the rule, and the whole point of the split is that there is exactly one
/// implementation of the frozen behaviour.
class VoteAggregator implements SequenceDecoder {
  VoteAggregator({required this.cfg}) : _inner = ThresholdVoteDecoder(cfg: cfg);

  final VotingConfig cfg;
  final ThresholdVoteDecoder _inner;

  @override
  int get sampleCount => _inner.sampleCount;

  @override
  int get consecutiveCount => _inner.consecutiveCount;

  @override
  void reset() => _inner.reset();

  @override
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) =>
      _inner.add(r, seq: seq, voiced: voiced);
}

extension VotingConfigLabels on VotingConfig {
  int get numClasses => cfg.FeatureConfig.numClasses;

  String labelOf(int classId) => cfg.FeatureConfig.classLabels[classId];
}

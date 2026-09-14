import 'dart:math' as math;

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../model/health_score.dart';

/// Inputs of the scoring kernel (`SPEC-A-01` section 4, `ScoreInputs`).
///
/// Private to the A domain: it exists so the kernel can be unit-tested on hand-computed
/// fixtures without a database. `U-*` must never see it.
class ScoreInputs {
  const ScoreInputs({
    required this.sigmaMinutes,
    required this.mealTimeSamples,
    required this.classCounts,
    required this.recordCount,
    required this.snackCount,
    required this.lateNightCount,
    required this.avgChewIntervalSeconds,
    required this.sampleCount,
    required this.missingMetricsCount,
    required this.windowDays,
  });

  final double? sigmaMinutes;

  /// Number of records that fell inside a meal window (`API-04` section 3 evidence key).
  final int mealTimeSamples;
  final Map<String, int> classCounts;
  final int recordCount;
  final int snackCount;
  final int lateNightCount;
  final double? avgChewIntervalSeconds;
  final int sampleCount;
  final int missingMetricsCount;
  final int windowDays;
}

/// The four dimension formulas, exactly as frozen (`SPEC-A-01` section 5, table A-01-T1).
///
/// Two rules are non-negotiable here and both come from `ADR-15`:
///
/// 1. **Literal expression evaluation.** Every formula is evaluated as written, with no
///    algebraic rearrangement. `30 * min(1, 0.30 / 0.4)` is `22.499999999999996` (rounds to
///    22) while `30 * 0.30 / 0.4` is `22.5` (rounds to 23) -- the same formula, two
///    equivalent-looking writings, a one-point difference the UI would happily display.
/// 2. **Round each dimension, then sum.** Summing first and rounding once can make the
///    total disagree with the four numbers printed beside it.
class ScoreFormulas {
  ScoreFormulas._();

  /// Dimension display names; these are also the radar axis labels of `U-01`/`U-04`.
  static const String labelRegularity = '饮食规律性';
  static const String labelStructure = '食物结构';
  static const String labelSnack = '零食控制';
  static const String labelSpeed = '进食速度';

  /// Single source of the human-readable formula strings (A-01-K5).
  static String formulaOf(String dimension) => switch (dimension) {
        'regularity' => '30 × max(0, 1 − σ/90min)',
        'structure' => '30 × min(1, p/0.4)',
        'snack' => '20 × max(0, 1 − n/10)',
        'speed' => 't ≥ 0.8s → 20；t ≤ 0.4s → 0；中间 20 × (t − 0.4)/0.4',
        _ => throw Errors.score(dimension, 'unknownDimension'),
      };

  static int get maxRegularity => cfg.FeatureConfig.healthScoreWeightsRegularity;
  static int get maxStructure => cfg.FeatureConfig.healthScoreWeightsStructure;
  static int get maxSnack => cfg.FeatureConfig.healthScoreWeightsSnack;
  static int get maxSpeed => cfg.FeatureConfig.healthScoreWeightsSpeed;

  /// Builds the four [DimensionScore]s plus the total. Synchronous and pure.
  static HealthScore compute(ScoreInputs i) {
    if (i.windowDays < 1) throw Errors.score('window', 'windowDays < 1');
    if (i.recordCount < 0 || i.snackCount < 0 || i.lateNightCount < 0) {
      throw Errors.score('window', 'negative count');
    }
    final sigma = i.sigmaMinutes;
    if (sigma != null && !sigma.isFinite) {
      throw Errors.score('regularity', 'sigma is not finite');
    }

    // ---- regularity: 30 × max(0, 1 − σ/90) -------------------------------------------
    // σ == null means "no meal class had two samples"; the dimension is 0 and the evidence
    // records the null so the UI can render `--` instead of an invented 0.
    final regularityRaw = sigma == null
        ? 0.0
        : maxRegularity *
            math.max(0.0, 1.0 - sigma / _sigmaAtZeroScore);

    final regularity = DimensionScore(
      score: _roundClamp(regularityRaw, maxRegularity),
      max: maxRegularity,
      label: labelRegularity,
      evidence: {
        'sigmaMinutes': sigma,
        'mealTimeSamples': i.mealTimeSamples,
        'windowDays': i.windowDays,
      },
    );

    // ---- structure: 30 × min(1, p / 0.4) --------------------------------------------
    final totalCount = i.recordCount;
    final healthyCount = _healthyLabels.fold<int>(
      0,
      (sum, label) => sum + (i.classCounts[label] ?? 0),
    );
    final healthyRatio = totalCount == 0 ? 0.0 : healthyCount / totalCount;
    // LITERAL: divide first, then min, then multiply (ADR-15).
    final structureRaw =
        maxStructure * math.min(1.0, healthyRatio / _healthyRatioAtFullScore);

    final structure = DimensionScore(
      score: _roundClamp(structureRaw, maxStructure),
      max: maxStructure,
      label: labelStructure,
      evidence: {
        'healthyRatio': healthyRatio,
        'healthyCount': healthyCount,
        'totalCount': totalCount,
      },
    );

    // ---- snack: 20 × max(0, 1 − n/10) ------------------------------------------------
    final snackRaw =
        maxSnack * math.max(0.0, 1.0 - i.snackCount / _countAtZeroScore);
    final snack = DimensionScore(
      score: _roundClamp(snackRaw, maxSnack),
      max: maxSnack,
      label: labelSnack,
      evidence: {
        'snackCount': i.snackCount,
        'lateNightCount': i.lateNightCount,
      },
    );

    // ---- speed: piecewise, never merging the FF-21e text thresholds ------------------
    final t = i.avgChewIntervalSeconds;
    if (t != null && !t.isFinite) {
      throw Errors.score('speed', 'interval is not finite');
    }
    double speedRaw;
    if (t == null) {
      speedRaw = 0.0;
    } else if (t >= _secondsAtFullScore) {
      speedRaw = maxSpeed.toDouble();
    } else if (t <= _secondsAtZeroScore) {
      speedRaw = 0.0;
    } else {
      // LITERAL: 20 × (t − 0.4) / (0.8 − 0.4)
      speedRaw = maxSpeed.toDouble() *
          (t - _secondsAtZeroScore) /
          (_secondsAtFullScore - _secondsAtZeroScore);
    }

    final speed = DimensionScore(
      score: _roundClamp(speedRaw, maxSpeed),
      max: maxSpeed,
      label: labelSpeed,
      evidence: {
        'avgChewIntervalSeconds': t,
        'sampleCount': i.sampleCount,
        'missingMetricsCount': i.missingMetricsCount,
      },
    );

    final totalScore =
        regularity.score + structure.score + snack.score + speed.score;

    return HealthScore(
      totalScore: totalScore,
      grade: HealthScore.gradeOf(totalScore),
      regularity: regularity,
      structure: structure,
      snack: snack,
      speed: speed,
    );
  }

  /// `round()` with half away from zero, then clamped into the dimension's range.
  ///
  /// Takes `num` on purpose: `int * double` is statically `num` in Dart, and the literal
  /// formulas above mix both. Widening here keeps the formula bodies exactly as written.
  static int _roundClamp(num raw, int max) {
    final d = raw.toDouble();
    if (!d.isFinite) return 0;
    final r = d < 0 ? -((-d).round()) : d.round();
    return r.clamp(0, max);
  }

  // Values mirrored from the SSOT (never literals in the formula bodies above).
  static double get _sigmaAtZeroScore =>
      cfg.FeatureConfig.healthScoreFormulaRegularitySigmaAtZeroScoreMinutes.toDouble();
  static double get _healthyRatioAtFullScore =>
      cfg.FeatureConfig.healthScoreFormulaStructureHealthyRatioAtFullScore;
  static double get _countAtZeroScore =>
      cfg.FeatureConfig.healthScoreFormulaSnackCountAtZeroScore.toDouble();
  static double get _secondsAtFullScore =>
      cfg.FeatureConfig.healthScoreFormulaSpeedSecondsAtFullScore;
  static double get _secondsAtZeroScore =>
      cfg.FeatureConfig.healthScoreFormulaSpeedSecondsAtZeroScore;
  static List<String> get _healthyLabels =>
      cfg.FeatureConfig.healthScoreFormulaStructureHealthyLabels;
}

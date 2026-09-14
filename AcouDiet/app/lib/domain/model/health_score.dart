import '../../core/feature_config.g.dart' as cfg;

/// One dimension of the health score, with its drill-down evidence (API-04 section 3).
class DimensionScore {
  const DimensionScore({
    required this.score,
    required this.max,
    required this.label,
    required this.evidence,
  });

  final int score;
  final int max;

  /// Fixed Chinese dimension names, shared with the radar axes of `U-01`/`U-04`.
  final String label;

  /// Drill-down values. The **key set is the contract** -- a missing or extra key is a
  /// violation, and `PLAN-A-01`'s unit tests assert it key by key.
  final Map<String, Object?> evidence;

  double get ratio => max == 0 ? 0 : score / max;
}

/// Total score plus the four dimensions (FF-22 / API-04 section 3).
class HealthScore {
  const HealthScore({
    required this.totalScore,
    required this.grade,
    required this.regularity,
    required this.structure,
    required this.snack,
    required this.speed,
    this.deltaVsYesterday,
  });

  /// Sum of the four **individually rounded** dimension scores (API-04 section 1 rule 3).
  final int totalScore;

  /// `'良好'` / `'一般'` / `'需改善'` -- three values, never a fourth (FF-22b).
  final String grade;

  final DimensionScore regularity;
  final DimensionScore structure;
  final DimensionScore snack;
  final DimensionScore speed;

  /// Today minus yesterday. Three distinct semantics (ADR-10):
  /// * `null` -- yesterday had no usable data; the UI hides the row;
  /// * `0`    -- yesterday had data and the score is genuinely unchanged; the UI **must**
  ///             show "持平" rather than hiding it;
  /// * other  -- the actual difference.
  final int? deltaVsYesterday;

  static const String gradeGood = '良好';
  static const String gradeFair = '一般';
  static const String gradePoor = '需改善';

  List<DimensionScore> get dimensions => [regularity, structure, snack, speed];

  /// Grade from the frozen thresholds in the SSOT (ADR-P2).
  static String gradeOf(int totalScore) {
    if (totalScore >= cfg.FeatureConfig.healthScoreFormulaGradeThresholdsGoodMin) {
      return gradeGood;
    }
    if (totalScore >= cfg.FeatureConfig.healthScoreFormulaGradeThresholdsFairMin) {
      return gradeFair;
    }
    return gradePoor;
  }
}

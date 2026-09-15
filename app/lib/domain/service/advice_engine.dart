import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../model/advice.dart';
import '../model/health_score.dart';
import '../model/summaries.dart';

/// A-02 rule engine (`API-04` section 4, `SPEC-A-02`).
///
/// Five fixed rules plus an always-present `general` disclaimer. The engine is a pure
/// function: no clock, no randomness, no IO, no network -- so the same inputs always produce
/// byte-identical output (a property the report page and the tests both rely on).
///
/// It never recomputes a score (the four FF-22 formulas appear only in `ScoreFormulas`) and
/// never rewrites the numbers it is given.
class AdviceEngine {
  const AdviceEngine();

  // ------------------------------------------------------------------ frozen constants

  /// A-02-K1: at most five non-disclaimer suggestions.
  static const int maxSuggestions = 5;

  /// A-02-K4: below this many records the only output is the disclaimer.
  static const int minimumRecords = 3;

  /// A-02-K6: frozen word-for-word; this literal is the **only** definition in the repo.
  static const String disclaimerText = '提供日常健康管理建议，不进行疾病诊断，不替代专业医疗意见';

  /// A-02-K7: snack reminder threshold (deliberately lower than FF-22's zero-score point).
  static const int snackAlertThreshold = 5;

  /// A-02-K8: late-night reminder threshold.
  static const int lateNightAlertThreshold = 3;

  /// A-02-K9: regularity reminder ratio (`score < 0.6 × max`).
  static const double regularityAlertRatio = 0.6;

  /// A-02-K10: variety reminder threshold.
  static const int varietyAlertThreshold = 2;

  /// A-02-K2: priorities; `general` is the maximum so it always sorts last.
  static const int priorityHigh = 1;
  static const int priorityMedium = 2;
  static const int priorityLow = 3;
  static const int priorityGeneral = 4;

  /// A-02-K11: text length ceiling (characters).
  static const int maxTextLength = 40;

  // ------------------------------------------------------------------ generation

  Future<List<Advice>> generate({
    required HealthScore score,
    required WeekSummary agg,
  }) async {
    if (agg.recordCount < 0) {
      throw Errors.score('general', 'recordCount < 0');
    }

    final out = <Advice>[];

    // The disclaimer goes in first, so no early return can drop it.
    out.add(const Advice(
      dimension: Advice.dimGeneral,
      text: disclaimerText,
      priority: priorityGeneral,
    ));

    // A-02-K4: too little data -> the disclaimer alone (no invented advice).
    if (agg.recordCount < minimumRecords) {
      return AdviceOrder.sorted(out);
    }

    final n = agg.snackCount;
    final m = agg.lateNightCount;
    final t = score.speed.evidence['avgChewIntervalSeconds'] as double?;
    final k = agg.classCounts.values.where((v) => v > 0).length;

    // Rule 1 -- snack frequency.
    if (n >= snackAlertThreshold) {
      out.add(Advice(
        dimension: Advice.dimSnack,
        text: '本周零食 $n 次，建议减少薯片与软糖的频率，两餐之间可优先选择卷心菜或胡萝卜。',
        priority: priorityHigh,
      ));
    }

    // Rule 2 -- late-night eating (mapped onto `regularity`: the enum has no lateNight).
    if (m >= lateNightAlertThreshold) {
      out.add(Advice(
        dimension: Advice.dimRegularity,
        text: '有 $m 次进食发生在晚间，建议把正餐与加餐安排得更早一些。',
        priority: priorityHigh,
      ));
    }

    // Rule 3 -- eating speed, using FF-21e's "偏快" threshold (NOT the scoring endpoints).
    if (t != null && t < _speedFastSeconds) {
      out.add(Advice(
        dimension: Advice.dimSpeed,
        text: '本周平均咀嚼间隔约 ${t.toStringAsFixed(1)} 秒（偏快），建议放慢进食节奏。',
        priority: priorityMedium,
      ));
    }

    // Rule 4 -- meal-time regularity. A null sigma means the rule cannot fire (skip, never
    // substitute a zero: filling in `0` would invent a regularity claim).
    final sigma = score.regularity.evidence['sigmaMinutes'] as double?;
    if (sigma != null &&
        score.regularity.score < regularityAlertRatio * score.regularity.max) {
      out.add(const Advice(
        dimension: Advice.dimRegularity,
        text: '三餐时间不够固定，建议固定每天的用餐时段。',
        priority: priorityMedium,
      ));
    }

    // Rule 5 -- variety.
    if (k <= varietyAlertThreshold) {
      out.add(Advice(
        dimension: Advice.dimStructure,
        text: '本周记录到的食物只有 $k 类，建议主食与蔬果类都出现一些。',
        priority: priorityLow,
      ));
    }

    final ordered = AdviceOrder.sorted(out);
    return _truncateKeepingDisclaimer(ordered);
  }

  /// A-02-K1 / step 6: at most [maxSuggestions] non-disclaimer items; the `general` item is
  /// never truncated and always stays last.
  List<Advice> _truncateKeepingDisclaimer(List<Advice> sorted) {
    final general = <Advice>[];
    final others = <Advice>[];
    for (final a in sorted) {
      if (a.dimension == Advice.dimGeneral) {
        general.add(a);
      } else {
        others.add(a);
      }
    }
    final kept = others.take(maxSuggestions).toList();
    return [...kept, ...general];
  }

  static double get _speedFastSeconds =>
      cfg.FeatureConfig.behaviorSpeedThresholdsSecondsFast;
}

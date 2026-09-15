import '../../core/errors.dart';
import '../../core/time.dart';
import '../model/health_score.dart';
import '../repository/repositories.dart';
import 'score_formulas.dart';

/// A-01 health score card (`API-04` section 3, `SPEC-A-01`).
///
/// The service is a thin, stateless orchestrator: it reads the window aggregate and the
/// chewing statistics **once**, hands them to the pure [ScoreFormulas] kernel, and derives
/// `deltaVsYesterday` by re-running the kernel over the previous local calendar day.
///
/// Deliberate properties:
///  * no caching and no state -- the same range on the same database always produces the
///    same numbers (`API-05` section 6.1);
///  * no clock reads: the window comes from the caller, so a report is reproducible;
///  * no SQL and no sigma recomputation: `mealTimeStdDevMinutes` is consumed as-is.
class HealthScoreService {
  HealthScoreService({
    required this.stats,
    this.maxWindowDays = maxRangeDays,
  });

  final StatsRepo stats;

  /// `SPEC-A-01` A-01-K6: a range spans 1-31 days; anything else is `ACD-DB-004`.
  final int maxWindowDays;

  static const int maxRangeDays = 31;

  /// Minimum number of records before the UI leaves the empty state (A-01-K4).
  static const int minimumRecordsForDisplay = 3;

  Future<HealthScore> score({required DateRange range}) async {
    if (range.endMs <= range.startMs) {
      throw Errors.dbInvalid('range reversed: start=${range.startMs} end=${range.endMs}');
    }
    if (range.localDayCount > maxWindowDays) {
      throw Errors.dbInvalid('range longer than $maxWindowDays days');
    }
    return _compute(range);
  }

  Future<HealthScore> _compute(DateRange range) async {
    final agg = await stats.summary(range);
    final chew = await stats.chewStats(range);
    final mealSamples = await stats.mealTimeSamples(range);

    final inputs = ScoreInputs(
      sigmaMinutes: agg.mealTimeStdDevMinutes,
      mealTimeSamples: mealSamples.length,
      classCounts: agg.classCounts,
      recordCount: agg.recordCount,
      snackCount: agg.snackCount,
      lateNightCount: agg.lateNightCount,
      avgChewIntervalSeconds: chew.meanChewIntervalSeconds,
      sampleCount: chew.sampleCount,
      missingMetricsCount:
          (agg.recordCount - chew.sampleCount).clamp(0, agg.recordCount),
      windowDays: range.localDayCount,
    );

    final score = ScoreFormulas.compute(inputs);

    // deltaVsYesterday -> "the previous equal-length window", which is the previous local day
    // for a one-day window and the previous seven days for the home card's seven-day window.
    // ADR-23 changed this from a hard-wired `startOfLocalDay(range.startMs - 1)`: that always
    // measured ONE day, so a seven-day card would have been compared against a single day and
    // the delta would have been meaningless (while still looking plausible).
    final prevRange = range.previous;
    final prev = await _computeWithoutDelta(prevRange);
    // `null` (no usable previous window) is NOT the same as `0` (genuinely unchanged).
    final int? delta = prev == null ? null : score.totalScore - prev.totalScore;

    return HealthScore(
      totalScore: score.totalScore,
      grade: score.grade,
      regularity: score.regularity,
      structure: score.structure,
      snack: score.snack,
      speed: score.speed,
      deltaVsYesterday: delta,
    );
  }

  /// A day with no records at all yields `null`, which becomes `deltaVsYesterday == null`.
  Future<HealthScore?> _computeWithoutDelta(DateRange range) async {
    final agg = await stats.summary(range);
    if (agg.recordCount == 0) return null;
    final chew = await stats.chewStats(range);
    final mealSamples = await stats.mealTimeSamples(range);
    return ScoreFormulas.compute(ScoreInputs(
      sigmaMinutes: agg.mealTimeStdDevMinutes,
      mealTimeSamples: mealSamples.length,
      classCounts: agg.classCounts,
      recordCount: agg.recordCount,
      snackCount: agg.snackCount,
      lateNightCount: agg.lateNightCount,
      avgChewIntervalSeconds: chew.meanChewIntervalSeconds,
      sampleCount: chew.sampleCount,
      missingMetricsCount:
          (agg.recordCount - chew.sampleCount).clamp(0, agg.recordCount),
      windowDays: range.localDayCount,
    ));
  }
}

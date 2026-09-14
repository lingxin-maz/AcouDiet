import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../core/time.dart';
import '../model/advice.dart';
import '../model/health_score.dart';
import '../model/summaries.dart';
import '../repository/repositories.dart';
import 'advice_engine.dart';
import 'health_score_service.dart';

/// A-03 weekly report and trend service (`API-04` section 5, `SPEC-A-03`).
///
/// `summaryText` is the **only** sentence the domain layer is allowed to build (an explicit
/// exception to "formatting belongs to the UI"). Every number in it is derived from the real
/// aggregate; when there is nothing to compare against, the sentence says so instead of
/// inventing a percentage.
class ReportService {
  ReportService({
    required this.stats,
    required this.scores,
    this.advice = const AdviceEngine(),
  });

  final StatsRepo stats;
  final HealthScoreService scores;
  final AdviceEngine advice;

  /// A-03-K4, frozen word for word. The only text used when the window is empty.
  static const String insufficientDataText = '数据不足，继续记录即可看到趋势';
  /// A-03-K3: `days` must be in `[1,365]`.
  static const int minDays = 1;
  static const int maxDays = 365;

  /// ADR-25: **a daily number is scored over the seven local days ending on that day**, not over
  /// the day in isolation.
  ///
  /// Why (measured 2026-09-13, `tool/probe_daily_score.dart`): the four-axis display rule needs σ
  /// (two samples in the **same** meal window) and a structure ratio over ≥3 records. Inside one
  /// calendar day σ is essentially undefinable -- a normal day is one breakfast, one lunch, one
  /// dinner, and σ wants *two* breakfasts -- so `ScoreView.of` closed the total on **every** day
  /// and the 每日 card showed four rows plus `--` for the score **and** the grade. On the demo
  /// fixture (4 records/day, 3 with chewing metrics) every single day measured σ = null with
  /// structure 30/30, snack 18/20, speed 15/20 and a `--` total.
  ///
  /// The trailing window is the **same window the home card already scores** for today
  /// (`HomeNotifier.scoreWindowDays`), so today's 每日 number and the home card are one
  /// computation, and the 评分 trend line stops being a series of deflated totals (the kernel
  /// scores a null σ as `0`, which silently removed the whole 30-point regularity axis).
  static const int dailyScoreWindowDays = 7;

  // ------------------------------------------------------------------ weekly

  Future<WeeklyReport> weekly({required DateRange range}) async {
    if (range.endMs <= range.startMs) {
      throw Errors.dbInvalid('range reversed');
    }
    if (range.localDayCount > HealthScoreService.maxRangeDays) {
      throw Errors.dbInvalid('range longer than ${HealthScoreService.maxRangeDays} days');
    }

    // One read of each window: `API-04` section 5 forbids re-querying the same window.
    final agg = await stats.summary(range);
    final score = await scores.score(range: range);

    final prevRange = range.previous;
    final prevAgg = await _trySummary(prevRange);
    // The score deltas need the *previous* score; it is computed once, here, and reused.
    final prevScore =
        prevAgg == null ? null : await scores.score(range: prevRange);

    final deltas = _deltas(agg, score, prevAgg, prevScore);
    final summaryText = buildSummaryText(agg: agg, score: score, prevAgg: prevAgg);

    final advices = await advice.generate(score: score, agg: agg);

    return WeeklyReport(
      startMs: range.startMs,
      endMs: range.endMs,
      summaryText: summaryText,
      advices: advices,
      score: score,
      deltas: deltas,
    );
  }

  Future<WeekSummary?> _trySummary(DateRange range) async {    // An empty previous window is a normal state, not an error: it means "no benchmark".
    try {
      final agg = await stats.summary(range);
      return agg.recordCount == 0 ? null : agg;
    } on AcouDietError {
      return null;
    }
  }

  /// A-03-K2: exactly seven keys, always numeric, `0` when there is no benchmark.
  Map<String, num> _deltas(
    WeekSummary cur,
    HealthScore score,
    WeekSummary? prev,
    HealthScore? prevScore,
  ) {
    final zero = <String, num>{for (final k in WeeklyReport.deltaKeys) k: 0};
    if (prev == null || prevScore == null) return zero;

    return <String, num>{
      'totalScore': score.totalScore - prevScore.totalScore,
      'regularity': score.regularity.score - prevScore.regularity.score,
      'structure': score.structure.score - prevScore.structure.score,
      'snack': score.snack.score - prevScore.snack.score,
      'speed': score.speed.score - prevScore.speed.score,
      'recordCount': cur.recordCount - prev.recordCount,
      'estimatedKcal': cur.estimatedKcal - prev.estimatedKcal,
    };
  }

  /// Builds `summaryText` from table A-03-T1. Deterministic, clause by clause.
  String buildSummaryText({
    required WeekSummary agg,
    required HealthScore score,
    required WeekSummary? prevAgg,
  }) {
    if (agg.recordCount == 0) return insufficientDataText;

    final clauses = <String>['本周记录 ${agg.recordCount} 次'];

    if (agg.snackCount > 0) {
      clauses.add('，零食 ${agg.snackCount} 次');
    }

    // Clauses 3/4 attach to the snack count, which is what the report page highlights.
    if (prevAgg != null) {
      if (prevAgg.snackCount > 0) {
        final pct = ((agg.snackCount - prevAgg.snackCount) / prevAgg.snackCount * 100).round();
        final sign = pct >= 0 ? '+' : '−';
        clauses.add('，较上周 $sign${pct.abs()}%');
      } else if (agg.snackCount > 0) {
        clauses.add('，上周无同类记录可比');
      }
    }

    // Clause 5 only appears when the four dimensions are actually displayable, so the text
    // can never quote a score the report page would replace with `--`.
    if (_mayShowScore(score)) {
      clauses.add('，本周评分 ${score.totalScore} 分（${score.grade}）');
    }

    return clauses.join();
  }

  bool _mayShowScore(HealthScore score) {
    if (score.structure.evidence['totalCount'] == 0) return false;
    if (score.regularity.evidence['sigmaMinutes'] == null) return false;
    if (score.speed.evidence['avgChewIntervalSeconds'] == null) return false;
    return true;
  }

  // ------------------------------------------------------------------ trend

  /// One local day at a time, with the day's counts, kilocalories and **four-dimension score**
  /// (ADR-23), the score being the trailing window of ADR-25.
  ///
  /// The report page's 本周 scope scores the whole window; this is the 每日 scope's data, and it
  /// is also what the trend chart is built from -- so a day's number cannot differ between the
  /// chart, the daily list and the daily summary card.
  ///
  /// `estimatedKcal` and the counts come from **one** `stats.summary(day)` per day (the same
  /// aggregate the records page shows), never from a second, differently-shaped source. The day
  /// keys still come from `stats.trend(days)`: that series owns "one point per local day,
  /// ascending and gapless" contract **and** reads the repository's clock, which is what makes
  /// the page reproducible under test (`API-05` section 6.1). A day with records that cannot be
  /// scored keeps `score == null` instead of aborting the series (`SPEC-A-03` section 6).
  Future<List<DailyScore>> dailyScores({required int days}) async {
    if (days < minDays || days > maxDays) {
      throw Errors.dbInvalid('days out of [$minDays,$maxDays]: $days');
    }

    final raw = await stats.trend(days);
    final out = <DailyScore>[];

    for (final point in raw) {
      final dayStart = _parseDayKey(point.date);
      if (dayStart == null) {
        out.add(DailyScore(
          date: point.date,
          estimatedKcal: null,
          recordCount: 0,
          snackCount: 0,
          classCounts: {for (final l in cfg.FeatureConfig.classLabels) l: 0},
          score: null,
        ));
        continue;
      }

      final range = DateRange(dayStart, dayStart + 86400000);
      final agg = await stats.summary(range);

      HealthScore? dayScore;
      if (agg.recordCount > 0) {
        try {
          // ADR-25: the score covers the seven days ending on this day, not the day alone.
          dayScore = await scores.score(range: scoreWindowFor(dayStart));
        } on AcouDietError {
          dayScore = null;
        }
      }

      out.add(DailyScore(
        date: point.date,
        estimatedKcal: agg.recordCount == 0 ? null : agg.estimatedKcal,
        recordCount: agg.recordCount,
        snackCount: agg.snackCount,
        classCounts: agg.classCounts,
        score: dayScore,
      ));
    }

    return out;
  }

  Future<TrendSeries> trend({required int days}) async {
    if (days < minDays || days > maxDays) {
      throw Errors.dbInvalid('days out of [$minDays,$maxDays]: $days');
    }

    final raw = await stats.trend(days);
    final filled = <TrendPoint>[];

    for (final point in raw) {
      int? total;
      final dayStart = _parseDayKey(point.date);
      if (dayStart != null && point.estimatedKcal != null) {
        try {
          // ADR-25: the same trailing window as `dailyScores`, so the chart's 评分 line and the
          // 「每日」card can never disagree about a day.
          total = (await scores.score(range: scoreWindowFor(dayStart))).totalScore;
        } on AcouDietError {
          // A single unscorable day must not break the whole series (SPEC-A-03 section 6).
          total = null;
        }
      }
      filled.add(TrendPoint(
        date: point.date,
        estimatedKcal: point.estimatedKcal,
        totalScore: total,
      ));
    }

    return TrendSeries(filled);
  }

  /// The window a daily score is computed over: the `dailyScoreWindowDays` local days ending on
  /// `dayStart` (inclusive), half-open `[start, end)` (ADR-25).
  ///
  /// Public because the report presenter labels the card with it: a number that covers seven days
  /// must say so, or a reader will take it for that day's own score.
  static DateRange scoreWindowFor(int dayStart) {
    final (start, end) =
        TimeUtil.lastLocalDays(dailyScoreWindowDays, nowMsOverride: dayStart);
    return DateRange(start, end);
  }

  int? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d).millisecondsSinceEpoch;
  }
}

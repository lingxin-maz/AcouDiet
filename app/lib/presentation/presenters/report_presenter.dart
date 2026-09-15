// app/lib/presentation/presenters/report_presenter.dart
//
// U-04 (health report) display logic. PURE DART (no Flutter import).
//
// Rules encoded here:
//  * the four drill-down rows reuse `ScoreFormulas.formulaOf` -- there is exactly one
//    human-readable formula string in the repository (A-01-K5), so the page cannot drift from
//    the kernel it explains;
//  * `deltas` always has exactly seven keys (API-04 section 5) and is a **difference, not a
//    ratio**; a value of `0` means "genuinely unchanged" and the row therefore stays visible
//    (ADR-10) -- `deltas.isEmpty` is never a degradation test, it is always false;
//  * the trend series keeps `null` for a day without records: the chart breaks the line instead
//    of drawing a zero (SPEC-U-04 section 2.2 step 2) and the text equivalent says "no data";
//  * the disclaimer is rendered in the ready **and** the insufficient state.

import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/advice.dart';
import '../../domain/model/health_score.dart';
import '../../domain/model/summaries.dart';
import '../../domain/service/advice_engine.dart';
import '../../domain/service/behavior_analyzer.dart';
import '../../domain/service/health_score_service.dart';
import '../theme/acou_format.dart';
import '../theme/food_class.dart';
import 'records_presenter.dart' show RecordCardText;
import 'score_view.dart';
import 'ui_strings.dart';

/// One dimension drill-down row.
class DimensionDrillView {
  const DimensionDrillView({
    required this.dimension,
    required this.label,
    required this.displayable,
    required this.scoreText,
    required this.ratioLine,
    required this.formulaText,
    required this.evidence,
    required this.semanticsText,
  });

  final String dimension;
  final String label;
  final bool displayable;

  /// `26/30`, or the empty marker.
  final String scoreText;

  /// `饮食规律性 26/30` (criterion 4: every row matches `\S+ \d+/\d+`).
  final String ratioLine;

  /// The single authoritative formula string.
  final String formulaText;

  final List<EvidenceLine> evidence;
  final String semanticsText;

  static DimensionDrillView of(ScoreAxisView axis) => DimensionDrillView(
        dimension: axis.dimension,
        label: axis.label,
        displayable: axis.displayable,
        scoreText: axis.scoreText,
        ratioLine: axis.ratioText,
        formulaText: axis.formulaText,
        evidence: axis.evidence,
        semanticsText: axis.displayable
            ? '${axis.label} ${axis.score} 分，满分 ${axis.max} 分，公式 ${axis.formulaText}'
            : '${axis.label} ${AcouFormat.noValue}',
      );
}

/// One period-over-period row.
class DeltaRowView {
  const DeltaRowView({
    required this.key,
    required this.label,
    required this.value,
    required this.text,
  });

  /// One of `WeeklyReport.deltaKeys`.
  final String key;
  final String label;
  final num value;

  /// `+12 分` / `-3 次` / `持平`; the kilocalorie row keeps its estimate word.
  final String text;

  static const Map<String, String> labels = {
    'totalScore': '总分',
    'regularity': '饮食规律性',
    'structure': '食物结构',
    'snack': '零食控制',
    'speed': '进食速度',
    'recordCount': '记录次数',
    'estimatedKcal': '估算热量',
  };

  static DeltaRowView of(String key, num value) {
    final label = labels[key] ?? key;
    final String text;
    if (key == 'estimatedKcal') {
      // A kilocalorie may never appear without its estimate wording (FF-25).
      text = '估算 ${AcouFormat.periodDeltaText(value, 'kcal')}';
    } else if (key == 'recordCount') {
      text = AcouFormat.periodDeltaText(value, UiStrings.snackCountSuffix);
    } else {
      text = AcouFormat.periodDeltaText(value, '分');
    }
    return DeltaRowView(key: key, label: label, value: value, text: text);
  }
}

/// One point of the trend chart. `value == null` means the day has no records and the line
/// must break (never a zero).
class TrendChartPoint {
  const TrendChartPoint({
    required this.date,
    required this.label,
    required this.value,
    required this.valueText,
    required this.axis,
  });

  /// `yyyy-MM-dd`, ascending and gapless (API-04 section 5).
  final String date;

  /// `M/d` for the abscissa.
  final String label;

  final double? value;
  final String valueText;
  final ChartAxis axis;

  bool get hasValue => value != null;

  /// `周一 1100 千卡` / `周三无数据`.
  String get spokenText {
    final weekday = AcouFormat.weekdayLabel(date);
    return hasValue ? '$weekday $valueText' : '$weekday${UiStrings.trendNoDataWord}';
  }
}

/// The whole trend series plus its text equivalent.
class TrendChartData {
  const TrendChartData({
    required this.axis,
    required this.points,
    required this.textEquivalent,
    required this.hasAnyValue,
  });

  final ChartAxis axis;
  final List<TrendChartPoint> points;
  final String textEquivalent;

  /// `false` when every day is empty: the chart degrades to the empty state instead of a flat
  /// line at zero.
  final bool hasAnyValue;

  int get days => points.length;
  int get filledCount => points.where((p) => p.hasValue).length;

  static TrendChartData of(List<TrendPoint> raw, ChartAxis axis) {
    final points = <TrendChartPoint>[];
    for (final p in raw) {
      final double? value = switch (axis) {
        ChartAxis.kcal => p.estimatedKcal?.toDouble(),
        ChartAxis.score => p.totalScore?.toDouble(),
      };
      points.add(TrendChartPoint(
        date: p.date,
        label: AcouFormat.shortDate(p.date),
        value: value,
        valueText: value == null
            ? UiStrings.trendNoDataWord
            : switch (axis) {
                ChartAxis.kcal => '${value.round()} ${UiStrings.kcalUnit}',
                ChartAxis.score => '${value.round()} 分',
              },
        axis: axis,
      ));
    }
    return TrendChartData(
      axis: axis,
      points: points,
      textEquivalent: UiStrings.trendSemantics(
        points.map((p) => p.spokenText).join('，'),
      ),
      hasAnyValue: points.any((p) => p.hasValue),
    );
  }

  /// The series must be ascending and gapless in local calendar days; the presenter exposes
  /// the check so the pure test runner can assert the contract without re-deriving it.
  ({bool ascending, bool gapless}) get shape {
    var ascending = true;
    var gapless = true;
    for (var i = 1; i < points.length; i++) {
      final prev = DateTime.tryParse(points[i - 1].date);
      final cur = DateTime.tryParse(points[i].date);
      if (prev == null || cur == null) {
        ascending = false;
        gapless = false;
        continue;
      }
      if (!cur.isAfter(prev)) ascending = false;
      if (cur.difference(prev).inDays != 1) gapless = false;
    }
    return (ascending: ascending, gapless: gapless);
  }
}

/// One day of the report's 「每日」 scope (ADR-23).
class DailyScoreView {
  const DailyScoreView({
    required this.date,
    required this.dateLabel,
    required this.hasData,
    required this.scoreView,
    required this.totalText,
    required this.kcalText,
    required this.countText,
    required this.snackText,
    required this.classSummary,
    required this.rows,
    required this.semanticsText,
  });

  /// `yyyy-MM-dd`.
  final String date;

  /// `9月10日`.
  final String dateLabel;

  /// `false` for a day with no records: the list omits it entirely (the caller filters), so a
  /// rendered view always has data.
  final bool hasData;

  /// The day's four dimensions, projected exactly like the 本周 header's. `ScoreView.unavailable()`
  /// when the day could not be scored at all, so the card renders four `--` rows instead of an
  /// invented score.
  final ScoreView scoreView;

  /// The day's total, or the empty marker when its four dimensions are not all displayable.
  final String totalText;

  /// `估算 300 kcal`, or the empty marker.
  final String kcalText;

  /// `4 次`.
  final String countText;

  /// `1 次` -- solid snacks only (ADR-23).
  final String snackText;

  /// `面条 ×2 · 胡萝卜 ×1`, or empty when the day has no records.
  final String classSummary;

  /// Exactly four rows, `饮食规律性 26/30` / `食物结构 --`.
  final List<(String, String)> rows;

  final String semanticsText;

  /// Builds the four rows from the SAME `ScoreView` projection the 本周 header uses, so a
  /// dimension cannot be displayable in one scope and not the other.
  static DailyScoreView of(DailyScore day) {
    final score = day.score;
    final view = score == null ? ScoreView.unavailable() : ScoreView.of(score);
    final rows = <(String, String)>[];
    for (final axis in view.axes) {
      rows.add((axis.label, axis.scoreText));
    }
    final dateLabel = labelOf(day.date);
    final total = view.totalDisplayable ? view.totalText : AcouFormat.noValue;
    final kcalText = day.estimatedKcal == null
        ? AcouFormat.noValue
        : AcouFormat.kcalEstimate(day.estimatedKcal!);
    return DailyScoreView(
      date: day.date,
      dateLabel: dateLabel,
      hasData: day.hasData,
      scoreView: view,
      totalText: total,
      kcalText: kcalText,
      countText: '${day.recordCount} ${UiStrings.snackCountSuffix}',
      snackText: '${day.snackCount} ${UiStrings.snackCountSuffix}',
      classSummary: classSummaryOf(day),
      rows: rows,
      semanticsText: '$dateLabel，记录 ${day.recordCount} 次，'
          '${day.estimatedKcal == null ? '无估算热量' : '估算热量 ${day.estimatedKcal} 千卡'}，'
          '其中零食 ${day.snackCount} 次，四维评分：'
          '${rows.map((r) => '${r.$1} ${r.$2}').join('，')}，总分 $total 分',
    );
  }

  /// `软性主食 ×2 · 脆爽蔬菜 ×1` -- the day's classes by Chinese name, biggest first, ties broken
  /// by the frozen FF-19 order so the string is deterministic.
  static String classSummaryOf(DailyScore day) {
    final order = <String, int>{
      for (final c in FoodClassId.values) c.zhName: c.id,
    };
    final entries = <(String, int)>[];
    for (final label in cfg.FeatureConfig.classLabels) {
      final n = day.countOf(label);
      if (n == 0) continue;
      entries.add((foodNameOf(label), n));
    }
    if (entries.isEmpty) return '';
    // Dart's `List.sort` is not stable, so the comparison spells out both keys instead of
    // relying on the input order to break ties.
    entries.sort((a, b) {
      final byCount = b.$2.compareTo(a.$2);
      return byCount != 0 ? byCount : (order[a.$1] ?? 1 << 30).compareTo(order[b.$1] ?? 1 << 30);
    });
    return entries.map((e) => '${e.$1} ×${e.$2}').join(' · ');
  }

  /// The Chinese name of a class label -- 「未知类别」 for a label outside FF-19, never a guess.
  static String foodNameOf(String label) {
    for (final c in FoodClassId.values) {
      if (c.label == label) return c.zhName;
    }
    return UiStrings.unknownCategory;
  }

  /// `9月10日` for a `yyyy-MM-dd` key (the same helper the records page uses).
  static String labelOf(String date) {
    final parts = date.split('-');
    if (parts.length != 3) return date;
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (month == null || day == null) return date;
    return '$month月$day日';
  }
}

/// One advice row.
class AdviceItemView {
  const AdviceItemView({
    required this.dimension,
    required this.text,
    required this.priority,
    required this.isDisclaimer,
  });

  final String dimension;
  final String text;
  final int priority;

  /// `true` for the single `general` item (API-04 section 4).
  final bool isDisclaimer;

  static AdviceItemView of(Advice advice) => AdviceItemView(
        dimension: advice.dimension,
        text: advice.text,
        priority: advice.priority,
        isDisclaimer: advice.dimension == Advice.dimGeneral,
      );
}

/// The whole report page.
class ReportView {
  const ReportView({
    required this.insufficient,
    required this.insufficientText,
    required this.score,
    required this.drills,
    required this.deltas,
    required this.summaryText,
    required this.advices,
    required this.adviceEmptyText,
    required this.disclaimerText,
    required this.trendScore,
    required this.trendKcal,
    required this.dailyScores,
    required this.demoActive,
    required this.recordCount,
    required this.snackCount,
    required this.meanChewIntervalSeconds,
    required this.recentRecords,
  });

  /// SPEC-U-04 section 6: below the record threshold the page degrades deterministically
  /// instead of fabricating a chart.
  final bool insufficient;
  final String insufficientText;

  final ScoreView score;

  /// Exactly four rows, in the FF-22 order.
  final List<DimensionDrillView> drills;

  /// Always exactly seven rows (API-04 section 5).
  final List<DeltaRowView> deltas;

  final String summaryText;

  /// Non-disclaimer suggestions; empty means the frozen empty copy is shown.
  final List<AdviceItemView> advices;
  final String adviceEmptyText;

  /// Always rendered, in both the ready and the insufficient state (criterion 9).
  final String disclaimerText;

  final TrendChartData trendScore;
  final TrendChartData trendKcal;

  /// ADR-23: the per-day four-dimension breakdown, newest day first, **only days with records**
  /// (a day with no data would be four rows of `--`, which the empty state already says once).
  final List<DailyScoreView> dailyScores;

  final bool demoActive;
  final int recordCount;

  /// ADR-24: the window's **solid** snack count (`ADR-23`: a liquid is not a snack). It is the
  /// same `WeekSummary.snackCount` the records page and the scoring kernel read, surfaced here
  /// because 「我的」 shows it in the three-up panel.
  final int snackCount;

  /// ADR-24: the window's mean chewing interval (`StatsRepo.chewStats`, the frozen input of
  /// FF-22's `speed` dimension), or `null` when no record in the window carried a chewing sample.
  /// `null` is rendered as `--`/`无样本`, **never** as `0` or as a grade word.
  final double? meanChewIntervalSeconds;

  /// ADR-24: the newest few records of the same window, in the frozen card template. Only the
  /// 最近识别记录 tiles read this; it is a *view* of the ordinary record list, not a new metric.
  final List<RecordCardText> recentRecords;

  /// `正常` / `偏快` / `偏慢` / `--`. The grade comes from `BehaviorAnalyzer.speedGradeFor`, the
  /// same mapping a live session uses.
  String get meanChewSpeedText => meanChewIntervalSeconds == null
      ? UiStrings.overviewNoSample
      : BehaviorAnalyzer.speedGradeFor(meanChewIntervalSeconds!);

  /// The three-up panel's values, in the mockup's order.
  String get overviewRecordCountText => '$recordCount ${UiStrings.snackCountSuffix}';
  String get overviewSnackCountText => '$snackCount ${UiStrings.snackCountSuffix}';

  TrendChartData trend(ChartAxis axis) =>
      axis == ChartAxis.kcal ? trendKcal : trendScore;

  /// M-03 C5 wants the badge visible in at least two places on the demonstration screens;
  /// the report page contributes the header badge and the trend-section badge.
  String get demoBadgeText => demoActive ? UiStrings.demoDataBadge : '';

  static ReportView of({
    required HealthScore? score,
    required String summaryText,
    required Map<String, num> deltas,
    required List<Advice> advices,
    required List<TrendPoint> trendPoints,
    required WeekSummary? agg,
    List<DailyScore> dailyScores = const <DailyScore>[],
    double? meanChewIntervalSeconds,
    List<RecordCardText> recentRecords = const <RecordCardText>[],
    bool demoActive = false,
    bool summaryUnavailable = false,
  }) {
    final scoreView = score == null ? ScoreView.unavailable() : ScoreView.of(score);
    final recordCount = agg?.recordCount ?? 0;
    final snackCount = agg?.snackCount ?? 0;
    final insufficient = score == null || recordCount < HealthScoreService.minimumRecordsForDisplay;

    final drillViews = scoreView.axes.map(DimensionDrillView.of).toList(growable: false);

    // `deltas` is contractually complete; iterate the frozen key list rather than the map so a
    // missing key shows up as an explicit empty row instead of silently vanishing.
    final deltaRows = <DeltaRowView>[];
    for (final key in WeeklyReport.deltaKeys) {
      deltaRows.add(DeltaRowView.of(key, deltas[key] ?? 0));
    }

    final itemViews = <AdviceItemView>[];
    var disclaimer = UiStrings.disclaimerText;
    for (final a in advices) {
      if (a.dimension == Advice.dimGeneral) {
        disclaimer = a.text;
        continue;
      }
      itemViews.add(AdviceItemView.of(a));
    }

    return ReportView(
      insufficient: insufficient,
      insufficientText: recordCount == 0
          ? UiStrings.reportInsufficient
          : UiStrings.reportInsufficientFew,
      score: scoreView,
      drills: drillViews,
      deltas: deltaRows,
      summaryText: summaryUnavailable ? UiStrings.weekSummaryInsufficient : summaryText,
      advices: itemViews,
      adviceEmptyText: UiStrings.adviceEmpty,
      disclaimerText: disclaimer.isEmpty ? AdviceEngine.disclaimerText : disclaimer,
      trendScore: TrendChartData.of(trendPoints, ChartAxis.score),
      trendKcal: TrendChartData.of(trendPoints, ChartAxis.kcal),
      // Newest first, and only the days that actually have records.
      dailyScores: dailyScores.reversed
          .where((d) => d.hasData)
          .map(DailyScoreView.of)
          .toList(growable: false),
      demoActive: demoActive,
      recordCount: recordCount,
      snackCount: snackCount,
      meanChewIntervalSeconds: meanChewIntervalSeconds,
      recentRecords: List<RecordCardText>.unmodifiable(recentRecords),
    );
  }
}

abstract final class ReportPresenter {
  ReportPresenter._();

  /// The page title is `本周`; the visual-correction list forbids the older wording.
  static const String title = UiStrings.reportTitle;

  /// The four-axis total: the drill-down rows must add up to the displayed total, because the
  /// kernel rounds each dimension before summing (ADR-15 / API-05 section 6.2).
  static int sumOfDimensions(Iterable<DimensionDrillView> drills) {
    var total = 0;
    for (final d in drills) {
      if (!d.displayable) continue;
      final parts = d.scoreText.split('/');
      if (parts.length != 2) continue;
      total += int.tryParse(parts[0]) ?? 0;
    }
    return total;
  }

  /// The disclaimer footer is rendered in both states (criterion 9).
  static const String disclaimerText = UiStrings.disclaimerText;
}

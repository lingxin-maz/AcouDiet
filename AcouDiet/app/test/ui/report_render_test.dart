// app/test/ui/report_render_test.dart
//
// SPEC-C-05 section 5 #1 / SPEC-A-03 acceptance 8: the report page's rendered numbers must be
// field-by-field equal to the `WeeklyReport` the service produced -- the total, the four
// `score/max` rows, all seven deltas and the weekly sentence. It also pins the two structural
// rules that are easy to regress:
//   * the seven deltas are always rendered, `0` included (never hidden as "no data");
//   * the insufficient state shows no fabricated numbers and still shows the disclaimer.
//
// Runs under `flutter test`; the binding-free half of these assertions lives in
// `tool/ui_presenter_tests.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/core/time.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/domain/model/diet_record.dart';
import '../../lib/domain/service/advice_engine.dart';
import '../../lib/domain/service/health_score_service.dart';
import '../../lib/domain/service/report_service.dart';
import '../../lib/presentation/presenters/report_presenter.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/theme/acou_format.dart' show ChartAxis;
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/advice_list_item.dart';
import '../../lib/presentation/widgets/trend_line_chart.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

DateRange _week() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

/// A record at a fixed local time on [dayOfWindow] (0 = the anchor day).
DietRecord _record(int dayOfWindow, int hour, int minute, int classId) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOfWindow));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: 'r-$dayOfWindow-$hour-$minute-$classId',
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + 300000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    attribute: 'fixture',
    confidence: 0.82,
    durationSeconds: 300,
    source: 'real',
  );
}

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('the report view carries exactly the service values', (tester) async {
    final repo = FakeRepo.demoFixture();
    final service = ReportService(stats: repo, scores: HealthScoreService(stats: repo));
    final report = await service.weekly(range: _week());
    final trend = await service.trend(days: 7);
    final view = ReportView.of(
      score: report.score,
      summaryText: report.summaryText,
      deltas: report.deltas,
      advices: report.advices,
      trendPoints: trend.points,
      agg: await repo.week(),
    );

    // Total, grade and the four score/max rows, field by field.
    expect(view.score.totalText, '${report.score.totalScore}');
    expect(view.score.gradeText, report.score.grade);
    expect(view.drills.length, 4);
    for (final dimension in report.score.dimensions) {
      final row = view.drills.firstWhere((d) => d.label == dimension.label);
      expect(row.scoreText, '${dimension.score}/${dimension.max}');
    }

    // All seven deltas, each equal to the service value, all rendered (zero included).
    expect(view.deltas.length, 7);
    for (final row in view.deltas) {
      expect(row.value, report.deltas[row.key]);
      expect(row.text.isNotEmpty, isTrue);
    }

    // The weekly sentence is the service sentence, rendered by the page.
    expect(view.summaryText, report.summaryText);

    await tester.pumpWidget(_host(AdviceSection(
      advices: view.advices,
      disclaimerText: view.disclaimerText,
    )));
    expect(find.text(AdviceEngine.disclaimerText), findsOneWidget);
  });

  testWidgets('the trend chart keeps seven slots and breaks the empty days',
      (tester) async {
    final repo = FakeRepo(
      records: [_record(0, 7, 0, 3), _record(2, 12, 0, 4)],
      baseDayMs: _anchorMs,
    );
    final service = ReportService(stats: repo, scores: HealthScoreService(stats: repo));
    final trend = await service.trend(days: 7);
    final data = TrendChartData.of(trend.points, ChartAxis.kcal);

    await tester.pumpWidget(_host(TrendLineChart(data: data)));

    expect(data.days, 7);
    expect(data.filledCount, 2);
    expect(data.points.where((p) => !p.hasValue).every((p) => p.value == null), isTrue);
    // The text equivalent is the screen-reader form of the series (U-04 section 8).
    expect(data.textEquivalent, contains(UiStrings.trendNoDataWord));
  });

  testWidgets('the insufficient state fabricates nothing and keeps the disclaimer',
      (tester) async {
    final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
    final service = ReportService(stats: repo, scores: HealthScoreService(stats: repo));
    final report = await service.weekly(range: _week());
    final view = ReportView.of(
      score: report.score,
      summaryText: report.summaryText,
      deltas: report.deltas,
      advices: report.advices,
      trendPoints: (await service.trend(days: 7)).points,
      agg: await repo.week(),
    );

    expect(view.insufficient, isTrue);
    expect(view.insufficientText, UiStrings.reportInsufficient);
    expect(view.advices, isEmpty);
    expect(view.trendKcal.hasAnyValue, isFalse);

    await tester.pumpWidget(_host(AdviceSection(
      advices: view.advices,
      disclaimerText: view.disclaimerText,
    )));
    expect(find.text(UiStrings.adviceEmpty), findsOneWidget);
    expect(find.text(AdviceEngine.disclaimerText), findsOneWidget);
  });
}

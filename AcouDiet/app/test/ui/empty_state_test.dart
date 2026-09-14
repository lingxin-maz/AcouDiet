// app/test/ui/empty_state_test.dart
//
// SPEC-U-01 acceptance 3 and 4, plus the shared `--` rules: the empty state must be deterministic,
// a failed region must not be reported as a zero, and the "vs yesterday" row has exactly three
// behaviours. A `0` where the contract says the empty marker is a defect: a zero is data, "no
// data" is not.
//
// Runs under `flutter test`; the binding-free half lives in `tool/ui_presenter_tests.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/core/time.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/domain/model/diet_record.dart';
import '../../lib/domain/model/health_score.dart';
import '../../lib/domain/model/summaries.dart';
import '../../lib/domain/service/health_score_service.dart';
import '../../lib/presentation/presenters/food_catalog.dart';
import '../../lib/presentation/presenters/home_presenter.dart';
import '../../lib/presentation/presenters/records_presenter.dart';
import '../../lib/presentation/presenters/score_view.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/theme/acou_format.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/score_card.dart';
import '../../lib/presentation/widgets/state_view.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

DateRange _week() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

/// A record at a fixed local time on [dayOfWindow] (0 = the anchor day).
DietRecord _record(int dayOfWindow, int hour, int minute, {int classId = 3}) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOfWindow));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: 'e-$dayOfWindow-$hour-$minute',
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
  testWidgets('an empty library shows the four frozen values', (tester) async {
    final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
    final score = await HealthScoreService(stats: repo).score(range: _week());
    final home = HomeView.of(
      today: await repo.today(),
      week: await repo.week(),
      score: score,
      catalog: const EmptyFoodCatalog(),
    );

    // The four contract values: `--`, 暂无数据, 0 次, 今天还没有记录.
    expect(home.score.totalText, AcouFormat.noValue);
    expect(home.energy.displayText, UiStrings.homeEnergyEmpty);
    expect(home.week.text, '本周记录 0 次');
    expect(home.todayRecordsEmptyText, UiStrings.homeTodayRecordsEmpty);

    await tester.pumpWidget(_host(ScoreCard(score: home.score)));
    expect(find.text(AcouFormat.noValue), findsWidgets);
    expect(find.text(score.grade), findsNothing);
  });

  testWidgets('a dimension without a basis renders the empty marker, not a zero',
      (tester) async {
    // One record per meal class: no class reaches two samples, so sigma is undefined.
    final repo = FakeRepo(
      records: [_record(1, 7, 0), _record(2, 12, 0, classId: 4), _record(3, 18, 0, classId: 0)],
      baseDayMs: _anchorMs,
    );
    final score = await HealthScoreService(stats: repo).score(range: _week());
    final view = ScoreView.of(score);

    expect(score.regularity.evidence['sigmaMinutes'], isNull);
    expect(view.totalText, AcouFormat.noValue);
    expect(view.deltaVisible, isFalse);
    final regularity = view.axes.firstWhere((a) => a.dimension == 'regularity');
    expect(regularity.displayable, isFalse);
    expect(regularity.radarValue, 0);

    await tester.pumpWidget(_host(ScoreCard(score: view)));
    expect(find.text(AcouFormat.noValue), findsWidgets);
  });

  testWidgets('the delta row is hidden for null, flat for zero, signed otherwise',
      (tester) async {
    final repo = FakeRepo.demoFixture();
    final score = await HealthScoreService(stats: repo).score(range: _week());

    HealthScore withDelta(int? delta) => HealthScore(
          totalScore: score.totalScore,
          grade: score.grade,
          regularity: score.regularity,
          structure: score.structure,
          snack: score.snack,
          speed: score.speed,
          deltaVsYesterday: delta,
        );

    await tester.pumpWidget(_host(ScoreCard(score: ScoreView.of(withDelta(null)))));
    expect(find.text(UiStrings.deltaRowLabel), findsNothing);

    await tester.pumpWidget(_host(ScoreCard(score: ScoreView.of(withDelta(0)))));
    expect(find.text(UiStrings.deltaRowLabel), findsOneWidget);
    expect(find.text(AcouFormat.flatText), findsOneWidget);

    await tester.pumpWidget(_host(ScoreCard(score: ScoreView.of(withDelta(12)))));
    expect(find.text(AcouFormat.deltaText(12)!), findsOneWidget);
  });

  testWidgets('a failed region shows its retry copy instead of a zero', (tester) async {
    final home = HomeView.of(
      today: null,
      week: null,
      score: null,
      catalog: const EmptyFoodCatalog(),
      recordsUnavailable: true,
    );

    expect(home.scoreUnavailable, isTrue);
    expect(home.week.text, '本周记录 -- 次');
    expect(home.todayRecordsEmptyText, UiStrings.recordsListError);
    expect(home.energy.displayText, UiStrings.homeEnergyEmpty);

    await tester.pumpWidget(_host(StateView(
      status: ViewStatus.error,
      message: home.todayRecordsEmptyText,
      compact: true,
    )));
    expect(find.text(UiStrings.recordsListError), findsOneWidget);
  });

  testWidgets('the summary bar keeps real zeros and refuses to fake a failed aggregate',
      (tester) async {
    expect(RecordsSummaryView.unknown.barText, '-- / -- / --');
    expect(RecordsSummaryView.of(TodaySummary.empty).barText, '估算 0 kcal / 0 次 / 0 次');
  });
}

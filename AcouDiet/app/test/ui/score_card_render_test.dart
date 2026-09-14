// app/test/ui/score_card_render_test.dart
//
// SPEC-C-05 section 5 #3 / SPEC-A-01 acceptance 7: the score card's rendered numbers must be
// **field-by-field equal** to what `HealthScoreService` computed. This is the anti-"design-mockup
// numbers" test: if the widget layer ever hard-codes a score, a grade or a dimension ratio, it
// fails here.
//
// Runs under `flutter test` (needs a Flutter toolchain). Everything that can be asserted without a
// binding lives in `tool/ui_presenter_tests.dart`, which runs against the Dart SDK alone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/time.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/domain/model/health_score.dart';
import '../../lib/domain/service/health_score_service.dart';
import '../../lib/presentation/presenters/food_catalog.dart';
import '../../lib/presentation/presenters/home_presenter.dart';
import '../../lib/presentation/presenters/records_presenter.dart';
import '../../lib/presentation/presenters/score_view.dart';
import '../../lib/presentation/theme/acou_format.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/four_dim_radar.dart';
import '../../lib/presentation/widgets/record_card.dart';
import '../../lib/presentation/widgets/score_card.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

Future<HealthScore> _demoScore() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return HealthScoreService(stats: FakeRepo.demoFixture())
      .score(range: DateRange(start, end));
}

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('score card renders the service total, grade and dimension ratios',
      (tester) async {
    final score = await _demoScore();
    final view = ScoreView.of(score);

    await tester.pumpWidget(_host(ScoreCard(score: view)));

    expect(find.text('${score.totalScore}'), findsOneWidget);
    expect(find.text(score.grade), findsOneWidget);
    for (final dimension in score.dimensions) {
      // Scoped to the dimension's own row, not the whole tree. Two demo dimensions both score
      // `30/30`, so a global `find.text` legitimately matches twice -- the widget is right and a
      // global finder simply cannot tell the two rows apart.
      final row = find
          .ancestor(of: find.text(dimension.label), matching: find.byType(Row))
          .first;
      expect(
        find.descendant(of: row, matching: find.text('${dimension.score}/${dimension.max}')),
        findsOneWidget,
        reason: 'dimension ${dimension.label} must render score/max verbatim',
      );
      expect(find.text(dimension.label), findsWidgets);
    }
  });

  testWidgets('the four dimensions add up to the displayed total', (tester) async {
    final score = await _demoScore();
    final view = ScoreView.of(score);
    await tester.pumpWidget(_host(ScoreCard(score: view)));

    expect(view.totalText, '${score.totalScore}');
    expect(
      score.regularity.score + score.structure.score + score.snack.score + score.speed.score,
      score.totalScore,
    );
  });

  testWidgets('the radar carries a text equivalent for screen readers', (tester) async {
    final score = await _demoScore();
    final view = ScoreView.of(score);
    await tester.pumpWidget(_host(FourDimRadar(score: view)));

    final semantics = tester.getSemantics(find.byType(FourDimRadar));
    for (final axis in view.axes) {
      expect(semantics.label, contains(axis.label));
    }
    expect(semantics.label, contains(view.totalText));
  });

  testWidgets('a null delta hides the row and a zero delta shows 持平', (tester) async {
    final score = await _demoScore();
    final hidden = ScoreView.of(HealthScore(
      totalScore: score.totalScore,
      grade: score.grade,
      regularity: score.regularity,
      structure: score.structure,
      snack: score.snack,
      speed: score.speed,
      deltaVsYesterday: null,
    ));
    await tester.pumpWidget(_host(ScoreCard(score: hidden)));
    expect(find.text(AcouFormat.flatText), findsNothing);

    final flat = ScoreView.of(HealthScore(
      totalScore: score.totalScore,
      grade: score.grade,
      regularity: score.regularity,
      structure: score.structure,
      snack: score.snack,
      speed: score.speed,
      deltaVsYesterday: 0,
    ));
    await tester.pumpWidget(_host(ScoreCard(score: flat)));
    expect(find.text(AcouFormat.flatText), findsOneWidget);
  });

  testWidgets('a record without a knowledge-base entry renders no kilocalorie at all',
      (tester) async {
    final repo = FakeRepo.demoFixture();
    final record = (await repo.today()).records.first;
    // An unloaded catalogue is the honest degraded path: no portion, no kilocalorie, and the
    // placeholder food name instead of a guess (U-06 section 2.4).
    final card = RecordsView.cardOf(record, const EmptyFoodCatalog());
    await tester.pumpWidget(_host(RecordCard(card: card)));

    expect(card.hasKnowledge, isFalse);
    expect(find.textContaining('kcal'), findsNothing);
    expect(find.text(card.foodName), findsOneWidget);
  });
}

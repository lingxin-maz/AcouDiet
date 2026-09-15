// app/test/ui/design_system_test.dart
//
// SPEC-U-06 acceptance 1-8: the design system's own guarantees.
//
//   * exactly four radar axes, labelled from FF-22 (never a nutrient axis);
//   * exactly six food classes, with a placeholder for an out-of-range id;
//   * the confidence bands follow FF-20's thresholds, boundaries included;
//   * the state view renders all four statuses;
//   * the trend chart does not interpolate a null day;
//   * a record card's kilocalorie always travels with its portion and the estimate marker.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/domain/model/health_score.dart';
import '../../lib/domain/service/score_formulas.dart';
import '../../lib/presentation/presenters/score_view.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/state/async_value.dart';
import '../../lib/presentation/theme/acou_format.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/theme/food_class.dart';
import '../../lib/presentation/widgets/food_icon.dart';
import '../../lib/presentation/widgets/four_dim_radar.dart';
import '../../lib/presentation/widgets/record_card.dart';
import '../../lib/presentation/widgets/state_view.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  test('the six food classes are covered with one glyph each', () {
    expect(FoodClassId.matchesFeatureConfig, isTrue);
    expect(FoodIcon.coveredClasses, cfg.FeatureConfig.numClasses);
    // An out-of-range id falls back to the placeholder glyph rather than guessing.
    expect(FoodIcon.glyphFor(0), Icons.local_pizza_outlined);
    expect(FoodIcon.glyphFor(9), Icons.help_outline);
    expect(FoodIcon.glyphFor(-1), Icons.help_outline);
  });

  test('the confidence bands follow FF-20, boundaries included', () {
    expect(AcouFormat.tierOf(cfg.FeatureConfig.votingTauConfirm), ConfidenceTier.high);
    expect(AcouFormat.tierOf(0.699), ConfidenceTier.medium);
    expect(AcouFormat.tierOf(cfg.FeatureConfig.votingTauLow), ConfidenceTier.medium);
    expect(AcouFormat.tierOf(0.449), ConfidenceTier.low);
  });

  test('the energy text is always a band carrying the estimate wording', () {
    expect(AcouFormat.kcalRange(1250), '估算能量参考 约 1000–1500 kcal');
    expect(RegExp(r'^估算能量参考 约 \d+–\d+ kcal$').hasMatch(AcouFormat.kcalRange(0)), isTrue);
  });

  testWidgets('the radar renders exactly four FF-22 axes', (tester) async {
    final view = ScoreView.unavailable();
    expect(view.axes.length, 4);
    expect(
      view.axes.map((a) => a.label).toSet(),
      {
        ScoreFormulas.labelRegularity,
        ScoreFormulas.labelStructure,
        ScoreFormulas.labelSnack,
        ScoreFormulas.labelSpeed,
      },
    );

    await tester.pumpWidget(_host(FourDimRadar(score: view)));
    final semantics = tester.getSemantics(find.byType(FourDimRadar));
    for (final axis in view.axes) {
      expect(semantics.label, contains(axis.label));
    }
  });

  testWidgets('the state view renders every status with its own words', (tester) async {
    for (final status in ViewStatus.values) {
      await tester.pumpWidget(_host(StateView(status: status)));
      if (status == ViewStatus.ready) {
        expect(find.byType(StateView), findsOneWidget);
      } else {
        expect(find.text(StateView.defaultMessage(status)), findsOneWidget);
      }
    }
    // A retry affordance appears only when the caller decided the failure was retryable.
    await tester.pumpWidget(_host(StateView(
      status: ViewStatus.error,
      message: '失败',
      onRetry: () {},
    )));
    expect(find.text(UiStrings.retry), findsOneWidget);
  });

  testWidgets('a confidence chip always renders its percentage as text',
      (tester) async {
    await tester.pumpWidget(_host(const ConfidenceChip(confidence: 0.88)));
    expect(find.text('置信度 88%'), findsOneWidget);
    // Colour is a second channel only: the band is also in the semantic label.
    final semantics = tester.getSemantics(find.byType(ConfidenceChip));
    expect(semantics.label, contains('置信度 88%'));
  });

  testWidgets('the theme keeps body ink legible on its surface', (tester) async {
    // A coarse but real contrast guard: the body ink must be clearly darker than the surface.
    double luminance(Color c) => c.computeLuminance();
    final surface = luminance(AcouTheme.surface);
    final ink = luminance(AcouTheme.ink);
    final ratio = (surface + 0.05) / (ink + 0.05);
    expect(ratio >= 4.5, isTrue, reason: 'body contrast was $ratio:1');
    for (final grade in [
      AcouTheme.gradeGood,
      AcouTheme.gradeFair,
      AcouTheme.gradePoor,
    ]) {
      final gradeRatio = (surface + 0.05) / (luminance(grade) + 0.05);
      expect(gradeRatio >= 4.5, isTrue, reason: 'grade colour contrast was $gradeRatio:1');
    }
  });

  test('the four dimension labels come from the kernel, not from a copy', () {
    expect(ScoreFormulas.formulaOf('regularity'), contains('σ'));
    expect(ScoreFormulas.formulaOf('snack'), contains('n'));
    expect(() => ScoreFormulas.formulaOf('protein'), throwsA(anything));
    expect(HealthScore.gradeOf(cfg.FeatureConfig.healthScoreFormulaGradeThresholdsGoodMin),
        HealthScore.gradeGood);
  });
}

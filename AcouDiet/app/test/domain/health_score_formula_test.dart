// SPEC-A-01 section 7 acceptance table — the four hand-computed worked examples.
//
// Test names are the ones SPEC-A-01 mandates verbatim, so a reviewer can match spec to code
// line by line. The offline equivalent (which runs today, without a resolved package config)
// is `tool/pure_tests.dart` → groups "SPEC-A-01 formulas" and
// "SPEC-A-01 worked example A/B/C/D".

import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/core/time.dart';
import 'package:acoudiet/domain/model/health_score.dart';
import 'package:acoudiet/domain/model/summaries.dart';
import 'package:acoudiet/domain/service/health_score_service.dart';
import 'package:acoudiet/domain/service/score_formulas.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  test('算例A_满分基准', () async {
    final repo = repoOf(workedExampleA());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());

    expect(score.regularity.score, 30);
    expect(score.structure.score, 30);
    expect(score.snack.score, 20);
    expect(score.speed.score, 20);
    expect(score.totalScore, 100);
    expect(score.grade, HealthScore.gradeGood);
    expect(score.regularity.evidence['sigmaMinutes'], 0.0);
    expect(score.snack.evidence['lateNightCount'], 0);
  });

  test('算例B_下午加餐新窗口生效', () async {
    final repo = repoOf(workedExampleB());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());

    // sigma = 20 -> 23.33 -> 23
    expect(score.regularity.evidence['sigmaMinutes'], closeTo(20.0, 1e-9));
    expect(score.regularity.score, 23);
    // p = 2/10 = 0.20 -> 30 * min(1, 0.20/0.4) = 15
    expect(score.structure.evidence['healthyRatio'], closeTo(0.20, 1e-9));
    expect(score.structure.score, 15);
    // ADR-09: 15:40 counts as a snack, NOT as lunch (the old window would give n = 0)
    expect(score.snack.evidence['snackCount'], 6);
    expect(score.snack.score, 8);
    expect(score.speed.score, 15);
    expect(score.totalScore, 61);
    expect(score.grade, HealthScore.gradeFair);
  });

  test('算例C_端点与空delta', () async {
    final repo = repoOf(workedExampleC());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());

    // ADR-05: the formula wins over the prose -> sigma = 30 gives 20, never 30
    expect(score.regularity.evidence['sigmaMinutes'], closeTo(30.0, 1e-9));
    expect(score.regularity.score, 20);
    // p = 2/20 = 0.10 -> 7.5 -> rounds away from zero to 8
    expect(score.structure.score, 8);
    // n = 14 -> max(0, 1 - 1.4) = 0, never negative
    expect(score.snack.score, 0);
    // t = 0.40 hits the zero endpoint
    expect(score.speed.score, 0);
    expect(score.totalScore, 28);
    expect(score.grade, HealthScore.gradePoor);
    // No usable data for the previous day -> null, never 0 (ADR-10)
    expect(score.deltaVsYesterday, isNull);
  });

  test('算例D_不足数据的确定性', () async {
    final repo = repoOf(workedExampleD());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());

    expect(score.regularity.score, 0);
    expect(score.regularity.evidence['sigmaMinutes'], isNull);
    // p = 2/8 = 0.25 -> 18.75 -> 19
    expect(score.structure.score, 19);
    expect(score.snack.score, 10);
    expect(score.speed.score, 0);
    expect(score.totalScore, 29);
    expect(score.speed.evidence['avgChewIntervalSeconds'], isNull);
    expect(score.speed.evidence['sampleCount'], 0);
    expect(score.speed.evidence['missingMetricsCount'], 8);
  });

  test('evidence键集_无多键缺键', () async {
    final score =
        await HealthScoreService(stats: repoOf(workedExampleD())).score(range: weekRange());

    expect(score.regularity.evidence.keys.toSet(),
        {'sigmaMinutes', 'mealTimeSamples', 'windowDays'});
    expect(score.structure.evidence.keys.toSet(),
        {'healthyRatio', 'healthyCount', 'totalCount'});
    expect(score.snack.evidence.keys.toSet(), {'snackCount', 'lateNightCount'});
    expect(score.speed.evidence.keys.toSet(),
        {'avgChewIntervalSeconds', 'missingMetricsCount', 'sampleCount'});
    expect(score.dimensions.map((d) => d.label).toList(),
        ['饮食规律性', '食物结构', '零食控制', '进食速度']);
  });

  test('总分等于四维之和', () async {
    for (final fixture in [workedExampleA(), workedExampleB(), workedExampleC(), workedExampleD()]) {
      final score =
          await HealthScoreService(stats: repoOf(fixture)).score(range: weekRange());
      final sum = score.regularity.score +
          score.structure.score +
          score.snack.score +
          score.speed.score;
      expect(score.totalScore, sum);
    }
  });

  test('ADR15_字面表达式求值_p030得22', () {
    final counts = {for (final l in cfg.FeatureConfig.classLabels) l: 0}..['noodles'] = 3;
    final score = ScoreFormulas.compute(ScoreInputs(
      sigmaMinutes: null,
      mealTimeSamples: 0,
      classCounts: counts,
      recordCount: 10,
      snackCount: 0,
      lateNightCount: 0,
      avgChewIntervalSeconds: null,
      sampleCount: 0,
      missingMetricsCount: 10,
      windowDays: 7,
    ));
    // 30 * min(1, 0.3/0.4) = 22.499999999999996 -> 22. The algebraic rewrite gives 23.
    expect(score.structure.score, 22);
  });

  test('公式串唯一来源', () {
    expect(ScoreFormulas.formulaOf('regularity'), '30 × max(0, 1 − σ/90min)');
    expect(ScoreFormulas.formulaOf('structure'), '30 × min(1, p/0.4)');
    expect(ScoreFormulas.formulaOf('snack'), '20 × max(0, 1 − n/10)');
    expect(ScoreFormulas.formulaOf('speed'), 't ≥ 0.8s → 20；t ≤ 0.4s → 0；中间 20 × (t − 0.4)/0.4');
  });

  test('速度端点不混用', () {
    // The scoring endpoints (0.4 / 0.8) must not be confused with FF-21e's copy thresholds
    // (0.50 / 0.80). They live in different config blocks on purpose.
    expect(cfg.FeatureConfig.healthScoreFormulaSpeedSecondsAtZeroScore, 0.4);
    expect(cfg.FeatureConfig.healthScoreFormulaSpeedSecondsAtFullScore, 0.8);
    expect(cfg.FeatureConfig.behaviorSpeedThresholdsSecondsFast, 0.5);
    expect(cfg.FeatureConfig.behaviorSpeedThresholdsSecondsNormal, 0.8);
  });

  test('范围校验_反序与超31天', () async {
    final repo = repoOf(workedExampleA());
    final service = HealthScoreService(stats: repo);
    expect(() => service.score(range: const DateRange(2000, 1000)), throwsA(anything));
    expect(
      () => service.score(range: DateRange(anchorMs - 40 * 86400000, anchorMs)),
      throwsA(anything),
    );
  });

  test('可复现_同库同窗逐字段相同', () async {
    final repo = repoOf(workedExampleB());
    final a = await HealthScoreService(stats: repo).score(range: weekRange());
    final b = await HealthScoreService(stats: repo).score(range: weekRange());
    expect(b.totalScore, a.totalScore);
    expect(b.regularity.score, a.regularity.score);
    expect(b.speed.score, a.speed.score);
    expect(b.deltaVsYesterday, a.deltaVsYesterday);
  });
}

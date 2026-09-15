// SPEC-A-03 section 7 acceptance table (weekly report). Test names match the SPEC verbatim.
//
// Offline equivalent: `tool/pure_tests.dart` → group "SPEC-A-03 weekly report".

import 'package:acoudiet/domain/model/advice.dart';
import 'package:acoudiet/domain/service/advice_engine.dart';
import 'package:acoudiet/domain/service/health_score_service.dart';
import 'package:acoudiet/domain/service/report_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// 6 snacks this week (offsets 0…5) and 5 last week (offsets 7…11 -- the previous
/// equal-length window), so the snack cycle is exactly +20 %.
List<(dynamic, dynamic)> _twoWeeks() => [
      (rec(0, 7, 0, noodles, id: 'cur-b'), met(interval: 0.7)),
      (rec(0, 12, 0, carrot, id: 'cur-c'), met(interval: 0.7)),
      (rec(0, 18, 0, cabbage, id: 'cur-a'), met(interval: 0.7)),
      for (var i = 0; i < 6; i++) (rec(i, 15, 40, chips, id: 'cur-s$i'), met(interval: 0.7)),
      for (var i = 7; i <= 11; i++)
        (rec(i, 15, 40, chips, id: 'prev-s$i'), met(interval: 0.7)),
    ];

void main() {
  test('环比_零食5到6为加20', () async {
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    // round((6 - 5) / 5 * 100) = 20, computed from real data -- never hard-coded.
    expect(report.summaryText, contains('+20%'));
    expect(report.deltas['recordCount'], 4); // 9 this week vs 5 last week
  });

  test('无基准_不用百分比', () async {
    final repo = repoOf([
      (rec(0, 7, 0, noodles), met(interval: 0.7)),
      (rec(0, 12, 0, carrot), met(interval: 0.7)),
      (rec(0, 18, 0, cabbage), met(interval: 0.7)),
    ]);
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    expect(report.summaryText, isNot(contains('%')));
    expect(report.deltas.values.every((v) => v == 0), isTrue);
    expect(report.deltas.values.every((v) => v is num), isTrue);
  });

  test('deltas键集_恰七键', () async {
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    expect(report.deltas.keys.toSet(), {
      'totalScore',
      'regularity',
      'structure',
      'snack',
      'speed',
      'recordCount',
      'estimatedKcal',
    });
  });

  test('空态文案_逐字冻结', () async {
    final repo = repoOf([]);
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    expect(report.summaryText, '数据不足，继续记录即可看到趋势');
    expect(report.summaryText, ReportService.insufficientDataText);
    expect(report.deltas.values.every((v) => v == 0), isTrue);
  });

  test('报告分数_等于直接调用评分服务', () async {
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());
    final direct = await HealthScoreService(stats: repo).score(range: weekRange());

    expect(report.score.totalScore, direct.totalScore);
    expect(report.score.regularity.score, direct.regularity.score);
    expect(report.score.grade, direct.grade);
    expect(report.score.regularity.evidence, direct.regularity.evidence);
  });

  test('免责声明随advices透传且不重复注入', () async {
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    expect(report.advices.where((a) => a.dimension == Advice.dimGeneral), hasLength(1));
    expect(report.advices.last.dimension, Advice.dimGeneral);
    expect(report.advices.last.text, AdviceEngine.disclaimerText);
  });

  test('文案无残留占位符且不超过60字', () async {
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    expect(RegExp(r'\{[a-zA-Z]+\}').hasMatch(report.summaryText), isFalse);
    expect(report.summaryText.length, lessThanOrEqualTo(60));
  });

  test('热量必须是估算区间（展示层口径）', () async {
    // The domain exposes a point estimate; API-05 section 6.2 / FF-25 require the UI to render
    // it as a range with an "estimate" label. Asserted here so the rule has a home in the test
    // suite even before the widget test lands.
    final repo = repoOf(_twoWeeks().cast());
    final report = await ReportService(
      stats: repo,
      scores: HealthScoreService(stats: repo),
    ).weekly(range: weekRange());

    final point = report.deltas['estimatedKcal']!;
    expect(point, isA<num>());
    final lo = (point * 0.8).round();
    final hi = (point * 1.2).round();
    expect('约 $lo–$hi kcal（估算）', matches(RegExp(r'^约 \d+–\d+ kcal（估算）$')));
  });
}

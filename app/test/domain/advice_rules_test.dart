// SPEC-A-02 section 7 acceptance table. Test names match the SPEC verbatim.
//
// Offline equivalent (runs today): `tool/pure_tests.dart` → group "SPEC-A-02 advice rules".

import 'package:acoudiet/domain/model/advice.dart';
import 'package:acoudiet/domain/model/diet_record.dart';
import 'package:acoudiet/domain/service/advice_engine.dart';
import 'package:acoudiet/domain/service/health_score_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// A fixture that trips rules 1 (snacks), 2 (late night) and 3 (fast chewing).
List<(DietRecord, BehaviorMetrics?)> _busyWeek() => [
      (rec(1, 7, 0, noodles), met(interval: 0.42)),
      (rec(2, 7, 0, noodles), met(interval: 0.42)),
      (rec(3, 7, 0, chips), met(interval: 0.42)),
      for (var i = 1; i <= 6; i++) (rec(i, 15, 40, chips), met(interval: 0.42)),
      for (var i = 1; i <= 3; i++) (rec(i, 21, 30, chips), met(interval: 0.42)),
    ];

void main() {
  late AdviceEngine engine;

  setUp(() => engine = const AdviceEngine());

  test('规则1_零食', () async {
    final repo = repoOf(_busyWeek());
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final advices = await engine.generate(score: score, agg: agg);

    final rule = advices.firstWhere((a) => a.dimension == Advice.dimSnack);
    expect(rule.priority, AdviceEngine.priorityHigh);
    expect(rule.text, contains('本周零食 ${agg.snackCount} 次'));
    expect(rule.text, contains('建议减少薯片与软糖的频率'));
  });

  test('规则2_晚间进食', () async {
    final repo = repoOf(_busyWeek());
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final advices = await engine.generate(score: score, agg: agg);

    final rule = advices.firstWhere(
        (a) => a.dimension == Advice.dimRegularity && a.text.contains('晚间'));
    expect(rule.text, contains('有 ${agg.lateNightCount} 次进食发生在晚间'));
    expect(rule.text, contains('安排得更早'));
  });

  test('规则3_进食速度', () async {
    final repo = repoOf(_busyWeek());
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final advices = await engine.generate(score: score, agg: agg);

    final rule = advices.firstWhere((a) => a.dimension == Advice.dimSpeed);
    expect(rule.text, contains('偏快'));
    expect(rule.text, contains('放慢进食节奏'));
    // One decimal place, from the real evidence value.
    expect(rule.text, matches(RegExp(r'约 \d\.\d 秒')));
  });

  test('规则4_饮食规律性', () async {
    // Exactly one record in each meal window -> no accepted meal class -> sigma is null, so
    // rule 4 cannot fire (SPEC-A-02 section 2.4 #4: skip, never substitute a zero).
    // recordCount is 3, i.e. at or above A-02-K4, so the engine does evaluate the rules.
    final repo = repoOf([
      (rec(1, 7, 0, noodles), met(interval: 0.7)),
      (rec(2, 12, 0, carrot), met(interval: 0.7)),
      (rec(3, 18, 0, chips), met(interval: 0.7)),
    ]);
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    expect(score.regularity.evidence['sigmaMinutes'], isNull);
    expect(agg.recordCount, greaterThanOrEqualTo(AdviceEngine.minimumRecords));

    final advices = await engine.generate(score: score, agg: agg);
    expect(advices.any((a) => a.text.contains('三餐时间不够固定')), isFalse);
  });

  test('规则5_多样性', () async {
    // Only two distinct classes -> k = 2 <= A-02-K10
    final repo = repoOf([
      (rec(1, 7, 0, noodles), met(interval: 0.9)),
      (rec(2, 7, 0, noodles), met(interval: 0.9)),
      (rec(3, 12, 0, noodles), met(interval: 0.9)),
    ]);
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final advices = await engine.generate(score: score, agg: agg);

    final rule = advices.firstWhere((a) => a.dimension == Advice.dimStructure);
    expect(rule.text, contains('只有 1 类'));
    expect(rule.priority, AdviceEngine.priorityLow);
  });

  test('免责声明项_唯一且最后', () async {
    final repo = repoOf(_busyWeek());
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final advices = await engine.generate(score: score, agg: agg);

    final general = advices.where((a) => a.dimension == Advice.dimGeneral).toList();
    expect(general, hasLength(1));
    expect(advices.last.dimension, Advice.dimGeneral);
    final maxOther = advices
        .where((a) => a.dimension != Advice.dimGeneral)
        .fold<int>(0, (m, a) => a.priority > m ? a.priority : m);
    expect(general.single.priority, greaterThan(maxOther));
  });

  test('免责声明_逐字相等', () async {
    final advices = await engine.generate(
      score: await HealthScoreService(stats: repoOf(workedExampleA()))
          .score(range: weekRange()),
      agg: await repoOf(workedExampleA()).summary(weekRange()),
    );
    expect(
      advices.firstWhere((a) => a.dimension == Advice.dimGeneral).text,
      '提供日常健康管理建议，不进行疾病诊断，不替代专业医疗意见',
    );
  });

  test('文案红线_禁用词命中为零', () async {
    final repo = repoOf(_busyWeek());
    final advices = await engine.generate(
      score: await HealthScoreService(stats: repo).score(range: weekRange()),
      agg: await repo.summary(weekRange()),
    );
    const banned = ['准确识别', '零操作', '完全无感', '测热量', '可以测', '营养成分'];
    for (final a in advices) {
      for (final word in banned) {
        expect(a.text, isNot(contains(word)));
      }
      expect(a.text, isNot(matches(RegExp(r'\d+\s*kcal'))));
      expect(a.text.length, lessThanOrEqualTo(AdviceEngine.maxTextLength));
      expect(a.text, isNot(matches(RegExp(r'\{[a-zA-Z]+\}'))));
    }
  });

  test('排序稳定_100次相同', () async {
    final repo = repoOf(_busyWeek());
    final agg = await repo.summary(weekRange());
    final score = await HealthScoreService(stats: repo).score(range: weekRange());
    final first = (await engine.generate(score: score, agg: agg))
        .map((a) => '${a.dimension}|${a.priority}|${a.text}')
        .join(';');
    for (var i = 0; i < 100; i++) {
      final again = (await engine.generate(score: score, agg: agg))
          .map((a) => '${a.dimension}|${a.priority}|${a.text}')
          .join(';');
      expect(again, first);
    }
  });

  test('数据不足_仅免责声明项', () async {
    final repo = repoOf([
      (rec(1, 7, 0, noodles), met(interval: 0.7)),
      (rec(2, 7, 0, noodles), met(interval: 0.7)),
    ]);
    final advices = await engine.generate(
      score: await HealthScoreService(stats: repo).score(range: weekRange()),
      agg: await repo.summary(weekRange()),
    );
    expect(advices, hasLength(1));
    expect(advices.single.dimension, Advice.dimGeneral);
  });

  test('null字段_跳过规则', () async {
    final repo = repoOf([
      (rec(1, 7, 0, noodles), met(interval: 0.7)),
      (rec(2, 12, 0, carrot), met(interval: 0.7)),
      (rec(3, 18, 0, chips), met(interval: 0.7)),
    ]);
    final advices = await engine.generate(
      score: await HealthScoreService(stats: repo).score(range: weekRange()),
      agg: await repo.summary(weekRange()),
    );
    expect(advices.any((a) => a.text.contains('三餐时间不够固定')), isFalse);
    expect(advices.any((a) => a.text.contains('null')), isFalse);
  });
}

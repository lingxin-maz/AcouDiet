// API-03 section 10 (data-layer unit tests) — the assertions that need no SQLite engine.
//
// The engine-dependent half (real transactions, schema scanning, aggregation SQL) lives in
// `tool/data_tests.dart`, which runs against a real SQLite library; see
// `records/compliance/C-05_regression_checklist.md` §3 for the mapping.

import 'package:acoudiet/core/errors.dart';
import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/core/time.dart';
import 'package:acoudiet/data/fake_repo.dart';
import 'package:acoudiet/domain/model/diet_record.dart';
import 'package:acoudiet/domain/model/summaries.dart';
import 'package:acoudiet/domain/repository/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

class _KcalStub implements KcalResolver {
  @override
  int kcalFor(int classId) {
    if (classId < 0 || classId >= cfg.FeatureConfig.numClasses) {
      throw Errors.kb('classId out of range: $classId');
    }
    return 100 + classId;
  }

  /// `implements` does not inherit the contract's default body (ADR-23 added the method).
  @override
  int kcalForDuration(int classId, int durationSeconds) => kcalFor(classId);
}

void main() {
  test('toMap与fromMap双向往返_含占位指标行', () {
    final record = rec(0, 8, 0, noodles, id: 'r1');
    final roundTrip = DietRecord.fromMap(record.toMap());
    expect(roundTrip.recordId, record.recordId);
    expect(roundTrip.eatenAtMs, record.eatenAtMs);
    expect(roundTrip.endedAtMs, record.endedAtMs);
    expect(roundTrip.classLabel, record.classLabel);
    expect(roundTrip.classId, record.classId);
    expect(roundTrip.attribute, record.attribute);
    expect(roundTrip.confidence, record.confidence);
    expect(roundTrip.durationSeconds, record.durationSeconds);
    expect(roundTrip.source, record.source);
    expect(roundTrip.correctedByUser, record.correctedByUser);
    expect(roundTrip.confirmedByUser, record.confirmedByUser);

    // The placeholder metrics row round-trips as all-null (not as a missing row).
    const placeholder = BehaviorMetrics.placeholder;
    final metricsRoundTrip = BehaviorMetrics.fromMap(placeholder.toMap('r1'));
    expect(metricsRoundTrip.isPlaceholder, isTrue);
    expect(metricsRoundTrip.chewCount, isNull);
    expect(metricsRoundTrip.avgChewIntervalSeconds, isNull);
    expect(metricsRoundTrip.durationSeconds, isNull);
    expect(metricsRoundTrip.speedGrade, isNull);
  });

  test('占位指标行列名与契约一致', () {
    expect(BehaviorMetrics.placeholder.toMap('r1').keys.toSet(), {
      'record_id',
      'chew_count',
      'avg_chew_interval_seconds',
      'duration_seconds',
      'speed_grade',
    });
  });

  test('I1_无指标时仍写占位行', () async {
    final repo = FakeRepo(baseDayMs: anchorMs);
    await repo.insertSession(record: rec(0, 8, 0, noodles, id: 'x1'), metrics: null);
    final stored = await repo.metricsByRecordId('x1');
    expect(stored, isNotNull, reason: 'a record without metrics must still own a row');
    expect(stored!.isPlaceholder, isTrue);
    expect(await repo.metricsByRecordId('missing'), isNull);
  });

  test('唯一约束_重复recordId抛ACD_DB_002', () async {
    final repo = FakeRepo(baseDayMs: anchorMs);
    final r = rec(0, 8, 0, noodles, id: 'dup');
    await repo.insertSession(record: r, metrics: null);
    await expectLater(
      repo.insertSession(record: r, metrics: null),
      throwsA(isA<AcouDietError>()
          .having((e) => e.code, 'code', Codes.dbUniqueConstraint)),
    );
  });

  test('入参非法_抛ACD_DB_004', () async {
    final repo = FakeRepo(baseDayMs: anchorMs);
    await expectLater(
      repo.insertSession(
        record: DietRecord(
          recordId: 'bad',
          eatenAtMs: 500,
          endedAtMs: 100,
          classLabel: 'noodles',
          classId: 3,
          attribute: 'x',
          confidence: 2.0,
          durationSeconds: 1,
          source: 'real',
        ),
        metrics: null,
      ),
      throwsA(isA<AcouDietError>()
          .having((e) => e.code, 'code', Codes.dbInvalidArgument)),
    );
  });

  test('区间语义_左闭右开', () async {
    final repo = FakeRepo(baseDayMs: anchorMs);
    final r = rec(0, 8, 0, noodles, id: 'r1');
    await repo.insertSession(record: r, metrics: null);
    expect((await repo.byRange(DateRange(r.eatenAtMs, r.endedAtMs))).length, 1);
    expect((await repo.byRange(DateRange(0, r.eatenAtMs))).length, 0);
  });

  test('行序_按eatenAtMs升序', () async {
    final repo = FakeRepo(baseDayMs: anchorMs);
    await repo.insertSession(record: rec(0, 12, 0, carrot, id: 'b'), metrics: null);
    await repo.insertSession(record: rec(0, 8, 0, noodles, id: 'a'), metrics: null);
    final rows = await repo.byRange(DateRange(0, 1 << 62));
    expect(rows.map((r) => r.recordId).toList(), ['a', 'b']);
  });

  test('键集完整_classCounts六键与byHour二十四键', () async {
    final repo = repoOf([(rec(0, 8, 0, noodles), met(interval: 0.7))]);
    final summary = await repo.summary(weekRange());
    expect(summary.classCounts.keys.toSet(), cfg.FeatureConfig.classLabels.toSet());
    final meals = await repo.mealTimes(7);
    expect(meals.byHour.keys.toSet(), {for (var h = 0; h < 24; h++) h});
  });

  test('week等价于summary最近七个本地日历日', () async {
    final repo = FakeRepo.demoFixture();
    final week = await repo.week();
    final (start, end) = TimeUtil.lastLocalDays(7,
        nowMsOverride: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch);
    final direct = await repo.summary(DateRange(start, end));
    expect(week.recordCount, direct.recordCount);
    expect(week.snackCount, direct.snackCount);
    expect(week.estimatedKcal, direct.estimatedKcal);
    expect(week.classCounts, direct.classCounts);
    expect(week.mealTimeStdDevMinutes, direct.mealTimeStdDevMinutes);
  });

  test('KcalResolver_未注册classId抛ACD_KB_001', () {
    expect(() => _KcalStub().kcalFor(9), throwsA(isA<AcouDietError>()));
    expect(_KcalStub().kcalFor(0), 100);
  });

  test('FakeRepo永不实现MaintenanceRepo', () {
    // Guard rail: the placeholder repository must not offer a fake "clear everything" action.
    final repo = FakeRepo.demoFixture();
    expect(repo, isNot(isA<MaintenanceRepo>()));
  });

  test('演示夹具_确定性与自洽', () async {
    final a = FakeRepo.demoFixture();
    final b = FakeRepo.demoFixture();
    final sa = await a.summary(weekRange());
    final sb = await b.summary(weekRange());
    expect(sa.recordCount, sb.recordCount);
    expect(sa.estimatedKcal, sb.estimatedKcal);
    final today = await a.today();
    expect(today.records.every((r) => r.isDemo), isTrue);
    expect(today.recordCount, today.records.length);
  });

  test('演示数据集资产_每条记录自洽且带1对1指标块', () async {
    final entries = demoDataset();
    expect(entries, hasLength(28));
    for (final (record, _) in entries) {
      expect(record.validate(), isEmpty, reason: 'record ${record.recordId}');
      expect(record.source, 'demo');
    }
  });
}

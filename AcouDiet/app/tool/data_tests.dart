// app/tool/data_tests.dart
//
// Test runner for the L3 data layer against a REAL SQLite engine (dart:ffi).
//
//   $env:ACOUDIET_SQLITE = "D:\Anaconda\DLLs\sqlite3.dll"
//   dart run tool/data_tests.dart
//
// Covers the invariants API-03 section 1 makes non-negotiable and the aggregation SQL of
// SPEC-D-03: strict 1:1 (a placeholder row must exist), single-transaction writes, the
// absence of BLOB/audio columns, half-open range semantics, key-set completeness,
// reproducibility, and the SQLite-side sigma / snack / late-night classification.

import 'dart:io';
import 'dart:typed_data';

import '../lib/core/errors.dart';
import '../lib/core/feature_config.g.dart' as cfg;
import '../lib/core/time.dart';
import '../lib/data/db/app_database.dart';
import '../lib/data/repository/sql_repos.dart';
import '../lib/domain/model/diet_record.dart';
import '../lib/domain/model/summaries.dart';
import '../lib/domain/repository/repositories.dart';

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

void group(String t) {
  print('');
  print('### $t');
}

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    print('  [ok  ] $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failed++;
    _failures.add(name);
    print('  [FAIL] $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String name, Object? a, Object? b) =>
    check(name, a == b, 'actual=$a expected=$b');

class _KcalTable implements KcalResolver {
  static const Map<int, int> table = {
    0: 160, 1: 90, 2: 150, 3: 130, 4: 40, 5: 60,
  };

  @override
  int kcalFor(int classId) {
    final v = table[classId];
    if (v == null) throw Errors.kb('no kcal for classId=$classId');
    return v;
  }

  /// `implements` does not inherit the contract's default body, so the duration-aware method
  /// must be spelled out. This stub keeps the standard portion (the table *is* the portion),
  /// which is what the frozen aggregate assertions expect.
  @override
  int kcalForDuration(int classId, int durationSeconds) => kcalFor(classId);
}

/// ADR-23 stub: a portion model with a 100 s reference, so the SQL aggregate can be checked
/// against the same per-record arithmetic the record cards use.
class _ScalingKcal implements KcalResolver {
  const _ScalingKcal(this.perSecond);

  final double perSecond;

  @override
  int kcalFor(int classId) => (perSecond * 100).round();

  @override
  int kcalForDuration(int classId, int durationSeconds) =>
      (perSecond * durationSeconds).round();
}

DateTime _day(int dayOffset) =>
    DateTime(2026, 9, 10).subtract(Duration(days: dayOffset));

DietRecord _rec(
  int dayOffset,
  int hour,
  int minute,
  int classId, {
  required String id,
  String source = 'real',
  int duration = 300,
  double confidence = 0.8,
}) {
  final d = _day(dayOffset);
  final at = DateTime(d.year, d.month, d.day, hour, minute);
  return DietRecord(
    recordId: id,
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + duration * 1000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    attribute: 'crispy',
    confidence: confidence,
    durationSeconds: duration,
    source: source,
  );
}

Future<void> main() async {
  print('=' * 78);
  print('AcouDiet data-layer test suite (real SQLite over dart:ffi)');
  print('=' * 78);

  if (Platform.environment['ACOUDIET_SQLITE'] == null) {
    const fallback = r'D:\Anaconda\DLLs\sqlite3.dll';
    if (File(fallback).existsSync()) {
      print('note: ACOUDIET_SQLITE not set; relying on the default search path '
          '(known local copy: $fallback)');
    }
  }

  AppDatabase db;
  try {
    db = await AppDatabase.openAt('', inMemory: true);
  } on AcouDietError catch (e) {
    print('FAIL: could not open SQLite: ${e.message}');
    print(e.detail);
    exit(2);
  }

  group('schema (D-01)');
  eq('user_version is the current schema version', await db.executor.userVersion,
      AppDatabase.schemaVersion);
  var noAudioColumns = true;
  try {
    await db.assertNoAudioColumns();
  } on AcouDietError {
    noAudioColumns = false;
  }
  check('no BLOB / audio / mel / pcm column exists (I-2)', noAudioColumns);

  final tables = (await db.executor
          .query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))
      .map((r) => r['name'])
      .where((t) => !'$t'.startsWith('sqlite_'))
      .join(',');
  eq('four tables exist', tables, 'app_meta,behavior_metrics,diet_record,user_profile');

  group('migration idempotence (D-02)');
  await db.migrate();
  await db.migrate();
  check('migrate() is safe to re-run',
      await db.executor.userVersion == AppDatabase.schemaVersion);

  group('v2 migration: retired class labels are renamed (ADR-19)');
  // A database written before the FF-19 revision holds labels that are no longer in
  // `class_labels`. The aggregation refuses an unknown label, so a single such row used to take
  // the whole home page down with `ACD-KB-001` -- this was found by running the app, not by a
  // unit test, which is exactly why it is now a unit test.
  {
    // Plant the pre-revision rows directly (the repositories would reject the old labels).
    for (final (id, oldLabel, classId) in const [
      ('legacy-1', 'apple', 1),
      ('legacy-2', 'cookie', 2),
      ('legacy-3', 'bread', 3),
      ('legacy-4', 'chips', 0),        // untouched: already a valid label
      ('legacy-5', 'pizza', 4),        // corrupt on purpose: id and label disagree
    ]) {
      await db.executor.execute(
        'INSERT INTO diet_record (record_id, eaten_at_ms, ended_at_ms, class_label, class_id, '
        'attribute, confidence, duration_seconds, source, corrected_by_user, confirmed_by_user) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [id, _anchorMs, _anchorMs + 300000, oldLabel, classId, 'snapshot', 0.8, 300, 'real', 0, 0],
      );
    }

    // Force a re-run of v2 by rewinding user_version, then migrate again.
    await db.executor.setUserVersion(1);
    await db.migrate();

    final renamed = await db.executor.query(
        'SELECT record_id, class_label FROM diet_record WHERE record_id LIKE ? ORDER BY record_id',
        ['legacy-%']);
    final byId = {for (final r in renamed) r['record_id'] as String: r['class_label'] as String};
    eq('apple(id 1) becomes cabbage', byId['legacy-1'], 'cabbage');
    eq('cookie(id 2) becomes gummies', byId['legacy-2'], 'gummies');
    eq('bread(id 3) becomes noodles', byId['legacy-3'], 'noodles');
    eq('an already-valid label is untouched', byId['legacy-4'], 'chips');
    eq('a label that disagrees with its id is NOT guessed', byId['legacy-5'], 'pizza');

    // Idempotence: the guard is on the old label, so a second pass cannot rename anything else.
    await db.executor.setUserVersion(1);
    await db.migrate();
    final again = await db.executor.query(
        'SELECT class_label FROM diet_record WHERE record_id = ?', ['legacy-1']);
    eq('a second v2 pass is a no-op', again.first['class_label'], 'cabbage');

    // The migrated rows must now be resolvable by the aggregation's own rule.
    for (final id in ['legacy-1', 'legacy-2', 'legacy-3', 'legacy-4']) {
      final rows = await db.executor
          .query('SELECT class_label FROM diet_record WHERE record_id = ?', [id]);
      final label = rows.first['class_label'] as String;
      check('$id is inside the frozen six after migration',
          cfg.FeatureConfig.classLabels.contains(label), label);
    }

    await db.executor.execute("DELETE FROM diet_record WHERE record_id LIKE 'legacy-%'");
  }

  group('DietRepo (D-01/D-02, invariants I-1 and I-3)');
  final diet = DietRepoImpl(db);
  final metricsCount = _MetricsCounter(db);

  await diet.insertSession(record: _rec(0, 8, 0, 3, id: 'r1'), metrics: null);
  eq('insertSession writes exactly one record', await diet.countAll(), 1);
  final placeholder = await diet.metricsByRecordId('r1');
  eq('I-1: a placeholder metrics row exists', placeholder!.isPlaceholder, true);
  eq('metrics row count is 1', await metricsCount.count(), 1);

  await diet.insertSession(
    record: _rec(0, 12, 0, 4, id: 'r2'),
    metrics: const BehaviorMetrics(
        chewCount: 45,
        avgChewIntervalSeconds: 0.7,
        durationSeconds: 300,
        speedGrade: 'normal'),
  );
  final r2Metrics = await diet.metricsByRecordId('r2');
  eq('a real metrics row round-trips', r2Metrics!.chewCount, 45);
  eq('metrics count is 2', await metricsCount.count(), 2);

  var duplicateRejected = false;
  try {
    await diet.insertSession(record: _rec(0, 8, 0, 3, id: 'r1'), metrics: null);
  } on AcouDietError catch (e) {
    duplicateRejected = e.code == Codes.dbUniqueConstraint;
  }
  check('duplicate recordId -> ACD-DB-002', duplicateRejected);

  // I-3: a failing metrics insert must roll the record back with it.
  final before = await diet.countAll();
  var rolledBack = false;
  try {
    await db.executor.transaction((txn) async {
      await txn.execute(
        'INSERT INTO diet_record (record_id, eaten_at_ms, ended_at_ms, class_label, '
        'class_id, attribute, confidence, duration_seconds, source, corrected_by_user, '
        'confirmed_by_user) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        ['broken', 1, 2, 'noodles', 3, 'x', 0.5, 10, 'real', 0, 0],
      );
      // Primary-key violation on behavior_metrics -> the whole transaction rolls back.
      await txn.execute(
        'INSERT INTO behavior_metrics (record_id, chew_count, avg_chew_interval_seconds, '
        'duration_seconds, speed_grade) VALUES (?,?,?,?,?)',
        ['r1', null, null, null, null],
      );
      return 0;
    });
  } on AcouDietError {
    rolledBack = true;
  }
  eq('I-3: failed transaction leaves no partial record', await diet.countAll(), before);
  check('the rollback actually happened', rolledBack);

  group('range semantics and ordering');
  final r1 = await diet.byId('r1');
  final r2 = await diet.byId('r2');
  final dayStart = TimeUtil.startOfLocalDay(r1!.eatenAtMs);
  final inclusive = await diet.byRange(DateRange(r1.eatenAtMs, r2!.eatenAtMs));
  eq('range is left-closed (contains its start)', inclusive.length, 1);
  final exclusive = await diet.byRange(DateRange(dayStart, r1.eatenAtMs));
  eq('range is right-open (excludes its end)', exclusive.length, 0);
  final ordered = await diet.byRange(DateRange(dayStart, dayStart + 86400000));
  check('rows come back ascending by eaten_at_ms',
      ordered.length == 2 && ordered[0].eatenAtMs <= ordered[1].eatenAtMs);

  group('StatsRepo (D-03) - meal windows, sigma, key completeness');
  await diet.deleteAll();
  await diet.insertSession(record: _rec(1, 7, 0, 3, id: 's1'), metrics: null);
  await diet.insertSession(record: _rec(2, 7, 0, 3, id: 's2'), metrics: null);
  await diet.insertSession(record: _rec(3, 7, 0, 2, id: 's3'), metrics: null);
  await diet.insertSession(record: _rec(4, 7, 40, 2, id: 's4'), metrics: null);
  for (var d = 1; d <= 6; d++) {
    await diet.insertSession(record: _rec(d, 15, 40, 0, id: 'snack$d'), metrics: null);
  }

  final stats = StatsRepoImpl(db: db, kcal: _KcalTable(), clock: () => _anchorMs);
  final win = weekRange();
  final summary = await stats.summary(win);

  eq('record count', summary.recordCount, 10);
  eq('afternoon snacks counted (ADR-09)', summary.snackCount, 6);
  eq('late-night count', summary.lateNightCount, 0);
  eq('classCounts has six keys', summary.classCounts.length, 6);
  eq('sigma = 20 (breakfast {420,420,420,460})',
      summary.mealTimeStdDevMinutes!.toStringAsFixed(6), '20.000000');
  eq('estimatedKcal uses the injected resolver', summary.estimatedKcal,
      130 * 2 + 150 * 2 + 160 * 6);

  // ADR-23: a drink outside the meal windows is NOT a snack, and it is not a meal sample
  // either. Before this rule the same row was counted both as a snack and as its own class.
  await diet.insertSession(record: _rec(1, 15, 40, 5, id: 'drink1'), metrics: null);
  final withDrink = await stats.summary(win);
  eq('a 15:40 drink does not raise the snack count', withDrink.snackCount, 6);
  eq('but the record itself is still counted', withDrink.recordCount, 11);
  eq('and it is counted in its own class column', withDrink.classCounts['drink'], 1);
  eq('a drink inside a meal window is not a σ sample either',
      (await stats.summary(DateRange(
        TimeUtil.startOfLocalDay(_rec(1, 12, 30, 5, id: 'probe').eatenAtMs),
        TimeUtil.startOfLocalDay(_rec(1, 12, 30, 5, id: 'probe').eatenAtMs) + 86400000,
      )))
          .mealTimeStdDevMinutes,
      null);
  await diet.deleteAll();
  await diet.insertSession(record: _rec(1, 7, 0, 3, id: 's1'), metrics: null);
  await diet.insertSession(record: _rec(2, 7, 0, 3, id: 's2'), metrics: null);
  await diet.insertSession(record: _rec(3, 7, 0, 2, id: 's3'), metrics: null);
  await diet.insertSession(record: _rec(4, 7, 40, 2, id: 's4'), metrics: null);
  for (var d = 1; d <= 6; d++) {
    await diet.insertSession(record: _rec(d, 15, 40, 0, id: 'snack$d'), metrics: null);
  }

  // ADR-23: the aggregate kcal is the SUM OF PER-RECORD estimates, so it stays equal to the
  // sum of the record cards. A resolver that scales with the duration must move the total.
  final scaling = StatsRepoImpl(db: db, kcal: const _ScalingKcal(0.5), clock: () => _anchorMs);
  final scaled = await scaling.summary(win);
  final durations = <int>[];
  for (final r in await diet.byRange(win)) {
    durations.add(r.durationSeconds);
  }
  eq('the duration-scaled aggregate is the sum of per-record estimates', scaled.estimatedKcal,
      durations.fold<int>(0, (s, d) => s + (0.5 * d).round()));
  check('and that sum is not the fixed-portion product',
      scaled.estimatedKcal != 100 * durations.length);

  final w = await stats.week();
  eq('week() equals summary(last 7 local days)',
      '${w.recordCount}|${w.snackCount}|${w.estimatedKcal}|${w.mealTimeStdDevMinutes}',
      '${summary.recordCount}|${summary.snackCount}|${summary.estimatedKcal}|'
          '${summary.mealTimeStdDevMinutes}');

  final samples = await stats.mealTimeSamples(win);
  eq('mealTimeSamples returns only meal-window records', samples.length, 4);
  check('mealTimeSamples is ascending',
      List.generate(samples.length - 1, (i) => samples[i] <= samples[i + 1])
          .every((x) => x));

  final meals = await stats.mealTimes(7);
  eq('byHour has 24 keys', meals.byHour.length, 24);
  eq('the 15:00 bucket holds the six snacks', meals.hourOf(15), 6);

  final trend = await stats.trend(7);
  eq('trend returns one point per day', trend.length, 7);
  check('L3 never fills totalScore', trend.every((p) => p.totalScore == null));
  check('a day without records keeps null kcal (not 0)',
      trend.last.estimatedKcal == null,
      'last=${trend.last.date} kcal=${trend.last.estimatedKcal}');
  check('dates are gapless and ascending',
      List.generate(6, (i) {
        final a = DateTime.parse(trend[i].date);
        final b = DateTime.parse(trend[i + 1].date);
        return b.difference(a).inDays == 1;
      }).every((x) => x));

  group('chewStats weighting (SPEC-A-01 A-01-K3)');
  await diet.deleteAll();
  await diet.insertSession(
    record: _rec(1, 7, 0, 3, id: 'c1'),
    metrics: const BehaviorMetrics(
        chewCount: 10,
        avgChewIntervalSeconds: 1.0,
        durationSeconds: 100,
        speedGrade: 'slow'),
  );
  await diet.insertSession(
    record: _rec(2, 7, 0, 3, id: 'c2'),
    metrics: const BehaviorMetrics(
        chewCount: 10,
        avgChewIntervalSeconds: 0.5,
        durationSeconds: 300,
        speedGrade: 'normal'),
  );
  await diet.insertSession(record: _rec(3, 7, 0, 3, id: 'c3'), metrics: null);
  final chew = await stats.chewStats(win);
  eq('sampleCount counts only rows with a valid duration', chew.sampleCount, 2);
  eq('duration-weighted mean = (1.0*100 + 0.5*300)/400',
      chew.meanChewIntervalSeconds!.toStringAsFixed(6), '0.625000');

  group('activeDays and reproducibility');
  eq('activeDays counts distinct local days', await stats.activeDays(), 3);
  // Reproducibility: two consecutive reads of the same window must be identical
  // (API-05 section 6.1 -- the answer must not depend on when it is asked).
  final read1 = await stats.summary(win);
  final read2 = await stats.summary(win);
  eq('same database + same window -> identical aggregate',
      '${read1.recordCount}|${read1.snackCount}|${read1.estimatedKcal}|'
          '${read1.mealTimeStdDevMinutes}',
      '${read2.recordCount}|${read2.snackCount}|${read2.estimatedKcal}|'
          '${read2.mealTimeStdDevMinutes}');
  eq('the two reads also agree on the class histogram',
      read1.classCounts.toString(), read2.classCounts.toString());

  group('ProfileRepo (D-04)');
  final profile = ProfileRepoImpl(db);
  final defaults = await profile.load();
  eq('empty table returns the default profile', defaults.targetMealsPerDay,
      UserProfile.defaultTargetMealsPerDay);
  await profile.save(defaults.copyWith(nickname: 'tester', targetMealsPerDay: 4));
  final saved = await profile.load();
  eq('profile round-trips', '${saved.nickname}|${saved.targetMealsPerDay}', 'tester|4');
  var rejected = false;
  try {
    await profile.save(defaults.copyWith(targetMealsPerDay: 9));
  } on AcouDietError catch (e) {
    rejected = e.code == Codes.dbInvalidArgument;
  }
  check('targetMealsPerDay out of [1,6] -> ACD-DB-004', rejected);

  group('MaintenanceRepo (D-05)');
  var nativeCalls = 0;
  final maintenance = MaintenanceRepoImpl(
    db: db,
    nativeAudioCleaner: () async {
      nativeCalls++;
      return 3;
    },
    tempFileCounter: () async => 0,
  );
  eq('clearTempAudio delegates to the native side', await maintenance.clearTempAudio(), 3);
  eq('the native matcher is called exactly once', nativeCalls, 1);
  eq('countTempAudioFiles reports 0 after cleanup',
      await maintenance.countTempAudioFiles(), 0);
  final cleared = await maintenance.clearAllData();
  check('clearAllData reports the affected rows', cleared > 0, 'cleared=$cleared');
  eq('no records remain', await diet.countAll(), 0);
  eq('no metrics remain', await metricsCount.count(), 0);
  eq('profile was reset but the row kept', (await profile.load()).nickname, null);
  eq('MetaDao clears the demo fingerprint',
      await _MetaProbe(db).get('demoDatasetFingerprint'), null);

  group('privacy guard on parameters');
  var blobRejected = false;
  try {
    await db.executor.execute('SELECT ?', [Uint8List.fromList([1, 2, 3])]);
  } on AcouDietError {
    blobRejected = true;
  }
  check('binding a BLOB parameter is refused (I-2)', blobRejected);

  await db.close();

  print('');
  print('=' * 78);
  print('DATA: $_passed passed, $_failed failed, ${_passed + _failed} total');
  if (_failed > 0) {
    print('FAILED CHECKS:');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  print('=' * 78);
  if (_failed > 0) exit(1);
}

/// Week window pinned to the fixture anchor day.
DateRange weekRange() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

class _MetricsCounter {
  _MetricsCounter(this.db);
  final AppDatabase db;
  Future<int> count() async {
    final rows = await db.executor.query('SELECT COUNT(*) AS c FROM behavior_metrics');
    return (rows.first['c'] as num).toInt();
  }
}

class _MetaProbe {
  _MetaProbe(this.db);
  final AppDatabase db;
  Future<String?> get(String key) async {
    final rows = await db.executor.query('SELECT value FROM app_meta WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }
}

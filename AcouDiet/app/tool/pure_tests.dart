// app/tool/pure_tests.dart
//
// Dependency-free test runner for the pure-Dart layers (core / domain / data-logic).
//
//   dart run tool/pure_tests.dart
//
// Why it exists: this environment has no network, so `flutter pub get` (and therefore
// `flutter test`) cannot resolve sqflite / Riverpod / fl_chart. Everything that carries
// logic -- the scoring kernel, the vote aggregator, the behaviour analyzer, the advice
// rules, the report text, the meal windows -- is deliberately pure Dart with no package
// imports, so it compiles and runs against the Dart SDK alone.
//
// The official suite mandated by PLAN-C-05 lives in `app/test/**` and runs under
// `flutter test` once the dependencies resolve; this runner covers every assertion that
// does not need a Flutter binding, including the four hand-computed worked examples of
// SPEC-A-01 table A-01-T3.
//
// Imports are relative on purpose: a package: import would require a resolved package
// config, which is exactly what is unavailable offline.

import 'dart:typed_data';

import '../lib/core/errors.dart';
import '../lib/core/feature_config.g.dart' as cfg;
import '../lib/core/time.dart';
import '../lib/data/fake_repo.dart';
import '../lib/domain/model/advice.dart';
import '../lib/domain/model/diet_record.dart';
import '../lib/domain/model/demo.dart';
import '../lib/domain/model/inference.dart';
import '../lib/domain/service/handshake.dart';
import '../lib/domain/service/inference_engine.dart';
import '../lib/domain/model/summaries.dart';
import '../lib/domain/service/advice_engine.dart';
import '../lib/domain/service/behavior_analyzer.dart';
import '../lib/domain/service/health_score_service.dart';
import '../lib/domain/service/report_service.dart';
import '../lib/domain/service/score_formulas.dart';

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void group(String title) {
  print('');
  print('### $title');
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

void eq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, 'actual=$actual expected=$expected');

void near(String name, double actual, double expected, [double tol = 1e-9]) =>
    check(name, (actual - expected).abs() <= tol,
        'actual=$actual expected=$expected diff=${(actual - expected).abs()}');

Future<void> expectThrows(String name, String code, Future<void> Function() body) async {
  try {
    await body();
    check(name, false, 'no error raised, expected $code');
  } on AcouDietError catch (e) {
    check(name, e.code == code, 'code=${e.code}');
  } catch (e) {
    check(name, false, 'wrong exception type: $e');
  }
}

// --------------------------------------------------------------------------- fixtures

const int chips = 0;
const int cabbage = 1;
const int gummies = 2;
const int noodles = 3;
const int carrot = 4;
const int drink = 5;

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

/// A record at a fixed local time on [dayOfWindow] (0 = the anchor day).
DietRecord rec(
  int dayOfWindow,
  int hour,
  int minute,
  int classId, {
  String? id,
  int durationSeconds = 300,
  double confidence = 0.8,
}) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOfWindow));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: id ?? 'r-$dayOfWindow-$hour-$minute-$classId',
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + durationSeconds * 1000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    // Synthetic marker, not a real knowledge-base attribute: this builder serves every class,
    // so claiming one attribute for all of them (it used to say 脆性食品 for all six) would be
    // a false statement even in a fixture -- and ADR-19 made it false for a second reason.
    attribute: 'attr-$classId',
    confidence: confidence,
    durationSeconds: durationSeconds,
    source: 'real',
  );
}

BehaviorMetrics met({double? interval, int duration = 300, int? chew = 40}) =>
    BehaviorMetrics(
      chewCount: chew,
      avgChewIntervalSeconds: interval,
      durationSeconds: duration,
      speedGrade: interval == null ? null : '正常',
    );

/// The 7-local-day window every worked example uses.
DateRange weekRange() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

FakeRepo repoOf(List<(DietRecord, BehaviorMetrics?)> items) => FakeRepo(
      records: items.map((e) => e.$1).toList(),
      metrics: items.map((e) => e.$2 ?? BehaviorMetrics.placeholder).toList(),
      baseDayMs: _anchorMs,
      kcalOverride: FakeRepo.defaultKcalTable,
    );

// --------------------------------------------------------------------------- main

Future<void> main() async {
  print('=' * 78);
  print('AcouDiet pure-Dart test suite (core / domain / data-logic)');
  print('=' * 78);

  _coreChecks();
  _timeAndWindowChecks();
  _scoreFormulaChecks();
  await _specA01WorkedExamples();
  await _adr23Checks();
  await _adviceChecks();
  await _reportChecks();
  await _repoInvariantChecks();
  _voteAggregatorChecks();
  _behaviorAnalyzerChecks();

  print('');
  print('=' * 78);
  print('PURE: $_passed passed, $_failed failed, ${_passed + _failed} total');
  if (_failed > 0) {
    print('FAILED CHECKS:');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  print('=' * 78);
  if (_failed > 0) {
    throw StateError('$_failed pure-Dart checks failed');
  }
}

// --------------------------------------------------------------------------- groups

void _coreChecks() {
  group('core / errors');
  final e = AcouDietError(Codes.melFrameCount, 'x', detail: {'expectedFrames': 129});
  eq('error code preserved', e.code, 'ACD-MEL-001');
  check('error detail is serialisable', e.detail!['expectedFrames'] == 129);
  check('ACD-AUD-001 is retryable', isRetryable(Codes.audioRecordInitFailed));
  check('ACD-MEL-001 is not retryable', !isRetryable(Codes.melFrameCount));
  final fromPlatform = AcouDietError.fromPlatform(
      code: Codes.cfgMismatch, message: 'mismatch', detail: {'field': 'nFrames'});
  check('platform error keeps its code', fromPlatform.code == Codes.cfgMismatch);
  check('platform error is flagged as config mismatch', fromPlatform.isConfigMismatch);
}

void _timeAndWindowChecks() {
  group('core / time + meal windows (ADR-09)');
  final t = DateTime(2026, 9, 10, 15, 40);
  eq('minutesOfLocalDay', TimeUtil.minutesOfLocalDay(t.millisecondsSinceEpoch), 15 * 60 + 40);
  eq('hourOfLocalDay', TimeUtil.hourOfLocalDay(t.millisecondsSinceEpoch), 15);

  // The 14 frozen boundary minutes from API-03 section 5.
  final boundaries = <int, String>{
    4 * 60 + 59: 'snack',
    5 * 60: 'breakfast',
    9 * 60 + 59: 'breakfast',
    10 * 60: 'snack',
    10 * 60 + 59: 'snack',
    11 * 60: 'lunch',
    13 * 60 + 59: 'lunch',
    14 * 60: 'snack',
    16 * 60 + 59: 'snack',
    17 * 60: 'dinner',
    19 * 60 + 59: 'dinner',
    20 * 60: 'dinner',
    20 * 60 + 59: 'dinner',
    21 * 60: 'snack',
  };
  final bad = <String>[];
  boundaries.forEach((minutes, expected) {
    final actual = MealWindows.mealName(minutes);
    if (actual != expected) bad.add('$minutes->$actual(want $expected)');
  });
  check('14 window boundaries', bad.isEmpty, bad.join(','));

  check('15:40 is a snack (the whole point of ADR-09)', MealWindows.isSnack(15 * 60 + 40));
  check('20:30 counts as late night', MealWindows.isLateNight(20 * 60 + 30));
  check('snack and late night deliberately overlap',
      MealWindows.isSnack(22 * 60) && MealWindows.isLateNight(22 * 60));

  // ADR-23: a snack is a SOLID food outside the meal windows. A drink is its own category, so
  // it is neither a snack nor a meal sample -- before this rule an afternoon drink was counted
  // as a snack and as its own class in the same aggregate (i.e. twice).
  final drinkId = MealWindows.liquidClassId;
  check('the liquid class id resolves from the SSOT class table',
      drinkId >= 0 && cfg.FeatureConfig.classLabels[drinkId] == 'drink', '$drinkId');
  check('15:40 chips is a snack', MealWindows.isSnackRecord(15 * 60 + 40, 0));
  check('15:40 drink is NOT a snack', !MealWindows.isSnackRecord(15 * 60 + 40, drinkId));
  check('12:00 drink is not a meal sample either',
      !MealWindows.isMealSample(12 * 60, drinkId));
  check('12:00 noodles is a meal sample', MealWindows.isMealSample(12 * 60, 3));
  check('the time-only predicate still says snack (frozen API-03 semantics)',
      MealWindows.isSnack(15 * 60 + 40));

  group('core / portion estimate (ADR-23)');
  // The estimator itself is exercised against the real knowledge base in
  // `session_tests.dart` -> `P-08 knowledge base`; here only the class rule is pinned, because
  // it lives in the domain model and must hold without an asset.

  group('core / de-duplicated statistics');
  eq('sampleStdDev needs n>=2', sampleStdDev([5]), null);
  near('sampleStdDev {420,420,420,460} = 20', sampleStdDev([420, 420, 420, 460])!, 20.0);
  near('sampleStdDev {1020,1020,1020,1140} = 60',
      sampleStdDev([1020, 1020, 1020, 1140])!, 60.0);

  group('core / handshake field list (API-00 section 3.6)');
  // NOT `eq(12, 12)`. That is what this used to be -- a literal compared with itself, which
  // could never fail and therefore could never catch the field list drifting away from the
  // Kotlin side. It now compares the two lists that actually have to agree.
  eq('the Dart field list has 15 entries (ADR-21)', NativeCapabilities.handshakeFields.length, 15);
  eq('Handshake.expected() covers exactly the same 15 fields',
      Handshake.expected(melVersion: cfg.FeatureConfig.melVersion).keys.toList().join(','),
      NativeCapabilities.handshakeFields.join(','));
  check('no db-clip field survives (ADR-21 removed the fixed clip)',
      !NativeCapabilities.handshakeFields.contains('dbClipMin') &&
          !NativeCapabilities.handshakeFields.contains('dbClipMax'));
  check('the two frame counts are both compared and are different numbers',
      NativeCapabilities.handshakeFields.contains('rawMelFrames') &&
          NativeCapabilities.handshakeFields.contains('nFrames') &&
          cfg.FeatureConfig.rawMelFrames != cfg.FeatureConfig.nFrames);
  eq('nFrames is the frozen SSOT value (ADR-21)', cfg.FeatureConfig.nFrames, 128);
  eq('rawMelFrames keeps the STFT frame count', cfg.FeatureConfig.rawMelFrames, 129);
  eq('input shape follows n_frames', cfg.FeatureConfig.inputShape.join(','), '1,128,128,1');
}

void _scoreFormulaChecks() {
  group('SPEC-A-01 formulas');
  eq('formula string regularity', ScoreFormulas.formulaOf('regularity'),
      '30 × max(0, 1 − σ/90min)');
  eq('formula string structure', ScoreFormulas.formulaOf('structure'), '30 × min(1, p/0.4)');
  eq('formula string snack', ScoreFormulas.formulaOf('snack'), '20 × max(0, 1 − n/10)');
  eq('regularity weight from the SSOT', ScoreFormulas.maxRegularity, 30);
  eq('speed weight from the SSOT', ScoreFormulas.maxSpeed, 20);

  final counts = <String, int>{for (final l in cfg.FeatureConfig.classLabels) l: 0}..['noodles'] = 3;

  // ADR-15 regression: p = 0.30 must give 22 under the literal expression, never 23.
  final literal = ScoreFormulas.compute(ScoreInputs(
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
  eq('ADR-15 literal expression: p=0.30 -> 22 (not 23)', literal.structure.score, 22);

  final half = ScoreFormulas.compute(ScoreInputs(
    sigmaMinutes: 30,
    mealTimeSamples: 4,
    // healthyCount = 2 of 20 records -> p = 0.10, the fixture of worked example C.
    classCounts: {for (final l in cfg.FeatureConfig.classLabels) l: 0}..['noodles'] = 2,
    recordCount: 20,
    snackCount: 14,
    lateNightCount: 0,
    avgChewIntervalSeconds: 0.45,
    sampleCount: 20,
    missingMetricsCount: 0,
    windowDays: 7,
  ));
  eq('sigma=30 -> regularity 20 (ADR-05)', half.regularity.score, 20);
  eq('p=0.10 -> structure 8 (7.5 rounds away from zero)', half.structure.score, 8);
  eq('n=14 -> snack 0 (floor at zero)', half.snack.score, 0);
  eq('total = sum of rounded dimensions', half.totalScore,
      half.regularity.score + half.structure.score + half.snack.score + half.speed.score);
}

Future<void> _specA01WorkedExamples() async {
  group('SPEC-A-01 worked example A (all four dimensions full marks)');
  final a = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.80)),
    (rec(2, 7, 0, noodles), met(interval: 0.80)),
    (rec(1, 12, 0, carrot), met(interval: 0.80)),
    (rec(2, 12, 0, carrot), met(interval: 0.80)),
    (rec(1, 18, 30, cabbage), met(interval: 0.80)),
    (rec(2, 18, 30, cabbage), met(interval: 0.80)),
  ]);
  final sa = await HealthScoreService(stats: a).score(range: weekRange());
  eq('A.totalScore', sa.totalScore, 100);
  eq('A.grade', sa.grade, '良好');
  eq('A.regularity', sa.regularity.score, 30);
  eq('A.structure', sa.structure.score, 30);
  eq('A.snack', sa.snack.score, 20);
  eq('A.speed', sa.speed.score, 20);
  near('A.sigma = 0', sa.regularity.evidence['sigmaMinutes'] as double, 0.0);
  eq('A.lateNightCount', sa.snack.evidence['lateNightCount'], 0);
  eq('A.deltaVsYesterday is null when the previous day is empty',
      sa.deltaVsYesterday, null);

  group('SPEC-A-01 worked example B (afternoon snack: ADR-09 windows)');
  final b = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.70)),
    (rec(2, 7, 0, noodles), met(interval: 0.70)),
    (rec(3, 7, 0, gummies), met(interval: 0.70)),
    (rec(4, 7, 40, gummies), met(interval: 0.70)),
    for (var d = 1; d <= 6; d++) (rec(d, 15, 40, chips), met(interval: 0.70)),
  ]);
  final sb = await HealthScoreService(stats: b).score(range: weekRange());
  near('B.sigma = 20', sb.regularity.evidence['sigmaMinutes'] as double, 20.0);
  eq('B.regularity = 23', sb.regularity.score, 23);
  near('B.healthyRatio = 0.20', sb.structure.evidence['healthyRatio'] as double, 0.20);
  eq('B.structure = 15', sb.structure.score, 15);
  eq('B.snackCount = 6 (15:40 is a snack)', sb.snack.evidence['snackCount'], 6);
  eq('B.snack = 8', sb.snack.score, 8);
  eq('B.speed = 15', sb.speed.score, 15);
  eq('B.totalScore = 61', sb.totalScore, 61);
  eq('B.grade = 一般', sb.grade, '一般');

  group('SPEC-A-01 worked example C (sigma=30 dispute + two zero endpoints)');
  final c = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.40)),
    (rec(2, 7, 0, noodles), met(interval: 0.40)),
    (rec(1, 17, 0, chips), met(interval: 0.40)),
    (rec(2, 17, 0, chips), met(interval: 0.40)),
    (rec(3, 17, 0, chips), met(interval: 0.40)),
    (rec(4, 19, 0, chips), met(interval: 0.40)),
    // All seven snack days must lie inside the window (offsets 0…6); offsets 1…7 would leak
    // one day into the previous-day window and make `deltaVsYesterday` non-null.
    for (var d = 1; d <= 7; d++) ...[
      (rec(d - 1, 15, 40, chips, id: 'c-a-$d'), met(interval: 0.40)),
      (rec(d - 1, 15, 45, chips, id: 'c-b-$d'), met(interval: 0.40)),
    ],
  ]);
  final sc = await HealthScoreService(stats: c).score(range: weekRange());
  near('C.sigma = 30', sc.regularity.evidence['sigmaMinutes'] as double, 30.0);
  eq('C.regularity = 20 (ADR-05: formula wins over prose)', sc.regularity.score, 20);
  eq('C.structure = 8', sc.structure.score, 8);
  eq('C.snack = 0', sc.snack.score, 0);
  eq('C.speed = 0', sc.speed.score, 0);
  eq('C.totalScore = 28', sc.totalScore, 28);
  eq('C.grade = 需改善', sc.grade, '需改善');
  eq('C.deltaVsYesterday is null when the previous day is empty', sc.deltaVsYesterday, null);
  eq('C.lateNightCount = 0 (17:00 and 19:00 precede 20:00)',
      sc.snack.evidence['lateNightCount'], 0);

  group('SPEC-A-01 worked example D (insufficient data stays deterministic)');
  final d = repoOf([
    (rec(1, 7, 0, noodles), BehaviorMetrics.placeholder),
    (rec(2, 12, 0, carrot), BehaviorMetrics.placeholder),
    (rec(3, 18, 0, chips), BehaviorMetrics.placeholder),
    for (var i = 1; i <= 5; i++) (rec(i, 15, 40, chips), BehaviorMetrics.placeholder),
  ]);
  final sd = await HealthScoreService(stats: d).score(range: weekRange());
  eq('D.regularity = 0', sd.regularity.score, 0);
  eq('D.sigmaMinutes stays null for the UI', sd.regularity.evidence['sigmaMinutes'], null);
  eq('D.structure = 19 (18.75)', sd.structure.score, 19);
  eq('D.snack = 10', sd.snack.score, 10);
  eq('D.speed = 0', sd.speed.score, 0);
  eq('D.totalScore = 29', sd.totalScore, 29);
  eq('D.avgChewIntervalSeconds is null', sd.speed.evidence['avgChewIntervalSeconds'], null);
  eq('D.sampleCount = 0', sd.speed.evidence['sampleCount'], 0);
  eq('D.missingMetricsCount = 8', sd.speed.evidence['missingMetricsCount'], 8);

  group('SPEC-A-01 evidence key sets (the key set IS the contract)');
  eq('regularity keys', (sd.regularity.evidence.keys.toList()..sort()).join(','),
      'mealTimeSamples,sigmaMinutes,windowDays');
  eq('structure keys', (sd.structure.evidence.keys.toList()..sort()).join(','),
      'healthyCount,healthyRatio,totalCount');
  eq('snack keys', (sd.snack.evidence.keys.toList()..sort()).join(','),
      'lateNightCount,snackCount');
  eq('speed keys', (sd.speed.evidence.keys.toList()..sort()).join(','),
      'avgChewIntervalSeconds,missingMetricsCount,sampleCount');
  eq('four dimension labels are fixed', sa.dimensions.map((x) => x.label).join(','),
      '饮食规律性,食物结构,零食控制,进食速度');

  group('SPEC-A-01 validation and reproducibility');
  await expectThrows('reversed range -> ACD-DB-004', Codes.dbInvalidArgument, () async {
    await HealthScoreService(stats: a).score(range: const DateRange(2000, 1000));
  });
  await expectThrows('range longer than 31 days -> ACD-DB-004', Codes.dbInvalidArgument,
      () async {
    await HealthScoreService(stats: a)
        .score(range: DateRange(_anchorMs - 40 * 86400000, _anchorMs));
  });
  final first = await HealthScoreService(stats: a).score(range: weekRange());
  final second = await HealthScoreService(stats: a).score(range: weekRange());
  check('same database + same window -> identical output',
      first.totalScore == second.totalScore &&
          first.regularity.score == second.regularity.score &&
          first.speed.score == second.speed.score &&
          first.deltaVsYesterday == second.deltaVsYesterday);
}

Future<void> _adr23Checks() async {
  group('ADR-23 score window + per-day four dimensions');

  // A week of solid meals (so σ is defined) plus ONE record in the previous equal-length
  // window, so the delta has a benchmark and the two window lengths give different answers.
  final stats = repoOf([
    for (var d = 1; d <= 3; d++) ...[
      (rec(d, 7, 0, noodles), met(interval: 0.7)),
      (rec(d, 12, 0, carrot), met(interval: 0.7)),
      (rec(d, 18, 30, cabbage), met(interval: 0.7)),
    ],
    (rec(8, 12, 0, chips), met(interval: 0.7)),
  ]);
  final svc = HealthScoreService(stats: stats);

  final oneDayRange = DateRange(
    TimeUtil.startOfLocalDay(_anchorMs),
    TimeUtil.startOfNextLocalDay(_anchorMs),
  );
  final sevenDayRange = DateRange(
    TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs).$1,
    TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs).$2,
  );

  final oneDay = await svc.score(range: oneDayRange);
  final sevenDay = await svc.score(range: sevenDayRange);

  // The one-day window is exactly the window that showed `--` on the home card: the window has
  // no records at all, so every dimension has no basis.
  eq('a one-day window over an empty day has no records',
      oneDay.structure.evidence['totalCount'], 0);
  eq('the seven-day window counts the three days of meals',
      sevenDay.structure.evidence['totalCount'], 9);
  check('the seven-day window has a defined σ (meal classes with >= 2 samples)',
      sevenDay.regularity.evidence['sigmaMinutes'] != null);

  // The delta must come from the previous EQUAL-LENGTH window. The fixture has meals on days
  // 1-3 and one lone record on day 8, so the two window lengths give different benchmarks.
  final oneDayPrev = await svc.score(range: oneDayRange.previous);
  check('the one-day delta is computed against the previous day',
      oneDay.deltaVsYesterday ==
          oneDay.totalScore - oneDayPrev.totalScore);
  eq('the previous day (day 1) holds the three meal days of the fixture',
      oneDayPrev.structure.evidence['totalCount'], 3);
  check('the seven-day delta does have a benchmark (day 8 is in the previous week)',
      sevenDay.deltaVsYesterday != null);
  // The old hard-wired implementation always measured ONE day, so it could never have produced
  // a different delta for a seven-day window. Pin the two apart explicitly.
  check('a seven-day window is not compared against a single day',
      sevenDay.deltaVsYesterday !=
          (sevenDay.totalScore -
              (await svc.score(range: DateRange(
                TimeUtil.startOfLocalDay(sevenDayRange.startMs - 86400000),
                sevenDayRange.startMs,
              ))).totalScore));

  // Per-day four dimensions (the report's 「每日四维评分」).
  final reports = ReportService(stats: stats, scores: svc);
  final daily = await reports.dailyScores(days: 7);
  eq('one entry per local day', daily.length, 7);
  eq('the series is ascending and gapless',
      daily.map((d) => d.date).join(','),
      TimeUtil.dayKeysInRange(sevenDayRange.startMs, sevenDayRange.endMs).join(','));
  final withData = daily.where((d) => d.hasData).toList();
  eq('only the three days with records carry a score', withData.length, 3);
  check('a scored day carries all four dimensions',
      withData.every((d) => d.score!.dimensions.length == 4));
  check('an empty day stays null instead of a zero',
      daily.where((d) => !d.hasData).every((d) => d.estimatedKcal == null && d.score == null));
  check('the same day scored twice is the same number',
      (await reports.dailyScores(days: 7)).firstWhere((d) => d.hasData).score!.totalScore ==
          withData.first.score!.totalScore);

  // ADR-25: a daily number is scored over the SEVEN days ending that day, not the day alone.
  //
  // Measured before the fix (`tool/probe_daily_score.dart`): a single calendar day can essentially
  // never define σ (it needs two samples of the SAME meal), so `ScoreView.of` closed the total on
  // every day and the 每日 card rendered `--` for both the score and the grade -- no matter how
  // good the day was. These three assertions are the bug's offline equivalent.
  eq('ADR-25: the score window is the seven days ending that day',
      withData.last.score!.regularity.evidence['windowDays'], 7);
  check('ADR-25: every scored day has a defined σ (the trailing window supplies it)',
      withData.every((d) => d.score!.regularity.evidence['sigmaMinutes'] != null));
  final displayable = withData.where((d) {
    final s = d.score!;
    final totalCount = (s.structure.evidence['totalCount'] as num?)?.toInt() ?? 0;
    return s.regularity.evidence['sigmaMinutes'] != null &&
        totalCount >= HealthScoreService.minimumRecordsForDisplay &&
        s.speed.evidence['avgChewIntervalSeconds'] != null;
  }).toList();
  eq('ADR-25: every scored day passes all three display gates, so a total and a grade render',
      displayable.length, withData.length);
  // The window ends ON the day: a day's score must move when that day's own meals change.
  check('ADR-25: the window includes the day itself',
      ReportService.scoreWindowFor(TimeUtil.startOfLocalDay(_anchorMs)).endMs ==
          TimeUtil.startOfNextLocalDay(_anchorMs));
}

Future<void> _adviceChecks() async {
  group('SPEC-A-02 advice rules');
  const engine = AdviceEngine();

  final fixture = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.42)),
    (rec(2, 7, 0, noodles), met(interval: 0.42)),
    (rec(3, 7, 0, chips), met(interval: 0.42)),
    for (var i = 1; i <= 6; i++) (rec(i, 15, 40, chips), met(interval: 0.42)),
    for (var i = 1; i <= 3; i++) (rec(i, 21, 30, chips), met(interval: 0.42)),
  ]);
  final score = await HealthScoreService(stats: fixture).score(range: weekRange());
  final agg = await fixture.summary(weekRange());

  final advices = await engine.generate(score: score, agg: agg);
  final general = advices.where((a) => a.dimension == Advice.dimGeneral).toList();
  eq('exactly one general disclaimer', general.length, 1);
  eq('disclaimer text is frozen verbatim', general.first.text, AdviceEngine.disclaimerText);
  final maxOther = advices
      .where((a) => a.dimension != Advice.dimGeneral)
      .fold<int>(0, (m, a) => a.priority > m ? a.priority : m);
  check('disclaimer priority is the maximum', general.first.priority > maxOther);
  eq('disclaimer is last', advices.last.dimension, Advice.dimGeneral);

  check('snack rule fires with the real count',
      advices.any((a) =>
          a.dimension == Advice.dimSnack && a.text.contains('本周零食 ${agg.snackCount} 次')),
      'snackCount=${agg.snackCount}');
  check('late-night rule fires with the real count',
      advices.any((a) =>
          a.dimension == Advice.dimRegularity &&
          a.text.contains('有 ${agg.lateNightCount} 次进食发生在晚间')),
      'lateNightCount=${agg.lateNightCount}');
  check('speed rule fires with a one-decimal interval',
      advices.any((a) => a.dimension == Advice.dimSpeed && a.text.contains('约 0.4 秒')));

  var noPlaceholders = true;
  var withinLength = true;
  var cleanText = true;
  const banned = ['准确识别', '零操作', '完全无感', '测热量', '可以测', '营养成分'];
  for (final a in advices) {
    if (RegExp(r'\{[a-zA-Z]+\}').hasMatch(a.text)) noPlaceholders = false;
    if (a.text.length > AdviceEngine.maxTextLength) withinLength = false;
    for (final b in banned) {
      if (a.text.contains(b)) cleanText = false;
    }
    if (RegExp(r'\d+\s*kcal').hasMatch(a.text)) cleanText = false;
  }
  check('no unfilled placeholders', noPlaceholders);
  check('every text is within 40 characters', withinLength);
  check('no FF-25 banned wording', cleanText);

  final again = await engine.generate(score: score, agg: agg);
  eq('deterministic ordering and text',
      again.map((a) => '${a.dimension}|${a.priority}|${a.text}').join(';'),
      advices.map((a) => '${a.dimension}|${a.priority}|${a.text}').join(';'));

  group('SPEC-A-02 insufficient data');
  final tinyRepo = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.7)),
    (rec(2, 7, 0, noodles), met(interval: 0.7)),
  ]);
  final tinyAdvice = await engine.generate(
    score: await HealthScoreService(stats: tinyRepo).score(range: weekRange()),
    agg: await tinyRepo.summary(weekRange()),
  );
  eq('recordCount < 3 -> disclaimer only', tinyAdvice.length, 1);
  eq('the single item is general', tinyAdvice.single.dimension, Advice.dimGeneral);

  group('SPEC-A-02 null fields skip rules instead of faking zero');
  final nullRepo = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.7)),
    (rec(2, 12, 0, carrot), met(interval: 0.7)),
    (rec(3, 18, 0, chips), met(interval: 0.7)),
  ]);
  final nullAdvice = await engine.generate(
    score: await HealthScoreService(stats: nullRepo).score(range: weekRange()),
    agg: await nullRepo.summary(weekRange()),
  );
  check('no regularity wording when sigma is null',
      !nullAdvice.any((a) => a.text.contains('三餐时间不够固定')));
  check('no literal null leaks into text', !nullAdvice.any((a) => a.text.contains('null')));
}

Future<void> _reportChecks() async {
  group('SPEC-A-03 weekly report');
  final thisWeek = repoOf([
    (rec(1, 7, 0, noodles), met(interval: 0.7)),
    (rec(1, 12, 0, carrot), met(interval: 0.7)),
    (rec(1, 18, 0, cabbage), met(interval: 0.7)),
    for (var i = 1; i <= 6; i++) (rec(i, 15, 40, chips), met(interval: 0.7)),
  ]);

  final svc = ReportService(stats: thisWeek, scores: HealthScoreService(stats: thisWeek));
  final report = await svc.weekly(range: weekRange());
  eq('deltas has exactly 7 keys', report.deltas.length, 7);
  eq('deltas key set',
      (report.deltas.keys.toList()..sort()).join(','),
      'estimatedKcal,recordCount,regularity,snack,speed,structure,totalScore');
  check('no benchmark -> all deltas are 0 (never null)',
      report.deltas.values.every((v) => v == 0));
  check('summaryText quotes the real record count (9)',
      report.summaryText.contains('本周记录 9 次'), report.summaryText);
  check('summaryText quotes the real snack count (6)',
      report.summaryText.contains('零食 6 次'), report.summaryText);
  eq('report score equals a direct service call', report.score.totalScore,
      (await HealthScoreService(stats: thisWeek).score(range: weekRange())).totalScore);
  eq('advices carry the disclaimer', report.advices.last.dimension, Advice.dimGeneral);
  eq('summaryText contains no unfilled placeholder',
      RegExp(r'\{').hasMatch(report.summaryText), false);

  // Fixture for verdict 1 of SPEC-A-03 section 7: 6 snacks this week, 5 last week.
  final withPrev = repoOf([
    (rec(1, 7, 0, noodles, id: 'cur-b'), met(interval: 0.7)),
    (rec(1, 12, 0, carrot, id: 'cur-c'), met(interval: 0.7)),
    (rec(1, 18, 0, cabbage, id: 'cur-a'), met(interval: 0.7)),
    for (var i = 1; i <= 6; i++) (rec(i, 15, 40, chips, id: 'cur-s$i'), met(interval: 0.7)),
    for (var i = 8; i <= 12; i++) (rec(i, 15, 40, chips, id: 'prev-s$i'), met(interval: 0.7)),
  ]);
  final report2 = await ReportService(
    stats: withPrev,
    scores: HealthScoreService(stats: withPrev),
  ).weekly(range: weekRange());
  check('snack cycle appears as +20%',
      report2.summaryText.contains('+20%'), report2.summaryText);
  eq('recordCount delta is 4 (9 - 5)', report2.deltas['recordCount'], 4);

  group('SPEC-A-03 empty window');
  final empty = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final emptyReport = await ReportService(
    stats: empty,
    scores: HealthScoreService(stats: empty),
  ).weekly(range: weekRange());
  eq('empty window uses the frozen text', emptyReport.summaryText,
      ReportService.insufficientDataText);
  check('empty window text has no percentage', !emptyReport.summaryText.contains('%'));
  check('empty window deltas are all zero', emptyReport.deltas.values.every((v) => v == 0));
  eq('empty window score is still deterministic', emptyReport.score.totalScore,
      0 + 0 + 20 + 0);

  group('SPEC-A-03 trend series');
  final trendRepo = FakeRepo(
    records: [rec(0, 7, 0, noodles), rec(2, 12, 0, carrot)],
    metrics: [met(interval: 0.7), met(interval: 0.7)],
    baseDayMs: _anchorMs,
    kcalOverride: FakeRepo.defaultKcalTable,
  );
  final trend = await ReportService(
    stats: trendRepo,
    scores: HealthScoreService(stats: trendRepo),
  ).trend(days: 7);
  eq('trend length equals days', trend.points.length, 7);
  var ascending = true;
  var contiguous = true;
  var formatted = true;
  final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  for (var i = 0; i < trend.points.length; i++) {
    if (!dateRe.hasMatch(trend.points[i].date)) formatted = false;
    if (i > 0) {
      final prev = DateTime.parse(trend.points[i - 1].date);
      final cur = DateTime.parse(trend.points[i].date);
      if (!cur.isAfter(prev)) ascending = false;
      if (cur.difference(prev).inDays != 1) contiguous = false;
    }
  }
  check('trend dates match yyyy-MM-dd', formatted);
  check('trend is ascending', ascending);
  check('trend is gapless', contiguous);
  final todayPoint = trend.points.last;
  eq('today has records so kcal is filled', todayPoint.estimatedKcal != null, true);
  eq('today has a score filled by L4', todayPoint.totalScore != null, true);
  final gapDay = trend.points[5];
  eq('a day without records keeps null kcal (not 0)', gapDay.estimatedKcal, null);
  eq('a day without records keeps null score', gapDay.totalScore, null);

  await expectThrows('days out of range -> ACD-DB-004', Codes.dbInvalidArgument, () async {
    await ReportService(stats: trendRepo, scores: HealthScoreService(stats: trendRepo))
        .trend(days: 400);
  });
}

Future<void> _repoInvariantChecks() async {
  group('API-03 repository invariants');
  final repo = FakeRepo(baseDayMs: _anchorMs);
  final r = rec(0, 8, 0, noodles, id: 'x1');
  await repo.insertSession(record: r, metrics: null);
  eq('I-1: a placeholder metrics row exists',
      (await repo.metricsByRecordId('x1'))!.isPlaceholder, true);
  eq('metricsByRecordId returns null for an unknown record',
      await repo.metricsByRecordId('nope'), null);
  await expectThrows('duplicate recordId -> ACD-DB-002', Codes.dbUniqueConstraint, () async {
    await repo.insertSession(record: r, metrics: null);
  });
  await expectThrows('invalid record -> ACD-DB-004', Codes.dbInvalidArgument, () async {
    await repo.insertSession(
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
    );
  });

  final all = await repo.byRange(DateRange(0, 1 << 62));
  eq('byRange finds the inserted record', all.length, 1);
  final summary = await repo.summary(weekRange());
  eq('classCounts always has 6 keys', summary.classCounts.length, 6);
  final meals = await repo.mealTimes(7);
  eq('byHour always has 24 keys', meals.byHour.length, 24);

  await expectThrows('unregistered classId -> ACD-KB-001', Codes.kbLookup, () async {
    final noKcal = FakeRepo(baseDayMs: _anchorMs, kcalOverride: const {});
    await noKcal.insertSession(record: rec(0, 9, 0, noodles, id: 'k1'), metrics: null);
    await noKcal.summary(weekRange());
  });

  await repo.deleteAll();
  eq('deleteAll clears records', await repo.countAll(), 0);

  group('API-03 week() == summary(last 7 local days)');
  final fixture = FakeRepo.demoFixture();
  final w = await fixture.week();
  final (ws, we) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  final s = await fixture.summary(DateRange(ws, we));
  eq('recordCount matches', w.recordCount, s.recordCount);
  eq('snackCount matches', w.snackCount, s.snackCount);
  eq('estimatedKcal matches', w.estimatedKcal, s.estimatedKcal);
  eq('classCounts match', w.classCounts.toString(), s.classCounts.toString());
  eq('sigma matches', w.mealTimeStdDevMinutes, s.mealTimeStdDevMinutes);

  group('API-03 demo fixture');
  final demo = FakeRepo.demoFixture();
  final today = await demo.today();
  eq('demo fixture has 4 meals today', today.recordCount, 4);
  check('demo records are flagged as demo', today.records.every((r) => r.isDemo));
  eq('activeDays counts distinct days', await demo.activeDays(), 7);
  check('demo kcal is an estimate over the whole day', today.estimatedKcal > 0);
}

void _voteAggregatorChecks() {
  group('ADR-20 model I/O dtype contract (float32 in / float32 out)');
  // The artifact is INT8-*weight* quantisation with float32 I/O. The App therefore feeds a
  // Float32List and reads float probabilities, and never quantises. These branches are what the
  // FFI loader runs against the real tensor metadata at load time; a model exported with true
  // int8 I/O must be rejected with a message that names the dtype, not a confusing byte-size
  // error, so every branch is pinned here.
  eq('the accepted TfLiteType is 1 (kTfLiteFloat32)', ModelIoContract.tfliteFloat32, 1);
  eq('the documented input dtype is float32', ModelIoContract.inputDtype, 'float32');
  eq('the documented output dtype is float32', ModelIoContract.outputDtype, 'float32');
  eq('float32 in / float32 out satisfies the contract',
      ModelIoContract.problem(
          inputType: ModelIoContract.tfliteFloat32,
          outputType: ModelIoContract.tfliteFloat32),
      null);
  check('an int8 input tensor is rejected',
      (ModelIoContract.problem(inputType: 9, outputType: 1) ?? '').contains('input tensor'));
  check('an int8 output tensor is rejected',
      (ModelIoContract.problem(inputType: 1, outputType: 9) ?? '').contains('output tensor'));
  check('the rejection names the numeric dtype so it is actionable',
      (ModelIoContract.problem(inputType: 1, outputType: 9) ?? '').contains('9'));
  check('int8 in AND out is reported as an input problem first',
      (ModelIoContract.problem(inputType: 9, outputType: 9) ?? '').contains('input tensor'));
  check('a uint8 input (TfLiteType 3) is also rejected',
      ModelIoContract.problem(inputType: 3, outputType: 1) != null);

  // The byte-size form is the PRIMARY check because it needs no optional symbol, so it cannot
  // be the reason a valid model fails to load. For the frozen [1,128,128,1] the two readings
  // differ by exactly 4x, which is what makes the derivation unambiguous.
  {
    const melCount = 128 * 128;      // n_mels * n_frames (FF-14 / ADR-21)
    const numClasses = 6;
    const float32Input = melCount * 4;    // 65536
    const float32Output = numClasses * 4; // 24
    eq('float32 sizes satisfy the byte-size contract',
        ModelIoContract.byteSizeProblem(
            inputBytes: float32Input,
            outputBytes: float32Output,
            melCount: melCount,
            numClasses: numClasses),
        null);
    check('an int8 input tensor (melCount bytes) is rejected by byte size',
        (ModelIoContract.byteSizeProblem(
                    inputBytes: melCount,
                    outputBytes: float32Output,
                    melCount: melCount,
                    numClasses: numClasses) ??
                '')
            .contains('INT8'));
    check('an int8 output tensor (numClasses bytes) is rejected by byte size',
        ModelIoContract.byteSizeProblem(
                inputBytes: float32Input,
                outputBytes: numClasses,
                melCount: melCount,
                numClasses: numClasses) !=
            null);
    check('the byte-size rejection states both observed and expected counts',
        (ModelIoContract.byteSizeProblem(
                    inputBytes: melCount,
                    outputBytes: float32Output,
                    melCount: melCount,
                    numClasses: numClasses) ??
                '')
            .contains('$float32Input'));
  }

  group('API-02 VoteAggregator');
  final voteCfg = VotingConfig.fromFeatureConfig();
  eq('voting config comes from the SSOT', voteCfg.confirmConsecutivePatches, 4);
  eq('tau thresholds come from the SSOT', voteCfg.tauConfirm, 0.7);

  InferenceResult res(int classId, double p) {
    final probs = Float32List(cfg.FeatureConfig.numClasses);
    final rest = (1 - p) / (cfg.FeatureConfig.numClasses - 1);
    for (var i = 0; i < probs.length; i++) {
      probs[i] = i == classId ? p : rest;
    }
    return InferenceResult(
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      confidence: p,
      probs: probs,
      latencyMs: 30,
    );
  }

  final agg = VoteAggregator(cfg: voteCfg);
  eq('the first add after reset returns none',
      agg.add(res(0, 0.9), seq: 0, voiced: true).stage, VoteStage.none);

  var confirmed = false;
  var sawLowConfidence = false;
  for (var i = 1; i <= 12; i++) {
    final d = agg.add(res(0, 0.9), seq: i, voiced: true);
    if (d.stage == VoteStage.confirmed) confirmed = true;
    if (d.stage == VoteStage.lowConfidence) sawLowConfidence = true;
  }
  check('repeated identical patches reach confirmed', confirmed);
  check('high confidence never asks the user', !sawLowConfidence);

  final low = VoteAggregator(cfg: voteCfg);
  for (var i = 0; i <= 6; i++) {
    low.add(res(1, 0.5), seq: i, voiced: true);
  }
  final d = low.add(res(1, 0.5), seq: 7, voiced: true);
  eq('tauLow <= p < tauConfirm -> lowConfidence', d.stage, VoteStage.lowConfidence);
  eq('lowConfidence asks the user', d.shouldAskUser, true);

  final silent = VoteAggregator(cfg: voteCfg);
  for (var i = 0; i <= 5; i++) {
    silent.add(res(2, 0.9), seq: i, voiced: true);
  }
  final beforeCount = silent.consecutiveCount;
  final beforeSamples = silent.sampleCount;
  silent.add(res(3, 0.1), seq: 6, voiced: false);
  eq('a silent patch still advances the EMA', silent.sampleCount, beforeSamples + 1);
  eq('a silent patch leaves the consecutive count alone',
      silent.consecutiveCount, beforeCount);

  final gap = VoteAggregator(cfg: voteCfg);
  for (var i = 0; i <= 5; i++) {
    gap.add(res(0, 0.9), seq: i, voiced: true);
  }
  gap.add(res(0, 0.9), seq: 20, voiced: true);
  eq('a seq gap resets the consecutive counter', gap.consecutiveCount, 1);

  final reset = VoteAggregator(cfg: voteCfg);
  reset.add(res(0, 0.9), seq: 0, voiced: true);
  reset.reset();
  eq('reset clears the sample count', reset.sampleCount, 0);
  eq('the add after reset is none again',
      reset.add(res(0, 0.9), seq: 0, voiced: true).stage, VoteStage.none);

  try {
    VoteAggregator(cfg: voteCfg).add(
      InferenceResult(
        classId: 0,
        label: 'chips',
        confidence: 1,
        probs: Float32List(3),
        latencyMs: 1,
      ),
      seq: 0,
      voiced: true,
    );
    check('wrong probs length -> ACD-INF-002', false, 'no error');
  } on AcouDietError catch (e) {
    check('wrong probs length -> ACD-INF-002', e.code == Codes.inferShape, e.code);
  }
}

void _behaviorAnalyzerChecks() {
  group('API-02 BehaviourAnalyzer');
  final behaviorCfg = BehaviorConfig.fromFeatureConfig();
  eq('envelope length from the SSOT', behaviorCfg.envelopeLength, 819);
  eq('envelope hop from the SSOT', behaviorCfg.envelopeHopMs, 5);

  Float32List envelopeWithPeaks(double intervalSeconds, {int peaks = 12}) {
    final env = Float32List(behaviorCfg.envelopeLength);
    for (var i = 0; i < env.length; i++) {
      env[i] = 0.01;
    }
    final framesPerPeak = (intervalSeconds * 1000 / behaviorCfg.envelopeHopMs).round();
    for (var p = 0; p < peaks; p++) {
      final at = 20 + p * framesPerPeak;
      if (at + 3 < env.length) {
        env[at] = 0.9;
        env[at + 1] = 0.6;
        env[at + 2] = 0.25;
      }
    }
    return env;
  }

  final analyzer = BehaviorAnalyzer();
  var t = 1000000;
  for (var i = 0; i < 5; i++) {
    analyzer.feedEnvelope(envelopeWithPeaks(0.7),
        hopMs: behaviorCfg.envelopeHopMs, tStartMs: t);
    t += 4096;
  }
  final metrics = analyzer.finish(endMs: t + 1000)!;
  check('chew count is detected', (metrics.chewCount ?? 0) > 0, 'count=${metrics.chewCount}');
  final avg = metrics.avgChewIntervalSeconds;
  check('average interval is close to 0.7 s', avg != null && (avg - 0.7).abs() < 0.15,
      'avg=$avg');
  eq('speed grade for ~0.7 s is 正常', metrics.speedGrade, '正常');
  check('duration is reported', (metrics.durationSeconds ?? 0) >= 0);
  eq('the metrics map has no rhythm-sigma key (X-07 cut)',
      metrics.toMap('x').keys.any((k) => k.contains('sigma') || k.contains('rhythm')), false);

  // A single peak carries no interval: all three interval fields stay null, never 0.
  final single = BehaviorAnalyzer();
  final onePeak = Float32List(behaviorCfg.envelopeLength);
  onePeak[100] = 0.9;
  single.feedEnvelope(onePeak, hopMs: behaviorCfg.envelopeHopMs, tStartMs: 3000);
  final oneMetrics = single.finish(endMs: 9000);
  check('a single isolated peak is dropped as a pseudo-peak', oneMetrics == null,
      'result=$oneMetrics');

  // Two lone peaks far apart: both isolated, so nothing survives.
  final two = BehaviorAnalyzer();
  final twoPeaks = Float32List(behaviorCfg.envelopeLength);
  for (var i = 0; i < twoPeaks.length; i++) {
    twoPeaks[i] = 0.01;
  }
  twoPeaks[50] = 0.9;
  twoPeaks[700] = 0.9;
  two.feedEnvelope(twoPeaks, hopMs: behaviorCfg.envelopeHopMs, tStartMs: 4000);
  check('two far-apart lone peaks are both dropped', two.finish(endMs: 9000) == null);

  // A wide plateau peak exceeds chewMaxPeakWidthMs and must be removed.
  final wide = BehaviorAnalyzer();
  final wideEnv = Float32List(behaviorCfg.envelopeLength);
  for (var i = 100; i < 100 + (behaviorCfg.chewMaxPeakWidthMs ~/ 5) + 40; i++) {
    wideEnv[i] = 0.9;
  }
  wide.feedEnvelope(wideEnv, hopMs: behaviorCfg.envelopeHopMs, tStartMs: 5000);
  check('a wide peak is removed (FF-21d)', wide.finish(endMs: 11000) == null);

  final fast = BehaviorAnalyzer();
  var t2 = 2000000;
  for (var i = 0; i < 5; i++) {
    fast.feedEnvelope(envelopeWithPeaks(0.3),
        hopMs: behaviorCfg.envelopeHopMs, tStartMs: t2);
    t2 += 4096;
  }
  eq('speed grade for ~0.3 s is 偏快', fast.finish(endMs: t2)!.speedGrade, '偏快');

  // ADR-24: the grade mapping was promoted to a public, pure function because a second caller
  // appeared (the profile page's 「平均咀嚼速度」 tile grades the window aggregate instead of a
  // session). The boundaries are read from the SSOT rather than repeated as literals here, so a
  // threshold change cannot silently leave the test asserting yesterday's number.
  final fastThreshold = cfg.FeatureConfig.behaviorSpeedThresholdsSecondsFast;
  final normalThreshold = cfg.FeatureConfig.behaviorSpeedThresholdsSecondsNormal;
  eq('just below the fast threshold is 偏快',
      BehaviorAnalyzer.speedGradeFor(fastThreshold - 0.01), '偏快');
  eq('exactly on the fast threshold is 正常',
      BehaviorAnalyzer.speedGradeFor(fastThreshold), '正常');
  eq('exactly on the normal threshold is 正常',
      BehaviorAnalyzer.speedGradeFor(normalThreshold), '正常');
  eq('just past the normal threshold is 偏慢',
      BehaviorAnalyzer.speedGradeFor(normalThreshold + 0.01), '偏慢');
  eq('the midpoint is 正常',
      BehaviorAnalyzer.speedGradeFor((fastThreshold + normalThreshold) / 2), '正常');

  final silent = BehaviorAnalyzer();
  silent.feedEnvelope(Float32List(behaviorCfg.envelopeLength),
      hopMs: behaviorCfg.envelopeHopMs, tStartMs: 1000);
  eq('all-silence -> finish returns null', silent.finish(endMs: 2000), null);

  var threw = false;
  try {
    BehaviorAnalyzer().feedEnvelope(Float32List(10), hopMs: 5, tStartMs: 0);
  } on AcouDietError catch (e) {
    threw = e.code == Codes.behaviorInput;
  }
  check('wrong envelope length -> ACD-BEH-001', threw);

  threw = false;
  try {
    BehaviorAnalyzer().feedEnvelope(Float32List(behaviorCfg.envelopeLength),
        hopMs: 10, tStartMs: 0);
  } on AcouDietError catch (e) {
    threw = e.code == Codes.behaviorInput;
  }
  check('wrong hopMs -> ACD-BEH-001', threw);

  threw = false;
  final monkey = BehaviorAnalyzer();
  monkey.feedEnvelope(Float32List(behaviorCfg.envelopeLength),
      hopMs: behaviorCfg.envelopeHopMs, tStartMs: 5000);
  try {
    monkey.feedEnvelope(Float32List(behaviorCfg.envelopeLength),
        hopMs: behaviorCfg.envelopeHopMs, tStartMs: 4000);
  } on AcouDietError catch (e) {
    threw = e.code == Codes.behaviorInput;
  }
  check('non-monotonic tStartMs -> ACD-BEH-001', threw);

  final reset = BehaviorAnalyzer();
  reset.feedEnvelope(envelopeWithPeaks(0.7),
      hopMs: behaviorCfg.envelopeHopMs, tStartMs: 100);
  reset.reset();
  eq('reset clears frames', reset.frameCount, 0);
}

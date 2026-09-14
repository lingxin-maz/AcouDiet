// app/tool/ui_presenter_tests.dart
//
// Dependency-free test runner for the **L5 presentation layer** (U-01..U-06, M-03, M-04).
//
//   dart run tool/ui_presenter_tests.dart
//
// Why it exists: this environment has no network, so `flutter pub get` -- and therefore
// `flutter test` -- cannot resolve sqflite / Riverpod / fl_chart. Every piece of pure display
// logic was therefore put in `lib/presentation/presenters/` and `lib/presentation/theme/`
// **without any Flutter import**, so it compiles and runs against the Dart SDK alone.
// The widget-level suite mandated by PLAN-C-05 lives in `app/test/ui/` and runs under
// `flutter test` once the dependencies resolve.
//
// Imports are relative on purpose: a `package:` import would need a resolved package config,
// which is exactly what is unavailable offline.
//
// The flagship assertion is the cross-function consistency check of SPEC-C-05 section 5 #1/#3:
// for `FakeRepo.demoFixture()`, every number the presenters produce must be field-by-field
// equal to what `HealthScoreService.score(...)` and `ReportService` computed.
//
// NOTE FOR EDITORS: this file contains Chinese text. PowerShell 5.1 reads BOM-less UTF-8 as the
// ANSI code page and destroys every CJK string on write, so edit it with a UTF-8-aware tool.

import 'dart:io';
import 'dart:typed_data';

import '../lib/core/errors.dart';
import '../lib/core/feature_config.g.dart' as cfg;
import '../lib/core/time.dart';
import '../lib/data/fake_repo.dart';
import '../lib/data/native/audio_bridge.dart';
import '../lib/domain/model/advice.dart';
import '../lib/domain/model/demo.dart';
import '../lib/domain/model/diet_record.dart';
import '../lib/domain/model/food_info.dart';
import '../lib/domain/model/health_score.dart';
import '../lib/domain/model/inference.dart';
import '../lib/domain/model/summaries.dart';
import '../lib/domain/service/advice_engine.dart';
import '../lib/domain/service/demo_controller.dart';
import '../lib/domain/service/detection_session.dart';
import '../lib/domain/service/food_knowledge_base.dart';
import '../lib/domain/service/handshake.dart';
import '../lib/domain/service/health_score_service.dart';
import '../lib/domain/service/inference_engine.dart';
import '../lib/domain/service/portion_estimator.dart';
import '../lib/domain/service/report_service.dart';
import '../lib/domain/service/score_formulas.dart';
import '../lib/presentation/presenters/detect_presenter.dart';
import '../lib/presentation/presenters/food_catalog.dart';
import '../lib/presentation/presenters/home_presenter.dart';
import '../lib/presentation/presenters/records_presenter.dart';
import '../lib/presentation/presenters/report_presenter.dart';
import '../lib/presentation/presenters/score_view.dart';
import '../lib/presentation/presenters/selfcheck_presenter.dart';
import '../lib/presentation/presenters/settings_presenter.dart';
import '../lib/presentation/presenters/ui_strings.dart';
import '../lib/presentation/state/app_services.dart';
import '../lib/presentation/state/async_value.dart';
import '../lib/presentation/theme/acou_format.dart';
import '../lib/presentation/theme/food_class.dart';

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
    check(name, '$actual' == '$expected', 'actual=$actual expected=$expected');

// --------------------------------------------------------------------------- fixtures

/// Reads `assets/**` straight off the file system, so the presentation layer can be exercised
/// without a Flutter binding (the same trick `tool/session_tests.dart` uses).
class FileAssetReader implements AssetReader {
  FileAssetReader(this.root);

  final String root;

  @override
  Future<Uint8List> readBytes(String path) async {
    final f = File('$root/$path');
    if (!f.existsSync()) throw Errors.asset(path, 'missing on disk');
    return f.readAsBytes();
  }

  @override
  Future<String> readString(String path) async {
    final f = File('$root/$path');
    if (!f.existsSync()) throw Errors.asset(path, 'missing on disk');
    return f.readAsString();
  }
}

/// A stable anchor day (2026-09-10 12:00 local). Both `FakeRepo`'s default base day and the
/// shipped `assets/demo_dataset.json` are anchored on 2026-09-10, so one constant covers both.
final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

/// The **real** knowledge base, loaded from `assets/foods.json` (P-08 shipped it).
///
/// The presentation layer never hard-codes a food name, an attribute, a portion description or
/// a kilocalorie, so neither does this runner: every expectation below is read back out of the
/// catalogue, which is exactly the property the UI has to preserve.
final FoodKnowledgeBase _kb = FoodKnowledgeBase();

FoodCatalog testCatalog() => KbFoodCatalog(_kb);

FoodInfo foodOf(int classId) => _kb.byClassId(classId);

/// The seven-local-day window every worked example uses.
DateRange weekRange() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

/// A record at a fixed local time on [dayOfWindow] (0 = the anchor day).
DietRecord rec(
  int dayOfWindow,
  int hour,
  int minute,
  int classId, {
  String? id,
  int durationSeconds = 300,
  double confidence = 0.82,
  bool correctedByUser = false,
  String source = 'real',
}) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOfWindow));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: id ?? 'r-$dayOfWindow-$hour-$minute-$classId',
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + durationSeconds * 1000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    // The attribute is snapshotted at write time (API-03 section 2); the fixture takes it from
    // the shipped knowledge base so the rendering path is the real one.
    attribute: _kb.byClassId(classId).attribute,
    confidence: confidence,
    durationSeconds: durationSeconds,
    source: source,
    correctedByUser: correctedByUser,
  );
}

FakeRepo repoOf(List<(DietRecord, BehaviorMetrics?)> items) => FakeRepo(
      records: items.map((e) => e.$1).toList(),
      metrics: items.map((e) => e.$2 ?? BehaviorMetrics.placeholder).toList(),
      baseDayMs: _anchorMs,
      kcalOverride: FakeRepo.defaultKcalTable,
    );

BehaviorMetrics met({double? interval = 0.7, int duration = 300, int? chew = 45}) =>
    BehaviorMetrics(
      chewCount: chew,
      avgChewIntervalSeconds: interval,
      durationSeconds: duration,
      speedGrade: interval == null ? null : '正常',
    );

// --------------------------------------------------------------------------- main

Future<void> main() async {
  print('=' * 78);
  print('AcouDiet L5 presentation-layer suite (pure presenters + state)');
  print('=' * 78);

  // The real knowledge base, straight off disk (no Flutter binding needed).
  final assets = FileAssetReader('.');
  await _kb.load(
    assetPath: 'assets/foods.json',
    jsonText: await assets.readString('assets/foods.json'),
  );

  _formatChecks();
  _foodClassAndCatalogChecks();
  await _crossFunctionConsistency();
  await _emptyStateChecks();
  _deltaThreeStateChecks();
  _chewCopyChecks();
  await _recordsChecks();
  _detectChecks();
  await _reportChecks();
  _settingsChecks();
  await _selfCheckChecks(assets);
  _stateLayerChecks();
  await _handshakeAndDemoChecks(assets);
  _bannedWordingChecks();

  print('');
  print('=' * 78);
  print('UI: $_passed passed, $_failed failed, ${_passed + _failed} total');
  if (_failed > 0) {
    print('FAILED CHECKS:');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  print('=' * 78);
  if (_failed > 0) {
    throw StateError('$_failed presentation-layer checks failed');
  }
}

// --------------------------------------------------------------------------- groups

void _formatChecks() {
  group('AcouFormat (SPEC-U-06 section 4.3)');

  // U-06 PLAN section 4 pins this exact string.
  eq('kcalRange(1250)', AcouFormat.kcalRange(1250), '估算能量参考 约 1000–1500 kcal');
  eq('kcalRange(1100)', AcouFormat.kcalRange(1100), '估算能量参考 约 880–1320 kcal');
  check(
      'the energy text matches the frozen shape',
      RegExp(r'^估算能量参考 约 \d+–\d+ kcal$').hasMatch(AcouFormat.kcalRange(1100)),
      AcouFormat.kcalRange(1100));
  eq('kcalLow rounds 0.8x', AcouFormat.kcalLow(999), (999 * 0.8).round());
  eq('kcalHigh rounds 1.2x', AcouFormat.kcalHigh(999), (999 * 1.2).round());
  check('the band never collapses to a point',
      AcouFormat.kcalLow(160) < AcouFormat.kcalHigh(160));

  eq('duration under a minute', AcouFormat.durationText(43), '43 秒');
  eq('duration over a minute', AcouFormat.durationText(263), '4 分 23 秒');
  eq('duration null is the empty marker', AcouFormat.durationText(null), '--');
  eq('percent rounds', AcouFormat.percent(0.876), '88%');
  eq('confidence text', AcouFormat.confidence(0.876), '置信度 88%');
  eq('chew count carries the about hedge (FF-21f)',
      AcouFormat.chewCountText(45), '约 45 次');
  eq('chew count null is the empty marker', AcouFormat.chewCountText(null), '--');
  eq('speed grade passthrough', AcouFormat.speedGradeText('偏快'), '偏快');
  eq('speed grade null', AcouFormat.speedGradeText(null), '--');

  // FF-20 thresholds come from the SSOT, so the boundaries are asserted against it.
  eq('tier at tauConfirm', AcouFormat.tierOf(cfg.FeatureConfig.votingTauConfirm),
      ConfidenceTier.high);
  eq('tier at tauLow', AcouFormat.tierOf(cfg.FeatureConfig.votingTauLow),
      ConfidenceTier.medium);
  eq('tier just below tauLow', AcouFormat.tierOf(cfg.FeatureConfig.votingTauLow - 0.001),
      ConfidenceTier.low);
  eq('tier above tauConfirm stays high', AcouFormat.tierOf(0.99), ConfidenceTier.high);

  eq('grade tone good', AcouFormat.gradeToneOf(HealthScore.gradeGood), GradeTone.good);
  eq('grade tone fair', AcouFormat.gradeToneOf(HealthScore.gradeFair), GradeTone.fair);
  eq('grade tone poor', AcouFormat.gradeToneOf(HealthScore.gradePoor), GradeTone.poor);

  final clockNoon = DateTime(2026, 9, 10, 9, 5).millisecondsSinceEpoch;
  eq('clock is zero padded HH:mm', AcouFormat.clock(clockNoon), '09:05');

  eq('today header',
      AcouFormat.dayGroupHeader(
          dayKey: '2026-09-10', todayKey: '2026-09-10', yesterdayKey: '2026-09-09'),
      '今天');
  eq('yesterday header',
      AcouFormat.dayGroupHeader(
          dayKey: '2026-09-09', todayKey: '2026-09-10', yesterdayKey: '2026-09-09'),
      '昨天');
  eq('older header',
      AcouFormat.dayGroupHeader(
          dayKey: '2026-09-03', todayKey: '2026-09-10', yesterdayKey: '2026-09-09'),
      '9月3日');

  eq('period delta is a difference, not a ratio',
      AcouFormat.periodDeltaText(-3, '次'), '-3 次');
  eq('period delta of zero is flat', AcouFormat.periodDeltaText(0, '分'), '持平');
  eq('period delta positive', AcouFormat.periodDeltaText(12, '分'), '+12 分');
}

void _foodClassAndCatalogChecks() {
  group('FF-19 food classes and the knowledge-base port');
  check('the six classes mirror the SSOT', FoodClassId.matchesFeatureConfig);
  eq('exactly six classes', FoodClassId.values.length, cfg.FeatureConfig.numClasses);
  eq('an unknown id has no class', FoodClassId.tryParse(6), null);
  // ADR-19: `noodles` is a delivered class now, so it can no longer stand in for "unknown".
  // `nuts` is the remaining reserved class and is the honest choice here.
  eq('a reserved-class label has no class', FoodClassId.tryParseLabel('nuts'), null);
  eq('an unknown label has no class', FoodClassId.tryParseLabel('pizza'), null);
  eq('chips attribute', FoodClassId.chips.kbAttribute, '脆性高加工零食');
  eq('gummies attribute', FoodClassId.gummies.kbAttribute, '黏弹性零食');
  eq('noodles attribute', FoodClassId.noodles.kbAttribute, '软性主食');
  eq('carrot attribute', FoodClassId.carrot.kbAttribute, '脆爽蔬菜');

  const empty = EmptyFoodCatalog();
  eq('an unloaded catalogue has no entry', empty.byClassId(3), null);
  eq('an unloaded catalogue is not loaded', empty.isLoaded, false);

  final catalog = testCatalog();
  check('the shipped catalogue resolves every class',
      List.generate(6, (i) => catalog.byClassId(i)).every((f) => f != null));
  eq('an out-of-range id stays null', catalog.byClassId(9), null);
  eq('the shipped catalogue is loaded', catalog.isLoaded, true);
  eq('the shipped catalogue has six entries', catalog.all.length,
      cfg.FeatureConfig.numClasses);
}

Future<void> _crossFunctionConsistency() async {
  group('SPEC-C-05 #1/#3 cross-function consistency (demo fixture)');

  final fixture = FakeRepo.demoFixture();
  final anchor = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: anchor);
  final range = DateRange(start, end);

  final score = await HealthScoreService(stats: fixture).score(range: range);
  final week = await fixture.week();
  final today = await fixture.today();
  final catalog = testCatalog();

  final home = HomeView.of(
    today: today,
    week: week,
    score: score,
    catalog: catalog,
    demoActive: true,
    recordsUnavailable: false,
  );

  // ---- the score card, field by field -------------------------------------------------
  eq('home total equals the service total', home.score.totalText, '${score.totalScore}');
  eq('home grade equals the service grade', home.score.gradeText, score.grade);
  eq('home delta equals the service delta (null here: yesterday is empty)',
      home.score.deltaVisible, score.deltaVsYesterday != null);
  eq('demo rows are flagged', home.demoActive && home.demoBadgeText == '演示数据', true);

  final dims = <String, DimensionScore>{
    'regularity': score.regularity,
    'structure': score.structure,
    'snack': score.snack,
    'speed': score.speed,
  };
  eq('four axes in the FF-22 order', home.score.axes.length, 4);
  eq('axis order', home.score.axes.map((a) => a.dimension).join(','),
      'regularity,structure,snack,speed');
  var axisMismatch = 0;
  for (final axis in home.score.axes) {
    final d = dims[axis.dimension]!;
    if (axis.label != d.label) axisMismatch++;
    if (axis.max != d.max) axisMismatch++;
    if (axis.score != d.score) axisMismatch++;
    if (axis.ratioText != '${d.label} ${d.score}/${d.max}') axisMismatch++;
    if (axis.formulaText != ScoreFormulas.formulaOf(axis.dimension)) axisMismatch++;
  }
  eq('every axis field equals the service value', axisMismatch, 0);

  // ---- every number embedded in the drill-down text -------------------------------------
  final drills = home.score.axes.map(DimensionDrillView.of).toList();
  var drillMismatch = 0;
  final drillDetail = <String>[];
  for (final drill in drills) {
    final d = dims[drill.dimension]!;
    if (drill.scoreText != '${d.score}/${d.max}') {
      drillMismatch++;
      drillDetail.add('${drill.dimension}:score');
    }
    if (drill.formulaText != ScoreFormulas.formulaOf(drill.dimension)) {
      drillMismatch++;
      drillDetail.add('${drill.dimension}:formula');
    }
    for (final line in drill.evidence) {
      final raw = d.evidence[line.key];
      final expected = _expectedEvidenceText(line.key, raw);
      if (line.text != expected) {
        drillMismatch++;
        drillDetail.add('${drill.dimension}.${line.key}:${line.text}!=$expected');
      }
    }
  }
  check('every drill-down number equals the domain evidence', drillMismatch == 0,
      drillDetail.join(' '));
  eq('the four drill rows sum to the displayed total',
      ReportPresenter.sumOfDimensions(drills), score.totalScore);
  check('the drill text reuses the single formula string',
      drills.every((d) => d.formulaText == ScoreFormulas.formulaOf(d.dimension)));

  // ---- the energy band and the week counter ---------------------------------------------
  eq('energy text is the ±20% band of TodaySummary.estimatedKcal', home.energy.displayText,
      '估算能量参考 ${AcouFormat.kcalRangeValue(today.estimatedKcal)}');
  eq('energy band low', AcouFormat.kcalLow(today.estimatedKcal),
      (today.estimatedKcal * 0.8).round());
  eq('week counter quotes WeekSummary.recordCount', home.week.text,
      '本周记录 ${week.recordCount} 次');
  eq('the demo fixture has four meals today', today.recordCount, 4);
  eq('the home list is truncated to three rows', home.todayCards.length, 3);
  eq('more than three rows offer the view-all affordance', home.showViewAll, true);

  // ---- the report page, field by field ---------------------------------------------------
  final reportService = ReportService(
    stats: fixture,
    scores: HealthScoreService(stats: fixture),
  );
  final report = await reportService.weekly(range: range);
  final trend = await reportService.trend(days: 7);

  final reportView = ReportView.of(
    score: report.score,
    summaryText: report.summaryText,
    deltas: report.deltas,
    advices: report.advices,
    trendPoints: trend.points,
    agg: week,
    demoActive: true,
  );

  eq('report total equals the service total',
      reportView.score.totalText, '${report.score.totalScore}');
  eq('home and report agree on the total',
      reportView.score.totalText, home.score.totalText);
  eq('home and report agree on the grade',
      reportView.score.gradeText, home.score.gradeText);
  eq('report summary is the service sentence', reportView.summaryText, report.summaryText);
  eq('the demo badge is present on the report view', reportView.demoBadgeText, '演示数据');

  var deltaMismatch = 0;
  for (final row in reportView.deltas) {
    final raw = report.deltas[row.key];
    if (raw == null || row.value != raw) deltaMismatch++;
  }
  eq('all seven deltas carry the service value', deltaMismatch, 0);
  eq('the delta rows are exactly the seven frozen keys',
      reportView.deltas.map((d) => d.key).join(','), WeeklyReport.deltaKeys.join(','));
  eq('the report drills are the same four rows',
      reportView.drills.map((d) => d.ratioLine).join('|'),
      drills.map((d) => d.ratioLine).join('|'));
  eq('the disclaimer text is the single frozen definition',
      reportView.disclaimerText, AdviceEngine.disclaimerText);

  // ---- the trend series ------------------------------------------------------------------
  eq('the trend has exactly seven slots', reportView.trendScore.days, 7);
  eq('the kcal series has the same slot count', reportView.trendKcal.days, 7);
  check('the trend is ascending and gapless',
      reportView.trendScore.shape.ascending && reportView.trendScore.shape.gapless);
  eq('the demo fixture fills every day', reportView.trendScore.filledCount, 7);
  eq('a filled day equals the service value', reportView.trendKcal.points.last.value!.round(),
      trend.points.last.estimatedKcal);
  eq('the score series is filled by L4', reportView.trendScore.points.last.value!.round(),
      trend.points.last.totalScore);
}

/// Independent re-derivation of the four evidence formats (API-04 section 3 + U-06 section 4.3).
String _expectedEvidenceText(String key, Object? raw) {
  if (raw == null) return '--';
  switch (key) {
    case 'sigmaMinutes':
      return '${(raw as num).toStringAsFixed(1)} 分钟';
    case 'avgChewIntervalSeconds':
      return '${(raw as num).toStringAsFixed(1)} 秒';
    case 'healthyRatio':
      return '${((raw as num) * 100).round()}%';
    default:
      return '$raw';
  }
}

Future<void> _emptyStateChecks() async {
  group('SPEC-A-01 section 4 `--` rules');

  // sigma is null (no meal class has two samples) and every metric row is a placeholder.
  final thin = repoOf([
    (rec(1, 7, 0, 3), BehaviorMetrics.placeholder),
    (rec(2, 12, 0, 4), BehaviorMetrics.placeholder),
    (rec(3, 18, 0, 0), BehaviorMetrics.placeholder),
    for (var i = 1; i <= 5; i++) (rec(i, 15, 40, 0), BehaviorMetrics.placeholder),
  ]);
  final score = await HealthScoreService(stats: thin).score(range: weekRange());
  eq('sigmaMinutes is null in this fixture', score.regularity.evidence['sigmaMinutes'], null);
  eq('avgChewIntervalSeconds is null in this fixture',
      score.speed.evidence['avgChewIntervalSeconds'], null);

  final view = ScoreView.of(score);
  eq('the total is hidden', view.totalText, '--');
  eq('the grade is hidden', view.gradeText, '--');
  eq('the delta row is hidden too', view.deltaVisible, false);
  final regularity = view.axes.firstWhere((a) => a.dimension == 'regularity');
  final speed = view.axes.firstWhere((a) => a.dimension == 'speed');
  final structure = view.axes.firstWhere((a) => a.dimension == 'structure');
  eq('regularity is not displayable', regularity.displayable, false);
  eq('regularity renders the empty marker', regularity.ratioText, '饮食规律性 --');
  eq('the empty axis collapses to the radar centre', regularity.radarValue, 0.0);
  eq('speed is not displayable', speed.displayable, false);
  eq('structure still has a basis (records exist)', structure.displayable, true);
  check('the semantics string carries the empty marker',
      view.semanticsText.contains('--'), view.semanticsText);

  // An entirely empty library: nothing at all is displayable.
  final emptyRepo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final emptyScore = await HealthScoreService(stats: emptyRepo).score(range: weekRange());
  final emptyView = ScoreView.of(emptyScore);
  eq('an empty library hides every number',
      emptyView.axes.every((a) => !a.displayable), true);
  eq('an empty library hides the total', emptyView.totalText, '--');

  // The home page's energy and list rows.
  final emptyToday = await emptyRepo.today();
  final home = HomeView.of(
    today: emptyToday,
    week: await emptyRepo.week(),
    score: emptyScore,
    catalog: testCatalog(),
  );
  eq('energy is the empty word with no records', home.energy.displayText, '暂无数据');
  eq('energy has no data flag', home.energy.hasData, false);
  eq('the week counter shows a real zero, not the empty marker', home.week.text,
      '本周记录 0 次');
  eq('the today list is empty', home.todayCards.isEmpty, true);
  eq('the list copy is the frozen sentence', home.todayRecordsEmptyText, '今天还没有记录');

  // A failed region must not be reported as zero either.
  final failedHome = HomeView.of(
    today: null,
    week: null,
    score: null,
    catalog: testCatalog(),
    recordsUnavailable: true,
  );
  eq('a failed score region degrades to the empty markers',
      failedHome.score.totalText, '--');
  eq('a failed score region keeps the four axis labels',
      failedHome.score.axes.length, 4);
  check('a failed score region does not claim a grade',
      failedHome.score.gradeText == '--');
  eq('a failed week region shows the empty marker', failedHome.week.text, '本周记录 -- 次');
  eq('a failed list region shows the retry copy',
      failedHome.todayRecordsEmptyText, '暂时无法读取记录');
  eq('an unavailable score is marked as such', failedHome.scoreUnavailable, true);

  // The records page summary on an empty day keeps three real zeros.
  final summary = RecordsSummaryView.of(emptyToday);
  eq('the summary bar keeps three zeros', summary.barText, '估算 0 kcal / 0 次 / 0 次');
  eq('an unavailable aggregate is not zeroed',
      RecordsSummaryView.unknown.barText, '-- / -- / --');

  // The trend presenter keeps null for a day without records.
  final gapRepo = FakeRepo(
    records: [rec(0, 7, 0, 3), rec(2, 12, 0, 4)],
    metrics: [met(), met()],
    baseDayMs: _anchorMs,
    kcalOverride: FakeRepo.defaultKcalTable,
  );
  final series = await ReportService(
    stats: gapRepo,
    scores: HealthScoreService(stats: gapRepo),
  ).trend(days: 7);
  final chart = TrendChartData.of(series.points, ChartAxis.kcal);
  eq('the chart keeps seven slots', chart.days, 7);
  eq('only the two days with records are filled', chart.filledCount, 2);
  final gap = chart.points.firstWhere((p) => !p.hasValue);
  eq('an empty day keeps null (never zero)', gap.value, null);
  eq('an empty day reads the no-data word', gap.valueText, '无数据');
  check('the text equivalent says there is no data',
      chart.textEquivalent.contains('无数据'), chart.textEquivalent);
  eq('the weekday label is derived from the date key',
      AcouFormat.weekdayLabel(chart.points.first.date).startsWith('周'), true);
  final allEmpty = TrendChartData.of(const <TrendPoint>[], ChartAxis.score);
  eq('an all-empty series has no value', allEmpty.hasAnyValue, false);
  eq('an all-empty series still matches the requested length', allEmpty.days, 0);
}

void _deltaThreeStateChecks() {
  group('ADR-10 three-state delta');

  final base = ScoreFormulas.compute(const ScoreInputs(
    sigmaMinutes: 0,
    mealTimeSamples: 6,
    classCounts: {'chips': 0, 'cabbage': 2, 'gummies': 0, 'noodles': 2, 'carrot': 2, 'drink': 0},
    recordCount: 6,
    snackCount: 0,
    lateNightCount: 0,
    avgChewIntervalSeconds: 0.8,
    sampleCount: 6,
    missingMetricsCount: 0,
    windowDays: 7,
  ));
  HealthScore withDelta(int? d) => HealthScore(
        totalScore: base.totalScore,
        grade: base.grade,
        regularity: base.regularity,
        structure: base.structure,
        snack: base.snack,
        speed: base.speed,
        deltaVsYesterday: d,
      );

  eq('null hides the row', AcouFormat.deltaText(null), null);
  eq('zero shows the flat word', AcouFormat.deltaText(0), '持平');
  eq('positive is signed up', AcouFormat.deltaText(12), '↑12 分');
  eq('negative is signed down', AcouFormat.deltaText(-3), '↓3 分');

  final hidden = ScoreView.of(withDelta(null));
  eq('a null delta hides the row', hidden.deltaVisible, false);
  eq('a null delta renders nothing', hidden.deltaText, null);
  check('the semantics string omits the delta',
      !hidden.semanticsText.contains('持平'), hidden.semanticsText);

  final flat = ScoreView.of(withDelta(0));
  eq('a zero delta keeps the row visible', flat.deltaVisible, true);
  eq('a zero delta shows the flat word', flat.deltaText, '持平');
  check('the semantics string says the tie out loud',
      flat.semanticsText.contains('与上一周期持平'), flat.semanticsText);

  // ADR-23: one bowl of noodles must not saturate 食物结构 at 30/30. A single record with a
  // 100% healthy ratio used to read as a perfect structure; the axis is now undetermined until
  // the window holds the page-level minimum of records.
  final thin = ScoreFormulas.compute(const ScoreInputs(
    sigmaMinutes: null,
    mealTimeSamples: 0,
    classCounts: {'chips': 0, 'cabbage': 0, 'gummies': 0, 'noodles': 1, 'carrot': 0, 'drink': 0},
    recordCount: 1,
    snackCount: 0,
    lateNightCount: 0,
    avgChewIntervalSeconds: null,
    sampleCount: 0,
    missingMetricsCount: 1,
    windowDays: 1,
  ));
  final thinView = ScoreView.of(thin);
  final thinStructure = thinView.axes.firstWhere((a) => a.dimension == 'structure');
  eq('one record of noodles still scores 30/30 in the kernel (the frozen formula)',
      thin.structure.score, 30);
  eq('but the card refuses to present it as a structure', thinStructure.displayable, false);
  eq('and the row renders the empty marker', thinStructure.scoreText, AcouFormat.noValue);
  final enoughView = ScoreView.of(base);
  eq('with enough records the structure axis is presented',
      enoughView.axes.firstWhere((a) => a.dimension == 'structure').displayable, true);

  // ADR-23: the window is seven days, and the caption names the inputs behind the four bars so
  // 「零食控制 20/20」 reads as "no snacks" instead of as an unexplained maximum.
  check('the score semantics name the seven-day window',
      flat.semanticsText.contains(UiStrings.scoreWindowLabel), flat.semanticsText);
  eq('the home score card is titled for its window',
      UiStrings.scoreCardTitle, '近 7 天健康评分');
  check('the input caption names the record and snack counts',
      flat.inputCaption.contains('记录 ') &&
          flat.inputCaption.contains('零食 ') &&
          flat.inputCaption.contains('有咀嚼指标 '),
      flat.inputCaption);
  eq('an unavailable score has no input caption', ScoreView.unavailable().inputCaption, '');

  final up = ScoreView.of(withDelta(12));
  eq('a positive delta is signed', up.deltaText, '↑12 分');
  check('the semantics string carries the signed delta',
      up.semanticsText.contains('↑12 分'), up.semanticsText);
  eq('the delta row helper agrees', HomePresenter.deltaRow(up).visible, true);
  eq('the delta row helper is hidden when null',
      HomePresenter.deltaRow(hidden).visible, false);
}

void _chewCopyChecks() {
  group('FF-21f / FF-21g chew copy');
  eq('FF-21f keeps the about hedge', RecordsPresenter.chewText(45), '约 45 次');
  eq('a missing count is the empty marker', RecordsPresenter.chewText(null), '--');
  eq('FF-21g degraded copy is verbatim',
      RecordsPresenter.chewText(45, degraded: true), '咀嚼节奏：较快');
  check('the degraded copy carries no digit',
      RecordsPresenter.hasNoDigits(RecordsPresenter.chewText(45, degraded: true)));
  check('the degraded copy carries no digit on the detection page too',
      !RegExp(r'\d').hasMatch(DetectPresenter.chewText(45, degraded: true)));
  eq('the detection page uses the same rule', DetectPresenter.chewText(null), '--');
  eq('the interval keeps one decimal', RecordsPresenter.intervalText(0.7), '0.7 秒');
  eq('a null interval is the empty marker', RecordsPresenter.intervalText(null), '--');

  final behavior = RecordBehaviorView.of(met(interval: 0.7, chew: 45, duration: 300));
  eq('the behaviour block reads about-45', behavior.chewText, '约 45 次');
  eq('the behaviour block reads the interval', behavior.intervalText, '0.7 秒');
  eq('the behaviour block reads the duration', behavior.durationText, '5 分 0 秒');
  eq('the behaviour block reads the grade', behavior.speedText, '正常');
  final degraded = RecordBehaviorView.of(met(interval: null, chew: null), degraded: true);
  eq('the degraded block uses the digit-free copy', degraded.chewText, '咀嚼节奏：较快');
  eq('the degraded block still fills the interval as empty', degraded.intervalText, '--');
  final placeholder = RecordBehaviorView.of(BehaviorMetrics.placeholder);
  eq('a placeholder row renders four empty markers',
      '${placeholder.chewText}|${placeholder.intervalText}|'
      '${placeholder.durationText}|${placeholder.speedText}',
      '--|--|--|--');
}

Future<void> _recordsChecks() async {
  group('U-03 records timeline');

  final catalog = testCatalog();
  // 23:59 and 00:01 must land in different groups; a demo row carries the badge.
  final records = <DietRecord>[
    rec(0, 23, 59, 3, id: 'late'),
    rec(1, 0, 1, 4, id: 'early'),
    rec(1, 12, 20, 3, id: 'noon', confidence: 0.876, correctedByUser: true, source: 'demo'),
  ];
  final repo = FakeRepo(records: records, baseDayMs: _anchorMs);
  final today = await repo.today();
  final view = RecordsView.of(
    records: await repo.byRange(weekRange()),
    today: today,
    summaryText: 'fixture-summary',
    catalog: catalog,
    nowMs: _anchorMs,
  );

  eq('three cards survive grouping',
      view.groups.fold<int>(0, (n, g) => n + g.records.length), 3);
  eq('two local calendar days', view.groups.length, 2);
  eq('the newest group is first', view.groups.first.dayKey, TimeUtil.dayKey(_anchorMs));
  eq('the first header is today', view.groups.first.header, '今天');
  eq('the second header is yesterday', view.groups[1].header, '昨天');
  check('23:59 and 00:01 are split across groups',
      view.groups.map((g) => g.dayKey).toSet().length == 2);

  // Order inside a group must be exactly the repository order (ASC), never re-sorted.
  final orderedRepo = FakeRepo(
    records: [rec(1, 12, 20, 3, id: 'ctx'), rec(1, 0, 1, 4, id: 'ctx2')],
    baseDayMs: _anchorMs,
  );
  final ordered = RecordsView.of(
    records: await orderedRepo.byRange(weekRange()),
    today: null,
    summaryText: null,
    catalog: catalog,
    nowMs: _anchorMs,
  );
  final rawOrder = await orderedRepo.byRange(weekRange());
  eq('the in-group order follows the repository (ASC)',
      ordered.groups.single.records.map((r) => r.record.recordId).join(','),
      rawOrder.map((r) => r.recordId).join(','));
  eq('and that order really is ascending by time',
      rawOrder.first.eatenAtMs < rawOrder.last.eatenAtMs, true);
  eq('a failed summary degrades to the frozen copy',
      ordered.weekSummaryText, RecordsView.weekSummaryFallback);
  eq('a failed summary flag also degrades the real summary',
      RecordsView.of(
        records: const <DietRecord>[],
        today: null,
        summaryText: '本周记录 3 次，零食 1 次',
        summaryUnavailable: true,
        catalog: catalog,
        nowMs: _anchorMs,
      ).weekSummaryText,
      RecordsView.weekSummaryFallback);

  // The frozen three-line template. ADR-23: the portion and the kilocalories are now derived
  // from **this record's** duration, so the expectations are computed from the same estimator
  // the card uses -- and the estimator itself is pinned by its own group below.
  final noodles = foodOf(3);
  final noon = view.groups
      .expand((g) => g.records)
      .firstWhere((c) => c.record.recordId == 'noon');
  final noonPortion =
      PortionEstimator.of(noodles, durationSeconds: noon.record.durationSeconds);
  eq('row 1 left is HH:mm', noon.timeText, '12:20');
  eq('row 1 centre is the knowledge-base name', noon.foodName, noodles.zhName);
  eq('row 1 right is the per-record estimate badge', noon.kcalBadge,
      '≈${noonPortion.kcal} kcal');
  eq('row 2 is attribute · estimated amount（估算）', noon.estimateLine,
      '${noodles.attribute} · ${noonPortion.amountText}（估算）');
  eq('row 3 is the confidence', noon.confidenceText, '置信度 88%');
  check('the estimate line carries the estimate marker',
      noon.estimateLine.contains(AcouFormat.estimateMarker));
  check('the combined text carries the portion and the estimate marker',
      noon.estimateWithKcal.contains('${noonPortion.amountText}（估算）') &&
          noon.estimateWithKcal.contains('≈${noonPortion.kcal} kcal'),
      noon.estimateWithKcal);
  eq('a demo row carries the demonstration badge', noon.sourceBadge, '演示数据');
  eq('a real row carries no badge',
      view.groups.first.records.first.sourceBadge, '');
  eq('ADR-P6 makes the confirmed badge available', noon.showConfirmedBadge, true);

  // A record the knowledge base cannot resolve degrades without inventing anything.
  final orphan = RecordsView.cardOf(rec(0, 8, 0, 3, id: 'orphan'), const EmptyFoodCatalog());
  eq('an unloaded knowledge base yields the placeholder name',
      orphan.foodName, UiStrings.unknownCategory);
  eq('an unresolved record has no kilocalorie badge', orphan.kcalBadge, '');
  eq('an unresolved record has no portion line', orphan.estimateLine, '');
  eq('an unresolved record is marked as such', orphan.hasKnowledge, false);

  // The summary bar keeps the estimate word and the contract shape.
  final summary = RecordsSummaryView.of(today);
  eq('the bar is built from TodaySummary', summary.barText,
      '估算 ${today.estimatedKcal} kcal / ${today.recordCount} 次 / ${today.snackCount} 次');
  check('the bar matches the frozen shape',
      RegExp(r'\d+ kcal / \d+ 次 / \d+ 次').hasMatch(summary.barText));
  check('the bar carries the estimate word', summary.barText.contains('估算'));

  // The detail page.
  final detail = RecordDetailView.of(
    record: noon.record,
    food: noon.food,
    metrics: met(interval: 0.7, chew: 45, duration: 263),
    timeText: noon.timeText,
    confidenceText: noon.confidenceText,
  );
  eq('detail shows the confirmed badge only', detail.confirmedText, '已确认');
  eq('detail shows the standard portion', detail.portionText, noodles.portionDesc);
  eq('detail shows this record\'s estimated amount', detail.amountText,
      noonPortion.amountText);
  eq('detail shows the estimated kilocalories', detail.kcalText,
      '估算 ${noonPortion.kcal} kcal');
  eq('detail shows the chew count with the hedge', detail.behavior.chewText, '约 45 次');
  eq('detail shows the duration', detail.behavior.durationText, '4 分 23 秒');
  eq('the knowledge block states its origin', detail.knowledgeOriginNote,
      '来自食物知识库估算，非模型输出');
  eq('the detail view exposes the knowledge tags in its own block',
      detail.nutritionTags, noodles.nutritionTags);
  final unconfirmed = RecordDetailView.of(
    record: rec(0, 8, 0, 3, id: 'u'),
    food: noodles,
    metrics: BehaviorMetrics.placeholder,
    timeText: '08:00',
    confidenceText: AcouFormat.confidence(0.5),
  );
  eq('an auto-confirmed record shows the empty marker', unconfirmed.confirmedText, '--');
  final orphanDetail = RecordDetailView.of(
    record: rec(0, 8, 0, 3, id: 'o2'),
    food: null,
    metrics: null,
    timeText: '08:00',
    confidenceText: AcouFormat.confidence(0.5),
  );
  eq('an unresolved detail hides the portion', orphanDetail.portionText, '');
  eq('an unresolved detail hides the kilocalories', orphanDetail.kcalText, '');
  eq('an unresolved detail hides the risk note', orphanDetail.riskNote, '');
}

void _detectChecks() {
  group('U-02 detection page');

  final catalog = testCatalog();
  final noodles = foodOf(3);
  final observing = AggregatedDecision(
    stage: VoteStage.observing,
    classId: 0,
    label: 'chips',
    smoothedConfidence: 0.62,
    consecutiveCount: 2,
    shouldAskUser: false,
  );
  final grey = DetectPresenter.predictionOf(observing, catalog: catalog);
  // ADR-24 / SPEC-U-02 section 4: the card shows the **knowledge-base name**, not the frozen
  // FF-19 token. `decision.label` is `chips`; `FoodInfo.zhName` is `薯片`, and U-06 section 2.4
  // forbids showing the raw token.
  eq('a forming EMA shows the grey chip', grey.text, '薯片 62%');
  eq('the grey chip is not the result card', grey.confirmed, false);

  final lowConfidence = AggregatedDecision(
    stage: VoteStage.lowConfidence,
    classId: 0,
    label: 'chips',
    smoothedConfidence: 0.55,
    consecutiveCount: 3,
    shouldAskUser: true,
  );
  final ask = DetectPresenter.predictionOf(lowConfidence, catalog: catalog);
  eq('the low-confidence stage asks the user', ask.text, '疑似 薯片，请确认？');
  eq('shouldAskUser propagates', ask.shouldAskUser, true);

  // `observing` with a formed EMA below tauLow is the "no clear food" case (API-02 section 9).
  final below = AggregatedDecision(
    stage: VoteStage.observing,
    classId: 0,
    label: 'chips',
    smoothedConfidence: cfg.FeatureConfig.votingTauLow - 0.01,
    consecutiveCount: 1,
    shouldAskUser: false,
  );
  eq('a formed EMA below tauLow says no clear food',
      DetectPresenter.predictionOf(below, catalog: catalog).text, '未识别到明确食物');

  final unconfirmed = AggregatedDecision(
    stage: VoteStage.unconfirmed,
    classId: 0,
    label: 'chips',
    smoothedConfidence: 0.75,
    consecutiveCount: 3,
    shouldAskUser: false,
  );
  eq('an unconfirmed prediction keeps the grey chip',
      DetectPresenter.predictionOf(unconfirmed, catalog: catalog).text, '薯片 75%');

  final confirmed = AggregatedDecision(
    stage: VoteStage.confirmed,
    classId: 0,
    label: 'chips',
    smoothedConfidence: 0.91,
    consecutiveCount: 4,
    shouldAskUser: false,
  );
  final card = DetectPresenter.predictionOf(confirmed, catalog: catalog);
  eq('the result card carries the three elements', card.text, '薯片 / 91% / 脆性高加工零食');
  eq('the attribute comes from the knowledge base', card.attributeText, '脆性高加工零食');
  check('the semantics string reads the card out',
      card.semanticsText.contains('置信度 91%'), card.semanticsText);
  eq('a confirmed card is not the grey form', card.confirmed, true);

  // The card holds its previous state instead of flickering back (criterion 6).
  final held = DetectPresenter.predictionOf(unconfirmed, heldConfirmed: card, catalog: catalog);
  eq('a lower-confidence patch keeps the result card', held.text, card.text);
  eq('a lower-confidence patch keeps the confirmed flag', held.confirmed, true);
  final heldAtNone = DetectPresenter.predictionOf(
    AggregatedDecision.idle,
    heldConfirmed: card,
    catalog: catalog,
  );
  eq('the none stage keeps the held card', heldAtNone.text, card.text);
  eq('without a held card the none stage senses',
      DetectPresenter.predictionOf(AggregatedDecision.idle, catalog: catalog).text, '正在感知…');

  eq('the progress line uses the SSOT denominator', DetectPresenter.progressText(confirmed),
      '连续一致 4/${cfg.FeatureConfig.votingConfirmConsecutivePatches} 个窗口');

  eq('idle status', DetectPresenter.statusText(DetectUiState.idle), '等待进食声…');
  eq('starting status waits for the first sound',
      DetectPresenter.statusText(DetectUiState.starting), '等待进食声…');
  eq('listening status still waits for the first sound',
      DetectPresenter.statusText(DetectUiState.listening), '等待进食声…');
  eq('an arriving patch switches to the sensing sentence',
      DetectPresenter.statusText(DetectUiState.unconfirmed), '正在感知进食声音…');
  eq('asking the user keeps the sensing sentence',
      DetectPresenter.statusText(DetectUiState.askingUser), '正在感知进食声音…');
  eq('ended status', DetectPresenter.statusText(DetectUiState.ended), '已结束');

  // FF-20a wording.
  eq('the first-confirmation hint is the frozen wording', DetectPresenter.firstConfirmHint,
      '从开始进食到首次确认结果约 4–5 秒');
  check('the hint mentions the 4–5 second window',
      DetectPresenter.firstConfirmHint.contains('4–5 秒'));

  // Behaviour rows and badges.
  final behavior = DetectBehaviorView.of(met(interval: 0.7, chew: 45, duration: 263));
  eq('the four behaviour values are joined', behavior.combinedText,
      '约 45 次 / 0.7 秒 / 4 分 23 秒 / 正常');
  eq('a missing metric set is four empty markers', DetectBehaviorView.empty.combinedText,
      '-- / -- / -- / --');
  eq('the injection badge follows patch.source only',
      DetectPresenter.injectionBadge(DetectUiState.listening, injected: true), '示例演示');
  eq('no injection badge without an injected patch',
      DetectPresenter.injectionBadge(DetectUiState.listening, injected: false), '');
  eq('the injection badge is absent when idle',
      DetectPresenter.injectionBadge(DetectUiState.idle, injected: true), '');

  final savedRecord = rec(0, 12, 20, 3, id: 'saved');
  final savedPortion =
      PortionEstimator.of(noodles, durationSeconds: savedRecord.durationSeconds);
  final saved = DetectPresenter.savedBanner(savedRecord, noodles);
  check('the saved banner says it recorded automatically', saved.contains('已自动记录'), saved);
  check('the saved banner carries the estimate wording',
      saved.contains('（估算）') && saved.contains('≈${savedPortion.kcal} kcal'), saved);
  check('the saved banner quotes the per-record amount, not the standard portion',
      saved.contains(savedPortion.amountText) &&
          !saved.contains(noodles.portionDesc),
      saved);
  eq('no saved banner before a record exists',
      DetectPresenter.savedBanner(null, null), '');

  eq('a retryable microphone failure keeps its sentence',
      DetectPresenter.errorText(AcouDietError(
          Codes.audioRecordInitFailed, '麦克风初始化失败，请重试',
          retryable: true)),
      '麦克风初始化失败，请重试');
  eq('a permanent permission rejection offers settings',
      DetectPresenter.permissionActionLabel(
          AcouDietError(Codes.permPermanentlyDenied, '需要录音权限才能开始检测')),
      '去设置');
  eq('a plain rejection offers a retry',
      DetectPresenter.permissionActionLabel(
          AcouDietError(Codes.permDenied, '需要录音权限才能开始检测')),
      '授权');

  eq('the button label while listening',
      DetectPresenter.primaryActionLabel(DetectUiState.listening), '停止检测');
  eq('the button label after the session',
      DetectPresenter.primaryActionLabel(DetectUiState.ended), '再次检测');
  eq('the button label before the session',
      DetectPresenter.primaryActionLabel(DetectUiState.idle), '开始 AI 检测');
  // SPEC-U-02 section 2.3: `confirmed` and `ending` are running states. The result card must not
  // turn into a second start button while the AudioRecord behind it is still open -- the native
  // side admits one session (maxConcurrentSessions = 1) and would refuse the start, stranding
  // the live session with no way left to stop it.
  eq('the confirmed card keeps the stop button',
      DetectPresenter.primaryActionLabel(DetectUiState.confirmed), '停止检测');
  eq('the ending state keeps the stop button',
      DetectPresenter.primaryActionLabel(DetectUiState.ending), '停止检测');
  final stopStates =
      DetectUiState.values.where(DetectPresenter.primaryActionIsStop).toList();
  check(
      'exactly the five running states stop the session',
      stopStates.length == 5 &&
          stopStates.toSet().containsAll(<DetectUiState>{
            DetectUiState.listening,
            DetectUiState.unconfirmed,
            DetectUiState.confirmed,
            DetectUiState.askingUser,
            DetectUiState.ending,
          }),
      stopStates.join(','));
  check(
      'the stop predicate never disagrees with the label',
      DetectUiState.values.every((s) =>
          DetectPresenter.primaryActionIsStop(s) ==
          (DetectPresenter.primaryActionLabel(s) == '停止检测')));

  // The session timeline row.
  final timeline = DetectTimelineView.of(SessionSummary({
    'startedAtMs': DateTime(2026, 9, 10, 12, 0).millisecondsSinceEpoch,
    'stoppedAtMs': DateTime(2026, 9, 10, 12, 4).millisecondsSinceEpoch,
    'patchesEmitted': 8,
    'endReason': 'userStop',
  }));
  eq('the timeline shows the start', timeline.startedText, '12:00');
  eq('the timeline shows the end', timeline.endedText, '12:04');
  eq('the timeline shows the patch count', timeline.patchesText, '8');
  eq('an idle timeline is all empty markers', DetectTimelineView.empty.startedText, '--');
  eq('the silence end reason is worded', DetectTimelineView.of(SessionSummary({
    'startedAtMs': 0,
    'stoppedAtMs': 1,
    'endReason': 'silence',
  })).endReasonText, '静默结束');
}

Future<void> _reportChecks() async {
  group('U-04 report page');

  final fixture = FakeRepo.demoFixture();
  final anchor = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: anchor);
  final range = DateRange(start, end);
  final service = ReportService(stats: fixture, scores: HealthScoreService(stats: fixture));
  final report = await service.weekly(range: range);
  final trend = await service.trend(days: 7);
  final agg = await fixture.week();

  final view = ReportView.of(
    score: report.score,
    summaryText: report.summaryText,
    deltas: report.deltas,
    advices: report.advices,
    trendPoints: trend.points,
    agg: agg,
    demoActive: true,
  );

  eq('the drill rows match `label score/max`', view.drills.length, 4);
  check('every drill row matches the frozen shape',
      view.drills.every((d) => RegExp(r'\S+ \d+/\d+').hasMatch(d.ratioLine)),
      view.drills.map((d) => d.ratioLine).join(' | '));
  check('the drill rows expose the shared formula, not a second copy',
      view.drills.every((d) => d.formulaText == ScoreFormulas.formulaOf(d.dimension)));
  check('every drill row carries its evidence lines',
      view.drills.every((d) => d.evidence.isNotEmpty));

  eq('the delta rows are seven', view.deltas.length, 7);
  eq('a zero delta renders the flat word',
      view.deltas.firstWhere((d) => d.value == 0).text, '持平');
  final kcalRow = view.deltas.firstWhere((d) => d.key == 'estimatedKcal');
  check('the kilocalorie delta keeps the estimate wording',
      kcalRow.text.contains('估算'), kcalRow.text);
  final countRow = DeltaRowView.of('recordCount', 4);
  check('the record-count delta uses the count unit', countRow.text.contains('次'), countRow.text);
  eq('a real record-count delta is signed', countRow.text, '+4 次');
  eq('a zero record-count delta is the flat word',
      DeltaRowView.of('recordCount', 0).text, '持平');
  eq('a negative total delta is signed', DeltaRowView.of('totalScore', -4).text, '-4 分');
  eq('the delta labels are Chinese', view.deltas.first.label, '总分');
  eq('the delta rows keep the frozen key order',
      view.deltas.map((d) => d.key).join(','), WeeklyReport.deltaKeys.join(','));

  eq('the summary is the service sentence', view.summaryText, report.summaryText);
  eq('the report is not in the insufficient state', view.insufficient, false);

  // ADR-23 -- the per-day four-dimension list.
  final daily = await service.dailyScores(days: 7);
  final dailyView = ReportView.of(
    score: report.score,
    summaryText: report.summaryText,
    deltas: report.deltas,
    advices: report.advices,
    trendPoints: trend.points,
    dailyScores: daily,
    agg: agg,
  );
  check('the daily list only carries the days with records',
      dailyView.dailyScores.every((d) => d.hasData),
      '${dailyView.dailyScores.length} of ${daily.length}');
  var newestFirst = true;
  for (var i = 1; i < dailyView.dailyScores.length; i++) {
    if (dailyView.dailyScores[i - 1].date.compareTo(dailyView.dailyScores[i].date) <= 0) {
      newestFirst = false;
    }
  }
  check('the daily list is newest first', newestFirst,
      dailyView.dailyScores.map((d) => d.date).join(','));
  check('every daily card carries four labelled rows',
      dailyView.dailyScores.every((d) => d.rows.length == 4),
      '${dailyView.dailyScores.first.rows}');
  eq('a daily card opens with the four frozen dimension labels',
      dailyView.dailyScores.first.rows.map((r) => r.$1).join(','),
      ScoreFormulas.labelRegularity + ',' + ScoreFormulas.labelStructure + ',' +
          ScoreFormulas.labelSnack + ',' + ScoreFormulas.labelSpeed);
  check('a daily card dates itself in words',
      RegExp(r'\d+月\d+日').hasMatch(dailyView.dailyScores.first.dateLabel),
      dailyView.dailyScores.first.dateLabel);
  check('the daily semantics list the four dimensions',
      dailyView.dailyScores.first.semanticsText.contains('四维评分'));
  // ADR-23: the 每日 scope is a full day report, not only four numbers.
  final firstDay = dailyView.dailyScores.first;
  check('a daily card carries the day summary rows',
      firstDay.countText.endsWith('次') &&
          firstDay.snackText.endsWith('次') &&
          firstDay.kcalText.isNotEmpty,
      '${firstDay.countText} / ${firstDay.kcalText} / ${firstDay.snackText}');
  check('a daily card names the day\'s food classes',
      firstDay.classSummary.contains('×'),
      firstDay.classSummary);
  final classCounts = RegExp(r'×(\d+)')
      .allMatches(firstDay.classSummary)
      .map((m) => int.parse(m.group(1)!))
      .toList();
  var classSummaryOrdered = true;
  for (var i = 1; i < classCounts.length; i++) {
    if (classCounts[i - 1] < classCounts[i]) classSummaryOrdered = false;
  }
  check('the class summary is ordered by count, biggest first', classSummaryOrdered,
      firstDay.classSummary);
  check('every daily card exposes a ScoreView for the card and the drill-down',
      dailyView.dailyScores.every((d) => d.scoreView.axes.length == 4));

  // ADR-25 -- the bug the user reported: 「报告那里当日四维评分的分数和评价都没有」. Before the fix
  // the 每日 card rendered `--` for BOTH the total and the grade on **every** day, because a single
  // calendar day cannot define σ (it needs two samples of the same meal) and the total is gated on
  // all four axes. The day the page opens on is the newest one, so that is the assertion that
  // matches the report.
  final newestDay = dailyView.dailyScores.first;
  check('ADR-25: the day the report opens on shows a real score and grade, not --',
      newestDay.totalText != AcouFormat.noValue &&
          newestDay.scoreView.totalText != AcouFormat.noValue &&
          newestDay.scoreView.gradeText != AcouFormat.noValue,
      '${newestDay.dateLabel}: ${newestDay.scoreView.totalText} / ${newestDay.scoreView.gradeText}');
  check('ADR-25: the daily card names the window it scores',
      UiStrings.reportDailyScoreTitle.contains('7'), UiStrings.reportDailyScoreTitle);
  check('ADR-25: the trend score note names the window too',
      UiStrings.reportTrendScoreNote.contains('7'), UiStrings.reportTrendScoreNote);

  // ADR-24: the two blocks added after the first UI pass. `snackCount` must be the same frozen
  // WeekSummary counter the scoring kernel reads, and the speed tile must be a **grade word**
  // derived from the window's mean interval -- `null` stays `无样本` instead of turning into a
  // grade, because an absent sample is not a normal speed.
  eq('the weekly view carries the frozen snack count',
      dailyView.snackCount, agg.snackCount);
  eq('no chewing sample renders the empty word, not a grade',
      ReportView.of(
        score: report.score,
        summaryText: report.summaryText,
        deltas: report.deltas,
        advices: report.advices,
        trendPoints: trend.points,
        agg: agg,
      ).meanChewSpeedText,
      UiStrings.overviewNoSample);
  eq('0.7 s is the middle grade', ReportView.of(
    score: report.score,
    summaryText: report.summaryText,
    deltas: report.deltas,
    advices: report.advices,
    trendPoints: trend.points,
    agg: agg,
    meanChewIntervalSeconds: 0.7,
  ).meanChewSpeedText, '正常');
  final recentCard = RecordCardText(
    record: const DietRecord(
      recordId: 'r-recent',
      eatenAtMs: 0,
      endedAtMs: 1000,
      classLabel: 'chips',
      classId: 0,
      attribute: '脆性食品',
      confidence: 0.9,
      durationSeconds: 100,
      source: 'real',
    ),
    food: null,
    timeText: '08:30',
    foodName: '薯片',
    kcalBadge: '',
    estimateLine: '',
    confidenceText: '置信度 90%',
    sourceBadge: '',
    showConfirmedBadge: false,
    semanticsLabel: '',
  );
  final withRecent = ReportView.of(
    score: report.score,
    summaryText: report.summaryText,
    deltas: report.deltas,
    advices: report.advices,
    trendPoints: trend.points,
    agg: agg,
    recentRecords: [recentCard],
  );
  eq('the recent-records strip carries the cards it was given',
      withRecent.recentRecords.length, 1);
  var recentImmutable = false;
  try {
    withRecent.recentRecords.add(recentCard);
  } on UnsupportedError {
    recentImmutable = true;
  }
  check('the recent-records list is unmodifiable', recentImmutable);
  // The day card must obey `ScoreView`'s rules instead of inventing a number: an undisplayable
  // total is the empty marker, and a displayable one is exactly the projection's value.
  var dailyTotalsHonest = true;
  for (final d in dailyView.dailyScores) {
    if (!d.scoreView.totalDisplayable && d.totalText != AcouFormat.noValue) {
      dailyTotalsHonest = false;
    }
    if (d.scoreView.totalDisplayable && d.totalText != d.scoreView.totalText) {
      dailyTotalsHonest = false;
    }
  }
  check('a daily card agrees with ScoreView about whether it can claim a total',
      dailyTotalsHonest, dailyView.dailyScores.map((d) => d.totalText).join(','));
  check('the daily kcal text keeps the estimate wording from the weekly scope',
      firstDay.kcalText == AcouFormat.noValue || firstDay.kcalText.startsWith('估算'),
      firstDay.kcalText);
  // A report without daily data must not invent a section.
  eq('an empty daily series renders no section',
      ReportView.of(
        score: report.score,
        summaryText: report.summaryText,
        deltas: report.deltas,
        advices: report.advices,
        trendPoints: trend.points,
        agg: agg,
      ).dailyScores.length,
      0);
  eq('the disclaimer is always present', view.disclaimerText, AdviceEngine.disclaimerText);
  eq('the report demo badge', view.demoBadgeText, '演示数据');
  eq('the suggestions exclude the disclaimer',
      view.advices.every((a) => !a.isDisclaimer), true);
  eq('the suggestions are sorted by priority',
      view.advices.map((a) => a.priority).toList(),
      (view.advices.map((a) => a.priority).toList()..sort()));

  // The insufficient state must not fabricate numbers.
  final thin = repoOf([(rec(1, 7, 0, 3), met())]);
  final thinService = ReportService(stats: thin, scores: HealthScoreService(stats: thin));
  final thinReport = await thinService.weekly(range: range);
  final thinView = ReportView.of(
    score: thinReport.score,
    summaryText: thinReport.summaryText,
    deltas: thinReport.deltas,
    advices: thinReport.advices,
    trendPoints: (await thinService.trend(days: 7)).points,
    agg: await thin.summary(range),
  );
  eq('fewer than three records is the insufficient state', thinView.insufficient, true);
  eq('the insufficient copy names the record shortage', thinView.insufficientText,
      '本周记录较少，暂不生成完整报告');
  eq('the advice area shows the frozen empty copy',
      thinView.adviceEmptyText, '暂不生成建议');
  eq('the thin chart fills only the day that has records',
      thinView.trendKcal.filledCount, 1);
  check('and it breaks the empty days rather than drawing a zero',
      thinView.trendKcal.points.where((p) => !p.hasValue).every((p) => p.value == null));
  eq('the disclaimer survives the insufficient state', thinView.disclaimerText.isNotEmpty, true);
  eq('the duration vocabulary is the frozen 3-record threshold', thinView.insufficient,
      thinReport.score.totalScore >= 0 &&
          (await thin.summary(range)).recordCount < HealthScoreService.minimumRecordsForDisplay);

  final emptyRepo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final emptyService = ReportService(
    stats: emptyRepo,
    scores: HealthScoreService(stats: emptyRepo),
  );
  final emptyReport = await emptyService.weekly(range: weekRange());
  final emptyView = ReportView.of(
    score: emptyReport.score,
    summaryText: emptyReport.summaryText,
    deltas: emptyReport.deltas,
    advices: emptyReport.advices,
    trendPoints: (await emptyService.trend(days: 7)).points,
    agg: await emptyRepo.summary(weekRange()),
  );
  eq('an empty week reads as not enough data', emptyView.insufficientText, '暂无足够数据');
  eq('the empty week keeps the frozen summary', emptyView.summaryText,
      ReportService.insufficientDataText);
  eq('the score axis is selectable', emptyView.trend(ChartAxis.score).axis, ChartAxis.score);
  eq('the kcal axis is selectable', emptyView.trend(ChartAxis.kcal).axis, ChartAxis.kcal);
  eq('all seven deltas are zero without a benchmark',
      emptyView.deltas.every((d) => d.value == 0), true);
  eq('and they are still rendered', emptyView.deltas.length, 7);
}

void _settingsChecks() {
  group('U-05 settings');

  eq('a missing day count degrades', SettingsPresenter.activeDaysText(null), '已坚持 -- 天');
  eq('zero days is a real value', SettingsPresenter.activeDaysText(0), '已坚持 0 天');
  eq('three days', SettingsPresenter.activeDaysText(3), '已坚持 3 天');
  check('no hard-coded seven-day copy',
      !SettingsPresenter.activeDaysText(3).contains('7'));

  final catalog = testCatalog();
  final records = <DietRecord>[rec(0, 12, 20, 3, id: 'c1'), rec(1, 7, 0, 1, id: 'c2')];
  final line = SettingsPresenter.clipboardLine(records.first, catalog);
  check('the clipboard line carries the record time', line.contains('12:20'), line);
  check('the clipboard line carries the food class', line.contains('面条'), line);
  check('the clipboard line carries the estimate marker', line.contains('（估算）'), line);
  check('the clipboard line carries the confidence', line.contains('置信度 82%'), line);

  final payload = SettingsPresenter.clipboardText(records, catalog);
  check('the payload lists every record',
      payload.contains('面条') && payload.contains('卷心菜'), payload);
  check('the payload states the portability truth',
      payload.contains('数据仅存于本机，卸载即丢失。'), payload);
  check('the payload carries no file-export wording',
      !payload.contains('导出文件') && !payload.contains('分享'), payload);
  final orphanPayload =
      SettingsPresenter.clipboardText(records, const EmptyFoodCatalog());
  check('an unresolved record still carries its time and its class slot',
      orphanPayload.contains('12:20') && orphanPayload.contains(UiStrings.unknownCategory),
      orphanPayload);

  final view = SettingsView.of(
    nickname: null,
    activeDays: 3,
    versionText: SettingsPresenter.fallbackVersionText,
    demoActive: true,
    recordCount: records.length,
  );
  eq('the nickname degrades', view.nicknameText, '未设置昵称');
  eq('the day count is dynamic', view.activeDaysText, '已坚持 3 天');
  eq('the achievements are a static constant list',
      view.achievements.length, SettingsPresenter.achievements.length);
  eq('the export entry stays disabled', SettingsPresenter.exportEntryEnabled, false);
  check('the export entry is labelled for the future version',
      view.exportEntryBadge == 'v1.1' && view.exportEntryText.contains('v1.1'));
  eq('the demo badge is visible on this page too', view.demoBadgeText, '演示数据');
  eq('copy is enabled when records exist', view.copyEnabled, true);
  eq('the clear confirmation is the frozen sentence', view.clearConfirmText,
      '将删除全部饮食记录与本地档案，且无法恢复。是否继续？');
  eq('the portability notice is verbatim', view.portabilityNotice,
      '你的记录仅保存在本机。卸载应用或更换手机后数据将无法找回，v1.0 不提供导出功能。');
  check('the privacy notice says there is no network permission',
      view.privacyNotice.contains('不申请网络权限'));
  check('the privacy notice says audio is not written to storage',
      view.privacyNotice.contains('不写入存储'));
  eq('the empty-library case disables copy',
      SettingsView.of(nickname: 'x', activeDays: 0, versionText: 'v1.0').copyEnabled, false);
  eq('an unavailable day port shows the empty marker',
      SettingsView.of(nickname: 'x', activeDays: null, versionText: 'v1.0',
              activeDaysUnavailable: true)
          .activeDaysText,
      '已坚持 -- 天');
  eq('an unavailable day port is flagged', SettingsView.of(
          nickname: 'x',
          activeDays: null,
          versionText: 'v1.0',
          activeDaysUnavailable: true)
      .activeDaysKnown, false);

  // ADR-24: the three-up 「本周健康数据概览」 panel. The two counters are the frozen WeekSummary
  // fields and the third tile is the grade word of the window's mean chewing interval -- the same
  // mapping a live session uses (`BehaviorAnalyzer.speedGradeFor`).
  final overview = SettingsView.of(
    nickname: 'x',
    activeDays: 3,
    versionText: 'v1.0',
    weekRecordCount: 28,
    weekSnackCount: 5,
    meanChewIntervalSeconds: 0.7,
  );
  eq('the overview records tile carries the unit', overview.overviewRecordCountText, '28 次');
  eq('the overview snack tile carries the unit', overview.overviewSnackCountText, '5 次');
  eq('the speed tile is the grade word, not a number', overview.overviewSpeedText, '正常');

  final noSample = SettingsView.of(
    nickname: 'x',
    activeDays: 3,
    versionText: 'v1.0',
    weekRecordCount: 6,
    weekSnackCount: 1,
  );
  eq('a window with no chewing sample says 无样本, never 正常',
      noSample.overviewSpeedText, UiStrings.overviewNoSample);

  final deadOverview = SettingsView.of(
    nickname: 'x',
    activeDays: 3,
    versionText: 'v1.0',
    weekRecordCount: 28,
    weekSnackCount: 5,
    meanChewIntervalSeconds: 0.7,
    overviewUnavailable: true,
  );
  check(
      'one failed query degrades all three tiles together',
      deadOverview.overviewRecordCountText == AcouFormat.noValue &&
          deadOverview.overviewSnackCountText == AcouFormat.noValue &&
          deadOverview.overviewSpeedText == AcouFormat.noValue,
      '${deadOverview.overviewRecordCountText} / ${deadOverview.overviewSnackCountText} / '
          '${deadOverview.overviewSpeedText}');
}

Future<void> _selfCheckChecks(AssetReader assets) async {
  group('M-04 self check -- rendered from the real controller');

  // The checks themselves belong to `DemoController.runSelfCheck()` (API-04 section 7.1); the
  // presentation layer only renders them, normalises the row count and derives the verdict.
  // This group therefore drives the real controller through `FakeAudioBridge` /
  // `FakeInferenceEngine` / `FakeRepo`.
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final bridge = FakeAudioBridge();
  final engine = FakeInferenceEngine();
  final kb = FoodKnowledgeBase();
  await kb.load(
    assetPath: 'assets/foods.json',
    jsonText: await assets.readString('assets/foods.json'),
  );
  final demoData = DemoDataController(diet: repo, assets: assets);
  final handshake = Handshake.verify(await bridge.getCapabilities(),
      melVersion: cfg.FeatureConfig.melVersion);

  DemoController controllerWith({
    AudioBridge? withBridge,
    InferenceEngine? withEngine,
    FoodKnowledgeBase? withKb,
    HandshakeResult? withHandshake,
    bool omitHandshake = false,
  }) =>
      DemoController(
        bridge: withBridge ?? bridge,
        engine: withEngine ?? engine,
        diet: repo,
        knowledge: withKb ?? kb,
        maintenance:
            PlaceholderMaintenanceRepo(diet: repo, profile: repo, bridge: withBridge ?? bridge),
        assets: assets,
        demoData: demoData,
        handshake: omitHandshake ? null : (withHandshake ?? handshake),
      );

  await engine.load(assetPath: 'assets/models/model_card.json');
  final report = await controllerWith().runSelfCheck();

  eq('exactly fourteen items', report.items.length, 14);
  eq('the keys are the frozen order', report.items.map((i) => i.key).join(','),
      SelfCheckKeys.all.join(','));
  eq('the first nine keys are the base set',
      report.items.take(9).map((i) => i.key).join(','),
      'permission,mic,model,delegate,featureConfig,db,knowledge,tempAudio,sampleAudio');
  // ADR-34：回到 ADR-14 的 14 项闭集（ADR-27 增加的第 15 项 adviceModel 已随端侧语言模型删除），
  // 并逐字断言顺序 —— 这一条的存在价值正是"有人加了项但没更新它"时立刻变红。
  eq('the last five keys are the field set',
      report.items.skip(9).map((i) => i.key).join(','),
      'session,modelInfo,envelope,dropRate,demoData');
  check('no noise item sneaks in',
      !report.items.any((i) => i.key.contains('noise') || i.key == 'ambientNoise'));
  check('every observed value is non-empty', report.items.every((i) => i.observed.isNotEmpty));
  check('a failed item always carries an actionable hint',
      report.items.where((i) => !i.passed).every((i) => (i.hint ?? '').isNotEmpty));

  // The panel renders one numbered row per key, whatever the report contains.
  final view = SelfCheckView.of(report);
  eq('the panel renders fourteen rows', view.rows.length, 14);
  eq('the rows are numbered one to fourteen', view.rows.map((r) => r.index).join(','),
      List.generate(14, (i) => i + 1).join(','));
  eq('the row count agrees with the report', view.rows.length, report.items.length);
  check('the panel exposes a text channel for every row',
      view.rows.every((r) => r.statusText == '通过' || r.statusText == '失败'));
  check('the panel counts its passes and failures',
      view.passedCount + view.failedCount == 14);
  eq('the all-passed flag matches the rows', view.allPassed, report.allPassed);

  // ADR-02 / D18: an unengaged microphone is not a failure.
  final skipped = FakeAudioBridge(micInUseKnown: false);
  final skippedReport = await controllerWith(withBridge: skipped).runSelfCheck();
  final micItem = skippedReport.byKey(SelfCheckKeys.mic)!;
  eq('an unengaged microphone passes', micItem.passed, true);
  eq('an unengaged microphone is reported as such', micItem.observed, '未启用麦克风');
  eq('and it carries no hint', micItem.hint, null);

  // D10 / FF-18: a usable delegate passes and the observed value shows which one.
  final cpuEngine = FakeInferenceEngine();
  await cpuEngine.load(assetPath: 'assets/models/model_card.json');
  final cpuReport = await controllerWith(withEngine: cpuEngine).runSelfCheck();
  final delegateItem = cpuReport.byKey(SelfCheckKeys.delegate)!;
  eq('a usable delegate passes', delegateItem.passed, true);
  eq('the delegate is echoed verbatim', delegateItem.observed, cpuEngine.delegateInUse);

  // An unverified handshake is item 5 failing -- and it must not throw (D20).
  final unverified = await controllerWith(omitHandshake: true).runSelfCheck();
  eq('an unverified handshake fails item 5',
      unverified.byKey(SelfCheckKeys.featureConfig)!.passed, false);
  check('and it still returns a full report', unverified.items.length == 14);
  check('the unverified item carries a hint',
      (unverified.byKey(SelfCheckKeys.featureConfig)!.hint ?? '').isNotEmpty);

  // An unloaded knowledge base fails item 7 with the asset hint, and the panel still renders.
  final noKb = await controllerWith(withKb: FoodKnowledgeBase()).runSelfCheck();
  eq('an unloaded knowledge base fails item 7',
      noKb.byKey(SelfCheckKeys.knowledge)!.passed, false);
  eq('item 7 points at the asset file',
      noKb.byKey(SelfCheckKeys.knowledge)!.hint, '检查 assets/foods.json');

  // D9: no session data is explicitly not a failure (the fake bridge reports zero patches).
  eq('no session data passes', report.byKey(SelfCheckKeys.dropRate)!.passed, true);
  eq('no session data is reported verbatim',
      report.byKey(SelfCheckKeys.dropRate)!.observed, '无会话数据');

  // The panel's own verdict judgements (SPEC-M-04 section 2.2 step 5).
  SelfCheckReport withFailure(String key) => SelfCheckReport([
        for (final item in report.items)
          SelfCheckItem(
            key: item.key,
            label: item.label,
            passed: item.key == key ? false : true,
            observed: item.observed,
            hint: item.key == key ? SelfCheckPresenter.fieldActionFor(key) : null,
          ),
      ]);
  eq('a permission failure points at the microphone side',
      SelfCheckView.of(withFailure(SelfCheckKeys.permission)).verdictText,
      UiStrings.verdictMicSide);
  eq('a microphone failure points at the microphone side',
      SelfCheckView.of(withFailure(SelfCheckKeys.mic)).verdictText, UiStrings.verdictMicSide);
  eq('a model failure points at the model side',
      SelfCheckView.of(withFailure(SelfCheckKeys.model)).verdictText,
      UiStrings.verdictModelSide);
  eq('an envelope failure also points at the model side',
      SelfCheckView.of(withFailure(SelfCheckKeys.envelope)).verdictText,
      UiStrings.verdictModelSide);
  eq('a configuration drift is a bridge problem, not a model problem',
      SelfCheckView.of(withFailure(SelfCheckKeys.featureConfig)).verdictText,
      UiStrings.verdictBothSides);
  eq('a database failure is a bridge problem',
      SelfCheckView.of(withFailure(SelfCheckKeys.db)).verdictText, UiStrings.verdictBothSides);

  check('the two model items give different field actions',
      SelfCheckPresenter.fieldActionFor(SelfCheckKeys.model) !=
          SelfCheckPresenter.fieldActionFor(SelfCheckKeys.modelInfo));
  eq('item 3 points at Mode C', SelfCheckPresenter.fieldActionFor(SelfCheckKeys.model),
      '切换到 Mode C（报告演示）');
  eq('item 11 forbids the demonstration',
      SelfCheckPresenter.fieldActionFor(SelfCheckKeys.modelInfo), '禁止演示，先重载模型');

  // A short report is normalised, never silently shortened.
  final normalized = SelfCheckView.of(SelfCheckReport(report.items.take(9).toList()));
  eq('a short report is normalised to fourteen rows', normalized.rows.length, 14);
  eq('the missing item is an explicit failure', normalized.rows.last.passed, false);
  eq('the missing item reports unavailable',
      normalized.rows.last.observed, UiStrings.selfCheckUnavailable);
  eq('the panel counts the failures', normalized.failedCount, 5);
  eq('an empty report has no results', SelfCheckView.idle.hasResults, false);
  eq('an empty report cannot be all-passed', SelfCheckView.idle.allPassed, false);
  eq('an empty report says so', SelfCheckView.idle.verdictText, UiStrings.verdictUnknown);
  eq('the three mode labels',
      SelfCheckPresenter.modes.map(SelfCheckPresenter.modeLabel).join('/'),
      'A · 实时/B · 示例音频/C · 报告演示');
}

void _stateLayerChecks() {
  group('presentation state layer (Riverpod-free)');

  eq('idle status', const AsyncValue<int>.idle().status, ViewStatus.idle);
  eq('loading keeps the previous value', const AsyncValue.loading(7).data, 7);
  eq('ready carries the value', const AsyncValue<int>.ready(9).data, 9);
  final error = AsyncValue<int>.error(
      AcouDietError(Codes.audioRecordInitFailed, '麦克风初始化失败，请重试', retryable: true));
  eq('the error state keeps the code', error.errorCode, Codes.audioRecordInitFailed);
  eq('a retryable error offers a retry', error.canRetry, true);
  final fatal = AsyncValue<int>.error(AcouDietError(Codes.cfgMismatch, '配置不一致，请更新应用'));
  eq('a non-retryable error offers no retry', fatal.canRetry, false);
  eq('a non-retryable error still carries its message', fatal.errorMessage,
      '配置不一致，请更新应用');
  eq('a ready value carries no error', const AsyncValue<int>.ready(1).canRetry, false);

  final empty = const AsyncValue<List<int>>.ready(<int>[]);
  eq('an empty list is the empty state, not ready', AsyncValue.statusForList(empty),
      ViewStatus.empty);
  final full = const AsyncValue<List<int>>.ready(<int>[1]);
  eq('a non-empty list is ready', AsyncValue.statusForList(full), ViewStatus.ready);

  final folded = const AsyncValue<int>.ready(4).when(
    idle: () => 'idle',
    loading: (p) => 'loading',
    ready: (v) => 'ready:$v',
    error: (e, p) => 'error',
  );
  eq('when() folds the ready branch', folded, 'ready:4');
  eq('map preserves idle', const AsyncValue<int>.idle().map((v) => '$v').status, ViewStatus.idle);
  eq('toLoading keeps the last good value', const AsyncValue<int>.ready(3).toLoading().data, 3);
}

Future<void> _handshakeAndDemoChecks(AssetReader assets) async {
  group('C-03 handshake gate, plus the M-03 demo wiring');

  // The fifteen frozen fields (ADR-21), compared by the real `Handshake`.
  final bridge = FakeAudioBridge();
  final ok = Handshake.verify(
      await bridge.getCapabilities(), melVersion: cfg.FeatureConfig.melVersion);
  eq('fifteen fields compared', ok.checkedFields, 15);
  eq('the agreed frame count comes from the bridge', ok.nFrames, cfg.FeatureConfig.nFrames);

  var drifted = '';
  try {
    Handshake.verify(await FakeAudioBridge(nFrames: 129).getCapabilities(),
        melVersion: cfg.FeatureConfig.melVersion);
  } on AcouDietError catch (e) {
    drifted = e.code;
  }
  eq('a drifted frame count raises the configuration code', drifted, Codes.cfgMismatch);
  eq('the configuration code is not retryable', isRetryable(Codes.cfgMismatch), false);
  check('the detection presenter agrees the page is unreachable',
      !DetectPresenter.pageReachable(
          handshakeError: AcouDietError(Codes.cfgMismatch, '配置不一致，请更新应用')));

  // ---- the app-level gate ---------------------------------------------------------------
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  AppServices servicesWith(AudioBridge b) => AppServices.assemble(
        assets: assets,
        dietRepo: repo,
        statsRepo: repo,
        profileRepo: repo,
        maintenanceRepo: PlaceholderMaintenanceRepo(diet: repo, profile: repo, bridge: b),
        bridge: b,
        nowMsOverride: _anchorMs,
      );

  final services = servicesWith(bridge);
  check('detection is blocked before the handshake runs', services.detectionBlocked);
  final handed = await services.runHandshake();
  check('a matching bridge passes the handshake', handed);
  eq('detection becomes reachable', services.detectionBlocked, false);
  eq('the knowledge base loads six entries', await services.loadKnowledgeBase(), true);
  eq('the catalogue resolves a class', services.catalog.byClassId(3)!.zhName, '面条');
  eq('an out-of-range class stays null', services.catalog.byClassId(9), null);
  eq('the demo flag starts false', await services.refreshDemoActive(), false);
  await services.bootstrap();
  eq('bootstrap leaves the catalogue loaded', services.catalog.isLoaded, true);

  final broken = servicesWith(FakeAudioBridge(nFrames: 129));
  eq('a drifted bridge fails the handshake', await broken.runHandshake(), false);
  check('and the detection page stays unreachable', broken.detectionBlocked);
  eq('the blocking error keeps the frozen code', broken.handshakeError!.code, Codes.cfgMismatch);
  eq('the self-check panel is still constructible behind the gate',
      broken.demoController.currentMode, DemoMode.realtime);

  // ---- the M-03 demo dataset -------------------------------------------------------------
  final demoRepo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final realRecord = DietRecord(
    recordId: 'real-1',
    eatenAtMs: DateTime(2026, 9, 10, 8).millisecondsSinceEpoch,
    endedAtMs: DateTime(2026, 9, 10, 8, 5).millisecondsSinceEpoch,
    classLabel: 'noodles',
    classId: 3,
    attribute: '软性主食',
    confidence: 0.8,
    durationSeconds: 300,
    source: 'real',
  );
  await demoRepo.insertSession(record: realRecord, metrics: null);
  final demoData = DemoDataController(diet: demoRepo, assets: assets);
  eq('the demo flag starts false', demoData.isDemoActive, false);
  final loaded = await demoData.loadDemoDataset();
  eq('the shipped dataset loads every record', loaded, 28);
  eq('the demo flag flips to true', demoData.isDemoActive, true);
  final afterLoad = await demoRepo.byRange(DateRange(0, 1 << 62));
  eq('28 demo rows plus the one real row', afterLoad.length, 29);
  check('every loaded row is flagged demo',
      afterLoad.where((r) => r.isDemo).length == 28);
  eq('a second load is idempotent', await demoData.loadDemoDataset(), 28);
  final dropped = await demoData.clearDemoDataset();
  eq('only demo rows are removed', dropped, 28);
  final afterClear = await demoRepo.byRange(DateRange(0, 1 << 62));
  eq('the real row survives', afterClear.length, 1);
  eq('the surviving row is the real one', afterClear.single.recordId, 'real-1');
  eq('the demo flag is false again', demoData.isDemoActive, false);

  // ---- the demo mode state machine (API-04 section 7.2) ----------------------------------
  final kb = FoodKnowledgeBase();
  await kb.load(
    assetPath: 'assets/foods.json',
    jsonText: await assets.readString('assets/foods.json'),
  );
  final engine = FakeInferenceEngine();
  final demoBridge = FakeAudioBridge();
  final registry = DetectionSessionRegistry();
  final controller = DemoController(
    bridge: demoBridge,
    engine: engine,
    diet: demoRepo,
    knowledge: kb,
    maintenance:
        PlaceholderMaintenanceRepo(diet: demoRepo, profile: demoRepo, bridge: demoBridge),
    assets: assets,
    demoData: demoData,
    handshake: Handshake.verify(await demoBridge.getCapabilities(),
        melVersion: cfg.FeatureConfig.melVersion),
    registry: registry,
  );
  eq('the default mode is realtime', controller.currentMode, DemoMode.realtime);
  await controller.switchTo(DemoMode.realtime);
  eq('a same-mode switch is an idempotent no-op', controller.currentMode, DemoMode.realtime);
  await controller.switchTo(DemoMode.sampleAudio);
  eq('sample audio switches', controller.currentMode, DemoMode.sampleAudio);
  eq('report demo without a dataset is refused',
      await _switchFailure(controller, DemoMode.reportOnly), Codes.demoModeSwitch);
  await controller.loadReportDemo();
  eq('loading the report demo lands in Mode C', controller.currentMode, DemoMode.reportOnly);
  eq('and the dataset is active', demoData.isDemoActive, true);

  // A running session blocks every switch, and the switch must not stop it optimistically.
  final session = services.newDetectionSession();
  registry.register(session);
  await session.start(sessionId: 'S-test-0001');
  eq('a running session blocks the switch',
      await _switchFailure(controller, DemoMode.realtime), Codes.demoModeSwitch);
  check('the session was not stopped behind the user back', session.isRunning);
  await session.stop();
  eq('stopping clears the running flag', session.isRunning, false);
}

Future<String> _switchFailure(DemoController c, DemoMode mode) async {
  try {
    await c.switchTo(mode);
    return 'noError';
  } on AcouDietError catch (e) {
    return e.code;
  }
}

/// Every string the presenters can produce, scanned as one set by the FF-25 checks below.
final List<String> _allStrings = <String>[];

void _bannedWordingChecks() {
  group('FF-25 wording red lines');

  final catalog = testCatalog();
  final harvest = <String>[];

  harvest.add(AcouFormat.kcalRange(1250));
  harvest.add(AcouFormat.kcalRangeValue(1100));
  harvest.add(AcouFormat.kcalEstimate(315));
  harvest.add(AcouFormat.confidence(0.88));
  harvest.add(DetectPresenter.firstConfirmHint);
  harvest
      .add(SettingsPresenter.clipboardText([rec(0, 12, 20, 3, id: 'b1')], catalog));

  // The self-check panel copy: the frozen labels, the field actions and the mode buttons.
  for (final key in SelfCheckKeys.all) {
    harvest.add(SelfCheckKeys.labels[key]!);
    harvest.add(SelfCheckPresenter.fieldActionFor(key));
  }
  for (final mode in SelfCheckPresenter.modes) {
    harvest.add(SelfCheckPresenter.modeLabel(mode));
  }
  harvest.addAll([
    UiStrings.selfCheckPassedWord,
    UiStrings.selfCheckFailedWord,
    UiStrings.selfCheckUnavailable,
    UiStrings.selfCheckTitle,
    UiStrings.selfCheckRun,
  ]);

  for (final state in DetectUiState.values) {
    harvest.add(DetectPresenter.statusText(state));
    harvest.add(DetectPresenter.primaryActionLabel(state));
  }
  for (final c in FoodClassId.values) {
    harvest.add(c.zhName);
    harvest.add(c.kbAttribute);
  }
  harvest.addAll([
    UiStrings.appTitle,
    UiStrings.portabilityNotice,
    UiStrings.privacyNotice,
    UiStrings.privacyLossNotice,
    UiStrings.clearConfirmText,
    UiStrings.exportEntryText,
    UiStrings.exportEntrySpoken,
    UiStrings.copyAsText,
    UiStrings.copiedToClipboard,
    UiStrings.detectSaved,
    UiStrings.detectWaiting,
    UiStrings.detectListening,
    UiStrings.detectUnrecognised,
    UiStrings.askUserText('chips'),
    UiStrings.weekSummaryInsufficient,
    UiStrings.reportInsufficient,
    UiStrings.reportInsufficientFew,
    UiStrings.adviceEmpty,
    UiStrings.disclaimerText,
    UiStrings.homeTodayRecordsEmpty,
    UiStrings.homeEnergyEmpty,
    UiStrings.unknownCategory,
    UiStrings.demoDataBadge,
    UiStrings.sampleDemoBadge,
    UiStrings.chewRhythmDegraded,
    UiStrings.verdictAllPassed,
    UiStrings.verdictMicSide,
    UiStrings.verdictModelSide,
    UiStrings.verdictBothSides,
    UiStrings.knowledgeOriginNote,
    UiStrings.recordDetailTitle,
    UiStrings.weekSummaryCardTitle,
    UiStrings.scoreCardTitle,
    UiStrings.reportTrendTitle,
  ]);

  // The record surfaces, produced end to end for all six classes.
  for (final classId in [0, 1, 2, 3, 4, 5]) {
    final card = RecordsView.cardOf(rec(0, 12, 0, classId, id: 'h$classId'), catalog);
    harvest.addAll([
      card.foodName,
      card.kcalBadge,
      card.estimateLine,
      card.confidenceText,
      card.semanticsLabel,
      card.estimateWithKcal,
    ]);
  }
  harvest.add(HomeEnergyView.of(null).displayText);
  harvest.add(HomeWeekCountView.of(null).text);
  harvest.add(RecordsSummaryView.of(TodaySummary.empty).barText);
  harvest.add(RecordsSummaryView.unknown.barText);
  harvest.add(RecordsSummaryView.of(TodaySummary.empty).semanticsLabel);
  for (final axis in ScoreView.unavailable().axes) {
    harvest.add(axis.ratioText);
    harvest.add(axis.formulaText);
    harvest.add(axis.semanticsText);
  }
  harvest.add(ScoreView.unavailable().semanticsText);
  for (final key in WeeklyReport.deltaKeys) {
    harvest.add(DeltaRowView.of(key, 0).text);
    harvest.add(DeltaRowView.of(key, 4).text);
    harvest.add(DeltaRowView.of(key, -4).text);
  }
  harvest.add(TrendChartData.of(const <TrendPoint>[], ChartAxis.kcal).textEquivalent);
  final gapPoint = TrendChartData.of(
      const [TrendPoint(date: '2026-09-08')], ChartAxis.kcal);
  harvest.add(gapPoint.textEquivalent);
  harvest.add(gapPoint.points.single.valueText);

  _allStrings
    ..clear()
    ..addAll(harvest);

  // The negative list lives here, outside `lib/`, so that the repository-wide safety scan over
  // `lib/` stays at zero hits.
  const banned = <String>[
    '准确识别',
    '零操作',
    '完全无感',
    '测热量',
    '可以测',
    '营养成分',
    '识别所有食物',
  ];
  final hits = <String>[];
  for (final s in harvest) {
    for (final b in banned) {
      if (s.contains(b)) hits.add('$b <= $s');
    }
  }
  check('no FF-25 banned wording in any produced string', hits.isEmpty, hits.join(' | '));

  final speedClaims = harvest.where((s) => s.contains('2 秒') || s.contains('2秒')).toList();
  check('no two-second latency claim anywhere', speedClaims.isEmpty, speedClaims.join(' | '));
  check('the only latency hint is the 4–5 second one',
      DetectPresenter.firstConfirmHint.contains('4–5 秒'));

  // The forbidden shapes of the cut features must not appear either.
  const cutShapes = <String>['已修正', '识别历史', '蛋白质', '目标热量'];
  final cutHits = <String>[];
  for (final s in harvest) {
    for (final c in cutShapes) {
      if (s.contains(c)) cutHits.add('$c <= $s');
    }
  }
  check('none of the cut features leak into the copy', cutHits.isEmpty, cutHits.join(' | '));

  // A bare kilocalorie must never be produced: every kcal string either carries the estimate
  // marker, is a hedged range, or is the frozen `≈N kcal` badge whose card also carries it.
  final bare = <String>[];
  for (final s in harvest) {
    if (!s.contains('kcal')) continue;
    final carriesEstimate = s.contains('估算');
    final isHedgedRange = RegExp(r'^约 \d+–\d+ kcal$').hasMatch(s);
    final isFrozenBadge = RegExp(r'^≈\d+ kcal$').hasMatch(s);
    if (!carriesEstimate && !isHedgedRange && !isFrozenBadge) bare.add(s);
  }
  check('no kilocalorie is produced without its estimate wording', bare.isEmpty, bare.join(' | '));
  check('the harvest actually covered a substantial string set', harvest.length > 60,
      '${harvest.length} strings');
}

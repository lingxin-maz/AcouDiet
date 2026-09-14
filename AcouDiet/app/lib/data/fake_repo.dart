import 'dart:math' as math;

import '../core/errors.dart';
import '../core/feature_config.g.dart' as cfg;
import '../core/time.dart';
import '../domain/model/diet_record.dart';
import '../domain/model/summaries.dart';
import '../domain/repository/repositories.dart';

/// In-memory stand-in for the three read/write repositories (`API-03` section 8).
///
/// Purpose: let the UI and the A-domain tests run **before** the SQLite layer exists
/// ("placeholder data decoupling", `PLAN-00` section 4), and let hand-computed scoring
/// fixtures be expressed directly as records.
///
/// Guarantees the contract demands:
///  * only `DietRepo` / `StatsRepo` / `ProfileRepo` are implemented -- **not**
///    `MaintenanceRepo`, so no "pretend clear everything" button can appear;
///  * everything is derived from one in-memory record list (never hard-coded per endpoint);
///  * deterministic: the "today" anchor is an injected fixed day, never `DateTime.now()`;
///  * `classCounts` always has six keys and `byHour` always 24;
///  * `insertSession` honours I-1 (a record without metrics still gets a placeholder row).
class FakeRepo implements DietRepo, StatsRepo, ProfileRepo {
  FakeRepo({
    List<DietRecord>? records,
    List<BehaviorMetrics>? metrics,
    int? baseDayMs,
    this.kcalOverride,
  })  : _records = List<DietRecord>.from(records ?? const []),
        _baseDayMs = baseDayMs ?? _defaultBaseDayMs {
    // Keep record <-> metrics 1:1 even when a caller seeds only records.
    final recs = records ?? const <DietRecord>[];
    for (var i = 0; i < recs.length; i++) {
      _metricsByRecordId[recs[i].recordId] =
          (metrics != null && i < metrics.length) ? metrics[i] : BehaviorMetrics.placeholder;
    }
  }

  final List<DietRecord> _records;

  /// Metrics keyed by record id: identity is the id, never value equality (two identical
  /// meals on different days are different rows).
  final Map<String, BehaviorMetrics> _metricsByRecordId = {};
  final int _baseDayMs;

  /// Overrides the knowledge-base kcal lookup in tests (default: a fixed table).
  final Map<int, int>? kcalOverride;

  UserProfile _profile = UserProfile.defaults;

  /// A stable anchor day (2026-09-10 12:00 local) so results never depend on the clock.
  static final int _defaultBaseDayMs =
      DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

  List<DietRecord> get records => List<DietRecord>.unmodifiable(_records);

  // ------------------------------------------------------------------ DietRepo

  @override
  Future<void> insertSession({
    required DietRecord record,
    required BehaviorMetrics? metrics,
  }) async {
    if (_records.any((r) => r.recordId == record.recordId)) {
      throw AcouDietError(Codes.dbUniqueConstraint, 'recordId already exists',
          detail: {'recordId': record.recordId});
    }
    final problems = record.validate();
    if (problems.isNotEmpty) {
      throw Errors.dbInvalid(problems.join('; '));
    }
    _records.add(record);
    // I-1: a placeholder row is written, never omitted.
    _metricsByRecordId[record.recordId] = metrics ?? BehaviorMetrics.placeholder;
  }

  @override
  Future<List<DietRecord>> byRange(DateRange r) async {
    if (r.startMs > r.endMs) throw Errors.dbInvalid('range reversed');
    final out = _records.where((x) => r.contains(x.eatenAtMs)).toList();
    out.sort((a, b) => a.eatenAtMs.compareTo(b.eatenAtMs));
    return out;
  }

  @override
  Future<DietRecord?> byId(String recordId) async {
    for (final r in _records) {
      if (r.recordId == recordId) return r;
    }
    return null;
  }

  @override
  Future<int> deleteById(String recordId) async {
    final idx = _records.indexWhere((r) => r.recordId == recordId);
    if (idx < 0) return 0;
    _records.removeAt(idx);
    _metricsByRecordId.remove(recordId);
    return 1;
  }

  @override
  Future<int> deleteAll() async {
    final n = _records.length;
    _records.clear();
    _metricsByRecordId.clear();
    return n;
  }

  @override
  Future<int> countAll() async => _records.length;

  @override
  Future<BehaviorMetrics?> metricsByRecordId(String recordId) async {
    if (!_records.any((r) => r.recordId == recordId)) return null;
    return _metricsByRecordId[recordId] ?? BehaviorMetrics.placeholder;
  }

  // ------------------------------------------------------------------ StatsRepo

  @override
  Future<TodaySummary> today() async {
    final (start, end) = (TimeUtil.startOfLocalDay(_baseDayMs),
        TimeUtil.startOfNextLocalDay(_baseDayMs));
    final range = DateRange(start, end);
    final recs = await byRange(range);
    return TodaySummary(
      recordCount: recs.length,
      estimatedKcal: recs.fold<int>(0, (s, r) => s + _kcalForRecord(r)),
      snackCount: recs
          .where((r) => MealWindows.isSnackRecord(
                TimeUtil.minutesOfLocalDay(r.eatenAtMs),
                r.classId,
              ))
          .length,
      records: recs,
    );
  }

  @override
  Future<WeekSummary> week() async {
    final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _baseDayMs);
    return summary(DateRange(start, end));
  }

  @override
  Future<WeekSummary> summary(DateRange range) async {
    if (range.startMs > range.endMs) throw Errors.dbInvalid('range reversed');
    final recs = await byRange(range);
    final counts = <String, int>{for (final l in cfg.FeatureConfig.classLabels) l: 0};
    var snack = 0;
    var lateNight = 0;
    for (final r in recs) {
      counts[r.classLabel] = (counts[r.classLabel] ?? 0) + 1;
      final minutes = TimeUtil.minutesOfLocalDay(r.eatenAtMs);
      // ADR-23: the same class-aware rule the SQL repository applies, so the two
      // implementations cannot disagree.
      if (MealWindows.isSnackRecord(minutes, r.classId)) snack++;
      if (MealWindows.isLateNight(minutes)) lateNight++;
    }
    return WeekSummary(
      recordCount: recs.length,
      estimatedKcal: recs.fold<int>(0, (s, r) => s + _kcalForRecord(r)),
      snackCount: snack,
      lateNightCount: lateNight,
      mealTimeStdDevMinutes: mealTimeStdDevMinutesOf(recs),
      classCounts: counts,
    );
  }

  @override
  Future<ChewStats> chewStats(DateRange range) async {
    final recs = await byRange(range);
    // Duration-weighted mean, matching API-03 revision A-1 / SPEC-A-01 A-01-K3.
    var weight = 0.0;
    var acc = 0.0;
    var samples = 0;
    for (var i = 0; i < recs.length; i++) {
      final m = _metricOf(recs[i]);
      final interval = m.avgChewIntervalSeconds;
      final duration = m.durationSeconds ?? 0;
      if (interval == null || duration <= 0) continue;
      samples++;
      weight += duration;
      acc += interval * duration;
    }
    return ChewStats(
      sampleCount: samples,
      meanChewIntervalSeconds: weight > 0 ? acc / weight : null,
    );
  }

  @override
  Future<List<int>> mealTimeSamples(DateRange range) async {
    final recs = await byRange(range);
    final out = <int>[];
    for (final r in recs) {
      final minutes = TimeUtil.minutesOfLocalDay(r.eatenAtMs);
      if (MealWindows.isMainMeal(minutes)) out.add(minutes);
    }
    out.sort();
    return out;
  }

  @override
  Future<List<TrendPoint>> trend(int days) async {
    if (days < 1 || days > 365) throw Errors.dbInvalid('days out of range');
    final (start, end) = TimeUtil.lastLocalDays(days, nowMsOverride: _baseDayMs);
    final keys = TimeUtil.dayKeysInRange(start, end);
    final out = <TrendPoint>[];
    for (final key in keys) {
      final dayStart = _parseDay(key);
      final dayEnd = TimeUtil.startOfNextLocalDay(dayStart);
      final recs = await byRange(DateRange(dayStart, dayEnd));
      out.add(TrendPoint(
        date: key,
        estimatedKcal: recs.isEmpty
            ? null
            : recs.fold<int>(0, (s, r) => s + _kcalForRecord(r)),
        totalScore: null, // L3 must never fill this (API-03 section 5)
      ));
    }
    return out;
  }

  @override
  Future<MealTimeDistribution> mealTimes(int days) async {
    if (days < 1 || days > 365) throw Errors.dbInvalid('days out of range');
    final (start, end) = TimeUtil.lastLocalDays(days, nowMsOverride: _baseDayMs);
    final byHour = <int, int>{for (var h = 0; h < 24; h++) h: 0};
    for (final r in await byRange(DateRange(start, end))) {
      final h = TimeUtil.hourOfLocalDay(r.eatenAtMs);
      byHour[h] = (byHour[h] ?? 0) + 1;
    }
    return MealTimeDistribution(byHour);
  }

  @override
  Future<int> activeDays() async {
    final days = <String>{};
    for (final r in _records) {
      days.add(TimeUtil.dayKey(r.eatenAtMs));
    }
    return days.length;
  }

  // ------------------------------------------------------------------ ProfileRepo

  @override
  Future<UserProfile> load() async => _profile;

  @override
  Future<void> save(UserProfile p) async {
    p.assertValid();
    _profile = p;
  }

  // ------------------------------------------------------------------ internals

  BehaviorMetrics _metricOf(DietRecord r) =>
      _metricsByRecordId[r.recordId] ?? BehaviorMetrics.placeholder;

  int _kcalFor(int classId) {
    final override = kcalOverride;
    if (override != null) {
      final v = override[classId];
      if (v == null) throw Errors.kb('no kcal for classId=$classId');
      return v;
    }
    if (classId < 0 || classId >= cfg.FeatureConfig.numClasses) {
      throw Errors.kb('classId out of range: $classId');
    }
    // Deterministic placeholder table (the real values come from foods.json).
    return _defaultKcal[classId] ?? 100;
  }

  /// ADR-23: the placeholder wiring has no knowledge base, so it has no portion model. It
  /// scales the placeholder table **linearly against a reference eating duration**, and the
  /// table therefore describes a [referencePortionSeconds] event -- which is what the fixtures
  /// and the demo dataset use. A record written without timing evidence (`durationSeconds <= 0`)
  /// keeps the table value rather than inventing a duration.
  ///
  /// The real wiring does not do this: there, `KcalResolver.kcalForDuration` runs
  /// `PortionEstimator` over the same knowledge base the record cards read.
  static const int referencePortionSeconds = 300;

  int _kcalForRecord(DietRecord r) {
    final base = _kcalFor(r.classId);
    final d = r.durationSeconds;
    if (d <= 0 || d == referencePortionSeconds) return base;
    return (base * d / referencePortionSeconds).round();
  }

  static const Map<int, int> _defaultKcal = {
    0: 160, // chips
    1: 90, // cabbage
    2: 150, // gummies
    3: 130, // noodles
    4: 40, // carrot
    5: 60, // drink
  };

  static int _parseDay(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]))
        .millisecondsSinceEpoch;
  }

  /// A deterministic demo dataset for the placeholder UI (source = `demo`).
  static FakeRepo demoFixture() {
    final base = DateTime(2026, 9, 10, 12);
    final labels = cfg.FeatureConfig.classLabels;
    final records = <DietRecord>[];
    final metrics = <BehaviorMetrics>[];
    var id = 0;
    for (var dayOffset = 0; dayOffset < 7; dayOffset++) {
      final day = base.subtract(Duration(days: dayOffset));
      final picks = <(int, int)>[
        (7, 0), // 07:00 breakfast
        (12, 1), // 12:00 lunch
        (18, 3), // 18:00 dinner
        (15, 2), // 15:40-ish snack
      ];
      for (var i = 0; i < picks.length; i++) {
        final (hour, classId) = picks[i];
        final at = DateTime(day.year, day.month, day.day, hour, i == 3 ? 40 : 0);
        records.add(DietRecord(
          recordId: 'demo-${id.toString().padLeft(3, '0')}',
          eatenAtMs: at.millisecondsSinceEpoch,
          endedAtMs: at.millisecondsSinceEpoch + 300000,
          classLabel: labels[classId],
          classId: classId,
          attribute: _attributeFor(classId),
          confidence: 0.82,
          durationSeconds: 300,
          source: 'demo',
        ));
        metrics.add(i == 3
            ? BehaviorMetrics.placeholder
            : const BehaviorMetrics(
                chewCount: 45,
                avgChewIntervalSeconds: 0.7,
                durationSeconds: 300,
                speedGrade: '正常',
              ));
        id++;
      }
    }
    return FakeRepo(records: records, metrics: metrics, baseDayMs: base.millisecondsSinceEpoch);
  }

  /// Attribute snapshot for the in-memory fixture repo.
  ///
  /// ADR-19 removed the ability to derive this from a hardcoded classId switch: `chips` became
  /// 脆性高加工零食 and id 2 became `gummies` (黏弹性零食), so `0 || 2 => 脆性食品` was wrong on
  /// both rows at once. The values are now read from the class table, which is the same source
  /// `foods.json` and `FoodClassId` use -- one table, three consumers.
  static String _attributeFor(int classId) =>
      _classAttributes[classId] ?? _classAttributes.last;

  /// Mirrors FF-19's 知识库属性 column, in class-id order (see `foods.json`).
  static const List<String> _classAttributes = [
    '脆性高加工零食',
    '脆爽蔬菜',
    '黏弹性零食',
    '软性主食',
    '脆爽蔬菜',
    '液体',
  ];

  /// Convenience for tests: the SSOT kcal table as a plain map.
  static Map<int, int> get defaultKcalTable => Map<int, int>.from(_defaultKcal);

  /// P95 helper kept here so both the UI and the diagnostics use one definition.
  static double p95(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.from(values)..sort();
    return sorted[math.min(sorted.length - 1, ((sorted.length - 1) * 0.95).round())];
  }
}

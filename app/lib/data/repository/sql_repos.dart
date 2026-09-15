import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../core/time.dart';
import '../../domain/model/diet_record.dart';
import '../../domain/model/summaries.dart';
import '../../domain/repository/repositories.dart';
import '../db/app_database.dart';
import '../db/sqlite_ffi.dart';

/// L3 DAOs (`API-03` section 3). Internal to the data layer -- `U-*` must never see them.
///
/// Every write takes an executor so the caller owns the transaction (invariant I-3);
/// no DAO ever opens a database of its own.
class DietDao {
  DietDao(this.txn);

  final SqlExecutor txn;

  Future<void> insert(DietRecord r) async {
    await txn.execute(
      'INSERT INTO diet_record (record_id, eaten_at_ms, ended_at_ms, class_label, '
      'class_id, attribute, confidence, duration_seconds, source, corrected_by_user, '
      'confirmed_by_user) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [
        r.recordId,
        r.eatenAtMs,
        r.endedAtMs,
        r.classLabel,
        r.classId,
        r.attribute,
        r.confidence,
        r.durationSeconds,
        r.source,
        r.correctedByUser ? 1 : 0,
        r.confirmedByUser ? 1 : 0,
      ],
    );
  }

  /// Always ascending by `eaten_at_ms`: the records timeline depends on it and the UI must
  /// not have to sort (API-03 section 3, "row order").
  Future<List<DietRecord>> selectByRange(DateRange r) async {
    final rows = await txn.query(
      'SELECT * FROM diet_record WHERE eaten_at_ms >= ? AND eaten_at_ms < ? '
      'ORDER BY eaten_at_ms ASC',
      [r.startMs, r.endMs],
    );
    return rows.map(DietRecord.fromMap).toList();
  }

  Future<DietRecord?> selectById(String recordId) async {
    final rows =
        await txn.query('SELECT * FROM diet_record WHERE record_id = ?', [recordId]);
    if (rows.isEmpty) return null;
    return DietRecord.fromMap(rows.first);
  }

  Future<int> deleteById(String recordId) async {
    await txn.execute('DELETE FROM diet_record WHERE record_id = ?', [recordId]);
    return _changes();
  }

  Future<int> deleteAll() async {
    await txn.execute('DELETE FROM diet_record');
    return _changes();
  }

  Future<int> countAll() async {
    final rows = await txn.query('SELECT COUNT(*) AS c FROM diet_record');
    return (rows.first['c'] as num).toInt();
  }

  Future<int> _changes() async {
    final rows = await txn.query('SELECT changes() AS c');
    return (rows.first['c'] as num).toInt();
  }
}

class MetricsDao {
  MetricsDao(this.txn);

  final SqlExecutor txn;

  /// Placeholder row: the row must exist even when every field is NULL (invariant I-1).
  Future<void> insertPlaceholder(String recordId) async {
    await txn.execute(
      'INSERT INTO behavior_metrics (record_id, chew_count, avg_chew_interval_seconds, '
      'duration_seconds, speed_grade) VALUES (?, NULL, NULL, NULL, NULL)',
      [recordId],
    );
  }

  Future<void> insert(BehaviorMetrics m, String recordId) async {
    await txn.execute(
      'INSERT INTO behavior_metrics (record_id, chew_count, avg_chew_interval_seconds, '
      'duration_seconds, speed_grade) VALUES (?,?,?,?,?)',
      [
        recordId,
        m.chewCount,
        m.avgChewIntervalSeconds,
        m.durationSeconds,
        m.speedGrade,
      ],
    );
  }

  Future<BehaviorMetrics?> selectByRecordId(String recordId) async {
    final rows = await txn
        .query('SELECT * FROM behavior_metrics WHERE record_id = ?', [recordId]);
    if (rows.isEmpty) return null;
    return BehaviorMetrics.fromMap(rows.first);
  }

  Future<int> count() async {
    final rows = await txn.query('SELECT COUNT(*) AS c FROM behavior_metrics');
    return (rows.first['c'] as num).toInt();
  }
}

class ProfileDao {
  ProfileDao(this.txn);

  final SqlExecutor txn;

  /// Returns the default profile when the table is empty; never throws (normal empty state).
  Future<UserProfile> select() async {
    final rows = await txn.query('SELECT * FROM user_profile WHERE id = 1');
    if (rows.isEmpty) return UserProfile.defaults;
    return UserProfile.fromMap(rows.first);
  }

  Future<void> upsert(UserProfile p) async {
    // `INSERT OR REPLACE` rather than `ON CONFLICT DO UPDATE`: the single-row profile table
    // has no other columns to preserve, and this form works on older SQLite builds too.
    await txn.execute(
      'INSERT OR REPLACE INTO user_profile '
      '(id, nickname, target_meals_per_day, reminder_enabled, privacy_banner_enabled) '
      'VALUES (1,?,?,?,?)',
      [
        p.nickname,
        p.targetMealsPerDay,
        p.reminderEnabled ? 1 : 0,
        p.privacyBannerEnabled ? 1 : 0,
      ],
    );
  }

  Future<void> resetToDefaults() async {
    await txn.execute('DELETE FROM user_profile');
    await upsert(UserProfile.defaults);
  }
}

class MetaDao {
  MetaDao(this.txn);

  final SqlExecutor txn;

  Future<String?> get(String key) async {
    final rows = await txn.query('SELECT value FROM app_meta WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> put(String key, String value, int updatedAtMs) async {
    // Same compatibility reasoning as the profile upsert.
    await txn.execute('DELETE FROM app_meta WHERE key = ?', [key]);
    await txn.execute(
      'INSERT INTO app_meta (key, value, updated_at_ms) VALUES (?,?,?)',
      [key, value, updatedAtMs],
    );
  }

  Future<void> remove(String key) async {
    await txn.execute('DELETE FROM app_meta WHERE key = ?', [key]);
  }
}

// --------------------------------------------------------------------------- repos

/// `DietRepo` over SQLite (`API-03` section 4).
class DietRepoImpl implements DietRepo {
  DietRepoImpl(this.db);

  final AppDatabase db;

  SqlExecutor get _exec => db.executor;

  @override
  Future<void> insertSession({
    required DietRecord record,
    required BehaviorMetrics? metrics,
  }) async {
    final problems = record.validate();
    if (problems.isNotEmpty) throw Errors.dbInvalid(problems.join('; '));
    try {
      await _exec.transaction((txn) async {
        await DietDao(txn).insert(record);
        // I-1: exactly one metrics row, placeholder when there is no evidence.
        await MetricsDao(txn).insert(
          metrics ?? BehaviorMetrics.placeholder,
          record.recordId,
        );
      });
    } on AcouDietError catch (e) {
      final detail = '${e.detail} ${e.message}';
      if (detail.contains('UNIQUE') || detail.contains('PRIMARY KEY')) {
        // A duplicate primary key is a caller error, not a transient failure.
        throw AcouDietError(Codes.dbUniqueConstraint, 'duplicate recordId',
            detail: {'recordId': record.recordId});
      }
      // The transaction wrapper already rolled back (I-3).
      throw AcouDietError(Codes.dbTransaction, 'insert failed and was rolled back',
          detail: {'reason': detail}, retryable: true);
    } catch (e) {
      throw AcouDietError(Codes.dbTransaction, 'insert failed and was rolled back',
          detail: {'reason': '$e'}, retryable: true);
    }
  }

  @override
  Future<List<DietRecord>> byRange(DateRange r) async {
    if (r.startMs > r.endMs) throw Errors.dbInvalid('range reversed');
    return DietDao(_exec).selectByRange(r);
  }

  @override
  Future<DietRecord?> byId(String recordId) => DietDao(_exec).selectById(recordId);

  @override
  Future<int> deleteById(String recordId) => DietDao(_exec).deleteById(recordId);

  @override
  Future<int> deleteAll() => DietDao(_exec).deleteAll();

  @override
  Future<int> countAll() => DietDao(_exec).countAll();

  @override
  Future<BehaviorMetrics?> metricsByRecordId(String recordId) async {
    if (await DietDao(_exec).selectById(recordId) == null) return null;
    final m = await MetricsDao(_exec).selectByRecordId(recordId);
    // A record always has a metrics row (I-1); if it is somehow missing, report the
    // placeholder shape rather than "no record".
    return m ?? BehaviorMetrics.placeholder;
  }
}

/// `StatsRepo` over SQLite (`API-03` section 5, `SPEC-D-03`).
///
/// Every aggregate is a single `GROUP BY` query -- never an N+1 walk over records. The meal
/// window classification is applied in Dart against [MealWindows], so the window boundaries
/// exist in exactly one place (the SSOT projection) rather than being duplicated in SQL.
class StatsRepoImpl implements StatsRepo {
  StatsRepoImpl({required this.db, required this.kcal, int Function()? clock})
      : _clock = clock ?? TimeUtil.nowMs;

  final AppDatabase db;
  final KcalResolver kcal;

  /// Injectable clock. The real app uses the device clock; tests pin it so that
  /// "current window" queries are reproducible (`API-05` section 6.1).
  final int Function() _clock;

  SqlExecutor get _exec => db.executor;

  @override
  Future<TodaySummary> today() async {
    final now = _clock();
    final range = DateRange(TimeUtil.startOfLocalDay(now), TimeUtil.startOfNextLocalDay(now));
    final agg = await summary(range);
    final records = await DietDao(_exec).selectByRange(range);
    return TodaySummary(
      recordCount: agg.recordCount,
      estimatedKcal: agg.estimatedKcal,
      snackCount: agg.snackCount,
      records: records,
    );
  }

  @override
  Future<WeekSummary> week() async {
    final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _clock());
    return summary(DateRange(start, end));
  }

  @override
  Future<WeekSummary> summary(DateRange range) async {
    if (range.startMs > range.endMs) throw Errors.dbInvalid('range reversed');
    final exec = _exec;

    // One query for per-class counts (kcal + structure), one for the minute × class histogram
    // (snack / late-night / sigma). Two GROUP BY statements, zero N+1.
    //
    // ADR-23: the histogram carries `class_label` as well, because "is this a snack?" is no
    // longer a time-only question -- a liquid outside a meal window is its own category, not a
    // snack. Aggregating by minute alone could not express that.
    final classRows = await exec.query(
      'SELECT class_label AS label, COUNT(*) AS c FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ? GROUP BY class_label',
      [range.startMs, range.endMs],
    );

    final histogram = await exec.query(
      'SELECT CAST(strftime(\'%H\', eaten_at_ms / 1000, \'unixepoch\', \'localtime\') '
      'AS INTEGER) AS h, '
      'CAST(strftime(\'%M\', eaten_at_ms / 1000, \'unixepoch\', \'localtime\') '
      'AS INTEGER) AS m, class_label AS label, COUNT(*) AS c FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ? GROUP BY h, m, label',
      [range.startMs, range.endMs],
    );

    final counts = <String, int>{for (final l in cfg.FeatureConfig.classLabels) l: 0};
    var recordCount = 0;
    for (final row in classRows) {
      final label = row['label'] as String;
      final c = (row['c'] as num).toInt();
      counts[label] = (counts[label] ?? 0) + c;
      recordCount += c;
      if (cfg.FeatureConfig.classLabels.indexOf(label) < 0) {
        // Unknown label: the knowledge base cannot resolve it, and silently using 0 would
        // make the estimate quietly wrong (API-03 section 3).
        throw Errors.kb('unregistered class label "$label"');
      }
    }

    // ADR-23: the energy estimate is the **sum of per-record estimates**, each derived from
    // that record's own duration. Summing the durations per class and clamping once is a
    // different number (the estimate clamps per event), and the home total would then disagree
    // with the sum of the record cards the user can tap. One more flat query -- still O(1)
    // statements, no N+1.
    final durationRows = await exec.query(
      'SELECT class_label AS label, duration_seconds AS d FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ?',
      [range.startMs, range.endMs],
    );
    var kcalTotal = 0;
    for (final row in durationRows) {
      final label = row['label'] as String;
      final classId = cfg.FeatureConfig.classLabels.indexOf(label);
      if (classId < 0) {
        throw Errors.kb('unregistered class label "$label"');
      }
      kcalTotal += kcal.kcalForDuration(classId, (row['d'] as num?)?.toInt() ?? 0);
    }

    var snack = 0;
    var lateNight = 0;
    final mealMinutes = <String, List<int>>{
      'breakfast': [],
      'lunch': [],
      'dinner': [],
    };
    for (final row in histogram) {
      final minutes = (row['h'] as num).toInt() * 60 + (row['m'] as num).toInt();
      final c = (row['c'] as num).toInt();
      final label = row['label'] as String;
      final classId = cfg.FeatureConfig.classLabels.indexOf(label);
      if (classId < 0) {
        throw Errors.kb('unregistered class label "$label"');
      }
      // ADR-23: a snack is a solid food outside the meal windows; liquids are their own
      // category and are neither snacks nor meal samples.
      if (MealWindows.isSnackRecord(minutes, classId)) snack += c;
      if (MealWindows.isLateNight(minutes)) lateNight += c;
      if (MealWindows.isMealSample(minutes, classId)) {
        final name = MealWindows.mealName(minutes);
        for (var i = 0; i < c; i++) {
          mealMinutes[name]!.add(minutes);
        }
      }
    }

    // Sigma exactly as API-03 section 5.3: per-meal-class sample sd (n-1), classes with
    // fewer than two samples ignored, then the arithmetic mean of the accepted ones.
    final deviations = <double>[];
    for (final entry in mealMinutes.entries) {
      if (entry.value.length < 2) continue;
      final sd = sampleStdDev(entry.value);
      if (sd != null) deviations.add(sd);
    }
    final sigma = deviations.isEmpty
        ? null
        : deviations.reduce((a, b) => a + b) / deviations.length;

    return WeekSummary(
      recordCount: recordCount,
      estimatedKcal: kcalTotal,
      snackCount: snack,
      lateNightCount: lateNight,
      mealTimeStdDevMinutes: sigma,
      classCounts: counts,
    );
  }

  @override
  Future<ChewStats> chewStats(DateRange range) async {
    // Duration-weighted mean: `avg_chew_interval_seconds` is itself a per-record mean, so
    // weighting by that record's duration reconstructs the window mean (SPEC-A-01 A-01-K3).
    final rows = await _exec.query(
      'SELECT COUNT(*) AS n, '
      'SUM(m.avg_chew_interval_seconds * m.duration_seconds) AS acc, '
      'SUM(m.duration_seconds) AS w '
      'FROM behavior_metrics m JOIN diet_record r ON r.record_id = m.record_id '
      'WHERE r.eaten_at_ms >= ? AND r.eaten_at_ms < ? '
      'AND m.avg_chew_interval_seconds IS NOT NULL '
      'AND m.duration_seconds IS NOT NULL AND m.duration_seconds > 0',
      [range.startMs, range.endMs],
    );
    final row = rows.first;
    final n = (row['n'] as num?)?.toInt() ?? 0;
    final w = (row['w'] as num?)?.toDouble() ?? 0;
    final acc = (row['acc'] as num?)?.toDouble() ?? 0;
    return ChewStats(
      sampleCount: n,
      meanChewIntervalSeconds: (n > 0 && w > 0) ? acc / w : null,
    );
  }

  @override
  Future<List<int>> mealTimeSamples(DateRange range) async {
    final rows = await _exec.query(
      'SELECT CAST(strftime(\'%H\', eaten_at_ms / 1000, \'unixepoch\', \'localtime\') '
      'AS INTEGER) AS h, '
      'CAST(strftime(\'%M\', eaten_at_ms / 1000, \'unixepoch\', \'localtime\') '
      'AS INTEGER) AS m, COUNT(*) AS c FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ? GROUP BY h, m',
      [range.startMs, range.endMs],
    );
    final out = <int>[];
    for (final row in rows) {
      final minutes = (row['h'] as num).toInt() * 60 + (row['m'] as num).toInt();
      if (!MealWindows.isMainMeal(minutes)) continue;
      final c = (row['c'] as num).toInt();
      for (var i = 0; i < c; i++) {
        out.add(minutes);
      }
    }
    out.sort();
    return out;
  }

  @override
  Future<List<TrendPoint>> trend(int days) async {
    if (days < 1 || days > 365) throw Errors.dbInvalid('days out of [1,365]: $days');
    final (start, end) = TimeUtil.lastLocalDays(days, nowMsOverride: _clock());
    final rows = await _exec.query(
      'SELECT date(eaten_at_ms / 1000, \'unixepoch\', \'localtime\') AS d, '
      'class_label AS label, duration_seconds AS dur FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ?',
      [start, end],
    );

    // kcal per day, aggregated in Dart so the knowledge base stays the only kcal source --
    // and per record, so a day's total equals the sum of that day's record cards (ADR-23).
    final kcalByDay = <String, int>{};
    for (final row in rows) {
      final day = row['d'] as String;
      final label = row['label'] as String;
      final classId = cfg.FeatureConfig.classLabels.indexOf(label);
      if (classId < 0) throw Errors.kb('unregistered class label "$label"');
      kcalByDay[day] = (kcalByDay[day] ?? 0) +
          kcal.kcalForDuration(classId, (row['dur'] as num?)?.toInt() ?? 0);
    }

    // Gapless series: every local day in the window appears, empty days with null (not 0).
    final out = <TrendPoint>[];
    for (final key in TimeUtil.dayKeysInRange(start, end)) {
      out.add(TrendPoint(
        date: key,
        estimatedKcal: kcalByDay[key],
        totalScore: null, // L3 never fills this (API-03 section 5)
      ));
    }
    return out;
  }

  @override
  Future<MealTimeDistribution> mealTimes(int days) async {
    if (days < 1 || days > 365) throw Errors.dbInvalid('days out of [1,365]: $days');
    final (start, end) = TimeUtil.lastLocalDays(days, nowMsOverride: _clock());
    final rows = await _exec.query(
      'SELECT CAST(strftime(\'%H\', eaten_at_ms / 1000, \'unixepoch\', \'localtime\') '
      'AS INTEGER) AS h, COUNT(*) AS c FROM diet_record '
      'WHERE eaten_at_ms >= ? AND eaten_at_ms < ? GROUP BY h',
      [start, end],
    );
    final byHour = <int, int>{for (var h = 0; h < 24; h++) h: 0};
    for (final row in rows) {
      byHour[(row['h'] as num).toInt()] = (row['c'] as num).toInt();
    }
    return MealTimeDistribution(byHour);
  }

  @override
  Future<int> activeDays() async {
    final rows = await _exec.query(
      'SELECT COUNT(DISTINCT date(eaten_at_ms / 1000, \'unixepoch\', \'localtime\')) AS c '
      'FROM diet_record',
    );
    return (rows.first['c'] as num).toInt();
  }
}

/// `ProfileRepo` over SQLite (`API-03` section 6).
class ProfileRepoImpl implements ProfileRepo {
  ProfileRepoImpl(this.db);

  final AppDatabase db;

  @override
  Future<UserProfile> load() => ProfileDao(db.executor).select();

  @override
  Future<void> save(UserProfile p) async {
    p.assertValid();
    await ProfileDao(db.executor).upsert(p);
  }
}

/// `MaintenanceRepo` over SQLite (`API-03` section 7, `SPEC-D-05`).
class MaintenanceRepoImpl implements MaintenanceRepo {
  MaintenanceRepoImpl({
    required this.db,
    required this.nativeAudioCleaner,
    this.tempFileCounter,
  });

  final AppDatabase db;

  /// Bridge to `API-01` section 2.7. There must be exactly one `audio_*` matcher in the
  /// project, and it lives on the native side -- this port is how Dart reaches it.
  final Future<int> Function() nativeAudioCleaner;

  /// Reads `getDiagnostics().tempAudioFiles`. `null` (or a thrown error) renders as `-1`,
  /// which `M-04` shows as "not determinable" rather than as a pass.
  final Future<int> Function()? tempFileCounter;

  @override
  Future<int> clearAllData() async {
    var affected = 0;
    await db.executor.transaction((txn) async {
      final records = await DietDao(txn).countAll();
      final metrics = await MetricsDao(txn).count();
      await DietDao(txn).deleteAll(); // behavior_metrics cascades (I-1)
      await ProfileDao(txn).resetToDefaults();
      await MetaDao(txn).remove('demoDatasetFingerprint');
      affected = records + metrics + 1;
    });
    return affected;
  }

  @override
  Future<int> clearTempAudio() async {
    // Must delegate: a second matcher on this side would mean two behaviours and two counts.
    try {
      return await nativeAudioCleaner();
    } catch (_) {
      // ACD-IO-001 semantics: never blocks the main flow; the counter simply reports 0.
      return 0;
    }
  }

  @override
  Future<int> countTempAudioFiles() async {
    final f = tempFileCounter;
    if (f == null) return -1;
    try {
      return await f();
    } catch (_) {
      return -1;
    }
  }
}

/// Utility used by the demo-data controller: fingerprint a JSON payload without any
/// third-party hash package (FNV-1a 64-bit, plenty for change detection).
String fingerprintOf(String text) {
  const int offset = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  var hash = offset;
  final bytes = Uint8List.fromList(text.codeUnits);
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

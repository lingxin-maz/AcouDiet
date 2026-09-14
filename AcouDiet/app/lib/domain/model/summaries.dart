import '../../core/feature_config.g.dart' as cfg;
import '../../core/time.dart';
import 'diet_record.dart';
import 'health_score.dart';

/// Meal windows -- **the single authoritative definition is `API-03` section 5**.
///
/// Never define a second set of window constants anywhere else (SPEC-00 section 5 rule 2).
/// The values live in the SSOT (`meal_windows`) and are projected here as minutes of the
/// local day, half-open `[start, end)`; `late_night` wraps past midnight.
class MealWindows {
  MealWindows._();

  static List<int> get breakfast => cfg.FeatureConfig.mealWindowsBreakfast;
  static List<int> get lunch => cfg.FeatureConfig.mealWindowsLunch;
  static List<int> get dinner => cfg.FeatureConfig.mealWindowsDinner;
  static List<int> get lateNight => cfg.FeatureConfig.mealWindowsLateNight;

  static bool _inWindow(int minutes, List<int> w) {
    final start = w[0];
    final end = w[1];
    if (start <= end) return minutes >= start && minutes < end;
    // wraps past midnight
    return minutes >= start || minutes < end;
  }

  static bool isBreakfast(int minutes) => _inWindow(minutes, breakfast);
  static bool isLunch(int minutes) => _inWindow(minutes, lunch);
  static bool isDinner(int minutes) => _inWindow(minutes, dinner);

  /// A "main meal" is any of the three meal windows (snacks are the complement).
  static bool isMainMeal(int minutes) =>
      isBreakfast(minutes) || isLunch(minutes) || isDinner(minutes);

  /// Snack = the complement of the three meal windows; deliberately *not* disjoint from
  /// `lateNight` -- they are two different product metrics, not a partition.
  ///
  /// This is the **time-only** predicate. Product metrics must use [isSnackRecord] instead:
  /// ADR-23 made a liquid its own category, so a 15:40 drink is no longer a snack.
  static bool isSnack(int minutes) => !isMainMeal(minutes);

  /// The frozen `FF-19` label of the liquid class.
  static const String liquidLabel = 'drink';

  /// The class id of [liquidLabel], resolved from the SSOT class table rather than written as a
  /// literal `5` (the ids are positional and `ADR-19` already moved classes once).
  ///
  /// A missing label is a **configuration defect**, not a silent no-op: without it the liquid
  /// rule would quietly stop excluding drinks, which is exactly the bug ADR-23 fixes.
  static final int liquidClassId = _resolveLiquidClassId();

  static int _resolveLiquidClassId() {
    final id = cfg.FeatureConfig.classLabels.indexOf(liquidLabel);
    if (id < 0) {
      throw StateError('class_labels has no "$liquidLabel" (FF-19 / ADR-23)');
    }
    return id;
  }

  /// ADR-23 -- **a snack is a solid food eaten outside the three meal windows.**
  ///
  /// Before this rule the snack count was purely temporal, so an afternoon drink was counted as
  /// a snack *and* as its own class in the same aggregate: the same event was counted twice, and
  /// 「零食控制」 was penalised for drinking water. A liquid outside a meal window now counts as
  /// neither a snack nor a meal; it is simply its own category.
  static bool isSnackRecord(int minutes, int classId) =>
      isSnack(minutes) && classId != liquidClassId;

  /// A liquid inside a meal window is **not** a meal sample either: it must not enter the
  /// regularity σ (`API-03` section 5.3 takes per-meal-class samples; a drink is not one).
  static bool isMealSample(int minutes, int classId) =>
      !isSnack(minutes) && classId != liquidClassId;

  /// Late-night eating is `[20:00, 05:00)` (the `计划书 v1` definition). ADR-23 kept this one
  /// purely temporal on purpose: 「晚间进食」 is a *time* metric, and a late drink still is
  /// late eating.
  static bool isLateNight(int minutes) => _inWindow(minutes, lateNight);

  static String mealName(int minutes) => isBreakfast(minutes)
      ? 'breakfast'
      : isLunch(minutes)
          ? 'lunch'
          : isDinner(minutes)
              ? 'dinner'
              : 'snack';
}

/// Aggregates for the "today" card (`API-03` section 5).
class TodaySummary {
  const TodaySummary({
    required this.recordCount,
    required this.estimatedKcal,
    required this.snackCount,
    required this.records,
  });

  final int recordCount;

  /// `Σ KcalResolver.kcalFor(classId)` -- an **estimate** in the knowledge-base + standard
  /// portion sense, and it may only be displayed next to the portion description (FF-25).
  final int estimatedKcal;
  final int snackCount;
  final List<DietRecord> records;

  static const TodaySummary empty =
      TodaySummary(recordCount: 0, estimatedKcal: 0, snackCount: 0, records: []);
}

/// Aggregates over an arbitrary half-open window; `week()` is the 7-local-day case.
class WeekSummary {
  const WeekSummary({
    required this.recordCount,
    required this.estimatedKcal,
    required this.snackCount,
    required this.lateNightCount,
    required this.mealTimeStdDevMinutes,
    required this.classCounts,
  });

  final int recordCount;
  final int estimatedKcal;
  final int snackCount;

  /// `eatenAtMs` local hour inside `[20:00, 05:00)`.
  final int lateNightCount;

  /// `API-03` section 5.3 definition; `null` when no meal class had `>= 2` samples.
  /// This is the **only** entry point for FF-22's `regularity` input -- L4 must not
  /// recompute sigma from raw samples.
  final double? mealTimeStdDevMinutes;

  /// Keyed by the six frozen labels; **all six keys are always present** (missing => 0).
  final Map<String, int> classCounts;

  static WeekSummary empty() => WeekSummary(
        recordCount: 0,
        estimatedKcal: 0,
        snackCount: 0,
        lateNightCount: 0,
        mealTimeStdDevMinutes: null,
        classCounts: {for (final l in cfg.FeatureConfig.classLabels) l: 0},
      );

  int countOf(String label) => classCounts[label] ?? 0;

  /// Completeness guard: `U-*` and the scoring service both rely on a full key set.
  void assertComplete() {
    for (final label in cfg.FeatureConfig.classLabels) {
      if (!classCounts.containsKey(label)) {
        throw StateError('classCounts is missing "$label" (API-03 section 5)');
      }
    }
  }
}

/// One point of the trend series. `totalScore` is **filled by L4** (`ReportService`),
/// because L3 must not contain scoring rules (invariant I-4).
class TrendPoint {
  const TrendPoint({required this.date, this.estimatedKcal, this.totalScore});

  /// `yyyy-MM-dd` in the device's local time zone.
  final String date;

  /// `null` (not `0`) when the day has no record: "no data" and "zero kcal" differ.
  final int? estimatedKcal;

  final int? totalScore;

  TrendPoint copyWith({int? estimatedKcal, int? totalScore}) => TrendPoint(
        date: date,
        estimatedKcal: estimatedKcal ?? this.estimatedKcal,
        totalScore: totalScore ?? this.totalScore,
      );
}

/// One local day's report (ADR-23) -- the report page's 「每日」 scope.
///
/// The report page's 本周 scope scores the whole seven-day window; this is the per-day breakdown,
/// so a reader can see *which* day was off instead of only the weekly average.
class DailyScore {
  const DailyScore({
    required this.date,
    required this.estimatedKcal,
    required this.recordCount,
    required this.snackCount,
    required this.classCounts,
    required this.score,
  });

  /// `yyyy-MM-dd` in the device's local time zone (same key as `TrendPoint.date`).
  final String date;

  /// `null` (not `0`) when the day has no record: "no data" and "zero kcal" differ.
  final int? estimatedKcal;

  /// Records logged on this day; `0` means the day is empty (and the page omits it).
  final int recordCount;

  /// Solid snacks only (`ADR-23`: a drink is never a snack).
  final int snackCount;

  /// The six frozen labels, all keys present (missing => 0).
  final Map<String, int> classCounts;

  /// `null` when the day has no records at all, or when it could not be scored
  /// (`SPEC-A-03` section 6: one unscorable day must not break the series).
  final HealthScore? score;

  /// `true` when the day has anything to report. A day with records whose four dimensions are
  /// not all displayable still counts as data: the per-day summary rows are real numbers.
  bool get hasData => recordCount > 0;

  int countOf(String label) => classCounts[label] ?? 0;
}

/// Distribution of records over the local hour of day; always 24 keys.
class MealTimeDistribution {
  const MealTimeDistribution(this.byHour);

  final Map<int, int> byHour;

  static MealTimeDistribution empty() =>
      MealTimeDistribution({for (var h = 0; h < 24; h++) h: 0});

  int hourOf(int h) => byHour[h] ?? 0;

  void assertComplete() {
    for (var h = 0; h < 24; h++) {
      if (!byHour.containsKey(h)) {
        throw StateError('byHour is missing hour $h (API-03 section 5)');
      }
    }
  }
}

/// Chewing statistics for a window -- the direct input of FF-22's `speed` dimension.
class ChewStats {  const ChewStats({required this.sampleCount, this.meanChewIntervalSeconds});

  final int sampleCount;

  /// `null` iff `sampleCount == 0`.
  final double? meanChewIntervalSeconds;

  static const ChewStats empty = ChewStats(sampleCount: 0);
}

/// `mealTimeStdDevMinutes` per `API-03` section 5.3 -- one implementation, used by the
/// stats repository (and asserted against hand-computed fixtures in the tests).
///
/// ADR-23: liquids are excluded (`MealWindows.isMealSample`), because a drink is not a meal.
double? mealTimeStdDevMinutesOf(Iterable<DietRecord> records) {
  final buckets = <String, List<int>>{'breakfast': [], 'lunch': [], 'dinner': []};
  for (final r in records) {
    final minutes = TimeUtil.minutesOfLocalDay(r.eatenAtMs);
    if (!MealWindows.isMealSample(minutes, r.classId)) continue;
    buckets[MealWindows.mealName(minutes)]!.add(minutes);
  }
  final deviations = <double>[];
  for (final entry in buckets.entries) {
    final samples = entry.value;
    if (samples.length < 2) continue;
    final sd = sampleStdDev(samples);
    if (sd != null) deviations.add(sd);
  }
  if (deviations.isEmpty) return null;
  return deviations.reduce((a, b) => a + b) / deviations.length;
}

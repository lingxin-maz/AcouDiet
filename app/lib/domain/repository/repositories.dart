import '../../core/time.dart';
import '../model/diet_record.dart';
import '../model/summaries.dart';

/// Data-access contracts (`API-03` sections 4-7). Implemented in `lib/data/`.
///
/// Invariants that every implementation must honour:
///  * **I-1** `diet_record` and `behavior_metrics` are strictly 1:1; a record with no
///    metrics still gets a placeholder row;
///  * **I-2** no BLOB audio, no Mel tensor, no waveform, no audio file path may ever be
///    stored;
///  * **I-3** one session's write is a single transaction (1 record + 1 metrics row);
///  * **I-4** this layer contains no business rules -- no scoring, no advice, no speed
///    grading.
abstract class DietRepo {
  /// Single transaction: writes exactly one record row and one metrics row (I-1/I-3).
  /// `metrics == null` writes a placeholder row.
  Future<void> insertSession({
    required DietRecord record,
    required BehaviorMetrics? metrics,
  });

  /// Half-open `[startMs, endMs)`, ascending by `eatenAtMs` (the UI must not re-sort).
  Future<List<DietRecord>> byRange(DateRange r);

  Future<DietRecord?> byId(String recordId);

  Future<int> deleteById(String recordId);

  Future<int> deleteAll();

  Future<int> countAll();

  /// 1:1 lookup. Returns `null` when the record does not exist, and a **fully null**
  /// [BehaviorMetrics] when it exists but its metrics row is a placeholder -- so that
  /// "no record" and "record without metrics" stay distinguishable.
  Future<BehaviorMetrics?> metricsByRecordId(String recordId);
}

/// Chewing aggregation for one window; the direct input of FF-22's `speed` dimension.
abstract class StatsRepo {
  Future<TodaySummary> today();

  /// `summary` of the most recent 7 local calendar days; must equal
  /// `summary(lastLocalDays(7))` field by field.
  Future<WeekSummary> week();

  Future<List<TrendPoint>> trend(int days);

  Future<MealTimeDistribution> mealTimes(int days);

  /// Arbitrary half-open window aggregate (added by revision A-1 so that `A-03` can obtain
  /// the previous equal-length window; `week()` has no parameters and cannot).
  Future<WeekSummary> summary(DateRange range);

  Future<ChewStats> chewStats(DateRange range);

  /// Minutes-of-local-day of each *meal-window* record in the range, ascending.
  /// Provided for evidence/verification; sigma itself still comes from
  /// `WeekSummary.mealTimeStdDevMinutes` and must not be recomputed in L4.
  Future<List<int>> mealTimeSamples(DateRange range);

  /// Number of local calendar days with at least one record, over all history.
  Future<int> activeDays();
}

abstract class ProfileRepo {
  /// Returns the default profile (never throws) when the table is empty.
  Future<UserProfile> load();

  Future<void> save(UserProfile p);
}

abstract class MaintenanceRepo {
  /// Single transaction: clears `diet_record` + `behavior_metrics` and resets
  /// `user_profile` to defaults (keeping the row). Returns the number of affected rows.
  Future<int> clearAllData();

  /// Must delegate to the native `clearTempAudio` (API-01 section 2.7) -- no second
  /// `audio_*` matcher may exist on the Dart side.
  Future<int> clearTempAudio();

  Future<int> countTempAudioFiles();
}

/// Port used by `StatsRepo` to fill `estimatedKcal`, because L3 may not depend on the L4
/// knowledge-base class (`API-00` section 1 rule 3). The assembly layer injects an adapter
/// over `FoodKnowledgeBase`.
abstract class KcalResolver {
  /// Standard-portion kilocalories. Must throw `ACD-KB-001` for an unregistered `classId`
  /// rather than silently using 0.
  int kcalFor(int classId);

  /// Kilocalories of one eating event that lasted [durationSeconds] (ADR-23).
  ///
  /// The knowledge-base adapter scales `portionKcal` by the estimated amount; an
  /// implementation with no portion model (the test stubs) may keep the standard portion,
  /// which is why this has a default body rather than being abstract.
  int kcalForDuration(int classId, int durationSeconds) => kcalFor(classId);
}

/// Convenience: `stats.week()` is defined in terms of `summary()` (revision A-1).
Future<WeekSummary> weekFromSummary(StatsRepo repo, {int? nowMs}) {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: nowMs);
  return repo.summary(DateRange(start, end));
}

import 'dart:math' as math;

/// Time helpers implementing `API-00` section 3.2.
///
/// Storage and transport are always epoch milliseconds UTC; *bucketing* (today, this week,
/// the hour of day, meal windows) is always done in the **device local time zone**. Nothing
/// in the domain layer ever formats a string for display -- that is the `U-*` layer's job.
class TimeUtil {
  TimeUtil._();

  static int nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Local calendar day key `yyyy-MM-dd` (the grouping unit for `D-03`).
  static String dayKey(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static String dayKeyOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Local midnight (00:00) of the calendar day containing [epochMs].
  static int startOfLocalDay(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  /// Start of the next local calendar day; `DateRange` is half-open `[start, end)`.
  static int startOfNextLocalDay(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return DateTime(d.year, d.month, d.day).add(const Duration(days: 1))
        .millisecondsSinceEpoch;
  }

  /// Minutes since local midnight, `0..1439` (the unit of the meal windows).
  static int minutesOfLocalDay(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return d.hour * 60 + d.minute;
  }

  /// Local hour `0..23` (the unit of `MealTimeDistribution.byHour`).
  static int hourOfLocalDay(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs).hour;

  /// The `days` local calendar days ending today, as a half-open range.
  static (int, int) lastLocalDays(int days, {int? nowMsOverride}) {
    final now = nowMsOverride ?? nowMs();
    final end = startOfNextLocalDay(now);
    var start = end;
    for (var i = 0; i < days; i++) {
      start = startOfLocalDay(start - 1);
    }
    return (start, end);
  }

  /// The `days` local calendar days immediately *before* [rangeStart] -- used for the
  /// week-over-week deltas of `A-03` (`API-04` section 5).
  static (int, int) previousWindowOf(int rangeStart, int rangeEnd) {
    final span = rangeEnd - rangeStart;
    return (rangeStart - span, rangeStart);
  }

  /// Ascending list of `yyyy-MM-dd` keys covering `[startMs, endMs)` in local time.
  static List<String> dayKeysInRange(int startMs, int endMs) {
    final keys = <String>[];
    var cursor = startOfLocalDay(startMs);
    while (cursor < endMs) {
      keys.add(dayKey(cursor));
      cursor = startOfNextLocalDay(cursor);
    }
    return keys;
  }
}

/// Half-open `[startMs, endMs)` epoch-millisecond window (API-03 section 4).
class DateRange {
  const DateRange(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get spanMs => endMs - startMs;

  bool contains(int epochMs) => epochMs >= startMs && epochMs < endMs;

  DateRange get previous => DateRange(startMs - spanMs, startMs);

  /// Number of local calendar days the window touches (used for `evidence.windowDays`).
  int get localDayCount =>
      TimeUtil.dayKeysInRange(startMs, endMs).length.clamp(1, 400);

  @override
  String toString() => 'DateRange($startMs, $endMs)';

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);
}

/// Sample standard deviation (`n-1` denominator), returning `null` when `n < 2`.
///
/// Written with explicit loops rather than `reduce`: `List<num>.reduce` with a closure typed
/// `(num, num) => num` fails at runtime when the list's runtime type is `List<int>`.
double? sampleStdDev(List<num> values) {
  if (values.length < 2) return null;
  final n = values.length;
  var sum = 0.0;
  for (final v in values) {
    sum += v;
  }
  final mean = sum / n;
  var acc = 0.0;
  for (final v in values) {
    final d = v - mean;
    acc += d * d;
  }
  return math.sqrt(acc / (n - 1));
}

/// Arithmetic mean, `null` for an empty list.
double? meanOf(Iterable<num> values) {
  var sum = 0.0;
  var n = 0;
  for (final v in values) {
    sum += v;
    n++;
  }
  if (n == 0) return null;
  return sum / n;
}

/// Nearest-rank percentile on an already sorted list (`p` in `[0,1]`).
double percentileSorted(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0.0;
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}

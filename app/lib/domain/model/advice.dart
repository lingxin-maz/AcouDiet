import 'health_score.dart';
import 'summaries.dart';

/// One lifestyle suggestion (A-02 / API-04 section 4).
class Advice {
  const Advice({
    required this.dimension,
    required this.text,
    required this.priority,
  });

  /// `'regularity'` / `'structure'` / `'snack'` / `'speed'` / `'general'`.
  /// The first four must match the [HealthScore] dimension keys.
  final String dimension;

  /// Chinese body text. No absolute claims, no diagnostic or treatment statements (FF-25).
  final String text;

  /// Lower sorts first; ties break on a fixed dimension order (`general` last).
  final int priority;

  static const String dimRegularity = 'regularity';
  static const String dimStructure = 'structure';
  static const String dimSnack = 'snack';
  static const String dimSpeed = 'speed';
  static const String dimGeneral = 'general';
}

/// A weekly report (A-03 / API-04 section 5).
class WeeklyReport {
  const WeeklyReport({
    required this.startMs,
    required this.endMs,
    required this.summaryText,
    required this.advices,
    required this.score,
    required this.deltas,
  });

  final int startMs;
  final int endMs;

  /// The **only** text field the domain layer may produce (an explicit exception to
  /// "formatting belongs to the UI"). Must not invent numbers when data is missing.
  final String summaryText;

  final List<Advice> advices;
  final HealthScore score;

  /// Period-over-period differences (this window minus the previous equal-length window).
  /// **Exactly seven keys**, all numeric (never `null`):
  /// `totalScore`, `regularity`, `structure`, `snack`, `speed`, `recordCount`,
  /// `estimatedKcal`.
  final Map<String, num> deltas;

  static const List<String> deltaKeys = [
    'totalScore',
    'regularity',
    'structure',
    'snack',
    'speed',
    'recordCount',
    'estimatedKcal',
  ];
}

/// A trend series (A-03). `points.length == days`, ascending, gapless.
class TrendSeries {
  const TrendSeries(this.points);

  final List<TrendPoint> points;

  int get length => points.length;
}

/// Advice ordering, frozen so that two identical runs produce identical output.
class AdviceOrder {
  AdviceOrder._();

  static const Map<String, int> dimensionRank = {
    Advice.dimRegularity: 0,
    Advice.dimStructure: 1,
    Advice.dimSnack: 2,
    Advice.dimSpeed: 3,
    Advice.dimGeneral: 9,
  };

  static List<Advice> sorted(List<Advice> input) {
    final out = List<Advice>.from(input);
    out.sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      if (p != 0) return p;
      final ra = dimensionRank[a.dimension] ?? 99;
      final rb = dimensionRank[b.dimension] ?? 99;
      if (ra != rb) return ra.compareTo(rb);
      return a.text.compareTo(b.text);
    });
    return out;
  }
}

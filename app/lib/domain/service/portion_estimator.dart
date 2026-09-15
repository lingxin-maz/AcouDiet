import 'dart:math' as math;

import '../model/food_info.dart';

/// One eating event's estimated portion (ADR-23).
class PortionEstimate {
  const PortionEstimate({
    required this.amount,
    required this.unit,
    required this.kcal,
    required this.durationSeconds,
    required this.durationBased,
    required this.clamped,
  });

  /// The estimated amount in [unit] (`g` or `ml`), already rounded for display.
  final int amount;

  /// `'g'` or `'ml'`, copied from the knowledge-base entry.
  final String unit;

  /// Estimated kilocalories for **this** amount, `round(portionKcal × amount / standardAmount)`.
  final int kcal;

  /// The eating duration the estimate was derived from (`0` when the record carried none).
  final int durationSeconds;

  /// `false` when no duration was available and the standard portion was used instead. The UI
  /// must not claim a timing basis it does not have.
  final bool durationBased;

  /// `true` when the duration-derived amount hit the class's floor or ceiling: the number is
  /// still the best estimate, but it is bounded by the knowledge base rather than by the clock.
  final bool clamped;

  /// `约 150 g` / `约 250 ml`.
  String get amountText => '约 $amount $unit';

  /// `1 小包（约 30g）`-style fallback description, used when [durationBased] is false.
  String get standardText => '$amount $unit';

  @override
  String toString() =>
      'PortionEstimate($amount$unit, $kcal kcal, ${durationSeconds}s, '
      'durationBased=$durationBased, clamped=$clamped)';
}

/// ADR-23 -- the portion model: **a record's amount comes from that record's own duration.**
///
/// Why this exists: before ADR-23 the app displayed `foods.json`'s standard portion verbatim
/// on every record of a class, so a 15-second bite of noodles and a 10-minute bowl of noodles
/// both read 「1 碗（约 200g）≈280 kcal」. The number never moved, which is exactly what the
/// user reported ("不是真的在动态计算").
///
/// The model is deliberately simple and fully knowledge-base driven:
///
/// ```
/// amount = clamp(round_to_step(amountPerSecond × durationSeconds), minAmount, maxAmount)
/// kcal   = round(portionKcal × amount / standardAmount)
/// ```
///
/// Every parameter comes from `foods.json` (the knowledge-base asset), never from a literal
/// here -- only the two display rounding steps are declared in this file, and they are
/// declared once.
///
/// Two honesty rules:
///  * `durationSeconds <= 0` (a record written without timing evidence) falls back to the
///    **standard portion** and reports `durationBased == false`; it never invents a duration;
///  * the result is clamped into the class's plausible range, so a session left running for
///    twenty minutes cannot produce a five-kilogram lunch.
abstract final class PortionEstimator {
  PortionEstimator._();

  /// Display rounding for solids / liquids. Not a frozen threshold: it only decides which
  /// gram or millilitre the user reads.
  static const int gramsStep = 5;
  static const int millilitresStep = 10;

  static PortionEstimate of(FoodInfo food, {required int durationSeconds}) {
    if (durationSeconds <= 0) {
      return PortionEstimate(
        amount: food.standardAmount,
        unit: food.unit,
        kcal: food.portionKcal,
        durationSeconds: 0,
        durationBased: false,
        clamped: false,
      );
    }

    final step = food.isLiquid ? millilitresStep : gramsStep;
    final raw = food.amountPerSecond * durationSeconds;
    final bounded = raw.clamp(food.minAmount.toDouble(), food.maxAmount.toDouble());
    // Round, then clamp again: rounding must not be able to escape the plausible range.
    var amount = (bounded / step).round() * step;
    amount = amount.clamp(food.minAmount, food.maxAmount);

    final kcal =
        (food.portionKcal * amount / food.standardAmount).round().clamp(0, 100000);
    return PortionEstimate(
      amount: amount,
      unit: food.unit,
      kcal: kcal,
      durationSeconds: durationSeconds,
      durationBased: true,
      clamped: raw < food.minAmount || raw > food.maxAmount,
    );
  }

  /// The amount alone, for callers that need no kilocalories (never used to skip the
  /// estimate label: FF-25 ties every kilocalorie to it).
  static int amountOf(FoodInfo food, {required int durationSeconds}) =>
      of(food, durationSeconds: durationSeconds).amount;

  /// `max(0, ...)` guard shared with the callers that feed a raw column value in.
  static int nonNegative(int seconds) => math.max(0, seconds);
}

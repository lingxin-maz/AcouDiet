/// Knowledge-base entry for one of the six frozen food classes (P-08 / API-04 section 2).
///
/// The `foods.json` file is the source; this object is the in-memory projection. Nothing
/// here is a model output -- attributes, portions and nutrition tags all come from the
/// knowledge base, and `portionKcal` may only ever be displayed together with
/// `portionDesc` and an "estimate" label (FF-25).
///
/// ADR-23 added the portion **model** (`unit` / `standardAmount` / `amountPerSecond` /
/// `minAmount` / `maxAmount`). Before it, every record of a class displayed the same fixed
/// standard portion ("1 碗（约 200g）") no matter how long the meal lasted. The four numbers
/// let `PortionEstimator` derive a per-record amount from that record's own duration.
class FoodInfo {
  const FoodInfo({
    required this.label,
    required this.zhName,
    required this.attribute,
    required this.category,
    required this.portionDesc,
    required this.portionKcal,
    required this.unit,
    required this.standardAmount,
    required this.amountPerSecond,
    required this.minAmount,
    required this.maxAmount,
    required this.nutritionTags,
    required this.riskNote,
  });

  /// One of `feature_config.class_labels`; equals its own key in `foods.json`.
  final String label;

  /// Chinese name, verbatim from FF-19.
  final String zhName;

  /// Knowledge-base attribute (e.g. 「脆性高加工零食」); this value is snapshotted into
  /// `diet_record.attribute` at write time.
  final String attribute;

  final String category;

  /// Standard portion description -- the human-readable partner of [portionKcal].
  final String portionDesc;

  final int portionKcal;

  /// `'g'` (solid) or `'ml'` (liquid). ADR-23: the unit is a knowledge-base fact, never
  /// guessed from the class name.
  final String unit;

  /// The amount [portionDesc] and [portionKcal] describe, in [unit].
  final int standardAmount;

  /// Average intake per second **of the whole eating event** (pauses included), in [unit].
  final double amountPerSecond;

  /// Plausible floor/ceiling of one eating event, in [unit]. They bound the extrapolation:
  /// a 20-minute session must not produce a 5 kg portion.
  final int minAmount;
  final int maxAmount;

  final List<String> nutritionTags;

  /// Advice material consumed by `A-02`.
  final String riskNote;

  /// ADR-23: a liquid is its own category. Used by `MealWindows.isSnackRecord` /
  /// `isMealSample` through the SSOT label, and by the estimator for its rounding step.
  bool get isLiquid => unit == 'ml';

  String get estimatedKcalText => '约 $portionDesc · 估算 $portionKcal kcal';
}

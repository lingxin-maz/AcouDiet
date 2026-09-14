// app/lib/presentation/theme/acou_format.dart
//
// `AcouFormat` -- the **single** source of display formatting for the L5 presentation layer
// (SPEC-U-06 section 4.3: "页面只调用，不拼字符串").
//
// PURE DART ON PURPOSE: this file imports `dart:` only plus the frozen domain models, so it
// compiles and runs against the Dart SDK alone (`tool/ui_presenter_tests.dart`). Pages and
// widgets call it; nothing here may reach into Flutter, a Repository or a MethodChannel.
//
// Every threshold comes from the SSOT (`FeatureConfig`) or from a frozen domain constant --
// no hand-written magic number is permitted (SPEC-C-03 section 7 #1). The two band factors of
// the energy estimate are the spec-given ones of A-03-K6 / API-05 section 6.2 (±20%).

import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/health_score.dart';
import '../../domain/service/portion_estimator.dart';

/// Semantic colour role of a grade (FF-22b three-value enum). The colours themselves live in
/// `acou_theme.dart`; this pure enum is what `AcouTheme` maps from, so that colour is never
/// the only carrier of meaning.
enum GradeTone { good, fair, poor }

/// Confidence band of a probability, thresholds taken from FF-20 (never literals).
enum ConfidenceTier { high, medium, low, none }

/// Vertical-axis calibre of the trend chart.
enum ChartAxis { score, kcal }

abstract final class AcouFormat {
  AcouFormat._();

  // ---------------------------------------------------------------- frozen band factors

  /// A-03-K6 / API-05 section 6.2: the point estimate `x` is displayed as the ±20% band.
  static const double kcalBandLow = 0.8;
  static const double kcalBandHigh = 1.2;

  /// The empty marker. One definition, used by every numeric field (U-06 section 4.3).
  static const String noValue = '--';

  /// The interval separator used by every kilocalorie range (en dash, U+2013).
  static const String rangeDash = '–';

  // ---------------------------------------------------------------- grade / confidence

  /// FF-22b: exactly three grades, never a fourth.
  static GradeTone gradeToneOf(String grade) {
    if (grade == HealthScore.gradeGood) return GradeTone.good;
    if (grade == HealthScore.gradeFair) return GradeTone.fair;
    return GradeTone.poor;
  }

  /// FF-20: `>= tauConfirm` high, `>= tauLow` medium, else low.
  static ConfidenceTier tierOf(double confidence) {
    if (confidence.isNaN) return ConfidenceTier.none;
    if (confidence >= cfg.FeatureConfig.votingTauConfirm) return ConfidenceTier.high;
    if (confidence >= cfg.FeatureConfig.votingTauLow) return ConfidenceTier.medium;
    return ConfidenceTier.low;
  }

  // ---------------------------------------------------------------- numbers

  /// `round(p × 100)` plus a percent sign (API-00 section 3.3).
  static String percent(double p) => '${(p * 100).round()}%';

  /// The confidence chip text of the record template's third line.
  static String confidence(double p) => '置信度 ${percent(p)}';

  /// `4 分 23 秒` / `43 秒`; `null` renders the empty marker (never `0`).
  static String durationText(int? seconds) {
    if (seconds == null) return noValue;
    if (seconds < 60) return '$seconds 秒';
    return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  }

  /// `HH:mm` in the device's local time zone (API-00 section 3.2).
  static String clock(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// FF-21f: a chew count always carries the "about" hedge; `null` renders the empty marker.
  static String chewCountText(int? chewCount) =>
      chewCount == null ? noValue : '约 $chewCount 次';

  /// FF-21e: the three frozen speed words, `null` renders the empty marker.
  static String speedGradeText(String? speedGrade) => speedGrade ?? noValue;

  // ---------------------------------------------------------------- energy (FF-25)

  /// The lower bound of the ±20% band.
  static int kcalLow(int pointEstimate) => (pointEstimate * kcalBandLow).round();

  /// The upper bound of the ±20% band.
  static int kcalHigh(int pointEstimate) => (pointEstimate * kcalBandHigh).round();

  /// `约 1100–1400 kcal` -- the band alone, never a bare number.
  static String kcalRangeValue(int pointEstimate) =>
      '约 ${kcalLow(pointEstimate)}$rangeDash${kcalHigh(pointEstimate)} kcal';

  /// `估算能量参考 约 1100–1400 kcal` (README section 3 / U-01 section 2.2 step 4).
  static String kcalRange(int pointEstimate) =>
      '$_energyLabel ${kcalRangeValue(pointEstimate)}';

  static const String _energyLabel = '估算能量参考';

  /// The aggregate single value with its estimate label, used by the summary bar
  /// (`SPEC-U-03` section 10 open question 1: the bar's label must carry the estimate word).
  static String kcalEstimate(int pointEstimate) => '$_estimateWord $pointEstimate kcal';

  static const String _estimateWord = '估算';

  /// The estimate marker that must accompany every portion kilocalorie (FF-25).
  static const String estimateMarker = '（估算）';

  // ---------------------------------------------------------------- record card (U-03 4.2)

  /// Row 1 right: `≈120 kcal` (verbatim from the frozen standard template).
  ///
  /// ADR-23: the number is the **per-record** estimate from `PortionEstimator`, not the
  /// knowledge-base standard portion, so it moves with the eating duration.
  static String recordKcalBadge(PortionEstimate portion) => '≈${portion.kcal} kcal';

  /// Row 2: `软性主食 · 约 150 g（估算）` -- the amount and the estimate marker travel
  /// together, so no kilocalorie can ever be rendered on its own (FF-25).
  static String recordEstimateLine(String attribute, PortionEstimate portion) =>
      '$attribute · ${portion.amountText}$estimateMarker';

  /// The combined single-string form of SPEC-U-06 section 4.3, used for the semantic label:
  /// `软性主食 · 约 150 g（估算）≈120 kcal`.
  static String recordKcalCombined(String attribute, PortionEstimate portion) =>
      '${recordEstimateLine(attribute, portion)}${recordKcalBadge(portion)}';

  /// De-duplicated string for the degraded knowledge-base path: no portion, no kilocalorie,
  /// never a guessed food name (U-06 section 2.4).
  static const String unknownFoodName = '未知类别';

  // ---------------------------------------------------------------- deltas (ADR-10)

  /// Three distinct states, never conflated:
  /// * `null`  -> yesterday had no usable data, the caller **hides the row**;
  /// * `0`     -> genuinely unchanged, the UI **must** show the flat word;
  /// * other   -> the signed difference.
  static String? deltaText(int? delta) {
    if (delta == null) return null;
    if (delta == 0) return flatText;
    return '${delta > 0 ? '↑' : '↓'}${delta.abs()} 分';
  }

  /// ADR-10 frozen wording for a genuine tie.
  static const String flatText = '持平';

  /// The period-over-period difference of the report page: a **difference, not a ratio**
  /// (SPEC-U-04 section 2.2 step 6). `0` means "genuinely unchanged", never "no data".
  static String periodDeltaText(num delta, String unit) {
    if (delta == 0) return flatText;
    final sign = delta > 0 ? '+' : '-';
    final abs = delta.abs();
    final rendered = abs == abs.roundToDouble()
        ? abs.round().toString()
        : abs.toStringAsFixed(1);
    return '$sign$rendered $unit';
  }

  // ---------------------------------------------------------------- day grouping (U-03)

  /// `今天` / `昨天` / `M月d日` (API-00 section 3.2 local calendar days).
  static String dayGroupHeader({
    required String dayKey,
    required String todayKey,
    required String yesterdayKey,
  }) {
    if (dayKey == todayKey) return todayLabel;
    if (dayKey == yesterdayKey) return yesterdayLabel;
    final parts = dayKey.split('-');
    if (parts.length != 3) return dayKey;
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (month == null || day == null) return dayKey;
    return '$month月$day日';
  }

  static const String todayLabel = '今天';
  static const String yesterdayLabel = '昨天';

  /// `M月d日` for the day-group header's second half (ADR-24: the mockups print the calendar date
  /// beside 今天 / 昨天, and a relative word alone loses the date once the list is scrolled).
  static String dayDateLabel(String dayKey) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return dayKey;
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (month == null || day == null) return dayKey;
    return '$month月$day日';
  }

  /// `M/d` short label for the trend chart's abscissa.
  static String shortDate(String dayKey) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return dayKey;
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (month == null || day == null) return dayKey;
    return '$month/$day';
  }

  /// The weekday word used by the trend chart's text equivalent (U-04 section 8).
  static String weekdayLabel(String dayKey) {
    final d = DateTime.tryParse(dayKey);
    if (d == null) return dayKey;
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[(d.weekday - 1).clamp(0, 6)];
  }

  // ---------------------------------------------------------------- dimension drill (U-04)

  /// `饮食规律性 26/30`, or the dimension label plus the empty marker when it has no basis.
  static String dimensionRatio(DimensionScore d, {required bool displayable}) =>
      displayable ? '${d.label} ${d.score}/${d.max}' : '${d.label} $noValue';

  /// `26/30` alone (the drill-down row of U-04 section 7 criterion 4, regex `\S+ \d+/\d+`).
  static String ratio(int score, int max) => '$score/$max';
}

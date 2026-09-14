// app/lib/presentation/presenters/records_presenter.dart
//
// U-03 (records timeline + record detail) display logic. PURE DART (no Flutter import).
//
// Rules encoded here, with their source:
//  * the three-line standard template of README section 3 / SPEC-U-03 section 4.2, verbatim;
//  * the food name is **always** resolved through the knowledge base (`FoodInfo`), never
//    through a string built out of the class label; an unloaded knowledge base degrades to the
//    unknown-category placeholder with no portion and no kilocalorie (U-06 section 2.4);
//  * day grouping by the device's local calendar day (API-00 section 3.2), group contents in
//    the order the repository returned them (`eatenAtMs` ascending -- API-03 section 3.1 is
//    frozen, and `DietRepo.byRange` explicitly says the UI must not re-sort);
//  * FF-21f: a chew count always carries the "about" hedge; FF-21g: the MAE-degraded wording
//    carries **no digit at all**; a missing metric is `--`, never `0`;
//  * ADR-P6: the only confirmation badge the UI may render is the confirmed one.

import '../../core/time.dart';
import '../../domain/model/diet_record.dart';
import '../../domain/model/food_info.dart';
import '../../domain/model/summaries.dart';
import '../../domain/service/portion_estimator.dart';
import '../theme/acou_format.dart';
import 'food_catalog.dart';
import 'ui_strings.dart';

/// One rendered record card (the frozen three-line template).
class RecordCardText {
  const RecordCardText({
    required this.record,
    required this.food,
    this.portion,
    required this.timeText,
    required this.foodName,
    required this.kcalBadge,
    required this.estimateLine,
    required this.confidenceText,
    required this.sourceBadge,
    required this.showConfirmedBadge,
    required this.semanticsLabel,
  });

  final DietRecord record;

  /// `null` when the knowledge base is unavailable or the id is out of range.
  final FoodInfo? food;

  /// ADR-23: this record's portion estimate, derived from its own `durationSeconds`.
  /// `null` exactly when [food] is.
  final PortionEstimate? portion;

  /// Row 1 left: `HH:mm` in the device's local time zone.
  final String timeText;

  /// Row 1 centre: `FoodInfo.zhName`, or the unknown-category placeholder.
  final String foodName;

  /// Row 1 right: `≈120 kcal`, or empty on the degraded path (a kilocalorie without a portion
  /// description would be exactly the isolated number FF-25 forbids).
  final String kcalBadge;

  /// Row 2: `软性主食 · 1 片（估算）`, or empty on the degraded path.
  final String estimateLine;

  /// Row 3: `置信度 88%`.
  final String confidenceText;

  /// `演示数据` for a `source == 'demo'` row; empty for a real record.
  final String sourceBadge;

  /// ADR-P6: shown when the record went through the two-choice confirmation. The UI never
  /// renders the other state, so this is a boolean, not an enum.
  final bool showConfirmedBadge;

  /// The full screen-reader sentence for this card (U-03 section 8).
  final String semanticsLabel;

  bool get hasKnowledge => food != null;

  /// The complete single-string form used for the semantic label and for the clipboard
  /// payload, so that a kilocalorie can never leave the UI without its estimate marker.
  String get estimateWithKcal => food == null || portion == null
      ? UiStrings.unknownCategory
      : AcouFormat.recordKcalCombined(record.attribute, portion!);
}

/// One local calendar day of the timeline.
class RecordDayGroup {
  const RecordDayGroup({
    required this.dayKey,
    required this.header,
    required this.dateLabel,
    required this.records,
  });

  /// `yyyy-MM-dd`, the grouping unit of API-00 section 3.2.
  final String dayKey;

  /// `今天` / `昨天` / `M月d日`.
  final String header;

  /// `M月d日` -- the calendar date printed next to [header] (ADR-24).
  final String dateLabel;

  final List<RecordCardText> records;
}

/// ADR-24: one bucket of the meal chip row above the timeline.
///
/// The classification is **derived from the frozen predicates** rather than re-implemented, so a
/// chip filter can never contradict the numbers on the bar above it:
///
///  * a liquid is [drink], whatever the clock says (ADR-23: a drink is neither a snack nor a meal
///    sample, and it is its own class);
///  * a solid outside the three meal windows is [snack] -- literally `MealWindows.isSnackRecord`,
///    the same predicate the 零食 count uses;
///  * everything else is the meal window it fell into.
///
/// The five buckets are therefore a **total and disjoint** partition of the timeline.
enum RecordMealBucket {
  breakfast,
  lunch,
  dinner,
  snack,
  drink;

  /// `minutes` is the local minute of day; `classId` is the record's frozen class.
  static RecordMealBucket of(int minutes, int classId) {
    if (classId == MealWindows.liquidClassId) return RecordMealBucket.drink;
    if (MealWindows.isSnackRecord(minutes, classId)) return RecordMealBucket.snack;
    if (MealWindows.isBreakfast(minutes)) return RecordMealBucket.breakfast;
    if (MealWindows.isLunch(minutes)) return RecordMealBucket.lunch;
    return RecordMealBucket.dinner;
  }
}

/// The records-page summary bar (SPEC-U-03 section 4.1). The estimate word is part of the
/// label, which is how section 10 open question 1 reconciled the bar's format with FF-25.
class RecordsSummaryView {
  const RecordsSummaryView({
    required this.kcalText,
    required this.countText,
    required this.snackText,
    required this.barText,
    required this.semanticsLabel,
    required this.isUnknown,
  });

  /// `估算 315 kcal`, or the empty marker when the aggregate failed.
  final String kcalText;
  final String countText;
  final String snackText;

  /// `估算 315 kcal / 3 次 / 1 次`.
  final String barText;
  final String semanticsLabel;

  /// `true` when the aggregate could not be read: `-- / -- / --`, never `0`.
  final bool isUnknown;

  static const RecordsSummaryView unknown = RecordsSummaryView(
    kcalText: AcouFormat.noValue,
    countText: AcouFormat.noValue,
    snackText: AcouFormat.noValue,
    barText: UiStrings.recordsSummaryError,
    semanticsLabel: '今日汇总不可用',
    isUnknown: true,
  );

  /// The three frozen values, with `0` used for a genuinely empty day (never for an error).
  static RecordsSummaryView of(TodaySummary summary) {
    final kcal = AcouFormat.kcalEstimate(summary.estimatedKcal);
    final count = '${summary.recordCount} ${UiStrings.snackCountSuffix}';
    final snack = '${summary.snackCount} ${UiStrings.snackCountSuffix}';
    return RecordsSummaryView(
      kcalText: kcal,
      countText: count,
      snackText: snack,
      barText: '$kcal / $count / $snack',
      semanticsLabel:
          '今日已记录 ${summary.recordCount} 次，估算总热量 ${summary.estimatedKcal} 千卡，其中零食 ${summary.snackCount} 次',
      isUnknown: false,
    );
  }
}

/// The detail page's behaviour block; every `null` renders the empty marker, never `0`.
class RecordBehaviorView {
  const RecordBehaviorView({
    required this.chewText,
    required this.intervalText,
    required this.durationText,
    required this.speedText,
    required this.degraded,
  });

  final String chewText;
  final String intervalText;
  final String durationText;
  final String speedText;

  /// FF-21g: the estimate was below the accuracy line, so the copy carries no digit.
  final bool degraded;

  static const RecordBehaviorView empty = RecordBehaviorView(
    chewText: AcouFormat.noValue,
    intervalText: AcouFormat.noValue,
    durationText: AcouFormat.noValue,
    speedText: AcouFormat.noValue,
    degraded: false,
  );

  /// [degraded] is supplied by the assembly layer: no frozen field on `BehaviorMetrics`
  /// carries the MAE state (FF-21g is a property of the model evaluation, not of a row), so
  /// the presenter takes it as an explicit input instead of inferring it from a `null` chew
  /// count -- `null` means "not measured" and must stay `--`.
  static RecordBehaviorView of(BehaviorMetrics? m, {bool degraded = false}) {
    if (m == null) return RecordBehaviorView.empty;
    return RecordBehaviorView(
      chewText: RecordsPresenter.chewText(m.chewCount, degraded: degraded),
      intervalText: m.avgChewIntervalSeconds == null
          ? AcouFormat.noValue
          : '${m.avgChewIntervalSeconds!.toStringAsFixed(1)} 秒',
      durationText: AcouFormat.durationText(m.durationSeconds),
      speedText: AcouFormat.speedGradeText(m.speedGrade),
      degraded: degraded,
    );
  }
}

/// The record detail page (a derived page: `push`-ed, never a tab).
class RecordDetailView {
  const RecordDetailView({
    required this.card,
    required this.behavior,
    required this.foodName,
    required this.attribute,
    required this.timeText,
    required this.confidenceText,
    required this.confirmedText,
    required this.portionText,
    required this.kcalText,
    required this.amountText,
    required this.riskNote,
    required this.nutritionTags,
    required this.knowledgeOriginNote,
    required this.sourceText,
  });

  final RecordCardText card;
  final RecordBehaviorView behavior;
  final String foodName;
  final String attribute;
  final String timeText;
  final String confidenceText;

  /// ADR-P6: `已确认` or the empty marker -- the corrected wording never appears.
  final String confirmedText;

  /// Hidden (empty) when the knowledge base has no entry: no portion, no kilocalorie.
  final String portionText;
  final String kcalText;

  /// ADR-23: this record's **estimated** amount (`约 150 g`), derived from its own duration.
  /// Empty when the knowledge base has no entry. It is shown next to [portionText] (the
  /// knowledge-base standard portion) so the two are never confused.
  final String amountText;

  /// Hidden (empty) when the knowledge base has no entry.
  final String riskNote;

  /// Readable only in the knowledge-base block, which is labelled as a knowledge-base estimate
  /// and kept visually apart from the confidence block (SPEC-U-03 section 4.3).
  final List<String> nutritionTags;
  final String knowledgeOriginNote;

  /// `mic` is not a `DietRecord.source` value; only `real` / `demo` exist, so the detail page
  /// shows the demonstration badge only for a demo row.
  final String sourceText;

  static RecordDetailView of({
    required DietRecord record,
    required FoodInfo? food,
    required BehaviorMetrics? metrics,
    required String timeText,
    required String confidenceText,
    bool chewDegraded = false,
  }) {
    final portion =
        food == null ? null : PortionEstimator.of(food, durationSeconds: record.durationSeconds);
    final card = RecordCardText(
      record: record,
      food: food,
      portion: portion,
      timeText: timeText,
      foodName: food?.zhName ?? UiStrings.unknownCategory,
      kcalBadge: portion == null ? '' : AcouFormat.recordKcalBadge(portion),
      estimateLine:
          portion == null ? '' : AcouFormat.recordEstimateLine(record.attribute, portion),
      confidenceText: confidenceText,
      sourceBadge: record.isDemo ? UiStrings.demoDataBadge : '',
      showConfirmedBadge: record.correctedByUser,
      semanticsLabel: '',
    );
    return RecordDetailView(
      card: card,
      behavior: RecordBehaviorView.of(metrics, degraded: chewDegraded),
      foodName: card.foodName,
      attribute: record.attribute,
      timeText: timeText,
      confidenceText: confidenceText,
      confirmedText: record.correctedByUser ? UiStrings.confirmedBadge : AcouFormat.noValue,
      // `标准份量` stays the knowledge-base row; the record's own estimate is a separate row,
      // so a reader can always tell the reference portion from what this meal actually was.
      portionText: food == null ? '' : food.portionDesc,
      amountText: portion == null ? '' : portion.amountText,
      kcalText: portion == null ? '' : AcouFormat.kcalEstimate(portion.kcal),
      riskNote: food == null ? '' : food.riskNote,
      nutritionTags: food == null ? const <String>[] : food.nutritionTags,
      knowledgeOriginNote: UiStrings.knowledgeOriginNote,
      sourceText: record.isDemo ? UiStrings.demoDataBadge : 'local',
    );
  }
}

/// The whole records page.
class RecordsView {
  const RecordsView({
    required this.groups,
    required this.summary,
    required this.weekSummaryText,
    required this.isEmpty,
  });

  final List<RecordDayGroup> groups;
  final RecordsSummaryView summary;

  /// `WeeklyReport.summaryText`, or the frozen short form when the service is unavailable.
  final String weekSummaryText;

  final bool isEmpty;

  /// SPEC-U-03 section 6: a failed weekly summary degrades to the frozen short copy rather
  /// than to an invented sentence.
  static const String weekSummaryFallback = UiStrings.weekSummaryInsufficient;

  static RecordsView of({
    required List<DietRecord> records,
    required TodaySummary? today,
    required String? summaryText,
    required FoodCatalog catalog,
    required int nowMs,
    bool summaryUnavailable = false,
  }) {
    final cards = records.map((r) => cardOf(r, catalog)).toList(growable: false);

    final todayKey = TimeUtil.dayKey(nowMs);
    final yesterdayKey = TimeUtil.dayKey(nowMs - 86400000);

    // Bucket by local calendar day, preserving the repository order inside each bucket
    // (API-03 section 3.1: the UI must not re-sort). Groups themselves are ordered newest
    // first so that "今天" is the first header the user sees.
    final buckets = <String, List<RecordCardText>>{};
    for (final card in cards) {
      final key = TimeUtil.dayKey(card.record.eatenAtMs);
      buckets.putIfAbsent(key, () => <RecordCardText>[]).add(card);
    }
    final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    final groups = keys
        .map((key) => RecordDayGroup(
              dayKey: key,
              header: AcouFormat.dayGroupHeader(
                dayKey: key,
                todayKey: todayKey,
                yesterdayKey: yesterdayKey,
              ),
              dateLabel: AcouFormat.dayDateLabel(key),
              records: List<RecordCardText>.unmodifiable(buckets[key]!),
            ))
        .toList(growable: false);

    return RecordsView(
      groups: groups,
      summary: today == null ? RecordsSummaryView.unknown : RecordsSummaryView.of(today),
      weekSummaryText: summaryUnavailable
          ? weekSummaryFallback
          : (summaryText ?? weekSummaryFallback),
      isEmpty: cards.isEmpty,
    );
  }

  /// Builds one card. The food name, the estimated amount and both kilocalorie strings come
  /// from `FoodInfo` + `PortionEstimator`, so the card can never show a food name outside the
  /// six frozen classes, and the amount always belongs to *this* record's duration (ADR-23).
  static RecordCardText cardOf(DietRecord record, FoodCatalog catalog) {
    final food = catalog.byClassId(record.classId);
    final timeText = AcouFormat.clock(record.eatenAtMs);
    final foodName = food?.zhName ?? UiStrings.unknownCategory;
    final confidenceText = AcouFormat.confidence(record.confidence);
    final portion = food == null
        ? null
        : PortionEstimator.of(food, durationSeconds: record.durationSeconds);
    final estimateLine =
        portion == null ? '' : AcouFormat.recordEstimateLine(record.attribute, portion);
    final kcalBadge = portion == null ? '' : AcouFormat.recordKcalBadge(portion);
    return RecordCardText(
      record: record,
      food: food,
      portion: portion,
      timeText: timeText,
      foodName: foodName,
      kcalBadge: kcalBadge,
      estimateLine: estimateLine,
      confidenceText: confidenceText,
      sourceBadge: record.isDemo ? UiStrings.demoDataBadge : '',
      showConfirmedBadge: record.correctedByUser,
      semanticsLabel: UiStrings.recordSemantics(
        hour: DateTime.fromMillisecondsSinceEpoch(record.eatenAtMs).hour,
        minute: DateTime.fromMillisecondsSinceEpoch(record.eatenAtMs).minute,
        foodName: foodName,
        estimateLine: food == null ? UiStrings.unknownCategory : estimateLine,
        kcalBadge: kcalBadge,
        confidenceText: confidenceText,
      ),
    );
  }
}

/// Free functions kept beside the view models so the pages import one file.
abstract final class RecordsPresenter {
  RecordsPresenter._();

  /// FF-21f / FF-21g. [degraded] switches to the digit-free wording, whose contract is that it
  /// contains **no number at all** -- hence the dedicated constant rather than a formatted one.
  static String chewText(int? chewCount, {bool degraded = false}) {
    if (degraded) return UiStrings.chewRhythmDegraded;
    return AcouFormat.chewCountText(chewCount);
  }

  /// True when [text] carries no decimal digit -- the FF-21g degraded copy must satisfy this.
  static bool hasNoDigits(String text) => !RegExp(r'\d').hasMatch(text);

  /// `4 分 23 秒` / `--`.
  static String durationText(int? seconds) => AcouFormat.durationText(seconds);

  /// `0.7 秒` / `--`.
  static String intervalText(double? seconds) => seconds == null
      ? AcouFormat.noValue
      : '${seconds.toStringAsFixed(1)} 秒';

  /// The chip caption of a [RecordMealBucket] (the only place these five words live).
  static String mealBucketLabel(RecordMealBucket bucket) => switch (bucket) {
        RecordMealBucket.breakfast => UiStrings.recordsMealBreakfast,
        RecordMealBucket.lunch => UiStrings.recordsMealLunch,
        RecordMealBucket.dinner => UiStrings.recordsMealDinner,
        RecordMealBucket.snack => UiStrings.recordsMealSnack,
        RecordMealBucket.drink => UiStrings.recordsMealDrink,
      };

  /// The bucket of one rendered card, read from the record's own local time and class.
  static RecordMealBucket bucketOf(RecordCardText card) {
    final at = DateTime.fromMillisecondsSinceEpoch(card.record.eatenAtMs);
    return RecordMealBucket.of(at.hour * 60 + at.minute, card.record.classId);
  }
}

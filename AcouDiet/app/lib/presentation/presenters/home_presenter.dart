// app/lib/presentation/presenters/home_presenter.dart
//
// U-01 (home / today overview) display logic. PURE DART (no Flutter import).
//
// The page's data contract is the README section 3 table, row by row; nothing outside it may
// be rendered, and every number below comes from a domain object:
//  * the score card is a [ScoreView] (shared with U-04, so the two pages cannot disagree);
//  * the energy row is the ±20% **band** of `TodaySummary.estimatedKcal` with the estimate
//    wording (A-03-K6 / FF-25), or the empty word when the day is empty;
//  * the week row is `WeekSummary.recordCount` -- it replaced the impossible "8 of 12 kinds"
//    diversity counter (README section 8);
//  * the today list is `TodaySummary.records`, truncated to [maxTodayRecords].

import '../../domain/model/diet_record.dart';
import '../../domain/model/health_score.dart';
import '../../domain/model/summaries.dart';
import '../theme/acou_format.dart';
import 'food_catalog.dart';
import 'records_presenter.dart';
import 'score_view.dart';
import 'ui_strings.dart';

/// The "estimated energy reference" row.
class HomeEnergyView {
  const HomeEnergyView({
    required this.label,
    required this.valueText,
    required this.displayText,
    required this.hasData,
  });

  /// The row label: always [title].
  final String label;

  /// The one frozen spelling of the row label.
  static const String title = '估算能量参考';

  /// `约 1100–1400 kcal`, or empty when there is no data.
  final String valueText;

  /// `估算能量参考 约 1100–1400 kcal`, or `暂无数据`.
  final String displayText;

  final bool hasData;

  /// `TodaySummary.estimatedKcal` is a knowledge-base × standard-portion estimate; a day with
  /// no records shows the empty word rather than a band around zero.
  static HomeEnergyView of(TodaySummary? today) {
    if (today == null || today.recordCount == 0) {
      return const HomeEnergyView(
        label: title,
        valueText: '',
        displayText: UiStrings.homeEnergyEmpty,
        hasData: false,
      );
    }
    final value = AcouFormat.kcalRangeValue(today.estimatedKcal);
    return HomeEnergyView(
      label: title,
      valueText: value,
      displayText: '$title $value',
      hasData: true,
    );
  }
}

/// The "records this week" row. `0 次` is a real value; `-- 次` means the aggregate is missing.
class HomeWeekCountView {
  const HomeWeekCountView({required this.text, required this.count});

  final String text;
  final int? count;

  static HomeWeekCountView of(WeekSummary? week) =>
      HomeWeekCountView(text: UiStrings.weekRecordCount(week?.recordCount), count: week?.recordCount);
}

/// The whole home page.
class HomeView {
  const HomeView({
    required this.score,
    required this.scoreUnavailable,
    required this.energy,
    required this.week,
    required this.todayCards,
    required this.showViewAll,
    required this.recordsUnavailable,
    required this.demoActive,
    required this.recordCountToday,
  });

  final ScoreView score;

  /// `true` when the scoring service failed: the card degrades to the empty markers while the
  /// rest of the page keeps working (SPEC-U-01 section 6, local degradation only).
  final bool scoreUnavailable;

  final HomeEnergyView energy;
  final HomeWeekCountView week;

  /// At most [HomePresenter.maxTodayRecords] cards, in the order `StatsRepo.today()` returned.
  final List<RecordCardText> todayCards;

  /// `true` when more than the displayed maximum exist -> the "view all" affordance appears.
  final bool showViewAll;

  /// `true` when the record query failed: the list area shows its own retry affordance.
  final bool recordsUnavailable;

  /// A-04-K3: the demonstration badge, shown when the active dataset contains demo rows.
  final bool demoActive;

  final int recordCountToday;

  bool get isEmptyDay => recordCountToday == 0;

  /// The list area's copy: the frozen empty sentence, or nothing when the region failed (the
  /// widget renders the retry affordance instead of a sentence).
  String get todayRecordsEmptyText =>
      recordsUnavailable ? UiStrings.recordsListError : UiStrings.homeTodayRecordsEmpty;

  /// The demo badge appears once in the page header; the report page repeats it (M-03 C5
  /// requires at least two occurrences across the demo screens).
  String get demoBadgeText => demoActive ? UiStrings.demoDataBadge : '';

  static HomeView of({
    required TodaySummary? today,
    required WeekSummary? week,
    required HealthScore? score,
    required FoodCatalog catalog,
    bool demoActive = false,
    bool recordsUnavailable = false,
  }) {
    final scoreView = score == null ? ScoreView.unavailable() : ScoreView.of(score);
    final scoreUnavailable = score == null;

    final records = today?.records ?? const <DietRecord>[];
    final cards = records
        .take(HomePresenter.maxTodayRecords)
        .map((r) => RecordsView.cardOf(r, catalog))
        .toList(growable: false);

    return HomeView(
      score: scoreView,
      scoreUnavailable: scoreUnavailable,
      energy: HomeEnergyView.of(today),
      week: HomeWeekCountView.of(week),
      todayCards: cards,
      showViewAll: records.length > HomePresenter.maxTodayRecords,
      recordsUnavailable: recordsUnavailable,
      demoActive: demoActive,
      recordCountToday: today?.recordCount ?? 0,
    );
  }
}

abstract final class HomePresenter {
  HomePresenter._();

  /// SPEC-U-01 section 1.2 item 6 / section 6: the home list shows at most three rows and then
  /// offers "view all". The number is a page-layout decision frozen by that SPEC, and it is
  /// declared here once so no page body writes a literal.
  static const int maxTodayRecords = 3;

  /// Convenience for widgets: the label shown above the score.
  static const String scoreCardTitle = UiStrings.scoreCardTitle;

  /// The delta row's label; the row itself is hidden when the delta is `null` (ADR-10).
  static const String deltaRowLabel = UiStrings.deltaRowLabel;

  /// The three-state delta as a widget can consume it.
  static ({bool visible, String text}) deltaRow(ScoreView view) =>
      (visible: view.deltaVisible, text: view.deltaText ?? '');
}

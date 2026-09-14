// app/lib/presentation/pages/report/report_page.dart
//
// U-04 · 健康报告页. **One page, two scopes (ADR-23)**: 「每日」 and 「本周」, switched by swiping
// left/right or by the segmented control under the app bar, and **opening on 「每日」**.
//
//  * 每日 (default) -- the selected day's score card + radar, that day's summary (records /
//    estimated energy / snacks / classes) and the per-day list of four-dimension scores;
//  * 本周 -- the frozen weekly report: the trend chart with a kcal/score toggle, the four
//    drill-down rows, the weekly sentence with its seven deltas and the advice list.
//
// The weekly scope keeps the frozen title 「本周」 (SPEC-U-04 acceptance 1); the daily scope is
// titled 「每日报告」. Both scopes read the SAME `ReportView`, so the two can never disagree about
// a number, and the weekly numbers are the ones the home page shows.
//
// The disclaimer is rendered in the `ready` **and** the `insufficient` state (criterion 9): a
// page that hides its caveats exactly when the data is thin would be the worst possible failure
// mode.

import 'package:flutter/material.dart';

import '../../presenters/records_presenter.dart' show RecordCardText;
import '../../presenters/report_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/notifiers.dart' show ReportNotifier;
import '../../theme/acou_format.dart' show AcouFormat, ChartAxis;
import '../../theme/acou_theme.dart';
import '../../widgets/advice_list_item.dart';
import '../../widgets/demo_banner.dart';
import '../../widgets/drill_down_sheet.dart';
import '../../widgets/food_icon.dart';
import '../../widgets/score_card.dart';
import '../../widgets/state_view.dart';
import '../../widgets/trend_line_chart.dart';
import '../records/record_detail_page.dart';

/// The two report scopes, in swipe order. `daily` is deliberately the first one: the page opens
/// there (`PageController(initialPage: 0)`).
enum ReportScope { daily, weekly }

class ReportPage extends StatefulWidget {
  const ReportPage({super.key});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final PageController _pages = PageController();

  /// Which scope is on screen. Kept here (not in the notifier) so the page keeps its position
  /// while the user moves between tabs, and so the default is simply `initialPage: 0`.
  ReportScope _scope = ReportScope.daily;

  /// The day the 每日 scope shows. `null` means "the newest day that has records", which is what
  /// the page starts on and what it falls back to when the selected day disappears (a data
  /// clear, or the window sliding forward).
  String? _selectedDay;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(ReportScope scope) {
    setState(() => _scope = scope);
    _pages.animateToPage(
      scope.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    final notifier = scope.notifiers.report;
    return Scaffold(
      // ADR-24: the report page joins the rest of the app on the mint gradient. It keeps the opaque
      // app bar look of the other pages by painting the gradient *behind* the bar; `_ScopeSwitcher`
      // reserves the toolbar inset so nothing hides under it.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_scope == ReportScope.daily
            ? UiStrings.reportDailyTitle
            : UiStrings.reportTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: UiStrings.retry,
            onPressed: notifier.reload,
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: AcouTheme.pageGradientDecoration(),
        child: AcouBuilder<ReportView>(
        notifier: notifier,
        builder: (context, value) {
          if (!value.hasValue) {
            return Column(
              children: [
                _ScopeSwitcher(scope: _scope, onChanged: _goTo),
                Expanded(
                  child: RefreshableBody(
                    onRefresh: notifier.reload,
                    child: StateView.of(
                      value,
                      emptyMessage: UiStrings.reportInsufficient,
                      loadingMessage: '正在生成报告…',
                      onRetry: notifier.reload,
                    ),
                  ),
                ),
              ],
            );
          }
          final view = value.data!;
          return Column(
            children: [
              _ScopeSwitcher(scope: _scope, onChanged: _goTo),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (index) =>
                      setState(() => _scope = ReportScope.values[index]),
                  children: [
                    _DailyReportBody(
                      view: view,
                      notifier: notifier,
                      selectedDay: _selectedDay,
                      onSelectDay: (date) => setState(() => _selectedDay = date),
                    ),
                    _WeeklyReportBody(view: view, notifier: notifier),
                  ],
                ),
              ),
            ],
          );
          },
        ),
      ),
    );
  }
}

/// The 「每日 / 本周」 switch. It exists because a swipe alone is not discoverable, and it is the
/// only affordance that tells the user there are two reports at all.
class _ScopeSwitcher extends StatelessWidget {
  const _ScopeSwitcher({required this.scope, required this.onChanged});

  final ReportScope scope;
  final void Function(ReportScope) onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        // The toolbar inset belongs here: this row is the top of the body, and the page paints its
        // gradient behind the app bar (ADR-24).
        padding: EdgeInsets.fromLTRB(
          AcouTheme.spacePage,
          kToolbarHeight + MediaQuery.paddingOf(context).top + AcouTheme.spaceSm,
          AcouTheme.spacePage,
          AcouTheme.spaceXs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: '${UiStrings.reportScopeHint}，当前${scope == ReportScope.daily ? UiStrings.reportScopeDaily : UiStrings.reportScopeWeekly}',
                container: true,
                child: SegmentedButton<ReportScope>(
                  segments: const [
                    ButtonSegment<ReportScope>(
                      value: ReportScope.daily,
                      label: Text(UiStrings.reportScopeDaily),
                    ),
                    ButtonSegment<ReportScope>(
                      value: ReportScope.weekly,
                      label: Text(UiStrings.reportScopeWeekly),
                    ),
                  ],
                  selected: <ReportScope>{scope},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => onChanged(selection.first),
                ),
              ),
            ),
          ],
        ),
      );
}

/// 「每日」: one chosen day, its score card + radar, its summary rows and the per-day list.
class _DailyReportBody extends StatelessWidget {
  const _DailyReportBody({
    required this.view,
    required this.notifier,
    required this.selectedDay,
    required this.onSelectDay,
  });

  final ReportView view;
  final ReportNotifier notifier;
  final String? selectedDay;
  final void Function(String date) onSelectDay;

  @override
  Widget build(BuildContext context) {
    final days = view.dailyScores;
    if (days.isEmpty) {
      return RefreshableBody(
        onRefresh: notifier.reload,
        child: StateView(
          status: ViewStatus.empty,
          message: UiStrings.reportInsufficient,
        ),
      );
    }

    // `selectedDay` may point at a day that has since fallen out of the window; the newest day
    // with records is always a valid fallback because the list is newest-first and non-empty.
    final selected = days.firstWhere(
      (d) => d.date == selectedDay,
      orElse: () => days.first,
    );

    return RefreshIndicator(
      onRefresh: notifier.reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: AcouTheme.spaceXl),
        children: [
          DemoBanner(visible: view.demoActive, note: '本次报告使用预置演示数据集'),
          Padding(
            padding: const EdgeInsets.all(AcouTheme.spacePage),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(UiStrings.reportDailyPickTitle, style: AcouTheme.sectionTitle),
                const SizedBox(height: AcouTheme.spaceSm),
                _DayPicker(
                  days: days,
                  selected: selected.date,
                  onSelect: onSelectDay,
                ),
                const SizedBox(height: AcouTheme.spaceMd),
                _DailyScoreCard(day: selected),
                const SizedBox(height: AcouTheme.spaceMd),
                _DailySummaryCard(day: selected),
                const SizedBox(height: AcouTheme.spaceMd),
                _DailyListSection(days: days, onSelect: onSelectDay),
                const SizedBox(height: AcouTheme.spaceMd),
                const Text(UiStrings.disclaimerText, style: AcouTheme.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The date chips: one per day that has records, newest first. Tapping one selects it; the list
/// below is the same set of days.
class _DayPicker extends StatelessWidget {
  const _DayPicker({required this.days, required this.selected, required this.onSelect});

  final List<DailyScoreView> days;
  final String selected;
  final void Function(String date) onSelect;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final day in days)
              Padding(
                padding: const EdgeInsets.only(right: AcouTheme.spaceSm),
                child: ChoiceChip(
                  label: Text(day.dateLabel),
                  selected: day.date == selected,
                  onSelected: (_) => onSelect(day.date),
                ),
              ),
          ],
        ),
      );
}

/// The selected day's four dimensions. A day whose σ / chewing samples are missing renders `--`
/// for those axes -- the note under the card says why, so an empty axis cannot be mistaken for a
/// zero.
class _DailyScoreCard extends StatelessWidget {
  const _DailyScoreCard({required this.day});

  final DailyScoreView day;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 不再单独渲染 `reportDailyScoreTitle`：它下面那张 ScoreCard 的标题**就是同一天**
          // （`day.dateLabel`），两者并排出现时日期在屏幕上连着出现两遍（用户实测反馈
          // 「每日报告的各餐界面日期显示重复了」）。卡片的标题保留了日期，因为这是
          // 「近 7 天评分（截至该日）」口径要显示出来的关键信息（ADR-25 要求把口径说出口）。
          ScoreCard(
            score: day.scoreView,
            title: day.dateLabel,
            onTap: () => DrillDownSheet.show(
              context,
              drills: drillsOf(day.scoreView),
              title: '${day.dateLabel} 四维依据',
            ),
          ),
          const SizedBox(height: AcouTheme.spaceXs),
          Text(UiStrings.reportDailySingleDayNote, style: AcouTheme.caption),
        ],
      );
}

/// The selected day's real numbers: records, estimated energy, solid snacks and the class mix.
class _DailySummaryCard extends StatelessWidget {
  const _DailySummaryCard({required this.day});

  final DailyScoreView day;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      (UiStrings.reportDailyCountLabel, day.countText),
      (UiStrings.reportDailyKcalLabel, day.kcalText),
      (UiStrings.reportDailySnackLabel, day.snackText),
      if (day.classSummary.isNotEmpty)
        (UiStrings.reportDailyClassesLabel, day.classSummary),
    ];
    return Semantics(
      label: day.semanticsText,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(UiStrings.reportDailySummaryTitle, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceSm),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(row.$1, style: AcouTheme.bodyMuted)),
                    Text(row.$2, style: AcouTheme.metric),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Every day of the window that has records, newest first: the whole-window picture at a glance,
/// and a second way to pick the day shown above.
class _DailyListSection extends StatelessWidget {
  const _DailyListSection({required this.days, required this.onSelect});

  final List<DailyScoreView> days;
  final void Function(String date) onSelect;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(UiStrings.reportDailyListTitle, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceXs),
            const Text(UiStrings.reportDailyListNote, style: AcouTheme.caption),
            const SizedBox(height: AcouTheme.spaceSm),
            for (final day in days)
              Semantics(
                label: day.semanticsText,
                button: true,
                child: InkWell(
                  onTap: () => onSelect(day.date),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(day.dateLabel, style: AcouTheme.body)),
                            Text('${day.totalText} 分', style: AcouTheme.metric),
                          ],
                        ),
                        const SizedBox(height: 2),
                        for (final row in day.rows)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(row.$1, style: AcouTheme.bodyMuted),
                                ),
                                Text(row.$2, style: AcouTheme.metric),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// 「本周」: the frozen weekly report.
class _WeeklyReportBody extends StatelessWidget {
  const _WeeklyReportBody({required this.view, required this.notifier});

  final ReportView view;
  final ReportNotifier notifier;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: notifier.reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: AcouTheme.spaceXl),
          children: [
            DemoBanner(visible: view.demoActive, note: '本次报告使用预置演示数据集'),
            Padding(
              padding: const EdgeInsets.all(AcouTheme.spacePage),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ReportScoreHeader(view: view),
                  const SizedBox(height: AcouTheme.spaceMd),
                  _TrendSection(notifier: notifier, view: view),
                  const SizedBox(height: AcouTheme.spaceMd),
                  _DimensionSection(view: view),
                  const SizedBox(height: AcouTheme.spaceMd),
                  _DeltasSection(view: view),
                  const SizedBox(height: AcouTheme.spaceMd),
                  if (view.insufficient) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AcouTheme.spaceMd),
                      decoration: AcouTheme.cardDecoration(fill: AcouTheme.surfaceMuted),
                      child: Text(view.insufficientText, style: AcouTheme.bodyMuted),
                    ),
                    const SizedBox(height: AcouTheme.spaceMd),
                  ],
                  AdviceSection(
                    advices: view.advices,
                    disclaimerText: view.disclaimerText,
                  ),
                  if (view.recentRecords.isNotEmpty) ...[
                    const SizedBox(height: AcouTheme.spaceMd),
                    RecentRecordsSection(cards: view.recentRecords),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

/// The trend chart plus its calibre toggle. Switching the axis redraws from data already in
/// hand, so the request count never changes (SPEC-U-04 acceptance 3).
class _TrendSection extends StatelessWidget {
  const _TrendSection({required this.notifier, required this.view});

  final ReportNotifier notifier;
  final ReportView view;

  @override
  Widget build(BuildContext context) {
    final data = view.trend(notifier.axis);
    return Container(
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(UiStrings.reportTrendTitle, style: AcouTheme.sectionTitle),
              ),
              SegmentedButton<ChartAxis>(
                segments: const [
                  ButtonSegment<ChartAxis>(
                    value: ChartAxis.score,
                    label: Text(UiStrings.reportAxisScore),
                  ),
                  ButtonSegment<ChartAxis>(
                    value: ChartAxis.kcal,
                    label: Text(UiStrings.reportAxisKcal),
                  ),
                ],
                selected: <ChartAxis>{notifier.axis},
                onSelectionChanged: (selection) =>
                    notifier.setAxis(selection.first),
              ),
            ],
          ),
          const SizedBox(height: AcouTheme.spaceSm),
          if (view.demoBadgeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
              child: DemoTag(text: view.demoBadgeText),
            ),
          TrendLineChart(data: data),
          const SizedBox(height: AcouTheme.spaceXs),
          // ADR-25: the 评分 line is a rolling seven-day series. Saying so here is what keeps it
          // from being read as "that day's score" -- the two differ, and the chart is the place a
          // reader would assume the tighter meaning.
          if (notifier.axis == ChartAxis.score) ...[
            Text(UiStrings.reportTrendScoreNote, style: AcouTheme.caption),
            const SizedBox(height: AcouTheme.spaceXs),
          ],
          Text(data.textEquivalent, style: AcouTheme.caption),
        ],
      ),
    );
  }
}

/// The four dimensions, each `label score/max`, tappable to reveal the evidence.
class _DimensionSection extends StatelessWidget {
  const _DimensionSection({required this.view});

  final ReportView view;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('四维评分', style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceSm),
            for (final drill in view.drills)
              Semantics(
                label: '${drill.semanticsText}，双击展开依据',
                button: true,
                child: InkWell(
                  onTap: () => DrillDownSheet.show(
                    context,
                    drills: view.drills,
                    title: '四维评分依据',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
                    child: Row(
                      children: [
                        Expanded(child: Text(drill.label, style: AcouTheme.body)),
                        Text(drill.scoreText, style: AcouTheme.metric),
                        const SizedBox(width: AcouTheme.spaceXs),
                        const Icon(Icons.expand_more,
                            size: 20, color: AcouTheme.inkMuted),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// The seven deltas. They are differences, never ratios, and a `0` means "genuinely unchanged",
/// so the row stays visible (ADR-10).
class _DeltasSection extends StatelessWidget {
  const _DeltasSection({required this.view});

  final ReportView view;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(UiStrings.deltasTitle, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceXs),
            Text('与上一等长窗口的差值；持平表示确实没有变化', style: AcouTheme.caption),
            const SizedBox(height: AcouTheme.spaceSm),
            for (final row in view.deltas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(row.label, style: AcouTheme.bodyMuted)),
                    Text(row.text, style: AcouTheme.metric),
                  ],
                ),
              ),
          ],
        ),
      );
}

/// ADR-24: the mockups' 「最近识别记录」 strip.
///
/// It is **not a new metric**: these are the newest rows of the same seven-day record window the
/// records page reads, rendered with the same frozen `RecordCardText` template and opened on the
/// same detail page. It is capped (6) and labelled as such, so it can never be mistaken for the
/// complete history -- that is what the records tab is for.
///
/// The section is rendered only when there is something to show: with an empty window the weekly
/// body already carries the explicit `insufficient` sentence, and a titled-but-empty strip would
/// add a second, weaker way of saying the same thing.
class RecentRecordsSection extends StatelessWidget {
  const RecentRecordsSection({super.key, required this.cards});

  final List<RecordCardText> cards;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(UiStrings.reportRecentTitle, style: AcouTheme.sectionTitle),
          const SizedBox(height: AcouTheme.spaceXs),
          const Text(UiStrings.reportRecentNote, style: AcouTheme.caption),
          const SizedBox(height: AcouTheme.spaceSm),
          SizedBox(
            height: 124,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cards.length,
              separatorBuilder: (_, __) => const SizedBox(width: AcouTheme.spaceSm),
              itemBuilder: (context, i) {
                final card = cards[i];
                return _RecentRecordTile(
                  card: card,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RecordDetailPage(recordId: card.record.recordId),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
}

class _RecentRecordTile extends StatelessWidget {
  const _RecentRecordTile({required this.card, required this.onTap});

  final RecordCardText card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        label: card.semanticsLabel.isEmpty
            ? '${card.timeText} ${card.foodName}'
            : card.semanticsLabel,
        button: true,
        container: true,
        child: SizedBox(
          width: 104,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AcouTheme.radiusLg),
              child: Container(
                padding: const EdgeInsets.all(AcouTheme.spaceSm),
                decoration: AcouTheme.cardDecoration(),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FoodIconBadge(classId: card.record.classId, size: 44),
                    const SizedBox(height: AcouTheme.spaceXs),
                    Text(
                      card.foodName,
                      style: AcouTheme.metric,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(card.timeText, style: AcouTheme.caption),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

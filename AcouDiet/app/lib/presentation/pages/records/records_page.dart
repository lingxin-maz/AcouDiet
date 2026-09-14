// app/lib/presentation/pages/records/records_page.dart
//
// U-03 · 饮食记录页. A read-only timeline, grouped by local calendar day, with the stats bar on
// top, the weekly sentence below it, and the mockups' meal chip row above both (ADR-24).
//
// Deliberate omissions, each one a cut feature rather than a missing one:
//  * no editing, no deletion and no class correction entry (X-02);
//  * no CSV or file export (X-03);
//  * the detail page is a derived page reached by tapping a row, so it is not a fifth tab.
//
// ADR-24 notes on the visual rebuild:
//  * the chip row is a **client-side filter over the already-loaded day groups**; it changes what
//    the list shows and nothing else. The stats bar above it keeps describing *today*, which is
//    what its 「今日热量」 label says, so a filtered view can never be read as a smaller day;
//  * `全部` is an addition to the mockup's four chips: the mockup has no way back to the whole
//    timeline, and a filter that can hide every record with no exit is a trap;
//  * 饮品 is a fifth chip because ADR-23 made a liquid its own category -- see [RecordMealBucket].

import 'package:flutter/material.dart';

import '../../presenters/records_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/demo_banner.dart';
import '../../widgets/record_card.dart';
import '../../widgets/state_view.dart';
import 'record_detail_page.dart';

class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key});

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  /// `null` is 全部, and it is the default: the first paint of the page must never hide a record.
  RecordMealBucket? _mealFilter;

  void _selectMeal(RecordMealBucket? bucket) {
    if (bucket == _mealFilter) return;
    setState(() => _mealFilter = bucket);
  }

  /// The day groups with the filter applied. A day whose every record was filtered out loses its
  /// header too -- an empty `今天` header above nothing reads as data loss.
  List<RecordDayGroup> _filteredGroups(RecordsView view) {
    final filter = _mealFilter;
    if (filter == null) return view.groups;
    final out = <RecordDayGroup>[];
    for (final group in view.groups) {
      final kept = group.records
          .where((card) => RecordsPresenter.bucketOf(card) == filter)
          .toList(growable: false);
      if (kept.isEmpty) continue;
      out.add(RecordDayGroup(
        dayKey: group.dayKey,
        header: group.header,
        dateLabel: group.dateLabel,
        records: kept,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    final notifier = scope.notifiers.records;
    final topInset = kToolbarHeight + MediaQuery.paddingOf(context).top;
    return Scaffold(
      // ADR-24: the mockups' records screen is a mint gradient page with floating white cards.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(UiStrings.recordsTitle),
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
        child: AcouBuilder<RecordsView>(
          notifier: notifier,
          builder: (context, value) {
            if (!value.hasValue) {
              return RefreshableBody(
                onRefresh: notifier.reload,
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: StateView.of(
                    value,
                    emptyMessage: UiStrings.recordsEmpty,
                    loadingMessage: '正在读取记录…',
                    onRetry: notifier.reload,
                  ),
                ),
              );
            }
            final view = value.data!;
            final groups = _filteredGroups(view);
            return RefreshIndicator(
              onRefresh: notifier.reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(top: topInset, bottom: AcouTheme.spaceXl),
                children: [
                  DemoBanner(
                    visible: view.groups
                        .expand((g) => g.records)
                        .any((c) => c.sourceBadge.isNotEmpty),
                  ),
                  MealFilterRow(selected: _mealFilter, onChanged: _selectMeal),
                  const SizedBox(height: AcouTheme.spaceSm),
                  _PageInset(child: RecordsStatsBar(summary: view.summary)),
                  const SizedBox(height: AcouTheme.spaceSm),
                  _PageInset(child: WeekSummaryCard(text: view.weekSummaryText)),
                  const SizedBox(height: AcouTheme.spaceSm),
                  if (view.isEmpty)
                    const EmptyRecordsView()
                  else if (groups.isEmpty)
                    _PageInset(child: FilteredEmptyView(bucket: _mealFilter))
                  else
                    for (final group in groups) ...[
                      DayGroupHeader(
                        header: group.header,
                        dateLabel: group.dateLabel,
                        count: group.records.length,
                      ),
                      _PageInset(
                        child: Column(
                          children: [
                            for (var i = 0; i < group.records.length; i++) ...[
                              if (i > 0) const TimelineConnector(),
                              RecordCard(
                                card: group.records[i],
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => RecordDetailPage(
                                      recordId: group.records[i].record.recordId,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The page's horizontal page margin, applied to every floating card (ADR-24).
class _PageInset extends StatelessWidget {
  const _PageInset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spacePage),
        child: child,
      );
}

/// The mockups' meal chip row: 全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品.
///
/// The chips are scrolling and stadium-shaped like the mockup's, but 48 dp tall so a chip keeps
/// the U-06 section 8 minimum touch target.
class MealFilterRow extends StatelessWidget {
  const MealFilterRow({super.key, required this.selected, required this.onChanged});

  /// `null` = 全部.
  final RecordMealBucket? selected;
  final ValueChanged<RecordMealBucket?> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: AcouTheme.minTapTarget,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spacePage),
          children: [
            // `null` first, so 全部 is always the leftmost chip and cannot be scrolled out of
            // reach on a narrow screen in a way the user cannot undo.
            for (final option in <RecordMealBucket?>[
              null,
              ...RecordMealBucket.values,
            ]) ...[
              MealFilterChip(
                label: option == null
                    ? UiStrings.recordsMealFilterAll
                    : RecordsPresenter.mealBucketLabel(option),
                selected: option == selected,
                onTap: () => onChanged(option),
              ),
              const SizedBox(width: AcouTheme.spaceSm),
            ],
          ],
        ),
      );
}

/// One chip. Selected = mint fill with white text, unselected = white pill with ink text, which is
/// exactly the mockup's pair; the selection is also exposed to the accessibility tree.
class MealFilterChip extends StatelessWidget {
  const MealFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AcouTheme.radiusLg),
            child: Container(
              alignment: Alignment.center,
              constraints: const BoxConstraints(minWidth: 64),
              padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spaceLg),
              decoration: BoxDecoration(
                color: selected ? AcouTheme.mintDeep : AcouTheme.surface,
                borderRadius: BorderRadius.circular(AcouTheme.radiusLg),
                boxShadow: selected ? null : AcouTheme.cardShadows,
              ),
              child: Text(
                label,
                style: AcouTheme.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? AcouTheme.onMint : AcouTheme.ink,
                ),
              ),
            ),
          ),
        ),
      );
}

/// The top stats bar: the mockups' three inline figures, filled with the frozen values.
///
/// The estimate word stays attached to the number (FF-25), which is why the first label is
/// 「今日热量」 and not 「今日估算热量」; the error state keeps `-- / -- / --` and never `0`.
class RecordsStatsBar extends StatelessWidget {
  const RecordsStatsBar({super.key, required this.summary});

  final RecordsSummaryView summary;

  @override
  Widget build(BuildContext context) => Semantics(
        label: summary.semanticsLabel,
        container: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AcouTheme.spaceMd,
            vertical: AcouTheme.spaceSm,
          ),
          decoration: AcouTheme.cardDecoration(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StatItem(
                  label: UiStrings.recordsStatKcalLabel,
                  value: summary.kcalText,
                ),
              ),
              Expanded(
                child: _StatItem(
                  label: UiStrings.recordsStatCountLabel,
                  value: summary.countText,
                ),
              ),
              Expanded(
                child: _StatItem(
                  label: UiStrings.recordsStatSnackLabel,
                  value: summary.snackText,
                ),
              ),
            ],
          ),
        ),
      );
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AcouTheme.mint,
                ),
              ),
              const SizedBox(width: AcouTheme.spaceXs),
              Expanded(child: Text(label, style: AcouTheme.caption)),
            ],
          ),
          const SizedBox(height: 2),
          Text(value, style: AcouTheme.metric.copyWith(fontSize: 14)),
        ],
      );
}

/// The weekly sentence from `ReportService.summaryText`, or the frozen short copy.
class WeekSummaryCard extends StatelessWidget {
  const WeekSummaryCard({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(UiStrings.weekSummaryCardTitle, style: AcouTheme.bodyMuted),
            const SizedBox(height: AcouTheme.spaceXs),
            Text(text, style: AcouTheme.body),
          ],
        ),
      );
}

/// `今天 9月10日 ★` -- the mockup's day header, with the record count kept as text (colour alone
/// never carries a value, U-06 section 8).
class DayGroupHeader extends StatelessWidget {
  const DayGroupHeader({
    super.key,
    required this.header,
    required this.dateLabel,
    required this.count,
  });

  final String header;
  final String dateLabel;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AcouTheme.spacePage,
          AcouTheme.spaceMd,
          AcouTheme.spacePage,
          AcouTheme.spaceSm,
        ),
        child: Row(
          children: [
            Text(header, style: AcouTheme.metric.copyWith(fontSize: 16)),
            const SizedBox(width: AcouTheme.spaceXs),
            Text(dateLabel, style: AcouTheme.bodyMuted),
            const SizedBox(width: AcouTheme.spaceXs),
            // Decorative only: the star carries no value, so it needs no semantic label.
            const Icon(Icons.star_rounded, size: 18, color: AcouTheme.starGold),
            const Spacer(),
            Text('$count ${UiStrings.snackCountSuffix}', style: AcouTheme.caption),
          ],
        ),
      );
}

/// The dotted vertical rail the mockups draw between two records of the same day.
class TimelineConnector extends StatelessWidget {
  const TimelineConnector({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: AcouTheme.spaceLg,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 2, height: 4, color: AcouTheme.mint),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AcouTheme.mint,
                  border: Border.all(color: AcouTheme.surface, width: 2),
                ),
              ),
              Container(width: 2, height: 4, color: AcouTheme.mint),
            ],
          ),
        ),
      );
}

/// The deterministic empty state: a sentence, and no misleading "add a record" button -- records
/// are only ever produced by the detection page.
class EmptyRecordsView extends StatelessWidget {
  const EmptyRecordsView({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AcouTheme.spaceXl),
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, color: AcouTheme.inkMuted, size: 32),
            const SizedBox(height: AcouTheme.spaceSm),
            Text(UiStrings.recordsEmpty, style: AcouTheme.bodyMuted),
          ],
        ),
      );
}

/// Shown when the day groups are non-empty but the active chip matched nothing: it names the
/// filter, so the blank list is never read as "no records at all".
class FilteredEmptyView extends StatelessWidget {
  const FilteredEmptyView({super.key, required this.bucket});

  final RecordMealBucket? bucket;

  @override
  Widget build(BuildContext context) {
    final label = bucket == null
        ? UiStrings.recordsMealFilterAll
        : RecordsPresenter.mealBucketLabel(bucket!);
    return Padding(
      padding: const EdgeInsets.all(AcouTheme.spaceXl),
      child: Column(
        children: [
          const Icon(Icons.filter_alt_off_outlined, color: AcouTheme.inkMuted, size: 32),
          const SizedBox(height: AcouTheme.spaceSm),
          Text('$label：${UiStrings.recordsFilteredEmpty}', style: AcouTheme.bodyMuted),
        ],
      ),
    );
  }
}

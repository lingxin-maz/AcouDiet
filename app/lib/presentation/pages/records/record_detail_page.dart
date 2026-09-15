// app/lib/presentation/pages/records/record_detail_page.dart
//
// U-03 · 条目详情（衍生页）. Read-only: basic information, recognition information, this meal's
// behaviour analysis, the knowledge-base block and the source.
//
// Two presentation boundaries are enforced here:
//  * the knowledge-base block is labelled "来自食物知识库估算，非模型输出" and kept visually apart
//    from the confidence, so a knowledge value cannot be mistaken for a model output
//    (SPEC-U-03 section 4.3);
//  * the only confirmation badge the page can render is 「已确认」 (ADR-P6) -- there is no code
//    path that could show the corrected wording.

import 'package:flutter/material.dart';

import '../../theme/acou_format.dart' show AcouFormat;
import '../../presenters/records_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/record_card.dart';
import '../../widgets/state_view.dart';

class RecordDetailPage extends StatefulWidget {
  const RecordDetailPage({super.key, required this.recordId});

  final String recordId;

  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  RecordDetailView? _view;
  bool _missing = false;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_view == null && !_missing && _loading) _load();
  }

  Future<void> _load() async {
    final scope = AcouScope.of(context);
    setState(() => _loading = true);
    try {
      final (record, metrics) = await scope.notifiers.records.detail(widget.recordId);
      if (!mounted) return;
      if (record == null) {
        setState(() {
          _missing = true;
          _loading = false;
        });
        return;
      }
      final food = scope.services.catalog.byClassId(record.classId);
      setState(() {
        _view = RecordDetailView.of(
          record: record,
          food: food,
          metrics: metrics,
          timeText: AcouFormat.clock(record.eatenAtMs),
          confidenceText: AcouFormat.confidence(record.confidence),
        );
        _loading = false;
      });
    } on Object {
      // A read failure is a state, not a crash: the page explains and offers to go back.
      if (!mounted) return;
      setState(() {
        _missing = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: StateView(status: ViewStatus.loading, message: '正在读取记录…'),
      );
    }
    if (_missing || _view == null) {
      return Scaffold(
        appBar: AppBar(title: const Text(UiStrings.recordDetailTitle)),
        body: StateView(
          status: ViewStatus.error,
          message: UiStrings.recordMissing,
          onRetry: () => Navigator.of(context).maybePop(),
        ),
      );
    }
    final view = _view!;
    return Scaffold(
      appBar: AppBar(title: const Text(UiStrings.recordDetailTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AcouTheme.spacePage),
        children: [
          _Section(
            title: UiStrings.detailBasicSection,
            rows: <(String, String)>[
              (UiStrings.detailFoodName, view.foodName),
              (UiStrings.detailAttribute, view.attribute),
              (UiStrings.detailEatenAt, view.timeText),
            ],
          ),
          _Section(
            title: UiStrings.detailRecognitionSection,
            rows: <(String, String)>[
              (UiStrings.detailConfidence, view.confidenceText),
              (UiStrings.detailConfirmed, view.confirmedText),
            ],
          ),
          _Section(
            title: UiStrings.detailBehaviorSection,
            // Every missing metric renders the empty marker: `null` never becomes `0`.
            rows: <(String, String)>[
              (UiStrings.behaviorChewLabel, view.behavior.chewText),
              (UiStrings.behaviorIntervalLabel, view.behavior.intervalText),
              (UiStrings.behaviorDurationLabel, view.behavior.durationText),
              (UiStrings.behaviorSpeedLabel, view.behavior.speedText),
            ],
          ),
          if (view.portionText.isNotEmpty || view.kcalText.isNotEmpty)
            _Section(
              title: UiStrings.detailKnowledgeSection,
              note: UiStrings.knowledgeOriginNote,
              rows: <(String, String)>[
                // ADR-23: the record's own estimate first, the knowledge-base reference second.
                if (view.amountText.isNotEmpty)
                  (UiStrings.detailEstimatedAmount, view.amountText),
                if (view.portionText.isNotEmpty)
                  (UiStrings.detailPortion, view.portionText),
                if (view.kcalText.isNotEmpty) (UiStrings.detailKcal, view.kcalText),
                if (view.riskNote.isNotEmpty) (UiStrings.detailRiskNote, view.riskNote),
              ],
              tags: view.nutritionTags,
            ),
          _Section(
            title: UiStrings.detailSourceSection,
            rows: <(String, String)>[
              (UiStrings.detailSourceSection, view.sourceText),
            ],
          ),
        ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.rows,
    this.note,
    this.tags = const <String>[],
  });

  final String title;
  final List<(String, String)> rows;
  final String? note;
  final List<String> tags;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: AcouTheme.spaceMd),
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AcouTheme.sectionTitle),
            if (note != null) ...[
              const SizedBox(height: AcouTheme.spaceXs),
              Text(note!, style: AcouTheme.caption),
            ],
            const SizedBox(height: AcouTheme.spaceSm),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(row.$1, style: AcouTheme.bodyMuted)),
                    Expanded(
                      child: Text(
                        row.$2,
                        style: AcouTheme.body,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: AcouTheme.spaceSm),
              Wrap(
                spacing: AcouTheme.spaceXs,
                runSpacing: AcouTheme.spaceXs,
                children: [
                  for (final tag in tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AcouTheme.spaceSm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AcouTheme.surfaceMuted,
                        borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
                      ),
                      child: Text(tag, style: AcouTheme.caption),
                    ),
                ],
              ),
            ],
          ],
        ),
      );
}

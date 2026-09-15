// app/lib/presentation/widgets/drill_down_sheet.dart
//
// The four-dimension drill-down (U-01's score-card tap and U-04's dimension rows).
//
// The sheet renders **only** what the drill view already produced: `label score/max`, the single
// authoritative formula string from `ScoreFormulas.formulaOf`, and the evidence key/value pairs
// as the domain layer handed them over. The page recomputes nothing (API-04 section 3), which is
// what makes the SPEC-C-05 consistency assertion meaningful.

import 'package:flutter/material.dart';

import '../presenters/report_presenter.dart';
import '../theme/acou_theme.dart';

class DrillDownSheet extends StatelessWidget {
  const DrillDownSheet({super.key, required this.drills, this.title});

  final List<DimensionDrillView> drills;
  final String? title;

  /// Shows the sheet; returns when it is dismissed.
  static Future<void> show(
    BuildContext context, {
    required List<DimensionDrillView> drills,
    String? title,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AcouTheme.surface,
        builder: (_) => DrillDownSheet(drills: drills, title: title),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AcouTheme.spacePage,
          AcouTheme.spaceSm,
          AcouTheme.spacePage,
          AcouTheme.spaceLg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title!, style: AcouTheme.sectionTitle),
              const SizedBox(height: AcouTheme.spaceSm),
            ],
            for (final drill in drills) _DrillRow(drill: drill),
          ],
        ),
      ),
    );
  }
}

class _DrillRow extends StatefulWidget {
  const _DrillRow({required this.drill});

  final DimensionDrillView drill;

  @override
  State<_DrillRow> createState() => _DrillRowState();
}

class _DrillRowState extends State<_DrillRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final drill = widget.drill;
    return Semantics(
      label: '${drill.semanticsText}，双击展开依据',
      button: true,
      container: true,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(drill.label, style: AcouTheme.metric)),
                  Text(drill.scoreText, style: AcouTheme.metric),
                  const SizedBox(width: AcouTheme.spaceXs),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: AcouTheme.inkMuted,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(drill.formulaText, style: AcouTheme.caption),
              if (_expanded) ...[
                const SizedBox(height: AcouTheme.spaceSm),
                for (final line in drill.evidence)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(line.label, style: AcouTheme.caption)),
                        Text(line.text, style: AcouTheme.caption),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

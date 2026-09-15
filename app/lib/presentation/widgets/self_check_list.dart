// app/lib/presentation/widgets/self_check_list.dart
//
// The M-04 checklist: fourteen numbered rows with their observed value and, for a failure, an
// actionable hint, plus the verdict line that separates a microphone problem from a model
// problem.
//
// Accessibility (SPEC-M-04 section 8): pass/fail is carried by **text and colour together** --
// the row always renders `通过` / `失败`, so a colour-blind operator still reads the result.

import 'package:flutter/material.dart';

import '../presenters/selfcheck_presenter.dart';
import '../presenters/ui_strings.dart';
import '../theme/acou_theme.dart';

class SelfCheckList extends StatelessWidget {
  const SelfCheckList({super.key, required this.view});

  final SelfCheckView view;

  @override
  Widget build(BuildContext context) {
    if (!view.hasResults) {
      return const Padding(
        padding: EdgeInsets.all(AcouTheme.spaceMd),
        child: Text(UiStrings.verdictUnknown, style: AcouTheme.bodyMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VerdictLine(text: view.verdictText, allPassed: view.allPassed),
        const SizedBox(height: AcouTheme.spaceSm),
        for (final row in view.rows) SelfCheckRow(row: row),
      ],
    );
  }
}

class SelfCheckRow extends StatelessWidget {
  const SelfCheckRow({super.key, required this.row});

  final SelfCheckRowView row;

  @override
  Widget build(BuildContext context) {
    final tone = row.passed ? AcouTheme.gradeGood : AcouTheme.gradePoor;
    return Semantics(
      label: row.semanticsText,
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text('${row.index}', style: AcouTheme.caption),
            ),
            // Text plus glyph: the shape is a second channel beside the colour.
            Icon(
              row.passed ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: tone,
            ),
            const SizedBox(width: AcouTheme.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(row.label, style: AcouTheme.metric)),
                      Text(
                        row.statusText,
                        style: AcouTheme.caption.copyWith(
                          color: tone,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${UiStrings.selfCheckObservedLabel}：${row.observed}',
                    style: AcouTheme.caption,
                  ),
                  if (row.hint != null && row.hint!.isNotEmpty)
                    Text(
                      row.hint!,
                      style: AcouTheme.caption.copyWith(color: AcouTheme.gradePoor),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerdictLine extends StatelessWidget {
  const _VerdictLine({required this.text, required this.allPassed});

  final String text;
  final bool allPassed;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(
          fill: allPassed ? AcouTheme.surfaceMuted : AcouTheme.demoBanner,
        ),
        child: Row(
          children: [
            Icon(
              allPassed ? Icons.verified_outlined : Icons.report_problem_outlined,
              size: 20,
              color: allPassed ? AcouTheme.gradeGood : AcouTheme.demoBannerInk,
            ),
            const SizedBox(width: AcouTheme.spaceSm),
            Expanded(
              child: Text(
                text,
                style: AcouTheme.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: allPassed ? AcouTheme.ink : AcouTheme.demoBannerInk,
                ),
              ),
            ),
          ],
        ),
      );
}

// app/lib/presentation/widgets/advice_list_item.dart
//
// The advice list of U-04 (`Advice[]`, sorted by priority) plus the persistent disclaimer.
//
// Rules:
//  * the UI renders `Advice.text` verbatim and never rewrites it (SPEC-U-04 section 6: a rule
//    engine's wording is not the page's to edit);
//  * the disclaimer is the single `general` item -- exactly one definition repo-wide
//    (`AdviceEngine.disclaimerText`), and it stays visible in the `insufficient` state too
//    (acceptance criterion 9);
//  * when no non-disclaimer suggestion exists the frozen empty sentence is shown instead.

import 'package:flutter/material.dart';

import '../presenters/report_presenter.dart';
import '../presenters/ui_strings.dart';
import '../theme/acou_theme.dart';

class AdviceListItem extends StatelessWidget {
  const AdviceListItem({super.key, required this.advice});

  final AdviceItemView advice;

  @override
  Widget build(BuildContext context) {
    final icon = switch (advice.dimension) {
      'regularity' => Icons.schedule_outlined,
      'structure' => Icons.dinner_dining_outlined,
      'snack' => Icons.cookie_outlined,
      'speed' => Icons.timer_outlined,
      _ => Icons.info_outline,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AcouTheme.inkMuted),
          const SizedBox(width: AcouTheme.spaceSm),
          Expanded(child: Text(advice.text, style: AcouTheme.body)),
        ],
      ),
    );
  }
}

/// The advice block: the list, its empty copy, and the always-present disclaimer footer.
///
/// ADR-24: it is now drawn as the mockups' rounded suggestion card -- a light mint gradient with a
/// leading check glyph. The mockup's white-on-green text is **not** copied: white body text on a
/// mid-mint fill is about 2.5:1 and breaks U-06 section 8, so the card keeps the shape and the
/// gradient while every sentence stays `ink`/`inkMuted`.
class AdviceSection extends StatelessWidget {
  const AdviceSection({super.key, required this.advices, required this.disclaimerText});

  final List<AdviceItemView> advices;
  final String disclaimerText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.adviceCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.check_circle_outline,
                size: 22,
                color: AcouTheme.gradeGood,
              ),
              const SizedBox(width: AcouTheme.spaceSm),
              const Text(UiStrings.adviceTitle, style: AcouTheme.sectionTitle),
            ],
          ),
          const SizedBox(height: AcouTheme.spaceSm),
          if (advices.isEmpty)
            Text(UiStrings.adviceEmpty, style: AcouTheme.bodyMuted)
          else
            ...advices.map((a) => AdviceListItem(advice: a)),
          const Divider(height: AcouTheme.spaceLg),
          // The disclaimer is not optional and not hidden behind a tap.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.gavel_outlined, size: 18, color: AcouTheme.inkMuted),
              const SizedBox(width: AcouTheme.spaceSm),
              Expanded(
                child: Text(
                  disclaimerText,
                  style: AcouTheme.caption,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// app/lib/presentation/widgets/demo_banner.dart
//
// The "demonstration data" badge shared by U-01 / U-03 / U-04 / U-05 (A-04-K3 wording, SPEC-A-04
// acceptance 7), plus a compact inline tag for a single row.
//
// Two different badges exist in the product and they must never be confused:
//  * `演示数据` (this widget) is triggered by `DemoDataController.isDemoActive`, i.e. by rows
//    whose `DietRecord.source == 'demo'`;
//  * `示例演示` is triggered **only** by `patch.source == 'inject'` during a live Mode B session
//    (API-01 section 3.2) and therefore lives in the detection page, not here.

import 'package:flutter/material.dart';

import '../presenters/ui_strings.dart';
import '../theme/acou_theme.dart';

class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, this.visible = true, this.note});

  /// `false` renders nothing; the page passes `DemoDataController.isDemoActive`.
  final bool visible;

  /// An optional short explanation shown beside the badge.
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Semantics(
      label: '${UiStrings.demoDataBadge}${note == null ? '' : '，$note'}',
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AcouTheme.spaceMd,
          vertical: AcouTheme.spaceSm,
        ),
        color: AcouTheme.demoBanner,
        child: Row(
          children: [
            const Icon(Icons.science_outlined, size: 18, color: AcouTheme.demoBannerInk),
            const SizedBox(width: AcouTheme.spaceSm),
            Text(
              UiStrings.demoDataBadge,
              style: AcouTheme.body.copyWith(
                color: AcouTheme.demoBannerInk,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (note != null) ...[
              const SizedBox(width: AcouTheme.spaceSm),
              Expanded(
                child: Text(
                  note!,
                  style: AcouTheme.caption.copyWith(color: AcouTheme.demoBannerInk),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The same badge in row form, used by the record card and the detection page.
class DemoTag extends StatelessWidget {
  const DemoTag({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spaceSm, vertical: 2),
        decoration: BoxDecoration(
          color: AcouTheme.demoBanner,
          borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
        ),
        child: Text(
          text,
          style: AcouTheme.caption.copyWith(color: AcouTheme.demoBannerInk),
        ),
      );
}

// app/lib/presentation/widgets/record_card.dart
//
// `RecordCard` + `ConfidenceChip` -- the frozen three-line record template (README section 3,
// SPEC-U-03 section 4.2):
//
//   12:20  面条                    ≈120 kcal
//          软性主食 · 1 片（估算）
//          置信度 88%                      ›
//
// The widget renders **only** what [RecordCardText] already decided: no string is built here,
// which is what keeps the "food name always comes from the knowledge base" and "a kilocalorie
// always travels with its portion and the estimate marker" rules enforceable by the pure tests.
// ADR-P6 is also enforced by construction: the card can show the confirmed badge and has no way
// to show the other wording.

import 'package:flutter/material.dart';

import '../presenters/records_presenter.dart';
import '../presenters/ui_strings.dart';
import '../theme/acou_format.dart' show AcouFormat, ConfidenceTier;
import '../theme/acou_theme.dart';
import 'food_icon.dart';

export '../theme/acou_format.dart' show ConfidenceTier;

/// A small chip coloured by the confidence band (FF-20). The text is always present, so the
/// band is readable without colour (U-06 section 8).
class ConfidenceChip extends StatelessWidget {
  const ConfidenceChip({super.key, required this.confidence, this.text});

  final double confidence;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final tier = AcouFormat.tierOf(confidence);
    final colour = AcouTheme.forConfidence(tier);
    final label = text ?? AcouFormat.confidence(confidence);
    return Semantics(
      label: '$label，${_tierWord(tier)}',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AcouTheme.spaceSm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: AcouTheme.surfaceMuted,
          borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
          border: Border.all(color: colour),
        ),
        child: Text(
          label,
          style: AcouTheme.caption.copyWith(color: colour),
        ),
      ),
    );
  }

  static String _tierWord(ConfidenceTier tier) => switch (tier) {
        ConfidenceTier.high => '已确认置信度档',
        ConfidenceTier.medium => '需人工确认置信度档',
        ConfidenceTier.low => '未识别置信度档',
        ConfidenceTier.none => '无置信度',
      };
}

/// One record row in the frozen three-line layout.
class RecordCard extends StatelessWidget {
  const RecordCard({
    super.key,
    required this.card,
    this.onTap,
    this.highlight = false,
  });

  final RecordCardText card;

  /// Opens the record's detail page; `null` renders the row read-only (still tappable-area
  /// sized, because the whole row is the target).
  final VoidCallback? onTap;

  /// Briefly highlights a freshly written record (SPEC-U-03 section 2.2 step 7).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final record = card.record;
    // ADR-24: the record row is a white rounded card with the mockups' soft shadow, and the
    // kilocalorie sits on its own right-hand column with the portion under it -- the same three
    // pieces of information the frozen template carries, laid out the way the mockup draws them.
    final row = Container(
      margin: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
      constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget + 24),
      padding: const EdgeInsets.symmetric(
        horizontal: AcouTheme.spaceMd,
        vertical: AcouTheme.spaceMd,
      ),
      decoration: AcouTheme.cardDecoration(fill: highlight ? AcouTheme.mintSoft : null),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FoodIconBadge(classId: record.classId, size: 44),
          const SizedBox(width: AcouTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card.timeText, style: AcouTheme.caption),
                    const SizedBox(width: AcouTheme.spaceSm),
                    Expanded(
                      child: Text(
                        card.foodName,
                        style: AcouTheme.metric,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // The kilocalorie badge is only rendered together with the portion line below;
                // a card with no knowledge-base entry shows neither.
                if (card.hasKnowledge)
                  Text(card.kcalBadge, style: AcouTheme.body),
                const SizedBox(height: AcouTheme.spaceXs),
                Wrap(
                  spacing: AcouTheme.spaceXs,
                  runSpacing: AcouTheme.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConfidenceChip(
                      confidence: record.confidence,
                      text: card.confidenceText,
                    ),
                    if (card.showConfirmedBadge)
                      _Tag(text: UiStrings.confirmedBadge, tone: AcouTheme.gradeGood),
                    if (card.sourceBadge.isNotEmpty)
                      _Tag(text: card.sourceBadge, tone: AcouTheme.demoBannerInk),
                  ],
                ),
                if (card.estimateLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    card.estimateLine,
                    style: AcouTheme.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null)
            const Icon(Icons.chevron_right, color: AcouTheme.inkMuted),
        ],
      ),
    );

    return Semantics(
      label: card.semanticsLabel.isEmpty ? '${card.timeText} ${card.foodName}' : card.semanticsLabel,
      button: onTap != null,
      container: true,
      child: InkWell(
        onTap: onTap,
        child: row,
      ),
    );
  }
}

/// A tiny outlined tag used for the confirmed / demonstration badges.
class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spaceSm, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
          border: Border.all(color: tone),
        ),
        child: Text(text, style: AcouTheme.caption.copyWith(color: tone)),
      );
}

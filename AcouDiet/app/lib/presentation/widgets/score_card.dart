// app/lib/presentation/widgets/score_card.dart
//
// The U-01 / U-04 score card: total, grade chip, the three-state "vs yesterday" row and the
// four-dimension radar. It renders a [ScoreView] and decides nothing itself, so the home page
// and the report page cannot disagree about a number (SPEC-C-05 / SPEC-U-01 acceptance 5-6).
//
// Two ADR-10 details are visible here and nowhere else:
//  * a `null` delta hides the row entirely;
//  * a `0` delta **keeps the row** and shows the flat word.

import 'package:flutter/material.dart';

import '../presenters/report_presenter.dart';
import '../presenters/score_view.dart';
import '../presenters/ui_strings.dart';
import '../theme/acou_format.dart' show AcouFormat, GradeTone;
import '../theme/acou_theme.dart';
import 'drill_down_sheet.dart';
import 'four_dim_radar.dart';

class ScoreCard extends StatelessWidget {
  const ScoreCard({
    super.key,
    required this.score,
    this.title = UiStrings.scoreCardTitle,
    this.showRadar = true,
    this.onTap,
  });

  final ScoreView score;
  final String title;

  /// U-01 shows the radar beside the number; U-04 puts it in its own section.
  final bool showRadar;

  /// Tapping the card opens the dimension drill-down.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = AcouFormat.gradeToneOf(score.gradeText);
    final card = Container(
      padding: const EdgeInsets.all(AcouTheme.spaceMd),
      decoration: AcouTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AcouTheme.sectionTitle),
          const SizedBox(height: AcouTheme.spaceSm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(score.totalText, style: AcouTheme.scoreLarge),
                        const SizedBox(width: AcouTheme.spaceXs),
                        Text('分', style: AcouTheme.bodyMuted),
                      ],
                    ),
                    const SizedBox(height: AcouTheme.spaceXs),
                    GradeChip(text: score.gradeText, tone: tone),
                    if (score.deltaVisible) ...[
                      const SizedBox(height: AcouTheme.spaceSm),
                      Row(
                        children: [
                          // No trailing space baked into the copy: the frozen string is
                          // `较昨日` exactly, and spacing is the layout's job. Baking a space in
                          // made `find.text(UiStrings.deltaRowLabel)` miss, which is exactly how
                          // the SPEC's "copy matches verbatim" rule is checked.
                          Text(UiStrings.deltaRowLabel, style: AcouTheme.caption),
                          const SizedBox(width: AcouTheme.spaceXs),
                          Text(score.deltaText ?? '', style: AcouTheme.metric),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (showRadar)
                SizedBox(
                  width: 132,
                  height: 132,
                  child: FourDimRadar(score: score, size: 132),
                ),
            ],
          ),
          const SizedBox(height: AcouTheme.spaceSm),
          for (final axis in score.axes)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(child: Text(axis.label, style: AcouTheme.bodyMuted)),
                  Text(axis.scoreText, style: AcouTheme.metric),
                ],
              ),
            ),
          // ADR-23: the inputs behind the four bars. Without it 「零食控制 20/20」 reads as an
          // unexplained maximum instead of "no snacks", and 「食物结构 --」 reads as broken
          // instead of "not enough records yet".
          if (score.inputCaption.isNotEmpty) ...[
            const SizedBox(height: AcouTheme.spaceXs),
            Text(score.inputCaption, style: AcouTheme.caption),
          ],
        ],
      ),
    );

    return Semantics(
      label: score.semanticsText,
      container: true,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AcouTheme.radiusMd),
        child: card,
      ),
    );
  }
}

/// The grade chip: colour plus the frozen word, never colour alone.
class GradeChip extends StatelessWidget {
  const GradeChip({super.key, required this.text, required this.tone});

  final String text;
  final GradeTone tone;

  @override
  Widget build(BuildContext context) {
    final colour = AcouTheme.forGrade(tone);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AcouTheme.spaceSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
        border: Border.all(color: colour),
      ),
      child: Text(
        text,
        style: AcouTheme.caption.copyWith(color: colour, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The report page's header: the same card, plus the radar (ADR-23 -- the report previously
/// showed the four dimensions as text rows only, so its four-dimension result had no visual),
/// plus the drill-down affordance.
class ReportScoreHeader extends StatelessWidget {
  const ReportScoreHeader({super.key, required this.view});

  final ReportView view;

  @override
  Widget build(BuildContext context) => ScoreCard(
        score: view.score,
        title: UiStrings.reportTitle,
        showRadar: true,
        onTap: () => DrillDownSheet.show(context, drills: view.drills),
      );
}

/// Convenience used by the home page: the four rows of its own drill-down.
List<DimensionDrillView> drillsOf(ScoreView view) =>
    view.axes.map(DimensionDrillView.of).toList(growable: false);

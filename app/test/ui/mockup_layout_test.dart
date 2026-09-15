// app/test/ui/mockup_layout_test.dart
//
// ADR-38 guards for the two layout rules taken from the delivered mockups that a reader can
// actually measure:
//
//   * `8.png` puts a record's kilocalorie in a **right-hand column** of the card, with the food
//     name and the attribute/portion line on the left. This file's own sibling `record_card.dart`
//     had claimed exactly that layout in its header comment for two rounds while the code rendered
//     the kilocalorie under the name on the left -- a comment is not a check, so this is the check.
//   * `3.png` / `10.png` give the detection disc a standing waveform; a `null` level used to leave
//     the disc empty. The rule that decides when the decorative motif may appear is a pure
//     predicate, and it is asserted here in all of its cases.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/domain/model/diet_record.dart';
import '../../lib/domain/service/food_knowledge_base.dart';
import '../../lib/presentation/presenters/food_catalog.dart';
import '../../lib/presentation/presenters/records_presenter.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/food_icon.dart';
import '../../lib/presentation/widgets/record_card.dart';
import '../../lib/presentation/widgets/waveform_view.dart';
import '../support/fixtures.dart' show readAssetText;

late final FoodCatalog _loaded;

/// A `chips` record at a fixed local time, built through this file's own import chain.
///
/// `support/fixtures.dart` reaches `DietRecord` through `package:acoudiet/...` while
/// `records_presenter.dart` reaches it relatively, and those are two different types to the
/// compiler. The string reader is shared; the record is built here.
DietRecord _rec({required String id}) => DietRecord(
      recordId: id,
      eatenAtMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
      endedAtMs: DateTime(2026, 9, 10, 12, 5).millisecondsSinceEpoch,
      classLabel: cfg.FeatureConfig.classLabels[0],
      classId: 0,
      attribute: 'attr-0',
      confidence: 0.82,
      durationSeconds: 300,
      source: 'demo',
    );

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  setUpAll(() async {
    // The real knowledge base, read off the disk: the point of this file is the card's *layout*,
    // and the layout only exists once a record has a portion and a kilocalorie to show.
    final kb = FoodKnowledgeBase();
    await kb.load(
      assetPath: 'assets/foods.json',
      jsonText: readAssetText('assets/foods.json'),
    );
    _loaded = KbFoodCatalog(kb);
  });

  group('record card right-hand metric column', () {
    testWidgets('the kilocalorie sits right of the name and above the portion line',
        (tester) async {
      final card = RecordsView.cardOf(_rec(id: 'adr38-a'), _loaded);
      expect(card.hasKnowledge, isTrue, reason: 'the fixture must resolve to a real entry');

      await tester.pumpWidget(_host(RecordCard(card: card, onTap: () {})));
      await tester.pumpAndSettle();

      final cardRect = tester.getRect(find.byType(RecordCard));
      final nameRect = tester.getRect(find.text(card.foodName));
      final kcalRect = tester.getRect(find.text(card.kcalBadge));
      final portionRect = tester.getRect(find.text(card.estimateLine));
      final iconRect = tester.getRect(find.byType(FoodIconBadge));

      // Glyph tile on the left, then the text column, then the kilocalorie.
      expect(iconRect.right, lessThanOrEqualTo(kcalRect.left));
      expect(nameRect.left, lessThan(kcalRect.left));

      // 猸?The measurable claim: the kilocalorie is in the **right half** of the card. Under the
      // pre-ADR-38 layout it sat in the left text column, well left of the centre.
      expect(
        kcalRect.left,
        greaterThan(cardRect.center.dx),
        reason: 'the kilocalorie must be the mockups\' right-hand column, not part of the left '
            'text block',
      );

      // It is the top line of that column; the portion line stays on the left, under the name.
      expect(kcalRect.top, lessThan(portionRect.bottom));
      expect(portionRect.left, lessThan(cardRect.center.dx));
      expect(portionRect.top, greaterThan(nameRect.top));
    });

    testWidgets('a record with no knowledge-base entry shows no kilocalorie anywhere',
        (tester) async {
      final card = RecordsView.cardOf(_rec(id: 'adr38-b'), const EmptyFoodCatalog());
      expect(card.hasKnowledge, isFalse);

      await tester.pumpWidget(_host(RecordCard(card: card)));
      await tester.pumpAndSettle();

      expect(find.text(card.kcalBadge), findsNothing);
      expect(find.text(card.foodName), findsOneWidget);
      expect(find.textContaining('kcal'), findsNothing);
    });
  });

  group('the 「我的」 entry descriptions add no new claim', () {
    test('each is exactly the clause after the comma of its own row\'s spoken label', () {
      // The rule that makes the ADR-38 descriptions safe to add: a description may only repeat a
      // slice of a sentence the row already puts in the accessibility tree. If one drifts -- a
      // re-worded promise, a number, an extra capability -- it stops being that slice and fails.
      // `final`, not `const`: `privacyEntrySpoken` / `privacyEntrySubtitle` became flavour-aware
      // getters in ADR-44 (`SPEC-U-07` section 4.3), so the pairing rule below is still asserted
      // but can no longer be a compile-time constant list.
      final rows = <(String, String, String)>[
        (UiStrings.healthReportEntry, UiStrings.healthReportEntrySpoken,
            UiStrings.healthReportEntrySubtitle),
        (UiStrings.privacyTitle, UiStrings.privacyEntrySpoken, UiStrings.privacyEntrySubtitle),
        (UiStrings.selfCheckEntry, UiStrings.selfCheckEntrySpoken,
            UiStrings.selfCheckEntrySubtitle),
        (UiStrings.aboutTitle, UiStrings.aboutEntrySpoken, UiStrings.aboutEntrySubtitle),
      ];

      for (final (title, spoken, subtitle) in rows) {
        expect(spoken, '$title，$subtitle',
            reason: '「$title」\'s description must be the tail of its own spoken label');
      }
    });
  });

  group('chart text comes from the design system', () {
    test('the radar label style is a token, not a literal in the painter', () {
      // A source-level check, because the painter is private and a `CustomPainter` paints into a
      // canvas no widget test can read back. Comments are stripped first: the paragraph explaining
      // *why* the literal used to be there would otherwise satisfy the very check it documents
      // (the same trap `notifier_lifecycle_test.dart` fell into in ADR-34).
      final raw = File('lib/presentation/widgets/four_dim_radar.dart').readAsStringSync();
      final src = raw
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
          .join('\n');

      expect(
        src.contains('TextStyle(fontSize'),
        isFalse,
        reason: 'the axis labels must come from AcouTheme.chartAxisLabel -- a literal here is the '
            'one piece of text in the app that no token and no text scale can reach',
      );
      expect(src.contains('AcouTheme.chartAxisLabel'), isTrue);
      expect(
        src.contains('textScaler'),
        isTrue,
        reason: 'the labels must also honour the reader\'s text scale',
      );
    });
  });

  group('detection disc idle motif', () {
    const idle = Color(0x4DFFFFFF);
    const none = null;

    test('paints only when it was asked for, with nothing to show', () {
      expect(
        WaveformView.showsIdleSilhouette(hasSamples: false, rms: 0, idle: idle),
        isTrue,
        reason: 'the empty disc is exactly the case the motif exists for',
      );
      expect(
        WaveformView.showsIdleSilhouette(hasSamples: true, rms: 0.4, idle: idle),
        isFalse,
        reason: 'a live sample must replace the motif on the very next frame',
      );
      expect(
        WaveformView.showsIdleSilhouette(hasSamples: false, rms: 0, idle: none),
        isFalse,
        reason: 'callers that did not opt in keep the strictly live rendering',
      );
      // A sample whose value is zero is still a sample: the disc is then honestly silent, and even
      // the motif stays away.
      expect(
        WaveformView.showsIdleSilhouette(hasSamples: true, rms: 0, idle: idle),
        isFalse,
      );
    });

    testWidgets('only the detection disc opts in', (tester) async {
      // The plain waveform view -- the one any other caller reaches for -- must stay strictly live.
      expect(const WaveformView().idleSilhouette, isNull);

      // And the disc must really pass one down, or the rule above never runs in the app.
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: WaveCircle(level: level)))),
      );
      await tester.pump();

      final inner = tester.widget<WaveformView>(find.byType(WaveformView));
      expect(
        inner.idleSilhouette,
        isNotNull,
        reason: 'the detection disc is the screen the mockups draw a standing waveform on',
      );
    });
  });
}

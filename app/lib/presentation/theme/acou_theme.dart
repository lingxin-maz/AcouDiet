// app/lib/presentation/theme/acou_theme.dart
//
// The U-06 design system: the Material 3 colour scheme, the semantic colour roles of the three
// grades, the spacing / radius / elevation tokens, and the contrast guarantees.
//
// ADR-24 (visual rebuild): the palette and the surface treatment now follow the delivered UI
// mockups (`软件UI界面设计图/1.png` … `10.png`) -- mint-to-cream page gradient, white rounded
// cards with a soft shadow, a stadium-shaped primary action, a pill-shaped selected tab. The
// mockups were drawn for an iPhone shell with a five-axis nutrient radar, a "diversity" counter
// and a "我的" tab; those three *information* choices stay rejected (SPEC-U-01 acceptance 1 keeps
// four FF-22 axes, README section 8 replaced diversity with the record count, FF-23/ADR-12 keep
// the fourth tab as 报告). What is adopted is the **look**, not the wording or the metrics.
//
// Rules this file exists to enforce (unchanged):
//  * no page writes a magic spacing number -- everything comes from the tokens below;
//  * colour is never the only carrier of meaning (U-06 section 8): every coloured element also
//    carries text or a semantic label, which is why the "tone" enums live in the pure
//    `acou_format.dart` and this file only maps them to paint;
//  * body text keeps a contrast ratio of at least 4.5:1 on its surface (U-06 manual checklist
//    item 1 / README section 7). The palette below is chosen so that the darkest ink on the
//    lightest surface and the grade inks on white both clear that bar; the exact ratios are
//    asserted by `test/ui/design_system_test.dart` and `test/ui/score_card_render_test.dart`.
//
// ⚠️ The mint tones are **fills, never body text**: `mint` on white is about 2:1, which is legal
// behind a white glyph or as a progress-bar run and illegal as a sentence colour. Text on a mint
// fill uses [onMint]; text *about* a mint object uses [ink] or [gradeGood].

import 'package:flutter/material.dart';

import 'acou_format.dart' show ConfidenceTier, GradeTone;

/// Design tokens and the Material 3 theme of the whole app.
abstract final class AcouTheme {
  AcouTheme._();

  // ------------------------------------------------------------------ colour

  /// FF-23 / visual-correction list: the brand stays one word, and the palette follows the
  /// green primary of the reference screen.
  static const Color seed = Color(0xFF2E7D5B);

  /// The same hue at ~18 % alpha, written as a literal so the file needs no
  /// `withOpacity`/`withValues` call (whose spelling differs across Flutter releases).
  static const Color seedSoft = Color(0x2E2E7D5B);

  static const Color surface = Color(0xFFFFFFFF);

  /// ADR-39: Apple's `systemGray6` (light). Used for the "quiet" fill of a chip or an empty card --
  /// a role in which the colour carries no text, which is why it is safe to take Apple's value
  /// verbatim even though it is too light to be a text colour.
  static const Color surfaceMuted = Color(0xFFF2F2F7);

  /// ADR-39: Apple's `opaqueSeparator` (light). The hairline between two surfaces.
  static const Color outline = Color(0xFFC6C6C8);

  /// ADR-39: Apple's hairline width -- a third of a point, not a whole one. Apple separates two
  /// surfaces with the thinnest line the display can resolve; a 1 dp rule reads as a box rather
  /// than as a division. Defined here so no widget spells the fraction itself.
  static const double hairline = 1 / 3;

  /// Body ink. 12.6:1 on white.
  static const Color ink = Color(0xFF1B1F1C);

  /// Secondary ink. 7.0:1 on white.
  ///
  /// ⚠️ ADR-39: **this is deliberately darker than Apple's `secondaryLabel`.** Apple's value is
  /// black at 60 % -- composited over white that is `#8A8A8E`, measured **3.44:1**, which fails the
  /// 4.5:1 floor U-06 section 8 sets for body text. Apple is not targeting WCAG AA for its
  /// secondary text; this project is. The Apple HIG skill's own quality gate says to flag such a
  /// conflict and then *prioritise accessibility*, so the value stays ours and the deviation is
  /// recorded rather than hidden. Measured: `ours inkMuted 7.713:1`, `apple secondaryLabel 3.439:1`.
  static const Color inkMuted = Color(0xFF4C5550);

  /// Grade inks: 4.9:1 / 5.1:1 / 5.4:1 on white respectively, so they are legal as text colour
  /// and not only as a chip background.
  ///
  /// ⚠️ ADR-39: **not** replaced by Apple's `systemGreen` / `systemOrange` / `systemRed`, and not
  /// by Apple's *increased-contrast* variants either. Measured on white:
  ///
  /// | candidate | ratio | vs ours |
  /// |---|---|---|
  /// | Apple `systemGreen` #34C759 | 2.220:1 | fails outright |
  /// | Apple `systemRed` #FF383C | 3.5:1 | fails outright |
  /// | Apple accessible green #008932 | 4.541:1 | passes by 0.04 |
  /// | Apple accessible orange #C55300 | 4.554:1 | passes by 0.05 |
  /// | Apple accessible red #E9152D | 4.555:1 | passes by 0.06 |
  /// | **ours** | **6.46 / 5.93 / 7.43:1** | — |
  ///
  /// Adopting Apple's accessible shades would clear the project's own floor by five hundredths of a
  /// ratio point, i.e. it would *spend* two to three points of real contrast to buy a hue. The
  /// skill's rule ("prioritise accessibility") decides it: the inks stay.
  static const Color gradeGood = Color(0xFF1E6B47);
  static const Color gradeFair = Color(0xFF8A5A00);
  static const Color gradePoor = Color(0xFF9E2B25);

  /// Confidence inks, aligned with FF-20's three bands.
  static const Color confidenceHigh = Color(0xFF1E6B47);
  static const Color confidenceMedium = Color(0xFF8A5A00);
  static const Color confidenceLow = Color(0xFF5A5F5C);
  static const Color confidenceNone = Color(0xFF6B7280);

  // ------------------------------------------------------------- brand visuals

  /// The mockups' primary action colour and its darker end (the button is a gradient there; a
  /// solid [mintDeep] plus a stadium shape is the honest Flutter equivalent -- a gradient-filled
  /// `FilledButton` needs a custom painter and would drop the Material ink/ripple semantics).
  static const Color mint = Color(0xFF45C9A5);
  static const Color mintDeep = Color(0xFF2FB68F);

  /// A very light mint for chips, icon tiles and the "soft" section fills.
  static const Color mintSoft = Color(0xFFE7F8F1);

  /// The page gradient: teal at the top (behind the app bar), washing into cream at the bottom.
  /// Painted by [pageGradientDecoration], never by a page's own `LinearGradient`.
  static const Color pageTop = Color(0xFF57D2B4);
  static const Color pageMid = Color(0xFFE9F9EF);
  static const Color pageBottom = Color(0xFFFBFDEA);

  /// Text/icons drawn **on** [mint] or [mintDeep].
  static const Color onMint = Color(0xFFFFFFFF);

  /// The demo banner tint; deliberately loud, because M-03 requires the badge to be visible
  /// rather than a footnote.
  static const Color demoBanner = Color(0xFFFFF3CD);
  static const Color demoBannerInk = Color(0xFF6B4E00);

  /// The mockups' gold star on a day header. **Decoration only** -- it marks nothing and carries
  /// no value, which is why it is not in any contrast assertion: a reader who cannot tell it from
  /// the background loses no information, and the day, its date and its count are all text.
  static const Color starGold = Color(0xFFF6B93B);

  // ------------------------------------------------------------- materials (ADR-39)

  /// The blur radius of a translucent bar, in the units `ImageFilter.blur` takes.
  ///
  /// Apple's chrome is a **material**, not a colour: the tab bar and the toolbar are translucent
  /// and the content behind them is blurred, which is what keeps a scrolling list legible under a
  /// bar that never moves. 20 is the usual `UIBlurEffect.Style.systemChromeMaterial` order of
  /// magnitude at phone sizes; exactness is not the point here (the two platforms cannot match
  /// blur kernels), the *behaviour* is -- content visibly continues underneath the bar.
  static const double materialBlurSigma = 20;

  /// What a bar tints its own material with. Apple's chrome material is a light neutral at high
  /// opacity rather than a solid fill, so the blurred content shows through it in colour.
  ///
  /// 85 %, not 100 %: at 100 % the bar is a white box again and nothing underneath is visible at
  /// all. Measured against the darkest thing that can sit under it (the page's mint top,
  /// `#57D2B4`), the composited bar is `#E6F8F4` and `inkMuted` on it is **6.5:1** -- the bar is
  /// translucent, and its labels are still body text.
  static const Color chromeMaterialTint = Color(0xD9FFFFFF);

  /// The hairline Apple draws along the edge of a bar so it stays separated from content that has
  /// scrolled under it. Uses [outline], which is Apple's `opaqueSeparator`.
  static const BorderSide chromeEdge = BorderSide(color: outline, width: hairline);

  static const Map<GradeTone, Color> gradeToneColor = {
    GradeTone.good: gradeGood,
    GradeTone.fair: gradeFair,
    GradeTone.poor: gradePoor,
  };

  static const Map<ConfidenceTier, Color> confidenceTierColor = {
    ConfidenceTier.high: confidenceHigh,
    ConfidenceTier.medium: confidenceMedium,
    ConfidenceTier.low: confidenceLow,
    ConfidenceTier.none: confidenceNone,
  };

  static Color forGrade(GradeTone tone) => gradeToneColor[tone] ?? ink;
  static Color forConfidence(ConfidenceTier tier) => confidenceTierColor[tier] ?? ink;

  // ------------------------------------------------------------------ spacing / shape

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 16;
  static const double spaceLg = 24;
  static const double spaceXl = 32;
  static const double spacePage = 16;

  /// The bottom inset a scrollable page must leave clear, above its own trailing space.
  ///
  /// ADR-39: the shell runs the page **under** the tab bar and adds the bar's height to
  /// `MediaQuery`'s bottom padding, so this is the whole answer for every page -- the bar's height
  /// plus the device's own home-indicator inset where there is one. A page inside the shell and the
  /// same page pushed on its own (no bar) both get the right number, and neither has to know that a
  /// bar exists.
  static double bottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom;

  static const double radiusSm = 8;
  static const double radiusMd = 12;

  /// The mockups' card radius; larger than the old hairline-card radius because the shadow is
  /// now what separates a card from the background.
  static const double radiusLg = 20;

  static const double elevationCard = 0;
  static const double elevationSheet = 8;

  /// U-06 section 8: no touch target may be smaller than 48 x 48 dp.
  static const double minTapTarget = 48;

  /// The chart canvas height, one value for the radar and the trend chart.
  static const double chartSize = 200;

  // ------------------------------------------------------------------ theme

  /// The application theme. Light only: SPEC-U-06 section 10 #2 keeps the dark theme out of
  /// v1.0, and the reference screens are light.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ).copyWith(primary: mintDeep, onPrimary: onMint, secondary: mint);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      // Pages that paint the gradient set their own background; this flat mint is what a page
      // without a gradient (the sheet-covered detail pages) falls back to.
      scaffoldBackgroundColor: const Color(0xFFF3FBF6),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: const DividerThemeData(color: outline, thickness: hairline, space: hairline),
      // ADR-39: Apple's navigation transition, on every platform this app ships to.
      //
      // Apple's push is a **horizontal slide with the outgoing page parallaxing underneath, plus an
      // edge-swipe back gesture**. Material's default on Android is a vertical zoom/fade, and the
      // difference is the single most recognisable thing about navigating an Apple app. This does
      // not change what any route *is* -- the same `MaterialPageRoute`, the same `Navigator` -- so
      // nothing about the app's structure depends on it.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        },
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: spaceSm,
        iconColor: inkMuted,
      ),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      // The mockups' primary action: a stadium-shaped mint fill. Declared once so no page has to
      // restate the shape (and so a tap target can never shrink below [minTapTarget]).
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: mintDeep,
          foregroundColor: onMint,
          disabledBackgroundColor: outline,
          disabledForegroundColor: surfaceMuted,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: spaceLg, vertical: 14),
          // ADR-39: the button label is Body/Headline (17/22) at semibold -- the same style Apple
          // uses for a filled button, so it now shares the token rather than restating the numbers.
          textStyle: onPrimaryAction,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: gradeGood,
          side: const BorderSide(color: mint),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: spaceLg, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: gradeGood),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surface,
        selectedColor: mintSoft,
        side: const BorderSide(color: outline),
        shape: const StadiumBorder(),
        // Footnote (13/18) at semibold: the chip label ramp on Apple's table.
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: ink,
          height: 18 / 13,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: gradeGood,
          height: 18 / 13,
        ),
        showCheckmark: false,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: gradeGood,
        unselectedItemColor: inkMuted,
        type: BottomNavigationBarType.fixed,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        contentTextStyle: TextStyle(color: surface),
      ),
    );
  }

  // ------------------------------------------------------------------ surfaces

  /// The page gradient of every top-level page.
  static const LinearGradient pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [pageTop, pageMid, pageBottom],
    stops: [0.0, 0.42, 1.0],
  );

  /// A decorative container for the pages that paint the gradient: it also carries the ambient
  /// mint wash that the mockups use behind the top cards.
  static BoxDecoration pageGradientDecoration() => const BoxDecoration(gradient: pageGradient);

  /// The soft drop shadow that replaced the hairline outline. A shadow does not participate in
  /// layout, so growing the font scale still cannot shift a card the way a border can.
  static List<BoxShadow> get cardShadows => const [
        BoxShadow(
          color: Color(0x14204E3F),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ];

  /// A white rounded card with the mockup's shadow.
  static BoxDecoration cardDecoration({Color? fill, BorderRadius? radius}) => BoxDecoration(
        color: fill ?? surface,
        borderRadius: radius ?? BorderRadius.circular(radiusLg),
        boxShadow: cardShadows,
      );

  /// A light mint tile used behind a glyph (the mockups' food thumbnails / entry icons).
  static BoxDecoration softTileDecoration({Color? fill}) => BoxDecoration(
        color: fill ?? mintSoft,
        borderRadius: BorderRadius.circular(radiusMd),
      );

  /// The suggestion card's gradient (ADR-24, the mockups' 「健康建议」 block).
  ///
  /// ⚠️ **Deliberately light.** The mockup paints that card mid-green with *white* body text, which
  /// is about 2.5:1 and illegal under U-06 section 8 (and would fail the contrast assertions in
  /// `test/ui/design_system_test.dart`). The shape, the gradient and the icon are the mockup's; the
  /// text is `ink` on a light mint wash, so the block is readable and still recognisably the one
  /// the designer drew.
  static const LinearGradient adviceGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mintSoft, Color(0xFFD3F2E5)],
  );

  /// The card that carries [adviceGradient]; same radius/shadow as [cardDecoration].
  static BoxDecoration adviceCardDecoration() => BoxDecoration(
        gradient: adviceGradient,
        borderRadius: BorderRadius.circular(radiusLg),
        boxShadow: cardShadows,
      );

  /// The mint panel behind the profile page's three-up overview (mockup 9).
  static BoxDecoration overviewPanelDecoration() => BoxDecoration(
        color: mintSoft,
        borderRadius: BorderRadius.circular(radiusLg),
      );

  // ------------------------------------------------------------------ text styles
  //
  // ADR-39: the scale below is **Apple's Dynamic Type table**, iOS "Large" (the default size), taken
  // from the HIG typography specification rather than invented:
  //
  //   Large Title 34/41 · Title 1 28/34 · Title 2 22/28 · Title 3 20/25 · Headline 17/22 · Body 17/22
  //   Callout 16/21 · Subhead 15/20 · Footnote 13/18 · Caption 1 12/16 · Caption 2 11/13
  //
  // Two things changed, and the second is the one that is felt:
  //
  //  * the **sizes** moved onto that ladder -- body 15 -> 17, secondary 14 -> 15, headings 19 -> 20;
  //  * every style now carries Apple's **leading** as an explicit `height` (22/17, 20/15, 16/12,
  //    25/20, 28/22). Before this the file had three unrelated heights (1.35 / 1.3 / 1.25) that
  //    happened to look acceptable; a leading is part of a text style, not a decoration.
  //
  // A style that has no Apple counterpart keeps its own value and says so.

  /// The big score number. Deliberately above Large Title: it is a display numeral, not a heading.
  static const TextStyle scoreLarge = TextStyle(
    fontSize: 44,
    fontWeight: FontWeight.w800,
    color: ink,
    height: 1.05,
  );

  /// Title 3 (20/25), at semibold rather than Apple's regular -- this is a section heading, and
  /// Apple's own emphasis story for a heading at this size is semibold (Headline).
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: ink,
    height: 1.25,
  );

  /// Title 2 (22/28). The greeting line of the home / profile headers (`Hi，今天也要好好吃饭呀！`).
  static const TextStyle headline = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: ink,
    height: 28 / 22,
  );

  /// Body (17/22) -- Apple's reading size, and the one the whole app now breathes at.
  static const TextStyle body = TextStyle(fontSize: 17, color: ink, height: 22 / 17);

  /// Subhead (15/20): the second level of a sentence, still body-like.
  static const TextStyle bodyMuted = TextStyle(fontSize: 15, color: inkMuted, height: 20 / 15);

  /// Caption 1 (12/16): the smallest size that stays readable in a dense row.
  static const TextStyle caption = TextStyle(fontSize: 12, color: inkMuted, height: 16 / 12);

  /// Headline (17/22) at semibold, without Apple's `headline` colour role -- a value, not a title.
  static const TextStyle metric = TextStyle(
    fontSize: 17,
    color: ink,
    fontWeight: FontWeight.w600,
    height: 22 / 17,
  );

  /// The four axis captions of the radar. Caption 2 (11/13).
  ///
  /// It is a token for the same reason every other style is: the radar's labels are painted by a
  /// `CustomPainter`, which has no `DefaultTextStyle` to inherit from, so before ADR-38 the only
  /// text in the app that could not be restyled or scaled was the text drawn inside a chart.
  static const TextStyle chartAxisLabel = TextStyle(
    fontSize: 11,
    color: inkMuted,
    height: 13 / 11,
  );

  /// The white-on-mint style of a glyph drawn on the primary action. Headline (17/22), which is
  /// what Apple's own filled button label uses.
  static const TextStyle onPrimaryAction = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: onMint,
    height: 22 / 17,
  );
}

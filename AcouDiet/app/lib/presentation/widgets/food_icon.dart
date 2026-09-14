// app/lib/presentation/widgets/food_icon.dart
//
// `FoodIcon` -- the six frozen food classes of FF-19 mapped to one glyph each, plus the
// placeholder used when the knowledge base cannot resolve an id.
//
// U-06 contracts honoured here:
//  * exactly six classes, no seventh (`test/ui/design_system_test.dart` asserts the coverage);
//  * an out-of-range id renders the placeholder plus the de-duplicated unknown-category word --
//    the widget never guesses a food name (U-06 section 2.4);
//  * vector glyphs only, so no bitmap budget is spent (U-06 section 8, package size).

import 'package:flutter/material.dart';

import '../theme/acou_theme.dart';
import '../theme/food_class.dart';

/// One glyph per FF-19 class. Material icons are used deliberately: they ship with the
/// framework, so there is no icon package to resolve offline and no style drift between the six.
///
/// ADR-19 renamed ids 1-3; the glyphs follow the food, not the slot (`cookie_outlined` moves
/// from the biscuit to the gummy because the biscuit class no longer exists).
const Map<FoodClassId, IconData> _glyphs = {
  FoodClassId.chips: Icons.local_pizza_outlined,
  FoodClassId.cabbage: Icons.grass_outlined,
  FoodClassId.gummies: Icons.cookie_outlined,
  FoodClassId.noodles: Icons.ramen_dining_outlined,
  FoodClassId.carrot: Icons.eco_outlined,
  FoodClassId.drink: Icons.local_drink_outlined,
};

/// The glyph of one food class, sized from the design tokens.
class FoodIcon extends StatelessWidget {
  const FoodIcon({super.key, required this.classId, this.size = 24, this.semanticLabel});

  /// `diet_record.class_id`; anything outside FF-19 renders the placeholder.
  final int classId;
  final double size;

  /// When given, the icon announces the food name; a decorative icon passes nothing.
  final String? semanticLabel;

  static int get coveredClasses => _glyphs.length;

  static IconData glyphFor(int classId) {
    final foodClass = FoodClassId.tryParse(classId);
    if (foodClass == null) return Icons.help_outline;
    return _glyphs[foodClass] ?? Icons.help_outline;
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      glyphFor(classId),
      size: size,
      color: AcouTheme.inkMuted,
      semanticLabel: semanticLabel,
    );
    if (semanticLabel != null) return icon;
    return ExcludeSemantics(child: icon);
  }
}

/// A mint tile holding a [FoodIcon]; used by the record card and the detection card.
class FoodIconBadge extends StatelessWidget {
  const FoodIconBadge({super.key, required this.classId, this.size = 40});

  final int classId;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: AcouTheme.softTileDecoration(),
        alignment: Alignment.center,
        child: FoodIcon(classId: classId, size: size * 0.55),
      );
}

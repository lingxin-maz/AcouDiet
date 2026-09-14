// app/lib/presentation/theme/food_class.dart
//
// `FoodClassId` -- the six frozen food classes of FF-19, in the SSOT order, with the Chinese
// display names and knowledge-base attributes copied verbatim from that table.
//
// ADR-19 (2026-09-12): the table was revised to chips / cabbage / gummies / noodles / carrot /
// drink. Ids are positional and unchanged, so nothing downstream keyed on an id moved.
//
// PURE DART (no Flutter import): the enum is the contract, `food_icon.dart` only maps it to a
// glyph. Keeping the words here means the UI can never invent a seventh class or a more
// specific food name ("全麦面条" / "番茄" / "鸡翅" are all forbidden by FF-19).

import '../../core/feature_config.g.dart' as cfg;

enum FoodClassId {
  chips(0, 'chips', '薯片', '脆性高加工零食'),
  cabbage(1, 'cabbage', '卷心菜', '脆爽蔬菜'),
  gummies(2, 'gummies', '软糖', '黏弹性零食'),
  noodles(3, 'noodles', '面条', '软性主食'),
  carrot(4, 'carrot', '胡萝卜', '脆爽蔬菜'),
  drink(5, 'drink', '饮料', '液体');

  const FoodClassId(this.id, this.label, this.zhName, this.kbAttribute);

  /// `diet_record.class_id` (0-5).
  final int id;

  /// One of `feature_config.class_labels`, in the same order (FF-19).
  final String label;

  /// The Chinese display name, verbatim from FF-19.
  final String zhName;

  /// The knowledge-base attribute, verbatim from FF-19.
  final String kbAttribute;

  /// `null` for an out-of-range id: the caller renders the placeholder glyph plus the
  /// de-duplicated unknown-category word instead of guessing (U-06 section 2.4).
  static FoodClassId? tryParse(int classId) {
    for (final c in FoodClassId.values) {
      if (c.id == classId) return c;
    }
    return null;
  }

  /// `null` for an unregistered label; never falls back to a default class.
  static FoodClassId? tryParseLabel(String label) {
    for (final c in FoodClassId.values) {
      if (c.label == label) return c;
    }
    return null;
  }

  /// The class list must stay one-to-one with the SSOT; asserted by the pure test runner.
  static bool get matchesFeatureConfig {
    if (cfg.FeatureConfig.classLabels.length != FoodClassId.values.length) {
      return false;
    }
    for (var i = 0; i < FoodClassId.values.length; i++) {
      if (FoodClassId.values[i].label != cfg.FeatureConfig.classLabels[i]) return false;
      if (FoodClassId.values[i].id != i) return false;
    }
    return true;
  }
}

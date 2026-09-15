// app/lib/presentation/presenters/food_catalog.dart
//
// The look-up port the presentation layer uses to turn a `classId` into the knowledge-base
// entry (`FoodInfo`: Chinese name, attribute, standard portion, estimated kilocalories).
//
// `FoodKnowledgeBase` (L4, API-02 section 6) implements this port in `main.dart` by adapting
// `byClassId`. The port exists so that pages never touch a Repository or an asset loader, and
// so widget tests can inject a fixture catalogue.
//
// Contract (API-04 section 2 / U-06 section 2.4): a look-up **never** falls back to a default
// entry. When the knowledge base is not loaded -- or the id is out of range -- the answer is
// `null` and the caller renders the placeholder glyph plus the unknown-category word, with no
// portion and no kilocalorie.

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/food_info.dart';
import '../../domain/service/food_knowledge_base.dart';

abstract class FoodCatalog {
  /// `null` when the class is unknown or the knowledge base is not loaded.
  FoodInfo? byClassId(int classId);

  /// `false` until `load()` has completed; the UI degrades instead of guessing.
  bool get isLoaded;

  /// All six entries, in FF-19 order; empty when not loaded.
  List<FoodInfo> get all;
}

/// The honest default: nothing is loaded, every look-up degrades.
class EmptyFoodCatalog implements FoodCatalog {
  const EmptyFoodCatalog();

  @override
  FoodInfo? byClassId(int classId) => null;

  @override
  bool get isLoaded => false;

  @override
  List<FoodInfo> get all => const <FoodInfo>[];
}

/// Deterministic in-memory catalogue (tests and the offline placeholder wiring).
class MapFoodCatalog implements FoodCatalog {
  MapFoodCatalog(Iterable<FoodInfo> entries)
      : _byId = {
          for (final f in entries) _idOf(f.label): f,
        },
        _all = List<FoodInfo>.unmodifiable(entries);

  final Map<int, FoodInfo> _byId;
  final List<FoodInfo> _all;

  static int _idOf(String label) {
    var id = 0;
    for (final l in _orderedLabels) {
      if (l == label) return id;
      id++;
    }
    return -1;
  }

  /// `feature_config.class_labels` itself, not a hand-copied list.
  ///
  /// This used to be a literal six-element list. ADR-19 changed the class table and that
  /// literal was one of the places it had to be found by grep -- a generated constant cannot
  /// drift, so the duplication is removed rather than updated.
  static List<String> get _orderedLabels => cfg.FeatureConfig.classLabels;

  @override
  FoodInfo? byClassId(int classId) => _byId[classId];

  @override
  bool get isLoaded => _all.isNotEmpty;

  @override
  List<FoodInfo> get all => _all;
}

/// The production adapter over `FoodKnowledgeBase` (`API-02` section 6).
///
/// A failed or out-of-range look-up answers `null` instead of falling back to a default entry:
/// per API-04 section 2 rule 4 the knowledge base must never silently substitute an entry, and
/// U-06 section 2.4 turns that `null` into the placeholder glyph plus the unknown-category word.
class KbFoodCatalog implements FoodCatalog {
  const KbFoodCatalog(this.kb);

  final FoodKnowledgeBase kb;

  @override
  FoodInfo? byClassId(int classId) {
    if (!kb.isLoaded) return null;
    try {
      return kb.byClassId(classId);
    } on AcouDietError {
      return null;
    }
  }

  @override
  bool get isLoaded => kb.isLoaded;

  @override
  List<FoodInfo> get all => kb.isLoaded ? kb.all : const <FoodInfo>[];
}

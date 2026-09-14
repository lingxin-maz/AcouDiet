import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../model/food_info.dart';
import '../repository/repositories.dart' show KcalResolver;
import 'portion_estimator.dart';

/// Food knowledge base (P-08 / `API-02` section 6).
///
/// Loads `assets/foods.json`, validates it, and answers by class id or label. The lookup
/// order is fixed by `feature_config.class_labels` (FF-19); an unregistered key raises
/// `ACD-KB-001` and **never** falls back to a default entry -- a silent fallback would make
/// the report page show a plausible but wrong food.
class FoodKnowledgeBase {
  FoodKnowledgeBase({this.expectedLabels});

  /// Defaults to the SSOT's six labels.
  final List<String>? expectedLabels;

  List<String> get _labels => expectedLabels ?? cfg.FeatureConfig.classLabels;

  List<FoodInfo>? _items;
  Map<String, FoodInfo> _byLabel = const {};

  /// Replaces the table only after a fully successful validation (atomic swap).
  Future<void> load({required String assetPath, String? jsonText}) async {
    final text = jsonText ?? await _readAsset(assetPath);
    final parsed = _parse(text);
    _items = parsed;
    _byLabel = {for (final f in parsed) f.label: f};
  }

  Future<String> _readAsset(String assetPath) async {
    // Imported lazily so the domain layer stays free of Flutter dependencies in tests.
    try {
      final bytes = await rootBundleLoader(assetPath);
      return utf8.decode(bytes);
    } catch (e) {
      throw Errors.asset(assetPath, 'unreadable: $e');
    }
  }

  /// Injected by the assembly layer (the real app passes `rootBundle.load`).
  static Future<Uint8List> Function(String path) rootBundleLoader =
      (path) async => throw StateError('asset loader not configured');

  List<FoodInfo> get all {
    final items = _items;
    if (items == null) throw Errors.kb('notLoaded');
    return List<FoodInfo>.unmodifiable(items);
  }

  bool get isLoaded => _items != null;

  FoodInfo byClassId(int classId) {
    final items = _items;
    if (items == null) throw Errors.kb('notLoaded');
    final labels = _labels;
    if (classId < 0 || classId >= labels.length) {
      throw Errors.kb('classId out of range: $classId');
    }
    final label = labels[classId];
    final info = _byLabel[label];
    if (info == null) throw Errors.kb('no entry for "$label"');
    return info;
  }

  FoodInfo byLabel(String label) {
    final info = _byLabel[label];
    if (info == null) throw Errors.kb('unregistered label "$label"');
    return info;
  }

  /// Adapter for `StatsRepo.estimatedKcal` (L3 must not know about this class).
  KcalResolver get kcalResolver => _KbKcalResolver(this);

  List<FoodInfo> _parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw Errors.asset('assets/foods.json', 'invalid JSON: $e');
    }
    if (decoded is! Map) {
      throw Errors.asset('assets/foods.json', 'top level must be an object');
    }

    final labels = _labels;
    final keys = decoded.keys.map((k) => '$k').toSet();
    final expected = labels.toSet();
    if (keys.length != expected.length || !keys.containsAll(expected)) {
      throw Errors.asset(
        'assets/foods.json',
        'keys must be exactly ${labels.join(",")}; got ${keys.join(",")}',
      );
    }

    final out = <FoodInfo>[];
    for (final label in labels) {
      final raw = decoded[label];
      if (raw is! Map) throw Errors.asset('assets/foods.json', '"$label" must be an object');
      final m = raw.cast<String, Object?>();

      String str(String key) {
        final v = m[key];
        if (v is! String || v.isEmpty) {
          throw Errors.asset('assets/foods.json', '"$label".$key must be a non-empty string');
        }
        return v;
      }

      final declaredLabel = str('label');
      if (declaredLabel != label) {
        throw Errors.asset(
          'assets/foods.json',
          '"$label".label is "$declaredLabel"; it must equal its key',
        );
      }

      final kcal = (m['portionKcal'] as num?)?.toInt() ?? 0;
      if (kcal <= 0) {
        throw Errors.asset('assets/foods.json', '"$label".portionKcal must be > 0');
      }

      // ADR-23 portion model. Every one of the five fields is required: a missing rate would
      // silently fall back to a fixed portion -- the exact defect ADR-23 removes -- so the
      // loader refuses the entry instead of guessing.
      final unit = str('unit');
      if (unit != 'g' && unit != 'ml') {
        throw Errors.asset('assets/foods.json', '"$label".unit must be "g" or "ml", got "$unit"');
      }
      final standardAmount = (m['standardAmount'] as num?)?.toInt() ?? 0;
      final amountPerSecond = (m['amountPerSecond'] as num?)?.toDouble() ?? 0;
      final minAmount = (m['minAmount'] as num?)?.toInt() ?? 0;
      final maxAmount = (m['maxAmount'] as num?)?.toInt() ?? 0;
      if (standardAmount <= 0) {
        throw Errors.asset('assets/foods.json', '"$label".standardAmount must be > 0');
      }
      if (!(amountPerSecond > 0)) {
        throw Errors.asset('assets/foods.json', '"$label".amountPerSecond must be > 0');
      }
      if (minAmount <= 0 || minAmount > standardAmount || standardAmount > maxAmount) {
        throw Errors.asset(
          'assets/foods.json',
          '"$label" needs 0 < minAmount <= standardAmount <= maxAmount '
          '(got $minAmount / $standardAmount / $maxAmount)',
        );
      }

      final tags = (m['nutritionTags'] as List?)?.map((e) => '$e').toList() ?? const <String>[];

      out.add(FoodInfo(
        label: label,
        zhName: str('zhName'),
        attribute: str('attribute'),
        category: str('category'),
        portionDesc: str('portionDesc'),
        portionKcal: kcal,
        unit: unit,
        standardAmount: standardAmount,
        amountPerSecond: amountPerSecond,
        minAmount: minAmount,
        maxAmount: maxAmount,
        nutritionTags: tags,
        riskNote: str('riskNote'),
      ));
    }
    return out;
  }
}

class _KbKcalResolver implements KcalResolver {
  _KbKcalResolver(this.kb);

  final FoodKnowledgeBase kb;

  @override
  int kcalFor(int classId) => kb.byClassId(classId).portionKcal;

  /// ADR-23: the duration-aware estimate. `StatsRepo` feeds it one record's duration at a
  /// time, so the aggregate is the sum of the same numbers the record cards display.
  @override
  int kcalForDuration(int classId, int durationSeconds) =>
      PortionEstimator.of(kb.byClassId(classId), durationSeconds: durationSeconds).kcal;
}

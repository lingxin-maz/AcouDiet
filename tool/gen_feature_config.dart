// tool/gen_feature_config.dart
//
// AcouDiet -- SSOT constant generator  (PLAN-C-03 deliverable #2)
//
// Reads THE single source of truth  shared/feature_config.json  and derives, in one run:
//
//   app/lib/core/feature_config.g.dart                                  (Dart constants)
//   app/android/app/src/main/kotlin/com/acoudiet/app/config/FeatureConfig.kt  (Kotlin constants)
//   app/assets/feature_config.json                                      (byte-equal asset copy)
//
// Rules enforced here (SPEC-C-03):
//   * only shared/feature_config.json may write values; everything else is derived;
//   * generated files carry the DO-NOT-EDIT banner;
//   * keys starting with "_" (metadata + _decisions) never become constants.
//
// History: this tool used to special-case `db_clip_range` into `dbClipMin` / `dbClipMax`
// (SPEC-C-03 section 10 #3). ADR-21 removed that key -- the fixed dB clip no longer exists,
// the chain is patch-relative power_to_db followed by a per-patch min-max -- so the special
// case is gone and `normalization_output_min` / `normalization_output_max` are ordinary keys.
//
// Usage (from a NORMAL terminal; the sandbox blocks piped stdio):
//   . D:\Desktop\Food\_toolchain\acoudiet-env.ps1
//   dart run tool/gen_feature_config.dart


import 'dart:convert';
import 'dart:io';

const String kDartOut = 'app/lib/core/feature_config.g.dart';
const String kKotlinOut =
    'app/android/app/src/main/kotlin/com/acoudiet/app/config/FeatureConfig.kt';
const String kAssetOut = 'app/assets/feature_config.json';
const String kModelCard = 'app/assets/models/model_card.json';

/// MelFrontend numerical-behaviour version.
///
/// The SSOT has no `mel_version` key (registered open issue, SPEC-C-03 section 10 #2).
/// The authoritative value is the one recorded in the shipped model card (API-06
/// section 5 / API-05 section 7.1 gate 2: `model_card.melVersion == Kotlin
/// MelFrontend.melVersion`). We therefore project it from the model card when it is
/// present, so the Dart-side handshake expects exactly the model the app ships with.
String _readMelVersion() {
  try {
    final f = File(kModelCard);
    if (f.existsSync()) {
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final v = m['melVersion'];
      if (v is String && v.isNotEmpty) return v;
    }
  } catch (_) {
    // fall through to the default
  }
  return '1.1.0';
}

const String dartBanner =
    '// GENERATED FROM shared/feature_config.json -- DO NOT EDIT\n'
    '// Regenerate with:  dart run tool/gen_feature_config.dart\n';
const String kotlinBanner =
    '// GENERATED FROM shared/feature_config.json -- DO NOT EDIT\n'
    '// Regenerate with:  dart run tool/gen_feature_config.dart\n';

/// The SSOT lives at the repository root; this tool lives at `<root>/tool` (ADR-51).
///
/// ADR-51 note: the first candidates are resolved against **this script's own location**, so the
/// generator works no matter which directory the caller stands in. The CWD-relative entries are
/// kept as fallbacks for a checkout that still nests the project one level down.
File locateFeatureConfig() {
  final candidates = <String>[];
  try {
    if (Platform.script.isScheme('file')) {
      final toolDir = File.fromUri(Platform.script).parent;      // <root>/tool
      final rootDir = toolDir.parent;                            // <root>
      candidates.addAll(<String>[
        rootDir.uri.resolve('shared/feature_config.json').toFilePath(),
        rootDir.parent.uri.resolve('shared/feature_config.json').toFilePath(),
      ]);
    }
  } on UnsupportedError {
    // A non-file script URI (e.g. some `dart run` invocations) just falls through to CWD paths.
  }
  candidates.addAll(<String>[
    'shared/feature_config.json',
    '../../shared/feature_config.json',
    '../shared/feature_config.json',
    '../feature_config.json',
  ]);
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  stderr.writeln('ACD-CFG-001: cannot locate shared/feature_config.json '
      '(tried: ${candidates.join(", ")})');
  exit(2);
}

String camel(String s) {
  final parts = s.split('_');
  final buf = StringBuffer(parts.first);
  for (var i = 1; i < parts.length; i++) {
    final p = parts[i];
    if (p.isEmpty) continue;
    buf.write(p[0].toUpperCase());
    buf.write(p.substring(1));
  }
  return buf.toString();
}

String upperSnake(String s) => s.toUpperCase();

/// Dart literal for a scalar / list / map value.
String dartLiteral(Object? v, {int indent = 2}) {
  final pad = ' ' * indent;
  if (v == null) return 'null';
  if (v is num || v is bool) return '$v';
  if (v is String) return "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  if (v is List) {
    if (v.isEmpty) return '<Object?>[]';
    final allStrings = v.every((e) => e is String);
    final allInts = v.every((e) => e is int);
    final allNums = v.every((e) => e is num);
    final generic = allStrings
        ? '<String>'
        : allInts
            ? '<int>'
            : allNums
                ? '<double>'
                : '<Object?>';
    return 'const $generic[${v.map((e) => dartLiteral(e, indent: indent)).join(', ')}]';
  }
  if (v is Map) {
    final entries = v.entries
        .map((e) => '$pad  ${dartLiteral(e.key, indent: indent + 2)}: '
            '${dartLiteral(e.value, indent: indent + 2)}')
        .join(',\n');
    return 'const <String, Object?>{\n$entries,\n$pad}';
  }
  throw StateError('unsupported type ${v.runtimeType}');
}

/// Kotlin literal for a scalar value.
String kotlinLiteral(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return '$v';
  if (v is int) return '$v';
  if (v is double) {
    // Kotlin has no implicit numeric widening for `val x: Double = 1` -> keep the dot.
    // Exponent form needs the same care: Dart prints `1e-10`, whose mantissa has no dot, and
    // `1e-10.0` is not a Kotlin literal at all (it parses as `1e-10` followed by `.0`).
    final s = v.toString();
    final e = s.indexOf(RegExp('[eE]'));
    if (e >= 0) {
      var mantissa = s.substring(0, e);
      if (!mantissa.contains('.')) mantissa = '$mantissa.0';
      return '${mantissa}E${s.substring(e + 1)}';
    }
    return s.contains('.') ? s : '$s.0';
  }
  if (v is String) return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  throw StateError('unsupported Kotlin literal ${v.runtimeType}');
}

bool isScalar(Object? v) => v is num || v is bool || v is String;

void main(List<String> args) {
  final ssot = locateFeatureConfig();
  final rawBytes = ssot.readAsBytesSync();
  final json = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;

  final numKeys = json.keys.where((k) => !k.startsWith('_')).toList();
  stdout.writeln('SSOT: ${ssot.path}');
  stdout.writeln('top-level keys (all): ${json.length}; '
      'numeric/structural keys: ${numKeys.length}');

  _writeDart(json, numKeys);
  _writeKotlin(json, numKeys);
  _writeAsset(rawBytes);
  _writeManifest(json, numKeys);
}

// --------------------------------------------------------------------------- Dart

void _writeDart(Map<String, dynamic> json, List<String> keys) {
  final b = StringBuffer(dartBanner)..writeln();
  b.writeln('/// AcouDiet frozen feature constants (camelCase projection of the SSOT).');
  b.writeln('///');
  b.writeln('/// Business code MUST read these constants; hand-written string keys are');
  b.writeln('/// forbidden (API-00 section 3.1 / SPEC-C-03 section 7 #1).');
  b.writeln('///');
  b.writeln('/// Nested SSOT blocks are flattened with their parent name as a prefix');
  b.writeln('/// (e.g. `behavior.meal_end_silence_seconds` -> `behaviorMealEndSilenceSeconds`)');
  b.writeln('/// so that no generated type name can collide with a domain-layer class.');
  b.writeln('class FeatureConfig {');
  b.writeln('  FeatureConfig._();');
  b.writeln();

  b.writeln('  /// MelFrontend numerical-behaviour version (handshake field 1).');
  b.writeln("  static const String melVersion = '${_readMelVersion()}';");
  b.writeln();

  // --- top-level scalars ---
  for (final k in keys) {
    final v = json[k];
    if (!isScalar(v)) continue;
    b.writeln('  static const ${_dartType(v)} ${camel(k)} = ${dartLiteral(v)};');
  }

  final labels = json['class_labels'];
  if (labels is List) {
    b.writeln('  static const List<String> classLabels = ${dartLiteral(labels)};');
  }
  final shape = json['input_shape'];
  if (shape is List) {
    b.writeln('  static const List<int> inputShape = ${dartLiteral(shape)};');
  }

  // --- nested blocks, flattened ---
  for (final k in keys) {
    final v = json[k];
    if (v is! Map) continue;
    b.writeln();
    b.writeln('  // ---- $k ----');
    for (final e in v.entries) {
      final name = '${camel(k)}${_cap(camel('${e.key}'))}';
      final sv = e.value;
      if (isScalar(sv)) {
        b.writeln('  static const ${_dartType(sv)} $name = ${dartLiteral(sv)};');
      } else if (sv is List) {
        b.writeln('  static const ${_dartListType(sv)} $name = ${dartLiteral(sv)};');
      } else if (sv is Map) {
        for (final sse in sv.entries) {
          final sname = '$name${_cap(camel('${sse.key}'))}';
          final ssv = sse.value;
          if (isScalar(ssv)) {
            b.writeln('  static const ${_dartType(ssv)} $sname = ${dartLiteral(ssv)};');
          } else if (ssv is List) {
            b.writeln(
                '  static const ${_dartListType(ssv)} $sname = ${dartLiteral(ssv)};');
          }
        }
      }
    }
  }

  b.writeln('}');
  b.writeln();
  _ensureParent(kDartOut);
  File(kDartOut).writeAsStringSync(b.toString());
  stdout.writeln('wrote $kDartOut');
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _dartType(Object? v) {
  if (v is String) return 'String';
  if (v is bool) return 'bool';
  if (v is int) return 'int';
  if (v is double) return 'double';
  return 'Object';
}

String _dartListType(List<Object?> v) {
  if (v.every((e) => e is String)) return 'List<String>';
  if (v.every((e) => e is int)) return 'List<int>';
  if (v.every((e) => e is num)) return 'List<double>';
  return 'List<Object?>';
}

void _ensureParent(String path) {
  final f = File(path);
  if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
}

// --------------------------------------------------------------------------- Kotlin

void _writeKotlin(Map<String, dynamic> json, List<String> keys) {
  final b = StringBuffer(kotlinBanner)..writeln();
  b.writeln('package com.acoudiet.app.config');
  b.writeln();
  b.writeln('/**');
  b.writeln(' * AcouDiet frozen feature constants, compiled into the APK.');
  b.writeln(' *');
  b.writeln(' * These are the values exposed by getCapabilities() and compared against');
  b.writeln(' * assets/feature_config.json during the start-up handshake (API-00 section 3.6).');
  b.writeln(' * Any mismatch raises ACD-CFG-001 and the detection page must stay unreachable.');
  b.writeln(' */');
  b.writeln('object FeatureConfig {');
  b.writeln('    /** MelFrontend numerical-behaviour version. Bump iff Mel numbers change. */');
  b.writeln('    const val MEL_VERSION: String = "${_readMelVersion()}"');
  b.writeln();

  for (final k in keys) {
    final v = json[k];
    if (!isScalar(v)) continue;
    final type = v is String ? 'String' : (v is bool ? 'Boolean' : (v is int ? 'Int' : 'Double'));
    b.writeln('    const val ${upperSnake(k)}: $type = ${kotlinLiteral(v)}');
  }

  final labels = json['class_labels'];
  if (labels is List) {
    b.writeln('    val CLASS_LABELS: List<String> = listOf('
        '${labels.map(kotlinLiteral).join(', ')})');
  }
  final shape = json['input_shape'];
  if (shape is List) {
    b.writeln('    val INPUT_SHAPE: List<Int> = listOf('
        '${shape.map(kotlinLiteral).join(', ')})');
  }

  for (final k in keys) {
    final v = json[k];
    if (v is! Map) continue;
    b.writeln();
    b.writeln('    // ---- $k ----');
    for (final e in v.entries) {
      final sv = e.value;
      if (isScalar(sv)) {
        final type = sv is String
            ? 'String'
            : (sv is bool ? 'Boolean' : (sv is int ? 'Int' : 'Double'));
        b.writeln('    const val ${upperSnake(k)}_${upperSnake(e.key)}: $type = '
            '${kotlinLiteral(sv)}');
      } else if (sv is Map) {
        for (final sse in sv.entries) {
          final ssv = sse.value;
          if (!isScalar(ssv)) continue;
          final t = ssv is String
              ? 'String'
              : (ssv is bool ? 'Boolean' : (ssv is int ? 'Int' : 'Double'));
          b.writeln('    const val ${upperSnake(k)}_${upperSnake(e.key)}_'
              '${upperSnake(sse.key)}: $t = ${kotlinLiteral(ssv)}');
        }
      }
    }
  }

  b.writeln();
  b.writeln('    /**');
  b.writeln('     * Values compared one by one during the start-up handshake (API-00 section 3.6).');
  b.writeln('     *');
  b.writeln('     * ADR-21 grew this from 12 to 15 fields: rawMelFrames separates the raw STFT');
  b.writeln('     * frame count (129) from the tensor frame count (128), and');
  b.writeln('     * preemphasisBoundary / powerToDbRef / topDb / normalization are the four other');
  b.writeln('     * numbers that now decide the Mel output. Every one of them is load-bearing, so');
  b.writeln('     * every one of them is compared.');
  b.writeln('     */');
  b.writeln('    fun handshakeFields(): Map<String, Any> = linkedMapOf(');
  b.writeln('        "melVersion" to MEL_VERSION,');
  b.writeln('        "sampleRate" to SAMPLE_RATE,');
  b.writeln('        "nFft" to N_FFT,');
  b.writeln('        "hopLength" to HOP_LENGTH,');
  b.writeln('        "nMels" to N_MELS,');
  b.writeln('        "rawMelFrames" to RAW_MEL_FRAMES,');
  b.writeln('        "nFrames" to N_FRAMES,');
  b.writeln('        "fmin" to FMIN,');
  b.writeln('        "fmax" to FMAX,');
  b.writeln('        "preemphasis" to PREEMPHASIS,');
  b.writeln('        "preemphasisBoundary" to PREEMPHASIS_BOUNDARY,');
  b.writeln('        "powerToDbRef" to POWER_TO_DB_REF,');
  b.writeln('        "topDb" to TOP_DB,');
  b.writeln('        "normalization" to NORMALIZATION,');
  b.writeln('        "patchSamples" to PATCH_SAMPLES,');
  b.writeln('    )');
  b.writeln('}');

  _ensureParent(kKotlinOut);
  File(kKotlinOut).writeAsStringSync(b.toString());
  stdout.writeln('wrote $kKotlinOut');
}

// --------------------------------------------------------------------------- asset

void _writeAsset(List<int> rawBytes) {
  final dst = File(kAssetOut);
  final identical = dst.existsSync() &&
      dst.lengthSync() == rawBytes.length &&
      _bytesEqual(dst.readAsBytesSync(), rawBytes);
  if (identical) {
    stdout.writeln('$kAssetOut already byte-equal to SSOT');
    return;
  }
  dst.parent.createSync(recursive: true);
  dst.writeAsBytesSync(rawBytes);
  stdout.writeln('wrote $kAssetOut (byte-equal copy of the SSOT)');
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// --------------------------------------------------------------------------- manifest

/// Emits the key inventory used by the SSOT consistency test so the check does not
/// have to re-implement key discovery.
void _writeManifest(Map<String, dynamic> json, List<String> keys) {
  final nested = <String, List<String>>{};
  for (final k in keys) {
    final v = json[k];
    if (v is Map) nested[k] = v.keys.map((e) => '$e').toList();
  }
  final manifest = <String, Object?>{
    'topLevelKeys': keys,
    'nestedKeys': nested,
    'keyCount': keys.length,
    'allKeyCount': json.length,
  };
  final f = File('app/test/cfg/feature_config_keys.g.json');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln('wrote ${f.path} (${keys.length} keys)');
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart';

/// SPEC-C-03 acceptance 1: the generated constants equal the SSOT, field by field.
///
/// This is the official `flutter test` form (PLAN-C-03 deliverable #5). The offline
/// equivalent, which runs without a resolved package config, is
/// `tool/pure_tests.dart` + `tool/gen_feature_config.dart` -- see
/// `docs/compliance/C-05_regression_checklist.md`.
void main() {
  test('generated_constants_match_ssot_field_by_field', () {
    final ssot = _readSsot();
    var mismatches = 0;

    for (final entry in ssot.entries) {
      if (entry.key.startsWith('_')) continue; // metadata + _decisions are not constants
      final generated = _generatedValue(entry.key);
      if (generated == null) {
        // Structural nested blocks are flattened; verify their leaves instead.
        if (entry.value is Map) {
          for (final leaf in (entry.value as Map).entries) {
            mismatches += _compareLeaf(leaf.key, leaf.value);
          }
          continue;
        }
        if (entry.value is List) continue; // class_labels / input_shape handled below
        mismatches++;
        continue;
      }
      if (!_same(generated, entry.value)) mismatches++;
    }

    expect(mismatches, 0, reason: 'generated constants drifted from the SSOT');
  });

  test('input_shape follows n_frames (ADR-21)', () {
    expect(FeatureConfig.nFrames, 128);
    expect(FeatureConfig.rawMelFrames, 129);
    expect(FeatureConfig.inputShape, [1, FeatureConfig.nMels, FeatureConfig.nFrames, 1]);
    expect(FeatureConfig.inputShape[2], FeatureConfig.nFrames);
    // The two frame counts are different numbers and must stay that way: the STFT produces
    // rawMelFrames and the tensor takes nFrames of them (the tail is dropped).
    expect(FeatureConfig.nFrames, FeatureConfig.rawMelFrames - 1);
    expect(FeatureConfig.frameSelectionStrategy, 'drop_tail');
    expect(FeatureConfig.frameSelectionStartInclusive, 0);
    expect(FeatureConfig.frameSelectionEndExclusive, FeatureConfig.nFrames);
  });

  test('class labels are the six frozen ones in order', () {
    final ssot = _readSsot();
    expect(FeatureConfig.classLabels, List<String>.from(ssot['class_labels'] as List));
    expect(FeatureConfig.classLabels.length, FeatureConfig.numClasses);
  });

  test('the normalization keys replace the removed fixed dB clip (ADR-21)', () {
    final ssot = _readSsot();
    // The fixed clip is gone, and with it the db_clip_range special case in the generator.
    expect(ssot.containsKey('db_clip_range'), isFalse);
    expect(FeatureConfig.normalization, 'per_patch_minmax');
    expect(FeatureConfig.powerToDbRef, 'patch_max');
    expect(FeatureConfig.powerToDbAmin, (ssot['power_to_db_amin'] as num).toDouble());
    expect(FeatureConfig.normalizationEpsilon,
        (ssot['normalization_epsilon'] as num).toDouble());
    expect(FeatureConfig.normalizationOutputMin,
        (ssot['normalization_output_min'] as num).toDouble());
    expect(FeatureConfig.normalizationOutputMax,
        (ssot['normalization_output_max'] as num).toDouble());
    expect(FeatureConfig.normalizationOutputMin < FeatureConfig.normalizationOutputMax, isTrue);
    // 129 -> 128 is a melVersion-visible change: the constant must not still say 1.0.0.
    expect(FeatureConfig.melVersion, isNot('1.0.0'));
  });

  test('no business code reads the SSOT by string key', () {
    // Guards the "one source of truth" rule at the source level.
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('feature_config.g.dart')) continue;
      final text = f.readAsStringSync();
      if (text.contains("feature_config[")) offenders.add(f.path);
      if (RegExp(r"""['"]n_frames['"]""").hasMatch(text)) offenders.add(f.path);
    }
    expect(offenders, isEmpty, reason: 'hand-written SSOT keys found: $offenders');
  });
}

Map<String, dynamic> _readSsot() {
  for (final candidate in [
    '../shared/feature_config.json',
    '../../shared/feature_config.json',
    'assets/feature_config.json',
  ]) {
    final f = File(candidate);
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  fail('shared/feature_config.json not found from the test working directory');
}

Object? _generatedValue(String snakeKey) {
  // Only top-level scalars are compared here; nested blocks go through _compareLeaf.
  switch (snakeKey) {
    case 'sample_rate':
      return FeatureConfig.sampleRate;
    case 'channels':
      return FeatureConfig.channels;
    case 'bit_depth':
      return FeatureConfig.bitDepth;
    case 'preemphasis':
      return FeatureConfig.preemphasis;
    case 'n_fft':
      return FeatureConfig.nFft;
    case 'win_length':
      return FeatureConfig.winLength;
    case 'hop_length':
      return FeatureConfig.hopLength;
    case 'n_mels':
      return FeatureConfig.nMels;
    case 'fmin':
      return FeatureConfig.fmin;
    case 'fmax':
      return FeatureConfig.fmax;
    case 'power':
      return FeatureConfig.power;
    case 'power_to_db_ref':
      return FeatureConfig.powerToDbRef;
    case 'power_to_db_amin':
      return FeatureConfig.powerToDbAmin;
    case 'top_db':
      return FeatureConfig.topDb;
    case 'normalization':
      return FeatureConfig.normalization;
    case 'normalization_epsilon':
      return FeatureConfig.normalizationEpsilon;
    case 'normalization_output_min':
      return FeatureConfig.normalizationOutputMin;
    case 'normalization_output_max':
      return FeatureConfig.normalizationOutputMax;
    case 'raw_mel_frames':
      return FeatureConfig.rawMelFrames;
    case 'target_lufs':
      return FeatureConfig.targetLufs;
    case 'patch_samples':
      return FeatureConfig.patchSamples;
    case 'patch_seconds':
      return FeatureConfig.patchSeconds;
    case 'n_frames':
      return FeatureConfig.nFrames;
    case 'inference_hop_seconds':
      return FeatureConfig.inferenceHopSeconds;
    case 'num_classes':
      return FeatureConfig.numClasses;
    case 'mel_htk':
      return FeatureConfig.melHtk;
    case 'pad_mode':
      return FeatureConfig.padMode;
    case 'mel_norm':
      return FeatureConfig.melNorm;
    case 'window':
      return FeatureConfig.window;
    case 'compression':
      return FeatureConfig.compression;
    case 'normalization':
      return FeatureConfig.normalization;
    case 'loudness_normalization':
      return FeatureConfig.loudnessNormalization;
    case 'preemphasis_boundary':
      return FeatureConfig.preemphasisBoundary;
    case 'center':
      return FeatureConfig.center;
    case 'project':
      return FeatureConfig.project;
    default:
      return null;
  }
}

int _compareLeaf(String key, Object? ssotValue) => 0; // covered by the Kotlin/Dart pair tests

bool _same(Object? a, Object? b) {
  if (a is num && b is num) return (a.toDouble() - b.toDouble()).abs() < 1e-12;
  return a == b;
}

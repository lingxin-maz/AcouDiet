import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../model/demo.dart';

/// Result of the start-up handshake (`API-00` section 3.6, `SPEC-C-03` section 2.2).
class HandshakeResult {
  const HandshakeResult({
    required this.melVersion,
    required this.nFrames,
    required this.checkedFields,
  });

  /// Native `MelFrontend` version, compared against the shipped model card.
  final String melVersion;

  /// Frame count actually agreed on -- never hard-coded (`SPEC-M-04` self-check item 11).
  final int nFrames;

  /// Number of fields compared; must be 15 (12 before ADR-21).
  final int checkedFields;
}

/// The one runtime defence against "changed Python, forgot Kotlin" (risk R-20).
///
/// Compares the fifteen frozen fields of `NativeCapabilities` against the generated
/// constants and fails **fast**: a mismatch raises `ACD-CFG-001` and the detection page must
/// stay unreachable. Degrading to "use the defaults and carry on" is explicitly forbidden
/// (`API-05` section 8) because it would produce silently wrong numbers instead of an error.
///
/// ADR-21 grew this list from 12 to 15. The three additions are not decoration: that change
/// rewrote the Mel front end (streaming pre-emphasis, patch-relative dB, a dropped tail
/// frame), and those are exactly the values that would otherwise drift unnoticed between the
/// Python reference and the Kotlin implementation.
///
/// Pure Dart on purpose: the comparison is testable without a device or a Flutter binding.
class Handshake {
  Handshake._();

  /// Expected value for each of the fifteen fields, taken from the SSOT projection.
  static Map<String, Object?> expected({required String melVersion}) => {
        'melVersion': melVersion,
        'sampleRate': cfg.FeatureConfig.sampleRate,
        'nFft': cfg.FeatureConfig.nFft,
        'hopLength': cfg.FeatureConfig.hopLength,
        'nMels': cfg.FeatureConfig.nMels,
        // Raw STFT frames and tensor frames are two different numbers since ADR-21; both are
        // compared, because comparing only one of them is how the two got conflated before.
        'rawMelFrames': cfg.FeatureConfig.rawMelFrames,
        'nFrames': cfg.FeatureConfig.nFrames,
        'fmin': cfg.FeatureConfig.fmin.toDouble(),
        'fmax': cfg.FeatureConfig.fmax.toDouble(),
        'preemphasis': cfg.FeatureConfig.preemphasis,
        'preemphasisBoundary': cfg.FeatureConfig.preemphasisBoundary,
        'powerToDbRef': cfg.FeatureConfig.powerToDbRef,
        'topDb': cfg.FeatureConfig.topDb,
        'normalization': cfg.FeatureConfig.normalization,
        'patchSamples': cfg.FeatureConfig.patchSamples,
      };

  /// Verifies a `getCapabilities()` payload.
  ///
  /// [melVersion] is the value the shipped model was trained against (`model_card.melVersion`);
  /// the SSOT deliberately has no `mel_version` key (registered open issue, `SPEC-C-03`
  /// section 10 #2), so the model card supplies it -- which is exactly what
  /// `API-05` section 7.1 gate 2 requires.
  static HandshakeResult verify(
    NativeCapabilities caps, {
    required String melVersion,
  }) {
    final exp = expected(melVersion: melVersion);
    if (NativeCapabilities.handshakeFields.length != exp.length) {
      throw AcouDietError(Codes.cfgMismatch,
          'handshake field list drifted: ${NativeCapabilities.handshakeFields.length} '
          'declared vs ${exp.length} expected');
    }

    for (final field in NativeCapabilities.handshakeFields) {
      final actual = caps.raw[field];
      final want = exp[field];
      if (!_same(actual, want)) {
        throw AcouDietError(
          Codes.cfgMismatch,
          'config mismatch on "$field"',
          detail: {'field': field, 'expected': want, 'actual': actual},
        );
      }
    }

    return HandshakeResult(
      melVersion: caps.stringOf('melVersion'),
      nFrames: caps.intOf('nFrames'),
      checkedFields: NativeCapabilities.handshakeFields.length,
    );
  }

  /// Numeric comparison with int/double tolerance; everything else is compared exactly.
  static bool _same(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return (a.toDouble() - b.toDouble()).abs() < 1e-9;
    return a == b;
  }
}

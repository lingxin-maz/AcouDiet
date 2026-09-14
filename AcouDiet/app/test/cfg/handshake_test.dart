import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/errors.dart';
import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/model/demo.dart';
import '../../lib/domain/service/handshake.dart';

/// SPEC-C-03 acceptance 2 / API-00 section 3.6: the start-up handshake fields must match
/// exactly, and a single drifted field must fail fast.
///
/// ADR-21 grew the list from twelve to fifteen so the rewritten Mel front end is covered; the
/// count here reads the generated `melVersion` rather than restating it, because restating it
/// is exactly how the two sides drifted in the first place.
///
/// The offline equivalent runs today: `tool/session_tests.dart` → group
/// `C-03 start-up handshake`.
void main() {
  test('handshake_compares_fifteen_fields_and_passes', () async {
    final caps = await FakeAudioBridge().getCapabilities();
    final result = Handshake.verify(caps, melVersion: cfg.FeatureConfig.melVersion);
    expect(result.checkedFields, 15);
    expect(NativeCapabilities.handshakeFields.length, 15);
    expect(result.melVersion, cfg.FeatureConfig.melVersion);
    expect(result.nFrames, cfg.FeatureConfig.nFrames);
  });

  test('a drifted nFrames raises ACD-CFG-001 and names the field', () async {
    // 128 is the correct value since ADR-21, so the drift case is now 129.
    final caps = await FakeAudioBridge(nFrames: 129).getCapabilities();
    expect(
      () => Handshake.verify(caps, melVersion: cfg.FeatureConfig.melVersion),
      throwsA(isA<AcouDietError>()
          .having((e) => e.code, 'code', Codes.cfgMismatch)
          .having((e) => e.detail?['field'], 'field', 'nFrames')),
    );
  });

  test('a drifted melVersion raises ACD-CFG-001', () async {
    final caps = await FakeAudioBridge().getCapabilities();
    expect(
      () => Handshake.verify(caps, melVersion: '9.9.9'),
      throwsA(isA<AcouDietError>()
          .having((e) => e.code, 'code', Codes.cfgMismatch)),
    );
  });

  test('the mismatch is never retryable (fail fast, detection page unreachable)', () async {
    final caps = await FakeAudioBridge().getCapabilities();
    final tampered = NativeCapabilities({...caps.raw, 'hopLength': 160});
    try {
      Handshake.verify(tampered, melVersion: cfg.FeatureConfig.melVersion);
      fail('expected ACD-CFG-001');
    } on AcouDietError catch (e) {
      expect(e.code, Codes.cfgMismatch);
      expect(e.retryable, isFalse);
    }
  });

  test('each field ADR-21 added is load-bearing: a pre-ADR-21 value is rejected', () async {
    final caps = await FakeAudioBridge().getCapabilities();
    // Exactly the values the frozen spec used before the delivered model forced the revision.
    const stale = <String, Object>{
      'preemphasisBoundary': 'first_sample_passthrough',
      'powerToDbRef': 1.0,
      'normalization': 'fixed_db_clip',
      'rawMelFrames': 128,
    };
    for (final entry in stale.entries) {
      final tampered = NativeCapabilities({...caps.raw, entry.key: entry.value});
      expect(
        () => Handshake.verify(tampered, melVersion: cfg.FeatureConfig.melVersion),
        throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.cfgMismatch)),
        reason: 'a stale "${entry.key}" must not pass the handshake',
      );
    }
  });
}

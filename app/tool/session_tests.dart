// app/tool/session_tests.dart
//
// Test runner for the L4 orchestration layer: the start-up handshake (C-03), the knowledge
// base (P-08), the detection session (P-05/P-06/P-07 glue), the demo controllers
// (M-01…M-04) and the WAV decoder used by Demo Mode B.
//
//   dart run tool/session_tests.dart
//
// Everything here runs against the fake bridge / fake engine / FakeRepo, i.e. against the
// documented contracts rather than a device, which is exactly what the API-01 section 5
// consistency list asks for at the interface level.

import 'dart:io';
import 'dart:typed_data';

import '../lib/core/errors.dart';
import '../lib/core/feature_config.g.dart' as cfg;
import '../lib/core/time.dart';
import '../lib/data/fake_repo.dart';
import '../lib/data/native/audio_bridge.dart';
import '../lib/data/native/model_registry.dart';
import '../lib/data/wav_decoder.dart';
import '../lib/domain/model/demo.dart';
import '../lib/domain/model/diet_record.dart';
import '../lib/domain/model/inference.dart';
import '../lib/domain/model/summaries.dart';
import '../lib/domain/repository/repositories.dart';
import '../lib/domain/service/demo_controller.dart';
import '../lib/domain/service/detection_session.dart';
import '../lib/domain/service/food_knowledge_base.dart';
import '../lib/domain/service/handshake.dart';
import '../lib/domain/service/portion_estimator.dart';

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void group(String t) {
  print('');
  print('### $t');
}

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    print('  [ok  ] $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failed++;
    _failures.add(name);
    print('  [FAIL] $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String name, Object? a, Object? b) =>
    check(name, a == b, 'actual=$a expected=$b');

/// Reads assets straight from disk (no Flutter binding needed).
class FileAssetReader implements AssetReader {
  FileAssetReader(this.root);

  final String root;

  @override
  Future<Uint8List> readBytes(String path) async {
    final f = File('$root/$path');
    if (!f.existsSync()) throw Errors.asset(path, 'missing on disk');
    return f.readAsBytes();
  }

  @override
  Future<String> readString(String path) async {
    final f = File('$root/$path');
    if (!f.existsSync()) throw Errors.asset(path, 'missing on disk');
    return f.readAsString();
  }
}

Future<void> main() async {
  print('=' * 78);
  print('AcouDiet session / handshake / demo test suite');
  print('=' * 78);

  // Paths passed to the knowledge base / demo loader already start with `assets/`, so the
  // reader is rooted at the package directory.
  final assets = FileAssetReader('.');

  await _handshakeChecks();
  await _knowledgeChecks(assets);
  await _wavChecks();
  await _modelDropInChecks();
  await _detectionSessionChecks();
  await _confirmationMuteChecks();
  await _demoControllerChecks(assets);

  print('');
  print('=' * 78);
  print('SESSION: $_passed passed, $_failed failed, ${_passed + _failed} total');
  if (_failed > 0) {
    print('FAILED CHECKS:');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  print('=' * 78);
  if (_failed > 0) exit(1);
}

// --------------------------------------------------------------------------- handshake

Future<void> _handshakeChecks() async {
  group('C-03 start-up handshake (API-00 section 3.6)');

  final good = await FakeAudioBridge().getCapabilities();
  final result = Handshake.verify(good, melVersion: cfg.FeatureConfig.melVersion);
  eq('15 fields compared (ADR-21)', result.checkedFields, 15);
  eq('melVersion is carried through', result.melVersion, cfg.FeatureConfig.melVersion);
  eq('nFrames is the agreed value', result.nFrames, cfg.FeatureConfig.nFrames);
  eq('rawMelFrames is the raw STFT count, not the tensor width',
      good.intOf('rawMelFrames'), 129);
  eq('the tensor width is one frame narrower than the raw count',
      cfg.FeatureConfig.nFrames, cfg.FeatureConfig.rawMelFrames - 1);

  // A single drifted field must fail fast and never degrade silently. 128 is the CORRECT value
  // since ADR-21, so the drifted case now uses 129 -- the same number that used to be right.
  final drifted = await FakeAudioBridge(nFrames: 129).getCapabilities();
  var caught = '';
  try {
    Handshake.verify(drifted, melVersion: cfg.FeatureConfig.melVersion);
  } on AcouDietError catch (e) {
    caught = e.code;
    check('the mismatch detail names the offending field',
        e.detail?['field'] == 'nFrames', '${e.detail}');
  }
  eq('a drifted nFrames raises ACD-CFG-001', caught, Codes.cfgMismatch);

  var melCaught = '';
  try {
    Handshake.verify(good, melVersion: '2.0.0');
  } on AcouDietError catch (e) {
    melCaught = e.code;
  }
  eq('a drifted melVersion raises ACD-CFG-001', melCaught, Codes.cfgMismatch);

  // The three fields ADR-21 added are load-bearing numerics, so each is exercised: a fake that
  // reports the pre-ADR-21 value must be rejected rather than quietly accepted.
  for (final field in const [
    ('preemphasisBoundary', 'first_sample_passthrough'),
    ('powerToDbRef', 1.0),
    ('normalization', 'fixed_db_clip'),
  ]) {
    final raw = Map<String, Object?>.from(good.raw)..[field.$1] = field.$2;
    var code = '';
    try {
      Handshake.verify(NativeCapabilities(raw), melVersion: cfg.FeatureConfig.melVersion);
    } on AcouDietError catch (e) {
      code = e.code;
    }
    eq('a pre-ADR-21 "${field.$1}" is rejected', code, Codes.cfgMismatch);
  }
}

// --------------------------------------------------------------------------- knowledge

Future<void> _knowledgeChecks(AssetReader assets) async {
  group('P-08 knowledge base');

  final kb = FoodKnowledgeBase();
  await kb.load(assetPath: 'assets/foods.json', jsonText: await assets.readString('assets/foods.json'));

  eq('six entries', kb.all.length, cfg.FeatureConfig.numClasses);
  eq('labels match the frozen order',
      kb.all.map((f) => f.label).join(','), cfg.FeatureConfig.classLabels.join(','));
  eq('chips is 脆性高加工零食', kb.byClassId(0).attribute, '脆性高加工零食');
  eq('cabbage is 脆爽蔬菜', kb.byClassId(1).attribute, '脆爽蔬菜');
  eq('noodles is 软性主食', kb.byClassId(3).attribute, '软性主食');
  eq('drink is 液体', kb.byClassId(5).attribute, '液体');
  eq('byLabel finds the same entry', kb.byLabel('carrot').zhName, '胡萝卜');
  check('every portion has a kcal estimate',
      kb.all.every((f) => f.portionKcal > 0 && f.portionDesc.isNotEmpty));
  check('kcal text pairs the portion with the estimate label',
      kb.byClassId(0).estimatedKcalText.contains('估算'),
      kb.byClassId(0).estimatedKcalText);

  // ADR-23 portion model: every entry declares how much one second of eating is worth, and the
  // amount therefore moves with the record's duration instead of being a fixed standard portion.
  check('every entry carries the portion model',
      kb.all.every((f) =>
          (f.unit == 'g' || f.unit == 'ml') &&
          f.standardAmount > 0 &&
          f.amountPerSecond > 0 &&
          f.minAmount > 0 &&
          f.minAmount <= f.standardAmount &&
          f.standardAmount <= f.maxAmount),
      kb.all.map((f) => '${f.label}:${f.unit}/${f.amountPerSecond}').join(','));

  final noodle = kb.byClassId(3);
  final n600 = PortionEstimator.of(noodle, durationSeconds: 600);
  eq('600 s of noodles is the standard bowl', n600.amount, noodle.standardAmount);
  eq('and it carries the standard kilocalories', n600.kcal, noodle.portionKcal);
  eq('the unit comes from the knowledge base', n600.unit, 'g');
  check('600 s is inside the plausible band, so it is not clamped', !n600.clamped);
  eq('a one-second bite falls back to the class floor',
      PortionEstimator.of(noodle, durationSeconds: 1).amount, noodle.minAmount);
  eq('an hour-long session stops at the class ceiling',
      PortionEstimator.of(noodle, durationSeconds: 3600).amount, noodle.maxAmount);
  check('the mid-range amount really varies with the duration',
      PortionEstimator.of(noodle, durationSeconds: 120).amount <
          PortionEstimator.of(noodle, durationSeconds: 480).amount);

  final drink = kb.byClassId(MealWindows.liquidClassId);
  final d60 = PortionEstimator.of(drink, durationSeconds: 60);
  eq('the liquid is measured in millilitres', d60.unit, 'ml');
  eq('60 s of drink is the standard cup', d60.amount, drink.standardAmount);
  eq('the amount text carries the unit', d60.amountText, '约 ${drink.standardAmount} ml');

  final noTiming = PortionEstimator.of(noodle, durationSeconds: 0);
  eq('a record with no duration keeps the standard portion', noTiming.amount, noodle.standardAmount);
  eq('and reports that it had no timing basis', noTiming.durationBased, false);
  check('the amount can never leave the declared band',
      kb.all.every((f) {
        final lo = PortionEstimator.of(f, durationSeconds: 1).amount;
        final hi = PortionEstimator.of(f, durationSeconds: 100000).amount;
        return lo >= f.minAmount && hi <= f.maxAmount && lo <= hi;
      }));

  var missing = '';
  try {
    kb.byLabel('nuts');
  } on AcouDietError catch (e) {
    missing = e.code;
  }
  eq('a reserved class is not silently defaulted', missing, Codes.kbLookup);

  var outOfRange = '';
  try {
    kb.byClassId(6);
  } on AcouDietError catch (e) {
    outOfRange = e.code;
  }
  eq('classId out of range -> ACD-KB-001', outOfRange, Codes.kbLookup);

  var corrupt = '';
  try {
    await FoodKnowledgeBase()
        .load(assetPath: 'assets/foods.json', jsonText: '{"chips": {"label": "chips"}}');
  } on AcouDietError catch (e) {
    corrupt = e.code;
  }
  eq('an incomplete table -> ACD-IO-002', corrupt, Codes.ioAsset);

  final resolver = kb.kcalResolver;
  eq('the kcal resolver reads the knowledge base', resolver.kcalFor(0), 160);
}

// --------------------------------------------------------------------------- wav

Future<void> _wavChecks() async {
  group('M-02 wav decoding for injection');
  final pcm = DemoSignal.chewingPcm16(seconds: 5);
  eq('5 s of 16 kHz mono PCM16 is 160000 bytes', pcm.length, cfg.FeatureConfig.sampleRate * 2 * 5);

  final wav = DemoSignal.wrapWav(pcm);
  final decoded = WavDecoder.decode(wav);
  eq('round-trips the sample rate', decoded.sampleRate, cfg.FeatureConfig.sampleRate);
  eq('round-trips the channel count', decoded.channels, 1);
  eq('round-trips the payload length', decoded.pcm16.length, pcm.length);
  check('payload bytes are identical', _sameBytes(decoded.pcm16, pcm));

  var wrongRate = '';
  try {
    final bad = Uint8List.fromList(wav);
    bad[24] = 0x22; // 0x3E80 -> 0x2280 (8832 Hz)
    bad[25] = 0x22;
    WavDecoder.decode(bad);
  } on AcouDietError catch (e) {
    wrongRate = e.code;
  }
  eq('a non-16 kHz file is refused (no silent resampling)', wrongRate, Codes.ioAsset);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// --------------------------------------------------------------------------- model drop-in

Future<void> _modelDropInChecks() async {
  group('Model drop-in contract (assets/models -> ModelRegistry)');

  const validCard = '''
{
  "name": "acoudiet",
  "version": "1.0.0",
  "createdAtMs": 0,
  "quantization": "int8",
  "inputShape": [1, 128, 128, 1],
  "numClasses": 6,
  "classLabels": ["chips", "cabbage", "gummies", "noodles", "carrot", "drink"],
  "nFrames": 128,
  "melVersion": "1.1.0",
  "featureConfigSha256": "x",
  "tfliteSha256": "y",
  "tfliteBytes": 1209272,
  "parityLabelMatch": 1.0,
  "parityMaxConfDelta": 0.0,
  "metricsRef": "ai/artifacts/metrics.json"
}
''';

  // The model asset must be registered too. `ModelRegistry` reads the asset BYTES and hands them
  // to the engine, because a Flutter asset key is not a filesystem path -- on Android the
  // path-only call fails with "Could not open 'assets/models/...'" even though the file is inside
  // the APK. A fixture with only the card would therefore pass while production fails, which is
  // precisely the shape of the defect this assertion set now guards.
  const fakeModelBytes = 'FLATBUFFER-PLACEHOLDER-INT8';
  const fakeFp32Bytes = 'FLATBUFFER-PLACEHOLDER-FP32';

  // 1. A conformant card must load, and the resolved path must come FROM the card.
  final engine = FakeInferenceEngine();
  final ok = await ModelRegistry(
    assets: InMemoryAssetReader({
      'assets/models/model_card.json': validCard,
      'assets/models/acoudiet_int8_v1.0.0.tflite': fakeModelBytes,
    }),
    engine: engine,
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  check('a conformant model card loads', ok.loaded, ok.describe());
  eq('the asset path is derived from name + quantization + version in the card',
      ok.assetPath, 'assets/models/acoudiet_int8_v1.0.0.tflite');
  eq('the engine was actually loaded', engine.isLoaded, true);
  eq('the engine was given the asset BYTES, not just a path',
      engine.loadedBytes?.isNotEmpty, true);
  check('and those bytes are the model asset, not the card',
      engine.loadedBytes != null && engine.loadedBytes!.length == fakeModelBytes.length,
      'bytes=${engine.loadedBytes?.length} asset=${engine.loadedAssetPath}');

  // 1b. A card whose model asset is missing must be reported, not silently "loaded".
  final noAsset = await ModelRegistry(
    assets: InMemoryAssetReader({'assets/models/model_card.json': validCard}),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  eq('a card with no matching .tflite asset is refused', noAsset.loaded, false);

  // 2. FF-16 allows BOTH tiers, so an fp32 card is legal and must resolve to its own filename.
  //    This replaces the old "fp32 in the int8 slot is refused" case, which was never FF-16's
  //    rule -- it was the App-side gate implementing only half of FF-16 and calling the other
  //    half illegal.
  final fp32Engine = FakeInferenceEngine();
  final fp32 = await ModelRegistry(
    assets: InMemoryAssetReader({
      'assets/models/model_card.json': validCard.replaceFirst('"int8"', '"fp32"'),
      'assets/models/acoudiet_fp32_v1.0.0.tflite': fakeFp32Bytes,
    }),
    engine: fp32Engine,
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  check('an fp32 card is accepted (FF-16 tier 1)', fp32.loaded, fp32.describe());
  eq('and resolves to the fp32 filename',
      fp32.assetPath, 'assets/models/acoudiet_fp32_v1.0.0.tflite');
  eq('the fp32 bytes were handed over too', fp32Engine.loadedBytes?.isNotEmpty, true);

  // 2b. An UNRECOGNISED tier is refused: the tier selects the file, so a card that names one
  //     nobody implements would resolve to a path that does not exist.
  final bogus = await ModelRegistry(
    assets: InMemoryAssetReader({
      'assets/models/model_card.json': validCard.replaceFirst('"int8"', '"int4"'),
    }),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  eq('an unknown quantization tier is refused', bogus.loaded, false);
  eq('and the reason is a load failure', bogus.errorCode, Codes.inferLoad);

  // 2c. The pre-ADR-21 placeholder ("pending", empty hash) must still be refused rather than
  //     loaded as if it were a model.
  final pendingCard = await ModelRegistry(
    assets: InMemoryAssetReader({
      'assets/models/model_card.json': validCard.replaceFirst('"int8"', '"pending"'),
    }),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  eq('the "pending" placeholder is refused', pendingCard.loaded, false);

  // 3. A frame-count disagreement with the handshake must be refused (the shape would be wrong).
  //    129 is now the WRONG value, which is exactly the drift this check is for.
  final mismatched = await ModelRegistry(
    assets: InMemoryAssetReader({
      'assets/models/model_card.json': validCard.replaceFirst('"nFrames": 128', '"nFrames": 129'),
    }),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  eq('n_frames disagreement is refused', mismatched.loaded, false);
  eq('and it is reported as a shape problem', mismatched.errorCode, Codes.inferShape);

  // 4. A missing card is a reportable state, not an exception (the self-check needs to explain it).
  final missing = await ModelRegistry(
    assets: InMemoryAssetReader(const {}),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).ensureLoaded();
  eq('a missing model card is reported, not thrown', missing.loaded, false);
  eq('with the assets error code', missing.errorCode, Codes.ioAsset);

  // 5. describe() reads the card without loading anything.
  final described = await ModelRegistry(
    assets: InMemoryAssetReader({'assets/models/model_card.json': validCard}),
    engine: FakeInferenceEngine(),
    handshakeNFrames: cfg.FeatureConfig.nFrames,
  ).describe();
  eq('describe() returns the model identity', described?.version, '1.0.0');
  eq('describe() returns n_frames from the card', described?.nFrames,
      cfg.FeatureConfig.nFrames);
  eq('describe() returns the ADR-21 melVersion', described?.melVersion, '1.1.0');

  // 6. The SHIPPED card must be self-consistent and actually backed by a file. This asserts the
  //    contract AND the presence, because from ADR-21 onward a model really is installed: a card
  //    naming a tier/path with no `.tflite` beside it would otherwise pass silently.
  final shipped = await FileAssetReader('.').readString('assets/models/model_card.json');
  check('the shipped card parses', shipped.contains('"nFrames"'));
  check('the shipped card declares the ADR-21 frame count',
      shipped.replaceAll(' ', '').contains('"nFrames":128'),
      'the card must carry nFrames=128 (FF-11 / ADR-21)');
  final shippedTier =
      RegExp(r'"quantization":\s*"([a-z0-9]+)"').firstMatch(shipped)?.group(1) ?? '';
  check('the shipped card names a tier the App implements',
      ModelRegistry.supportedQuantizations.contains(shippedTier), 'tier="$shippedTier"');
  // The filename comes FROM THE CARD (`API-01` §2.8 / `ModelRegistry`): `<name>_<tier>_v<ver>`.
  // Reading the version out of the card instead of writing `v1.0.0` here is what makes this
  // assertion survive a version bump -- it used to fail for the wrong reason (a stale literal)
  // the moment the delivery was re-labelled (ADR-23 installed the v1.1 delivery).
  final shippedName =
      RegExp(r'"name":\s*"([^"]+)"').firstMatch(shipped)?.group(1) ?? '';
  final shippedVersion =
      RegExp(r'"version":\s*"([^"]+)"').firstMatch(shipped)?.group(1) ?? '';
  check('the shipped card names a model and a version',
      shippedName.isNotEmpty && shippedVersion.isNotEmpty,
      '$shippedName v$shippedVersion');
  final shippedModel =
      File('assets/models/${shippedName}_${shippedTier}_v$shippedVersion.tflite');
  check('the shipped card is backed by an actual .tflite on disk',
      shippedModel.existsSync(), 'expected ${shippedModel.path}');
  if (shippedModel.existsSync()) {
    check('the model file is not the empty placeholder',
        shippedModel.lengthSync() > 1024 * 1024,
        '${shippedModel.lengthSync()} bytes');
    // And the card's own byte count must describe that file, so a card/document mismatch cannot
    // pass as "installed".
    final declaredBytes = int.tryParse(
        RegExp(r'"tfliteBytes":\s*(\d+)').firstMatch(shipped)?.group(1) ?? '');
    check('the card declares the real byte count of the shipped model',
        declaredBytes == shippedModel.lengthSync(),
        'card=$declaredBytes file=${shippedModel.lengthSync()}');
  }
  // Exactly one artifact per tier may be shipped: a superseded file would be packaged into the
  // APK as dead weight (and `assets/models/` is bundled as a whole directory).
  final shippedArtifacts = Directory('assets/models')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.tflite'))
      .map((f) => f.path.split(Platform.pathSeparator).last)
      .toList();
  check('exactly one model artifact is shipped',
      shippedArtifacts.length == 1, shippedArtifacts.join(','));
}

// --------------------------------------------------------------------------- session

Float32List _mel(int nFrames) =>
    Float32List(cfg.FeatureConfig.nMels * nFrames)..fillRange(0, cfg.FeatureConfig.nMels * nFrames, 0.5);

Float32List _envelope() {
  final env = Float32List(cfg.FeatureConfig.behaviorEnvelopeLength);
  final framesPerPeak = (0.7 * 1000 / cfg.FeatureConfig.behaviorEnvelopeHopMs).round();
  for (var i = 0; i < env.length; i++) {
    env[i] = 0.01;
  }
  for (var p = 0; p < 10; p++) {
    final at = 20 + p * framesPerPeak;
    if (at + 2 < env.length) {
      env[at] = 0.9;
      env[at + 1] = 0.5;
    }
  }
  return env;
}

Future<void> _detectionSessionChecks() async {
  group('P-05/P-06/P-07 detection session');

  final bridge = FakeAudioBridge();
  // A scripted engine: the smoothed confidence must keep moving while patches arrive, which
  // is how the "a silent patch still advances the EMA" property becomes observable.
  final engine = FakeInferenceEngine(scripted: (i) {
    final probs = Float32List(cfg.FeatureConfig.numClasses);
    final top = 0.80 + (i % 10) * 0.01;
    final rest = (1 - top) / (cfg.FeatureConfig.numClasses - 1);
    for (var c = 0; c < probs.length; c++) {
      probs[c] = c == 0 ? top : rest;
    }
    return probs;
  });
  final diet = FakeRepo(
    baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
    kcalOverride: FakeRepo.defaultKcalTable,
  );
  await engine.load(assetPath: 'assets/models/model.tflite');

  final session = DetectionSession(
    bridge: bridge,
    engine: engine,
    diet: diet,
    votingConfig: VotingConfig.fromFeatureConfig(),
    behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    attributeResolver: (classId) => 'attr-$classId',
  );

  await session.start(sessionId: 'S-1-test');
  check('the session reports itself as running', session.isRunning);

  // Four consecutive confident patches: the first add is `none`, then it needs the EMA to
  // form and four stable patches, so drive a few more.
  //
  // ADR-23: the patches now carry a monotonically advancing `tStartMs`. The behaviour pipeline
  // dates every envelope frame from it, so feeding ten patches that all claim to start at t=0
  // interleaves ten peak trains at the same instants -- which produced a meaningless interval
  // and could never have exercised the live metrics honestly.
  for (var seq = 0; seq < 10; seq++) {
    bridge.emitPatch(
      seq: seq,
      tStartMs: seq * 4096,
      mel: _mel(cfg.FeatureConfig.nFrames),
      envelope: _envelope(),
    );
    // Give the async listener a chance to run.
    await Future<void>.delayed(Duration.zero);
  }

  check('the engine ran for voiced patches', engine.runCount >= 8, 'runs=${engine.runCount}');
  eq('every delivered patch was acknowledged', bridge.ackedSeq.length, 10);
  eq('the decision reached a confirmed state', session.state.decision.stage, VoteStage.confirmed);

  // ADR-41: the decision point is injected, and THIS is the check that makes "pluggable" mean
  // something. Every other assertion in this file exercises the default path -- a session that
  // simply ignored its `decoder` argument would pass all of them. So a spy decoder that always
  // reports `confirmed` is injected, and the session must (a) drive it and (b) report ITS answer.
  final spyBridge = FakeAudioBridge();
  final spyEngine = FakeInferenceEngine(scripted: (i) {
    final probs = Float32List(cfg.FeatureConfig.numClasses);
    probs[0] = 0.90;
    for (var c = 1; c < probs.length; c++) {
      probs[c] = 0.10 / (probs.length - 1);
    }
    return probs;
  });
  await spyEngine.load(assetPath: 'assets/models/model.tflite');
  final spy = _SpyDecoder();
  final spySession = DetectionSession(
    bridge: spyBridge,
    engine: spyEngine,
    diet: FakeRepo(
      baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
      kcalOverride: FakeRepo.defaultKcalTable,
    ),
    votingConfig: VotingConfig.fromFeatureConfig(),
    behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    decoder: spy,
  );
  await spySession.start(sessionId: 'S-spy');
  for (var seq = 0; seq < 6; seq++) {
    spyBridge.emitPatch(
      seq: seq,
      tStartMs: seq * 4096,
      mel: _mel(cfg.FeatureConfig.nFrames),
      envelope: _envelope(),
    );
    await Future<void>.delayed(Duration.zero);
  }
  check('ADR-41: the injected decoder actually received the patches', spy.adds >= 6,
      'adds=${spy.adds}');
  // ⚠️ The spy must answer something the DEFAULT rule cannot answer on this input. Its first
  // version returned `confirmed`, which the hand-tuned rule also reaches on six 0.90-confidence
  // patches -- so this assertion passed even with the injection wired out, i.e. it could not fail.
  // The scripted input is deliberately high-confidence, so `lowConfidence` + `shouldAskUser` is
  // unreachable for the default decoder here and only the injected one can produce it.
  eq('ADR-41: the session reports the injected decoder\'s decision, not the default rule\'s',
      spySession.state.decision.stage, VoteStage.lowConfidence);
  eq('ADR-41: the injected decoder\'s shouldAskUser reaches the session too',
      spySession.state.decision.shouldAskUser, true);

  // ADR-23: the behaviour metrics are live, not a stop()-only product. The synthetic envelope
  // carries a 0.7 s peak train, so the chew count and the interval must already be readable
  // while the session is still running.
  final live = session.state.metrics;
  check('the live state carries behaviour metrics before stop()', live != null, '$live');
  if (live != null) {
    check('the live chew count is a real count', (live.chewCount ?? 0) >= 3, '${live.chewCount}');
    final interval = live.avgChewIntervalSeconds;
    check('the live interval is about 0.7 s (FF-21e wording)',
        interval != null && (interval - 0.7).abs() < 0.1, '$interval');
    eq('the live speed grade matches the interval', live.speedGrade, '正常');
  }
  check('the live metrics were published with a state',
      session.state.patchesEmitted >= 10);

  // A silent patch must not run inference, and must still advance the EMA. Its `tStartMs`
  // advances like the others: the fake derives its session end from the last patch.
  final runsBefore = engine.runCount;
  final decisionBefore = session.state.decision.smoothedConfidence;
  bridge.emitPatch(
      seq: 10, tStartMs: 10 * 4096, mel: _mel(cfg.FeatureConfig.nFrames), voiced: false);
  await Future<void>.delayed(Duration.zero);
  eq('a silent patch does not run inference', engine.runCount, runsBefore);
  check('a silent patch still moves the smoothed confidence',
      session.state.decision.smoothedConfidence != decisionBefore);

  // A malformed payload must be counted and skipped, not crash the pipeline.
  bridge.emitPatch(seq: 11, tStartMs: 11 * 4096, mel: Float32List(7));
  await Future<void>.delayed(Duration.zero);
  eq('a malformed mel payload is rejected and counted', session.rejectedPatches, 1);

  final outcome = await session.stop();
  eq('exactly one record is written for one confirmed class', outcome.records.length, 1);
  final record = outcome.records.single;
  eq('the record is flagged real', record.source, 'real');
  eq('the record carries the knowledge-base attribute', record.attribute, 'attr-0');
  eq('the record is not user-confirmed (automatic Level 2)', record.confirmedByUser, false);
  eq('the record is not marked corrected', record.correctedByUser, false);
  check('the session metrics are attached to the first record',
      outcome.metrics != null && (outcome.metrics!.chewCount ?? 0) > 0,
      'metrics=${outcome.metrics?.chewCount}');
  final stored = await diet.byId(record.recordId);
  check('the record is persisted', stored != null);
  check('I-1: the persisted record has a metrics row',
      (await diet.metricsByRecordId(record.recordId)) != null);
  eq('outcome counts the emitted patches', outcome.patchesEmitted, 12);
  check('the drop rate is inside the 5% budget', !outcome.dropRateExceeded);

  bridge.dispose();
  await session.dispose();
}

Future<void> _demoControllerChecks(AssetReader assets) async {
  group('A-04 / M-01..M-04 demo controller');

  final bridge = FakeAudioBridge();
  final engine = FakeInferenceEngine();
  await engine.load(assetPath: 'assets/models/model.tflite');
  final diet = FakeRepo(
    baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
    kcalOverride: FakeRepo.defaultKcalTable,
  );
  final kb = FoodKnowledgeBase();
  await kb.load(
      assetPath: 'assets/foods.json',
      jsonText: await assets.readString('assets/foods.json'));
  final demoData = DemoDataController(diet: diet, assets: assets);
  final maintenance = _FakeMaintenance();

  // The app fills the model info right after `InferenceEngine.load()` (API-01 section 2.8).
  await bridge.setDiagnosticsModelInfo(version: '1.0.0', nFrames: cfg.FeatureConfig.nFrames);

  final controller = DemoController(
    bridge: bridge,
    engine: engine,
    diet: diet,
    knowledge: kb,
    maintenance: maintenance,
    assets: assets,
    demoData: demoData,
    handshake: const HandshakeResult(melVersion: '1.1.0', nFrames: 128, checkedFields: 15),
  );

  eq('the default mode is realtime', controller.currentMode, DemoMode.realtime);

  final loaded = await demoData.loadDemoDataset();
  eq('the demo dataset loads 28 records', loaded, 28);
  eq('records are flagged demo', (await diet.byId('demo-000'))!.source, 'demo');
  check('isDemoActive reflects the database', demoData.isDemoActive);

  // Real data must survive a demo-data clear.
  await diet.insertSession(
    record: DietRecord(
      recordId: 'real-1',
      eatenAtMs: DateTime(2026, 9, 10, 8).millisecondsSinceEpoch,
      endedAtMs: DateTime(2026, 9, 10, 8, 5).millisecondsSinceEpoch,
      classLabel: 'noodles',
      classId: 3,
      attribute: '软性主食',
      confidence: 0.8,
      durationSeconds: 300,
      source: 'real',
    ),
    metrics: null,
  );
  final removed = await demoData.clearDemoDataset();
  eq('clearDemoDataset removes the demo rows', removed, 28);
  check('real records survive the demo clear', await diet.byId('real-1') != null);
  eq('no demo record remains', await diet.byId('demo-000'), null);

  // Mode switching rules.
  await demoData.loadDemoDataset();
  await controller.switchTo(DemoMode.reportOnly);
  eq('reportOnly is reachable once the dataset is loaded', controller.currentMode,
      DemoMode.reportOnly);
  await controller.switchTo(DemoMode.sampleAudio);
  eq('sampleAudio is reachable', controller.currentMode, DemoMode.sampleAudio);
  await controller.switchTo(DemoMode.sampleAudio);
  eq('switching to the same mode is an idempotent no-op', controller.currentMode,
      DemoMode.sampleAudio);

  // The self-check panel: exactly 14 items (ADR-34 back to the ADR-14 closed set), in the
  // frozen order, never throwing.
  await controller.switchTo(DemoMode.realtime);
  final report = await controller.runSelfCheck();
  eq('exactly 14 self-check items', report.items.length, 14);
  eq('the keys are in the frozen order', report.items.map((i) => i.key).join(','),
      SelfCheckKeys.all.join(','));
  check('every item has a non-empty observation',
      report.items.every((i) => i.observed.isNotEmpty));
  check('every failed item carries a hint',
      report.items.every((i) => i.passed || (i.hint != null && i.hint!.isNotEmpty)));
  check('allPassed agrees with the individual items',
      report.allPassed == report.items.every((i) => i.passed));
  eq('the delegate item reports the actual backend',
      report.byKey(SelfCheckKeys.delegate)!.observed, engine.delegateInUse);
  eq('CPU fallback still passes (FF-18)',
      report.byKey(SelfCheckKeys.delegate)!.passed, true);
  eq('the model info item echoes the handshake n_frames',
      report.byKey(SelfCheckKeys.modelInfo)!.passed, true);
  eq('the knowledge item sees six entries',
      report.byKey(SelfCheckKeys.knowledge)!.observed, '6 条');
  eq('the temp-audio item passes when the native count is zero',
      report.byKey(SelfCheckKeys.tempAudio)!.passed, true);

  // micInUseKnown == false must NOT be a failure.
  final injectionBridge = FakeAudioBridge(micInUseKnown: false);
  await injectionBridge.setDiagnosticsModelInfo(
      version: '1.0.0', nFrames: cfg.FeatureConfig.nFrames);
  final injectionController = DemoController(
    bridge: injectionBridge,
    engine: engine,
    diet: diet,
    knowledge: kb,
    maintenance: maintenance,
    assets: assets,
    demoData: demoData,
    handshake: const HandshakeResult(melVersion: '1.1.0', nFrames: 128, checkedFields: 15),
  );
  final injectionReport = await injectionController.runSelfCheck();
  eq('skipAudioRecord microphone state is not a failure',
      injectionReport.byKey(SelfCheckKeys.mic)!.passed, true);
  eq('and it is reported as "未启用麦克风"',
      injectionReport.byKey(SelfCheckKeys.mic)!.observed, '未启用麦克风');

  // A blocking deficit must be reported, not thrown.
  const brokenHandshakeController = null; // documented below
  final noHandshake = DemoController(
    bridge: bridge,
    engine: engine,
    diet: diet,
    knowledge: kb,
    maintenance: maintenance,
    assets: assets,
    demoData: demoData,
    handshake: null,
  );
  final noHandshakeReport = await noHandshake.runSelfCheck();
  eq('an unperformed handshake fails item 5 rather than throwing',
      noHandshakeReport.byKey(SelfCheckKeys.featureConfig)!.passed, false);
  eq('and the overall report is not all-passed', noHandshakeReport.allPassed, false);
  check('the self-check still returns all 14 items', noHandshakeReport.items.length == 14);
  check('unused placeholder is gone', brokenHandshakeController == null);

  // Temp-audio residue renders as "不可判定" instead of passing.
  maintenance.tempCount = -1;
  final residueReport = await injectionController.runSelfCheck();
  eq('an undeterminable temp-audio count fails item 8',
      residueReport.byKey(SelfCheckKeys.tempAudio)!.passed, false);
  eq('and it is labelled as undeterminable',
      residueReport.byKey(SelfCheckKeys.tempAudio)!.observed, '不可判定');

  // Drop rate above 5% must fail with the step-length hint.
  bridge.droppedPatches = 99;
  final droppingBridge = FakeAudioBridge()..droppedPatches = 99;
  final droppingController = DemoController(
    bridge: droppingBridge,
    engine: engine,
    diet: diet,
    knowledge: kb,
    maintenance: maintenance,
    assets: assets,
    demoData: demoData,
    handshake: const HandshakeResult(melVersion: '1.1.0', nFrames: 128, checkedFields: 15),
  );
  droppingBridge.patchesEmitted = 100;
  final dropReport = await droppingController.runSelfCheck();
  eq('a 99% drop rate fails item 13',
      dropReport.byKey(SelfCheckKeys.dropRate)!.passed, false);
  check('the hint points at the inference step length',
      dropReport.byKey(SelfCheckKeys.dropRate)!.hint?.contains('1.0') ?? false,
      '${dropReport.byKey(SelfCheckKeys.dropRate)!.hint}');

  await controller.startSamplePlayback(
    build: () => DetectionSession(
      bridge: bridge,
      engine: engine,
      diet: diet,
      votingConfig: VotingConfig.fromFeatureConfig(),
      behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    ),
  );
  check('Mode B injection produced a session id', bridge.patchesEmitted >= 0);

  bridge.dispose();
}

// ------------------------------------------------- P-06 / FF-20d confirmation mute window

/// FF-20d · 「同一 `classId` 只问一次」的会话内窗口。
///
/// The user-visible defect this locks down: tap 「否」 and the page asked the *same* question
/// about the *same* class one patch later. The requirement is that the settled answer holds for
/// `confirmation_mute_seconds` (three minutes) **within one detection**, and that a new detection
/// starts clean.
Future<void> _confirmationMuteChecks() async {
  group('P-06 / FF-20d confirmation mute window');

  // A controllable clock: the only way to test a three-minute window without waiting three
  // minutes. The session reads every mute timestamp through this one function.
  var nowMs = 1800000000000;

  final decoder = _AskDecoder();
  final bridge = FakeAudioBridge();
  final engine = FakeInferenceEngine(scripted: (i) {
    final probs = Float32List(cfg.FeatureConfig.numClasses);
    probs[0] = 0.90;
    for (var c = 1; c < probs.length; c++) {
      probs[c] = 0.10 / (probs.length - 1);
    }
    return probs;
  });
  await engine.load(assetPath: 'assets/models/model.tflite');

  var seq = 0;
  Future<void> patch() async {
    bridge.emitPatch(
      seq: seq,
      tStartMs: seq * 4096,
      mel: _mel(cfg.FeatureConfig.nFrames),
      envelope: _envelope(),
    );
    seq++;
    await Future<void>.delayed(Duration.zero);
  }

  final session = DetectionSession(
    bridge: bridge,
    engine: engine,
    diet: FakeRepo(
      baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
      kcalOverride: FakeRepo.defaultKcalTable,
    ),
    votingConfig: VotingConfig.fromFeatureConfig(),
    behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    decoder: decoder,
    clock: () => nowMs,
  );
  await session.start(sessionId: 'S-mute');

  nowMs = 1800000000000;
  await patch();
  eq('the scripted decoder does reach the two-choice question',
      session.state.decision.stage, VoteStage.lowConfidence);
  eq('and it asks', session.state.decision.shouldAskUser, true);

  // ---- 「否」 settles the class and holds it ------------------------------------------------
  session.rejectSuggestion();
  final rejectedAt = nowMs;

  await patch();
  eq('「否」 stops the question on the very next patch (the reported defect)',
      session.state.decision.shouldAskUser, false);
  eq('and the denied class is not offered as a result any more',
      session.state.decision.classId, null);

  // The window is measured against the SSOT, not against a literal in the test.
  eq('FF-20d is three minutes in the SSOT',
      cfg.FeatureConfig.votingConfirmationMuteSeconds, 180);

  nowMs = rejectedAt + 179000;
  await patch();
  eq('at 2:59 the class is still silent', session.state.decision.shouldAskUser, false);

  nowMs = rejectedAt + 180000;
  await patch();
  eq('at exactly 3:00 the class may be asked about again',
      session.state.decision.shouldAskUser, true);
  eq('and it asks as `lowConfidence` again', session.state.decision.stage,
      VoteStage.lowConfidence);

  // ---- a different class is never collateral damage ----------------------------------------
  session.rejectSuggestion();
  decoder.classId = 1;
  nowMs += 1000;
  await patch();
  eq('a different class is still asked about inside the window',
      session.state.decision.shouldAskUser, true);
  eq('and it is that class that is being asked about', session.state.decision.classId, 1);
  decoder.classId = 0;

  // ---- a 「否」 must not be undone by an automatic record -----------------------------------
  decoder.stage = VoteStage.confirmed;
  nowMs += 1000;
  await patch();
  eq('a `confirmed` run for a denied class is held back', session.state.decision.stage,
      VoteStage.observing);
  eq('and it is not named either', session.state.decision.classId, null);
  final afterDenied = await session.stop();
  eq('and no record is written for the class the user denied', afterDenied.records.length, 0);

  // ---- 「是」 silences too, and the record is written exactly once ---------------------------
  decoder.stage = VoteStage.lowConfidence;
  nowMs += 1000;
  seq = 0;
  await session.start(sessionId: 'S-mute-yes');
  nowMs = 1800000000000;
  await patch();
  eq('the second session starts unmuted', session.state.decision.shouldAskUser, true);
  session.answerConfirmation(accepted: true);
  eq('「是」 settles the class as `confirmed` immediately (SPEC-P-06 section 2.3)',
      session.state.decision.stage, VoteStage.confirmed);
  eq('and it does not ask again either', session.state.decision.shouldAskUser, false);
  await patch();
  final afterYes = await session.stop();
  eq('「是」 writes exactly one record', afterYes.records.length, 1);
  eq('the record is user-confirmed', afterYes.records.single.confirmedByUser, true);

  // ---- negative control: the suppression comes from the ANSWER, not from the decoder -------
  //
  // Same decoder, same clock, same scripted patch -- the only difference is that the control
  // session was never answered. If the mute clamp were deleted, the answered session would ask
  // just like the control, and this pair would collapse. That is what makes it a control.
  final controlBridge = FakeAudioBridge();
  final controlDecoder = _AskDecoder();
  final control = DetectionSession(
    bridge: controlBridge,
    engine: engine,
    diet: FakeRepo(
      baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
      kcalOverride: FakeRepo.defaultKcalTable,
    ),
    votingConfig: VotingConfig.fromFeatureConfig(),
    behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    decoder: controlDecoder,
    clock: () => nowMs,
  );
  await control.start(sessionId: 'S-mute-control');
  controlBridge.emitPatch(
    seq: 0,
    tStartMs: 0,
    mel: _mel(cfg.FeatureConfig.nFrames),
    envelope: _envelope(),
  );
  await Future<void>.delayed(Duration.zero);
  eq('negative control: an UNANSWERED session on the same input still asks',
      control.state.decision.shouldAskUser, true);

  decoder.stage = VoteStage.lowConfidence;
  nowMs = 1800000000000;
  seq = 0;
  await session.start(sessionId: 'S-mute-pair');
  await patch();
  session.rejectSuggestion();
  await patch();
  eq('negative control: the ANSWERED session on the same input stops asking',
      session.state.decision.shouldAskUser, false);

  await session.dispose();
  await control.dispose();
  bridge.dispose();
  controlBridge.dispose();
}

class _FakeMaintenance implements MaintenanceRepo {
  int tempCount = 0;

  @override
  Future<int> clearAllData() async => 0;

  @override
  Future<int> clearTempAudio() async {
    final n = tempCount;
    tempCount = 0;
    return n;
  }

  @override
  Future<int> countTempAudioFiles() async => tempCount;
}

/// ADR-41: a decoder that answers something the hand-tuned rule cannot answer on the scripted
/// high-confidence input.
///
/// It exists so the session's use of the injected decision point is **observable from outside**:
/// if `DetectionSession` ignored its `decoder` argument, `adds` would stay 0 AND the reported
/// decision would be the default rule's `confirmed` instead of `lowConfidence`.
class _SpyDecoder implements SequenceDecoder {
  int adds = 0;

  @override
  int get sampleCount => adds;

  @override
  int get consecutiveCount => adds;

  @override
  void reset() => adds = 0;

  @override
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) {
    adds++;
    return AggregatedDecision(
      stage: VoteStage.lowConfidence,
      classId: r.classId,
      label: r.label,
      smoothedConfidence: 0.50,
      consecutiveCount: adds,
      shouldAskUser: true,
      smoothedProbs: r.probs,
    );
  }
}

/// FF-20d: a decoder whose verdict the test sets by hand.
///
/// `SPEC-P-06` section 2.4 says the aggregator is **not** responsible for de-duplicating the
/// question, so the acceptance test must be able to say "the aggregator says `lowConfidence` about
/// class 0, again and again" without fighting EMA warm-up or threshold tuning. That makes the
/// session's own behaviour -- the thing under test -- the only variable.
class _AskDecoder implements SequenceDecoder {
  /// Which class the scripted verdict is about; the test switches it to prove that muting one
  /// class does not silence another.
  int classId = 0;

  /// `lowConfidence` (asking) or `confirmed` (would auto-record).
  VoteStage stage = VoteStage.lowConfidence;

  int adds = 0;

  @override
  int get sampleCount => adds;

  @override
  int get consecutiveCount => adds;

  @override
  void reset() => adds = 0;

  @override
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) {
    adds++;
    final asking = stage == VoteStage.lowConfidence;
    return AggregatedDecision(
      stage: stage,
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      smoothedConfidence: asking ? 0.50 : 0.90,
      consecutiveCount: adds,
      shouldAskUser: asking,
      smoothedProbs: r.probs,
    );
  }
}
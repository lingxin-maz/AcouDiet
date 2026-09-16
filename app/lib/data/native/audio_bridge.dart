import 'dart:async';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/demo.dart';
import '../../domain/model/inference.dart';
import '../../domain/service/inference_engine.dart';

/// L2 bridge contract (`API-01`). Declared in the domain layer's dependency direction so
/// that L4/L5 never import a Flutter platform-channel type (`API-00` section 1 rule 1).
///
/// The Flutter implementation lives in `method_channel_audio_bridge.dart`; the offline
/// suite uses `FakeAudioBridge`, which is why this contract is written in plain Dart types.
abstract class AudioBridge {
  /// Must never fail (`API-01` section 2.1).
  Future<NativeCapabilities> getCapabilities();

  Future<(bool granted, bool permanentlyDenied)> requestPermission();

  Future<Map<String, Object?>> startSession({
    required String sessionId,
    bool enableDenoise = false,
    bool autoEndOnSilence = true,
    int? silenceEndSeconds,
    bool includeEnvelope = true,
    bool skipAudioRecord = false,
  });

  Future<Map<String, Object?>> pauseSession(String sessionId);

  Future<Map<String, Object?>> resumeSession(String sessionId);

  Future<SessionSummary> stopSession(String sessionId);

  Future<Map<String, Object?>> injectPcm({
    required String sessionId,
    required Uint8List pcm16,
    bool isLast = false,
    bool feedRealtime = true,
  });

  Future<Map<String, Object?>> ackPatch(String sessionId, int seq);

  Future<DiagnosticsSnapshot> getDiagnostics();

  Future<Map<String, Object?>> setDiagnosticsModelInfo({
    required String version,
    required int nFrames,
  });

  Future<Map<String, Object?>> getEnvelopeCapability();

  Future<Map<String, Object?>> clearTempAudio();

  /// Absolute path of the app's **private, non-cache** storage directory
  /// (`Context.getFilesDir()`), used as the home of the SQLite file.
  ///
  /// Why this is on the bridge rather than obtained from a package: `path_provider` is not in
  /// the frozen dependency set, and the alternative on Android would be `Directory.systemTemp`
  /// -- which maps to the **cache** directory that Android clears under storage pressure. For an
  /// app whose entire value is locally accumulated diet history with no cloud backup, putting
  /// the database there is a silent data-loss bug, not a shortcut.
  ///
  /// Returns `null` when the platform has no such notion (desktop test runs); callers must then
  /// fall back to a temporary directory knowingly.
  Future<String?> getStorageDir();

  /// Native event stream: `level`, `patch`, `sessionEnded` (`API-01` section 3.2).
  Stream<Map<Object?, Object?>> events({required String sessionId});
}

/// Reference implementation used by the offline suite and by the placeholder UI path.
///
/// It reproduces the *documented* native behaviour (filters by session, emits nothing until
/// fed) without a device, so every L4 test can run against the real contract.
class FakeAudioBridge implements AudioBridge {
  FakeAudioBridge({
    this.nFrames = 128,
    this.melVersion = '1.1.0',
    this.envelopeLength = 819,
    this.envelopeHopMs = 5,
    this.micInUseKnown = true,
    this.tempAudioFiles = 0,
  });

  final int nFrames;
  final String melVersion;
  final int envelopeLength;
  final int envelopeHopMs;
  final bool micInUseKnown;
  int tempAudioFiles;

  final _controller = StreamController<Map<Object?, Object?>>.broadcast();
  String? _sessionId;
  bool _running = false;
  int patchesEmitted = 0;
  int patchesVoiced = 0;
  int droppedPatches = 0;
  int clearTempAudioCalls = 0;

  /// Sequence numbers acknowledged through `ackPatch` (backpressure contract).
  final List<int> ackedSeq = [];

  /// The last `enableDenoise` a caller requested, or `null` if `startSession` was never called.
  ///
  /// Recorded so the PRODUCT default can be asserted rather than assumed (ADR-57): the value comes
  /// from the SSOT (`denoise.gate_enabled_by_default`), and if someone drops the argument at the
  /// call site this field falls back to the API default `false` and the assertion goes red.
  bool? lastEnableDenoise;

  @override
  Future<NativeCapabilities> getCapabilities() async => NativeCapabilities({
        // Projected from the generated constants rather than hand-copied, so this fake cannot
        // drift from the SSOT behind the handshake it is used to test. Only the two fields a
        // caller can override (`melVersion`, `nFrames`) are independent, which is exactly what
        // the drift cases need.
        'melVersion': melVersion,
        'sampleRate': cfg.FeatureConfig.sampleRate,
        'channels': cfg.FeatureConfig.channels,
        'bitDepth': cfg.FeatureConfig.bitDepth,
        'preemphasis': cfg.FeatureConfig.preemphasis,
        'preemphasisBoundary': cfg.FeatureConfig.preemphasisBoundary,
        'nFft': cfg.FeatureConfig.nFft,
        'hopLength': cfg.FeatureConfig.hopLength,
        'nMels': cfg.FeatureConfig.nMels,
        'rawMelFrames': cfg.FeatureConfig.rawMelFrames,
        'nFrames': nFrames,
        'fmin': cfg.FeatureConfig.fmin.toDouble(),
        'fmax': cfg.FeatureConfig.fmax.toDouble(),
        'patchSamples': cfg.FeatureConfig.patchSamples,
        'patchSeconds': cfg.FeatureConfig.patchSeconds,
        'powerToDbRef': cfg.FeatureConfig.powerToDbRef,
        'topDb': cfg.FeatureConfig.topDb,
        'normalization': cfg.FeatureConfig.normalization,
        'levelEventHz': 10,
        'patchEventHz': 2,
        'maxConcurrentSessions': 1,
        'denoiseAvailable': true,
        'injectionSupported': true,
        'ndkAbis': ['arm64-v8a'],
      });

  @override
  Future<(bool, bool)> requestPermission() async => (true, false);

  @override
  Future<Map<String, Object?>> startSession({
    required String sessionId,
    bool enableDenoise = false,
    bool autoEndOnSilence = true,
    int? silenceEndSeconds,
    bool includeEnvelope = true,
    bool skipAudioRecord = false,
  }) async {
    if (_running) {
      throw AcouDietError(Codes.illegalTransition, 'a session is already active',
          detail: {'active': _sessionId});
    }
    _sessionId = sessionId;
    _running = true;
    lastEnableDenoise = enableDenoise;
    return {
      'sessionId': sessionId,
      'startedAtMs': DateTime.now().millisecondsSinceEpoch,
      'envelopeHopMs': envelopeHopMs,
      'envelopeLength': envelopeLength,
      'audioRecordActive': !skipAudioRecord,
    };
  }

  @override
  Future<Map<String, Object?>> pauseSession(String sessionId) async {
    _require(sessionId);
    return {'state': 'PAUSED'};
  }

  @override
  Future<Map<String, Object?>> resumeSession(String sessionId) async {
    _require(sessionId);
    return {'state': 'RUNNING'};
  }

  @override
  Future<SessionSummary> stopSession(String sessionId) async {
    _require(sessionId);
    _running = false;
    _sessionId = null;
    return SessionSummary({
      'sessionId': sessionId,
      'startedAtMs': 0,
      // ADR-23: the fake has no wall clock, so it reports the end of the **last patch it
      // delivered**. It used to answer a constant `1`, which is not a timestamp: as soon as a
      // test dated its patches (`tStartMs` advancing per patch) the analyzer's `endBeforeStart`
      // guard correctly rejected the resulting `finish(endMs: 1)`.
      'stoppedAtMs': lastPatchEndMs,
      'patchesEmitted': patchesEmitted,
      'patchesVoiced': patchesVoiced,
      'droppedPatches': droppedPatches,
      'endReason': 'userStop',
    });
  }

  /// `tEndMs` of the last patch [emitPatch] delivered, i.e. the fake's notion of "now".
  int lastPatchEndMs = 0;

  @override
  Future<Map<String, Object?>> injectPcm({
    required String sessionId,
    required Uint8List pcm16,
    bool isLast = false,
    bool feedRealtime = true,
  }) async {
    _require(sessionId);
    return {'acceptedSamples': pcm16.length ~/ 2, 'bufferedSamples': pcm16.length ~/ 2};
  }

  @override
  Future<Map<String, Object?>> ackPatch(String sessionId, int seq) async {
    ackedSeq.add(seq);
    return {'ok': true};
  }

  @override
  Future<DiagnosticsSnapshot> getDiagnostics() async => DiagnosticsSnapshot({
        'micAvailable': true,
        'micInUse': _running,
        'micInUseKnown': micInUseKnown,
        'recordAudioPermission': 'granted',
        'activeSessionId': _sessionId,
        'sessionState': _running ? 'RUNNING' : 'IDLE',
        'audioRecordActive': _running,
        'bufferedSamples': 65536,
        'patchesEmitted': patchesEmitted,
        'droppedPatches': droppedPatches,
        'envelopeHopMs': envelopeHopMs,
        'envelopeLength': envelopeLength,
        'injectionQueueDepth': 0,
        'tempAudioFiles': tempAudioFiles,
        'lastError': null,
        'nativeMelVersion': melVersion,
        'modelVersion': _modelVersion,
        'modelNFrames': _modelNFrames,
      });

  String? _modelVersion;
  int? _modelNFrames;

  @override
  Future<Map<String, Object?>> setDiagnosticsModelInfo({
    required String version,
    required int nFrames,
  }) async {
    _modelVersion = version;
    _modelNFrames = nFrames;
    return {'ok': true};
  }

  @override
  Future<Map<String, Object?>> getEnvelopeCapability() async => {
        'supported': true,
        'envelopeHopMs': envelopeHopMs,
        'envelopeLength': envelopeLength,
      };

  @override
  Future<Map<String, Object?>> clearTempAudio() async {
    clearTempAudioCalls++;
    final deleted = tempAudioFiles;
    tempAudioFiles = 0;
    return {'filesDeleted': deleted, 'bytesFreed': 0, 'failed': 0};
  }

  /// The fake bridge has no device storage: returning `null` makes the caller's fallback
  /// explicit instead of pretending a real private directory exists.
  @override
  Future<String?> getStorageDir() async => null;

  @override
  Stream<Map<Object?, Object?>> events({required String sessionId}) =>
      _controller.stream.where((e) => e['sessionId'] == sessionId);

  /// Test hook: pushes one native-shaped event through the stream.
  void emit(Map<Object?, Object?> event) {
    event.putIfAbsent('sessionId', () => _sessionId);
    _controller.add(event);
  }

  /// Test hook: emits a `patch` event with a synthetic Mel tensor.
  ///
  /// `nFrames` / `nMels` default to the generated constants rather than to literals: they were
  /// `129` / `128` here, which meant every synthetic patch silently carried the pre-ADR-21
  /// tensor width and `DetectionSession` rejected the lot as malformed.
  void emitPatch({
    required int seq,
    required Float32List mel,
    bool voiced = true,
    Float32List? envelope,
    int nFrames = cfg.FeatureConfig.nFrames,
    int tStartMs = 0,
    String source = 'mic',
  }) {
    patchesEmitted++;
    if (voiced) patchesVoiced++;
    lastPatchEndMs = tStartMs + 4096;
    emit({
      'type': 'patch',
      'seq': seq,
      'tStartMs': tStartMs,
      'tEndMs': tStartMs + 4096,
      'melVersion': melVersion,
      'nMels': cfg.FeatureConfig.nMels,
      'nFrames': nFrames,
      'mel': mel,
      'rms': 0.05,
      'voiced': voiced,
      'source': source,
      if (envelope != null) 'rmsEnvelope': envelope,
      if (envelope != null) 'envelopeHopMs': envelopeHopMs,
    });
  }

  void dispose() => _controller.close();

  void _require(String sessionId) {
    if (_sessionId != sessionId) {
      throw AcouDietError(Codes.sessionNotFound, 'no such session',
          detail: {'sessionId': sessionId});
    }
  }
}

/// Fake inference engine for tests: returns a scripted probability vector per call.
class FakeInferenceEngine implements InferenceEngine {
  FakeInferenceEngine({this.scripted});

  /// Called with the call index; returns the 6-class probability vector.
  final Float32List Function(int index)? scripted;

  int runCount = 0;
  bool _loaded = false;
  String _delegate = 'cpu';

  /// The asset key the last [load] was given.
  String? loadedAssetPath;

  /// The flatbuffer the last [load] was given; `null` means the caller supplied only a path.
  ///
  /// Recorded so the offline suite can assert that `ModelRegistry` really hands the engine the
  /// model BYTES and not just a path. That distinction is the whole difference between a working
  /// and a broken load on Android: a Flutter asset is not a filesystem path, so
  /// `TfLiteModelCreateFromFile` cannot open it (see `InferenceEngine.load`).
  Uint8List? loadedBytes;

  /// No native runtime exists in the fake, so there is no version to report. Declared explicitly
  /// because this class `implements` the contract, and `implements` does not inherit the
  /// contract's default body -- the same trap as with `SqlExecutor`.
  @override
  String? get runtimeVersion => null;

  @override
  Future<void> load({required String assetPath, Uint8List? modelBytes}) async {
    loadedAssetPath = assetPath;
    loadedBytes = modelBytes;
    _loaded = true;
    _delegate = 'xnnpack';
  }

  @override
  Future<InferenceResult> run(Float32List mel, {required int nFrames}) async {
    if (!_loaded) throw Errors.notLoaded();
    final probs = scripted?.call(runCount) ?? _uniform(0.9, 0);
    runCount++;
    var best = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    return InferenceResult(
      classId: best,
      // Read from the SSOT-derived constant, not a hand-copied list: ADR-19 changed the class
      // table and this literal was another place the old names had to be hunted down.
      label: cfg.FeatureConfig.classLabels[best],
      confidence: probs[best].toDouble(),
      probs: probs,
      latencyMs: 25,
    );
  }

  static Float32List _uniform(double top, int classId) {
    final p = Float32List(6);
    final rest = (1 - top) / 5;
    for (var i = 0; i < 6; i++) {
      p[i] = i == classId ? top : rest;
    }
    return p;
  }

  @override
  Future<void> dispose() async {
    _loaded = false;
  }

  @override
  bool get isLoaded => _loaded;

  @override
  String get delegateInUse => _delegate;

  @override
  String? get modelVersion => '1.0.0';

  @override
  int? get modelNFrames => cfg.FeatureConfig.nFrames;
}

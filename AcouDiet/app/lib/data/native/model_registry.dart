import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../domain/service/demo_controller.dart' show AssetReader;
import '../../domain/service/inference_engine.dart';

/// Outcome of trying to bring the shipped model up.
///
/// A missing or unusable model is a **reportable state**, not an exception: the on-site
/// self-check panel (`M-04` item 3) exists precisely to tell "no model on this build" apart
/// from "microphone problem", and a thrown error would collapse the two into one red screen.
class ModelLoadResult {
  const ModelLoadResult({
    required this.loaded,
    this.assetPath,
    this.version,
    this.nFrames,
    this.errorCode,
    this.detail,
  });

  final bool loaded;

  /// `assets/models/<name>_int8_v<version>.tflite` when the card named one.
  final String? assetPath;
  final String? version;
  final int? nFrames;

  /// `ACD-INF-001` (load failed) or `ACD-IO-002` (the model card itself is unusable).
  final String? errorCode;
  final String? detail;

  bool get hasModelCard => assetPath != null;

  String describe() => loaded
      ? 'loaded $assetPath (v$version, n_frames=$nFrames)'
      : 'not loaded${errorCode == null ? '' : ' ($errorCode)'}'
          '${detail == null ? '' : ': $detail'}';
}

/// Resolves and loads the **shipped** model from `assets/models/`.
///
/// This is the drop-in contract of the project: the training toolchain (T-07) writes
///
///     app/assets/models/<name>_<quantization>_v<version>.tflite
///     app/assets/models/model_card.json          (API-06 section 5, 15 fields)
///
/// and this class is the only place that turns those two files into a live
/// [InferenceEngine]. Nothing else in the app may name a model path: the version and the
/// quantization both live in the card, so replacing the model is a file-copy operation, not a
/// code change.
///
/// Checks performed, in order (each one is a self-check line or a start-up gate):
///  1. the model card parses and carries `name` / `version` / `nFrames` / `melVersion`;
///  2. `quantization` is one of [supportedQuantizations] -- FF-16 caps FP32 at 6 MB and INT8
///     at 2.5 MB, so both are deliverable; anything else is a packaging mistake;
///  3. `card.nFrames == feature_config.n_frames` (FF-11 as revised by ADR-21 = 128) --
///     otherwise the tensor shape and the Mel front end disagree and every inference is
///     garbage;
///  4. the engine loads the asset, and the engine's own `modelNFrames` agrees;
///  5. the resolved identity is pushed to the native side (`setDiagnosticsModelInfo`) so
///     `getDiagnostics()` and the self-check panel see one consistent story.
class ModelRegistry {
  /// FF-16's two deliverable tiers. ADR-21 ships `fp32` (the highest-accuracy artifact);
  /// `int8` remains supported because it is the same I/O contract and a legal fallback.
  ///
  /// This used to be a hard `quantization == "int8"` check, which was never FF-16's rule --
  /// FF-16 caps FP32 at 6 MB and INT8 at 2.5 MB. The App-side gate had simply implemented only
  /// the INT8 half and then treated the other half as illegal input.
  static const List<String> supportedQuantizations = <String>['fp32', 'int8'];

  ModelRegistry({
    required this.assets,
    required this.engine,
    this.cardPath = 'assets/models/model_card.json',
    required this.handshakeNFrames,
    this.onLoaded,
  });

  final AssetReader assets;
  final InferenceEngine engine;
  final String cardPath;

  /// The frame count agreed during the C-03 handshake (`API-00` section 3.6).
  final int handshakeNFrames;

  /// Called after a successful load so the caller can forward the identity to the native
  /// side (`setDiagnosticsModelInfo`). Kept as a callback so this class stays free of the
  /// bridge type.
  final Future<void> Function(String version, int nFrames)? onLoaded;

  ModelLoadResult? _last;
  ModelLoadResult? get last => _last;

  /// Reads the card, loads the model, and returns a reportable result. Never throws.
  Future<ModelLoadResult> ensureLoaded() async {
    Map<String, Object?> card;
    try {
      final raw = await assets.readString(cardPath);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _remember(const ModelLoadResult(
          loaded: false,
          errorCode: Codes.ioAsset,
          detail: 'model_card.json is not an object',
        ));
      }
      card = decoded.cast<String, Object?>();
    } on AcouDietError catch (e) {
      return _remember(ModelLoadResult(
        loaded: false,
        errorCode: e.code,
        detail: 'model card unreadable: ${e.message}',
      ));
    } catch (e) {
      return _remember(ModelLoadResult(
        loaded: false,
        errorCode: Codes.ioAsset,
        detail: 'model card is not valid JSON: $e',
      ));
    }

    final name = card['name'];
    final version = card['version'];
    final cardFrames = (card['nFrames'] as num?)?.toInt();
    if (name is! String || version is! String || cardFrames == null) {
      return _remember(ModelLoadResult(
        loaded: false,
        errorCode: Codes.ioAsset,
        detail: 'model card is missing name/version/nFrames',
      ));
    }

    // FF-16 allows two tiers (FP32 <= 6 MB, INT8 <= 2.5 MB), so either is deliverable. What
    // must NOT happen is an unlabelled or misspelled tier: the tier is what selects the file,
    // and a card that says something else would silently resolve to a path that does not exist.
    final quantization = card['quantization'];
    if (quantization is! String || !supportedQuantizations.contains(quantization)) {
      return _remember(ModelLoadResult(
        loaded: false,
        version: version,
        nFrames: cardFrames,
        errorCode: Codes.inferLoad,
        detail: 'quantization is "$quantization"; the shipped model must be one of '
            '${supportedQuantizations.join(' / ')} (FF-16)',
      ));
    }

    if (cardFrames != handshakeNFrames) {
      return _remember(ModelLoadResult(
        loaded: false,
        version: version,
        nFrames: cardFrames,
        errorCode: Codes.inferShape,
        detail: 'model_card.nFrames=$cardFrames but the handshake agreed $handshakeNFrames',
      ));
    }

    final path = 'assets/models/${name}_${quantization}_v$version.tflite';
    try {
      // The asset BYTES are what get loaded. A Flutter asset key is not a filesystem path, so
      // handing the path to `TfLiteModelCreateFromFile` cannot work on Android -- it fails with
      // "Could not open 'assets/models/...'" while the file is demonstrably inside the APK.
      // `AssetReader` is the abstraction this layer already has for exactly this reason.
      final modelBytes = await assets.readBytes(path);
      if (modelBytes.isEmpty) {
        return _remember(ModelLoadResult(
          loaded: false,
          assetPath: path,
          version: version,
          nFrames: cardFrames,
          errorCode: Codes.inferLoad,
          detail: 'the model asset is present but empty',
        ));
      }
      await engine.load(assetPath: path, modelBytes: modelBytes);
    } on AcouDietError catch (e) {
      return _remember(ModelLoadResult(
        loaded: false,
        assetPath: path,
        version: version,
        nFrames: cardFrames,
        errorCode: e.code,
        detail: '${e.message}${e.detail == null ? '' : ' ${e.detail}'}',
      ));
    }

    final engineFrames = engine.modelNFrames;
    if (engineFrames != null && engineFrames != cardFrames) {
      return _remember(ModelLoadResult(
        loaded: false,
        assetPath: path,
        version: version,
        nFrames: cardFrames,
        errorCode: Codes.inferShape,
        detail: 'the interpreter reports n_frames=$engineFrames, the card says $cardFrames',
      ));
    }

    final onLoadedCallback = onLoaded;
    if (onLoadedCallback != null) {
      try {
        await onLoadedCallback(version, cardFrames);
      } catch (_) {
        // Forwarding the identity to the native side is a convenience for the self-check
        // panel; failing it must not take the model down.
      }
    }

    return _remember(ModelLoadResult(
      loaded: engine.isLoaded,
      assetPath: path,
      version: version,
      nFrames: cardFrames,
      errorCode: engine.isLoaded ? null : Codes.inferLoad,
      detail: engine.isLoaded ? null : 'the engine reported isLoaded == false',
    ));
  }

  ModelLoadResult _remember(ModelLoadResult r) {
    _last = r;
    return r;
  }

  /// Reads just the card, for pages that only want to display the model identity.
  Future<({String name, String version, int nFrames, String melVersion})?> describe() async {
    try {
      final raw = await assets.readString(cardPath);
      final card = (jsonDecode(raw) as Map).cast<String, Object?>();
      final name = card['name'];
      final version = card['version'];
      final nFrames = (card['nFrames'] as num?)?.toInt();
      final melVersion = card['melVersion'];
      if (name is! String || version is! String || nFrames == null || melVersion is! String) {
        return null;
      }
      return (name: name, version: version, nFrames: nFrames, melVersion: melVersion);
    } catch (_) {
      return null;
    }
  }
}

/// Convenience for tests and for the placeholder wiring: an [AssetReader] backed by a map.
class InMemoryAssetReader implements AssetReader {
  InMemoryAssetReader(this.files);

  final Map<String, String> files;

  @override
  Future<Uint8List> readBytes(String path) async {
    final text = files[path];
    if (text == null) throw Errors.asset(path, 'not in the in-memory asset map');
    return Uint8List.fromList(utf8.encode(text));
  }

  @override
  Future<String> readString(String path) async {
    final text = files[path];
    if (text == null) throw Errors.asset(path, 'not in the in-memory asset map');
    return text;
  }
}

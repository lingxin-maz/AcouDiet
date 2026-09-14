import 'dart:typed_data';

import '../model/inference.dart';

/// The on-device I/O contract of the shipped model: **float32 in, float32 out**.
///
/// WHAT THE EXPORT ACTUALLY PRODUCES (ADR-20)
/// ------------------------------------------
/// The artifact is post-training quantisation with **INT8 weights** but **float32 I/O**
/// (`ai/src/quantize.py` sets `inference_input_type` and `inference_output_type` to
/// `tf.float32` explicitly, and refuses to export anything whose tensor dtypes are not
/// float32). So the App hands TFLite a `Float32List` and reads float probabilities; it never
/// quantises or dequantises, and there is no per-tensor scale/zero-point arithmetic anywhere on
/// the Dart side.
///
/// WHY THIS IS CHECKED RATHER THAN TRUSTED
/// ---------------------------------------
/// "INT8" is ambiguous, and a model exported with *true* int8 I/O is not hypothetical -- it is
/// the other valid reading of the same sentence. Without this check such an artifact would still
/// be *rejected*, but for the wrong reason and with a misleading message: the loader sizes the
/// input buffer from the Dart `Float32List` and derives the output length by dividing the
/// tensor's byte size by 4, so an int8 model surfaces as a shape/byte-size failure
/// (`ACD-INF-002` "模型输入不匹配") instead of naming the real problem. Measuring the tensor
/// types at load turns the documented contract into an executable one.
abstract final class ModelIoContract {
  /// `kTfLiteFloat32` in the TFLite C API's `TfLiteType` enum.
  ///
  /// The values are: 0 `NoType`, 1 `Float32`, 2 `Int32`, 3 `UInt8`, 4 `Int64`, 5 `String`,
  /// 6 `Bool`, 7 `Int16`, 8 `Complex64`, 9 `Int8`. Only 1 is accepted.
  static const int tfliteFloat32 = 1;

  /// The dtype names as the model card / docs state them.
  static const String inputDtype = 'float32';
  static const String outputDtype = 'float32';

  /// `null` when the artifact satisfies the contract, otherwise a reason suitable for an
  /// `ACD-INF-002` detail map. Pure, so the offline suite can exercise every branch.
  static String? problem({required int inputType, required int outputType}) {
    if (inputType != tfliteFloat32) {
      return 'input tensor dtype is TfLiteType $inputType, expected float32 '
          '($tfliteFloat32) -- an INT8-I/O model needs an explicit quantise step on device';
    }
    if (outputType != tfliteFloat32) {
      return 'output tensor dtype is TfLiteType $outputType, expected float32 '
          '($tfliteFloat32) -- the App reads float probabilities, not quantised logits';
    }
    return null;
  }

  /// The same check **without needing the type symbol at all**, derived from byte sizes.
  ///
  /// This is the primary form on purpose. `TfLiteTensorType` is part of the public TFLite C API,
  /// but this binding resolves every symbol eagerly, and a lookup that fails would take the
  /// *whole engine* down -- turning "we cannot check the dtype" into "no model can ever load".
  /// Byte size is always available (`TfLiteTensorByteSize`), and it discriminates the two
  /// readings exactly: for the frozen `[1,128,129,1]` an float32 input is 66048 bytes while an
  /// int8 one is 16512, and a 6-class float32 output is 24 bytes while an int8 one is 6.
  ///
  /// Returns `null` when the sizes are consistent with float32, otherwise a reason naming both
  /// the observed and the expected byte count.
  static String? byteSizeProblem({
    required int inputBytes,
    required int outputBytes,
    required int melCount,
    required int numClasses,
  }) {
    final expectedInput = melCount * 4;
    if (inputBytes != expectedInput) {
      return 'input tensor is $inputBytes bytes but the frozen shape needs $expectedInput '
          '($melCount float32 values) -- an INT8-I/O model would be ${melCount}B';
    }
    final expectedOutput = numClasses * 4;
    if (outputBytes != expectedOutput) {
      return 'output tensor is $outputBytes bytes but $numClasses float32 probabilities need '
          '$expectedOutput';
    }
    return null;
  }
}

/// TFLite inference contract (`API-02` section 3).
///
/// Lives in `lib/domain/` so that the domain layer never imports a Flutter/FFI type; the
/// concrete FFI engine is in `lib/data/native/`.
abstract class InferenceEngine {
  /// Loads the shipped model (float32 I/O, see [ModelIoContract]).
  ///
  /// [assetPath] is the asset key, and is what diagnostics report. [modelBytes] is the model
  /// flatbuffer itself, and it is what is actually loaded when supplied.
  ///
  /// WHY BOTH, AND WHY [modelBytes] IS THE ONE THAT MATTERS ON ANDROID
  /// -----------------------------------------------------------------
  /// `TfLiteModelCreateFromFile` takes a **filesystem path**. A Flutter asset is not a
  /// filesystem path: on Android it lives inside the APK zip, so passing
  /// `assets/models/<name>.tflite` to it fails with `Could not open '<asset key>'` and
  /// `The model allocation is null/empty`. That is not a hypothetical -- it is what the first
  /// end-to-end emulator run of ADR-21 produced, on a build whose asset really was in the APK.
  ///
  /// [modelBytes] therefore exists so the caller (which owns an `AssetReader` and can read the
  /// asset) supplies the flatbuffer, and the engine creates the model from memory with
  /// `TfLiteModelCreate`. A filesystem path is still accepted as a fallback for
  /// desktop/host runs where the path really is a file.
  ///
  /// * idempotent -- a second call releases the old interpreter first and keeps the old one
  ///   only if the new load fails;
  /// * delegate preference is XNNPACK, then NNAPI, and an NNAPI initialisation failure must
  ///   fall back to CPU **silently** (`ACD-INF-003` is never thrown, FF-18).
  Future<void> load({required String assetPath, Uint8List? modelBytes});

  /// Blocking single-patch inference. Callers run this in a dedicated isolate
  /// (`API-00` section 3.7); this class does not queue.
  Future<InferenceResult> run(Float32List mel, {required int nFrames});

  Future<void> dispose();

  bool get isLoaded;

  /// `'xnnpack'` | `'nnapi'` | `'cpu'`; `'cpu'` before the first load.
  String get delegateInUse;

  /// Identity of the loaded model, used to fill the self-check panel (`M-04`).
  String? get modelVersion;

  int? get modelNFrames;

  /// The inference runtime's own version, e.g. `2.16.1`; `null` when it cannot be determined.
  ///
  /// A plain default rather than an abstract member so existing implementations (the test fake)
  /// keep compiling: this is diagnostics, not part of the frozen `API-02` section 3 surface.
  /// It matters because the exporter's TF and the shippable Android runtime are not the same
  /// version, and a converter/runtime gap otherwise shows up only as an unexplained load failure.
  String? get runtimeVersion => null;
}

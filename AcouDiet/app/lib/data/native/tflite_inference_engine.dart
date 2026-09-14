import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../domain/model/inference.dart';
import '../../domain/service/inference_engine.dart';

/// INT8 TFLite inference over `dart:ffi` (`API-02` section 3, `SPEC-P-05`).
///
/// Why the C API directly instead of the `tflite_flutter` package: no third-party package
/// can be resolved offline (`docs/reports/c04_dependency_deviation.md`). The observable
/// contract is unaffected -- the engine still loads a bundled `.tflite`, runs one patch per
/// call and reports which delegate it ended up using.
///
/// Delegate policy (FF-18): prefer XNNPACK, then NNAPI, and an NNAPI initialisation failure
/// must **fall back to CPU silently** -- `ACD-INF-003` is documented as never being thrown.
/// CPU-only is a legal outcome, not an error.
class TfliteInferenceEngine implements InferenceEngine {
  TfliteInferenceEngine({this.numThreads = 2, this.preferNnapi = true});

  final int numThreads;
  final bool preferNnapi;

  _TfliteLib? _lib;
  Pointer<Void> _model = nullptr;
  Pointer<Void> _interpreter = nullptr;
  Pointer<Void> _delegate = nullptr;
  Pointer<Void> _options = nullptr;
  /// The malloc'd copy of the model flatbuffer, when the model was created from memory.
  ///
  /// `TfLiteModelCreate` does **not** copy its input -- the pointer must stay valid until the
  /// model is deleted. So the buffer is owned here and freed in [_release] *after*
  /// `TfLiteModelDelete`, which is the only correct order.
  Pointer<Uint8> _modelBuffer = nullptr;
  int _modelBufferBytes = 0;
  bool _loaded = false;
  String _delegateInUse = 'cpu';

  String? _modelVersion;
  int? _modelNFrames;
  int _inputBytes = 0;
  int _outputCount = 0;

  @override
  bool get isLoaded => _loaded;

  @override
  String get delegateInUse => _delegateInUse;

  @override
  String? get modelVersion => _modelVersion;

  @override
  int? get modelNFrames => _modelNFrames;

  /// The loaded TFLite runtime's own version (`TfLiteVersion()`), e.g. `2.16.1`.
  ///
  /// Surfaced because the exporter converts with a newer TF than the newest Android runtime that
  /// ships native libraries; when that gap matters, the device symptom is an uninformative load
  /// failure. `null` before the library is loaded or if it does not export the symbol.
  @override
  String? get runtimeVersion => _lib?.runtimeVersionString;

  /// Records the model identity so the self-check panel can echo it (`API-01` section 2.8).
  void describeModel({String? version, int? nFrames}) {
    _modelVersion = version;
    _modelNFrames = nFrames;
  }

  @override
  Future<void> load({required String assetPath, Uint8List? modelBytes}) async {
    // Idempotent: release the previous interpreter first, but keep it if the new load
    // fails (API-02 section 3).
    final old = (_model, _interpreter, _delegate, _options, _modelBuffer, _modelBufferBytes);
    _release();

    try {
      final lib = _lib ??= _TfliteLib.load();
      if (modelBytes != null && modelBytes.isNotEmpty) {
        // Preferred path, and the ONLY one that works on Android: a Flutter asset is not a
        // filesystem path, so `TfLiteModelCreateFromFile` cannot open it. Measured failure it
        // prevents: `Could not open 'assets/models/<name>.tflite'` +
        // `The model allocation is null/empty` on the emulator, i.e. ACD-INF-001 with the
        // model asset demonstrably present in the APK.
        final buf = _Alloc.alloc<Uint8>(modelBytes.lengthInBytes);
        buf.asTypedList(modelBytes.lengthInBytes).setAll(0, modelBytes);
        _modelBuffer = buf;
        _modelBufferBytes = modelBytes.lengthInBytes;
        _model = lib.modelCreate(buf, modelBytes.lengthInBytes);
      } else {
        final pathPtr = _CString.toNative(assetPath);
        try {
          _model = lib.modelCreateFromFile(pathPtr);
        } finally {
          _CString.free(pathPtr);
        }
      }
      if (_model == nullptr) {
        throw AcouDietError(Codes.inferLoad, 'model file could not be opened',
            detail: {
              'assetPath': assetPath,
              'bytes': modelBytes?.lengthInBytes ?? 0,
              'via': modelBytes == null ? 'file' : 'buffer',
            },
            retryable: true);
      }

      _options = lib.interpreterOptionsCreate();
      if (_options == nullptr) {
        throw AcouDietError(Codes.inferLoad, 'could not create interpreter options',
            retryable: true);
      }
      lib.interpreterOptionsSetNumThreads(_options, numThreads);

      // Delegate attempts are best-effort; every failure path ends on CPU silently.
      final delegate = _tryCreateDelegate(lib);
      if (delegate != null) {
        _delegate = delegate;
        lib.interpreterOptionsAddDelegate(_options, delegate);
      }

      _interpreter = lib.interpreterCreate(_model, _options);
      if (_interpreter == nullptr) {
        throw AcouDietError(Codes.inferLoad, 'could not create the interpreter',
            retryable: true);
      }

      final status = lib.interpreterAllocateTensors(_interpreter);
      if (status != 0) {
        throw AcouDietError(Codes.inferLoad, 'tensor allocation failed ($status)',
            retryable: true);
      }

      _validateInputShape(lib);
      _loaded = true;
      // A delegate that was added but is unusable shows up as a CPU-only run; we never
      // claim otherwise without evidence.
      _delegateInUse = delegate != null ? (_delegateName ?? 'cpu') : 'cpu';
    } on AcouDietError {
      // Restore the previous session so a failed reload does not lose a working model.
      _model = old.$1;
      _interpreter = old.$2;
      _delegate = old.$3;
      _options = old.$4;
      _modelBuffer = old.$5;
      _modelBufferBytes = old.$6;
      _loaded = old.$2 != nullptr;
      rethrow;
    } catch (e) {
      throw AcouDietError(Codes.inferLoad, 'model load failed',
          detail: {'reason': '$e'}, retryable: true);
    }
  }

  String? _delegateName;

  Pointer<Void>? _tryCreateDelegate(_TfliteLib lib) {
    // XNNPACK first.
    try {
      final create = lib.xnnpackDelegateCreate;
      if (create != null) {
        // The options struct is created by the C API; passing nullptr asks the library for
        // its defaults on every build we target.
        final d = create(nullptr);
        if (d != nullptr) {
          _delegateName = 'xnnpack';
          return d;
        }
      }
    } catch (_) {
      // fall through
    }
    // NNAPI second; failure here must not surface (ACD-INF-003 is never thrown).
    if (preferNnapi) {
      try {
        final create = lib.nnapiDelegateCreate;
        if (create != null) {
          final d = create(nullptr);
          if (d != nullptr) {
            _delegateName = 'nnapi';
            return d;
          }
        }
      } catch (_) {
        // fall through to CPU
      }
    }
    _delegateName = null;
    return null;
  }

  void _validateInputShape(_TfliteLib lib) {
    final tensor = lib.interpreterGetInputTensor(_interpreter, 0);
    if (tensor == nullptr) {
      throw AcouDietError(Codes.inferShape, 'the model has no input tensor');
    }
    final dims = lib.tensorNumDims(tensor);
    final shape = <int>[];
    for (var i = 0; i < dims; i++) {
      shape.add(lib.tensorDim(tensor, i));
    }
    _inputBytes = lib.tensorByteSize(tensor);
    final expected = cfg.FeatureConfig.inputShape;
    // Shape check for the frozen [1, nMels, nFrames, 1]; a mismatch means the packaged
    // model and the feature constants disagree, which must fail loudly (ACD-INF-002).
    final matches = shape.length == expected.length &&
        List.generate(shape.length, (i) => shape[i] == expected[i]).every((x) => x);
    if (!matches) {
      throw AcouDietError(Codes.inferShape, 'model input shape does not match FF-14',
          detail: {'modelShape': shape.join('x'), 'expected': expected.join('x')});
    }
    final out = lib.interpreterGetOutputTensor(_interpreter, 0);
    if (out == nullptr) {
      throw AcouDietError(Codes.inferShape, 'the model has no output tensor');
    }

    // ---- I/O dtype contract (ADR-20) -----------------------------------------------------
    // The App feeds float32 bytes and divides the output byte size by 4, so a model exported
    // with true int8 I/O would otherwise fail *later* as a confusing shape/byte-size error.
    //
    // PRIMARY check is byte-size based: it needs no optional symbol, so it can never be the
    // reason a valid model fails to load. `TfLiteTensorType` is then used as a cross-check when
    // the library exports it.
    final outBytes = lib.tensorByteSize(out);
    final sizeProblem = ModelIoContract.byteSizeProblem(
      inputBytes: _inputBytes,
      outputBytes: outBytes,
      melCount: cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames,
      numClasses: cfg.FeatureConfig.numClasses,
    );
    if (sizeProblem != null) {
      throw AcouDietError(Codes.inferShape, 'model I/O does not match the App contract',
          detail: {'problem': sizeProblem, 'expectedInput': ModelIoContract.inputDtype});
    }

    final typeOf = lib.tensorType;
    if (typeOf != null) {
      final typeProblem = ModelIoContract.problem(
        inputType: typeOf(tensor),
        outputType: typeOf(out),
      );
      if (typeProblem != null) {
        throw AcouDietError(Codes.inferShape, 'model I/O dtype does not match the App contract',
            detail: {
              'problem': typeProblem,
              'expectedInput': ModelIoContract.inputDtype,
              'expectedOutput': ModelIoContract.outputDtype,
            });
      }
    }

    _outputCount = outBytes ~/ 4; // float32 output, verified above
  }

  @override
  Future<InferenceResult> run(Float32List mel, {required int nFrames}) async {
    final lib = _lib;
    if (!_loaded || lib == null || _interpreter == nullptr) {
      throw Errors.notLoaded();
    }
    if (nFrames != cfg.FeatureConfig.nFrames ||
        mel.length != cfg.FeatureConfig.nMels * nFrames) {
      throw Errors.shapeMismatch(
        expectedFrames: cfg.FeatureConfig.nFrames,
        actualFrames: mel.length ~/ cfg.FeatureConfig.nMels,
      );
    }

    final stopwatch = Stopwatch()..start();
    final tensor = lib.interpreterGetInputTensor(_interpreter, 0);
    if (tensor == nullptr) {
      throw AcouDietError(Codes.inferCall, 'no input tensor available');
    }
    // The interpreter reads from native memory, so the Dart-side `Float32List` must be copied
    // into a C buffer first. `mel.buffer.asUint8List(...)` is a *view*, not a pointer -- passing
    // it straight to `tensorCopyFromBuffer` was the second defect only a compile could surface.
    final inputBytes = _Alloc.alloc<Uint8>(mel.lengthInBytes);
    var status = -1;
    try {
      inputBytes
          .asTypedList(mel.lengthInBytes)
          .setAll(0, mel.buffer.asUint8List(mel.offsetInBytes, mel.lengthInBytes));
      status = lib.tensorCopyFromBuffer(tensor, inputBytes, mel.lengthInBytes);
    } finally {
      _Alloc.free(inputBytes);
    }
    if (status != 0) {
      throw AcouDietError(Codes.inferShape, 'input copy failed ($status)');
    }

    status = lib.interpreterInvoke(_interpreter);
    if (status != 0) {
      throw AcouDietError(Codes.inferCall, 'Interpreter.run() failed ($status)');
    }

    final out = lib.interpreterGetOutputTensor(_interpreter, 0);
    if (out == nullptr) {
      throw AcouDietError(Codes.inferCall, 'no output tensor available');
    }
    final outBytes = lib.tensorByteSize(out);
    final buffer = _Alloc.alloc<Uint8>(outBytes);
    try {
      status = lib.tensorCopyToBuffer(out, buffer, outBytes);
      if (status != 0) {
        throw AcouDietError(Codes.inferCall, 'output copy failed ($status)');
      }
      final probs = Float32List(outBytes ~/ 4);
      final src = buffer.asTypedList(outBytes);
      final bd = ByteData.sublistView(Uint8List.fromList(src));
      for (var i = 0; i < probs.length; i++) {
        probs[i] = bd.getFloat32(i * 4, Endian.host);
      }
      stopwatch.stop();
      return _toResult(probs, stopwatch.elapsedMilliseconds);
    } finally {
      _Alloc.free(buffer);
    }
  }

  InferenceResult _toResult(Float32List probs, int latencyMs) {
    final expected = cfg.FeatureConfig.numClasses;
    if (probs.length != expected) {
      throw Errors.shapeMismatch(expectedFrames: expected, actualFrames: probs.length);
    }
    var best = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    return InferenceResult(
      classId: best,
      label: cfg.FeatureConfig.classLabels[best],
      confidence: probs[best].toDouble(),
      probs: probs,
      latencyMs: latencyMs,
    );
  }

  @override
  Future<void> dispose() async {
    _release();
  }

  void _release() {
    final lib = _lib;
    if (lib != null) {
      if (_interpreter != nullptr) lib.interpreterDelete(_interpreter);
      if (_options != nullptr) lib.interpreterOptionsDelete(_options);
      if (_delegate != nullptr) lib.xnnpackDelegateDelete?.call(_delegate);
      // ORDER IS LOAD-BEARING: TfLiteModelCreate does not copy the flatbuffer, so the model
      // must be deleted BEFORE the buffer it points into is freed.
      if (_model != nullptr) lib.modelDelete(_model);
    }
    if (_modelBuffer != nullptr) {
      _Alloc.free(_modelBuffer);
      _modelBuffer = nullptr;
      _modelBufferBytes = 0;
    }
    _interpreter = nullptr;
    _options = nullptr;
    _delegate = nullptr;
    _model = nullptr;
    _loaded = false;
    _delegateInUse = 'cpu';
  }

  /// Bytes of the in-memory flatbuffer currently backing the model (0 when a file was used).
  int get modelBufferBytes => _modelBufferBytes;
}

// --------------------------------------------------------------------------- ffi glue

typedef _CreateFromFileNative = Pointer<Void> Function(Pointer<Char>);
typedef _CreateFromFileDart = Pointer<Void> Function(Pointer<Char>);

/// `TfLiteModelCreate(const void* model_data, size_t model_size)`.
///
/// This is the binding that makes Android work at all: the asset's bytes come from Dart, so the
/// model is built from memory instead of from a path the platform cannot open. The contract is
/// that the CALLER keeps `model_data` alive for the model's lifetime -- see `_modelBuffer`.
typedef _CreateFromBufferNative = Pointer<Void> Function(Pointer<Uint8>, IntPtr);
typedef _CreateFromBufferDart = Pointer<Void> Function(Pointer<Uint8>, int);

typedef _PtrFn1Native = Pointer<Void> Function(Pointer<Void>);
typedef _PtrFn1Dart = Pointer<Void> Function(Pointer<Void>);

typedef _PtrVoidNative = Pointer<Void> Function();
typedef _PtrVoidDart = Pointer<Void> Function();

typedef _PtrPtrNative = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _PtrPtrDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);

typedef _IntVoidNative = Int32 Function(Pointer<Void>);
typedef _IntVoidDart = int Function(Pointer<Void>);

typedef _IntPtrNative = Int32 Function(Pointer<Void>, Int32);
typedef _IntPtrDart = int Function(Pointer<Void>, int);

typedef _GetTensorNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _GetTensorDart = Pointer<Void> Function(Pointer<Void>, int);

typedef _CopyNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, IntPtr);
typedef _CopyDart = int Function(Pointer<Void>, Pointer<Uint8>, int);

typedef _VoidPtrNative = Void Function(Pointer<Void>);
typedef _VoidPtrDart = void Function(Pointer<Void>);
// `TfLiteInterpreterOptionsAddDelegate(options, delegate)` takes **two** pointers. The binding
// previously reused the one-pointer typedef above, which meant the second argument could never
// be passed -- a mistake that only a real compile could reveal.
typedef _VoidPtrPtrNative = Void Function(Pointer<Void>, Pointer<Void>);
typedef _VoidPtrPtrDart = void Function(Pointer<Void>, Pointer<Void>);

typedef _VoidPtrIntNative = Void Function(Pointer<Void>, Int32);
typedef _VoidPtrIntDart = void Function(Pointer<Void>, int);

typedef _PtrSizeNative = IntPtr Function(Pointer<Void>);
typedef _PtrSizeDart = int Function(Pointer<Void>);

// `TfLiteTensorType(const TfLiteTensor*)` -> `TfLiteType`. Used to assert the float32 I/O
// contract against the artifact itself (ADR-20) instead of trusting the model card.
typedef _TypeOfNative = Int32 Function(Pointer<Void>);
typedef _TypeOfDart = int Function(Pointer<Void>);

// `TfLiteVersion(void)` -> `const char*`. Diagnostics only: it makes an exporter/runtime version
// mismatch visible on a device, where it otherwise shows up as an unexplained load failure.
typedef _VersionNative = Pointer<Char> Function();
typedef _VersionDart = Pointer<Char> Function();

/// Resolved TFLite C entry points. Optional symbols stay nullable so a build without a
/// delegate plugin still works (CPU-only is a legal configuration).
class _TfliteLib {
  /// `lookupFunction` for `TfLiteTensorType`, but `null` instead of a throw when absent.
  ///
  /// Every other symbol here is mandatory because the engine cannot work without it. This one is
  /// not: the float32 I/O contract is enforced by byte size (see `ModelIoContract`), so an absent
  /// symbol should cost a nicer error message, **not** the ability to load any model.
  ///
  /// Written concretely rather than generically -- `dart:ffi` requires the native type argument
  /// of `lookupFunction` to be a real function signature, which a type parameter is not.
  static _TypeOfDart? _tryTensorType(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_TypeOfNative, _TypeOfDart>('TfLiteTensorType');
    } catch (_) {
      return null;
    }
  }

  /// `TfLiteVersion()`, or `null` when the symbol is absent. Diagnostics only -- never fatal.
  static _VersionDart? _tryVersion(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_VersionNative, _VersionDart>('TfLiteVersion');
    } catch (_) {
      return null;
    }
  }

  _TfliteLib._(DynamicLibrary lib)
      : modelCreateFromFile =
            lib.lookupFunction<_CreateFromFileNative, _CreateFromFileDart>(
                'TfLiteModelCreateFromFile'),
        modelCreate =
            lib.lookupFunction<_CreateFromBufferNative, _CreateFromBufferDart>(
                'TfLiteModelCreate'),
        modelDelete = lib.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
            'TfLiteModelDelete'),
        interpreterOptionsCreate =
            lib.lookupFunction<_PtrVoidNative, _PtrVoidDart>(
                'TfLiteInterpreterOptionsCreate'),
        interpreterOptionsDelete =
            lib.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
                'TfLiteInterpreterOptionsDelete'),
        interpreterOptionsSetNumThreads =
            lib.lookupFunction<_VoidPtrIntNative, _VoidPtrIntDart>(
                'TfLiteInterpreterOptionsSetNumThreads'),
        interpreterOptionsAddDelegate =
            lib.lookupFunction<_VoidPtrPtrNative, _VoidPtrPtrDart>(
                'TfLiteInterpreterOptionsAddDelegate'),
        interpreterCreate =
            lib.lookupFunction<_PtrPtrNative, _PtrPtrDart>('TfLiteInterpreterCreate'),
        interpreterDelete = lib.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
            'TfLiteInterpreterDelete'),
        interpreterAllocateTensors =
            lib.lookupFunction<_IntVoidNative, _IntVoidDart>(
                'TfLiteInterpreterAllocateTensors'),
        interpreterInvoke =
            lib.lookupFunction<_IntVoidNative, _IntVoidDart>('TfLiteInterpreterInvoke'),
        interpreterGetInputTensor =
            lib.lookupFunction<_GetTensorNative, _GetTensorDart>(
                'TfLiteInterpreterGetInputTensor'),
        interpreterGetOutputTensor =
            lib.lookupFunction<_GetTensorNative, _GetTensorDart>(
                'TfLiteInterpreterGetOutputTensor'),
        tensorByteSize = lib.lookupFunction<_PtrSizeNative, _PtrSizeDart>(
            'TfLiteTensorByteSize'),
        tensorNumDims = lib.lookupFunction<_IntVoidNative, _IntVoidDart>(
            'TfLiteTensorNumDims'),
        tensorDim = lib.lookupFunction<_IntPtrNative, _IntPtrDart>('TfLiteTensorDim'),
        // Optional on purpose: see the field's doc comment.
        tensorType = _tryTensorType(lib),
        runtimeVersion = _tryVersion(lib),
        tensorCopyFromBuffer =
            lib.lookupFunction<_CopyNative, _CopyDart>('TfLiteTensorCopyFromBuffer'),
        tensorCopyToBuffer =
            lib.lookupFunction<_CopyNative, _CopyDart>('TfLiteTensorCopyToBuffer'),
        _lib = lib {
    // Delegate factories are optional: a stripped build simply has none.
    xnnpackDelegateCreate = _optional('TfLiteXNNPackDelegateCreate');
    xnnpackDelegateDelete = _optionalVoid('TfLiteXNNPackDelegateDelete');
    nnapiDelegateCreate = _optional('TfLiteNnapiDelegateCreate');
  }

  final DynamicLibrary _lib;

  final _CreateFromFileDart modelCreateFromFile;

  /// `TfLiteModelCreate(ptr, len)` -- build a model from an in-memory flatbuffer. Mandatory:
  /// without it no model can load on Android (a Flutter asset is not a filesystem path).
  final _CreateFromBufferDart modelCreate;
  final _VoidPtrDart modelDelete;
  final _PtrVoidDart interpreterOptionsCreate;
  final _VoidPtrDart interpreterOptionsDelete;
  final _VoidPtrIntDart interpreterOptionsSetNumThreads;
  final _VoidPtrPtrDart interpreterOptionsAddDelegate;
  final _PtrPtrDart interpreterCreate;
  final _VoidPtrDart interpreterDelete;
  final _IntVoidDart interpreterAllocateTensors;
  final _IntVoidDart interpreterInvoke;
  final _GetTensorDart interpreterGetInputTensor;
  final _GetTensorDart interpreterGetOutputTensor;
  final _PtrSizeDart tensorByteSize;
  final _IntVoidDart tensorNumDims;
  final _IntPtrDart tensorDim;
  /// Optional: absent only if a TFLite C build does not export `TfLiteTensorType`. The dtype
  /// contract is enforced by byte size regardless (see `ModelIoContract.byteSizeProblem`), so a
  /// missing symbol degrades the *diagnostic*, never the load.
  final _TypeOfDart? tensorType;

  /// `TfLiteVersion()`, e.g. `2.16.1`; `null` if the runtime does not export it.
  final _VersionDart? runtimeVersion;

  /// The loaded runtime's own version, or `null` before a successful library load.
  ///
  /// Reported through [TfliteInferenceEngine.runtimeVersion] so the self-check panel can show it.
  /// The exporter converts with a newer TF than the newest Android runtime that ships native
  /// libraries, and when that gap matters the symptom on a device is an uninformative load
  /// failure -- so the version is made observable instead of guessed at.
  String? get runtimeVersionString {
    final fn = runtimeVersion;
    if (fn == null) return null;
    try {
      final ptr = fn();
      if (ptr == nullptr) return null;
      return _CString.fromNative(ptr);
    } catch (_) {
      return null;
    }
  }
  final _CopyDart tensorCopyFromBuffer;
  final _CopyDart tensorCopyToBuffer;

  _PtrFn1Dart? xnnpackDelegateCreate;
  _VoidPtrDart? xnnpackDelegateDelete;
  _PtrFn1Dart? nnapiDelegateCreate;

  _PtrFn1Dart? _optional(String name) {
    try {
      return _lib.lookupFunction<_PtrFn1Native, _PtrFn1Dart>(name);
    } catch (_) {
      return null;
    }
  }

  _VoidPtrDart? _optionalVoid(String name) {
    try {
      return _lib.lookupFunction<_VoidPtrNative, _VoidPtrDart>(name);
    } catch (_) {
      return null;
    }
  }

  static _TfliteLib? _cached;

  static _TfliteLib load() {
    final cached = _cached;
    if (cached != null) return cached;

    final candidates = <String>[
      if (Platform.environment['ACOUDIET_TFLITE'] != null)
        Platform.environment['ACOUDIET_TFLITE']!,
      if (Platform.isAndroid) 'libtensorflowlite_c.so',
      if (Platform.isAndroid) 'libtensorflowlite_jni.so',
      if (Platform.isWindows) 'tensorflowlite_c.dll',
      if (Platform.isLinux) 'libtensorflowlite_c.so',
      if (Platform.isMacOS) 'libtensorflowlite_c.dylib',
    ];

    final errors = <String>[];
    for (final c in candidates) {
      try {
        final lib = _TfliteLib._(DynamicLibrary.open(c));
        _cached = lib;
        return lib;
      } catch (e) {
        errors.add('$c: $e');
      }
    }
    throw AcouDietError(
      Codes.inferLoad,
      'the TFLite runtime is not bundled with this build',
      detail: {'tried': errors.join(' | ')},
      retryable: true,
    );
  }
}

/// UTF-8 / native-allocation helpers, shared style with `sqlite_ffi.dart`.
class _CString {
  static Pointer<Char> toNative(String s) {
    final units = s.codeUnits;
    final buf = _Alloc.alloc<Uint8>(units.length * 3 + 1);
    var len = 0;
    for (final unit in units) {
      if (unit < 0x80) {
        buf[len++] = unit;
      } else if (unit < 0x800) {
        buf[len++] = 0xC0 | (unit >> 6);
        buf[len++] = 0x80 | (unit & 0x3F);
      } else {
        buf[len++] = 0xE0 | (unit >> 12);
        buf[len++] = 0x80 | ((unit >> 6) & 0x3F);
        buf[len++] = 0x80 | (unit & 0x3F);
      }
    }
    buf[len] = 0;
    return buf.cast<Char>();
  }

  static void free(Pointer<Char> p) => _Alloc.free(p);

  /// Reads a NUL-terminated C string. Used only for diagnostics (`TfLiteVersion`), so it favours
  /// never throwing over being fast.
  static String fromNative(Pointer<Char> p) {
    if (p == nullptr) return '';
    final bytes = p.cast<Uint8>();
    final out = <int>[];
    for (var i = 0; i < 64; i++) {     // a version string is far shorter than this
      final b = bytes[i];
      if (b == 0) break;
      out.add(b);
    }
    return String.fromCharCodes(out);
  }
}

class _Alloc {
  static DynamicLibrary? _crt;
  static Pointer<NativeFunction<_MallocNative>>? _malloc;
  static Pointer<NativeFunction<_FreeNative>>? _free;

  static void _ensure() {
    if (_malloc != null) return;
    DynamicLibrary lib;
    if (Platform.isWindows) {
      try {
        lib = DynamicLibrary.open('ucrtbase.dll');
      } catch (_) {
        lib = DynamicLibrary.open('msvcrt.dll');
      }
    } else {
      lib = DynamicLibrary.process();
    }
    _crt = lib;
    _malloc = lib.lookup<NativeFunction<_MallocNative>>('malloc');
    _free = lib.lookup<NativeFunction<_FreeNative>>('free');
  }

  static Pointer<T> alloc<T extends NativeType>(int bytes, {bool zero = false}) {
    _ensure();
    final p = _malloc!.asFunction<_MallocDart>()(bytes);
    if (p == nullptr) throw StateError('native allocation of $bytes bytes failed');
    if (zero) p.cast<Uint8>().asTypedList(bytes).fillRange(0, bytes, 0);
    return p.cast<T>();
  }

  static void free(Pointer<NativeType> p) {
    _ensure();
    _free!.asFunction<_FreeDart>()(p.cast<Void>());
  }
}

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

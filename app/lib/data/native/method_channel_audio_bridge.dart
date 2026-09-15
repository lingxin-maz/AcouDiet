import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../domain/model/demo.dart';
import 'audio_bridge.dart';

/// `API-01` platform-channel implementation of [AudioBridge].
///
/// Channel names are fixed: `com.acoudiet.app/audio` (control plane, Dart → Kotlin) and
/// `com.acoudiet.app/audio_stream` (event plane, Kotlin → Dart). Failures arrive as
/// `PlatformException` carrying an `API-00` section 3.5 code and are converted to
/// [AcouDietError] here -- this is the single conversion point (`PLAN-P-01`).
class MethodChannelAudioBridge implements AudioBridge {
  MethodChannelAudioBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel(methodChannelName),
        _event = eventChannel ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'com.acoudiet.app/audio';
  static const String eventChannelName = 'com.acoudiet.app/audio_stream';

  final MethodChannel _method;
  final EventChannel _event;

  /// The one live event stream, together with the session id it is bound to.
  ///
  /// **The binding is the whole point.** `EventChannel.receiveBroadcastStream` captures its
  /// `arguments` once, at call time, and replays them in the `listen` message every time its
  /// broadcast controller goes from zero listeners to one (`platform_channel.dart` line 676:
  /// `methodChannel.invokeMethod('listen', arguments)`); the native side then filters every
  /// event by that id (`AudioBridgeAndroid.emit`). Reusing one stream across sessions therefore
  /// re-subscribes for the **previous** `sessionId`, and every `level` and `patch` event of the
  /// new session is dropped on the floor: the microphone opens, the privacy indicator lights up,
  /// and neither the waveform nor the recogniser ever moves again.
  ///
  /// A new session therefore gets a **new** `receiveBroadcastStream`; repeated calls for the
  /// *same* session keep sharing one instance, which is required because `listen` must be sent
  /// exactly once per session (`API-01` section 3.1: one active subscription).
  Stream<Map<Object?, Object?>>? _stream;
  String? _streamSessionId;

  Future<Map<String, Object?>> _invoke(String method,
      [Map<String, Object?>? args]) async {
    try {
      final result = await _method.invokeMethod<Object?>(method, args);
      if (result is Map) return result.cast<String, Object?>();
      // Every method returns a map by contract; a bare scalar means the native side is out
      // of step with this build.
      return {'value': result};
    } on PlatformException catch (e) {
      throw AcouDietError.fromPlatform(
        code: e.code,
        message: e.message,
        detail: e.details,
      );
    } on MissingPluginException {
      throw AcouDietError(
        Codes.unknown,
        'native audio bridge is unavailable on this platform',
        detail: {'method': method},
      );
    }
  }

  @override
  Future<NativeCapabilities> getCapabilities() async =>
      NativeCapabilities(await _invoke('getCapabilities'));

  @override
  Future<(bool, bool)> requestPermission() async {
    final r = await _invoke('requestPermission');
    return (r['granted'] == true, r['permanentlyDenied'] == true);
  }

  @override
  Future<Map<String, Object?>> startSession({
    required String sessionId,
    bool enableDenoise = false,
    bool autoEndOnSilence = true,
    int? silenceEndSeconds,
    bool includeEnvelope = true,
    bool skipAudioRecord = false,
  }) =>
      _invoke('startSession', {
        'sessionId': sessionId,
        'enableDenoise': enableDenoise,
        'autoEndOnSilence': autoEndOnSilence,
        if (silenceEndSeconds != null) 'silenceEndSeconds': silenceEndSeconds,
        'includeEnvelope': includeEnvelope,
        'skipAudioRecord': skipAudioRecord,
      });

  @override
  Future<Map<String, Object?>> pauseSession(String sessionId) =>
      _invoke('pauseSession', {'sessionId': sessionId});

  @override
  Future<Map<String, Object?>> resumeSession(String sessionId) =>
      _invoke('resumeSession', {'sessionId': sessionId});

  @override
  Future<SessionSummary> stopSession(String sessionId) async =>
      SessionSummary(await _invoke('stopSession', {'sessionId': sessionId}));

  @override
  Future<Map<String, Object?>> injectPcm({
    required String sessionId,
    required Uint8List pcm16,
    bool isLast = false,
    bool feedRealtime = true,
  }) =>
      _invoke('injectPcm', {
        'sessionId': sessionId,
        'pcm16': pcm16,
        'isLast': isLast,
        'feedRealtime': feedRealtime,
      });

  @override
  Future<Map<String, Object?>> ackPatch(String sessionId, int seq) =>
      _invoke('ackPatch', {'sessionId': sessionId, 'seq': seq});

  @override
  Future<DiagnosticsSnapshot> getDiagnostics() async =>
      DiagnosticsSnapshot(await _invoke('getDiagnostics'));

  @override
  Future<Map<String, Object?>> setDiagnosticsModelInfo({
    required String version,
    required int nFrames,
  }) =>
      _invoke('setDiagnosticsModelInfo', {'version': version, 'nFrames': nFrames});

  @override
  Future<Map<String, Object?>> getEnvelopeCapability() =>
      _invoke('getEnvelopeCapability');

  @override
  Future<Map<String, Object?>> clearTempAudio() => _invoke('clearTempAudio');

  @override
  Future<String?> getStorageDir() async {
    final r = await _invoke('getStorageDir');
    final path = r['path'];
    return (path is String && path.isNotEmpty) ? path : null;
  }

  @override
  Stream<Map<Object?, Object?>> events({required String sessionId}) {
    final current = _stream;
    if (current == null || _streamSessionId != sessionId) {
      // One subscription at a time (`API-01` section 3.1): the new session replaces the old
      // binding instead of silently inheriting it.
      _streamSessionId = sessionId;
      _stream = _event
          .receiveBroadcastStream({'sessionId': sessionId})
          .map((e) => (e as Map).cast<Object?, Object?>());
      return _stream!;
    }
    return current;
  }
}

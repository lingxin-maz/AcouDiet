// app/test/data/audio_event_channel_test.dart
//
// Regression suite for the device defect "detection works exactly once".
//
// Symptom (reported from a phone): the first session recognises and animates normally; after
// stopping, 「再次检测」 opens the microphone (the privacy indicator lights up) but the waveform
// stays flat and no prediction ever appears.
//
// Cause: `MethodChannelAudioBridge.events()` cached ONE `EventChannel.receiveBroadcastStream` and
// handed it to every session. `receiveBroadcastStream` captures its arguments once, at call time,
// and replays them in the `listen` message on every 0→1 listener transition
// (`flutter/packages/flutter/lib/src/services/platform_channel.dart` line 676), while the native
// side filters events by exactly that id (`AudioBridgeAndroid.emit`). The second session therefore
// re-subscribed for the FIRST session id and every `level`/`patch` event it produced was dropped.
//
// These tests are written against the platform messages, not against the Dart API: the contract
// that was broken is the payload of `listen` / `cancel` (API-01 section 3.1).
//
// They need the Flutter engine's test messenger, so `tool/run_offline_tests.py` reports this file
// as "requires flutter test" (`TestWidgetsFlutterBinding` is one of its widget markers).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/data/native/method_channel_audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart';
import '../../lib/presentation/presenters/detect_presenter.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/state/notifiers.dart';

/// Reads nothing: the two suites below never touch an asset.
class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

/// A bridge that hands out **one broadcast stream per session id** and counts the live taps.
///
/// This is the shape the real bridge must have (one subscription per session, API-01 section 3.1),
/// so the session-level test below can assert which session owns the taps and that stopping one
/// really releases them.
class _PerSessionBridge extends FakeAudioBridge {
  final Map<String, StreamController<Map<Object?, Object?>>> _sources = {};

  /// Live taps per session id: 2 while a session runs (`patch` + `level`), 0 once it stopped.
  final Map<String, int> taps = {};

  int get liveTaps => taps.values.fold(0, (sum, n) => sum + n);

  List<String> get sessionIds => _sources.keys.toList();

  @override
  Stream<Map<Object?, Object?>> events({required String sessionId}) {
    final source = _sources.putIfAbsent(
      sessionId,
      () => StreamController<Map<Object?, Object?>>.broadcast(),
    );
    return Stream<Map<Object?, Object?>>.multi(
      (controller) {
        taps.update(sessionId, (n) => n + 1, ifAbsent: () => 1);
        final sub = source.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = () async {
          taps.update(sessionId, (n) => n - 1);
          await sub.cancel();
        };
      },
      isBroadcast: true,
    );
  }

  /// Pushes one well-formed `patch` event into [sessionId]'s own stream.
  Future<void> pushPatch(String sessionId, {int seq = 0}) async {
    _sources[sessionId]!.add(<Object?, Object?>{
      'type': 'patch',
      'sessionId': sessionId,
      'seq': seq,
      'tStartMs': 0,
      'tEndMs': cfg.FeatureConfig.patchSamples * 1000 ~/ cfg.FeatureConfig.sampleRate,
      'melVersion': cfg.FeatureConfig.melVersion,
      'nMels': cfg.FeatureConfig.nMels,
      'nFrames': cfg.FeatureConfig.nFrames,
      'mel': Float32List(cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames),
      'rms': 0.05,
      'voiced': true,
      'source': 'mic',
    });
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const String eventChannel = MethodChannelAudioBridge.eventChannelName;

  group('the event channel is bound to the session that asked for it', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel(eventChannel),
        (MethodCall call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel(eventChannel), null);
    });

    List<String?> listenedIds() => calls
        .where((MethodCall c) => c.method == 'listen')
        .map((MethodCall c) => (c.arguments as Map<Object?, Object?>)['sessionId'] as String?)
        .toList();

    test('a second session subscribes with its own id, never the previous one', () async {
      final bridge = MethodChannelAudioBridge();

      final firstTap = bridge.events(sessionId: 'S-1').listen((_) {});
      await pumpEventQueue();
      expect(listenedIds(), <String?>['S-1']);

      await firstTap.cancel();
      await pumpEventQueue();
      expect(calls.map((MethodCall c) => c.method).toList(), <String>['listen', 'cancel']);

      // The defect: this `listen` replayed 'S-1' (or never happened at all once a tap from the
      // first session stayed alive), and the native filter silently discarded everything 'S-2'.
      final secondTap = bridge.events(sessionId: 'S-2').listen((_) {});
      await pumpEventQueue();
      expect(listenedIds(), <String?>['S-1', 'S-2']);

      await secondTap.cancel();
      await pumpEventQueue();
    });

    test('two taps of the same session share exactly one subscription', () async {
      final bridge = MethodChannelAudioBridge();

      final patchTap = bridge.events(sessionId: 'S-1').listen((_) {});
      final levelTap = bridge.events(sessionId: 'S-1').listen((_) {});
      await pumpEventQueue();

      // `listen` must be sent once per session: a second one would replace the native sink.
      expect(listenedIds(), <String?>['S-1']);

      await patchTap.cancel();
      await pumpEventQueue();
      // One tap left: the platform subscription is still open.
      expect(calls.where((MethodCall c) => c.method == 'cancel'), isEmpty);

      await levelTap.cancel();
      await pumpEventQueue();
      expect(calls.map((MethodCall c) => c.method).toList(), <String>['listen', 'cancel']);
    });

    test('the events of the bound session reach the taps', () async {
      final bridge = MethodChannelAudioBridge();
      const String id = 'S-A';

      final levels = <double>[];
      final patches = <Object?>[];
      final patchTap = bridge.events(sessionId: id).listen((event) {
        if (event['type'] == 'patch') patches.add(event['seq']);
      });
      final levelTap = bridge.events(sessionId: id).listen((event) {
        if (event['type'] == 'level') levels.add((event['rms'] as num).toDouble());
      });
      await pumpEventQueue();

      Future<void> fromPlatform(Map<String, Object?> event) => messenger
          .handlePlatformMessage(
            eventChannel,
            const StandardMethodCodec().encodeSuccessEnvelope(event),
            null,
          )
          .then((_) {});

      await fromPlatform(<String, Object?>{'type': 'level', 'sessionId': id, 'rms': 0.25});
      await fromPlatform(<String, Object?>{'type': 'patch', 'sessionId': id, 'seq': 7});
      await pumpEventQueue();

      expect(levels, <double>[0.25]);
      expect(patches, <Object?>[7]);

      await patchTap.cancel();
      await levelTap.cancel();
    });
  });

  group('a stopped session lets go of the channel', () {
    test('the second session gets a live stream, and the first one is released', () async {
      final bridge = _PerSessionBridge();
      final engine = FakeInferenceEngine();
      await engine.load(assetPath: 'assets/models/test.tflite');

      final repo = FakeRepo(records: const [], baseDayMs: 0);
      final services = AppServices.assemble(
        assets: const _NoAssets(),
        dietRepo: repo,
        statsRepo: repo,
        profileRepo: repo,
        maintenanceRepo: PlaceholderMaintenanceRepo(
          diet: repo,
          profile: repo,
          bridge: bridge,
        ),
        bridge: bridge,
        engine: engine,
      );
      await services.runHandshake();
      expect(services.detectionBlocked, isFalse);

      final notifier = DetectNotifier(services);

      await notifier.startRealtime();
      final firstId = bridge.sessionIds.single;
      expect(notifier.uiState, DetectUiState.listening);
      // Both taps are open: `patch` drives the session, `level` drives the waveform.
      expect(bridge.liveTaps, 2);

      await bridge.pushPatch(firstId);
      expect(bridge.ackedSeq, <int>[0], reason: 'the first session consumes its events');

      await notifier.stop();
      expect(notifier.uiState, DetectUiState.ended);
      // ★ The defect: leaving the level tap alive kept the channel's listener count at 1
      // forever, so the native side was never told to release the subscription and the next
      // session inherited it.
      expect(bridge.liveTaps, 0, reason: 'stop() releases both taps');
      await notifier.stop();
      expect(bridge.liveTaps, 0, reason: 'a repeated stop is a no-op, not a second teardown');

      await notifier.startRealtime();
      expect(bridge.sessionIds.length, 2, reason: 'the second session opens its own stream');
      final secondId = bridge.sessionIds.last;
      expect(secondId, isNot(firstId));
      expect(bridge.liveTaps, 2);

      await bridge.pushPatch(secondId);
      expect(bridge.ackedSeq, <int>[0, 0],
          reason: 'the second session recognises exactly like the first one');
      expect(notifier.uiState, isNot(DetectUiState.idle));

      await notifier.stop();
      expect(bridge.liveTaps, 0);
      notifier.dispose();
      bridge.dispose();
    });

    test('the primary button stays a stop button while the session is live', () {
      // SPEC-U-02 section 2.3: `confirmed` and `ending` are running states. Treating
      // `confirmed` as idle offered a second 「开始 AI 检测」 while the first AudioRecord was
      // still open -- a start the native side refuses (maxConcurrentSessions = 1).
      for (final state in <DetectUiState>[
        DetectUiState.listening,
        DetectUiState.unconfirmed,
        DetectUiState.confirmed,
        DetectUiState.askingUser,
        DetectUiState.ending,
      ]) {
        expect(DetectPresenter.primaryActionIsStop(state), isTrue, reason: '$state');
        expect(DetectPresenter.primaryActionLabel(state), '停止检测', reason: '$state');
      }
      expect(DetectPresenter.primaryActionIsStop(DetectUiState.idle), isFalse);
      expect(DetectPresenter.primaryActionIsStop(DetectUiState.ended), isFalse);
      expect(DetectPresenter.primaryActionLabel(DetectUiState.ended), '再次检测');
    });
  });
}

// app/test/ui/detect_session_recovery_test.dart
//
// ADR-45 -- "只能检测一次" must be RECOVERABLE, and the page must never latch.
//
// THE MECHANISM, stated once so the assertions below make sense
// ------------------------------------------------------------
// `bridge.events(sessionId:)` hands out the EventChannel's BROADCAST stream. The native side owns
// a SINGLE sink and only re-arms it when the channel reports `cancel`
// (`AudioChannelHostAndroid.onCancel` -> `AudioBridgeAndroid.clearSubscription`). So a Dart-side
// subscription left alive keeps the broadcast controller's listener count above zero, `onCancel`
// never fires, the sink is never re-armed, and every later session's events are filtered out by
// `subscribedSessionId`.
//
// The user-visible result is exactly "只能检测一次": the microphone opens on the next attempt (the
// privacy indicator comes on, because `startSession` itself succeeded) and the UI stays empty
// forever. It is TERMINAL -- each retry leaks another subscription.
//
// `stop()` was given the release guarantee when this defect was first found. **`open()` was not**,
// and `open()` is the path that runs when the FIRST attempt fails. So a single transient failure
// used to poison the rest of the app's life.
//
// `hasListener` on a broadcast controller is the mechanical proxy for "the native side will see
// `cancel`". The first test proves the probe can detect a leak at all; without it the other
// assertions would be vacuous.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/presenters/detect_presenter.dart' show DetectUiState;
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';

const int _anchorMs = 1789308169834;

class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

/// A bridge whose event stream is a broadcast controller we can watch, and whose `startSession`
/// can be told to fail with an exception that is NOT an `AcouDietError`.
class _SpyBridge extends FakeAudioBridge {
  final StreamController<Map<Object?, Object?>> bus =
      StreamController<Map<Object?, Object?>>.broadcast();

  /// When true, `startSession` throws a bare `StateError` -- which is exactly what
  /// `DetectionSession.start` does NOT convert (it has no catch), and what the notifier's
  /// `on AcouDietError` therefore missed.
  bool failStart = false;
  int startCalls = 0;

  @override
  Stream<Map<Object?, Object?>> events({required String sessionId}) => bus.stream;

  @override
  Future<Map<String, Object?>> startSession({
    required String sessionId,
    bool enableDenoise = false,
    bool autoEndOnSilence = true,
    int? silenceEndSeconds,
    bool includeEnvelope = true,
    bool skipAudioRecord = false,
  }) async {
    startCalls++;
    if (failStart) throw StateError('host exploded');
    return super.startSession(
      sessionId: sessionId,
      enableDenoise: enableDenoise,
      autoEndOnSilence: autoEndOnSilence,
      silenceEndSeconds: silenceEndSeconds,
      includeEnvelope: includeEnvelope,
      skipAudioRecord: skipAudioRecord,
    );
  }
}

Future<({AcouNotifiers notifiers, _SpyBridge bridge})> _host() async {
  final bridge = _SpyBridge();
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final services = AppServices.assemble(
    assets: const _NoAssets(),
    dietRepo: repo,
    statsRepo: repo,
    profileRepo: repo,
    maintenanceRepo: PlaceholderMaintenanceRepo(
      diet: repo,
      profile: repo,
      bridge: FakeAudioBridge(),
    ),
    bridge: bridge,
    nowMsOverride: _anchorMs,
  );
  // The C-03 gate is not advisory: `DetectNotifier.blocked` is `services.detectionBlocked`, which
  // is true until the handshake has run, and both start paths return early on it. Without this the
  // whole file would assert against a notifier that never reaches the bridge -- and would pass.
  await services.runHandshake();
  return (notifiers: AcouNotifiers(services), bridge: bridge);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('negative control: a leaked subscription IS visible through hasListener', () async {
    final (:notifiers, :bridge) = await _host();
    expect(bridge.bus.hasListener, isFalse);

    final leaked = bridge.bus.stream.listen((_) {});
    expect(bridge.bus.hasListener, isTrue,
        reason: 'if a live subscription were invisible here, every assertion below would be '
            'vacuous -- this is the probe the whole file depends on');

    await leaked.cancel();
    expect(bridge.bus.hasListener, isFalse);
    await notifiers.dispose();
  });

  test('a start that THROWS releases its subscriptions and stays retryable', () async {
    final (:notifiers, :bridge) = await _host();
    final detect = notifiers.detect;

    expect(detect.blocked, isFalse, reason: 'the fixture must have passed the handshake');

    // ---- the first attempt fails with a non-AcouDietError --------------------------------
    bridge.failStart = true;
    await detect.startRealtime();

    expect(bridge.startCalls, 1);
    expect(detect.lastError, isNotNull,
        reason: 'a failure must be REPORTED, not swallowed');
    expect(detect.uiState, isNot(DetectUiState.starting),
        reason: 'the page must not latch in a state that owns the only button -- `_busy` '
            'includes `starting`, so latching there makes every later tap a no-op');

    // THE FIX: the two subscriptions opened before `session.start()` are gone, so the native side
    // gets its `cancel` and re-arms the sink.
    expect(bridge.bus.hasListener, isFalse,
        reason: 'a subscription left alive here is what makes the NEXT session permanently deaf');

    // ---- the second attempt must actually work ------------------------------------------
    bridge.failStart = false;
    await detect.startRealtime();

    expect(bridge.startCalls, 2, reason: 'the button is live again');
    expect(detect.uiState, DetectUiState.listening);
    expect(bridge.bus.hasListener, isTrue, reason: 'the new session is bound to the stream');

    await detect.stop();
    expect(bridge.bus.hasListener, isFalse,
        reason: 'stop() releases both taps -- the guarantee that already existed');
    await notifiers.dispose();
  });

  test('answering a confirmation with no live session is reported, not silently ignored',
      () async {
    final (:notifiers, :bridge) = await _host();
    final detect = notifiers.detect;

    // No session has ever started: `_handle` is null. The previous implementation was
    // `_handle?.session.answerConfirmation(...)` followed by `_setState(listening)` -- so the tap
    // did NOTHING and told the page it was listening. Both halves of that are asserted here.
    detect.answerConfirmation(accepted: true);

    expect(detect.lastError, isNotNull,
        reason: 'a tap with no session must say so');
    expect(detect.uiState, isNot(DetectUiState.listening),
        reason: 'and must NOT claim to be listening');
    expect(bridge.startCalls, 0, reason: 'and must not have started anything');

    detect.rejectSuggestion();
    expect(detect.uiState, isNot(DetectUiState.listening));
    await notifiers.dispose();
  });
}

// app/lib/data/native/agent_bridge.dart
//
// ADR-44 -- the L2 adapter for the platform handoff (`API-07` section 3, `SPEC-G-03`).
//
// The Dart side of the channel is deliberately THIN, and deliberately mirrored on
// `method_channel_audio_bridge.dart`: a `MethodChannel`, two methods, plain booleans, and a
// `false` for every failure. It exists so that `app/lib/presentation/**` can ask "may I hand this
// URL to the OS, and did the handoff start?" without ever naming a channel, an Intent or a URL
// scheme -- which is what keeps the takeout button the single, reviewable egress point of the UI
// (`FF-26i`: a handoff, never an order; no AccessibilityService, no simulated tap).
//
// The native host is `app/android/app/src/main/kotlin/com/acoudiet/app/agent/AgentChannelHostAndroid.kt`
// and it answers `{url: String}` with `Boolean`, never throwing: "the target app is not installed"
// is an ordinary answer the UI renders as a disabled button, not a crash.
//
// 鈿狅笍 This file lives under `data/native/` (the L2 adapter directory) rather than under
// `data/net/`: it is NOT a network client. `tool/check_network_boundary.py` enforces one egress
// point and that point is `data/net/deepseek_client.dart`; this channel only asks the operating
// system to show a URL to whichever app declares it.

import 'package:flutter/services.dart';

import '../../domain/agent/agent_tools.dart';

/// The real launcher: `MethodChannel` `acoudiet/agent`.
class MethodChannelAgentLauncher implements AgentPlatformLauncher {
  MethodChannelAgentLauncher({
    MethodChannel? channel,
    List<TakeoutPlatform>? platforms,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _platforms = platforms ?? platformsFromFeatureConfig();

  /// The channel name, verbatim from the Kotlin host.
  static const String channelName = 'acoudiet/agent';

  // The two wire method names are PUBLIC because they are the protocol, not an implementation
  // detail: `agent_launcher_test.dart` asserts the exact call sequence, and a test that has to
  // re-spell `'canOpenUrl'` as a literal would stop failing the day somebody renamed the method
  // on both sides -- i.e. it would stop being a test of the protocol.
  static const String methodCanOpenUrl = 'canOpenUrl';

  /// The host's second method name.
  ///
  /// An earlier revision wrote this as two adjacent literals (`'open' 'Url'`) to stay out of
  /// `tool/check_network_boundary.py`, whose network-API list then contained the bare token
  /// `openUrl`. **That was the wrong repair, and it has been undone on both sides.** The checker
  /// classified a method name as an egress API, so it fired on this adapter -- the sanctioned
  /// takeout handoff -- while `HttpClient` (the thing that actually opens a socket) is what the
  /// gate exists to catch. The token was removed from the checker's list, and this literal is
  /// plain again: an implementation should never have to obfuscate itself to satisfy a gate.
  static const String methodOpenUrl = 'openUrl';

  /// The keyword used by the reachability probe. The port's `canOpen` receives only a platform id
  /// (`SPEC-G-03` section 3.2), so the probe asks whether a URL of that shape can be routed to
  /// any installed app -- not what the user is about to search for.
  static const String probeKeyword = 'acoudiet';

  final MethodChannel _channel;
  final List<TakeoutPlatform> _platforms;

  TakeoutPlatform? _platformById(String id) {
    for (final p in _platforms) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// One channel round trip. Never throws: a missing plugin (a desktop/test host) and a native
  /// `false` are the same answer to the caller.
  Future<bool> _invoke(String method, String url) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, <String, Object?>{'url': url});
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> canOpen(String platformId) async {
    final platform = _platformById(platformId);
    if (platform == null) return false;
    // Ask about the APP SCHEME first: the question the button needs answered is "would this open
    // the app", and an `https` probe answers yes even when only a browser is installed. Falling
    // back to the web probe keeps the answer about the handoff rather than about one route.
    if (platform.hasScheme) {
      final byScheme = await _invoke(
          methodCanOpenUrl, takeoutSchemeFor(platform, probeKeyword));
      if (byScheme) return true;
    }
    return _invoke(methodCanOpenUrl, takeoutUrlFor(platform, probeKeyword));
  }

  @override
  Future<bool> openSearch({required String platformId, required String keyword}) async {
    final platform = _platformById(platformId);
    if (platform == null) return false;
    // ADR-45 (user requirement 銆岀洿鎺ユ墦寮€鎵嬫満APP銆?: try the app scheme first so an installed
    // Meituan / Eleme / Taobao opens as an APP, not as a web page.
    //
    // The scheme is an ATTEMPT, never the answer:
    //   * the templates have not been verified on a real device (see `TakeoutPlatform`);
    //   * a device without the app installed has no handler, and Android raises
    //     `ActivityNotFoundException` -- the Kotlin host converts that to `false` rather than
    //     crashing.
    // So a failed attempt costs one extra probe and then the web URL runs. Losing the handoff
    // entirely would be the unacceptable outcome; losing a few milliseconds is not.
    if (platform.hasScheme) {
      final schemeUrl = takeoutSchemeFor(platform, keyword);
      final handled = await _invoke(methodCanOpenUrl, schemeUrl);
      if (handled && await _invoke(methodOpenUrl, schemeUrl)) return true;
    }
    return _invoke(methodOpenUrl, takeoutUrlFor(platform, keyword));
  }
}

/// The offline wiring's launcher (`bootstrap.dart`'s placeholder path, and the tests).
///
/// It answers `false` by default, and that default is the honest one: the app did not leave, so
/// the page must say 銆岃骞冲彴鍏ュ彛鎵撲笉寮€銆傘€?rather than pretending a jump happened. Every call is
/// counted so a test can assert the strong claim of `SPEC-U-07` section 7 item 5 -- that a tool
/// round on its own never reaches the launcher.
class FakeAgentLauncher implements AgentPlatformLauncher {
  FakeAgentLauncher({this.canOpenResult = false, this.openResult = false});

  /// What [canOpen] answers.
  final bool canOpenResult;

  /// What [openSearch] answers: `true` means "the handoff started".
  final bool openResult;

  int canOpenCalls = 0;
  int openSearchCalls = 0;

  /// The platform ids handed to [openSearch], in call order. The keyword is recorded separately
  /// because a test must be able to prove the user saw it before the jump.
  final List<String> openedPlatforms = <String>[];
  final List<String> openedKeywords = <String>[];

  @override
  Future<bool> canOpen(String platformId) async {
    canOpenCalls++;
    return canOpenResult;
  }

  @override
  Future<bool> openSearch({required String platformId, required String keyword}) async {
    openSearchCalls++;
    openedPlatforms.add(platformId);
    openedKeywords.add(keyword);
    return openResult;
  }
}

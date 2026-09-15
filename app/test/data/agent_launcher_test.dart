// app/test/data/agent_launcher_test.dart
//
// ADR-45 -- the handoff must open the APP, and must never lose the handoff trying to.
//
// The user's requirement was 「直接打开手机APP」: the previous implementation handed the OS an
// `https://` URL and let App Links decide, which on a phone without the platform's link
// configuration lands in a browser. Each platform now carries an app-scheme template that the
// launcher tries FIRST, with the web URL as the fallback.
//
// WHY THIS FILE IS `TestWidgetsFlutterBinding`-CLASSIFIED
// ------------------------------------------------------
// It needs the real Flutter test messenger to observe the channel, so `run_offline_tests.py`
// classifies it as a widget-binding file and reports it rather than running it under the offline
// shim; the real `flutter test` runs it. That is the intended split (`app/test/README.md`).
//
// WHAT THE ASSERTIONS ARE ACTUALLY FOR
// ------------------------------------
// The tempting bug is not "the scheme is wrong" -- it is "the scheme is tried and then nothing
// else happens", which would make every phone WITHOUT the app installed show 「该平台入口打不开。」
// instead of the web page. So the ordering test and the fallback test are a pair, and the
// no-scheme test is the control that proves the scheme branch is doing something at all.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/native/agent_bridge.dart';
import '../../lib/domain/agent/agent_tools.dart';

const TakeoutPlatform _meituan = TakeoutPlatform(
  id: 'meituan',
  label: '美团',
  urlTemplate: 'https://i.meituan.com/s/{q}',
  schemeTemplate: 'imeituan://www.meituan.com/search?keyword={q}',
  enabled: true,
  verifiedOn: '',
);

/// The control: the same platform, but declaring no app scheme.
const TakeoutPlatform _noScheme = TakeoutPlatform(
  id: 'meituan',
  label: '美团',
  urlTemplate: 'https://i.meituan.com/s/{q}',
  enabled: true,
  verifiedOn: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(MethodChannelAgentLauncher.channelName);

  const keyword = '牛肉面';
  const schemeUrl = 'imeituan://www.meituan.com/search?keyword=%E7%89%9B%E8%82%89%E9%9D%A2';
  const webUrl = 'https://i.meituan.com/s/%E7%89%9B%E8%82%89%E9%9D%A2';

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Records every channel call and answers with [canOpenScheme] / [openAlways].
  List<String> record({required bool canOpenScheme, required bool openAlways}) {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final url = (call.arguments as Map<Object?, Object?>)['url'] as String;
      calls.add('${call.method} $url');
      if (call.method == MethodChannelAgentLauncher.methodCanOpenUrl) {
        return url.startsWith('imeituan://') ? canOpenScheme : true;
      }
      return openAlways;
    });
    return calls;
  }

  test('the app scheme is tried BEFORE the web url', () async {
    final calls = record(canOpenScheme: true, openAlways: true);
    final ok = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_meituan])
        .openSearch(platformId: 'meituan', keyword: keyword);

    expect(ok, isTrue, reason: 'the handoff started');
    expect(calls, <String>[
      '${MethodChannelAgentLauncher.methodCanOpenUrl} $schemeUrl',
      '${MethodChannelAgentLauncher.methodOpenUrl} $schemeUrl',
    ]);
    expect(calls.any((c) => c.contains('https://')), isFalse,
        reason: 'once the app answers, the web url must not be touched at all');
  });

  test('when no app handles the scheme, it FALLS BACK to the web url', () async {
    final calls = record(canOpenScheme: false, openAlways: true);
    final ok = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_meituan])
        .openSearch(platformId: 'meituan', keyword: keyword);

    expect(ok, isTrue,
        reason: 'a phone without the app must still get the web handoff, not an error');
    expect(calls, <String>[
      '${MethodChannelAgentLauncher.methodCanOpenUrl} $schemeUrl',
      '${MethodChannelAgentLauncher.methodOpenUrl} $webUrl',
    ]);
  });

  test('a platform with no scheme template goes straight to the web url', () async {
    // The control for the two tests above: without a scheme there is nothing to try first, and
    // the call list must be exactly one `openUrl`. If the scheme branch were dead code, this test
    // and the fallback test would pass while the first one silently did nothing.
    final calls = record(canOpenScheme: true, openAlways: true);
    final ok = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_noScheme])
        .openSearch(platformId: 'meituan', keyword: keyword);

    expect(ok, isTrue);
    expect(calls, <String>['${MethodChannelAgentLauncher.methodOpenUrl} $webUrl']);
  });

  test('a scheme that resolves but refuses to open still falls back', () async {
    // `canOpenUrl` true + `openUrl` false is the hostile case: the OS says something handles the
    // scheme, then the launch reports failure. The handoff must continue to the web url instead
    // of reporting success it did not have.
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final url = (call.arguments as Map<Object?, Object?>)['url'] as String;
      calls.add('${call.method} $url');
      if (call.method == MethodChannelAgentLauncher.methodCanOpenUrl) return true;
      return !url.startsWith('imeituan://');
    });
    final ok = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_meituan])
        .openSearch(platformId: 'meituan', keyword: keyword);

    expect(ok, isTrue);
    expect(calls.last, '${MethodChannelAgentLauncher.methodOpenUrl} $webUrl');
  });

  test('canOpen asks about the scheme first, then the web url', () async {
    final calls = record(canOpenScheme: false, openAlways: true);
    final can = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_meituan])
        .canOpen('meituan');

    expect(can, isTrue, reason: 'the web url is still openable, so the button stays enabled');
    expect(calls, <String>[
      '${MethodChannelAgentLauncher.methodCanOpenUrl} '
          'imeituan://www.meituan.com/search?keyword=acoudiet',
      '${MethodChannelAgentLauncher.methodCanOpenUrl} '
          'https://i.meituan.com/s/acoudiet',
    ]);
  });

  test('a missing plugin is an ordinary false, never a throw', () async {
    // The desktop/test host has no `acoudiet/agent` handler at all. A `MissingPluginException`
    // escaping here would crash the page on every non-Android run.
    messenger.setMockMethodCallHandler(channel, null);
    final ok = await MethodChannelAgentLauncher(platforms: const <TakeoutPlatform>[_meituan])
        .openSearch(platformId: 'meituan', keyword: keyword);
    expect(ok, isFalse);
  });
}

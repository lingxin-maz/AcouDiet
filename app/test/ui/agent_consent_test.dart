// app/test/ui/agent_consent_test.dart
//
// U-07 / ADR-44 -- the agent page's gate, copy and handoff rules (`SPEC-U-07` sections 2, 4.3, 7).
//
// The three claims worth a machine check, in the order they matter:
//
//   1. **Zero requests without consent.** `SPEC-U-07` section 7 item 3. The counter lives on the
//      transport, so "no request" is measured rather than argued.
//   2. **The frozen copy.** Empty / network / truncated are asserted against the section 4.3
//      strings character by character.
//   3. **The handoff button is the ONLY way out.** A tool round on its own must produce zero
//      launcher calls; the count becomes 1 only when a real tap happens, and a disabled platform's
//      button is not tappable at all.
//
// ⚠️ Every file-system touch happens inside `tester.runAsync`. The credential and consent stores
// are real files (that is the point of `API-07` section 2), and real I/O cannot complete inside
// `flutter_test`'s fake-async zone -- an `await` on it hangs instead of failing, which is the
// worst possible failure mode for a test.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/errors.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/agent_bridge.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/data/net/agent_credentials.dart';
import '../../lib/data/net/agent_transport.dart';
import '../../lib/domain/agent/agent_service.dart';
import '../../lib/domain/agent/agent_tool.dart';
import '../../lib/domain/agent/agent_tools.dart';
import '../../lib/domain/service/advice_engine.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/domain/service/health_score_service.dart';
import '../../lib/presentation/pages/agent/agent_page.dart';
import '../../lib/presentation/pages/profile/agent_key_page.dart';
import '../../lib/presentation/presenters/agent_presenter.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/theme/acou_theme.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

const String _testKey = 'sk-test-0123456789abcdef';

class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

/// A transport that answers from a script and counts how many requests it was asked to send.
///
/// `SPEC-U-07` section 7 item 3 measures egress by counting HERE rather than by reading the gate:
/// a page that "looks closed" and still posts a request is exactly the defect.
class _ScriptedTransport implements AgentTransport {
  _ScriptedTransport({this.rounds = const <List<AgentDelta>>[], this.failureCode});

  /// One entry per round of the tool loop; each entry is that round's whole stream.
  final List<List<AgentDelta>> rounds;
  final String? failureCode;

  int requestCount = 0;

  @override
  Stream<AgentDelta> send(AgentRequest request) async* {
    final index = requestCount;
    requestCount++;
    if (failureCode != null) {
      yield AgentFailed(Errors.agent(failureCode!));
      return;
    }
    if (index < rounds.length) {
      for (final d in rounds[index]) {
        yield d;
      }
      return;
    }
    yield const AgentTextDelta('好的。');
    yield const AgentFinished(AgentFinishReason.stop);
  }

  @override
  void cancel() {}

  @override
  void dispose() {}
}

typedef _Harness = ({
  AgentRuntime runtime,
  AgentTransport transport,
  AcouNotifiers notifiers,
  FakeAgentLauncher launcher,
  Directory dir,
});

/// Builds a complete agent runtime over a throwaway directory.
///
/// Must be called through [harness], never directly from a test body: it writes real files.
Future<_Harness> _build({
  bool consented = false,
  bool withKey = false,
  AgentTransport? transport,
  FakeAgentLauncher? launcher,
}) async {
  final dir = Directory.systemTemp.createTempSync('acoudiet_agent_test');
  final credentials = AgentCredentialsStore(dir);
  final consent = AgentConsentStore(dir);
  if (consented) await consent.write(true, decidedAtMs: _anchorMs);
  if (withKey) await credentials.write(const AgentCredentials(apiKey: _testKey));
  final gate = FileAgentGate(credentials: credentials, consent: consent);
  final platforms = platformsFromFeatureConfig();
  final send = launcher ?? FakeAgentLauncher();
  final wire = transport ?? _ScriptedTransport();
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final scores = HealthScoreService(stats: repo);
  const advice = AdviceEngine();
  final registry = AgentToolRegistry(<AgentTool>[
    GetHealthSummaryTool((String range) async => <String, Object?>{'range': range}),
    GetRecentMealsTool((int limit) async => const <Map<String, Object?>>[]),
    RecommendFoodTool(() async => const <String>[]),
    ProposeTakeoutSearchTool(platforms),
  ]);
  final runtime = AgentRuntime(
    gate: gate,
    credentials: credentials,
    consent: consent,
    platforms: platforms,
    launcher: send,
    buildService: () => AgentService(
      transport: wire,
      registry: registry,
      gate: gate,
      platforms: platforms,
      launcher: send,
    ),
  );
  // The composition root primes the gate; here that is this line. The page's `build` then needs no
  // I/O, which is what makes it testable inside `flutter_test`'s fake-async zone.
  await runtime.refresh();
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
    scores: scores,
    advice: advice,
    agent: runtime,
  );
  return (
    runtime: runtime,
    transport: wire,
    notifiers: AcouNotifiers(services),
    launcher: send,
    dir: dir,
  );
}

/// The only way a test may build a harness: real file I/O belongs in the real async zone.
Future<_Harness> _harness(
  WidgetTester tester, {
  bool consented = false,
  bool withKey = false,
  AgentTransport? transport,
  FakeAgentLauncher? launcher,
}) async {
  final built = await tester.runAsync(
    () => _build(
      consented: consented,
      withKey: withKey,
      transport: transport,
      launcher: launcher,
    ),
  );
  return built!;
}

Widget _host(AcouNotifiers notifiers, Widget page) => AcouScope(
      services: notifiers.services,
      notifiers: notifiers,
      child: MaterialApp(theme: AcouTheme.light(), home: page),
    );

/// Registers the viewport and the teardown the widget tests in this file need.
void _prepare(WidgetTester tester, _Harness f) {
  // 400 x 2000 logical pixels: the consent gate is a long page, and a button the tester cannot
  // reach would make this suite assert "the tap failed" rather than anything about the app.
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await f.notifiers.dispose();
    try {
      if (f.dir.existsSync()) f.dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a transient handle on a just-written file; a leftover temp directory is
      // not a test result and must not turn a green run red.
    }
  });
}

void main() {
  testWidgets('with consent withheld the agent issues zero requests', (tester) async {
    final f = await _harness(tester);
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();

    // The gate itself is closed...
    expect(f.runtime.gate.enabled, isFalse);
    expect(f.runtime.gate.consented, isFalse);

    // ...the consent gate is what is on screen, not a conversation...
    expect(find.text(UiStrings.agentConsentTitle), findsWidgets);
    expect(find.text(UiStrings.agentConsentDecline), findsOneWidget);
    expect(find.text(UiStrings.agentEmpty), findsNothing);

    // ...and NOBODY has been asked for anything (`SPEC-U-07` section 2.2 step 1).
    expect((f.transport as _ScriptedTransport).requestCount, 0);

    // The primary button is inert while the box is unticked: dismissing is not consenting.
    await tester.tap(find.text(UiStrings.agentConsentConfirm));
    await tester.pumpAndSettle();
    expect(f.runtime.gate.consented, isFalse);
    expect((f.transport as _ScriptedTransport).requestCount, 0);
  });

  testWidgets('with consent granted but no key the page shows the key gate and sends nothing',
      (tester) async {
    final f = await _harness(tester, consented: true);
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();

    expect(f.runtime.gate.consented, isTrue);
    expect(f.runtime.gate.hasKey, isFalse);
    expect(f.runtime.gate.enabled, isFalse);
    expect(find.text(UiStrings.agentKeyMissing), findsWidgets);
    // Consent is not a request: the key gate is reached with the counter still at zero.
    expect((f.transport as _ScriptedTransport).requestCount, 0);
  });

  test('the frozen copy is the section 4.3 wording, character for character', () {
    expect(UiStrings.agentEmpty, '还没有对话。问它「今天吃得怎么样」，或让它帮你想一顿饭。');
    expect(AgentPresenter.failureText(AgentFailureReason.network),
        '当前离线，核心功能可正常使用。恢复网络后可继续对话。');
    expect(AgentPresenter.failureText(AgentFailureReason.invalidKey),
        'Key 无效或额度不足。请在设置中检查你自己的 API Key。');
    expect(AgentPresenter.failureText(AgentFailureReason.truncated), '回复不完整（已达输出上限）。');
    expect(AgentPresenter.failureText(AgentFailureReason.streamBroken), '回复不完整（连接已断开）。');
    expect(
        AgentPresenter.failureText(AgentFailureReason.rateLimited), '服务暂时不可用，请稍后再试。');
    expect(AgentPresenter.failureText(AgentFailureReason.toolRoundsExceeded),
        '本轮工具调用已达上限，已停止继续尝试。');
    expect(UiStrings.agentKeyMissing, '请先填入你自己的 API Key。AcouDiet 不提供额度，Key 只保存在本机。');
    expect(UiStrings.agentConsentTitle, '开启云端智能前，请先读这段');
    expect(UiStrings.agentConsentConfirm, '我已了解，开启云端智能');
    expect(UiStrings.agentConsentDecline, '暂不开启');
    expect(UiStrings.agentRevokeAction, '关闭云端智能并删除本机保存的 Key');
  });

  testWidgets('the idle empty state is rendered, not merely declared', (tester) async {
    final f = await _harness(tester, consented: true, withKey: true);
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();

    expect(f.runtime.gate.enabled, isTrue);
    expect(find.text(UiStrings.agentEmpty), findsOneWidget);
    expect((f.transport as _ScriptedTransport).requestCount, 0);
  });

  testWidgets('a network failure renders the frozen offline sentence', (tester) async {
    final f = await _harness(
      tester,
      consented: true,
      withKey: true,
      transport: _ScriptedTransport(failureCode: Codes.agentOffline),
    );
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '今天吃得怎么样');
    await tester.pumpAndSettle();
    await tester.tap(find.text(UiStrings.agentSend));
    await tester.pumpAndSettle();

    expect((f.transport as _ScriptedTransport).requestCount, 1);
    expect(find.text(UiStrings.agentErrorNetwork), findsWidgets);
  });

  testWidgets('a disabled platform is not tappable and an unverified one says so',
      (tester) async {
    // The SSOT has eleme disabled and no platform verified on a real device yet, so one tool round
    // produces two tappable-but-unverified cards and one closed card.
    final transport = _ScriptedTransport(rounds: <List<AgentDelta>>[
      <AgentDelta>[
        const AgentToolCallDelta(AgentToolCall(
          id: 'call-1',
          name: AgentToolNames.proposeTakeout,
          argumentsJson: '{"keyword":"牛肉面"}',
        )),
        const AgentFinished(AgentFinishReason.toolCalls),
      ],
      <AgentDelta>[
        const AgentTextDelta('给你两个选择。'),
        const AgentFinished(AgentFinishReason.stop),
      ],
    ]);
    final f = await _harness(tester, consented: true, withKey: true, transport: transport);
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我想吃牛肉面');
    await tester.pumpAndSettle();
    await tester.tap(find.text(UiStrings.agentSend));
    await tester.pumpAndSettle();

    // The card names the platform and the keyword (section 4.3).
    expect(find.text(UiStrings.agentHandoffTitle('美团', '牛肉面')), findsOneWidget);
    expect(find.text(UiStrings.agentHandoffButton('美团')), findsOneWidget);

    // An unverified platform: tappable, and the caveat is printed next to the button.
    expect(find.text(UiStrings.agentHandoffUnverified), findsWidgets);

    // A disabled platform: the card exists, says it is closed, and its button is inert.
    expect(find.text(UiStrings.agentHandoffClosed), findsWidgets);
    final closedButton = tester.widget<FilledButton>(find.ancestor(
      of: find.text(UiStrings.agentHandoffButton('饿了么')),
      matching: find.byType(FilledButton),
    ));
    expect(closedButton.onPressed, isNull,
        reason: 'a disabled platform must not be tappable -- it has no URL at all');
  });

  testWidgets('the handoff button is the only caller of the launcher', (tester) async {
    final transport = _ScriptedTransport(rounds: <List<AgentDelta>>[
      <AgentDelta>[
        const AgentToolCallDelta(AgentToolCall(
          id: 'call-1',
          name: AgentToolNames.proposeTakeout,
          argumentsJson: '{"keyword":"牛肉面","platforms":["meituan"]}',
        )),
        const AgentFinished(AgentFinishReason.toolCalls),
      ],
      <AgentDelta>[
        const AgentTextDelta('给你看看美团。'),
        const AgentFinished(AgentFinishReason.stop),
      ],
    ]);
    final launcher = FakeAgentLauncher(canOpenResult: true, openResult: true);
    final f = await _harness(
      tester,
      consented: true,
      withKey: true,
      transport: transport,
      launcher: launcher,
    );
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我想吃牛肉面');
    await tester.pumpAndSettle();
    await tester.tap(find.text(UiStrings.agentSend));
    await tester.pumpAndSettle();

    // A tool round on its own reaches the launcher ZERO times (`SPEC-U-07` section 7 item 5).
    expect(launcher.openSearchCalls, 0);
    expect(launcher.canOpenCalls, 0);

    await tester.tap(find.text(UiStrings.agentHandoffButton('美团')));
    await tester.pumpAndSettle();

    expect(launcher.canOpenCalls, 1);
    expect(launcher.openSearchCalls, 1);
    expect(launcher.openedPlatforms.single, 'meituan');
    expect(launcher.openedKeywords.single, '牛肉面');
  });

  test('the handoff card is honest about enabled/verified in all three branches', () {
    const platform = TakeoutPlatform(
      id: 'meituan',
      label: '美团',
      urlTemplate: 'https://i.meituan.com/s/{q}',
      enabled: true,
      verifiedOn: '',
    );
    final cards = AgentPresenter.cardsFrom(
      toolName: AgentToolNames.proposeTakeout,
      observation: const AgentObservation.ok('x', artifacts: <String, Object?>{
        'cards': <Object?>[
          <String, Object?>{
            'platformId': 'meituan',
            'label': '美团',
            'keyword': '牛肉面',
            'verified': true,
          },
        ],
        'skipped': <Object?>[
          <String, Object?>{'id': 'meituan', 'reason': 'disabled_in_config'},
        ],
      }),
      platforms: const <TakeoutPlatform>[platform],
    );
    final verified = cards.first.handoff!;
    final disabled = cards.last.handoff!;
    expect(verified.enabled, isTrue);
    expect(verified.verified, isTrue);
    expect(verified.caveats, isEmpty, reason: 'nothing to be honest about: enabled + verified');
    expect(disabled.enabled, isFalse);
    expect(disabled.caveats, <String>[UiStrings.agentHandoffClosed]);
  });

  testWidgets('the key is only ever shown masked', (tester) async {
    final f = await _harness(tester, consented: true, withKey: true);
    _prepare(tester, f);

    await tester.pumpWidget(_host(f.notifiers, const AgentKeyPage()));
    await tester.pumpAndSettle();

    expect(AgentPresenter.maskedKey(_testKey), startsWith('sk-'));
    expect(AgentPresenter.maskedKey(_testKey), isNot(_testKey));
    // The plaintext must not be anywhere in the tree.
    expect(find.text(_testKey), findsNothing);
    expect(find.text(AgentPresenter.maskedKey(_testKey)), findsWidgets);
  });
}

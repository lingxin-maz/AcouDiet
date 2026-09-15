// app/test/ui/app_shell_layout_test.dart
//
// ADR-24 regression guard for a **blank screen that shipped**.
//
// What happened: the rebuilt shell replaced `BottomNavigationBar` with a custom `AcouNavBar`
// whose selected tab is a mint rounded tile. `Scaffold` hands `bottomNavigationBar` the whole
// screen as available height, and the tile's `Column` kept the default `MainAxisSize.max`, so the
// tile expanded to the full height of the screen, squeezed the page body to zero and produced a
// white page with one tall mint bar on the left.
//
// Why 124 widget tests did not catch it: every existing test either pumped a **page** on its own
// `Scaffold` or pumped a widget in isolation. **Nothing pumped `AppShell`**, so the only place the
// bug lived was the one place nothing looked. That is the same lesson as ADR-22 ("a gate nobody
// runs is not a gate"), moved from the build pipeline into the test suite: this file is the test
// that looks at the shell.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/flavour.dart' show acouIsOffline;
import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/home/home_page.dart';
import '../../lib/presentation/pages/shell/app_shell.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/state/notifiers.dart';
import '../../lib/presentation/theme/acou_theme.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

AppServices _services() {
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  return AppServices.assemble(
    assets: const _NoAssets(),
    dietRepo: repo,
    statsRepo: repo,
    profileRepo: repo,
    maintenanceRepo: PlaceholderMaintenanceRepo(
      diet: repo,
      profile: repo,
      bridge: FakeAudioBridge(),
    ),
    nowMsOverride: _anchorMs,
  );
}

Widget _host(AcouNotifiers notifiers) => AcouScope(
      services: notifiers.services,
      notifiers: notifiers,
      child: MaterialApp(theme: AcouTheme.light(), home: const AppShell()),
    );

void main() {
  testWidgets('the bottom bar does not eat the screen', (tester) async {
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    final bar = tester.getSize(find.byType(AcouNavBar));
    expect(bar.height, lessThan(140),
        reason: 'the bar must be a bar: a `MainAxisSize.max` column inside it would take the '
            'whole screen and blank the page');

    // The glyph is the giveaway: if the tile stretches, the icon is pushed into a tall column.
    final icon = tester.getSize(find.byIcon(Icons.home));
    expect(icon.height, lessThanOrEqualTo(24),
        reason: 'the selected tile must hug its content, not stretch');

    // ...and the page body must actually have room.
    final body = tester.getSize(find.byType(HomePage));
    expect(body.height, greaterThan(300),
        reason: 'the body was squeezed to zero height when the bar stretched');

    await notifiers.dispose();
  });

  testWidgets('the shell tab set is the one this flavour ships', (tester) async {
    // ADR-44 amended FF-23 from four pages to five -- FOR THE `agent` FLAVOUR.
    //
    // `SPEC-U-07` section 7 item 1 is flavour-conditional and says so: `agent` ships five tabs
    // with 智能体 at index 2; `offline` ships four and the agent page does not exist at all
    // (FF-24 item 4 -- that flavour's whole point is that its permission set is unchanged).
    //
    // ⚠️ This case used to assert five unconditionally, which meant `flutter test` passed only
    // because the DEFAULT flavour is `agent`. The `offline` branch is selected by a COMPILE-TIME
    // constant, so nothing had ever compiled it: running
    // `flutter test --dart-define=ACOUDIET_FLAVOUR=offline` failed here, in
    // 'a tab tap still moves the selection', and in refresh_and_tab_test's agent case. A
    // compile-time branch with no test is a branch nobody has ever built.
    if (acouIsOffline) {
      expect(AppShell.tabs.length, 4);
      expect(AppShell.tabs.contains(ShellTab.agent), isFalse,
          reason: 'the offline build has no agent page and no tab that reaches one');
      expect(AcouNavBar.labels.length, 4);
      expect(AcouNavBar.labels.contains('智能体'), isFalse);
      expect(AcouNavBar.icons.length, 4);
      expect(AcouNavBar.activeIcons.length, 4);
    } else {
      expect(AppShell.tabs.length, 5);
      expect(AppShell.tabs.indexOf(ShellTab.agent), 2);
      expect(AcouNavBar.labels.length, AppShell.tabs.length);
      expect(AcouNavBar.labels[2], '智能体');
      expect(AcouNavBar.icons.length, 5);
      expect(AcouNavBar.activeIcons.length, 5);
    }
    // `ShellTab.values` is the enum, which is flavour-independent: `agent` always exists as a
    // value even when the offline build never constructs a tab for it.
    expect(ShellTab.values.length, 5);

    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    if (!acouIsOffline) {
      // `findsWidgets`, not `findsOneWidget`: an `IndexedStack` keeps every page mounted, so the
      // agent page's own header carries the same frozen title as the bar's label.
      expect(find.text('智能体'), findsWidgets, reason: 'the label must be on the bar');
    }
    await notifiers.dispose();
  });

  testWidgets('a tab tap still moves the selection', (tester) async {
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AcouNavBar>(find.byType(AcouNavBar)).currentIndex,
      0,
      reason: 'the shell opens on 首页',
    );

    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AcouNavBar>(find.byType(AcouNavBar)).currentIndex,
      // ADR-44: in the `agent` flavour 智能体 took index 2, so 记录 moved from 2 to 3. In the
      // `offline` flavour there is no agent tab, so 记录 is still the third item (index 2).
      // The assertion is flavour-conditional because the fact is.
      acouIsOffline ? 2 : 3,
      reason: '记录 position follows the flavour: index 2 without the agent tab, 3 with it',
    );

    await notifiers.dispose();
  });
}

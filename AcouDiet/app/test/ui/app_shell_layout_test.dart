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
      2,
      reason: '记录 is the third tab in FF-23 order',
    );

    await notifiers.dispose();
  });
}

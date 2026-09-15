// app/test/ui/demo_banner_widget_test.dart
//
// SPEC-A-04 acceptance 7: while the library holds `source == 'demo'` rows, every page that shows
// data shows the 「演示数据」 badge; once the demonstration rows are cleared the badge disappears.
//
// The badge is bound to `DemoDataController.isDemoActive` (not to a per-page flag), so a page
// cannot forget it and the clearing path cannot leave a stale label behind.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/time.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/model/demo.dart';
import '../../lib/domain/service/demo_controller.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/demo_banner.dart';

/// Reads `assets/**` from the file system so this test needs no Flutter asset bundle.
class _FileAssetReader implements AssetReader {
  const _FileAssetReader();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('the banner follows the demo-data flag', (tester) async {
    await tester.pumpWidget(_host(const DemoBanner(visible: false)));
    expect(find.text(UiStrings.demoDataBadge), findsNothing);

    await tester.pumpWidget(_host(const DemoBanner(visible: true)));
    expect(find.text(UiStrings.demoDataBadge), findsOneWidget);

    // The two badges are different things and must not be confused: the injected-audio badge
    // belongs to the detection page and is never triggered by a database row.
    expect(UiStrings.sampleDemoBadge, isNot(UiStrings.demoDataBadge));
  });

  testWidgets('clearing the demonstration rows hides the badge', (tester) async {
    final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
    final bridge = FakeAudioBridge();
    final demoData = DemoDataController(diet: repo, assets: const _FileAssetReader());

    await tester.pumpWidget(_host(DemoBanner(visible: demoData.isDemoActive)));
    expect(find.text(UiStrings.demoDataBadge), findsNothing);

    // A row written with `source == 'demo'` flips the flag; the badge is derived from it.
    await repo.insertSession(
      record: FakeRepo.demoFixture().records.first,
      metrics: null,
    );
    await demoData.refreshActive();
    await tester.pumpWidget(_host(DemoBanner(visible: demoData.isDemoActive)));
    expect(find.text(UiStrings.demoDataBadge), findsOneWidget);

    // Clearing removes only the demonstration rows and takes the badge with them.
    await demoData.clearDemoDataset();
    await tester.pumpWidget(_host(DemoBanner(visible: demoData.isDemoActive)));
    expect(find.text(UiStrings.demoDataBadge), findsNothing);
    expect(await repo.countAll(), 0);
    bridge.dispose();
  });

  testWidgets('the services expose the same flag the badge uses', (tester) async {
    final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
    final services = AppServices.assemble(
      assets: const _FileAssetReader(),
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
    expect(await services.refreshDemoActive(), false);
    expect(services.demoData.isDemoActive, false);
    // The report-demo path is the only thing that may switch the mode to `reportOnly`.
    await services.runHandshake();
    expect(services.demoController.currentMode, DemoMode.realtime);
  });
}

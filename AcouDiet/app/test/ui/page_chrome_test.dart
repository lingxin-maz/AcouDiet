// app/test/ui/page_chrome_test.dart
//
// ADR-24 guard: **every top-level page paints the same chrome.**
//
// The rebuild moved the app to the mockups' mint-to-cream page gradient. Four pages got it in the
// first pass and 报告 was missed -- which is exactly the kind of gap a per-page test cannot see,
// because each page was only ever checked on its own. This file walks all five and asserts the
// gradient is actually in the tree, so "forgot to wrap one page" fails here instead of on a phone.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/detect/detect_page.dart';
import '../../lib/presentation/pages/home/home_page.dart';
import '../../lib/presentation/pages/profile/profile_page.dart';
import '../../lib/presentation/pages/records/records_page.dart';
import '../../lib/presentation/pages/report/report_page.dart';
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

Widget _host(AcouNotifiers notifiers, Widget page) => AcouScope(
      services: notifiers.services,
      notifiers: notifiers,
      child: MaterialApp(theme: AcouTheme.light(), home: page),
    );

/// True when some box in the tree paints the page gradient.
bool _paintsPageGradient(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(find.byType(DecoratedBox))
    .any((b) => b.decoration is BoxDecoration &&
        (b.decoration as BoxDecoration).gradient == AcouTheme.pageGradient);

void main() {
  final pages = <String, Widget>{
    'home': const HomePage(),
    'detect': const DetectPage(),
    'records': const RecordsPage(),
    'report': const ReportPage(),
    'profile': const ProfilePage(),
  };

  for (final entry in pages.entries) {
    testWidgets('the ${entry.key} page paints the ADR-24 page gradient', (tester) async {
      final notifiers = AcouNotifiers(_services());
      await tester.pumpWidget(_host(notifiers, entry.value));
      await tester.pumpAndSettle();

      expect(_paintsPageGradient(tester), isTrue,
          reason: '${entry.key} is missing `AcouTheme.pageGradientDecoration()` -- it would be '
              'the one screen that did not move to the mockups\' background');

      await notifiers.dispose();
    });
  }
}

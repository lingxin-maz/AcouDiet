// app/test/ui/app_bar_test.dart
//
// ADR-38 guard: **every top-level page centres its title, and no page strands the reader.**
//
// The mockups all draw the same two things in the top bar, and until this file nobody checked
// either of them:
//
//   1. the page title is in the **middle** of the bar, with the brand wordmark (or a back arrow) on
//      the left and the page's own actions on the right;
//   2. the left slot shows the wordmark only when there is nowhere to go back to -- a pushed page
//      that drew a wordmark there would have no way out.
//
// `page_chrome_test.dart` deliberately only asks that a gradient is painted somewhere in the tree.
// That is what let four pages keep a left-aligned title through a whole "UI rebuild" round.

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
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/state/notifiers.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/acou_app_bar.dart';

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

/// Every top-level page, with the title string it must draw and centre.
const Map<String, (Widget, String)> _pages = {
  'records': (RecordsPage(), UiStrings.recordsTitle),
  'report': (ReportPage(), UiStrings.reportDailyTitle),
  'detect': (DetectPage(), UiStrings.detectTabTitle),
  'profile': (ProfilePage(), UiStrings.profileTitle),
};

void main() {
  for (final entry in _pages.entries) {
    testWidgets('the ${entry.key} page centres its title in the bar', (tester) async {
      final (page, title) = entry.value;
      final notifiers = AcouNotifiers(_services());
      await tester.pumpWidget(_host(notifiers, page));
      await tester.pumpAndSettle();

      expect(find.byType(AcouPageHeader), findsOneWidget,
          reason: '${entry.key} did not use the shared header');
      final titleFinder = find.text(title);
      expect(titleFinder, findsOneWidget,
          reason: '${entry.key} must draw the frozen title「$title」');

      // The measurable claim: the title's own centre sits on the bar's centre. A left-aligned
      // title -- what every page shipped before ADR-38 -- misses by tens of logical pixels.
      final barCentre = tester.getRect(find.byType(AppBar)).center.dx;
      final titleCentre = tester.getCenter(titleFinder).dx;
      expect(
        (titleCentre - barCentre).abs(),
        lessThan(1.0),
        reason: '${entry.key}: title centre $titleCentre vs bar centre $barCentre',
      );

      // And the left slot carries the wordmark, because this page is the root of the navigator.
      expect(find.byType(AcouBrandMark), findsOneWidget,
          reason: '${entry.key} is a root page, so its left slot is the wordmark');
      expect(find.byType(BackButton), findsNothing);

      await notifiers.dispose();
    });
  }

  testWidgets('a pushed page keeps its way back instead of the wordmark', (tester) async {
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(
      _host(
        notifiers,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The profile page is reached from the home app bar, so this is the real navigation shape.
    expect(find.byType(AcouPageHeader), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget,
        reason: '「我的」 is pushed from 首页; without a back arrow it is a dead end');
    expect(find.byType(AcouBrandMark), findsNothing,
        reason: 'a pushed page has a way back, so the wordmark slot is taken by the arrow');

    // And the arrow really pops.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);

    await notifiers.dispose();
  });

  testWidgets('the home header keeps the full frozen brand name', (tester) async {
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers, const HomePage()));
    await tester.pumpAndSettle();

    // Home has no page title to centre (mockup 1 has none), so it keeps the long name; the four
    // inner pages use the short one. Both marks are the same widget.
    expect(find.text(UiStrings.appTitle), findsOneWidget);
    expect(find.text(UiStrings.appBrandShort), findsNothing);

    await notifiers.dispose();
  });

  test('the short wordmark is the brand name, not a second brand', () {
    expect(UiStrings.appBrandShort, UiStrings.appName);
    expect(UiStrings.appBrandShort, isNot(UiStrings.appTitle));
  });
}

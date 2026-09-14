// app/test/ui/apple_style_test.dart
//
// ADR-39 guards for the Apple-style pass. Three claims, each of which can fail:
//
//   1. **The scroll-edge material appears.** This is the one that matters most, because its failure
//      mode is silent: `AcouScrollEdge.of` reads an `InheritedWidget`, so calling it from the wrong
//      context compiles, runs, and returns `false` forever -- a feature that is wired up, tested by
//      nothing, and never shows. The first draft of the home page did exactly that, with a `Builder`
//      missing. This test drags a real page and asserts the frosted band is in the tree afterwards
//      and absent before.
//   2. **The bottom bar is a translucent material over content**, not an opaque strip: the shell
//      runs the body under it (`extendBody`) and the bar's tint is not fully opaque.
//   3. **The type scale is Apple's Dynamic Type table**, sizes and leadings, checked against the
//      literal published values rather than against "whatever the theme says".
//
// Haptic feedback is covered too, at the channel level, because a haptic that is never sent is
// indistinguishable from one that is sent and ignored by a device.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/home/home_page.dart';
import '../../lib/presentation/pages/profile/profile_page.dart';
import '../../lib/presentation/pages/records/records_page.dart';
import '../../lib/presentation/pages/report/report_page.dart';
import '../../lib/presentation/pages/shell/app_shell.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
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
  final repo = FakeRepo.demoFixture();
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

/// How many [AcouChromeMaterial]s in the tree are currently showing their frosted band.
int _visibleMaterials(WidgetTester tester) => tester
    .widgetList<AcouChromeMaterial>(find.byType(AcouChromeMaterial))
    .where((m) => m.visible)
    .length;

/// The page's own vertical scrollable -- the one with room to move.
///
/// ⚠️ `find.byType(Scrollable).first` / `.last` are both wrong here: the records page has a
/// horizontal chip row, and a drag on that one moves nothing, so the test would report "the
/// material never appears" while never having scrolled the page. Picking by *axis and range* is the
/// difference between a test that measures the page and one that measures a chip.
ScrollableState _pageScroll(WidgetTester tester) {
  final states = tester.stateList<ScrollableState>(find.byType(Scrollable)).toList();
  for (final s in states) {
    if (s.position.axisDirection == AxisDirection.down &&
        s.position.maxScrollExtent > 100) {
      return s;
    }
  }
  throw StateError(
      'no vertical scrollable with room to scroll -- the page cannot show a scroll edge. '
      'Observed: ${states.map((s) => '${s.position.axisDirection}/max=${s.position.maxScrollExtent}').toList()}');
}

void main() {
  group('the scroll-edge material', () {
    for (final (name, page) in <(String, Widget)>[
      ('records', const RecordsPage()),
      ('report', const ReportPage()),
      ('profile', const ProfilePage()),
      ('home', const HomePage()),
    ]) {
      testWidgets('$name is plain at the top and frosted once content is under the bar',
          (tester) async {
        final notifiers = AcouNotifiers(_services());
        // ⚠️ Without this every page renders its loading branch, whose body is a single item
        // stretched to the viewport -- `maxScrollExtent == 0`, nothing to scroll, and the scroll
        // edge can never be exercised. The first draft of this test did exactly that and reported
        // "the material never appears", which is the wrong conclusion from a real measurement.
        await notifiers.prime();
        // A phone-sized surface: several of these pages do not scroll at all in a tall viewport,
        // and a page that cannot scroll cannot demonstrate a scroll edge.
        tester.view.physicalSize = const Size(1080, 1920);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_host(notifiers, page));
        await tester.pumpAndSettle();

        // The band must be *in the tree* and switched off -- distinguishing "the page never wired
        // the material" from "the material is wired but never activates".
        expect(find.byType(AcouChromeMaterial), findsWidgets,
            reason: '$name has no chrome material in its bar at all');

        // At the top of the page the bar is the page's own background -- Apple's scroll-edge
        // appearance. A material here would be a frosted band the mockups do not have.
        expect(_visibleMaterials(tester), 0,
            reason: '$name must not frost its bar before anything has scrolled under it');

        final scroll = _pageScroll(tester);
        expect(scroll.position.pixels, 0);
        scroll.position.jumpTo(300);
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0),
            reason: '$name did not actually scroll, so the scroll edge was never exercised');

        // ⭐ The claim. If `AcouScrollEdge.of` is ever read from the wrong context again, or the
        // page stops being wrapped, this is 0 and the build fails.
        expect(_visibleMaterials(tester), greaterThan(0),
            reason: '$name: content is under the bar and nothing is separating them -- a card '
                'would paint its text through the centred title');

        await notifiers.dispose();
      });
    }
  });

  group('the tab bar is a material, not a strip', () {
    testWidgets('the body runs under it and its tint is translucent', (tester) async {
      final notifiers = AcouNotifiers(_services());
      await tester.pumpWidget(_host(notifiers, const AppShell(initialTab: ShellTab.records)));
      await tester.pumpAndSettle();

      // `extendBody` is what lets content pass underneath at all; without it the blur has nothing
      // to blur and the bar is an ordinary opaque strip.
      final scaffold = tester.widget<Scaffold>(
        find.descendant(of: find.byType(AppShell), matching: find.byType(Scaffold)).first,
      );
      expect(scaffold.extendBody, isTrue,
          reason: 'the page must run under the bar, or the material has nothing to show');

      // And the tint really is translucent -- at 100 % alpha the bar is white again.
      expect(AcouTheme.chromeMaterialTint.alpha, lessThan(255));
      expect(AcouTheme.chromeMaterialTint.alpha, greaterThan(200),
          reason: 'translucent, but still opaque enough for the bar labels to be body text');

      // The bar's labels must still clear the project's contrast floor on what shows through it.
      double lum(Color c) => c.computeLuminance();
      final overMintTop = Color.alphaBlend(AcouTheme.chromeMaterialTint, AcouTheme.pageTop);
      final ratio = (lum(overMintTop) + 0.05) / (lum(AcouTheme.inkMuted) + 0.05);
      expect(ratio >= 4.5, isTrue,
          reason: 'tab bar label contrast over the scrolled page was $ratio:1');

      await notifiers.dispose();
    });
  });

  group('no page overflows at phone width', () {
    // ⚠️ Why this group exists. Every widget test in this repo ran at flutter_test's default
    // 800 x 600 surface, which is wider than any phone. The report page's 「食物类别」 row overflowed
    // by **222 px** at a 360 dp width and no test could see it -- the first measurement at phone
    // width found it immediately, and only because the widened type made the overflow worse.
    // 360 x 640 is the narrow end of what this app supports, so it is the width to test at.
    for (final (name, page) in <(String, Widget)>[
      ('records', const RecordsPage()),
      ('report', const ReportPage()),
      ('profile', const ProfilePage()),
      ('home', const HomePage()),
    ]) {
      testWidgets('$name lays out at 360 dp without an overflow', (tester) async {
        final notifiers = AcouNotifiers(_services());
        await notifiers.prime();
        tester.view.physicalSize = const Size(1080, 1920);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_host(notifiers, page));
        await tester.pumpAndSettle();

        // A `RenderFlex` overflow is reported as a Flutter error and would already fail the test;
        // asserting it explicitly keeps the failure legible and catches the same class of error
        // from any other render object.
        expect(tester.takeException(), isNull,
            reason: '$name does not fit a 360 dp phone');

        await notifiers.dispose();
      });
    }

    testWidgets('every shell tab lays out at 360 dp without an overflow', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      for (final tab in ShellTab.values) {
        final notifiers = AcouNotifiers(_services());
        await notifiers.prime();
        await tester.pumpWidget(_host(notifiers, AppShell(initialTab: tab)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'the ${tab.name} tab does not fit a 360 dp phone');
        await notifiers.dispose();
      }
    });
  });

  group('the type scale is Apple Dynamic Type', () {
    // The published iOS "Large" table: size / leading. Not "the values the theme happens to have".
    const table = <String, (double, double)>{
      'sectionTitle': (20, 25), // Title 3
      'headline': (22, 28), // Title 2
      'body': (17, 22), // Body
      'bodyMuted': (15, 20), // Subhead
      'caption': (12, 16), // Caption 1
      'metric': (17, 22), // Headline
      'chartAxisLabel': (11, 13), // Caption 2
      'onPrimaryAction': (17, 22), // Headline
    };

    test('every style lands on a published size and its exact leading', () {
      final styles = <String, TextStyle>{
        'sectionTitle': AcouTheme.sectionTitle,
        'headline': AcouTheme.headline,
        'body': AcouTheme.body,
        'bodyMuted': AcouTheme.bodyMuted,
        'caption': AcouTheme.caption,
        'metric': AcouTheme.metric,
        'chartAxisLabel': AcouTheme.chartAxisLabel,
        'onPrimaryAction': AcouTheme.onPrimaryAction,
      };

      table.forEach((name, expect2) {
        final (size, leading) = expect2;
        final style = styles[name]!;
        expect(style.fontSize, size, reason: '$name size');
        // `height` is the multiplier Flutter wants; Apple publishes points of leading.
        expect(style.height, closeTo(leading / size, 0.0001),
            reason: '$name leading: ${style.height} x $size != $leading pt');
      });
    });

    test('the body size is Apple\'s reading size, not the old 15', () {
      // A one-line statement of the change that is felt everywhere: the app used to read at 15 pt.
      expect(AcouTheme.body.fontSize, 17);
      expect(AcouTheme.bodyMuted.fontSize, 15);
    });
  });

  group('haptics are spent on meaningful events only', () {
    testWidgets('selecting a different tab ticks, and re-tapping the same one does not',
        (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}');
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final notifiers = AcouNotifiers(_services());
      await tester.pumpWidget(_host(notifiers, const AppShell(initialTab: ShellTab.home)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.selectionClick'],
          reason: 'moving to another tab is a state change the finger cannot otherwise see');

      calls.clear();
      // Re-tapping the *current* tab only refreshes it; Apple does not tick for that.
      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'a refresh is not a selection');

      await notifiers.dispose();
    });
  });
}

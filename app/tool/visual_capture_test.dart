// app/tool/visual_capture_test.dart
//
// A **development aid**, not a gate: it renders the real pages to PNG so the ADR-24 / ADR-38 visual
// work can be reviewed against `软件UI界面设计图/*.png` without a device or an emulator.
//
// Why it lives in `tool/` and not in `test/`:
//   * goldens are pixel comparisons, and a pixel comparison across engines, platforms and Flutter
//     SDK versions is a flaky gate -- exactly the "gate that lies" this repo keeps refusing;
//   * `flutter test` (and therefore CI) runs `test/` only, so this file is never part of the 143
//     assertions that must stay green.
//
// Run it explicitly, with the goldens updated, from `app`:
//
//     <toolchain>/flutter/bin/flutter.bat test tool/visual_capture_test.dart --update-goldens
//
// Output: `tool/visual_capture/*.png`, one per screen, at 384 x 832 logical pixels / 3.0 dpr
// (1152 x 2496 device pixels -- the size of the delivered mockups).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/fake_repo.dart';
import '../lib/data/native/audio_bridge.dart';
import '../lib/domain/service/demo_controller.dart' show AssetReader;
import '../lib/presentation/pages/detect/detect_page.dart';
import '../lib/presentation/pages/demo/self_check_panel.dart';
import '../lib/presentation/pages/profile/profile_page.dart';
import '../lib/presentation/pages/records/record_detail_page.dart';
import '../lib/presentation/pages/records/records_page.dart';
import '../lib/presentation/pages/report/report_page.dart';
import '../lib/presentation/pages/shell/app_shell.dart';
import '../lib/presentation/state/acou_scope.dart';
import '../lib/presentation/state/app_services.dart';
import '../lib/presentation/theme/acou_theme.dart';

/// The demo dataset's own clock (see `FakeRepo.demoFixture`), so a capture is reproducible.
final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

/// `assets/**` straight off the disk: the widget tests stub the bundle away, but a *visual* capture
/// needs the real knowledge base, otherwise every food renders its frozen placeholder name.
class _DiskAssets implements AssetReader {
  const _DiskAssets();

  static final Map<String, String> _cache = {};

  String _resolve(String path) {
    for (final root in ['.', '..']) {
      final f = File('$root/$path');
      if (f.existsSync()) return f.path;
    }
    throw StateError('asset not found from ${Directory.current.path}: $path');
  }

  @override
  Future<Uint8List> readBytes(String path) async => File(_resolve(path)).readAsBytes();

  @override
  Future<String> readString(String path) async =>
      _cache[path] ??= File(_resolve(path)).readAsStringSync();
}

AppServices _services() {
  final repo = FakeRepo.demoFixture();
  return AppServices.assemble(
    assets: const _DiskAssets(),
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

/// Registers the host's CJK font family under the name [AcouTheme] text picks up.
///
/// `flutter test` ships only a metrics placeholder font, so without this every Chinese glyph is a
/// box and the capture cannot be compared with the mockups at all.
abstract final class _CaptureFont {
  static const String family = 'AcouCapture';
}

Future<void> _loadFonts() async {
  final bytes = <ByteData>[];
  for (final file in ['C:/Windows/Fonts/Deng.ttf', 'C:/Windows/Fonts/Dengb.ttf']) {
    final f = File(file);
    if (f.existsSync()) bytes.add(ByteData.sublistView(f.readAsBytesSync()));
  }
  if (bytes.isEmpty) {
    throw StateError('no CJK font found: install DengXian or change _loadFonts');
  }
  // Registered under one explicit name; the capture theme below applies it to every style the
  // design system names. `flutter test`'s engine default cannot be overridden (`FontLoader` under
  // 'Ahem' / 'FlutterTest' was tried and does not take), so the two places that bypass the theme
  // entirely are handled separately -- see the note in the file header.
  final loader = FontLoader(_CaptureFont.family);
  for (final b in bytes) {
    loader.addFont(Future.value(b));
  }
  await loader.load();

  // `Icons.*` is the Material glyph font, and `flutter test` does not register it either: without
  // this every icon in the capture is an empty box, which reads exactly like a broken icon and
  // would make the screenshots useless for judging the layout.
  final root = Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['ACOUDIET_TOOLCHAIN'] ?? ''}/flutter';
  final iconFont = File(
    '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (iconFont.existsSync()) {
    final icons = FontLoader('MaterialIcons');
    icons.addFont(Future.value(ByteData.sublistView(iconFont.readAsBytesSync())));
    await icons.load();
  } else {
    // Loud, not silent: a capture without the icon font is a capture nobody can check.
    throw StateError('materialicons-regular.otf not found under FLUTTER_ROOT=$root');
  }
}

/// The app theme with the capture font applied.
///
/// `textTheme` alone is not enough: a `Text` styled from a theme *sub-style* -- `chipTheme`,
/// `filledButtonTheme`, `outlinedButtonTheme`, `textButtonTheme` -- is wrapped by that widget in its
/// own `DefaultTextStyle`, which **replaces** the ambient one. A style that names no family
/// therefore falls all the way through to the engine, whose default in `flutter test` is Ahem: every
/// glyph a solid black box. (On Android the same absence resolves to Roboto plus the system CJK
/// fallback, so this is a property of the harness, not of the app.) The reachable sub-styles are
/// re-stamped here so the capture shows the page instead of the boxes.
///
/// The one remaining artefact is the radar's four axis labels: those are painted by a
/// `CustomPainter`, which has no `DefaultTextStyle` at all, and they render as tofu. Their content
/// is asserted by `flutter test` instead -- pixels are for judging the layout.
ThemeData _captureTheme() {
  const family = _CaptureFont.family;
  final base = AcouTheme.light();

  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: family);
  ButtonStyle button(ButtonStyle? s) => s!.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(s.textStyle?.resolve(const <WidgetState>{})),
        ),
      );

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: f(base.chipTheme.labelStyle),
      secondaryLabelStyle: f(base.chipTheme.secondaryLabelStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button(base.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button(base.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: button(base.textButtonTheme.style)),
  );
}

Widget _host(Widget page, {ThemeData? theme, Key? key}) => MaterialApp(
      key: key,
      theme: theme ?? _captureTheme(),
      debugShowCheckedModeBanner: false,
      home: page,
    );

/// Pumps a bounded number of frames instead of `pumpAndSettle()`: the detection page animates the
/// waveform forever, and `pumpAndSettle` would block on it until the test timed out.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  Widget app, {
  Future<void> Function(WidgetTester)? after,
}) async {
  // ⚠️ Drop the previous tree first. `pumpWidget` with a widget of the *same type* updates the
  // existing element instead of rebuilding it, so four `AppShell(initialTab: …)` captures in a row
  // all reused the first `_AppShellState` and wrote four identical PNGs -- a harness that silently
  // reported "every tab looks the same" while never switching tabs at all.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(app);
  await _settle(tester);
  if (after != null) await after(tester);
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('visual_capture/$name.png'),
  );
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('capture every screen', (tester) async {
    tester.view.physicalSize = const Size(1152, 2496);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // ⚠️ The single line that makes these captures readable. Anything painted without an explicit
    // family -- a `CustomPainter`'s `TextPainter` (the radar's four axis labels) or a theme
    // sub-style such as `chipTheme.labelStyle` (the report page's date chips) -- resolves to the
    // engine default, and `flutter test`'s default is **Ahem**, which draws every glyph as a solid
    // black box. On Android that same absence resolves to Roboto plus the system CJK fallback, so
    // the boxes are an artefact of the harness and not of the app; pointing the engine's default at
    // the family loaded above removes the artefact instead of hiding it.
    tester.platformDispatcher.systemFontFamily = _CaptureFont.family;
    addTearDown(() => tester.platformDispatcher.systemFontFamily = null);

    Future<void> shot(
      String name,
      Widget Function(AcouNotifiers) build, {
      Future<void> Function(WidgetTester)? after,
    }) async {
      // Fresh notifiers per screen: `prime()` is a start-up side effect, and reusing one set would
      // let the previous screen's loaded value stand in for this one's.
      final services = _services();
      // ⚠️ The order the real bootstrap uses, and it is load-bearing for a *visual* capture: the
      // knowledge base fills `services.catalog`, and without it every record renders the honest
      // 「未知类别」 placeholder and the whole screen is unjudgeable.
      await services.loadKnowledgeBase();
      await services.runHandshake();
      final notifiers = AcouNotifiers(services);
      await notifiers.prime();
      await _capture(
        tester,
        name,
        AcouScope(
          services: notifiers.services,
          notifiers: notifiers,
          child: _host(build(notifiers)),
        ),
        after: after,
      );
      await notifiers.dispose();
    }

    // The shell, one capture per tab: this is the only way the bottom bar and a page are ever seen
    // together (ADR-24 shipped a broken bar precisely because nothing pumped the shell).
    for (final (name, tab) in const [
      ('shell_home', ShellTab.home),
      ('shell_detect', ShellTab.detect),
      ('shell_records', ShellTab.records),
      ('shell_report', ShellTab.report),
    ]) {
      await shot(name, (_) => AppShell(initialTab: tab));
    }

    // The screens the shell does not own, plus a pushed detail page and a bare top-level page.
    await shot('profile', (_) => const ProfilePage());
    await shot('record_detail', (_) => const RecordDetailPage(recordId: 'demo-000'));
    await shot('self_check', (_) => const SelfCheckPanelPage());
    await shot('records', (_) => const RecordsPage());
    await shot('report', (_) => const ReportPage());
    await shot('detect', (_) => const DetectPage());

    // ADR-39: the tab bar is a translucent *material*, and a material can only be judged with
    // something behind it. At the top of a page the bar sits over a flat gradient and looks like
    // any other white bar; scrolled, cards are passing underneath it. This is the capture that can
    // actually fail -- if the bar goes opaque again, or `extendBody` is dropped, this is the one
    // that stops showing cards through it.
    await shot(
      'shell_records_scrolled',
      (_) => const AppShell(initialTab: ShellTab.records),
      after: (tester) async {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pumpAndSettle();
      },
    );
  });
}

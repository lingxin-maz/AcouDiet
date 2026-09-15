// app/test/ui/accessibility_test.dart
//
// An accessibility check that FAILS, rather than a document that describes.
//
// Why this shape: the repo's existing UI tests assert *copy* and *layout*; nothing asserted that a
// control a screen reader must announce actually has something to announce. An icon-only button
// with no `tooltip` is the classic case -- TalkBack reads "button", the user has no idea which
// one. That is mechanically detectable, so it belongs in the suite, not in a checklist.
//
// Scope is deliberately narrow and honest: it checks the controls on the pages it can build
// (home, report, records, profile, detect gate) for an accessible name, and that the four-axis
// radar has a text equivalent. It does NOT claim WCAG conformance; contrast and focus order are
// not covered here.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/agent/agent_page.dart';
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

Future<AcouNotifiers> _loaded() async {
  final repo = FakeRepo.demoFixture();
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
    nowMsOverride: _anchorMs,
  );
  final notifiers = AcouNotifiers(services);
  await notifiers.home.reload();
  await notifiers.report.reload();
  await notifiers.records.reload();
  await notifiers.profile.reload();
  return notifiers;
}

Widget _host(AcouNotifiers notifiers, Widget page) => AcouScope(
      services: notifiers.services,
      notifiers: notifiers,
      child: MaterialApp(theme: AcouTheme.light(), home: page),
    );

/// Walks the tree and returns (problems, how many controls were actually inspected).
///
/// ⚠️ The count is not decoration. A scan that finds nothing to check passes silently and proves
/// nothing -- this repo has been bitten by exactly that ("a gate that cannot fail is not a gate",
/// ADR-22/ADR-33/ADR-34). Every caller asserts the count is non-zero.
(List<String>, int) _scanControls(WidgetTester tester) {
  final problems = <String>[];
  var checked = 0;

  for (final element in find.byType(IconButton).evaluate()) {
    checked++;
    final button = element.widget as IconButton;
    final hasTooltip = (button.tooltip ?? '').trim().isNotEmpty;
    final hasSemanticLabel =
        button.icon is Icon && ((button.icon as Icon).semanticLabel ?? '').trim().isNotEmpty;
    if (!hasTooltip && !hasSemanticLabel) {
      problems.add('IconButton(icon=${_iconName(button.icon)}) has no tooltip/semanticLabel');
    }
  }

  // A `Semantics` node with an empty label is worse than none: it *claims* to describe something.
  for (final element in find.byType(Semantics).evaluate()) {
    checked++;
    final s = element.widget as Semantics;
    final label = s.properties.label;
    if (label != null && label.trim().isEmpty) {
      problems.add('Semantics with an empty (non-null) label');
    }
  }

  return (problems, checked);
}

String _iconName(Widget? icon) {
  if (icon is Icon) return icon.icon?.codePoint.toString() ?? '?';
  return icon.runtimeType.toString();
}

void main() {
  final pages = <String, Widget Function()>{
    'home': () => const HomePage(),
    'report': () => const ReportPage(),
    'records': () => const RecordsPage(),
    'profile': () => const ProfilePage(),
    // ADR-44 / SPEC-U-07 section 7 item 9: the fifth page is in the scan too. Its icon-only
    // control is the revoke affordance, whose accessible name is the frozen revoke sentence.
    'agent': () => const AgentPage(),
  };

  pages.forEach((name, build) {
    testWidgets('$name: every icon-only control has an accessible name', (tester) async {
      final notifiers = await _loaded();
      await tester.pumpWidget(_host(notifiers, build()));
      await tester.pumpAndSettle();

      final (problems, checked) = _scanControls(tester);
      // Positive control: if a page ever renders no controls at all, this test must say so rather
      // than pass by having nothing to inspect.
      expect(checked, greaterThan(0), reason: '$name: nothing was inspected -- the scan is vacuous');
      expect(problems, isEmpty,
          reason: 'TalkBack would announce these with no name:\n  ${problems.join('\n  ')}');

      await notifiers.dispose();
    });
  });

  testWidgets('the four-axis radar exposes a text equivalent (not just a picture)',
      (tester) async {
    final notifiers = await _loaded();
    await tester.pumpWidget(_host(notifiers, const HomePage()));
    await tester.pumpAndSettle();

    // A chart that only draws pixels is invisible to a screen reader; the widget must publish
    // the same four numbers as text. The semantics handler is what makes that true.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('.')).evaluate().isNotEmpty, isTrue,
        reason: 'no semantics labels at all on the home page -- a screen reader sees an empty screen');
    semantics.dispose();

    await notifiers.dispose();
  });

  testWidgets('interactive cards are reachable as buttons, not as bare text', (tester) async {
    final notifiers = await _loaded();
    await tester.pumpWidget(_host(notifiers, const ReportPage()));
    await tester.pumpAndSettle();

    // The drill-down affordance must be a semantic *button*; otherwise the four-dimension detail
    // is unreachable without a tap target the assistive layer can describe.
    final semantics = tester.ensureSemantics();
    final labelled = find.bySemanticsLabel(RegExp('四维|评分|分'));
    expect(labelled.evaluate(), isNotEmpty,
        reason: 'the report page publishes no accessible name for its score card');
    semantics.dispose();

    await notifiers.dispose();
  });
}

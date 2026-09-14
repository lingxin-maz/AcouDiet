// app/test/ui/report_scope_test.dart
//
// ADR-23: the report page carries **two** scopes in one page -- 「每日」 and 「本周」 -- reachable
// from the same tab, switchable by swiping (or by the segmented control), and **opening on
// 「每日」**.
//
// The assertions are deliberately about what the user sees, because the whole point of the split
// is the entry state and the gesture: which scope is on screen when the page opens, and whether a
// horizontal swipe actually moves between them.
//
// It needs a Flutter binding (widgets), so `tool/run_offline_tests.py` reports it as
// "requires flutter test".

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/report/report_page.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/state/notifiers.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/score_card.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

/// A report with data: the demo fixture logs four meals a day across seven days.
Future<AcouNotifiers> _loadedNotifiers() async {
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
  await notifiers.report.reload();
  return notifiers;
}

Widget _host(AcouNotifiers notifiers) => AcouScope(
      services: notifiers.services,
      notifiers: notifiers,
      child: MaterialApp(theme: AcouTheme.light(), home: const ReportPage()),
    );

/// The day the 每日 scope opens on (the newest day with records).
String _openDayLabel(AcouNotifiers notifiers) =>
    notifiers.report.state.data!.dailyScores.first.dateLabel;

/// The 每日 scope's score card, asserted by the day it is **titled** with.
///
/// ADR-30 removed the standalone `reportDailyScoreTitle` heading, so "is the daily score on
/// screen" can no longer be asked by looking for that string. What identifies the card now is
/// that its title is the selected day's own label -- `find.widgetWithText` is used rather than
/// `find.text` because the day label ALSO appears on the picker chip above it.
Finder _openDayScoreCard(AcouNotifiers notifiers) =>
    find.widgetWithText(ScoreCard, _openDayLabel(notifiers));

/// The 本周 scope's score card. **Both** scopes render exactly one `ScoreCard`
/// (`_DailyScoreCard` vs `ReportScoreHeader`), so `find.byType(ScoreCard)` cannot tell them
/// apart -- the title can: the daily card is titled with a date, the weekly one with
/// `reportTitle`. Asserting on the wrong one is exactly how this file went stale after ADR-30.
Finder _weeklyScoreCard() => find.widgetWithText(ScoreCard, UiStrings.reportTitle);

void main() {
  testWidgets('the report opens on 每日, and 本周 content is off screen', (tester) async {
    final notifiers = await _loadedNotifiers();
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    expect(find.text(UiStrings.reportScopeDaily), findsWidgets);
    expect(find.text(UiStrings.reportScopeWeekly), findsWidgets);

    // Default scope: the app bar says 每日报告 and the daily sections are on screen.
    expect(find.text(UiStrings.reportDailyTitle), findsOneWidget);
    // ADR-30: the day's score card carries the day itself as its title (the standalone
    // `reportDailyScoreTitle` heading was removed because it repeated that date on screen).
    expect(_openDayScoreCard(notifiers), findsOneWidget);
    expect(find.text(UiStrings.reportDailyListTitle), findsOneWidget);

    // The weekly-only content must not be visible yet (the PageView keeps it off screen).
    expect(find.text(UiStrings.reportTrendTitle), findsNothing);

    await notifiers.dispose();
  });

  testWidgets('swiping moves between 本周 and 每日', (tester) async {
    final notifiers = await _loadedNotifiers();
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    // Swipe left -> 本周. A `fling` (not a plain `drag`): a PageView snaps back to the nearest
    // page when the gesture ends with no velocity and the drag is only half a viewport.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text(UiStrings.reportTitle), findsWidgets);
    expect(find.text(UiStrings.reportTrendTitle), findsOneWidget);
    // The whole page (either scope) holds exactly ONE `ScoreCard`, so its mere presence proves
    // nothing. What separates the scopes is the title: 本周 is titled `reportTitle`, 每日 is
    // titled with a date.
    expect(_weeklyScoreCard(), findsOneWidget);
    expect(_openDayScoreCard(notifiers), findsNothing);

    // Swipe right -> back to 每日.
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text(UiStrings.reportDailyTitle), findsOneWidget);
    expect(_openDayScoreCard(notifiers), findsOneWidget);
    expect(find.text(UiStrings.reportTrendTitle), findsNothing);

    await notifiers.dispose();
  });

  testWidgets('the segmented control switches without a swipe', (tester) async {
    final notifiers = await _loadedNotifiers();
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    // Tap the 「本周」 segment (the app bar title is 「每日报告」, so this is unambiguous).
    await tester.tap(find.text(UiStrings.reportScopeWeekly));
    await tester.pumpAndSettle();
    expect(find.text(UiStrings.reportTrendTitle), findsOneWidget);
    expect(_weeklyScoreCard(), findsOneWidget);
    expect(_openDayScoreCard(notifiers), findsNothing);

    await tester.tap(find.text(UiStrings.reportScopeDaily));
    await tester.pumpAndSettle();
    expect(_openDayScoreCard(notifiers), findsOneWidget);

    await notifiers.dispose();
  });

  testWidgets('the daily scope picks a day and shows that day\'s own numbers', (tester) async {
    final notifiers = await _loadedNotifiers();
    await tester.pumpWidget(_host(notifiers));
    await tester.pumpAndSettle();

    final days = notifiers.report.state.data!.dailyScores;
    expect(days.length, greaterThan(1), reason: 'the fixture spans several days');

    // The newest day is selected on open; tapping another chip must move the day cards.
    expect(find.text(UiStrings.reportDailyPickTitle), findsOneWidget);
    final target = days[1];
    await tester.tap(find.text(target.dateLabel).first);
    await tester.pumpAndSettle();

    // The selected day's summary is rendered as real numbers, not placeholders.
    expect(find.text(UiStrings.reportDailySummaryTitle), findsOneWidget);
    expect(find.text(target.countText), findsOneWidget);
    expect(find.text(target.classSummary), findsOneWidget);

    await notifiers.dispose();
  });
}

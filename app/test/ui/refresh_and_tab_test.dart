// app/test/ui/refresh_and_tab_test.dart
//
// ADR-23 regression suite for the two "user asked for fresh data" behaviours:
//
//  * **pull-to-refresh on every page** -- including the loading / empty / error branches, which
//    are NOT scrollable and therefore could not be pulled at all before `RefreshableBody`;
//  * **a tab switch refreshes before it presents** -- `reloadFresh()` drops the previous value
//    so the incoming page shows its loading state instead of the stale numbers the user did not
//    ask for, while a pull-to-refresh keeps them dimmed (`reload()`).
//
// It needs a Flutter binding (widgets), so `tool/run_offline_tests.py` reports it as
// "requires flutter test".

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/flavour.dart' show acouIsOffline;
import '../../lib/data/fake_repo.dart';
import '../../lib/data/native/audio_bridge.dart';
import '../../lib/core/feature_config.g.dart' as cfg;
import '../../lib/domain/model/diet_record.dart';
import '../../lib/domain/service/demo_controller.dart' show AssetReader;
import '../../lib/presentation/pages/home/home_page.dart';
import '../../lib/presentation/pages/profile/profile_page.dart';
import '../../lib/presentation/pages/records/records_page.dart';
import '../../lib/presentation/pages/report/report_page.dart';
import '../../lib/presentation/pages/shell/app_shell.dart';
import '../../lib/presentation/presenters/home_presenter.dart';
import '../../lib/presentation/presenters/records_presenter.dart';
import '../../lib/presentation/state/acou_scope.dart';
import '../../lib/presentation/state/app_services.dart';
import '../../lib/presentation/state/notifiers.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/state_view.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

/// Reads nothing: these widget tests never load an asset.
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

void main() {
  testWidgets('a non-scrollable state can still be pulled to refresh', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshableBody(
          onRefresh: () async => calls++,
          child: const StateView(status: ViewStatus.empty, message: '暂无数据'),
        ),
      ),
    ));

    // The empty panel is not a scrollable, yet the gesture must reach the indicator: that is
    // exactly the state in which a user wants to retry.
    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('every data page carries a pull-to-refresh affordance', (tester) async {
    final pages = <String, Widget>{
      'home': const HomePage(),
      'records': const RecordsPage(),
      'report': const ReportPage(),
      'profile': const ProfilePage(),
    };
    for (final entry in pages.entries) {
      final notifiers = AcouNotifiers(_services());
      await tester.pumpWidget(_host(notifiers, entry.value));
      await tester.pumpAndSettle();
      expect(find.byType(RefreshIndicator), findsOneWidget,
          reason: 'the ${entry.key} page must be pull-to-refresh-able');
      await notifiers.dispose();
    }
  });

  test('reloadFresh drops the old value, reload keeps it', () async {
    final services = _services();
    final home = HomeNotifier(services);
    await home.reload();
    expect(home.state.hasValue, isTrue, reason: 'the first load must produce a value');

    final reloadStates = <AsyncValue<HomeView>>[];
    home.addListener(() => reloadStates.add(home.state));
    await home.reload();
    expect(
      reloadStates.any((v) => v.isLoading && v.hasValue),
      isTrue,
      reason: 'a pull-to-refresh dims the existing content instead of flashing white',
    );

    reloadStates.clear();
    await home.reloadFresh();
    expect(
      reloadStates.any((v) => v.isLoading && !v.hasValue),
      isTrue,
      reason: 'a tab switch must show the loading state, never the previous numbers',
    );
    expect(home.state.hasValue, isTrue, reason: 'and it must end with the fresh value');
    home.dispose();
  });

  test('the home score covers the seven-day window, not just today', () async {
    // ADR-23: σ needs two samples per meal class, so a today-only window could never show
    // 饮食规律性. The fixture has meals on the three days BEFORE the anchor day and none on the
    // anchor day itself, which is exactly the case that used to render an all-`--` radar.
    final records = <DietRecord>[
      for (var d = 1; d <= 3; d++) ...[
        _record(d, 7, 0, 3),
        _record(d, 12, 0, 4),
        _record(d, 18, 30, 1),
      ],
    ];
    final repo = FakeRepo(
      records: records,
      baseDayMs: _anchorMs,
      kcalOverride: FakeRepo.defaultKcalTable,
    );
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
    final home = HomeNotifier(services);
    await home.reload();
    final view = home.state.data!;

    expect(view.recordCountToday, 0, reason: 'the anchor day itself is empty');
    expect(view.score.score, isNotNull);
    expect(view.score.score!.structure.evidence['totalCount'], records.length,
        reason: 'the score must cover the seven-day window, not today');
    expect(view.score.score!.regularity.evidence['sigmaMinutes'], isNotNull,
        reason: 'a multi-day window is what makes σ computable at all');
    home.dispose();
  });

  testWidgets('switching tabs refreshes the target page', (tester) async {
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers, const AppShell()));
    await tester.pumpAndSettle(); // start-up priming

    final seen = <AsyncValue<RecordsView>>[];
    void listener() => seen.add(notifiers.records.state);
    notifiers.records.addListener(listener);

    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();

    expect(seen, isNotEmpty, reason: 'tapping the tab must trigger a reload');
    expect(
      seen.any((v) => v.isLoading),
      isTrue,
      reason: 'the refresh must start with the loading state (no stale numbers)',
    );
    notifiers.records.removeListener(listener);
    await notifiers.dispose();
  });

  testWidgets('the agent tab refreshes nothing and opens its own gate', (tester) async {
    // ADR-44 added a fifth tab whose page owns its state (consent gate -> key gate -> in-memory
    // conversation). Switching to it must NOT touch the three data pages and must NOT issue a
    // request (`SPEC-U-07` section 2.2 step 1 / `FF-24` item 9).
    //
    // ⚠️ FLAVOUR-CONDITIONAL. In the `offline` flavour there is no agent tab at all, so the
    // honest assertion is the opposite one: the entry must be ABSENT. This case previously
    // assumed `agent` unconditionally, and it failed the first time the offline branch was ever
    // compiled (`flutter test --dart-define=ACOUDIET_FLAVOUR=offline`).
    final notifiers = AcouNotifiers(_services());
    await tester.pumpWidget(_host(notifiers, const AppShell()));
    await tester.pumpAndSettle(); // start-up priming

    final seen = <String>[];
    notifiers.home.addListener(() => seen.add('home'));
    notifiers.records.addListener(() => seen.add('records'));
    notifiers.report.addListener(() => seen.add('report'));

    if (acouIsOffline) {
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing,
          reason: 'the offline build ships no agent tab and no agent page (FF-24 item 4)');
      expect(find.byIcon(Icons.smart_toy), findsNothing);
      expect(seen, isEmpty, reason: 'nothing was tapped, so nothing reloaded');
      await notifiers.dispose();
      return;
    }

    // Tapped by ICON: the label 智能体 appears twice once the page is mounted (the bar's caption
    // and the page's own header), so a text finder would be ambiguous.
    await tester.tap(find.byIcon(Icons.smart_toy_outlined));
    await tester.pumpAndSettle();

    expect(seen, isEmpty,
        reason: 'the agent tab has no read-only data page to reload');
    await notifiers.dispose();
  });
}

/// A record at a fixed local time on the day [dayOffset] days before the anchor day.
DietRecord _record(int dayOffset, int hour, int minute, int classId) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOffset));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: 'adr23-$dayOffset-$hour-$minute',
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + 300000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    attribute: 'fixture',
    confidence: 0.82,
    durationSeconds: 300,
    source: 'real',
  );
}

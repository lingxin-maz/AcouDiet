// app/test/ui/overview_and_recent_test.dart
//
// ADR-24: the three blocks that were added after the first UI pass, each pinned by a rendering
// assertion rather than by inspection:
//
//  * 「最近识别记录」 (report page) -- the newest rows of the ordinary record window;
//  * 「本周健康数据概览」 (profile page) -- three tiles, and the degradation contract: a failed
//    query shows `--` and a window without a chewing sample shows `无样本`, **never** `正常`;
//  * the 「健康建议」 card is drawn as the mockups' **light** gradient card: the mockup's
//    white-on-mid-green text is about 2.5:1 and would break the U-06 section 8 contrast rule, so
//    the shape is copied and the ink is not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/domain/model/diet_record.dart';
import '../../lib/presentation/presenters/records_presenter.dart';
import '../../lib/presentation/presenters/report_presenter.dart';
import '../../lib/presentation/presenters/settings_presenter.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/pages/profile/profile_page.dart';
import '../../lib/presentation/pages/report/report_page.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/advice_list_item.dart';

RecordCardText _card({
  required String id,
  required String name,
  required int classId,
  required int minute,
}) {
  final ms = DateTime(2026, 9, 10, 8, minute).millisecondsSinceEpoch;
  return RecordCardText(
    record: DietRecord(
      recordId: id,
      eatenAtMs: ms,
      endedAtMs: ms + 120000,
      classLabel: 'chips',
      classId: classId,
      attribute: '脆性食品',
      confidence: 0.91,
      durationSeconds: 120,
      source: 'real',
    ),
    food: null,
    timeText: '08:${minute.toString().padLeft(2, '0')}',
    foodName: name,
    kcalBadge: '',
    estimateLine: '',
    confidenceText: '置信度 91%',
    sourceBadge: '',
    showConfirmedBadge: false,
    semanticsLabel: '',
  );
}

Widget _host(Widget child) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

SettingsView _settings({
  int? weekRecords,
  int? weekSnacks,
  double? meanChewInterval,
  bool overviewUnavailable = false,
}) =>
    SettingsView.of(
      nickname: '健康达人',
      activeDays: 7,
      versionText: 'v1.0.0',
      recordCount: 3,
      weekRecordCount: weekRecords,
      weekSnackCount: weekSnacks,
      meanChewIntervalSeconds: meanChewInterval,
      overviewUnavailable: overviewUnavailable,
    );

void main() {
  testWidgets('the recent-records strip lists every card it was given', (tester) async {
    final cards = [
      _card(id: 'r1', name: '薯片', classId: 0, minute: 30),
      _card(id: 'r2', name: '胡萝卜', classId: 4, minute: 40),
    ];
    await tester.pumpWidget(_host(RecentRecordsSection(cards: cards)));

    expect(find.text(UiStrings.reportRecentTitle), findsOneWidget);
    expect(find.text(UiStrings.reportRecentNote), findsOneWidget);
    expect(find.text('薯片'), findsOneWidget);
    expect(find.text('胡萝卜'), findsOneWidget);
    // The strip is a view of the ordinary record list, so it must never claim to be complete.
    expect(find.text('全部记录'), findsNothing);
  });

  testWidgets('the overview panel shows the three frozen values', (tester) async {
    await tester.pumpWidget(_host(WeeklyOverviewPanel(
      view: _settings(weekRecords: 28, weekSnacks: 5, meanChewInterval: 0.7),
    )));

    expect(find.text(UiStrings.overviewTitle), findsOneWidget);
    expect(find.text(UiStrings.overviewRecordsLabel), findsOneWidget);
    expect(find.text(UiStrings.overviewSpeedLabel), findsOneWidget);
    expect(find.text(UiStrings.overviewSnackLabel), findsOneWidget);
    expect(find.text('28 次'), findsOneWidget);
    expect(find.text('5 次'), findsOneWidget);
    // 0.7 s sits between the two SSOT thresholds, so the grade is the middle one.
    expect(find.text('正常'), findsOneWidget);
    expect(find.text(UiStrings.overviewNote), findsOneWidget);
  });

  testWidgets('a failed overview query degrades all three tiles to --', (tester) async {
    await tester.pumpWidget(_host(WeeklyOverviewPanel(
      view: _settings(
        weekRecords: 28,
        weekSnacks: 5,
        meanChewInterval: 0.7,
        overviewUnavailable: true,
      ),
    )));

    expect(find.text('--'), findsNWidgets(3),
        reason: 'a dead tile next to two live ones would be read as a real zero');
    expect(find.text('正常'), findsNothing);
    expect(find.text('28 次'), findsNothing);
  });

  testWidgets('a window with no chewing sample says 无样本, never 正常', (tester) async {
    await tester.pumpWidget(_host(WeeklyOverviewPanel(
      view: _settings(weekRecords: 6, weekSnacks: 1, meanChewInterval: null),
    )));

    expect(find.text(UiStrings.overviewNoSample), findsOneWidget);
    expect(find.text('正常'), findsNothing);
    expect(find.text('6 次'), findsOneWidget);
  });

  testWidgets('the advice block is a light gradient card', (tester) async {
    await tester.pumpWidget(_host(const AdviceSection(
      advices: [
        AdviceItemView(
          dimension: 'snack',
          text: '建议减少晚间零食',
          priority: 1,
          isDisclaimer: false,
        ),
      ],
      disclaimerText: '仅为参考',
    )));

    final gradientCards = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).gradient != null)
        .toList();
    expect(gradientCards, isNotEmpty,
        reason: 'the mockups draw 健康建议 as a gradient card');
    expect(
      (gradientCards.first.decoration! as BoxDecoration).gradient,
      AcouTheme.adviceGradient,
    );
    // The sentence is still ink on a light fill -- not white on mint.
    expect(find.text('建议减少晚间零食'), findsOneWidget);
    final label = tester.widget<Text>(find.text('建议减少晚间零食'));
    expect(label.style?.color, AcouTheme.ink);
  });
}

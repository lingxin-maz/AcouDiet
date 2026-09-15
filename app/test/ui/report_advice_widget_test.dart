// app/test/ui/report_advice_widget_test.dart
//
// SPEC-A-02 acceptance 10 (the authoritative test name for this file): with no suggestion other
// than the disclaimer, the advice area renders 「暂不生成建议」 exactly once, and the disclaimer
// text appears once in **both** the ready and the insufficient state -- the page must not hide its
// caveats exactly when the data is thin.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/time.dart';
import '../../lib/data/fake_repo.dart';
import '../../lib/domain/model/advice.dart';
import '../../lib/domain/service/advice_engine.dart';
import '../../lib/domain/service/health_score_service.dart';
import '../../lib/domain/service/report_service.dart';
import '../../lib/presentation/presenters/report_presenter.dart';
import '../../lib/presentation/presenters/ui_strings.dart';
import '../../lib/presentation/theme/acou_theme.dart';
import '../../lib/presentation/widgets/advice_list_item.dart';

final int _anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

DateRange _week() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: _anchorMs);
  return DateRange(start, end);
}

Widget _host(List<AdviceItemView> advices, String disclaimer) => MaterialApp(
      theme: AcouTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AdviceSection(advices: advices, disclaimerText: disclaimer),
        ),
      ),
    );

void main() {
  testWidgets('the advice empty state shows the frozen copy', (tester) async {
    const engine = AdviceEngine();
    final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
    final agg = await repo.week();
    final score = await HealthScoreService(stats: repo).score(range: _week());
    final advices = await engine.generate(score: score, agg: agg);

    // Too little data -> the disclaimer alone.
    expect(advices.length, 1);
    expect(advices.single.dimension, Advice.dimGeneral);

    final view = ReportView.of(
      score: score,
      summaryText: ReportService.insufficientDataText,
      deltas: const <String, num>{},
      advices: advices,
      trendPoints: const [],
      agg: agg,
    );

    await tester.pumpWidget(_host(view.advices, view.disclaimerText));
    expect(find.text(UiStrings.adviceEmpty), findsOneWidget);
    expect(find.text(AdviceEngine.disclaimerText), findsOneWidget);
    expect(view.advices.where((a) => !a.isDisclaimer), isEmpty);
  });

  testWidgets('a ready report keeps the disclaimer once', (tester) async {
    final repo = FakeRepo.demoFixture();
    final score = await HealthScoreService(stats: repo).score(range: _week());
    final advices = await const AdviceEngine().generate(score: score, agg: await repo.week());
    final view = ReportView.of(
      score: score,
      summaryText: '本周记录 28 次',
      deltas: const <String, num>{},
      advices: advices,
      trendPoints: const [],
      agg: await repo.week(),
    );

    await tester.pumpWidget(_host(view.advices, view.disclaimerText));
    expect(find.text(AdviceEngine.disclaimerText), findsOneWidget);
    expect(view.advices.length, advices.length - 1,
        reason: 'the general item is separated from the suggestions');
  });
}

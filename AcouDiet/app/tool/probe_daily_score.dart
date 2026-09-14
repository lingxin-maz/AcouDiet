// app/tool/probe_daily_score.dart
//
// Diagnostic (2026-09-13): "报告页「当日四维评分」的分数和评价都没有".
//
// Runs the real `ReportService.dailyScores` + the real presenter projection and prints, per day,
// WHY the daily card does (or does not) show a total and a grade. Evidence first: no guessing
// about which display gate is closed.

import '../lib/data/fake_repo.dart';
import '../lib/domain/model/diet_record.dart';
import '../lib/domain/service/health_score_service.dart';
import '../lib/domain/service/report_service.dart';
import '../lib/presentation/presenters/score_view.dart';

String _c(Object? v) => (v?.toString() ?? '-').padRight(20);

Future<void> _report(String title, FakeRepo repo) async {
  final service = ReportService(
    stats: repo,
    scores: HealthScoreService(stats: repo),
  );
  print('');
  print('=== $title ===');
  print('${_c('day')}${_c('records')}${_c('sigma')}${_c('chewN')}'
      '${_c('total')}${_c('grade')}');
  final days = await service.dailyScores(days: 7);
  for (final d in days) {
    final s = d.score;
    final view = s == null ? ScoreView.unavailable() : ScoreView.of(s);
    print('${_c(d.date)}${_c(d.recordCount)}'
        '${_c(s?.regularity.evidence['sigmaMinutes'])}'
        '${_c(s?.speed.evidence['sampleCount'])}'
        '${_c(view.totalText)}${_c(view.gradeText)}');
    print('      rows: ${view.axes.map((a) => '${a.label}=${a.scoreText}').join('  ')}');
  }
}

DietRecord _rec(String id, DateTime at, int classId) => DietRecord(
      recordId: id,
      eatenAtMs: at.millisecondsSinceEpoch,
      endedAtMs: at.millisecondsSinceEpoch + 300000,
      classLabel: const ['chips', 'cabbage', 'gummies', 'noodles', 'carrot', 'drink'][classId],
      classId: classId,
      attribute: '脆性食品',
      confidence: 0.9,
      durationSeconds: 300,
      source: 'real',
    );

Future<void> main() async {
  // 1. The demo fixture: 4 records per day (07:00 / 12:00 / 18:00 / 15:40 snack), the first three
  //    with chewing metrics. This is as good as a day ever gets.
  await _report('demoFixture (4 records/day, 3 with chew metrics)', FakeRepo.demoFixture());

  // 2. A deliberately "normal" day: three records inside ONE meal window (two lunches + one more),
  //    all with chewing metrics -- the only way a single day can produce sigma.
  final base = DateTime(2026, 9, 10, 12);
  await _report(
    'synthetic: 3 records all inside the lunch window, all with chew metrics',
    FakeRepo(
      records: [
        _rec('a', DateTime(2026, 9, 10, 12, 0), 1),
        _rec('b', DateTime(2026, 9, 10, 12, 10), 1),
        _rec('c', DateTime(2026, 9, 10, 12, 20), 1),
      ],
      metrics: const [
        BehaviorMetrics(
            chewCount: 20, avgChewIntervalSeconds: 0.7, durationSeconds: 300, speedGrade: '正常'),
        BehaviorMetrics(
            chewCount: 20, avgChewIntervalSeconds: 0.7, durationSeconds: 300, speedGrade: '正常'),
        BehaviorMetrics(
            chewCount: 20, avgChewIntervalSeconds: 0.7, durationSeconds: 300, speedGrade: '正常'),
      ],
      baseDayMs: base.millisecondsSinceEpoch,
    ),
  );
}

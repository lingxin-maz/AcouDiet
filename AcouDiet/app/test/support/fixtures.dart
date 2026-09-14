// Shared fixtures for the SPEC-mandated `flutter test` suite.
//
// These helpers build records at fixed local times on a pinned anchor day, so every test in
// `app/test/domain/**` is reproducible and independent of the wall clock (API-05 section 6.1).
//
// The same fixtures power the offline runner `tool/pure_tests.dart`, which is what actually
// executes in this environment; see `app/test/README.md` for why.

import 'dart:convert';
import 'dart:io';

import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/core/time.dart';
import 'package:acoudiet/data/fake_repo.dart';
import 'package:acoudiet/domain/model/diet_record.dart';

const int chips = 0;
const int cabbage = 1;
const int gummies = 2;
const int noodles = 3;
const int carrot = 4;
const int drink = 5;

/// 2026-09-10 12:00 local: the anchor every fixture is built around.
final int anchorMs = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;

/// A record at [hour]:[minute] on the day [dayOffset] days before the anchor.
DietRecord rec(
  int dayOffset,
  int hour,
  int minute,
  int classId, {
  String? id,
  int durationSeconds = 300,
  double confidence = 0.8,
  String source = 'real',
}) {
  final day = DateTime(2026, 9, 10).subtract(Duration(days: dayOffset));
  final at = DateTime(day.year, day.month, day.day, hour, minute);
  return DietRecord(
    recordId: id ?? 'r-$dayOffset-$hour-$minute-$classId',
    eatenAtMs: at.millisecondsSinceEpoch,
    endedAtMs: at.millisecondsSinceEpoch + durationSeconds * 1000,
    classLabel: cfg.FeatureConfig.classLabels[classId],
    classId: classId,
    attribute: 'attr-$classId',
    confidence: confidence,
    durationSeconds: durationSeconds,
    source: source,
  );
}

BehaviorMetrics met({double? interval, int duration = 300, int? chew = 40}) =>
    BehaviorMetrics(
      chewCount: chew,
      avgChewIntervalSeconds: interval,
      durationSeconds: duration,
      speedGrade: interval == null ? null : '正常',
    );

/// Builds a FakeRepo from `(record, metrics)` pairs, with the anchor clock pinned.
FakeRepo repoOf(List<(DietRecord, BehaviorMetrics?)> items) => FakeRepo(
      records: items.map((e) => e.$1).toList(),
      metrics: items.map((e) => e.$2 ?? BehaviorMetrics.placeholder).toList(),
      baseDayMs: anchorMs,
      kcalOverride: FakeRepo.defaultKcalTable,
    );

/// The 7-local-day window ending on the anchor day.
DateRange weekRange() {
  final (start, end) = TimeUtil.lastLocalDays(7, nowMsOverride: anchorMs);
  return DateRange(start, end);
}

/// The four hand-computed fixtures of SPEC-A-01 table A-01-T3.
List<(DietRecord, BehaviorMetrics?)> workedExampleA() => [
      (rec(1, 7, 0, noodles), met(interval: 0.80)),
      (rec(2, 7, 0, noodles), met(interval: 0.80)),
      (rec(1, 12, 0, carrot), met(interval: 0.80)),
      (rec(2, 12, 0, carrot), met(interval: 0.80)),
      (rec(1, 18, 30, cabbage), met(interval: 0.80)),
      (rec(2, 18, 30, cabbage), met(interval: 0.80)),
    ];

List<(DietRecord, BehaviorMetrics?)> workedExampleB() => [
      (rec(1, 7, 0, noodles), met(interval: 0.70)),
      (rec(2, 7, 0, noodles), met(interval: 0.70)),
      (rec(3, 7, 0, gummies), met(interval: 0.70)),
      (rec(4, 7, 40, gummies), met(interval: 0.70)),
      for (var d = 1; d <= 6; d++) (rec(d, 15, 40, chips), met(interval: 0.70)),
    ];

List<(DietRecord, BehaviorMetrics?)> workedExampleC() => [
      (rec(1, 7, 0, noodles), met(interval: 0.40)),
      (rec(2, 7, 0, noodles), met(interval: 0.40)),
      (rec(1, 17, 0, chips), met(interval: 0.40)),
      (rec(2, 17, 0, chips), met(interval: 0.40)),
      (rec(3, 17, 0, chips), met(interval: 0.40)),
      (rec(4, 19, 0, chips), met(interval: 0.40)),
      // "D1…D7 各 2 条": all seven snack days must sit INSIDE the window (offsets 0…6).
      // Using offsets 1…7 would push one day into the previous-day window and make
      // `deltaVsYesterday` non-null, contradicting SPEC-A-01's worked example C.
      for (var d = 1; d <= 7; d++) ...[
        (rec(d - 1, 15, 40, chips, id: 'c-a-$d'), met(interval: 0.40)),
        (rec(d - 1, 15, 45, chips, id: 'c-b-$d'), met(interval: 0.40)),
      ],
    ];

List<(DietRecord, BehaviorMetrics?)> workedExampleD() => [
      (rec(1, 7, 0, noodles), BehaviorMetrics.placeholder),
      (rec(2, 12, 0, carrot), BehaviorMetrics.placeholder),
      (rec(3, 18, 0, chips), BehaviorMetrics.placeholder),
      for (var i = 1; i <= 5; i++) (rec(i, 15, 40, chips), BehaviorMetrics.placeholder),
    ];

/// Loads a bundled asset as text straight from disk (no Flutter binding needed).
String readAssetText(String relativePath) {
  for (final candidate in ['$relativePath', '../$relativePath', '../../$relativePath']) {
    final f = File(candidate);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('asset not found: $relativePath');
}

/// Decodes the demo dataset into `(record, metrics)` pairs, rebased onto the anchor week.
List<(DietRecord, BehaviorMetrics?)> demoDataset() {
  final raw = jsonDecode(readAssetText('assets/demo_dataset.json')) as Map<String, dynamic>;
  final out = <(DietRecord, BehaviorMetrics?)>[];
  for (final entry in (raw['records'] as List)) {
    final m = (entry as Map).cast<String, Object?>();
    final metrics = (m['metrics'] as Map).cast<String, Object?>();
    final at = (m['eatenAtMs'] as num).toInt();
    final local = DateTime.fromMillisecondsSinceEpoch(at);
    // Rebase: keep the local clock time, move the day onto the anchor week so the report page
    // always has data (the asset stores a fixed calendar date).
    final anchorDay = DateTime(2026, 9, 10);
    final dayDelta = anchorDay.difference(DateTime(local.year, local.month, local.day)).inDays;
    final rebased = DateTime(anchorDay.year, anchorDay.month, anchorDay.day - dayDelta,
            local.hour, local.minute)
        .millisecondsSinceEpoch;
    final duration = (m['durationSeconds'] as num).toInt();
    out.add((
      DietRecord(
        recordId: '${m['recordId']}',
        eatenAtMs: rebased,
        endedAtMs: rebased + duration * 1000,
        classLabel: '${m['classLabel']}',
        classId: (m['classId'] as num).toInt(),
        attribute: '${m['attribute']}',
        confidence: (m['confidence'] as num).toDouble(),
        durationSeconds: duration,
        source: 'demo',
        correctedByUser: false,
        confirmedByUser: m['confirmedByUser'] == true,
      ),
      BehaviorMetrics(
        chewCount: (metrics['chewCount'] as num?)?.toInt(),
        avgChewIntervalSeconds:
            (metrics['avgChewIntervalSeconds'] as num?)?.toDouble(),
        durationSeconds: (metrics['durationSeconds'] as num?)?.toInt(),
        speedGrade: metrics['speedGrade'] as String?,
      ),
    ));
  }
  return out;
}

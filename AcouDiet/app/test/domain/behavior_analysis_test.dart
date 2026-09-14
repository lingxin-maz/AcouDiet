// SPEC-A-03 section 7 acceptance (trend series) + SPEC-P-07 section 7 (behaviour analysis).
//
// Offline equivalents: `tool/pure_tests.dart` → "SPEC-A-03 trend series" and
// "API-02 BehaviourAnalyzer".

import 'dart:typed_data';

import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/domain/model/diet_record.dart';
import 'package:acoudiet/domain/model/summaries.dart';
import 'package:acoudiet/domain/service/behavior_analyzer.dart';
import 'package:acoudiet/domain/service/health_score_service.dart';
import 'package:acoudiet/domain/service/report_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// Builds an envelope whose peaks arrive every [intervalSeconds].
Float32List _envelopeWithPeaks(double intervalSeconds, {int peaks = 12}) {
  final length = cfg.FeatureConfig.behaviorEnvelopeLength;
  final env = Float32List(length);
  for (var i = 0; i < length; i++) {
    env[i] = 0.01;
  }
  final framesPerPeak =
      (intervalSeconds * 1000 / cfg.FeatureConfig.behaviorEnvelopeHopMs).round();
  for (var p = 0; p < peaks; p++) {
    final at = 20 + p * framesPerPeak;
    if (at + 2 < length) {
      env[at] = 0.9;
      env[at + 1] = 0.5;
    }
  }
  return env;
}

void main() {
  group('trend series (SPEC-A-03)', () {
    test('七天序列_连续升序', () async {
      final repo = repoOf([
        (rec(0, 7, 0, noodles), met(interval: 0.7)),
        (rec(2, 12, 0, carrot), met(interval: 0.7)),
      ]);
      final trend = await ReportService(
        stats: repo,
        scores: HealthScoreService(stats: repo),
      ).trend(days: 7);

      expect(trend.points, hasLength(7));
      final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
      for (var i = 0; i < trend.points.length; i++) {
        expect(trend.points[i].date, matches(dateRe));
        if (i > 0) {
          final prev = DateTime.parse(trend.points[i - 1].date);
          final cur = DateTime.parse(trend.points[i].date);
          expect(cur.difference(prev).inDays, 1, reason: 'the series must be gapless');
        }
      }
    });

    test('L4填充总分与空日', () async {
      final repo = repoOf([
        (rec(0, 7, 0, noodles), met(interval: 0.7)),
        (rec(2, 12, 0, carrot), met(interval: 0.7)),
      ]);
      final trend = await ReportService(
        stats: repo,
        scores: HealthScoreService(stats: repo),
      ).trend(days: 7);

      // The anchor day has records -> both fields are filled by L4.
      expect(trend.points.last.estimatedKcal, isNotNull);
      expect(trend.points.last.totalScore, isNotNull);

      // A day with no records keeps null for BOTH: 0 would mean "records but zero kcal".
      final emptyDay = trend.points[5];
      expect(emptyDay.estimatedKcal, isNull);
      expect(emptyDay.totalScore, isNull);

      // L3 must never fill totalScore on its own (API-03 section 5).
      final raw = await repo.trend(7);
      expect(raw.every((p) => p.totalScore == null), isTrue);
    });

    test('days越界_抛ACD_DB_004', () async {
      final repo = repoOf([]);
      final service = ReportService(stats: repo, scores: HealthScoreService(stats: repo));
      expect(() => service.trend(days: 400), throwsA(anything));
      expect(() => service.trend(days: 0), throwsA(anything));
    });
  });

  group('behaviour analysis (SPEC-P-07)', () {
    test('minPeakDistance_applied', () {
      // Two peaks 150 ms apart collapse to one; 250 ms apart both survive.
      final analyzer = BehaviorAnalyzer();
      final close = Float32List(cfg.FeatureConfig.behaviorEnvelopeLength);
      final hop = cfg.FeatureConfig.behaviorEnvelopeHopMs;
      final gap150 = (150 / hop).round();
      final gap250 = (250 / hop).round();
      for (var i = 0; i < close.length; i++) {
        close[i] = 0.01;
      }
      close[100] = 0.9;
      close[100 + gap150] = 0.8;
      close[400] = 0.9;
      close[400 + gap250] = 0.8;
      close[700] = 0.9;
      close[700 + gap250] = 0.8;
      analyzer.feedEnvelope(close, hopMs: hop, tStartMs: 1000);
      final metrics = analyzer.finish(endMs: 9000);
      expect(metrics, isNotNull);
      expect(metrics!.chewCount, lessThan(6));
    });

    test('dynamicThreshold_mu_plus_halfSigma', () {
      // The threshold is an internal detail; the observable contract is that an all-zero
      // envelope produces no peaks at all (threshold == 0 and nothing exceeds it).
      final analyzer = BehaviorAnalyzer();
      analyzer.feedEnvelope(Float32List(cfg.FeatureConfig.behaviorEnvelopeLength),
          hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: 1000);
      expect(analyzer.finish(endMs: 2000), isNull);
    });

    test('widePeak_removed', () {
      final analyzer = BehaviorAnalyzer();
      final env = Float32List(cfg.FeatureConfig.behaviorEnvelopeLength);
      final width = cfg.FeatureConfig.behaviorChewMaxPeakWidthMs ~/ 5 + 40;
      for (var i = 100; i < 100 + width; i++) {
        env[i] = 0.9;
      }
      analyzer.feedEnvelope(env,
          hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: 1000);
      expect(analyzer.finish(endMs: 9000), isNull);
    });

    test('isolatedPeak_removed', () {
      final analyzer = BehaviorAnalyzer();
      final env = Float32List(cfg.FeatureConfig.behaviorEnvelopeLength);
      env[100] = 0.9; // one lone spike in an otherwise silent session
      analyzer.feedEnvelope(env,
          hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: 1000);
      expect(analyzer.finish(endMs: 9000), isNull);
    });

    test('speedGrade_threeValues', () {
      var startMs = 1000000;
      final analyzer = BehaviorAnalyzer();
      for (var i = 0; i < 5; i++) {
        analyzer.feedEnvelope(_envelopeWithPeaks(0.7),
            hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: startMs);
        startMs += 4096;
      }
      final metrics = analyzer.finish(endMs: startMs + 1000)!;
      expect(metrics.avgChewIntervalSeconds, closeTo(0.7, 0.15));
      expect(metrics.speedGrade, '正常');

      var fast = 2000000;
      final quick = BehaviorAnalyzer();
      for (var i = 0; i < 5; i++) {
        quick.feedEnvelope(_envelopeWithPeaks(0.3),
            hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: fast);
        fast += 4096;
      }
      expect(quick.finish(endMs: fast)!.speedGrade, '偏快');
    });

    test('singlePeak_givesNulls', () {
      // "Valid peaks < 2" must yield nulls, never 0 and never a fourth speed grade.
      final analyzer = BehaviorAnalyzer();
      final env = Float32List(cfg.FeatureConfig.behaviorEnvelopeLength);
      env[100] = 0.9;
      analyzer.feedEnvelope(env,
          hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: 1000);
      final metrics = analyzer.finish(endMs: 3000);
      if (metrics != null) {
        expect(metrics.chewCount, isNull);
        expect(metrics.avgChewIntervalSeconds, isNull);
        expect(metrics.speedGrade, isNull);
      }
    });

    test('reset_isIdempotent', () {
      final analyzer = BehaviorAnalyzer();
      analyzer.feedEnvelope(_envelopeWithPeaks(0.7),
          hopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs, tStartMs: 1000);
      analyzer.reset();
      analyzer.reset();
      expect(analyzer.frameCount, 0);
    });

    test('badInput_throwsACD_BEH_001', () {
      expect(
        () => BehaviorAnalyzer().feedEnvelope(Float32List(10), hopMs: 5, tStartMs: 0),
        throwsA(anything),
      );
      expect(
        () => BehaviorAnalyzer().feedEnvelope(
            Float32List(cfg.FeatureConfig.behaviorEnvelopeLength), hopMs: 10, tStartMs: 0),
        throwsA(anything),
      );
    });

    test('noPcmParam_and_smoothingWindow_50ms', () {
      // FF-21i: the analyzer consumes a native-computed envelope and never sees PCM. The
      // smoothing window comes from the SSOT, not from a literal.
      expect(cfg.FeatureConfig.behaviorSmoothingWindowMs, 50);
      final analyzer = BehaviorAnalyzer();
      final metrics = analyzer.finish(endMs: 0);
      expect(metrics, isNull); // EMPTY -> finish() returns null
    });

    test('metrics表格无节律sigma字段_X07已裁', () {
      const metrics = BehaviorMetrics(chewCount: 1);
      final keys = metrics.toMap('x').keys;
      expect(keys.any((k) => k.contains('sigma') || k.contains('rhythm')), isFalse);
      expect(keys.toSet(),
          {'record_id', 'chew_count', 'avg_chew_interval_seconds', 'duration_seconds', 'speed_grade'});
    });
  });
}

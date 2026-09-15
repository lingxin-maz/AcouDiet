import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/errors.dart';
import '../model/diet_record.dart';

/// Behaviour analysis (P-07, `API-02` section 5).
///
/// Division of labour fixed by ADR-01 / FF-21h/FF-21i: the **native** side produces the
/// short-time RMS envelope and ships it inside the `patch` event; this class does the
/// smoothing, peak detection, pseudo-peak filtering and speed grading. Dart keeps the part
/// that needs tuning on site, because retuning a Kotlin threshold means rebuilding the APK.
///
/// It must never:
///  * recompute an envelope from PCM (there is none here),
///  * use the scalar `patch.rms` instead of the envelope (a single scalar cannot resolve a
///    200 ms peak spacing, FF-21b),
///  * produce a rhythm standard deviation -- `X-07` is cut.
class BehaviorAnalyzer {
  BehaviorAnalyzer({BehaviorConfig? config})
      : cfg = config ?? BehaviorConfig.fromFeatureConfig();

  final BehaviorConfig cfg;

  /// Minimum number of peaks that constitutes a "train" rather than a lone spike; see the
  /// isolation-filter note in [finish].
  static const int minPeaksForTrain = 3;

  /// Smoothed envelope values, one per envelope frame (hop = `cfg.envelopeHopMs`).
  final List<double> _values = <double>[];

  /// Wall-clock time (epoch ms) of each stored frame.
  final List<int> _timesMs = <int>[];

  bool _sealed = false;
  int _lastTStartMs = -1;

  int get frameCount => _values.length;

  void reset() {
    _values.clear();
    _timesMs.clear();
    _sealed = false;
    _lastTStartMs = -1;
  }

  /// Feeds one patch's envelope. Throws `ACD-BEH-001` on any contract violation.
  void feedEnvelope(
    Float32List rmsEnvelope, {
    required int hopMs,
    required int tStartMs,
  }) {
    if (rmsEnvelope.length != cfg.envelopeLength) {
      throw Errors.behavior('envelopeLength', {
        'expected': cfg.envelopeLength,
        'actual': rmsEnvelope.length,
      });
    }
    if (hopMs <= 0 || hopMs != cfg.envelopeHopMs) {
      throw Errors.behavior('hopMs', {'expected': cfg.envelopeHopMs, 'actual': hopMs});
    }
    if (_sealed) {
      throw Errors.behavior('feedAfterFinish', null);
    }
    if (_lastTStartMs >= 0 && tStartMs < _lastTStartMs) {
      // Monotonicity is a contract requirement, not a nicety: peak intervals depend on it.
      throw Errors.behavior('tStartMsNotMonotonic', {
        'previous': _lastTStartMs,
        'actual': tStartMs,
      });
    }
    _lastTStartMs = tStartMs;

    for (var i = 0; i < rmsEnvelope.length; i++) {
      final v = rmsEnvelope[i];
      if (!v.isFinite) {
        throw Errors.behavior('nonFiniteEnvelope', {'index': i});
      }
      _values.add(v.toDouble());
      _timesMs.add(tStartMs + i * hopMs);
    }
  }

  /// @return `null` when there is no valid eating evidence at all.
  BehaviorMetrics? finish({required int endMs}) {
    _sealed = true;
    return snapshot(endMs: endMs);
  }

  /// The behaviour metrics as they stand at [endMs], **without sealing** the analyzer.
  ///
  /// ADR-23: the detection page shows the chew count / eating duration / eating speed while the
  /// session is still running, so the very same pipeline must be callable repeatedly. It is the
  /// identical code path `finish()` uses -- a live reading and the final one can never be two
  /// different definitions of "chewing speed".
  ///
  /// `endBeforeStart` is still enforced: a reading whose clock is behind the newest frame would
  /// silently mis-date the duration.
  BehaviorMetrics? snapshot({required int endMs}) {
    if (_values.isEmpty) return null;
    if (_lastTStartMs >= 0 && endMs < _lastTStartMs) {
      throw Errors.behavior('endBeforeStart', {'endMs': endMs, 'last': _lastTStartMs});
    }

    final smoothed = _smooth(_values, math.max(1, cfg.smoothWindowMs ~/ cfg.envelopeHopMs));
    final stats = _meanStd(smoothed);
    // FF-21c: dynamic threshold = mu + k * sigma over this session only; `k` comes from the
    // SSOT (`behavior.chew_peak_threshold_k`), never from a literal in this file.
    final threshold = stats.$1 + cfg.chewPeakThresholdK * stats.$2;

    var anyActive = false;
    for (final v in smoothed) {
      if (v > threshold) {
        anyActive = true;
        break;
      }
    }
    final firstActiveIdx = _firstIndexAbove(smoothed, threshold);

    if (!anyActive) {
      // Pure silence / no chewing-like activity: no evidence, so no metrics.
      return null;
    }

    // --- candidate peaks: local maxima above the dynamic threshold (step 3b) ---
    final candidates = <int>[];
    for (var i = 1; i < smoothed.length - 1; i++) {
      if (smoothed[i] > threshold &&
          smoothed[i] >= smoothed[i - 1] &&
          smoothed[i] > smoothed[i + 1]) {
        candidates.add(i);
      }
    }

    // --- pseudo-peak filtering (FF-21d, step 4) ---
    final maxWidthFrames = math.max(1, cfg.chewMaxPeakWidthMs ~/ cfg.envelopeHopMs);
    final gapFrames = math.max(1, cfg.isolationGapMs ~/ cfg.envelopeHopMs);

    // 4a. wide peaks are not chews.
    final widthFiltered = candidates
        .where((idx) => _peakWidthFrames(smoothed, idx, threshold) <= maxWidthFrames)
        .toList();

    // 4b. isolated peaks.
    //
    // FF-21d says "drop a peak that has no neighbour within isolation_gap_ms (300 ms)".
    // Taken literally this removes *every* peak of a normal chew train, because chewing
    // peaks are 0.5-0.8 s apart (FF-21e) -- i.e. always further apart than 300 ms. That
    // reading also makes the two acceptance criteria of SPEC-P-07 section 7 mutually
    // unsatisfiable: criterion 4 wants a lone peak dropped while criterion 5 wants a
    // 0.7 s peak train to survive and yield avgChewIntervalSeconds ~ 0.7.
    //
    // Resolution (recorded in records/reports/p07_isolation_rule.md): the isolation test is a
    // *lone-spike* guard. A set of three or more peaks is by definition a train and is never
    // treated as isolated; with one or two peaks the 300 ms neighbourhood test is applied as
    // written, so a single door-slam spike is still discarded.
    final List<int> isolatedFiltered;
    if (widthFiltered.length >= minPeaksForTrain) {
      isolatedFiltered = widthFiltered;
    } else {
      isolatedFiltered = widthFiltered
          .where((idx) =>
              widthFiltered.any((o) => o != idx && (o - idx).abs() <= gapFrames))
          .toList();
    }

    // --- minimum peak distance (FF-21b, step 5): keep the stronger of a too-close pair ---
    final minDistanceFrames =
        math.max(1, cfg.chewMinPeakDistanceMs ~/ cfg.envelopeHopMs);
    final kept = <int>[];
    for (final idx in isolatedFiltered) {
      if (kept.isEmpty) {
        kept.add(idx);
        continue;
      }
      final last = kept.last;
      if (idx - last < minDistanceFrames) {
        if (smoothed[idx] > smoothed[last]) kept[kept.length - 1] = idx;
      } else {
        kept.add(idx);
      }
    }

    final durationSeconds = firstActiveIdx >= 0
        ? math.max(0, ((endMs - _timesMs[firstActiveIdx]) / 1000).round())
        : null;

    // No peak survived -> no evidence at all (SPEC-P-07 section 2.4).
    if (kept.isEmpty) return null;

    // A single peak yields no interval, so all three interval-derived fields stay null
    // (never 0, never a fourth speed grade).
    if (kept.length < 2) {
      return BehaviorMetrics(durationSeconds: durationSeconds);
    }

    final intervals = <double>[];
    for (var i = 1; i < kept.length; i++) {
      intervals.add((_timesMs[kept[i]] - _timesMs[kept[i - 1]]) / 1000.0);
    }
    final avgInterval = intervals.reduce((a, b) => a + b) / intervals.length;

    return BehaviorMetrics(
      chewCount: kept.length,
      avgChewIntervalSeconds: avgInterval,
      durationSeconds: durationSeconds,
      speedGrade: speedGradeFor(avgInterval, config: cfg),
    );
  }

  /// FF-21e: the grade word of a mean chewing interval, against the SSOT thresholds
  /// (`behavior.speed_thresholds_seconds`) -- this file holds no numeric literal of its own.
  ///
  /// ADR-24 promoted this from a private helper to a public, **pure** function because a second
  /// caller appeared: the 「平均咀嚼速度」 tile grades the *window* aggregate (`ChewStats`,
  /// `API-03` section 5) rather than one session. Both go through this one mapping, so a session
  /// and a seven-day window can never disagree about what 「正常」 means. `config` defaults to the
  /// SSOT values (the same ones an analyzer with no injected config uses) so a caller with no
  /// analyzer instance -- or a test -- does not have to build one.
  static String speedGradeFor(double seconds, {BehaviorConfig? config}) {
    final cfg = config ?? BehaviorConfig.fromFeatureConfig();
    if (seconds < cfg.speedFastSeconds) return '偏快';
    if (seconds > cfg.speedNormalSeconds) return '偏慢';
    return '正常';
  }

  /// FF-21c's `k` is `feature_config.behavior.chew_peak_threshold_k`, carried by
  /// [BehaviorConfig] so this file holds no numeric literal of its own.
  static List<double> _smooth(List<double> v, int window) {
    if (window <= 1) return List<double>.from(v);
    final out = List<double>.filled(v.length, 0);
    var acc = 0.0;
    for (var i = 0; i < v.length; i++) {
      acc += v[i];
      if (i >= window) acc -= v[i - window];
      final n = math.min(i + 1, window);
      out[i] = acc / n;
    }
    return out;
  }

  static (double, double) _meanStd(List<double> v) {
    if (v.isEmpty) return (0, 0);
    final mean = v.reduce((a, b) => a + b) / v.length;
    var acc = 0.0;
    for (final x in v) {
      final d = x - mean;
      acc += d * d;
    }
    return (mean, math.sqrt(acc / v.length));
  }

  static int _firstIndexAbove(List<double> v, double threshold) {
    for (var i = 0; i < v.length; i++) {
      if (v[i] > threshold) return i;
    }
    return -1;
  }

  /// Contiguous run above the threshold that contains [idx], in frames.
  static int _peakWidthFrames(List<double> v, int idx, double threshold) {
    var left = idx;
    while (left > 0 && v[left - 1] > threshold) {
      left--;
    }
    var right = idx;
    while (right < v.length - 1 && v[right + 1] > threshold) {
      right++;
    }
    return right - left + 1;
  }
}

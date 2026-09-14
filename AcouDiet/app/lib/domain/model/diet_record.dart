import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;

/// A logged eating event (API-03 section 2).
///
/// Column names and field names correspond one-to-one; `snake_case` in SQLite,
/// `lowerCamelCase` in Dart (API-00 section 3.1). Nothing in this object may be a BLOB of
/// audio or a Mel tensor -- that is invariant **I-2** and the core of the privacy claim.
class DietRecord {
  const DietRecord({
    required this.recordId,
    required this.eatenAtMs,
    required this.endedAtMs,
    required this.classLabel,
    required this.classId,
    required this.attribute,
    required this.confidence,
    required this.durationSeconds,
    required this.source,
    this.correctedByUser = false,
    this.confirmedByUser = false,
  });

  /// UUID v4 (API-00 section 3.4).
  final String recordId;

  /// Eating start, epoch ms UTC; `<= endedAtMs`.
  final int eatenAtMs;

  /// Session end, epoch ms UTC (the native `SessionSummary.stoppedAtMs`).
  final int endedAtMs;

  /// One of the six frozen English class names (FF-19). The Chinese name is looked up in
  /// the knowledge base at render time, never stored here.
  final String classLabel;

  final int classId;

  /// Knowledge-base attribute **snapshotted at write time** (API-03 section 2): a later
  /// knowledge-base edit must not silently re-word history.
  final String attribute;

  /// `[0,1]` smoothed confidence; never a percentage.
  final double confidence;

  final int durationSeconds;

  /// `'real'` or `'demo'`.
  final String source;

  /// Set by the two-choice confirmation (X-02 degraded form). Stored, but the UI only ever
  /// shows "已确认" (ADR-P6) -- "已修正" is not surfaced.
  final bool correctedByUser;

  /// `true` when the user tapped "是" in the Level-3 confirmation.
  final bool confirmedByUser;

  bool get isDemo => source == 'demo';

  DietRecord copyWith({
    String? recordId,
    int? eatenAtMs,
    int? endedAtMs,
    String? classLabel,
    int? classId,
    String? attribute,
    double? confidence,
    int? durationSeconds,
    String? source,
    bool? correctedByUser,
    bool? confirmedByUser,
  }) =>
      DietRecord(
        recordId: recordId ?? this.recordId,
        eatenAtMs: eatenAtMs ?? this.eatenAtMs,
        endedAtMs: endedAtMs ?? this.endedAtMs,
        classLabel: classLabel ?? this.classLabel,
        classId: classId ?? this.classId,
        attribute: attribute ?? this.attribute,
        confidence: confidence ?? this.confidence,
        durationSeconds: durationSeconds ?? this.durationSeconds,
        source: source ?? this.source,
        correctedByUser: correctedByUser ?? this.correctedByUser,
        confirmedByUser: confirmedByUser ?? this.confirmedByUser,
      );

  Map<String, Object?> toMap() => {
        'record_id': recordId,
        'eaten_at_ms': eatenAtMs,
        'ended_at_ms': endedAtMs,
        'class_label': classLabel,
        'class_id': classId,
        'attribute': attribute,
        'confidence': confidence,
        'duration_seconds': durationSeconds,
        'source': source,
        'corrected_by_user': correctedByUser ? 1 : 0,
        'confirmed_by_user': confirmedByUser ? 1 : 0,
      };

  factory DietRecord.fromMap(Map<String, Object?> m) => DietRecord(
        recordId: m['record_id']! as String,
        eatenAtMs: (m['eaten_at_ms']! as num).toInt(),
        endedAtMs: (m['ended_at_ms']! as num).toInt(),
        classLabel: m['class_label']! as String,
        classId: (m['class_id']! as num).toInt(),
        attribute: m['attribute']! as String,
        confidence: (m['confidence']! as num).toDouble(),
        durationSeconds: (m['duration_seconds']! as num).toInt(),
        source: m['source']! as String,
        correctedByUser: ((m['corrected_by_user'] as num?)?.toInt() ?? 0) == 1,
        confirmedByUser: ((m['confirmed_by_user'] as num?)?.toInt() ?? 0) == 1,
      );

  /// Structural validation shared by the demo-dataset loader and the row mapper
  /// (API-04 section 6 "record self-consistency").
  List<String> validate() {
    final problems = <String>[];
    if (eatenAtMs > endedAtMs) problems.add('eatenAtMs > endedAtMs');
    if (confidence < 0.0 || confidence > 1.0) problems.add('confidence out of [0,1]');
    if (classId < 0 || classId >= cfg.FeatureConfig.numClasses) {
      problems.add('classId out of range: $classId');
    }
    if (classId >= 0 &&
        classId < cfg.FeatureConfig.classLabels.length &&
        cfg.FeatureConfig.classLabels[classId] != classLabel) {
      problems.add('classLabel "$classLabel" does not match classId $classId');
    }
    if (durationSeconds < 0) problems.add('durationSeconds < 0');
    if (source != 'real' && source != 'demo') problems.add('source must be real|demo');
    return problems;
  }
}

/// Behaviour metrics for one record; **strictly 1:1** with `diet_record` (invariant I-1).
///
/// A missing metric is represented by a row whose fields are all `NULL` -- the row must
/// exist, because "no row" and "row with no data" mean different things to the report page's
/// denominators.
class BehaviorMetrics {
  const BehaviorMetrics({
    this.chewCount,
    this.avgChewIntervalSeconds,
    this.durationSeconds,
    this.speedGrade,
  });

  /// Placeholder row: the record exists but no behaviour evidence was available.
  static const BehaviorMetrics placeholder = BehaviorMetrics();

  final int? chewCount;
  final double? avgChewIntervalSeconds;
  final int? durationSeconds;

  /// `'偏快'` / `'正常'` / `'偏慢'` (FF-21e). Never a rhythm standard deviation (X-07 cut).
  final String? speedGrade;

  bool get isPlaceholder =>
      chewCount == null &&
      avgChewIntervalSeconds == null &&
      durationSeconds == null &&
      speedGrade == null;

  Map<String, Object?> toMap(String recordId) => {
        'record_id': recordId,
        'chew_count': chewCount,
        'avg_chew_interval_seconds': avgChewIntervalSeconds,
        'duration_seconds': durationSeconds,
        'speed_grade': speedGrade,
      };

  factory BehaviorMetrics.fromMap(Map<String, Object?> m) => BehaviorMetrics(
        chewCount: (m['chew_count'] as num?)?.toInt(),
        avgChewIntervalSeconds:
            (m['avg_chew_interval_seconds'] as num?)?.toDouble(),
        durationSeconds: (m['duration_seconds'] as num?)?.toInt(),
        speedGrade: m['speed_grade'] as String?,
      );
}

/// Behaviour thresholds, all injected from the SSOT (never hard-coded).
///
/// `smoothWindowMs` and `isolationGapMs` were added because the peak-detection steps need
/// them and hard-coding them is exactly what `SPEC-C-03` exists to prevent.
class BehaviorConfig {
  const BehaviorConfig({
    required this.mealEndSilenceSeconds,
    required this.chewMinPeakDistanceMs,
    required this.chewMaxPeakWidthMs,
    required this.chewPeakThresholdK,
    required this.isolationGapMs,
    required this.smoothWindowMs,
    required this.envelopeHopMs,
    required this.envelopeLength,
    required this.speedFastSeconds,
    required this.speedNormalSeconds,
  });

  final int mealEndSilenceSeconds;
  final int chewMinPeakDistanceMs;
  final int chewMaxPeakWidthMs;

  /// FF-21c's `k` in `threshold = mu + k * sigma`.
  final double chewPeakThresholdK;
  final int isolationGapMs;
  final int smoothWindowMs;
  final int envelopeHopMs;
  final int envelopeLength;
  final double speedFastSeconds;
  final double speedNormalSeconds;

  /// Built from the generated constants (the SSOT projection).
  factory BehaviorConfig.fromFeatureConfig() => BehaviorConfig(
        mealEndSilenceSeconds: cfg.FeatureConfig.behaviorMealEndSilenceSeconds,
        chewMinPeakDistanceMs: cfg.FeatureConfig.behaviorChewMinPeakDistanceMs,
        chewMaxPeakWidthMs: cfg.FeatureConfig.behaviorChewMaxPeakWidthMs,
        chewPeakThresholdK: cfg.FeatureConfig.behaviorChewPeakThresholdK,
        isolationGapMs: cfg.FeatureConfig.behaviorChewIsolatedGapMs,
        smoothWindowMs: cfg.FeatureConfig.behaviorSmoothingWindowMs,
        envelopeHopMs: cfg.FeatureConfig.behaviorEnvelopeHopMs,
        envelopeLength: cfg.FeatureConfig.behaviorEnvelopeLength,
        speedFastSeconds: cfg.FeatureConfig.behaviorSpeedThresholdsSecondsFast,
        speedNormalSeconds: cfg.FeatureConfig.behaviorSpeedThresholdsSecondsNormal,
      );
}

/// Local profile (D-04). Degraded delivery: no login, no account, never uploaded.
class UserProfile {
  const UserProfile({
    this.nickname,
    this.targetMealsPerDay = defaultTargetMealsPerDay,
    this.reminderEnabled = false,
    this.privacyBannerEnabled = true,
  });

  static const int defaultTargetMealsPerDay = 3;
  static const int nicknameMaxLength = 20;

  final String? nickname;
  final int targetMealsPerDay;
  final bool reminderEnabled;
  final bool privacyBannerEnabled;

  static const UserProfile defaults = UserProfile();

  UserProfile copyWith({
    String? nickname,
    bool clearNickname = false,
    int? targetMealsPerDay,
    bool? reminderEnabled,
    bool? privacyBannerEnabled,
  }) =>
      UserProfile(
        nickname: clearNickname ? null : (nickname ?? this.nickname),
        targetMealsPerDay: targetMealsPerDay ?? this.targetMealsPerDay,
        reminderEnabled: reminderEnabled ?? this.reminderEnabled,
        privacyBannerEnabled: privacyBannerEnabled ?? this.privacyBannerEnabled,
      );

  /// `[1,6]` per API-03 section 6; anything else is `ACD-DB-004`.
  void assertValid() {
    if (targetMealsPerDay < 1 || targetMealsPerDay > 6) {
      throw Errors.dbInvalid('targetMealsPerDay out of [1,6]');
    }
    final n = nickname;
    if (n != null && n.length > nicknameMaxLength) {
      throw Errors.dbInvalid('nickname longer than $nicknameMaxLength');
    }
  }

  Map<String, Object?> toMap() => {
        'id': 1,
        'nickname': nickname,
        'target_meals_per_day': targetMealsPerDay,
        'reminder_enabled': reminderEnabled ? 1 : 0,
        'privacy_banner_enabled': privacyBannerEnabled ? 1 : 0,
      };

  factory UserProfile.fromMap(Map<String, Object?> m) => UserProfile(
        nickname: m['nickname'] as String?,
        targetMealsPerDay:
            (m['target_meals_per_day'] as num?)?.toInt() ?? defaultTargetMealsPerDay,
        reminderEnabled: ((m['reminder_enabled'] as num?)?.toInt() ?? 0) == 1,
        privacyBannerEnabled: ((m['privacy_banner_enabled'] as num?)?.toInt() ?? 1) == 1,
      );
}

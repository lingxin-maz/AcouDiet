// GENERATED FROM shared/feature_config.json -- DO NOT EDIT
// Regenerate with:  dart run tool/gen_feature_config.dart

/// AcouDiet frozen feature constants (camelCase projection of the SSOT).
///
/// Business code MUST read these constants; hand-written string keys are
/// forbidden (API-00 section 3.1 / SPEC-C-03 section 7 #1).
///
/// Nested SSOT blocks are flattened with their parent name as a prefix
/// (e.g. `behavior.meal_end_silence_seconds` -> `behaviorMealEndSilenceSeconds`)
/// so that no generated type name can collide with a domain-layer class.
class FeatureConfig {
  FeatureConfig._();

  /// MelFrontend numerical-behaviour version (handshake field 1).
  static const String melVersion = '1.1.0';

  static const String project = 'AcouDiet';
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitDepth = 16;
  static const double preemphasis = 0.97;
  static const String preemphasisBoundary = 'continuous_stream_previous_raw_sample_or_zero_at_source_start';
  static const String window = 'hann';
  static const int nFft = 1024;
  static const int winLength = 1024;
  static const int hopLength = 512;
  static const String padMode = 'constant';
  static const int nMels = 128;
  static const bool melHtk = false;
  static const String melNorm = 'slaney';
  static const int fmin = 20;
  static const int fmax = 8000;
  static const double power = 2.0;
  static const String compression = 'power_to_db';
  static const String powerToDbRef = 'patch_max';
  static const double powerToDbAmin = 1e-10;
  static const double topDb = 80.0;
  static const String normalization = 'per_patch_minmax';
  static const double normalizationEpsilon = 1e-8;
  static const double normalizationOutputMin = 0.0;
  static const double normalizationOutputMax = 1.0;
  static const String loudnessNormalization = 'training_only';
  static const double targetLufs = -23.0;
  static const int patchSamples = 65536;
  static const double patchSeconds = 4.096;
  static const bool center = true;
  static const int rawMelFrames = 129;
  static const int nFrames = 128;
  static const double inferenceHopSeconds = 0.5;
  static const int numClasses = 6;
  static const List<String> classLabels = const <String>['chips', 'cabbage', 'gummies', 'noodles', 'carrot', 'drink'];
  static const List<int> inputShape = const <int>[1, 128, 128, 1];

  // ---- frame_selection ----
  static const String frameSelectionStrategy = 'drop_tail';
  static const int frameSelectionStartInclusive = 0;
  static const int frameSelectionEndExclusive = 128;

  // ---- model_internal_preprocessing ----
  static const double modelInternalPreprocessingRescalingScale = 2.0;
  static const double modelInternalPreprocessingRescalingOffset = -1.0;
  static const String modelInternalPreprocessingChannelAdapter = 'concatenate_input_three_times';

  // ---- behavior ----
  static const int behaviorMealEndSilenceSeconds = 90;
  static const int behaviorChewMinPeakDistanceMs = 200;
  static const int behaviorChewMaxPeakWidthMs = 150;
  static const int behaviorChewIsolatedGapMs = 300;
  static const double behaviorChewPeakThresholdK = 0.5;
  static const int behaviorSmoothingWindowMs = 50;
  static const int behaviorEnvelopeFrameMs = 10;
  static const int behaviorEnvelopeHopMs = 5;
  static const int behaviorEnvelopeLength = 819;
  static const double behaviorNoiseFloorInit = 0.001;
  static const double behaviorNoiseFloorMin = 0.0003;
  static const double behaviorVoicedMarginDb = 6.0;
  static const double behaviorNoiseFloorAlpha = 0.95;
  static const double behaviorChewCountMaeDegradeRatio = 0.25;
  static const double behaviorSpeedThresholdsSecondsFast = 0.5;
  static const double behaviorSpeedThresholdsSecondsNormal = 0.8;

  // ---- voting ----
  static const int votingEmaWindow = 5;
  static const double votingEmaAlpha = 0.4;
  static const int votingConfirmConsecutivePatches = 4;
  static const double votingTauConfirm = 0.7;
  static const double votingTauLow = 0.45;
  static const int votingConfirmationMuteSeconds = 180;

  // ---- meal_windows ----
  static const String mealWindowsUnits = 'minutes_of_local_day; half-open [start, end); late_night wraps past midnight';
  static const List<int> mealWindowsBreakfast = const <int>[300, 600];
  static const List<int> mealWindowsLunch = const <int>[660, 840];
  static const List<int> mealWindowsDinner = const <int>[1020, 1260];
  static const List<int> mealWindowsLateNight = const <int>[1200, 300];
  static const bool mealWindowsSnackIsComplementOfMeals = true;

  // ---- health_score_weights ----
  static const int healthScoreWeightsRegularity = 30;
  static const int healthScoreWeightsStructure = 30;
  static const int healthScoreWeightsSnack = 20;
  static const int healthScoreWeightsSpeed = 20;

  // ---- health_score_formula ----
  static const int healthScoreFormulaRegularitySigmaAtZeroScoreMinutes = 90;
  static const double healthScoreFormulaStructureHealthyRatioAtFullScore = 0.4;
  static const List<String> healthScoreFormulaStructureHealthyLabels = const <String>['cabbage', 'carrot', 'noodles'];
  static const int healthScoreFormulaSnackCountAtZeroScore = 10;
  static const double healthScoreFormulaSpeedSecondsAtFullScore = 0.8;
  static const double healthScoreFormulaSpeedSecondsAtZeroScore = 0.4;
  static const String healthScoreFormulaEvaluationOrder = 'literal_expression';
  static const String healthScoreFormulaRounding = 'per_dimension_round_then_sum';
  static const int healthScoreFormulaGradeThresholdsGoodMin = 80;
  static const int healthScoreFormulaGradeThresholdsFairMin = 60;

  // ---- agent ----
  static const String agentComment = 'ADR-44 (2026-09-16) cloud agent. This block is the ONLY place the model identifier may appear (FF-26h): no Dart/Kotlin source may contain it as a literal, because the upstream vendor renamed and retired two earlier model names within one year and a hardcoded name rots silently. NOTE: the `model` value below is deliberately written exactly ONCE in this file -- including not repeated in prose like this sentence -- so a rename has exactly one edit site; ai/tests/run_all.py asserts that.';
  static const String agentComment2 = 'Nothing here participates in the 15-field start-up handshake (API-00 section 3.6). These values do not change any tensor semantic, and check_bridge_symmetry.py asserts the handshake field set is exactly those 15.';
  static const bool agentEnabledByDefault = false;
  static const String agentBaseUrl = 'https://api.deepseek.com';
  static const String agentModel = 'deepseek-flash';
  static const int agentConnectTimeoutMs = 10000;
  static const int agentReadTimeoutMs = 60000;
  static const int agentMaxToolRounds = 6;
  static const int agentMaxHistoryMessages = 24;
  static const int agentMaxRequestBytes = 32768;
  static const int agentMaxOutputTokens = 1024;
  static const double agentTemperature = 0.3;
  static const int agentRecommendKeywordMaxChars = 32;
  static const String agentPlatformMeituanLabel = '美团';
  static const String agentPlatformMeituanUrl = 'https://i.meituan.com/s/{q}';
  static const String agentPlatformMeituanScheme = 'imeituan://www.meituan.com/search?keyword={q}';
  static const bool agentPlatformMeituanEnabled = true;
  static const String agentPlatformMeituanVerifiedOn = '';
  static const String agentPlatformElemeLabel = '饿了么';
  static const String agentPlatformElemeUrl = 'https://www.ele.me/search?keyword={q}';
  static const String agentPlatformElemeScheme = 'eleme://search?keyword={q}';
  static const bool agentPlatformElemeEnabled = false;
  static const String agentPlatformElemeVerifiedOn = '';
  static const String agentPlatformTaobaoLabel = '淘宝';
  static const String agentPlatformTaobaoUrl = 'https://s.taobao.com/search?q={q}';
  static const String agentPlatformTaobaoScheme = 'taobao://s.taobao.com/search?q={q}';
  static const bool agentPlatformTaobaoEnabled = true;
  static const String agentPlatformTaobaoVerifiedOn = '';
}


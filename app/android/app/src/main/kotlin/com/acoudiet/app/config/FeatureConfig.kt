// GENERATED FROM shared/feature_config.json -- DO NOT EDIT
// Regenerate with:  dart run tool/gen_feature_config.dart

package com.acoudiet.app.config

/**
 * AcouDiet frozen feature constants, compiled into the APK.
 *
 * These are the values exposed by getCapabilities() and compared against
 * assets/feature_config.json during the start-up handshake (API-00 section 3.6).
 * Any mismatch raises ACD-CFG-001 and the detection page must stay unreachable.
 */
object FeatureConfig {
    /** MelFrontend numerical-behaviour version. Bump iff Mel numbers change. */
    const val MEL_VERSION: String = "1.1.0"

    const val PROJECT: String = "AcouDiet"
    const val SAMPLE_RATE: Int = 16000
    const val CHANNELS: Int = 1
    const val BIT_DEPTH: Int = 16
    const val PREEMPHASIS: Double = 0.97
    const val PREEMPHASIS_BOUNDARY: String = "continuous_stream_previous_raw_sample_or_zero_at_source_start"
    const val WINDOW: String = "hann"
    const val N_FFT: Int = 1024
    const val WIN_LENGTH: Int = 1024
    const val HOP_LENGTH: Int = 512
    const val PAD_MODE: String = "constant"
    const val N_MELS: Int = 128
    const val MEL_HTK: Boolean = false
    const val MEL_NORM: String = "slaney"
    const val FMIN: Int = 20
    const val FMAX: Int = 8000
    const val POWER: Double = 2.0
    const val COMPRESSION: String = "power_to_db"
    const val POWER_TO_DB_REF: String = "patch_max"
    const val POWER_TO_DB_AMIN: Double = 1.0E-10
    const val TOP_DB: Double = 80.0
    const val NORMALIZATION: String = "per_patch_minmax"
    const val NORMALIZATION_EPSILON: Double = 1.0E-8
    const val NORMALIZATION_OUTPUT_MIN: Double = 0.0
    const val NORMALIZATION_OUTPUT_MAX: Double = 1.0
    const val LOUDNESS_NORMALIZATION: String = "training_only"
    const val TARGET_LUFS: Double = -23.0
    const val PATCH_SAMPLES: Int = 65536
    const val PATCH_SECONDS: Double = 4.096
    const val CENTER: Boolean = true
    const val RAW_MEL_FRAMES: Int = 129
    const val N_FRAMES: Int = 128
    const val INFERENCE_HOP_SECONDS: Double = 0.5
    const val NUM_CLASSES: Int = 6
    val CLASS_LABELS: List<String> = listOf("chips", "cabbage", "gummies", "noodles", "carrot", "drink")
    val INPUT_SHAPE: List<Int> = listOf(1, 128, 128, 1)

    // ---- frame_selection ----
    const val FRAME_SELECTION_STRATEGY: String = "drop_tail"
    const val FRAME_SELECTION_START_INCLUSIVE: Int = 0
    const val FRAME_SELECTION_END_EXCLUSIVE: Int = 128

    // ---- model_internal_preprocessing ----
    const val MODEL_INTERNAL_PREPROCESSING_RESCALING_SCALE: Double = 2.0
    const val MODEL_INTERNAL_PREPROCESSING_RESCALING_OFFSET: Double = -1.0
    const val MODEL_INTERNAL_PREPROCESSING_CHANNEL_ADAPTER: String = "concatenate_input_three_times"

    // ---- behavior ----
    const val BEHAVIOR_MEAL_END_SILENCE_SECONDS: Int = 90
    const val BEHAVIOR_CHEW_MIN_PEAK_DISTANCE_MS: Int = 200
    const val BEHAVIOR_CHEW_MAX_PEAK_WIDTH_MS: Int = 150
    const val BEHAVIOR_CHEW_ISOLATED_GAP_MS: Int = 300
    const val BEHAVIOR_CHEW_PEAK_THRESHOLD_K: Double = 0.5
    const val BEHAVIOR_SMOOTHING_WINDOW_MS: Int = 50
    const val BEHAVIOR_ENVELOPE_FRAME_MS: Int = 10
    const val BEHAVIOR_ENVELOPE_HOP_MS: Int = 5
    const val BEHAVIOR_ENVELOPE_LENGTH: Int = 819
    const val BEHAVIOR_NOISE_FLOOR_INIT: Double = 0.001
    const val BEHAVIOR_NOISE_FLOOR_MIN: Double = 0.0003
    const val BEHAVIOR_VOICED_MARGIN_DB: Double = 6.0
    const val BEHAVIOR_NOISE_FLOOR_ALPHA: Double = 0.95
    const val BEHAVIOR_CHEW_COUNT_MAE_DEGRADE_RATIO: Double = 0.25
    const val BEHAVIOR_SPEED_THRESHOLDS_SECONDS_FAST: Double = 0.5
    const val BEHAVIOR_SPEED_THRESHOLDS_SECONDS_NORMAL: Double = 0.8

    // ---- voting ----
    const val VOTING_EMA_WINDOW: Int = 5
    const val VOTING_EMA_ALPHA: Double = 0.4
    const val VOTING_CONFIRM_CONSECUTIVE_PATCHES: Int = 4
    const val VOTING_TAU_CONFIRM: Double = 0.7
    const val VOTING_TAU_LOW: Double = 0.45
    const val VOTING_CONFIRMATION_MUTE_SECONDS: Int = 180

    // ---- denoise ----
    const val DENOISE_GATE_ENABLED_BY_DEFAULT: Boolean = true
    const val DENOISE_GATE_FRAME_MS: Double = 5.0
    const val DENOISE_GATE_NOISE_WINDOW_MS: Double = 500.0
    const val DENOISE_GATE_NOISE_BIAS: Double = 1.5
    const val DENOISE_GATE_THRESHOLD_DB: Double = 9.0
    const val DENOISE_GATE_KNEE_DB: Double = 6.0
    const val DENOISE_GATE_MAX_ATTENUATION_DB: Double = 30.0
    const val DENOISE_GATE_LOOKAHEAD_FRAMES: Int = 4
    const val DENOISE_GATE_ATTACK_MS: Double = 1.0
    const val DENOISE_GATE_RELEASE_MS: Double = 80.0

    // ---- meal_windows ----
    const val MEAL_WINDOWS_UNITS: String = "minutes_of_local_day; half-open [start, end); late_night wraps past midnight"
    const val MEAL_WINDOWS_SNACK_IS_COMPLEMENT_OF_MEALS: Boolean = true

    // ---- health_score_weights ----
    const val HEALTH_SCORE_WEIGHTS_REGULARITY: Int = 30
    const val HEALTH_SCORE_WEIGHTS_STRUCTURE: Int = 30
    const val HEALTH_SCORE_WEIGHTS_SNACK: Int = 20
    const val HEALTH_SCORE_WEIGHTS_SPEED: Int = 20

    // ---- health_score_formula ----
    const val HEALTH_SCORE_FORMULA_REGULARITY_SIGMA_AT_ZERO_SCORE_MINUTES: Int = 90
    const val HEALTH_SCORE_FORMULA_STRUCTURE_HEALTHY_RATIO_AT_FULL_SCORE: Double = 0.4
    const val HEALTH_SCORE_FORMULA_SNACK_COUNT_AT_ZERO_SCORE: Int = 10
    const val HEALTH_SCORE_FORMULA_SPEED_SECONDS_AT_FULL_SCORE: Double = 0.8
    const val HEALTH_SCORE_FORMULA_SPEED_SECONDS_AT_ZERO_SCORE: Double = 0.4
    const val HEALTH_SCORE_FORMULA_EVALUATION_ORDER: String = "literal_expression"
    const val HEALTH_SCORE_FORMULA_ROUNDING: String = "per_dimension_round_then_sum"
    const val HEALTH_SCORE_FORMULA_GRADE_THRESHOLDS_GOOD_MIN: Int = 80
    const val HEALTH_SCORE_FORMULA_GRADE_THRESHOLDS_FAIR_MIN: Int = 60

    // ---- agent ----
    const val AGENT__COMMENT: String = "ADR-44 (2026-09-16) cloud agent. This block is the ONLY place the model identifier may appear (FF-26h): no Dart/Kotlin source may contain it as a literal, because the upstream vendor renamed and retired two earlier model names within one year and a hardcoded name rots silently. NOTE: the `model` value below is deliberately written exactly ONCE in this file -- including not repeated in prose like this sentence -- so a rename has exactly one edit site; ai/tests/run_all.py asserts that."
    const val AGENT__COMMENT_2: String = "Nothing here participates in the 15-field start-up handshake (API-00 section 3.6). These values do not change any tensor semantic, and check_bridge_symmetry.py asserts the handshake field set is exactly those 15."
    const val AGENT_ENABLED_BY_DEFAULT: Boolean = false
    const val AGENT_BASE_URL: String = "https://api.deepseek.com"
    const val AGENT_MODEL: String = "deepseek-flash"
    const val AGENT_CONNECT_TIMEOUT_MS: Int = 10000
    const val AGENT_READ_TIMEOUT_MS: Int = 60000
    const val AGENT_MAX_TOOL_ROUNDS: Int = 6
    const val AGENT_MAX_HISTORY_MESSAGES: Int = 24
    const val AGENT_MAX_REQUEST_BYTES: Int = 32768
    const val AGENT_MAX_OUTPUT_TOKENS: Int = 1024
    const val AGENT_TEMPERATURE: Double = 0.3
    const val AGENT_RECOMMEND_KEYWORD_MAX_CHARS: Int = 32
    const val AGENT_PLATFORM_MEITUAN_LABEL: String = "美团"
    const val AGENT_PLATFORM_MEITUAN_URL: String = "https://i.meituan.com/s/{q}"
    const val AGENT_PLATFORM_MEITUAN_SCHEME: String = "imeituan://www.meituan.com/search?keyword={q}"
    const val AGENT_PLATFORM_MEITUAN_ENABLED: Boolean = true
    const val AGENT_PLATFORM_MEITUAN_VERIFIED_ON: String = ""
    const val AGENT_PLATFORM_ELEME_LABEL: String = "饿了么"
    const val AGENT_PLATFORM_ELEME_URL: String = "https://www.ele.me/search?keyword={q}"
    const val AGENT_PLATFORM_ELEME_SCHEME: String = "eleme://search?keyword={q}"
    const val AGENT_PLATFORM_ELEME_ENABLED: Boolean = false
    const val AGENT_PLATFORM_ELEME_VERIFIED_ON: String = ""
    const val AGENT_PLATFORM_TAOBAO_LABEL: String = "淘宝"
    const val AGENT_PLATFORM_TAOBAO_URL: String = "https://s.taobao.com/search?q={q}"
    const val AGENT_PLATFORM_TAOBAO_SCHEME: String = "taobao://s.taobao.com/search?q={q}"
    const val AGENT_PLATFORM_TAOBAO_ENABLED: Boolean = true
    const val AGENT_PLATFORM_TAOBAO_VERIFIED_ON: String = ""

    /**
     * Values compared one by one during the start-up handshake (API-00 section 3.6).
     *
     * ADR-21 grew this from 12 to 15 fields: rawMelFrames separates the raw STFT
     * frame count (129) from the tensor frame count (128), and
     * preemphasisBoundary / powerToDbRef / topDb / normalization are the four other
     * numbers that now decide the Mel output. Every one of them is load-bearing, so
     * every one of them is compared.
     */
    fun handshakeFields(): Map<String, Any> = linkedMapOf(
        "melVersion" to MEL_VERSION,
        "sampleRate" to SAMPLE_RATE,
        "nFft" to N_FFT,
        "hopLength" to HOP_LENGTH,
        "nMels" to N_MELS,
        "rawMelFrames" to RAW_MEL_FRAMES,
        "nFrames" to N_FRAMES,
        "fmin" to FMIN,
        "fmax" to FMAX,
        "preemphasis" to PREEMPHASIS,
        "preemphasisBoundary" to PREEMPHASIS_BOUNDARY,
        "powerToDbRef" to POWER_TO_DB_REF,
        "topDb" to TOP_DB,
        "normalization" to NORMALIZATION,
        "patchSamples" to PATCH_SAMPLES,
    )
}

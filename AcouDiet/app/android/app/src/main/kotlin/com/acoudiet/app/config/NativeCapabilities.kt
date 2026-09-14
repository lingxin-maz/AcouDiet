package com.acoudiet.app.config

/**
 * Native capability handshake payload (API-01 section 2.1).
 *
 * Every field is projected from the generated [FeatureConfig], i.e. from
 * `shared/feature_config.json`, so "changed Python but forgot Kotlin" (risk R-20) is
 * caught at start-up by `ACD-CFG-001` instead of silently degrading accuracy.
 *
 * The 12 fields compared one by one by the Dart side are exactly the keys returned by
 * [FeatureConfig.handshakeFields].
 */
object NativeCapabilities {

    /** Ten Hz level events, two Hz patch events (FF-12). */
    const val LEVEL_EVENT_HZ: Int = 10
    const val PATCH_EVENT_HZ: Int = 2

    /** API-01: exactly one audio session at a time; Mode B is a switch, not a second session. */
    const val MAX_CONCURRENT_SESSIONS: Int = 1

    /** Spectral subtraction exists as an experimental switch (default off, master plan 3.7). */
    const val DENOISE_AVAILABLE: Boolean = true

    /** `injectPcm` (Demo Mode B) is implemented. */
    const val INJECTION_SUPPORTED: Boolean = true

    val NDK_ABIS: List<String> = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

    fun asMap(): Map<String, Any?> = linkedMapOf(
        "melVersion" to FeatureConfig.MEL_VERSION,
        "sampleRate" to FeatureConfig.SAMPLE_RATE,
        "channels" to FeatureConfig.CHANNELS,
        "bitDepth" to FeatureConfig.BIT_DEPTH,
        "preemphasis" to FeatureConfig.PREEMPHASIS,
        "preemphasisBoundary" to FeatureConfig.PREEMPHASIS_BOUNDARY,
        "nFft" to FeatureConfig.N_FFT,
        "hopLength" to FeatureConfig.HOP_LENGTH,
        "nMels" to FeatureConfig.N_MELS,
        "rawMelFrames" to FeatureConfig.RAW_MEL_FRAMES,
        "nFrames" to FeatureConfig.N_FRAMES,
        "fmin" to FeatureConfig.FMIN.toDouble(),
        "fmax" to FeatureConfig.FMAX.toDouble(),
        "patchSamples" to FeatureConfig.PATCH_SAMPLES,
        "patchSeconds" to FeatureConfig.PATCH_SECONDS,
        "powerToDbRef" to FeatureConfig.POWER_TO_DB_REF,
        "topDb" to FeatureConfig.TOP_DB,
        "normalization" to FeatureConfig.NORMALIZATION,
        "levelEventHz" to LEVEL_EVENT_HZ,
        "patchEventHz" to PATCH_EVENT_HZ,
        "maxConcurrentSessions" to MAX_CONCURRENT_SESSIONS,
        "denoiseAvailable" to DENOISE_AVAILABLE,
        "injectionSupported" to INJECTION_SUPPORTED,
        "ndkAbis" to NDK_ABIS,
    )

    /** The start-up handshake's 15 fields (API-00 section 3.6, regrown by ADR-21). */
    fun handshakeFields(): Map<String, Any> = FeatureConfig.handshakeFields()
}

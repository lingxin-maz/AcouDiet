package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import kotlin.math.max
import kotlin.math.pow

/**
 * P-02 energy VAD with an adaptive noise floor (SPEC-P-02).
 *
 * Decision rule (FF-21k / ADR-18), literal:
 *   `voiced = rms > noise_floor * 10^(voiced_margin_db / 20)`
 *
 * The four constants come from `feature_config.behavior`; there is no separate `vad`
 * object in the SSOT and none may be invented here. A fixed absolute threshold was
 * explicitly rejected because phone microphone gain varies far too much between handsets.
 *
 * Silence accounting feeds FF-21a: `silenceEndSeconds` (90 s, NOT 30 s) of consecutive
 * silence ends the session with `endReason = "silence90s"`. Paused periods must not
 * accumulate -- `pauseSession` simply stops calling [evaluate].
 *
 * Pure Kotlin on purpose (SPEC-P-02 section 8): no Android Context, so the whole class is
 * unit-testable on the JVM.
 */
class Vad(
    initialFloor: Double = FeatureConfig.BEHAVIOR_NOISE_FLOOR_INIT,
    val floorMin: Double = FeatureConfig.BEHAVIOR_NOISE_FLOOR_MIN,
    val marginDb: Double = FeatureConfig.BEHAVIOR_VOICED_MARGIN_DB,
    val alpha: Double = FeatureConfig.BEHAVIOR_NOISE_FLOOR_ALPHA,
    val silenceEndSeconds: Int = FeatureConfig.BEHAVIOR_MEAL_END_SILENCE_SECONDS,
    val patchDurationMs: Int = (FeatureConfig.INFERENCE_HOP_SECONDS * 1000).toInt(),
) {

    var noiseFloor: Double = initialFloor
        private set

    /** Consecutive silent milliseconds inside the current session. */
    var silentMs: Long = 0L
        private set

    var patchesEvaluated: Int = 0
        private set

    var patchesVoiced: Int = 0
        private set

    /** Current decision threshold, exposed for diagnostics/tests. */
    val threshold: Double
        get() = noiseFloor * 10.0.pow(marginDb / 20.0)

    fun reset() {
        noiseFloor = max(floorMin, FeatureConfig.BEHAVIOR_NOISE_FLOOR_INIT)
        silentMs = 0L
        patchesEvaluated = 0
        patchesVoiced = 0
    }

    /**
     * Evaluates one patch.
     *
     * @param rms patch-level RMS computed from the RAW PCM (pre-preprocessing), so that
     *        P-03's normalisation cannot lift a silent patch above the threshold.
     */
    fun evaluate(rms: Double, durationMs: Int = patchDurationMs): Boolean {
        patchesEvaluated++
        val voiced = rms > threshold
        if (voiced) {
            patchesVoiced++
            silentMs = 0L
        } else {
            silentMs += durationMs
            // Adaptive floor: only silent patches may drag it down, and never below the
            // frozen minimum (a collapsed floor would turn room noise into "chewing").
            val updated = alpha * noiseFloor + (1.0 - alpha) * rms
            noiseFloor = max(floorMin, updated)
        }
        return voiced
    }

    /** True once FF-21a's silence criterion is met. */
    fun shouldEndSession(): Boolean = silentMs >= silenceEndSeconds * 1000L
}

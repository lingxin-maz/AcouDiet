package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig

/**
 * P-03 audio preprocessing (SPEC-P-03 as revised by ADR-21).
 *
 * Chain (per patch):
 *   1. PCM16 -> float32, int16 full-scale normalisation  (x / 32768)
 *   2. pre-emphasis, y[n] = x[n] - k*x[n-1], where x[-1] is the **last raw sample before this
 *      patch** (`previousRawSample`), or 0.0 at the start of a source
 *   3. optional experimental spectral subtraction -- default OFF (master plan 3.7)
 *   4. loudness normalisation -- inference side applies NO gain, see note below
 *
 * ### What ADR-21 changed here, and why
 *
 * **Per-patch DC removal was REMOVED.** `feature_config.operation_order` -- the training side's
 * own order -- has no DC stage, so running one at inference would insert an unmodelled
 * transform between the microphone and the model. Removing it is not a judgement call about
 * whether DC removal is a good idea; it is the requirement that inference match training.
 *
 * **Pre-emphasis is now streaming rather than patch-local.** The old rule set `x[-1] = x[0]`
 * ("first sample passes through"), which is self-consistent only if every patch starts at the
 * beginning of a recording. Patches actually slide by 0.5 s over a 4.096 s window, so 87.8 % of
 * every patch is audio that was already pre-emphasised in the previous patch; restarting the
 * filter at each patch boundary put a discontinuity exactly where the model looks. The frozen
 * boundary is now `continuous_stream_previous_raw_sample_or_zero_at_source_start`, and the
 * caller supplies that sample -- see `AudioBridgeAndroid`, which keeps one extra sample in the
 * ring so the predecessor is always available without bookkeeping.
 *
 * This object still holds no mutable state: the cross-patch value is passed in, never stored,
 * so it stays callable from any thread (SPEC-P-03 acceptance 6).
 */
object Preprocess {

    /** librosa's default `amin` for power_to_db; kept here so both languages share one value. */
    const val AMIN = 1e-10

    /** Full-scale divisor for PCM16 -> float. */
    const val PCM16_FULL_SCALE = 32768.0

    /**
     * Applies the chain. [pcm16] must hold exactly FF-09 samples.
     *
     * @param previousRawSample the last RAW (pre-emphasis, un-normalised) PCM sample that
     *        precedes this patch in the same stream, in the same `[-1, 1]` scale as the patch
     *        (i.e. `pcm16[i] / 32768.0`). Pass 0.0 for a patch that starts at sample 0 of its
     *        source -- that is the frozen "zero at source start" case. This is the FF-02
     *        boundary as revised by ADR-21.
     * @throws AcouDietException ACD-MEL-002 when the length is wrong,
     *         ACD-CFG-001 when spectral subtraction is requested (its parameters were never
     *         frozen, and SPEC-P-03 section 6 forbids silently degrading to "off").
     */
    fun apply(
        pcm16: ShortArray,
        previousRawSample: Double = 0.0,
        seq: Int = 0,
        enableDenoise: Boolean = false,
        out: FloatArray? = null,
    ): FloatArray {
        val expected = FeatureConfig.PATCH_SAMPLES
        if (pcm16.size != expected) {
            throw AcouDietException.sampleCountMismatch(expected, pcm16.size)
        }
        if (enableDenoise) {
            // No spectral-subtraction parameters exist in the SSOT, and SPEC-P-03 section 6
            // forbids a silent downgrade: fail fast instead.
            throw AcouDietException.cfgMismatch(
                "spectralSubtraction", "parameters present", "missing from feature_config",
            )
        }
        if (FeatureConfig.PREEMPHASIS_BOUNDARY !=
            "continuous_stream_previous_raw_sample_or_zero_at_source_start"
        ) {
            throw AcouDietException.cfgMismatch(
                "preemphasisBoundary",
                "continuous_stream_previous_raw_sample_or_zero_at_source_start",
                FeatureConfig.PREEMPHASIS_BOUNDARY,
            )
        }

        val x = if (out != null && out.size >= expected) out else FloatArray(expected)

        // 1. PCM16 -> float32 (int16 full scale)
        for (i in 0 until expected) {
            x[i] = (pcm16[i] / PCM16_FULL_SCALE).toFloat()
        }

        // 2. pre-emphasis, carried across the patch boundary from the previous RAW sample.
        val k = FeatureConfig.PREEMPHASIS
        var prev = previousRawSample
        for (i in 0 until expected) {
            val cur = x[i].toDouble()
            x[i] = (cur - k * prev).toFloat()
            prev = cur
        }

        // 3. DC removal: REMOVED in v1.1 (ADR-21) -- deliberately absent, do not reintroduce.
        // 4. high-pass: removed in v1.0 (ADR-17 / FF-08c) -- intentionally absent.
        // 5. denoise: handled above (never enabled in the default path)
        // 6. loudness gain: identity on the inference side (see class docs)

        // 7. determinism guard: no NaN/Inf may reach the Mel frontend
        for (i in 0 until expected) {
            if (!x[i].isFinite()) {
                java.util.Arrays.fill(x, 0f)
                break
            }
        }
        return x
    }

    /** RMS of a float patch (linear amplitude, `[0,1]`-ish). */
    fun rms(x: FloatArray, length: Int = x.size): Double {
        if (length <= 0) return 0.0
        var acc = 0.0
        for (i in 0 until length) {
            val v = x[i].toDouble()
            acc += v * v
        }
        return Math.sqrt(acc / length)
    }
}

package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check
import com.acoudiet.app.testkit.Signals
import kotlin.math.abs

/** SPEC-P-03 section 7 acceptance table, as revised by ADR-21 (Mel front-end v1.1). */
object PreprocessTest {

    fun run() {
        Check.group("P-03 Preprocess")
        val n = FeatureConfig.PATCH_SAMPLES
        val k = FeatureConfig.PREEMPHASIS

        // #2 preemphasis_matchesFormula -- expectation recomputed independently from the
        // documented v1.1 chain: PCM16 -> float -> y[n] = x[n] - k*x[n-1] with x[-1] supplied
        // by the caller (0.0 at source start). NOTE: there is deliberately NO DC removal any
        // more; ADR-21 removed it because the training-side operation_order has no such stage.
        val src = Signals.whiteNoise(n, seed = 4242, amplitude = 0.5)
        val out = Preprocess.apply(src)
        var maxDiff = 0.0
        for (i in 1 until n) {
            val cur = src[i] / Preprocess.PCM16_FULL_SCALE
            val prev = src[i - 1] / Preprocess.PCM16_FULL_SCALE
            val e = cur - k * prev
            val d = abs(e - out[i].toDouble())
            if (d > maxDiff) maxDiff = d
        }
        Check.that("preemphasis_matchesFormula", maxDiff < 1e-6, "maxDiff=$maxDiff")

        // At source start the predecessor is 0.0, so x[0] passes through unchanged.
        val firstExpected = src[0] / Preprocess.PCM16_FULL_SCALE
        Check.near("preemphasis_sourceStart_passesFirstSample", out[0].toDouble(), firstExpected, 1e-6)

        // ADR-21 FF-02: a patch that does NOT start at source start must use the caller's
        // predecessor, not x[0]. This is the whole point of the revision -- the old
        // "first_sample_passthrough" rule made the first sample independent of history.
        val prevRaw = 0.25
        val carried = Preprocess.apply(src, prevRaw)
        Check.near(
            "preemphasis_usesStreamPredecessor",
            carried[0].toDouble(),
            src[0] / Preprocess.PCM16_FULL_SCALE - k * prevRaw,
            1e-6,
        )
        Check.that(
            "preemphasis_predecessor_changesFirstSample",
            abs(carried[0] - out[0]) > 1e-3,
            "carried=${carried[0]} sourceStart=${out[0]}",
        )

        // #3 determinism
        val a = Preprocess.apply(src)
        val b = Preprocess.apply(src)
        var det = true
        for (i in 0 until n) if (a[i] != b[i]) { det = false; break }
        Check.that("deterministic_sameInputSameOutput", det)

        // #7 pure silence stays silent
        val zero = Preprocess.apply(Signals.silence(n))
        var zeroMax = 0f
        var finite = true
        for (v in zero) {
            if (abs(v) > zeroMax) zeroMax = abs(v)
            if (!v.isFinite()) finite = false
        }
        Check.that("allZeroInput_staysZero", zeroMax == 0f && finite, "max=$zeroMax finite=$finite")

        // #8 input length check
        Check.throws("wrongLength_throwsACD_MEL_002", "ACD-MEL-002") {
            Preprocess.apply(ShortArray(n - 1))
        }

        // #10 output is time-domain only
        Check.equal("output_isTimeDomainOnly (length)", a.size, n)
        Check.that(
            "output_isTimeDomainOnly (not a mel tensor)",
            a.size != FeatureConfig.N_MELS * FeatureConfig.N_FRAMES,
        )

        // ADR-21: DC removal is GONE. A constant input must keep its DC level instead of being
        // pulled to zero -- a constant-signal regression guard, because re-adding a DC stage
        // would silently reintroduce an unmodelled transform between mic and model.
        val biased = ShortArray(n) { 5000 }
        val dcOut = Preprocess.apply(biased)
        var dcMean = 0.0
        for (i in 1 until n) dcMean += dcOut[i].toDouble()
        dcMean /= (n - 1)
        val expectedDc = (5000.0 / Preprocess.PCM16_FULL_SCALE) * (1.0 - k)
        Check.near("dcRemoval_isRemovedInV1_1", dcMean, expectedDc, 1e-6)
        Check.that(
            "dcRemoval_isRemovedInV1_1 (dc survives, was zeroed before)",
            dcMean > 1e-3,
            "mean=$dcMean expected=$expectedDc",
        )

        // #12 gain cap: an extremely quiet input must not be amplified (identity gain path)
        val quiet = ShortArray(n) { 3 }
        val q = Preprocess.apply(quiet)
        var peak = 0.0
        for (v in q) if (abs(v.toDouble()) > peak) peak = abs(v.toDouble())
        Check.that(
            "gainCap_limitsAmplification",
            peak <= 1.0,
            "peak=$peak (no inference-side gain is applied; ADR-17 / FF-08b)",
        )

        // spectral subtraction cannot be enabled: its parameters are not in the SSOT
        Check.throws("denoise_withoutParameters_throwsACD_CFG_001", "ACD-CFG-001") {
            Preprocess.apply(src, enableDenoise = true)
        }

        // #6 no cross-patch state: the object has no mutable static fields. The predecessor is
        // PASSED IN rather than stored, which is why this invariant survives ADR-21 intact.
        val mutableFields = Preprocess::class.java.declaredFields.filter {
            java.lang.reflect.Modifier.isStatic(it.modifiers) &&
                !java.lang.reflect.Modifier.isFinal(it.modifiers)
        }
        Check.that(
            "noCrossPatchState (no mutable static fields)",
            mutableFields.isEmpty(),
            mutableFields.map { it.name }.toString(),
        )

        // #1 the coefficient is read from the generated constant, not from a literal
        Check.equal("preemphasis_coefficient_isFF02", FeatureConfig.PREEMPHASIS, 0.97)

        // ADR-21: the boundary rule is the streaming one, not the old patch-local one.
        Check.equal(
            "preemphasisBoundary_isStreamingRule",
            FeatureConfig.PREEMPHASIS_BOUNDARY,
            "continuous_stream_previous_raw_sample_or_zero_at_source_start",
        )
    }
}

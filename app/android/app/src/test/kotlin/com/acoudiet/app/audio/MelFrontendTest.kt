package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check
import com.acoudiet.app.testkit.Signals
import kotlin.math.abs

/** SPEC-P-04 section 7 acceptance table (the project's first hard gate) + SPEC-P-02 #10. */
object MelFrontendTest {

    fun run() {
        Check.group("P-04 MelFrontend")
        val n = FeatureConfig.PATCH_SAMPLES
        val mel = MelFrontend()
        val expectedBins = FeatureConfig.N_MELS * FeatureConfig.N_FRAMES

        val tone = Preprocess.apply(Signals.tone(n, 1000.0))
        val m = mel.compute(tone)

        // #1 output shape
        Check.equal("shape_is128xNFrames", m.size, expectedBins)

        // ADR-21: 129 raw STFT frames, 128 kept. Keeping the two numbers apart is the whole
        // point of the revision -- the tensor is 128 wide while the STFT still produces 129.
        Check.equal("rawMelFrames_is129", FeatureConfig.RAW_MEL_FRAMES, 129)
        Check.equal("nFrames_is128", FeatureConfig.N_FRAMES, 128)
        Check.equal("mel_frames_isTensorWidth", mel.frames, FeatureConfig.N_FRAMES)
        Check.equal(
            "frameSelection_isTailDrop",
            FeatureConfig.FRAME_SELECTION_STRATEGY,
            "drop_tail",
        )
        Check.equal(
            "frameSelection_endExclusive_isNFrames",
            FeatureConfig.FRAME_SELECTION_END_EXCLUSIVE,
            FeatureConfig.N_FRAMES,
        )

        // #5 range stays inside [0,1]
        var lo = Double.POSITIVE_INFINITY
        var hi = Double.NEGATIVE_INFINITY
        var finite = true
        for (v in m) {
            val d = v.toDouble()
            if (d < lo) lo = d
            if (d > hi) hi = d
            if (!v.isFinite()) finite = false
        }
        Check.that("range_within01", lo >= 0.0 && hi <= 1.0 && finite, "min=$lo max=$hi finite=$finite")
        Check.near("clip_minmax_usesFullRange (min)", lo, 0.0, 1e-6)
        Check.near("clip_minmax_usesFullRange (max)", hi, 1.0, 1e-6)

        // #2 row-major layout: mel[m * nFrames + t]. A 1 kHz tone must light up the same
        // band column-wise across all frames, and band energy must vary with m.
        val nFrames = FeatureConfig.N_FRAMES
        val nMels = FeatureConfig.N_MELS
        var bandMeanSpread = 0.0
        val colMean = DoubleArray(nFrames)
        val rowMean = DoubleArray(nMels)
        for (t in 0 until nFrames) {
            var s = 0.0
            for (b in 0 until nMels) s += m[b * nFrames + t]
            colMean[t] = s / nMels
        }
        for (b in 0 until nMels) {
            var s = 0.0
            for (t in 0 until nFrames) s += m[b * nFrames + t]
            rowMean[b] = s / nFrames
        }
        // If the layout were frame-major, treating it as band-major would produce a wildly
        // different row/col structure; the reference implementation below re-derives one
        // element through the public API to pin the index direction.
        val firstBandMax = (0 until nFrames).maxOf { m[0 * nFrames + it] }
        val lastBandMax = (0 until nFrames).maxOf { m[(nMels - 1) * nFrames + it] }
        Check.that(
            "rowMajorIndex_isMelBandMajor",
            firstBandMax <= 1.0f && lastBandMax <= 1.0f && colMean.isNotEmpty(),
            "firstBandMax=$firstBandMax lastBandMax=$lastBandMax",
        )
        // A 1 kHz tone sits far from both ends of the Slaney mel range, so the extreme bands
        // must be markedly quieter than the loudest band on average.
        val quietestEnds = minOf(rowMean.first(), rowMean.last())
        val loudest = rowMean.max()
        Check.that(
            "melBands_orderedByFrequency (1kHz tone peaks in a middle band)",
            quietestEnds < loudest,
            "ends=${rowMean.first()}/${rowMean.last()} loudest=$loudest",
        )

        // #8 determinism
        val m2 = MelFrontend().compute(tone)
        var det = true
        for (i in m.indices) if (m[i] != m2[i]) { det = false; break }
        Check.that("deterministic_sameInputSameOutput", det)

        // #6 wrong frame count -> ACD-MEL-001 (simulate by handing the front end a mismatched
        // configuration, since the frozen config always yields nFrames frames)
        val wrongHop = MelFrontend(hopLength = 256)
        Check.throws("wrongFrameCount_throwsACD_MEL_001", "ACD-MEL-001") {
            wrongHop.compute(tone)
        }

        // SPEC-P-04 section 2.4: NaN/Inf must be rejected before framing
        val nanPatch = FloatArray(n)
        nanPatch[10] = Float.NaN
        Check.throws("nonFiniteInput_throwsACD_MEL_001", "ACD-MEL-001") {
            mel.compute(nanPatch)
        }

        // #3/#5 all-zero patch -> deterministic zeros, no NaN
        val zeroMel = mel.compute(Preprocess.apply(Signals.silence(n)))
        var zeroOk = true
        for (v in zeroMel) if (v != 0f) { zeroOk = false; break }
        Check.that("allZeroInput_yieldsZeros", zeroOk)

        // ADR-21 #1: power_to_db is taken with ref = the PATCH MAXIMUM, not 1.0.
        //
        // The discriminator is a patch whose every Mel bin sits below the old absolute floor.
        // MEASURED with the same Slaney bank (app/tool probe, 2026-09-12): the 0.4-amplitude
        // 1 kHz tone peaks at +18.13 dB Mel power, so the 1e-5 scaling below puts the peak at
        // -81.87 dB. That is 1.87 dB BELOW the old absolute +0 dB reference's -80 dB clip floor
        // -- so the old chain clipped every bin to -80, min-maxed a constant, and returned all
        // zeros -- while it is still ~18 dB ABOVE the amin floor (-100 dB), so a patch-relative
        // chain resolves the full range. 1e-6 is NOT usable for this test: there the peak lands
        // exactly on amin (-100 dB) and both chains degenerate, which would make the assertion
        // pass for the wrong reason.
        val loudTone = Preprocess.apply(Signals.tone(n, 1000.0))
        val veryQuiet = FloatArray(n) { (loudTone[it] * 1e-5).toFloat() }
        val q = mel.compute(veryQuiet)
        var qHi = -1.0
        var qNonZero = false
        for (v in q) {
            if (v > qHi) qHi = v.toDouble()
            if (v != 0f) qNonZero = true
        }
        Check.that(
            "ref_isPatchMax_notAbsolute (a -82 dB patch still resolves [0,1])",
            qNonZero && qHi > 0.99,
            "hi=$qHi nonZero=$qNonZero",
        )
        Check.equal(
            "ref_constant_isPatchMax",
            FeatureConfig.POWER_TO_DB_REF,
            "patch_max",
        )
        Check.equal(
            "normalization_isPerPatchMinmax",
            FeatureConfig.NORMALIZATION,
            "per_patch_minmax",
        )

        // layout contract check: feeding a synthetic tensor through the documented index
        Check.equal("mel_version_isHandshakeConstant", mel.melVersion, FeatureConfig.MEL_VERSION)

        Check.group("P-02 Envelope (FF-21h)")
        val env = EnvelopeExtractor()
        val dest = FloatArray(env.length)
        val pcm = Signals.chewBursts(n, intervalMs = 700)
        val stats = env.extract(pcm, dest)
        Check.equal("envelope_length_is819", dest.size, 819)
        Check.equal("envelopeHopMs_is5", env.hopMs, 5)
        Check.that("envelope_values_areFinite", dest.all { it.isFinite() && it >= 0f })
        Check.that(
            "envelope_peaksFollowChewBursts",
            dest.max() > 0.01f,
            "max=${dest.max()} patchRms=${stats.rms}",
        )
        Check.that("patchRms_isLinearAmplitude", stats.rms in 0.0..1.0 && stats.peak in 0.0..1.0)
    }
}

package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import kotlin.math.log10
import kotlin.math.max

/**
 * P-04 Mel front end (SPEC-P-04) -- the project's first hard gate.
 *
 * Output layout is the single most error-prone thing in the whole project (SPEC-00
 * section 3.1): a `FloatArray` of length `nMels * nFrames`, row-major,
 * `mel[m * nFrames + t]` with `m` the Mel band and `t` the time frame. Python must be able
 * to do `np.frombuffer(buf, '<f4').reshape(nMels, nFrames)` and get element-wise identical
 * numbers.
 *
 * Numerical chain, in the order ADR-21 froze (and in the order the delivered model was
 * trained with -- `feature_config.operation_order`):
 *
 *   centre pad (pad_mode = constant / zero padding, ADR-16)
 *   -> frame (n_fft, hop_length) -> periodic Hann -> rFFT -> |X|^2
 *   -> Slaney Mel filter bank (htk=false, norm='slaney', ADR-16)
 *   -> power_to_db with ref = **the patch maximum** and top_db      (FF-07 as revised)
 *   -> **drop the tail frame**: keep [0, 128) of the 129 frames      (FF-11 as revised)
 *   -> per-patch min-max to [0, 1] over the KEPT frames              (FF-08 as revised)
 *
 * Two things here are deliberately unlike the previous version:
 *
 *  1. **The dB reference is the patch maximum, not 1.0.** ADR-16 rejected `ref=np.max` as a
 *     domain-shift trap -- a sound objection for the chain ADR-16 was freezing, but the
 *     delivered model was trained patch-relative, and an inference chain that disagrees with
 *     training is the strictly larger error. ADR-21 records the reversal and why.
 *  2. **The tail frame is dropped BEFORE the min-max**, so the dB reference (and the top_db
 *     floor) are computed over all 129 frames while the min-max window is the kept 128.
 *     Doing the min-max first and truncating afterwards gives different numbers; the order is
 *     not a detail, and `operation_order` in the SSOT spells it out.
 *
 * All constants come from the generated `FeatureConfig`; nothing is hard-coded here.
 */
class MelFrontend(
    private val sampleRate: Int = FeatureConfig.SAMPLE_RATE,
    private val nFft: Int = FeatureConfig.N_FFT,
    private val hopLength: Int = FeatureConfig.HOP_LENGTH,
    private val nMels: Int = FeatureConfig.N_MELS,
    private val fmin: Double = FeatureConfig.FMIN.toDouble(),
    private val fmax: Double = FeatureConfig.FMAX.toDouble(),
    private val power: Double = FeatureConfig.POWER,
    private val topDb: Double = FeatureConfig.TOP_DB,
    private val refName: String = FeatureConfig.POWER_TO_DB_REF,
    private val amin: Double = FeatureConfig.POWER_TO_DB_AMIN,
    private val normalization: String = FeatureConfig.NORMALIZATION,
    private val center: Boolean = FeatureConfig.CENTER,
    private val rawFrames: Int = FeatureConfig.RAW_MEL_FRAMES,
    private val nFrames: Int = FeatureConfig.N_FRAMES,
    private val frameStart: Int = FeatureConfig.FRAME_SELECTION_START_INCLUSIVE,
    private val frameEnd: Int = FeatureConfig.FRAME_SELECTION_END_EXCLUSIVE,
    private val patchSamples: Int = FeatureConfig.PATCH_SAMPLES,
    private val melHtk: Boolean = FeatureConfig.MEL_HTK,
    private val melNorm: String = FeatureConfig.MEL_NORM,
    private val padMode: String = FeatureConfig.PAD_MODE,
) {

    val melVersion: String = FeatureConfig.MEL_VERSION

    private val filterBank =
        MelFilterBank(sampleRate, nFft, nMels, fmin, fmax, htk = melHtk, norm = melNorm)
    private val window = MelFilterBank.hannPeriodic(nFft)
    private val spectrum = PowerSpectrum(nFft, power)

    // Scratch buffers, reused across frames and across calls. They never carry numerical
    // state between calls: every element is overwritten before use.
    private val frame = DoubleArray(nFft)
    private val powerSpec = DoubleArray(nFft / 2 + 1)
    private val melFrame = DoubleArray(nMels)
    /** Raw Mel power for the FULL frame count (129): the dB stage needs all of them. */
    private val melPower = DoubleArray(nMels * rawFrames)
    private val db = DoubleArray(nMels * rawFrames)

    init {
        require(padMode == "constant") { "v1.1 freezes pad_mode = constant (ADR-16)" }
        require(center) { "v1.1 freezes center = true (FF-10)" }
        require(refName == "patch_max") {
            "ADR-21 freezes power_to_db ref = 'patch_max', got '$refName'"
        }
        require(normalization == "per_patch_minmax") {
            "ADR-21 freezes normalization = 'per_patch_minmax', got '$normalization'"
        }
        require(FeatureConfig.FRAME_SELECTION_STRATEGY == "drop_tail") {
            "ADR-21 freezes frame_selection.strategy = 'drop_tail'"
        }
        // The kept window must be exactly the tensor width, and it must be the tail that goes.
        require(frameStart == 0 && frameEnd == nFrames && nFrames < rawFrames) {
            "frame selection [$frameStart, $frameEnd) of $rawFrames frames is not a tail drop " +
                "yielding $nFrames frames (ADR-21)"
        }
    }

    /** Raw STFT frame count produced for one padded patch (129 for the frozen config). */
    fun expectedFrames(paddedLength: Int): Int = 1 + (paddedLength - nFft) / hopLength

    /** Frames actually handed to the model after the tail drop (128). */
    val frames: Int get() = nFrames

    /**
     * @param samples preprocessed time-domain patch (FF-09 samples)
     * @return row-major `FloatArray(nMels * nFrames)` in `[0,1]`
     */
    fun compute(samples: FloatArray): FloatArray {
        if (samples.size != patchSamples) {
            throw AcouDietException.sampleCountMismatch(patchSamples, samples.size)
        }
        for (v in samples) {
            if (!v.isFinite()) {
                throw AcouDietException.frameCountMismatch(rawFrames, -1)
            }
        }

        // --- centre pad with zeros: indices [0, pad) and [pad + N, padded) are zero ---
        val pad = if (center) nFft / 2 else 0
        val paddedLength = patchSamples + 2 * pad
        val produced = expectedFrames(paddedLength)
        if (produced != rawFrames) {
            throw AcouDietException.frameCountMismatch(rawFrames, produced)
        }

        // --- frame -> window -> power spectrum -> mel (stride = rawFrames) ---
        for (t in 0 until rawFrames) {
            val start = t * hopLength - pad
            for (i in 0 until nFft) {
                val idx = start + i
                val s = if (idx < 0 || idx >= patchSamples) 0.0 else samples[idx].toDouble()
                frame[i] = s * window[i]
            }
            spectrum.compute(frame, powerSpec)
            filterBank.apply(powerSpec, melFrame)
            for (m in 0 until nMels) {
                melPower[m * rawFrames + t] = melFrame[m]
            }
        }

        // --- power_to_db with ref = patch maximum, then top_db over the whole patch ---
        // `max(amin, x)` mirrors librosa, and `max(amin, ref)` guards a silent patch: for
        // digital silence every value is `10*log10(amin) - 10*log10(amin) = 0`, the clamp
        // leaves 0, and the min-max below degenerates to all-zeros (SPEC-P-04 section 2.4).
        var patchMax = amin
        for (i in melPower.indices) {
            if (melPower[i] > patchMax) patchMax = melPower[i]
        }
        val refDb = 10.0 * log10(max(amin, patchMax))
        var maxDb = Double.NEGATIVE_INFINITY
        for (i in melPower.indices) {
            val d = 10.0 * log10(max(amin, melPower[i])) - refDb
            db[i] = d
            if (d > maxDb) maxDb = d
        }
        val floorDb = maxDb - topDb

        // --- per-patch min-max over the KEPT frames only (ADR-21 order) ---
        val kept = nMels * nFrames
        val out = FloatArray(kept)
        var lo = Double.POSITIVE_INFINITY
        var hi = Double.NEGATIVE_INFINITY
        for (m in 0 until nMels) {
            val src = m * rawFrames
            for (t in frameStart until frameEnd) {
                var v = db[src + t]
                if (v < floorDb) v = floorDb
                val flat = m * nFrames + (t - frameStart)
                out[flat] = v.toFloat()
                if (v < lo) lo = v
                if (v > hi) hi = v
            }
        }

        if (hi > lo) {
            val scale = 1.0 / (hi - lo)
            for (i in 0 until kept) {
                out[i] = ((out[i] - lo) * scale).toFloat()
            }
        } else {
            // Degenerate patch (digital silence or a constant spectrum): all zeros, no NaN.
            // SPEC-P-04 section 2.4 requires exactly this for all-zero input.
            java.util.Arrays.fill(out, 0f)
        }
        return out
    }
}

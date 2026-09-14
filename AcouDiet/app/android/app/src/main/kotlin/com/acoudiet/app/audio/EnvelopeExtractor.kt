package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Short-time RMS envelope, computed natively (FF-21h) for `P-07` behaviour analysis.
 *
 * Architecture ruling (API-01 section 7): the Dart side never sees raw PCM, so the
 * per-frame energy has to be produced here and shipped inside the `patch` event. The
 * envelope costs 819 * 4 B = 3.3 KB per event, i.e. about 5 % of the Mel payload, whereas
 * shipping PCM16 would cost 131 KB per event (~40x).
 *
 * Framing parameters live in the SSOT `behavior` block (`envelope_frame_ms` /
 * `envelope_hop_ms` / `envelope_length`) and are shared with `Vad`: this class is the ONLY
 * place that turns them into sample counts, so `P-02` (producer) and `P-07` (consumer)
 * cannot drift apart (SPEC-P-02 acceptance 10).
 *
 * Length rule (FF-21h, literal):
 *   `floor(patch_samples * 1000 / (sample_rate * envelope_hop_ms))` = 819
 * The last frame therefore starts inside the patch but may run past its end; those samples
 * are simply not available and the frame's RMS is taken over the samples that exist. The
 * frozen length 819 wins over "drop the partial frame" (which would give 818).
 */
class EnvelopeExtractor(
    val sampleRate: Int = FeatureConfig.SAMPLE_RATE,
    val frameMs: Int = FeatureConfig.BEHAVIOR_ENVELOPE_FRAME_MS,
    val hopMs: Int = FeatureConfig.BEHAVIOR_ENVELOPE_HOP_MS,
    val length: Int = FeatureConfig.BEHAVIOR_ENVELOPE_LENGTH,
    val patchSamples: Int = FeatureConfig.PATCH_SAMPLES,
) {

    val frameSamples: Int = sampleRate * frameMs / 1000
    val hopSamples: Int = sampleRate * hopMs / 1000

    init {
        require(frameSamples > 0 && hopSamples > 0) { "envelope framing must be positive" }
        val computed = (patchSamples.toLong() * 1000L / (sampleRate.toLong() * hopMs)).toInt()
        require(computed == length) {
            "envelope length mismatch: formula gives $computed, SSOT freezes $length"
        }
    }

    /** Patch-level energy statistics (linear amplitude in `[0,1]`). */
    data class Stats(val rms: Double, val peak: Double)

    /**
     * One pass over the patch: patch RMS, patch peak and the [length]-point envelope.
     * [dest] must have at least [length] entries.
     */
    fun extract(pcm16: ShortArray, dest: FloatArray): Stats {
        val n = pcm16.size
        var sumSq = 0.0
        var peak = 0.0
        for (i in 0 until n) {
            val v = pcm16[i] / Preprocess.PCM16_FULL_SCALE
            sumSq += v * v
            val a = if (v < 0) -v else v
            if (a > peak) peak = a
        }
        val patchRms = if (n > 0) sqrt(sumSq / n) else 0.0

        for (f in 0 until length) {
            val start = f * hopSamples
            val end = min(start + frameSamples, n)
            var acc = 0.0
            var count = 0
            var i = start
            while (i < end) {
                val v = pcm16[i] / Preprocess.PCM16_FULL_SCALE
                acc += v * v
                count++
                i++
            }
            dest[f] = if (count > 0) sqrt(acc / count).toFloat() else 0f
        }
        return Stats(patchRms, peak)
    }

    /** RMS of an arbitrary slice, used for the 10 Hz level events. */
    fun sliceRms(pcm16: ShortArray, from: Int, to: Int): Double {
        val a = max(0, from)
        val b = min(pcm16.size, to)
        if (b <= a) return 0.0
        var acc = 0.0
        for (i in a until b) {
            val v = pcm16[i] / Preprocess.PCM16_FULL_SCALE
            acc += v * v
        }
        return sqrt(acc / (b - a))
    }
}

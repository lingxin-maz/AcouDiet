package com.acoudiet.app.tools

import com.acoudiet.app.audio.MelFrontend
import com.acoudiet.app.audio.Preprocess
import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.WavIo
import java.io.File

/**
 * Offline parity dump: Kotlin side of PLAN-T-08 / SPEC-P-04 acceptance 3 & 4.
 *
 * Reads a wav, extracts a patch of exactly FF-09 samples at [--offset], runs the frozen
 * preprocessing chain and the Mel front end, and writes:
 *   --pre-out : the preprocessed time-domain patch as raw little-endian float32
 *   --mel-out : the row-major Mel tensor as raw little-endian float32 (128 x 128, ADR-21)
 *
 * [--offset] also selects the pre-emphasis boundary: a patch starting at sample 0 of the wav
 * uses predecessor 0.0, any other offset uses the raw sample immediately before the patch.
 * Without that rule the two sides would agree only for offset 0 and drift (silently, and by a
 * growing amount) for every later patch -- which is exactly the boundary case SPEC-P-04's
 * acceptance list asks for.
 *
 * The Python side (`ai/scripts/mel_parity_test.py`) unpacks both with
 * `np.fromfile(path, '<f4')` and asserts `np.allclose(..., atol=1e-3)`. That is the hard
 * gate: if the two languages disagree, no model may be shipped.
 */
object MelDump {

    @JvmStatic
    fun main(args: Array<String>) {
        val opts = HashMap<String, String>()
        var i = 0
        while (i < args.size) {
            val a = args[i]
            if (a.startsWith("--")) {
                val key = a.substring(2)
                val value = if (i + 1 < args.size && !args[i + 1].startsWith("--")) args[++i] else "true"
                opts[key] = value
            }
            i++
        }

        val wavPath = opts["wav"] ?: error("--wav <path> is required")
        val melOut = opts["mel-out"] ?: error("--mel-out <path> is required")
        val preOut = opts["pre-out"]
        val offset = opts["offset"]?.toInt() ?: 0

        val wav = WavIo.read(wavPath)
        if (wav.sampleRate != FeatureConfig.SAMPLE_RATE || wav.channels != 1) {
            error(
                "wav must be ${FeatureConfig.SAMPLE_RATE} Hz mono, got " +
                    "${wav.sampleRate} Hz / ${wav.channels} ch: $wavPath",
            )
        }

        val n = FeatureConfig.PATCH_SAMPLES
        // ADR-21: a patch starting at sample 0 of its source has predecessor 0.0; any later
        // offset must carry the raw sample immediately BEFORE the patch, or the pre-emphasis
        // boundary is wrong and every value downstream drifts.
        if (offset > 0) {
            require(offset - 1 >= 0) { "offset must be >= 0" }
        }
        require(wav.samples.size >= offset + n) {
            "wav holds ${wav.samples.size} samples; need ${offset + n} " +
                "(offset=$offset, patchSamples=$n)"
        }
        val patchPcm = wav.samples.copyOfRange(offset, offset + n)
        val previousRawSample =
            if (offset > 0) wav.samples[offset - 1] / Preprocess.PCM16_FULL_SCALE else 0.0

        val pre = Preprocess.apply(patchPcm, previousRawSample)
        val mel = MelFrontend().compute(pre)

        preOut?.let {
            WavIo.writeFloat32Raw(it, pre)
            println("wrote preprocessed patch ${pre.size} floats -> $it")
        }
        File(melOut).parentFile?.mkdirs()
        WavIo.writeFloat32Raw(melOut, mel)
        println(
            "wrote mel ${FeatureConfig.N_MELS}x${FeatureConfig.N_FRAMES} = ${mel.size} floats -> $melOut",
        )

        var lo = Float.MAX_VALUE
        var hi = -Float.MAX_VALUE
        for (v in mel) { if (v < lo) lo = v; if (v > hi) hi = v }
        println("mel range: [$lo, $hi]  melVersion=${FeatureConfig.MEL_VERSION}")
    }
}

package com.acoudiet.app.tools

import com.acoudiet.app.audio.MelFilterBank
import com.acoudiet.app.audio.PowerSpectrum
import com.acoudiet.app.audio.Preprocess
import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Signals

/** Scratch diagnostics for the Mel chain (development only, not part of any gate). */
object MelDebug {

    @JvmStatic
    fun main(args: Array<String>) {
        val n = FeatureConfig.PATCH_SAMPLES
        val pre = Preprocess.apply(Signals.tone(n, 1000.0))
        var preMax = 0f
        for (v in pre) if (v > preMax) preMax = v
        println("preprocessed max = $preMax")

        // one frame through the power spectrum
        val nFft = FeatureConfig.N_FFT
        val window = MelFilterBank.hannPeriodic(nFft)
        val frame = DoubleArray(nFft) { (pre[it].toDouble() * window[it]) }
        val ps = PowerSpectrum(nFft, FeatureConfig.POWER)
        val out = DoubleArray(nFft / 2 + 1)
        ps.compute(frame, out)
        var psMax = 0.0
        var psArgMax = 0
        for (i in out.indices) if (out[i] > psMax) { psMax = out[i]; psArgMax = i }
        println("power spectrum max = $psMax at bin $psArgMax (${psArgMax * 16000.0 / nFft} Hz)")

        val fb = MelFilterBank(
            FeatureConfig.SAMPLE_RATE, nFft, FeatureConfig.N_MELS,
            FeatureConfig.FMIN.toDouble(), FeatureConfig.FMAX.toDouble(),
            FeatureConfig.MEL_HTK, FeatureConfig.MEL_NORM,
        )
        val melFrame = DoubleArray(FeatureConfig.N_MELS)
        fb.apply(out, melFrame)
        var mMax = 0.0
        var mArg = 0
        for (i in melFrame.indices) if (melFrame[i] > mMax) { mMax = melFrame[i]; mArg = i }
        println("mel frame max = $mMax at band $mArg")
        println("mel band 0 = ${melFrame[0]}, band 20 = ${melFrame[20]}, band 127 = ${melFrame[127]}")
        println("filterbank weight row 0 sum = ${(0 until fb.bins).sumOf { fb.weights[it] }}")
        println("filterbank weight row 20 sum = ${(0 until fb.bins).sumOf { fb.weights[20 * fb.bins + it] }}")
    }
}

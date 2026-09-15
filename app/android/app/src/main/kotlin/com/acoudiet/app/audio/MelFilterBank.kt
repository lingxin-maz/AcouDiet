package com.acoudiet.app.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/**
 * Slaney-scale Mel filter bank, numerically identical to
 * `librosa.filters.mel(sr, n_fft, n_mels, fmin, fmax, htk=False, norm='slaney')`.
 *
 * Why this class exists at all: `mel_htk` / `mel_norm` were four "unfrozen parameters"
 * until ADR-16 froze them (FF-05). A second, hand-tuned filter bank on either side would
 * silently break the `atol = 1e-3` parity gate, so this is a literal transcription of
 * librosa's algorithm -- including the `enorm` Slaney area normalisation.
 *
 * All parameters are injected from the generated constants (never hard-coded).
 */
class MelFilterBank(
    val sampleRate: Int,
    val nFft: Int,
    val nMels: Int,
    val fmin: Double,
    val fmax: Double,
    val htk: Boolean = false,
    val norm: String = "slaney",
) {

    /** Row-major [nMels][nFft/2 + 1] triangular weights. */
    val weights: DoubleArray

    val bins: Int = nFft / 2 + 1

    init {
        require(!htk) { "v1.0 freezes mel_htk = false (ADR-16)" }
        require(norm == "slaney") { "v1.0 freezes mel_norm = slaney (ADR-16)" }
        require(fmin >= 0.0 && fmax > fmin && fmax <= sampleRate / 2.0) {
            "invalid mel frequency range [$fmin, $fmax] for sr=$sampleRate"
        }

        val melMin = hzToMel(fmin)
        val melMax = hzToMel(fmax)
        val melPoints = DoubleArray(nMels + 2) { i ->
            melToHz(melMin + (melMax - melMin) * i / (nMels + 1))
        }

        // fftfreqs = np.linspace(0, sr / 2, 1 + n_fft // 2)
        val fftFreqs = DoubleArray(bins) { i -> (sampleRate / 2.0) * i / (bins - 1) }

        val fdiff = DoubleArray(nMels + 1) { melPoints[it + 1] - melPoints[it] }

        val w = DoubleArray(nMels * bins)
        for (m in 0 until nMels) {
            val lowerDen = fdiff[m]
            val upperDen = fdiff[m + 1]
            for (k in 0 until bins) {
                // ramps[i] = melPoints[i] - fftFreqs[k]
                val lower = -(melPoints[m] - fftFreqs[k]) / lowerDen
                val upper = (melPoints[m + 2] - fftFreqs[k]) / upperDen
                w[m * bins + k] = max(0.0, min(lower, upper))
            }
        }

        // Slaney area normalisation: enorm = 2 / (mel_f[2:n_mels+2] - mel_f[:n_mels])
        for (m in 0 until nMels) {
            val enorm = 2.0 / (melPoints[m + 2] - melPoints[m])
            for (k in 0 until bins) {
                w[m * bins + k] *= enorm
            }
        }
        weights = w
    }

    /** Applies the filter bank to one power spectrum, writing [nMels] values into [out]. */
    fun apply(powerSpectrum: DoubleArray, out: DoubleArray) {
        require(powerSpectrum.size >= bins)
        require(out.size >= nMels)
        for (m in 0 until nMels) {
            var acc = 0.0
            val base = m * bins
            for (k in 0 until bins) {
                val wv = weights[base + k]
                if (wv != 0.0) acc += wv * powerSpectrum[k]
            }
            out[m] = acc
        }
    }

    // ------------------------------------------------------------------ mel scale

    fun hzToMel(freq: Double): Double =
        if (freq < MIN_LOG_HZ) freq / F_SP
        else MIN_LOG_MEL + ln(freq / MIN_LOG_HZ) / LOG_STEP

    fun melToHz(mel: Double): Double =
        if (mel < MIN_LOG_MEL) mel * F_SP
        else MIN_LOG_HZ * exp(LOG_STEP * (mel - MIN_LOG_MEL))

    companion object {
        const val TWO_PI = 2.0 * PI

        // Slaney mel scale (librosa._scale / hz_to_mel with htk=False).
        // These MUST be compile-time constants declared in the companion: property
        // initialisers in the class body run top-to-bottom, so putting them after `init`
        // would leave them at 0.0 while the filter bank is being built (a silent NaN).
        private const val F_SP = 200.0 / 3.0
        private const val MIN_LOG_HZ = 1000.0
        private const val MIN_LOG_MEL = MIN_LOG_HZ / F_SP
        private const val LOG_STEP = 0.06875177742094912 // ln(6.4) / 27.0

        /**
         * Periodic Hann window (scipy `get_window('hann', N, fftbins=True)`), which is what
         * librosa uses by default. Using the symmetric variant instead shifts every frame's
         * spectrum -- a classic parity failure.
         */
        fun hannPeriodic(n: Int): DoubleArray =
            DoubleArray(n) { 0.5 - 0.5 * cos(TWO_PI * it / n) }
    }
}

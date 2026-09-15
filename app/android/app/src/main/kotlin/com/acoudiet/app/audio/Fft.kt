package com.acoudiet.app.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Minimal in-place radix-2 complex FFT.
 *
 * `n_fft = 1024` (FF-03) is a power of two, so the simple Cooley-Tukey form is enough
 * and keeps the numerical behaviour fully deterministic -- which is a hard requirement
 * of the cross-language parity gate (SPEC-T-08 / PLAN-T-08).
 *
 * The tables are built once per instance and reused for every frame; the instance holds
 * no per-patch state, so `MelFrontend` stays a pure function of its input (SPEC-P-04
 * section 2.3).
 */
class Fft(val n: Int) {

    init {
        require(n > 0 && (n and (n - 1)) == 0) { "n_fft must be a power of two, got $n" }
    }

    private val cosTable = DoubleArray(n / 2) { cos(2.0 * PI * it / n) }
    private val sinTable = DoubleArray(n / 2) { sin(2.0 * PI * it / n) }

    /** Bit-reversal permutation indices. */
    private val rev = IntArray(n).also { r ->
        val bits = Integer.numberOfTrailingZeros(n)
        for (i in 0 until n) r[i] = Integer.reverse(i) ushr (32 - bits)
    }

    /**
     * Forward FFT of [re] (imaginary part assumed zero). Result written in place.
     * Callers must pass scratch arrays they own.
     */
    fun forward(re: DoubleArray, im: DoubleArray) {
        require(re.size == n && im.size == n) { "fft buffers must have length $n" }

        for (i in 0 until n) {
            val j = rev[i]
            if (j > i) {
                val tr = re[i]; re[i] = re[j]; re[j] = tr
                val ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }

        var len = 2
        while (len <= n) {
            val half = len / 2
            val step = n / len
            var i = 0
            while (i < n) {
                var j = 0
                var k = 0
                while (j < half) {
                    val wr = cosTable[k]
                    val wi = -sinTable[k]
                    val a = i + j
                    val b = a + half
                    val xr = re[b] * wr - im[b] * wi
                    val xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr
                    im[b] = im[a] - xi
                    re[a] += xr
                    im[a] += xi
                    j++
                    k += step
                }
                i += len
            }
            len = len shl 1
        }
    }
}

/**
 * Real-input power spectrum helper: |X|^power for the non-redundant half of the spectrum.
 * `power = 2.0` (FF-06) is the only supported exponent in v1.0 but the parameter is kept
 * explicit so the SSOT value is threaded through instead of hard-coded here.
 */
class PowerSpectrum(val nFft: Int, val power: Double) {

    private val fft = Fft(nFft)
    private val re = DoubleArray(nFft)
    private val im = DoubleArray(nFft)

    val bins: Int get() = nFft / 2 + 1

    /** Writes |X|^power for bins 0..nFft/2 into [out]; returns [out]. */
    fun compute(frame: DoubleArray, out: DoubleArray): DoubleArray {
        require(frame.size == nFft) { "frame length must be $nFft" }
        require(out.size >= bins) { "out length must be >= $bins" }

        for (i in 0 until nFft) {
            re[i] = frame[i]
            im[i] = 0.0
        }
        fft.forward(re, im)

        for (k in 0 until bins) {
            val p = re[k] * re[k] + im[k] * im[k]
            out[k] = if (power == 2.0) p else Math.pow(p, power / 2.0)
        }
        return out
    }
}

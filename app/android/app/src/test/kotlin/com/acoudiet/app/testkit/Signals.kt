package com.acoudiet.app.testkit

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import kotlin.random.Random

/** Deterministic test signals (no wall-clock, no ambient randomness). */
object Signals {

    fun silence(n: Int): ShortArray = ShortArray(n)

    fun impulse(n: Int, at: Int = 0, amplitude: Int = 20000): ShortArray {
        val x = ShortArray(n)
        x[at] = amplitude.toShort()
        return x
    }

    fun tone(n: Int, freq: Double, sampleRate: Int = 16000, amplitude: Double = 0.4): ShortArray {
        val x = ShortArray(n)
        for (i in 0 until n) {
            x[i] = (amplitude * 32767.0 * sin(2.0 * PI * freq * i / sampleRate)).toInt().toShort()
        }
        return x
    }

    fun whiteNoise(n: Int, seed: Int = 12345, amplitude: Double = 0.2): ShortArray {
        val rnd = Random(seed)
        val x = ShortArray(n)
        for (i in 0 until n) {
            x[i] = ((rnd.nextDouble() * 2.0 - 1.0) * amplitude * 32767.0).toInt().toShort()
        }
        return x
    }

    /** Band-limited "chewing-like" bursts: an exponentially decaying click train. */
    fun chewBursts(
        n: Int,
        intervalMs: Int,
        sampleRate: Int = 16000,
        seed: Int = 7,
    ): ShortArray {
        val x = ShortArray(n)
        val step = sampleRate * intervalMs / 1000
        val rnd = Random(seed)
        var start = 0
        while (start < n) {
            val decay = 0.004 * sampleRate
            var i = 0
            while (i < 600 && start + i < n) {
                val env = exp(-i / decay)
                val v = env * sin(2.0 * PI * 1800.0 * i / sampleRate) * 0.7
                val jitter = 1.0 + (rnd.nextDouble() - 0.5) * 0.05
                x[start + i] = (v * jitter * 32767.0).toInt().coerceIn(-32768, 32767).toShort()
                i++
            }
            start += step
        }
        return x
    }
}

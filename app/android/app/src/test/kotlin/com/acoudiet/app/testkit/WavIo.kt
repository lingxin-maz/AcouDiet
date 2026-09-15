package com.acoudiet.app.testkit

import java.io.File

/**
 * Minimal RIFF/WAVE reader plus PCM16 writer, used by the offline parity tooling and the
 * JVM test suite. Deliberately dependency-free.
 *
 * Only the frozen format is accepted (FF-01: 16 kHz, mono, PCM16); anything else is
 * rejected loudly rather than silently resampled -- SPEC-P-03 section 1.3 forbids
 * resampling on the device, and the offline side must not paper over a mismatched file.
 */
object WavIo {

    data class Wav(val sampleRate: Int, val channels: Int, val samples: ShortArray)

    fun read(path: String): Wav {
        val bytes = File(path).readBytes()
        require(bytes.size > 44) { "not a wav: $path" }
        require(bytes[0] == 'R'.code.toByte() && bytes[1] == 'I'.code.toByte()) {
            "missing RIFF header: $path"
        }

        var pos = 12
        var fmtFound = false
        var audioFormat = 1
        var channels = 1
        var sampleRate = 16000
        var bitsPerSample = 16
        var data: ByteArray? = null

        while (pos + 8 <= bytes.size) {
            val id = String(bytes, pos, 4, Charsets.US_ASCII)
            val size = leInt(bytes, pos + 4)
            val body = pos + 8
            when (id) {
                "fmt " -> {
                    audioFormat = leShort(bytes, body).toInt()
                    channels = leShort(bytes, body + 2).toInt()
                    sampleRate = leInt(bytes, body + 4)
                    bitsPerSample = leShort(bytes, body + 14).toInt()
                    fmtFound = true
                }
                "data" -> data = bytes.copyOfRange(body, minOf(body + size, bytes.size))
            }
            pos = body + size + (size and 1)
        }

        require(fmtFound) { "no fmt chunk: $path" }
        require(audioFormat == 1) { "only PCM is supported (format=$audioFormat): $path" }
        require(bitsPerSample == 16) { "only 16-bit PCM is supported: $path" }
        val payload = data ?: error("no data chunk: $path")

        val n = payload.size / 2
        val samples = ShortArray(n)
        for (i in 0 until n) {
            val lo = payload[2 * i].toInt() and 0xFF
            val hi = payload[2 * i + 1].toInt()
            samples[i] = ((hi shl 8) or lo).toShort()
        }
        return Wav(sampleRate, channels, samples)
    }

    /** Writes 32-bit little-endian floats (raw, no header) -- the parity interchange format. */
    fun writeFloat32Raw(path: String, values: FloatArray) {
        val out = ByteArray(values.size * 4)
        val bb = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        for (v in values) bb.putFloat(v)
        File(path).parentFile?.mkdirs()
        File(path).writeBytes(out)
    }

    fun writeInt16Raw(path: String, values: ShortArray) {
        val out = ByteArray(values.size * 2)
        val bb = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        for (v in values) bb.putShort(v)
        File(path).parentFile?.mkdirs()
        File(path).writeBytes(out)
    }

    private fun leInt(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8) or
            ((b[off + 2].toInt() and 0xFF) shl 16) or ((b[off + 3].toInt() and 0xFF) shl 24)

    private fun leShort(b: ByteArray, off: Int): Short =
        ((b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)).toShort()
}

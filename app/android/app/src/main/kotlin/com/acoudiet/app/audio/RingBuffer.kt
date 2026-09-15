package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig

/**
 * Fixed-capacity ring buffer of PCM16 samples (SPEC-P-01).
 *
 * Capacity is exactly FF-09 (`patch_samples`), so one snapshot is one model patch.
 * Nothing here ever touches the file system: FF-24 item 1 forbids persisting audio,
 * and this buffer is the only place raw samples live (besides the AudioRecord copy).
 *
 * Implementation notes:
 *  * `write` overwrites the oldest samples when full (required by SPEC-P-01 acceptance #4).
 *  * `snapshot` always returns samples in chronological order (oldest first), which is
 *    what MelFrontend expects.
 *  * No allocation on the audio thread: `snapshot` writes into a caller-owned array.
 */
class RingBuffer(val capacity: Int = FeatureConfig.PATCH_SAMPLES) {

    private val buf = ShortArray(capacity)

    /** Index the next sample will be written to. */
    private var head = 0

    /** Total samples written since construction (monotonic, may exceed capacity). */
    var totalWritten: Long = 0L
        private set

    /** Samples currently held; saturates at [capacity]. */
    val size: Int
        get() = if (totalWritten >= capacity) capacity else totalWritten.toInt()

    val isFull: Boolean
        get() = totalWritten >= capacity

    /** Clears contents without reallocating (used on session restart). */
    fun reset() {
        head = 0
        totalWritten = 0L
        java.util.Arrays.fill(buf, 0)
    }

    /** Writes [length] samples from [src] starting at [offset]. */
    fun write(src: ShortArray, offset: Int = 0, length: Int = src.size) {
        require(offset >= 0 && length >= 0 && offset + length <= src.size) {
            "write out of bounds: offset=$offset length=$length size=${src.size}"
        }
        var h = head
        for (i in 0 until length) {
            buf[h] = src[offset + i]
            h++
            if (h == capacity) h = 0
        }
        head = h
        totalWritten += length
    }

    fun write(value: Short) {
        buf[head] = value
        head++
        if (head == capacity) head = 0
        totalWritten++
    }

    /**
     * Copies the most recent [dest].size samples into [dest], oldest first.
     * Returns false when fewer than [dest].size samples have ever been written
     * (SPEC-P-01 section 2.4: a session shorter than FF-09 emits no patch at all).
     */
    fun snapshot(dest: ShortArray): Boolean {
        if (totalWritten < dest.size) return false
        val n = dest.size
        // oldest sample of the window
        var start = head - n
        if (start < 0) start += capacity
        var s = start
        for (i in 0 until n) {
            dest[i] = buf[s]
            s++
            if (s == capacity) s = 0
        }
        return true
    }

    /** Most recent [count] samples as a new array (diagnostics/tests only). */
    fun tail(count: Int): ShortArray {
        val n = minOf(count, size)
        val out = ShortArray(n)
        var start = head - n
        if (start < 0) start += capacity
        var s = start
        for (i in 0 until n) {
            out[i] = buf[s]
            s++
            if (s == capacity) s = 0
        }
        return out
    }
}

package com.acoudiet.app.android

import android.content.Context
import java.io.File

/**
 * `clearTempAudio` (API-01 section 2.7) and the `tempAudioFiles` diagnostic.
 *
 * FF-24 item 2 requires `cacheDir` to be free of `audio_*` files at cold start and after
 * every session. v1.0 never writes such a file -- this class exists so the privacy claim is
 * *verifiable* rather than merely asserted: the self-check panel reads the same counter the
 * acceptance test asserts on, and a future regression that starts writing audio would show
 * up immediately.
 *
 * Failures never block the main flow: SPEC / API-01 defines `ACD-IO-001` as non-retryable
 * and log-only, and the returned count reflects what was actually deleted.
 */
class TempAudioAndroid(private val context: Context) {

    private fun tempDir(): File = context.cacheDir

    private fun matches(f: File): Boolean = f.isFile && f.name.startsWith(AUDIO_PREFIX)

    fun count(): Int {
        val dir = tempDir()
        val files = dir.listFiles() ?: return 0
        return files.count { matches(it) }
    }

    /** @return `filesDeleted` per API-01 section 2.7. */
    fun clear(): Int {
        val dir = tempDir()
        val files = dir.listFiles() ?: return 0
        var deleted = 0
        for (f in files) {
            if (!matches(f)) continue
            try {
                if (f.delete()) deleted++
            } catch (_: Throwable) {
                // ACD-IO-001: log only; the returned count stays honest.
            }
        }
        return deleted
    }

    /** Detailed result for the bridge's method reply. */
    fun clearDetailed(): Map<String, Any?> {
        val before = count()
        var freed = 0L
        val dir = tempDir()
        (dir.listFiles() ?: emptyArray()).forEach { if (matches(it)) freed += it.length() }
        val deleted = clear()
        return linkedMapOf(
            "filesDeleted" to deleted,
            "bytesFreed" to freed,
            "failed" to (before - deleted).coerceAtLeast(0),
        )
    }

    companion object {
        /** The single, authoritative `audio_*` prefix (FF-24 item 2). */
        const val AUDIO_PREFIX = "audio_"
    }
}

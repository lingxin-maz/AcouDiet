package com.acoudiet.app.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import com.acoudiet.app.audio.AcouDietException
import com.acoudiet.app.config.FeatureConfig

/**
 * `AudioRecord` capture thread (SPEC-P-01).
 *
 * Responsibilities, and nothing else:
 *  * own the dedicated native background thread (`API-00` section 3.7 requires the audio
 *    path never to run on the main thread),
 *  * pull FF-04-sized blocks (512 samples) and hand them to [onSamples] on that thread,
 *  * report device failures as `ACD-AUD-001` / `ACD-AUD-002`.
 *
 * Everything downstream (ring buffer, VAD, envelope, Mel, events) lives in
 * [AudioBridgeAndroid] so that the DSP stays free of Android types and unit-testable.
 *
 * `AudioSource.MIC` is used deliberately: `VOICE_RECOGNITION` and `UNPROCESSED` apply
 * vendor AGC/NS which would make the device input differ from the training corpus
 * (SPEC-P-01 section 10 item 2 keeps this as an open question; MIC is the conservative
 * choice and is recorded in `appliedConfig`).
 */
class AudioCaptureAndroid(
    private val onSamples: (ShortArray, Int) -> Unit,
    private val onError: (AcouDietException) -> Unit,
) {

    private var record: AudioRecord? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    @Volatile
    private var running = false

    val isActive: Boolean get() = running

    val audioSourceName: String = "MIC"

    /** Opens and starts the recorder. Throws [AcouDietException] on any device failure. */
    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return

        val sampleRate = FeatureConfig.SAMPLE_RATE
        val channelMask = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBytes = AudioRecord.getMinBufferSize(sampleRate, channelMask, encoding)
        if (minBytes <= 0) {
            throw AcouDietException.audioRecordInitFailed("getMinBufferSize=$minBytes")
        }

        // Comfortably larger than one hop so a scheduling hiccup does not drop audio.
        val bufferBytes = maxOf(minBytes, FeatureConfig.PATCH_SAMPLES * 2 / 4)

        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC, sampleRate, channelMask, encoding, bufferBytes,
            )
        } catch (t: Throwable) {
            throw AcouDietException.audioRecordInitFailed(t.message)
        }

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            // STATE_INITIALIZED == false almost always means the mic is taken or absent.
            throw AcouDietException.audioDeviceBusy()
        }

        try {
            rec.startRecording()
        } catch (t: Throwable) {
            rec.release()
            throw AcouDietException.audioRecordInitFailed(t.message)
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            throw AcouDietException.audioDeviceBusy()
        }

        record = rec
        running = true

        val ht = HandlerThread("acoudiet-audio").also { it.start() }
        thread = ht
        val h = Handler(ht.looper)
        handler = h
        h.post(captureLoop)
    }

    private val captureLoop = object : Runnable {
        private val block = ShortArray(FeatureConfig.HOP_LENGTH)
        private var consecutiveErrors = 0

        override fun run() {
            if (!running) return
            val rec = record ?: return
            val read = try {
                rec.read(block, 0, block.size)
            } catch (t: Throwable) {
                -1
            }
            if (read > 0) {
                consecutiveErrors = 0
                onSamples(block, read)
            } else {
                consecutiveErrors++
                // A single short read is normal; a sustained failure means the device is gone.
                if (consecutiveErrors >= 50) {
                    running = false
                    onError(AcouDietException.audioDeviceBusy())
                    return
                }
            }
            handler?.post(this)
        }
    }

    fun stop() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        handler = null
        thread?.quitSafely()
        thread = null
        record?.let {
            try {
                if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) it.stop()
            } catch (_: Throwable) {
                // ignored: we are tearing down
            }
            it.release()
        }
        record = null
    }

    /**
     * Pause keeps `AudioRecord` running (no re-initialisation glitch, buffer stays
     * continuous) and only stops patch emission -- API-01 section 2.4.
     */
    fun pause() {
        paused = true
    }

    fun resume() {
        paused = false
    }

    @Volatile
    var paused: Boolean = false
        private set
}

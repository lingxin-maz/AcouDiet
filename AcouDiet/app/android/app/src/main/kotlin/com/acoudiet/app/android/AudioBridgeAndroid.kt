package com.acoudiet.app.android

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import com.acoudiet.app.audio.AcouDietException
import com.acoudiet.app.audio.EnvelopeExtractor
import com.acoudiet.app.audio.MelFrontend
import com.acoudiet.app.audio.Preprocess
import com.acoudiet.app.audio.RingBuffer
import com.acoudiet.app.audio.SessionStateMachine
import com.acoudiet.app.audio.Vad
import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.config.NativeCapabilities
import java.util.ArrayDeque
import kotlin.math.roundToInt

/**
 * L1 bridge: the native side of `API-01`.
 *
 * Holds the session, the ring buffer, the DSP chain and the event emission, and decides
 * nothing about business rules (no inference, no database, no thresholds beyond the frozen
 * ones). Everything here is *plumbing*: the numerically interesting parts delegate to the
 * Android-free classes in `com.acoudiet.app.audio`, which are covered by the JVM suite.
 *
 * Key contract points implemented here:
 *  * 10 Hz `level` events and 2 Hz `patch` events (FF-12);
 *  * patch emission every `inference_hop_seconds` over a full FF-09 window;
 *  * drop-oldest backpressure driven by `ackPatch`, never blocking the capture thread;
 *  * silent patches are still delivered, and still carry `rmsEnvelope` (FF-21h);
 *  * `skipAudioRecord` sessions (Demo Mode B) need no permission and never open a mic;
 *  * `getDiagnostics` exposes exactly what `M-04` needs to tell "mic problem" from
 *    "model problem".
 */
class AudioBridgeAndroid(private val context: Context) {

    // ------------------------------------------------------------------ collaborators

    private val main = Handler(Looper.getMainLooper())
    private val sm = SessionStateMachine()
    // One sample MORE than a patch: `snapshot` then yields the patch plus the single raw sample
    // immediately preceding it, which is the pre-emphasis boundary ADR-21 froze (FF-02). At
    // session start a zero sample is seeded, which is the frozen "zero at source start" case --
    // so the first patch is exactly samples [0, FF-09) with predecessor 0.0, and every later
    // patch gets its genuine predecessor for free, with no cross-patch bookkeeping to get wrong.
    private val ring = RingBuffer(FeatureConfig.PATCH_SAMPLES + 1)
    private val envelope = EnvelopeExtractor()
    private val mel = MelFrontend()
    private val preSkill = Preprocess

    private var vad: Vad? = null
    private var capture: AudioCaptureAndroid? = null

    /** EventChannel sink; null when Dart has not subscribed. */
    @Volatile
    private var eventSink: ((Map<String, Any?>) -> Unit)? = null

    @Volatile
    private var subscribedSessionId: String? = null

    // ------------------------------------------------------------------ session state

    private var startedAtMs = 0L
    private var stoppedAtMs = 0L
    private var includeEnvelope = true
    private var skipAudioRecord = false
    private var silenceEndSeconds = FeatureConfig.BEHAVIOR_MEAL_END_SILENCE_SECONDS

    private var patchSeq = 0
    private var patchesEmitted = 0
    private var patchesVoiced = 0
    private var droppedPatches = 0
    private var lastEmittedSeq = -1
    private var lastAckedSeq = -1
    private var firstVoicedAtMs: Long? = null
    private var lastVoicedAtMs: Long? = null

    private var samplesSincePatch = 0
    private var samplesSinceLevel = 0
    private val patchHopSamples =
        (FeatureConfig.SAMPLE_RATE * FeatureConfig.INFERENCE_HOP_SECONDS).roundToInt()
    private val levelIntervalSamples = FeatureConfig.SAMPLE_RATE / NativeCapabilities.LEVEL_EVENT_HZ

    /** Patch window (+1 predecessor sample) and working buffers, allocated once per session. */
    private var patchWindow: ShortArray? = null
    private var patchBody: ShortArray? = null
    private var patchEnv: FloatArray? = null

    /** Session RMS samples for `SessionSummary.rmsStats` (bounded, for p95). */
    private val rmsHistory = ArrayDeque<Double>()
    private var rmsSum = 0.0
    private var rmsPeak = 0.0

    /** Injection (Demo Mode B) queue. */
    private val injectQueue = ArrayDeque<ShortArray>()
    private var injectIsLast = false

    private var lastError: String? = null

    /** Model info, filled in by Dart after InferenceEngine.load() (API-01 section 2.8). */
    private var modelVersion: String? = null
    private var modelNFrames: Int? = null

    fun attachSink(s: ((Map<String, Any?>) -> Unit)?) {
        eventSink = s
    }

    fun setSubscription(sessionId: String?) {
        subscribedSessionId = sessionId
    }

    /**
     * Releases the sink and the session filter, but only when [sessionId] is the session that
     * owns them.
     *
     * `onCancel` is not synchronised with the next `onListen`: the Dart side tears its old
     * subscriptions down asynchronously, so a late `cancel` carrying the previous session id
     * can arrive *after* a new session has already subscribed. Clearing unconditionally there
     * would silence a live session -- the microphone would be open with no `level` and no
     * `patch` events, which is exactly the "detected once, then nothing" failure. A `null`
     * [sessionId] (an unparameterised cancel) still clears, as `API-01` section 3.1 requires.
     */
    @Synchronized
    fun clearSubscription(sessionId: String?) {
        val current = subscribedSessionId
        if (sessionId != null && current != null && sessionId != current) return
        subscribedSessionId = null
        eventSink = null
    }

    // ------------------------------------------------------------------ permissions

    fun hasRecordPermission(): Boolean =
        context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    // ------------------------------------------------------------------ session control

    @Synchronized
    fun startSession(params: Map<String, Any?>): Map<String, Any?> {
        val id = params["sessionId"] as? String
            ?: throw AcouDietException.sessionNotFound("null")
        val requestedSkip = params["skipAudioRecord"] as? Boolean ?: false
        val requestedEnvelope = params["includeEnvelope"] as? Boolean ?: true
        val requestedDenoise = params["enableDenoise"] as? Boolean ?: false
        val requestedSilence = (params["silenceEndSeconds"] as? Number)?.toInt()
            ?: FeatureConfig.BEHAVIOR_MEAL_END_SILENCE_SECONDS
        val requestedAutoEnd = params["autoEndOnSilence"] as? Boolean ?: true

        sm.startSession(id)
        startedAtMs = System.currentTimeMillis()
        skipAudioRecord = requestedSkip
        includeEnvelope = requestedEnvelope
        silenceEndSeconds =
            if (requestedAutoEnd) requestedSilence else Int.MAX_VALUE / 1000

        if (requestedDenoise) {
            // Spectral subtraction has no frozen parameters; SPEC-P-03 section 6 forbids
            // silently downgrading to "off".
            sm.recover()
            throw AcouDietException.cfgMismatch(
                "enableDenoise", "parameters present", "missing from feature_config",
            )
        }

        resetSessionCounters()
        ring.reset()
        // Seed the predecessor slot with silence: the first patch then begins at source start
        // with `previousRawSample = 0.0`, exactly as FF-02 (ADR-21) requires.
        ring.write(0.toShort())
        patchWindow = ShortArray(FeatureConfig.PATCH_SAMPLES + 1)
        patchBody = ShortArray(FeatureConfig.PATCH_SAMPLES)
        patchEnv = FloatArray(envelope.length)
        vad = Vad(silenceEndSeconds = silenceEndSeconds)
        injectQueue.clear()
        injectIsLast = false
        lastError = null

        var audioActive = false
        if (!skipAudioRecord) {
            if (!hasRecordPermission()) {
                sm.recover()
                throw AcouDietException.permDenied()
            }
            val cap = AudioCaptureAndroid(
                onSamples = ::onMicSamples,
                onError = { e -> onCaptureError(e) },
            )
            try {
                cap.start()
            } catch (e: AcouDietException) {
                sm.recover()
                throw e
            }
            capture = cap
            audioActive = true
        }

        sm.onStarted()

        return linkedMapOf(
            "sessionId" to id,
            "startedAtMs" to startedAtMs,
            "appliedConfig" to linkedMapOf(
                "melVersion" to FeatureConfig.MEL_VERSION,
                "sampleRate" to FeatureConfig.SAMPLE_RATE,
                "nFft" to FeatureConfig.N_FFT,
                "hopLength" to FeatureConfig.HOP_LENGTH,
                "nMels" to FeatureConfig.N_MELS,
                "rawMelFrames" to FeatureConfig.RAW_MEL_FRAMES,
                "nFrames" to FeatureConfig.N_FRAMES,
                "patchSamples" to FeatureConfig.PATCH_SAMPLES,
                "preemphasisBoundary" to FeatureConfig.PREEMPHASIS_BOUNDARY,
                "powerToDbRef" to FeatureConfig.POWER_TO_DB_REF,
                "topDb" to FeatureConfig.TOP_DB,
                "normalization" to FeatureConfig.NORMALIZATION,
                "includeEnvelope" to includeEnvelope,
                "skipAudioRecord" to skipAudioRecord,
                "audioSource" to (capture?.audioSourceName ?: "none"),
            ),
            "denoiseEnabled" to false,
            "envelopeHopMs" to envelope.hopMs,
            "envelopeLength" to envelope.length,
            "audioRecordActive" to audioActive,
        )
    }

    @Synchronized
    fun pauseSession(params: Map<String, Any?>): Map<String, Any?> {
        val id = params["sessionId"] as? String ?: ""
        sm.pause(id)
        capture?.pause()
        return linkedMapOf("pausedAtMs" to System.currentTimeMillis(), "state" to sm.state.name)
    }

    @Synchronized
    fun resumeSession(params: Map<String, Any?>): Map<String, Any?> {
        val id = params["sessionId"] as? String ?: ""
        sm.resume(id)
        capture?.resume()
        // API-01 section 2.4: the first patch after resuming is a full FF-09 window, and the
        // silence accumulator keeps its value (pause neither resets nor accumulates it).
        return linkedMapOf("resumedAtMs" to System.currentTimeMillis(), "state" to sm.state.name)
    }

    @Synchronized
    fun stopSession(params: Map<String, Any?>): Map<String, Any?> {
        val id = params["sessionId"] as? String ?: ""
        sm.stop(id)
        stoppedAtMs = System.currentTimeMillis()
        capture?.stop()
        capture = null
        val summary = buildSummary("userStop")
        emit(
            linkedMapOf(
                "type" to "sessionEnded",
                "sessionId" to id,
                "tMs" to stoppedAtMs,
                "reason" to "userStop",
                "code" to null,
                "summary" to summary,
            ),
        )
        return summary
    }

    private fun onCaptureError(e: AcouDietException) {
        lastError = e.code
        capture?.stop()
        capture = null
        if (sm.isActive()) {
            try {
                sm.onStartFailed()
            } catch (_: Throwable) {
                // already terminal
            }
            stoppedAtMs = System.currentTimeMillis()
            val id = sm.sessionId
            emit(
                linkedMapOf(
                    "type" to "sessionEnded",
                    "sessionId" to id,
                    "tMs" to stoppedAtMs,
                    "reason" to "error",
                    "code" to e.code,
                    "summary" to buildSummary("error"),
                ),
            )
            sm.recover()
        }
    }

    private fun resetSessionCounters() {
        patchSeq = 0
        patchesEmitted = 0
        patchesVoiced = 0
        droppedPatches = 0
        lastEmittedSeq = -1
        lastAckedSeq = -1
        firstVoicedAtMs = null
        lastVoicedAtMs = null
        samplesSincePatch = 0
        samplesSinceLevel = 0
        rmsHistory.clear()
        rmsSum = 0.0
        rmsPeak = 0.0
    }

    // ------------------------------------------------------------------ audio path

    private fun onMicSamples(block: ShortArray, read: Int) {
        if (!sm.isActive()) return
        if (capture?.paused == true) {
            // AudioRecord keeps running so the window stays continuous; we just do not emit.
            ring.write(block, 0, read)
            return
        }
        feedAudio(block, read)
    }

    /** Shared by the microphone path and `injectPcm`, so both produce identical events. */
    private fun feedAudio(block: ShortArray, read: Int) {
        ring.write(block, 0, read)

        // 10 Hz level events (diagnostic only -- `rms` never drives a business decision).
        samplesSinceLevel += read
        if (samplesSinceLevel >= levelIntervalSamples) {
            samplesSinceLevel = 0
            val tail = ring.tail(levelIntervalSamples)
            val rms = envelope.sliceRms(tail, 0, tail.size)
            var peak = 0.0
            for (s in tail) {
                val v = Math.abs(s / Preprocess.PCM16_FULL_SCALE)
                if (v > peak) peak = v
            }
            val voiced = rms > (vad?.threshold ?: Double.MAX_VALUE)
            emit(
                linkedMapOf(
                    "type" to "level",
                    "sessionId" to sm.sessionId,
                    "tMs" to System.currentTimeMillis(),
                    "rms" to rms,
                    "peak" to peak,
                    "voiced" to voiced,
                ),
            )
        }

        // 2 Hz patch events: a full FF-09 window every inference_hop_seconds.
        samplesSincePatch += read
        while (samplesSincePatch >= patchHopSamples) {
            samplesSincePatch -= patchHopSamples
            maybeEmitPatch()
        }
    }

    private fun maybeEmitPatch() {
        val window = patchWindow ?: return
        if (!ring.snapshot(window)) return // session shorter than FF-09: no patch at all

        // Backpressure (API-01 section 3.3): drop-oldest, never block the audio thread.
        if (lastAckedSeq < lastEmittedSeq) {
            droppedPatches++
            return
        }

        // window[0] is the raw sample immediately before the patch; the patch is the rest.
        val pcm = patchBody ?: ShortArray(FeatureConfig.PATCH_SAMPLES).also { patchBody = it }
        System.arraycopy(window, 1, pcm, 0, FeatureConfig.PATCH_SAMPLES)
        val previousRawSample = window[0] / Preprocess.PCM16_FULL_SCALE

        // The envelope buffer is allocated per session; if a caller ever reaches here without
        // one, allocate it now rather than passing a zero-length destination (which would
        // throw inside `extract`). The VAD and the envelope come from the SAME framing pass
        // (FF-21h), so the stats and the envelope must always be produced together.
        val env = patchEnv ?: FloatArray(envelope.length).also { patchEnv = it }
        val stats = envelope.extract(pcm, env)
        val voiced = vad?.evaluate(stats.rms) ?: true
        val now = System.currentTimeMillis()

        if (voiced) {
            patchesVoiced++
            if (firstVoicedAtMs == null) firstVoicedAtMs = now
            lastVoicedAtMs = now
        } else if (vad?.shouldEndSession() == true) {
            autoEndOnSilence()
        }

        // Session statistics (raw PCM, matching P-02's VAD domain -- SPEC-P-03 section 10.6).
        rmsSum += stats.rms
        if (stats.peak > rmsPeak) rmsPeak = stats.peak
        if (rmsHistory.size >= 4096) rmsHistory.removeFirst()
        rmsHistory.addLast(stats.rms)

        val melTensor = mel.compute(preSkill.apply(pcm, previousRawSample))
        val seq = patchSeq++
        val tEnd = now
        val tStart = tEnd - FeatureConfig.PATCH_SAMPLES * 1000L / FeatureConfig.SAMPLE_RATE

        val event = linkedMapOf<String, Any?>(
            "type" to "patch",
            "sessionId" to sm.sessionId,
            "seq" to seq,
            "tStartMs" to tStart,
            "tEndMs" to tEnd,
            "melVersion" to FeatureConfig.MEL_VERSION,
            "nMels" to FeatureConfig.N_MELS,
            "nFrames" to FeatureConfig.N_FRAMES,
            "mel" to melTensor,
            "rms" to stats.rms,
            "voiced" to voiced,
            "source" to if (skipAudioRecord) "inject" else "mic",
        )
        if (includeEnvelope) {
            event["rmsEnvelope"] = env
            event["envelopeHopMs"] = envelope.hopMs
        }

        lastEmittedSeq = seq
        patchesEmitted++
        emit(event)
    }

    private fun autoEndOnSilence() {
        capture?.stop()
        capture = null
        stoppedAtMs = System.currentTimeMillis()
        val id = sm.sessionId
        sm.endOnSilence()
        emit(
            linkedMapOf(
                "type" to "sessionEnded",
                "sessionId" to id,
                "tMs" to stoppedAtMs,
                "reason" to "silence90s",
                "code" to null,
                "summary" to buildSummary("silence90s"),
            ),
        )
    }

    private fun buildSummary(reason: String): Map<String, Any?> {
        val sorted = rmsHistory.sorted()
        val p95 = if (sorted.isEmpty()) 0.0 else sorted[((sorted.size - 1) * 0.95).toInt()]
        val mean = if (rmsHistory.isEmpty()) 0.0 else rmsSum / rmsHistory.size
        return linkedMapOf(
            "sessionId" to sm.sessionId,
            "startedAtMs" to startedAtMs,
            "stoppedAtMs" to stoppedAtMs,
            "durationMs" to (stoppedAtMs - startedAtMs),
            "patchesEmitted" to patchesEmitted,
            "patchesVoiced" to patchesVoiced,
            "droppedPatches" to droppedPatches,
            "firstVoicedAtMs" to firstVoicedAtMs,
            "lastVoicedAtMs" to lastVoicedAtMs,
            "endReason" to reason,
            "rmsStats" to linkedMapOf(
                "mean" to mean,
                "p95" to p95,
                "peak" to rmsPeak,
            ),
        )
    }

    private fun emit(event: Map<String, Any?>) {
        val sid = event["sessionId"]
        val subscribed = subscribedSessionId
        if (subscribed != null && sid != subscribed) return
        val s = eventSink ?: return
        main.post { s(event) }
    }

    // ------------------------------------------------------------------ injection

    /**
     * Demo Mode B. The wav is decoded by Dart and pushed straight into the ring buffer --
     * never played through a speaker and re-recorded (API-01 section 2.6 forbids that).
     */
    @Synchronized
    fun injectPcm(params: Map<String, Any?>): Map<String, Any?> {
        val id = params["sessionId"] as? String ?: ""
        if (sm.sessionId != id) throw AcouDietException.sessionNotFound(id)
        val bytes = params["pcm16"] as? ByteArray
            ?: throw AcouDietException.injectionFailed("pcm16 missing")
        if (bytes.size % 2 != 0) throw AcouDietException.injectionFailed("odd byte count")
        val isLast = params["isLast"] as? Boolean ?: false
        val realtime = params["feedRealtime"] as? Boolean ?: true

        val samples = ShortArray(bytes.size / 2)
        for (i in samples.indices) {
            val lo = bytes[2 * i].toInt() and 0xFF
            val hi = bytes[2 * i + 1].toInt()
            samples[i] = ((hi shl 8) or lo).toShort()
        }

        if (realtime) {
            injectQueue.addLast(samples)
            injectIsLast = injectIsLast || isLast
            scheduleInjection()
        } else {
            feedAudio(samples, samples.size)
            if (isLast) drainInjection()
        }
        return linkedMapOf(
            "acceptedSamples" to samples.size,
            "bufferedSamples" to ring.size,
        )
    }

    private val injectionTicker = object : Runnable {
        override fun run() {
            if (!sm.isActive()) return
            val next = injectQueue.pollFirst()
            if (next != null) {
                feedAudio(next, next.size)
                main.postDelayed(this, next.size * 1000L / FeatureConfig.SAMPLE_RATE)
            } else if (injectIsLast) {
                injectIsLast = false
                main.postDelayed({ stopFromInjection() }, 300)
            }
        }
    }

    private fun scheduleInjection() {
        main.removeCallbacks(injectionTicker)
        main.post(injectionTicker)
    }

    private fun drainInjection() {
        while (injectQueue.isNotEmpty()) {
            val next = injectQueue.pollFirst()!!
            feedAudio(next, next.size)
        }
    }

    private fun stopFromInjection() {
        if (!sm.isActive()) return
        val id = sm.sessionId ?: return
        try {
            stopSession(mapOf("sessionId" to id))
        } catch (_: Throwable) {
            // session already gone
        }
    }

    // ------------------------------------------------------------------ diagnostics

    fun ackPatch(params: Map<String, Any?>): Map<String, Any?> {
        val seq = (params["seq"] as? Number)?.toInt() ?: -1
        if (seq > lastAckedSeq) lastAckedSeq = seq
        return linkedMapOf("ok" to true)
    }

    fun setDiagnosticsModelInfo(params: Map<String, Any?>): Map<String, Any?> {
        modelVersion = params["version"] as? String
        modelNFrames = (params["nFrames"] as? Number)?.toInt()
        return linkedMapOf("ok" to true)
    }

    fun getEnvelopeCapability(): Map<String, Any?> = linkedMapOf(
        "supported" to true,
        "envelopeHopMs" to envelope.hopMs,
        "envelopeLength" to envelope.length,
    )

    fun getDiagnostics(): Map<String, Any?> {
        val micAvailable = context.packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)
        val inUseKnown = !skipAudioRecord
        val sessionId = sm.sessionId
        val state = when {
            sessionId != null -> sm.state.name
            else -> "IDLE"
        }
        return linkedMapOf(
            "micAvailable" to micAvailable,
            "micInUse" to (if (inUseKnown) (capture?.isActive ?: false) else null),
            "micInUseKnown" to inUseKnown,
            "recordAudioPermission" to if (hasRecordPermission()) "granted" else "denied",
            "activeSessionId" to sessionId,
            "sessionState" to state,
            "audioRecordActive" to (capture?.isActive ?: false),
            "bufferedSamples" to ring.size,
            "patchesEmitted" to patchesEmitted,
            "patchesVoiced" to patchesVoiced,
            "droppedPatches" to droppedPatches,
            "envelopeHopMs" to envelope.hopMs,
            "envelopeLength" to envelope.length,
            "injectionQueueDepth" to injectQueue.size,
            "tempAudioFiles" to TempAudioAndroid(context).count(),
            "lastError" to lastError,
            "nativeMelVersion" to FeatureConfig.MEL_VERSION,
            "modelVersion" to modelVersion,
            "modelNFrames" to modelNFrames,
        )
    }
}

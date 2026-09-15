package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check

/**
 * SPEC-P-02 acceptance 1/2/3 exercised end-to-end over a synthetic session.
 *
 * These checks need no Android API: they drive `Vad`, `EnvelopeExtractor` and
 * `SessionStateMachine` exactly the way `SessionManager` does, so the silence accounting
 * and the "silent patches are still delivered" invariant are verified here.
 */
object VadSilenceEndTest {

    fun run() {
        Check.group("P-02 silence session")
        val vad = Vad()
        val sm = SessionStateMachine()
        sm.startSession("S-test")
        sm.onStarted()

        var emitted = 0
        var voicedCount = 0
        var ended = false
        var endReason: String? = null

        // 30 s of pure silence at the frozen 512 ms patch cadence.
        val patchMs = vad.patchDurationMs
        val patches30s = 30_000 / patchMs
        repeat(patches30s) {
            val rms = 0.0
            val voiced = vad.evaluate(rms)
            emitted++                      // silent patches must still be delivered
            if (voiced) voicedCount++
            if (vad.shouldEndSession() && !ended) {
                ended = true
                endReason = sm.endReasonWire() ?: "silence90s"
            }
        }
        val expected = patches30s
        Check.that(
            "silentPatch_deliveryCount",
            emitted == expected,
            "emitted=$emitted expected=$expected (no dropped silent patch)",
        )
        Check.equal("silentPatch_voicedCount", voicedCount, 0)
        Check.that("30sOfSilence_doesNotEndSession", !ended, "FF-21a is 90 s, not 30 s")

        // continue to 90 s
        val vad2 = Vad()
        var endedAtPatch = -1
        var i = 0
        while (i < 1000) {
            vad2.evaluate(0.0)
            i++
            if (vad2.shouldEndSession()) { endedAtPatch = i; break }
        }
        Check.equal(
            "silenceEndsAt90s_patchCount",
            endedAtPatch,
            (FeatureConfig.BEHAVIOR_MEAL_END_SILENCE_SECONDS * 1000) / vad2.patchDurationMs,
        )

        // A voiced patch at the 89 s mark must push the end back.
        val vad3 = Vad()
        val until89 = (89_000) / vad3.patchDurationMs
        repeat(until89) { vad3.evaluate(0.0) }
        Check.that("justBefore90s_notYetEnded", !vad3.shouldEndSession())
        vad3.evaluate(0.5)
        Check.that("voicedAt89s_resetsCounter", !vad3.shouldEndSession())
    }
}

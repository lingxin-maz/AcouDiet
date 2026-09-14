package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check
import com.acoudiet.app.testkit.Signals

/** SPEC-P-01 section 7 acceptance 4 (ring buffer) plus the state machine (acceptances 2/3). */
object RingBufferTest {

    fun run() {
        Check.group("P-01 RingBuffer")
        val rb = RingBuffer()
        Check.equal("capacity_isFF09_and_overwritesOldest (capacity)", rb.capacity, FeatureConfig.PATCH_SAMPLES)

        // Write 70000 samples with a recognisable ramp; the oldest 4464 must be gone.
        val total = 70000
        val src = ShortArray(total) { (it % 30000).toShort() }
        rb.write(src)
        Check.equal("size saturates at capacity", rb.size, FeatureConfig.PATCH_SAMPLES)

        val snap = ShortArray(FeatureConfig.PATCH_SAMPLES)
        Check.that("snapshot succeeds when full", rb.snapshot(snap))
        Check.equal("oldest surviving sample", snap[0], src[total - FeatureConfig.PATCH_SAMPLES])
        Check.equal("newest sample", snap[FeatureConfig.PATCH_SAMPLES - 1], src[total - 1])

        val small = RingBuffer(8)
        Check.that("snapshot returns false before the buffer is full", !small.snapshot(ShortArray(8)))
        small.write(shortArrayOf(1, 2, 3))
        small.write(shortArrayOf(4, 5, 6, 7, 8, 9, 10))
        val out = ShortArray(8)
        small.snapshot(out)
        Check.that(
            "wrap-around keeps chronological order",
            out.toList() == listOf<Short>(3, 4, 5, 6, 7, 8, 9, 10),
            out.toList().toString(),
        )

        Check.group("P-01 SessionStateMachine")
        val sm = SessionStateMachine()
        sm.startSession("S-1")
        Check.equal("IDLE -> STARTING", sm.state, SessionStateMachine.State.STARTING)
        sm.onStarted()
        Check.equal("STARTING -> RUNNING", sm.state, SessionStateMachine.State.RUNNING)
        sm.pause("S-1")
        Check.equal("RUNNING -> PAUSED", sm.state, SessionStateMachine.State.PAUSED)
        sm.resume("S-1")
        Check.equal("PAUSED -> RUNNING", sm.state, SessionStateMachine.State.RUNNING)
        val reason = sm.stop("S-1")
        Check.equal("RUNNING -> IDLE", sm.state, SessionStateMachine.State.IDLE)
        Check.equal("stop end reason", reason, SessionStateMachine.EndReason.USER_STOP)

        Check.throws("illegal: resume while not paused -> ACD-SESS-002", "ACD-SESS-002") {
            val m = SessionStateMachine()
            m.startSession("S-2")
            m.onStarted()
            m.resume("S-2")
        }
        Check.throws("illegal: pause twice -> ACD-SESS-002", "ACD-SESS-002") {
            val m = SessionStateMachine()
            m.startSession("S-3")
            m.onStarted()
            m.pause("S-3")
            m.pause("S-3")
        }
        Check.throws("illegal: pause after end -> ACD-SESS-001", "ACD-SESS-001") {
            val m = SessionStateMachine()
            m.startSession("S-4")
            m.onStarted()
            m.stop("S-4")
            m.pause("S-4")
        }
        Check.throws("illegal: two sessions at once -> ACD-SESS-002", "ACD-SESS-002") {
            val m = SessionStateMachine()
            m.startSession("S-5")
            m.startSession("S-6")
        }
        Check.equal(
            "silence end reason",
            SessionStateMachine().let { m ->
                m.startSession("S-7"); m.onStarted(); m.endOnSilence()
                m.endReasonWire()
            },
            "silence90s",
        )
    }
}

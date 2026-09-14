package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check

/** SPEC-P-02 section 7 acceptance table (VAD + silence auto-end). */
object VadTest {

    fun run() {
        Check.group("P-02 Vad")
        val f = FeatureConfig

        // #5 thresholds come from the SSOT behavior block
        val vad = Vad()
        Check.equal("noiseFloorInit_isSSOT", vad.noiseFloor, f.BEHAVIOR_NOISE_FLOOR_INIT)
        Check.near(
            "threshold_isFloorTimesMargin",
            vad.threshold,
            f.BEHAVIOR_NOISE_FLOOR_INIT * Math.pow(10.0, f.BEHAVIOR_VOICED_MARGIN_DB / 20.0),
            1e-12,
        )

        // voiced decision above/below the margin
        Check.that("loudPatch_isVoiced", vad.evaluate(0.5))
        Check.that("quietPatch_isNotVoiced", !vad.evaluate(0.0001))

        // #6 noise floor never drops below the frozen minimum and is untouched by voiced patches
        val floorTest = Vad()
        repeat(200) { floorTest.evaluate(0.0) }
        Check.that(
            "noiseFloor_neverBelowFloor",
            floorTest.noiseFloor >= f.BEHAVIOR_NOISE_FLOOR_MIN - 1e-15,
            "floor=${floorTest.noiseFloor}",
        )
        val before = floorTest.noiseFloor
        floorTest.evaluate(0.9)
        Check.equal("noiseFloor_notUpdatedOnVoiced", floorTest.noiseFloor, before)

        // #4 90 s of silence triggers the end, one patch short does not
        val silence = Vad()
        val stepMs = silence.patchDurationMs
        val patchesFor90s = (f.BEHAVIOR_MEAL_END_SILENCE_SECONDS * 1000) / stepMs
        repeat(patchesFor90s - 1) { silence.evaluate(0.0) }
        Check.that("silenceShortOf90s_doesNotEnd", !silence.shouldEndSession(), "silentMs=${silence.silentMs}")
        silence.evaluate(0.0)
        Check.that("silenceTriggersEnd_afterFF21a", silence.shouldEndSession(), "silentMs=${silence.silentMs}")

        // a voiced patch resets the silence accumulator
        val reset = Vad()
        repeat(patchesFor90s / 2) { reset.evaluate(0.0) }
        reset.evaluate(0.5)
        Check.equal("voicedPatch_resetsSilence", reset.silentMs, 0L)

        // #8 pause does not accumulate: not calling evaluate() keeps the counter frozen
        val paused = Vad()
        repeat(10) { paused.evaluate(0.0) }
        val frozen = paused.silentMs
        // (pauseSession stops patch emission, hence no evaluate() calls)
        Check.equal("pause_doesNotAccumulateSilence", paused.silentMs, frozen)

        // #7 patchesVoiced counting
        val counter = Vad()
        counter.evaluate(0.4)
        counter.evaluate(0.0)
        counter.evaluate(0.4)
        Check.equal("patchesEvaluated_count", counter.patchesEvaluated, 3)
        Check.equal("patchesVoiced_count", counter.patchesVoiced, 2)

        // FF-21a is 90 s, not 30 s
        Check.equal("mealEndSilence_isFF21a", f.BEHAVIOR_MEAL_END_SILENCE_SECONDS, 90)

        // reset() is idempotent and restores the SSOT initial floor
        counter.reset()
        Check.equal("reset_restoresInitialFloor", counter.noiseFloor, f.BEHAVIOR_NOISE_FLOOR_INIT)
        Check.equal("reset_clearsCounters", counter.patchesVoiced, 0)
    }
}

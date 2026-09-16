package com.acoudiet.app.audio

import com.acoudiet.app.config.FeatureConfig
import com.acoudiet.app.testkit.Check
import kotlin.math.abs
import kotlin.system.measureNanoTime

/**
 * P-03 stage 3 noise gate: cross-language parity, primitive semantics, invariants, real-time budget.
 *
 * WHY THIS FILE EXISTS (ADR-56)
 * -----------------------------
 * `NoiseGate.kt` is a hand port of `ai/src/denoise_td.py`. The gate is a chain of a sliding minimum,
 * a sliding maximum, a soft expansion curve, a two-rate one-pole smoother and a clamped linear
 * interpolation. **Any one of those can be off by an index or an edge rule and still produce a
 * plausible-sounding result** -- on the real corpus that would read as "slightly different numbers"
 * and nobody would notice until the recognition rate moved.
 *
 * So the parity assertion is against a golden vector emitted by the Python reference (which is the
 * specification), and it is deliberately paired with hand-computed checks of the two sliding windows,
 * because that is where a mis-port actually hides.
 *
 * The real-time check closes `SPEC-P-03` section 8, which has been owed since the beginning: the
 * preprocessing chain must fit inside the hop budget (`FF-12`: 0.5 s per patch) and no number had
 * ever been produced for it.
 */
object NoiseGateParityTest {

    /**
     * The real deadline for one patch: the HOP (`FF-12`), not the window length.
     *
     * ⚠️ The first version of this file used `PATCH_SECONDS * 500.0` = 2048 ms, i.e. it compared the
     * cost of one patch against *four* patches' worth of time. That is a four-times-too-lenient gate
     * that would still have passed everything -- the exact failure mode a budget check must not have.
     * A patch of 4.096 s is produced every 0.5 s, so 500 ms is what the chain has to fit inside.
     */
    private const val HOP_BUDGET_MS = FeatureConfig.INFERENCE_HOP_SECONDS * 1000.0

    fun run() {
        Check.group("P-03 stage 3 noise gate (ADR-56)")

        // ---- 1. the golden vector: Kotlin must reproduce the Python reference element-wise --------
        val params = NoiseGate.Params()
        val actual = NoiseGate.apply(
            NoiseGateGolden.INPUT,
            NoiseGateGolden.INPUT.size,
            params,
            NoiseGateGolden.SAMPLE_RATE,
        )
        Check.equal("golden_lengths_match", actual.size, NoiseGateGolden.EXPECTED.size)
        val diff = NoiseGate.maxAbsDiff(actual, NoiseGateGolden.EXPECTED)
        Check.that(
            "golden_parity_withPythonReference",
            diff <= NoiseGateGolden.ATOL,
            "max|diff|=$diff atol=${NoiseGateGolden.ATOL} (n=${actual.size})",
        )

        // A golden vector equal to its input would make the assertion above vacuous. Assert the
        // golden actually moves the signal, so this file cannot silently stop testing anything.
        val inputVsExpected = NoiseGate.maxAbsDiff(NoiseGateGolden.INPUT, NoiseGateGolden.EXPECTED)
        Check.that(
            "golden_is_not_a_noOp",
            inputVsExpected > 1e-3,
            "max|expected-input|=$inputVsExpected (a no-op golden would prove nothing)",
        )

        // ---- 2. sliding windows: the primitives where an index/edge error hides ------------------
        // Hand-computed. Window for an ODD size is [i-h, i+h]; for an EVEN size `lo+hi+1` the window
        // is [i-lo, i+hi]. Both clamp at the ends (edge value extends), which is what the Python
        // reference does too -- it is written out explicitly there for exactly this reason.
        val e = doubleArrayOf(5.0, 1.0, 4.0, 2.0, 3.0)
        // min over [i-1, i+1] clamped:
        //   i=0 -> [0,1]   -> min(5,1)   = 1
        //   i=1 -> [0,2]   -> min(5,1,4) = 1
        //   i=2 -> [1,3]   -> min(1,4,2) = 1
        //   i=3 -> [2,4]   -> min(4,2,3) = 2
        //   i=4 -> [3,4]   -> min(2,3)   = 2
        val minOut = NoiseGate.slidingMin(e, 1, 1)
        Check.that(
            "slidingMin_oddWindow_clampsAtEdges",
            minOut.contentEquals(doubleArrayOf(1.0, 1.0, 1.0, 2.0, 2.0)),
            minOut.joinToString(","),
        )
        // max over [i-1, i+1] clamped: i=0 -> max(5,1)=5 ; i=1 -> 5 ; i=2 -> 4 ; i=3 -> 4 ; i=4 -> 3
        val maxOut = NoiseGate.slidingMax(e, 1, 1)
        Check.that(
            "slidingMax_oddWindow_clampsAtEdges",
            maxOut.contentEquals(doubleArrayOf(5.0, 5.0, 4.0, 4.0, 3.0)),
            maxOut.joinToString(","),
        )
        // EVEN window `lo+hi+1 == 4` means lo=2, hi=1 -> [i-2, i+1]:
        //   i=0 -> [0,1] min 1 ; i=1 -> [0,2] 1 ; i=2 -> [0,3] 1 ; i=3 -> [1,4] 1 ; i=4 -> [2,4] 2
        val evenOut = NoiseGate.slidingMin(e, 2, 1)
        Check.that(
            "slidingMin_evenWindow_boundsAreLoHiNotSymmetric",
            evenOut.contentEquals(doubleArrayOf(1.0, 1.0, 1.0, 1.0, 2.0)),
            evenOut.joinToString(","),
        )
        Check.that(
            "slidingWindow_doesNotMutateItsInput",
            e.contentEquals(doubleArrayOf(5.0, 1.0, 4.0, 2.0, 3.0)),
            e.joinToString(","),
        )

        // ---- 3. invariants that must hold for ANY input -----------------------------------------
        val rng = java.util.Random(20260915)
        val noise = FloatArray(4096) { (rng.nextGaussian() * 0.01).toFloat() }
        val gated = NoiseGate.apply(noise, noise.size, params, FeatureConfig.SAMPLE_RATE)
        var amplified = false
        for (i in noise.indices) {
            if (abs(gated[i].toDouble()) > abs(noise[i].toDouble()) + 1e-9) amplified = true
        }
        Check.that(
            "gate_neverAmplifies_onNoiseOnlyInput",
            !amplified,
            "gain <= 1 by construction; an amplified sample means the gain curve is wrong",
        )
        val att = NoiseGate.attenuationDb(noise, params)
        Check.that(
            "noise_only_input_is_attenuated",
            att < -3.0,
            "attenuation=$att dB (must be clearly negative; the first-generation recipe was +9.5 dB)",
        )
        // Determinism (SPEC-P-03 acceptance 3 extends to stage 3).
        val again = NoiseGate.apply(noise, noise.size, params, FeatureConfig.SAMPLE_RATE)
        Check.that(
            "gate_isDeterministic",
            NoiseGate.maxAbsDiff(gated, again) == 0.0,
            "same input must give bit-identical output",
        )
        // A pure tone well above the threshold must pass essentially untouched: the gate is not a
        // blanket attenuator. This is the "does not smother the signal" property.
        val tone = FloatArray(4096) { (0.5 * kotlin.math.sin(it * 0.05)).toFloat() }
        val toneOut = NoiseGate.apply(tone, tone.size, params, FeatureConfig.SAMPLE_RATE)
        var worstRatio = 0.0
        for (i in tone.indices) {
            if (abs(tone[i]) > 0.05) {
                val r = abs(toneOut[i].toDouble()) / abs(tone[i].toDouble())
                if (r > worstRatio) worstRatio = r
            }
        }
        Check.that(
            "tone_aboveThreshold_passesThrough",
            worstRatio <= 1.0 + 1e-9,
            "worst gain=$worstRatio (must not exceed 1.0)",
        )

        // ---- 4. real-time budget (SPEC-P-03 section 8, owed since the beginning) ----------------
        // One full patch is FF-09's 65536 samples and arrives every FF-12 hop of 0.5 s, so the whole
        // budget is 500 ms and the pre-processing chain must be a small fraction of it.
        val patch = ShortArray(FeatureConfig.PATCH_SAMPLES) { (rng.nextGaussian() * 800).toInt().toShort() }
        repeat(3) { Preprocess.apply(patch, enableDenoise = true) }   // warm the JIT
        val ns = measureNanoTime {
            repeat(20) { Preprocess.apply(patch, enableDenoise = true) }
        } / 20
        val ms = ns / 1_000_000.0
        Check.that(
            "preprocess_withGate_fitsTheHopBudget",
            ms < HOP_BUDGET_MS,
            "preprocess(+gate) $ms ms/patch vs ${HOP_BUDGET_MS} ms budget " +
                "(FF-12 hop = ${FeatureConfig.INFERENCE_HOP_SECONDS} s, from the SSOT)",
        )
        // And the gate on its own, so a future regression can be attributed.
        val gateOnly = measureNanoTime {
            repeat(20) { NoiseGate.apply(FloatArray(FeatureConfig.PATCH_SAMPLES), FeatureConfig.PATCH_SAMPLES) }
        } / 20
        Check.that(
            "gateOnly_costIsReported",
            gateOnly / 1_000_000.0 < HOP_BUDGET_MS,
            "gate alone ${gateOnly / 1_000_000.0} ms/patch (budget $HOP_BUDGET_MS ms)",
        )
    }
}

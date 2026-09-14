package com.acoudiet.app

import com.acoudiet.app.audio.MelFrontendTest
import com.acoudiet.app.audio.PreprocessTest
import com.acoudiet.app.audio.RingBufferTest
import com.acoudiet.app.audio.VadTest
import com.acoudiet.app.audio.VadSilenceEndTest
import com.acoudiet.app.testkit.Check

/**
 * Runner for the JVM-runnable native (Kotlin) test suite.
 *
 *   java -cp <classes>;<kotlin-stdlib> com.acoudiet.app.JvmTestMain
 *
 * Exit code 0 = every check passed. The same assertions are mirrored as `*Test.kt`
 * classes that a Gradle/instrumented run can pick up once the Android build can resolve
 * its dependencies; this runner exists so the DSP path is verifiable offline.
 */
object JvmTestMain {
    @JvmStatic
    fun main(args: Array<String>) {
        println("=".repeat(72))
        println("AcouDiet native (Kotlin) JVM test suite")
        println("=".repeat(72))
        RingBufferTest.run()
        PreprocessTest.run()
        MelFrontendTest.run()
        VadTest.run()
        VadSilenceEndTest.run()
        val failed = Check.summary("NATIVE")
        System.exit(if (failed == 0) 0 else 1)
    }
}

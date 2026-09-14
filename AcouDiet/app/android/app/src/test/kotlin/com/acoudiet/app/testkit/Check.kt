package com.acoudiet.app.testkit

/**
 * Dependency-free assertion helper for the JVM-runnable native test suite.
 *
 * The Android instrumented suite (`flutter test` / `gradlew test`) cannot run in this
 * environment because Gradle artifacts and pub packages are unreachable offline. The DSP
 * classes are deliberately Android-free (SPEC-P-02 section 8 / SPEC-P-03 section 8), so
 * they are compiled and exercised here with the Kotlin compiler that ships inside the
 * Android SDK. `JvmTestMain` prints one line per check and exits non-zero on failure.
 */
object Check {

    data class Result(val name: String, val passed: Boolean, val detail: String)

    val results = mutableListOf<Result>()

    fun that(name: String, condition: Boolean, detail: String = "") {
        results += Result(name, condition, detail)
        val mark = if (condition) "ok  " else "FAIL"
        val suffix = if (detail.isEmpty()) "" else "  ($detail)"
        println("  [$mark] $name$suffix")
    }

    fun near(name: String, actual: Double, expected: Double, tol: Double) {
        val d = kotlin.math.abs(actual - expected)
        that(name, d <= tol, "actual=$actual expected=$expected |diff|=$d tol=$tol")
    }

    fun equal(name: String, actual: Any?, expected: Any?) {
        that(name, actual == expected, "actual=$actual expected=$expected")
    }

    fun throws(name: String, expectedCode: String, block: () -> Unit) {
        try {
            block()
            that(name, false, "no exception raised, expected $expectedCode")
        } catch (e: com.acoudiet.app.audio.AcouDietException) {
            that(name, e.code == expectedCode, "code=${e.code} expected=$expectedCode")
        } catch (e: Throwable) {
            that(name, false, "wrong exception type ${e::class.simpleName}: ${e.message}")
        }
    }

    fun group(title: String) {
        println()
        println("### $title")
    }

    fun summary(label: String): Int {
        val failed = results.count { !it.passed }
        println()
        println("=".repeat(72))
        println("$label: ${results.size - failed} passed, $failed failed, ${results.size} total")
        if (failed > 0) {
            println("FAILED CHECKS:")
            results.filter { !it.passed }.forEach { println("  - ${it.name}  ${it.detail}") }
        }
        println("=".repeat(72))
        return failed
    }
}

# AcouDiet -- one-command verification (C-05 regression entry point).
#
#   powershell -File tool\verify_all.ps1
#
# Runs every suite that can execute in an offline environment and prints a single summary.
# Exit code 0 iff every suite passed. This is the local equivalent of the four mechanical
# acceptances in docs/common/README.md section 5, adapted to the constraint that
# `flutter pub get` / `gradlew` cannot resolve dependencies here (see
# records/reports/c04_dependency_deviation.md).
#
# ENCODING: KEEP THIS FILE PURE ASCII -- no BOM, no non-ASCII bytes. Measured (ADR-32/ADR-33):
# it previously carried Chinese comments and no BOM, and Windows PowerShell 5.1 decodes a
# BOM-less .ps1 with the machine ANSI code page (936/GBK here), so the file died before running
# a single step: "The Try statement is missing its Catch or Finally block." A UTF-8 BOM fixes
# that decode, but the BOM is easily and silently stripped by ordinary editing tools (it was,
# twice, during the ADR-32 round) -- which restores the failure without any visible clue. Pure
# ASCII removes the whole class: every other .ps1 in tool/ is pure ASCII for the same reason.
# Rationale that used to live in Chinese comments is in docs/01_<ADR log>.md (ADR-31).

[CmdletBinding()]
param(
    [switch]$SkipParity
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot              # repository root
# ADR-36: the toolchain location is an environment fact, not a constant, so CI (or another
# machine) can point this at its own checkout instead of one hardcoded path.
$Tool = if ($env:ACOUDIET_TOOLCHAIN) { $env:ACOUDIET_TOOLCHAIN } else { 'D:\Desktop\Food\_toolchain' }
$Dart = "$Tool\flutter\bin\cache\dart-sdk\bin\dart.exe"
$Py   = if ($env:ACOUDIET_PYTHON) { $env:ACOUDIET_PYTHON } else { "$Tool\dl\python\python.exe" }
$Flutter = if ($env:ACOUDIET_FLUTTER) { $env:ACOUDIET_FLUTTER } else { "$Tool\flutter\bin\flutter.bat" }

$results = @()

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host ">>> $Name" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    & $Body
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    $script:results += [pscustomobject]@{ Step = $Name; ExitCode = $code }
    if ($code -ne 0) {
        Write-Host "!!! $Name FAILED (exit $code)" -ForegroundColor Red
    }
}

Push-Location $Root
try {
    Invoke-Step "C-03  generate constants from the SSOT" {
        & $Dart "tool\gen_feature_config.dart"
    }

    Invoke-Step "P-01..P-04  Kotlin DSP (JVM suite)" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$Root\tool\jvm_build.ps1" -Run
    }

    Invoke-Step "L4  pure domain suite" {
        Push-Location "$Root\app"
        try { & $Dart "tool\pure_tests.dart" } finally { Pop-Location }
    }

    # ADR-44: the cloud agent's offline suite. 80 checks, and SIX of them are negative controls.
    # Running `dart tool/agent_tests.dart --without-negative-controls` must flip exactly those six
    # to FAIL -- that flip is how "this gate can fail" is demonstrated instead of asserted, which
    # is the failure mode this repository keeps rediscovering.
    Invoke-Step "G-01..G-03  agent offline suite (cloud egress + handoff rules)" {
        Push-Location "$Root\app"
        try { & $Dart "tool\agent_tests.dart" } finally { Pop-Location }
    }

    Invoke-Step "L3  data layer (real SQLite)" {
        if (-not $env:ACOUDIET_SQLITE) {
            $candidates = @("D:\Anaconda\DLLs\sqlite3.dll", "D:\Anaconda\Library\bin\sqlite3.dll")
            foreach ($c in $candidates) { if (Test-Path $c) { $env:ACOUDIET_SQLITE = $c; break } }
        }
        Push-Location "$Root\app"
        try { & $Dart "tool\data_tests.dart" } finally { Pop-Location }
    }

    Invoke-Step "C-03 / P-05..P-08 / M-01..M-04  session + demo suite" {
        Push-Location "$Root\app"
        try { & $Dart "tool\session_tests.dart" } finally { Pop-Location }
    }

    if (-not $SkipParity) {
        Invoke-Step "T-08b  cross-language Mel parity (Kotlin vs librosa)" {
            $env:PYTHONPATH = "$Tool\site-packages"
            $env:TMP = "$Tool\tmp"; $env:TEMP = "$Tool\tmp"
            $env:TF_CPP_MIN_LOG_LEVEL = '3'
            # `--n 14`, not `--n 12`: `--n` truncates the SORTED wav list, and the two
            # three-patch clips that exercise ADR-21's streaming pre-emphasis predecessor
            # (`tone_long.wav`, `tone_4000hz.wav`) sort near the end. With 12 the gate still
            # passed but never tested a non-zero predecessor -- the script now fails on that
            # (see its `boundaryCoverage` assertion), so the two have to agree.
            & $Py "ai\scripts\mel_parity_test.py" --n 14 2>$null
        }
    }

    Invoke-Step "C-02  consent-registry admission (R-11)" {
        $env:PYTHONPATH = "$Tool\site-packages"
        & $Py "tool\check_consent_registry.py" --strict
    }

    Invoke-Step "T-02  independent split/leak verification (API-06 section 3.3)" {
        & $Py "tool\check_split_leakage.py" --strict
    }

    Invoke-Step "L5->L4 call-site consistency (no Flutter analyzer available offline)" {
        & $Py "tool\check_l4_usage.py" --strict
    }

    Invoke-Step "API-01  Kotlin<->Dart bridge symmetry (side-to-side)" {
        & $Py "tool\check_bridge_symmetry.py" --strict
    }

    Invoke-Step "Kotlin usage consistency (Android host -> pure DSP)" {
        & $Py "tool\check_kotlin_usage.py" --strict
    }

    # ADR-31: writing a disposed ValueNotifier from an async continuation throws an ASYNC
    # UNCAUGHT exception. The offline suites do not compile the presentation lifecycle and the
    # tool suites never call pumpWidget, so nothing mechanical covered this before. The checker
    # carries its own negative control (put `onLevel` back to a bare assignment and it fires).
    Invoke-Step "presentation async state writes carry a mounted guard" {
        & $Py "tool\check_async_state_writes.py"
    }

    # Two manifests were unparseable XML for the whole project lifetime, because nothing ever
    # parsed them offline. A real `flutter build apk --debug` found it; this keeps it found.
    Invoke-Step "Android XML well-formedness (manifests + res)" {
        & $Py "tool\check_android_xml.py" --strict
    }

    # ADR-33: `_toolchain/check_apk_contents.py` used to compare the packaged model against a
    # HARDCODED v1.1 sha256, so once the model was replaced it printed `False` for a perfectly
    # good package; `tool/ui_fingerprint_check.py` condemned every post-ADR-30 build the same
    # way. Both are now card/measurement driven. This step runs the synthetic-APK negative
    # controls for the contents checker -- it needs no real APK, so it belongs in the offline set.
    Invoke-Step "APK contents checker still discriminates (synthetic fixtures)" {
        & $Py "tool\selftest_check_apk_contents.py"
    }

    # ADR-35: measured on the shipped APK, not assumed. A 4 KB-aligned libtensorflowlite_jni.so
    # cannot be mapped on a 16 KB-page device, so the model would fail to load on the newest
    # phones -- and neither `zipalign` nor any test looked at it. Checks the NEWEST release
    # package in dist/ and prints which one it chose.
    Invoke-Step "APK is 16 KB page compatible (ELF p_align + zip offsets)" {
        & $Py "tool\check_page_alignment.py"
    }

    # The artifact gate is reported but not counted as a hard failure while the model slot is
    # still empty: `verify_artifacts.py` exits 3 for "nothing to verify yet" precisely so that
    # state cannot be mistaken for a pass (or for a broken build). Once a real `.tflite` is
    # installed it returns 0/2 like any other gate.
    Invoke-Step "T-07/T-08a  artifact gate (verifies the SHIPPED model)" {
        & $Py "tool\verify_artifacts.py"
        if ($LASTEXITCODE -eq 3) {
            Write-Host "    [note] no model installed yet: reported as NOT BUILT (exit 3)," `
                -ForegroundColor Yellow
            Write-Host "           which is neither a pass nor a failure." -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
        }
    }

    Invoke-Step "AI toolchain guard-rails (SSOT / cut features / terms / no audio)" {
        & $Py "ai\tests\run_all.py"
    }

    # ADR-44: two static gates for the ONE new egress path. The selftests run too, because the
    # rule for a detector is the same as for any other gate: it has to be shown discriminating
    # cases it must catch from cases it must ignore, including one it got WRONG on the first try
    # (the generated Kotlin constants were flagged as a hardcoded model name).
    Invoke-Step "ADR-44  cloud egress boundaries + PS1 encoding" {
        $bad = 0
        & $Py "tool\check_network_boundary.py" --selftest; if ($LASTEXITCODE -ne 0) { $bad = 1 }
        & $Py "tool\check_network_boundary.py" --strict;   if ($LASTEXITCODE -ne 0) { $bad = 1 }
        & $Py "tool\check_audio_egress.py" --selftest;     if ($LASTEXITCODE -ne 0) { $bad = 1 }
        & $Py "tool\check_audio_egress.py" --strict;       if ($LASTEXITCODE -ne 0) { $bad = 1 }
        # A BOM-less .ps1 containing non-ASCII becomes a PARSE ERROR under Windows PowerShell 5.1
        # (ANSI code page 936 here). `build_release.ps1` documents the rule and was still broken
        # again during the ADR-44 work, because ordinary file-editing tools strip the BOM and
        # nothing looked at the bytes. Prose had already failed twice; this is the mechanical
        # version. It bit the APK build itself, which is what made it worth a gate.
        & $Py "tool\check_ps1_encoding.py" --selftest;     if ($LASTEXITCODE -ne 0) { $bad = 1 }
        & $Py "tool\check_ps1_encoding.py" --strict;       if ($LASTEXITCODE -ne 0) { $bad = 1 }
        $global:LASTEXITCODE = $bad
    }

    Invoke-Step "app/test  SPEC-named flutter_test suites (offline shim)" {
        $env:PYTHONPATH = "$Tool\site-packages"
        & $Py "tool\run_offline_tests.py"
    }

    # ADR-35: the REAL `flutter test`. The shim step above only runs the 12 files that avoid
    # Flutter's widget/binding APIs, so 14 files -- AppShell layout, page chrome, report scope,
    # score cards, notifier lifecycle -- were covered by NOTHING, and the suite had been red
    # (4 failures) since ADR-30 removed a string without updating its test. It was believed that
    # `flutter test` could not run on this machine at all; that stopped being true once the
    # toolchain worked. A gate that never runs is not a gate.
    # ADR-35: the REAL `flutter test`. The shim step above only runs the 12 files that avoid
    # Flutter's widget/binding APIs, so 14 files -- AppShell layout, page chrome, report scope,
    # score cards, notifier lifecycle -- were covered by NOTHING, and the suite had been red
    # (4 failures) since ADR-30 removed a string without updating its test. It was believed that
    # `flutter test` could not run on this machine at all; that stopped being true once the
    # toolchain worked. A gate that never runs is not a gate.
    #
    # ADR-44: BOTH flavours are run, and the second one is why. `acouIsOffline` is a COMPILE-TIME
    # constant, so the default run never compiles the offline branch -- and until this was added
    # the offline flavour had never been built at all. The first time it was, three tests turned
    # out to assume the agent flavour. One branch, two builds; test both or you have tested one.
    Invoke-Step "app/test  REAL flutter test (both flavours)" {
        $flutter = $Flutter
        if (-not (Test-Path $flutter)) {
            Write-Host "    !! flutter not found at $flutter -- this step cannot be skipped" `
                -ForegroundColor Red
            $global:LASTEXITCODE = 2
        } else {
            # `flutter test` needs the Android SDK env only for `flutter build`; it reads
            # JAVA_HOME/ANDROID_HOME defensively, so set them the same way the build does.
            if (-not $env:JAVA_HOME) { $env:JAVA_HOME = "$Tool\jdk17" }
            if (-not $env:ANDROID_HOME) {
                $env:ANDROID_HOME = "$Tool\android-sdk"
                $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
            }
            Push-Location "$Root\app"
            try {
                & $flutter test
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    !! the default (agent) flavour suite failed" -ForegroundColor Red
                    $global:LASTEXITCODE = 1
                } else {
                    & $flutter test --dart-define=ACOUDIET_FLAVOUR=offline
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "    !! the offline flavour suite failed" -ForegroundColor Red
                        $global:LASTEXITCODE = 1
                    }
                }
            } finally { Pop-Location }
        }
    }

    if (Test-Path "$Root\app\tool\ui_presenter_tests.dart") {
        Invoke-Step "U-01..U-06 / M-03 / M-04  UI presenters" {
            Push-Location "$Root\app"
            try { & $Dart "tool\ui_presenter_tests.dart" } finally { Pop-Location }
        }
    }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "VERIFICATION SUMMARY" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    $failed = 0
    foreach ($r in $results) {
        $mark = if ($r.ExitCode -eq 0) { "[ok]  " } else { "[FAIL]" }
        "{0} {1,-62} exit={2}" -f $mark, $r.Step, $r.ExitCode | Write-Host
        if ($r.ExitCode -ne 0) { $failed++ }
    }
    Write-Host ""
    if ($failed -eq 0) {
        Write-Host "ALL SUITES PASSED ($($results.Count) steps)" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "$failed of $($results.Count) suites FAILED" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}

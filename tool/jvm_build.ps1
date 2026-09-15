# AcouDiet -- compile and run the Android-free Kotlin DSP layer on the JVM.
#
#   powershell -File tool\jvm_build.ps1                 # compile only
#   powershell -File tool\jvm_build.ps1 -Run            # compile + run the test suite
#   powershell -File tool\jvm_build.ps1 -Cmd "com.acoudiet.app.tools.MelDump --wav x.wav --mel-out m.bin"
#   powershell -File tool\jvm_build.ps1 -Run -Rebuild   # force a clean compile
#
# Why this exists: Gradle/AGP artifacts and pub packages are unreachable offline in this
# environment, so `gradlew test` and `flutter test` cannot resolve dependencies here. The
# DSP classes are deliberately Android-free (SPEC-P-02 section 8 / SPEC-P-03 section 8), so
# they are compiled with a standalone Kotlin compiler and exercised on the JVM -- including
# the cross-language Mel parity gate (SPEC-P-04 acceptance 3/4).
#
# Compiler discovery order:
#   1. $env:ACOUDIET_KOTLINC          (explicit override: a kotlinc `lib` folder)
#   2. IntelliJ IDEA's bundled kotlinc (full compiler)
#   3. the Android SDK's lint-psi kotlin-compiler (partial; kept as a last resort)

[CmdletBinding()]
param(
    [switch]$Run,
    [string]$Cmd,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot          # repository root
$Tool = 'D:\Desktop\Food\_toolchain'
$Sdk  = "$Tool\android-sdk"
$Java = "$Tool\jdk17\bin\java.exe"

function Resolve-KotlinLib {
    $candidates = @()
    if ($env:ACOUDIET_KOTLINC) { $candidates += $env:ACOUDIET_KOTLINC }
    $candidates += (Get-ChildItem 'D:\IDEA' -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.FullName)\plugins\Kotlin\kotlinc\lib" })
    foreach ($c in $candidates) {
        if ((Test-Path $c) -and (Test-Path (Join-Path $c 'kotlin-compiler.jar'))) { return $c }
    }
    throw "no Kotlin compiler found; set ACOUDIET_KOTLINC to a kotlinc 'lib' folder"
}

$KotlinLib  = Resolve-KotlinLib
$CompilerCp = (Get-ChildItem $KotlinLib -Filter *.jar | Select-Object -ExpandProperty FullName) -join ';'
$StdLib     = Join-Path $KotlinLib 'kotlin-stdlib.jar'

if (-not (Test-Path $Java))  { throw "missing JDK 17: $Java" }
if (-not (Test-Path $StdLib)) { throw "missing kotlin-stdlib.jar in $KotlinLib" }

$Out = "$Root\_build\jvm"
$Src = @(
    "$Root\app\android\app\src\main\kotlin\com\acoudiet\app\config\FeatureConfig.kt",
    "$Root\app\android\app\src\main\kotlin\com\acoudiet\app\config\NativeCapabilities.kt"
)
# Everything under audio/ that is not Android-specific is pure Kotlin by design.
$Src += (Get-ChildItem "$Root\app\android\app\src\main\kotlin\com\acoudiet\app\audio" -Filter *.kt |
         Where-Object { $_.Name -notlike '*Android*' } | Select-Object -ExpandProperty FullName)
$TestSrc = Get-ChildItem "$Root\app\android\app\src\test\kotlin" -Recurse -Filter *.kt |
           Select-Object -ExpandProperty FullName

if ($Rebuild -and (Test-Path $Out)) { Remove-Item $Out -Recurse -Force }

$needCompile = $Rebuild -or -not (Test-Path $Out)
if (-not $needCompile) {
    $newest = ($Src + $TestSrc | ForEach-Object { (Get-Item $_).LastWriteTimeUtc } |
               Sort-Object -Descending)[0]
    $marker = Get-ChildItem $Out -Recurse -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $marker -or $marker.LastWriteTimeUtc -lt $newest) { $needCompile = $true }
}

if ($needCompile) {
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    Write-Host "kotlinc: $KotlinLib" -ForegroundColor DarkGray
    Write-Host "compiling $($Src.Count) main + $($TestSrc.Count) test sources ..." -ForegroundColor Cyan
    $argList = @(
        '-cp', $CompilerCp,
        'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
        '-no-stdlib', '-no-reflect',
        '-jvm-target', '17',
        '-classpath', $StdLib,
        '-nowarn',
        '-d', $Out
    ) + $Src + $TestSrc
    & $Java @argList
    if ($LASTEXITCODE -ne 0) { throw "kotlinc failed with exit code $LASTEXITCODE" }
}

$runCp = "$Out;$StdLib"

if ($Run) {
    & $Java -cp $runCp com.acoudiet.app.JvmTestMain
    exit $LASTEXITCODE
}

if ($Cmd) {
    $parts = $Cmd -split ' '
    $mainClass = $parts[0]
    $rest = @()
    if ($parts.Count -gt 1) { $rest = $parts[1..($parts.Count - 1)] }
    & $Java -cp $runCp $mainClass @rest
    exit $LASTEXITCODE
}

Write-Host "compiled OK -> $Out"

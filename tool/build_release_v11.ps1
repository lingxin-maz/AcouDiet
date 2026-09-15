<#
.SYNOPSIS
    Build the release APK (v1.3 acoustic model, no on-device language model after ADR-34).

.DESCRIPTION
    WHY THIS IS A SCRIPT AND NOT A ONE-LINER
    ----------------------------------------
    `flutter build apk` fails on this machine under the restricted sandbox:
    the Flutter tool runs `cmd.exe /c ver` at startup (os.dart: _WindowsUtils.name), which is
    spawned with piped stdio, and the confined sandbox denies that (CreateFile failed 5 /
    ProcessException: access denied). It happens BEFORE argument parsing, so no flutter flag
    avoids it. Measured: the same `cmd.exe /c ver` succeeds once the sandbox is relaxed.

    So the whole build is bundled here and run once, under a single wider-permission approval,
    instead of asking for approval repeatedly.

    It also verifies what actually matters for this artifact: that the .tflite the model card
    names is inside the APK, byte-identical to the one on disk, and that the TFLite runtime is
    present. This used to check the Qwen weights and libacoudiet_llm.so instead; ADR-34 removed
    that layer, so the check moved back onto the acoustic model (which is the point of the app).

.NOTES
    Pure ASCII: Windows PowerShell 5.1 decodes .ps1 as ANSI unless it has a UTF-8 BOM.
#>

[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [string]$OutName = '',
    [switch]$Force,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Repo 'app'
$Dist = Join-Path $Repo 'dist'

# The shared toolchain (JDK / Flutter / gradle cache) lives OUTSIDE the deliverable tree,
# one level above the repository, so it cannot be shipped by accident. Probe rather than
# hard-code, and fail with both candidates named if neither exists.
$toolchainCandidates = @(
    (Join-Path (Split-Path -Parent $Repo) '_toolchain'),
    (Join-Path $Repo '_toolchain')
)
$Toolchain = $null
foreach ($c in $toolchainCandidates) {
    if (Test-Path (Join-Path $c 'jdk17\bin\java.exe')) { $Toolchain = $c; break }
}
if (-not $Toolchain) {
    Fail ("toolchain not found. Looked for jdk17 under:`n  " +
          ($toolchainCandidates -join "`n  "))
}

function Step($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 2 }

# --------------------------------------------------------------------------- environment

Step 'Environment'

$java = Join-Path $Toolchain 'jdk17'
if (-not (Test-Path (Join-Path $java 'bin\java.exe'))) { Fail "JDK not found: $java" }
$env:JAVA_HOME = $java
$env:GRADLE_USER_HOME = Join-Path $Toolchain 'cache\gradle'
if (($env:PATH -split ';') -notcontains (Join-Path $java 'bin')) {
    $env:PATH = (Join-Path $java 'bin') + ';' + $env:PATH
}
Write-Host "JAVA_HOME      : $env:JAVA_HOME"
Write-Host "GRADLE_USER_HOME: $env:GRADLE_USER_HOME"

$flutter = Join-Path $Toolchain 'flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) { Fail "flutter not found: $flutter" }
Write-Host "flutter        : $flutter"

# The Flutter tool refuses to build without an Android SDK and does NOT read
# android/local.properties for it (that file is for Gradle); it wants ANDROID_HOME /
# ANDROID_SDK_ROOT in the environment.
$sdk = Join-Path $Toolchain 'android-sdk'
if (-not (Test-Path (Join-Path $sdk 'platform-tools'))) {
    Fail "Android SDK not found at $sdk (expected platform-tools/ inside)"
}
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
Write-Host "ANDROID_HOME   : $env:ANDROID_HOME"

# --------------------------------------------------------------------------- preflight assets

Step 'Preflight: the artifact that must reach the APK'

# The card is the source of truth the App itself reads: it names the .tflite that must ship.
$cardPath = Join-Path $App 'assets\models\model_card.json'
if (-not (Test-Path $cardPath)) { Fail "model card missing: $cardPath" }
$card = Get-Content -LiteralPath $cardPath -Raw | ConvertFrom-Json
$tfliteName = "{0}_{1}_v{2}.tflite" -f $card.name, $card.quantization, $card.version
$tflitePath = Join-Path $App ("assets\models\$tfliteName")
if (-not (Test-Path $tflitePath)) {
    Fail ("the model card names '$tfliteName', which is not in app\assets\models\ -- the App " +
          "would fail to load the model (ACD-INF-001)")
}
$tfliteLen = (Get-Item $tflitePath).Length
$tfliteSha = (Get-FileHash -LiteralPath $tflitePath -Algorithm SHA256).Hash.ToLower()
if ($card.tfliteBytes -ne $tfliteLen) {
    Fail ("model card tfliteBytes=$($card.tfliteBytes) but the file is $tfliteLen bytes")
}
if ($card.tfliteSha256 -ne $tfliteSha) {
    Fail ("model card tfliteSha256=$($card.tfliteSha256) but the file hashes to $tfliteSha")
}
Write-Host ("acoustic model : {0}  ({1:N0} bytes)" -f $tflitePath, $tfliteLen)
Write-Host ("               : sha256 $tfliteSha")

$keyProps = Join-Path $App 'android\key.properties'
if (-not (Test-Path $keyProps)) {
    Fail "app/android/key.properties is required for a release build (SPEC-C-04)"
}
Write-Host "signing        : key.properties present"

# --------------------------------------------------------------------------- build

if (-not $SkipBuild) {
    Step "flutter build apk --release (version $Version)"
    Push-Location $App
    try {
        # No --target-platform: the build must contain every ABI the project supports, because
        # the emulator here is x86_64 while real phones are arm64-v8a. Restricting ABIs is a
        # packaging decision for the custodian, not something this script should decide.
        & $flutter build apk --release
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) { Fail "flutter build apk failed (exit $code)" }
}

# --------------------------------------------------------------------------- collect

Step 'Collecting the artifact'

$built = Join-Path $App 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $built)) { Fail "APK not produced: $built" }

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
# ADR-32: the app version (pubspec `version:`) and the artifact name are two different facts.
# Swapping the acoustic model does not change versionName/versionCode, so a plain rerun would
# silently overwrite the previous 595 MB APK and leave no way to tell which model it carried.
# `-OutName` names the artifact explicitly; refuse to clobber an existing file unless -Force.
$final = if ($OutName) { Join-Path $Dist $OutName }
         else { Join-Path $Dist "AcouDiet-$Version-arm64-release.apk" }
if ((Test-Path $final) -and -not $Force) {
    Fail ("$final already exists. Pass a different -OutName, or -Force to overwrite it " +
          "(the previous artifact cannot be recovered once overwritten).")
}
Copy-Item $built $final -Force

$apk = Get-Item $final
Write-Host ("APK            : {0}" -f $apk.FullName)
Write-Host ("size           : {0:N0} bytes ({1:N1} MB)" -f $apk.Length, ($apk.Length / 1MB))

# --------------------------------------------------------------------------- verify contents

Step 'Verifying the APK actually contains the model the card names'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($apk.FullName)
try {
    $entries = $zip.Entries | ForEach-Object { $_.FullName }

    $wanted = @(
        ("assets/flutter_assets/assets/models/$tfliteName"),
        'assets/flutter_assets/assets/models/model_card.json',
        'lib/arm64-v8a/libtensorflowlite_jni.so'
    )
    foreach ($w in $wanted) {
        $hit = $zip.Entries | Where-Object { $_.FullName -eq $w }
        if (-not $hit) {
            Write-Host "  MISSING: $w" -ForegroundColor Red
            $script:missing = $true
        } else {
            Write-Host ("  OK  {0}  ({1:N0} bytes)" -f $w, $hit.Length)
        }
    }

    # Byte-level cross-check on the model itself: a truncated or stale asset is worse than a
    # missing one, because it looks fine until the model fails to load on the device.
    $mEntry = $zip.Entries | Where-Object { $_.FullName -eq $wanted[0] }
    if ($mEntry) {
        if ($mEntry.Length -ne $tfliteLen) {
            Write-Host ("  SIZE MISMATCH: apk={0} disk={1}" -f $mEntry.Length, $tfliteLen) -ForegroundColor Red
            $script:missing = $true
        } else {
            $stream = $mEntry.Open()
            try {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $apkSha = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLower()
                } finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
            if ($apkSha -ne $tfliteSha) {
                Write-Host ("  SHA256 MISMATCH: apk={0} disk={1}" -f $apkSha, $tfliteSha) -ForegroundColor Red
                $script:missing = $true
            } else {
                Write-Host ("  model bytes identical: sha256 {0}" -f $apkSha)
            }
        }
    }

    # ADR-34: the on-device language model is gone. If any of its files are still being packaged,
    # the asset list or a stale build directory is wrong -- and it would silently re-bloat the
    # APK by 500+ MB, which is exactly what this rollback was for.
    $llmLeftovers = $entries | Where-Object { $_ -match 'llm|gguf' }
    if ($llmLeftovers) {
        Write-Host "  UNEXPECTED (ADR-34 removed the on-device LLM):" -ForegroundColor Red
        $llmLeftovers | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        $script:missing = $true
    } else {
        Write-Host "  no LLM/gguf entries in the APK (ADR-34 rollback confirmed)"
    }

    Write-Host ""
    Write-Host "  native libs in APK:"
    $entries | Where-Object { $_ -like 'lib/*' } | Sort-Object | ForEach-Object {
        Write-Host ("    {0}" -f $_)
    }
} finally {
    $zip.Dispose()
}

if ($script:missing) { Fail "the APK is missing a required artifact (see MISSING above)" }

# --------------------------------------------------------------------------- hash

Step 'SHA-256'
$hash = (Get-FileHash $apk.FullName -Algorithm SHA256).Hash.ToLower()
Write-Host "sha256         : $hash"
Set-Content -Path "$final.sha256" -Value "$hash  $([System.IO.Path]::GetFileName($final))" -Encoding ascii

# --------------------------------------------------------------------------- page alignment

# ADR-35: a `.so` whose ELF LOAD segments are 4 KB-aligned cannot be mapped on a 16 KB-page
# device (Android 15+), so the model would simply never load on the newest phones. The build
# against tensorflow-lite:2.16.1 shipped exactly such a library and nothing noticed, because the
# only way to see it was to install the APK. This runs the check on the artifact just produced.
Step 'Page alignment (16 KB devices)'
$alignCheck = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool\check_page_alignment.py'
if (Test-Path $alignCheck) {
    $py = 'D:\Desktop\Food\_toolchain\dl\python\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py $alignCheck $apk.FullName
    if ($LASTEXITCODE -ne 0) {
        Fail "the APK is not 16 KB page compatible (see the report above)"
    }
} else {
    Fail "page-alignment checker missing: $alignCheck"
}

Step 'Done'
Write-Host $apk.FullName

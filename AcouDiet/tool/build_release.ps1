# AcouDiet -- release build, signing and evidence collection (SPEC-C-04 / PLAN-C-04).
#
# ⚠️ THIS FILE MUST KEEP ITS UTF-8 BOM. It contains Chinese comments AND Chinese string literals
# (the generated release index is in Chinese). Windows PowerShell 5.1 reads a BOM-less file as
# ANSI/GBK, which mis-decodes those bytes and makes the script a **parse error** -- not a
# cosmetic problem: `powershell -File tool\build_release.ps1` fails before executing a line.
# Measured: 7 parse errors without the BOM, 0 with it. If you edit this file with a tool that
# drops the BOM, re-add it (`Set-Content -Encoding UTF8` on PS 5.1 writes one; or
# `[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))`).
#
# AcouDiet -- release build, signing and evidence collection (SPEC-C-04 / PLAN-C-04).
#
#   powershell -File tool\build_release.ps1            # full run: analyze -> build -> evidence -> archive
#   powershell -File tool\build_release.ps1 -AnalyzeOnly
#   powershell -File tool\build_release.ps1 -Universal # single universal APK (must be re-evidenced)
#
# MUST BE RUN FROM A **NORMAL** TERMINAL (not from inside the DSH sandbox): the sandbox blocks
# the piped stdio that `flutter` and Gradle use for their helper processes, and this checkout
# has no network to resolve Gradle/pub artifacts.
#
# What it does, in the order SPEC-C-04 section 2.2 prescribes:
#   1. activate the toolchain and check that key.properties exists (fails otherwise)
#   2. static analysis, asserting zero `error`
#   3. flutter build apk --release (--split-per-abi by default)
#   4. per-ABI evidence: apksigner verify, aapt dump badging (permission set), sha256, bytes
#   5. archive as docs/release/AcouDiet-v<version>-<yyyyMMdd>-<abi>.apk + apk_sha256.txt
#   6. write docs/release/RELEASE_<version>_<yyyyMMdd>.md (the archive index of SPEC-C-04 section 4)

[CmdletBinding()]
param(
    [switch]$AnalyzeOnly,
    [switch]$Universal,
    [string]$Version = '1.0.0'
)

# 'Continue', NOT 'Stop'. The toolchain's native commands (`flutter`, `gradle`, `adb`) write
# informational text to stderr -- e.g. the FLUTTER_STORAGE_BASE_URL mirror notice -- and Windows
# PowerShell 5.1 turns a native command's stderr into an ErrorRecord, which under 'Stop' becomes
# a **terminating** error. Measured: with 'Stop' this script died at "[1/5] flutter analyze"
# with `NativeCommandError` before it could read a single analyze result. Every gate in this
# script is therefore an EXPLICIT `throw` (plus `$LASTEXITCODE` checks), not a side effect of
# the preference variable -- so 'Continue' loses no strictness that the gates actually relied on.
$ErrorActionPreference = 'Continue'

# `$PSScriptRoot` is `<AcouDiet>\tool`, so its parent is `<AcouDiet>` and the Flutter project is
# one level further down at `<AcouDiet>\app`. Both of these used to be one level short
# (`$App = <AcouDiet>`, `$Root = <workspace>`), which made every path in this script point at the
# wrong tree: it looked for `<AcouDiet>\android\key.properties` (the real one is under `app\`),
# and it would have archived release artifacts into `<workspace>\docs\release` -- a DIFFERENT
# directory that also happens to exist -- instead of `<AcouDiet>\docs\release`.
$App   = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'   # AcouDiet/app
$Root  = Split-Path -Parent $App                              # AcouDiet
$Docs  = Join-Path $Root 'docs\release'                       # AcouDiet/docs/release
$Tool  = 'D:\Desktop\Food\_toolchain'
$Sdk   = "$Tool\android-sdk"
$Stamp = Get-Date -Format 'yyyyMMdd'

New-Item -ItemType Directory -Force -Path $Docs | Out-Null

# ---- 1. toolchain + signing material ----------------------------------------------------
. "$Tool\acoudiet-env.ps1" | Out-Null

if (-not (Test-Path "$App\android\key.properties")) {
    throw "SPEC-C-04: app/android/key.properties is missing. " +
          "Copy key.properties.example and point storeFile at the keystore (kept OUTSIDE the repo). " +
          "A release build must never fall back to the debug signature."
}
Write-Host "key.properties present (contents deliberately not printed)" -ForegroundColor Green

# ---- 2. static analysis: zero errors is a hard gate ------------------------------------
Write-Host "`n[1/5] flutter analyze" -ForegroundColor Cyan
$analyzeLog = Join-Path $Docs "analyze_$Stamp.txt"
Push-Location $App
try {
    & flutter analyze 2>&1 | Tee-Object -FilePath $analyzeLog
} finally {
    Pop-Location
}
$errorCount = (Select-String -Path $analyzeLog -Pattern 'error\s+[•\-]\s' | Measure-Object).Count
$warnCount  = (Select-String -Path $analyzeLog -Pattern 'warning\s+[•\-]\s' | Measure-Object).Count
$infoCount  = (Select-String -Path $analyzeLog -Pattern 'info\s+[•\-]\s' | Measure-Object).Count
Write-Host "analyze: errors=$errorCount warnings=$warnCount info=$infoCount " `
    -ForegroundColor ($(if ($errorCount -eq 0) { 'Green' } else { 'Red' }))
if ($errorCount -ne 0) {
    throw "SPEC-C-04 section 7 #1 failed: $errorCount analyze error(s). Fix them before releasing."
}
if ($AnalyzeOnly) { Write-Host "AnalyzeOnly: stopping here." -ForegroundColor Yellow; exit 0 }

# ---- 3. build --------------------------------------------------------------------------
Write-Host "`n[2/5] flutter build apk --release" -ForegroundColor Cyan
Push-Location $App
try {
    if ($Universal) {
        & flutter build apk --release
    } else {
        & flutter build apk --release --split-per-abi
    }
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# ---- 4/5. evidence + archive -----------------------------------------------------------
Write-Host "`n[3/5] evidence per artifact" -ForegroundColor Cyan

$aapt      = "$Sdk\build-tools\34.0.0\aapt.exe"
$apksigner = "$Sdk\build-tools\34.0.0\apksigner.bat"
if (-not (Test-Path $aapt)) { $aapt = (Get-ChildItem "$Sdk\build-tools" -Recurse -Filter aapt.exe |
                                       Select-Object -First 1).FullName }
if (-not (Test-Path $apksigner)) { $apksigner = (Get-ChildItem "$Sdk\build-tools" -Recurse -Filter apksigner.bat |
                                                 Select-Object -First 1).FullName }

$apkDir = "$App\build\app\outputs\flutter-apk"
$apks   = Get-ChildItem "$apkDir\app-*-release.apk" -ErrorAction SilentlyContinue
if (-not $apks) { throw "SPEC-C-04 section 7 #2 failed: no release APK under $apkDir" }

$appVersion = (Select-String -Path "$App\pubspec.yaml" -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$rows = @()

foreach ($apk in $apks) {
    $abi = ($apk.BaseName -replace '^app-', '' -replace '-release$', '')
    $dst = Join-Path $Docs "AcouDiet-v$Version-$Stamp-$abi.apk"
    Copy-Item $apk.FullName $dst -Force

    $sha   = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    $bytes = (Get-Item $dst).Length

    # signature
    $signOut = & $apksigner verify --print-certs $dst 2>&1
    $signOk  = $LASTEXITCODE -eq 0
    # permissions
    $badging = & $aapt dump badging $dst 2>&1
    $perms = ($badging | Select-String "uses-permission: name='([^']+)'").Matches |
             ForEach-Object { $_.Groups[1].Value } |
             Where-Object { $_ -notlike '*DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION' }
    $hasInternet = ($badging | Select-String 'INTERNET') -ne $null
    $permsOk = ($perms.Count -eq 1 -and $perms[0] -eq 'android.permission.RECORD_AUDIO')

    Write-Host ("  {0,-14} bytes={1,-10} sha256={2}" -f $abi, $bytes, $sha.Substring(0,16) + '...')
    Write-Host ("  {0,-14} signature={1} permissions={2} {3}" -f
        $abi, $(if ($signOk) { 'OK' } else { 'FAIL' }),
        ($perms -join ','), $(if ($permsOk -and -not $hasInternet) { 'OK' } else { 'FAIL' }))

    # NOTE the `${abi}` braces: `"$abi: ..."` does NOT parse -- PowerShell reads `$abi:` as a
    # scope/drive-qualified variable name and fails with "Variable reference is not valid. ':'
    # was not followed by a valid variable name character." These two lines made this script
    # unparseable, i.e. it could never have run at all.
    if (-not $signOk)   { throw "SPEC-C-04 section 7 #3 failed for ${abi}: apksigner verify failed" }
    if ($hasInternet)   { throw "FF-24 item 4 violated: $abi requests INTERNET" }
    if (-not $permsOk)  { throw "FF-24 item 5 violated for ${abi}: permissions = $($perms -join ',')" }

    "$abi sha256=$sha bytes=$bytes" | Add-Content (Join-Path $Docs 'apk_sha256.txt')
    $rows += [pscustomobject]@{ Abi = $abi; Path = "docs/release/$(Split-Path $dst -Leaf)";
                                Sha256 = $sha; Bytes = $bytes }
}

# model artifact size -- FF-16 has TWO tiers and the card names which one ships.
# This check used to hardcode the INT8 ceiling (2.5 MB) for whatever .tflite it found, which is a
# third instance of the same misreading that ADR-21 corrected in ModelRegistry,
# tool/install_model.py and tool/verify_artifacts.py: FF-16 says "FP32 <= 6 MB; INT8 <= 2.5 MB",
# so a 4 MB fp32 model is LEGAL and the old check would have aborted a valid release.
Write-Host "`n[4/5] model artifact" -ForegroundColor Cyan
$cardPath = "$App\assets\models\model_card.json"
$tfliteBytes = 0
if (-not (Test-Path $cardPath)) {
    Write-Host "  no model_card.json -- the release is INCOMPLETE (recorded as 0 in the index)" -ForegroundColor Yellow
} else {
    $card = Get-Content $cardPath -Raw | ConvertFrom-Json
    $tier = $card.quantization
    $caps = @{ 'int8' = 2.5 * 1024 * 1024; 'fp32' = 6 * 1024 * 1024 }
    if (-not $caps.ContainsKey($tier)) {
        throw "FF-16 / SPEC-C-04 section 7 #6 failed: model_card.quantization is '$tier', expected one of int8/fp32"
    }
    # Resolve the artifact through the CARD, exactly like ModelRegistry does, so this check
    # cannot silently measure a different file than the app loads.
    $tflite = Join-Path "$App\assets\models" "$($card.name)_${tier}_v$($card.version).tflite"
    if (-not (Test-Path $tflite)) {
        throw "SPEC-C-04 section 7 #6 failed: the card names $tflite but it does not exist"
    }
    $tfliteBytes = (Get-Item $tflite).Length
    $limit = $caps[$tier]
    $ok = $tfliteBytes -le $limit
    Write-Host ("  {0}: {1} bytes ({2:N2} MB) tier={3} limit {4:N2} MB -> {5}" -f
        (Split-Path $tflite -Leaf), $tfliteBytes, ($tfliteBytes / 1MB), $tier,
        ($limit / 1MB), $(if ($ok) { 'OK' } else { 'FAIL' }))
    if (-not $ok) {
        throw "FF-16 / SPEC-C-04 section 7 #6 failed: model exceeds the $tier ceiling of $limit bytes"
    }
    if ([int]$card.tfliteBytes -ne $tfliteBytes) {
        throw "SPEC-C-04 section 7 #6 failed: model_card.tfliteBytes=$($card.tfliteBytes) but the file is $tfliteBytes"
    }
}

# archive index (SPEC-C-04 section 4)
Write-Host "`n[5/5] archive index" -ForegroundColor Cyan
$freezeCommit = (& git -C (Split-Path $Root -Parent) rev-parse --short HEAD 2>$null)
if (-not $freezeCommit) { $freezeCommit = 'unavailable' }

$index = @()
$index += "# RELEASE $Version ($Stamp)"
$index += ""
$index += "| 字段 | 值 |"
$index += "|---|---|"
$index += "| ``appVersion`` | ``$appVersion`` |"
$index += "| ``apkPath`` | $(($rows | ForEach-Object { '`' + $_.Path + '`' }) -join ' / ') |"
$index += "| ``apkSha256`` | $(($rows | ForEach-Object { '`' + $_.Sha256 + '`' }) -join ' / ') |"
$index += "| ``apkBytes`` | $(($rows | ForEach-Object { $_.Bytes }) -join ' / ') |"
$index += "| ``tfliteBytes`` | $tfliteBytes |"
$index += "| ``permissions`` | ``[""'android.permission.RECORD_AUDIO""]`` |"
$index += "| ``freezeCommit`` | ``$freezeCommit`` |"
$index += "| ``analyzeErrors`` | $errorCount |"
$index += ""
$index += "ABI 清单：$(($rows | ForEach-Object { $_.Abi }) -join ', ')"
$index += ""
$index += "分析日志：``docs/release/analyze_$Stamp.txt``（warnings=$warnCount, info=$infoCount，均不阻塞但须记录）"
$index += "哈希清单：``docs/release/apk_sha256.txt``"
$index += ""
$index += "> 生成命令：``powershell -File tool\build_release.ps1$(if ($Universal) { ' -Universal' })``"
$index += "> 本文件由脚本生成；发布前检查清单见 ``docs/release/pre_release_checklist_$Stamp.md``。"

$indexPath = Join-Path $Docs "RELEASE_${Version}_$Stamp.md"
$index | Set-Content -Path $indexPath -Encoding UTF8
Write-Host "  wrote $indexPath" -ForegroundColor Green

Write-Host "`nDONE. Next: fill docs/release/pre_release_checklist_$Stamp.md, then" -ForegroundColor Cyan
Write-Host "      git tag v$Version-freeze    # R-14 closure: no commits after this point" -ForegroundColor Cyan

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
#   powershell -File tool\build_release.ps1            # full run, agent flavour (the default)
#   powershell -File tool\build_release.ps1 -Flavour offline   # offline flavour (no INTERNET)
#   powershell -File tool\build_release.ps1 -AnalyzeOnly
#   powershell -File tool\build_release.ps1 -Universal # single universal APK (must be re-evidenced)
#
# ADR-44 delivers TWO product flavours and both must be built and evidenced; there is no single
# "the release APK" any more. This script builds one flavour per run and asserts that flavour's
# own permission set, instead of the single pre-ADR-44 rule:
#   offline -> exactly {RECORD_AUDIO}, no INTERNET (the original evidence chain, unchanged)
#   agent   -> exactly {RECORD_AUDIO, INTERNET} (the new posture; default here)
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
#   5. archive as release/AcouDiet-v<version>-<yyyyMMdd>-<abi>-<flavour>.apk + apk_sha256.txt
#   6. write release/RELEASE_<version>_<yyyyMMdd>.md (the archive index of SPEC-C-04 section 4)

[CmdletBinding()]
param(
    [switch]$AnalyzeOnly,
    [switch]$Universal,
    [string]$Version = '1.0.0',
    # ADR-44 product flavour. `agent` is the default because it is the shipped posture; pass
    # `offline` to build the no-INTERNET evidence-chain flavor.
    [string]$Flavour = 'agent'
)

# 'Continue', NOT 'Stop'. The toolchain's native commands (`flutter`, `gradle`, `adb`) write
# informational text to stderr -- e.g. the FLUTTER_STORAGE_BASE_URL mirror notice -- and Windows
# PowerShell 5.1 turns a native command's stderr into an ErrorRecord, which under 'Stop' becomes
# a **terminating** error. Measured: with 'Stop' this script died at "[1/5] flutter analyze"
# with `NativeCommandError` before it could read a single analyze result. Every gate in this
# script is therefore an EXPLICIT `throw` (plus `$LASTEXITCODE` checks), not a side effect of
# the preference variable -- so 'Continue' loses no strictness that the gates actually relied on.
$ErrorActionPreference = 'Continue'

# `$PSScriptRoot` is `<root>\tool`, so its parent is the repository root and the Flutter project is
# one level further down at `<root>\app`. Both of these used to be one level short
# (`$App = <root>`, `$Root = <parent of root>`), which made every path in this script point at the
# wrong tree: it looked for `<root>\android\key.properties` (the real one is under `app\`), and it
# would have archived release artifacts into a sibling directory that also happens to exist.
# ADR-51 moved the archive to `<root>\release\` and made `<root>` the repository root itself.
$App   = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'   # <root>/app
$Root  = Split-Path -Parent $App                              # repository root
$Docs  = Join-Path $Root 'release'                          # ADR-51: release/ holds the archive
$Tool  = 'D:\Desktop\Food\_toolchain'
$Sdk   = "$Tool\android-sdk"
$Stamp = Get-Date -Format 'yyyyMMdd'

New-Item -ItemType Directory -Force -Path $Docs | Out-Null

# ---- ADR-44 flavour selection: fail fast on a bad value ---------------------------------
# The expected permission set is derived here, once, and used by BOTH the build invocation and
# the post-build evidence gate, so the two can never disagree about what "correct" means.
$Flavour = $Flavour.ToLowerInvariant()
if ($Flavour -ne 'offline' -and $Flavour -ne 'agent') {
    throw "ADR-44: -Flavour must be 'offline' or 'agent', got '$Flavour'."
}
if ($Flavour -eq 'offline') {
    $expectInternet = $false
    $expectedPerms  = @('android.permission.RECORD_AUDIO')
    $internetText   = 'absent (offline flavour: the original no-network evidence chain)'
} else {
    $expectInternet = $true
    $expectedPerms  = @('android.permission.RECORD_AUDIO', 'android.permission.INTERNET')
    $internetText   = 'present (agent flavour: the cloud export ADR-44 introduced)'
}
Write-Host "flavour=$Flavour  expected permissions: $($expectedPerms -join ', ')  INTERNET: $internetText" `
    -ForegroundColor Green

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
# `--flavor` selects the ADR-44 manifest overlay (agent adds INTERNET plus <queries>) and
# `--dart-define=ACOUDIET_FLAVOUR` carries the SAME value into the Dart string table. Two
# reasons for the define rather than a runtime switch:
#   * the offline flavour must keep the exact "no INTERNET permission" privacy wording and the
#     agent flavour must NOT claim it, so the wording has to differ per flavour;
#   * a compile-time constant cannot be wrong at runtime, while a runtime switch read from
#     platform state could disagree with the manifest that was actually merged.
# `app/lib/core/flavour.dart` reads it with `String.fromEnvironment('ACOUDIET_FLAVOUR',
# defaultValue: 'agent')`, so an unflavoured debug build behaves like the agent flavour.
Write-Host "`n[2/5] flutter build apk --release (flavour $Flavour)" -ForegroundColor Cyan
Push-Location $App
try {
    if ($Universal) {
        & flutter build apk --release --flavor $Flavour "--dart-define=ACOUDIET_FLAVOUR=$Flavour"
    } else {
        & flutter build apk --release --flavor $Flavour --split-per-abi "--dart-define=ACOUDIET_FLAVOUR=$Flavour"
    }
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk --flavor $Flavour failed (exit $LASTEXITCODE)" }
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
# ⚠️ ADR-44 REAL BUG, found on the first two-flavour run: this glob used to be
# `app-*-release.apk`, which matches EVERY flavour's APKs. `build\...\flutter-apk\` is not
# cleared between runs, so building `offline` straight after `agent` audited the AGENT artifacts
# and correctly-but-uselessly reported "the offline flavour must NOT request INTERNET, but
# arm64-v8a-agent does" -- pointing the failure at the wrong file. The gate's RULE was right;
# its INPUT was wrong, which is the more dangerous of the two because the message looks like a
# real violation of the thing you are building.
#
# The flavour is now part of the glob, so each run audits exactly the artifacts it produced.
# Pre-ADR-44 this could not happen: there was only one flavour, so "every APK in the directory"
# and "the APK I just built" were the same set.
$apks   = Get-ChildItem "$apkDir\app-*-$Flavour-release.apk" -ErrorAction SilentlyContinue
if (-not $apks) {
    $present = (Get-ChildItem "$apkDir\app-*-release.apk" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name }) -join ', '
    throw ("SPEC-C-04 section 7 #2 failed: no '$Flavour' release APK under $apkDir " +
           "(found instead: $present). A stale APK from ANOTHER flavour must never be audited " +
           "as if it were this one -- see ADR-44.")
}

$appVersion = (Select-String -Path "$App\pubspec.yaml" -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$rows = @()

foreach ($apk in $apks) {
    # ADR-44: `flutter.groovy` names the copy `app<-abi>?<-flavor>-<build-mode>.apk`, i.e. the
    # flavour comes AFTER the ABI (`app-arm64-v8a-agent-release.apk`), so it has to be stripped
    # rather than assumed at the front. A universal build has no ABI segment at all and reduces
    # to a bare `app-<flavour>-release.apk`.
    # Order matters: strip the trailing segments first, then the `app-` prefix, so the
    # universal case ends as an empty stem instead of leaving the flavour behind as an "ABI".
    $stem = $apk.BaseName -replace '-release$', ''
    $stem = $stem -replace "-$Flavour$", ''
    $stem = $stem -replace '^app-', ''
    # A universal build leaves the bare prefix behind (`app`); it has no ABI segment.
    if ($stem -eq 'app') { $stem = '' }
    $stem = $stem.Trim('-')
    $abi = $(if ($stem) { $stem } else { 'universal' })
    # The flavour goes into the archived name: without it, building `offline` and then `agent`
    # into the same docs/release would silently overwrite the first artifact with the second.
    $dst = Join-Path $Docs "AcouDiet-v$Version-$Stamp-$abi-$Flavour.apk"
    Copy-Item $apk.FullName $dst -Force

    $sha   = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    $bytes = (Get-Item $dst).Length

    # signature
    $signOut = & $apksigner verify --print-certs $dst 2>&1
    $signOk  = $LASTEXITCODE -eq 0
    # permissions
    $badging = & $aapt dump badging $dst 2>&1
    # `@(...)` is load-bearing: with a single permission the pipeline yields a bare STRING, and
    # `$perms[0]` on a string is its first CHARACTER. The pre-ADR-44 line compared that character
    # against the permission name, so the offline gate could never have accepted a correct APK.
    $perms = @(($badging | Select-String "uses-permission: name='([^']+)'").Matches |
               ForEach-Object { $_.Groups[1].Value } |
               Where-Object { $_ -notlike '*DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION' })
    $hasInternet = ($badging | Select-String 'INTERNET') -ne $null
    # Order independent set equality: sorting both sides before joining means a reordered
    # manifest is still "the same permission set", which is what FF-24 item 5 actually says.
    $permsOk = ((($perms | Sort-Object) -join ',') -eq (($expectedPerms | Sort-Object) -join ','))
    $internetOk = ($hasInternet -eq $expectInternet)

    Write-Host ("  {0,-14} bytes={1,-10} sha256={2}" -f $abi, $bytes, $sha.Substring(0,16) + '...')
    Write-Host ("  {0,-14} signature={1} permissions={2} internet={3} {4}" -f
        $abi, $(if ($signOk) { 'OK' } else { 'FAIL' }),
        ($perms -join ','), $hasInternet,
        $(if ($permsOk -and $internetOk) { 'OK' } else { 'FAIL' }))

    # NOTE the `${abi}` braces: `"$abi: ..."` does NOT parse -- PowerShell reads `$abi:` as a
    # scope/drive-qualified variable name and fails with "Variable reference is not valid. ':'
    # was not followed by a valid variable name character." These two lines made this script
    # unparseable, i.e. it could never have run at all.
    if (-not $signOk)      { throw "SPEC-C-04 section 7 #3 failed for ${abi}: apksigner verify failed" }
    # FF-24 item 4 as amended by ADR-44: the expectation is a property of the FLAVOUR, not of
    # "an APK" -- offline must not hold INTERNET, agent must.
    if ($hasInternet -and -not $expectInternet) {
        throw "FF-24 item 4 (ADR-44) violated: the $Flavour flavour must NOT request INTERNET, but ${abi} does"
    }
    if (-not $hasInternet -and $expectInternet) {
        throw "FF-24 item 4 (ADR-44) violated: the $Flavour flavour must request INTERNET, but ${abi} does not"
    }
    if (-not $permsOk)     {
        throw "FF-24 item 5 (ADR-44) violated for ${abi}: the $Flavour flavour must declare exactly " +
              "[$($expectedPerms -join ', ')], got [$($perms -join ', ')]"
    }

    # ⚠️ ADR-44 REAL DEFECT, found by reading the file after the first two-flavour release.
    #
    # This line used to be `"$abi sha256=$sha bytes=$bytes"` and to be APPENDED. With one flavour
    # that was fine. With two it produces a file that is useless for its one purpose:
    #
    #   arm64-v8a sha256=d715ebff... bytes=27856234     <- which flavour is this?
    #   arm64-v8a sha256=e9d6dfe3... bytes=27069194     <- and this?
    #   arm64-v8a sha256=d715ebff... bytes=27856234     <- and why is it here twice?
    #
    # Measured state after building `agent` twice and `offline` once: NINE lines, no flavour
    # column, three of them duplicates. An evidence file you cannot attribute is not evidence.
    #
    # Fix, two parts: (1) the ARCHIVED FILE NAME is the key -- it carries the version, the date,
    # the ABI and the flavour, so the line is self-identifying; (2) the write is IDEMPOTENT per
    # file name, so rebuilding a flavour replaces its own lines instead of stacking them.
    $shaFile = Join-Path $Docs 'apk_sha256.txt'
    $apkLeaf = Split-Path $dst -Leaf
    $kept = @()
    if (Test-Path $shaFile) {
        $kept = @(Get-Content $shaFile | Where-Object { $_ -notmatch [regex]::Escape($apkLeaf) })
    }
    ($kept + "$apkLeaf sha256=$sha bytes=$bytes" | Sort-Object) |
        Set-Content -Path $shaFile -Encoding ascii
    $rows += [pscustomobject]@{ Abi = $abi; Path = "release/$(Split-Path $dst -Leaf)";
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
$freezeCommit = (& git -C $Root rev-parse --short HEAD 2>$null)
if (-not $freezeCommit) { $freezeCommit = 'unavailable' }

# ADR-44: the evidenced permission set belongs to the FLAVOUR that was built, so it is rendered
# from $expectedPerms rather than from a literal that predates the flavours.
$permCell = '[' + (($expectedPerms | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
$flavourArgs = "-Flavour $Flavour$(if ($Universal) { ' -Universal' })"

$index = @()
$index += "# RELEASE $Version ($Stamp)"
$index += ""
$index += "| 字段 | 值 |"
$index += "|---|---|"
$index += "| ``appVersion`` | ``$appVersion`` |"
$index += "| ``flavour`` | ``$Flavour`` |"
$index += "| ``apkPath`` | $(($rows | ForEach-Object { '`' + $_.Path + '`' }) -join ' / ') |"
$index += "| ``apkSha256`` | $(($rows | ForEach-Object { '`' + $_.Sha256 + '`' }) -join ' / ') |"
$index += "| ``apkBytes`` | $(($rows | ForEach-Object { $_.Bytes }) -join ' / ') |"
$index += "| ``tfliteBytes`` | $tfliteBytes |"
$index += "| ``permissions`` | ``$permCell`` |"
$index += "| ``freezeCommit`` | ``$freezeCommit`` |"
$index += "| ``analyzeErrors`` | $errorCount |"
$index += ""
$index += "ABI 清单：$(($rows | ForEach-Object { $_.Abi }) -join ', ')"
$index += ""
$index += "分析日志：``release/analyze_$Stamp.txt``（warnings=$warnCount, info=$infoCount，均不阻塞但须记录）"
$index += "哈希清单：``release/apk_sha256.txt``"
$index += ""
$index += "> 生成命令：``powershell -File tool\build_release.ps1 $flavourArgs``"
$index += "> 本文件由脚本生成；发布前检查清单见 ``release/pre_release_checklist_$Stamp.md``。"

# ⚠️ ADR-48 REAL DEFECT, found while producing the second two-flavour release: this path used to be
# `RELEASE_${Version}_$Stamp.md` -- with NO flavour in it. Both flavours therefore wrote the SAME
# file, and the second run silently destroyed the first one's record while its own rows claimed to
# describe a whole release. The v1.3.0 agent note was lost that way; only `apk_sha256.txt` (which is
# keyed per file, ADR-44) survived. The index describes ONE flavour -- it always did, see the
# `flavour` row below -- so it must be named after that flavour.
$indexPath = Join-Path $Docs "RELEASE_${Version}_${Stamp}_$Flavour.md"
$index | Set-Content -Path $indexPath -Encoding UTF8
Write-Host "  wrote $indexPath" -ForegroundColor Green

# ---- 16 KB page compatibility, on the artifacts THIS RUN produced -------------------------
#
# `tool/check_page_alignment.py` has existed since ADR-35, but it defaults to the newest APK in
# `dist/` -- and this script archives to `release/`. So `verify_all.ps1`'s alignment step has
# been checking whatever stale package happens to sit in `dist/`, i.e. **not the build it is
# supposed to be guarding**. It is run here, per-ABI, against the files just written.
#
# This is the same shape as everything else in this session: the check existed, was correct, and
# was pointed at the wrong input. `tool/build_release_v11.ps1` (the older script) did call it; this
# one never did.
$alignCheck = Join-Path $PSScriptRoot 'check_page_alignment.py'
if (-not (Test-Path $alignCheck)) {
    throw "page-alignment checker missing: $alignCheck -- cannot make the 16 KB claim"
}
# The toolchain Python, spelled the same way the rest of this script spells the toolchain root.
$pyExe = "$Tool\dl\python\python.exe"
if (-not (Test-Path $pyExe)) { throw "toolchain python not found: $pyExe" }
Write-Host "`n[6/6] 16 KB page compatibility (per archived artifact)" -ForegroundColor Cyan
$alignBad = 0
foreach ($row in $rows) {
    # `$rows` carries `Path` (relative, `release/<file>`), not an absolute path.
    $apk = Join-Path $Docs (Split-Path $row.Path -Leaf)
    & $pyExe $alignCheck $apk | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  !! $($row.Abi): NOT 16 KB compatible" -ForegroundColor Red
        $alignBad = 1
    } else {
        Write-Host "  $($row.Abi)  -> 16 KB COMPATIBLE" -ForegroundColor Green
    }
}
if ($alignBad -ne 0) {
    throw ("the APK is not 16 KB page compatible -- on Android 15 the packaged .so cannot be " +
           "mapped, so the model would fail to load. See ADR-35 / check_page_alignment.py.")
}

Write-Host "`nDONE. Next: fill release/pre_release_checklist_$Stamp.md, then" -ForegroundColor Cyan
Write-Host "      git tag v$Version-freeze    # R-14 closure: no commits after this point" -ForegroundColor Cyan

# AcouDiet -- boot an emulator, install the APK and prove the app actually starts.
#
#   powershell -File tool\run_on_emulator.ps1
#
# WHY THIS EXISTS
# ---------------
# `flutter build apk --debug` proves the APK is *produced*. It does not prove the app *runs*:
# the first frame, the L1 Kotlin audio service binding, the SQLite open and the C-03 handshake
# all happen after the process launches. Everything up to this script is static or unit-level
# evidence; this is the first end-to-end execution on an Android runtime.
#
# WHAT "STARTED" MEANS HERE (each is checked, not assumed)
#   1. the emulator boots to `sys.boot_completed=1` and `pm` is usable;
#   2. `adb install` returns Success;
#   3. `am start` reports the activity and it becomes the **top resumed** activity;
#   4. a process exists for the package;
#   5. logcat has no `FATAL EXCEPTION` / `AndroidRuntime` crash;
#   6. a screenshot is pulled and is **not** a uniform image (pixel variance), because a blank
#      surface is exactly what a silently-failed first frame looks like.
#   7. **the shipped model actually loaded** (ADR-22). Added because criteria 1-6 were ALL green
#      on a build whose model could not be opened at all: `TfLiteModelCreateFromFile` needs a
#      filesystem path and a Flutter asset lives inside the APK, so logcat said
#      `Could not open 'assets/models/...'` while this script printed "APP STARTED".
#      "The app runs" and "the model is usable" are two different facts.
#
# Exit code 0 iff all seven hold.
# BUGS THIS SCRIPT ITSELF HAD (kept as a warning, because the first version lied)
#   * `$failures += ...` inside a `Step` scriptblock ran in the block's own child scope, so
#     every recorded failure was discarded and the script printed "APP STARTED" while its own
#     `resumed activity` check had returned False. Scope-prefixed now (`$script:`).
#   * `$pid` is a read-only PowerShell automatic variable; assigning to it threw, and the "pid"
#     printed was the *shell's* pid. Renamed.
#   * `adb exec-out screencap -p > file` corrupts the PNG, because PowerShell `>` is a **text**
#     redirection. Now `screencap` to the device then `adb pull`.
#   * `mResumedActivity` is the pre-Android-10 dumpsys field; current releases report
#     `topResumedActivity`. The old grep never matched.
#   * the emulator inherited the console and its INFO chatter interleaved with adb output,
#     corrupting parsed results. Its stdio now goes to a log file.
#
# Exit code 0 iff all six hold.

[CmdletBinding()]
param(
    [string]$AvdName = 'acoudiet_api34',
    [int]$BootTimeoutSec = 420,
    [string]$SystemImage = 'system-images;android-34;google_apis;x86_64',
    # Which APK to install. Defaults to the debug build, but pointing it at a RELEASE build is
    # how the shipped artifact gets device-verified -- and it must be a multi-ABI release,
    # because this emulator is x86_64 and an arm64-only APK is rejected with
    # INSTALL_FAILED_NO_MATCHING_ABIS (see PHONE_INSTALL.md section 0).
    [string]$Apk = '',
    # Uninstall the package before installing. Required when the new APK is signed with a
    # different key than the installed one (debug key vs release/test key) -- Android then
    # refuses the install with INSTALL_FAILED_UPDATE_INCOMPATIBLE and the launch step silently
    # exercises the OLD build, which is a false result in either direction.
    [switch]$UninstallFirst,
    # Seconds to let the app settle after `am start` before the running/logcat checks. A cold
    # AOT release launch is slower than a debug one; 12 s was tuned on debug builds only.
    [int]$SettleSec = 20,
    [switch]$SkipCreate,
    [switch]$KeepEmulator
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot                        # AcouDiet/
$Tool = 'D:\Desktop\Food\_toolchain'
$Sdk = "$Tool\android-sdk"
$Adb = "$Sdk\platform-tools\adb.exe"
$Emu = "$Sdk\emulator\emulator.exe"
$AvdManager = "$Sdk\cmdline-tools\latest\bin\avdmanager.bat"
$Apk = if ($Apk) { $Apk } else { "$Root\app\build\app\outputs\flutter-apk\app-debug.apk" }
$Package = 'com.acoudiet.app'
$OutDir = "$Root\docs\demo\emulator_run"

$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_USER_HOME = "$Tool\cache\android"
$env:ANDROID_AVD_HOME = "$Tool\cache\android\avd"
$env:JAVA_HOME = "$Tool\jdk17"
$env:PATH = "$Tool\jdk17\bin;$env:PATH"
$env:TMP = "$Tool\tmp"; $env:TEMP = "$Tool\tmp"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# `$script:` is load-bearing: a bare `$failures +=` inside a Step block would write to the
# block's child scope and vanish, which is how the first version of this script reported a
# passing run while its own checks had failed.
$script:failures = @()
$script:emuProc = $null

function Step([string]$Name, [scriptblock]$Body) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host ">>> $Name" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    & $Body
}

function Stop-Emulator {
    if ($script:emuProc -and -not $script:emuProc.HasExited) {
        & $Adb emu kill 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if (-not $script:emuProc.HasExited) { Stop-Process -Id $script:emuProc.Id -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- preconditions
Step "preconditions" {
    foreach ($p in @($Adb, $Emu, $AvdManager)) {
        if (-not (Test-Path $p)) { $script:failures += "missing: $p" }
        Write-Host ("  {0}  {1}" -f (Test-Path $p), $p)
    }
    if (-not (Test-Path $Apk)) { $script:failures += "APK not built (run: flutter build apk --debug)" }
    else { Write-Host ("  APK {0:N0} bytes" -f (Get-Item $Apk).Length) }
}

if ($script:failures.Count -gt 0) {
    Write-Host ""; Write-Host "PRECONDITIONS FAILED" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    exit 2
}

# ---------------------------------------------------------------- AVD
Step "create AVD '$AvdName'" {
    if ($SkipCreate) { Write-Host "  skipped"; return }
    if ((& $AvdManager list avd 2>&1 | Out-String) -match [regex]::Escape($AvdName)) {
        Write-Host "  already exists"; return
    }
    "no`r`n" | & $AvdManager create avd --force --name $AvdName `
        --package $SystemImage --device "pixel_5" 2>&1 | Select-Object -Last 4
    Write-Host "  created"
}

# ---------------------------------------------------------------- boot
Step "boot emulator" {
    & $Adb kill-server 2>&1 | Out-Null
    & $Adb start-server  2>&1 | Out-Null

    # `-no-window` is deliberate: `screencap` captures the framebuffer anyway, so a visible
    # window buys nothing and a headless emulator is far more stable.
    $emuArgs = @(
        '-avd', $AvdName,
        '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
        '-gpu', 'swiftshader_indirect',
        '-memory', '2048',
        '-netdelay', 'none', '-netspeed', 'full'
    )
    $emuLog = "$OutDir\emulator.log"
    Write-Host "  emulator $($emuArgs -join ' ')"
    $script:emuProc = Start-Process -FilePath $Emu -ArgumentList $emuArgs -PassThru `
        -RedirectStandardOutput $emuLog -RedirectStandardError "$OutDir\emulator.err.log"
    Write-Host "  pid=$($script:emuProc.Id)  log=$emuLog"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
    $booted = $false
    while ((Get-Date) -lt $deadline) {
        if ((& $Adb shell getprop sys.boot_completed 2>&1 | Out-String).Trim() -eq '1') { $booted = $true; break }
        if ($script:emuProc.HasExited) { Write-Host "  emulator exited early" -ForegroundColor Red; break }
        Start-Sleep -Seconds 5
    }
    if ($booted) { Write-Host "  boot_completed=1" -ForegroundColor Green }
    else { $script:failures += "emulator did not boot within ${BootTimeoutSec}s" }
}

if ($script:failures.Count -gt 0) {
    Write-Host ""; Write-Host "BOOT FAILED" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    & $Adb devices -l 2>&1 | ForEach-Object { "  $_" }
    Stop-Emulator
    exit 3
}

Step "wait for package manager + install APK" {
    # `boot_completed` precedes a usable `pm`; without this the install races the system server.
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ((& $Adb shell pm path android 2>&1 | Out-String) -match 'package:') { $ready = $true; break }
        Start-Sleep -Seconds 3
    }
    Write-Host "  pm ready: $ready"

    if ($UninstallFirst) {
        # Needed whenever the previously installed build had a DIFFERENT signer: Android refuses
        # to replace an app whose signature changed (INSTALL_FAILED_UPDATE_INCOMPATIBLE). A debug
        # build (debug key) and a release build (test key) collide exactly this way.
        & $Adb uninstall $Package 2>&1 | Out-Null
        Write-Host "  uninstalled any previous $Package"
    }

    & $Adb logcat -c 2>&1 | Out-Null
    $install = (& $Adb install -r -t $Apk 2>&1 | Out-String)
    # The EXIT CODE is authoritative. Matching the word "Success" in the text is not: a truncated
    # or raced capture yields neither "Success" nor a failure line, and the previous version of
    # this script then recorded a failure while the app was in fact installed and running.
    $installExit = $LASTEXITCODE
    $install.Trim() -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { "  " + $_.Trim() }
    Write-Host "  adb install exit=$installExit"
    if ($installExit -ne 0) {
        $script:failures += "adb install failed (exit $installExit)"
        return
    }

    # Print WHAT got installed, so "the APK under test" is identified rather than assumed.
    $pkg = (& $Adb shell dumpsys package $Package 2>&1 | Out-String)
    $vn = ([regex]::Match($pkg, 'versionName=(\S+)')).Groups[1].Value
    $vc = ([regex]::Match($pkg, 'versionCode=(\d+)')).Groups[1].Value
    $installedPath = (& $Adb shell pm path $Package 2>&1 | Out-String).Trim()
    Write-Host "  installed: $Package versionName=$vn versionCode=$vc"
    Write-Host "  pm path  : $installedPath"
    if (-not $installedPath) { $script:failures += "the package is not installed after a clean exit" }
}

Step "launch the app" {
    & $Adb shell wm dismiss-keyguard 2>&1 | Out-Null
    & $Adb shell am force-stop $Package 2>&1 | Out-Null
    $start = (& $Adb shell am start -W -n "$Package/.MainActivity" 2>&1 | Out-String)
    Write-Host ($start -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { "  " + $_.Trim() } | Out-String)
    if ($start -match 'Error:|Exception') { $script:failures += "am start reported an error" }
    Start-Sleep -Seconds $SettleSec   # first frame + DB open + handshake + model load
}

Step "is it actually running?" {
    # Android 10+ reports `topResumedActivity`; `mResumedActivity` is the legacy field and the
    # first version of this script only grepped that, so it never matched.
    $acts = (& $Adb shell dumpsys activity activities 2>&1 | Out-String)
    $isResumed = $acts -match "topResumedActivity.*$([regex]::Escape($Package))" -or
    $acts -match "mResumedActivity.*$([regex]::Escape($Package))"
    Write-Host "  top resumed activity is ours: $isResumed"
    if (-not $isResumed) { $script:failures += "app is not the top resumed activity" }

    $appPid = (& $Adb shell pidof $Package 2>&1 | Out-String).Trim()
    Write-Host "  app pid: $appPid"
    if (-not $appPid) { $script:failures += "no process for $Package" }

    $drawn = $acts -match 'Fully drawn|Displayed'
    Write-Host "  (logcat 'Fully drawn' is checked in the next step)"
}

Step "logcat: crashes and Flutter errors" {
    $log = (& $Adb logcat -d 2>&1 | Out-String)
    $log | Set-Content "$OutDir\logcat.txt" -Encoding UTF8

    $fatal = ($log -split "`n") | Where-Object { $_ -match 'FATAL EXCEPTION' -or $_ -match 'AndroidRuntime.*(E |FATAL)' }
    if ($fatal) {
        Write-Host "  FATAL:" -ForegroundColor Red
        $fatal | Select-Object -First 30 | ForEach-Object { "    " + $_.Trim() }
        $script:failures += "FATAL EXCEPTION in logcat"
    } else { Write-Host "  no FATAL EXCEPTION" -ForegroundColor Green }

    $drawn = ($log -split "`n") | Where-Object { $_ -match 'Fully drawn.*acoudiet|Displayed.*acoudiet' }
    if ($drawn) {
        Write-Host "  first frame painted:" -ForegroundColor Green
        $drawn | ForEach-Object { "    " + $_.Trim() }
    } else { $script:failures += "no 'Fully drawn' evidence for our activity" }

    Write-Host "  --- our package / ACD-* lines ---"
    (($log -split "`n") | Where-Object { $_ -match 'acoudiet|ACD-[A-Z]+-\d+' }) |
        Select-Object -Last 20 | ForEach-Object { "    " + $_.Trim() }
}

Step "did the SHIPPED MODEL actually load?" {
    # WHY THIS IS A SEPARATE CHECK (ADR-22)
    # -------------------------------------
    # The six criteria above only prove the app RUNS. They were all green on a build whose model
    # could not load at all -- the logcat said `Could not open 'assets/models/...'` and
    # `The model allocation is null/empty`, because `TfLiteModelCreateFromFile` needs a
    # filesystem path and a Flutter asset lives inside the APK. "The app started" and "the model
    # is usable" are two different facts, and this step is the one that can tell them apart.
    #
    # The checker looks BOTH ways: it fails on the defect signature AND requires the app's own
    # process to have initialised the TFLite runtime, so a silent no-op load cannot pass as
    # "no error seen".
    $checker = 'D:\Desktop\Food\_toolchain\check_emulator_model_log.py'
    if (-not (Test-Path $checker)) {
        $script:failures += "model-log checker missing: $checker"
        return
    }
    $out = & "$Tool\dl\python\python.exe" $checker 2>&1 | Out-String
    $out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 14 |
        ForEach-Object { "  " + $_.TrimEnd() }
    if ($LASTEXITCODE -ne 0) {
        $script:failures += "the shipped model did not load on device (see the model-log check)"
    }
}

Step "screenshot (a blank frame is a failed first frame)" {
    # Text redirection (`>`) corrupts a PNG; capture on-device then `adb pull` the bytes.
    & $Adb shell screencap -p /sdcard/acoudiet_shot.png 2>&1 | Out-Null
    $shot = "$OutDir\home_screen.png"
    (& $Adb pull /sdcard/acoudiet_shot.png $shot 2>&1 | Out-String).Trim() | ForEach-Object { "  $_" }
    if (-not (Test-Path $shot) -or (Get-Item $shot).Length -lt 1000) {
        $script:failures += "screenshot not captured"
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($shot)
    $magic = ($bytes[0..7] | ForEach-Object { $_.ToString('X2') }) -join ' '
    if ($magic -ne '89 50 4E 47 0D 0A 1A 0A') { $script:failures += "screenshot is not a valid PNG ($magic)" }
    Write-Host ("  {0} ({1:N0} bytes, magic {2})" -f $shot, $bytes.Length, $magic)

    # NOTE on the statistic: PNG scanlines are *filtered*, so a smooth light screen encodes as
    # mostly 0x00 bytes and `mean` is meaningless (~1.3 even for a bright page). What is
    # meaningful is the spread (text/edges) plus the file size -- a genuinely blank screenshot
    # compresses to a few KB. The first version of this probe also used `-notmatch` on an array,
    # which returns the *non-matching elements* and is therefore always truthy.
    $probe = & "$Tool\dl\python\python.exe" -c @"
import struct, zlib, os
p = r'$shot'
data = open(p,'rb').read()
size = os.path.getsize(p)
pos, idat, w, h = 8, b'', None, None
while pos < len(data):
    ln = struct.unpack('>I', data[pos:pos+4])[0]; typ = data[pos+4:pos+8]
    if typ == b'IHDR': w, h = struct.unpack('>II', data[pos+8:pos+16])
    if typ == b'IDAT': idat += data[pos+8:pos+8+ln]
    pos += 12 + ln
try:
    raw = zlib.decompress(idat)
    n = len(raw); mean = sum(raw)/n
    stddev = (sum((v-mean)**2 for v in raw)/n) ** 0.5
except Exception as e:
    print('PROBE_FAILED', e); raise SystemExit(0)
print(f'{w}x{h} file={size} raw={n} stddev={stddev:.2f}')
blank = size < 20000 or stddev < 1.0
print('BLANK' if blank else 'HAS_CONTENT')
"@
    $probe | ForEach-Object { "  $_" }
    $verdict = ($probe | Where-Object { $_ -match '^(BLANK|HAS_CONTENT|PROBE_FAILED)' } | Select-Object -Last 1)
    if ($verdict -eq 'BLANK') { $script:failures += "screenshot is blank (first frame never painted)" }
    elseif ($verdict -ne 'HAS_CONTENT') { $script:failures += "screenshot probe failed" }
}

if (-not $KeepEmulator) { Step "shut the emulator down" { Stop-Emulator; Write-Host "  stopped" } }

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
if ($script:failures.Count -eq 0) {
    Write-Host "EMULATOR RUN: APP STARTED (all checks passed)" -ForegroundColor Green
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    exit 0
} else {
    Write-Host "EMULATOR RUN: FAILED" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    exit 1
}

"""Did the SHIPPED model actually load on the device? (ADR-22)

WHY THIS EXISTS
---------------
`run_on_emulator.ps1`'s six criteria prove the app RUNS: boot, install, top-resumed, process
alive, no crash, non-blank first frame. All six were green on a build whose model could NOT
load -- the logcat said

    E tflite : Could not open 'assets/models/acoudiet_fp32_v1.0.0.tflite'.
    E tflite : The model allocation is null/empty

because `TfLiteModelCreateFromFile` needs a filesystem path, and a Flutter asset lives inside
the APK. "The app started" and "the model is usable" are two different facts; this checker is
what tells them apart, and it is wired into the emulator script as its own step.

It looks BOTH ways on purpose:

  * FAIL on the defect signature (either line above);
  * FAIL unless the APP'S OWN PID initialised the TFLite runtime -- so "the load never
    happened at all" cannot pass as "no error was seen". A log with no error and no evidence of
    a load attempt is a silent no-op, not a success.

Usage:
    python _toolchain/check_emulator_model_log.py [logcat.txt]

Exit 0 only when the model demonstrably loaded.
"""

from __future__ import annotations

import io
import re
import sys
from pathlib import Path

DEFAULT_LOG = Path(r"D:\Desktop\Food\records\demo\emulator_run\logcat.txt")
PACKAGE = "com.acoudiet.app"

#: Lines that mean the model could not be opened / allocated.
DEFECT_SIGNATURES = (
    "Could not open 'assets/models",
    "model allocation is null/empty",
)
#: Positive evidence that the app process itself used the TFLite runtime.
INIT_EVIDENCE = "Initialized TensorFlow Lite runtime"

#: logcat threadtime prefix: `MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: ...`
LINE_RE = re.compile(r"^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+(\d+)\s+")


def main(argv: list[str]) -> int:
    log = Path(argv[1]) if len(argv) > 1 else DEFAULT_LOG
    if not log.exists():
        print(f"ACD-RUN-001: no logcat at {log}")
        return 2
    lines = io.open(log, encoding="utf-8", errors="replace").read().splitlines()
    print(f"model-load check: {log}  ({len(lines)} lines)")

    # ---- 1. defect signature ------------------------------------------------------------
    defects = [l for l in lines if any(s.lower() in l.lower() for s in DEFECT_SIGNATURES)]
    print()
    print("-- defect signature --")
    for s in DEFECT_SIGNATURES:
        n = sum(1 for l in lines if s.lower() in l.lower())
        print(f"   {s!r:46s} {n}")
    for l in defects[:6]:
        print("     " + l.strip()[:170])

    # ---- 2. the app's own pids -----------------------------------------------------------
    app_pids = set()
    for l in lines:
        if PACKAGE not in l:
            continue
        m = LINE_RE.match(l)
        if m:
            app_pids.add(m.group(1))
    print()
    print(f"-- pids seen for {PACKAGE}: {sorted(app_pids) or '(none)'}")

    # ---- 3. positive evidence from one of THOSE pids -------------------------------------
    init_from_app = []
    init_any = []
    for l in lines:
        if INIT_EVIDENCE.lower() not in l.lower():
            continue
        init_any.append(l)
        m = LINE_RE.match(l)
        if m and m.group(1) in app_pids:
            init_from_app.append(l)
    print(f"-- '{INIT_EVIDENCE}' lines: {len(init_any)} total, "
          f"{len(init_from_app)} from the app's own pid(s)")
    for l in (init_from_app or init_any)[:4]:
        print("     " + l.strip()[:170])

    print()
    if defects:
        print(f"RESULT: FAIL -- the model could not be opened ({len(defects)} line(s))")
        return 1
    if not init_from_app:
        print("RESULT: FAIL -- no TFLite runtime initialisation attributable to the app's own "
              "process; a load that never happened is not evidence of success")
        return 1
    print("RESULT: PASS -- the app loaded the shipped model on device "
          "(no defect signature + the app's own pid initialised the TFLite runtime)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

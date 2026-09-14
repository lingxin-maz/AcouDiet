"""Negative controls for `check_emulator_model_log.py`.

A checker that cannot fail is not a checker. This builds two fixtures from the real logcat --
one reproducing the pre-fix ADR-22 defect, one where the load silently never happened -- and
asserts the checker rejects both while accepting the real log.
"""

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path

TOOL = Path(r"D:\Desktop\Food\_toolchain")
CHECKER = TOOL / "check_emulator_model_log.py"
PY = TOOL / "dl" / "python" / "python.exe"
REAL = Path(r"D:\Desktop\Food\AcouDiet\docs\demo\emulator_run\logcat.txt")
OUT = TOOL / "tmp"

DEFECT_LINES = (
    "09-12 15:15:51.697  3359  3456 E tflite  : Could not open "
    "'assets/models/acoudiet_fp32_v1.0.0.tflite'.\n"
    "09-12 15:15:51.717  3359  3586 E tflite  : The model allocation is null/empty\n"
)


def run(path: Path) -> int:
    proc = subprocess.run([str(PY), str(CHECKER), str(path)],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.returncode


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    text = io.open(REAL, encoding="utf-8", errors="replace").read()

    real_copy = OUT / "log_real.txt"
    io.open(real_copy, "w", encoding="utf-8").write(text)

    # (a) the pre-fix defect: inject the two signature lines into an otherwise-good log
    defect = OUT / "log_defect.txt"
    io.open(defect, "w", encoding="utf-8").write(
        text.replace("I tflite  : Initialized TensorFlow Lite runtime.",
                     "I tflite  : Initialized TensorFlow Lite runtime.\n" + DEFECT_LINES, 1)
    )

    # (b) silent no-op: no error, but ALSO no evidence the app ever touched the runtime
    silent = OUT / "log_silent.txt"
    io.open(silent, "w", encoding="utf-8").write(
        "\n".join(l for l in text.splitlines()
                  if "Initialized TensorFlow Lite runtime" not in l)
    )

    cases = [("real log (must PASS)", real_copy, 0),
             ("pre-fix defect injected (must FAIL)", defect, 1),
             ("silent no-op, no init evidence (must FAIL)", silent, 1)]
    bad = []
    for name, path, want in cases:
        got = run(path)
        ok = (got == want)
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}: exit={got} expected={want}")
        if not ok:
            bad.append(name)
    print()
    if bad:
        print(f"RESULT: the checker does not discriminate ({bad})")
        return 1
    print("RESULT: the checker discriminates all three cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

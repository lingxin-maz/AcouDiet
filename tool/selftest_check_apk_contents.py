"""Negative controls for `check_apk_contents.py`.

Why: ADR-32 replaced the hardcoded `RELEASED_FP32_SHA256` literal in that checker with a
comparison against the `model_card.json` **packaged inside the APK**. A checker that silently
accepts everything would look identical to a fixed one, so this builds a handful of tiny
synthetic APKs and proves the checker discriminates:

  (a) card and .tflite agree, filename derived from the card  -> exit 0
  (b) the packaged .tflite does not hash to card.tfliteSha256 -> exit 1
  (c) card.tfliteBytes is wrong                               -> exit 1
  (d) the card names a file the APK does not contain          -> exit 1
  (e) no model_card.json in the APK at all                    -> exit 1

The INTERNET branch has its own controls, because until ADR-44 `run()` passed only the APK path
and that branch therefore had NO coverage at all:

  (f) INTERNET present + `--expect-no-internet` -> exit 1
  (g) INTERNET absent  + `--expect-internet`    -> exit 1
  (h) INTERNET absent  + `--expect-no-internet` -> exit 0
  (i) INTERNET present + `--expect-internet`    -> exit 0
  (j) both flags at once (mutually exclusive)   -> exit 1

Synthetic zips, not real APKs: the point is the checker's DECISION, and a 595 MB fixture would
make the control unusable in a regression run.

    python tool/selftest_check_apk_contents.py
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# ADR-36: this file moved from `_toolchain/` (outside the repo) into `tool/` (inside it), so its
# paths are now derived from its own location rather than hardcoded to one machine's layout.
HERE = Path(__file__).resolve().parent
CHECKER = HERE / "check_apk_contents.py"
#: The interpreter is whatever is running this file; `_toolchain`'s Python is only a fallback.
PY = Path(sys.executable)
_TOOLCHAIN_PY = Path(r"D:\Desktop\Food\_toolchain\dl\python\python.exe")
if not PY.exists() and _TOOLCHAIN_PY.exists():
    PY = _TOOLCHAIN_PY
OUT = Path(os.environ.get("ACOUDIET_SELFTEST_TMP", tempfile.gettempdir())) / "apk_contents_selftest"

#: Deliberately unlike any real model: this control must not depend on a delivery that could
#: later be replaced (that staleness is exactly the defect being fixed).
MODEL_BYTES = b"TFL3" + b"\x00\x01\x02\x03" * 64
MODEL_SHA = hashlib.sha256(MODEL_BYTES).hexdigest()
ASSET_DIR = "assets/flutter_assets/assets/models"

#: Stand-in for the binary AXML `AndroidManifest.xml` entry. A real AXML keeps its strings in a
#: UTF-16LE pool, so the "present" fixture uses that encoding on purpose: it is exactly the
#: encoding the original ASCII-only scan could never see (an unfailable gate, ADR-22/ADR-23).
MANIFEST_WITH_INTERNET = (
    b"\x03\x00\x08\x00" + "android.permission.INTERNET".encode("utf-16-le")
)
MANIFEST_WITHOUT_INTERNET = (
    b"\x03\x00\x08\x00" + "android.permission.RECORD_AUDIO".encode("utf-16-le")
)


def card(**overrides) -> dict:
    base = {
        "name": "acoudiet",
        "version": "9.9.9",
        "quantization": "fp32",
        "inputShape": [1, 128, 128, 1],
        "numClasses": 6,
        "nFrames": 128,
        "melVersion": "1.1.0",
        "tfliteSha256": MODEL_SHA,
        "tfliteBytes": len(MODEL_BYTES),
        "parityLabelMatch": 1.0,
        "parityMaxConfDelta": 1.5e-06,
    }
    base.update(overrides)
    return base


def build(path: Path, *, model_name: str | None, model_bytes: bytes, card_obj: dict | None,
          manifest_bytes: bytes | None = None) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        if model_name is not None:
            z.writestr(f"{ASSET_DIR}/{model_name}", model_bytes)
        if card_obj is not None:
            z.writestr(f"{ASSET_DIR}/model_card.json",
                       json.dumps(card_obj, indent=2).encode("utf-8"))
        if manifest_bytes is not None:
            z.writestr("AndroidManifest.xml", manifest_bytes)


def run(path: Path, *extra: str) -> int:
    """Run the checker on `path`; `extra` carries the flavour expectation flags.

    The INTERNET branch is only reachable when a flag is passed, so a control that omits them
    would prove nothing about it.
    """
    proc = subprocess.run([str(PY), str(CHECKER), str(path), *extra],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.returncode


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    good_name = "acoudiet_fp32_v9.9.9.tflite"

    cases = [
        ("card and .tflite agree (must PASS)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card()), 0, ()),
        ("sha256 mismatch (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES + b"\xff", card_obj=card()), 1, ()),
        ("tfliteBytes wrong (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES,
            card_obj=card(tfliteBytes=len(MODEL_BYTES) + 1)), 1, ()),
        ("card names an absent file (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES,
            card_obj=card(version="9.9.8")), 1, ()),
        ("no model card in the APK (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=None), 1, ()),
        # ---- ADR-44: the INTERNET branch, which had no negative control before -------------
        ("INTERNET present, --expect-no-internet (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card(),
            manifest_bytes=MANIFEST_WITH_INTERNET), 1, ("--expect-no-internet",)),
        ("INTERNET absent, --expect-internet (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card(),
            manifest_bytes=MANIFEST_WITHOUT_INTERNET), 1, ("--expect-internet",)),
        ("INTERNET absent, --expect-no-internet (must PASS)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card(),
            manifest_bytes=MANIFEST_WITHOUT_INTERNET), 0, ("--expect-no-internet",)),
        ("INTERNET present, --expect-internet (must PASS)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card(),
            manifest_bytes=MANIFEST_WITH_INTERNET), 0, ("--expect-internet",)),
        ("both INTERNET flags at once (must FAIL)", dict(
            model_name=good_name, model_bytes=MODEL_BYTES, card_obj=card(),
            manifest_bytes=MANIFEST_WITH_INTERNET), 1,
            ("--expect-no-internet", "--expect-internet")),
    ]

    bad = []
    for i, (name, kwargs, want, extra) in enumerate(cases):
        apk = OUT / f"case_{i}.apk"
        build(apk, **kwargs)
        got = run(apk, *extra)
        ok = got == want
        flags = " ".join(extra)
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}"
              f"{(' [' + flags + ']') if flags else ''}: exit={got} expected={want}")
        if not ok:
            bad.append(name)

    print()
    if bad:
        print(f"RESULT: the checker does not discriminate ({bad})")
        return 1
    accepts = sum(1 for _, _, want, _ in cases if want == 0)
    print(f"RESULT: the checker discriminates all {len(cases)} cases "
          f"({accepts} accept, {len(cases) - accepts} reject)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

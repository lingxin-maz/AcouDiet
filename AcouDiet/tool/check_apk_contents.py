"""Proves the shipped APK really contains the model, the card and the new constants.

Reading the APK's zip central directory is the only evidence that answers "did the model
actually get packaged", as opposed to "the asset exists in the source tree".

    python tool/check_apk_contents.py                      # newest *release*.apk in dist/
    python tool/check_apk_contents.py path/to/app.apk
    python tool/check_apk_contents.py <apk> --expect-no-internet
"""

from __future__ import annotations

import hashlib
import json
import sys
import zipfile
from pathlib import Path

# ADR-36: moved from `_toolchain/` (outside the repo) into `tool/` (inside it), so the default
# target is derived from this file's own location instead of one machine's absolute layout.
_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent
DIST = _REPO / "dist"


def _default_apk() -> Path:
    """The newest release package in `dist/` -- printed on use, so the choice is visible."""
    candidates = [p for p in DIST.glob("*release*.apk") if p.is_file()]
    if candidates:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    return _REPO / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-debug.apk"


#: NOTE (ADR-32): this script used to carry a hardcoded `RELEASED_FP32_SHA256` literal for the
#: v1.1 delivery. That literal went stale the moment the acoustic model was replaced, and the
#: check then printed `matches the released acoudiet_fp32.tflite: False` for a perfectly good
#: package -- i.e. it reported "wrong" for the right artifact, which is as useless as a gate
#: that cannot fail. The comparison is now driven by the `model_card.json` **packaged inside
#: the APK**, which is the same source of truth the App itself reads, so it cannot go stale.


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    APK = Path(args[0]) if args else _default_apk()
    if not args:
        print(f"(no path given: checking {APK})")
    print("=" * 78)
    print(f"APK contents check: {APK}")
    print("=" * 78)
    print(f"  file size: {APK.stat().st_size:,} bytes "
          f"({APK.stat().st_size / (1024 * 1024):.1f} MB)")
    z = zipfile.ZipFile(APK)
    names = z.namelist()

    print()
    print("--- model assets inside the APK ---")
    hits = [n for n in names if "models/" in n]
    for n in sorted(hits):
        info = z.getinfo(n)
        print(f"  {info.file_size:>12,}  {n}")

    tflites = [n for n in names if n.endswith(".tflite")]
    if not tflites:
        print("  !! NO .tflite INSIDE THE APK")
        return 1
    for n in tflites:
        data = z.read(n)
        print(f"  sha256({n}) = {hashlib.sha256(data).hexdigest()}")

    print()
    print("--- model card as packaged ---")
    card_name = [n for n in names if n.endswith("models/model_card.json")]
    card = None
    for n in card_name:
        card = json.loads(z.read(n).decode("utf-8"))
        print(f"  {n}")
        for k in ("name", "version", "quantization", "inputShape", "nFrames", "melVersion",
                  "tfliteSha256", "tfliteBytes", "parityLabelMatch", "parityMaxConfDelta"):
            print(f"    {k} = {card.get(k)!r}")

    print()
    print("--- does the packaged .tflite match the packaged card? ---")
    if card is None:
        print("  !! no models/model_card.json inside the APK -- cannot tell which model this is")
        return 1
    mismatched = 0
    for n in tflites:
        data = z.read(n)
        sha = hashlib.sha256(data).hexdigest()
        ok_sha = sha == card.get("tfliteSha256")
        ok_bytes = len(data) == card.get("tfliteBytes")
        print(f"  {n}")
        print(f"    sha256 == card.tfliteSha256 : {ok_sha}")
        print(f"    size   == card.tfliteBytes  : {ok_bytes} "
              f"({len(data):,} vs {card.get('tfliteBytes')!r})")
        if not (ok_sha and ok_bytes):
            mismatched += 1
    if mismatched == len(tflites):
        print("  !! no packaged .tflite matches the packaged card -- blocker")
        return 1
    # The card is what the App reads to DERIVE the asset path, so a card that names a file the
    # APK does not contain is a load failure waiting to happen (`ACD-INF-001` on the device).
    expected = "{name}_{quantization}_v{version}.tflite".format(**{
        k: card.get(k) for k in ("name", "quantization", "version")})
    if not any(n.endswith(expected) for n in tflites):
        print(f"  !! the card names {expected!r}, which is NOT the packaged filename: "
              f"{[n.rsplit('/', 1)[-1] for n in tflites]} -- blocker")
        return 1
    print(f"  -> the packaged model is {expected}")

    print()
    print("--- feature_config.json as packaged ---")
    fc_name = [n for n in names if n.endswith("assets/feature_config.json")]
    for n in fc_name:
        fc = json.loads(z.read(n).decode("utf-8"))
        for k in ("n_frames", "raw_mel_frames", "input_shape", "power_to_db_ref",
                  "normalization", "preemphasis_boundary"):
            print(f"    {k} = {fc.get(k)!r}")
        print(f"    db_clip_range present = {'db_clip_range' in fc}")

    print()
    print("--- TFLite native runtime inside the APK ---")
    libs = sorted(n for n in names if "libtensorflowlite" in n)
    if libs:
        for n in libs:
            print(f"  {z.getinfo(n).file_size:>12,}  {n}")
    else:
        print("  !! no libtensorflowlite* in the APK")

    print()
    print("--- packaged ABIs (all lib/* entries) ---")
    abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/")})
    for a in abis:
        print(f"  {a}")

    print()
    print("--- observed audio demo asset ---")
    for n in sorted(x for x in names if "assets/demo/" in x):
        print(f"  {z.getinfo(n).file_size:>12,}  {n}")

    print()
    print("--- INTERNET permission (must be ABSENT) ---")
    # Textual scan of the binary manifest: only meaningful as a smoke check; `aapt2 dump badging`
    # is the authoritative read and is run separately.
    #
    # ⚠️ 2026-09-13: this check used to be a FALSE NEGATIVE BY CONSTRUCTION. The binary AXML string
    # pool stores UTF-16, so searching for the ASCII bytes of the permission could never match --
    # it printed `False` even for the profile APK, where `aapt2 dump badging` shows INTERNET is
    # present. Both encodings are therefore searched, and the exit code now reflects the anomaly
    # for a release-looking package. (A gate that cannot fail is not a gate: ADR-22/ADR-23.)
    manifest = z.read("AndroidManifest.xml") if "AndroidManifest.xml" in names else b""
    needle = "android.permission.INTERNET"
    as_utf16 = needle.encode("utf-16-le")
    found_ascii = needle.encode("ascii") in manifest
    found_utf16 = as_utf16 in manifest
    print(f"  '{needle}' present in the binary manifest: "
          f"{found_ascii or found_utf16}  (ascii={found_ascii}, utf16le={found_utf16})")
    if "--expect-no-internet" in flags and (found_ascii or found_utf16):
        print("  !! --expect-no-internet was requested and INTERNET is present -- blocker")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

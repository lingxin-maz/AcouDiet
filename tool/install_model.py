"""Installs a finished TFLite model into the app's drop-in directory.

THE POINT
---------
The App must consume a **finished** model without any code change: drop the `.tflite` in
`app/assets/models/`, make the model card describe it, done. This script is that path.

It verifies everything the App will later rely on, *before* anything is copied:

  * the file is a readable TFLite flatbuffer with exactly one input and one output;
  * the input tensor is `[1, n_mels, n_frames, 1]` with `n_frames` from the SSOT (FF-11 = 128
    since ADR-21; the raw STFT frame count is 129 and is NOT what the tensor holds);
  * the output tensor has `numClasses` entries (FF-14 / FF-19 = 6);
  * **both** I/O tensors are float32, which is the App's frozen I/O contract (ADR-20). A true
    int8-I/O artifact is rejected here rather than silently installed and then rejected on the
    device by `ModelIoContract`;
  * the byte size is within the FF-16 ceiling **for its own tier**: FP32 <= 6 MB, INT8 <= 2.5 MB;
  * `melVersion` is taken from the Kotlin `MEL_VERSION` constant, so the start-up handshake
    cannot drift from the app that ships alongside this model.

The quantization tier is **measured from the artifact**, not taken on trust: if any tensor in
the file is int8 the tier is `int8`, otherwise it is `fp32`. That matters because "INT8" is
ambiguous -- INT8 *weights* with float32 I/O and *true* int8 I/O are both called "INT8", and
the two need different handling. `--quantization` can override the measurement for a file the
heuristic misreads, but the tier decides both the model-card field and the installed filename,
so a wrong answer is visible rather than silent.

Then it computes the two measured fields (`tfliteSha256`, `tfliteBytes`), writes the 15-field
model card of API-06 section 5, and copies the artifact as
`<name>_<quantization>_v<version>.tflite`.

    python tool/install_model.py --tflite D:\\models\\mine.tflite --version 1.0.0
    python tool/install_model.py --tflite mine.tflite --version 1.0.0 --dry-run

`--dry-run` validates and prints what it *would* write, touching nothing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root
# ADR-51: the code was promoted to the repository root, so the workspace root IS `ROOT` and the
# SSOT is a direct child of it. Before ADR-51 this was `ROOT.parent`.
WORKSPACE = ROOT
SSOT = WORKSPACE / "shared" / "feature_config.json"
MODELS = ROOT / "app" / "assets" / "models"
KOTLIN_CONFIG = (ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin" /
                 "com" / "acoudiet" / "app" / "config" / "FeatureConfig.kt")

#: FF-16 size caps, per tier. Deliberately written as literals rather than imported from
#: `ai/src/config.py`: the app-side installer is an independent check on the producer, and
#: reading the producer's own constants would let one wrong number agree with itself.
SIZE_CAPS = {"int8": int(2.5 * 1024 * 1024), "fp32": int(6 * 1024 * 1024)}
CARD_FIELDS = (
    "name", "version", "createdAtMs", "quantization", "inputShape", "numClasses",
    "classLabels", "nFrames", "melVersion", "featureConfigSha256", "tfliteSha256",
    "tfliteBytes", "parityLabelMatch", "parityMaxConfDelta", "metricsRef",
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def kotlin_mel_version() -> str:
    if KOTLIN_CONFIG.exists():
        for line in KOTLIN_CONFIG.read_text(encoding="utf-8").splitlines():
            if "MEL_VERSION" in line and "=" in line:
                value = line.split("=", 1)[1].strip().rstrip(";").strip().strip('"')
                if value:
                    return value
    print("  [warn] could not read MEL_VERSION from FeatureConfig.kt; using 1.0.0")
    return "1.0.0"


def inspect_tflite(path: Path, ssot: dict) -> tuple[list[int], int, str]:
    """Returns (input_shape, output_size, measured_quantization). Uses the real interpreter."""
    try:
        import numpy as np
        import tensorflow as tf
    except Exception as e:  # pragma: no cover - TF is present in this toolchain
        raise SystemExit(f"ACD-ART-001: TensorFlow is required to inspect the model ({e})")

    try:
        interp = tf.lite.Interpreter(model_path=str(path))
        interp.allocate_tensors()
    except Exception as e:
        raise SystemExit(f"ACD-ART-001: not a loadable TFLite model: {e}")

    inputs = interp.get_input_details()
    outputs = interp.get_output_details()
    if len(inputs) != 1 or len(outputs) != 1:
        raise SystemExit(
            f"ACD-ART-001: expected exactly 1 input and 1 output, got {len(inputs)}/"
            f"{len(outputs)}")

    shape = [int(d) for d in inputs[0]["shape"]]
    expected = list(ssot["input_shape"])
    if shape != expected:
        raise SystemExit(
            f"ACD-ART-004: input shape {shape} != feature_config.input_shape {expected}")
    out_size = int(outputs[0]["shape"][-1])
    if out_size != int(ssot["num_classes"]):
        raise SystemExit(
            f"ACD-ART-004: output size {out_size} != num_classes {ssot['num_classes']}")

    # ADR-20: the App feeds float32 bytes and divides the output byte size by 4. A true int8-I/O
    # artifact would still fail on the device, but as a misleading byte-size error -- so it is
    # refused here, where the reason can be stated exactly.
    for label, detail in (("input", inputs[0]), ("output", outputs[0])):
        if detail["dtype"] != np.float32:
            raise SystemExit(
                f"ACD-ART-004: {label} tensor dtype is {detail['dtype'].__name__}, but the App "
                f"I/O contract requires float32 (ADR-20). An INT8-WEIGHT model with float32 I/O "
                f"is fine; a fully-integer one is not."
            )

    # Measured, not declared: dynamic-range int8 leaves int8 weight tensors in the file.
    has_int8 = any(np.dtype(d["dtype"]) == np.int8 for d in interp.get_tensor_details())
    return shape, out_size, ("int8" if has_int8 else "fp32")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tflite", required=True, help="the finished .tflite to install")
    ap.add_argument("--version", required=True, help="model version, e.g. 1.0.0")
    ap.add_argument("--name", default=None, help="model name (default from the SSOT project)")
    ap.add_argument("--quantization", default="auto", choices=("auto", "int8", "fp32"),
                    help="FF-16 tier; 'auto' measures it from the artifact (default)")
    ap.add_argument("--parity-label-match", type=float, default=None)
    ap.add_argument("--parity-max-conf-delta", type=float, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src = Path(args.tflite)
    if not src.exists():
        raise SystemExit(f"ACD-ART-001: no such file: {src}")
    ssot = json.loads(SSOT.read_text(encoding="utf-8"))
    name = args.name or ssot.get("project", "acoudiet").lower()

    print("=" * 78)
    print("Install a finished model into app/assets/models/")
    print("=" * 78)
    print(f"  source        : {src}")
    print(f"  bytes         : {src.stat().st_size}")

    shape, out_size, measured = inspect_tflite(src, ssot)
    quantization = measured if args.quantization == "auto" else args.quantization
    if args.quantization != "auto" and args.quantization != measured:
        print(f"  [warn] --quantization {args.quantization} overrides the measured "
              f"{measured!r}; the card and the filename will say {args.quantization!r}")
    cap = SIZE_CAPS[quantization]
    print(f"  quantization  : {quantization} (measured {measured!r}; FF-16 cap {cap})")
    print(f"  input shape   : {shape}")
    print(f"  output size   : {out_size} ")
    print(f"  n_frames      : {shape[2]} (SSOT const {ssot['n_frames']})")
    print(f"  class labels  : {ssot['class_labels']}")

    if src.stat().st_size > cap:
        raise SystemExit(
            f"ACD-ART-004: {src.stat().st_size} bytes exceeds the FF-16 {quantization} ceiling "
            f"of {cap}")

    mel_version = kotlin_mel_version()
    card = {
        "name": name,
        "version": args.version,
        "createdAtMs": int(time.time() * 1000),
        "quantization": quantization,
        "inputShape": shape,
        "numClasses": int(ssot["num_classes"]),
        "classLabels": list(ssot["class_labels"]),
        "nFrames": int(ssot["n_frames"]),
        "melVersion": mel_version,
        "featureConfigSha256": sha256_file(SSOT),
        "tfliteSha256": sha256_file(src),
        "tfliteBytes": src.stat().st_size,
        "parityLabelMatch": args.parity_label_match,
        "parityMaxConfDelta": args.parity_max_conf_delta,
        "metricsRef": "ai/artifacts/metrics.json",
    }
    missing = [f for f in CARD_FIELDS if f not in card]
    if missing:
        raise SystemExit(f"ACD-ART-001: card is missing {missing}")

    target = MODELS / f"{name}_{quantization}_v{args.version}.tflite"
    card_path = MODELS / "model_card.json"
    print()
    print(f"  would write   : {target}")
    print(f"                  {card_path}  (15 fields)")
    print(f"  melVersion    : {mel_version} (from the Kotlin constant)")
    print(f"  tfliteSha256  : {card['tfliteSha256'][:32]}...")

    if args.dry_run:
        print()
        print("--dry-run: nothing was written")
        return 0

    MODELS.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, target)
    if sha256_file(target) != card["tfliteSha256"]:
        raise SystemExit("ACD-ART-003: the copied file hashes differently; nothing installed")
    card_path.write_text(json.dumps(card, indent=2, ensure_ascii=False) + "\n",
                         encoding="utf-8")

    print()
    print(f"  installed     : {target} ({target.stat().st_size} bytes)")
    print(f"  model card    : {card_path}")
    print()
    print("Next: python tool\\verify_artifacts.py     (independent gate)")
    print("      powershell -File tool\\verify_all.ps1 (full regression)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

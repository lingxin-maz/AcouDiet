"""T-07 + T-08a pipeline check **without training** (no trainable artifact required).

WHY THIS EXISTS
---------------
This environment cannot produce a deliverable model: training to a useful accuracy is out of
reach here (2 CPU epochs on the synthetic offline corpus gave ``valAcc`` 0.167), and the user's
instruction is explicit -- do not keep training; leave a slot for a finished model.

But the *delivery pipeline* (INT8 export -> train/deploy parity -> artifact gate) still has to
be exercisable, or nobody will know it works until the day a real model arrives. So this script
builds the frozen architecture with **untrained weights**, pushes it through the real converter
with a real representative dataset drawn from ``train.csv`` only, and runs the real parity
comparison against it.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It never writes into ``app/assets/models/``. An untrained model in the App's asset slot would be
*worse* than no model: the App would load it, block nothing, and answer nonsense with
confidence. The artifact lands in ``ai/artifacts/`` and its name says what it is:

    ai/artifacts/acoudiet_int8_PIPELINECHECK.tflite

Consequences for the numbers it prints:
* label agreement will be ~1.0, because two runtimes that both predict garbage agree about the
  garbage. That proves the *plumbing*, not the model. The report says so in ``pipeline``.
* therefore it must never be quoted as a model quality metric (SPEC-00 section 8).

When a real model exists, use the normal path instead: ``python ai/src/quantize.py`` plus
``python ai/scripts/t08_parity_test.py``, or ``python tool/install_model.py`` for an external
artifact. See ``records/reports/model_dropin_and_feedback.md``.

    python ai/scripts/t07_export_int8.py --pipeline-check
    python ai/scripts/t07_export_int8.py --pipeline-check --representative-n 120
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]              # repository root
sys.path.insert(0, str(ROOT / "ai"))

from src.config import CONFIG, paths  # noqa: E402
from src import model as model_mod  # noqa: E402
from src import quantize as quantize_mod  # noqa: E402

PROBE_NAME = "acoudiet_int8_PIPELINECHECK.tflite"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pipeline-check", action="store_true",
                    help="required: acknowledges that the artifact is NOT deliverable")
    ap.add_argument("--representative-n", type=int, default=200)
    ap.add_argument("--samples", type=int, default=48,
                    help="samples used for the parity comparison")
    args = ap.parse_args()

    if not args.pipeline_check:
        print("This script only performs a PIPELINE CHECK (untrained weights, artifact not "
              "delivered).\nRe-run with --pipeline-check to acknowledge, or use "
              "`python ai/src/quantize.py` when a trained model exists.", file=sys.stderr)
        return 2

    import tensorflow as tf

    print("=" * 78)
    print("T-07/T-08a PIPELINE CHECK (untrained weights -- NOT a deliverable model)")
    print("=" * 78)

    # ---- 1. build the frozen architecture -------------------------------------------------
    model, info = model_mod.build_model()
    print(f"  architecture  : {CONFIG.domain.model_name} "
          f"({info.get('paramCount', model_mod.count_params(model))} params, "
          f"pretrained={info.get('pretrained')})")
    print(f"  input shape   : {list(CONFIG.input_shape)}")

    # ---- 2. representative dataset, train.csv only ----------------------------------------
    patches = quantize_mod.representative_samples(limit=args.representative_n)
    print(f"  representative: {len(patches)} patches from train.csv only")
    if not patches:
        print("ACD-ART-001: the representative set is empty; cannot quantise", file=sys.stderr)
        return 2

    # ---- 3. INT8 conversion (route chosen by the converter itself) --------------------------
    int8_blob, route_used = quantize_mod.convert_model(
        model, patches, int8=True, route="auto")
    print(f"  converter     : {route_used}")
    out = paths.artifacts / PROBE_NAME
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(int8_blob)

    cap = int(2.5 * 1024 * 1024)
    print(f"  int8 artifact : {out.name} = {len(int8_blob)} bytes "
          f"({len(int8_blob)/1024/1024:.2f} MB, FF-16 cap {cap}) "
          f"{'OK' if len(int8_blob) <= cap else 'OVER CAP'}")
    print(f"  sha256        : {sha256_file(out)[:32]}...")
    if len(int8_blob) > cap:
        print("ACD-ART-004: the artifact exceeds the FF-16 INT8 ceiling", file=sys.stderr)
        return 1

    # ---- 4. parity: Keras (in memory) vs TFLite ------------------------------------------
    interp = tf.lite.Interpreter(model_path=str(out))
    interp.allocate_tensors()
    in_d = interp.get_input_details()[0]
    out_d = interp.get_output_details()[0]

    rows = quantize_mod.dataset_mod.read_splits().get("test_public") or []
    rows = rows[: max(1, args.samples)]
    if not rows:
        print("ACD-ART-005: test_public.csv is empty; cannot compare", file=sys.stderr)
        return 2

    from src import features

    agree = 0
    deltas: list[float] = []
    mismatches: list[str] = []
    for i, row in enumerate(rows):
        path = paths.workspace / row["path"]
        pcm = features.read_pcm16(path)
        mel = features.mel_patch(pcm[: CONFIG.patch_samples])
        batch = features.to_model_input(mel)

        k_probs = np.asarray(model.predict(batch, verbose=0))[0].astype(np.float64)
        interp.set_tensor(in_d["index"], batch.astype(in_d["dtype"]))
        interp.invoke()
        t_probs = np.asarray(interp.get_tensor(out_d["index"]))[0].astype(np.float64)

        k_lab, t_lab = int(np.argmax(k_probs)), int(np.argmax(t_probs))
        deltas.append(float(abs(k_probs[k_lab] - t_probs[t_lab])))
        if k_lab == t_lab:
            agree += 1
        else:
            mismatches.append(row["path"])
        if (i + 1) % 12 == 0:
            print(f"  compared      : {i + 1}/{len(rows)}")

    label_match = agree / len(rows)
    max_delta = max(deltas) if deltas else 0.0
    thresh = {"labelMatch": 0.98, "maxConfDelta": 0.05}
    print()
    print(f"  labelMatch    : {label_match:.6f} (>= {thresh['labelMatch']})")
    print(f"  maxConfDelta  : {max_delta:.6f} (<= {thresh['maxConfDelta']})")
    print(f"  mismatches    : {len(mismatches)}")

    # ---- 5. record it, preserving melParity ------------------------------------------------
    report_path = paths.artifacts / "parity_report.json"
    existing = {}
    if report_path.exists():
        try:
            existing = json.loads(report_path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}
    mel_parity = existing.get("melParity")
    if mel_parity is None:
        print("  [warn] no melParity block found; the cross-language result would be lost. "
              "Run ai/scripts/mel_parity_test.py first if this is unexpected.")

    report = {
        "schemaVersion": "1.0",
        "generatedAtMs": int(time.time() * 1000),
        "sampleCount": len(rows),
        "labelMatch": label_match,
        "maxConfDelta": max_delta,
        "thresholds": thresh,
        "mismatches": mismatches,
        "melParity": mel_parity,
        "tfliteSha256": sha256_file(out),
        "pipeline": {
            "pythonVersion": sys.version.split()[0],
            "kerasVersion": tf.keras.__version__,
            "tfliteRuntimeVersion": tf.__version__,
            "artifact": f"ai/artifacts/{PROBE_NAME}",
            "delivered": False,
            "weights": "untrained (pipeline check only)",
            "warning": ("labelMatch here proves the export/parity plumbing, not model quality: "
                        "two runtimes that both predict untrained weights agree trivially. This "
                        "artifact is NOT installed into app/assets/models/ and must never be "
                        "quoted as a model metric."),
        },
    }
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  report        : {report_path} (melParity preserved: "
          f"{'yes' if mel_parity else 'NO'})")

    passed = label_match >= thresh["labelMatch"] and max_delta <= thresh["maxConfDelta"]
    print()
    print("RESULT:", "PASS" if passed else "FAIL")
    print()
    print("Reminder: the artifact is a pipeline probe with UNTRAINED weights and was NOT")
    print("delivered to the App. `app/assets/models/` still holds only the placeholder card.")
    print("To ship a real model: `python ai/src/quantize.py`, or")
    print("`python tool/install_model.py --tflite <model> --version <v>`.")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Measure the SHIPPED `.tflite` on this repo's real test splits.

WHY THIS IS NOT `ai/src/evaluate.py`
------------------------------------
`evaluate.py` is the T-05 producer of `ai/artifacts/metrics.json`, and its classification metrics
come from a **Keras `.keras` artifact it loads itself** (`load_model(...)` -> `predict_split`); the
`.tflite` it is given is used only for latency. So `metrics.json` describes *this repo's own trained
model*, and it cannot be produced without T-04 training -- which this checkout has no artifact for
(`ai/artifacts/` holds no `.keras`; `ai/data/augmented` is empty).

That distinction matters, because writing a `metrics.json` from some other model into the shipped
model card's `metricsRef` would be a false claim about the artifact users install. It stays unwritten.

But it exposed a real, different gap: **nobody had ever measured the accuracy of the model that
actually ships.** The repo could quote the model team's 55.9% and nothing else. This script closes
that gap using only what is in the tree: the shipped `.tflite`, the frozen splits, and the repo's
own Mel front end (`ai/src/features.py` -- the same chain `mel_parity_test.py` proves matches Kotlin).

    python tool/evaluate_shipped_model.py                    # test_public + test_mobile
    python tool/evaluate_shipped_model.py --split test_public
    python tool/evaluate_shipped_model.py --limit 50         # quick look, reported as truncated

Output: `ai/artifacts/metrics_shipped_model.json`, plus a printed summary. Every number is measured;
nothing is estimated, and a clip whose file is missing is COUNTED as missing rather than skipped
silently.

Exit codes: 0 = measured, 1 = could not measure (missing model/splits/data), 2 = bad usage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # repository root
# ADR-51: the code was promoted to the repository root, so the workspace root IS `ROOT`. It is
# still kept as its own name because the split CSVs are written relative to it.
WORKSPACE = ROOT

sys.path.insert(0, str(ROOT / "ai"))

MODEL_CARD = ROOT / "app" / "assets" / "models" / "model_card.json"
SPLITS = ROOT / "ai" / "data" / "splits"
OUT = ROOT / "ai" / "artifacts" / "metrics_shipped_model.json"

#: The primary mobile test set, matching `evaluate.py`'s PRIMARY_TEST_SET.
PRIMARY = "test_mobile"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def wilson95(k: int, n: int, z: float = 1.959963984540054) -> dict:
    """Wilson score interval. Reported instead of a bare point estimate: on ~600 clips the point
    estimate looks far more precise than the evidence supports (SPEC-T-05 section 8)."""
    if n == 0:
        return {"low": None, "high": None}
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return {"low": max(0.0, centre - half), "high": min(1.0, centre + half)}


def resolve(csv_path: str) -> Path | None:
    """Splits store repository-relative paths (`ai/data/raw/...`).

    ADR-51 promoted the code from `AcouDiet/` up to the repository root, so a CSV written before
    that commit still carries the old `AcouDiet/` prefix; it is stripped here and both spellings
    resolve. The parent directory is tried too, because the CSVs may be consumed from a checkout
    that still nests the project one level down. A miss is reported, never silently dropped.
    """
    rel = csv_path
    if rel.startswith("AcouDiet/"):
        rel = rel[len("AcouDiet/"):]
    for c in (ROOT / rel, WORKSPACE / rel):
        if c.exists():
            return c
    return None


def read_split(name: str) -> list[dict]:
    import csv

    path = SPLITS / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"ACD-ART-001: split file missing: {path}")
    with path.open(encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--split", action="append", default=None,
                    help=f"split to measure (repeatable); default: test_public + {PRIMARY}")
    ap.add_argument("--limit", type=int, default=0, help="cap clips per split (reported as such)")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--predictions", default=None,
                    help="also dump one JSON object per clip (split/path/trueId/predId/probs) "
                         "to this path, for ai/scripts/calibrate_thresholds.py. Without it this "
                         "script cannot feed the FF-20b calibration -- the aggregate metrics in "
                         "the report do not carry the per-sample confidences it needs.")
    args = ap.parse_args(argv[1:])

    if not MODEL_CARD.exists():
        print(f"ACD-ART-001: no model card at {MODEL_CARD}", file=sys.stderr)
        return 1
    card = json.loads(MODEL_CARD.read_text(encoding="utf-8"))
    model_path = MODEL_CARD.parent / (
        f"{card['name']}_{card['quantization']}_v{card['version']}.tflite")
    if not model_path.exists():
        print(f"ACD-ART-001: the card names {model_path.name}, which is not on disk", file=sys.stderr)
        return 1

    labels: list[str] = list(card["classLabels"])
    label_id = {name: i for i, name in enumerate(labels)}

    try:
        import numpy as np
        import tensorflow as tf
        from src import augment as augment_mod
        from src import features as features_mod
    except Exception as exc:  # pragma: no cover
        print(f"ACD-ART-001: cannot import the measurement stack ({exc})", file=sys.stderr)
        return 1

    print("=" * 78)
    print("Shipped-model evaluation (the .tflite that actually ships)")
    print("=" * 78)
    print(f"  model      : {model_path}")
    print(f"  sha256     : {sha256(model_path)}")
    print(f"  classes    : {labels}")
    print()

    interp = tf.lite.Interpreter(model_path=str(model_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    splits = args.split or ["test_public", PRIMARY]
    report: dict = {
        "schemaVersion": "1.0",
        "what": ("Accuracy of the SHIPPED .tflite measured on this repo's frozen splits. "
                 "This is NOT ai/src/evaluate.py's metrics.json (that one measures a locally "
                 "trained Keras model and is therefore not produced here)."),
        "model": {
            "path": str(model_path.relative_to(ROOT)),
            "sha256": sha256(model_path),
            "bytes": model_path.stat().st_size,
            "cardVersion": card["version"],
            "cardSha256": card["tfliteSha256"],
            "shaMatchesCard": sha256(model_path) == card["tfliteSha256"],
        },
        "frontEnd": {
            # The FROZEN evaluation chain, taken from the repo rather than re-implemented:
            # `evaluate.py::predict_split` builds its input with `augment_mod.feature_tensor(...,
            # augment_on=False)`, NOT with `features.mel_of_file`. The two are close but not the
            # same, and using the wrong one silently produced a chance-level score on the first run
            # of this script -- a harness bug that looked exactly like a broken model.
            "source": "ai/src/augment.py::feature_tensor(augment_on=False) "
                      "(the same call ai/src/evaluate.py::predict_split makes)",
            "patchSamples": int(features_mod.CONFIG.patch_samples),
            "nMels": int(features_mod.CONFIG.n_mels),
            "nFrames": int(features_mod.CONFIG.n_frames),
        },
        "splits": {},
    }

    all_true: list[int] = []
    all_pred: list[int] = []

    # ADR-40 / FF-20b: the per-sample record. The aggregate table in `report` cannot be
    # calibrated -- temperature scaling and conformal prediction both need every row's full
    # probability vector, not a confusion matrix.
    pred_rows: list[dict] = []

    for split in splits:
        rows = read_split(split)
        truncated = bool(args.limit and args.limit < len(rows))
        if args.limit:
            rows = rows[: args.limit]

        y_true: list[int] = []
        y_pred: list[int] = []
        conf: list[float] = []
        missing: list[str] = []
        unknown_label: list[str] = []

        for row in rows:
            label = row["label"]
            if label not in label_id:
                unknown_label.append(label)
                continue
            path = resolve(row["path"])
            if path is None:
                missing.append(row["path"])
                continue
            # EXACTLY the chain `ai/src/evaluate.py::predict_split` uses for measurement
            # (`apply_lufs=False`: FF-08 is the only normalisation on the inference path, ADR-17).
            pcm = features_mod.read_pcm16(path)
            stats = augment_mod.AugmentStats()
            tensor, stats = augment_mod.feature_tensor(
                pcm, split=split, rng=None, noise_bank=None, augment_on=False)
            x = np.asarray(tensor, dtype=np.float32).reshape(
                tuple(int(v) for v in inp["shape"]))
            interp.set_tensor(inp["index"], x)
            interp.invoke()
            probs = interp.get_tensor(out["index"])[0]
            y_true.append(label_id[label])
            y_pred.append(int(np.argmax(probs)))
            conf.append(float(np.max(probs)))
            if args.predictions:
                pred_rows.append({
                    "split": split,
                    "path": row["path"],
                    "trueId": int(label_id[label]),
                    "trueLabel": label,
                    "predId": int(np.argmax(probs)),
                    "probs": [float(v) for v in probs],
                })

        n = len(y_true)
        if n == 0:
            print(f"  [warn] {split}: no measurable clip ({len(missing)} missing files)")
            report["splits"][split] = {"n": 0, "missing": len(missing),
                                       "unknownLabel": len(unknown_label)}
            continue

        correct = sum(1 for t, p in zip(y_true, y_pred) if t == p)
        print(f"  {split:<14} n={n:<5} top1={correct / n:.4f} "
              f"({correct}/{n})  missing={len(missing)}  meanConf={sum(conf) / n:.3f}")

        cm = [[0] * len(labels) for _ in labels]
        for t, p in zip(y_true, y_pred):
            cm[t][p] += 1
        per_class = []
        for i, name in enumerate(labels):
            tp = cm[i][i]
            fn = sum(cm[i]) - tp
            fp = sum(row[i] for row in cm) - tp
            prec = tp / (tp + fp) if tp + fp else 0.0
            rec = tp / (tp + fn) if tp + fn else 0.0
            f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
            per_class.append({"label": name, "support": sum(cm[i]), "precision": prec,
                              "recall": rec, "f1": f1})

        report["splits"][split] = {
            "n": n, "top1": correct / n, "wilson95": wilson95(correct, n),
            "confusionMatrix": {"labels": labels, "matrix": cm},
            "perClass": per_class,
            "meanConfidence": sum(conf) / n,
            "truncated": truncated,
            "requestedRows": len(read_split(split)),
            "missingFiles": missing[:20],
            "missingCount": len(missing),
            "unknownLabels": unknown_label,
        }
        if split == PRIMARY or not all_true:
            all_true, all_pred = y_true, y_pred

    if all_true:
        n = len(all_true)
        correct = sum(1 for t, p in zip(all_true, all_pred) if t == p)
        report["overall"] = {"testSet": PRIMARY, "n": n, "top1": correct / n,
                             "wilson95": wilson95(correct, n)}
        print()
        print(f"  OVERALL (primary = {PRIMARY}): top1={correct / n:.4f}  "
              f"Wilson95=[{wilson95(correct, n)['low']:.4f}, {wilson95(correct, n)['high']:.4f}]")
        ref = 0.559
        print(f"  model team's claim for comparison: {ref:.3f} "
              f"(NOT measured here; quoted from their release note)")
        lo = wilson95(correct, n)["low"]
        hi = wilson95(correct, n)["high"]
        print(f"  -> this measurement's CI {'CONTAINS' if lo <= ref <= hi else 'EXCLUDES'} "
              f"the quoted figure")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print()
    print(f"wrote {out_path}")

    if args.predictions:
        pred_path = Path(args.predictions)
        pred_path.parent.mkdir(parents=True, exist_ok=True)
        with pred_path.open("w", encoding="utf-8") as fh:
            for row in pred_rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"wrote {pred_path} ({len(pred_rows)} clips)")
        if not pred_rows:
            # Do not let an empty dump look like a successful one: the calibrator would then fail
            # with a confusing "split not found" instead of "the evaluator produced nothing".
            print("ACD-ART-001: --predictions produced zero rows", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

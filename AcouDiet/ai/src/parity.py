"""T-08a train/deploy parity (the App-side half of the numeric-alignment gate).

WHY THIS GATE EXISTS
--------------------
Two different runtimes compute the same prediction: Keras on the training machine and the
TFLite interpreter on the phone. INT8 quantisation changes the numbers, so the delivered model
can be "the same model" and still answer differently. `SPEC-T-08` therefore freezes two
thresholds, and a model that misses either one may not be shipped:

    label agreement  >= 0.98      (the App must pick the same class)
    max confidence delta <= 0.05  (the App must be about as sure)

WHAT THIS MODULE DOES NOT DO
----------------------------
It does not touch the Mel front end. The cross-language Mel parity (Kotlin `MelFrontend` vs
`librosa`, `atol = 1e-3`) is a separate result that lives in the `melParity` block of
`parity_report.json`, produced by `ai/scripts/mel_parity_test.py`. This module **preserves that
block** when it updates the report: dropping it would silently discard the project's number-one
hard gate.

Determinism
-----------
Samples are drawn from a split with a fixed seed and a fixed stride, so two runs on the same
artifacts compare exactly the same inputs.

Usage::

    python ai/src/parity.py --n 64
    python ai/src/parity.py --n 64 --update-model-card
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

if __package__ in (None, ""):  # executed as a script
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, paths, sha256_file
    from src import dataset as dataset_mod
    from src import features
else:
    from .config import CONFIG, paths, sha256_file
    from . import dataset as dataset_mod
    from . import features

__all__ = ["THRESH", "ParityResult", "run_parity", "update_report", "main"]

#: `SPEC-T-08` / main plan section 5.2 THRESH. Frozen; not a tunable.
THRESH: Dict[str, float] = {"labelMatch": 0.98, "maxConfDelta": 0.05}

#: The report schema version this module writes.
SCHEMA_VERSION = "1.0"


class ParityError(RuntimeError):
    """Raised when the gate cannot be evaluated (missing artifact, unreadable split)."""


class ParityResult:
    """Outcome of one parity run, plus the numbers the model card needs."""

    def __init__(self, sample_count: int, label_match: float, max_conf_delta: float,
                 mismatches: Sequence[str], per_sample: Sequence[dict]) -> None:
        self.sample_count = sample_count
        self.label_match = label_match
        self.max_conf_delta = max_conf_delta
        self.mismatches = list(mismatches)
        self.per_sample = list(per_sample)

    @property
    def passed(self) -> bool:
        return (self.label_match >= THRESH["labelMatch"]
                and self.max_conf_delta <= THRESH["maxConfDelta"])

    def summary(self) -> str:
        return (f"labelMatch={self.label_match:.6f} (>= {THRESH['labelMatch']}), "
                f"maxConfDelta={self.max_conf_delta:.6f} (<= {THRESH['maxConfDelta']}), "
                f"n={self.sample_count} -> {'PASS' if self.passed else 'FAIL'}")


def _sample_rows(split: str, n: int, seed: int) -> List[dict]:
    """Deterministically draws `n` rows from a split, spread across the classes."""
    data = dataset_mod.read_splits()
    rows = list(data.get(split) or [])
    if not rows:
        raise ParityError(f"ACD-ART-005: split '{split}' is empty; cannot evaluate parity")

    rng = np.random.default_rng(seed)
    by_class: Dict[str, List[dict]] = {}
    for row in rows:
        by_class.setdefault(row["label"], []).append(row)

    picked: List[dict] = []
    per_class = max(1, n // max(1, len(by_class)))
    for label in sorted(by_class):
        candidates = by_class[label]
        idx = rng.permutation(len(candidates))[:per_class]
        picked.extend(candidates[i] for i in idx)
    picked.sort(key=lambda r: (r["label"], r["path"]))
    return picked[:n]


def _mel_for(row: dict) -> np.ndarray:
    path = paths.workspace / row["path"].replace("/", "/")
    if not path.exists():
        path = paths.workspace / row["path"]
    pcm = features.read_pcm16(path)
    window = CONFIG.patch_samples
    if pcm.shape[0] < window:
        raise ParityError(f"ACD-ART-005: {path} holds {pcm.shape[0]} samples, need {window}")
    return features.mel_patch(pcm[:window])


def run_parity(n: int = 64, split: str = "test_public", seed: int = 20260910,
               keras_path: Optional[Path] = None,
               tflite_path: Optional[Path] = None) -> Tuple[ParityResult, dict]:
    """Runs both runtimes over the same inputs and returns the gate outcome."""
    import tensorflow as tf

    keras_file = Path(keras_path) if keras_path else _default_keras()
    tflite_file = Path(tflite_path) if tflite_path else _default_tflite()
    if not keras_file.exists():
        raise ParityError(f"ACD-ART-005: Keras artifact not found: {keras_file}")
    if not tflite_file.exists():
        raise ParityError(f"ACD-ART-005: TFLite artifact not found: {tflite_file}")

    rows = _sample_rows(split, n, seed)
    print(f"  samples       : {len(rows)} from {split}.csv")
    print(f"  keras         : {keras_file.name}")
    print(f"  tflite        : {tflite_file.name}")

    model = tf.keras.models.load_model(str(keras_file))
    interp = tf.lite.Interpreter(model_path=str(tflite_file))
    interp.allocate_tensors()
    in_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]

    mismatches: List[str] = []
    per_sample: List[dict] = []
    deltas: List[float] = []
    agree = 0

    for row in rows:
        mel = _mel_for(row)
        batch = features.to_model_input(mel)
        keras_probs = np.asarray(model.predict(batch, verbose=0))[0].astype(np.float64)

        interp.set_tensor(in_detail["index"], batch.astype(in_detail["dtype"]))
        interp.invoke()
        tflite_probs = np.asarray(interp.get_tensor(out_detail["index"]))[0].astype(np.float64)
        # The exported model keeps float32 I/O (see quantize.py), but a future int8-I/O build
        # would need dequantising here rather than silently comparing quantised integers.
        if out_detail["dtype"] != np.float32:
            scale, zero = out_detail["quantization"]
            tflite_probs = (tflite_probs.astype(np.float64) - zero) * scale

        k_label = int(np.argmax(keras_probs))
        t_label = int(np.argmax(tflite_probs))
        delta = float(abs(keras_probs[k_label] - tflite_probs[t_label]))
        deltas.append(delta)
        if k_label == t_label:
            agree += 1
        else:
            mismatches.append(row["path"])
        per_sample.append({
            "path": row["path"],
            "label": row["label"],
            "kerasClass": CONFIG.class_labels[k_label],
            "tfliteClass": CONFIG.class_labels[t_label],
            "maxConfDelta": delta,
        })

    label_match = agree / len(rows)
    max_conf_delta = max(deltas) if deltas else 0.0
    result = ParityResult(len(rows), label_match, max_conf_delta, mismatches, per_sample)

    pipeline = {
        "pythonVersion": sys.version.split()[0],
        "kerasVersion": tf.keras.__version__,
        "tfliteRuntimeVersion": tf.__version__,
        "tensorflowVersion": tf.__version__,
        "split": split,
        "seed": seed,
    }
    return result, pipeline


def _default_keras() -> Path:
    candidates = sorted(paths.artifacts.glob("*_fp32_v*.keras"))
    if not candidates:
        raise ParityError("ACD-ART-005: no fp32 .keras under ai/artifacts; run T-04 first")
    return candidates[-1]


def _default_tflite() -> Path:
    candidates = sorted(paths.app_models.glob("*.tflite")) or \
        sorted(paths.artifacts.glob("*.tflite"))
    if not candidates:
        raise ParityError("ACD-ART-005: no .tflite found; run T-07 first")
    return candidates[-1]


def update_report(result: ParityResult, pipeline: dict,
                  report_path: Optional[Path] = None,
                  tflite_path: Optional[Path] = None) -> Path:
    """Writes `parity_report.json`, **preserving the existing `melParity` block**.

    That block is the cross-language Kotlin<->librosa result (SPEC-P-04 acceptance 4). It is
    produced by a different tool and must survive every update here -- losing it would discard
    the project's primary hard gate while leaving the report looking complete.
    """
    path = Path(report_path) if report_path else paths.artifacts / "parity_report.json"
    existing: dict = {}
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}

    mel_parity = existing.get("melParity")
    if mel_parity is None:
        print("  [warn] the existing report has no melParity block; it will be absent from the "
              "updated report. Re-run ai/scripts/mel_parity_test.py to regenerate it.")

    tflite_file = Path(tflite_path) if tflite_path else _default_tflite()
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAtMs": int(time.time() * 1000),
        "sampleCount": result.sample_count,
        "labelMatch": result.label_match,
        "maxConfDelta": result.max_conf_delta,
        "thresholds": dict(THRESH),
        "mismatches": result.mismatches,
        "melParity": mel_parity,
        "tfliteSha256": sha256_file(tflite_file) if tflite_file.exists() else None,
        "perSample": result.per_sample,
        "pipeline": pipeline,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def update_model_card(result: ParityResult,
                      card_path: Optional[Path] = None) -> Optional[Path]:
    """Fills `parityLabelMatch` / `parityMaxConfDelta` into the shipped model card."""
    path = Path(card_path) if card_path else paths.app_models / "model_card.json"
    if not path.exists():
        print(f"  [warn] no model card at {path}; skipping the card update")
        return None
    card = json.loads(path.read_text(encoding="utf-8"))
    card["parityLabelMatch"] = result.label_match
    card["parityMaxConfDelta"] = result.max_conf_delta
    path.write_text(json.dumps(card, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=64, help="number of samples to compare")
    ap.add_argument("--split", default="test_public",
                    help="split to draw samples from (never train)")
    ap.add_argument("--seed", type=int, default=20260910)
    ap.add_argument("--keras", default=None, help="override the fp32 .keras path")
    ap.add_argument("--tflite", default=None, help="override the .tflite path")
    ap.add_argument("--report", default=None, help="override parity_report.json")
    ap.add_argument("--update-model-card", action="store_true",
                    help="write the two parity fields into the shipped model card")
    args = ap.parse_args(argv)

    print("=" * 78)
    print("T-08a train/deploy parity")
    print("=" * 78)
    print(f"  thresholds    : labelMatch >= {THRESH['labelMatch']}, "
          f"maxConfDelta <= {THRESH['maxConfDelta']}")

    result, pipeline = run_parity(
        n=args.n, split=args.split, seed=args.seed,
        keras_path=Path(args.keras) if args.keras else None,
        tflite_path=Path(args.tflite) if args.tflite else None,
    )

    print()
    print(f"  measured      : {result.summary()}")
    if result.mismatches:
        print(f"  mismatches    : {len(result.mismatches)} "
              f"(first: {result.mismatches[0]})")

    report = update_report(result, pipeline,
                           report_path=Path(args.report) if args.report else None,
                           tflite_path=Path(args.tflite) if args.tflite else None)
    print(f"  report        : {report}  (melParity preserved: "
          f"{'yes' if json.loads(report.read_text(encoding='utf-8')).get('melParity') else 'NO'})")

    if args.update_model_card:
        card = update_model_card(result)
        if card:
            print(f"  model card    : {card} updated")

    if not result.passed:
        print(
            f"ACD-ART-005: parity failed ({result.summary()})", file=sys.stderr)
        return 1
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

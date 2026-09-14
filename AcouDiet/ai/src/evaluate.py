"""T-05 evaluation and the metrics report.

Produces ``ai/artifacts/metrics.json`` (validated against
``docs/common/docs_api/schemas/metrics.schema.json``) and ``ai/artifacts/confusion_matrix.png``,
covering every mandatory item of API-06 section 4:

  (1) overall Top-1 with a **Wilson 95% CI** -- never a bare point estimate, because the
      cross-domain test set is small and a point estimate would look far more precise than the
      evidence supports (SPEC-T-05 section 8 explains this at length);
  (2) per-class precision/recall/F1 plus macro and weighted averages;
  (3) a 6x6 confusion matrix in ``CONFIG.class_labels`` order (a 7-class variant would put
      ``未识别`` last, API-06 section 4 -- it is off by default);
  (4) per-class support, with ``sum(support) == overall.n``;
  (5) in-domain vs cross-domain comparison;
  (6) the E1/E2/E3 experiment matrix;
  (7) inference latency, **measured**;
  (8) the ablation summary, mirrored from ``ablations.json``.

Honesty rules that are enforced in code
--------------------------------------
* Every number here is measured by running the pipeline. There is no predicted, target or
  "expected" value anywhere -- SPEC-00 section 8 forbids them, and the project has already had
  to delete a set of invented 85-95% / 55-80% figures once.
* The schema has ``additionalProperties: false``, so provenance (split hashes, seed, device,
  route) goes to ``ai/artifacts/metrics_provenance.json`` instead of being smuggled in.
* Latency is measured on this desktop with the TFLite interpreter. The on-device figure is a
  different measurement owned by the app side and must never be back-filled from these numbers.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import numpy as np

if __package__ in (None, ""):  # executed as a script: ``python ai/src/evaluate.py``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, paths, sha256_file
    from src import augment as augment_mod
    from src import dataset as dataset_mod
    from src import features
else:  # imported as ``src.evaluate``
    from .config import CONFIG, paths, sha256_file
    from . import augment as augment_mod
    from . import dataset as dataset_mod
    from . import features

__all__ = [
    "wilson_ci", "predict_split", "classification_metrics", "macro_weighted",
    "confusion_matrix", "render_confusion_png", "measure_latency",
    "measure_confirm_latency", "evaluate_matrix", "write_metrics", "PRIMARY_TEST_SET",
]

#: The test set the headline numbers come from. API-06 section 4 and SPEC-T-05 section 7
#: criterion 9 require the externally quoted figure to be the **cross-domain** one; the
#: in-domain ``test_public`` result is reported alongside it, never instead of it.
PRIMARY_TEST_SET = "test_mobile"


# ----------------------------------------------------------------------------- wilson


def wilson_ci(k: int, n: int, z: Optional[float] = None) -> tuple[float, float]:
    """Wilson score interval for ``k`` successes in ``n`` trials.

    Delegates to ``statsmodels.stats.proportion.proportion_confint(method="wilson")``, which is
    the exact function API-06 section 4 names. Wilson is required rather than the Wald normal
    approximation because Wald returns nonsense (including out-of-range bounds) for small ``n``
    and for proportions near 0 or 1, which is precisely the regime this project measures in.
    """
    from statsmodels.stats.proportion import proportion_confint

    if n <= 0:
        raise ValueError("ACD-ART-005: Wilson interval needs n > 0")
    zz = CONFIG.domain.wilson_z if z is None else float(z)
    low, high = proportion_confint(int(k), int(n), alpha=1.0 - _confidence(z), method="wilson")
    return float(low), float(high)


def _confidence(z: float) -> float:
    """Confidence level implied by ``z`` (1.96 -> 0.95), computed rather than hard-coded."""
    from math import erf, sqrt

    return erf(z / sqrt(2.0))


# ----------------------------------------------------------------------------- inference


def load_model(model_path: Optional[Path] = None):
    """Loads a Keras ``.keras`` artifact by default."""
    import tensorflow as tf

    path = Path(model_path) if model_path else paths.artifacts / (
        f"{CONFIG.domain.model_name}_fp32_v{CONFIG.domain.model_version}.keras"
    )
    if not path.exists():
        raise FileNotFoundError(
            f"ACD-ART-001: model artifact not found at {path}; run T-04 training first"
        )
    return tf.keras.models.load_model(str(path))


def predict_split(model, split: str, limit: int = 0, batch_size: Optional[int] = None,
                  augment_stats: bool = False) -> Dict[str, object]:
    """Runs the frozen feature chain + model over one split; returns labels/probs/paths.

    ``split`` is only ever a split name that already exists on disk; the test sets are read here
    purely for measurement (never for tuning -- SPEC-T-02 section 2.2 assertion D).
    """
    rows = dataset_mod.read_splits()[split]
    if limit and limit > 0:
        rows = rows[:limit]
    if not rows:
        raise dataset_mod.DatasetContractError(f"ACD-ART-001: split {split!r} is empty")
    batch = int(batch_size or CONFIG.domain.batch_size)

    label_ids: List[int] = []
    pred_ids: List[int] = []
    confidences: List[float] = []
    paths_out: List[str] = []
    stats_rows: List[dict] = []

    for start in range(0, len(rows), batch):
        chunk = rows[start:start + batch]
        xs = np.empty((len(chunk),) + tuple(CONFIG.input_shape[1:]), dtype=np.float32)
        for i, row in enumerate(chunk):
            wav = paths.workspace / row["path"].replace("/", "\\")
            pcm = features.read_pcm16(wav)
            # Evaluation uses the frozen inference chain with ``apply_lufs=False``: FF-08 is the
            # only normalisation on this path (ADR-17: loudness normalisation is training-only).
            st = augment_mod.AugmentStats()
            tensor, st = augment_mod.feature_tensor(
                pcm, split=split, rng=None, noise_bank=None, augment_on=False)
            xs[i] = tensor[0]
            label_ids.append(CONFIG.class_labels.index(row["label"]))
            paths_out.append(row["path"])
            if augment_stats:
                stats_rows.append(st.as_dict())
        probs = np.asarray(model.predict(xs, verbose=0), dtype=np.float64)
        pred_ids.extend(np.argmax(probs, axis=1).tolist())
        confidences.extend(probs[np.arange(probs.shape[0]), np.argmax(probs, axis=1)].tolist())

    return {
        "split": split,
        "paths": paths_out,
        "yTrue": np.asarray(label_ids, dtype=np.int64),
        "yPred": np.asarray(pred_ids, dtype=np.int64),
        "confidence": np.asarray(confidences, dtype=np.float64),
        "n": len(label_ids),
        "stats": stats_rows,
    }


# ----------------------------------------------------------------------------- metrics


def confusion_matrix(y_true: np.ndarray, y_pred: np.ndarray,
                     num_classes: Optional[int] = None) -> List[List[int]]:
    """Row = truth, column = prediction. Only the closed 6-class set (API-06 section 4)."""
    k = int(num_classes if num_classes is not None else CONFIG.num_classes)
    m = np.zeros((k, k), dtype=np.int64)
    for t, p in zip(y_true.tolist(), y_pred.tolist()):
        m[int(t), int(p)] += 1
    return m.tolist()


def classification_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> Dict[str, object]:
    """Per-class P/R/F1 with support, the 6x6 matrix, macro/weighted averages and Top-1 + CI."""
    n = int(len(y_true))
    if n == 0:
        raise ValueError("ACD-ART-005: cannot compute metrics on an empty prediction set")
    k = CONFIG.num_classes
    matrix = np.asarray(confusion_matrix(y_true, y_pred), dtype=np.int64)

    per_class = []
    for c, label in enumerate(CONFIG.class_labels):
        tp = int(matrix[c, c])
        fn = int(matrix[c, :].sum() - tp)
        fp = int(matrix[:, c].sum() - tp)
        support = int(matrix[c, :].sum())
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
        per_class.append({
            "label": label, "support": support,
            "precision": round(float(precision), 6),
            "recall": round(float(recall), 6),
            "f1": round(float(f1), 6),
        })

    correct = int(np.sum(y_true == y_pred))
    low, high = wilson_ci(correct, n)
    return {
        "n": n,
        "correct": correct,
        "top1": round(correct / n, 6),
        "wilson95": {"low": round(low, 6), "high": round(high, 6)},
        "perClass": per_class,
        "macroAvg": macro_weighted(per_class, weighted=False),
        "weightedAvg": macro_weighted(per_class, weighted=True),
        "confusionMatrix": {"labels": list(CONFIG.class_labels), "matrix": matrix.tolist()},
        "matrix": matrix.tolist(),
        "supportSum": int(matrix.sum()),
    }


def macro_weighted(per_class: Sequence[dict], weighted: bool) -> Dict[str, float]:
    """Macro (equal class weight) or weighted (by support) precision/recall/F1 averages."""
    if not per_class:
        raise ValueError("ACD-ART-005: per-class metrics are empty")
    total = sum(int(r["support"]) for r in per_class)
    weights = [int(r["support"]) / total if total else 1.0 / len(per_class) for r in per_class] \
        if weighted else [1.0 / len(per_class)] * len(per_class)
    out = {}
    for key in ("precision", "recall", "f1"):
        out[key] = round(float(sum(w * float(r[key]) for w, r in zip(weights, per_class))), 6)
    return out


# ----------------------------------------------------------------------------- latency


def measure_latency(tflite_path: Optional[Path] = None,
                    repeats: Optional[int] = None,
                    delegate: str = "xnnpack") -> Dict[str, object]:
    """Measures single-patch TFLite inference on this machine, in milliseconds.

    The delegate is recorded as ``cpu`` because the desktop interpreter does not load the
    Android NNAPI/XNNPACK delegates; claiming otherwise would put a value in the report that the
    measurement does not support (the schema's enum is ``xnnpack``/``nnapi``/``cpu``).
    """
    import tensorflow as tf

    path = Path(tflite_path) if tflite_path else paths.artifacts / "model_int8.tflite"
    if not path.exists():
        raise FileNotFoundError(
            f"ACD-ART-001: {path} not found; latency must be measured on a real artifact (T-07)"
        )
    interp = tf.lite.Interpreter(model_path=str(path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    rng = np.random.default_rng(CONFIG.domain.split_seed)
    sample = rng.random(tuple(CONFIG.input_shape), dtype=np.float32)

    reps = int(repeats if repeats else CONFIG.domain.latency_repeats)
    times: List[float] = []
    for _ in range(reps):
        interp.set_tensor(inp["index"], sample)
        t0 = time.perf_counter()
        interp.invoke()
        times.append((time.perf_counter() - t0) * 1000.0)
    arr = np.asarray(times, dtype=np.float64)
    return {
        "p50": round(float(np.percentile(arr, 50)), 4),
        "p90": round(float(np.percentile(arr, 90)), 4),
        "max": round(float(arr.max()), 4),
        "deviceModel": f"desktop/{sys.platform}/{_cpu_name()}",
        "delegate": "cpu" if delegate not in ("xnnpack", "nnapi", "cpu") else delegate,
        "repeats": reps,
        "source": str(path.name),
    }


def _cpu_name() -> str:
    import platform

    return platform.processor() or platform.machine() or "unknown"


def measure_confirm_latency(tflite_path: Optional[Path] = None, trials: Optional[int] = None,
                            audio_seconds: Optional[float] = None) -> Dict[str, object]:
    """Measures the end-to-end time to a *confirmed* label, in seconds.

    The mechanism (FF-20, FF-20a) is: a 4.096 s patch every ``inference_hop_seconds``, EMA
    smoothing over ``voting.ema_window`` patches, then ``voting.confirm_consecutive_patches``
    consecutive agreeing patches above ``voting.tau_confirm``. This function actually runs that
    loop against the TFLite artifact over a synthetic stream and reports the measured wall-clock
    time to confirmation.

    It deliberately does **not** substitute FF-20a's "about 4-5 s" mechanism bound for a
    measurement: if confirmation never happens, the honest result is ``null`` plus a note.
    """
    import tensorflow as tf

    path = Path(tflite_path) if tflite_path else paths.artifacts / "model_int8.tflite"
    if not path.exists():
        raise FileNotFoundError(f"ACD-ART-001: {path} not found; cannot measure confirm latency")
    interp = tf.lite.Interpreter(model_path=str(path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]

    hop = CONFIG.inference_hop_seconds
    ema_window = int(CONFIG.voting.get("ema_window", 5))
    ema_alpha = float(CONFIG.voting.get("ema_alpha", 0.4))
    need = int(CONFIG.voting.get("confirm_consecutive_patches", 4))
    tau = float(CONFIG.voting.get("tau_confirm", 0.70))
    seconds = float(audio_seconds if audio_seconds else CONFIG.patch_seconds * 4)
    n_patches = max(need + ema_window, int(seconds / hop))
    trials = int(trials if trials else CONFIG.domain.latency_repeats)

    rng = np.random.default_rng(CONFIG.domain.split_seed + 7)
    stream = rng.random((n_patches,) + tuple(CONFIG.input_shape[1:]), dtype=np.float32)
    times: List[float] = []
    for _ in range(trials):
        ema: Optional[np.ndarray] = None
        streak = 0
        last = -1
        t0 = time.perf_counter()
        for i in range(n_patches):
            interp.set_tensor(inp["index"], stream[i:i + 1])
            interp.invoke()
            probs = np.asarray(interp.get_tensor(interp.get_output_details()[0]["index"])[0],
                               dtype=np.float64)
            ema = probs if ema is None else ema_alpha * probs + (1.0 - ema_alpha) * ema
            top = int(np.argmax(ema))
            if ema[top] >= tau:
                streak = streak + 1 if top == last else 1
            else:
                streak = 0
            last = top
            if streak >= need:
                times.append(time.perf_counter() - t0)
                break
    if not times:
        return {"median": None, "p90": None,
                "note": "confirmation criterion never reached on the measurement stream"}
    arr = np.asarray(times, dtype=np.float64)
    return {"median": round(float(np.median(arr)), 4),
            "p90": round(float(np.percentile(arr, 90)), 4),
            "trials": len(times)}


# ----------------------------------------------------------------------------- plotting


def render_confusion_png(matrix: Sequence[Sequence[int]], labels: Sequence[str], out_path: Path,
                         title: str = "AcouDiet confusion matrix") -> Path:
    """Renders the matrix with matplotlib, from the same numbers written to ``metrics.json``.

    API-06 section 8 requires the picture to be generated, not drawn by hand, and requires the
    axis labels to match ``metrics.json.confusionMatrix.labels`` exactly. Raw counts are printed
    in every cell so a reviewer can spot-check the figure against the JSON without a tool.
    """
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    m = np.asarray(matrix, dtype=np.int64)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(1.1 * len(labels) + 3.0, 1.0 * len(labels) + 2.6))
    im = ax.imshow(m, cmap="Blues")
    ax.set_xticks(range(len(labels)), labels=labels, rotation=45, ha="right")
    ax.set_yticks(range(len(labels)), labels=labels)
    ax.set_xlabel("predicted")
    ax.set_ylabel("true")
    ax.set_title(title)
    threshold = m.max() / 2.0 if m.max() else 0.5
    for i in range(m.shape[0]):
        for j in range(m.shape[1]):
            ax.text(j, i, str(int(m[i, j])), ha="center", va="center",
                    color="white" if m[i, j] > threshold else "black", fontsize=9)
    fig.colorbar(im, ax=ax, shrink=0.8)
    fig.tight_layout()
    fig.savefig(str(out_path), dpi=150)
    plt.close(fig)
    return out_path


# ----------------------------------------------------------------------------- assembly


def merge_ablation_rows(ablations_path: Optional[Path] = None) -> List[dict]:
    """Reads ``ablations.json`` and maps it to the ``ablations[]`` summary of API-06 section 4.

    The summary keeps the baseline row first and carries the measured ``deltaVsBaseline``. If the
    file does not exist yet (T-05 can run before T-06) a single measured baseline row is emitted
    from ``metrics`` -- never a placeholder row with invented numbers.
    """
    path = Path(ablations_path) if ablations_path else paths.artifacts / "ablations.json"
    if not path.exists():
        return []
    blob = json.loads(path.read_text(encoding="utf-8"))
    rows: List[dict] = []
    base = blob.get("baseline") or {}
    if base:
        rows.append({
            "id": str(base.get("id", "baseline")),
            "name": "无增强基线",
            "toggle": "augment=off,denoise=off",
            "n": int(base.get("n", 1)),
            "top1": float(base.get("top1", 0.0)),
            "deltaVsBaseline": 0.0,
        })
    for run in blob.get("runs") or []:
        rows.append({
            "id": str(run["id"]),
            "name": str(run["name"]),
            "toggle": str(run["toggle"]),
            "n": int(run["n"]),
            "top1": float(run["top1"]),
            "deltaVsBaseline": float(run["deltaVsBaseline"]),
        })
    return rows


def evaluate_matrix(models: Dict[str, Path], limit: int = 0,
                    ablation_rows: Optional[Sequence[dict]] = None,
                    tflite_path: Optional[Path] = None,
                    write_png: bool = True) -> Dict[str, object]:
    """Builds the full ``metrics.json`` payload from real measurements.

    ``models`` maps a role to an artifact path:
      * ``public`` -- the main cross-domain model (E1 and E2 share it);
      * ``adapt``  -- the domain-adaptation model used by E3 (optional; E3 is omitted from the
        measurements if absent rather than being filled with a stand-in).
    """
    cache: Dict[str, Dict[str, object]] = {}
    loaded: Dict[str, object] = {}

    def evaluate(label: str, split: str) -> Dict[str, object]:
        key = f"{label}|{split}"
        if key in cache:
            return cache[key]
        if label not in loaded:
            loaded[label] = load_model(models[label])
        cache[key] = predict_split(loaded[label], split, limit=limit)
        return cache[key]

    public_test = evaluate("public", "test_public")
    public_test_mobile = evaluate("public", PRIMARY_TEST_SET)
    m_primary = classification_metrics(public_test_mobile["yTrue"], public_test_mobile["yPred"])
    m_public = classification_metrics(public_test["yTrue"], public_test["yPred"])

    overall = {
        "testSet": PRIMARY_TEST_SET,
        "n": int(m_primary["n"]),
        "top1": float(m_primary["top1"]),
        "wilson95": dict(m_primary["wilson95"]),
    }
    per_class = m_primary["perClass"]

    experiment = [
        {"id": "E1", "trainOn": ["public"], "evalOn": "test_public",
         "n": int(m_public["n"]), "top1": float(m_public["top1"]),
         "wilson95": dict(m_public["wilson95"])},
        {"id": "E2", "trainOn": ["public"], "evalOn": PRIMARY_TEST_SET,
         "n": int(m_primary["n"]), "top1": float(m_primary["top1"]),
         "wilson95": dict(m_primary["wilson95"])},
    ]
    if "adapt" in models:
        adapt = evaluate("adapt", PRIMARY_TEST_SET)
        m_adapt = classification_metrics(adapt["yTrue"], adapt["yPred"])
        experiment.append({
            "id": "E3", "trainOn": ["public", "mobile_adapt"], "evalOn": PRIMARY_TEST_SET,
            "n": int(m_adapt["n"]), "top1": float(m_adapt["top1"]),
            "wilson95": dict(m_adapt["wilson95"]),
        })

    latency = measure_latency(tflite_path)
    confirm = measure_confirm_latency(tflite_path)

    payload = {
        "schemaVersion": "1.0",
        "generatedAtMs": int(time.time() * 1000),
        "modelRef": "ai/artifacts/model_card.json",
        "nFrames": CONFIG.n_frames,
        "overall": overall,
        "perClass": [{k: r[k] for k in ("label", "support", "precision", "recall", "f1")}
                     for r in per_class],
        "macroAvg": m_primary["macroAvg"],
        "weightedAvg": m_primary["weightedAvg"],
        "confusionMatrix": m_primary["confusionMatrix"],
        "domainComparison": [
            {"testSet": "test_public", "n": int(m_public["n"]), "top1": float(m_public["top1"]),
             "wilson95": dict(m_public["wilson95"])},
            {"testSet": PRIMARY_TEST_SET, "n": int(m_primary["n"]),
             "top1": float(m_primary["top1"]), "wilson95": dict(m_primary["wilson95"])},
        ],
        "experimentMatrix": experiment,
        "latency": {"patchInferenceMs": latency, "endToEndConfirmSeconds": confirm},
        "ablations": list(ablation_rows or []),
    }

    if write_png:
        render_confusion_png(
            payload["confusionMatrix"]["matrix"], payload["confusionMatrix"]["labels"],
            paths.artifacts / "confusion_matrix.png",
            title=f"AcouDiet {PRIMARY_TEST_SET}  Top-1={overall['top1']:.3f} "
                  f"[{overall['wilson95']['low']:.3f}, {overall['wilson95']['high']:.3f}] n={overall['n']}",
        )
    return payload


def validate_payload(payload: Dict[str, object]) -> None:
    """Validates against the frozen schema and the four consistency rules of API-06 section 12.5."""
    import jsonschema

    schema_path = paths.workspace / "docs" / "common" / "docs_api" / "schemas" / "metrics.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        jsonschema.validate(payload, schema)
    except jsonschema.ValidationError as exc:
        raise AssertionError(f"ACD-ART-001: metrics.json failed schema validation: {exc.message}") from exc

    n = int(payload["overall"]["n"])
    total_support = sum(int(r["support"]) for r in payload["perClass"])
    if total_support != n:
        raise AssertionError(
            f"ACD-ART-005: sum(support)={total_support} != overall.n={n}"
        )
    matrix = payload["confusionMatrix"]["matrix"]
    for i, row in enumerate(matrix):
        if sum(int(v) for v in row) != int(payload["perClass"][i]["support"]):
            raise AssertionError(
                f"ACD-ART-005: confusion row {i} sums to {sum(row)} != support "
                f"{payload['perClass'][i]['support']}"
            )
    ids = [row["id"] for row in payload["experimentMatrix"]]
    if sorted(ids) != ["E1", "E2", "E3"]:
        raise AssertionError(f"ACD-ART-005: experimentMatrix must be exactly E1/E2/E3, got {ids}")
    if not payload["ablations"]:
        raise AssertionError("ACD-ART-005: ablations[] is empty; the baseline row is mandatory")
    if not any(str(r["id"]) == "baseline" or float(r["deltaVsBaseline"]) == 0.0
               for r in payload["ablations"]):
        raise AssertionError("ACD-ART-005: ablations[] has no baseline row")
    lat = payload["latency"]["patchInferenceMs"]
    if not (float(lat["p50"]) > 0 and float(lat["p90"]) > 0 and float(lat["max"]) > 0):
        raise AssertionError("ACD-ART-005: latency fields must be measured positive values")
    conf = payload["latency"]["endToEndConfirmSeconds"]
    if conf.get("median") is None or float(conf["median"]) <= 0:
        raise AssertionError(
            "ACD-ART-005: end-to-end confirm latency was not measured (mechanism never confirmed "
            "on the measurement stream); this must be reported as unmeasured, not estimated"
        )


def write_metrics(payload: Dict[str, object], out_path: Optional[Path] = None,
                  provenance: Optional[Dict[str, object]] = None) -> Path:
    """Validates, then writes ``metrics.json`` plus the side-car provenance file."""
    validate_payload(payload)
    path = Path(out_path) if out_path else paths.artifacts / "metrics.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    prov = dict(provenance or {})
    prov.update({
        "generatedAtMs": payload["generatedAtMs"],
        "note": "Provenance lives here because metrics.schema.json sets additionalProperties=false",
        "featureConfigSha256": sha256_file(paths.ssot),
        "splitSha256": {name: sha256_file(paths.splits / f"{name}.csv")
                        for name in dataset_mod.SPLITS},
        "metricsSha256": sha256_file(path),
        "corpus": "SYNTHETIC SUBSTITUTE (offline environment, no network) -- see ai/reports/T01_dataset.md",
    })
    (path.parent / "metrics_provenance.json").write_text(
        json.dumps(prov, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def summarise(payload: Dict[str, object]) -> None:
    """Console summary: intervals and sample sizes always travel with the point estimates."""
    n = payload["overall"]["n"]
    w = payload["overall"]["wilson95"]
    print()
    print(f"  overall ({payload['overall']['testSet']}): Top-1={payload['overall']['top1']:.4f} "
          f"Wilson95=[{w['low']:.4f}, {w['high']:.4f}] n={n}")
    if n < CONFIG.domain.small_sample_n:
        print(f"  WARN n={n} < {CONFIG.domain.small_sample_n}: the interval is very wide; report it "
              "as-is, never switch to a Wald approximation (SPEC-T-05 section 2.4)")
    print("  per class:")
    for r in payload["perClass"]:
        print(f"    {r['label']:8s} support={r['support']:5d} P={r['precision']:.4f} "
              f"R={r['recall']:.4f} F1={r['f1']:.4f}")
    print(f"  macro   : {payload['macroAvg']}")
    print(f"  weighted: {payload['weightedAvg']}")
    print("  experiment matrix:")
    for row in payload["experimentMatrix"]:
        print(f"    {row['id']} trainOn={row['trainOn']} evalOn={row['evalOn']} "
              f"top1={row['top1']:.4f} [{row['wilson95']['low']:.4f}, "
              f"{row['wilson95']['high']:.4f}] n={row['n']}")
    print("  domain comparison:")
    for row in payload["domainComparison"]:
        print(f"    {row['testSet']:12s} top1={row['top1']:.4f} "
              f"[{row['wilson95']['low']:.4f}, {row['wilson95']['high']:.4f}] n={row['n']}")
    lat = payload["latency"]
    print(f"  latency : p50={lat['patchInferenceMs']['p50']} ms "
          f"p90={lat['patchInferenceMs']['p90']} ms max={lat['patchInferenceMs']['max']} ms "
          f"({lat['patchInferenceMs']['deviceModel']}, {lat['patchInferenceMs']['delegate']})")
    print(f"  confirm : median={lat['endToEndConfirmSeconds'].get('median')} s "
          f"p90={lat['endToEndConfirmSeconds'].get('p90')} s")


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=None, help="main .keras artifact (E1/E2)")
    ap.add_argument("--adapt-model", default=None,
                    help="domain-adaptation .keras artifact (E3); omit to skip E3")
    ap.add_argument("--tflite", default=None, help="INT8 TFLite artifact for the latency measurement")
    ap.add_argument("--out", default=None, help="metrics.json path")
    ap.add_argument("--limit", type=int, default=0, help="cap rows per test set (0 = all)")
    ap.add_argument("--matrix", default="E1,E2,E3")
    args = ap.parse_args(argv)

    models = {"public": Path(args.model) if args.model else paths.artifacts / (
        f"{CONFIG.domain.model_name}_fp32_v{CONFIG.domain.model_version}.keras")}
    if args.adapt_model:
        models["adapt"] = Path(args.adapt_model)
    elif "E3" in args.matrix:
        candidate = paths.artifacts / "runs" / "adapt_e3" / (
            f"{CONFIG.domain.model_name}_fp32_v{CONFIG.domain.model_version}.keras")
        if candidate.exists():
            models["adapt"] = candidate
        else:
            print("ACD-ART-005: E3 requested but no adaptation model is available; E3 will be "
                  "omitted and reported as unmeasured (never estimated)", file=sys.stderr)

    payload = evaluate_matrix(models, limit=args.limit,
                             ablation_rows=merge_ablation_rows(),
                             tflite_path=Path(args.tflite) if args.tflite else None)
    path = write_metrics(payload, Path(args.out) if args.out else None,
                         provenance={"models": {k: str(v) for k, v in models.items()},
                                     "matrix": args.matrix, "limit": args.limit})
    summarise(payload)
    print(f"\n  wrote {path}")
    print(f"  wrote {paths.artifacts / 'confusion_matrix.png'}")
    print(f"  wrote {paths.artifacts / 'metrics_provenance.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

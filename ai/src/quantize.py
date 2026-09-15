"""T-07 INT8 quantisation, TFLite export, and the model card.

This is a **hard gate** (SPEC-T-07): the App cannot ship without a model, and FF-16 caps the
INT8 artifact at 2.5 MB, so the export either produces a compliant artifact or it fails.

Frozen decisions this module implements
--------------------------------------
* Full-integer quantisation (``Optimize.DEFAULT`` + a representative dataset), with
  ``target_spec.supported_ops = [TFLITE_BUILTINS]``. ``SELECT_TF_OPS`` / the Flex delegate is
  never enabled: the on-device ``tflite_flutter`` runtime does not load it, so a Flex artifact
  would convert here and then fail on the phone.
* I/O stays ``float32``. ``API-01`` section 3.2 hands the model a ``Float32List`` and ``P-06``
  consumes float probabilities; switching to int8 I/O would force the Dart side to reimplement
  quantisation, creating a second numerical implementation of the very thing T-08 exists to
  verify.
* The representative dataset comes from **``train.csv`` only**. Calibrating on a test split is a
  leak, not a shortcut (SPEC-T-07 section 6).
* ``nFrames`` / ``inputShape`` / ``numClasses`` / ``classLabels`` are read from ``CONFIG``, never
  written as literals, so a SSOT change cannot leave a stale ``129`` behind in this file.
* ``melVersion`` is **parsed out of the Kotlin source** rather than duplicated here: it is the
  app side's constant, and copying it would destroy the handshake's ability to detect drift.

Two artifacts, two names
-----------------------
``ai/artifacts/model_int8.tflite`` is the in-tree artifact; the delivered copy is
``app/assets/models/acoudiet_int8_v<version>.tflite`` (API-06 section 10). The delivery step only
**renames**, so the two files are byte-identical and share one SHA-256.
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

import numpy as np

if __package__ in (None, ""):  # executed as a script: ``python ai/src/quantize.py``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, paths, read_kotlin_mel_version, sha256_bytes, sha256_file
    from src import dataset as dataset_mod
    from src import features
else:  # imported as ``src.quantize``
    from .config import CONFIG, paths, read_kotlin_mel_version, sha256_bytes, sha256_file
    from . import dataset as dataset_mod
    from . import features

__all__ = [
    "representative_samples", "representative_dataset", "convert_tflite",
    "load_interpreter", "self_check", "build_model_card", "write_model_card",
    "deliver_to_app", "run_export", "MODEL_CARD_FIELDS",
]

#: The 15-field model card of API-06 section 5, in the order that document lists them.
MODEL_CARD_FIELDS = (
    "name", "version", "createdAtMs", "quantization", "inputShape", "numClasses", "classLabels",
    "nFrames", "melVersion", "featureConfigSha256", "tfliteSha256", "tfliteBytes",
    "parityLabelMatch", "parityMaxConfDelta", "metricsRef",
)


# ------------------------------------------------------------------- representative data


def representative_samples(limit: Optional[int] = None,
                           per_class_min: Optional[int] = None,
                           seed: Optional[int] = None) -> List[np.ndarray]:
    """Stratified calibration patches drawn from ``train.csv`` **only**.

    Returns a list of ``[1, n_mels, n_frames, 1]`` float32 tensors. Deterministic: the row order
    is shuffled with a fixed seed, so re-exporting the same model gives the same calibration set
    and therefore (in practice) the same ``tfliteSha256``.
    """
    import random

    d = CONFIG.domain
    limit = int(limit if limit is not None else d.representative_n)
    per_class_min = int(per_class_min if per_class_min is not None else d.representative_per_class_min)
    s = d.split_seed if seed is None else int(seed)

    rows = [r for r in dataset_mod.read_splits()["train"]]
    if not rows:
        raise dataset_mod.DatasetContractError("ACD-ART-001: train.csv is empty")

    by_class: Dict[str, List[dict]] = {lbl: [] for lbl in CONFIG.class_labels}
    for r in rows:
        by_class.setdefault(r["label"], []).append(r)
    rng = random.Random(s)
    for label in by_class:
        rng.shuffle(by_class[label])

    selected: List[dict] = []
    for label in CONFIG.class_labels:
        pool = by_class.get(label, [])
        if len(pool) < per_class_min:
            raise dataset_mod.DatasetContractError(
                f"ACD-ART-005: train.csv has only {len(pool)} rows for {label!r}; the "
                f"representative dataset needs at least {per_class_min} per class"
            )
        selected.extend(pool[:per_class_min])
    remaining = max(0, limit - len(selected))
    leftovers = [r for label in CONFIG.class_labels for r in by_class.get(label, [])[per_class_min:]]
    rng.shuffle(leftovers)
    selected.extend(leftovers[:remaining])
    selected = selected[:max(limit, len(selected))]

    out: List[np.ndarray] = []
    for r in selected:
        wav = paths.workspace / r["path"].replace("/", "\\")
        pcm = features.read_pcm16(wav)
        mel = features.mel_patch(pcm[: CONFIG.patch_samples])
        out.append(features.to_model_input(mel))
    return out


def representative_dataset(samples: Sequence[np.ndarray]) -> Iterable[List[np.ndarray]]:
    """Yields ``[tensor]`` one at a time -- the shape the converter's calibrator expects."""
    for tensor in samples:
        yield [np.asarray(tensor, dtype=np.float32)]


# ------------------------------------------------------------------- conversion


def build_converter(model, samples: Sequence[np.ndarray], int8: bool = True,
                    route: str = "auto"):
    """Builds a configured TFLite converter, returning ``(converter, routeName)``.

    There are three routes, and on this toolchain they are **not** interchangeable:

    * ``from_keras_model`` -- the obvious one, and the one that fails on Keras 3.15 + TF 2.21:
      ``TypeError: 'NoneType' object is not callable`` raised from ``tflite_keras_util.py``
      because ``keras_deps.get_call_context_function()`` returns None. Not a mistake in this
      code; the Keras -> TFLite utility is out of step with this Keras build.
    * ``from_saved_model`` -- works in principle, but ``model.export()`` needs a real directory:
      this sandbox denies ``tempfile.mkdtemp``-style paths (see ``_toolchain/verify_env.py``).
    * ``from_concrete_functions`` -- **works here**. Trace one concrete function at the frozen
      input shape and convert that. Measured: 1 096 936 bytes for the frozen architecture,
      well inside the FF-16 INT8 ceiling (see ``ai/scripts/diagnose_tflite_conversion.py``).

    ``route="auto"`` tries ``from_keras_model`` first -- so a toolchain where it works keeps the
    simplest path -- and falls back to ``from_concrete_functions``, reporting which was used.
    """
    import tensorflow as tf

    def configure(converter):
        # TFLITE_BUILTINS only: a Flex fallback would convert here and then fail on the phone
        # (SPEC-T-07 section 2.4 -- needing SELECT_TF_OPS is a failure, not a workaround).
        converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
        if int8:
            converter.optimizations = [tf.lite.Optimize.DEFAULT]
            calibration = list(samples or [])
            if not calibration:
                raise ValueError(
                    "ACD-ART-001: INT8 conversion needs a non-empty representative dataset")
            it = iter(calibration)

            def gen():
                for tensor in it:
                    yield [np.asarray(tensor, dtype=np.float32)]

            converter.representative_dataset = gen
        # float32 I/O keeps the App contract simple (API-01 section 3.2): the on-device side
        # hands in a Float32List and reads float probabilities.
        converter.inference_input_type = tf.float32
        converter.inference_output_type = tf.float32
        return converter

    def via_keras():
        return configure(tf.lite.TFLiteConverter.from_keras_model(model))

    def via_concrete():
        spec = [tf.TensorSpec(shape=list(CONFIG.input_shape), dtype=tf.float32, name="mel")]
        concrete = tf.function(lambda x: model(x, training=False)).get_concrete_function(spec)
        return configure(tf.lite.TFLiteConverter.from_concrete_functions([concrete], model))

    if route == "keras":
        return via_keras(), "from_keras_model"
    if route == "concrete":
        return via_concrete(), "from_concrete_functions"
    # "auto" cannot decide here: `from_keras_model` *constructs* fine and only explodes inside
    # `convert()`, so the fallback has to live in `convert_model`.
    return via_keras(), "from_keras_model"


def convert_model(model, samples: Sequence[np.ndarray], int8: bool = True,
                  route: str = "auto") -> tuple[bytes, str]:
    """Converts an in-memory Keras model, returning ``(blob, routeName)``.

    The retry has to wrap ``convert()``, not the converter construction: on Keras 3.15 + TF 2.21
    ``from_keras_model`` builds an object that fails only when asked to convert. Callers that
    hold a model in memory (the pipeline check, T-06 ablations) should use this rather than
    round-tripping through a ``.keras`` file.
    """
    if route in ("auto", "keras"):
        try:
            converter, _ = build_converter(model, samples, int8=int8, route="keras")
            return bytes(converter.convert()), "from_keras_model"
        except Exception as exc:  # noqa: BLE001
            if route == "keras":
                raise
            print(f"  [note] from_keras_model cannot convert on this toolchain "
                  f"({type(exc).__name__}: {exc}); falling back to from_concrete_functions")
    converter, _ = build_converter(model, samples, int8=int8, route="concrete")
    return bytes(converter.convert()), "from_concrete_functions"


def convert_tflite(model_path: Path, int8: bool = True,
                   samples: Optional[Sequence[np.ndarray]] = None,
                   route: str = "auto") -> bytes:
    """Converts a ``.keras`` artifact to TFLite bytes.

    ``int8=True`` performs the full-integer conversion with calibration; ``int8=False`` produces
    the FP32 control artifact (FF-16 caps it at 6 MB).
    """
    import tensorflow as tf

    model = tf.keras.models.load_model(str(model_path))
    blob, used = convert_model(
        model,
        samples if samples is not None else representative_samples(),
        int8=int8,
        route=route,
    )
    print(f"  converter     : {used}")
    if not blob:
        raise RuntimeError("ACD-ART-001: TFLite conversion produced an empty artifact")
    return blob


def load_interpreter(tflite_path: Path):
    """Loads a TFLite artifact and allocates its tensors."""
    import tensorflow as tf

    interp = tf.lite.Interpreter(model_path=str(tflite_path))
    interp.allocate_tensors()
    return interp


def self_check(tflite_path: Path, expect_bytes_max: Optional[int] = None) -> Dict[str, object]:
    """Loads the artifact, runs one forward pass and asserts the §7 criteria 5-7 and 3-4.

    Raises on any deviation: an artifact that does not load, does not produce a 6-class softmax
    or exceeds the FF-16 size cap must never reach ``app/assets/models/``.
    """
    import tensorflow as tf

    size = tflite_path.stat().st_size
    cap = int(expect_bytes_max if expect_bytes_max is not None else CONFIG.domain.int8_max_bytes)
    if size > cap:
        raise AssertionError(
            f"ACD-ART-001: {tflite_path.name} is {size} bytes > FF-16 cap {cap}; the export is a "
            "hard gate and 'ship now, optimise later' is not an option (SPEC-T-07 section 2.4)"
        )
    interp = load_interpreter(tflite_path)
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    if inp["dtype"] != np.float32 or out["dtype"] != np.float32:
        raise AssertionError(
            f"ACD-ART-001: I/O dtype must be float32, got {inp['dtype']} / {out['dtype']}"
        )
    shape = [int(v) for v in inp["shape"]]
    if shape != list(CONFIG.input_shape):
        raise AssertionError(f"ACD-ART-004: input shape {shape} != {CONFIG.input_shape} (FF-14)")
    oshape = [int(v) for v in out["shape"]]
    if oshape != [1, CONFIG.num_classes]:
        raise AssertionError(
            f"ACD-ART-004: output shape {oshape} != [1, {CONFIG.num_classes}] (FF-19)"
        )
    probe = np.zeros(tuple(CONFIG.input_shape), dtype=np.float32)
    interp.set_tensor(inp["index"], probe)
    interp.invoke()
    probs = np.asarray(interp.get_tensor(out["index"])[0], dtype=np.float64)
    total = float(probs.sum())
    if not (0.999 <= total <= 1.001):
        raise AssertionError(f"ACD-ART-004: output rows must sum to 1, got {total}")
    return {
        "bytes": int(size),
        "inputShape": shape,
        "outputShape": oshape,
        "inputDtype": "float32",
        "outputDtype": "float32",
        "probsSum": total,
        "tfliteSha256": sha256_file(tflite_path),
        "tfliteRuntimeVersion": tf.__version__,
    }


# ------------------------------------------------------------------- model card


def build_model_card(tflite_path: Path, version: Optional[str] = None,
                     mel_version: Optional[str] = None,
                     parity_label_match: Optional[float] = None,
                     parity_max_conf_delta: Optional[float] = None,
                     created_at_ms: Optional[int] = None) -> Dict[str, object]:
    """Assembles the 15-field model card of API-06 section 5.

    ``parityLabelMatch`` / ``parityMaxConfDelta`` default to ``None`` (the SPEC allows ``null``
    pre-T-08, and T-08's ``--update-model-card`` fills them in). Every other field is measured or
    read from the SSOT / the Kotlin constant.
    """
    if not tflite_path.exists():
        raise FileNotFoundError(f"ACD-ART-001: {tflite_path} not found; run the export first")
    card = {
        "name": CONFIG.domain.model_name,
        "version": version or CONFIG.domain.model_version,
        "createdAtMs": int(created_at_ms if created_at_ms is not None else time.time() * 1000),
        "quantization": "int8",
        "inputShape": list(CONFIG.input_shape),
        "numClasses": int(CONFIG.num_classes),
        "classLabels": list(CONFIG.class_labels),
        "nFrames": int(CONFIG.n_frames),
        "melVersion": mel_version if mel_version is not None else read_kotlin_mel_version(),
        "featureConfigSha256": sha256_file(paths.ssot),
        "tfliteSha256": sha256_file(tflite_path),
        "tfliteBytes": int(tflite_path.stat().st_size),
        "parityLabelMatch": parity_label_match,
        "parityMaxConfDelta": parity_max_conf_delta,
        "metricsRef": "ai/artifacts/metrics.json",
    }
    missing = [f for f in MODEL_CARD_FIELDS if f not in card]
    if missing:
        raise AssertionError(f"ACD-ART-001: model card is missing {missing}")
    return card


def write_model_card(card: Dict[str, object], out_path: Optional[Path] = None) -> Path:
    """Writes the card, refusing to drop or rename any of the 15 fields."""
    extra = set(card) - set(MODEL_CARD_FIELDS)
    if extra:
        raise AssertionError(
            f"ACD-ART-001: model card has fields not in API-06 section 5: {sorted(extra)}"
        )
    path = Path(out_path) if out_path else paths.artifacts / "model_card.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(card, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def deliver_to_app(tflite_path: Path, card: Dict[str, object],
                   app_models: Optional[Path] = None) -> Path:
    """Renames-copies the artifact into the app asset tree and asserts byte equality.

    The copy is a **rename only** -- re-converting would risk a different artifact and break the
    ``tfliteSha256`` closure of API-06 section 9.
    """
    import shutil

    target_dir = Path(app_models) if app_models else paths.app_models
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{card['name']}_int8_v{card['version']}.tflite"
    shutil.copyfile(tflite_path, target)
    copied = sha256_file(target)
    if copied != card["tfliteSha256"]:
        raise AssertionError(
            f"ACD-ART-003: delivered copy hash {copied} != card hash {card['tfliteSha256']}"
        )
    if target.stat().st_size != int(card["tfliteBytes"]):
        raise AssertionError("ACD-ART-003: delivered copy size differs from the card")
    return target


# ------------------------------------------------------------------- orchestration


def run_export(model_path: Optional[Path] = None, out_dir: Optional[Path] = None,
               version: Optional[str] = None, representative_n: Optional[int] = None,
               deliver: bool = True, skip_fp32: bool = False,
               card_out: Optional[Path] = None) -> Dict[str, object]:
    """Full T-07 pipeline: convert INT8 (+FP32 control), self-check, card, deliver.

    ``card_out`` names where the authoritative card is written. Its default is
    ``app/assets/models/model_card.json``: that is the copy the App reads at start-up, and it is
    the file API-06 section 1 table row 4 points at, so the artifact tree and the asset tree must
    not be allowed to disagree. ``ai/artifacts/model_card.json`` is also written as the
    ``metrics.json.modelRef`` target.
    """
    out = Path(out_dir) if out_dir else paths.artifacts
    out.mkdir(parents=True, exist_ok=True)
    keras_path = Path(model_path) if model_path else out / (
        f"{CONFIG.domain.model_name}_fp32_v{CONFIG.domain.model_version}.keras")
    if not keras_path.exists():
        raise FileNotFoundError(
            f"ACD-ART-001: {keras_path} not found; T-07 converts the T-04 artifact"
        )
    version = version or CONFIG.domain.model_version

    print("=" * 78)
    print("T-07 INT8 export")
    print(f"  source        : {keras_path}")
    print(f"  nFrames       : {CONFIG.n_frames} (FF-11 / ADR-P1, read from the SSOT)")
    print(f"  inputShape    : {CONFIG.input_shape}")
    print(f"  classLabels   : {CONFIG.class_labels}")
    print(f"  INT8 cap      : {CONFIG.domain.int8_max_bytes} bytes (FF-16)")
    print("=" * 78)

    samples = representative_samples(limit=representative_n)
    print(f"  representative: {len(samples)} patches from train.csv only "
          f"(>= {CONFIG.domain.representative_per_class_min}/class)")

    int8_blob = convert_tflite(keras_path, int8=True, samples=samples)
    int8_path = out / "model_int8.tflite"
    int8_path.write_bytes(int8_blob)
    print(f"  INT8          : {int8_path.name} = {len(int8_blob)} bytes")

    fp32_report = None
    if not skip_fp32:
        fp32_blob = convert_tflite(keras_path, int8=False)
        fp32_path = out / "model_fp32.tflite"
        fp32_path.write_bytes(fp32_blob)
        fp32_report = self_check(fp32_path, expect_bytes_max=CONFIG.domain.fp32_max_bytes)
        print(f"  FP32 control  : {fp32_path.name} = {len(fp32_blob)} bytes")

    check = self_check(int8_path)
    print(f"  self-check    : input={check['inputShape']} output={check['outputShape']} "
          f"sum(probs)={check['probsSum']:.6f}")

    card = build_model_card(int8_path, version=version)
    # Authoritative location first (the App reads it and the constant generator projects it),
    # then the artifact-tree copy that metrics.json.modelRef names.
    primary_card = Path(card_out) if card_out else paths.app_models / "model_card.json"
    card_path = write_model_card(card, primary_card)
    artifact_card = write_model_card(card, out / "model_card.json")
    print(f"  melVersion    : {card['melVersion']} (parsed from Kotlin FeatureConfig.kt)")
    print(f"  model card    : {card_path}")
    print(f"  model card    : {artifact_card} (artifact-tree copy)")

    delivered = None
    if deliver:
        delivered = deliver_to_app(int8_path, card)
        print(f"  delivered     : {delivered} (byte-identical, sha256 unchanged)")

    summary = {
        "int8Path": str(int8_path),
        "fp32Path": None if skip_fp32 else str(out / "model_fp32.tflite"),
        "cardPath": str(card_path),
        "artifactCardPath": str(artifact_card),
        "deliveredPath": None if delivered is None else str(delivered),
        "int8Bytes": int(card["tfliteBytes"]),
        "tfliteSha256": card["tfliteSha256"],
        "selfCheck": check,
        "fp32Check": fp32_report,
        "representativeN": len(samples),
        "modelCard": card,
    }
    (out / "export_report.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n  wrote {card_path}")
    print(f"  wrote {out / 'export_report.json'}")
    return summary


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=None, help="source .keras artifact (default: T-04 output)")
    ap.add_argument("--out-dir", default=None, help="artifacts directory")
    ap.add_argument("--version", default=None, help="model version (default from CONFIG)")
    ap.add_argument("--representative-n", type=int, default=None)
    ap.add_argument("--no-deliver", action="store_true",
                    help="do not copy into app/assets/models/")
    ap.add_argument("--skip-fp32", action="store_true", help="skip the FP32 control conversion")
    args = ap.parse_args(argv)

    try:
        run_export(model_path=Path(args.model) if args.model else None,
                   out_dir=Path(args.out_dir) if args.out_dir else None,
                   version=args.version, representative_n=args.representative_n,
                   deliver=not args.no_deliver, skip_fp32=args.skip_fp32)
    except (FileNotFoundError, dataset_mod.DatasetContractError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except AssertionError as exc:
        print(str(exc), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

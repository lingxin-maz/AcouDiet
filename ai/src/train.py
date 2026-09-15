"""T-04 the training loop (FF-17) -- AdamW, cosine 1e-3 -> 1e-5, batch 32, early stopping.

Frozen configuration (FF-17), all of it read from ``CONFIG.domain`` so there is exactly one copy
of every number: AdamW with weight decay, a cosine decay from ``learning_rate_initial`` to
``learning_rate_final``, batch 32, at most 50 epochs, ``EarlyStopping`` on ``val_loss`` with
patience 5, and categorical cross-entropy with label smoothing 0.1.

The test sets are never touched
-------------------------------
``SPEC-T-02`` section 2.2 assertion D forbids the literals ``test_public`` / ``test_mobile``
anywhere in ``train.py`` / ``model.py`` / ``augment.py``: model selection may only look at
``val.csv``. That is why the split names below are assembled from :data:`SPLITS` constants
rather than written out, and why ``test_no_test_literal_in_train_code`` can grep this file.

Reproducibility
---------------
One seed drives everything: the patch offset inside each recording, the augmentation RNG and the
Keras initialisers. The augmentation seed is derived from ``(base_seed, epoch, index)``, so the
same configuration produces the same curves (SPEC-T-03 section 2.3).

Usage::

    python ai/src/train.py --run-id baseline --augment off
    python ai/src/train.py --run-id aug --augment on --epochs 2 --limit 240
    python ai/src/train.py --run-id smoke --epochs 1 --dry-run
"""

from __future__ import annotations

# oneDNN's fused kernels change the summation order, which would make "same seed -> same curve"
# subtly false across machines. Turn it off before TensorFlow is imported (SPEC-T-04 section 8).
import os

os.environ.setdefault("TF_ENABLE_ONEDNN_OPTS", "0")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import argparse  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402
from typing import Dict, List, Optional, Sequence  # noqa: E402

import numpy as np  # noqa: E402

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, assert_frozen_invariants, paths, sha256_file
    from src import augment as augment_mod
    from src import dataset as dataset_mod
    from src import features
else:
    from .config import CONFIG, assert_frozen_invariants, paths, sha256_file
    from . import augment as augment_mod
    from . import dataset as dataset_mod
    from . import features

__all__ = ["PatchSequence", "TrainResult", "run_training", "resolve_device"]

#: The split names this script is allowed to read. ``val`` is the ONLY selection set (assertion D).
SELECTION_SPLIT = "val"
TRAIN_SPLIT = "train"


def resolve_device(requested: str = "auto") -> tuple[str, str]:
    """Resolves ``auto|cpu|gpu`` into ``("/CPU:0", reason)``.

    TensorFlow does not use CUDA on native Windows (>= 2.11), so ``auto`` legitimately lands on
    the CPU here; the reason string is recorded in ``train_config.json`` for the report.
    """
    import tensorflow as tf

    gpus = tf.config.list_physical_devices("GPU")
    if requested == "cpu":
        return "/CPU:0", "requested --device cpu"
    if requested == "gpu":
        if not gpus:
            return "/CPU:0", "requested gpu but TensorFlow sees none; fell back to CPU"
        return "/GPU:0", "requested --device gpu"
    if gpus:
        return "/GPU:0", f"auto: {len(gpus)} GPU(s) visible"
    return "/CPU:0", "auto: no TensorFlow GPU (CUDA is unsupported on native Windows TF>=2.11)"


class TrainWatchdog:
    """The R-ENV-2 stop-loss: record a ``deviceSwitchReason`` when the 2 h line is crossed.

    Keras 3 has no supported way for a callback to abort ``fit`` mid-epoch, and SPEC-T-04
    section 2.4 explicitly forbids cutting the epoch budget to make up time, so the watchdog
    does not silently shrink the run. It measures and records, and the caller can then act on
    the recorded reason -- which is the honest behaviour: a silently shortened run would make
    the resulting numbers incomparable with the rest of the report.
    """

    def __init__(self, deadline_s: float) -> None:
        self.deadline_s = float(deadline_s)
        self.started = time.time()
        self.tripped = False

    @property
    def elapsed(self) -> float:
        return time.time() - self.started

    def check(self) -> Optional[str]:
        if self.elapsed > self.deadline_s:
            self.tripped = True
            return (
                f"watchdog: elapsed {self.elapsed / 3600.0:.2f} h exceeded the "
                f"{self.deadline_s / 3600.0:.1f} h stop-loss (R-ENV-2); the epoch budget was NOT "
                "reduced, because that would make this run incomparable (SPEC-T-04 section 2.4)"
            )
        return None


class PatchSequence:
    """On-the-fly patch provider: read wav -> (augment) -> FF-02..FF-08 -> model input.

    Nothing is cached to disk. SPEC-T-04 section 8 forbids caching Mel features, and SPEC-T-03
    section 8 forbids caching augmentation results, because a cache would break the auditability
    of "the test sets are never augmented".
    """

    def __init__(self, rows: Sequence[dict], augment_on: bool, denoise: bool,
                 seed: int, noise_bank: Optional[augment_mod.NoiseBank] = None,
                 limit: int = 0, name: str = "train") -> None:
        self.rows = list(rows)
        if limit and limit > 0:
            self.rows = self.rows[:limit]
        self.augment_on = bool(augment_on)
        self.denoise = bool(denoise)
        self.seed = int(seed)
        self.noise_bank = noise_bank
        self.name = name
        self.epoch = 0
        #: Aggregated augmentation statistics, surfaced into the training log.
        self.last_stats: List[dict] = []
        if not self.rows:
            raise dataset_mod.DatasetContractError(
                f"ACD-ART-001: split {name!r} is empty; refusing to train (SPEC-T-04 exit 1)"
            )

    def __len__(self) -> int:
        return len(self.rows)

    def on_epoch_begin(self, epoch: int) -> None:
        self.epoch = int(epoch)

    def _patch(self, row: dict, index: int) -> np.ndarray:
        """Reads one patch. The offset depends only on ``(seed, epoch, index)``.

        The offset RNG is a *separate* stream from the augmentation RNG. Sharing one stream
        would make the augmentation parameters depend on whether a file was long enough to need
        an offset at all, so the same sample index would draw different gains in different
        epochs for no principled reason.
        """
        import soundfile as sf

        path = paths.workspace / row["path"].replace("/", os.sep)
        if not path.exists():
            raise FileNotFoundError(f"ACD-ART-001: split row points at a missing file: {path}")
        data, sr = sf.read(str(path), dtype="int16", always_2d=True)
        if int(sr) != CONFIG.sample_rate:
            raise ValueError(f"ACD-ART-001: {path} is {sr} Hz, expected {CONFIG.sample_rate} Hz")
        pcm = np.ascontiguousarray(data[:, 0])
        n = CONFIG.patch_samples
        if pcm.shape[0] <= n:
            return pcm
        span = pcm.shape[0] - n
        rng = np.random.default_rng(augment_mod.derive_seed(self.seed, -self.epoch - 1, index))
        start = int(rng.integers(0, span + 1))
        return pcm[start:start + n]

    def batch(self, indices: Sequence[int]) -> tuple[np.ndarray, np.ndarray]:
        """Builds one batch of model inputs and one-hot labels."""
        xs = np.empty((len(indices),) + tuple(CONFIG.input_shape[1:]), dtype=np.float32)
        ys = np.zeros((len(indices), CONFIG.num_classes), dtype=np.float32)
        self.last_stats = []
        for slot, idx in enumerate(indices):
            row = self.rows[int(idx)]
            pcm = self._patch(row, int(idx))
            rng = np.random.default_rng(augment_mod.derive_seed(self.seed, self.epoch, int(idx)))
            tensor, stats = augment_mod.feature_tensor(
                pcm,
                split=TRAIN_SPLIT if self.augment_on else SELECTION_SPLIT,
                rng=rng,
                noise_bank=self.noise_bank,
                augment_on=self.augment_on,
                specaugment_on=self.augment_on,
                denoise=self.denoise,
            )
            xs[slot] = tensor[0]
            ys[slot, CONFIG.class_labels.index(row["label"])] = 1.0
            self.last_stats.append(stats.as_dict())
        return xs, ys

    def keras_sequence(self):
        """Returns a ``keras.utils.Sequence`` over batches (shuffled every epoch)."""
        import tensorflow as tf

        outer = self

        class _Seq(tf.keras.utils.Sequence):
            def __init__(self) -> None:
                self.indices = np.arange(len(outer))

            def __len__(self) -> int:
                return int(np.ceil(len(outer) / CONFIG.domain.batch_size))

            def __getitem__(self, i):
                lo = i * CONFIG.domain.batch_size
                hi = min(lo + CONFIG.domain.batch_size, len(self.indices))
                return outer.batch(self.indices[lo:hi])

            def on_epoch_end(self) -> None:
                np.random.default_rng(augment_mod.derive_seed(outer.seed, outer.epoch, 0)).shuffle(
                    self.indices
                )

        return _Seq()


# --------------------------------------------------------------------------------- training


class TrainResult(dict):
    """Plain dict subclass so callers can ``**result`` without a dataclass ceremony."""


def _jsonl_append(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False) + "\n")


def run_training(run_id: str, augment_on: bool, denoise: bool, epochs: int,
                 seed: int, device: str = "auto", limit: int = 0, dry_run: bool = False,
                 batch_size: Optional[int] = None, resume: bool = False,
                 out_dir: Optional[Path] = None) -> TrainResult:
    """Runs one training job and returns its measured summary.

    Everything reported here is measured: parameter count from the built model, epochs from the
    history, macro F1 computed from the validation predictions. No value is predicted.
    """
    import tensorflow as tf

    assert_frozen_invariants()
    tf.keras.utils.set_random_seed(int(seed))
    # Keras 3 has no ``enable_op_determinism`` knob; the seed above plus ``shuffle=False`` on
    # ``fit`` and the deterministic patch offsets are what make a run reproducible.

    batch = int(batch_size or CONFIG.domain.batch_size)
    out = Path(out_dir) if out_dir else paths.artifacts
    out.mkdir(parents=True, exist_ok=True)
    run_dir = out / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    splits = dataset_mod.read_splits()
    train_rows = splits[TRAIN_SPLIT]
    val_all = splits[SELECTION_SPLIT]
    adapt_subjects = set(CONFIG.domain.mobile_adapt_subjects)
    val_rows = [r for r in val_all if r["subject_id"] not in adapt_subjects]
    adapt_rows = [r for r in val_all if r["subject_id"] in adapt_subjects]
    if not val_rows:
        print("ACD-ART-001: the public validation rows are empty (exit 6)", file=sys.stderr)
        raise SystemExit(6)
    present = {r["label"] for r in val_rows}
    missing = [lbl for lbl in CONFIG.class_labels if lbl not in present]
    if missing:
        print(f"ACD-ART-001: val is missing classes {missing} (exit 6); early stopping and "
              "threshold calibration would be meaningless", file=sys.stderr)
        raise SystemExit(6)

    # T-06 factor A ("denoise") can additionally fold the adaptation rows (P04/P05) into the
    # training set. Those rows are validation-only by API-06 section 3.2 -- they may never come
    # from train.csv -- so they are added here, explicitly, and the fact is recorded.
    if denoise and adapt_rows:
        train_rows = list(train_rows) + list(adapt_rows)

    noise_bank = None
    if augment_on:
        noise_bank = augment_mod.load_noise_bank()
        if len(noise_bank) == 0:
            print("ACD-ART-001: augmentation requested but the noise bank is empty (exit 1); "
                  "SPEC-T-03 section 6 forbids substituting white noise", file=sys.stderr)
            raise SystemExit(1)

    train_seq = PatchSequence(train_rows, augment_on=augment_on, denoise=denoise,
                              seed=seed, noise_bank=noise_bank, limit=limit, name=TRAIN_SPLIT)
    val_seq = PatchSequence(val_rows, augment_on=False, denoise=False, seed=seed,
                            noise_bank=None, limit=limit, name=SELECTION_SPLIT)

    model, info = _build_and_compile(epochs=epochs, batch_size=batch, steps=len(train_seq))
    resolved_device, device_reason = resolve_device(device)

    log_path = out / "train_log.jsonl"
    config_path = run_dir / "train_config.json"
    watchdog = TrainWatchdog(CONFIG.domain.watchdog_seconds)
    history = {"loss": [], "val_loss": [], "accuracy": [], "val_accuracy": []}
    switch_reason = ""

    print("=" * 78)
    print(f"T-04 training  run_id={run_id}  augment={'on' if augment_on else 'off'}  "
          f"denoise={'on' if denoise else 'off'}")
    print(f"  train rows    : {len(train_seq)}" + (f" (limit {limit})" if limit else "")
          + f"   val rows: {len(val_seq)}")
    print(f"  epochs        : <= {epochs} (early stopping patience "
          f"{CONFIG.domain.early_stopping_patience} on val_loss)")
    print(f"  batch / lr    : {batch} / {CONFIG.domain.learning_rate_initial} -> "
          f"{CONFIG.domain.learning_rate_final}")
    print(f"  params        : {info['paramCount']} (measured, FF-15)")
    print(f"  pretrained    : {info['pretrained']} {info['note']}")
    print(f"  device        : {resolved_device} ({device_reason})")
    print("=" * 78)

    best_val = float("inf")
    best_epoch = 0
    epochs_run = 0
    t_start = time.time()
    for epoch in range(1, int(epochs) + 1):
        train_seq.on_epoch_begin(epoch)
        seq = train_seq.keras_sequence()
        t0 = time.time()
        hist = model.fit(seq, epochs=1, verbose=0, shuffle=False)
        t1 = time.time()
        val_metrics = model.evaluate(val_seq.keras_sequence(), verbose=0, return_dict=True)
        val_loss = float(val_metrics.get("loss", float("nan")))
        val_acc = float(val_metrics.get("accuracy", float("nan")))
        val_f1 = _macro_f1(model, val_seq, batch)
        lr_now = float(tf.keras.backend.get_value(model.optimizer.learning_rate))
        epochs_run = epoch
        history["loss"].append(float(hist.history["loss"][0]))
        history["val_loss"].append(val_loss)
        history["accuracy"].append(float(hist.history["accuracy"][0]))
        history["val_accuracy"].append(val_acc)

        row = {
            "runId": run_id, "epoch": epoch, "step": int(len(seq)),
            "trainLoss": round(history["loss"][-1], 6), "valLoss": round(val_loss, 6),
            "valAcc": round(val_acc, 6), "valMacroF1": round(val_f1, 6),
            "lr": lr_now, "device": resolved_device, "elapsedS": round(t1 - t0, 3),
            "augment": "on" if augment_on else "off", "denoise": "on" if denoise else "off",
            "seed": int(seed), "augmentStats": _summarise_stats(train_seq.last_stats),
        }
        _jsonl_append(log_path, row)
        print(f"  epoch {epoch:3d}  trainLoss={row['trainLoss']:.4f}  valLoss={val_loss:.4f}  "
              f"valAcc={val_acc:.4f}  valMacroF1={val_f1:.4f}  lr={lr_now:.2e}  "
              f"({row['elapsedS']:.1f}s)")
        if val_loss < best_val - 1e-9:
            best_val, best_epoch = val_loss, epoch
        reason = watchdog.check()
        if reason and not switch_reason:
            switch_reason = reason
            print(f"  WARN {reason}")
        if epoch - best_epoch >= CONFIG.domain.early_stopping_patience:
            print(f"  early stopping: no val_loss improvement for "
                  f"{CONFIG.domain.early_stopping_patience} epochs")
            break

    if best_epoch and best_epoch != epochs_run:
        print(f"  NOTE best epoch was {best_epoch}; the freshly exported model is the LAST epoch. "
              "T-05 evaluates the exported artifact, so this run is reproducible but not "
              "best-epoch-restored (SPEC-T-04 section 8 budgets the export, not a re-fit).")

    keras_path, saved_model_dir = _export(model, out, run_id, dry_run=dry_run)
    elapsed = time.time() - t_start

    config = {
        "runId": run_id,
        "createdAtMs": int(time.time() * 1000),
        "nFrames": CONFIG.n_frames,
        "inputShape": list(CONFIG.input_shape),
        "numClasses": CONFIG.num_classes,
        "paramCount": info["paramCount"],
        "epochsRun": epochs_run,
        "bestEpoch": best_epoch,
        "epochsRequested": int(epochs),
        "selectionSplit": SELECTION_SPLIT,
        "device": resolved_device,
        "deviceRequested": device,
        "deviceSwitchReason": switch_reason or device_reason,
        "baseSeed": int(seed),
        "augment": "on" if augment_on else "off",
        "denoise": "on" if denoise else "off",
        "trainRows": len(train_seq),
        "valRows": len(val_seq),
        "limit": int(limit),
        "batchSize": batch,
        "pretrained": info["pretrained"],
        "pretrainedNote": info["note"],
        "earlyStoppingPatience": CONFIG.domain.early_stopping_patience,
        "watchdogSeconds": CONFIG.domain.watchdog_seconds,
        "kerasFile": None if dry_run else keras_path.name,
        "savedModelDir": None if dry_run else str(saved_model_dir),
        "elapsedS": round(elapsed, 3),
        "history": history,
        "splitSha256": {name: sha256_file(paths.splits / f"{name}.csv")
                        for name in dataset_mod.SPLITS},
        "featureConfigSha256": sha256_file(paths.ssot),
        "kerasVersion": tf.keras.__version__,
        "tfVersion": tf.__version__,
        "substituteCorpus": True,
    }
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n  wrote {config_path}")
    print(f"  wrote {log_path}")
    if not dry_run:
        print(f"  wrote {keras_path}")
        print(f"  wrote {saved_model_dir}")

    return TrainResult(config)


def _summarise_stats(stats: Sequence[dict]) -> Dict[str, object]:
    """Reduces per-sample augmentation stats to the log-friendly summary of SPEC-T-03 section 4."""
    if not stats:
        return {}
    def _mean(key: str):
        vals = [s[key] for s in stats if s.get(key) is not None]
        return round(float(np.mean(vals)), 4) if vals else None

    skipped: Dict[str, int] = {}
    for s in stats:
        for k in s.get("skipped") or []:
            skipped[k] = skipped.get(k, 0) + 1
    return {
        "snrDbMean": _mean("snrDb"),
        "gainMean": _mean("gain"),
        "clippedRatioMax": round(max(float(s["clippedRatio"]) for s in stats), 6),
        "specaugTimeRatioMax": round(max(float(s["specaugTimeRatio"]) for s in stats), 6),
        "specaugFreqRatioMax": round(max(float(s["specaugFreqRatio"]) for s in stats), 6),
        "noiseFilesUsed": sorted({s["noiseFile"] for s in stats if s.get("noiseFile")}),
        "skipped": skipped,
    }


def _macro_f1(model, seq: PatchSequence, batch: int) -> float:
    """Macro F1 measured from validation predictions (the early-stopping companion metric)."""
    preds: List[int] = []
    truth: List[int] = []
    for i in range(0, len(seq), batch):
        idx = list(range(i, min(i + batch, len(seq))))
        xs, ys = seq.batch(idx)
        p = model.predict(xs, verbose=0)
        preds.extend(np.argmax(p, axis=1).tolist())
        truth.extend(np.argmax(ys, axis=1).tolist())
    return float(_f1_from(np.asarray(truth), np.asarray(preds), CONFIG.num_classes))


def _f1_from(y_true: np.ndarray, y_pred: np.ndarray, num_classes: int) -> float:
    """Macro-averaged F1 from a confusion matrix (no sklearn dependency)."""
    scores = []
    for c in range(num_classes):
        tp = int(np.sum((y_pred == c) & (y_true == c)))
        fp = int(np.sum((y_pred == c) & (y_true != c)))
        fn = int(np.sum((y_pred != c) & (y_true == c)))
        if tp == 0 and (fp + fn) == 0:
            continue
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        scores.append(0.0 if (precision + recall) == 0 else 2 * precision * recall / (precision + recall))
    return float(np.mean(scores)) if scores else 0.0


def _build_and_compile(epochs: int, batch_size: int, steps: int):
    """Builds and compiles the model with the FF-17 optimizer/loss configuration."""
    import tensorflow as tf

    if __package__ in (None, ""):
        import model as model_mod  # type: ignore[import-not-found]
    else:
        from . import model as model_mod

    net, info = model_mod.build_model()
    total_steps = max(1, steps) * max(1, int(epochs))
    schedule = tf.keras.optimizers.schedules.CosineDecay(
        initial_learning_rate=CONFIG.domain.learning_rate_initial,
        decay_steps=total_steps,
        alpha=CONFIG.domain.learning_rate_final / CONFIG.domain.learning_rate_initial,
    )
    optimizer = tf.keras.optimizers.AdamW(
        learning_rate=schedule, weight_decay=CONFIG.domain.weight_decay
    )
    loss = tf.keras.losses.CategoricalCrossentropy(
        label_smoothing=CONFIG.domain.label_smoothing
    )
    net.compile(optimizer=optimizer, loss=loss, metrics=["accuracy"])
    return net, info


def _export(model, out: Path, run_id: str, dry_run: bool) -> tuple[Path, Path]:
    """Writes the ``.keras`` artifact and the SavedModel that T-07 consumes."""
    version = CONFIG.domain.model_version
    keras_path = out / f"{CONFIG.domain.model_name}_fp32_v{version}.keras"
    saved_dir = out / "saved_model"
    if dry_run:
        print("  --dry-run: artifacts NOT written (SPEC-T-04 section 7 criterion 15)")
        return keras_path, saved_dir
    model.save(str(keras_path))
    # Keep one SavedModel per run so T-06 ablations can quantise each run independently; the
    # canonical path is overwritten by the last (main-line) run.
    run_dir = out / "runs" / run_id
    model.export(str(run_dir / "saved_model"))
    model.export(str(saved_dir))
    return keras_path, saved_dir


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-id", default="baseline")
    ap.add_argument("--augment", choices=["on", "off"], default="off",
                    help="T-03 factor B: the four online augmentations")
    ap.add_argument("--denoise", choices=["on", "off"], default="off",
                    help="T-06 factor A: training-side spectral-subtraction denoising")
    ap.add_argument("--epochs", type=int, default=CONFIG.domain.max_epochs)
    ap.add_argument("--seed", type=int, default=CONFIG.domain.split_seed)
    ap.add_argument("--device", choices=["auto", "cpu", "gpu"], default="auto")
    ap.add_argument("--batch-size", type=int, default=None)
    ap.add_argument("--limit", type=int, default=CONFIG.domain.default_train_limit,
                    help="cap the number of training rows (0 = use them all)")
    ap.add_argument("--dry-run", action="store_true", help="smoke mode: never writes artifacts")
    ap.add_argument("--resume", action="store_true", help="informational; checkpoints are per-run")
    ap.add_argument("--out", default=None, help="artifacts directory (default ai/artifacts)")
    args = ap.parse_args(argv)

    if args.epochs < 1:
        print("ACD-ART-001: --epochs must be >= 1", file=sys.stderr)
        return 1
    try:
        run_training(
            run_id=args.run_id,
            augment_on=args.augment == "on",
            denoise=args.denoise == "on",
            epochs=args.epochs,
            seed=args.seed,
            device=args.device,
            limit=args.limit,
            dry_run=args.dry_run,
            batch_size=args.batch_size,
            resume=args.resume,
            out_dir=Path(args.out) if args.out else None,
        )
    except dataset_mod.DatasetContractError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

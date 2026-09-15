"""T-06 the ablation study -- a 2x2 factorial design with **measured** deltas.

Two factors, four runs (SPEC-T-06 section 1.2):

  factor A ``denoise``  training-side spectral-subtraction denoising      off / on
  factor B ``augment``  the four online augmentations of T-03 (as a set)  off / on

      off/off  baseline            off/on  augment=on
      on/off   denoise=on          on/on   denoise=on,augment=on

Every non-factor hyper-parameter is frozen by FF-17 and must be identical across the four runs --
otherwise the comparison is meaningless, and SPEC-T-06 section 6 makes that a hard error rather
than a footnote. ``deltaVsBaseline`` is the **measured** difference ``top1 - baseline.top1``; it
may perfectly well be negative, and a negative result is kept rather than re-rolled. The SPEC is
explicit that nothing here is a "predicted" or "expected" improvement.

Cut features
------------
``X-06`` cuts RIR convolution and Mixup, so no ablation may mention them, and :func:`assert_clean`
refuses to write a file that contains those keys or the reserved class ``nuts`` (FF-19: it is not
in v1.0). ``noodles`` was reserved too until ADR-19 promoted it to a delivered class, so it is a
required per-class row now, not a forbidden token. The check is on the serialised JSON, so a key
cannot sneak in through a nested structure.

Where the numbers live
----------------------
``ai/artifacts/ablations.json`` is authoritative for the full table (API-06 section 6).
``metrics.json.ablations[]`` carries only the summary and must agree with it field by field --
:func:`merge_summary` produces that summary from this file, so the two can never drift.

Usage::

    python ai/src/ablations.py --out ai/artifacts/ablations.json --epochs 2 --limit 600
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence

if __package__ in (None, ""):  # executed as a script: ``python ai/src/ablations.py``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, paths, sha256_file
    from src import dataset as dataset_mod
    from src import evaluate as evaluate_mod
else:  # imported as ``src.ablations``
    from .config import CONFIG, paths, sha256_file
    from . import dataset as dataset_mod
    from . import evaluate as evaluate_mod
__all__ = [
    "FACTOR_COMBINATIONS", "TOGGLES", "ID_MAP", "NAME_MAP",
    "assert_clean", "run_ablations", "merge_summary", "write_ablations",
]

#: ``(denoise, augment)`` in a fixed order so the JSON rows are deterministic.
FACTOR_COMBINATIONS = ((False, False), (False, True), (True, False), (True, True))

#: ``toggle`` strings exactly as API-06 section 6 / SPEC-T-06 section 7 criterion 3 require them.
TOGGLES: Dict[tuple, str] = {
    (False, False): "augment=off",
    (False, True): "augment=on",
    (True, False): "denoise=on",
    (True, True): "denoise=on,augment=on",
}

#: Row ids used in ``runs[]`` (the baseline is represented by the ``baseline`` object instead).
ID_MAP: Dict[tuple, str] = {
    (False, False): "baseline",
    (False, True): "aug_on",
    (True, False): "denoise_on",
    (True, True): "denoise_on_aug_on",
}

NAME_MAP: Dict[tuple, str] = {
    (False, False): "无增强基线",
    (False, True): "增强组合 on",
    (True, False): "降噪 on",
    (True, True): "降噪 on + 增强组合 on",
}

#: Non-factor hyper-parameters that must be byte-identical across the four runs. Anything here
#: differing makes the row incomparable (SPEC-T-06 section 6, exit 11).
NON_FACTOR_KEYS = (
    "nFrames", "inputShape", "numClasses", "paramCount", "epochsRun", "epochsRequested",
    "baseSeed", "selectionSplit", "limit", "batchSize", "pretrained",
    "earlyStoppingPatience", "watchdogSeconds",
)

#: Strings that must never appear in the produced artifact (X-06 cuts, FF-19 reserved classes).
#: ADR-19 moved `noodles` out of the reserved set -- it is a delivered class now, and this table
#: legitimately reports per-class rows for it.
FORBIDDEN = ("rir", "mixup", "nuts", "显著", "significantly", "预期提升")


def assert_clean(blob: dict) -> None:
    """Refuses to emit a table containing a cut feature or a reserved class (API-06 section 12.8)."""
    text = json.dumps(blob, ensure_ascii=False).lower()
    hits = [token for token in FORBIDDEN if token in text]
    if hits:
        raise AssertionError(
            f"ACD-ART-005: the ablation table mentions cut features or reserved classes: {hits}. "
            "RIR and Mixup are cut by X-06 and nuts is not part of v1.0 (FF-19, as amended by ADR-19)."
        )


def run_ablations(run_dir: Optional[Path] = None, epochs: int = 2, limit: int = 600,
                  seed: Optional[int] = None, device: str = "auto",
                  reuse: bool = True, verbose: bool = True) -> Dict[str, object]:
    """Runs (or reuses) the four combinations and returns the assembled ``ablations.json`` blob.

    Each run is trained into its own sub-directory so the four artifacts coexist and each row's
    model stays available for inspection. The measured primary metric is the **cross-domain**
    Top-1 on ``test_mobile`` (SPEC-T-06 section 2.2 step 3), never the in-domain number.
    """
    from . import train as train_mod

    base_dir = Path(run_dir) if run_dir else paths.artifacts
    seed = CONFIG.domain.split_seed if seed is None else int(seed)
    records: List[dict] = []
    reference: Optional[dict] = None

    for denoise, augment in FACTOR_COMBINATIONS:
        run_id = ID_MAP[(denoise, augment)]
        out = base_dir
        cfg_path = out / "runs" / run_id / "train_config.json"
        keras_path = out / "runs" / run_id / (
            f"{CONFIG.domain.model_name}_fp32_v{CONFIG.domain.model_version}.keras")
        cfg: Optional[dict] = None
        if reuse and cfg_path.exists():
            cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
            same = (cfg.get("epochsRequested") == epochs and cfg.get("limit") == limit
                    and cfg.get("baseSeed") == seed
                    and cfg.get("augment") == ("on" if augment else "off")
                    and cfg.get("denoise") == ("on" if denoise else "off"))
            if not same or not keras_path.exists():
                if verbose:
                    print(f"  [{run_id}] stored run does not match this budget; retraining")
                cfg = None
        if cfg is None:
            if verbose:
                print(f"  [{run_id}] training denoise={'on' if denoise else 'off'} "
                      f"augment={'on' if augment else 'off'} ...")
            result = train_mod.run_training(
                run_id=run_id, augment_on=augment, denoise=denoise, epochs=epochs,
                seed=seed, device=device, limit=limit, out_dir=out,
            )
            cfg = dict(result)

        for key in NON_FACTOR_KEYS:
            if key not in cfg:
                raise AssertionError(
                    f"ACD-ART-005: run {run_id} is missing comparability field {key!r}; "
                    "the 2x2 design cannot be verified (SPEC-T-06 section 2.2 step 5)"
                )
            if reference is None:
                continue
            if cfg[key] != reference[key]:
                raise SystemExit(
                    f"ACD-ART-005: exit 11 -- non-factor hyper-parameter {key!r} differs between "
                    f"runs ({reference[key]!r} vs {cfg[key]!r}); the rows are not comparable"
                )
        if reference is None:
            reference = cfg

        evaluated = evaluate_mod.predict_split(
            evaluate_mod.load_model(keras_path), evaluate_mod.PRIMARY_TEST_SET
        )
        metrics = evaluate_mod.classification_metrics(evaluated["yTrue"], evaluated["yPred"])
        records.append({
            "combination": (denoise, augment),
            "runId": run_id,
            "id": ID_MAP[(denoise, augment)],
            "name": NAME_MAP[(denoise, augment)],
            "toggle": TOGGLES[(denoise, augment)],
            "top1": float(metrics["top1"]),
            "n": int(metrics["n"]),
            "macroF1": float(metrics["macroAvg"]["f1"]),
            "wilson95": dict(metrics["wilson95"]),
            "paramCount": int(cfg["paramCount"]),
            "trainRows": int(cfg.get("trainRows", 0)),
            "kerasSha256": sha256_file(keras_path),
        })
        if verbose:
            print(f"  [{run_id}] E2 top1={metrics['top1']:.4f} "
                  f"[{metrics['wilson95']['low']:.4f}, {metrics['wilson95']['high']:.4f}] "
                  f"n={metrics['n']} macroF1={metrics['macroAvg']['f1']:.4f}")

    base = next(r for r in records if r["combination"] == (False, False))
    params = {r["paramCount"] for r in records}
    if len(params) > 1:
        raise AssertionError(
            f"ACD-ART-005: the four runs have different parameter counts {sorted(params)}; the "
            "switches must not change the architecture (SPEC-T-06 section 6)"
        )

    runs = []
    for r in records:
        if r["combination"] == (False, False):
            continue
        runs.append({
            "id": r["id"],
            "name": r["name"],
            "toggle": r["toggle"],
            "top1": round(r["top1"], 6),
            "n": r["n"],
            "macroF1": round(r["macroF1"], 6),
            # Measured difference, allowed to be negative; never an "expected" improvement.
            "deltaVsBaseline": round(r["top1"] - base["top1"], 6),
            "note": (f"E2 cross-domain Top-1; Wilson95=[{r['wilson95']['low']:.4f}, "
                     f"{r['wilson95']['high']:.4f}]; runId={r['runId']}; "
                     f"trainRows={r['trainRows']}"),
        })

    blob = {
        "schemaVersion": "1.0",
        "generatedAtMs": int(time.time() * 1000),
        "baseline": {"id": base["id"], "top1": round(base["top1"], 6), "n": base["n"]},
        "runs": runs,
    }
    assert_clean(blob)
    return blob


def merge_summary(ablations_path: Optional[Path] = None) -> List[dict]:
    """Builds the ``metrics.json.ablations[]`` summary from ``ablations.json``.

    Producing the summary from the full table (rather than typing it twice) is what guarantees
    the two agree field by field, which API-06 section 6 requires.
    """
    path = Path(ablations_path) if ablations_path else paths.artifacts / "ablations.json"
    blob = json.loads(path.read_text(encoding="utf-8"))
    base = blob["baseline"]
    summary = [{
        "id": base["id"],
        "name": "无增强基线",
        "toggle": TOGGLES[(False, False)],
        "n": int(base["n"]),
        "top1": float(base["top1"]),
        "deltaVsBaseline": 0.0,
    }]
    for run in blob["runs"]:
        summary.append({
            "id": run["id"], "name": run["name"], "toggle": run["toggle"],
            "n": int(run["n"]), "top1": float(run["top1"]),
            "deltaVsBaseline": float(run["deltaVsBaseline"]),
        })
    return summary


def write_ablations(blob: dict, out_path: Optional[Path] = None) -> Path:
    """Validates the field set of API-06 section 6 and writes the file."""
    assert_clean(blob)
    expected = {"schemaVersion", "generatedAtMs", "baseline", "runs"}
    extra = set(blob) - expected
    if extra:
        raise AssertionError(
            f"ACD-ART-001: ablations.json has fields not defined by API-06 section 6: {sorted(extra)}"
        )
    if set(blob["baseline"]) != {"id", "top1", "n"}:
        raise AssertionError("ACD-ART-001: baseline must be exactly {id, top1, n}")
    if len(blob["runs"]) != CONFIG.domain.ablation_run_count:
        raise AssertionError(
            f"ACD-ART-005: expected {CONFIG.domain.ablation_run_count} runs, "
            f"got {len(blob['runs'])}"
        )
    combos = {run["toggle"] for run in blob["runs"]}
    if combos != {TOGGLES[c] for c in FACTOR_COMBINATIONS if c != (False, False)}:
        raise AssertionError(f"ACD-ART-005: toggle set {sorted(combos)} does not cover the 2x2")
    for run in blob["runs"]:
        missing = {"id", "name", "toggle", "top1", "n", "macroF1",
                   "deltaVsBaseline", "note"} - set(run)
        if missing:
            raise AssertionError(f"ACD-ART-001: run {run.get('id')} is missing {sorted(missing)}")
    path = Path(out_path) if out_path else paths.artifacts / "ablations.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(blob, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=None, help="ablations.json path")
    ap.add_argument("--epochs", type=int, default=2, help="identical budget for all four runs")
    ap.add_argument("--limit", type=int, default=600, help="identical row cap for all four runs")
    ap.add_argument("--seed", type=int, default=CONFIG.domain.split_seed)
    ap.add_argument("--device", choices=["auto", "cpu", "gpu"], default="auto")
    ap.add_argument("--no-reuse", action="store_true", help="retrain every combination")
    ap.add_argument("--summary-only", action="store_true",
                    help="do not train; just rebuild the metrics.json summary from the table")
    args = ap.parse_args(argv)

    if args.summary_only:
        path = Path(args.out) if args.out else paths.artifacts / "ablations.json"
        print(json.dumps(merge_summary(path), indent=2, ensure_ascii=False))
        return 0

    print("=" * 78)
    print("T-06 ablation: 2x2 factorial (denoise x augment), primary metric = E2 test_mobile top1")
    print(f"  budget: epochs={args.epochs} limit={args.limit} seed={args.seed} (identical for all 4)")
    print("=" * 78)
    blob = run_ablations(epochs=args.epochs, limit=args.limit, seed=args.seed,
                         device=args.device, reuse=not args.no_reuse)
    path = write_ablations(blob, Path(args.out) if args.out else None)

    print()
    print(f"  baseline            top1={blob['baseline']['top1']:.4f} n={blob['baseline']['n']}")
    for run in blob["runs"]:
        print(f"  {run['id']:20s} top1={run['top1']:.4f} n={run['n']} "
              f"macroF1={run['macroF1']:.4f} delta={run['deltaVsBaseline']:+.4f}")
    print(f"\n  wrote {path}")
    print("  deltas are measured differences, not expected improvements (SPEC-T-06 section 4)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

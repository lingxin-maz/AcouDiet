"""A small linear model, kept as a **gate**: is a model's output actually a function of its input?

Why a model is the right tool here, and why it belongs in the toolchain rather than the App
------------------------------------------------------------------------------------------
ADR-40 measured the shipped recogniser and found it barely depends on its input: it predicted
3 of 6 classes, no finite temperature minimised its NLL, and buying 90 % conformal coverage cost
a prediction set of 5.76 of 6 classes. That was found with an ad-hoc logistic regression fitted
on the corpus -- a *small model*, used to answer a question the aggregate metrics could not:
"is the corpus learnable at all, and does the artifact respond to it?"

That is the genuinely useful role for a small auxiliary model in this project. It is not a
replacement recogniser and it does not go in the APK:

  * the six-class taxonomy is the model team's own (FF-19, ADR-19), so no off-the-shelf model
    predicts it;
  * the one audio model that fits FF-16 and is reachable from this machine (YAMNet, 4,126,810 B,
    Apache-2.0) takes a **raw waveform** `[15600]`, while FF-11/FF-14 freeze the model input as a
    `[1,128,128,1]` mel tensor from the Kotlin front end. Putting it in the App would retire that
    front end and void T-08b -- one of the five deliverables section 6 marks as uncuttable;
  * and an auxiliary head cannot rescue a primary whose output is already input-independent.

So this file is a **gate**, in the toolchain, where a small model costs nothing and buys the one
thing the project keeps needing: a check that can fail.

Two detectors, each with the control that lets it fail
-----------------------------------------------------
1. `degeneracy(...)` -- given per-clip probability vectors, is the output independent of the
   input? Reports the distinct predicted classes, the spread of the per-clip max probability, and
   the fraction of clips whose prediction changes when the input does.
2. `separability(...)` -- fit the small linear model on features+labels and report cross-validated
   accuracy. This is the *control* for every "the model is broken" claim: if simple features
   cannot separate the corpus either, the corpus is the problem, not the model.

`--selftest` runs both against data whose answer is known, in both directions, and needs no model
and no corpus -- which is what makes it usable in CI.

Usage::

    python ai/scripts/model_sanity.py --selftest
    python ai/scripts/model_sanity.py --predictions ai/artifacts/shipped_predictions.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

EPS = 1e-12


# --------------------------------------------------------------------------- small model

def separability(features: np.ndarray, labels: np.ndarray, folds: int = 5,
                 seed: int = 20260915) -> float:
    """Cross-validated accuracy of a plain linear classifier.

    Deliberately the least powerful model that can still answer the question. If a *linear* read
    out separates the classes, then no amount of "the task is hard" explains a trained network
    scoring at chance -- which is exactly the conclusion ADR-40 needed and could not get from
    accuracy numbers alone.
    """
    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import StratifiedKFold, cross_val_score
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    X = np.asarray(features, dtype=np.float64)
    y = np.asarray(labels, dtype=np.int64)
    if X.ndim != 2:
        raise ValueError("features must be a 2-D matrix")
    if len(np.unique(y)) < 2:
        raise ValueError("need at least two classes to measure separability")
    clf = make_pipeline(StandardScaler(), LogisticRegression(max_iter=4000))
    cv = StratifiedKFold(n_splits=folds, shuffle=True, random_state=seed)
    return float(cross_val_score(clf, X, y, cv=cv, scoring="accuracy").mean())


# --------------------------------------------------------------------------- detector

def degeneracy(probs: np.ndarray, change_eps: float = 1e-3) -> dict:
    """How much does the prediction depend on the input?

    `probs` is `(n_clips, n_classes)`. The three numbers are chosen so that a model which always
    answers the same thing is named, not inferred:

    * `distinctClasses` -- 1 means a constant predictor;
    * `pmaxStd` -- the standard deviation of the per-clip maximum probability. Exactly 0 means the
      output vector is identical for every clip, i.e. the model is a constant function;
    * `argmaxFlipFraction` -- the share of clips whose prediction differs from the *previous*
      clip's. This is the one that catches a model that is not constant but still ignores the
      input's class: a predictor that follows the input should flip rarely within a sorted run,
      a predictor that is noise flips about `1 - 1/n_classes` of the time.
    """
    P = np.asarray(probs, dtype=np.float64)
    if P.ndim != 2:
        raise ValueError("probs must be (n_clips, n_classes)")
    if len(P) == 0:
        raise ValueError("no clips to inspect")
    pred = P.argmax(axis=1)
    pmax = P.max(axis=1)
    flips = float(np.mean(pred[1:] != pred[:-1])) if len(P) > 1 else 0.0
    return {
        "n": int(len(P)),
        "nClasses": int(P.shape[1]),
        "distinctClasses": int(len(np.unique(pred))),
        "pmaxStd": float(pmax.std()),
        "pmaxMin": float(pmax.min()),
        "pmaxMax": float(pmax.max()),
        "argmaxFlipFraction": flips,
        "constant": bool(float(pmax.std()) < change_eps and len(np.unique(pred)) == 1),
    }


def verdict(deg: dict) -> tuple[bool, str]:
    """`(ok, why)`. `ok` is False when the artifact cannot support a meaningful confidence.

    ⚠️ The unreachable-class rule is deliberately strict, and the first version of it was too
    lenient: it allowed up to `nClasses // 2` classes to go unpredicted, so the SHIPPED model --
    which predicts exactly 3 of 6 on 468 balanced clips -- came back PASS. It should not. A class
    the artifact never emits is a class the App can never report, and on a balanced sample of a few
    hundred clips "never" is not a sampling accident. Any unreachable class fails.
    """
    if deg["constant"]:
        return False, (f"constant predictor: {deg['distinctClasses']}/{deg['nClasses']} classes "
                       f"ever predicted, per-clip max-probability std {deg['pmaxStd']:.6f}")
    unreachable = deg["nClasses"] - deg["distinctClasses"]
    if unreachable > 0:
        return False, (f"{unreachable} of {deg['nClasses']} classes were never predicted on this "
                       f"sample -- the App can never report them from this artifact "
                       f"(predicted {deg['distinctClasses']}/{deg['nClasses']})")
    return True, (f"output varies and every class is reachable: "
                  f"{deg['distinctClasses']}/{deg['nClasses']} classes, "
                  f"pmax std {deg['pmaxStd']:.6f}, argmax flips {deg['argmaxFlipFraction']:.3f}")


# --------------------------------------------------------------------------- self-test

def selftest() -> int:
    rng = np.random.default_rng(20260915)
    fails: list[str] = []
    print("=" * 78)
    print("model_sanity -- self-test (no model, no corpus)")
    print("=" * 78)

    n, k = 600, 6

    # --- detector, positive direction: a constant predictor must be caught -------------------
    const = np.tile(np.array([0.56, 0.09, 0.09, 0.09, 0.09, 0.08]), (n, 1))
    d_const = degeneracy(const)
    ok, why = verdict(d_const)
    print(f"  [constant predictor] distinct={d_const['distinctClasses']} "
          f"pmaxStd={d_const['pmaxStd']:.6f} -> ok={ok}")
    if ok or not d_const["constant"]:
        fails.append("a constant predictor was NOT flagged")

    # --- detector, negative direction: an input-dependent model must NOT be flagged ----------
    z = rng.normal(0, 1, size=(n, k))
    z[np.arange(n), rng.integers(0, k, n)] += 3.0
    healthy = np.exp(z) / np.exp(z).sum(axis=1, keepdims=True)
    d_ok = degeneracy(healthy)
    ok2, why2 = verdict(d_ok)
    print(f"  [varying predictor]  distinct={d_ok['distinctClasses']} "
          f"pmaxStd={d_ok['pmaxStd']:.6f} -> ok={ok2}")
    if not ok2:
        fails.append(f"an input-dependent model was wrongly flagged: {why2}")

    # --- detector, third direction: a collapsed (not constant) model must be caught ----------
    collapse = rng.normal(0, 0.01, size=(n, k))
    collapse[:, 1] += 2.0                       # always class 1, small jitter
    d_col = degeneracy(collapse)
    ok3, _ = verdict(d_col)
    print(f"  [collapsed model]    distinct={d_col['distinctClasses']} "
          f"pmaxStd={d_col['pmaxStd']:.6f} -> ok={ok3}")
    if ok3:
        fails.append("a model that predicts only one class was NOT flagged")

    # --- small model, both directions -------------------------------------------------------
    X = rng.normal(0, 1, size=(300, 24))
    y = rng.integers(0, k, 300)
    X[ np.arange(300), y % 24 ] += 4.0          # a genuinely separable corpus
    acc_sep = separability(X, y)
    acc_rand = separability(rng.normal(0, 1, size=(300, 24)), y)
    print(f"  [separability] separable corpus acc={acc_sep:.4f}   "
          f"noise-only acc={acc_rand:.4f}   (chance {1/k:.4f})")
    if acc_sep < 0.95:
        fails.append(f"the linear read-out failed on a separable corpus ({acc_sep:.4f})")
    if acc_rand > 0.45:
        fails.append(f"the linear read-out scored {acc_rand:.4f} on noise -- it is fitting noise")

    if fails:
        print("\nSELFTEST FAILED")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("\nRESULT: both detectors discriminate, in both directions")
    return 0


# --------------------------------------------------------------------------- real run

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--predictions", help="JSONL from tool/evaluate_shipped_model.py --predictions")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.predictions:
        print("ACD-ART-001: pass --predictions or --selftest", file=sys.stderr)
        return 2

    path = Path(args.predictions)
    if not path.exists():
        print(f"ACD-ART-001: no such file: {path}", file=sys.stderr)
        return 2
    by_split: dict[str, list[list[float]]] = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        by_split.setdefault(row["split"], []).append(row["probs"])

    worst = True
    print("=" * 78)
    print("model_sanity -- is the artifact's output a function of its input?")
    print("=" * 78)
    for split, probs in sorted(by_split.items()):
        d = degeneracy(np.asarray(probs))
        ok, why = verdict(d)
        worst = worst and ok
        print(f"  {split:<14} n={d['n']:<5} {'[ok  ]' if ok else '[FAIL]'} {why}")
    print(f"\nRESULT: {'PASS' if worst else 'FAIL'}")
    return 0 if worst else 1


if __name__ == "__main__":
    raise SystemExit(main())

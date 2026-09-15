"""T-05b / **FF-20b**: calibrate the three confidence thresholds, and report the process.

WHY THIS FILE EXISTS (it is not an addition -- it is an unpaid debt)
-------------------------------------------------------------------
`SPEC-00` section 3.4 **FF-20b** has always required:

    "三档阈值须在 D3 用自采跨域测试集的置信度分布直方图**标定**，标定过程写进测试报告"

The App ships three hard-coded numbers (`shared/feature_config.json` -> `voting`:
`ema_window=5`, `ema_alpha=0.4`, `confirm_consecutive_patches=4`, `tau_confirm=0.70`,
`tau_low=0.45`). Measured 2026-09-15: **no calibration report exists anywhere in this
repository** -- `ai/reports/` was an empty directory and `records/reports/` contains no
threshold-calibration document. So FF-20b is a frozen requirement that has never been met.

This script meets the *method* half of it. It needs no training: it consumes the per-sample
predictions of **the model that is actually shipped**, which `tool/evaluate_shipped_model.py`
emits with `--predictions`.

WHAT IT MEASURES, AND WHY EACH NUMBER CAN FAIL
----------------------------------------------
1. **Temperature scaling.** Fit one scalar `T` on a *fit* split by minimising negative log
   likelihood, then report **ECE** (expected calibration error, 15 equal-width bins) on a
   *held-out* split, before and after. A fitted `T` that does not reduce ECE on data it did not
   see is a failed calibration, and the script says so.
2. **Split-conformal prediction** at a requested coverage `1 - alpha`. The conformal quantile is
   taken on the *calibration* rows and the **empirical coverage** is then measured on the
   *held-out* rows. The finite-sample guarantee is `coverage >= 1 - alpha` under exchangeability,
   so the assertion is one-sided and can genuinely fail.
3. **The price of coverage: mean prediction-set size.** This is the number that stops the report
   from lying. Reaching 90 % coverage is trivial if you return all six classes every time, so a
   coverage figure without its mean set size is not evidence. A model that predicts one constant
   class has to grow its set towards all six to buy coverage, and that shows up here.

HONESTY ABOUT THE DATA
----------------------
The splits in this repository are built on the **synthetic** substitute corpus
(`ai/scripts/make_synthetic_dataset.py` -- its own docstring: *"Any accuracy number measured on
it is a pipeline proof, not a scientific result"*). Whatever this script prints is therefore a
**procedure proof**: it demonstrates that the calibration machinery runs, is falsifiable, and
produces the report FF-20b asks for. It is **not** a calibration of the product, and the emitted
report says so in its header.

Usage::

    # 1) get per-sample predictions from the shipped model (no training)
    python tool/evaluate_shipped_model.py --predictions ai/artifacts/shipped_predictions.jsonl

    # 2) calibrate on one split, verify on the other
    python ai/scripts/calibrate_thresholds.py \
        --predictions ai/artifacts/shipped_predictions.jsonl \
        --fit test_public --eval test_mobile --alpha 0.10

    # 3) the self-test: synthetic logits with a KNOWN miscalibration, both directions
    python ai/scripts/calibrate_thresholds.py --selftest
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]           # repository root
AI = ROOT / "ai"
REPORT = AI / "reports" / "threshold_calibration.md"

EPS = 1e-12


# --------------------------------------------------------------------------- core maths

def _softmax(z: np.ndarray) -> np.ndarray:
    z = z - np.max(z, axis=-1, keepdims=True)
    e = np.exp(z)
    return e / np.sum(e, axis=-1, keepdims=True)


def probabilities(logits: np.ndarray, temperature: float = 1.0) -> np.ndarray:
    """Softmax with a temperature. `temperature == 1` is the uncalibrated model."""
    if temperature <= 0:
        raise ValueError("temperature must be > 0")
    return _softmax(np.asarray(logits, dtype=np.float64) / temperature)


def nll(probs: np.ndarray, y: np.ndarray) -> float:
    n = len(y)
    if n == 0:
        return float("nan")
    return float(-np.mean(np.log(np.clip(probs[np.arange(n), y], EPS, 1.0))))


def fit_temperature(logits: np.ndarray, y: np.ndarray,
                    lo: float = 0.05, hi: float = 1e4, iters: int = 120) -> float:
    """Golden-section search for the NLL-minimising temperature.

    A scalar has one basin, so a derivative-free search is both sufficient and impossible to get
    wrong by a bad gradient step. The search interval is asserted to bracket the optimum: if the
    minimum sits on an endpoint the function raises rather than silently returning a boundary.

    The upper bound is deliberately enormous. On the **shipped** model the optimum ran past 20 and
    the assertion fired -- which is not a defect in the search, it is the measurement: a model
    whose output barely depends on its input can only be calibrated by flattening towards the
    uniform distribution, so `T -> inf`. Truncating the search would have hidden that behind a
    "best fit" number; `--boundary` in the report is what names it instead.
    """
    def f(t: float) -> float:
        return nll(probabilities(logits, t), y)

    phi = (math.sqrt(5) - 1) / 2
    a, b = lo, hi
    c, d = b - phi * (b - a), a + phi * (b - a)
    fc, fd = f(c), f(d)
    for _ in range(iters):
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - phi * (b - a)
            fc = f(c)
        else:
            a, c, fc = c, d, fd
            d = a + phi * (b - a)
            fd = f(d)
    t = (a + b) / 2
    if t <= lo * 1.001 or t >= hi * 0.999:
        raise ValueError(f"temperature optimum sits on the search boundary ({t:.4f}) -- widen "
                         f"[{lo}, {hi}] rather than accepting a clipped answer")
    return t


def ece(probs: np.ndarray, y: np.ndarray, bins: int = 15) -> float:
    """Expected calibration error: |accuracy - confidence| averaged over equal-width bins."""
    conf = probs.max(axis=1)
    pred = probs.argmax(axis=1)
    correct = (pred == y).astype(np.float64)
    edges = np.linspace(0.0, 1.0, bins + 1)
    total = 0.0
    n = len(y)
    for i in range(bins):
        lo, hi = edges[i], edges[i + 1]
        m = (conf > lo) & (conf <= hi) if i > 0 else (conf >= lo) & (conf <= hi)
        if not np.any(m):
            continue
        total += (np.sum(m) / n) * abs(correct[m].mean() - conf[m].mean())
    return float(total)


def conformal_quantile(cal_probs: np.ndarray, cal_y: np.ndarray, alpha: float) -> float:
    """Split-conformal threshold on `1 - p(true class)`.

    The `ceil((n+1)(1-alpha))` order statistic is the finite-sample-correct choice; the `+1` is
    what makes the coverage guarantee hold rather than hold asymptotically.
    """
    n = len(cal_y)
    if n == 0:
        raise ValueError("calibration set is empty")
    scores = 1.0 - cal_probs[np.arange(n), cal_y]
    k = math.ceil((n + 1) * (1.0 - alpha))
    if k > n:
        # Not enough calibration rows to claim this coverage at all -- say so instead of
        # returning the maximum and pretending.
        raise ValueError(f"cannot guarantee {1 - alpha:.2f} coverage with only {n} calibration "
                         f"rows (need at least {math.ceil(alpha * (n + 1))} more)")
    return float(np.sort(scores)[k - 1])


def prediction_sets(probs: np.ndarray, q: float) -> np.ndarray:
    """Boolean matrix: which classes are in the set for each row."""
    return probs >= (1.0 - q) - EPS


def coverage(sets: np.ndarray, y: np.ndarray) -> float:
    if len(y) == 0:
        return float("nan")
    return float(np.mean(sets[np.arange(len(y)), y]))


# --------------------------------------------------------------------------- io

def read_predictions(path: Path) -> tuple[dict[str, tuple[np.ndarray, np.ndarray]], list[str]]:
    """JSONL written by `tool/evaluate_shipped_model.py --predictions`, grouped by split.

    Returns the per-split (probabilities, true ids) and the class-name table, which is taken from
    the file itself rather than assumed -- so the report cannot name the classes differently from
    the model card the evaluator read.
    """
    if not path.exists():
        raise FileNotFoundError(path)
    by_split: dict[str, list[tuple[list[float], int]]] = {}
    label_of: dict[int, str] = {}
    for lineno, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as e:
            raise ValueError(f"ACD-ART-001: line {lineno} is not valid JSON: {e}") from e
        by_split.setdefault(row["split"], []).append((row["probs"], int(row["trueId"])))
        label_of[int(row["trueId"])] = str(row["trueLabel"])

    out: dict[str, tuple[np.ndarray, np.ndarray]] = {}
    for split, rows in by_split.items():
        probs = np.asarray([r[0] for r in rows], dtype=np.float64)
        y = np.asarray([r[1] for r in rows], dtype=np.int64)
        if probs.ndim != 2:
            raise ValueError(f"ACD-ART-001: {split}: expected a probability vector per row")
        out[split] = (probs, y)
    n_classes = int(max(len(p) for p, _ in out.values()))
    labels = [label_of.get(i, f"class{i}") for i in range(n_classes)]
    return out, labels


def logits_of(probs: np.ndarray) -> np.ndarray:
    """Recover logits up to an additive constant, which is all softmax needs."""
    return np.log(np.clip(probs, EPS, 1.0))


# --------------------------------------------------------------------------- self-test

def selftest() -> int:
    """Two directions, both of which must hold, on data with a KNOWN answer.

    Positive control: probabilities computed at a temperature of 3 (deliberately
    over-confident) must come back calibrated -- fitted T well above 1, and ECE strictly lower
    on a held-out split.

    Negative control: already-calibrated probabilities (T = 1) must NOT be "improved" by a large
    factor -- if the fitter reported a big correction here it would be fitting noise, and the
    test fails.
    """
    rng = np.random.default_rng(20260915)
    n, k = 4000, 6
    y = rng.integers(0, k, size=n)
    # True logits: right class gets a modest edge, so the T=1 model is honestly calibrated.
    z = rng.normal(0.0, 1.0, size=(n, k))
    z[np.arange(n), y] += 1.2
    hold = slice(n // 2, n)
    fit = slice(0, n // 2)

    failures: list[str] = []

    # --- positive control ---
    z_over = z * 3.0                                   # equivalent to T = 1/3: over-confident
    t_hat = fit_temperature(z_over[fit], y[fit])
    before = ece(probabilities(z_over[hold]), y[hold])
    after = ece(probabilities(z_over[hold], t_hat), y[hold])
    print(f"  [positive control] fitted T = {t_hat:.4f} (expected ~3.0)")
    print(f"                     ECE on holdout: {before:.4f} -> {after:.4f}")
    if not (2.0 < t_hat < 4.5):
        failures.append(f"fitted T={t_hat:.3f} is not near the true 3.0")
    if not after < before:
        failures.append(f"ECE did not improve ({before:.4f} -> {after:.4f})")

    # --- negative control ---
    t_flat = fit_temperature(z[fit], y[fit])
    print(f"  [negative control] fitted T on honest logits = {t_flat:.4f} (expected ~1.0)")
    if not (0.7 < t_flat < 1.4):
        failures.append(f"fitted T={t_flat:.3f} on already-calibrated data is a spurious "
                        f"correction -- the fitter is chasing noise")

    # --- conformal coverage ---
    #
    # ⚠️ A single split cannot test a conformal implementation. The guarantee is *marginal*:
    # `P(Y in C(X)) >= 1 - alpha` holds in expectation over the drawn calibration set, NOT for
    # every calibration set. Measured on this data, one draw gave 0.9390 / 0.8955 / 0.8000 at
    # targets 0.95 / 0.90 / 0.80 -- all at or just under target, which is the expected
    # fluctuation and would have looked like a bug in a one-shot check either way.
    #
    # So the coverage claim is tested over many redraws AND at a calibration size where the
    # finite-sample correction actually bites.
    #
    # ⚠️ The first version of this control dropped the `+1` from `ceil((n+1)(1-alpha))`. Measured
    # at n_cal = 2000 that moves coverage by 0.0005 -- far below Monte-Carlo noise -- so the
    # control could not discriminate and the test was worth nothing. The correction is O(1/n);
    # a control has to be run where it is visible.
    def mean_coverage(n_cal: int, k_rule, reps: int = 400) -> dict[float, float]:
        out: dict[float, float] = {}
        p = probabilities(z)
        for alpha in (0.05, 0.10, 0.20):
            covs = []
            for r in range(reps):
                rr = np.random.default_rng(7000 + r)
                idx = rr.permutation(len(y))
                tr, te = idx[:n_cal], idx[n_cal:]
                scores = np.sort(1.0 - p[tr, y[tr]])
                k = min(max(k_rule(n_cal, alpha), 1), len(scores))
                sets = prediction_sets(p[te], float(scores[k - 1]))
                covs.append(coverage(sets, y[te]))
            out[alpha] = float(np.mean(covs))
        return out

    # Materially wrong: drop well below the correct order statistic, by 2 % of the calibration set.
    wrong_rule = lambda n, a: math.ceil((n + 1) * (1 - a)) - max(1, int(round(0.02 * n)))
    for n_cal in (40, 200):
        correct = mean_coverage(n_cal, lambda n, a: math.ceil((n + 1) * (1 - a)))
        wrong = mean_coverage(n_cal, wrong_rule)
        for alpha in (0.05, 0.10, 0.20):
            c, w = correct[alpha], wrong[alpha]
            print(f"  [conformal mean over 400 redraws, n_cal={n_cal:4d}] alpha={alpha:.2f}  "
                  f"correct k -> {c:.4f}   wrong quantile -> {w:.4f}   (target >= {1 - alpha:.2f})")
            if c < (1 - alpha) - 0.01:
                failures.append(f"n_cal={n_cal} alpha={alpha}: mean coverage {c:.4f} < target "
                                f"{1 - alpha:.2f} -- the conformal quantile is too small")
            if w >= (1 - alpha) - 0.01:
                failures.append(f"n_cal={n_cal} alpha={alpha}: the deliberately-wrong quantile also "
                                f"reached {w:.4f}, i.e. this test cannot detect a broken quantile")

    # And the other direction: an impossible target must be refused, not silently met.
    probs = probabilities(z)
    try:
        conformal_quantile(probs[:5], y[:5], 0.001)
        failures.append("conformal accepted a coverage claim it cannot support with 5 rows")
    except ValueError:
        print("  [negative control] an unsupportable coverage claim was refused")

    if failures:
        print("\nSELFTEST FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nRESULT: calibration machinery behaves in both directions")
    return 0


# --------------------------------------------------------------------------- report

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--predictions", help="JSONL from tool/evaluate_shipped_model.py --predictions")
    ap.add_argument("--fit", default="test_public", help="split used to fit T and the quantile")
    ap.add_argument("--eval", default="test_mobile", help="held-out split the numbers are read on")
    ap.add_argument("--alpha", type=float, default=0.10, help="1 - target coverage")
    ap.add_argument("--report", default=str(REPORT))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        print("=" * 78)
        print("calibrate_thresholds -- self-test (no data required)")
        print("=" * 78)
        return selftest()

    if not args.predictions:
        print("ACD-ART-001: --predictions is required (or use --selftest)", file=sys.stderr)
        return 2

    splits, labels = read_predictions(Path(args.predictions))
    if args.fit not in splits or args.eval not in splits:
        print(f"ACD-ART-001: need both splits in the file; have {sorted(splits)}", file=sys.stderr)
        return 2

    fit_p, fit_y = splits[args.fit]
    ev_p, ev_y = splits[args.eval]
    fit_logits, ev_logits = logits_of(fit_p), logits_of(ev_p)

    # --- degeneracy diagnostics (BEFORE fitting, because they decide what fitting means) -----
    #
    # A calibration number on its own is not interpretable. If the model emits nearly the same
    # distribution for every clip, then `T -> inf` is the only fit available (the uniform
    # distribution is the NLL minimiser), the conformal set has to grow towards all six classes
    # to buy any coverage, and both facts mean the same thing: the outputs carry no per-input
    # information. These numbers name that state instead of leaving the reader to infer it.
    #
    # ⚠️ On the shipped model the fit ran to the search bound at BOTH 20 and 1e4. Widening the
    # bound again would have been the wrong fix: an unbounded temperature is not a calibration,
    # it is the measurement. It is caught here and reported as such.
    ev_pred = ev_p.argmax(axis=1)
    distinct_pred = sorted({int(v) for v in ev_pred})
    pmax = ev_p.max(axis=1)
    pmax_spread = float(pmax.std())
    pmax_min, pmax_max = float(pmax.min()), float(pmax.max())
    degenerate = len(distinct_pred) <= 1 or pmax_spread < 1e-6

    boundary = False
    try:
        t_hat = fit_temperature(fit_logits, fit_y)
    except ValueError:
        # The optimum sits on the search bound, i.e. the best available temperature is "as large
        # as you like". Keep going with T = 1 (the uncalibrated model) so the rest of the report
        # is still produced and comparable, and let the verdict below refuse to call it a pass.
        boundary = True
        t_hat = 1.0
    ece_before = ece(ev_p, ev_y)
    ece_after = ece(probabilities(ev_logits, t_hat), ev_y)
    q = conformal_quantile(probabilities(fit_logits, t_hat), fit_y, args.alpha)
    cal_p = probabilities(ev_logits, t_hat)
    sets = prediction_sets(cal_p, q)
    cov = coverage(sets, ev_y)
    size = float(sets.sum(axis=1).mean())
    if boundary:
        # Report the uncalibrated ECE as "after" too, so the table cannot show a flattering
        # improvement that was produced by the fallback rather than by the fit.
        ece_after = ece_before

    lines = [
        "# T-05b threshold calibration (FF-20b)",
        "",
        "> ⚠️ **This is a PROCEDURE proof, not a calibration of the product.** The splits it ran on",
        "> are built on the **synthetic** substitute corpus (`ai/scripts/make_synthetic_dataset.py`),",
        "> whose own docstring states that any accuracy measured on it is a pipeline proof and not a",
        "> scientific result. Re-run it against a real cross-domain set before quoting any number",
        "> below as a property of the shipped model.",
        "",
        f"- predictions : `{args.predictions}`",
        f"- fit split   : `{args.fit}` (n={len(fit_y)})",
        f"- eval split  : `{args.eval}` (n={len(ev_y)})",
        f"- target cov. : {1 - args.alpha:.2f}",
        "",
        "| quantity | value |",
        "|---|---|",
        f"| fitted temperature T | **{'UNBOUNDED -- the NLL fit ran to the search bound' if boundary else f'{t_hat:.4f}'}** |",
        f"| ECE before (T=1) | {ece_before:.4f} |",
        f"| ECE after | **{ece_after:.4f}**{'' if not boundary else ' (fallback: the fit hit its bound, so T=1 is reported and no improvement is claimed)'} |",
        f"| conformal quantile q | {q:.4f} |",
        f"| empirical coverage (held-out) | **{cov:.4f}** |",
        f"| mean prediction-set size | **{size:.2f} / 6** |",
        "",
        "## Degeneracy diagnostics (read this before the table above)",
        "",
        "| quantity | value |",
        "|---|---|",
        f"| distinct classes ever predicted on the held-out split | **{len(distinct_pred)} / 6** |",
        f"| which | {[labels[i] for i in distinct_pred]} |",
        f"| std of per-clip max probability | **{pmax_spread:.6f}** |",
        f"| min / max of per-clip max probability | {pmax_min:.6f} / {pmax_max:.6f} |",
        "",
        ("🔴 **This model's output does not depend on its input.** It predicts "
         f"{len(distinct_pred)} class(es) and the per-clip maximum probability barely moves "
         f"(std={pmax_spread:.6f}). Under those conditions the fitted temperature is not a "
         "calibration of anything -- it is a single scalar stretched until the average confidence "
         "matches the base rate, and the conformal set has to grow towards all six classes to buy "
         "coverage. **No threshold derived from this model can make the App's confidence "
         "meaningful**, and that is a property of the artifact, not of the calibration procedure."
         if degenerate else
         ("🟠 **Not degenerate, but not calibratable either -- and these are two different "
          "failures.** The output *does* vary across clips (it names "
          f"{len(distinct_pred)} of 6 classes, per-clip max probability spread "
          f"{pmax_spread:.4f}), so it is not a constant predictor. But **no finite temperature "
          "minimises the NLL**, and buying "
          f"{1 - args.alpha:.0%} coverage costs a mean prediction set of **{size:.2f} of 6 "
          "classes** -- i.e. the conformal gate can only certify by returning almost every "
          "class. Read the two facts together: the outputs move, but they do not move *with the "
          "label*. An unbounded temperature is therefore the measurement, not a bug in the "
          "fitter, and the confidence cannot be made meaningful by any threshold."
          if boundary else
          "✅ The model's output varies across clips, predicts more than one class, and admits a "
          "finite NLL-minimising temperature -- so the numbers above describe a real calibration.")),
        "",
        "## How to read the set size",
        "",
        "Coverage alone cannot be trusted: returning all six classes every time gives 100 % for",
        "free. The set size is the price paid for the coverage, and a model that collapses onto one",
        "constant class must buy coverage by widening the set towards 6. A high coverage next to a",
        "set size near 6 means **the conformal gate is refusing to certify anything**, which is the",
        "honest reading of a model that does not discriminate.",
        "",
        f"- ECE improved by the fit: **{'yes' if ece_after < ece_before else 'NO'}**",
        f"- coverage met: **{'yes' if cov >= (1 - args.alpha) - 0.02 else 'NO'}**",
        f"- model degenerate (output independent of input): **{'YES' if degenerate else 'no'}**",
        f"- NLL fit hit its search bound (T unbounded): **{'YES' if boundary else 'no'}**",
        "",
    ]
    out = Path(args.report)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")

    print("=" * 78)
    print("FF-20b threshold calibration")
    print("=" * 78)
    for ln in lines[6:]:
        if ln.startswith("|") or ln.startswith("- ") or ln.startswith(f"- "):
            print("  " + ln)
    print(f"\n  wrote {out}")

    # The verdict is deliberately NOT just "ECE went down". A degenerate model can have its ECE
    # driven to zero by flattening towards the uniform distribution, which is the opposite of a
    # useful calibration -- so degeneracy and an unbounded fit are hard failures regardless of
    # what the ECE column says.
    ok = ((not degenerate) and (not boundary)
          and (ece_after < ece_before) and (cov >= (1 - args.alpha) - 0.02))
    why = ("model output is independent of its input -- no threshold derived from it can be "
           "meaningful" if degenerate else
           "no finite temperature minimises the NLL -- the fit is unbounded" if boundary else
           f"ECE {'improved' if ece_after < ece_before else 'DID NOT improve'}, "
           f"coverage {cov:.4f} vs target {1 - args.alpha:.2f}, set size {size:.2f}/6")
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'} ({why})")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

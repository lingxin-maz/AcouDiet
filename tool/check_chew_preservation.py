"""Does the time-domain gate damage the BEHAVIOUR metrics? (ADR-55)

THE QUESTION
------------
`ADR-54` left one open risk: the gate's envelope looked "peakier" than clean (`crestRatio` 3.55)
and correlated less with the clean envelope (`envCorr` 0.875 vs 0.968 for plain noise). Behaviour
analysis (chew count / eating duration / speed, `P-07`) reads the **envelope**, not the classifier,
so a gate that reshapes the envelope could break the chew count even while it helps recognition.

WHY `crestRatio` ALONE COULD NOT ANSWER IT
------------------------------------------
`crestRatio` = p99.5/median of the envelope. A gate's whole job is to pull the *quiet* part down,
which raises peak/median **by construction** -- even when the peaks are untouched. So a big
`crestRatio` is not evidence of damage, and `envCorr` punishes the deliberate level change in the
gaps. Neither metric speaks to whether the chewing RHYTHM survives.

WHAT THIS SCRIPT DOES INSTEAD
-----------------------------
Runs the **actual frozen chew criterion** (`FF-21b/c/d`, parameters read from the SSOT -- never
literals) over the envelope, and compares the chew count against the clean reference:

    CHEW_MIN_PEAK_DISTANCE_MS / CHEW_MAX_PEAK_WIDTH_MS / CHEW_ISOLATED_GAP_MS /
    CHEW_PEAK_THRESHOLD_K / SMOOTHING_WINDOW_MS / ENVELOPE_FRAME_MS / ENVELOPE_HOP_MS

Note the criterion's threshold is `mu + k*sigma` **of the envelope itself**, so it is invariant to a
constant gain and sensitive to a time-varying one. That is exactly why the gate has to be checked
here rather than with a level-based metric.

This is a faithful **replica** of `app/lib/domain/service/behavior_analyzer.dart` (the authoritative
implementation); it is labelled a replica because a Python copy can drift. Its job is to rank
clean / noisy / gated, not to replace the Dart suite.

    python tool/check_chew_preservation.py
    python tool/check_chew_preservation.py --per-class 4
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

import numpy as np  # noqa: E402
from src import denoise_td as G  # noqa: E402
from src import features  # noqa: E402
from src.config import CONFIG  # noqa: E402

N_PATCH = int(CONFIG.patch_samples)
NOISE_DIR = ROOT / "ai" / "data" / "noise"
MIX_SNR_DB = 10.0


def ssot_behavior() -> dict:
    d = json.loads((ROOT / "shared" / "feature_config.json").read_text(encoding="utf-8"))
    b = d["behavior"]
    return {
        "min_peak_distance_ms": b["chew_min_peak_distance_ms"],
        "max_peak_width_ms": b["chew_max_peak_width_ms"],
        "isolated_gap_ms": b["chew_isolated_gap_ms"],
        "peak_k": b["chew_peak_threshold_k"],
        "smooth_ms": b["smoothing_window_ms"],
        "frame_ms": b["envelope_frame_ms"],
        "hop_ms": b["envelope_hop_ms"],
        "length": b["envelope_length"],
    }


def envelope(x: np.ndarray, frame_ms: float, hop_ms: float, length: int,
             sample_rate: int = 16000) -> np.ndarray:
    """RMS envelope, `frame_ms` window every `hop_ms` (overlapping) -- FF-21's framing."""
    frame = max(1, int(round(sample_rate * frame_ms / 1000.0)))
    hop = max(1, int(round(sample_rate * hop_ms / 1000.0)))
    if len(x) < frame:
        x = np.pad(x, (0, frame - len(x)))
    n = min(length, 1 + (len(x) - frame) // hop)
    out = np.empty(n, dtype=np.float64)
    for i in range(n):
        seg = x[i * hop:i * hop + frame]
        out[i] = float(np.sqrt(np.mean(seg.astype(np.float64) ** 2) + 1e-20))
    return out


def _smooth(v: np.ndarray, window: int) -> np.ndarray:
    if window <= 1:
        return v
    k = np.ones(window) / window
    return np.convolve(v, k, mode="same")


def chew_count(env: np.ndarray, b: dict) -> int:
    """Replica of `BehaviorAnalyzer`: threshold, maxima, width filter, isolation guard, spacing."""
    hop = b["hop_ms"]
    smooth_win = max(1, int(round(b["smooth_ms"] / hop)))
    sm = _smooth(env, smooth_win)
    mu, sigma = float(np.mean(sm)), float(np.std(sm))
    thr = mu + b["peak_k"] * sigma

    idx = [i for i in range(1, len(sm) - 1)
           if sm[i] > thr and sm[i] >= sm[i - 1] and sm[i] > sm[i + 1]]

    # 4a. wide peaks are not chews
    max_w = max(1, int(round(b["max_peak_width_ms"] / hop)))
    kept = []
    for i in idx:
        left = i
        while left > 0 and sm[left - 1] > thr:
            left -= 1
        right = i
        while right < len(sm) - 1 and sm[right + 1] > thr:
            right += 1
        if right - left + 1 <= max_w:
            kept.append(i)

    # 4b. lone-spike guard: >= 3 peaks is a train; with 1-2 apply the 300 ms neighbourhood test
    if 0 < len(kept) < 3:
        gap = max(1, int(round(b["isolated_gap_ms"] / hop)))
        kept = [i for i in kept if any(j != i and abs(j - i) <= gap for j in kept)]

    # 5. minimum peak distance: keep the stronger of a too-close pair
    min_d = max(1, int(round(b["min_peak_distance_ms"] / hop)))
    out: list[int] = []
    for i in kept:
        if out and i - out[-1] < min_d:
            if sm[i] > sm[out[-1]]:
                out[-1] = i
            continue
        out.append(i)
    return len(out)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-class", type=int, default=3)
    ap.add_argument("--out", default=str(ROOT / "ai" / "reports" / "chew_preservation.md"))
    args = ap.parse_args(argv[1:])

    b = ssot_behavior()
    noise = [n[:N_PATCH] for n in
             (features.read_pcm16(p).astype(np.float32) / 32768.0
              for p in sorted(NOISE_DIR.glob("*.wav")))
             if len(n) >= N_PATCH]
    by_label: dict[str, list] = {}
    with (ROOT / "ai" / "data" / "splits" / "test_mobile.csv").open(encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            by_label.setdefault(r["label"], []).append(r)
    picks = [r for lab in sorted(by_label) for r in by_label[lab][:args.per_class]]

    tp = G.TdGateParams(max_attenuation_db=30.0, threshold_db=9.0, lookahead_frames=4,
                        release_ms=80.0, knee_db=6.0, noise_bias=1.5)

    # variants: the gate as chosen, and a candidate fix (slower attack + gentler knee)
    variants = {
        "noisy": lambda x: x,
        "gate_td": lambda x: G.gate(x, tp),
        "gate_td_slow": lambda x: G.gate(x, G.with_params(
            max_attenuation_db=30.0, threshold_db=9.0, lookahead_frames=4,
            release_ms=80.0, knee_db=6.0, noise_bias=1.5, attack_ms=10.0)),
    }

    per = {k: [] for k in ["clean"] + list(variants)}
    for i, row in enumerate(picks):
        p = ROOT / row["path"]
        if not p.exists():
            continue
        c = np.asarray(features.read_pcm16(p), dtype=np.float32) / 32768.0
        c = np.ascontiguousarray(c[:N_PATCH])
        if len(c) < N_PATCH:
            continue
        n = noise[i % len(noise)]
        noisy = np.ascontiguousarray(
            (c + n * (float(np.sqrt(np.mean(c.astype(np.float64) ** 2))) /
                      float(np.sqrt(np.mean(n.astype(np.float64) ** 2))) /
                      (10.0 ** (MIX_SNR_DB / 20.0)))).astype(np.float32))
        per["clean"].append(chew_count(envelope(c, b["frame_ms"], b["hop_ms"], b["length"]), b))
        for k, fn in variants.items():
            per[k].append(chew_count(
                envelope(fn(noisy), b["frame_ms"], b["hop_ms"], b["length"]), b))

    def mae(k):
        return float(np.mean([abs(a - c) for a, c in zip(per[k], per["clean"])]))

    def bias(k):
        return float(np.mean([a - c for a, c in zip(per[k], per["clean"])]))

    print("=" * 84)
    print("chew-count preservation (replica of the frozen FF-21b/c/d criterion)")
    print("=" * 84)
    print(f"  clips={len(per['clean'])}  mix={MIX_SNR_DB:g} dB  "
          f"params from SSOT: k={b['peak_k']} smooth={b['smooth_ms']}ms "
          f"minDist={b['min_peak_distance_ms']}ms maxWidth={b['max_peak_width_ms']}ms")
    print()
    print(f"  {'variant':<16} {'mean chew':>10} {'MAE vs clean':>13} {'bias':>8}")
    print("  " + "-" * 62)
    for k in ["clean"] + list(variants):
        mm = float(np.mean(per[k]))
        if k == "clean":
            print(f"  {k:<16} {mm:>10.2f} {'--':>13} {'--':>8}")
        else:
            print(f"  {k:<16} {mm:>10.2f} {mae(k):>13.2f} {bias(k):>8.2f}")

    base = mae("noisy")
    best = min((k for k in variants), key=mae)
    print()
    print(f"  plain noise already costs MAE {base:.2f} chews; the gate must not cost more.")
    print(f"  best variant: {best} with MAE {mae(best):.2f} "
          f"({'better than noise' if mae(best) < base else 'WORSE than noise -> fix required'})")

    lines = ["# Chew-count preservation under denoising (generated)\n",
             "Generated by `python tool/check_chew_preservation.py`. Do not hand-edit.\n",
             f"- clips: {len(per['clean'])}, mix SNR {MIX_SNR_DB:g} dB",
             f"- criterion: replica of `behavior_analyzer.dart` (FF-21b/c/d), "
             f"parameters read from `shared/feature_config.json`\n",
             "| variant | mean chew | MAE vs clean | bias |", "|---|---|---|---|"]
    for k in ["clean"] + list(variants):
        mm = float(np.mean(per[k]))
        if k == "clean":
            lines.append(f"| `{k}` | {mm:.2f} | -- | -- |")
        else:
            lines.append(f"| `{k}` | {mm:.2f} | {mae(k):.2f} | {bias(k):.2f} |")
    lines += ["", f"Plain noise already costs MAE **{base:.2f}** chews. "
                  f"Best variant: `{best}` at MAE **{mae(best):.2f}** "
                  f"({'better' if mae(best) < base else 'worse'} than noise).", ""]
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(lines), encoding="utf-8")
    print(f"\n  wrote {Path(args.out).relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

"""Parameter sweep for the TIME-DOMAIN transient-preserving gate (`ai/src/denoise_td.py`, ADR-54).

Same three metrics as `tool/sweep_denoise_params.py`, same PASS rule, so the two families are
directly comparable:

    * noise attenuation  -- dB removed from a NOISE-ONLY patch   (want: <= -6)
    * signal attenuation -- dB removed from a CLEAN patch        (want: >= -1)
    * SSNR (gain-matched, dB) on a 10 dB mix                     (want: >= noisy - 1)

No model in the loop, so a configuration costs milliseconds and the grid can be wide. Whatever wins
here is then put through `tool/measure_denoise.py` (which does run the shipped `.tflite`) before
anything is claimed about recognition.

    python tool/sweep_denoise_td.py
    python tool/sweep_denoise_td.py --top 20 --csv ai/reports/denoise_td_sweep.csv
"""

from __future__ import annotations

import argparse
import csv
import itertools
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

import numpy as np  # noqa: E402
from src import denoise_td as G  # noqa: E402
from src import features  # noqa: E402
from src.config import CONFIG  # noqa: E402

N_PATCH = int(CONFIG.patch_samples)
N_FFT, HOP = int(CONFIG.n_fft), int(CONFIG.hop_length)
NOISE_DIR = ROOT / "ai" / "data" / "noise"
MIX_SNR_DB = 10.0


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x, dtype=np.float64) ** 2) + 1e-20))


def att_db(out, src):
    return 20.0 * np.log10((rms(out) + 1e-20) / (rms(src) + 1e-20))


def gain_matched_ssnr(clean, test):
    a = np.asarray(clean, dtype=np.float32)
    b = np.asarray(test, dtype=np.float32)
    den = float(np.dot(b, b))
    if den <= 1e-20:
        return float("nan")
    b = (float(np.dot(b, a)) / den) * b
    vals = []
    for i in range(1 + (len(a) - N_FFT) // HOP):
        ca = a[i * HOP:i * HOP + N_FFT]
        e0 = float(np.sum(ca * ca))
        if e0 / N_FFT < 1e-4:
            continue
        e1 = float(np.sum((b[i * HOP:i * HOP + N_FFT] - ca) ** 2))
        vals.append(35.0 if e1 <= 1e-20 else
                    float(np.clip(10.0 * np.log10(e0 / e1), -10.0, 35.0)))
    return float(np.mean(vals)) if vals else float("nan")


def load_inputs(per_class: int):
    noise = [n[:N_PATCH] for n in
             (features.read_pcm16(p).astype(np.float32) / 32768.0
              for p in sorted(NOISE_DIR.glob("*.wav")))
             if len(n) >= N_PATCH]
    by_label: dict[str, list] = {}
    with (ROOT / "ai" / "data" / "splits" / "test_mobile.csv").open(encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            by_label.setdefault(r["label"], []).append(r)
    clean = []
    for lab in sorted(by_label):
        for r in by_label[lab][:per_class]:
            p = ROOT / r["path"]
            if not p.exists():
                continue
            c = np.asarray(features.read_pcm16(p), dtype=np.float32) / 32768.0
            c = np.ascontiguousarray(c[:N_PATCH])
            if len(c) >= N_PATCH:
                clean.append(c)
    rng = np.random.default_rng(7)
    noisy = []
    for i, c in enumerate(clean):
        n = noise[i % len(noise)]
        noisy.append(np.ascontiguousarray(
            (c + n * (rms(c) / rms(n) / (10.0 ** (MIX_SNR_DB / 20.0)))).astype(np.float32)))
    return noise, clean, noisy


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-class", type=int, default=2, help="clean clips per class (6 classes)")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--csv", default=None)
    args = ap.parse_args(argv[1:])

    noise, clean, noisy = load_inputs(args.per_class)
    if not clean or not noise:
        print("ACD-ART-001: no input audio available", file=sys.stderr)
        return 1
    base = float(np.mean([gain_matched_ssnr(c, x) for c, x in zip(clean, noisy)]))

    print("=" * 100)
    print("time-domain transient-preserving gate: parameter sweep  (no model in the loop)")
    print("=" * 100)
    print(f"  clips: clean={len(clean)} noisy={len(noisy)} noiseFiles={len(noise)}  "
          f"mix={MIX_SNR_DB:g} dB")
    print(f"  noisy baseline SSNR (gain-matched) = {base:.2f} dB")
    print()

    rows = []
    for att, thr, look, rel, knee, bias in itertools.product(
            [12.0, 18.0, 24.0, 30.0], [3.0, 6.0, 9.0, 12.0], [0, 2, 4],
            [20.0, 40.0, 80.0], [6.0, 12.0], [1.0, 1.2, 1.5]):
        p = G.TdGateParams(sample_rate=16000, max_attenuation_db=att, threshold_db=thr,
                           lookahead_frames=look, release_ms=rel, knee_db=knee, noise_bias=bias)
        n_att = float(np.mean([att_db(G.gate(n, p), n) for n in noise]))
        s_att = float(np.mean([att_db(G.gate(c, p), c) for c in clean]))
        ssnr = float(np.mean([gain_matched_ssnr(c, G.gate(x, p))
                              for c, x in zip(clean, noisy)]))
        ok = (n_att <= -6.0) and (s_att >= -1.0) and (ssnr >= base - 1.0)
        # rank: reward noise removal and signal retention, penalise SSNR loss
        score = (-n_att) + 3.0 * (s_att + 1.0) - 2.0 * max(0.0, base - ssnr)
        rows.append(dict(score=score, ok=ok, max_att=att, threshold=thr, lookahead=look,
                         release=rel, knee=knee, bias=bias, noise=n_att, signal=s_att,
                         ssnr=ssnr))

    rows.sort(key=lambda r: (not r["ok"], -r["score"]))
    passing = [r for r in rows if r["ok"]]
    print(f"  {'maxAtt':>7} {'thr':>5} {'look':>5} {'rel':>5} {'knee':>5} {'bias':>5} "
          f"{'noise dB':>9} {'signal dB':>10} {'SSNR dB':>8}  verdict")
    print("  " + "-" * 94)
    for r in rows[:args.top]:
        print(f"  {r['max_att']:>7} {r['threshold']:>5} {r['lookahead']:>5} {r['release']:>5} "
              f"{r['knee']:>5} {r['bias']:>5} {r['noise']:>9.2f} {r['signal']:>10.2f} "
              f"{r['ssnr']:>8.2f}  {'PASS' if r['ok'] else ''}")
    print()
    print(f"  configs swept         : {len(rows)}")
    print(f"  configs passing       : {len(passing)}")
    if passing:
        b = passing[0]
        print(f"  best passing          : max_att={b['max_att']} threshold={b['threshold']} "
              f"lookahead={b['lookahead']} release={b['release']} knee={b['knee']} bias={b['bias']}")
        print(f"                          noise={b['noise']:.2f} dB  signal={b['signal']:.2f} dB  "
              f"SSNR={b['ssnr']:.2f} dB (noisy {base:.2f})")
        print("  -> next: tool/measure_denoise.py must confirm this on the shipped model")
    else:
        print("  NO configuration passed. Report the frontier; do not enable the gate.")

    if args.csv:
        cp = Path(args.csv)
        cp.parent.mkdir(parents=True, exist_ok=True)
        with cp.open("w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print(f"  wrote {cp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

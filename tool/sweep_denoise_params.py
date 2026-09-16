"""Cheap parameter sweep for `ai/src/denoise.py` (ADR-53, tuning stage).

Uses NO model: only the two metrics that matter for the trade-off this feature has to balance, both
computed against a known reference because the noise is mixed here.

    * noise attenuation  -- dB the denoiser removes from a NOISE-ONLY patch (want: very negative)
    * signal attenuation -- dB it removes from a CLEAN patch          (want: ~0.00)
    * SSNR (gain-matched, dB) on noisy input                          (want: > the noisy baseline)

Keeping the model out of the loop is what makes a sweep affordable: each configuration costs a few
seconds instead of ~10 minutes.

    python tool/sweep_denoise_params.py
"""

from __future__ import annotations

import itertools
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "tool"))

import numpy as np  # noqa: E402
from src import denoise as D  # noqa: E402
from src import features  # noqa: E402
from src.config import CONFIG  # noqa: E402

N_FFT, HOP, N_PATCH = int(CONFIG.n_fft), int(CONFIG.hop_length), int(CONFIG.patch_samples)
NOISE_DIR = ROOT / "ai" / "data" / "noise"
CLIPS = 12  # per-class-stratified would be better; this is noise/signal only, order matters less


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x, dtype=np.float64) ** 2) + 1e-20))


def db(a, b):
    return 20.0 * np.log10((rms(a) + 1e-20) / (rms(b) + 1e-20))


def gain_matched_ssnr(clean, test):
    a = np.asarray(clean, dtype=np.float32)
    b = np.asarray(test, dtype=np.float32)
    den = float(np.dot(b, b))
    if den <= 1e-20:
        return float("nan")
    a_scaled = (float(np.dot(b, a)) / den) * b
    # frame-wise, skipping frames whose clean energy is negligible
    vals = []
    for i in range(1 + (len(a) - N_FFT) // HOP):
        ca = a[i * HOP:i * HOP + N_FFT]
        cb = a_scaled[i * HOP:i * HOP + N_FFT]
        e0 = float(np.sum(ca * ca))
        if e0 / N_FFT < 1e-4:
            continue
        e1 = float(np.sum((cb - ca) ** 2))
        vals.append(35.0 if e1 <= 1e-20 else float(np.clip(10.0 * np.log10(e0 / e1), -10, 35)))
    return float(np.mean(vals)) if vals else float("nan")


def main() -> int:
    noise = [features.read_pcm16(p).astype(np.float32) / 32768.0
             for p in sorted(NOISE_DIR.glob("*.wav"))]
    noise = [n[:N_PATCH] for n in noise if len(n) >= N_PATCH]

    rows = []
    import csv
    with (ROOT / "ai" / "data" / "splits" / "test_mobile.csv").open(encoding="utf-8") as fh:
        by_label: dict[str, list] = {}
        for r in csv.DictReader(fh):
            by_label.setdefault(r["label"], []).append(r)
    picks = [r for lab in sorted(by_label) for r in by_label[lab][:2]][:CLIPS]
    clean = []
    for r in picks:
        p = ROOT / r["path"]
        if not p.exists():
            continue
        c = np.asarray(features.read_pcm16(p), dtype=np.float32) / 32768.0
        clean.append(np.ascontiguousarray(c[:N_PATCH]))

    # noisy set at 10 dB, deterministic
    noisy = []
    rng = np.random.default_rng(7)
    for i, c in enumerate(clean):
        n = noise[i % len(noise)]
        scale = rms(c) / rms(n) / (10.0 ** (10.0 / 20.0))
        noisy.append(np.ascontiguousarray((c + n * scale).astype(np.float32)))

    base_ssnr = float(np.mean([gain_matched_ssnr(c, x) for c, x in zip(clean, noisy)]))

    print("=" * 96)
    print("denoise parameter sweep  (10 dB mix; no model in the loop)")
    print("=" * 96)
    print(f"  noisy baseline SSNR (gain-matched) = {base_ssnr:.2f} dB")
    print(f"  clips={len(clean)}  noise files={len(noise)}")
    print()
    print(f"  {'dd_alpha':>8} {'min_bias':>8} {'floor_dB':>8} {'xi_min':>7} "
          f"{'noise dB':>9} {'signal dB':>10} {'SSNR dB':>8} {'verdict':>10}")
    print("  " + "-" * 90)

    best = None
    for dd, bias, floor, ximin in itertools.product(
            [0.5, 0.7, 0.9, 0.98], [0.5, 1.0, 1.5], [-18.0, -12.0, -8.0], [-18.0, -12.0]):
        p = D.DenoiseParams(n_fft=N_FFT, hop=HOP, dd_alpha=dd, min_bias=bias,
                            gain_floor_db=floor, xi_min_db=ximin)
        n_att = float(np.mean([db(D.denoise(n, p), n) for n in noise]))
        s_att = float(np.mean([db(D.denoise(c, p), c) for c in clean]))
        ssnr = float(np.mean([gain_matched_ssnr(c, D.denoise(x, p))
                              for c, x in zip(clean, noisy)]))
        # want: noise well reduced, signal nearly untouched, SSNR no worse than noisy
        ok = (n_att <= -6.0) and (s_att >= -1.0) and (ssnr >= base_ssnr - 1.0)
        score = (-n_att) + (s_att + 1.0) * 3.0 - max(0.0, base_ssnr - ssnr)
        rows.append((score, dd, bias, floor, ximin, n_att, s_att, ssnr, ok))
        if ok and (best is None or score > best[0]):
            best = (score, dd, bias, floor, ximin)

    for _, dd, bias, floor, ximin, n_att, s_att, ssnr, ok in sorted(rows, reverse=True)[:14]:
        print(f"  {dd:>8} {bias:>8} {floor:>8} {ximin:>7} {n_att:>9.2f} {s_att:>10.2f} "
              f"{ssnr:>8.2f} {'PASS' if ok else '':>10}")

    print()
    if best:
        _, dd, bias, floor, ximin = best
        print(f"  best passing config: dd_alpha={dd} min_bias={bias} "
              f"gain_floor_db={floor} xi_min_db={ximin}")
    else:
        print("  NO configuration passed (noise<=-6 dB, signal>=-1 dB, SSNR>=noisy-1 dB).")
        print("  The trade-off is real; the next lever is a transient-protection gate, "
              "not these four numbers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

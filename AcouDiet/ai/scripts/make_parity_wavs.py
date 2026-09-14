"""Generates deterministic synthetic wavs for the Mel / preprocessing parity gates.

T-01 (public dataset acquisition) needs the network, which is not available in this
environment. The parity gate itself, however, only needs *some* fixed 16 kHz mono PCM16
input -- the point is that Kotlin and librosa agree on the same bytes. So this script
synthesises a small, reproducible corpus covering the cases that historically break parity:

* pure tones at several frequencies (Mel band placement)
* white noise (broadband, exercises every filter)
* an impulse and a step (framing / boundary / centre-padding behaviour)
* digital silence and near-silence (the degenerate min-max branch)
* chewing-like click trains (the actual use case)
* a clipped square wave (full-scale, non-linear input)

**Multi-patch clips.** ADR-21 made the pre-emphasis predecessor a *streaming* quantity: a
patch that does not start at sample 0 must be pre-emphasised using the raw sample immediately
before it. A corpus of one-patch files can only ever exercise offset 0 -- the one offset where
the predecessor is 0.0 and the old patch-local rule agreed by accident. The two `*_long`
entries below are three patches long so the gate also compares a mid-file patch and the last
full window, which is where a wrong boundary shows up as a growing drift.

Everything is seeded, so re-running produces identical files and the parity result is
reproducible.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.config import CONFIG, paths  # noqa: E402


def _tone(n: int, freq: float, amp: float = 0.4) -> np.ndarray:
    t = np.arange(n) / CONFIG.sample_rate
    return (amp * np.sin(2 * np.pi * freq * t) * 32767.0)


def _noise(n: int, seed: int, amp: float = 0.2) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return (rng.uniform(-1.0, 1.0, n) * amp * 32767.0)


def _impulse(n: int, at: int = 1000) -> np.ndarray:
    x = np.zeros(n)
    x[at] = 20000.0
    return x


def _step(n: int) -> np.ndarray:
    x = np.zeros(n)
    x[n // 2:] = 8000.0
    return x


def _chews(n: int, interval_ms: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    x = np.zeros(n)
    step = int(CONFIG.sample_rate * interval_ms / 1000)
    decay = 0.004 * CONFIG.sample_rate
    i = 0
    while i < n:
        k = np.arange(600)
        env = np.exp(-k / decay)
        burst = env * np.sin(2 * np.pi * 1800.0 * k / CONFIG.sample_rate) * 0.7
        jitter = 1.0 + (rng.random(600) - 0.5) * 0.05
        end = min(i + 600, n)
        x[i:end] += (burst * jitter)[: end - i] * 32767.0
        i += step
    return x


def _square(n: int, freq: float) -> np.ndarray:
    t = np.arange(n) / CONFIG.sample_rate
    return np.sign(np.sin(2 * np.pi * freq * t)) * 32000.0


def build_corpus() -> dict[str, np.ndarray]:
    n = CONFIG.patch_samples
    return {
        "tone_1000hz": _tone(n, 1000.0),
        "tone_250hz": _tone(n, 250.0),
        "tone_4000hz": _tone(n, 4000.0),
        "noise_seed1": _noise(n, 1),
        "noise_seed2": _noise(n, 2, amp=0.05),
        "impulse": _impulse(n),
        "step": _step(n),
        "silence": np.zeros(n),
        "near_silence": _noise(n, 3, amp=1e-4),
        "chews_500ms": _chews(n, 500, 11),
        "chews_700ms": _chews(n, 700, 12),
        "square_500hz": _square(n, 500.0),
        # Three patches long, so offsets 0 / mid / (size - n) are all exercised. Generated as
        # ONE continuous signal and sliced by the gate, which is what makes them able to catch
        # a wrong streaming predecessor: an implementation that restarts pre-emphasis at each
        # offset still matches at offset 0 and diverges here.
        "chews_long": _chews(3 * n, 550, 21),
        "tone_long": _tone(3 * n, 1000.0),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(paths.data / "parity"), help="output directory")
    args = ap.parse_args()

    import soundfile as sf

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    corpus = build_corpus()
    for name, samples in corpus.items():
        pcm = np.clip(np.round(samples), -32768, 32767).astype(np.int16)
        assert pcm.shape[0] >= CONFIG.patch_samples, (
            f"ACD-ART-001: {name} is shorter than one patch"
        )
        assert pcm.shape[0] % CONFIG.patch_samples == 0 or pcm.shape[0] == CONFIG.patch_samples
        path = out / f"{name}.wav"
        sf.write(str(path), pcm, CONFIG.sample_rate, subtype="PCM_16")
        print(f"wrote {path}  ({pcm.shape[0]} samples, peak={int(np.max(np.abs(pcm)))})")

    print(f"\n{len(corpus)} parity wavs in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

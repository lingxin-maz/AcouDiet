"""Generate the cross-language golden vector for the P-03 stage-3 noise gate (ADR-56).

WHY A GOLDEN VECTOR
-------------------
`NoiseGate.kt` is a hand port of `ai/src/denoise_td.py`. A port that "looks right" is not evidence:
the gate is a chain of a sliding minimum, a sliding maximum, a soft expansion curve, a two-rate
one-pole smoother and a clamped linear interpolation, and **any one of them can be off by an index or
an edge rule while still producing a plausible-sounding result**. Measured against the real corpus,
such an error would look like "slightly different numbers", which is exactly the kind of difference
nobody notices until the recognition rate moves.

So the Python reference -- which is the specification -- emits a golden vector, and the Kotlin JVM
suite asserts element-wise agreement. The input is deliberately a *transient train over a noise
floor*, not white noise: it is the case the algorithm exists for, and it exercises the gate opening
and closing rather than sitting at one extreme.

Regenerate with:
    python tool/gen_noise_gate_golden.py
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

import numpy as np  # noqa: E402
from src import denoise_td as G  # noqa: E402

OUT = (ROOT / "app" / "android" / "app" / "src" / "test" / "kotlin" / "com" / "acoudiet" / "app"
       / "audio" / "NoiseGateGolden.kt")

#: 2000 samples at 16 kHz = 125 ms -> 25 frames of 80 samples. Long enough for the smoother and the
#: look-ahead to matter, short enough that the generated source stays reviewable.
N = 2000
#: Agreed tolerance on the waveform. Python accumulates the envelope in float64 and Kotlin uses
#: Double, so the two should agree to rounding; the epsilon exists because `10.0.pow()` and `exp()`
#: are not bit-identical across the two runtimes. 1e-6 on a signal bounded by 1.0 is ~-120 dB.
ATOL = 1e-6


def build_input() -> np.ndarray:
    """A deterministic crunch train over a noise floor, in [-1, 1].

    ⚠️ THE BURST SPACING IS LOAD-BEARING. The first version of this generator put four transients
    480 samples (6 frames) apart, and with `gate_lookahead_frames = 4` **every** frame then sat
    within the look-ahead window of some transient. The gate therefore stayed fully open for the
    whole patch and the "golden vector" was a byte-for-byte copy of its input -- a parity test
    against it would have proved nothing at all, while still passing.

    So the two bursts here are far apart (160 and 1600), which leaves a long stretch that the
    look-ahead cannot protect, and `main()` refuses to write a golden whose output equals its input.
    """
    rng = np.random.default_rng(20260915)
    x = np.zeros(N, dtype=np.float64)
    # background hiss at about -46 dBFS
    x += rng.normal(0.0, 0.005, N)
    # two transients: fast attack, exponential decay -- the shape the gate must NOT smother
    for onset in (160, 1600):
        length = 120
        env = np.exp(-np.arange(length) / 18.0)
        burst = rng.normal(0.0, 1.0, length) * env
        x[onset:onset + length] += 0.6 * burst
    return np.clip(x, -1.0, 1.0)


def params_from_ssot() -> G.TdGateParams:
    d = json.loads((ROOT / "shared" / "feature_config.json").read_text(encoding="utf-8"))["denoise"]
    return G.TdGateParams(
        sample_rate=int(json.loads(
            (ROOT / "shared" / "feature_config.json").read_text(encoding="utf-8"))["sample_rate"]),
        frame_ms=d["gate_frame_ms"],
        noise_window_ms=d["gate_noise_window_ms"],
        noise_bias=d["gate_noise_bias"],
        threshold_db=d["gate_threshold_db"],
        knee_db=d["gate_knee_db"],
        max_attenuation_db=d["gate_max_attenuation_db"],
        lookahead_frames=d["gate_lookahead_frames"],
        attack_ms=d["gate_attack_ms"],
        release_ms=d["gate_release_ms"],
    )


def fmt(arr: np.ndarray, per_line: int = 6) -> str:
    parts = []
    for i in range(0, len(arr), per_line):
        row = ", ".join(f"{v:.9g}f" for v in arr[i:i + per_line])
        parts.append("        " + row + ",")
    return "\n".join(parts)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the committed golden is stale instead of rewriting it")
    args = ap.parse_args(argv[1:])

    p = params_from_ssot()
    x = build_input()
    y = G.gate(x.astype(np.float32), p)

    # A golden vector that equals its input proves nothing about the port, so refuse to write one.
    changed = float(np.max(np.abs(y.astype(np.float64) - x)))
    if changed < 1e-3:
        print(f"ACD-ART-005: the golden vector is a NO-OP (max |y-x| = {changed:.3e}). "
              "The input does not exercise the gate -- check the burst spacing against "
              "gate_lookahead_frames before trusting any parity assertion.", file=sys.stderr)
        return 1

    body = (
        "// GENERATED BY tool/gen_noise_gate_golden.py -- DO NOT EDIT.\n"
        "//\n"
        "// Golden vector for the P-03 stage-3 noise gate (ADR-56). The Python reference\n"
        "// `ai/src/denoise_td.py` is the specification; `NoiseGate.kt` must reproduce it.\n"
        "// Input: a deterministic four-transient crunch train over a noise floor, 2000 samples.\n"
        "package com.acoudiet.app.audio\n"
        "\n"
        "object NoiseGateGolden {\n"
        f"    const val ATOL = {ATOL:.0e}\n"
        "    const val SAMPLE_RATE = "
        f"{p.sample_rate}\n"
        "\n"
        "    /** 2000 samples, 16 kHz: four transients over a noise floor. */\n"
        "    val INPUT: FloatArray = floatArrayOf(\n"
        f"{fmt(x)}\n"
        "    )\n"
        "\n"
        "    /** `denoise_td.gate(INPUT)` with the SSOT `denoise` parameters. */\n"
        "    val EXPECTED: FloatArray = floatArrayOf(\n"
        f"{fmt(y)}\n"
        "    )\n"
        "}\n"
    )

    if args.check:
        if not OUT.exists():
            print(f"ACD-ART-001: {OUT.name} is missing; run without --check", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != body:
            print("ACD-ART-003: the noise-gate golden vector is STALE "
                  "(regenerate with `python tool/gen_noise_gate_golden.py`)", file=sys.stderr)
            return 1
        print("noise-gate golden vector is current")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(body, encoding="utf-8")
    rms_in = float(np.sqrt(np.mean(x * x)))
    rms_out = float(np.sqrt(np.mean(y.astype(np.float64) ** 2)))
    print(f"wrote {OUT.relative_to(ROOT)}")
    print(f"  n={N}  rms in {rms_in:.6f} -> out {rms_out:.6f} "
          f"({20.0 * np.log10(rms_out / rms_in):+.2f} dB)")
    print(f"  atol={ATOL:.0e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

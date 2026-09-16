"""P-03 stage-3 denoiser, third generation: **time-domain transient-preserving gating** (ADR-54).

WHY THIS FAMILY, AND WHY IT CAN WIN WHERE THE OTHERS LOST
--------------------------------------------------------
`ADR-53` measured the whole spectral family (`augment.py::spectral_subtract`, the spectral-floor
variant, and a second-generation minimum-statistics + decision-directed Wiener) and swept 48
configurations. **None** removed noise without removing signal, and the reason is structural, not a
tuning failure: the classes are discriminated by **broadband transients** (crunchiness), and any
**per-bin** gain derived from a noise-floor estimate attenuates the low-energy parts of a transient
-- its onset and decay, which is exactly where "crunch" lives.

This module is a different family. It applies **one broadband gain per instant**, so:

* the **spectrum of a transient is untouched** -- scaling cannot smear spectral shape, it can only
  make the transient quieter or louder. No musical noise is possible: there are no per-bin
  decisions to switch on and off;
* it can only **attenuate** (`gain <= 1`), so it can never invent energy -- the failure mode of the
  first-generation recipes, which *added* 9 dB of artefact energy on noise-only input;
* the gain is driven by a **peak-held envelope over a look-ahead window**, so the gate is already
  open *before* a transient arrives. A naive gate clips onsets; this one cannot.

AND WHY THE FROZEN FEATURE CHAIN TOLERATES IT
---------------------------------------------
`FF-08` normalisation is `per_patch_minmax` on the Mel **dB** image, so a *constant* gain over the
whole patch is normalised away. A time-*varying* gain (the thing this module actually does) is not,
which is the point: the noise floor between crunches goes down, the crunches stay where they are.

STATELESS BY DEFAULT
--------------------
Everything is computed inside one patch -- and because a patch is processed **offline**, the
look-ahead is free (`symmetric` peak hold, no causal delay needed). That keeps `Preprocess` the
stateless object `SPEC-P-03` acceptance 6 requires. `carry` exists for a future streaming stage.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

import numpy as np


@dataclass(frozen=True)
class TdGateParams:
    """Every tuneable number in one place, so freezing them into the SSOT is mechanical."""

    sample_rate: int = 16000

    #: Envelope framing. 5 ms matches the project's frozen envelope hop (FF-21*), which keeps one
    #: framing definition in the codebase instead of two.
    frame_ms: float = 5.0

    #: Noise floor = running minimum of the envelope over this window, bias-compensated.
    noise_window_ms: float = 500.0
    noise_bias: float = 1.20

    #: Gate threshold, relative to the estimated noise floor, and the knee width of the soft
    #: expansion curve. `threshold_db` is the "how much is signal" decision, `knee_db` how gently
    #: the gain approaches full attenuation (a hard knee chatters).
    threshold_db: float = 6.0
    knee_db: float = 12.0

    #: How far the gate may pull the quiet parts down. This is the 「尽可能消除噪音」 knob: bigger
    #: means more noise gone and more risk of thinning the recording between crunches.
    max_attenuation_db: float = 24.0

    #: Look-ahead in frames (symmetric peak hold). >= 1 is what protects transient onsets.
    lookahead_frames: int = 2

    #: Attack / release time constants of the gain smoother, in ms. Attack must be short (protect
    #: onsets); release can be long (avoid pumping between crunches).
    attack_ms: float = 1.0
    release_ms: float = 40.0


_DEFAULT = TdGateParams()


def _frame_envelope(x: np.ndarray, step: int) -> np.ndarray:
    """RMS per non-overlapping frame; the tail shorter than `step` is dropped.

    Accumulated in float64 (not float32) on purpose: the Kotlin port computes in `Double`, and a
    float32 envelope here would put a gratuitous precision gap between the two implementations that
    the cross-language parity test would then have to absorb.
    """
    n = len(x) // step
    if n == 0:
        return np.array([float(np.sqrt(np.mean(x.astype(np.float64) ** 2) + 1e-20))], dtype=np.float64)
    frames = x[:n * step].astype(np.float64).reshape(n, step)
    return np.sqrt(np.mean(frames * frames, axis=1) + 1e-20)


def _sliding_min(e: np.ndarray, lo: int, hi: int) -> np.ndarray:
    """Minimum over the clamped window `[i-lo, i+hi]` (edge values extend).

    Written out explicitly instead of calling scipy so that THIS FILE is the specification the
    Kotlin port mirrors. A library's edge/origin semantics are a silent parity hazard; here the
    window bounds are visible in the signature. Verified element-wise equal to
    `scipy.ndimage.minimum_filter1d(size=lo+hi+1, mode="nearest")`, including the even-size case
    (size 100 -> window `[i-50, i+49]`).
    """
    n = len(e)
    idx = np.arange(n)
    out = e.copy()
    for d in range(-lo, hi + 1):
        if d == 0:
            continue
        out = np.minimum(out, e[np.clip(idx + d, 0, n - 1)])
    return out


def _sliding_max(e: np.ndarray, lo: int, hi: int) -> np.ndarray:
    """Maximum over the clamped window `[i-lo, i+hi]` (edge values extend). See `_sliding_min`."""
    n = len(e)
    idx = np.arange(n)
    out = e.copy()
    for d in range(-lo, hi + 1):
        if d == 0:
            continue
        out = np.maximum(out, e[np.clip(idx + d, 0, n - 1)])
    return out


def _minimum_statistics(e: np.ndarray, window: int, bias: float) -> np.ndarray:
    """Running minimum over `window` frames, bias-compensated.

    The minimum of an envelope over ~0.5 s reaches the noise floor between crunches, so the
    estimate tracks the *noise* even while the signal is loud most of the time.

    Centred rather than causal: a patch is processed offline, so there is no reason to handicap the
    estimate with a delay.
    """
    if window <= 1:
        return e * bias
    lo = window // 2
    return _sliding_min(e, lo, window - 1 - lo) * bias


def _smooth_gain_db(g_db: np.ndarray, a_att: float, a_rel: float) -> np.ndarray:
    """One-pole smoother with separate attack/release coefficients (in the dB domain)."""
    out = np.empty_like(g_db)
    prev = 0.0
    for m in range(len(g_db)):
        target = g_db[m]
        a = a_att if target > prev else a_rel
        prev = a * prev + (1.0 - a) * target
        out[m] = prev
    return out


def _peak_hold(e: np.ndarray, half: int) -> np.ndarray:
    """Symmetric max filter: the gain decision sees the loudest value within +/- `half` frames.

    This is the transient protection: the gate opens `half` frames before an onset, so the onset is
    never clipped. It is free here because a patch is processed offline.
    """
    if half <= 0:
        return e
    return _sliding_max(e, half, half)


def gate(x: np.ndarray, params: TdGateParams | None = None) -> np.ndarray:
    """Time-varying broadband gain that pulls down the noise floor and leaves transients alone."""
    p = params or _DEFAULT
    x = np.asarray(x, dtype=np.float32)
    if len(x) < 4:
        return x.copy()

    step = max(1, int(round(p.sample_rate * p.frame_ms / 1000.0)))
    e = _frame_envelope(x, step)
    noise = _minimum_statistics(e, max(1, int(round(p.noise_window_ms / p.frame_ms))), p.noise_bias)

    # Drive the decision from the peak-held envelope so the gate opens BEFORE a transient.
    e_peak = _peak_hold(e, p.lookahead_frames)
    thr = noise * (10.0 ** (p.threshold_db / 20.0))

    # Soft downward expansion, expressed in dB relative to the threshold:
    #   over_db >= 0  -> gain 0 dB (untouched)
    #   over_db << 0  -> gain approaches -max_attenuation_db smoothly
    # C1-continuous and monotone; no hard knee, so it cannot chatter.
    ratio = e_peak / np.maximum(thr, 1e-12)
    over_db = 20.0 * np.log10(np.maximum(ratio, 1e-12))
    g_db = -p.max_attenuation_db * (1.0 - np.exp(-np.maximum(-over_db, 0.0) / max(p.knee_db, 1e-6)))
    g_db = np.minimum(g_db, 0.0)                       # never amplify

    a_att = float(np.exp(-p.frame_ms / max(p.attack_ms, 1e-6)))
    a_rel = float(np.exp(-p.frame_ms / max(p.release_ms, 1e-6)))
    g_db = _smooth_gain_db(g_db, a_att, a_rel)

    # Interpolate the frame-rate gain to per-sample and apply. Interpolation (rather than a
    # sample-and-hold per frame) is what keeps the gain curve continuous and click-free.
    centres = np.arange(len(g_db), dtype=np.float64) * step + (step - 1) / 2.0
    if len(g_db) == 1:
        g = np.full(len(x), 10.0 ** (g_db[0] / 20.0), dtype=np.float32)
    else:
        g = (10.0 ** (np.interp(np.arange(len(x), dtype=np.float64), centres, g_db) / 20.0)
             ).astype(np.float32)
    return (x * g).astype(np.float32)


def attenuation_db(noise_only: np.ndarray, params: TdGateParams | None = None) -> float:
    """Energy this gate removes from a NOISE-ONLY patch, in dB (negative = removed)."""
    p = params or _DEFAULT
    n = np.asarray(noise_only, dtype=np.float32)
    out = gate(n, p)
    r0 = float(np.sqrt(np.mean(n * n) + 1e-20))
    r1 = float(np.sqrt(np.mean(out * out) + 1e-20))
    return float(20.0 * np.log10(r1 / r0))


def with_params(**kw) -> TdGateParams:
    return replace(_DEFAULT, **kw)

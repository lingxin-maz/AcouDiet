"""P-03 stage-3 denoiser, second generation -- the one that is allowed to be enabled.

WHY A SECOND GENERATION (ADR-53)
--------------------------------
`augment.py::spectral_subtract` is the first generation: it estimates the noise magnitude as the
mean of the quietest 20 % of frames *of the patch itself*, subtracts `1.5x` of it, and gates the
result at zero. Measured on the frozen `test_mobile` split with real noise mixed in at 20/10/5/0 dB
(`ai/reports/denoise_effect.md`), that recipe does not remove noise -- it removes signal:

    variant            top1    SSNR dB   envCorr   crestRatio
    noisy             0.1215      7.63      0.968         0.840
    denoise_ref       0.0382      2.52      0.281         2.969   <- worse than not denoising

Two independent causes, and this module fixes both:

1. **The noise estimate is biased high.** "Quietest 20 % of this patch" still contains the signal
   (a patch of crunchy chewing has no silent frames at all), so `1.5x` of an already-inflated
   estimate over-subtracts everywhere. Fix: **minimum statistics** -- track the running minimum of
   the smoothed periodogram over a window of frames. During a crunch the minimum over the window
   still reaches the true noise floor between transients, so the estimate converges on the *noise*
   rather than on the signal.

2. **A zero gate destroys broadband transients and creates musical noise.** Fix: a
   **decision-directed a-priori SNR** (Ephraim-Malah), a **Wiener gain**, and a **gain floor**.
   The gain floor is the single most effective distortion control: it bounds how much any bin is
   attenuated, which is what stops isolated bins from switching on and off (musical noise) and
   keeps the transient envelope intact.

Everything here is computed **inside one patch** (127 frames of 1024 samples at a 512 hop is a lot
of temporal context), so `Preprocess` can stay the stateless object `SPEC-P-03` acceptance 6
requires. `carry` exists so a future streaming stage can pass the three cross-patch values in --
exactly the pattern `previousRawSample` already uses -- but the default is stateless.

The parameters live in ONE dataclass so freezing them into the SSOT (`SPEC-C-03`) is mechanical.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

import numpy as np


@dataclass(frozen=True)
class DenoiseParams:
    """Every tuneable number, in one place. Nothing here may be a literal at a call site."""

    #: STFT geometry. Values come from the generated config at call time, not from here.
    n_fft: int = 1024
    hop: int = 512

    #: Periodogram smoothing before the noise estimate (reduces the variance of the minimum).
    alpha_smooth: float = 0.70
    freq_smooth_bins: int = 3

    #: Minimum-statistics window, in frames, and the bias compensation for "minimum of a smoothed
    #: periodogram underestimates the true PSD".
    min_window: int = 32
    min_bias: float = 1.50

    #: Decision-directed a-priori SNR (Ephraim-Malah). `xi_min_db` bounds the over-suppression of
    #: bins that are momentarily weak, which is where musical noise is born.
    dd_alpha: float = 0.98
    xi_min_db: float = -18.0

    #: Gain floor: the hard lower bound on attenuation per bin. THE distortion control.
    gain_floor_db: float = -15.0

    #: Subtracted from the minimum-statistics estimate when running wide-band (a small extra margin
    #: on top of `min_bias`); 0.0 keeps the two controls independent.
    extra_margin_db: float = 0.0


_DEFAULT = DenoiseParams()


def _stft(x: np.ndarray, p: DenoiseParams) -> np.ndarray:
    window = np.hanning(p.n_fft).astype(np.float32)
    frames = 1 + (len(x) - p.n_fft) // p.hop
    spec = np.empty((frames, p.n_fft // 2 + 1), dtype=np.complex64)
    for i in range(frames):
        spec[i] = np.fft.rfft(x[i * p.hop:i * p.hop + p.n_fft] * window)
    return spec


def _istft(cleaned: np.ndarray, phase: np.ndarray, length: int, p: DenoiseParams) -> np.ndarray:
    window = np.hanning(p.n_fft).astype(np.float32)
    frames = cleaned.shape[0]
    rec = np.zeros(length, dtype=np.float32)
    norm = np.zeros(length, dtype=np.float32)
    for i in range(frames):
        seg = np.fft.irfft(cleaned[i] * phase[i], n=p.n_fft).astype(np.float32) * window
        rec[i * p.hop:i * p.hop + p.n_fft] += seg
        norm[i * p.hop:i * p.hop + p.n_fft] += window * window
    norm[norm < 1e-8] = 1.0
    return rec / norm


def _smooth_freq(P: np.ndarray, bins: int) -> np.ndarray:
    if bins <= 1:
        return P
    k = bins // 2
    out = P.copy()
    for d in range(1, k + 1):
        out[:, d:] += P[:, :-d]
        out[:, :-d] += P[:, d:]
    return out / (1.0 + 2 * k)


def _minimum_statistics(P: np.ndarray, p: DenoiseParams) -> np.ndarray:
    """Running minimum of `P` over a sliding window of `min_window` frames, bias-compensated.

    This is what makes the estimate track the NOISE rather than the signal: a crunch raises `P` for
    a few frames, but the minimum over the window still lands on the noise floor between them.
    """
    frames, bins = P.shape
    N = np.empty_like(P)
    for m in range(frames):
        lo = max(0, m - p.min_window + 1)
        N[m] = P[lo:m + 1].min(axis=0)
    return N * p.min_bias * (10.0 ** (p.extra_margin_db / 10.0))


def denoise(x: np.ndarray, params: DenoiseParams | None = None,
            carry: dict | None = None) -> np.ndarray:
    """Remove noise from one float patch in roughly [-1, 1].

    `carry`, when given, is reused/updated in place with the three values a streaming stage would
    keep across patches (`gain_prev`, `gamma_prev`). Omit it and the whole thing is stateless.
    """
    p = params or _DEFAULT
    x = np.asarray(x, dtype=np.float32)
    if len(x) < p.n_fft:
        return x.copy()

    spec = _stft(x, p)
    mag = np.abs(spec)
    P = (mag * mag).astype(np.float32)

    # --- 1. smooth the periodogram (time then frequency) so the minimum is meaningful
    Ps = np.empty_like(P)
    Ps[0] = P[0]
    for m in range(1, P.shape[0]):
        Ps[m] = p.alpha_smooth * Ps[m - 1] + (1.0 - p.alpha_smooth) * P[m]
    Ps = _smooth_freq(Ps, p.freq_smooth_bins)

    # --- 2. noise PSD by minimum statistics
    N = _minimum_statistics(Ps, p)
    eps = 1e-12

    # --- 3. decision-directed a-priori SNR -> Wiener gain -> gain floor
    xi_min = 10.0 ** (p.xi_min_db / 10.0)
    g_floor = 10.0 ** (p.gain_floor_db / 20.0)

    frames = P.shape[0]
    gain = np.empty_like(P)
    g_prev = (carry or {}).get("gain_prev")
    gamma_prev = (carry or {}).get("gamma_prev")
    if g_prev is None:
        g_prev = np.ones(P.shape[1], dtype=np.float32)
        gamma_prev = np.ones(P.shape[1], dtype=np.float32)

    for m in range(frames):
        gamma = Ps[m] / (N[m] + eps)
        # a posteriori SNR, softened by the previous frame's estimate (the "decision directed" part)
        xi = (p.dd_alpha * (g_prev ** 2) * gamma_prev
              + (1.0 - p.dd_alpha) * np.maximum(gamma - 1.0, 0.0))
        xi = np.maximum(xi, xi_min)
        g = xi / (1.0 + xi)                     # Wiener
        g = np.maximum(g, g_floor)              # distortion control
        gain[m] = g
        g_prev = g
        gamma_prev = gamma

    if carry is not None:
        carry["gain_prev"] = g_prev
        carry["gamma_prev"] = gamma_prev

    cleaned = (mag * gain).astype(np.float32)
    phase = np.exp(1j * np.angle(spec))
    return _istft(cleaned, phase, len(x), p)


def attenuation_db(noise_only: np.ndarray, params: DenoiseParams | None = None) -> float:
    """How much broadband energy this denoiser removes from a NOISE-ONLY patch, in dB.

    This is the direct measurement of "消除噪音": run the denoiser on a patch that contains no
    signal at all, and compare output RMS with input RMS. It cannot be gamed by destroying the
    signal, which is exactly why it is measured separately from SSNR.
    """
    p = params or _DEFAULT
    n = np.asarray(noise_only, dtype=np.float32)
    out = denoise(n, p)
    r_in = float(np.sqrt(np.mean(n * n) + 1e-20))
    r_out = float(np.sqrt(np.mean(out * out) + 1e-20))
    return float(20.0 * np.log10(r_out / r_in))


def with_params(**kw) -> DenoiseParams:
    """`replace` wrapper so callers never mutate the frozen default."""
    return replace(_DEFAULT, **kw)

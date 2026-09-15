"""Frozen feature pipeline -- the Python half of the parity gate (SPEC-T-08).

Everything here is a literal transcription of the frozen facts (SPEC-00 section 3.1) using
``librosa``, and every constant comes from :mod:`src.config` (which reads the SSOT). The
Kotlin class ``com.acoudiet.app.audio.MelFrontend`` implements the same chain by hand; the
two must agree element-wise within ``atol = 1e-3`` -- if they do not, no model may ship.

The chain, in order (== ``feature_config.operation_order``):

1. PCM16 -> float32 at int16 full scale          (FF-01)
2. optional training-only loudness normalisation (FF-08b, ADR-17: *training only*)
3. pre-emphasis ``y[n] = x[n] - 0.97 x[n-1]`` where ``x[-1]`` is the **last raw sample before
   this patch** (FF-02 as revised by ADR-21)
4. ``librosa.feature.melspectrogram``            (FF-03..FF-06, ADR-16)
5. ``librosa.power_to_db(ref=patch max, top_db)``(FF-07 as revised by ADR-21)
6. drop the tail frame: keep ``[0, n_frames)`` of the 129 frames (FF-11 as revised)
7. per-patch min-max to ``[0, 1]`` over the KEPT frames (FF-08 as revised)

### What ADR-21 changed, and why it matters here

Two stages left and one changed:

* ``remove_dc`` is **gone**. The delivered model's ``operation_order`` has no DC stage, so
  running one at inference would insert an unmodelled transform between mic and model.
* the dB reference is the **patch maximum**, not ``1.0``. ADR-16 rejected ``ref=np.max`` as a
  domain-shift trap; that objection was sound for the chain ADR-16 froze, and it does not
  apply once the model has been *trained* patch-relative. Inference that disagrees with
  training is the strictly larger error.
* the tail frame is dropped **between** the dB stage and the min-max, so the dB reference and
  the ``top_db`` floor are computed over all 129 frames while the min-max window is the kept
  128. Reordering these two steps changes the numbers.
"""

from __future__ import annotations

from typing import Optional, Tuple

import numpy as np

from .config import CONFIG

try:  # librosa is optional for pure-numpy consumers (e.g. threshold unit tests)
    import librosa
except Exception:  # pragma: no cover
    librosa = None


PCM16_FULL_SCALE = 32768.0

#: librosa's default ``amin`` for ``power_to_db``; mirrored in Kotlin as
#: ``Preprocess.AMIN`` so both sides share one literal. The authoritative value is
#: ``CONFIG.power_to_db_amin``; this constant only keeps the two languages' literals in step.
AMIN = 1e-10

#: The ADR-21 pre-emphasis boundary. Spelled once here so a silent rewrite is impossible.
PREEMPHASIS_BOUNDARY = "continuous_stream_previous_raw_sample_or_zero_at_source_start"


# --------------------------------------------------------------------------- loading


def read_pcm16(path) -> np.ndarray:
    """Reads a 16 kHz mono PCM16 wav into ``int16`` samples (FF-01).

    Refuses anything else instead of resampling: SPEC-P-03 section 1.3 forbids resampling,
    and a silently converted file would poison every downstream metric.
    """
    import soundfile as sf

    data, sr = sf.read(str(path), dtype="int16", always_2d=True)
    if sr != CONFIG.sample_rate:
        raise ValueError(f"ACD-ART-001: {path} is {sr} Hz, expected {CONFIG.sample_rate} Hz")
    if data.shape[1] != CONFIG.channels:
        raise ValueError(f"ACD-ART-001: {path} has {data.shape[1]} channels, expected mono")
    return np.ascontiguousarray(data[:, 0])


def wav_to_float(pcm16: np.ndarray) -> np.ndarray:
    """PCM16 -> float32 at int16 full scale (bit-identical to the Kotlin conversion)."""
    return (pcm16.astype(np.float64) / PCM16_FULL_SCALE).astype(np.float32)


# --------------------------------------------------------------------------- steps


def preemphasis(x: np.ndarray, previous_raw_sample: float = 0.0) -> np.ndarray:
    """``y[n] = x[n] - k x[n-1]`` with a **streaming** predecessor (FF-02 / ADR-21).

    ``previous_raw_sample`` is the last RAW sample before this patch, in the same ``[-1, 1]``
    scale as ``x``; 0.0 means "this patch starts at sample 0 of its source". The loop mirrors
    the Kotlin implementation's float32 rounding so the two agree far below the parity
    tolerance.

    The old rule (``x[-1] = x[0]``, "first sample passes through") is deliberately gone: with
    patches sliding by 0.5 s over a 4.096 s window, 87.8 % of every patch is audio that was
    already pre-emphasised, so restarting the filter per patch put a discontinuity exactly
    where the model looks.
    """
    if CONFIG.preemphasis_boundary != PREEMPHASIS_BOUNDARY:
        raise AssertionError(
            "ACD-ART-001: preemphasis_boundary must be the streaming rule (ADR-21), got "
            f"{CONFIG.preemphasis_boundary!r}"
        )
    k = np.float64(CONFIG.preemphasis)
    out = x.astype(np.float32).copy()
    prev = np.float64(previous_raw_sample)
    for i in range(out.shape[0]):
        cur = np.float64(out[i])
        out[i] = np.float32(cur - k * prev)
        prev = cur
    return out


def preprocess_patch(
    pcm16: np.ndarray,
    apply_lufs: bool = False,
    previous_raw_sample: float = 0.0,
) -> np.ndarray:
    """Full preprocessing chain for ONE patch (exactly FF-09 samples).

    ``apply_lufs`` is the training-side loudness normalisation (FF-08b, ADR-17). It is off
    by default because the inference path never runs it, and the parity test compares the
    *inference* chain.

    There is no DC-removal step: ADR-21 removed it because the delivered model was trained
    without one. See the module docstring.
    """
    n = CONFIG.patch_samples
    if pcm16.shape[0] != n:
        raise ValueError(f"ACD-MEL-002: patch must be {n} samples, got {pcm16.shape[0]}")
    x = wav_to_float(pcm16)
    if apply_lufs:
        x = loudness_normalize(x)
    x = preemphasis(x, previous_raw_sample)
    if not np.all(np.isfinite(x)):
        raise ValueError("ACD-MEL-001: preprocessing produced NaN/Inf")
    return x


# --------------------------------------------------------------------------- mel


def mel_power(x: np.ndarray) -> np.ndarray:
    """Power Mel spectrogram, ``[n_mels, raw_mel_frames]`` (128 x 129), frozen STFT params."""
    if librosa is None:
        raise RuntimeError("librosa is required for the mel pipeline")
    if x.shape[0] != CONFIG.patch_samples:
        raise ValueError(
            f"ACD-MEL-002: mel input must be {CONFIG.patch_samples} samples, got {x.shape[0]}"
        )
    s = librosa.feature.melspectrogram(
        y=x.astype(np.float64),
        sr=CONFIG.sample_rate,
        n_fft=CONFIG.n_fft,
        win_length=CONFIG.win_length,
        hop_length=CONFIG.hop_length,
        window=CONFIG.window,
        center=CONFIG.center,
        pad_mode=CONFIG.pad_mode,
        power=CONFIG.power,
        n_mels=CONFIG.n_mels,
        fmin=CONFIG.fmin,
        fmax=CONFIG.fmax,
        htk=CONFIG.mel_htk,
        norm=CONFIG.mel_norm,
    )
    if s.shape != CONFIG.mel_power_shape:
        raise ValueError(
            f"ACD-MEL-001: expected {CONFIG.mel_power_shape} raw frames, got {s.shape}"
        )
    return s


def db_compress(s: np.ndarray) -> np.ndarray:
    """``power_to_db(ref=patch max, top_db)`` -- patch-relative scale (FF-07 / ADR-21).

    ``ref=np.max`` is what the *delivered model* was trained with. The pre-ADR-21 objection
    (a patch-relative reference re-introduces a domain shift) is recorded in
    ``SPEC-00`` section 3.1 FF-07 and deliberately reversed here; ADR-21 explains why.
    """
    if librosa is None:
        raise RuntimeError("librosa is required for the mel pipeline")
    if CONFIG.power_to_db_ref != "patch_max":
        raise AssertionError(
            f"ACD-ART-001: power_to_db ref must be 'patch_max' (ADR-21), got "
            f"{CONFIG.power_to_db_ref!r}"
        )
    ref = np.max(s)
    return librosa.power_to_db(
        s, ref=ref, amin=CONFIG.power_to_db_amin, top_db=CONFIG.top_db
    )


def select_frames(db: np.ndarray) -> np.ndarray:
    """ADR-21 frame selection: drop the tail, keeping ``[0, n_frames)`` of the 129 frames."""
    start, end = CONFIG.kept_frames
    if db.shape[-1] < end:
        raise ValueError(
            f"ACD-MEL-001: cannot select [{start}, {end}) from {db.shape[-1]} frames"
        )
    return db[:, start:end]


def per_patch_minmax(db: np.ndarray) -> np.ndarray:
    """FF-08 as revised: per-patch min-max into the frozen ``[0, 1]`` output window."""
    lo = float(np.min(db))
    hi = float(np.max(db))
    eps = float(CONFIG.normalization_epsilon)
    if hi - lo < eps:
        # Degenerate patch (digital silence or a constant spectrum): zeros, never NaN.
        return np.full(db.shape, float(CONFIG.normalization_output_min), dtype=np.float32)
    out = (db - lo) / (hi - lo)
    out = out * (CONFIG.normalization_output_max - CONFIG.normalization_output_min)
    out = out + CONFIG.normalization_output_min
    return out.astype(np.float32)


def mel_patch(pcm16: np.ndarray, previous_raw_sample: float = 0.0) -> np.ndarray:
    """The complete inference-side chain for one patch -> ``[n_mels, n_frames]`` float32."""
    x = preprocess_patch(pcm16, apply_lufs=False, previous_raw_sample=previous_raw_sample)
    db = db_compress(mel_power(x))
    return per_patch_minmax(select_frames(db))


def to_model_input(mel: np.ndarray) -> np.ndarray:
    """``[n_mels, n_frames]`` -> ``[1, n_mels, n_frames, 1]`` (FF-14 as revised by ADR-21)."""
    c = CONFIG
    if mel.shape != (c.n_mels, c.n_frames):
        raise ValueError(f"ACD-MEL-001: mel must be {(c.n_mels, c.n_frames)}, got {mel.shape}")
    return mel.reshape(tuple(c.input_shape)).astype(np.float32)


# --------------------------------------------------------------------------- lufs


def loudness_normalize(x: np.ndarray, target_lufs: Optional[float] = None) -> np.ndarray:
    """Training-only loudness normalisation (FF-08b / ADR-17).

    Skipped silently when ``pyloudnorm`` is unavailable or the patch is silent -- a silent
    patch must never be amplified (SPEC-P-03 acceptance 12).
    """
    target = CONFIG.target_lufs if target_lufs is None else target_lufs
    if CONFIG.loudness_normalization != "training_only":
        raise AssertionError("ACD-ART-001: loudness normalisation must be training_only")
    if not np.any(np.abs(x) > 1e-6):
        return x
    try:
        import pyloudnorm as pyln

        meter = pyln.Meter(CONFIG.sample_rate)
        loudness = meter.integrated_loudness(x.astype(np.float64))
        if not np.isfinite(loudness):
            return x
        gain_db = target - loudness
        # +-12 dB ceiling: never turn room noise into a bang.
        gain_db = float(np.clip(gain_db, -12.0, 12.0))
        return (x * (10.0 ** (gain_db / 20.0))).astype(np.float32)
    except Exception:
        return x


# --------------------------------------------------------------------------- patches


def iter_patches(samples: np.ndarray, hop_seconds: Optional[float] = None):
    """Yields ``(start_sample, patch)`` sliding windows of exactly FF-09 samples."""
    n = CONFIG.patch_samples
    hop = int(round(CONFIG.sample_rate * (CONFIG.inference_hop_seconds if hop_seconds is None else hop_seconds)))
    for start in range(0, max(0, samples.shape[0] - n) + 1, hop):
        yield start, samples[start:start + n]


def predecessor_of(samples: np.ndarray, start: int) -> float:
    """The raw sample that precedes the patch at ``start`` (0.0 at source start, ADR-21)."""
    if start <= 0:
        return 0.0
    return float(samples[start - 1]) / PCM16_FULL_SCALE


def mel_of_file(path, apply_lufs: bool = False, offset: int = 0) -> np.ndarray:
    """Convenience used by the parity tooling: one patch of a wav -> ``[n_mels, n_frames]``."""
    pcm = read_pcm16(path)
    n = CONFIG.patch_samples
    if pcm.shape[0] < offset + n:
        raise ValueError(
            f"ACD-ART-001: {path} holds {pcm.shape[0]} samples, need {offset + n} "
            f"(offset={offset})"
        )
    x = preprocess_patch(
        pcm[offset:offset + n],
        apply_lufs=apply_lufs,
        previous_raw_sample=predecessor_of(pcm, offset),
    )
    return per_patch_minmax(select_frames(db_compress(mel_power(x))))

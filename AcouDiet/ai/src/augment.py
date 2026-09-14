"""T-03 the augmentation pipeline -- online, train-split-only, and never written to disk.

Four augmentations are in scope (SPEC-T-03 section 1.2). The chain order is frozen and is the
single most error-prone part of this module:

    wav -> patch (FF-09)
        -> (1) environmental noise mixing   SNR in [5, 20] dB, noise from the self-collected bank
        -> (2) LUFS normalisation           target -23 LUFS (FF-08b, ADR-17)
        -> (3) random gain                  0.5x .. 2.0x
        -> (4) frozen feature chain         FF-02 -> FF-08 (in ``features.py``)
        -> (5) SpecAugment on the Mel tensor, filled with 0.0

**Step (3) must come after (2).** LUFS normalisation is deterministic level standardisation, so
gain-then-normalise cancels the random gain completely and ``g_r`` silently becomes a no-op
parameter. SPEC-T-03 section 7 criterion 8 pins this down with an RMS-ratio test.

Cut features (X-06) -- deliberately absent, not merely unimplemented
-------------------------------------------------------------------
**RIR convolution and Mixup are cut** (``X-06``). They must not appear anywhere, and indeed
there is no code path, no switch, no parameter and no mention of them as a feature below.
SPEC-T-03 section 9 is explicit that Mixup must not be implemented "while we are here": the
linear-interpolation assumption does not hold at this data scale. Time stretch / pitch shift /
speed perturb and additive white Gaussian noise are cut as well -- noise has to come from the
self-collected bank, otherwise the cross-domain argument loses its evidence.

Hard constraints enforced in code
--------------------------------
* ``augment()`` refuses any split other than ``train``: the test sets must never be augmented
  (SPEC-T-03 section 1.3, SPEC-T-02 section 2.2 forbidden behaviour (3)).
* Nothing here writes to disk -- no ``sf.write``, no ``np.save``, no ``open(..., "w")``. The
  acceptance test snapshots ``ai/data/`` before and after 500 augmentations and requires the
  file set and every hash to be unchanged (SPEC-T-03 section 7 criterion 4).
* The RNG is ``np.random.default_rng`` only; the global ``np.random`` state is never touched,
  so a run is reproducible from ``(base_seed, epoch, sample_index)`` alone.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import numpy as np

if __package__ in (None, ""):  # executed as a script: ``python ai/src/augment.py``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, paths as _paths
    from src import features
else:  # imported as ``src.augment``
    from .config import CONFIG, paths as _paths
    from . import features

#: Default noise-library location, resolved by ``load_noise_bank`` when no directory is given.
DEFAULT_NOISE_DIR = _paths.data / "noise"

__all__ = [
    "AugmentStats", "NoiseBank", "load_noise_bank", "derive_seed",
    "augment_audio", "augment_mel", "augment", "feature_tensor",
]

#: The only split that may be augmented. Compared as a string so a caller cannot sneak a
#: ``split=None`` past the guard.
TRAIN_SPLIT = "train"

#: Splits that must be rejected outright (API-06 section 3.1 enumerates exactly these).
FORBIDDEN_SPLITS = ("val", "test_public", "test_mobile")


@dataclass
class AugmentStats:
    """Per-call statistics returned to the training log (SPEC-T-03 section 1.2 item 7).

    These are what make the T-06 ablation interpretable: without ``snr_db`` and ``g_r`` on
    record there is no way to explain why one factor moved the cross-domain number.
    """

    snr_db: Optional[float] = None
    gain: Optional[float] = None
    lufs_before: Optional[float] = None
    lufs_applied: bool = False
    clipped_ratio: float = 0.0
    specaug_masked_ratio: float = 0.0
    specaug_time_ratio: float = 0.0
    specaug_freq_ratio: float = 0.0
    noise_file: Optional[str] = None
    skipped: List[str] = field(default_factory=list)

    def as_dict(self) -> Dict[str, object]:
        return {
            "snrDb": None if self.snr_db is None else round(float(self.snr_db), 4),
            "gain": None if self.gain is None else round(float(self.gain), 4),
            "lufsBefore": None if self.lufs_before is None else round(float(self.lufs_before), 3),
            "lufsApplied": self.lufs_applied,
            "clippedRatio": round(float(self.clipped_ratio), 6),
            "specaugMaskedRatio": round(float(self.specaug_masked_ratio), 6),
            "specaugTimeRatio": round(float(self.specaug_time_ratio), 6),
            "specaugFreqRatio": round(float(self.specaug_freq_ratio), 6),
            "noiseFile": self.noise_file,
            "skipped": list(self.skipped),
        }


# ----------------------------------------------------------------------------- noise bank


class NoiseBank:
    """In-memory environmental-noise library used by step (1).

    The bank holds whole recordings and serves random slices with wrap-around tiling, so a
    short noise file still covers a full patch (SPEC-T-03 section 2.4). It is intentionally
    loaded once and kept resident: SPEC-T-03 section 8 budgets <= 200 MB and forbids any disk
    cache, because a cache would break the auditability of "the test sets are never augmented".
    """

    def __init__(self, samples: Sequence[np.ndarray], names: Sequence[str],
                 sample_rate: int, reused_from: Optional[str] = None) -> None:
        if len(samples) != len(names):
            raise ValueError("ACD-ART-001: noise samples and names must be parallel")
        self.samples = list(samples)
        self.names = list(names)
        self.sample_rate = int(sample_rate)
        #: Set when the bank had to be resampled; recorded so a report can state it.
        self.resampled_from = reused_from
        self.uses = 0

    def __len__(self) -> int:
        return len(self.samples)

    @property
    def total_seconds(self) -> float:
        return sum(s.shape[0] for s in self.samples) / float(self.sample_rate or 1)

    def sample(self, n: int, rng: np.random.Generator) -> tuple[np.ndarray, str]:
        """Returns ``(slice, filename)`` of exactly ``n`` samples, tiling if necessary."""
        if not self.samples:
            # SPEC-T-03 section 6: an empty bank is NEVER silently skipped. The caller decides
            # whether to degrade to a noise-free training run; the library refuses to invent
            # white noise, which would invalidate the cross-domain argument.
            raise FileNotFoundError(
                "ACD-ART-001: the environmental-noise bank is empty; run "
                "`make_synthetic_dataset.py` (or provide 10-20 min of self-collected noise under "
                "ai/data/noise/) -- white noise must not be substituted (SPEC-T-03 section 6)"
            )
        i = int(rng.integers(0, len(self.samples)))
        src = self.samples[i]
        if src.shape[0] >= n:
            start = int(rng.integers(0, src.shape[0] - n + 1))
            out = src[start:start + n]
        else:
            reps = int(np.ceil(n / src.shape[0]))
            out = np.tile(src, reps)[:n]
        self.uses += 1
        return out.astype(np.float32), self.names[i]


def load_noise_bank(noise_dir: Optional[Path] = None,
                    sample_rate: Optional[int] = None) -> NoiseBank:
    """Loads ``ai/data/noise/*.wav`` into a :class:`NoiseBank` (SPEC-T-03 section 3).

    Files whose rate differs from FF-01 are resampled once, here, and the fact is recorded --
    mixing two sample rates would corrupt the SNR arithmetic of step (1).
    """
    import soundfile as sf

    root = Path(noise_dir) if noise_dir is not None else DEFAULT_NOISE_DIR
    target = int(sample_rate if sample_rate is not None else CONFIG.sample_rate)
    samples: List[np.ndarray] = []
    names: List[str] = []
    resampled: Optional[str] = None
    if not root.exists():
        return NoiseBank([], [], target)
    for p in sorted(root.glob("*.wav")):
        data, sr = sf.read(str(p), dtype="float32", always_2d=True)
        x = data[:, 0]
        if int(sr) != target:
            import librosa

            x = librosa.resample(x, orig_sr=int(sr), target_sr=target).astype(np.float32)
            resampled = f"{sr}->{target}"
        samples.append(np.ascontiguousarray(x, dtype=np.float32))
        names.append(p.name)
    return NoiseBank(samples, names, target, reused_from=resampled)


# ----------------------------------------------------------------------------- helpers


def derive_seed(base_seed: int, epoch: int, index: int) -> int:
    """``seed_derived = f(base_seed, epoch, sample_index)`` (SPEC-T-03 section 2.3).

    SHA-256 based on purpose: Python's ``hash()`` is salted per process, so using it would make
    "same configuration -> same curves" false across invocations.
    """
    import hashlib

    digest = hashlib.sha256(f"{int(base_seed)}:{int(epoch)}:{int(index)}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % (2 ** 32)


def _rms(x: np.ndarray) -> float:
    if x.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64))))


def _loudness(x: np.ndarray) -> Optional[float]:
    """Integrated loudness in LUFS, or ``None`` when it cannot be measured."""
    try:
        import pyloudnorm as pyln

        meter = pyln.Meter(CONFIG.sample_rate)
        value = float(meter.integrated_loudness(np.asarray(x, dtype=np.float64)))
        return value if np.isfinite(value) else None
    except Exception:  # noqa: BLE001 - pyloudnorm absent or degenerate input
        return None


# ----------------------------------------------------------------------------- step 1-3


def augment_audio(x: np.ndarray, split: str, rng: np.random.Generator,
                  noise_bank: Optional[NoiseBank] = None,
                  stats: Optional[AugmentStats] = None,
                  force_gain: Optional[float] = None) -> np.ndarray:
    """Steps (1)-(3): noise mixing, LUFS normalisation, random gain.

    ``split`` must be ``"train"``; anything else raises before a single sample is modified.
    ``force_gain`` exists only for the order test of SPEC-T-03 section 7 criterion 8.
    """
    if split != TRAIN_SPLIT:
        raise AssertionError(
            f"ACD-ART-002: augmentation is train-only, refused split={split!r} "
            "(SPEC-T-03 section 1.3; the test sets are never augmented)"
        )
    st = stats if stats is not None else AugmentStats()
    d = CONFIG.domain
    y = np.asarray(x, dtype=np.float32)
    if y.ndim != 1:
        raise ValueError(f"ACD-ART-001: expected mono audio, got shape {y.shape}")

    silent = _rms(y) < d.silence_rms
    if silent:
        # SPEC-T-03 section 2.4: a silent patch gets neither noise nor LUFS -- there is no
        # measurable loudness to normalise and mixing noise into digital silence would
        # manufacture structure that the recording does not have.
        st.skipped.append("SILENT_PATCH")
    else:
        if noise_bank is not None and len(noise_bank) > 0:
            noise, name = noise_bank.sample(y.shape[0], rng)
            st.noise_file = name
            snr_db = float(rng.uniform(d.snr_db_min, d.snr_db_max))
            st.snr_db = snr_db
            rms_x, rms_n = _rms(y), _rms(noise)
            if rms_n > 0:
                y = y + noise * (rms_x / (rms_n * (10.0 ** (snr_db / 20.0))))
            else:
                st.skipped.append("NOISE_SILENT")
        # (2) LUFS normalisation -- AFTER the noise, BEFORE the gain.
        loudness = _loudness(y)
        st.lufs_before = loudness
        if loudness is None or loudness < d.lufs_measure_floor:
            st.skipped.append("LUFS_UNMEASURABLE")
        else:
            gain_db = CONFIG.target_lufs - loudness
            gain_db = float(np.clip(gain_db, -d.lufs_gain_clip_db, d.lufs_gain_clip_db))
            y = (y * (10.0 ** (gain_db / 20.0))).astype(np.float32)
            st.lufs_applied = True

    # (3) random gain, clipped to the legal sample range.
    gain = float(force_gain) if force_gain is not None else float(rng.uniform(d.gain_min, d.gain_max))
    st.gain = gain
    y = y * gain
    clipped = float(np.mean(np.abs(y) > 1.0)) if y.size else 0.0
    st.clipped_ratio = clipped
    return np.clip(y, d.audio_clip_min, d.audio_clip_max).astype(np.float32)


# ----------------------------------------------------------------------------- step 5


def augment_mel(mel: np.ndarray, rng: np.random.Generator,
                stats: Optional[AugmentStats] = None) -> np.ndarray:
    """Step (5): SpecAugment on the normalised Mel tensor, masked cells filled with 0.0.

    ``T`` and ``F`` are the mask **count** upper bounds (10 time masks, 8 frequency masks) and a
    single mask is at most ``floor(axis_len / divisor)`` wide, per SPEC-T-03 section 5. Those two
    numbers alone are not a coverage bound -- 10 masks of up to 12 frames each reach ~93% of the
    time axis -- so the ceiling that makes the pipeline safe is the per-axis **total** coverage
    cap of SPEC-T-03 section 7 criterion 10 (10% of the time axis, 12.5% of the frequency axis,
    i.e. the plain SpecAugment convention that at most one tenth of one axis is masked). Masks
    are still drawn as counts, but the loop stops once the axis budget is spent, and the realised
    coverage is written into ``stats`` so the training log carries the evidence rather than a
    claim.
    """
    d = CONFIG.domain
    if mel.ndim != 2 or mel.shape != CONFIG.mel_shape:
        raise ValueError(
            f"ACD-MEL-001: SpecAugment expects {CONFIG.mel_shape}, got {mel.shape}"
        )
    out = np.array(mel, dtype=np.float32, copy=True)
    n_mels, n_frames = out.shape
    st = stats if stats is not None else AugmentStats()

    time_width = max(1, n_frames // d.specaug_time_divisor)
    freq_width = max(1, n_mels // d.specaug_freq_divisor)
    time_budget = int(n_frames * d.specaug_time_coverage_max)
    freq_budget = int(n_mels * d.specaug_freq_coverage_max)
    time_hits = np.zeros(n_frames, dtype=bool)
    freq_hits = np.zeros(n_mels, dtype=bool)

    # A single random mask stays within the coverage budget; only the count varies (0..T / 0..F),
    # so the augmentation is a count-bounded uniform draw exactly as SPEC-T-03 section 5 states.
    for _ in range(int(rng.integers(0, d.specaug_time_masks + 1))):
        if int(np.count_nonzero(time_hits)) >= time_budget:
            break
        w = int(rng.integers(1, time_width + 1))
        w = int(min(w, time_budget, max(n_frames - 1, 1)))
        if w < 1:
            break
        start = int(rng.integers(0, max(1, n_frames - w + 1)))
        out[:, start:start + w] = d.specaug_fill
        time_hits[start:start + w] = True
    for _ in range(int(rng.integers(0, d.specaug_freq_masks + 1))):
        if int(np.count_nonzero(freq_hits)) >= freq_budget:
            break
        w = int(rng.integers(1, freq_width + 1))
        w = int(min(w, freq_budget, max(n_mels - 1, 1)))
        if w < 1:
            break
        start = int(rng.integers(0, max(1, n_mels - w + 1)))
        out[start:start + w, :] = d.specaug_fill
        freq_hits[start:start + w] = True

    st.specaug_time_ratio = float(np.mean(time_hits)) if n_frames else 0.0
    st.specaug_freq_ratio = float(np.mean(freq_hits)) if n_mels else 0.0
    total = n_frames * n_mels
    masked = int(np.count_nonzero(time_hits)) * n_mels + int(np.count_nonzero(freq_hits)) * n_frames
    st.specaug_masked_ratio = float(min(1.0, masked / total)) if total else 0.0
    if not np.all(np.isfinite(out)):
        raise ValueError("ACD-MEL-001: SpecAugment produced NaN/Inf")
    # FF-08 guarantees the tensor lives in [0, 1]. A violation means the fixed dB clip was
    # replaced (the ``ref=np.max`` domain-shift trap) and must fail loudly, never be clipped
    # away silently (SPEC-T-03 section 7 criterion 16).
    if float(out.min()) < 0.0 or float(out.max()) > 1.0:
        raise AssertionError(
            f"ACD-ART-005: augmented Mel left [0,1] (range [{out.min()}, {out.max()}])"
        )
    return out.astype(np.float32)


# ----------------------------------------------------------------------------- pipeline


def feature_tensor(pcm16: np.ndarray, apply_lufs: bool = False,
                   split: str = TRAIN_SPLIT, rng: Optional[np.random.Generator] = None,
                   noise_bank: Optional[NoiseBank] = None,
                   augment_on: bool = True,
                   specaugment_on: bool = True,
                   denoise: bool = False,
                   force_gain: Optional[float] = None,
                   ) -> tuple[np.ndarray, AugmentStats]:
    """Full patch -> model-input pipeline, with the augmentation switches of T-06.

    ``augment_on=False`` skips steps (1)-(3) and (5) and leaves the feature chain untouched, so
    an ablation difference can only be caused by the switches and never by a changed pipeline
    (SPEC-T-03 section 7 criterion 15).

    ``denoise`` is the T-06 factor A: spectral-subtraction denoising on the *training* side
    only. It defaults to OFF and never alters the FF-08 normalisation mode.
    """
    st = AugmentStats()
    d = CONFIG.domain
    n = CONFIG.patch_samples
    pcm = np.asarray(pcm16)
    if pcm.shape[0] < n:
        # SPEC-T-03 section 2.4: tile, never zero-pad. Zero padding fabricates silence, which
        # would corrupt every downstream VAD-related statistic.
        reps = int(np.ceil(n / pcm.shape[0]))
        pcm = np.tile(pcm, reps)[:n]
    patch = np.ascontiguousarray(pcm[:n])

    if augment_on:
        if rng is None:
            rng = np.random.default_rng(CONFIG.domain.split_seed)
        if denoise:
            patch = spectral_subtract(patch, rng)
            st.skipped.append("DENOISE_ON")
        audio = features.wav_to_float(patch)
        audio = augment_audio(audio, TRAIN_SPLIT, rng, noise_bank=noise_bank, stats=st,
                              force_gain=force_gain)
        x = _preprocess_float(audio)
        mel = features.per_patch_minmax(
            features.select_frames(features.db_compress(features.mel_power(x)))
        )
        if specaugment_on:
            mel = augment_mel(mel, rng, stats=st)
    else:
        # No augmentation: run the frozen inference-side chain unchanged, so that
        # --augment off differs from --augment on in exactly one thing (SPEC-T-03 criterion 15).
        x = features.preprocess_patch(patch, apply_lufs=False)
        mel = features.per_patch_minmax(
            features.select_frames(features.db_compress(features.mel_power(x)))
        )

    if mel.shape != CONFIG.mel_shape:
        raise ValueError(f"ACD-MEL-001: expected {CONFIG.mel_shape}, got {mel.shape}")
    tensor = features.to_model_input(mel)
    return tensor, st


def _preprocess_float(x: np.ndarray) -> np.ndarray:
    """Pre-emphasis on an already-float patch (the FF-02 chain as revised by ADR-21).

    ``features.preprocess_patch`` starts from PCM16 and would re-scale by the int16 full scale;
    here the samples are already float in [-1, 1], so only the pre-emphasis step applies.

    There is NO DC removal any more: ADR-21 removed it because the delivered model was trained
    without one. The predecessor is 0.0 because this path operates on a whole augmented clip,
    i.e. it does begin at the start of its own source.
    """
    y = features.preemphasis(np.asarray(x, dtype=np.float32), 0.0)
    if not np.all(np.isfinite(y)):
        raise ValueError("ACD-MEL-001: preprocessing produced NaN/Inf")
    return y


def spectral_subtract(pcm16: np.ndarray, rng: np.random.Generator,
                      oversubtraction: Optional[float] = None) -> np.ndarray:
    """Training-side denoising used as T-06 factor A (spectral subtraction).

    This is the same algorithm family as the on-device ``P-03`` stage, kept deliberately simple:
    estimate the noise magnitude spectrum from the quietest frames of the patch, subtract an
    oversubtracted multiple, and gate the result at zero. It runs **before** the frozen feature
    chain and never changes FF-08's normalisation mode.

    It is applied to the *training* patch only, so the value of ``--denoise`` cannot leak into
    the feature definition; SPEC-T-06 section 6 requires any mismatch with the on-device
    implementation to be recorded rather than papered over.
    """
    x = np.asarray(pcm16, dtype=np.float32) / 32768.0
    n_fft = CONFIG.n_fft
    hop = CONFIG.hop_length
    if x.shape[0] < n_fft:
        return np.asarray(pcm16, dtype=np.int16)
    k = oversubtraction if oversubtraction is not None else 1.5
    window = np.hanning(n_fft).astype(np.float32)
    frames = 1 + (x.shape[0] - n_fft) // hop
    spec = np.empty((frames, n_fft // 2 + 1), dtype=np.complex64)
    for i in range(frames):
        seg = x[i * hop:i * hop + n_fft] * window
        spec[i] = np.fft.rfft(seg)
    mag = np.abs(spec)
    energy = mag.sum(axis=1)
    quiet = energy <= np.percentile(energy, 20.0)
    noise_mag = mag[quiet].mean(axis=0) if np.any(quiet) else mag.min(axis=0)
    cleaned = np.maximum(mag - k * noise_mag[None, :], 0.0)
    phase = np.exp(1j * np.angle(spec))
    rec = np.zeros(x.shape[0], dtype=np.float32)
    norm = np.zeros(x.shape[0], dtype=np.float32)
    for i in range(frames):
        seg = np.fft.irfft(cleaned[i] * phase[i], n=n_fft).astype(np.float32) * window
        rec[i * hop:i * hop + n_fft] += seg
        norm[i * hop:i * hop + n_fft] += window * window
    norm[norm < 1e-8] = 1.0
    rec = rec / norm
    return np.clip(np.round(rec * 32768.0), -32768, 32767).astype(np.int16)


def augment(pcm16: np.ndarray, split: str, rng: np.random.Generator,
            noise_bank: Optional[NoiseBank] = None,
            augment_on: bool = True,
            specaugment_on: bool = True,
            denoise: bool = False,
            ) -> tuple[np.ndarray, AugmentStats]:
    """Convenience wrapper returning ``(model_input, stats)``; enforces the train-only rule."""
    if split != TRAIN_SPLIT:
        raise AssertionError(
            f"ACD-ART-002: augment() refused split={split!r}; augmentation is train-only "
            "(SPEC-T-03 section 1.3)"
        )
    return feature_tensor(pcm16, split=split, rng=rng, noise_bank=noise_bank,
                          augment_on=augment_on, specaugment_on=specaugment_on,
                          denoise=denoise)

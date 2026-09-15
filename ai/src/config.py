"""AcouDiet offline training configuration.

THE single source of truth is ``shared/feature_config.json``. This module only *reads* it
(API-06 section 2: "write access to the SSOT exists only in C-03"). Nothing here may
hard-code a frozen number: if a value is needed, it comes from ``CONFIG``.

Usage::

    from src.config import CONFIG, paths
    CONFIG.n_frames          # 128 (FF-11 as REVISED by ADR-21; the raw STFT count is 129)
    paths.splits / "train.csv"
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List

__all__ = [
    "AI_ROOT", "PROJECT_ROOT", "WORKSPACE_ROOT", "SSOT_PATH",
    "Paths", "paths", "FeatureConfigError", "DomainConst", "Config",
    "CONFIG", "assert_frozen_invariants", "sha256_file", "sha256_bytes",
    "read_kotlin_mel_version",
]


class FeatureConfigError(RuntimeError):
    """Raised when the SSOT cannot be trusted (API-06 section 11, ``ACD-ART-001``)."""

# --------------------------------------------------------------------------- layout

#: ``<root>/ai/src/config.py``
AI_ROOT = Path(__file__).resolve().parents[1]        # <root>/ai
PROJECT_ROOT = AI_ROOT.parent                        # <root> (ADR-51: the repository root)
#: ADR-51 promoted the code to the repository root, so the workspace root IS the repository root
#: and the SSOT is ``<root>/shared/feature_config.json``. Split CSV paths are stored relative to
#: this directory, which is why ``paths.workspace`` is what every writer/reader below divides by.
WORKSPACE_ROOT = PROJECT_ROOT


def _find_ssot() -> Path:
    candidates = [
        Path(os.environ["ACOUDIET_SSOT"]) if os.environ.get("ACOUDIET_SSOT") else None,
        WORKSPACE_ROOT / "shared" / "feature_config.json",
        PROJECT_ROOT / "shared" / "feature_config.json",
        AI_ROOT / "shared" / "feature_config.json",
        AI_ROOT / "feature_config.json",
    ]
    for c in candidates:
        if c is not None and c.exists():
            return c
    raise FileNotFoundError(
        "ACD-ART-001: shared/feature_config.json not found; tried "
        + ", ".join(str(c) for c in candidates if c)
    )


SSOT_PATH = _find_ssot()


@dataclass(frozen=True)
class Paths:
    ai: Path = AI_ROOT
    project: Path = PROJECT_ROOT
    workspace: Path = WORKSPACE_ROOT
    ssot: Path = SSOT_PATH
    data: Path = AI_ROOT / "data"
    raw_public: Path = AI_ROOT / "data" / "raw" / "public"
    raw_mobile: Path = AI_ROOT / "data" / "raw" / "mobile"
    augmented: Path = AI_ROOT / "data" / "augmented"
    splits: Path = AI_ROOT / "data" / "splits"
    artifacts: Path = AI_ROOT / "artifacts"
    reports: Path = AI_ROOT / "reports"
    app_assets: Path = PROJECT_ROOT / "app" / "assets"
    app_models: Path = PROJECT_ROOT / "app" / "assets" / "models"

    def ensure(self) -> None:
        for d in (
            self.data,
            self.raw_public,
            self.raw_mobile,
            self.augmented,
            self.splits,
            self.artifacts,
            self.reports,
            self.app_models,
        ):
            d.mkdir(parents=True, exist_ok=True)


paths = Paths()


# ------------------------------------------------------------------- hashing helpers


def sha256_bytes(blob: bytes) -> str:
    """Lower-case hex SHA-256 of ``blob`` (API-06 section 5: 64 hex chars)."""
    import hashlib

    return hashlib.sha256(blob).hexdigest()


def sha256_file(path) -> str:
    """Lower-case hex SHA-256 of a file, streamed (never loads the whole file)."""
    import hashlib

    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


#: Kotlin file that publishes the Mel front-end version (the handshake constant).
#: API-06 section 5 requires ``model_card.melVersion`` to equal this constant *verbatim*,
#: so it is always parsed out of the Kotlin source instead of being duplicated here.
KOTLIN_FEATURE_CONFIG = (
    PROJECT_ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin"
    / "com" / "acoudiet" / "app" / "config" / "FeatureConfig.kt"
)


def read_kotlin_mel_version(path=None) -> str:
    """Parses ``MEL_VERSION`` out of the generated Kotlin ``FeatureConfig.kt``.

    Reading the Kotlin constant (rather than a copy of the string in this file) is what
    makes the ``model_card.melVersion`` handshake drift-proof: if B bumps
    ``MEL_VERSION``, our card stops matching and the T-08/gate scripts fail loudly.
    """
    src = Path(path) if path is not None else KOTLIN_FEATURE_CONFIG
    if not src.exists():
        raise FeatureConfigError(
            f"ACD-CFG-001: Kotlin FeatureConfig not found at {src}; cannot close the "
            "melVersion handshake"
        )
    import re

    text = src.read_text(encoding="utf-8")
    m = re.search(r'const\s+val\s+MEL_VERSION\s*:\s*String\s*=\s*"([^"]+)"', text)
    if not m:
        raise FeatureConfigError(
            f"ACD-CFG-001: MEL_VERSION not found in {src}"
        )
    return m.group(1)


# --------------------------------------------------------------------------- config


@dataclass(frozen=True)
class DomainConst:
    """Numeric constants that belong to domain T but are **not** part of the SSOT.

    The SSOT is the single source of truth for every *frozen feature fact* (FF-*). It does
    not carry the toolchain's own thresholds, so those live here, each annotated with the
    SPEC section that defines it. Collecting them in ``config.py`` (and nowhere else) is
    what makes ``ai/scripts/assert_no_hardcoded_values.py`` able to prove there is no
    second, drifting copy of any frozen number inside ``ai/src`` or ``ai/scripts``.

    Authoritative SPEC sections:
      * T-01 section 2.2 / section 2.4 -- ingest thresholds and rejects.
      * T-02 section 5              -- split ratios, seed.
      * T-03 section 5              -- augmentation ranges and SpecAugment T/F.
      * T-04 section 5              -- FF-17 hyper-parameters, 2 h watchdog.
      * T-05 section 5              -- Wilson level, histogram bin, latency repeats.
      * T-06 section 5              -- 2x2 factor design.
      * T-07 section 5              -- representative set size, FF-16 byte caps.
      * T-08 section 5              -- label/confidence thresholds, Mel atol.
      * API-06 sections 3, 7, 9     -- split tolerance, report thresholds.
    """

    # -- T-01 ingest and cleaning -------------------------------------------------
    #: Minimum fragments per class before ``--strict`` fails (SPEC-T-01 section 2.4).
    min_fragments_per_class: int = 500
    #: Longest single fragment kept without a ``LONG_FILE`` flag (SPEC-T-01 section 2.4).
    max_fragment_seconds: float = 60.0
    #: A fragment quieter than this RMS is discarded as silent (SPEC-T-01 section 2.2).
    silence_rms: float = 1e-4
    #: Fraction of full-scale samples above ``clip_abs`` that marks a fragment clipped.
    clip_fraction: float = 0.01
    #: Absolute sample magnitude that counts as full scale for clipping detection.
    clip_abs: float = 0.999
    #: Self-collected corpus shape: 6 classes x 5 people x 8 segments (SPEC-T-01 section 1.2).
    mobile_people: int = 5
    mobile_segments_per_class: int = 8
    #: Minimum segments per person and class that must use each capture pose.
    mobile_pose_min: int = 2
    #: Noise library duration window, in minutes (SPEC-T-01 section 2.4).
    noise_minutes_min: float = 10.0
    noise_minutes_max: float = 20.0
    #: Number of distinct noise scenes required by SPEC-T-01 section 2.2.
    noise_scene_count: int = 3

    # -- T-02 splitting -----------------------------------------------------------
    #: Public split ratio target train/val/test_public (SPEC-T-02 section 1.2).
    split_ratio_train: float = 0.70
    split_ratio_val: float = 0.15
    split_ratio_test_public: float = 0.15
    #: Allowed deviation of the realised ratio, in ratio points (SPEC-T-02 section 2.4).
    split_ratio_tolerance: float = 0.02
    #: Default deterministic split seed (SPEC-T-02 section 5).
    split_seed: int = 20260910
    #: Subjects whose data is cross-domain test only, never training (API-06 section 3.2).
    mobile_test_subjects: tuple = ("P01", "P02", "P03")
    #: Subjects reserved for domain-adaptation validation (API-06 section 3.2).
    mobile_adapt_subjects: tuple = ("P04", "P05")

    # -- T-03 augmentation --------------------------------------------------------
    snr_db_min: float = 5.0
    snr_db_max: float = 20.0
    gain_min: float = 0.5
    gain_max: float = 2.0
    #: LUFS below which measurement is refused; the patch is left unnormalised.
    lufs_measure_floor: float = -70.0
    #: Per-call gain ceiling, protects against amplifying near-silence (features.py).
    lufs_gain_clip_db: float = 12.0
    #: SpecAugment mask *count* upper bounds (T = time, F = frequency).
    specaug_time_masks: int = 10
    specaug_freq_masks: int = 8
    #: Mask width = floor(axis_len / divisor); chosen so single-axis coverage <= 10%.
    specaug_time_divisor: int = 10
    specaug_freq_divisor: int = 8
    #: Fill value for masked Mel cells: the lower bound of the FF-08 range.
    specaug_fill: float = 0.0
    #: Sample clamp applied after the random gain.
    audio_clip_min: float = -1.0
    audio_clip_max: float = 1.0
    #: Fraction of clipped samples in one batch that triggers a warning.
    clipped_warn_ratio: float = 0.10
    #: Per-axis SpecAugment coverage ceilings used by the acceptance test (SPEC-T-03 #10).
    specaug_time_coverage_max: float = 0.10
    specaug_freq_coverage_max: float = 0.125

    # -- T-04 training (FF-17) ----------------------------------------------------
    learning_rate_initial: float = 1e-3
    learning_rate_final: float = 1e-5
    weight_decay: float = 1e-4
    batch_size: int = 32
    max_epochs: int = 50
    early_stopping_patience: int = 5
    label_smoothing: float = 0.1
    dropout_rate: float = 0.2
    #: Watchdog deadline (R-ENV-2), in seconds.
    watchdog_seconds: float = 2.0 * 3600.0
    #: Fallback learning rate after a divergence (SPEC-T-04 section 2.4).
    divergent_learning_rate: float = 5e-4
    #: CLI default for the training-set cap; 0 means "use every row".
    default_train_limit: int = 0

    # -- T-05 evaluation ----------------------------------------------------------
    #: Wilson confidence level -> z. 95% -> 1.96 (SPEC-T-05 section 5).
    wilson_z: float = 1.96
    #: Confidence-histogram bin width (SPEC-T-05 section 5).
    confidence_bin_width: float = 0.05
    #: Desktop latency benchmark repetitions (SPEC-T-05 section 5).
    latency_repeats: int = 30
    #: Below this sample count the report must flag a very wide interval.
    small_sample_n: int = 30

    # -- T-06 ablation ------------------------------------------------------------
    ablation_factor_count: int = 2
    ablation_level_count: int = 2
    ablation_run_count: int = 4

    # -- T-07 export (FF-16) ------------------------------------------------------
    #: Representative calibration patches, at least 20 per class (SPEC-T-07 section 2.2).
    representative_n: int = 200
    representative_per_class_min: int = 20
    #: FF-16 size caps in bytes: INT8 <= 2.5 MB, FP32 <= 6 MB.
    int8_max_bytes: int = int(2.5 * 1024 * 1024)
    fp32_max_bytes: int = int(6 * 1024 * 1024)
    #: Model version string; must match the delivered ``<name>_<version>.tflite``.
    model_version: str = "1.0.0"
    model_name: str = "acoudiet"
    metrics_ref: str = "ai/artifacts/model_card.json -> ai/artifacts/metrics.json"

    # -- T-08 numerical alignment -------------------------------------------------
    #: Label agreement gate: labelMatch >= 0.98 (SPEC-T-08 section 1.2).
    parity_label_match_min: float = 0.98
    #: Confidence delta gate: maxConfDelta <= 0.05 (SPEC-T-08 section 1.2).
    parity_max_conf_delta_max: float = 0.05
    #: Cross-language Mel tolerance (API-01 section 5 / SPEC-T-08 section 4).
    mel_atol: float = 1e-3
    #: Minimum number of fixed parity samples (SPEC-T-08 section 2.4).
    parity_min_samples: int = 50


@dataclass(frozen=True)
class Config:
    """Frozen feature spec, mirrored from ``shared/feature_config.json``.

    Every field is filled from the SSOT JSON by :func:`_load_config`; the defaults declared
    below exist only so the dataclass is constructible in tests and are **never** used in
    production, because a missing SSOT key raises ``ACD-ART-001`` (a silent default would be
    exactly the "second copy of a frozen number" that SPEC-00 section 3 forbids).
    """

    raw: Dict[str, Any] = field(repr=False, default_factory=dict)

    # -- audio / feature (FF-01 .. FF-12) --
    sample_rate: int = 16000
    channels: int = 1
    bit_depth: int = 16
    preemphasis: float = 0.97
    preemphasis_boundary: str = "continuous_stream_previous_raw_sample_or_zero_at_source_start"
    window: str = "hann"
    n_fft: int = 1024
    win_length: int = 1024
    hop_length: int = 512
    pad_mode: str = "constant"
    n_mels: int = 128
    mel_htk: bool = False
    mel_norm: str = "slaney"
    fmin: float = 20.0
    fmax: float = 8000.0
    power: float = 2.0
    compression: str = "power_to_db"
    power_to_db_ref: str = "patch_max"
    power_to_db_amin: float = 1e-10
    top_db: float = 80.0
    normalization: str = "per_patch_minmax"
    normalization_epsilon: float = 1e-08
    normalization_output_min: float = 0.0
    normalization_output_max: float = 1.0
    loudness_normalization: str = "training_only"
    target_lufs: float = -23.0
    patch_samples: int = 65536
    patch_seconds: float = 4.096
    center: bool = True
    #: Raw STFT frames for one patch (129). NOT the tensor width any more -- see n_frames.
    raw_mel_frames: int = 129
    #: Frames handed to the model after the tail drop (128). ADR-21.
    n_frames: int = 128
    frame_selection: Dict[str, Any] = field(default_factory=dict)
    operation_order: List[str] = field(default_factory=list)
    model_internal_preprocessing: Dict[str, Any] = field(default_factory=dict)
    inference_hop_seconds: float = 0.5

    # -- model (FF-13 .. FF-18) --
    input_shape: List[int] = field(default_factory=lambda: [1, 128, 128, 1])
    num_classes: int = 6
    class_labels: List[str] = field(default_factory=lambda: list("chips cabbage gummies noodles carrot drink".split()))

    # -- behaviour / voting / windows / scoring --
    behavior: Dict[str, Any] = field(default_factory=dict)
    voting: Dict[str, Any] = field(default_factory=dict)
    meal_windows: Dict[str, Any] = field(default_factory=dict)
    health_score_weights: Dict[str, Any] = field(default_factory=dict)
    health_score_formula: Dict[str, Any] = field(default_factory=dict)

    # -- domain-T toolchain constants (not FF values; see :class:`DomainConst`) --
    domain: DomainConst = field(default_factory=DomainConst)

    # -- convenience ---------------------------------------------------------------
    @property
    def mel_shape(self) -> tuple:
        """``(n_mels, n_frames)`` -- the Mel tensor shape every stage must agree on."""
        return (self.n_mels, self.n_frames)

    @property
    def mel_power_shape(self) -> tuple:
        """``(n_mels, raw_mel_frames)`` -- the shape BEFORE the ADR-21 tail drop (128, 129)."""
        return (self.n_mels, self.raw_mel_frames)

    @property
    def kept_frames(self) -> tuple:
        """``(start, end)`` of the frames kept by ``frame_selection`` (0, 128)."""
        fs = self.frame_selection or {}
        return (int(fs.get("start_inclusive", 0)), int(fs.get("end_exclusive", self.n_frames)))

    @property
    def extended_class_labels(self) -> List[str]:
        """``class_labels`` plus the evaluation-only ``未识别`` bucket (API-06 section 4)."""
        return list(self.class_labels) + [UNRECOGNIZED_LABEL]


#: The evaluation-only seventh class of the confusion matrix (API-06 section 4: the
#: 6x6 matrix is the default; a 7-class variant must put this label LAST).
UNRECOGNIZED_LABEL = "未识别"


def _load_config() -> Config:
    """Reads the SSOT into an immutable :class:`Config`.

    A missing key raises ``ACD-ART-001``; optional-but-expected keys fall back to the
    documented FF default and are recorded in :attr:`Config.raw`, so the only literals in
    this module are the ones the SSOT is allowed to omit.
    """
    if not SSOT_PATH.exists():
        raise FeatureConfigError(f"ACD-ART-001: SSOT missing at {SSOT_PATH}")
    with SSOT_PATH.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)

    required = [
        "sample_rate", "channels", "bit_depth", "preemphasis", "window", "n_fft",
        "win_length", "hop_length", "n_mels", "fmin", "fmax", "power",
        "power_to_db_ref", "top_db", "patch_samples", "raw_mel_frames", "n_frames",
        "num_classes", "class_labels", "input_shape", "normalization",
        "normalization_epsilon", "normalization_output_min", "normalization_output_max",
        "frame_selection", "operation_order", "preemphasis_boundary",
    ]
    missing = [k for k in required if k not in raw]
    if missing:
        raise FeatureConfigError(f"ACD-ART-001: SSOT is missing required keys: {missing}")

    # `power_to_db_ref` is a STRING since ADR-21 ("patch_max"), not the number 1.0, so it is
    # deliberately absent from `float_keys`: validating it as numeric would reject the frozen
    # value. The DB reference is checked as a string in `assert_frozen_invariants`.
    float_keys = ("preemphasis", "fmin", "fmax", "power", "top_db", "power_to_db_amin",
                  "target_lufs", "patch_seconds", "normalization_epsilon",
                  "normalization_output_min", "normalization_output_max")
    for k in float_keys:
        if k in raw and not isinstance(raw[k], (int, float)):
            raise FeatureConfigError(
                f"ACD-ART-001: SSOT key {k!r} must be numeric, got {type(raw[k]).__name__}"
            )
    if not isinstance(raw["power_to_db_ref"], str):
        raise FeatureConfigError(
            "ACD-ART-001: SSOT key 'power_to_db_ref' must be a string such as 'patch_max' "
            f"(ADR-21), got {type(raw['power_to_db_ref']).__name__}"
        )

    return Config(
        raw=raw,
        sample_rate=int(raw["sample_rate"]),
        channels=int(raw["channels"]),
        bit_depth=int(raw["bit_depth"]),
        preemphasis=float(raw["preemphasis"]),
        preemphasis_boundary=raw.get(
            "preemphasis_boundary",
            "continuous_stream_previous_raw_sample_or_zero_at_source_start",
        ),
        window=raw["window"],
        n_fft=int(raw["n_fft"]),
        win_length=int(raw["win_length"]),
        hop_length=int(raw["hop_length"]),
        pad_mode=raw.get("pad_mode", "constant"),
        n_mels=int(raw["n_mels"]),
        mel_htk=bool(raw.get("mel_htk", False)),
        mel_norm=raw.get("mel_norm", "slaney"),
        fmin=float(raw["fmin"]),
        fmax=float(raw["fmax"]),
        power=float(raw["power"]),
        compression=raw.get("compression", "power_to_db"),
        power_to_db_ref=str(raw["power_to_db_ref"]),
        power_to_db_amin=float(raw.get("power_to_db_amin", 1e-10)),
        top_db=float(raw["top_db"]),
        normalization=raw.get("normalization", "per_patch_minmax"),
        normalization_epsilon=float(raw.get("normalization_epsilon", 1e-08)),
        normalization_output_min=float(raw.get("normalization_output_min", 0.0)),
        normalization_output_max=float(raw.get("normalization_output_max", 1.0)),
        loudness_normalization=raw.get("loudness_normalization", "training_only"),
        target_lufs=float(raw.get("target_lufs", -23.0)),
        patch_samples=int(raw["patch_samples"]),
        patch_seconds=float(raw["patch_seconds"]),
        center=bool(raw["center"]),
        raw_mel_frames=int(raw["raw_mel_frames"]),
        n_frames=int(raw["n_frames"]),
        frame_selection=dict(raw.get("frame_selection", {})),
        operation_order=list(raw.get("operation_order", [])),
        model_internal_preprocessing=dict(raw.get("model_internal_preprocessing", {})),
        inference_hop_seconds=float(raw["inference_hop_seconds"]),
        input_shape=list(raw["input_shape"]),
        num_classes=int(raw["num_classes"]),
        class_labels=list(raw["class_labels"]),
        behavior=dict(raw.get("behavior", {})),
        voting=dict(raw.get("voting", {})),
        meal_windows=dict(raw.get("meal_windows", {})),
        health_score_weights=dict(raw.get("health_score_weights", {})),
        health_score_formula=dict(raw.get("health_score_formula", {})),
        domain=DomainConst(),
    )


CONFIG = _load_config()


def assert_frozen_invariants() -> None:
    """Cheap self-checks that catch a corrupted or half-edited SSOT early."""
    c = CONFIG
    problems = []
    # ADR-21 split the old single frame count into two, and the invariant follows: the STFT
    # still produces `patch_samples // hop_length + 1` frames, and `n_frames` is how many of
    # them survive the tail drop. Conflating them is exactly the defect ADR-21 fixed.
    raw_expected = c.patch_samples // c.hop_length + 1
    if c.raw_mel_frames != raw_expected:
        problems.append(
            f"raw_mel_frames={c.raw_mel_frames} but patch_samples//hop_length+1={raw_expected}"
        )
    start, end = c.kept_frames
    if c.frame_selection.get("strategy") != "drop_tail":
        problems.append("frame_selection.strategy must be 'drop_tail' (ADR-21)")
    if start != 0 or end != c.n_frames or end > c.raw_mel_frames:
        problems.append(
            f"frame_selection [{start}, {end}) does not drop the tail to {c.n_frames} frames "
            f"of {c.raw_mel_frames} (ADR-21)"
        )
    if c.input_shape != [1, c.n_mels, c.n_frames, 1]:
        problems.append(f"input_shape={c.input_shape} inconsistent with n_mels/n_frames")
    if len(c.class_labels) != c.num_classes:
        problems.append("class_labels length != num_classes")
    if c.win_length != c.n_fft:
        problems.append("win_length != n_fft")
    if c.pad_mode != "constant":
        problems.append("pad_mode must be 'constant' (ADR-16)")
    # ADR-21 inverted this one on purpose: FF-07's ref=1.0 was superseded by the training-side
    # patch-relative scale. If someone sets it back to a number, that is the drift to catch.
    if c.power_to_db_ref != "patch_max":
        problems.append(
            f"power_to_db ref must be 'patch_max' (ADR-21), got {c.power_to_db_ref!r}"
        )
    if c.normalization != "per_patch_minmax":
        problems.append(
            f"normalization must be 'per_patch_minmax' (ADR-21), got {c.normalization!r}"
        )
    if c.mel_htk or c.mel_norm != "slaney":
        problems.append("mel filter bank must be htk=false / norm='slaney' (ADR-16)")
    if c.preemphasis_boundary != "continuous_stream_previous_raw_sample_or_zero_at_source_start":
        problems.append(
            "preemphasis_boundary must be the streaming rule (ADR-21), got "
            f"{c.preemphasis_boundary!r}"
        )
    if c.loudness_normalization != "training_only":
        problems.append("loudness_normalization must be training_only (ADR-17)")
    if c.normalization_output_min >= c.normalization_output_max:
        problems.append(
            f"normalization output range must be increasing, got "
            f"[{c.normalization_output_min}, {c.normalization_output_max}]"
        )
    if c.normalization_epsilon <= 0:
        problems.append("normalization_epsilon must be positive")
    if c.power_to_db_amin <= 0:
        problems.append("power_to_db_amin must be positive")
    # The delivered chain has no DC stage; a stray "dc_removal" entry in operation_order would
    # mean the frozen order still describes a chain the model was not trained with.
    if "remove_dc" in c.operation_order or "dc_removal" in c.operation_order:
        problems.append("operation_order must not contain a DC-removal stage (ADR-21)")
    if c.operation_order and c.operation_order[-1] != "append_channel_axis":
        problems.append("operation_order must end with append_channel_axis (FF-14)")

    if c.sample_rate <= 0 or c.hop_length <= 0 or c.n_fft <= 0:
        problems.append("sample_rate / hop_length / n_fft must be positive")
    if c.fmax > c.sample_rate / 2:
        problems.append(f"fmax={c.fmax} exceeds the Nyquist limit {c.sample_rate / 2}")
    if c.fmin < 0 or c.fmin >= c.fmax:
        problems.append(f"fmin/fmax out of order: {c.fmin} / {c.fmax}")
    if not c.class_labels:
        problems.append("class_labels is empty")
    if len(set(c.class_labels)) != len(c.class_labels):
        problems.append("class_labels contains duplicates")
    if UNRECOGNIZED_LABEL in c.class_labels:
        problems.append(
            f"{UNRECOGNIZED_LABEL!r} is an evaluation-only label and must not be trained"
        )
    d = c.domain
    if not (d.gain_min > 0 and d.gain_max >= d.gain_min):
        problems.append("domain gain range must satisfy 0 < min <= max")
    if d.snr_db_max < d.snr_db_min:
        problems.append("domain SNR range must satisfy min <= max")
    if d.split_ratio_train + d.split_ratio_val + d.split_ratio_test_public != 1.0:
        problems.append("domain split ratios must sum to exactly 1.0")
    if not (0.0 < d.parity_label_match_min <= 1.0):
        problems.append("parity label-match threshold must be in (0, 1]")
    if d.parity_max_conf_delta_max < 0:
        problems.append("parity confidence-delta threshold must be >= 0")
    if d.int8_max_bytes <= 0 or d.fp32_max_bytes <= 0:
        problems.append("FF-16 byte caps must be positive")
    if len(d.mobile_test_subjects) < 3:
        problems.append("cross-domain testing needs at least three subjects (SPEC-T-02 2.4)")
    if set(d.mobile_test_subjects) & set(d.mobile_adapt_subjects):
        problems.append("mobile test subjects and adaptation subjects must be disjoint")
    if problems:
        raise AssertionError("ACD-ART-001: SSOT invariant violations: " + "; ".join(problems))


if __name__ == "__main__":
    assert_frozen_invariants()
    print(f"SSOT          : {SSOT_PATH}")
    print(f"ssot sha256   : {sha256_file(SSOT_PATH)}")
    print(f"raw_mel_frames: {CONFIG.raw_mel_frames} (raw STFT frames, ADR-16/ADR-P1)")
    print(f"n_frames      : {CONFIG.n_frames} (FF-11 as revised by ADR-21; tail dropped)")
    print(f"input_shape   : {CONFIG.input_shape}")
    print(f"dBreference   : {CONFIG.power_to_db_ref} (ADR-21)")
    print(f"normalization : {CONFIG.normalization} (ADR-21)")
    print(f"class_labels  : {CONFIG.class_labels}")
    print(f"melVersion    : {read_kotlin_mel_version()} (Kotlin FeatureConfig.MEL_VERSION)")
    print(f"INT8 cap      : {CONFIG.domain.int8_max_bytes} bytes (FF-16)")
    print(f"FP32 cap      : {CONFIG.domain.fp32_max_bytes} bytes (FF-16)")
    print("frozen invariants: OK")

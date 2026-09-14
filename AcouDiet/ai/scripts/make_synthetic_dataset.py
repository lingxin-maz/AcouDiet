"""T-01 -- deterministic **synthetic** stand-in for the public eating-sound corpus.

Why this file exists
--------------------
``SPEC-T-01`` section 2.2 expects the Eating Sound Collection (Ma et al. 2020) at
``ai/data/raw/esc/``. Building it needs the network, and **this environment has no network
access at all** (no ``pip install``, no dataset download, no HTTP). Rather than leaving
T-01..T-08 without any input, this script synthesises a deterministic substitute corpus with
the same *shape* as the real one, so every downstream stage (splitting, augmentation,
training, evaluation, INT8 export, parity, the delivery gate) can be built and **actually
measured** offline.

What this substitute is and is NOT
----------------------------------
* It IS: 16 kHz / mono / PCM16 wavs (FF-01), one directory per class taken from
  ``CONFIG.class_labels``, several distinct ``source_file_id`` groups per class (so the
  T-02 session-level leak assertion is not vacuous), class-dependent spectral character so a
  classifier can genuinely learn something, several sessions per subject, and a self-collected
  ``mobile/`` tree with 6 classes x 5 anonymous people x 8 segments across three capture poses.
* It is NOT: the real ESC corpus. Any accuracy number measured on it is a **pipeline proof,
  not a scientific result** -- ``ai/reports/T01_dataset.md`` repeats this warning, and the
  T-05/T-07 reports carry the same caveat. The real download path is ``--download``: it is
  implemented as required, is unusable without the network, and raises ``ACD-ART-001`` with a
  clear message when it fails. **Do not** claim Eating Sound Collection was used as training
  data while this substitute is what was actually ingested (SPEC-T-01 section 9).

Determinism
-----------
Every file is generated from ``np.random.default_rng`` seeded only by
``(base_seed, source_file_id, segment index)``, so re-running reproduces byte-identical wavs
and therefore byte-identical manifests (SPEC-T-01 section 2.3 idempotence).

Usage::

    python ai/scripts/make_synthetic_dataset.py                 # write the substitute corpus
    python ai/scripts/make_synthetic_dataset.py --force         # rebuild from scratch
    python ai/scripts/make_synthetic_dataset.py --download      # network path (expected to fail offline)
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.config import CONFIG, FeatureConfigError, paths  # noqa: E402

# --------------------------------------------------------------------------- design

#: Public-corpus sessions per class. Six classes x 260 sessions x 2 fragments = 3,120 total,
#: which satisfies **both** SPEC-T-01 section 7 criterion 2 (3,000 <= n <= 4,000 overall) and
#: criterion 12 (every class <= 1,000). Those two bounds are what pin the corpus size: with six
#: classes a 3,000-fragment floor already means 500 fragments per class, so the headroom above
#: the per-class cap is only 2x and this script deliberately stays near the floor rather than
#: "adding more because more is better" (master plan correction N-14).
#:
#: Sessions are the T-02 split unit. Keeping the fragment count uniform per session makes the
#: session ratio and the fragment ratio coincide, which is what keeps a 70/15/15 split inside
#: the +-2 pp window of SPEC-T-02 section 2.4; and sessions holding more than one fragment keep
#: the session-level leak assertion (SPEC-T-02 section 2.2 assertion A) a real constraint.
PUBLIC_GROUPS_PER_CLASS = 260
#: Fragments inside one session.
PUBLIC_FILES_PER_GROUP = 2
#: Fragments per class (x 6 classes = 3,120 total).
PUBLIC_FILES_PER_CLASS = PUBLIC_GROUPS_PER_CLASS * PUBLIC_FILES_PER_GROUP

#: Capture poses of the self-collected corpus (SPEC-T-01 section 1.2).
MOBILE_POSES = ("desk30", "handheld", "near10")

#: Noise scenes required by SPEC-T-01 section 2.2 / section 7 criterion 9.
NOISE_SCENES = ("canteen", "office", "street")
#: Files per scene and their length in seconds -- the sum must land in the 10-20 min window
#: of ``CONFIG.domain.noise_minutes_*``.
NOISE_FILES_PER_SCENE = 2
NOISE_FILE_SECONDS = 150.0

#: Default determinism seed (the same one SPEC-T-02 freezes for splitting).
BASE_SEED = CONFIG.domain.split_seed


@dataclass(frozen=True)
class SoundTexture:
    """Synthesis parameters of one food class.

    The classifier sees only the FF-08-normalised Mel tensor, and FF-08 min-max normalisation
    removes absolute level, so **class separability must come from spectral shape and
    temporal modulation** -- never from loudness. Each class therefore gets a distinct
    carrier band, burst rate, decay and spectral tilt.
    """

    #: Centre of the band the recording lives in, in Hz.
    centre_hz: float
    #: Fractional bandwidth of the band-pass shaping filter.
    bandwidth: float
    #: Chew/bite events per second.
    events_per_second: float
    #: Exponential decay time constant of one event, in milliseconds.
    decay_ms: float
    #: Per-event amplitude jitter (0 = metronomic, which would leak the class identity).
    amplitude_jitter: float
    #: Timing jitter as a fraction of the inter-event interval.
    timing_jitter: float
    #: Broadband transient exciter: called "brightness" -- wide for brittle, low for soft.
    brightness_hz: float
    #: Spectral tilt exponent: 1.0 = flat, >1 = low-frequency dominated.
    tilt: float
    #: Continuous airy component (0 for dry foods, >0 for drinks).
    airiness: float


#: Keyed by ``CONFIG.class_labels`` entry, so a label added to the SSOT fails loudly here
#: rather than silently producing an untrained class.
#:
#: ADR-19 renamed ids 1-3. `cabbage` and `noodles` take the profiles of the classes they
#: replaced (a crisp juicy vegetable; a soft low-frequency staple), because those are the
#: closest acoustic analogues and re-using them keeps the existing separability argument intact.
#: `gummies` has no predecessor with the right character -- the biscuit was *crunchy*, a gummy is
#: *chewy/elastic* -- so it gets its own profile: lower and slower events, a much longer decay,
#: and unusually high amplitude/timing jitter to stand for the irregular stick-slip of an
#: adhesive food. These numbers are synthesis placeholders for a declared-synthetic corpus, not
#: measured values; the real corpus is the trainer's.
TEXTURES = {
    # brittle, high-frequency crackle
    "chips": SoundTexture(4300.0, 0.62, 6.5, 9.0, 0.40, 0.18, 9000.0, 0.55, 0.02),
    # crisp juicy bursts with a wet low-mid body (leafy rather than fruity, but the same physics)
    "cabbage": SoundTexture(2400.0, 0.50, 4.0, 24.0, 0.35, 0.15, 7000.0, 0.85, 0.05),
    # chewy and elastic: slow, low, long decay, irregular (stick-slip) event timing
    "gummies": SoundTexture(1250.0, 0.75, 1.8, 85.0, 0.55, 0.40, 3800.0, 1.30, 0.03),
    # soft, low, few events
    "noodles": SoundTexture(900.0, 0.60, 2.4, 45.0, 0.30, 0.25, 4500.0, 1.35, 0.03),
    # sharp snappy high transient
    "carrot": SoundTexture(3300.0, 0.45, 5.0, 6.0, 0.50, 0.12, 8500.0, 0.70, 0.01),
    # liquid: sustained low-frequency bubbling, no discrete events
    "drink": SoundTexture(600.0, 0.85, 1.0, 120.0, 0.20, 0.35, 3000.0, 1.60, 0.55),
}

#: Per-class spectral/level perturbation applied to a capture pose. Poses are attributes of
#: the *person*, never a split unit (SPEC-T-02 section 2.4), so they must not change the label.
POSE_GAIN = {"desk30": 0.32, "handheld": 0.40, "near10": 0.60}
POSE_TILT = {"desk30": 1.00, "handheld": 1.12, "near10": 0.90}


# --------------------------------------------------------------------------- synthesis


def _bandpass(rng: np.random.Generator, n: int, centre: float, bandwidth: float, tilt: float) -> np.ndarray:
    """Shaped white noise: a random-phase spectral envelope around ``centre``.

    Working in the frequency domain keeps the class identity purely spectral (which is what
    survives min-max Mel normalisation) and avoids any filter-design dependency beyond numpy.
    """
    freqs = np.fft.rfftfreq(n, d=1.0 / CONFIG.sample_rate)
    log_ratio = np.log2(np.maximum(freqs, 1.0) / centre)
    env = np.exp(-0.5 * (log_ratio / max(bandwidth, 1e-6)) ** 2)
    nyq = CONFIG.sample_rate / 2.0
    env *= (np.maximum(freqs, 1.0) / nyq) ** (tilt - 1.0)
    env[0] = 0.0
    phase = rng.uniform(0.0, 2.0 * np.pi, env.shape[0])
    spec = env * np.exp(1j * phase)
    return np.fft.irfft(spec, n=n)


def _whiten(rng: np.random.Generator, length: int, brightness_hz: float) -> np.ndarray:
    """Broadband exciter, pre-whitened so its energy sits in the bright band of the class."""
    exciter = rng.normal(0.0, 1.0, length)
    return np.diff(exciter, prepend=0.0) * (brightness_hz / 8000.0)


def _event_envelope(n: int, interval: float, decay_samples: float,
                    rng: np.random.Generator, jitter: float) -> np.ndarray:
    """Exponentially decaying envelope with one event per (jittered) grid slot.

    Vectorised: the whole envelope is built at once instead of looping per event, which keeps
    corpus generation to seconds rather than minutes.
    """
    slots = int(np.ceil(n / max(interval, 1.0))) + 1
    starts = np.arange(slots, dtype=np.float64) * interval
    starts += (rng.random(slots) - 0.5) * 2.0 * jitter * interval
    starts = np.clip(np.round(starts), 0, max(n - 1, 0)).astype(np.int64)
    tail = int(max(4, np.ceil(8.0 * decay_samples)))
    shape = np.exp(-np.arange(tail, dtype=np.float64) / max(decay_samples, 1.0))
    # Drop the slots whose decay tail would run past the end of the buffer; truncating them
    # would look like an event cut in half, which is a synthesis artefact no real recording has.
    usable = starts[starts + tail <= n]
    env = np.zeros(n, dtype=np.float64)
    if usable.size:
        np.add.at(env, (usable[:, None] + np.arange(tail)[None, :]).ravel(),
                  np.broadcast_to(shape, (usable.size, tail)).ravel())
    env = np.minimum(env, 1.0)
    return env


def synth_recording(label: str, seconds: float, rng: np.random.Generator, pose: str | None = None) -> np.ndarray:
    """Synthesises one mono float32 recording for ``label`` (a whole file, not one patch).

    Returns samples in ``[-1, 1]``. The caller clips and converts to PCM16.
    """
    if label not in TEXTURES:
        raise KeyError(f"ACD-ART-001: no synthesis texture for class {label!r}")
    texture = TEXTURES[label]
    n = int(round(seconds * CONFIG.sample_rate))

    # 1) sustained spectral bed -- the "background texture" of chewing, class-specific band
    bed = _bandpass(rng, n, texture.centre_hz, texture.bandwidth, texture.tilt)
    bed /= max(float(np.max(np.abs(bed))), 1e-9)
    bed *= 0.25

    # 2) discrete bite/chew events on a jittered grid
    interval = CONFIG.sample_rate / max(texture.events_per_second, 1e-6)
    envelope = _event_envelope(
        n, interval, texture.decay_ms / 1000.0 * CONFIG.sample_rate, rng, texture.timing_jitter
    )
    events = envelope * _whiten(rng, n, texture.brightness_hz)
    peak = float(np.max(np.abs(events)))
    if peak > 0:
        events /= peak
    bed = bed * (1.0 - 0.6 * texture.airiness) + events * 0.85

    # 3) airy component for liquids (continuous, slowly modulated)
    if texture.airiness > 0:
        air = _bandpass(rng, n, texture.centre_hz * 0.6, texture.bandwidth * 1.3, texture.tilt)
        air /= max(float(np.max(np.abs(air))), 1e-9)
        mod = 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(1.5, 4.0) * np.arange(n) / CONFIG.sample_rate)
        bed += texture.airiness * air * mod

    # 4) pose: gain + tilt. Label never changes with pose.
    gain = POSE_GAIN.get(pose, 0.45) if pose else 0.45
    if pose:
        bed = _apply_tilt(bed, POSE_TILT[pose])
    bed /= max(float(np.max(np.abs(bed))), 1e-9)
    return (bed * gain).astype(np.float32)


def _apply_tilt(x: np.ndarray, tilt: float) -> np.ndarray:
    """Cheap spectral tilt via a one-pole high-frequency shelf (synthesis only)."""
    if abs(tilt - 1.0) < 1e-9:
        return x
    y = np.empty_like(x)
    a = float(np.clip((tilt - 1.0) * 0.6 + 0.5, 0.0, 0.98))
    prev = 0.0
    for i in range(x.shape[0]):
        prev = a * prev + (1.0 - a) * float(x[i])
        y[i] = prev
    higher = x - y
    return (x + (tilt - 1.0) * higher).astype(np.float32)


def clip_to_pcm16(x: np.ndarray) -> np.ndarray:
    """Float samples -> PCM16, saturated at full scale (FF-01: 16-bit)."""
    return np.clip(np.round(x.astype(np.float64) * 32767.0), -32768, 32767).astype(np.int16)


def seed_for(*parts) -> int:
    """Stable 63-bit seed derived from ``parts`` (never from Python's salted ``hash``)."""
    import hashlib

    h = hashlib.sha256(repr(parts).encode("utf-8")).digest()
    return int.from_bytes(h[:8], "big") % (2 ** 63 - 1)


# --------------------------------------------------------------------------- public


def public_file_ids(label: str) -> list[tuple[str, int, int]]:
    """Deterministic ``(source_file_id, group_index, file_index)`` list for one class.

    ``source_file_id`` is the T-02 split key (filename stem, no extension). The encoding is
    ``esc_<label>_s<group:04d>_<file:02d>``: several fragments share the ``s<group>`` prefix, so
    the session-level leak assertion of SPEC-T-02 section 2.2 assertion A is a real constraint
    rather than a tautology. The group count is sized from ``PUBLIC_FILES_PER_CLASS`` and never
    truncated, so no two sessions can collide onto the same id.
    """
    per_group = PUBLIC_FILES_PER_GROUP
    n_groups = max(1, PUBLIC_FILES_PER_CLASS // per_group)
    out: list[tuple[str, int, int]] = []
    for g in range(n_groups):
        for k in range(per_group):
            out.append((f"esc_{label}_s{g:04d}_{k:02d}", g, k))
    return out


def write_public_corpus(root: Path, force: bool) -> int:
    """Writes ``ai/data/raw/public/<class>/<source_file_id>.wav``; returns the file count."""
    import soundfile as sf

    if root.exists() and force:
        shutil.rmtree(root)
    written = 0
    for label in CONFIG.class_labels:
        class_dir = root / label
        class_dir.mkdir(parents=True, exist_ok=True)
        for fid, g, k in public_file_ids(label):
            path = class_dir / f"{fid}.wav"
            if path.exists() and not force:
                written += 1
                continue
            rng = np.random.default_rng(seed_for(BASE_SEED, "public", label, fid))
            # 4.096 s .. ~8.2 s: every fragment is at least one patch (FF-09) and none
            # exceeds the LONG_FILE threshold of SPEC-T-01 section 2.4.
            seconds = CONFIG.patch_seconds * (1.0 + 0.25 * (k % 4))
            audio = synth_recording(label, seconds, rng, pose=None)
            sf.write(str(path), clip_to_pcm16(audio), CONFIG.sample_rate, subtype="PCM_16")
            written += 1
    return written


# --------------------------------------------------------------------------- mobile


def mobile_file_specs() -> list[tuple[str, str, str, int]]:
    """``(subject_id, label, pose, seq)`` for the whole self-collected corpus.

    6 classes x 5 people x 8 segments = 240 segments (SPEC-T-01 section 1.2). Poses are
    assigned so every person/class pair covers all three poses at least twice, satisfying
    ``collect_check`` (``POSE_MIN``) and the deliberate scale gate of SPEC-T-02 section 2.4
    (``test_mobile`` must hold exactly 3 people x 6 classes x 8 segments = 144 rows).
    """
    per_class = CONFIG.domain.mobile_segments_per_class
    if per_class != len(MOBILE_POSES) * 2 + 2:  # 8 = 3 + 3 + 2
        raise AssertionError(
            "ACD-ART-001: mobile pose coverage assumes 8 segments split 3/3/2 across poses"
        )
    specs: list[tuple[str, str, str, int]] = []
    for person in range(1, CONFIG.domain.mobile_people + 1):
        subject = f"P{person:02d}"
        for label in CONFIG.class_labels:
            pose_cycle = [
                MOBILE_POSES[0], MOBILE_POSES[1], MOBILE_POSES[2],
                MOBILE_POSES[0], MOBILE_POSES[1], MOBILE_POSES[2],
                MOBILE_POSES[1], MOBILE_POSES[0],
            ]
            for seq in range(per_class):
                specs.append((subject, label, pose_cycle[seq], seq))
    return specs


def write_mobile_corpus(root: Path, force: bool) -> int:
    """Writes ``ai/data/raw/mobile/P0x_<class>_<pose>_<seq>.wav`` (SPEC-T-01 section 2.1)."""
    import soundfile as sf

    if root.exists() and force:
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    written = 0
    for subject, label, pose, seq in mobile_file_specs():
        path = root / f"{subject}_{label}_{pose}_{seq:02d}.wav"
        if path.exists() and not force:
            written += 1
            continue
        rng = np.random.default_rng(seed_for(BASE_SEED, "mobile", subject, label, pose, seq))
        seconds = CONFIG.patch_seconds * (1.25 + 0.05 * seq)
        audio = synth_recording(label, seconds, rng, pose=pose)
        sf.write(str(path), clip_to_pcm16(audio), CONFIG.sample_rate, subtype="PCM_16")
        written += 1
    return written


# --------------------------------------------------------------------------- noise


def write_noise_bank(root: Path, force: bool) -> int:
    """Writes the self-collected **environmental noise** library used by T-03.

    Shape and total duration follow SPEC-T-01 section 2.2 item 5 / section 7 criterion 9:
    three scenes, 10-20 minutes in total, 16 kHz mono PCM16. Like the corpus above, this is
    the offline substitute for a real recording session.
    """
    import soundfile as sf

    if root.exists() and force:
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)

    scene_centre = {"canteen": 700.0, "office": 1400.0, "street": 300.0}
    written = 0
    for scene in NOISE_SCENES:
        for idx in range(NOISE_FILES_PER_SCENE):
            name = scene if NOISE_FILES_PER_SCENE == 1 else f"{scene}_{idx + 1:02d}"
            path = root / f"{name}.wav"
            if path.exists() and not force:
                written += 1
                continue
            rng = np.random.default_rng(seed_for(BASE_SEED, "noise", scene, idx))
            n = int(round(NOISE_FILE_SECONDS * CONFIG.sample_rate))
            x = _bandpass(rng, n, scene_centre[scene], 1.10, 1.20)
            x /= max(float(np.max(np.abs(x))), 1e-9)
            # Slow loudness drift so the bank is not a stationary hiss (the models of T-05
            # compare cross-domain behaviour, and a stationary noise floor is too easy).
            drift = 1.0 + 0.35 * np.sin(
                2 * np.pi * 0.05 * np.arange(n) / CONFIG.sample_rate + idx
            )
            x = x * drift * 0.35
            sf.write(str(path), clip_to_pcm16(x), CONFIG.sample_rate, subtype="PCM_16")
            written += 1
    return written


# --------------------------------------------------------------------------- network path


def download_public_corpus(dest: Path) -> None:
    """The **real** T-01 acquisition path -- implemented, and unusable in this environment.

    SPEC-T-01 section 1.2 requires acquiring the Eating Sound Collection (Ma et al. 2020).
    There is no network here, so this function exists to document the real route and to fail
    with the contract's error code and a clear message instead of silently doing nothing.
    """
    raise FeatureConfigError(
        "ACD-ART-001: cannot acquire the real public corpus: this offline environment has no "
        "network access (pip / HTTP / dataset download all fail). Use the synthetic substitute "
        "(`make_synthetic_dataset.py` without --download) and record in every report that the "
        "numbers are a pipeline proof, NOT Eating Sound Collection results. Real path: place the "
        f"ESC tree under {dest} as one directory per class."
    )


# --------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="delete and rebuild existing wavs")
    ap.add_argument("--download", action="store_true",
                    help="attempt the real ESC download (requires network; fails offline with ACD-ART-001)")
    ap.add_argument("--skip-noise", action="store_true", help="do not build the noise bank")
    args = ap.parse_args(argv)

    paths.ensure()

    if args.download:
        try:
            download_public_corpus(paths.raw_public)
        except FeatureConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        return 0

    missing = [lbl for lbl in CONFIG.class_labels if lbl not in TEXTURES]
    if missing:
        print(f"ACD-ART-001: no synthesis texture for {missing}", file=sys.stderr)
        return 1

    print("=" * 78)
    print("T-01 synthetic corpus (offline substitute for the Eating Sound Collection)")
    print(f"  classes        : {CONFIG.class_labels}")
    print(f"  sample rate    : {CONFIG.sample_rate} Hz mono PCM16 (FF-01)")
    print(f"  public target  : {PUBLIC_GROUPS_PER_CLASS} sessions x "
          f"{PUBLIC_FILES_PER_GROUP} fragments x {len(CONFIG.class_labels)} classes = "
          f"{PUBLIC_FILES_PER_CLASS * len(CONFIG.class_labels)} fragments "
          f"({PUBLIC_FILES_PER_CLASS}/class, cap 1,000)")
    print(f"  mobile         : 6 classes x {CONFIG.domain.mobile_people} people x "
          f"{CONFIG.domain.mobile_segments_per_class} segments = "
          f"{6 * CONFIG.domain.mobile_people * CONFIG.domain.mobile_segments_per_class}")
    print("=" * 78)

    n_public = write_public_corpus(paths.raw_public, args.force)
    print(f"public : {n_public} wavs under {paths.raw_public}")

    n_mobile = write_mobile_corpus(paths.raw_mobile, args.force)
    print(f"mobile : {n_mobile} wavs under {paths.raw_mobile}")

    n_noise = 0
    if not args.skip_noise:
        noise_dir = paths.data / "noise"
        n_noise = write_noise_bank(noise_dir, args.force)
        minutes = n_noise * NOISE_FILE_SECONDS / 60.0
        print(f"noise  : {n_noise} wavs under {noise_dir} ({minutes:.1f} min, "
              f"scenes={len(NOISE_SCENES)})")

    meta = {
        "substitute": True,
        "reason": "offline environment: no network for the real Eating Sound Collection",
        "generator": "ai/scripts/make_synthetic_dataset.py",
        "seed": BASE_SEED,
        "sampleRate": CONFIG.sample_rate,
        "classLabels": CONFIG.class_labels,
        "publicFragments": n_public,
        "mobileFragments": n_mobile,
        "noiseFragments": n_noise,
        "textures": {
            k: {
                "centreHz": v.centre_hz, "bandwidth": v.bandwidth,
                "eventsPerSecond": v.events_per_second, "decayMs": v.decay_ms,
            }
            for k, v in TEXTURES.items()
        },
    }
    (paths.raw_public / "_GENERATED.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"\nwrote {paths.raw_public / '_GENERATED.json'}")
    print("WARNING: this is a synthetic substitute -- never report its numbers as ESC results.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""T-01 dataset discovery/cleaning and T-02 splitting with the six leak assertions.

This module is the single input stage of the whole offline toolchain: everything downstream
(T-03 augmentation, T-04 training, T-05 evaluation, T-07 calibration) consumes the four CSVs
it writes, so a mistake here silently invalidates every reported number.

Two responsibilities, two stages
--------------------------------
``--stage ingest`` (T-01)
    Walk ``ai/data/raw/{public,mobile}``, map directories to ``CONFIG.class_labels``, probe
    only the audio **headers** (``soundfile.info``, never a full decode), apply the reject
    rules of SPEC-T-01 section 2.2 and emit ``ai/data/raw/ingest_manifest.csv`` plus the
    audit list ``ai/data/raw/rejects.csv``. The manifest is the *only* input of T-02.

``--stage split`` (T-02)
    Split by ``source_file_id`` (public: 70/15/15) and by ``subject_id`` (mobile: ``P01``-
    ``P03`` are cross-domain test only, ``P04``/``P05`` are adaptation-only validation rows),
    write the four CSVs of API-06 section 3.1 and run the **six leak assertions** of API-06
    section 3.3. A leak exits non-zero with ``ACD-ART-002`` on the first line of stderr.

Why the assertions are not optional
-----------------------------------
SPEC-T-02 section 9 states it explicitly: this feature "must not be cut". A leaked test set
does not produce a wrong number, it produces a number that means nothing -- the T-05 report
would be academically dishonest rather than merely inaccurate. So the assertions run on every
invocation and there is no flag that turns them off.

Four forbidden behaviours (API-06 section 3.2, repeated here for the review checklist):
  (1) fragments of one eating session must not straddle subsets,
  (2) fragments of one person must not straddle subsets,
  (3) no test set may take part in any augmentation,
  (4) hyper-parameters must never be tuned on a test set.

Usage::

    python ai/src/dataset.py --stage ingest [--strict]
    python ai/src/dataset.py --stage split --assert-leakage [--seed 20260910]
    python ai/src/dataset.py --stage check-noise
    python ai/src/dataset.py --stage collect-check
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import random
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

if __package__ in (None, ""):  # executed as a script: ``python ai/src/dataset.py --stage ...``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG, DomainConst, paths, sha256_bytes, sha256_file
else:  # imported as ``src.dataset``
    from .config import CONFIG, DomainConst, paths, sha256_bytes, sha256_file

__all__ = [
    "SPLIT_COLUMNS", "MANIFEST_COLUMNS", "REJECT_COLUMNS", "SPLITS",
    "DatasetContractError", "LeakageError", "RejectReason",
    "probe_audio", "classify_reject", "build_manifest", "write_manifest",
    "read_manifest", "group_id_of", "mobile_pose_coverage",
    "build_splits", "write_splits", "read_splits", "assert_no_leakage",
    "split_sha256", "print_split_stats",
]

#: Column names and order of the four split CSVs -- frozen by API-06 section 3.1. The order
#: here *is* the contract: the acceptance test compares the header row element by element.
SPLIT_COLUMNS: Tuple[str, ...] = ("path", "label", "subject_id", "source_file_id", "split")

#: The four split names. ``test_public`` is the master plan's ``test_domain`` (SPEC-T-02 1.2).
SPLITS: Tuple[str, ...] = ("train", "val", "test_public", "test_mobile")

#: Extra columns of the ingest manifest. These live only under ``ai/data/raw/`` and never
#: reach the split CSVs (SPEC-T-01 section 10.2).
MANIFEST_COLUMNS: Tuple[str, ...] = SPLIT_COLUMNS + (
    "source", "duration_s", "sample_rate", "pose",
)

#: Audit columns of the reject list (SPEC-T-01 section 3).
REJECT_COLUMNS: Tuple[str, ...] = ("path", "reject_reason")


class DatasetContractError(RuntimeError):
    """Input/output violates a dataset contract (``ACD-ART-001``)."""


class LeakageError(RuntimeError):
    """A split leaked (``ACD-ART-002``, API-06 section 3.3). Never caught, never downgraded."""


# --------------------------------------------------------------------------- reject rules


class RejectReason:
    """The closed set of reject reasons of SPEC-T-01 section 2.2 (steps 4-6)."""

    SR_MISMATCH = "SR_MISMATCH"
    TOO_SHORT = "TOO_SHORT"
    CLASS_OUT_OF_SCOPE = "CLASS_OUT_OF_SCOPE"
    SILENT = "SILENT"
    CLIPPED = "CLIPPED"
    DECODE_FAILED = "DECODE_FAILED"
    EMPTY = "EMPTY"
    DUPLICATE_ID = "WARN_DUP_ID"


@dataclass(frozen=True)
class AudioInfo:
    """What the ingest stage needs to know about one candidate file (header probe only)."""

    path: Path
    sample_rate: int
    channels: int
    bits: int
    frames: int

    @property
    def duration_s(self) -> float:
        return self.frames / float(self.sample_rate) if self.sample_rate else 0.0


def probe_audio(path: Path) -> AudioInfo:
    """Reads *only* the wav header (SPEC-T-01 section 2.2 step 3, non-functional constraint)."""
    import soundfile as sf

    try:
        info = sf.info(str(path))
    except Exception as exc:  # noqa: BLE001 - any decoder failure is a rejected sample
        raise DatasetContractError(f"ACD-ART-001: cannot read header of {path}: {exc}") from exc
    return AudioInfo(
        path=path,
        sample_rate=int(info.samplerate),
        channels=int(info.channels),
        bits=_subtype_bits(info.subtype),
        frames=int(info.frames),
    )


def _subtype_bits(subtype: str) -> int:
    return {"PCM_16": 16, "PCM_24": 24, "PCM_32": 32, "FLOAT": 32, "DOUBLE": 64}.get(subtype, 0)


def _float_stats(path: Path, d: DomainConst) -> Tuple[float, float]:
    """Returns ``(rms, clipped_fraction)`` for a file, in the int16 full-scale domain."""
    import soundfile as sf

    data, sr = sf.read(str(path), dtype="int16", always_2d=True)
    if sr != CONFIG.sample_rate:
        raise DatasetContractError(f"ACD-ART-001: {path} changed rate during full read")
    x = data[:, 0].astype(np.float64) / 32768.0
    if x.size == 0:
        return 0.0, 0.0
    rms = float(np.sqrt(np.mean(x * x)))
    clipped = float(np.mean(np.abs(x) >= d.clip_abs))
    return rms, clipped


def classify_reject(label: str, info: AudioInfo, d: DomainConst,
                    full_stats: bool = True) -> str:
    """Applies SPEC-T-01 section 2.2 steps 4-6; returns ``""`` when the file is usable."""
    if label not in CONFIG.class_labels:
        return RejectReason.CLASS_OUT_OF_SCOPE
    if info.frames <= 0:
        return RejectReason.EMPTY
    if info.sample_rate != CONFIG.sample_rate:
        # Never resample implicitly: a resampler-version difference would poison the T-08
        # alignment baseline (SPEC-T-01 section 6).
        return RejectReason.SR_MISMATCH
    if info.channels != CONFIG.channels:
        return RejectReason.SR_MISMATCH
    if info.duration_s < CONFIG.patch_seconds:
        return RejectReason.TOO_SHORT
    if full_stats:
        rms, clipped = _float_stats(info.path, d)
        if rms < d.silence_rms:
            return RejectReason.SILENT
        if clipped > d.clip_fraction:
            return RejectReason.CLIPPED
    return ""


# --------------------------------------------------------------------------- ingest


def _pose_of(stem: str) -> str:
    """Extracts the capture pose from a self-collected filename (SPEC-T-01 section 2.1)."""
    for pose in ("desk30", "handheld", "near10"):
        if f"_{pose}_" in stem:
            return pose
    return ""


def _subject_of(stem: str) -> str:
    """Extracts the anonymous participant id ``P0x`` from a self-collected filename."""
    head = stem.split("_", 1)[0]
    if len(head) == 3 and head[0] == "P" and head[1:].isdigit():
        return head
    return ""


def discover(root: Path, source: str, subject_from_name: bool) -> List[dict]:
    """Lists candidate files under ``root`` with their ``label``/``subject_id``/``pose``.

    Layout follows SPEC-T-01 section 2.1: one directory per class on the public side, and
    ``P0x_<class>_<pose>_<seq>.wav`` flat files on the self-collected side.
    """
    rows: List[dict] = []
    if not root.exists():
        return rows
    if subject_from_name:
        candidates = sorted(p for p in root.rglob("*.wav"))
        for p in candidates:
            stem = p.stem
            subject = _subject_of(stem)
            pose = _pose_of(stem)
            label = ""
            for lbl in CONFIG.class_labels:
                if f"_{lbl}_" in f"_{stem}_":
                    label = lbl
                    break
            if not label:
                # Fall back to the containing directory name if present.
                label = p.parent.name if p.parent != root else ""
            rows.append({"path": p, "label": label, "subject_id": subject,
                         "source_file_id": stem, "pose": pose, "source": source})
    else:
        for class_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            label = class_dir.name
            for p in sorted(class_dir.rglob("*.wav")):
                rows.append({"path": p, "label": label, "subject_id": "",
                             "source_file_id": p.stem, "pose": "", "source": source})
    return rows


def build_manifest(raw_public: Optional[Path] = None,
                   raw_mobile: Optional[Path] = None,
                   full_stats: bool = True) -> Tuple[List[dict], List[dict]]:
    """Produces ``(manifest_rows, rejects)`` for both sources (SPEC-T-01 section 2.2).

    Determinism: rows are sorted by ``(source, label, source_file_id)`` and written with
    ``utf-8`` + ``\\n``, so re-running over the same tree yields byte-identical output
    (criterion 11 idempotence).
    """
    d = CONFIG.domain
    pub_root = Path(raw_public) if raw_public else paths.raw_public
    mob_root = Path(raw_mobile) if raw_mobile else paths.raw_mobile

    manifest: List[dict] = []
    rejects: List[dict] = []
    seen_ids: Dict[str, str] = {}
    skipped_classes: Counter = Counter()

    for source, root, from_name in (("esc", pub_root, False), ("mobile", mob_root, True)):
        for row in discover(root, source, from_name):
            rel = _relpath(row["path"])
            label = row["label"]
            if label not in CONFIG.class_labels:
                skipped_classes[label or "<none>"] += 1
                rejects.append({"path": rel, "reject_reason": RejectReason.CLASS_OUT_OF_SCOPE})
                continue
            try:
                info = probe_audio(row["path"])
            except DatasetContractError:
                rejects.append({"path": rel, "reject_reason": RejectReason.DECODE_FAILED})
                continue
            reason = classify_reject(label, info, d, full_stats=full_stats)
            if reason:
                rejects.append({"path": rel, "reject_reason": reason})
                continue
            fid = row["source_file_id"]
            if fid in seen_ids:
                rejects.append({"path": rel, "reject_reason": RejectReason.DUPLICATE_ID})
                continue
            seen_ids[fid] = rel
            manifest.append({
                "path": rel,
                "label": label,
                "subject_id": row["subject_id"],
                "source_file_id": fid,
                "split": "",
                "source": source,
                "duration_s": round(info.duration_s, 4),
                "sample_rate": info.sample_rate,
                "pose": row["pose"],
            })

    manifest.sort(key=lambda r: (r["source"], r["label"], r["source_file_id"]))
    rejects.sort(key=lambda r: (r["path"], r["reject_reason"]))
    if skipped_classes:
        print(f"  skipped out-of-scope classes: {dict(skipped_classes)}")
    return manifest, rejects


def _relpath(p: Path) -> str:
    """Path relative to the workspace root with POSIX separators (API-06 section 3.1).

    Assertion 1 (``path`` disjointness across splits) compares strings, so the separator must
    be canonical: a backslash in one file and a slash in another would make the comparison
    silently useless (SPEC-T-02 section 4).
    """
    p = Path(p).resolve()
    try:
        return p.relative_to(paths.workspace).as_posix()
    except ValueError:
        return p.as_posix()


def _write_csv(path: Path, columns: Sequence[str], rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        w = csv.DictWriter(fh, fieldnames=list(columns), lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in columns})


def write_manifest(manifest: List[dict], rejects: List[dict],
                   manifest_path: Optional[Path] = None,
                   rejects_path: Optional[Path] = None) -> Tuple[Path, Path]:
    """Writes the ingest and reject lists; returns their paths."""
    mp = Path(manifest_path) if manifest_path else paths.data / "raw" / "ingest_manifest.csv"
    rp = Path(rejects_path) if rejects_path else paths.data / "raw" / "rejects.csv"
    _write_csv(mp, MANIFEST_COLUMNS, manifest)
    _write_csv(rp, REJECT_COLUMNS, rejects)
    return mp, rp


def read_manifest(path: Optional[Path] = None) -> List[dict]:
    """Reads the ingest manifest, asserting the column contract of SPEC-T-01 section 4."""
    mp = Path(path) if path else paths.data / "raw" / "ingest_manifest.csv"
    if not mp.exists():
        raise DatasetContractError(f"ACD-ART-001: ingest manifest missing at {mp}; run --stage ingest")
    rows = _read_csv(mp)
    if not rows:
        raise DatasetContractError(f"ACD-ART-001: ingest manifest is empty: {mp}")
    missing = [c for c in MANIFEST_COLUMNS if c not in rows[0]]
    if missing:
        raise DatasetContractError(f"ACD-ART-001: manifest is missing columns {missing}")
    return rows


def _read_csv(path: Path) -> List[dict]:
    with path.open("r", encoding="utf-8", newline="") as fh:
        return [dict(r) for r in csv.DictReader(fh)]


# --------------------------------------------------------------------------- checks


def collect_check(mobile_rows: Sequence[dict]) -> Tuple[bool, List[str]]:
    """Validates the self-collected corpus shape and pose coverage (SPEC-T-01 section 7 #8).

    Returns ``(ok, problems)``; the CLI maps a failure to ``exit 4`` as the SPEC requires.
    """
    d = CONFIG.domain
    problems: List[str] = []
    subjects = sorted({r["subject_id"] for r in mobile_rows if r["subject_id"]})
    if len(subjects) < d.mobile_people:
        problems.append(
            f"people={len(subjects)} < required {d.mobile_people}: self-collected data must be "
            "completed, the public corpus may not stand in for it (SPEC-T-01 section 2.4)"
        )
    per_person_class: Counter = Counter((r["subject_id"], r["label"]) for r in mobile_rows)
    for subject in subjects:
        for label in CONFIG.class_labels:
            n = per_person_class.get((subject, label), 0)
            if n < d.mobile_segments_per_class:
                problems.append(
                    f"{subject}/{label}: {n} segments < required {d.mobile_segments_per_class}"
                )
    for subject in subjects:
        for label in CONFIG.class_labels:
            poses = Counter(r["pose"] for r in mobile_rows
                            if r["subject_id"] == subject and r["label"] == label)
            for pose in ("desk30", "handheld", "near10"):
                if poses.get(pose, 0) < d.mobile_pose_min:
                    problems.append(
                        f"{subject}/{label}/{pose}: {poses.get(pose, 0)} < {d.mobile_pose_min}"
                    )
    total = len(mobile_rows)
    expected = (len(CONFIG.class_labels) * d.mobile_people * d.mobile_segments_per_class)
    if total != expected:
        problems.append(f"total segments {total} != {expected}")
    return (not problems), problems


def mobile_pose_coverage(mobile_rows: Sequence[dict]) -> str:
    """Renders the 5x6 coverage matrix required on stdout by SPEC-T-01 section 7 #8."""
    subjects = sorted({r["subject_id"] for r in mobile_rows if r["subject_id"]})
    counts = Counter((r["subject_id"], r["label"]) for r in mobile_rows)
    header = "subject|" + "|".join(f"{lbl:>7s}" for lbl in CONFIG.class_labels)
    lines = [header]
    for s in subjects:
        lines.append(f"{s:>7s}|" + "|".join(f"{counts.get((s, lbl), 0):7d}" for lbl in CONFIG.class_labels))
    return "\n".join(lines)


def check_noise_bank(noise_dir: Optional[Path] = None) -> Tuple[bool, List[str], float, int]:
    """Validates the noise library: total minutes in range, every scene present.

    Returns ``(ok, problems, total_minutes, scene_count)``. A shortage is ``exit 5``
    (SPEC-T-01 section 2.4); an excess only warns, and white noise is never a substitute.
    """
    d = CONFIG.domain
    root = Path(noise_dir) if noise_dir else paths.data / "noise"
    problems: List[str] = []
    warnings: List[str] = []
    total_s = 0.0
    scenes = set()
    if not root.exists():
        return False, [f"noise directory missing: {root}"], 0.0, 0
    for p in sorted(root.glob("*.wav")):
        try:
            info = probe_audio(p)
        except DatasetContractError as exc:
            problems.append(str(exc))
            continue
        if info.sample_rate != CONFIG.sample_rate or info.channels != CONFIG.channels:
            problems.append(
                f"{p.name}: must be {CONFIG.sample_rate} Hz mono PCM16 (FF-01)"
            )
        total_s += info.duration_s
        scenes.add(p.stem.split("_")[0])
    minutes = total_s / 60.0
    if minutes < d.noise_minutes_min:
        problems.append(
            f"noise_minutes={minutes:.1f} < {d.noise_minutes_min} (not enough; white noise "
            "must not be used as a substitute -- SPEC-T-01 section 6)"
        )
    if minutes > d.noise_minutes_max:
        warnings.append(f"noise_minutes={minutes:.1f} > {d.noise_minutes_max} (warning only)")
    if len(scenes) < d.noise_scene_count:
        problems.append(f"scenes={len(scenes)} < {d.noise_scene_count}: {sorted(scenes)}")
    for w in warnings:
        print(f"  WARN {w}")
    return (not problems), problems, minutes, len(scenes)


# --------------------------------------------------------------------------- splitting


def group_id_of(row: dict) -> str:
    """Derives the T-02 split unit (SPEC-T-02 section 2.2 step 2).

    Public rows share a ``group_id`` when several fragments come from one recording session;
    the synthetic substitute encodes this as ``esc_<label>_s<NNNN>_<kk>``. Self-collected
    rows use the participant as the group, because a person is the split unit there.
    """
    if row.get("source") == "mobile":
        return row.get("subject_id") or row["source_file_id"]
    fid = row["source_file_id"]
    parts = fid.split("_")
    if len(parts) >= 3 and parts[0] == "esc":
        return "_".join(parts[:3])
    # Real ESC trees often have no explicit session marker; SPEC-T-02 section 10.3 says the
    # group then degrades to the file itself, which must be reported, not silently ignored.
    return fid


def _stable_seed(seed: int, tag: str) -> int:
    """Derives a reproducible sub-seed. ``hash()`` is salted per process, so never use it."""
    digest = hashlib.sha256(f"{seed}:{tag}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def build_splits(manifest: Sequence[dict], seed: Optional[int] = None,
                 allow_group_equals_file: bool = False) -> List[dict]:
    """Assigns every manifest row to one of the four splits (SPEC-T-02 section 2.2).

    Public rows are grouped by ``group_id`` and split 70/15/15 by **group count**, then written
    per ``source_file_id`` (all fragments of a session move together). Mobile rows go to
    ``test_mobile`` for ``P01``-``P03`` and to ``val`` (as adaptation rows) for ``P04``/``P05``.
    """
    d = CONFIG.domain
    s = d.split_seed if seed is None else int(seed)
    public = [r for r in manifest if r.get("source") == "esc"]
    mobile = [r for r in manifest if r.get("source") == "mobile"]

    groups: Dict[str, List[dict]] = defaultdict(list)
    for r in public:
        groups[group_id_of(r)].append(r)

    degenerate = [g for g, rs in groups.items() if len(rs) == 1]
    if degenerate and not allow_group_equals_file:
        # SPEC-T-02 section 10.3 / section 6: if the session granularity cannot be determined,
        # assertion A degenerates into "no file straddles a split". Proceed, but never silently.
        print(
            f"  WARN group_id == source_file_id for {len(degenerate)} of {len(groups)} public "
            "groups: assertion A degenerates to file-level disjointness for those groups. "
            "Report this in T-05 (SPEC-T-02 section 10.3).",
            file=sys.stderr,
        )

    # Assignment is computed **per class** (stratified) and within a class the group order is
    # shuffled deterministically. A single global shuffle would satisfy the global ratio while
    # leaving a class with zero fragments in ``val`` or ``test_public`` -- exactly the failure
    # mode SPEC-T-02 section 2.4 wants a non-zero exit for. Sorting the seed input by class is
    # also what makes the realised share robust to group size imbalance.
    by_class: Dict[str, List[str]] = defaultdict(list)
    for g in sorted(groups):
        labels = {r["label"] for r in groups[g]}
        if len(labels) != 1:
            raise DatasetContractError(
                f"ACD-ART-002: group {g!r} mixes labels {sorted(labels)}; a session must be one class"
            )
        by_class[labels.pop()].append(g)

    rng = random.Random(_stable_seed(s, "public-shuffle"))
    assignment: Dict[str, str] = {}
    for label in sorted(by_class):
        gids = list(by_class[label])
        rng.shuffle(gids)
        n = len(gids)
        if n == 0:
            raise DatasetContractError("ACD-ART-002: no public rows to split")
        cut_train = int(n * d.split_ratio_train)
        cut_val = int(n * (d.split_ratio_train + d.split_ratio_val))
        # A class with too few sessions cannot fill three subsets at the target ratio, so the
        # cuts are nudged to leave at least one session in each. This is a per-class floor, NOT
        # a global re-balance: clamping every class would push the realised ratio of a large
        # corpus out of the +-2 pp window of SPEC-T-02 section 2.4 (measured: 0.624/0.242/0.134).
        if n >= 3:
            if cut_train < 1:
                cut_train = 1
            if cut_val > n - 1:
                cut_val = n - 1
            if cut_val <= cut_train:
                cut_val = cut_train + 1
        for i, g in enumerate(gids):
            assignment[g] = ("train" if i < cut_train
                             else "val" if i < cut_val else "test_public")

    rows: List[dict] = []
    for g in sorted(assignment):
        for r in groups[g]:
            rows.append({**r, "split": assignment[g]})

    for r in mobile:
        subject = r["subject_id"]
        if not subject:
            raise DatasetContractError(
                f"ACD-ART-002: self-collected row without subject_id: {r['path']}"
            )
        if subject in d.mobile_test_subjects:
            split = "test_mobile"
        elif subject in d.mobile_adapt_subjects:
            # API-06 section 3.2: P04/P05 are validation-only and must never enter train.csv.
            # ``split`` stays "val" (no ``mobile_val`` enum exists) and consumers tell the two
            # kinds of validation row apart by ``subject_id`` (SPEC-T-02 section 4).
            split = "val"
        else:
            raise DatasetContractError(
                f"ACD-ART-002: subject {subject!r} is neither a test subject "
                f"{d.mobile_test_subjects} nor an adaptation subject {d.mobile_adapt_subjects}"
            )
        rows.append({**r, "split": split})

    rows.sort(key=lambda r: (r["split"], r["label"], r["subject_id"], r["source_file_id"]))
    return rows


def write_splits(rows: Sequence[dict], out_dir: Optional[Path] = None) -> Dict[str, Path]:
    """Writes the four split CSVs with exactly the columns of API-06 section 3.1."""
    out = Path(out_dir) if out_dir else paths.splits
    out.mkdir(parents=True, exist_ok=True)
    written: Dict[str, Path] = {}
    for split in SPLITS:
        subset = [r for r in rows if r["split"] == split]
        path = out / f"{split}.csv"
        _write_csv(path, SPLIT_COLUMNS, subset)
        written[split] = path
    return written


def read_splits(out_dir: Optional[Path] = None) -> Dict[str, List[dict]]:
    """Reads the four split CSVs, asserting the column contract on every one of them."""
    out = Path(out_dir) if out_dir else paths.splits
    data: Dict[str, List[dict]] = {}
    for split in SPLITS:
        path = out / f"{split}.csv"
        if not path.exists():
            raise DatasetContractError(f"ACD-ART-001: split file missing: {path}")
        rows = _read_csv(path)
        if rows:
            header = tuple(rows[0].keys())
            if header != SPLIT_COLUMNS:
                raise DatasetContractError(
                    f"ACD-ART-001: {path.name} columns {header} != {SPLIT_COLUMNS}"
                )
        data[split] = rows
    return data


# --------------------------------------------------------------------------- assertions


def assert_no_leakage(data: Dict[str, List[dict]]) -> None:
    """The six leak assertions of API-06 section 3.3. Raises :class:`LeakageError`.

    Each assertion prints an ``ASSERT_OK``/``ASSERT_FAIL`` line so the acceptance command of
    SPEC-T-02 section 7 criterion 3 can grep for its four legacy ``ASSERT_OK A|B|C|D`` labels
    *and* the API-06 numbering.
    """
    d = CONFIG.domain
    problems: List[str] = []

    def paths_of(split: str) -> set:
        return {r["path"] for r in data.get(split, [])}

    def subjects_of(split: str) -> set:
        return {r["subject_id"] for r in data.get(split, []) if r["subject_id"]}

    def fileids_of(split: str) -> set:
        return {r["source_file_id"] for r in data.get(split, [])}

    # ---- API-06 3.3 #1: the four path sets are pairwise disjoint.
    pair_problems = []
    for i, a in enumerate(SPLITS):
        for b in SPLITS[i + 1:]:
            inter = paths_of(a) & paths_of(b)
            if inter:
                pair_problems.append(f"{a}n{b}={len(inter)} (e.g. {sorted(inter)[:3]})")
    _emit(1, not pair_problems, pair_problems, problems, tag="A")

    # ---- API-06 3.3 #2: test_mobile subjects subset of {P01,P02,P03} and disjoint from train/val.
    tm = subjects_of("test_mobile")
    extra = tm - set(d.mobile_test_subjects)
    overlap = tm & (subjects_of("train") | subjects_of("val"))
    p2 = []
    if extra:
        p2.append(f"test_mobile has unexpected subjects {sorted(extra)}")
    if overlap:
        p2.append(f"test_mobile subjects also in train/val: {sorted(overlap)}")
    _emit(2, not p2, p2, problems, tag="B")

    # ---- API-06 3.3 #3: train and val subject sets are disjoint; P04/P05 only in val.
    tv = subjects_of("train") & subjects_of("val")
    p3 = []
    if tv:
        p3.append(f"subjects in both train and val: {sorted(tv)}")
    bad_adapt = subjects_of("train") & set(d.mobile_adapt_subjects)
    if bad_adapt:
        p3.append(f"adaptation subjects leaked into train.csv: {sorted(bad_adapt)}")
    _emit(3, not p3, p3, problems, tag="B2")

    # ---- API-06 3.3 #4: train/val source_file_id sets are disjoint.
    fid_overlap = fileids_of("train") & fileids_of("val")
    p4 = [f"source_file_id in both train and val: {sorted(fid_overlap)[:5]}"] if fid_overlap else []
    _emit(4, not p4, p4, problems, tag="A2")

    # ---- API-06 3.3 #5: every class has samples in every subset.
    p5 = []
    for split in SPLITS:
        counts = Counter(r["label"] for r in data.get(split, []))
        zero = [lbl for lbl in CONFIG.class_labels if counts.get(lbl, 0) <= 0]
        if zero:
            p5.append(f"{split} has no samples for {zero}")
    _emit(5, not p5, p5, problems, tag="C")

    # ---- API-06 3.3 #6: labels are in class_labels and split matches the file name.
    p6 = []
    for split in SPLITS:
        for r in data.get(split, []):
            if r["label"] not in CONFIG.class_labels:
                p6.append(f"{split}: label {r['label']!r} not in class_labels")
            if r["split"] != split:
                p6.append(f"{split}.csv contains split={r['split']!r} ({r['path']})")
    _emit(6, not p6, p6, problems, tag="D")

    # ---- SPEC-T-02 section 2.2 assertion A: one session never straddles subsets.
    by_group: Dict[str, set] = defaultdict(set)
    for split in SPLITS:
        for r in data.get(split, []):
            by_group[group_id_of(r)].add(split)
    pa = [f"group {g} spans {sorted(s)}" for g, s in by_group.items() if len(s) > 1]
    _emit(7, not pa, pa, problems, tag="E")

    # ---- SPEC-T-02 section 2.2 assertion C: no derived file lives next to the splits.
    stray = [p.name for p in (paths.splits).glob("*") if p.suffix.lower() != ".csv"]
    pc = [f"derived file in splits dir: {stray}"] if stray else []
    _emit(8, not pc, pc, problems, tag="F")

    if problems:
        raise LeakageError("ACD-ART-002: data split leaked -> " + " | ".join(problems))


def _emit(index: int, ok: bool, detail: Sequence[str], sink: List[str], tag: str = "") -> None:
    """Prints one assertion verdict and, on failure, records it for the final exception."""
    label = f"#{index}" + (f" ({tag})" if tag else "")
    if ok:
        print(f"  ASSERT_OK   {label} {tag}".rstrip())
    else:
        print(f"  ASSERT_FAIL {label} " + "; ".join(detail))
        sink.extend(detail)
        if tag:
            print(f"  ASSERT_FAIL {tag}")


def split_sha256(written: Dict[str, Path]) -> Dict[str, str]:
    """SHA-256 of each split CSV -- the reproducibility credential of SPEC-T-02 section 1.2.6."""
    return {name: sha256_file(path) for name, path in written.items()}


def print_split_stats(data: Dict[str, List[dict]],
                      full_rows: Optional[Sequence[dict]] = None) -> None:
    """Prints the four statistics SPEC-T-02 section 7 criterion 14 requires.

    ``data`` holds the five contract columns only (``source`` is deliberately not one of them,
    API-06 section 3.1), so the public/self-collected split has to come from ``full_rows`` -- the
    in-memory rows produced by :func:`build_splits`. That distinction matters: ``val.csv`` holds
    two different kinds of row (public validation rows with an empty ``subject_id`` and
    ``P04``/``P05`` adaptation rows), and a blended session count silently dilutes the public
    ratio -- measured at 0.659/0.199/0.141 against a true 0.700/0.150/0.150 before this was
    separated. The +-2 pp ratio gate applies to the public sessions only.
    """
    print()
    total_frags = sum(len(v) for v in data.values()) or 1
    for split in SPLITS:
        rows = data.get(split, [])
        files = len({r["source_file_id"] for r in rows})
        groups = len({group_id_of(r) for r in rows})
        counts = Counter(r["label"] for r in rows)
        share = len(rows) / total_frags
        print(f"  {split:12s} fragments={len(rows):5d} ({share:6.1%})  files={files:5d}  "
              f"sessions={groups:5d}")
        print("               " + "  ".join(f"{lbl}={counts.get(lbl, 0)}" for lbl in CONFIG.class_labels))

    public_rows = [r for r in (full_rows or [])
                   if r.get("source") == "esc" and r["split"] in ("train", "val", "test_public")]
    if public_rows:
        per_split = {s: [r for r in public_rows if r["split"] == s]
                     for s in ("train", "val", "test_public")}
        n_groups = sum(len({group_id_of(r) for r in rows}) for rows in per_split.values()) or 1
        print("  public session share: " + "  ".join(
            f"{s}={len({group_id_of(r) for r in rows}) / n_groups:.3f}"
            for s, rows in per_split.items()
        ))
        print(f"  public fragments     : {len(public_rows)}")
        print(f"  public sessions      : {n_groups}")
    adaptation = [r for r in data.get("val", []) if r["subject_id"]]
    if adaptation:
        subjects = sorted({r["subject_id"] for r in adaptation})
        print(f"  adaptation rows      : {len(adaptation)} in val.csv for {subjects} "
              "(validation-only, API-06 section 3.2; identified by subject_id, not by filename)")
    print("  NOTE fragment-count shares are REPORTED ONLY; the ratio gate is on session counts "
          "(SPEC-T-02 section 2.4).")


# --------------------------------------------------------------------------- CLI


def _stage_ingest(strict: bool, full_stats: bool) -> int:
    print("T-01 ingest: discovering and cleaning the raw corpus ...")
    manifest, rejects = build_manifest(full_stats=full_stats)
    mp, rp = write_manifest(manifest, rejects)
    esc = [r for r in manifest if r["source"] == "esc"]
    mobile = [r for r in manifest if r["source"] == "mobile"]

    print(f"  manifest : {mp}  ({len(manifest)} rows, sha256={sha256_file(mp)[:16]}...)")
    print(f"  rejects  : {rp}  ({len(rejects)} rows)")
    print()
    print("  class distribution (source=esc):")
    counts = Counter(r["label"] for r in esc)
    for label in CONFIG.class_labels:
        print(f"    {label:8s} {counts.get(label, 0):5d}")
    print(f"    {'TOTAL':8s} {len(esc):5d}   (SPEC-T-01 target 3,000-4,000)")

    ok, problems = collect_check(mobile)
    print()
    print("  self-collected coverage matrix:")
    for line in mobile_pose_coverage(mobile).splitlines():
        print(f"    {line}")
    print(f"  collect_check: {'240 segments, pose_coverage=OK' if ok else 'PROBLEMS'}")
    if not ok:
        for p in problems:
            print(f"    - {p}")
        if strict:
            print("ACD-ART-001: self-collected data incomplete (exit 4)", file=sys.stderr)
            return 4

    n_ok, n_problems, minutes, scenes = check_noise_bank()
    print(f"  noise: noise_minutes in [{CONFIG.domain.noise_minutes_min},"
          f"{CONFIG.domain.noise_minutes_max}] -> {minutes:.1f} min, scenes={scenes}")
    if not n_ok:
        for p in n_problems:
            print(f"    - {p}")
        if strict:
            print("ACD-ART-001: noise library insufficient (exit 5)", file=sys.stderr)
            return 5

    under = [lbl for lbl in CONFIG.class_labels
             if counts.get(lbl, 0) < CONFIG.domain.min_fragments_per_class]
    if under:
        print(f"  WARN classes below {CONFIG.domain.min_fragments_per_class} fragments: {under}"
              " -> evaluate the FF-19 four-class fallback")
        if strict:
            print("ACD-ART-001: too few fragments per class (exit 3)", file=sys.stderr)
            return 3

    over = [lbl for lbl in CONFIG.class_labels if counts.get(lbl, 0) > 1000]
    if over:
        print(f"  WARN classes above the 1,000-fragment cap of SPEC-T-01 criterion 12: {over}")
    return 0


def _stage_check_noise() -> int:
    ok, problems, minutes, scenes = check_noise_bank()
    print(f"noise_minutes in [{CONFIG.domain.noise_minutes_min},"
          f"{CONFIG.domain.noise_minutes_max}]: {minutes:.1f}")
    print(f"scenes={scenes}")
    if not ok:
        for p in problems:
            print(f"  - {p}")
        print("ACD-ART-001: noise library check failed (exit 5)", file=sys.stderr)
        return 5
    print("noise library: OK")
    return 0


def _stage_collect_check() -> int:
    rows = read_manifest()
    mobile = [r for r in rows if r["source"] == "mobile"]
    ok, problems = collect_check(mobile)
    print(mobile_pose_coverage(mobile))
    if not ok:
        for p in problems:
            print(f"  - {p}")
        print("ACD-ART-001: self-collected corpus check failed (exit 4)", file=sys.stderr)
        return 4
    print(f"{len(mobile)} segments, pose_coverage=OK")
    return 0


def _stage_split(seed: Optional[int], assert_leakage: bool, out_dir: Optional[Path]) -> int:
    manifest = read_manifest()
    rows = build_splits(manifest, seed=seed)
    written = write_splits(rows, out_dir=out_dir)
    data = read_splits(out_dir=out_dir)

    if assert_leakage:
        print("T-02 leak assertions (API-06 section 3.3):")
        assert_no_leakage(data)

    print_split_stats(data, full_rows=rows)
    print()
    print("  split sha256 (reproducibility credential for T-05):")
    for name, digest in split_sha256(written).items():
        print(f"    {name:12s} {digest}")
    print(f"\n  wrote 4 CSVs under {written['train'].parent}")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stage", required=True,
                    choices=["ingest", "split", "check-noise", "collect-check", "all"])
    ap.add_argument("--strict", action="store_true",
                    help="ingest: fail on low per-class counts, incomplete self-collected data "
                         "or an insufficient noise library")
    ap.add_argument("--assert-leakage", action="store_true",
                    help="accepted for the SPEC-T-02 CLI contract; the assertions always run")
    ap.add_argument("--seed", type=int, default=None, help="split: override the frozen seed")
    ap.add_argument("--out", default=None, help="split: output directory (default ai/data/splits)")
    ap.add_argument("--no-full-stats", action="store_true",
                    help="ingest: skip the silence/clipping full decode (header probe only)")
    args = ap.parse_args(argv)

    paths.ensure()
    out_dir = Path(args.out) if args.out else None

    if args.stage == "ingest":
        return _stage_ingest(args.strict, full_stats=not args.no_full_stats)
    if args.stage == "check-noise":
        return _stage_check_noise()
    if args.stage == "collect-check":
        return _stage_collect_check()
    if args.stage == "all":
        rc = _stage_ingest(args.strict, full_stats=not args.no_full_stats)
        if rc:
            return rc
        print()
        return _stage_split(args.seed, True, out_dir)
    # "split": the six leak assertions always run. SPEC-T-02 section 9 forbids cutting this
    # feature, and a split that was not checked is worse than no split at all, because it
    # produces numbers that look fine and mean nothing.
    return _stage_split(args.seed, True, out_dir)


if __name__ == "__main__":
    raise SystemExit(main())

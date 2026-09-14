"""Consent-registry admission check — the machine half of SPEC-C-02 (R-11 closure).

SPEC-C-02 section 3 makes the consent registry an *admission constraint* on the data plane:

  * `SPEC-T-01` (dataset ingestion) may only accept subject ids whose registry status is
    `CONSENTED` or later;
  * `SPEC-T-02` (splitting) must not contain any `WITHDRAWN` / `DELETED` subject id.

This script enforces both against the artefacts that actually exist, so the rule is a command
rather than a promise.

    python tool/check_consent_registry.py            # report
    python tool/check_consent_registry.py --strict    # non-zero exit on any violation

Exit codes: 0 = clean, 2 = violation (prints `ACD-ART-002` on the first stderr line, matching
the offline toolchain convention in API-06 section 11).
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]           # AcouDiet/
REGISTRY = ROOT / "docs" / "compliance" / "C-02" / "consent_registry.md"
NOTICE = ROOT / "docs" / "compliance" / "C-02" / "synthetic_corpus_notice.md"
SPLITS = ROOT / "ai" / "data" / "splits"
RAW_DIRS = [ROOT / "ai" / "data" / "raw" / "public", ROOT / "ai" / "data" / "raw" / "mobile"]

SUBJECT_RE = re.compile(r"^P\d{2}$")
#: Statuses that permit collection and inclusion (SPEC-C-02 section 2.3).
ADMITTED = {"CONSENTED", "COLLECTED", "IN_DATASET"}
#: Statuses that must never appear in a split file.
FORBIDDEN = {"WITHDRAWN", "DELETED", "DROPPED", "RECRUITED"}


def declared_synthetic() -> set[str]:
    """Subject ids declared as machine-generated audio in the synthetic-corpus notice.

    A synthetic corpus has no human subject, so consent is neither needed nor obtainable --
    but it must be *declared*, never silently exempted. That is the whole point of R-11: the
    rule is "nothing unconsented may enter", and this function is what turns an exemption into
    an auditable artefact.
    """
    if not NOTICE.exists():
        return set()
    text = NOTICE.read_text(encoding="utf-8")
    match = re.search(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    if not match:
        return set()
    try:
        import json

        payload = json.loads(match.group(1))
    except Exception:
        return set()
    ids = payload.get("synthetic_subjects") or []
    return {str(i) for i in ids if SUBJECT_RE.match(str(i))}


def parse_registry() -> dict[str, str]:
    """Reads `subjectId -> status` from the markdown table (one row per subject)."""
    if not REGISTRY.exists():
        return {}
    statuses: dict[str, str] = {}
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 8:
            continue
        subject = cells[0].strip("` ")
        if not SUBJECT_RE.match(subject):
            continue
        status = cells[7].strip("` ").upper()
        statuses[subject] = status
    return statuses


def split_subjects() -> dict[str, set[str]]:
    """`subject_id -> set(split files containing it)` across the four CSV files."""
    found: dict[str, set[str]] = {}
    if not SPLITS.exists():
        return found
    for csv_path in sorted(SPLITS.glob("*.csv")):
        with csv_path.open(newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                subject = (row.get("subject_id") or "").strip()
                if not subject or not SUBJECT_RE.match(subject):
                    continue
                found.setdefault(subject, set()).add(csv_path.name)
    return found


def raw_subjects() -> set[str]:
    """Subject directories that actually hold audio."""
    present: set[str] = set()
    for base in RAW_DIRS:
        if not base.exists():
            continue
        for child in base.iterdir():
            if child.is_dir() and SUBJECT_RE.match(child.name):
                present.add(child.name)
    return present


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero on any violation (used by the regression suite)")
    args = ap.parse_args()

    registry = parse_registry()
    in_splits = split_subjects()
    on_disk = raw_subjects()
    synthetic = declared_synthetic()

    print("=" * 78)
    print("C-02 consent-registry admission check")
    print("=" * 78)
    print(f"registry      : {REGISTRY}")
    print(f"subjects      : {', '.join(sorted(registry)) or '(none registered yet)'}")
    print(f"splits found  : {', '.join(sorted(p.name for p in SPLITS.glob('*.csv'))) or '(none)'}")
    print(f"synthetic decl: {', '.join(sorted(synthetic)) or '(none declared)'}")
    print()

    violations: list[str] = []

    # Rule 1: every subject that appears in a split must be admitted by the registry --
    # either with a consent row, or explicitly declared as machine-generated audio.
    for subject in sorted(in_splits):
        status = registry.get(subject)
        where = ", ".join(sorted(in_splits[subject]))
        if subject in synthetic:
            continue  # declared synthetic: no human subject, no consent possible
        if status is None:
            violations.append(
                f"ACD-ART-002: {subject} appears in [{where}] but has no consent-registry row")
        elif status in FORBIDDEN:
            violations.append(
                f"ACD-ART-002: {subject} appears in [{where}] while its status is {status}")

    # Rule 2: no audio may exist on disk for a subject that is neither admitted nor declared.
    for subject in sorted(on_disk):
        if subject in synthetic:
            continue
        status = registry.get(subject)
        if status is None:
            violations.append(
                f"ACD-ART-002: raw audio exists for {subject} with no consent-registry row")
        elif status in FORBIDDEN:
            violations.append(
                f"ACD-ART-002: raw audio exists for {subject} while its status is {status}")

    # Rule 3: a subject that is declared synthetic AND also marked consented is contradictory
    # (someone signed a form for a subject that has no human behind it) -- surface it loudly.
    for subject in sorted(synthetic):
        status = registry.get(subject)
        if status in ADMITTED:
            violations.append(
                f"ACD-ART-002: {subject} is declared synthetic yet its registry status is "
                f"{status}; delete or renumber the synthetic corpus before using real data")

    # Rule 4: an admitted subject with audio but zero recorded segments is a bookkeeping gap.
    for subject in sorted(registry):
        if registry[subject] in ADMITTED and subject in on_disk and subject not in in_splits:
            print(f"  [warn] {subject}: admitted and has audio on disk but is not in any split")

    print()
    if violations:
        for v in violations:
            print(f"  [FAIL] {v}")
        print()
        print(f"RESULT: FAIL ({len(violations)} violation(s))")
        if args.strict:
            print(violations[0], file=sys.stderr)
            return 2
        return 0

    real = sorted(set(in_splits) - synthetic)
    if synthetic:
        print(f"  [note] {len(synthetic)} subject id(s) are declared machine-generated "
              f"({', '.join(sorted(synthetic))}) -- see {NOTICE.name}; no human subject, "
              f"so no consent is applicable")
    if real:
        for subject in real:
            print(f"  [ok  ] {subject} is admitted (status {registry.get(subject)})")
    elif not synthetic:
        print("  [ok  ] no subject-tagged rows in the splits yet "
              "(nothing to admit; the check is vacuously clean)")
    if on_disk:
        real_disk = sorted(on_disk - synthetic)
        if real_disk:
            print(f"  [ok  ] {len(real_disk)} real subject folder(s) on disk are admitted")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

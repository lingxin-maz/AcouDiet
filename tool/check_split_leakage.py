"""Independent verification of `ai/data/splits/*.csv` against API-06 section 3.

WHY THIS IS A SEPARATE TOOL
---------------------------
`SPEC-T-02` requires the six leak assertions of `API-06` section 3.3 to run inside the
splitting code. That makes them a *self*-check: the same program produces the splits and
declares them clean. This script is a second, independent implementation that reads only the
four CSV files plus the SSOT, so a bug in the splitter cannot hide behind its own assertion.

    python tool/check_split_leakage.py
    python tool/check_split_leakage.py --strict      # non-zero exit on any violation

Exit codes: 0 = clean (or warnings only), 2 = violation, with `ACD-ART-002` on the first
stderr line (the offline toolchain convention, API-06 section 11).
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]            # repository root
WORKSPACE = ROOT                                      # ADR-51: repo root == workspace root
SPLITS = ROOT / "ai" / "data" / "splits"

EXPECTED_COLUMNS = ["path", "label", "subject_id", "source_file_id", "split"]
FILES = ["train", "val", "test_public", "test_mobile"]
#: API-06 section 3.2: the mobile test set admits exactly these subjects.
MOBILE_SUBJECTS = {"P01", "P02", "P03"}


def load_ssot() -> dict:
    for candidate in (WORKSPACE / "shared" / "feature_config.json",):
        if candidate.exists():
            return json.loads(candidate.read_text(encoding="utf-8"))
    raise SystemExit("ACD-ART-001: shared/feature_config.json not found")


def read_split(name: str) -> list[dict]:
    path = SPLITS / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"ACD-ART-001: missing {path}")
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        columns = reader.fieldnames or []
        if columns != EXPECTED_COLUMNS:
            raise SystemExit(
                f"ACD-ART-001: {path.name} columns are {columns}, expected {EXPECTED_COLUMNS}")
        return [dict(row) for row in reader]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    ssot = load_ssot()
    labels = list(ssot["class_labels"])
    rows = {name: read_split(name) for name in FILES}

    print("=" * 78)
    print("Independent split verification (API-06 section 3.3)")
    print("=" * 78)
    for name in FILES:
        print(f"  {name + '.csv':18s} rows={len(rows[name]):5d}")
    print()

    violations: list[str] = []
    warnings: list[str] = []

    def paths(name: str) -> list[str]:
        return [r["path"] for r in rows[name]]

    # --- assertion 1: pairwise-disjoint path sets ---------------------------------------
    for i, a in enumerate(FILES):
        for b in FILES[i + 1:]:
            overlap = set(paths(a)) & set(paths(b))
            if overlap:
                sample = ", ".join(sorted(overlap)[:3])
                violations.append(
                    f"ACD-ART-002: path overlap between {a} and {b} ({len(overlap)} rows) e.g. {sample}")

    # --- assertion 2: test_mobile subjects -------------------------------------------------
    mobile_subjects = {r["subject_id"] for r in rows["test_mobile"]}
    extra = mobile_subjects - MOBILE_SUBJECTS
    if extra:
        violations.append(
            f"ACD-ART-002: test_mobile contains subjects outside {sorted(MOBILE_SUBJECTS)}: {sorted(extra)}")
    if not mobile_subjects:
        warnings.append("test_mobile.csv carries no subject ids at all")
    for other in ("train", "val"):
        clash = mobile_subjects & {r["subject_id"] for r in rows[other]} - {""}
        if clash:
            violations.append(
                f"ACD-ART-002: subject(s) {sorted(clash)} appear in both test_mobile and {other}")

    # --- assertion 3: train/val subjects disjoint -----------------------------------------
    train_subjects = {r["subject_id"] for r in rows["train"]} - {""}
    val_subjects = {r["subject_id"] for r in rows["val"]} - {""}
    clash = train_subjects & val_subjects
    if clash:
        violations.append(
            f"ACD-ART-002: subject(s) {sorted(clash)} appear in both train and val")

    # --- assertion 4: train/val source_file_id disjoint -----------------------------------
    train_files = {r["source_file_id"] for r in rows["train"]}
    val_files = {r["source_file_id"] for r in rows["val"]}
    clash = train_files & val_files
    if clash:
        violations.append(
            f"ACD-ART-002: {len(clash)} source_file_id(s) appear in both train and val, "
            f"e.g. {sorted(clash)[:3]}")

    # --- assertion 5: every subset covers every class -------------------------------------
    for name in FILES:
        counts = Counter(r["label"] for r in rows[name])
        missing = [c for c in labels if counts.get(c, 0) == 0]
        if missing:
            violations.append(f"ACD-ART-002: {name}.csv has zero samples for {missing}")
        # imbalance is reported, not failed: API-06 asks for the table to be *printed*.
        spread = ", ".join(f"{c}:{counts.get(c, 0)}" for c in labels)
        print(f"  {name + '.csv':18s} {spread}")

    # --- assertion 6: labels and split column -------------------------------------------------
    for name in FILES:
        for r in rows[name]:
            if r["label"] not in labels:
                violations.append(
                    f"ACD-ART-002: {name}.csv has label '{r['label']}' outside the frozen six")
                break
        bad_split = [r for r in rows[name] if r["split"] != name]
        if bad_split:
            violations.append(
                f"ACD-ART-002: {len(bad_split)} row(s) in {name}.csv have a mismatched split column")

    # --- extra checks the SPEC implies ---------------------------------------------------
    # The rule is per ROW and keyed on provenance, not per file: API-06 section 3.1 says
    # public-corpus rows carry an empty subject_id, while section 3.2 explicitly allows
    # P04/P05 *domain-adaptation* rows in val.csv -- and those live under raw/mobile/.
    for name in FILES:
        for r in rows[name]:
            p = r["path"].replace("\\", "/")
            is_public = "/raw/public/" in p
            is_mobile = "/raw/mobile/" in p
            if is_public and r["subject_id"]:
                violations.append(
                    f"ACD-ART-002: {name}.csv row '{r['path']}' is from the public corpus but "
                    f"carries subject_id '{r['subject_id']}' (must be empty)")
                break
            if is_mobile and not r["subject_id"]:
                violations.append(
                    f"ACD-ART-002: {name}.csv row '{r['path']}' is mobile data but has no subject_id")
                break
    for r in rows["test_mobile"]:
        if not r["subject_id"]:
            violations.append("ACD-ART-002: test_mobile.csv has a row without a subject_id")
            break

    print()
    for w in warnings:
        print(f"  [warn] {w}")
    if violations:
        for v in violations:
            print(f"  [FAIL] {v}")
        print()
        print(f"RESULT: FAIL ({len(violations)} violation(s))")
        if args.strict:
            print(violations[0], file=sys.stderr)
            return 2
        return 0

    print("  [ok  ] paths are pairwise disjoint across all four splits")
    print("  [ok  ] test_mobile subjects are within P01–P03 and disjoint from train/val")
    print("  [ok  ] train/val subject sets are disjoint")
    print("  [ok  ] train/val source_file_id sets are disjoint (split by recording)")
    print("  [ok  ] every split covers all six frozen classes")
    print("  [ok  ] all labels are within class_labels and all split columns match")
    print("  [ok  ] public rows carry an empty subject_id; mobile rows carry one")
    mobile_in_val = sorted({r["subject_id"] for r in rows["val"] if r["subject_id"]})
    if mobile_in_val:
        print(f"  [note] val.csv contains domain-adaptation subjects {mobile_in_val} "
              f"(API-06 section 3.2 permits P04/P05 in the validation set only)")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

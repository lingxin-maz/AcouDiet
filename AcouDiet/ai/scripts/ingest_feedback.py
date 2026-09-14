"""Ingests the App's *user feedback* into a labelled set for the next training round.

WHY THIS SHAPE (no on-device training)
--------------------------------------
On-device training is out of scope for v1.0 and would burn battery, so the feedback loop is
deliberately **cheap**: the App already stores, for every confirmed record, the two columns
`ADR-P6` added for exactly this purpose —

  * `confirmedByUser` — the user tapped "是" on the Level-3 two-choice prompt;
  * `correctedByUser` — the user picked the other class instead;
  * `classLabel` / `classId` / `confidence` / `eatenAtMs` — what was predicted, and how sure.

Those four numbers per event are the entire signal. No audio, no Mel, no new storage, no new
permission: the App's cost is a boolean write it already performs.

WHAT COMES IN
-------------
A JSON-lines file, one object per record (exported from the device database; `.jsonl`):

    {"recordId": "...", "eatenAtMs": 1757462400000, "classLabel": "chips",
     "classId": 0, "confidence": 0.51, "confirmedByUser": false, "correctedByUser": true,
     "correctedLabel": "gummies"}

`correctedLabel` is optional; when present it wins over `classLabel` for the training target.

WHAT COMES OUT
--------------
`ai/data/feedback/feedback_train.csv` with the same columns as `splits/*.csv` plus the
provenance columns, so `T-03`/`T-04` can fine-tune on it without any new loader:

    path,label,subject_id,source_file_id,split,origin,confidence

`path` is left **empty** on purpose: the device never stores audio (`FF-24` item 1), so a
feedback row is a *label* whose features must be re-recorded or re-derived on the device under
the same conditions. This script therefore reports a "usable fraction" instead of pretending
the rows are ready to train on.

    python ai/scripts/ingest_feedback.py --input feedback.jsonl
    python ai/scripts/ingest_feedback.py --input feedback.jsonl --min-confidence 0.45
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]              # AcouDiet/
sys.path.insert(0, str(ROOT / "ai"))
from src.config import CONFIG, paths  # noqa: E402

OUT_DIR = ROOT / "ai" / "data" / "feedback"


def _make_console_safe() -> None:
    """Degrade non-encodable glyphs instead of dying on them.

    A Windows console on a zh-CN machine defaults to a legacy codepage (cp936 here), where
    printing a symbol absent from that codepage raises `UnicodeEncodeError`. The failure mode
    is nasty because it lands at the *last* line: every row has already been written correctly,
    yet the process exits 1 and the caller reads that as "the feedback ingest failed". Replacing
    such characters with `?` is strictly better than reporting a false failure, and it protects
    any future line of output too.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, OSError):
            pass


def main() -> int:
    _make_console_safe()
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="feedback .jsonl exported from the device")
    ap.add_argument("--out", default=str(OUT_DIR / "feedback_train.csv"))
    ap.add_argument("--min-confidence", type=float, default=0.0,
                    help="drop rows below this predicted confidence (low-confidence rows are "
                         "exactly the ones the user corrected, so 0 keeps them)")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"ACD-ART-001: no such feedback file: {src}", file=sys.stderr)
        return 2

    labels = list(CONFIG.class_labels)
    rows_out: list[dict] = []
    stats = Counter()
    corrected_pairs: Counter = Counter()

    # `utf-8-sig`, not `utf-8`: an export produced by a tool that writes a BOM (or a file a
    # human saved from Notepad) would otherwise fail on line 1 with a JSON error.
    for lineno, line in enumerate(
            src.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as e:
            print(f"ACD-ART-001: line {lineno} is not valid JSON: {e}", file=sys.stderr)
            return 2

        predicted = row.get("classLabel")
        if predicted not in labels:
            stats["skipped_unknown_label"] += 1
            continue
        corrected = row.get("correctedLabel")
        if corrected is not None and corrected not in labels:
            stats["skipped_unknown_correction"] += 1
            continue

        confidence = float(row.get("confidence", 0.0))
        if confidence < args.min_confidence:
            stats["skipped_low_confidence"] += 1
            continue

        confirmed = bool(row.get("confirmedByUser"))
        was_corrected = bool(row.get("correctedByUser"))
        target = corrected if (was_corrected and corrected) else predicted

        stats["total"] += 1
        stats["confirmed"] += 1 if confirmed else 0
        stats["corrected"] += 1 if was_corrected else 0
        if was_corrected and corrected:
            corrected_pairs[f"{predicted}->{corrected}"] += 1

        rows_out.append({
            "path": "",                       # the device stores no audio (FF-24 item 1)
            "label": target,
            "subject_id": "",
            "source_file_id": f"fb_{row.get('recordId', lineno)}",
            "split": "feedback",
            "origin": "corrected" if was_corrected else ("confirmed" if confirmed else "auto"),
            "confidence": f"{confidence:.6f}",
        })

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh, fieldnames=["path", "label", "subject_id", "source_file_id", "split",
                            "origin", "confidence"])
        writer.writeheader()
        writer.writerows(rows_out)

    print("=" * 78)
    print("Ingest user feedback (the cheap half of the loop)")
    print("=" * 78)
    print(f"  input          : {src}")
    print(f"  output         : {out}")
    print(f"  rows written   : {len(rows_out)}")
    print(f"  user-confirmed : {stats['confirmed']}")
    print(f"  user-corrected : {stats['corrected']}")
    if stats["skipped_unknown_label"]:
        print(f"  skipped (label outside the frozen six): {stats['skipped_unknown_label']}")
    if stats["skipped_low_confidence"]:
        print(f"  skipped (below --min-confidence)     : {stats['skipped_low_confidence']}")
    if corrected_pairs:
        print("  confusion seen in the field (predicted->chosen):")
        for pair, n in corrected_pairs.most_common(6):
            print(f"    {pair}: {n}")
    print()
    print("  ⚠️ `path` is empty by design: the device stores no audio, so these rows are LABELS.")
    print("     They become training data only after the matching features are re-recorded")
    print("     (or re-derived on-device) under the same conditions. Treat this file as a")
    print("     prioritisation signal for the next data-collection round, not as a dataset.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

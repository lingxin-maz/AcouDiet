"""Generates `app/assets/demo_dataset.json` (A-04 / SPEC-A-04 dual-track demo data).

The demo dataset is deliberately *generated* rather than hand-written so that:

* every record satisfies `docs/common/docs_api/schemas/diet_record.schema.json`
  (all required keys, `source == "demo"`, the 1:1 `metrics` block present on every row);
* `eatenAtMs <= endedAtMs`, `durationSeconds` agrees with the difference, `classLabel`
  and `classId` are in the frozen order, and `confidence` is inside `[0, 1]` -- the
  self-consistency checks `API-04` section 6 demands;
* the fixture is reproducible: re-running this script produces byte-identical output.

The anchor day is stored with an explicit clock time per record. On load,
`DemoDataController` rebases the records onto the *current* local week while preserving the
local clock time, so the demo always shows a populated report without shipping data that
pretends to be today's real intake.

Usage::

    python tool/gen_demo_dataset.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

AI_ROOT = Path(__file__).resolve().parents[1]          # repository root
sys.path.insert(0, str(AI_ROOT / "ai"))

from src.config import CONFIG  # noqa: E402

APP_ASSETS = AI_ROOT / "app" / "assets"
OUT = APP_ASSETS / "demo_dataset.json"

#: Reference anchor: 2026-09-10 12:00 local. Only the day offset and the local clock time
#: matter, because the loader rebases onto the current week.
ANCHOR = (2026, 9, 10)

#: (day offset, hour, minute, class label, chews, interval s, duration s, speed grade)
#: Three meals plus one afternoon snack per day, matching `FakeRepo.demoFixture()` so the
#: placeholder UI and the demo dataset tell the same story.
#:
#: ADR-19 renamed ids 1-3 (apple->cabbage, cookie->gummies, bread->noodles). The plan below is
#: updated **positionally**: each slot keeps the role it had (vegetable / snack / staple), so
#: every downstream aggregate and the scoring fixtures keep their meaning.
PLAN = [
    (0, 7, 0, "chips", 52, 0.62, 300, "正常"),
    (0, 12, 0, "cabbage", 44, 0.74, 300, "正常"),
    (0, 15, 40, "gummies", None, None, 300, None),
    (0, 18, 0, "noodles", 38, 0.83, 300, "偏慢"),
    (1, 7, 5, "noodles", 40, 0.79, 300, "正常"),
    (1, 12, 10, "carrot", 47, 0.68, 300, "正常"),
    (1, 15, 45, "chips", None, None, 300, None),
    (1, 18, 20, "drink", 30, 0.91, 300, "偏慢"),
    (2, 7, 0, "cabbage", 42, 0.72, 300, "正常"),
    (2, 12, 30, "noodles", 36, 0.85, 300, "偏慢"),
    (2, 15, 30, "chips", None, None, 300, None),
    (2, 18, 40, "carrot", 49, 0.66, 300, "正常"),
    (3, 7, 15, "drink", 28, 0.95, 300, "偏慢"),
    (3, 12, 0, "chips", 50, 0.64, 300, "正常"),
    (3, 16, 0, "gummies", None, None, 300, None),
    (3, 18, 10, "noodles", 41, 0.77, 300, "正常"),
    (4, 7, 0, "noodles", 39, 0.81, 300, "偏慢"),
    (4, 12, 5, "cabbage", 46, 0.69, 300, "正常"),
    (4, 15, 50, "chips", None, None, 300, None),
    (4, 18, 30, "carrot", 48, 0.67, 300, "正常"),
    (5, 7, 20, "carrot", 43, 0.71, 300, "正常"),
    (5, 12, 15, "noodles", 37, 0.84, 300, "偏慢"),
    (5, 15, 35, "gummies", None, None, 300, None),
    (5, 18, 0, "chips", 51, 0.63, 300, "正常"),
    (6, 7, 0, "cabbage", 45, 0.70, 300, "正常"),
    (6, 12, 20, "carrot", 47, 0.68, 300, "正常"),
    (6, 16, 10, "chips", None, None, 300, None),
    (6, 18, 15, "drink", 29, 0.93, 300, "偏慢"),
]

#: FF-19's 知识库属性 column (ADR-19 values). `foods.json` is the runtime source; this table
#: exists only because the generator must write the attribute into each demo record.
ATTRIBUTE = {
    "chips": "脆性高加工零食",
    "gummies": "黏弹性零食",
    "cabbage": "脆爽蔬菜",
    "carrot": "脆爽蔬菜",
    "noodles": "软性主食",
    "drink": "液体",
}


def main() -> int:
    labels = CONFIG.class_labels
    records = []
    for i, (offset, hour, minute, label, chews, interval, duration, grade) in enumerate(PLAN):
        year, month, day = ANCHOR
        # Build the local wall-clock instant, then convert to epoch ms.
        import datetime as _dt

        base = _dt.datetime(year, month, day, hour, minute) - _dt.timedelta(days=offset)
        eaten = int(base.timestamp() * 1000)
        ended = eaten + duration * 1000
        if label not in labels:
            raise SystemExit(f"ACD-ART-001: unknown label {label}")
        records.append(
            {
                "recordId": f"demo-{i:03d}",
                "eatenAtMs": eaten,
                "endedAtMs": ended,
                "classLabel": label,
                "classId": labels.index(label),
                "attribute": ATTRIBUTE[label],
                "confidence": round(0.72 + (i % 5) * 0.03, 2),
                "durationSeconds": duration,
                "source": "demo",
                "correctedByUser": False,
                "confirmedByUser": i % 7 == 3,
                "metrics": {
                    "chewCount": chews,
                    "avgChewIntervalSeconds": interval,
                    "durationSeconds": duration if chews is not None else None,
                    "speedGrade": grade,
                },
            }
        )

    # Self-consistency assertions (API-04 section 6) before writing anything.
    for r in records:
        assert r["eatenAtMs"] <= r["endedAtMs"], r["recordId"]
        assert r["endedAtMs"] - r["eatenAtMs"] == r["durationSeconds"] * 1000
        assert labels[r["classId"]] == r["classLabel"]
        assert 0.0 <= r["confidence"] <= 1.0
        assert r["source"] == "demo"

    payload = {
        "schemaVersion": "1.0",
        "source": "demo",
        "anchorLocalDate": "2026-09-10",
        "notes": (
            "Generated by tool/gen_demo_dataset.py for Demo Mode C / A-04. Records carry "
            "source='demo' so they can be cleared independently of real accumulated data."
        ),
        "records": records,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {OUT}  ({len(records)} demo records)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

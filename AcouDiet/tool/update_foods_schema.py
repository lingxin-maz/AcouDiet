"""ADR-23: add the portion model to `foods.schema.json`, then check the real asset against it.

Why a script: the schema repeats the same nine-field block six times with
`additionalProperties: false`, so the five new fields have to be added to **every** entry's
`required` list and `properties`. Editing that by hand is where the two drift apart, which is
exactly what this file exists to prevent.

Run:  python tool/update_foods_schema.py           # patch + verify
      python tool/update_foods_schema.py --check    # verify only
"""

import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(ROOT, "..", "docs", "common", "docs_api", "schemas", "foods.schema.json")
ASSET = os.path.join(ROOT, "app", "assets", "foods.json")

UNIT = {
    "g": {
        "type": "string",
        "enum": ["g"],
        "description": "量的单位：g（固体）或 ml（液体）。ADR-23：单位是知识库事实，"
                       "不得由类别名推断；映射到 FoodInfo.unit，PortionEstimator 据此选择取整步长",
    },
    "ml": {
        "type": "string",
        "enum": ["ml"],
        "description": "量的单位：ml（液体）。ADR-23：该类别是「液体」，既不计入零食次数、"
                       "也不作为三餐样本进入 σ；映射到 FoodInfo.unit，并驱动 isLiquid",
    },
}

FIELDS = ["unit", "standardAmount", "amountPerSecond", "minAmount", "maxAmount"]


def field_schema(name: str, unit: str) -> dict:
    if name == "unit":
        return UNIT[unit]
    if name == "standardAmount":
        return {
            "type": "integer",
            "minimum": 1,
            "description": "portionDesc / portionKcal 所描述的量（单位见 unit）；映射到 "
                           "FoodInfo.standardAmount，是热量按量等比缩放的分母",
        }
    if name == "amountPerSecond":
        return {
            "type": "number",
            "exclusiveMinimum": 0,
            "description": "整段进食的平均摄入速率（单位/秒，含进食间停顿）；映射到 "
                           "FoodInfo.amountPerSecond。ADR-23：估算量 = clamp(速率 × 本次时长)。"
                           "该值是工程估计（标准份量 ÷ 一次典型进食时长），不是营养学测量值",
        }
    if name == "minAmount":
        return {
            "type": "integer",
            "minimum": 1,
            "description": "一次进食的合理下限（单位见 unit）；映射到 FoodInfo.minAmount，"
                           "用于夹住短时外推。必须满足 0 < minAmount <= standardAmount",
        }
    return {
        "type": "integer",
        "minimum": 1,
        "description": "一次进食的合理上限（单位见 unit）；映射到 FoodInfo.maxAmount，"
                       "用于夹住长时外推（会话忘停不会算出五公斤的午饭）。"
                       "必须满足 standardAmount <= maxAmount",
    }


def patch(schema: dict) -> int:
    changed = 0
    for label, entry in schema["properties"].items():
        unit = "ml" if label == "drink" else "g"
        for name in FIELDS:
            entry["properties"].setdefault(name, field_schema(name, unit))
            if name not in entry["required"]:
                # Keep the file in the same field order as the asset: after portionKcal.
                index = entry["required"].index("portionKcal") + 1
                entry["required"].insert(index, name)
                changed += 1
        entry["description"] = entry["description"].replace(
            "的知识库条目",
            "的知识库条目（含 ADR-23 的用量模型：unit / standardAmount / amountPerSecond / "
            "minAmount / maxAmount，使克/毫升与热量按本次进食时长推算而不是固定标准份量）",
        )
    return changed


def verify(schema: dict, asset: dict) -> list:
    problems = []
    for label, entry in schema["properties"].items():
        item = asset.get(label)
        if not isinstance(item, dict):
            problems.append("%s: missing" % label)
            continue
        for key in entry["required"]:
            if key not in item:
                problems.append("%s.%s: required but missing in the asset" % (label, key))
        extra = set(item) - set(entry["properties"])
        if extra:
            problems.append("%s: asset keys not in the schema: %s" % (label, sorted(extra)))
        if item.get("unit") != ("ml" if label == "drink" else "g"):
            problems.append("%s.unit: %r" % (label, item.get("unit")))
        if not (0 < item.get("minAmount", 0) <= item.get("standardAmount", 0)
                <= item.get("maxAmount", 0)):
            problems.append("%s: needs 0 < minAmount <= standardAmount <= maxAmount" % label)
        if not item.get("amountPerSecond", 0) > 0:
            problems.append("%s.amountPerSecond must be > 0" % label)
    return problems


def main() -> int:
    with io.open(SCHEMA, encoding="utf-8") as fh:
        schema = json.load(fh)
    with io.open(ASSET, encoding="utf-8") as fh:
        asset = json.load(fh)

    if "--check" not in sys.argv:
        changed = patch(schema)
        with io.open(SCHEMA, "w", encoding="utf-8", newline="") as fh:
            json.dump(schema, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print("patched %s (%d required entries added)" % (SCHEMA, changed))
    else:
        # Re-read the file that is actually on disk.
        with io.open(SCHEMA, encoding="utf-8") as fh:
            schema = json.load(fh)

    problems = verify(schema, asset)
    if problems:
        print("SCHEMA/ASSET MISMATCH:")
        for p in problems:
            print("  -", p)
        return 1
    print("schema and asset agree on all six entries (%d fields each)"
          % len(schema["properties"]["chips"]["required"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

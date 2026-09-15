"""T-08a parity CLI -- thin wrapper over :mod:`src.parity`.

Kept as a script (rather than only a module) because that is the name the plans and SPECs use:
`SPEC-T-08` section 7 / `PLAN-T-08` acceptance is written as
``python ai/scripts/parity_test.py --n 50``.

    python ai/scripts/t08_parity_test.py --n 50
    python ai/scripts/t08_parity_test.py --n 50 --update-model-card
    python ai/scripts/t08_parity_test.py --n 50 --keras ai/artifacts/mine.keras --tflite app/assets/models/acoudiet_int8_v1.0.0.tflite
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]              # repository root
sys.path.insert(0, str(ROOT / "ai"))

from src.parity import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())

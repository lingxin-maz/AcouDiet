"""Mel / preprocessing cross-language parity gate -- SPEC-P-04 acceptance 3/4, PLAN-T-08.

For every wav in the parity corpus:

1. run the Kotlin front end through ``com.acoudiet.app.tools.MelDump``
   (preprocessed patch + Mel tensor as raw little-endian float32),
2. run the frozen Python chain (:mod:`src.features`) on the same samples,
3. assert ``np.allclose(python, kotlin, atol=1e-3)`` on BOTH the preprocessed waveform and
   the Mel tensor.

Exit code 0 means the gate passed and ``ai/artifacts/parity_report.json`` is written.
Any failure exits non-zero with ``ACD-ART-005`` on the first line of stderr -- the offline
scripts' convention (API-06 section 11).

Usage::

    python ai/scripts/mel_parity_test.py --n 20
    python ai/scripts/mel_parity_test.py --shape-only
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.config import CONFIG, paths  # noqa: E402
from src import features  # noqa: E402

#: Parity tolerance, frozen by SPEC-P-04 acceptance 4 / SPEC-T-08.
ATOL = 1e-3

ROOT = Path(__file__).resolve().parents[2]          # AcouDiet/
MEL_DUMP_MAIN = "com.acoudiet.app.tools.MelDump"
MODELS = ROOT / "app" / "assets" / "models"
MODEL_CARD = MODELS / "model_card.json"


def resolve_shipped_model() -> Path | None:
    """The `.tflite` the installed model card names, or None when nothing is installed.

    Resolved through the card rather than by globbing, because the card is what the App itself
    reads -- comparing against a different artifact than the one that ships would make the
    T-08b numbers describe a model that is not in the build.
    """
    try:
        card = json.loads(MODEL_CARD.read_text(encoding="utf-8"))
        name, version, quant = card["name"], card["version"], card["quantization"]
    except Exception:
        return None
    path = MODELS / f"{name}_{quant}_v{version}.tflite"
    return path if path.exists() else None


def _run_model(interp, mel_2d: "np.ndarray") -> "np.ndarray":
    """One patch through the shipped interpreter: ``[n_mels, n_frames]`` -> probabilities."""
    inp = interp.get_input_details()[0]
    interp.set_tensor(inp["index"], mel_2d.reshape(tuple(int(v) for v in inp["shape"])).astype(np.float32))
    interp.invoke()
    return interp.get_tensor(interp.get_output_details()[0]["index"])[0]


def run_kotlin_mel_dump(
    wav: Path, work: Path, runner: Path, offset: int
) -> tuple[np.ndarray, np.ndarray]:
    """Invokes the Kotlin MelDump tool via the shared JVM build script."""
    pre_out = work / f"{wav.stem}.o{offset}.pre.f32"
    mel_out = work / f"{wav.stem}.o{offset}.mel.f32"
    cmd = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(runner), "-Cmd",
        f"{MEL_DUMP_MAIN} --wav {wav} --offset {offset} --mel-out {mel_out} --pre-out {pre_out}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not mel_out.exists():
        raise RuntimeError(
            f"ACD-ART-005: Kotlin MelDump failed for {wav.name}@{offset}: "
            f"{proc.stdout.strip()} {proc.stderr.strip()}"
        )
    pre = np.fromfile(pre_out, dtype="<f4")
    mel = np.fromfile(mel_out, dtype="<f4")
    return pre, mel


def offsets_for(pcm: np.ndarray) -> list:
    """The patch offsets the parity gate compares for one wav.

    ADR-21 made the pre-emphasis predecessor a *streaming* quantity, so offset 0 alone is no
    longer sufficient evidence: it is exactly the one offset where the predecessor is 0.0 and
    the old "first sample passes through" rule agreed by accident. The gate therefore also
    compares a mid-file patch and the last full window, which is where a wrong boundary shows
    up. Duplicates and out-of-range offsets are dropped.
    """
    n = CONFIG.patch_samples
    size = int(pcm.shape[0])
    if size < n:
        raise ValueError(f"ACD-ART-001: wav holds {size} samples, need at least {n}")
    candidates = [0]
    if size > n:
        candidates.append(size - n)
        if size >= 2 * n:
            candidates.append((size - n) // 2)
    seen, out = set(), []
    for o in candidates:
        if o not in seen and 0 <= o <= size - n:
            seen.add(o)
            out.append(o)
    return out


def check_wav(wav: Path, work: Path, runner: Path, shape_only: bool, model=None) -> list:
    """Runs every offset for one wav. Returns one report row per offset."""
    pcm = features.read_pcm16(wav)
    rows = []
    for offset in offsets_for(pcm):
        pre_kt, mel_kt = run_kotlin_mel_dump(wav, work, runner, offset)

        expected_mel = CONFIG.n_mels * CONFIG.n_frames
        expected_pre = CONFIG.patch_samples
        if pre_kt.size != expected_pre:
            raise AssertionError(
                f"ACD-ART-004: {wav.name}@{offset} kotlin pre length {pre_kt.size} "
                f"!= {expected_pre}"
            )
        if mel_kt.size != expected_mel:
            raise AssertionError(
                f"ACD-ART-004: {wav.name}@{offset} kotlin mel length {mel_kt.size} "
                f"!= {expected_mel}"
            )
        # Python must be able to restore the exact tensor layout from the raw bytes.
        mel_kt_2d = mel_kt.reshape(CONFIG.n_mels, CONFIG.n_frames)
        name = wav.name if offset == 0 else f"{wav.name}@{offset}"

        if shape_only:
            rows.append({
                "name": name,
                "offset": offset,
                "shapeOnly": True,
                "melShape": list(mel_kt_2d.shape),
                "melRange": [float(mel_kt_2d.min()), float(mel_kt_2d.max())],
            })
            continue

        prev = features.predecessor_of(pcm, offset)
        x = features.preprocess_patch(
            pcm[offset:offset + CONFIG.patch_samples],
            apply_lufs=False,
            previous_raw_sample=prev,
        )
        py_pre = np.asarray(x, dtype=np.float32)
        py_mel = features.mel_of_file(wav, offset=offset).reshape(CONFIG.n_mels, CONFIG.n_frames)

        pre_diff = float(np.max(np.abs(py_pre - pre_kt))) if py_pre.size == pre_kt.size else float("inf")
        mel_diff = float(np.max(np.abs(py_mel - mel_kt_2d)))
        pre_ok = bool(np.allclose(py_pre, pre_kt, atol=ATOL, rtol=0.0))
        mel_ok = bool(np.allclose(py_mel, mel_kt_2d, atol=ATOL, rtol=0.0))

        row = {
            "name": name,
            "offset": offset,
            "previousRawSample": prev,
            "melShape": list(mel_kt_2d.shape),
            "melRangeKotlin": [float(mel_kt_2d.min()), float(mel_kt_2d.max())],
            "melRangePython": [float(py_mel.min()), float(py_mel.max())],
            "preMaxAbsDiff": pre_diff,
            "melMaxAbsDiff": mel_diff,
            "preAllclose": pre_ok,
            "melAllclose": mel_ok,
        }

        # SPEC-T-08's other half: does the cross-language Mel difference change the MODEL's
        # answer? Feeding both tensors to the same shipped interpreter isolates exactly that --
        # same runtime, different Mel producer -- so a nonzero agreement loss can only come
        # from the language difference. These used to be hardcoded to 1.0 / 0.0 without being
        # measured at all, which would have made the T-07 gate pass on a fabricated number.
        if model is not None:
            p_kt = _run_model(model, mel_kt_2d)
            p_py = _run_model(model, py_mel)
            row["modelLabelKotlin"] = int(np.argmax(p_kt))
            row["modelLabelPython"] = int(np.argmax(p_py))
            row["modelConfDelta"] = float(abs(p_kt.max() - p_py.max()))
            row["modelLabelMatch"] = row["modelLabelKotlin"] == row["modelLabelPython"]

        rows.append(row)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n", type=int, default=20, help="max samples to compare")
    ap.add_argument("--dir", default=str(paths.data / "parity"), help="parity wav directory")
    ap.add_argument("--work", default=str(paths.ai / "data" / "parity_out"), help="scratch dir")
    ap.add_argument("--shape-only", action="store_true", help="only assert shapes/layout (acceptance 3)")
    ap.add_argument("--report", default=str(paths.artifacts / "parity_report.json"))
    ap.add_argument(
        "--allow-no-boundary", action="store_true",
        help="permit a run that never exercised a NON-ZERO pre-emphasis predecessor",
    )
    args = ap.parse_args()

    wav_dir = Path(args.dir)
    all_wavs = sorted(wav_dir.glob("*.wav"))
    wavs = all_wavs[: args.n]
    if not wavs:
        print(f"ACD-ART-001: no wavs in {wav_dir}", file=sys.stderr)
        return 2
    if len(wavs) < len(all_wavs):
        # `--n` truncates from the SORTED list, so it can silently drop the long clips that are
        # the only ones producing a non-zero predecessor. Say so rather than let a narrowed run
        # look like a full one.
        print(f"  [note] --n {args.n} narrows {len(all_wavs)} wav(s) to {len(wavs)}; "
              f"excluded: {', '.join(p.name for p in all_wavs[args.n:])}")

    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    runner = ROOT / "tool" / "jvm_build.ps1"

    print("=" * 78)
    print("Mel / preprocessing cross-language parity (SPEC-P-04 #4, PLAN-T-08)")
    print(f"  atol          : {ATOL}")
    print(f"  samples       : {len(wavs)} wav(s) x up to 3 offsets = up to {len(wavs) * 3} patches")
    print(f"  mel tensor    : {CONFIG.n_mels} x {CONFIG.n_frames} (row-major, m*nFrames+t)")
    print(f"  raw frames    : {CONFIG.raw_mel_frames} -> kept [{CONFIG.kept_frames[0]}, "
          f"{CONFIG.kept_frames[1]}) (ADR-21 tail drop)")
    print(f"  db reference  : {CONFIG.power_to_db_ref} (ADR-21)")
    print("=" * 78)

    # Model parity (SPEC-T-08's other half) is measured, never assumed.
    model = None
    model_path = None if args.shape_only else resolve_shipped_model()
    if model_path is not None:
        import tensorflow as tf
        model = tf.lite.Interpreter(model_path=str(model_path))
        model.allocate_tensors()
    print(f"  model parity  : {model_path if model_path else '(no model installed -- NOT measured)'}")
    print("=" * 78)

    rows = []
    failures = []
    for wav in wavs:
        for row in check_wav(wav, work, runner, args.shape_only, model):
            rows.append(row)
            if args.shape_only:
                print(f"  [ok  ] {row['name']:24s} shape={row['melShape']} "
                      f"range={row['melRange']}")
                continue
            status = "ok  " if (row["preAllclose"] and row["melAllclose"]) else "FAIL"
            extra = ""
            if "modelLabelMatch" in row:
                extra = (f" model={'==' if row['modelLabelMatch'] else '!='} "
                         f"({row['modelLabelKotlin']}/{row['modelLabelPython']})")
            print(
                f"  [{status}] {row['name']:24s} prev={row['previousRawSample']:+.6f} "
                f"preD={row['preMaxAbsDiff']:.3e} melD={row['melMaxAbsDiff']:.3e}{extra}"
            )
            if not (row["preAllclose"] and row["melAllclose"]):
                failures.append(row["name"])

    mel_diffs = [r["melMaxAbsDiff"] for r in rows if "melMaxAbsDiff" in r]
    pre_diffs = [r["preMaxAbsDiff"] for r in rows if "preMaxAbsDiff" in r]
    max_mel = max(mel_diffs) if mel_diffs else 0.0
    max_pre = max(pre_diffs) if pre_diffs else 0.0

    # ---- boundary-coverage assertion (ADR-21) -------------------------------------------
    # ADR-21 made the pre-emphasis predecessor a streaming quantity, so a run in which EVERY
    # patch starts at sample 0 proves strictly less than it appears to: offset 0 is the one
    # offset where the old patch-local rule and the new streaming rule agree by construction.
    # A narrowed corpus (e.g. `--n 12`, which truncates the sorted list and drops the long
    # clips) can therefore produce a green gate that never tested the thing it exists for.
    # So the coverage is asserted, not assumed.
    boundary_rows = [r for r in rows if r.get("previousRawSample")]
    has_boundary = bool(boundary_rows)
    print()
    print(f"boundaryCoverage: {len(boundary_rows)}/{len(rows)} patch(es) had a NON-ZERO "
          f"pre-emphasis predecessor")
    for r in boundary_rows:
        print(f"  {r['name']}: previousRawSample={r['previousRawSample']:+.6f}")

    failures = list(failures)
    if not has_boundary and not args.shape_only and not args.allow_no_boundary:
        failures.append(
            "boundary-coverage: no non-zero predecessor was exercised (ADR-21 streaming rule "
            "untested); include a multi-patch wav or pass --allow-no-boundary to accept a "
            "narrower run explicitly"
        )

    passed = not failures

    # Aggregate the model-parity figures from the measured rows; None when there is no model.
    measured = [r for r in rows if "modelLabelMatch" in r]
    if measured:
        label_match = sum(1 for r in measured if r["modelLabelMatch"]) / len(measured)
        max_conf_delta = max(float(r["modelConfDelta"]) for r in measured)
    else:
        label_match = None
        max_conf_delta = None

    print()
    print(f"allclose_ok={str(passed).lower()}")
    if not args.shape_only:
        print(f"melParity: atol={ATOL} maxAbsDiff={max_mel:.3e} passed={str(passed).lower()}")
        print(f"preprocessParity: atol={ATOL} maxAbsDiff={max_pre:.3e}")
        if label_match is None:
            print("modelParity: NOT MEASURED (no model installed) -- labelMatch/maxConfDelta "
                  "are written as null, not as 1.0/0.0")
        else:
            print(f"modelParity: labelMatch={label_match:.4f} maxConfDelta={max_conf_delta:.4e} "
                  f"over {len(measured)} patches (gate 0.98 / 0.05)")

    if passed and not args.shape_only:
        report = {
            "schemaVersion": "1.0",
            "generatedAtMs": int(time.time() * 1000),
            "sampleCount": len(rows),
            # Measured above, or None. A hardcoded 1.0 here would make tool/verify_artifacts.py
            # gate on a number nobody computed.
            "labelMatch": label_match,
            "maxConfDelta": max_conf_delta,
            "modelParityMeasured": label_match is not None,
            "modelParitySource": str(model_path) if model_path else None,
            "modelParityPatchCount": len(measured),
            "thresholds": {"labelMatch": 0.98, "maxConfDelta": 0.05},
            "mismatches": [r["name"] for r in rows if "modelLabelMatch" in r
                           and not r["modelLabelMatch"]],
            "boundaryCoverage": {
                "nonZeroPredecessorPatches": len(boundary_rows),
                "totalPatches": len(rows),
                "exercised": has_boundary,
            },
            "melParity": {
                "sampleCount": len(rows),
                "atol": ATOL,
                "maxAbsDiff": max_mel,
                "passed": True,
                "preprocessMaxAbsDiff": max_pre,
                "perSample": rows,
            },
            "pipeline": {
                "pythonVersion": sys.version.split()[0],
                "librosaVersion": _librosa_version(),
                "kerasVersion": _keras_version(),
                "tfliteRuntimeVersion": _tflite_version(),
                "kotlinMelTool": MEL_DUMP_MAIN,
            },
        }
        out = Path(args.report)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\nwrote {out}")

    if not passed:
        print(f"ACD-ART-005: mel parity failed for {failures}", file=sys.stderr)
        return 1
    return 0


def _librosa_version() -> str:
    try:
        import librosa

        return librosa.__version__
    except Exception:
        return "unavailable"


def _keras_version() -> str:
    try:
        import tensorflow as tf

        return tf.__version__
    except Exception:
        return "unavailable"


def _tflite_version() -> str:
    try:
        import tensorflow as tf

        return tf.__version__
    except Exception:
        return "unavailable"


if __name__ == "__main__":
    raise SystemExit(main())

"""Runner for the offline AI toolchain's own guard-rails.

    python ai/tests/run_all.py

Exits non-zero with a summary if anything fails. Five kinds of check live here, because they
are all "does the repository still obey its own rules" questions rather than numerical tests:

 1. **SSOT invariants** -- `raw_mel_frames == patch_samples // hop + 1`, `n_frames` equals the
    `frame_selection` window width, `input_shape` matches,
    the ADR-16/ADR-17 frozen parameters are still what they must be.
 2. **Cut features never appear as enabled** -- `RIR`, `Mixup` (`X-06`), and the reserved class
    `nuts` must not show up in `ai/artifacts/*.json` as delivered content. (`noodles` was on
    this list until ADR-19 promoted it to a delivered class; it is now a *required* label.)
 3. **Terminology bans** (`FF-25` / `SPEC-C-03` §7 #3) -- no `3s` / `3 秒` window, no
    `hop.*160`, no `帧移 10`, no banned marketing wording, in `ai/**` sources.
 4. **No audio is ever written into the app asset tree** -- `FF-24` item 1. The only model
    file allowed under `app/assets/` is the `.tflite` itself.
 5. **The feedback loop is cheap and still correct** -- `ai/scripts/ingest_feedback.py` is
    actually *executed* on a fixture, because "the user-correction path exists" is a claim
    that deserves a test rather than a code reading. The load-bearing assertion is that every
    emitted row has an **empty `path`**: the device stores no audio (`FF-24` item 1), so field
    feedback is a *label*, not a recording, and nothing here may imply otherwise.

The app-side gates (Mel parity, split leakage, artifact closure, Kotlin/Dart symmetry) live in
`AcouDiet/tool/verify_all.ps1`; this runner is the AI-side counterpart so the toolchain can be
checked without the whole app toolchain.
"""

from __future__ import annotations

import csv
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]              # AcouDiet/
AI = ROOT / "ai"
WORKSPACE = ROOT.parent
SSOT = WORKSPACE / "shared" / "feature_config.json"

#: Cut features (`X-06`) plus the still-reserved class. ADR-19 removed `noodles` from this list:
#: it is a delivered class now, so demanding its absence would forbid our own output.
CUT_TOKENS = ("RIR", "Mixup", "nuts")
BANNED_WORDS = ("准确识别", "零操作", "完全无感", "测热量", "可以测", "营养成分")
#: `3s` needs BOTH boundaries: `mobilenetv3small` matches the naive left-guarded form.
LEGACY_PATTERNS = (
    (re.compile(r"(^|[^0-9A-Za-z.])3s([^A-Za-z0-9]|$)"), "3s window"),
    (re.compile(r"3\s*秒"), "3 second window"),
    (re.compile(r"hop\D{0,6}160"), "hop=160"),
    (re.compile(r"帧移\s*10"), "10 ms frame shift"),
)


class Results:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks = 0

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        self.checks += 1
        mark = "[ok]  " if ok else "[FAIL]"
        print(f"  {mark} {name}" + (f"  ({detail})" if detail else ""))
        if not ok:
            self.failures.append(name)


def read_texts(root: Path, suffixes: tuple[str, ...]) -> list[tuple[Path, str]]:
    out = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix in suffixes and "__pycache__" not in path.parts:
            try:
                out.append((path, path.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                pass
    return out


def main() -> int:
    r = Results()
    print("=" * 78)
    print("AI toolchain guard-rails")
    print("=" * 78)

    # ---- 1. SSOT invariants ---------------------------------------------------------------
    print()
    print("### SSOT invariants")
    ssot = json.loads(SSOT.read_text(encoding="utf-8"))
    # ADR-21 split the old single frame count in two. The STFT invariant moved to
    # raw_mel_frames; n_frames is now "how many frames the model takes" and must equal the
    # width of the frame-selection window. Conflating the two is the defect ADR-21 fixed, so
    # the two checks below are deliberately separate.
    r.check("raw_mel_frames == patch_samples // hop_length + 1",
            ssot["raw_mel_frames"] == ssot["patch_samples"] // ssot["hop_length"] + 1,
            f"{ssot['raw_mel_frames']} vs {ssot['patch_samples'] // ssot['hop_length'] + 1}")
    fs = ssot.get("frame_selection") or {}
    r.check("n_frames == frame_selection window width (drop_tail, ADR-21)",
            fs.get("strategy") == "drop_tail"
            and fs.get("start_inclusive") == 0
            and fs.get("end_exclusive") == ssot["n_frames"],
            f"{fs} vs n_frames={ssot['n_frames']}")
    r.check("n_frames is smaller than raw_mel_frames (one tail frame dropped)",
            ssot["n_frames"] == ssot["raw_mel_frames"] - 1,
            f"{ssot['n_frames']} vs raw {ssot['raw_mel_frames']}")
    r.check("input_shape follows n_mels / n_frames",
            list(ssot["input_shape"]) == [1, ssot["n_mels"], ssot["n_frames"], 1],
            str(ssot["input_shape"]))
    r.check("pad_mode is constant (ADR-16)", ssot["pad_mode"] == "constant")
    # ADR-21 reversed this one on purpose: the delivered model was trained patch-relative.
    r.check("power_to_db ref is the patch max (ADR-21)", ssot["power_to_db_ref"] == "patch_max",
            repr(ssot["power_to_db_ref"]))
    r.check("normalization is per-patch min-max (ADR-21)",
            ssot["normalization"] == "per_patch_minmax", repr(ssot["normalization"]))
    r.check("mel filter bank is Slaney (ADR-16)",
            ssot["mel_htk"] is False and ssot["mel_norm"] == "slaney")
    r.check("pre-emphasis boundary is the streaming rule (ADR-21)",
            ssot["preemphasis_boundary"]
            == "continuous_stream_previous_raw_sample_or_zero_at_source_start",
            repr(ssot["preemphasis_boundary"]))
    r.check("the delivered operation_order has no DC-removal stage (ADR-21)",
            not any("dc" in op.lower() for op in ssot.get("operation_order", [])))
    r.check("loudness normalisation is training-only (ADR-17)",
            ssot["loudness_normalization"] == "training_only")
    r.check("no high-pass filter key exists (ADR-17 / FF-08c)",
            not any("highpass" in k or "high_pass" in k for k in ssot))
    r.check("no fixed dB clip key exists any more (ADR-21)",
            "db_clip_range" not in ssot)
    r.check("class labels are the six frozen ones",
            list(ssot["class_labels"]) == ["chips", "cabbage", "gummies", "noodles", "carrot", "drink"],
            str(ssot["class_labels"]))

    # ---- 2. cut features ----------------------------------------------------------------
    print()
    print("### Cut features must not appear as delivered content (X-06 / FF-19)")
    artifact_json = list((AI / "artifacts").glob("*.json")) if (AI / "artifacts").exists() else []
    if not artifact_json:
        r.check("no artifacts to inspect yet", True, "nothing produced")
    for path in artifact_json:
        text = path.read_text(encoding="utf-8", errors="replace")
        for token in CUT_TOKENS:
            r.check(f"{path.name} does not mention {token}", token not in text)

    # ---- 3. terminology bans ------------------------------------------------------------
    print()
    print("### Terminology bans (FF-25 / SPEC-C-03 section 7 #3)")
    sources = read_texts(AI, (".py", ".json", ".md", ".csv"))
    legacy_hits: list[str] = []
    word_hits: list[str] = []
    for path, text in sources:
        if path.name == "run_all.py":
            continue  # this file defines the patterns, so it would match itself
        for pattern, label in LEGACY_PATTERNS:
            if pattern.search(text):
                legacy_hits.append(f"{path.relative_to(ROOT)}: {label}")
        for word in BANNED_WORDS:
            if word in text:
                word_hits.append(f"{path.relative_to(ROOT)}: {word}")
    r.check("no legacy window/hop values", not legacy_hits, "; ".join(legacy_hits[:3]))
    r.check("no banned marketing wording", not word_hits, "; ".join(word_hits[:3]))

    # ---- 4. no audio written into the app asset tree ------------------------------------
    print()
    print("### No audio may be written into app/assets (FF-24 item 1)")
    app_assets = ROOT / "app" / "assets"
    audio_files = [p for p in app_assets.rglob("*")
                   if p.is_file() and p.suffix.lower() in (".wav", ".pcm", ".raw", ".flac", ".mp3", ".m4a")]
    # `assets/demo/sample_chews.wav` is the ONE sanctioned exception: Demo Mode B replays it
    # through the same pipeline, and it is a bundled demo asset, not a recording of the user.
    unexpected = [p for p in audio_files if p.name != "sample_chews.wav"]
    r.check("app/assets contains no recording of the user",
            not unexpected, ", ".join(str(p.relative_to(ROOT)) for p in unexpected[:3]))
    r.check("the single demo sample is present and sanctioned",
            any(p.name == "sample_chews.wav" for p in audio_files),
            "assets/demo/sample_chews.wav")

    # ---- 5. the feedback loop actually works ---------------------------------------------
    print()
    print("### The user-feedback loop is cheap and still correct (ADR-P6)")
    fb_dir = AI / "data" / "feedback"
    fb_dir.mkdir(parents=True, exist_ok=True)
    fixture = fb_dir / "_selftest_feedback.jsonl"
    produced = fb_dir / "_selftest_feedback_out.csv"
    # Four field events: one confirmation, one correction, and two rows whose labels fall
    # outside the frozen six (a bad export / a stale app build) -- those must be *skipped*,
    # never silently coerced into a class.
    fixture.write_text(
        "\n".join(json.dumps(o) for o in [
            {"recordId": "r1", "eatenAtMs": 1757462400000, "classLabel": "chips", "classId": 0,
             "confidence": 0.91, "confirmedByUser": True, "correctedByUser": False},
            {"recordId": "r2", "eatenAtMs": 1757462500000, "classLabel": "chips", "classId": 0,
             "confidence": 0.51, "confirmedByUser": False, "correctedByUser": True,
             "correctedLabel": "gummies"},
            {"recordId": "r3", "eatenAtMs": 1757462600000, "classLabel": "pizza", "classId": 99,
             "confidence": 0.80, "confirmedByUser": True, "correctedByUser": False},
            {"recordId": "r4", "eatenAtMs": 1757462700000, "classLabel": "cabbage", "classId": 1,
             "confidence": 0.70, "confirmedByUser": False, "correctedByUser": True,
             "correctedLabel": "pizza"},
        ]) + "\n", encoding="utf-8")
    try:
        proc = subprocess.run(
            [sys.executable, str(AI / "scripts" / "ingest_feedback.py"),
             "--input", str(fixture), "--out", str(produced)],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        r.check("ingest_feedback.py runs on a fixture", proc.returncode == 0,
                f"exit={proc.returncode} {(proc.stderr or '').strip()[:80]}")

        rows = list(csv.DictReader(produced.read_text(encoding="utf-8").splitlines())) \
            if produced.exists() else []
        r.check("only rows inside the frozen six survive", len(rows) == 2, f"{len(rows)} rows")
        r.check("no emitted row carries a path (the device stores no audio)",
                bool(rows) and all(row["path"] == "" for row in rows),
                "path column empty for every row")
        r.check("a user correction becomes the training target",
                any(row["label"] == "gummies" and row["origin"] == "corrected" for row in rows),
                "chips -> gummies")
        r.check("a bare confirmation keeps the predicted label",
                any(row["label"] == "chips" and row["origin"] == "confirmed" for row in rows))
        r.check("origin stays inside the frozen set",
                all(row["origin"] in ("confirmed", "corrected", "auto") for row in rows),
                str(sorted({row["origin"] for row in rows})))

        # Regression: two defects found by running this very check. (a) The script printed a
        # `⚠️` on a cp936 console, raising UnicodeEncodeError *after* writing every row, so a
        # correct run exited 1. (b) A BOM'd export failed on line 1 as "not valid JSON".
        bom = fb_dir / "_selftest_feedback_bom.jsonl"
        bom.write_text("\ufeff" + json.dumps(
            {"recordId": "r5", "classLabel": "noodles", "classId": 3, "confidence": 0.66,
             "confirmedByUser": True, "correctedByUser": False}) + "\n", encoding="utf-8")
        try:
            proc2 = subprocess.run(
                [sys.executable, str(AI / "scripts" / "ingest_feedback.py"),
                 "--input", str(bom), "--out", str(produced)],
                capture_output=True, text=True, encoding="utf-8", errors="replace")
            r.check("a BOM'd export still ingests and exits 0", proc2.returncode == 0,
                    f"exit={proc2.returncode} {(proc2.stderr or '').strip()[:80]}")
        finally:
            try:
                bom.unlink()
            except OSError:
                pass
    finally:
        for leftover in (fixture, produced):
            try:
                leftover.unlink()
            except OSError:
                pass

    # --- FF-20b threshold calibration (T-05b) ----------------------------------------------
    #
    # `SPEC-00` section 3.4 FF-20b has always required the three confidence thresholds to be
    # CALIBRATED, with the process written into a test report. Measured 2026-09-15: no such
    # report existed anywhere in the repository, and no calibration code existed at all -- so
    # FF-20b was a frozen requirement with nothing behind it.
    #
    # `ai/scripts/calibrate_thresholds.py` implements it. Its own self-test needs no data, which
    # is the point: it can run in a gate.
    #
    # ⚠️ Exit code alone is not enough here. The self-test's value is its NEGATIVE CONTROLS --
    # a deliberately over-confident model that must be corrected, an already-calibrated model
    # that must NOT be corrected, and a deliberately-wrong conformal quantile that must miss the
    # coverage target. Deleting a control would leave exit code 0 and the gate would go quiet,
    # so the presence of each control is asserted from the output as well.
    proc3 = subprocess.run(
        [sys.executable, str(AI / "scripts" / "calibrate_thresholds.py"), "--selftest"],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    out3 = (proc3.stdout or "") + (proc3.stderr or "")
    r.check("calibrate_thresholds --selftest exits 0", proc3.returncode == 0,
            f"exit={proc3.returncode} {out3.strip()[-120:]}")
    r.check("temperature scaling corrects an over-confident model",
            "[positive control]" in out3 and "ECE on holdout" in out3,
            "positive control (over-confident -> calibrated) present")
    r.check("temperature scaling does NOT 'correct' an already-calibrated model",
            "[negative control] fitted T" in out3,
            "the fitter is shown not to chase noise")
    r.check("conformal coverage is verified against a wrong quantile",
            "wrong quantile" in out3 and "correct k ->" in out3,
            "the control that can actually fail is present, not deleted")
    r.check("an unsupportable coverage claim is refused",
            "unsupportable coverage claim was refused" in out3)

    # FF-20b is not satisfied by machinery alone -- it asks for the calibration *process written
    # into a test report*. A missing report is the exact state this repository was in before
    # ADR-40, so its presence is asserted rather than assumed.
    r.check("the FF-20b calibration report exists (the spec requires one)",
            (AI / "reports" / "threshold_calibration.md").exists(),
            "ai/reports/threshold_calibration.md")

    # --- model sanity: a small linear model kept as a gate ------------------------------------
    #
    # ADR-40 found the shipped recogniser's output barely depends on its input, and the only thing
    # that established it was a logistic regression fitted on the corpus -- a small model, in the
    # toolchain. This makes that check permanent and cheap: the detector is exercised against data
    # whose answer is known, so it needs neither the model nor the corpus and can run in CI.
    #
    # A gate whose detector is never shown a failing case is not a gate, so both directions are
    # asserted from the output: a constant predictor must be flagged, an input-dependent one must
    # not be, and the separability control must separate a separable corpus while staying near
    # chance on noise.
    proc4 = subprocess.run(
        [sys.executable, str(AI / "scripts" / "model_sanity.py"), "--selftest"],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    out4 = (proc4.stdout or "") + (proc4.stderr or "")
    r.check("model_sanity --selftest exits 0", proc4.returncode == 0,
            f"exit={proc4.returncode} {out4.strip()[-100:]}")
    r.check("a constant predictor is flagged as unusable",
            "constant predictor]" in out4 and "ok=False" in out4,
            "the detector catches a model that ignores its input")
    r.check("an input-dependent model is NOT flagged",
            "varying predictor]" in out4 and "ok=True" in out4,
            "the detector does not fire on a healthy model")
    r.check("the small model separates a separable corpus and not noise",
            "[separability]" in out4,
            "the control that tells 'the model is broken' from 'the corpus is broken'")

    # ---- summary ------------------------------------------------------------------------
    print()
    print("=" * 78)
    if r.failures:
        print(f"GUARD-RAILS: {r.checks - len(r.failures)}/{r.checks} passed, "
              f"{len(r.failures)} FAILED")
        for f in r.failures:
            print(f"  - {f}")
        print("=" * 78)
        return 1
    print(f"GUARD-RAILS: all {r.checks} checks passed")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

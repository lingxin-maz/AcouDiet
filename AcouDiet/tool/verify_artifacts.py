"""Independent verification of the offline AI artifacts (the integrator's gate).

WHY A SECOND GATE
-----------------
`API-06` section 9 defines a seven-condition delivery gate, and the AI toolchain ships its own
`ai/scripts/gate_artifacts.py` implementing it. That is a producer checking its own work: the
same code writes `model_card.json` and then declares it consistent.

This script reads **only the artifacts plus the SSOT** and recomputes everything from first
principles, so a bug in the producer cannot hide behind its own assertion:

 1. `model_card.nFrames`        == `feature_config.n_frames`          (FF-11, ADR-21 -> 128)
 2. `model_card.melVersion`     == the Kotlin `MEL_VERSION` constant  (API-01 section 2.1)
 3. `model_card.tfliteSha256`   == sha256 of the shipped `.tflite`
 4. `model_card.inputShape`     == `feature_config.input_shape`
 5. `model_card.classLabels`    == `feature_config.class_labels` (order included)
 6. `model_card.tfliteBytes`    == the real file size, and <= **the FF-16 cap for the card's
    own quantization tier** (FP32 6 MB / INT8 2.5 MB)
 7. `parity_report.thresholds`  == the frozen THRESH, and the three verdicts pass
 8. `featureConfigSha256`       == sha256 of `shared/feature_config.json`
 9. `parity_report.melParity`   is present and passed (cross-language Mel alignment)
10. `metrics.json` self-consistency: `sum(support) == overall.n`, matrix row sums == support,
    the E1/E2/E3 experiment matrix exists, and an ablation baseline row exists.

    python tool/verify_artifacts.py
    python tool/verify_artifacts.py --allow-placeholder   # report but do not fail on the
                                                          # known-pending model card

Exit codes: 0 = all gates pass, 2 = a gate failed (prints `ACD-ART-00x` on the first stderr
line), 3 = artifacts are not produced yet (reported distinctly so "not built" never reads as
"built and passing").
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # AcouDiet/
WORKSPACE = ROOT.parent
SSOT = WORKSPACE / "shared" / "feature_config.json"
MODELS = ROOT / "app" / "assets" / "models"
MODEL_CARD = MODELS / "model_card.json"
ARTIFACTS = ROOT / "ai" / "artifacts"
PARITY = ARTIFACTS / "parity_report.json"
METRICS = ARTIFACTS / "metrics.json"
KOTLIN_CONFIG = (ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin" /
                 "com" / "acoudiet" / "app" / "config" / "FeatureConfig.kt")

#: FF-16 size caps per tier (FP32 <= 6 MB, INT8 <= 2.5 MB).
#:
#: Literals ON PURPOSE, and duplicated with `tool/install_model.py` on purpose. This file's
#: whole reason to exist is that it must not accept the producer's word for anything; if it
#: imported the caps from `tool/install_model.py` or `ai/src/config.py`, one wrong number could
#: agree with itself and the gate would report success for a model that is over budget.
SIZE_CAPS = {"int8": int(2.5 * 1024 * 1024), "fp32": int(6 * 1024 * 1024)}
SUPPORTED_QUANTIZATIONS = tuple(SIZE_CAPS)
#: API-06 section 7 thresholds (the same values SPEC-T-08 freezes).
PARITY_THRESHOLDS = {"labelMatch": 0.98, "maxConfDelta": 0.05}
#: SPEC-P-04 acceptance 4: the cross-language Mel tolerance.
MEL_ATOL = 1e-3


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def kotlin_mel_version() -> str | None:
    if not KOTLIN_CONFIG.exists():
        return None
    for line in KOTLIN_CONFIG.read_text(encoding="utf-8").splitlines():
        if "MEL_VERSION" in line and "=" in line:
            value = line.split("=", 1)[1].strip().rstrip(";").strip().strip('"')
            if value:
                return value
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--allow-placeholder", action="store_true",
                    help="treat a pending/placeholder model card as 'not built' instead of failing")
    args = ap.parse_args()

    ssot = load(SSOT)
    print("=" * 78)
    print("Independent verification of the offline AI artifacts (API-06 section 9)")
    print("=" * 78)

    tflites = sorted(MODELS.glob("*.tflite"))
    if not MODEL_CARD.exists():
        print("STATUS: NOT BUILT -- no model card at all")
        return 3
    card = load(MODEL_CARD)
    quantization = card.get("quantization")
    pending = quantization not in SUPPORTED_QUANTIZATIONS or not card.get("tfliteSha256")

    print(f"ssot        : {SSOT}")
    print(f"model card  : {MODEL_CARD}")
    print(f"quantization: {card.get('quantization')}")
    print(f"tflite      : {', '.join(p.name for p in tflites) or '(none)'}")
    print(f"parity      : {PARITY if PARITY.exists() else '(missing)'}")
    print(f"metrics     : {METRICS if METRICS.exists() else '(missing)'}")
    print()

    if pending:
        print("  [note] the shipped model card is still the documented PLACEHOLDER "
              "(quantization not in "
              f"{list(SUPPORTED_QUANTIZATIONS)} and/or empty tfliteSha256).")
        print("         Run the T-07 export to produce a real model, then re-run this gate.")

    # "Not built" is its own verdict, and it short-circuits: every other failure below would
    # simply be a consequence of there being no model, and burying that in a list of
    # downstream complaints is how "not built" starts reading like "built but broken".
    # The distinction matters for CI: exit 3 is "nothing to verify yet", exit 2 is "verified
    # and failing".
    if pending and not tflites and not args.allow_placeholder:
        print()
        print("STATUS: NOT BUILT -- the placeholder card is in place and no .tflite has been "
              "installed.")
        print("        Drop a finished model into app/assets/models/ (see its README.md), or run")
        print("        `python tool/install_model.py --tflite <model> --version <v>`.")
        print("        This is reported as exit 3 so it can never be confused with a pass.")
        return 3

    failures: list[str] = []

    # ---- 1/4/5: card versus SSOT ---------------------------------------------------------
    checks = [
        ("nFrames", card.get("nFrames"), ssot["n_frames"], "ACD-ART-004"),
        ("inputShape", card.get("inputShape"), ssot["input_shape"], "ACD-ART-004"),
        ("classLabels", card.get("classLabels"), ssot["class_labels"], "ACD-ART-004"),
        ("numClasses", card.get("numClasses"), ssot["num_classes"], "ACD-ART-004"),
    ]
    for name, got, want, code in checks:
        if got != want:
            failures.append(f"{code}: model_card.{name} = {got!r}, SSOT says {want!r}")

    # ---- 2: melVersion versus the Kotlin constant ----------------------------------------
    mel_version = kotlin_mel_version()
    if mel_version is None:
        failures.append("ACD-ART-001: could not read MEL_VERSION from FeatureConfig.kt")
    elif card.get("melVersion") != mel_version:
        failures.append(
            f"ACD-ART-001: model_card.melVersion = {card.get('melVersion')!r} but the Kotlin "
            f"MEL_VERSION is {mel_version!r} -- the start-up handshake would raise ACD-CFG-001")

    # ---- 3/6: tflite hash and size --------------------------------------------------------
    if not tflites:
        if not args.allow_placeholder:
            failures.append("ACD-ART-003: no .tflite exists in app/assets/models/")
    else:
        tflite = tflites[0]
        real_sha = sha256(tflite)
        real_bytes = tflite.stat().st_size
        if card.get("tfliteSha256") and card["tfliteSha256"] != real_sha:
            failures.append(
                f"ACD-ART-003: tfliteSha256 mismatch -- card says {card['tfliteSha256'][:16]}..., "
                f"file hashes to {real_sha[:16]}...")
        if card.get("tfliteBytes") not in (None, 0) and card["tfliteBytes"] != real_bytes:
            failures.append(
                f"ACD-ART-003: tfliteBytes = {card['tfliteBytes']} but the file is {real_bytes}")
        # FF-16 has two tiers and the card names which one this artifact claims. An unrecognised
        # tier is a failure, not a default: silently applying the INT8 cap to an FP32 model
        # would reject a legal model, and silently applying the FP32 cap to everything would
        # let a 5 MB "INT8" model through.
        if quantization not in SIZE_CAPS:
            failures.append(
                f"ACD-ART-004: model_card.quantization = {quantization!r}, expected one of "
                f"{list(SIZE_CAPS)} (FF-16)")
        else:
            cap = SIZE_CAPS[quantization]
            if real_bytes > cap:
                failures.append(
                    f"ACD-ART-004: the model is {real_bytes} bytes, over the FF-16 "
                    f"{quantization} ceiling of {cap}")
            print(f"  measured: tier {quantization}, cap {cap} bytes")
        print(f"  measured: {tflite.name} = {real_bytes} bytes, sha256 {real_sha[:16]}...")

    # ---- 8: feature config hash -----------------------------------------------------------
    ssot_sha = sha256(SSOT)
    if card.get("featureConfigSha256") and card["featureConfigSha256"] != ssot_sha:
        failures.append(
            f"ACD-ART-003: featureConfigSha256 = {card['featureConfigSha256'][:16]}... but the "
            f"SSOT hashes to {ssot_sha[:16]}...")
    print(f"  measured: feature_config.json sha256 {ssot_sha[:16]}...")

    # ---- 7/9: parity report ---------------------------------------------------------------
    if not PARITY.exists():
        failures.append("ACD-ART-001: ai/artifacts/parity_report.json is missing")
    else:
        parity = load(PARITY)
        mel = parity.get("melParity")
        if not mel:
            failures.append("ACD-ART-005: parity_report.melParity is missing (cross-language gate)")
        else:
            if mel.get("passed") is not True:
                failures.append("ACD-ART-005: parity_report.melParity.passed is not true")
            if mel.get("atol") is not None and float(mel["atol"]) > MEL_ATOL:
                failures.append(
                    f"ACD-ART-005: melParity.atol = {mel['atol']} exceeds the frozen {MEL_ATOL}")
            diff = mel.get("maxAbsDiff")
            print(f"  measured: melParity maxAbsDiff = {diff} (atol {mel.get('atol')})")
            if diff is not None and float(diff) > MEL_ATOL:
                failures.append(
                    f"ACD-ART-005: melParity.maxAbsDiff = {diff} exceeds atol {MEL_ATOL}")

        # ADR-21 boundary coverage. A parity run in which every patch starts at sample 0 proves
        # strictly less than it looks like it does, because offset 0 is the one offset where the
        # old patch-local pre-emphasis rule and the new streaming rule agree by construction. A
        # report that does not record a non-zero predecessor being exercised is therefore NOT
        # acceptable evidence, however green its numbers are.
        cov = parity.get("boundaryCoverage")
        if not isinstance(cov, dict):
            failures.append(
                "ACD-ART-005: parity_report.boundaryCoverage is missing -- a report from before "
                "the ADR-21 coverage assertion cannot show the streaming rule was tested")
        elif cov.get("exercised") is not True:
            failures.append(
                f"ACD-ART-005: no non-zero pre-emphasis predecessor was exercised "
                f"({cov.get('nonZeroPredecessorPatches')}/{cov.get('totalPatches')} patches) -- "
                f"the ADR-21 streaming rule was never tested")
        else:
            print(f"  measured: boundaryCoverage {cov.get('nonZeroPredecessorPatches')}/"
                  f"{cov.get('totalPatches')} patches had a non-zero predecessor")

        thresh = parity.get("thresholds") or {}
        for key, want in PARITY_THRESHOLDS.items():
            if key in thresh and abs(float(thresh[key]) - want) > 1e-12:
                failures.append(
                    f"ACD-ART-005: parity thresholds.{key} = {thresh[key]} but the frozen value "
                    f"is {want}")
            elif key not in thresh:
                failures.append(f"ACD-ART-005: parity_report.thresholds.{key} is missing")

        if pending:
            print("  [note] labelMatch / maxConfDelta are not gated while the model is pending")
        else:
            lm = parity.get("labelMatch")
            mcd = parity.get("maxConfDelta")
            # A model IS installed here, so these two numbers must have been MEASURED. Treating
            # an absent value as "no objection" is how a gate ends up passing on a number that
            # nobody computed -- the previous generator wrote 1.0/0.0 unconditionally.
            if parity.get("modelParityMeasured") is not True:
                failures.append(
                    "ACD-ART-005: parity_report.labelMatch / maxConfDelta were not measured "
                    "(modelParityMeasured is not true) -- re-run ai/scripts/mel_parity_test.py "
                    "with the model installed")
            print(f"  measured: labelMatch = {lm}, maxConfDelta = {mcd} "
                  f"(over {parity.get('modelParityPatchCount', '?')} patches)")
            if lm is None or float(lm) < PARITY_THRESHOLDS["labelMatch"]:
                failures.append(
                    f"ACD-ART-005: labelMatch = {lm} is below {PARITY_THRESHOLDS['labelMatch']}")
            if mcd is None or float(mcd) > PARITY_THRESHOLDS["maxConfDelta"]:
                failures.append(
                    f"ACD-ART-005: maxConfDelta = {mcd} exceeds "
                    f"{PARITY_THRESHOLDS['maxConfDelta']}")

    # ---- 10: metrics.json self-consistency ------------------------------------------------
    if not METRICS.exists():
        print("  [note] ai/artifacts/metrics.json not produced yet (T-05)")
    else:
        metrics = load(METRICS)
        overall = metrics.get("overall") or {}
        per_class = metrics.get("perClass") or []
        support_sum = sum(int(p.get("support", 0)) for p in per_class)
        if overall.get("n") is not None and support_sum != int(overall["n"]):
            failures.append(
                f"ACD-ART-005: sum(perClass.support) = {support_sum} != overall.n = {overall['n']}")
        matrix = (metrics.get("confusionMatrix") or {}).get("matrix")
        labels = (metrics.get("confusionMatrix") or {}).get("labels")
        if matrix is None or labels is None:
            failures.append("ACD-ART-005: metrics.confusionMatrix is incomplete")
        else:
            if len(matrix) != len(per_class):
                failures.append(
                    f"ACD-ART-005: confusion matrix has {len(matrix)} rows for {len(per_class)} classes")
            for i, row in enumerate(matrix):
                want = int(per_class[i].get("support", 0)) if i < len(per_class) else None
                if want is not None and sum(row) != want:
                    failures.append(
                        f"ACD-ART-005: confusion row {i} sums to {sum(row)}, support is {want}")
            if labels and labels[-1] == "unrecognised":
                pass  # an optional trailing "unrecognised" class is allowed (API-06 section 4)
        experiments = {e.get("id") for e in (metrics.get("experimentMatrix") or [])}
        if not {"E1", "E2", "E3"} <= experiments:
            failures.append(
                f"ACD-ART-005: experimentMatrix must contain E1/E2/E3, found {sorted(experiments)}")
        ablations = metrics.get("ablations") or []
        if not any(a.get("id") == "baseline" or "baseline" in str(a.get("name", "")).lower()
                   for a in ablations):
            failures.append("ACD-ART-005: metrics.ablations has no baseline row")
        print(f"  measured: metrics n={overall.get('n')}, perClass={len(per_class)}, "
              f"experiments={sorted(experiments)}, ablations={len(ablations)}")

        # cut features must never appear (X-06 / FF-19). `noodles` is NOT in this list: ADR-19
        # promoted it from a reserved class to a delivered one, so its presence is now required
        # rather than forbidden. `nuts` is still reserved.
        blob = json.dumps(metrics, ensure_ascii=False)
        for banned in ("RIR", "Mixup", "nuts"):
            if banned in blob:
                failures.append(f"ACD-ART-005: metrics.json mentions the cut item '{banned}'")

    # ---- 11: the shipped model's OWN measured accuracy (ADR-37) ----------------------------
    #
    # `metrics.json` above describes a **locally trained Keras model** (evaluate.py feeds it the
    # `.keras`, not the `.tflite`), which is why it is legitimately absent here -- writing it from
    # some other model would be a false claim about the artifact users install. What the repo CAN
    # and now DOES measure is the accuracy of the model that actually ships, via
    # `tool/evaluate_shipped_model.py`. This gate makes that measurement impossible to let go
    # stale: the report must exist AND must name the bytes currently in `app/assets/models/`.
    shipped_report = ARTIFACTS / "metrics_shipped_model.json"
    if not shipped_report.exists():
        failures.append(
            "ACD-ART-006: ai/artifacts/metrics_shipped_model.json is missing -- the accuracy of "
            "the SHIPPED model has not been measured. Run: python tool/evaluate_shipped_model.py")
    else:
        rep = load(shipped_report)
        rep_sha = ((rep.get("model") or {}).get("sha256")) or ""
        real_sha = None
        if tflites:
            real_sha = sha256(tflites[0])
        if real_sha and rep_sha != real_sha:
            failures.append(
                f"ACD-ART-006: metrics_shipped_model.json measured {rep_sha[:16]}... but the "
                f"shipped model hashes to {real_sha[:16]}... -- the measurement is STALE. Re-run "
                f"python tool/evaluate_shipped_model.py")
        else:
            overall = rep.get("overall") or {}
            top1 = overall.get("top1")
            ci = overall.get("wilson95") or {}
            print(f"  measured: shipped model top1 = {top1} on {overall.get('testSet')} "
                  f"(n={overall.get('n')}, Wilson95 [{ci.get('low')}, {ci.get('high')}])")

    print()
    if pending and not tflites and not failures:
        print("STATUS: NOT BUILT (placeholder card only, no model)")
        print("        This is reported distinctly so 'not built' never reads as 'passing'.")
        return 3

    if failures:
        for f in failures:
            print(f"  [FAIL] {f}")
        print()
        print(f"RESULT: FAIL ({len(failures)} gate condition(s) failed)")
        print(failures[0], file=sys.stderr)
        return 2

    print("  [ok  ] model_card agrees with the SSOT on nFrames / inputShape / classLabels / numClasses")
    print("  [ok  ] model_card.melVersion equals the Kotlin MEL_VERSION constant")
    print("  [ok  ] featureConfigSha256 matches the SSOT file")
    print("  [ok  ] tflite sha256 / byte size match, and the size is within the FF-16 ceiling "
          "for its own tier")
    print("  [ok  ] parity thresholds are the frozen ones and all three verdicts pass")
    if METRICS.exists():
        print("  [ok  ] metrics.json is self-consistent (supports, matrix, E1/E2/E3, "
              "baseline ablation)")
    else:
        # Printing an [ok] for a file that is not there would be the exact failure mode this
        # gate exists to prevent, one level down.
        print("  [--  ] metrics.json not produced yet (T-05) -- not checked, not claimed ok")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

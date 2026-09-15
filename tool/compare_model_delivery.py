"""Compare a model-delivery package against what this repo actually ships.

Why: a delivery arrives as a zip with its own `feature_config.json` / `class_labels.json`, and the
only safe way to answer "is this a new model?" is byte-level, not by the folder name. This script
prints

  * the sha256 of every `.tflite` next to the one already in `app/assets/models/`,
  * the Mel-relevant keys of the delivered `feature_config.json` against the repo SSOT
    (`shared/feature_config.json`),
  * the delivered class table against `feature_config.class_labels`.

Read-only: it never copies or rewrites anything.

Run:  python tool/compare_model_delivery.py <delivery-dir>
"""

import io
import json
import os
import sys
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SSOT = os.path.join(ROOT, "..", "shared", "feature_config.json")
SHIPPED = os.path.join(ROOT, "app", "assets", "models")

#: delivery key -> the SSOT key it must equal (`shared/feature_config.json` is FLAT; the app's
#: generated `FeatureConfig` renames them, and the 15 handshake fields are compared elsewhere).
SCALAR_KEYS = [
    ("sample_rate", "sample_rate"),
    ("channels", "channels"),
    ("pre_emphasis", "preemphasis"),
    ("pre_emphasis_previous_sample", "preemphasis_boundary"),
    ("window", "window"),
    ("n_fft", "n_fft"),
    ("win_length", "win_length"),
    ("hop_length", "hop_length"),
    ("stft_pad_mode", "pad_mode"),
    ("stft_center", "center"),
    ("power", "power"),
    ("n_mels", "n_mels"),
    ("fmin", "fmin"),
    ("fmax", "fmax"),
    ("mel_htk", "mel_htk"),
    ("mel_norm", "mel_norm"),
    ("power_to_db_ref", "power_to_db_ref"),
    ("power_to_db_amin", "power_to_db_amin"),
    ("top_db", "top_db"),
    ("waveform_samples", "patch_samples"),
    ("patch_seconds", "patch_seconds"),
    ("raw_mel_frames", "raw_mel_frames"),
    ("patch_frames", "n_frames"),
    ("inference_hop_seconds", "inference_hop_seconds"),
]

#: delivery path -> SSOT key, for the nested blocks.
NESTED_KEYS = [
    ("normalization.type", "normalization"),
    ("normalization.epsilon", "normalization_epsilon"),
    ("normalization.output_min", "normalization_output_min"),
    ("normalization.output_max", "normalization_output_max"),
]

#: delivery path -> SSOT key, for whole structures that must be equal verbatim.
STRUCTURE_KEYS = [
    ("frame_selection", "frame_selection"),
    ("operation_order", "operation_order"),
    ("model_internal_preprocessing", "model_internal_preprocessing"),
]

#: `bit_depth: 16` in the SSOT is the same fact as `pcm_format: "PCM_16BIT"`.
PCM_FORMATS = {"PCM_16BIT": 16, "PCM_16bit": 16}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        key = "%s.%s" % (prefix, k) if prefix else k
        if isinstance(v, dict):
            out.update(flat(v, key))
        else:
            out[key] = v
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    delivery = sys.argv[1]

    print("=" * 78)
    print("1. artifacts")
    print("=" * 78)
    shipped = {}
    for name in sorted(os.listdir(SHIPPED)):
        if name.endswith(".tflite"):
            path = os.path.join(SHIPPED, name)
            shipped[sha256(path)] = (name, os.path.getsize(path))
            print("  shipped  %-30s %10d B  %s" % (name, os.path.getsize(path), sha256(path)))

    models = os.path.join(delivery, "models")
    if not os.path.isdir(models):
        # A bare directory of .tflite files (e.g. just the retrained artifact) is fine too.
        models = delivery
    if not os.path.isdir(models):
        print("  [error] %s has no models/ directory" % delivery)
        return 1
    for name in sorted(os.listdir(models)):
        if not name.endswith(".tflite"):
            continue
        path = os.path.join(models, name)
        digest = sha256(path)
        match = shipped.get(digest)
        print("  delivery %-30s %10d B  %s" % (name, os.path.getsize(path), digest))
        print("           -> %s" % (
            "ALREADY SHIPPED as %s" % match[0] if match else "NOT in app/assets/models/"))
        if match and match[1] != os.path.getsize(path):
            print("           !! size differs from the shipped copy")

    print()
    print("=" * 78)
    print("2. Mel front end: delivery feature_config.json vs the repo SSOT")
    print("=" * 78)
    delivered_path = os.path.join(delivery, "feature_config.json")
    if not os.path.exists(delivered_path):
        print("  no feature_config.json in this delivery -- nothing to compare here.")
        print("  (a bare .tflite carries no front-end spec; install it and re-run")
        print("   ai/scripts/mel_parity_test.py if the training-side chain changed)")
        print()
        print("=" * 78)
        print("RESULT: checked the artifacts only")
        print("=" * 78)
        return 0
    with io.open(delivered_path, encoding="utf-8") as fh:
        delivered = json.load(fh)
    with io.open(SSOT, encoding="utf-8") as fh:
        ssot = json.load(fh)
    ssot_flat = flat(ssot)

    def normalise(v):
        if isinstance(v, str):
            return v.strip().lower()
        if isinstance(v, float) and v == int(v):
            return int(v)
        if isinstance(v, bool):
            return v
        return v

    def dig(d, path):
        cur = d
        for part in path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return ("<absent>", False)
            cur = cur[part]
        return (cur, True)

    mismatches = 0

    def compare(label, delivered_value, ssot_value, present=True):
        nonlocal mismatches
        if not present:
            print("  %-34s delivery: <absent>" % label)
            return
        d = normalise(delivered_value)
        s = normalise(ssot_value)
        ok = d == s
        if not ok:
            mismatches += 1
        print("  %-34s delivery=%-30r SSOT=%-30r %s" % (label, d, s, "OK " if ok else "DIFF"))

    for dkey, skey in SCALAR_KEYS:
        if dkey == "pcm_format":
            continue
        value, present = dig(delivered, dkey)
        compare("%s vs %s" % (dkey, skey), value, ssot.get(skey), present)
    # `pcm_format` is the string spelling of the SSOT's numeric `bit_depth`.
    pcm, present = dig(delivered, "pcm_format")
    compare("pcm_format vs bit_depth",
            PCM_FORMATS.get(pcm, pcm) if present else None, ssot.get("bit_depth"), present)
    for dpath, skey in NESTED_KEYS:
        value, present = dig(delivered, dpath)
        compare("%s vs %s" % (dpath, skey), value, ssot.get(skey), present)
    for dpath, skey in STRUCTURE_KEYS:
        value, present = dig(delivered, dpath)
        compare("%s vs %s" % (dpath, skey), value, ssot.get(skey), present)
    # The model input shape must equal the frozen `input_shape`.
    shape, present = dig(delivered, "model_input.shape")
    compare("model_input.shape vs input_shape", shape, ssot.get("input_shape"), present)
    dtype, present = dig(delivered, "model_input.dtype")
    compare("model_input.dtype vs float32 I/O", dtype, "float32", present)

    print()
    print("=" * 78)
    print("3. class table")
    print("=" * 78)
    labels_path = os.path.join(delivery, "class_labels.json")
    if os.path.exists(labels_path):
        with io.open(labels_path, encoding="utf-8") as fh:
            labels = json.load(fh)
        delivered_labels = None
        if isinstance(labels, dict) and "labels" in labels:
            labels = labels["labels"]
        if isinstance(labels, list):
            delivered_labels = [str(e.get("label") if isinstance(e, dict) else e)
                                for e in labels]
        elif isinstance(labels, dict):
            delivered_labels = [str(labels[k]) for k in sorted(labels, key=lambda x: int(x))]
        print("  delivery: %s" % delivered_labels)
        print("  SSOT    : %s" % ssot.get("class_labels"))
        print("  -> %s" % ("MATCH" if delivered_labels == ssot.get("class_labels") else "DIFF"))

    print()
    print("=" * 78)
    print("RESULT: Mel mismatches = %d" % mismatches)
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

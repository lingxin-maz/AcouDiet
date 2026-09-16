"""Measure what a P-03 stage-3 denoiser actually does to THIS pipeline.

WHY THIS EXISTS (measure before implementing)
--------------------------------------------
`Preprocess.kt` reserves stage 3 for "optional experimental spectral subtraction" and
`ai/src/augment.py::spectral_subtract` already implements a reference. Before adding a second
implementation to the Android side, this script answers three questions with numbers instead of
opinions:

1. **Does denoising improve recognition accuracy?** It is measured, and the answer is the honest
   one: on the only mobile test set the shipped model sits at chance, so a front-end change cannot
   show up as an accuracy gain. Reporting that is the point -- it is the difference between
   "we added spectral subtraction" and "we know what spectral subtraction bought us".
2. **Does it improve the signal?** Segmental SNR (SSNR) against the known clean reference, which is
   exact here because the noise is mixed in by this script.
3. **Does it destroy the cue the classifier needs?** The six classes are discriminated mostly by
   broadband transients (crunchiness). The reference rule `max(|Y| - 1.5*|N|, 0)` has NO spectral
   floor, which is the textbook cause of both musical noise and eaten transients. Two variants are
   measured against a clean reference envelope:
     * `ref`   -- `max(mag - a*noise, 0)`, exactly `augment.py::spectral_subtract`
     * `floor` -- `max(mag - a*noise, b*mag)`, i.e. Berouti spectral subtraction with a spectral
                  floor, plus a soft VAD-ish gate that leaves high-energy frames almost untouched

Envelope-domain numbers are **proxies with a documented definition** (RMS at the frozen 5 ms hop),
not the frozen chew-count estimator, and are labelled as such.

Usage
-----
    python tool/measure_denoise.py                       # test_mobile, SNR 20/10/5/0
    python tool/measure_denoise.py --snr 10 --limit 12    # quick smoke run
    python tool/measure_denoise.py --out ai/reports/denoise_effect.md

Exit codes: 0 = measured, 1 = could not measure, 2 = bad usage. A partial run always says so.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "tool"))

MODEL_CARD = ROOT / "app" / "assets" / "models" / "model_card.json"
SPLITS = ROOT / "ai" / "data" / "splits"
NOISE_DIR = ROOT / "ai" / "data" / "noise"
DEFAULT_OUT = ROOT / "ai" / "reports" / "denoise_effect.md"

#: Frozen envelope geometry (FF-21*): 5 ms hop, 819 frames = 4.095 s, i.e. one patch.
ENVELOPE_HOP_MS = 5
ENVELOPE_LENGTH = 819


# --------------------------------------------------------------------------- STFT helpers


def stft_mag(x, n_fft, hop, np):
    """Magnitude spectrogram, Hann window, `1 + (len-n_fft)//hop` frames (matches the reference)."""
    import numpy as _np

    window = _np.hanning(n_fft).astype(_np.float32)
    frames = 1 + (len(x) - n_fft) // hop
    out = _np.empty((frames, n_fft // 2 + 1), dtype=_np.float32)
    for i in range(frames):
        seg = x[i * hop:i * hop + n_fft] * window
        out[i] = _np.abs(_np.fft.rfft(seg))
    return out


def spectral_subtract(x, n_fft, hop, np, mode="ref", alpha=1.5, beta=0.05, gate_db=6.0):
    """One spectral-subtraction variant on a float patch in [-1, 1].

    `mode="ref"` reproduces `ai/src/augment.py::spectral_subtract`'s arithmetic (gate at zero).
    `mode="floor"` adds the two distortion controls: a spectral floor `beta*|Y|` and a soft gate
    that scales the subtraction down in frames that are loud relative to the patch's own noise
    estimate (so a crunch, which is loud and broadband, is protected).

    Both return float in the same scale as the input; the reference's int16 round-trip is a
    training-side detail and is deliberately NOT reproduced here (the on-device stage works in
    float, which is strictly higher precision).
    """
    import numpy as _np

    window = _np.hanning(n_fft).astype(_np.float32)
    frames = 1 + (len(x) - n_fft) // hop
    spec = _np.empty((frames, n_fft // 2 + 1), dtype=_np.complex64)
    for i in range(frames):
        spec[i] = _np.fft.rfft(x[i * hop:i * hop + n_fft] * window)
    mag = _np.abs(spec)

    # Noise estimate: mean magnitude of the quietest 20% of frames of THIS patch -- the same
    # stateless, patch-local rule the reference uses, so the two remain comparable.
    energy = mag.sum(axis=1)
    quiet = energy <= _np.percentile(energy, 20.0)
    noise = mag[quiet].mean(axis=0) if _np.any(quiet) else mag.min(axis=0)

    if mode == "ref":
        cleaned = _np.maximum(mag - alpha * noise[None, :], 0.0)
    else:
        # frame gain: 1.0 (no subtraction) for loud frames, up to `alpha` for quiet ones
        frame_db = 20.0 * _np.log10(_np.maximum(energy, 1e-12))
        loud = _np.median(frame_db) + gate_db
        w = _np.clip((loud - frame_db) / gate_db, 0.0, 1.0).astype(_np.float32)
        sub = (alpha * w)[:, None] * noise[None, :]
        cleaned = _np.maximum(mag - sub, beta * mag)

    phase = _np.exp(1j * _np.angle(spec))
    rec = _np.zeros(len(x), dtype=_np.float32)
    norm = _np.zeros(len(x), dtype=_np.float32)
    for i in range(frames):
        seg = _np.fft.irfft(cleaned[i] * phase[i], n=n_fft).astype(_np.float32) * window
        rec[i * hop:i * hop + n_fft] += seg
        norm[i * hop:i * hop + n_fft] += window * window
    norm[norm < 1e-8] = 1.0
    return rec / norm


# --------------------------------------------------------------------------- metrics


def ssnr(clean, test, n_fft, hop, np, floor_db=-10.0, ceil_db=35.0, silence=1e-4):
    """Segmental SNR of `test` against `clean`, clipped to [-10, 35] dB (Hansen & Pellom).

    Frames whose clean energy is below `silence` are skipped: their SNR is not defined and
    including them would let a denoiser "win" by muting silence.
    """
    frames = 1 + (len(clean) - n_fft) // hop
    vals = []
    for i in range(frames):
        a = clean[i * hop:i * hop + n_fft]
        b = test[i * hop:i * hop + n_fft]
        na = float(np.sum(a * a))
        if na / n_fft < silence:
            continue
        ne = float(np.sum((b - a) ** 2))
        if ne <= 1e-20:
            vals.append(ceil_db)
            continue
        db = 10.0 * np.log10(na / ne)
        vals.append(float(np.clip(db, floor_db, ceil_db)))
    return float(np.mean(vals)) if vals else float("nan")


def ssnr_gain_matched(clean, test, n_fft, hop, np, **kw):
    """SSNR after removing the overall gain difference.

    ⚠️ WHY THIS EXISTS: plain SSNR punishes a denoiser for the *level* it leaves behind, not just
    for the distortion it adds. Measured on the first run of the second-generation denoiser: it
    removed 14 dB of noise but showed a poor raw SSNR, because Wiener gains with a floor also make
    the signal quieter. Comparing `clean` against a scaled copy isolates distortion, which is the
    thing we actually care about; the scale itself is reported separately as signal attenuation.
    """
    a = np.asarray(clean, dtype=np.float32)
    b = np.asarray(test, dtype=np.float32)
    denom = float(np.dot(b, b))
    if denom <= 1e-20:
        return float("nan")
    alpha = float(np.dot(b, a)) / denom
    return ssnr(a, (alpha * b).astype(np.float32), n_fft, hop, np, **kw)


def envelope(x, np, sample_rate=16000):
    """RMS envelope at the frozen 5 ms hop (a proxy, NOT the frozen chew-count estimator)."""
    step = int(sample_rate * ENVELOPE_HOP_MS / 1000)
    n = len(x) // step
    e = np.empty(n, dtype=np.float32)
    for i in range(n):
        seg = x[i * step:(i + 1) * step]
        e[i] = np.sqrt(float(np.mean(seg * seg)) + 1e-20)
    return e


def env_metrics(env_clean, env_test, np):
    """Envelope fidelity: correlation with the clean rhythm, and transient sharpness ratio."""
    m = min(len(env_clean), len(env_test))
    a = env_clean[:m]
    b = env_test[:m]
    if m < 4 or float(np.std(a)) < 1e-9 or float(np.std(b)) < 1e-9:
        return {"corr": float("nan"), "crestRatio": float("nan")}
    corr = float(np.corrcoef(a, b)[0, 1])

    def crest(e):
        med = float(np.median(e))
        return float(np.percentile(e, 99.5) / med) if med > 0 else float("nan")

    c0, c1 = crest(a), crest(b)
    return {"corr": corr, "crestRatio": float(c1 / c0) if c0 and c0 == c0 else float("nan")}


# --------------------------------------------------------------------------- main


def read_split(name, np):
    import csv

    path = SPLITS / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"ACD-ART-001: split file missing: {path}")
    with path.open(encoding="utf-8", newline="") as fh:
        return [r for r in csv.DictReader(fh)]


def resolve(csv_path: str) -> Path | None:
    p = ROOT / csv_path
    if p.exists():
        return p
    p = ROOT / "AcouDiet" / csv_path
    return p if p.exists() else None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--split", default="test_mobile")
    ap.add_argument("--snr", type=float, nargs="+", default=[20.0, 10.0, 5.0, 0.0],
                    help="mix SNR in dB (noise scaled so rms(noise)/rms(clean) matches)")
    ap.add_argument("--limit", type=int, default=0, help="cap clips (a partial run says so)")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--json", default=None, help="also write the raw numbers here")
    args = ap.parse_args(argv[1:])

    try:
        import numpy as np
        import tensorflow as tf
        from src import augment as augment_mod
        from src import denoise as denoise_mod
        from src import denoise_td as denoise_td_mod
        from src import features as features_mod
    except Exception as exc:
        print(f"ACD-ART-001: cannot import the measurement stack ({exc})", file=sys.stderr)
        return 1

    from src.config import CONFIG

    n_fft, hop = int(CONFIG.n_fft), int(CONFIG.hop_length)
    n_patch = int(CONFIG.patch_samples)

    card = json.loads(MODEL_CARD.read_text(encoding="utf-8"))
    model_path = MODEL_CARD.parent / f"{card['name']}_{card['quantization']}_v{card['version']}.tflite"
    if not model_path.exists():
        print(f"ACD-ART-001: {model_path.name} is not on disk", file=sys.stderr)
        return 1
    labels = list(card["classLabels"])
    label_id = {n: i for i, n in enumerate(labels)}

    noise_files = sorted(NOISE_DIR.glob("*.wav"))
    if not noise_files:
        print(f"ACD-ART-001: no noise corpus under {NOISE_DIR}", file=sys.stderr)
        return 1

    rows = read_split(args.split, np)
    full_n = len(rows)
    if args.limit:
        # ⚠️ The split CSVs are ordered BY CLASS, so `rows[:limit]` is not a sample -- it is a
        # different experiment. Measured on the first attempt: `--limit 12` took twelve `cabbage`
        # clips, on which the shipped model scores 1.0000 while it scores 0.1667 on the whole set.
        # A truncated run therefore has to be stratified, or it invites a false conclusion.
        by_label: dict[str, list[dict]] = {}
        for r in rows:
            by_label.setdefault(r["label"], []).append(r)
        per = max(1, args.limit // max(len(by_label), 1))
        rows = [r for lab in sorted(by_label) for r in by_label[lab][:per]]
        rows = rows[:args.limit] if args.limit > len(rows) else rows
    truncated = bool(args.limit and args.limit < full_n)

    print("=" * 78)
    print("P-03 stage-3 denoiser: measured effect")
    print("=" * 78)
    print(f"  model   : {model_path.name}  (card v{card['version']}, {card['quantization']})")
    print(f"  split   : {args.split}  n={len(rows)}{'  (TRUNCATED by --limit)' if truncated else ''}")
    print(f"  noise   : {len(noise_files)} files from {NOISE_DIR.name}/")
    print(f"  variants: clean | noisy | noisy+ref | noisy+floor")
    print()

    interp = tf.lite.Interpreter(model_path=str(model_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    # deterministic noise bank: one long buffer per file, seeded slicing per clip
    noise_buf = {p.name: features_mod.read_pcm16(p).astype(np.float32) / 32768.0
                 for p in noise_files}

    variants = ["noisy", "denoise_ref", "denoise_floor", "denoise_ms", "denoise_td"]
    # Second-generation parameters, geometry taken from the generated config (never literals).
    dp = denoise_mod.DenoiseParams(n_fft=n_fft, hop=hop)
    # Third generation (ADR-54): the time-domain transient-preserving gate. The configuration is
    # the one `tool/sweep_denoise_td.py` selected under the stated budget -- "remove as much noise
    # as possible while signal attenuation stays within 2 dB" -- out of 864 swept configurations.
    tp = denoise_td_mod.TdGateParams(
        max_attenuation_db=30.0, threshold_db=9.0, lookahead_frames=4,
        release_ms=80.0, knee_db=6.0, noise_bias=1.5)
    acc = {v: {"top1": 0, "n": 0} for v in ["clean"] + variants}
    agg = {v: {"ssnr": [], "corr": [], "crest": []} for v in variants}
    per_snr = {s: {v: {"top1": 0, "n": 0} for v in ["clean"] + variants} for s in args.snr}

    def tensor_of(patch_f32):
        pcm16 = np.clip(np.round(patch_f32 * 32768.0), -32768, 32767).astype(np.int16)
        t, _ = augment_mod.feature_tensor(
            pcm16, split=args.split, rng=None, noise_bank=None, augment_on=False)
        return np.asarray(t, dtype=np.float32).reshape(tuple(int(v) for v in inp["shape"]))

    def top1_of(patch_f32):
        interp.set_tensor(inp["index"], tensor_of(patch_f32))
        interp.invoke()
        return int(np.argmax(interp.get_tensor(out["index"])[0]))

    skipped_missing = 0
    for idx, row in enumerate(rows):
        label = row["label"]
        if label not in label_id:
            continue
        path = resolve(row["path"])
        if path is None:
            skipped_missing += 1
            continue
        pcm = features_mod.read_pcm16(path)
        clean = np.asarray(pcm, dtype=np.float32) / 32768.0
        if len(clean) < n_patch:
            reps = int(np.ceil(n_patch / max(len(clean), 1)))
            clean = np.tile(clean, reps)
        clean = np.ascontiguousarray(clean[:n_patch])
        env_clean = envelope(clean, np)
        truth = label_id[label]

        # clean row is SNR-independent: count it once, under the first SNR cell
        acc["clean"]["top1"] += int(top1_of(clean) == truth)
        acc["clean"]["n"] += 1
        per_snr[args.snr[0]]["clean"]["top1"] += int(top1_of(clean) == truth)
        per_snr[args.snr[0]]["clean"]["n"] += 1

        rng = np.random.default_rng(20260915 + idx)
        for snr_db in args.snr:
            name = noise_files[idx % len(noise_files)].name
            nb = noise_buf[name]
            off = int(rng.integers(0, max(1, len(nb) - n_patch)))
            noise = nb[off:off + n_patch]
            if len(noise) < n_patch:
                noise = np.tile(noise, int(np.ceil(n_patch / len(noise))))[:n_patch]
            scale = (float(np.sqrt(np.mean(clean ** 2))) /
                     max(float(np.sqrt(np.mean(noise ** 2))), 1e-12)) / (10.0 ** (snr_db / 20.0))
            noisy = clean + noise * scale

            patches = {
                "noisy": noisy,
                "denoise_ref": spectral_subtract(noisy, n_fft, hop, np, mode="ref"),
                "denoise_floor": spectral_subtract(noisy, n_fft, hop, np, mode="floor"),
                "denoise_ms": denoise_mod.denoise(noisy, dp),
                "denoise_td": denoise_td_mod.gate(noisy, tp),
            }
            for v, patch in patches.items():
                ok = int(top1_of(patch) == truth)
                acc[v]["top1"] += ok
                acc[v]["n"] += 1
                per_snr[snr_db][v]["top1"] += ok
                per_snr[snr_db][v]["n"] += 1
                agg[v]["ssnr"].append(ssnr_gain_matched(clean, patch, n_fft, hop, np))
                em = env_metrics(env_clean, envelope(patch, np), np)
                agg[v]["corr"].append(em["corr"])
                agg[v]["crest"].append(em["crestRatio"])

        if (idx + 1) % 48 == 0:
            print(f"    ... {idx + 1}/{len(rows)} clips")

    def mean(xs):
        xs = [v for v in xs if v == v]
        return float(sum(xs) / len(xs)) if xs else float("nan")

    # ---- how much noise is actually removed? measured on NOISE-ONLY patches -----------------
    # This cannot be gamed by destroying the signal: the input contains no signal at all. It is the
    # direct, honest reading of 「尽可能消除噪音」, and it is kept separate from SSNR on purpose.
    def att_db(w):
        r0 = float(np.sqrt(np.mean(w * w) + 1e-20))
        out = fn_att(w)
        r1 = float(np.sqrt(np.mean(out * out) + 1e-20))
        return float(20.0 * np.log10((r1 + 1e-20) / (r0 + 1e-20)))

    attenuation = {}
    for label, fn_att in (
        ("denoise_ref", lambda w: spectral_subtract(w, n_fft, hop, np, mode="ref")),
        ("denoise_floor", lambda w: spectral_subtract(w, n_fft, hop, np, mode="floor")),
        ("denoise_ms", lambda w: denoise_mod.denoise(w, dp)),
        ("denoise_td", lambda w: denoise_td_mod.gate(w, tp)),
    ):
        attenuation[label] = mean([
            att_db(np.ascontiguousarray(buf[:n_patch]))
            for buf in noise_buf.values() if len(buf) >= n_patch
        ])

    # ---- and how much SIGNAL survives? measured on CLEAN patches ---------------------------
    # Reported next to noise attenuation, because "removes 14 dB of noise" is only good news if it
    # does not also remove the food. Ideal is (very negative, ~0): noise gone, signal intact.
    signal_att = {}
    for label, fn_sig in (
        ("denoise_ref", lambda w: spectral_subtract(w, n_fft, hop, np, mode="ref")),
        ("denoise_floor", lambda w: spectral_subtract(w, n_fft, hop, np, mode="floor")),
        ("denoise_ms", lambda w: denoise_mod.denoise(w, dp)),
        ("denoise_td", lambda w: denoise_td_mod.gate(w, tp)),
    ):
        vals = []
        # Stratified by stride, NOT `rows[:24]`: the split CSV is class-ordered, so a prefix would
        # be 24 cabbage clips -- the same trap that produced the bogus `--limit` result.
        for row in rows[::max(1, len(rows) // 24)][:24]:
            path = resolve(row["path"])
            if path is None:
                continue
            c = np.asarray(features_mod.read_pcm16(path), dtype=np.float32) / 32768.0
            c = np.ascontiguousarray(c[:n_patch])
            if len(c) < n_patch:
                continue
            out = fn_sig(c)
            r0 = float(np.sqrt(np.mean(c * c) + 1e-20))
            r1 = float(np.sqrt(np.mean(out * out) + 1e-20))
            vals.append(20.0 * np.log10((r1 + 1e-20) / (r0 + 1e-20)))
        signal_att[label] = mean(vals)

    def chance_ci(n, np):
        p = 1.0 / len(labels)
        return p, 1.96 * float(np.sqrt(p * (1 - p) / max(n, 1)))

    print()
    print(f"  {'variant':<16} {'top1':>8} {'n':>6}   {'SSNR dB':>8} {'envCorr':>8} {'crestRatio':>11}")
    print("  " + "-" * 66)
    base_p, base_ci = chance_ci(acc["noisy"]["n"], np)
    for v in ["clean"] + variants:
        row_txt = f"  {v:<16} {acc[v]['top1'] / max(acc[v]['n'], 1):>8.4f} {acc[v]['n']:>6}"
        if v != "clean":
            row_txt += (f"   {mean(agg[v]['ssnr']):>8.2f} {mean(agg[v]['corr']):>8.3f}"
                        f" {mean(agg[v]['crest']):>11.3f}")
        print(row_txt)
    print("  " + "-" * 66)
    print(f"  chance = {base_p:.4f} (6 balanced classes); the noisy row's 95% band is "
          f"+/-{base_ci:.4f} for n={acc['noisy']['n']}")
    print()
    print("  noise removed on NOISE-ONLY patches (negative = energy removed; this is the direct "
          "reading of the request), next to how much SIGNAL survives on CLEAN patches:")
    print(f"    {'variant':<16} {'noise dB':>9} {'signal dB':>10}")
    for label in attenuation:
        print(f"    {label:<16} {attenuation[label]:>9.2f} {signal_att.get(label, float('nan')):>10.2f}")
    print("    ideal = noise very negative, signal close to 0.00")

    print()
    print(f"  per-SNR top1. The clean measurement is SNR-independent by construction, so it is "
          f"reported once ({acc['clean']['top1'] / max(acc['clean']['n'], 1):.4f}) and NOT repeated "
          f"as a column -- an earlier version of this table did repeat it, which made clean look "
          f"like it depended on SNR.")
    head = "  {:>7}".format("SNR dB") + "".join(f" {v:>14}" for v in variants)
    print(head)
    for snr_db in args.snr:
        cells = "".join(
            f" {per_snr[snr_db][v]['top1'] / max(per_snr[snr_db][v]['n'], 1):>14.4f}"
            for v in variants)
        print("  {:>7}".format(f"{snr_db:g}") + cells)

    # ---- report ------------------------------------------------------------------------
    lines = []
    lines.append("# P-03 stage-3 denoiser -- measured effect (generated)\n")
    lines.append("Generated by `python tool/measure_denoise.py`. Do not hand-edit.\n")
    lines.append(f"- model: `{model_path.name}` (card v{card['version']}, {card['quantization']})")
    lines.append(f"- split: `{args.split}` n={acc['noisy']['n']}"
                 f"{' (TRUNCATED by --limit)' if truncated else ''}")
    lines.append(f"- noise: {len(noise_files)} files from `ai/data/noise/`, "
                 f"mixed at SNR(dB) = {', '.join(f'{s:g}' for s in args.snr)}")
    lines.append(f"- skipped (file missing): {skipped_missing}\n")
    lines.append("| variant | top1 | n | SSNR dB | envCorr | crestRatio |")
    lines.append("|---|---|---|---|---|---|")
    for v in ["clean"] + variants:
        if v == "clean":
            lines.append(f"| `{v}` | {acc[v]['top1'] / max(acc[v]['n'], 1):.4f} | {acc[v]['n']} "
                         f"| -- | -- | -- |")
        else:
            lines.append(f"| `{v}` | {acc[v]['top1'] / max(acc[v]['n'], 1):.4f} | {acc[v]['n']} "
                         f"| {mean(agg[v]['ssnr']):.2f} | {mean(agg[v]['corr']):.3f} "
                         f"| {mean(agg[v]['crest']):.3f} |")
    lines.append("")
    lines.append(f"Chance for six balanced classes is {base_p:.4f}; the noisy row's 95% band is "
                 f"+/-{base_ci:.4f} at n={acc['noisy']['n']}.")
    lines.append("")
    lines.append("## Recogniser top1 per mix SNR\n")
    lines.append(f"`clean` is SNR-independent by construction and is therefore reported once, in "
                 f"the table above (`{acc['clean']['top1'] / max(acc['clean']['n'], 1):.4f}`), not "
                 f"repeated here.\n")
    lines.append("| SNR dB | " + " | ".join(variants) + " |")
    lines.append("|---|" + "---|" * len(variants))
    for snr_db in args.snr:
        cells = " | ".join(
            f"{per_snr[snr_db][v]['top1'] / max(per_snr[snr_db][v]['n'], 1):.4f}"
            for v in variants)
        lines.append(f"| {snr_db:g} | {cells} |")
    lines.append("")
    lines.append("Definitions: SSNR = segmental SNR of the processed patch against the known clean "
                 "reference, frames with clean RMS < 1e-4 skipped, clipped to [-10, 35] dB. "
                 "envCorr = Pearson correlation of the 5 ms RMS envelope against the clean one. "
                 "crestRatio = (99.5th percentile / median) of the envelope, divided by the clean "
                 "value, i.e. transient sharpness relative to clean. Envelope numbers are proxies "
                 "with this definition, not the frozen chew-count estimator.")
    lines.append("")
    Path(args.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n  wrote {Path(args.out).relative_to(ROOT)}")

    if args.json:
        jp = Path(args.json)
        jp.parent.mkdir(parents=True, exist_ok=True)
        jp.write_text(json.dumps({
            "split": args.split, "snr": args.snr, "truncated": truncated,
            "model": model_path.name,
            "overall": {v: {"top1": acc[v]["top1"] / max(acc[v]["n"], 1), "n": acc[v]["n"]}
                        for v in ["clean"] + variants},
            "aggregate": {v: {"ssnr": mean(agg[v]["ssnr"]), "envCorr": mean(agg[v]["corr"]),
                              "crestRatio": mean(agg[v]["crest"])} for v in variants},
            "perSnr": {f"{s:g}": {v: {"top1": per_snr[s][v]["top1"] / max(per_snr[s][v]["n"], 1),
                                      "n": per_snr[s][v]["n"]} for v in ["clean"] + variants}
                       for s in args.snr},
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"  wrote {jp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

"""T-04 the model: MobileNetV3-Small in TensorFlow/Keras (FF-13, FF-14, FF-19).

Why Keras and not PyTorch
-------------------------
FF-13 freezes the architecture **and** the framework. The master plan rejects the
PyTorch -> ONNX -> TFLite route outright: MobileNetV3's Hardswish activations and
Squeeze-Excitation blocks very often fail to convert, and even when they convert they can lose
accuracy silently -- the same failure class as the T-08 parity risk, which is exactly the thing
this toolchain exists to catch. So the model is built with ``tf.keras.applications`` and
exported through ``TFLiteConverter`` with no intermediate format.

Input shape
-----------
``CONFIG.input_shape`` is ``[1, 128, 128, 1]`` (FF-14; ``n_frames = 128`` as revised by
ADR-21 -- ``raw_mel_frames`` is 129, the STFT frame count, and one tail frame is dropped).
The Keras application wants 3 channels, so the model starts with a 1x1 convolution that
duplicates the single channel -- that keeps the graph free of any op that TFLite cannot
represent, and it means the on-device input stays a single-channel ``Float32List`` of length
``n_mels * n_frames`` (API-01 section 3.2).

Pretrained weights
------------------
FF-17 asks for ImageNet pre-training. Fetching those weights needs the network, which is not
available here, so :func:`build_model` tries ``weights="imagenet"``, catches the failure and
degrades to random initialisation. The choice is reported as ``pretrained`` in
``train_config.json`` and in the T-04 report -- never silently, and never by failing the run.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional, Tuple

if __package__ in (None, ""):  # executed as a script: ``python ai/src/model.py``
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from src.config import CONFIG
else:  # imported as ``src.model``
    from .config import CONFIG

__all__ = ["build_model", "count_params", "pretrained_or_random", "WEIGHTS_IMAGENET"]

#: The Keras identifier for the ImageNet checkpoint set of FF-17.
WEIGHTS_IMAGENET = "imagenet"


def count_params(model) -> int:
    """Measured parameter count (FF-15: report the real number, never the old 2.5M figure)."""
    return int(model.count_params())


def pretrained_or_random(input_shape: Tuple[int, int, int], num_classes: int,
                         weights: Optional[str] = None):
    """Core builder returning ``(model, used_pretrained, note)``.

    ``input_shape`` is ``(n_mels, n_frames, channels)`` as Keras expects it.
    """
    import tensorflow as tf

    requested = weights if weights is not None else WEIGHTS_IMAGENET
    note = ""
    used = False
    for attempt in (requested, None):
        try:
            base = tf.keras.applications.MobileNetV3Small(
                include_top=False,
                weights=attempt,
                input_shape=input_shape,
                minimalistic=False,
                # The Mel tensor already lives in [0, 1] (FF-08), which is exactly the range the
                # official preprocessing layer expects, so keeping it in the graph is harmless and
                # it is what makes an ImageNet checkpoint transferable if one ever becomes
                # available offline.
                include_preprocessing=True,
            )
            used = attempt is not None
            if attempt is None:
                note = (
                    "ImageNet weights unavailable offline (no network); trained from random "
                    "initialisation -- pretrained=false (SPEC-T-04 section 6)"
                )
            return base, used, note
        except Exception as exc:  # noqa: BLE001 - any download/IO failure must degrade, not crash
            if attempt is None:
                raise
            note = f"weights={attempt!r} failed ({type(exc).__name__}: {exc}); falling back"
    raise RuntimeError("ACD-ART-001: MobileNetV3Small could not be constructed")


def build_model(n_frames: Optional[int] = None, num_classes: Optional[int] = None,
                input_shape: Optional[list] = None,
                weights: Optional[str] = None):
    """Builds the Keras classifier.

    Returns ``(model, info)`` where ``info`` carries ``pretrained``/``note``/``paramCount`` so the
    caller can record them without guessing.
    """
    import tensorflow as tf

    n_frames = CONFIG.n_frames if n_frames is None else int(n_frames)
    num_classes = CONFIG.num_classes if num_classes is None else int(num_classes)
    shape = list(input_shape if input_shape is not None else CONFIG.input_shape)

    # FF-14 is a 4-D NCHW-style descriptor [1, n_mels, n_frames, 1]; Keras needs the per-sample
    # shape. Asserting the correspondence here is what stops a "helpful" 128-frame tensor from
    # silently being accepted (SPEC-04 section 2.4: a shape mismatch is a fatal defect).
    expected = [1, CONFIG.n_mels, n_frames, 1]
    if shape != expected:
        raise ValueError(
            f"ACD-ART-004: input shape {shape} != {expected}; n_frames is frozen at "
            f"{CONFIG.n_frames} by FF-11 / ADR-P1"
        )

    keras_shape = (CONFIG.n_mels, n_frames, 1)
    # The Keras application is built for 3-channel input, so its stem convolution is fixed at
    # 3 channels. The single-channel Mel tensor is expanded with a 1x1 convolution -- a standard
    # op that TFLite supports with TFLITE_BUILTINS, unlike a network-level input rewrite.
    base, used, note = pretrained_or_random(
        (CONFIG.n_mels, n_frames, 3), num_classes, weights=weights
    )

    inputs = tf.keras.Input(shape=keras_shape, name="mel")
    x = tf.keras.layers.Conv2D(3, (1, 1), padding="same", name="channel_expand")(inputs)
    x = base(x)
    x = tf.keras.layers.GlobalAveragePooling2D(name="gap")(x)
    x = tf.keras.layers.Dropout(CONFIG.domain.dropout_rate, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="probs")(x)
    model = tf.keras.Model(inputs=inputs, outputs=outputs, name="acoudiet_mobilenetv3small")

    info = {
        "pretrained": bool(used),
        "note": note,
        "paramCount": count_params(model),
        "inputShape": shape,
        "numClasses": num_classes,
        "nFrames": n_frames,
        "classLabels": list(CONFIG.class_labels),
    }
    return model, info


if __name__ == "__main__":  # pragma: no cover - manual smoke check
    m, meta = build_model()
    print(f"input : {m.input_shape}")
    print(f"output: {m.output_shape}")
    print(f"params: {meta['paramCount']} (measured, FF-15)")
    print(f"pretrained: {meta['pretrained']} {meta['note']}")

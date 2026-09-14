"""Diagnostic: why does `from_keras_model` INT8 conversion fail for this architecture?

`src/quantize.py` (and the pipeline-check script) convert with
``tf.lite.TFLiteConverter.from_keras_model``. On this toolchain that raises
``TypeError: 'NoneType' object is not callable`` from inside ``convert()``.

This probe isolates the cause and tests the two known workarounds, so the finding can be
reported with evidence instead of a guess:

  A. ``from_keras_model``                       -- the current route
  B. ``from_saved_model`` after ``model.export`` -- the route Keras 3 projects are advised to use
  C. ``from_concrete_functions``                 -- the lowest-level route

It writes nothing into the app asset tree.

    python ai/scripts/diagnose_tflite_conversion.py
"""

from __future__ import annotations

import sys
import tempfile
import traceback
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ai"))

from src.config import CONFIG, paths  # noqa: E402
from src import model as model_mod  # noqa: E402
from src import quantize as quantize_mod  # noqa: E402


def _rep(samples):
    it = iter(samples)

    def gen():
        for t in it:
            yield [np.asarray(t, dtype=np.float32)]

    return gen


def main() -> int:
    import tensorflow as tf

    print("=" * 78)
    print("TFLite INT8 conversion diagnosis")
    print("=" * 78)
    print(f"  tensorflow    : {tf.__version__}")
    print(f"  keras         : {tf.keras.__version__}")

    model, info = model_mod.build_model()
    print(f"  architecture  : {info.get('note', CONFIG.domain.model_name)}")
    print(f"  params        : {model_mod.count_params(model)}")
    print(f"  layers        : {len(model.layers)}")

    samples = quantize_mod.representative_samples(limit=24)
    print(f"  calibration   : {len(samples)} patches")
    if not samples:
        print("no representative samples; aborting")
        return 2

    def attempt(label, build):
        print()
        print(f"--- {label}")
        try:
            blob = build()
            size = len(blob)
            cap = int(2.5 * 1024 * 1024)
            print(f"    OK   : {size} bytes ({size/1024/1024:.2f} MB) "
                  f"{'within' if size <= cap else 'OVER'} the FF-16 cap")
            return size
        except Exception as e:
            print(f"    FAIL : {type(e).__name__}: {e}")
            tb = traceback.format_exc().strip().splitlines()
            for line in tb[-4:]:
                print(f"           {line.strip()}")
            return None

    def route_a():
        c = tf.lite.TFLiteConverter.from_keras_model(model)
        c.optimizations = [tf.lite.Optimize.DEFAULT]
        c.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
        c.representative_dataset = _rep(samples)
        c.inference_input_type = tf.float32
        c.inference_output_type = tf.float32
        return c.convert()

    def route_b():
        with tempfile.TemporaryDirectory(dir=str(paths.artifacts)) as d:
            export_dir = Path(d) / "saved_model"
            model.export(str(export_dir))
            c = tf.lite.TFLiteConverter.from_saved_model(str(export_dir))
            c.optimizations = [tf.lite.Optimize.DEFAULT]
            c.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
            c.representative_dataset = _rep(samples)
            c.inference_input_type = tf.float32
            c.inference_output_type = tf.float32
            return c.convert()

    def route_c():
        spec = [tf.TensorSpec(shape=list(CONFIG.input_shape), dtype=tf.float32, name="mel")]
        concrete = tf.function(lambda x: model(x)).get_concrete_function(spec)
        c = tf.lite.TFLiteConverter.from_concrete_functions([concrete], model)
        c.optimizations = [tf.lite.Optimize.DEFAULT]
        c.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
        c.representative_dataset = _rep(samples)
        c.inference_input_type = tf.float32
        c.inference_output_type = tf.float32
        return c.convert()

    results = {
        "A from_keras_model": attempt("A. from_keras_model (current route)", route_a),
        "B from_saved_model": attempt("B. from_saved_model after model.export()", route_b),
        "C from_concrete_functions": attempt("C. from_concrete_functions", route_c),
    }

    print()
    print("=" * 78)
    print("Summary")
    print("=" * 78)
    for label, size in results.items():
        print(f"  {label:28s} : {'OK ' + str(size) + ' bytes' if size else 'FAILED'}")
    working = [k for k, v in results.items() if v]
    if working:
        print()
        print(f"  => use route {working[0][0]} for this toolchain.")
    else:
        print()
        print("  => no route converts this architecture on this TensorFlow build. The INT8")
        print("     artifact cannot be produced here; T-07 must run on a toolchain where one")
        print("     of the routes succeeds. Record this in the T-07/T-08 report.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

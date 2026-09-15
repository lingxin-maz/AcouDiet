"""AcouDiet offline AI training toolchain (functional domain T, features T-01..T-08).

Packages
--------
:mod:`src.config`      SSOT loader + every numeric constant used by this domain.
:mod:`src.features`    the frozen audio -> Mel chain (librosa), the Python half of the parity gate.
:mod:`src.dataset`     T-01 discovery/cleaning + T-02 splitting with the six leak assertions.
:mod:`src.augment`     T-03 online augmentation (train split only, never written to disk).
:mod:`src.model`       T-04 MobileNetV3-Small in TF/Keras (FF-13).
:mod:`src.train`       T-04 training loop (FF-17).
:mod:`src.evaluate`    T-05 metrics.json + confusion_matrix.png.
:mod:`src.ablations`   T-06 ablations.json.
:mod:`src.quantize`    T-07 INT8 TFLite conversion + model_card.json.
:mod:`src.parity`      T-08 train/deploy parity gate.
:mod:`src.artifacts`   the seven-condition delivery gate of API-06 section 9.
"""

from __future__ import annotations

__all__ = ["config", "features", "dataset", "augment", "model", "train",
           "evaluate", "ablations", "quantize", "parity", "artifacts"]

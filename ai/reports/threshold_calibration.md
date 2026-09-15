# T-05b threshold calibration (FF-20b)

> ⚠️ **This is a PROCEDURE proof, not a calibration of the product.** The splits it ran on
> are built on the **synthetic** substitute corpus (`ai/scripts/make_synthetic_dataset.py`),
> whose own docstring states that any accuracy measured on it is a pipeline proof and not a
> scientific result. Re-run it against a real cross-domain set before quoting any number
> below as a property of the shipped model.

- predictions : `ai\artifacts\shipped_predictions.jsonl`
- fit split   : `test_public` (n=468)
- eval split  : `test_mobile` (n=144)
- target cov. : 0.90

| quantity | value |
|---|---|
| fitted temperature T | **UNBOUNDED -- the NLL fit ran to the search bound** |
| ECE before (T=1) | 0.3972 |
| ECE after | **0.3972** (fallback: the fit hit its bound, so T=1 is reported and no improvement is claimed) |
| conformal quantile q | 0.9993 |
| empirical coverage (held-out) | **0.8958** |
| mean prediction-set size | **5.76 / 6** |

## Degeneracy diagnostics (read this before the table above)

| quantity | value |
|---|---|
| distinct classes ever predicted on the held-out split | **3 / 6** |
| which | ['chips', 'cabbage', 'noodles'] |
| std of per-clip max probability | **0.104646** |
| min / max of per-clip max probability | 0.314855 / 0.860141 |

🟠 **Not degenerate, but not calibratable either -- and these are two different failures.** The output *does* vary across clips (it names 3 of 6 classes, per-clip max probability spread 0.1046), so it is not a constant predictor. But **no finite temperature minimises the NLL**, and buying 90% coverage costs a mean prediction set of **5.76 of 6 classes** -- i.e. the conformal gate can only certify by returning almost every class. Read the two facts together: the outputs move, but they do not move *with the label*. An unbounded temperature is therefore the measurement, not a bug in the fitter, and the confidence cannot be made meaningful by any threshold.

## How to read the set size

Coverage alone cannot be trusted: returning all six classes every time gives 100 % for
free. The set size is the price paid for the coverage, and a model that collapses onto one
constant class must buy coverage by widening the set towards 6. A high coverage next to a
set size near 6 means **the conformal gate is refusing to certify anything**, which is the
honest reading of a model that does not discriminate.

- ECE improved by the fit: **NO**
- coverage met: **yes**
- model degenerate (output independent of input): **no**
- NLL fit hit its search bound (T unbounded): **YES**

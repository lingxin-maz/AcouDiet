# T-07 / T-08a 导出与对齐：实测记录与工具链缺陷

**结论**：导出与对齐**管线已跑通并实测**（1.05 MB INT8、`labelMatch = 1.000000`、
`maxConfDelta = 0.001302`）。但**交付模型仍然没有**——本环境无法完成一次可达标的训练，
按用户决定不再训练，改为**成品模型投放**（见 `model_dropin_and_feedback.md`）。

---

## 1. 一个真实的本机工具链缺陷（会让任何人的 T-07 都失败）

`src/quantize.py` 原先用 `tf.lite.TFLiteConverter.from_keras_model()` 转换。在本机
（TensorFlow **2.21.0** / Keras **3.15.1**）上它**必然失败**：

```
TypeError: 'NoneType' object is not callable
  File ".../tensorflow/lite/python/tflite_keras_util.py", line 223, in _wrapped_model
    with keras_deps.get_call_context_function()().enter(
```

`keras_deps.get_call_context_function()` 返回 `None` —— 这是 Keras 3.15 与 TF 2.21 的
兼容性缺口，**不是我们代码的问题**。注意它的失败位置：`from_keras_model` **构造成功**，
只在 `convert()` 里炸，所以"构造时 try/except"这种兜底写法是无效的。

三条路线实测（`ai/scripts/diagnose_tflite_conversion.py`，可复现）：

| 路线 | 结果 |
|---|---|
| A. `from_keras_model` | ❌ `TypeError: 'NoneType' object is not callable` |
| B. `from_saved_model`（先 `model.export`） | ❌ 失败于 `PermissionError [WinError 5]` —— 本沙箱禁止 `tempfile.mkdtemp` 路径（`_toolchain/verify_env.py` 已记录该限制）；换成非临时目录应可通 |
| **C. `from_concrete_functions`** | ✅ **成功：1 096 936 字节（1.05 MB）**，远低于 FF-16 的 2.5 MB 上限 |

**已修复**：`src/quantize.py` 新增 `build_converter()` 与 `convert_model()`，
`route="auto"` 先试 A、**在 `convert()` 失败时**回退到 C，并打印实际使用的路线。
因此 `python ai/src/quantize.py` 在本机现在可以工作；在有正常 Keras 的机器上仍走最简的 A。

> 📌 这正是"机械验收优于人为记忆"的又一例：这个缺陷不写下来，下一个跑 T-07 的人会在
> 同一个 `TypeError` 上再花一小时，而且很容易误判成"我们的模型有问题"。

## 2. 管线实测数据

命令：

```powershell
python ai/scripts/t07_export_int8.py --pipeline-check --representative-n 120 --samples 18
```

| 项 | 实测值 |
|---|---|
| 架构 / 参数量 | MobileNetV3-Small 类，**942 588** 参数（`pretrained=False`：离线无 ImageNet 权重） |
| 输入张量 | `[1, 128, 128, 1]`（与 SSOT `input_shape` 一致；**`ADR-21` 修订**，原为 `[1, 128, 129, 1]` —— 129 是 `raw_mel_frames`（STFT 原始帧数），张量宽度是 `n_frames = 128`，尾帧在归一化前丢弃） |
| 代表集 | 120 个 patch，**仅取自 `train.csv`**（校准不碰测试集） |
| 转换路线 | `from_concrete_functions`（A 失败后自动回退） |
| 产物 | `ai/artifacts/acoudiet_int8_PIPELINECHECK.tflite` = **1 096 936 B（1.05 MB）** ≤ 2.5 MB ✅ |
| `sha256` 前 32 位 | `a285e480a0d2a9f3bb51a083c7f2a76d` |
| Top-1 标签一致率 | **1.000000**（阈值 ≥ 0.98）✅ |
| 最大置信度偏差 | **0.001302**（阈值 ≤ 0.05）✅ |
| 不一致样本 | 0 |
| `melParity` | **保留**：`passed=true`、`maxAbsDiff=5.960464477539063e-08` |

写入 `ai/artifacts/parity_report.json`（同时含 T-08a 的字段与原有的 `melParity` 块）。

## 3. 这些数字**不能**当作模型指标（必须如实说明）

产物是**未训练权重**的管线探针：

* `labelMatch = 1.0` 只证明**导出与对齐的管线是通的**（两个运行时对同一份垃圾答案给出相同结果），
  与模型质量无关；
* 报告里的 `pipeline` 块已写明 `weights: "untrained (pipeline check only)"`、
  `delivered: false`；
* **该 `.tflite` 刻意不投放到 `app/assets/models/`**：把一个未训练模型放进 App 的模型槽位，
  比没有模型更糟 —— App 会加载它、门禁不拦、然后自信地给出胡说八道的结果。
  探针文件名 `acoudiet_int8_PIPELINECHECK.tflite` 与 `pipeline` 块共同保证它不会被误当交付物。

## 4. 当前交付状态

| 项 | 状态 |
|---|---|
| 导出管线（T-07） | ✅ 可执行、已实测，含 converter 回退 |
| 对齐管线（T-08a） | ✅ 可执行、已实测，报告保 `melParity` |
| 独立制品闸门 | ✅ `tool/verify_artifacts.py`：**exit 0 = PASS**（`ADR-21` 起模型已投放；此前是 exit 3 = 尚未构建，与 exit 0/2 仍明确区分） |
| 交付 `.tflite` | ✅ **已投放** `app/assets/models/acoudiet_fp32_v1.0.0.tflite`（4,051,716 B，FF-16 fp32 档上限 6 MB 以内），模型卡三 hash 闭合、`parityLabelMatch`/`parityMaxConfDelta` 为实测值。选 fp32 的理由见 `ADR-21`（三个交付制品里精度最高） |
| 投放方式 | `python tool/install_model.py --tflite <模型> --version <v> [--quantization auto|fp32|int8]`（档位决定 FF-16 上限与产物文件名 `<name>_<quantization>_v<version>.tflite`，`ADR-21`），或直接复制（见 `app/assets/models/README.md`） |
| 训练数据指标 | ❌ 不报。合成语料 2 epoch 的 `valAcc = 0.167` 不是产品指标（FF-25）。⚠️ 交付模型的精度数字（fp32 55.7% / int8 52.5%）来自模型组，**本仓无带标注语料可复测**（`ai/data/splits` 等为空），不得把它当作本仓实测值引用 |

**重新投放模型时要跑的三条命令**（`ADR-21` 之后）：

```powershell
python tool\install_model.py --tflite <你的模型.tflite> --version 1.0.0 --quantization auto
python ai\scripts\mel_parity_test.py --n 14      # 跨语言 Mel + 模型 parity（实测，写 parity_report.json）
python tool\verify_artifacts.py                  # 必须 exit 0；若是 exit 3，说明模型卡与制品对不上
```

> ⚠️ **`t08_parity_test.py --update-model-card` 不再出现在这条链里**：模型卡由 `install_model.py`
> 一次写全，parity 值从 `mel_parity_test.py` 的实测结果经 `--parity-label-match` / `--parity-max-conf-delta`
> 回填。两处都写卡会让"卡说的"和"文件是的"有机会不一致，而三 hash 闭环正是为了排除这一种。

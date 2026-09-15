# AI 工具链（T-01…T-08）

**定位**：离线训练与导出。**本仓不训练模型**（见 `../records/reports/model_dropin_and_feedback.md`）：
成品模型投放到 `app/assets/models/`，App 直接使用。

## 目录

```
ai/
├── src/
│   ├── config.py        SSOT 读取（唯一写入口仍是 ../../shared/feature_config.json）
│   ├── features.py      冻结音频→Mel 链（Python 侧，T-08b 的一半）
│   ├── dataset.py       T-01 清洗/发现 + T-02 划分与六条防泄漏断言
│   ├── augment.py       T-03 增强（环境噪声/随机增益/LUFS/SpecAugment；无 RIR/Mixup）
│   ├── model.py         T-04 MobileNetV3-Small（FF-13/FF-14）
│   ├── train.py         T-04 训练循环（FF-17）
│   ├── evaluate.py      T-05 指标 / Wilson CI / 混淆矩阵
│   ├── ablations.py     T-06 消融
│   ├── quantize.py      T-07 INT8 转换 + 交付（含 converter 路线回退）
│   └── parity.py        T-08a 训练/部署对齐
├── scripts/
│   ├── make_synthetic_dataset.py       离线合成语料（无网络时的替代）
│   ├── make_parity_wavs.py             确定性对齐语料（12 个 wav）
│   ├── mel_parity_test.py              T-08b 跨语言 Mel 对齐闸门（Kotlin ↔ librosa）
│   ├── t07_export_int8.py              T-07 入口（--pipeline-check 为免训练管线校验）
│   ├── t08_parity_test.py              T-08a 入口
│   ├── diagnose_tflite_conversion.py   三条转换路线实测（见下）
│   └── ingest_feedback.py              用户反馈 → 下一轮采集优先级
├── tests/run_all.py                    工具链自检（SSOT 不变量 / 裁剪项 / 术语 / 不落盘）
└── artifacts/                          产物（metrics.json / model_card.json / *.tflite）
```

## 依赖

```powershell
$env:PYTHONPATH = "D:\Desktop\Food\_toolchain\site-packages"
$py = "D:\Desktop\Food\_toolchain\dl\python\python.exe"
```

`tensorflow 2.21`（含 `tf.lite`）、`librosa`、`soundfile`、`numpy`、`scipy`、`scikit-learn`、
`matplotlib`、`seaborn`、`statsmodels`、`audiomentations`、`pyloudnorm`、`resampy`、`torch`。
见 `requirements.txt`。

## 常用命令

```powershell
# 工具链自检（28 项，退出码 0 才算过；含反馈回路实跑）
& $py ai\tests\run_all.py

# 跨语言 Mel 对齐闸门（硬闸门；当前实测 maxAbsDiff 5.96e-08 ≤ 1e-3）
& $py ai\scripts\mel_parity_test.py --n 12

# 导出与对齐管线校验（未训练权重，产物刻意不投放，仅供验管线）
& $py ai\scripts\t07_export_int8.py --pipeline-check --representative-n 120 --samples 18

# 有可达标训练时：正常导出 + 对齐 + 回填模型卡
& $py ai\src\quantize.py
& $py ai\scripts\t08_parity_test.py --n 64 --update-model-card
```

## ⚠️ 本机工具链缺陷（已修复，务必知悉）

`tf.lite.TFLiteConverter.from_keras_model()` 在 **Keras 3.15 + TF 2.21** 上**必然失败**：

```
TypeError: 'NoneType' object is not callable
  tensorflow/lite/python/tflite_keras_util.py:223  keras_deps.get_call_context_function()()
```

`src/quantize.py` 已加入 `from_concrete_functions` 回退（`route="auto"`），并打印实际使用的路线。
实测：回退路线产出 **1 096 936 字节（1.05 MB）** INT8 模型，`labelMatch = 1.000000`、
`maxConfDelta = 0.001302`。详见 `../records/reports/t07_t08_pipeline.md`。

## 数据与隐私

* `ai/data/raw/**` 与 `ai/data/augmented/**` **不进 Git、不进 APK**（`API-05` §3 类别 1）。
* 公共语料行 `subject_id` 必须为空；自采行必须是 `P<两位序号>`（`API-06` §3.1）。
* 现有 `P01`–`P05` 是**合成**语料，已在
  `../records/compliance/C-02/synthetic_corpus_notice.md` 显式声明；真实招募开始前必须先删除或重编号。
* 准入校验：`& $py ..\tool\check_consent_registry.py --strict`（R-11「未签不用」）。

# AcouDiet v1.3 模型发布说明（App 嵌入用）

**发布日期**：2026-09-13 ｜ **对应训练**：3 模型权重平均（Model Soup：KD + KD噪声 + D3冠军，val 选型）
**下游**：Role B（Flutter + Kotlin 原生 Mel 前端 + TFLite Interpreter）

> **v1.2 变更**（相对 v1.1）：正式嵌入模型内容更新为 **知识蒸馏训练的冠军**（EfficientAT mn10_as 教师，MIT）。聚合精度与 v1.1 持平（55.9% vs 55.7%），但**现场演示关键的类别可靠性显著提升**：drink F1 0.43→0.75（召回 0.53→0.85）、cabbage F1 0.18→0.42、chips 召回 0.83→0.85。I/O 契约不变，**替换 assets 文件即可，代码零改动**。

## 1. 包内清单

| 文件 | 用途 | 建议 |
|---|---|---|
| `models/acoudiet_fp32.tflite` | **正式嵌入模型**（KD 训练，parity 100%，桌面延迟 0.54ms） | App assets 使用 |
| `models/acoudiet_fp32_v1.1_legacy.tflite` | v1.1 冠军的 FP32 导出（回退用） | 如需对比保留 |
| `models/acoudiet_int8.tflite` | INT8 动态范围量化（v1.1 冠军） | 体积优选，精度 −3.25pp；QAT 后再评估 |
| `class_labels.json` | 类别 ID→名称映射（模型输出顺序唯一真源） | 解析输出用，**禁止硬编码** |
| `feature_config.json` | Mel 前端参数唯一真源 | Kotlin 端读取，**禁止硬编码** |

SHA256 见 `MANIFEST.sha256`。放置位置：`app/assets/models/`。

## 2. 模型 I/O 契约（冻结，与 v1.1 一致）

```
输入 : float32[1, 128, 128, 1]，值域 [0, 1]
       axis0=batch, axis1=mel 频率(低→高), axis2=时间(早→晚), axis3=单通道
输出 : float32[1, 6]，softmax 概率，顺序 = class_labels.json 的 id 0..5
       [chips, cabbage, gummies, noodles, carrot, drink]
```

`[0,1]→[-1,1]` 的 Rescaling 已在模型内部完成，**Kotlin 端不做值域映射**。

## 3. Kotlin Mel 前端规格（不变，与 feature_config.json 完全一致）

1. 采集：16 kHz、单声道、PCM 16-bit，环形缓冲 4.096s（65536 样本）
2. 预加重 `y[n]=x[n]−0.97·x[n−1]`，跨 patch 保留前一个原始样本
3. STFT：n_fft=1024，win=1024（Hann 周期窗），hop=512，center=True，零填充 → 129 帧
4. 功率谱 power=2.0
5. Mel：128 滤波器，20–8000Hz，Slaney 频刻 + 面积归一化
6. dB：`10·log10(max(x,1e-10))`，ref=patch max，top_db=80
7. 截断尾部第 129 帧 → 128 帧
8. per-patch minmax → [0,1]（min/max 每 patch 现算）
9. 推理步长 0.5s；对齐验收 `atol=1e-3`，覆盖首/中/尾/静音四类 patch

## 4. 参考性能（桌面 CPU）

| 模型 | 1 线程 avg | 备注 |
|---|---|---|
| v1.2 FP32（KD） | **0.54ms** | XNNPACK |
| v1.1 FP32 | 0.57ms | — |

远低于 50ms/patch 目标；真机瓶颈预计在 Kotlin Mel 前端。

## 5. 集成注意事项

1. 线程 1–2 个足够，单线程起测；
2. 精度现状：聚合 55.9%（Wilson CI 51.9–59.9%），**少样本类（drink/cabbage）可靠性较 v1.1 显著提升**；三级投票（EMA+稳定判据+低置信门控）照常使用；
3. 跨 patch 预加重状态必须连续（§3.2 规则）；
4. 标签顺序 = `class_labels.json` id 0..5，UI 文案取 `display_name_zh`。

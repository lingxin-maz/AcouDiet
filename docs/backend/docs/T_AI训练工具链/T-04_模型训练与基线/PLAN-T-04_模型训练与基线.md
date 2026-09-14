# PLAN-T-04 模型训练与基线

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-04` |
| 负责 | A |
| 目标日 | D2（基线）→ D3（增强训练） |
| 前置依赖 | `PLAN-T-02` 划分冻结；**`n_frames` 已修订（`ADR-21`，2026-09-12；FF-11 = `n_frames = 128` + `raw_mel_frames = 129`；原 `ADR-P1` 冻结值为 ~~129~~）**；`PLAN-T-03` 增强可用（D3 用）；CUDA 可用（否则按 §6 走 CPU） |
| 预估工时 | 12 h（含等待训练的时间，实际动手约 8 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/model.py` | Keras MobileNetV3-Small（FF-13/FF-14） |
| 2 | `ai/src/dataset.py` | 在线特征 + 在线增强的 DataLoader（只读 `train.csv`/`val.csv`） |
| 3 | `ai/src/train.py` | FF-17 训练循环 + 2 h 止损看门狗 |
| 4 | `ai/artifacts/saved_model/` | `SPEC-T-07` 的唯一量化输入 |
| 5 | `ai/artifacts/train_log.jsonl` | 每 epoch 曲线与设备信息 |
| 6 | `ai/artifacts/train_config.json` | **实测**参数量、epoch、设备、`selectionSplit`、划分 sha256 |
| 7 | `ai/artifacts/ckpt_{baseline,aug}/last.weights.h5` | 可 resume 的 checkpoint |
| 8 | `ai/tests/test_train.py` | 形状/止损/选择集判据（并入 `PLAN-C-05`） |
| 9 | 两次 run 的控制台记录 | 基线（D2）+ 增强（D3）的实际设备与耗时 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | Keras MobileNetV3-Small 构建 + 单通道适配 | `model.py` | 2 h | 环境 |
| 2 | DataLoader：在线特征（FF-02…FF-08）+ `train/val` 过滤 | `dataset.py` | 1.5 h | `PLAN-T-02` |
| 3 | FF-17 超参与损失（CE + LabelSmoothing 0.1） | `train.py` | 1.5 h | #1 #2 |
| 4 | `train_log.jsonl` / `train_config.json` 落盘 | 日志契约 | 1 h | #3 |
| 5 | **2 h 止损看门狗 + OOM 降级链** | 设备切换逻辑 | 1.5 h | #3 |
| 6 | GPU 跑基线（`--augment off`） | `run_id=baseline` | 1 h（含等待） | #4 #5 |
| 7 | 接入增强跑 D3（`--augment on`） | `run_id=aug` | 2 h（含等待） | #7 + `PLAN-T-03` |
| 8 | `test_train.py` + 泄漏 grep 复核 | 单测 | 1 h | #6 |

## 3. 技术方案
```python
# 骨架（≤30 行，非完整实现）
import json, time, numpy as np, tensorflow as tf
CFG = json.loads(open("shared/feature_config.json", encoding="utf-8").read())
N_FRAMES, N_CLS = CFG["n_frames"], CFG["num_classes"]        # FF-11 / FF-19
DEADLINE_S = 2 * 3600                                        # R-ENV-2 止损线

def build_model():
    base = tf.keras.applications.MobileNetV3Small(
        include_top=False, weights="imagenet",
        input_shape=(128, N_FRAMES, 1),        # FF-14
        minimalistic=False, include_preprocessing=True)
    x = tf.keras.layers.GlobalAveragePooling2D()(base.output)
    x = tf.keras.layers.Dropout(0.2)(x)
    return tf.keras.Model(base.input, tf.keras.layers.Dense(N_CLS, activation="softmax")(x))

def fit(model, ds_train, ds_val, run_id):
    lr = tf.keras.optimizers.schedules.CosineDecay(1e-3, decay_steps=50 * steps_per_epoch(),
                                                   alpha=1e-5 / 1e-3)
    model.compile(optimizer=tf.keras.optimizers.AdamW(lr, weight_decay=1e-4),
                  loss=tf.keras.losses.CategoricalCrossentropy(label_smoothing=0.1),
                  metrics=["accuracy"])
    cb = [tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=5,
                                           restore_best_weights=True),
          Watchdog(deadline_s=DEADLINE_S)]     # 超时 -> device="CPU" 并重跑剩余 epoch
    return model.fit(ds_train, validation_data=ds_val, epochs=50,
                     batch_size=32, callbacks=cb)
```

**关键约定**：
- `imagenet` 权重下载失败时 `weights=None` 并在 `train_config.json` 记 `pretrained=false`（`SPEC-T-04` §6）。
- 早停与最佳权重**只**看 `val_loss`；脚本中**禁止**出现 `test_public` / `test_mobile` 字面量（`PLAN-T-02` 判据 9）。
- **不得写死参数量**：`paramCount = model.count_params()` 实测后落盘。
- CPU 回退不改变 epoch 预算（保持与 `T-05` 可比）。
- 训练脚本的目录/设备选择使用 `--device auto|cpu|gpu`，默认 `auto`。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| 形状 | 单测 | `model.input_shape == FF-14`、`output_shape == (None, 6)` | D2 |
| 前向冒烟 | 单测 | 单 batch 前向输出 shape `(32, 6)`、每行和为 1±1e-5 | D2 |
| 止损线配置 | 单测 | watchdog 阈值常量 == 2 h；`train_config.json` 含 `device`/`deviceSwitchReason` | D2 |
| 设备降级演练 | 手动 | 人为把 batch 提到触发 OOM，观察自动降级并写日志 | D2 |
| 泄漏复核 | 单测 | `test_no_leakage.py::test_no_test_literal_in_train_code` 命中 0 | D2、D3 |
| 参数量 | 读配置 | `paramCount > 0` 且 grep `2.5M|2500000` 命中 0 | D2 |
| epoch/早停 | 读日志 | `epochsRun ≤ 50`；早停时 `epochsRun − bestEpoch ≤ 5` | D2、D3 |
| SavedModel 加载 | 集成 | `tf.saved_model.load()` 成功，签名可推理 | D2、D3 |
| 可复现 | 数值 | 同种子 1 epoch 首个 `trainLoss` 偏差 ≤ 1e-3 | D3 |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-04` §7 全部 13 条判据通过。
- [ ] `ai/artifacts/saved_model/` 已被 `PLAN-T-07` 成功 `from_saved_model()` 加载（D4 联调）。
- [ ] `run_id=baseline` 与 `run_id=aug` 两次 run 的 `train_config.json` 齐全，且**实际设备**已记录。
- [ ] 划分 sha256 与 `feature_config` sha256 已写入 `train_config.json`（供 `T-05` 复现）。
- [ ] 实测参数量已记录，**未**照抄旧文档的 2.5M。
- [ ] `SPEC-T-04` §9 的路线声明与实际执行路线一致（如启用备用路线已显式登记）。
- [ ] 未修改 `shared/feature_config.json`，未修改 `ai/data/splits/*.csv`。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **R-ENV-2 显存不足** | OOM / 2 h 未完成 | 按 `batch 32 → 16(+grad_accum 2) → CPU` 降级；CPU 预期 40–90 min / 50 epoch（可接受），**不得**削减 epoch |
| `n_frames` 修订值被误改 | 有人改写 FF-11 的 `n_frames` / `raw_mel_frames` 或缩短窗口 | **阻塞**：FF-11 现为 `n_frames = 128` + `raw_mel_frames = 129`（原 `ADR-P1` 冻结值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订）；改动会使已训练权重作废，必须走 `SPEC-C-03` 变更传播并重训。**D2 训练本身已不再受此阻塞** |
| ImageNet 权重不可得 | 下载失败 | `weights=None` 从零训练 + 报告中声明 `pretrained=false`；预计收敛变慢，D2 基线可能需延长 |
| GPU 被其他进程占用 | 显存不足报错 | 直接用 `--device cpu`；记录设备切换原因 |
| 训练发散 | loss NaN | lr → 5e-4 重跑一次并记录（工程容错，不算超参搜索） |
| 增强训练反而变差 | `val_macro_f1` 低于基线 | **不删基线**：两个 run 都保留，`T-05`/`T-06` 如实报告；由 `T-06` 消融定位是噪声、增益还是 SpecAugment |
| TensorFlow 环境不可用 | `import tensorflow` 失败 | 走 `SPEC-T-04` §9 备用路线 1（`onnx2tf`），并在所有材料中声明实际路线 |

## 7. 与检查点的关系
- **CP1（D3 晚，跨域实测）**：`run_id=aug` 的 `SavedModel` 是 `T-05` E2/E3 的输入。D3 出不了模型 → CP1 无数字。**这是关键路径上的节点**（`PLAN-00` §3：`D2 Baseline → D3 跨域评估 ★CP1 → D4 TFLite`）。
- **CP2（D5 晚，端到端闭环）**：`T-07` 的 INT8 模型来自本功能的 `SavedModel`；本功能延期会直接顺延 D4 → D5。
- **工时告警**：`PLAN-00` §5 指出 T 域仅 46 h、全项目余量 6 h（2.5%）。本功能两个 run 的训练等待时间必须与其他任务并行（D2 训练期间 A 同时做 `T-03`，D3 同时做 `T-05`/`T-06`）。
- **不可裁剪**：本功能是域 T 的模型来源，任何形式的新增功能都不允许占用它的窗口（`PLAN-00` §6 范围冻结，**已批准**：40 项交付 / 7 项裁剪，依据 `ADR-P5`）。

**文档结束**

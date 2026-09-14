# SPEC-T-04 模型训练与基线

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.2 / §3.3；`shared/feature_config.json`；`SPEC-00` §3.2 FF-13/FF-14/FF-15/FF-16/FF-17、§3.1 FF-11；`SPEC-T-02` §2.2 断言 D；`SPEC-T-03`；`docs/00_功能清单与数量分析.md` §2 |
| 依赖的 SPEC | `SPEC-T-02`（划分）、`SPEC-T-03`（增强开关）。下游：`SPEC-T-05` `SPEC-T-06` `SPEC-T-07` |

## 1. 目标与范围

### 1.1 一句话目标
用 **TensorFlow / Keras** 实现 MobileNetV3-Small（FF-13），在 FF-17 的配置下训练出**无增强基线（D2）**与**增强训练（D3）**两个模型，并导出 `SavedModel` 供 `SPEC-T-07` 做 INT8 量化；训练全程**不读测试集**。

### 1.2 范围内（In Scope）
1. `ai/src/model.py`：Keras 版 MobileNetV3-Small，输入 FF-14、输出 6 类 Softmax（FF-19）。
2. `ai/src/dataset.py`：读 `train.csv`/`val.csv`，在线特征提取（FF-02→FF-08）与在线增强（`SPEC-T-03`）。
3. `ai/src/train.py`：FF-17 的训练循环（AdamW / lr 1e-3→1e-5 / CosineAnnealing / batch 32 / ≤50 epoch / 早停 patience 5 / CE + LabelSmoothing ε=0.1 / ImageNet 预训练）。
4. 两次训练运行：`run_id=baseline`（`--augment off`，D2）与 `run_id=aug`（`--augment on`，D3）。
5. 导出 `SavedModel` 到 `ai/artifacts/saved_model/`（`SPEC-T-07` 的唯一输入）。
6. 实测并记录参数量（FF-15）、训练曲线、最佳 epoch 与选择依据（只依据 `val.csv`）。
7. **显存风险控制**：2 小时止损线 → 超时/OOM 立即切 CPU 训练（R-ENV-2）。
8. `--dry-run` 冒烟模式：跑 1 个 epoch 验证数据管线与形状，**不覆盖** `ai/artifacts/saved_model/`，供 `PLAN-C-05` 回归使用。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做 PyTorch→ONNX→TFLite 主路线**（已否决，见 §9）。
- **不做量化与 TFLite 导出**（`SPEC-T-07`）；本功能只交 `SavedModel`。
- **不做评估报告与 Wilson 区间**（`SPEC-T-05`）；本功能只输出训练期 `val` 曲线与混淆矩阵缓存供其复用。
- **不读 `test_public.csv` / `test_mobile.csv`**（`SPEC-T-02` 断言 D：源码零字面量命中）。
- **不做超参搜索**：FF-17 已冻结配置；不允许为刷分修改 lr/epoch/batch。
- **不做模型集成 / 蒸馏 / 剪枝 / 知识迁移**。
- 不修改 `shared/feature_config.json`（本域只读）；不修改划分文件。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 划分冻结 | `ai/data/splits/*.csv` 已产出且 `PLAN-T-02` 断言全通过 |
| **`n_frames` 已修订** | **✅ 已修订（`ADR-21`，2026-09-12；原 `ADR-P1`，2026-09-10）**：FF-11 = ~~`n_frames = 129`（选项 B，输入 `[1, 128, 129, 1]`）~~ → **`n_frames = 128`**（另有 `raw_mel_frames = 129`），输入形状 `[1, 128, 128, 1]`。**已拍板，D2 训练可直接开工**；改选选项 A 才会使权重全部作废（`SPEC-00` §3.5） |
| 增强可用 | `SPEC-T-03` 的 `augment.py` 已通过其 §7 判据（仅 `run_id=aug` 需要） |
| 环境 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`；装包经 `_toolchain\pip_runner.py --target D:\Desktop\Food\_toolchain\site-packages` |
| 设备 | CUDA 可用（torch 2.7.1+cu128 实测可用）；显存不足时按 §2.4 切 CPU |

### 2.2 主流程（编号步骤）
1. `train.py --run-id <baseline|aug> --augment {off,on} --seed <int>` 读 `shared/feature_config.json`（只读）与 FF-17 的超参默认值。
2. 构造 `dataset.py`：训练集只来自 `train.csv`，验证集只来自 `val.csv`；`val.csv` 内按 `subject_id` 区分「公共集验证行（`""`）」与「域适应验证行（`P04`/`P05`）」，两者分列统计（`API-06` §3.2）。
3. 构造模型：Keras `MobileNetV3Small(include_top=False, weights="imagenet", input_shape=(128, n_frames, 1), ...)` + GlobalAveragePooling + Dropout + 6 类 Dense Softmax；**输入通道在预处理层做单通道复制**（FF-14 是单通道输入）。
4. 编译：AdamW，`lr = 1e-3` → `1e-5` CosineAnnealing，`batch = 32`，损失 `CategoricalCrossentropy(label_smoothing=0.1)`。
5. 训练循环：≤50 epoch，`EarlyStopping(monitor="val_loss", patience=5, restore_best_weights=True)`；每个 epoch 末记录 `train_loss/val_loss/val_acc/val_macro_f1` 到 `ai/artifacts/train_log.jsonl`。
6. **止损看门狗**：启动计时；若 **2 h** 内未跑完计划的 epoch 预算，或触发 OOM，则**立即**保存最近 checkpoint、切换到 CPU 重新继续（R-ENV-2），并在日志写 `device_switch_reason`。
7. 训练结束：导出 `SavedModel` 至 `ai/artifacts/saved_model/`；写 `train_config.json`（含实测参数量、epoch 数、最佳 epoch、设备、`selectionSplit="val"`、划分 sha256）。
8. 打印实测参数量与 `SavedModel` 路径；**不打印任何准确率预测值**。

### 2.3 状态与状态迁移
训练运行是有状态的批处理，状态机为单次运行的阶段序列：

```
IDLE → DATA_READY → MODEL_BUILT → RUNNING(GPU) ⇄ RUNNING(CPU) → BEST_SAVED → EXPORTED
                                        │
                                        └─ OOM / 2h 超时 → WATCHDOG_SWITCH → RUNNING(CPU)
```
- checkpoint 每 epoch 覆盖写 `ai/artifacts/ckpt_<run_id>/last.weights.h5`；`BEST_SAVED` 以 `val_loss` 最优权重为准。
- 训练中断（人工 Ctrl-C 或崩溃）后允许 `--resume` 从 `last.weights.h5` 继续；**不允许**用测试集结果决定是否 resume。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| GPU OOM | 先降 batch（32 → 16，`grad_accum=2` 保持等效 batch），仍 OOM → 切 CPU |
| 2 h 未完成 | 立即切 CPU 并继续同一超参配置；**不得**为赶时间减少 epoch（会破坏与 `T-05` 的可比性） |
| CPU 训练时长 | 预期约 40–90 min / 50 epoch（MobileNetV3-Small + 11k 片段规模），属可接受范围 |
| `val` 某类样本数为 0 | 报错退出（`exit 6`），回 `SPEC-T-02` §6 处置 |
| `train.csv` 为空 / 列缺失 | 报错退出（`exit 1`） |
| 训练发散（loss = NaN） | 终止该 run；**只允许**把 lr 下调到 `5e-4` 重跑一次并记录（属工程容错，非超参搜索） |
| `n_frames` 被改选 | **必须**重新训练；旧权重不得复用（`SPEC-00` §3.5） |
| 训练中断（Ctrl-C / 崩溃） | 允许从 `last.weights.h5` `--resume` 继续；**不得**因中断而修改 FF-17 的任何超参 |
| 混合精度（AMP） | 默认**关闭**；10 天窗口内不引入新变量。若为省显存必须开启，须记录并在 `T-05` 报告中声明与 GPU 非 AMP run 的不可比性 |
| 类别顺序错位 | 构建模型时断言 `class_labels` 的顺序与 FF-19 一致；顺序错位属致命缺陷（会让全指标失真） |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/train.py --run-id <id> --augment {on,off} [--epochs 50] [--seed 20260910] [--device auto\|cpu\|gpu]` | 划分 CSV、`feature_config` | 退出码 0；`SavedModel`、`train_log.jsonl`、`train_config.json` | 非零退出码（1/6）；张量形状不符沿用 `ACD-INF-002`、帧数不符 `ACD-MEL-001`（`API-00` §3.5） |
| 函数 | `build_model(n_frames: int, num_classes: int) -> keras.Model` | `n_frames`（FF-11）、`num_classes`（FF-19） | Keras 模型 | — |
| 制品 | `SavedModel` 目录（`SPEC-T-07` 输入） | — | `ai/artifacts/saved_model/{saved_model.pb,variables/,assets/}` | — |
| 日志 | `ai/artifacts/train_log.jsonl` | — | 每 epoch 一行 JSON | — |
| 配置 | `ai/artifacts/train_config.json` | — | 实测参数量 / epoch / 设备 / `selectionSplit` / 划分 sha256 | — |
| CLI（冒烟） | `python ai/src/train.py --run-id smoke --epochs 1 --dry-run` | 同上 | 退出码 0；**不写制品** | — |
| 消费方 | `SPEC-T-07` 的 `TFLiteConverter.from_saved_model()` | `SavedModel` | `.tflite` | 见 `SPEC-T-07` |

> 本功能不跨端；`SavedModel` 属**离线中间产物**，不进 App 制品清单（`API-05` §7）。

## 4. 数据契约
- 输入：`ai/data/splits/train.csv`、`val.csv`（**只这两个**）；`shared/feature_config.json`（只读）。
- 输入张量：形状 FF-14、`dtype=float32`、值域 `[0,1]`（FF-08）。
- 输出张量：`[1, 6]` Softmax（FF-19）。
- `train_log.jsonl` 每行字段：`runId, epoch, step, trainLoss, valLoss, valAcc, valMacroF1, lr, device, elapsedS, augment, denoise, seed`。
- `train_config.json` 字段：`runId, createdAtMs, nFrames, inputShape, numClasses, paramCount（实测）, epochsRun, bestEpoch, selectionSplit:"val", device, deviceSwitchReason, baseSeed, augment, denoise, splitSha256, featureConfigSha256, kerasVersion, tfVersion`。
- `docs/common/docs_api/schemas/` 下无对应 schema；上述两个 JSON 为**离线中间产物**，其权威定义在本 SPEC。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 架构 | FF-13（MobileNetV3-Small，TensorFlow/Keras） |
| 输入/输出 | FF-14 |
| 参数量 | FF-15（**约 1.5 M，以实测为准，禁止照抄旧文档的 2.5M**） |
| 体积目标 | FF-16（FP32 ≤ 6 MB；INT8 ≤ 2.5 MB —— **两档都可交付**，`ADR-21` 起按模型卡申报档位取上限）—— 由 `SPEC-T-07` 验收 |
| 训练配置 | FF-17（AdamW / lr 1e-3→1e-5 / CosineAnnealing / batch 32 / ≤50 epoch / 早停 patience 5 / CE + LabelSmoothing 0.1 / ImageNet 预训练） |
| 运行时 | FF-18（`tflite_flutter` + XNNPACK）—— 由 B 侧验收，本功能不涉及 |
| 六类枚举 | FF-19 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 预加重 / 窗 / hop / `n_mels` / 压缩 / 归一化 | FF-02 … FF-08 |

**本域自有常量（非 FF）**：随机种子默认 `20260910`；GPU 止损线 **2 h**（R-ENV-2）；CPU 预期时长 40–90 min / 50 epoch（R-ENV-2）；OOM 降级序列 `batch 32 → 16(+grad_accum 2) → CPU`。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| GPU OOM | `tf.errors.ResourceExhaustedError` | 降 batch → 仍失败则切 CPU；写 `deviceSwitchReason` | 无 UI；日志 |
| 2 h 未完成 | 看门狗计时 | 切 CPU 继续；**不减少 epoch** | 无 |
| 训练发散 | `val_loss` 为 NaN | 终止 run；允许 lr→5e-4 重跑一次并记录 | 无 |
| `val` 缺类 | 每类计数 | 非零退出 `exit 6` | 无 |
| 输入形状与 FF-14 不符 | 模型构建断言 | 抛错终止；提示检查 FF-11 的修订值（~~`n_frames = 129`~~ → `n_frames = 128`，`ADR-21`） | 无 |
| `train.py` 命中测试集字面量 | `SPEC-T-02` 判据 9 的 grep | 视为「用测试集调超参」，非零退出 | 无 |
| 预训练权重下载失败 | Keras 报错 | 用 `weights=None` 从零训练，并在 `train_config.json` 标记 `pretrained=false`；报告中必须声明 | 无 |
| 预训练权重下载被误认为"引入了网络依赖" | 代码审查 | 澄清：下载发生在**开发机训练时**，与 App 的 FF-24 第 4 条（APK 不申请 `INTERNET`）无关；脚本中须以注释标明该唯一例外 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 基线训练可完成 | `python ai/src/train.py --run-id baseline --augment off` | 退出码 == 0 |
| 2 | 增强训练可完成 | `python ai/src/train.py --run-id aug --augment on` | 退出码 == 0 |
| 3 | SavedModel 存在且可加载 | `ls ai/artifacts/saved_model/` + `tf.saved_model.load()` | 目录含 `saved_model.pb` 且加载成功、无异常 |
| 4 | 输入形状合规 | `pytest ai/tests/test_train.py::test_input_shape` | `model.input_shape == FF-14` |
| 5 | 输出形状合规 | `test_train.py::test_output_shape` | `model.output_shape == (None, 6)` |
| 6 | 参数量实测并落盘 | 读 `ai/artifacts/train_config.json` | `paramCount > 0` 且为**实测值**（无任何预填常数） |
| 7 | 禁止照抄旧参数量 | grep `ai/src/` | `2500000` / `2.5M` 命中数 == 0 |
| 8 | 不读测试集 | `pytest ai/tests/test_no_leakage.py::test_no_test_literal_in_train_code`（`SPEC-T-02` 判据 9） | 命中数 == 0 |
| 9 | 模型选择只用 val | 读 `train_config.json` | `selectionSplit == "val"` |
| 10 | 早停与 epoch 上限生效 | 读 `train_log.jsonl` | `epochsRun ≤ 50` 且（若触发早停）`epochsRun − bestEpoch ≤ 5` |
| 11 | 止损线已实现 | `test_train.py::test_watchdog_configured` | `train_config.json` 含 `device` 与 `deviceSwitchReason` 字段；watchdog 阈值 == 2 h（常量可读） |
| 12 | 无预填预测值 | grep 全部新增文档与脚本 | 不含形如「准确率 85%」「预计 XX%」的预测数字（人工核对 + `PLAN-C-05` 清单） |
| 13 | 训练日志可复现 | 同种子重跑 1 epoch 比对首个 `trainLoss` | 相对偏差 ≤ 1e-3（TF 非确定性算子影响下允许该容差） |
| 14 | 类别顺序与 FF-19 一致 | `pytest ai/tests/test_train.py::test_class_order` | 模型输出顺序 == `feature_config.class_labels` |
| 15 | 冒烟模式不污染制品 | `python ai/src/train.py --run-id smoke --epochs 1 --dry-run` | 退出码 == 0，且 `ai/artifacts/saved_model/` 未被覆盖（mtime 不变） |
| 16 | 训练脚本无网络出口 | grep `ai/src/train.py` | `http` / `requests` / `urlopen` 命中数 == 0（仅预训练权重下载是例外，须在脚本中显式标注） |

## 8. 非功能约束
- **设备**：训练在开发机（CUDA 可用）；**`flutter`/Gradle 构建与本功能无关**，且**必须在沙箱外的普通终端执行**——本功能不需要任何构建命令。
- **耗时预算**：单 run ≤ 4 h（含 CPU 回退）；两个 run 合计 ≤ 8 h，落在 `PLAN-00` §5 的 T 域 46 h 预算内。
- **内存**：训练进程 RSS ≤ 16 GB；数据以在线方式生成，**不整库载入内存**。
- **隐私**：训练语料含自采音频，仅在本机使用，**不上传、不入 Git、不进任何网络路径**（FF-24 的隐私主张由 App 侧承载，训练侧同样不得引入外传）。
- **可复现**：固定种子 + 固定划分 sha256 + 固定超参；`train_config.json` 是复现的唯一凭据。
- **不落盘中间特征**：禁止缓存 Mel 到磁盘（与 `SPEC-T-03` §8 一致）。
- **依赖**：TensorFlow 2.21.0（经 `_toolchain\pip_runner.py --target D:\Desktop\Food\_toolchain\site-packages` 安装）；版本号写入 `train_config.json` 以便复现。
- **不得占用 App 侧构建**：本功能**不需要**任何 `flutter`/Gradle 命令；构建命令属 B/C 的职责，且**必须在沙箱外的普通终端执行**。
- **日志体量**：`train_log.jsonl` 每 epoch 一行（≤50 行/run），允许入 Git 以便答辩展示训练曲线。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| **主路线（必须遵守）** | **TF/Keras 直训 → `SavedModel` → `TFLiteConverter.from_saved_model()`**（FF-13）。 |
| **PyTorch→ONNX→TFLite 已否决** | 主方案 §3.2 已明确否决：MobileNetV3 的 **Hardswish 与 SE（Squeeze-Excitation）** 在 PyTorch→ONNX→TFLite 转换链上**大概率失败**，且**即使转换成功也可能静默损失精度**（与 `SPEC-T-08` 的「静默精度损失」风险同源）。**禁止**把该链条作为主路线。 |
| 备用路线 1 | PyTorch 训练 → `onnx2tf` 转换。**仅在** Keras 路线因环境阻塞无法在 D2 出基线时启用，且启用后 `T-08` 的数值对齐测试门槛不变。 |
| 备用路线 2 | PyTorch 训练 → **等价 Keras 权重迁移**（逐层映射到 `MobileNetV3Small`）。仅在备用路线 1 也失败时启用。 |
| 备用路线登记 | 无论启用哪条备用路线，**必须**在 `SPEC-T-05` 的报告与 PPT 中显式声明实际路线，不得默认声称走的是 Keras 直训。 |
| `X-06` RIR/Mixup | 与本功能无关（属 `SPEC-T-03` 的裁剪）。 |
| 若本功能被裁剪 | 后果：无模型 → `T-05`/`T-07`/`T-08` 全部不可交付 → CP1、CP2 及 App 的 `P-05` 全部失守。**本功能是域 T 的不可裁剪项。** |
| 不可裁剪声明 | 本功能不在主方案 §8.2.1 五项的字面列表中，但它是三项（实时检测闭环、自动生成记录、健康报告）赖以成立的模型来源，**实际不可裁剪**。 |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）」**已拍板为 ~~`n_frames = 129`（选项 B，输入 `[1, 128, 129, 1]`）~~ → 已由 `ADR-21`（2026-09-12）修订为 `n_frames = 128`**（`raw_mel_frames = 129`，输入 `[1, 128, 128, 1]`）。它同时决定的四处（`model.input_shape` FF-14、`SavedModel` 签名、`model_card.nFrames`、Kotlin 常量）**已全部同步为 128 / 129 两个数**。**结论：本功能不再是「拍板前不得开工」的硬约束方，D2 训练可直接开工**；改选选项 A 才会使权重作废（`SPEC-00` §3.5 明示），且必须走 `SPEC-C-03` 变更传播。
2. **`API-06` 已落盘**：`train_config.json` 属**离线中间产物**，`API-06` §1 的制品清单未收录它（该清单只约束 6 个 JSON/PNG 与制品 tflite）；其字段名（`nFrames`/`inputShape` 的驼峰写法）已按 `API-06` §4/§5 的命名风格统一。若后续要把训练配置纳入契约，须走 `SPEC-C-03`。
3. **类别不平衡是否加类别权重**：FF-17 未规定。本 SPEC 默认**不加**（保持与主方案一致），但这可能压低小吃类召回。**需 A 在 D2 前决策**；若加，须在 `T-05` 报告中声明并同步 `T-06` 消融说明。
4. **预训练权重的离线可得性**：`imagenet` 权重需一次性联网下载，训练环境若受限则退化为从零训练。此降级会显著影响收敛速度，**需在 D0–D2 内确认**。
5. **CPU 回退后的可比性**：GPU 与 CPU 的浮点累加顺序不同，可能带来轻微指标差异。若发生设备切换，**必须**在 `T-05` 报告中记录两个 run 的实际设备。

**文档结束**

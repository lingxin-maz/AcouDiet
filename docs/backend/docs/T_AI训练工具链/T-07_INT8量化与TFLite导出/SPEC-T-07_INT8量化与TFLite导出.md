# SPEC-T-07 INT8 量化与 TFLite 导出

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 · **硬闸门** |
| 上游依据 | 主方案 §3.2 / §3.3 / §5.1、修正 `N-4`；`shared/feature_config.json`；`SPEC-00` §3.1 FF-08/FF-11、§3.2 FF-13/FF-14/FF-15/FF-16/FF-18、§3.3 FF-19；`API-05` §7/§7.1；`API-01` §2.1/§3.2；`SPEC-T-04`、`SPEC-T-08` |
| 依赖的 SPEC | `SPEC-T-04`（`SavedModel`）；`SPEC-T-08`（回填 parity 字段）。下游：`SPEC-P-05`（端侧集成） |

## 1. 目标与范围

### 1.1 一句话目标
把 `SavedModel` 转成 **INT8 TFLite**（体积 ≤ FF-16 的 INT8 上限，即 **2.5 MB**）与 FP32 对照版，并产出字段完整、三个 hash 闭环的 `model_card.json`，使 App 侧拿到的模型是**可追溯、可校验、不会被静默替换**的制品。

### 1.2 范围内（In Scope）
1. SavedModel → **INT8 权重量化（PTQ）TFLite，I/O 保持 `float32`**，代表性数据集校准。
   > ⚠️ **术语红线（ADR-20）**：不写「全整数量化」/「full-integer」。TFLite 语境里「全整数量化」特指
   > **int8 I/O**，而本域交付的是 **INT8 权重 + float32 I/O**（见 §2 第 4 条）。两种读法都"合法"，
   > 所以这里必须写明是哪一种 —— App 侧不做任何量化/反量化，I/O 类型错了就是打包错误。
2. 产出 `ai/artifacts/model_int8.tflite`（主交付）与 `ai/artifacts/model_fp32.tflite`（对照）。
3. 产出 `ai/artifacts/model_card.json`，字段**逐字**按 `API-05` §7 定义：
   `name / version / createdAtMs / quantization / inputShape / numClasses / classLabels / nFrames / melVersion / featureConfigSha256 / tfliteSha256 / tfliteBytes / parityLabelMatch / parityMaxConfDelta / metricsRef`。
4. **三个 hash 必须闭环**（`API-05` §7.1）：
   - `model_card.nFrames == feature_config.n_frames`
   - `model_card.melVersion == Kotlin MelFrontend.melVersion`
   - `model_card.tfliteSha256 == sha256(app/assets/models/*.tflite)`
5. 实测并登记参数量（FF-15；**禁止照抄旧文档的 2.5M**，主方案 `N-4`）。
6. 交付到 App 侧：`app/assets/models/` 下的 TFLite 与 `ai/artifacts/model_int8.tflite` **字节完全相同**（仅重命名）。
7. 体积、加载、推理形状三项自检（§7）。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做训练**（`SPEC-T-04`）；**不做数值对齐测试的实现**（`SPEC-T-08`，本功能只提供制品与其 `parity*` 字段的**回填位置**）。
- **不做 float16 / 动态范围量化的选型对比**：INT8 是 FF-16 的目标，别的量化只是被否决的备选（§10）。
- **不使用 `SELECT_TF_OPS` / Flex delegate**：端侧 `tflite_flutter` 不加载 flex delegate，使用它会在真机上直接失败。
- **不做端侧推理引擎实现**（`P-05`，B 负责）；**不做 NNAPI 委托配置**（FF-18）。
- **不做模型热更新**：制品只有"构建期打包入境"一个方向（`API-05` §3.1 规则 R-OUT-3）。
- **不修改 `shared/feature_config.json`**（本域只读）、**不修改 Kotlin `MelFrontend` 的 `melVersion`**（那是 B 的实现版本号，A **不得**代填）。
- **不在本功能内宣称任何精度指标**：`parityLabelMatch` / `parityMaxConfDelta` 由 `SPEC-T-08` 实测回填；`metricsRef` 指向 `SPEC-T-05` 的产物。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| SavedModel | `ai/artifacts/saved_model/` 已产出且可被 `tf.saved_model.load()` 加载（`SPEC-T-04` 判据 3） |
| ✅ `n_frames` 已修订 | **FF-11 = `n_frames = 128`（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~，`129` 现为 `raw_mel_frames`）—— 本闸门的第一项闭合前提已满足**（§2.4、§10.1） |
| representative dataset | 取自 `train.csv` + `val.csv`（**绝不含 `test_public` / `test_mobile`**），且走与训练**同一条** FF-02→FF-08 管线 |
| Kotlin 侧 | `P-04` 的 `MelFrontend.melVersion` 已由 B 公布（用于闭环校验；**A 不代填**） |
| 环境 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`；装包经 `_toolchain\pip_runner.py --target D:\Desktop\Food\_toolchain\site-packages` |

### 2.2 主流程（编号步骤）
1. `python ai/src/export_tflite.py --out-dir ai/artifacts` 读 `shared/feature_config.json`（只读）与 `SavedModel`。
2. 构造 representative dataset：从 `train.csv` + `val.csv` 分层抽取 **200 个 patch**（每类 ≥20），逐 patch 走 FF-02→FF-08；**不允许**从 `test_*.csv` 取样。
3. `TFLiteConverter.from_saved_model(...)`；设置 `optimizations = [Optimize.DEFAULT]` + `representative_dataset`；`target_spec.supported_ops = [TFLITE_BUILTINS]`（**禁止** `SELECT_TF_OPS`）。
4. **I/O 类型固定为 `float32`**：`inference_input_type = tf.float32`、`inference_output_type = tf.float32`。理由：`API-01` §3.2 的 `mel` 是 `Float32List`、`P-06` 消费的是 float 概率；若改成 int8 I/O，端侧必须新增一套量化/反量化逻辑，等于在 Dart 侧再造一份数值实现（与 `SPEC-T-08` 的"唯一 Mel 实现"原则冲突）。
5. 写 `ai/artifacts/model_int8.tflite`；同法（不加 `optimizations`）写 `ai/artifacts/model_fp32.tflite` 作对照。
6. 计算 `tfliteBytes`（字节数）、`tfliteSha256`、`featureConfigSha256`；读 `model.count_params()` 得实测参数量。
7. 生成 `model_card.json`：`parity*` 两个字段先写 `null`（待 `SPEC-T-08` 回填），其余字段全部填实。
8. 自检：体积 ≤ FF-16；用 `tf.lite.Interpreter` 加载并前向一次，断言输入形状 == FF-14、输出形状 `(1, 6)`、输出行和 ≈1。
9. 拷贝到 App 侧：`app/assets/models/<API-05 §7 命名>`，并断言其 sha256 与 `ai/artifacts/model_int8.tflite` 相等。
10. `python ai/scripts/parity_test.py --check-card` 执行三 hash 闭环校验（`SPEC-T-08` 提供）。

### 2.3 状态与状态迁移
```
SAVEDMODEL_READY → CONVERTED(INT8) → CONVERTED(FP32) → CARD_WRITTEN(parity=null)
        → PARITY_PASSED（T-08 回填 parity*）→ CARD_FINAL → DELIVERED_TO_APP（hash 闭环）
```
- **闸门语义**：只有到达 `CARD_FINAL` 且 `--check-card` 退出码 0，才允许进入 App 联调（`PLAN-P-05` / CP2）。
- 任一步失败：制品保留但**不得**交付到 `app/assets/models/`。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| INT8 体积 > FF-16 上限 | **硬闸门不通过**：先查是否误留 Flex ops / 未量化层；仍超标则上报，由 `PLAN-T-07` §6 决策（不允许"先交付再优化"） |
| FP32 体积 > FF-16 的 FP32 上限 | 同样不通过（FP32 是对照，不是主干，但仍须达标） |
| 转换过程需要 `SELECT_TF_OPS` | **视为失败**：说明有算子无 TFLITE_BUILTINS 实现，须回 `SPEC-T-04` 调整实现（如去掉不支持的预处理层），**不得**启用 flex |
| `n_frames` 与本 SPEC 修订值不符（FF-11 = ~~129~~ → 128，`ADR-21`） | **✅ 已冻结，不再产生 `PENDING_DECISION`**（退出码 2 仅保留给 Kotlin 未就绪等其他未决输入）；比对 `feature_config`，实现值与之不符 → 退出码 10，**禁止**用硬编码值让闸门"假装闭合" |
| `melVersion` 未由 B 公布 | 字段写 `null` 并记 `notes`；`--check-card` 返回退出码 2（同 PENDING 语义） |
| `app/assets/models/` 不存在 | 创建目录并复制；目录路径不存在不算失败 |
| 同名制品被替换 | 交付时的 sha256 断言失败 → 退出码 10（制品被换过） |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/export_tflite.py --out-dir ai/artifacts [--representative-n 200]` | `SavedModel`、`feature_config`、`train.csv`/`val.csv` | 退出码 0；两个 `.tflite` + `model_card.json` | 非零退出码（1/2/10）；输入形状不符沿用 `ACD-INF-002`（`API-00` §3.5） |
| CLI | `python ai/scripts/parity_test.py --check-card` | `model_card.json`、`feature_config`、`app/assets/models/*.tflite`、Kotlin `melVersion` | 退出码 0（闭合）/2（输入未就绪，如 Kotlin `melVersion` 未公布）/10（不符） | 见 §2.4 |
| 制品 | `model_int8.tflite` → `app/assets/models/` | — | 字节相同 | — |
| 制品 | `model_card.json` | — | 随仓库，不打包（`API-05` §7） | — |
| 消费方 | `SPEC-P-05`（`tflite_flutter` 加载，FF-18） | — | — | `ACD-INF-001` / `ACD-INF-003` |

## 4. 数据契约

`ai/artifacts/model_card.json`（字段与示例结构权威定义在 `API-05` §7；**数值必须实测，禁止预填**）：

| 字段 | 类型 | 值域/来源 | 说明 |
|---|---|---|---|
| `name` | string | `"acoudiet"` | — |
| `version` | string | `"1.0.0"` | 与 `API-05` §7 一致；变更即需重跑闸门 |
| `createdAtMs` | int | 生成时刻 | — |
| `quantization` | string | `"fp32"` \| `"int8"` | **按卡片申报档位**（`ADR-21`：两档都可交付，~~本制品固定 `"int8"`~~）；文件名随之写 `<name>_<quantization>_v<version>.tflite` |
| `inputShape` | int[] | 取自 `feature_config.input_shape` | **不得硬编码**（FF-14） |
| `numClasses` | int | `feature_config.num_classes` | FF-19 |
| `classLabels` | string[] | `feature_config.class_labels` | FF-19 的 6 个 ID |
| `nFrames` | int | `feature_config.n_frames` | ✅ **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| `melVersion` | string | **B 侧** `MelFrontend.melVersion` | A **不得**代填（`API-01` §2.1）；**已由 `ADR-21`（2026-09-12）由 `1.0.0` 递增为 `1.1.0`**（Mel 数值行为变了就必须递增） |
| `featureConfigSha256` | string | `sha256(shared/feature_config.json)` | 64 hex |
| `tfliteSha256` | string | `sha256(model_int8.tflite)` | 64 hex |
| `tfliteBytes` | int | 文件字节数 | 须 ≤ FF-16 的 INT8 上限 |
| `parityLabelMatch` | number \| null | **`SPEC-T-08` 回填** | 生成时为 `null` |
| `parityMaxConfDelta` | number \| null | **`SPEC-T-08` 回填** | 生成时为 `null` |
| `metricsRef` | string | `"ai/artifacts/metrics.json"` | `SPEC-T-05` 产物 |

- **三个 hash 闭环**（`API-05` §7.1）是本功能的核心验收，由 `parity_test.py --check-card` 执行。
- **命名说明（需人工确认）**：任务冻结的域内产物名为 `model_int8.tflite` / `model_fp32.tflite`；而 `API-05` §7 的制品表写的是 `acoudiet_int8_v<X>.tflite` 交付到 `app/assets/models/`。本 SPEC 的做法是：**域内保持 `model_int8.tflite`，交付到 App 时按 `API-05` §7 命名重命名，sha256 不变**。两者若有冲突以 `API-05` 为准（§5 交叉引用规则）。
- `docs/common/docs_api/schemas/` 下当前无 `model_card.schema.json`；**建议补齐**（见 §10）。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 架构 | FF-13（TensorFlow/Keras MobileNetV3-Small） |
| 输入/输出 | FF-14（`[1, 128, n_frames, 1]` → 6 类 Softmax） |
| 参数量 | FF-15（**约 1.5 M，以实测为准，禁止照抄旧文档的 2.5M**，主方案 `N-4`） |
| 体积目标 | FF-16（FP32 ≤ 6 MB；**INT8 ≤ 2.5 MB** ← 硬闸门） |
| 运行时 | FF-18（`tflite_flutter` + XNNPACK；NNAPI 失败静默回退 CPU） |
| 六类枚举 | FF-19 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 归一化（代表性数据集必须沿用） | FF-07 / FF-08（`ADR-21`：`power_to_db(ref = "patch_max", top_db = 80)` → 丢尾帧 → `normalization = "per_patch_minmax"`；~~旧「固定 dB 截断 `clip(x,−80,0)` 再 min-max；禁止 `ref=np.max`」~~ **已反转**） |

**本域自有常量（非 FF）**：代表性数据集样本数 `200`（每类 ≥20，**不含测试集**）；`supported_ops = [TFLITE_BUILTINS]`；`inference_input_type = inference_output_type = tf.float32`；交付目标目录 `app/assets/models/`；`--check-card` 退出码语义 `0=闭合 / 2=输入未就绪（如 Kotlin melVersion 未公布）/ 10=不符`。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 转换要求 `SELECT_TF_OPS` | 转换器抛错或 warning | **终止**：回 `SPEC-T-04` 调整层实现；不得启用 flex delegate | App 侧无感（未交付） |
| INT8 体积超标 | `os.path.getsize` | 闸门不通过；排查未量化层与 flex 残留；上报 | 无 |
| FP32 体积超标 | 同上 | 同上（FP32 亦须 ≤ FF-16 上限） | 无 |
| 代表性数据集取样含测试集 | 源码 grep + `notes` 记录来源 | 视为**泄漏**：非零退出，重新导出 | 无 |
| `melVersion` 未公布 | 字段为 `null` | 闸门返回 2（待办），交付物标记 `PENDING` | App 侧握手会抛 `ACD-CFG-001` |
| `n_frames` 与修订值不符（FF-11 = ~~129~~ → 128，`ADR-21`） | 比对 `feature_config` | 退出码 10（不符）；**✅ 已冻结，不再产生 `PENDING_DECISION`**；**禁止**用硬编码值让闸门"假装闭合" | 无 |
| 交付后 sha256 不符 | `--check-card` | 退出码 10；视为制品被替换，立即回滚并查因 | 无 |
| Interpreter 加载/前向失败 | 加载与推理自检 | 非零退出；**不得**交付 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 导出成功 | `python ai/src/export_tflite.py --out-dir ai/artifacts` | 退出码 == 0 |
| 2 | INT8 制品存在 | 文件检查 | `ai/artifacts/model_int8.tflite` 存在 |
| 3 | **INT8 体积达标** | `python -c "import os;print(os.path.getsize('ai/artifacts/model_int8.tflite'))"` | ≤ FF-16 的 INT8 上限（**2.5 MB**） |
| 4 | FP32 对照达标 | 同上 | ≤ FF-16 的 FP32 上限（6 MB） |
| 5 | 无 Flex ops | 转换脚本断言 + 加载自检 | `supported_ops == [TFLITE_BUILTINS]`，且转换未见 `SELECT_TF_OPS` 回退 |
| 6 | I/O 为 float32 | `interpreter.get_input_details()[0]['dtype'] == float32` | 输入与输出 dtype 均为 `float32` |
| 7 | 形状正确 | 加载自检 | 输入形状 == FF-14；输出形状 == `(1, 6)`；输出行和 ∈ `[0.999, 1.001]` |
| 8 | 制品卡字段完整 | `pytest ai/tests/test_model_card.py::test_fields` | §4 的 **15 个字段全部存在**（`parity*` 允许为 `null`） |
| 9 | **三 hash 闭环** | `python ai/scripts/parity_test.py --check-card` | `n_frames` 已修订（`ADR-21`，`FF-11 = 128`；旧值 ~~`FF-11 = 129`~~）；B 公布 `melVersion` 后退出码 == 0（未公布则 == 2） |
| 10 | 交付字节一致 | `sha256` 比对 | `app/assets/models/*.tflite` 与 `ai/artifacts/model_int8.tflite` sha256 相等 |
| 11 | 参数量实测 | 读导出日志/制品字段 | 参数量为 `model.count_params()` 实测值；grep `2500000` / `2.5M` 命中数 == 0（主方案 `N-4`） |
| 12 | 代表性数据集无测试集 | grep `ai/src/export_tflite.py` | `test_public` / `test_mobile` 命中数 == 0 |
| 13 | **patch 相对 dB 参考未被替换** | grep `ai/src/features.py` + `augment.py` | **必须**使用 `power_to_db_ref = "patch_max"`；不含绝对刻度 `ref=1.0` / 固定 dB 截断 `clip(x,−80,0)` / `db_clip_range`（命中数 == 0）。⚠️ **本判据已随 `ADR-21`（2026-09-12）反转**：原文为「归一化未被替换 —— `ref=np.max` / `ref="max"` 命中数 == 0」 |
| 14 | 可复现 | 同 SavedModel 重跑导出的 sha256 | 两次 `model_int8.tflite` sha256 相等 |
| 15 | 模型卡版本字段 | 读 `model_card.json` | `name == "acoudiet"`、`quantization ∈ {"fp32","int8"}`（**按卡片申报档位**，`ADR-21`；~~固定 `"int8"`~~）、`version == "1.0.0"`、`melVersion == "1.1.0"`（`ADR-21`；~~`"1.0.0"`~~） |

## 8. 非功能约束
- **体积**：FF-16 是**硬闸门**；INT8 制品文件本身必须 ≤ 上限，不允许靠 APK 压缩、分包或动态下载规避（后者违反 `API-05` §3.1 R-OUT-3）。
- **兼容性**：产物必须能在 `tflite_flutter` + XNNPACK（FF-18）下加载；**禁用** flex delegate 与任何 `tf.*` 自定义算子。
- **可追溯**：`model_card.json` + `metrics.json` + 划分 sha256 构成完整溯源链；制品无溯源 = 不可交付。
- **性能**：导出流程在 CPU 上 ≤ 15 min。
- **隐私**：代表性数据集仅用于校准（读入内存、不落盘、不上传）；**不得**把任何音频写入制品或上传（FF-24 精神，训练侧同样适用）。
- **无网络**：制品只有构建期打包入境一个方向；导出脚本**不得**引入任何网络调用。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| `X-06` RIR/Mixup | 与本功能无关，但其裁剪意味着量化后的模型**没有混响鲁棒性增强**；该缺口只能由 `SPEC-T-05` 的 E2 跨域数字暴露，**须在报告与 QA 中主动说明**。 |
| float16 / 动态范围量化 | **不做**（FF-16 指定 INT8；对照只做 FP32）。 |
| 逐层量化敏感度分析（sensitivity analysis） | **不做**；后果：若某些层量化后精度损失明显，只能靠 `SPEC-T-08` 的 parity 与 `T-05` 的数字发现，无法定位到层。 |
| `SELECT_TF_OPS` / flex delegate | **明确不做**（端侧不支持）。 |
| 模型热更新 / 网络下载模型 | **不做**（`API-05` §3.1 R-OUT-3）。 |
| 若本功能被裁剪 | 后果：App 无模型可加载（`P-05` 直接失败）→ CP2（D5 端到端闭环）与 CP3（三模式 Demo）全部失守；且 FF-16 的「≤2.5 MB」作为差异化卖点消失。**本功能是四项硬闸门之一（`docs/00_功能清单` §1），不可裁剪。** |
| 不可裁剪声明 | 本功能属主方案 §8.2.1 五项中「①实时检测闭环」「⑤三种 Demo 模式」的必要前置，**不可裁剪**。 |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）—— 本闸门在拍板前无法闭合的直接技术原因」**已随 2026-09-10 拍板解除、并已由 `ADR-21`（2026-09-12）修订**：~~`n_frames = 129`（选项 B，输入 `[1, 128, 129, 1]`）~~ → `n_frames = 128`（`raw_mel_frames = 129`，输入 `[1, 128, 128, 1]`），它同时决定的五处（①模型输入形状 FF-14、②`SavedModel` 签名、③`model_card.nFrames`、④`feature_config.n_frames`、⑤Kotlin `MelFrontend` 常量）**已全部同步为 128 / 129 两个数**，任何一处不同仍会触发 App 侧 `ACD-CFG-001` 或 `ACD-MEL-001`。**结论：本闸门不再因 `n_frames` 停在退出码 2**；选项 A（128 / 4.064 s / 65024 样本）已否决，若日后改选必须走 `SPEC-C-03` 变更传播，**不得**用硬编码值让它"通过"。
2. **制品命名（已由 `API-06` §1/§10 裁定）**：交付到 App 的文件名为 `<name>_<version>.tflite`，即 `app/assets/models/acoudiet_int8_v1.0.0.tflite`；**域内中间产物名**保留 `ai/artifacts/model_int8.tflite`（`model_fp32.tflite` 为对照，不交付），交付时**重命名复制、字节不变**，故 `tfliteSha256` 对两者相同。任务书给出的 `model_int8.tflite` 与 `API-05` §7/`API-06` §10 的命名由此统一，**无需再拍板**。
3. **`melVersion` 的公布时点（需 B 确认）**：`P-04` 的实现版本号是闭环的必要输入，但它是 B 的产物。**若 D4 前未公布，闸门只能停在退出码 2**，D5 的 App 联调将缺少一项安全网。
4. **✅ `API-06` 已落盘且与本 SPEC 一致**：其 §5 的 `model_card` 15 字段与 §9 的七条闸门判定式（含 `inputShape` / `classLabels` / `tfliteBytes` / `thresholds` 三项）已全部并入本 SPEC §4 与 §7；差异说明：`API-06` §5 要求 `parityLabelMatch` / `parityMaxConfDelta` **不可空**，故 D4 必须完成 `SPEC-T-08` 的回填后闸门才算闭合（本 SPEC §2.3 的 `CARD_FINAL`）。
5. **`docs/common/docs_api/schemas/` 的覆盖缺口**：`API-06` §8 声明 `metrics.schema.json` 与 `feature_config.schema.json` 为该契约的机器可读版本，但**没有 `model_card.schema.json`**，本 SPEC 判据 8 目前只能人工比对字段。**建议补齐**（与 `parity_report` / `ablations` 同批），使闸门可完全机器化。
6. **`inference_input_type` 的选择**：本 SPEC 选 float32 I/O（保 App 契约简单）。改用 int8 I/O 可再省体积/提速，但会要求端侧实现量化/反量化，**须 A+B 共同评估**；当前决定是**不改**。

**文档结束**

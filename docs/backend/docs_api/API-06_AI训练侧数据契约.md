# API-06 AI 训练侧数据契约

| 项 | 值 |
|---|---|
| 上游依据 | 主方案 §5.2（`features.py` / `parity_test.py`）、§7.2（划分与防泄漏）、§7.4（评估报告必报项）、§9（Demo）；`SPEC-00` §3.1（FF-01~FF-12）、§3.2（FF-13~FF-18）、§3.3（FF-19）、§3.5（**FF-11 `n_frames` = 128 / `raw_mel_frames` = 129，2026-09-12 由 `ADR-21` 修订**）；`API-00` §3.1/§3.5；`API-05` §7（制品契约）/§7.1（三 hash 闭环） |
| 层级位置 | **不在 `API-00` §1 的运行时分层图内**：本文件是图中「制品导入（构建期，一次性）」箭头的契约，即 **离线训练侧（`ai/`）↔ App 侧（`app/`）的边界**。方向为**入境**（`API-05` §3.1 R-OUT-3：只允许构建期打包，运行时不得从网络更新） |
| 适用功能编号 | `T-01`（数据集获取与清洗）、`T-02`（划分与防泄漏校验）、`T-03`（增强管线）、`T-04`（训练与基线）、`T-05`（评估与指标报告）、`T-06`（消融实验）、`T-07`（INT8 量化与导出）、`T-08`（数值对齐） |
| 权威定义 | **本文件是下列文件契约的唯一权威定义**：`shared/feature_config.json` 的**交付与同步规则**、`ai/data/splits/*.csv` 的列与划分规则、`ai/artifacts/metrics.json`、`ai/artifacts/model_card.json`、`ai/artifacts/ablations.json`、`ai/artifacts/parity_report.json`、`ai/artifacts/confusion_matrix.png` 的字段与交付闸门。字段级机器可读版本见 `docs/common/docs_api/schemas/metrics.schema.json` 与 `docs/common/docs_api/schemas/feature_config.schema.json` |
| 非权威（只引用） | `feature_config.json` 的**数值**权威是该文件本身（`SPEC-00` §3 为其文字说明）；`foods.json` 见 `API-04` §2；App 侧资产目录与打包规则见 `SPEC-C-04`；`model_card` 字段清单与 `API-05` §7 必须逐字一致 |

---

## 1. 文件清单、方向与打包规则

| # | 路径 | 方向 | 是否打包进 APK | 契约权威 | 校验 |
|---|---|---|---|---|---|
| 1 | `shared/feature_config.json` | 双向真源（**只读**） | 是（构建期同步为 `app/assets/feature_config.json`） | 文件自身（数值）+ 本文件 §2（同步规则） | `docs/common/docs_api/schemas/feature_config.schema.json`；`API-00` §3.6 握手 12 字段一致 |
| 2 | `ai/data/splits/train.csv` `val.csv` `test_public.csv` `test_mobile.csv` | 离线内部 | ❌ | 本文件 §3 | `T-02` 防泄漏断言 |
| 3 | `ai/artifacts/metrics.json` | A → 报告/测试报告/PPT | ❌ | 本文件 §4 | `docs/common/docs_api/schemas/metrics.schema.json`；`T-05` 必报项齐全 |
| 4 | `ai/artifacts/model_card.json` | A → App 侧与答辩 | ❌ | 本文件 §5 | §9 三 hash 闭环 |
| 5 | `ai/artifacts/ablations.json` | 离线内部 | ❌ | 本文件 §6 | 与 `metrics.json.ablations` 摘要一致 |
| 6 | `ai/artifacts/parity_report.json` | A → 交付闸门 | ❌ | 本文件 §7 | 阈值与 `SPEC-T-08` 一致 |
| 7 | `ai/artifacts/confusion_matrix.png` | A → 测试报告/PPT | ❌ | 本文件 §8 | 人工核对 + 与 `metrics.json` 矩阵一致 |
| 8 | `app/assets/models/<name>_<quantization>_v<version>.tflite` | A → App | ✅（只读） | `SPEC-T-07` + 本文件 §5/§9 | 体积 ≤ **FF-16 中该档自己的上限**（fp32 6 MB / int8 2.5 MB）；`sha256` == `model_card.tfliteSha256` |

**三条交付规则**：
1. **禁止运行时下载/热更新任何制品**（`API-05` §3.1 R-OUT-3）；模型更新只能靠发新 APK。
2. `ai/data/` 下的原始音频与增强产物**不进 Git**、不进 APK、不进 `artifacts/`（`API-05` §3 类别 1）。
3. 每个 `artifacts/*.json` 顶部必须有 `schemaVersion`，且必须与本节表格版本一致；字段新增 = 版本递增（§10）。

## 2. `shared/feature_config.json`（唯一真源，**只读**）

| 项 | 规则 |
|---|---|
| 写入者 | 仅 `C-03`（`SPEC-C-03`）；任何实现方**不得**通过代码写入或"补默认值" |
| 读取者 | AI 侧 `ai/src/config.py`；App 侧构建期同步为 `app/assets/feature_config.json`，由 `PLAN-C-03` 的代码生成器转成 Dart 常量（**禁止手写字符串键名**，`API-00` §3.1） |
| 命名 | `snake_case`（Python 侧可读优先），是本项目 JSON 中**唯一**允许 `snake_case` 的文件（`API-00` §3.1 例外条款） |
| 同步验收 | ① `docs/common/docs_api/schemas/feature_config.schema.json` 校验通过（⚠️ 该 schema 是否已随 `ADR-21` 的 41→49 键更新，见 `SPEC-C-03` §10 #5，**本文件未复核**）；② App 侧副本与 `shared/` 原文件**字节相等**（构建脚本断言，禁止人工复制）；③ `API-00` §3.6 握手的 **15 个字段**（`ADR-21`；原 ~~12~~）与 Kotlin 编译期常量全等 |
| 变更流程 | 走**变更传播单**（**共 14 项** = P-1~P-9 + A-1/A-2/ADR-05/ADR-07/ADR-09；表在 `SPEC-C-03` §7 附表，`PLAN-C-03` 做打勾登记）；涉及 Mel 数值行为 → 递增 `melVersion` 并**重跑 `SPEC-T-08` 对齐测试** |
| 只读性 | 仓库内**不存在**对该文件的写入代码路径；App 运行期只读（`API-05` §3.1 R-OUT-3） |

**✅ `n_frames` 已修订（FF-11 / `ADR-21`，2026-09-12）**：
- 文件中的值为 `n_frames = 128`、`raw_mel_frames = 129`、`input_shape = [1, 128, 128, 1]`、`frame_selection = {drop_tail, [0,128)}`。
- **修订依据**：模型组交付的制品实测输入张量是 `float32[1,128,128,1]`（128×128×4 = 65536 字节），而 129 帧的 Mel 是 66048 字节 —— **根本喂不进去**，不是"差一帧的笔误"。窗口仍是 4.096 s（65536 样本），只是归一化前丢掉尾帧，与训练侧 `operation_order` 逐字一致。
- **上一版（已被取代）**：`n_frames = 129`、`input_shape = [1,128,129,1]`，2026-09-10 由 `ADR-P1` 拍板（选项 B）。ADR-P1 的三条理由仍然成立，它只是无法预见到训练侧按 128 帧出制品。详见 `ADR-21` 与 `SPEC-00` §3.5。
- `model_card.nFrames` 必须为 **128**（由 `T-07` / `tool/install_model.py` 按 §5 填入）；四处（`feature_config` / `model_card` / Kotlin 常量 / Dart 输入张量断言）必须**同时**一致并重跑 §7 的对齐测试。两份 schema 若仍写着 `const: 129`，**以本文件与 `SPEC-00` §3.1 为准**（见 §2 的 open issue 登记）。

## 3. `ai/data/splits/*.csv`

### 3.1 列定义（四份文件列名与顺序**完全一致**）

| 列 | 类型 | 可空 | 约束 |
|---|---|---|---|
| `path` | `string` | 否 | 相对仓库根的音频路径；同一 `path` **只能出现在一份 CSV 中** |
| `label` | `string` | 否 | ∈ `feature_config.class_labels`（FF-19，6 类）；储备类别不得出现 |
| `subject_id` | `string` | 否 | 自采录音填 `P<两位序号>`（`API-00` §3.4）；公共数据集填**空字符串** `""`（无主体信息） |
| `source_file_id` | `string` | 否 | 原始录音文件标识：自采填会话 ID/文件名去扩展名，公共集填原始文件名去扩展名（`API-00` §3.4） |
| `split` | `string` | 否 | ∈ `train` / `val` / `test_public` / `test_mobile`；必须与所在文件名一致 |

### 3.2 划分规则（`T-02` 权威）

| 子集 | 来源 | 规则 |
|---|---|---|
| `train.csv` / `val.csv` / `test_public.csv` | 公共数据集 | **按 `source_file_id` 划分**（同一原始录音的全部切片只进一个子集），比例目标 70% / 15% / 15% |
| `test_mobile.csv` | 自采集手机数据 | **只含 `P01`/`P02`/`P03`**，绝不进训练（主方案 §7.2） |
| 域适应微调 | 自采集 | `P04`/`P05` **只可用于验证集**，不得进 `train.csv` |

**四条禁止行为**（写进代码注释 + 评审清单）：① 同一次进食会话的片段跨子集；② 同一人片段跨子集；③ 测试集参与任何增强；④ 用测试集调超参。

### 3.3 防泄漏断言（`T-02` 必须自动执行，失败即退出非 0）

| # | 断言 |
|---|---|
| 1 | 四份 CSV 的 `path` 集合**两两不相交** |
| 2 | `test_mobile.csv` 的 `subject_id` 集合 ⊆ `{P01,P02,P03}`，且该集合与 `train.csv` / `val.csv` 的 `subject_id` 集合**不相交** |
| 3 | `train.csv` / `val.csv` 的 `subject_id` 集合不相交（`P04`/`P05` 只允许出现在 `val.csv`） |
| 4 | `train.csv` 与 `val.csv` 内部的 `source_file_id` 集合**不相交**（公共集按文件划分） |
| 5 | 每个子集的每个类别样本数 `> 0`，且打印类别分布表（暴露不平衡） |
| 6 | 全部 `label` ∈ `class_labels`；全部 `split` 列与文件名一致 |

- 错误码：`ACD-ART-002`（划分泄漏）等，见 §11。
- 单元测试要点：构造一个「同一 `subject_id` 同时出现在 train 与 test_mobile」的坏数据，断言断言 2 失败且 `stderr` 含 `ACD-ART-002`。

## 4. `ai/artifacts/metrics.json`（`T-05`，必报项缺一不可）

> **数值一律为 D3/D4 实测产出**（`SPEC-00` §8 禁令 1）。本文件**不预填任何预测值**；schema 只约束字段存在性与类型。
> 机器可读权威：`docs/common/docs_api/schemas/metrics.schema.json`。

| 必报项（主方案 §7.4 逐条对应） | `metrics.json` 字段 |
|---|---|
| ① 总体 Top-1 + Wilson 95% CI | `overall.top1`、`overall.wilson95.{low,high}`、`overall.n`（`statsmodels.proportion_confint(..., method='wilson')`） |
| ② 每类 P/R/F1 + 宏平均 + 加权平均 | `perClass[].{label,support,precision,recall,f1}`、`macroAvg.{precision,recall,f1}`、`weightedAvg.{precision,recall,f1}` |
| ③ 混淆矩阵（6×6，或 7 类含「未识别」） | `confusionMatrix.{labels,matrix}`；`labels` 顺序必须为 `class_labels`，若含「未识别」则置于**末位** |
| ④ 每类测试样本数 | `perClass[].support`，且 `Σ support == overall.n` |
| ⑤ in-domain vs 跨域对照 | `domainComparison[]`：每项 `{testSet, top1, n, wilson95}`，`testSet` ∈ `{test_public, test_mobile}` |
| ⑥ 三级实验矩阵 E1/E2/E3 | `experimentMatrix[]`：每项 `{id, trainOn[], evalOn, top1, n, wilson95}`，`id` ∈ `{E1,E2,E3}`（含义见主方案 §3.11） |
| ⑦ 推理延迟 | `latency.patchInferenceMs.{p50,p90,max,deviceModel,delegate}`、`latency.endToEndConfirmSeconds.{median,p90}`（端到端确认延迟的机制上限见 FF-20a，**此处只填实测值**） |
| ⑧ 消融表 | `ablations[]`：每项 `{id, name, toggle, top1, n, deltaVsBaseline}`；**至少**含基线行与「降噪 on/off」「各增强 on/off」行（`X-06` 已裁剪项不得出现）。完整结果见 §6 `ablations.json`，两处同名条目必须数值一致 |

| 顶层字段 | 类型 | 约束 |
|---|---|---|
| `schemaVersion` | `string` | 当前 `"1.0"` |
| `generatedAtMs` | `int` | epoch 毫秒（UTC） |
| `modelRef` | `string` | 指向 `ai/artifacts/model_card.json` |
| `nFrames` | `int` | 必须等于 `feature_config.n_frames`，即 `n_frames = 128`（**`ADR-21` 修订**，见 FF-11） |

- 缺失任一必报项 → `ACD-ART-005`，报告不得定稿。
- 单元测试要点：① schema 校验通过；② `Σ perClass[].support == overall.n`；③ `confusionMatrix.matrix` 每行之和 `== ` 对应类的 `support`；④ `experimentMatrix` 恰含 E1/E2/E3 三项；⑤ `ablations` 含基线行。

## 5. `ai/artifacts/model_card.json`（`T-07`；字段清单与 `API-05` §7 逐字一致）

| 字段 | 类型 | 可空 | 约束 |
|---|---|---|---|
| `name` | `string` | 否 | 固定 `"acoudiet"` |
| `version` | `string` | 否 | 语义化版本；与 tflite 文件名一致（`API-00` §3.4） |
| `createdAtMs` | `int` | 否 | epoch 毫秒（UTC） |
| `quantization` | `string` | 否 | 枚举 `"fp32"` / `"int8"`。**两档都可交付**（`ADR-21` 纠正）：FF-16 对两档都给了上限，App 侧按**卡片申报的档位**取对应上限并据它推导文件名 `<name>_<quantization>_v<version>.tflite`。~~"交付 App 的必须是 `int8`"~~ 是旧表述，已作废 |
| `inputShape` | `array<int>` | 否 | 必须等于 `feature_config.input_shape`，即 `[1, 128, n_frames, 1]`，其中 `n_frames = 128`（**`ADR-21` 修订**；`raw_mel_frames = 129` 是 STFT 原始帧数，**不是**张量宽度） |
| `numClasses` | `int` | 否 | 必须等于 `feature_config.num_classes`（FF-14） |
| `classLabels` | `array<string>` | 否 | 必须与 `feature_config.class_labels` **顺序逐字相等**（FF-19） |
| `nFrames` | `int` | 否 | ✅ **已修订（`ADR-21`）**：`n_frames = 128`（见 FF-11）；必须等于 `feature_config.n_frames` |
| `melVersion` | `string` | 否 | 必须等于 Kotlin `MelFrontend.melVersion`（`API-01` §2.1），否则握手抛 `ACD-CFG-001` |
| `featureConfigSha256` | `string` | 否 | `sha256(shared/feature_config.json)`，64 位小写 hex |
| `tfliteSha256` | `string` | 否 | `sha256(app/assets/models/*.tflite)`，64 位小写 hex |
| `tfliteBytes` | `int` | 否 | 实际字节数；必须 `≤` **FF-16 中 `quantization` 那一档自己的上限**（fp32 6 MB / int8 2.5 MB） |
| `parityLabelMatch` | `double` | 否 | 来自 §7 `parity_report.json`，`[0,1]` |
| `parityMaxConfDelta` | `double` | 否 | 来自 §7，`≥ 0` |
| `metricsRef` | `string` | 否 | 固定指向 `ai/artifacts/metrics.json` |

## 6. `ai/artifacts/ablations.json`（`T-06`）

| 字段 | 类型 | 约束 |
|---|---|---|
| `schemaVersion` | `string` | `"1.0"` |
| `generatedAtMs` | `int` | epoch 毫秒（UTC） |
| `baseline` | `object` | `{id, top1, n}`；`id` 与 `metrics.json.ablations` 的基线行一致 |
| `runs` | `array<object>` | 每项 `{id, name, toggle, top1, n, macroF1, deltaVsBaseline, note}`；`toggle` 表达开/关组合；`deltaVsBaseline` 为**实测差值**（可为负，不得填报"预期提升"） |

- 范围：降噪 on/off、环境噪声/随机增益/LUFS/SpecAugment 组合 on/off（`T-06` 简化版）。
- **`RIR 混响` 与 `Mixup`（`X-06`）不得出现**在任何 `name` / `toggle` 中。
- 错误码：`ACD-ART-001`、`ACD-ART-005`。

## 7. `ai/artifacts/parity_report.json`（`T-08` 硬闸门产物）

| 字段 | 类型 | 约束 |
|---|---|---|
| `schemaVersion` | `string` | `"1.0"` |
| `generatedAtMs` | `int` | epoch 毫秒（UTC） |
| `sampleCount` | `int` | 参与比对的样本数（`parity_test.py --n` 的实际值） |
| `labelMatch` | `double` | 训练侧管线 vs TFLite 部署管线的 Top-1 标签一致率，`[0,1]` |
| `maxConfDelta` | `double` | 最大置信度偏差，`≥ 0` |
| `thresholds` | `object` | `{labelMatch, maxConfDelta}`；取值见主方案 §5.2 的 `THRESH`（与 `SPEC-T-08` 一致），**本文件不重复写死数值** |
| `mismatches` | `array<string>` | 标签不一致的样本路径；为空数组表示全部一致 |
| `melParity` | `object` | `{sampleCount, atol, maxAbsDiff, passed}`：Python 侧 `librosa` 与 Kotlin `MelFrontend` 的 `np.allclose` 结果；`atol` 取自 `PLAN-T-08` 的验收阈值 |
| `pipeline` | `object` | `{pythonVersion, kerasVersion, tfliteRuntimeVersion}`，用于复盘环境差异 |

- **判定语义**：`labelMatch ≥ thresholds.labelMatch` **且** `maxConfDelta ≤ thresholds.maxConfDelta` **且** `melParity.passed == true` → 闸门通过；任一不满足 → 禁止把该 `.tflite` 放入 `app/assets/models/`。
- 错误码：`ACD-ART-003`（hash 闭环失败）、`ACD-ART-001`（字段缺失）。

## 8. `ai/artifacts/confusion_matrix.png`

| 项 | 要求 |
|---|---|
| 来源 | `ai/src/evaluate.py` 生成，**不得**手工绘制或美化后再交付 |
| 轴标签 | 顺序必须与 `metrics.json.confusionMatrix.labels` 一致（`class_labels`，可选末位「未识别」） |
| 数值 | 与 `metrics.json.confusionMatrix.matrix` 逐格一致（评审时抽查） |
| 用途 | 测试报告与 PPT；**不打包进 APK** |
| 缺失后果 | `ACD-ART-005`（必报项 ③ 的可视化产物缺失） |

## 9. 交付闸门（`API-05` §7.1 的三 hash 闭环，此处给完整判定式）

```
① model_card.nFrames        == feature_config.n_frames          （否则张量形状不符）
② model_card.melVersion     == Kotlin MelFrontend.melVersion     （否则握手抛 ACD-CFG-001）
③ model_card.tfliteSha256   == sha256(app/assets/models/*.tflite)（否则制品被替换）
④ model_card.inputShape     == feature_config.input_shape
⑤ model_card.classLabels    == feature_config.class_labels        （顺序逐字相等）
⑥ model_card.tfliteBytes    == 实际文件字节数，且 ≤ FF-16 中该 quantization 档自己的上限
⑦ parity_report.thresholds  == 主方案 §5.2 THRESH（与 SPEC-T-08 一致），且三项判定全过
⑧ parity_report.modelParityMeasured == true（`labelMatch`/`maxConfDelta` 必须是**测出来的**；
                                     写死或缺失都不得被读成"通过"）
```

- ✅ **`n_frames` 已修订（`ADR-21`，`SPEC-00` §3.5 / FF-11）：`n_frames = 128`，另有 `raw_mel_frames = 129`**。它同时决定模型输入形状、`model_card`、`feature_config`、Kotlin 常量四处，**四处已全部同步为 128 / 129 两个数**；任何改动须走 `SPEC-C-03` 变更传播。
- ⚠️ **`labelMatch` / `maxConfDelta` 必须是实测值**：`ai/scripts/mel_parity_test.py` 早先把它们**无条件写死**为 `1.0` / `0.0`，而本闸门会据此放行 —— 即闸门可能在一个**没人计算过**的数字上通过。现由该脚本把 Kotlin 与 Python 两侧的 Mel **分别**喂给同一个出厂解释器实测；无模型时写 `null` + `modelParityMeasured: false`，闸门**拒绝**（新增判定 ⑧）。
- 闸门脚本必须**失败即退出非 0**，且 `stderr` 首行含对应 `ACD-ART-*` 错误码，便于 CI 与人工排查。

## 10. 版本、命名与变更

| 项 | 规则 |
|---|---|
| 制品文件名 | `<name>_<quantization>_v<version>.tflite`（`API-00` §3.4 + `ADR-21`），例 `acoudiet_fp32_v1.0.0.tflite`、`acoudiet_int8_v1.0.0.tflite`。INT8 档的名字与旧规则逐字相同，故无兼容性成本 |
| `schemaVersion` | 任一 JSON 制品新增/删除/改义字段 → 递增；仅改数值不递增 |
| 变更传播 | 任何字段变更按 `API-00` §3.9 在 `PLAN-C-03` 登记，并同步更新本文件与 `docs/common/docs_api/schemas/*.json` |
| 重跑要求 | 涉及内存布局/数值口径（`n_frames`、Mel 参数、归一化）→ **必须重跑 `SPEC-T-08` 对齐测试**并更新 `parity_report.json` 与 `model_card.parity*` |
| 关联网 | `feature_config` 变更 → 递增 `melVersion`（当且仅当 Mel 数值行为变化，`API-01` §2.1） |

## 11. 错误码（离线工具；建议在 `API-00` §3.5 新增 `ACD-ART` 区域）

| 错误码 | 触发 | 使用方 |
|---|---|---|
| `ACD-ART-001` | 制品字段缺失 / 类型不符 / Schema 校验失败 | 各 `artifacts/*.json` 生产者与校验脚本 |
| `ACD-ART-002` | 数据划分泄漏（`path` 重复、`subject_id` 或 `source_file_id` 跨子集、`test_mobile` 含非 `P01–P03`） | `T-02` |
| `ACD-ART-003` | hash 闭环失败（`tfliteSha256` / `featureConfigSha256` 不匹配） | §9 闸门 |
| `ACD-ART-004` | 形状/帧数不一致（`inputShape`、`nFrames` 与 `feature_config` 不符；含与 `ADR-21` 的 `n_frames = 128` 不符）；或 `.tflite` 体积超过 FF-16 中该档上限 | §9 闸门 |
| `ACD-ART-005` | 指标报告缺必报项或可视化产物缺失 | `T-05` / §4 / §8 |

> ⚠️ `ACD-ART` 为**新增区域码**：`API-00` §3.5 是错误码权威表，本文件**未修改** `API-00`；该区域码须先补登 `API-00` §3.5 才生效（登记动作归 `PLAN-C-03`）。离线脚本的退出码约定：`0` = 通过；非 `0` = 失败，`stderr` 首行含错误码。

## 12. 校验与测试要点（写入 `PLAN-T-02` / `PLAN-T-05` / `PLAN-T-07` / `PLAN-T-08`）

| # | 命令 / 测试 | 通过判据 |
|---|---|---|
| 1 | 对 6 个制品跑 JSON Schema 校验（含本文件 §2~§7 全部 JSON） | 全部通过；失败报 `ACD-ART-001` |
| 2 | `T-02` 防泄漏断言 | §3.3 六条断言全过；构造坏数据必须报 `ACD-ART-002` |
| 3 | `python ai/scripts/parity_test.py --n 50` | 退出码 `0`；`labelMatch` / `maxConfDelta` / `melParity` 三项均达 §7 阈值（判定式见 `SPEC-T-08`） |
| 4 | §9 闸门脚本 | 七条判定式全过；把 `model_card.tfliteSha256` 故意改一位 → 报 `ACD-ART-003` |
| 5 | `metrics.json` 一致性 | `Σ support == overall.n`；矩阵行和 == `support`；`experimentMatrix` 含 E1/E2/E3；`ablations` 含基线行 |
| 6 | 体积与权限 | `.tflite` ≤ FF-16 中该档上限（fp32 6 MB / int8 2.5 MB）；`aapt dump badging` 无 `INTERNET`（`API-05` §12 判据 1） |
| 7 | 只读性 | 全仓搜索对 `shared/feature_config.json` 的写操作命中数为 0 |
| 8 | 禁用项 | `ablations.json` / `metrics.json` 中不含 `RIR` / `Mixup` / `nuts`（`X-06` / FF-19） |

## 变更影响

改本契约会波及：

| 类型 | 受影响对象 |
|---|---|
| SPEC | `SPEC-T-01`~`SPEC-T-08`（尤其 `T-02` 划分判据、`T-05` 必报项、`T-07` 制品字段、`T-08` 阈值）、`SPEC-C-03`（配置真源与变更传播）、`SPEC-C-04`（打包与体积）、`SPEC-C-05`（回归套件）、`SPEC-A-04`（演示数据集复用 `diet_record` schema） |
| PLAN | `PLAN-T-02` `PLAN-T-05` `PLAN-T-07` `PLAN-T-08`、`PLAN-C-03`、`PLAN-C-04`；变更登记归 `PLAN-C-03` |
| Schema | `docs/common/docs_api/schemas/metrics.schema.json`、`docs/common/docs_api/schemas/feature_config.schema.json`（本文件 §2/§4/§5 的机器可读版本，必须同步） |
| 上游需同步 | 若改 `model_card` 字段清单 → 必须同步 `API-05` §7（该表为交付契约的另一半）；若改 Mel 形状 → 必须同步 `API-01` §2.1/§3.2 与 `API-00` §3.6 握手字段 |
| 测试 | `PLAN-T-08` 对齐测试（硬闸门）、`PLAN-C-05` 回归套件、`API-05` §12 判据 6（制品闭环） |
| 宣传材料 | 任何指标进入 PPT 必须按 `SPEC-00` §3.10 口径书写（含 Wilson 区间与每类样本数；**不得**使用预测值） |

## 明确不做

| 不做 | 理由 |
|---|---|
| 运行时下载 / 热更新模型与配置 | `API-05` §3.1 R-OUT-3；破坏「无 INTERNET 权限」证据 |
| 把 `ai/data/` 的原始音频、切片、增强产物提交进 Git 或打进 APK | `API-05` §3 类别 1；FF-24 第 1 条 |
| RIR 混响增强与 Mixup（`X-06`） | 已裁剪；`ablations.json` 中不得出现 |
| 储备类别 `nuts` 的训练与制品 | FF-19：不进 v1.0 |
| 在制品或报告中写入预测/目标准确率、延迟、参数量 | `SPEC-00` §8 禁令 1；一律「D3/D4 实测产出」 |
| 云端评估服务、在线 A/B、埋点上报 | `API-05` §1 裁定（v1.0 无任何网络出口） |
| 把 `confusion_matrix.png` 打包进 APK | 体积与用途均无必要；属测试材料 |
| 由 App 侧读取 `ai/artifacts/*` | 除 §1 表中标记为「打包」者外，App 运行期不得访问离线制品 |

---

**文档结束**

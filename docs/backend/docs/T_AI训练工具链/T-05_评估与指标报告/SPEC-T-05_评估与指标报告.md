# SPEC-T-05 评估与指标报告

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.5 / §3.8 / §10.2；`SPEC-00` §3.4 FF-20a/FF-20b、§3.2 FF-14/FF-15/FF-16/FF-18、§3.1 FF-11、§7（验收写法）、§8 写作禁令；`SPEC-T-01`/`SPEC-T-02`/`SPEC-T-04`/`SPEC-T-06`/`SPEC-T-07`；`docs/00_功能清单与数量分析.md` §2 |
| 依赖的 SPEC | `SPEC-T-02`（测量集）、`SPEC-T-04`（模型）、`SPEC-T-06`（消融表）、`SPEC-T-07`（延迟测量对象） |

## 1. 目标与范围

### 1.1 一句话目标
把 `T-04` 训好的模型在 E1/E2/E3 三级实验矩阵上评估，产出**含 Wilson 95% 置信区间**的完整指标报告（`ai/artifacts/metrics.json` + `confusion_matrix.png`），使每一个数字都可以被评委按样本量复核。

### 1.2 范围内（In Scope）
1. **三级实验矩阵**：
   - **E1** 公共集 → 公共集（`train` 训练、`test_public` 评估）：**上限参考**，不代表真实使用效果。
   - **E2** 公共集 → 自采手机集（`test_mobile`，`P01`–`P03`）：**域差异核心数字**。
   - **E3** 公共集 + 自采集 → 自采手机集跨人（域适应收益）：以 `P04`/`P05` 为验证集做域适应后的评估。
2. **必报项（缺一不可，共 7 项）**：
   ① 总体 Top-1 准确率 + **Wilson 95% 置信区间**；
   ② 每类 Precision / Recall / F1 + 宏平均 / 加权平均；
   ③ 混淆矩阵（6×6；若启用「未识别」口径则为 7 类，含 `unknown` 行列）；
   ④ 每类测试样本数（support）；
   ⑤ in-domain（E1）vs 跨域（E2/E3）对照；
   ⑥ 推理延迟（单 patch ms + 端到端确认延迟 s）；
   ⑦ 消融实验表（引用 `ai/artifacts/ablations.json`，产出方 `SPEC-T-06`）。
3. 产出 `ai/artifacts/metrics.json`（字段结构见 §4）与 `ai/artifacts/confusion_matrix.png`。
4. 报告必须能被 `docs/common/docs_api/schemas/metrics.schema.json` 校验通过。
5. 记录实验溯源信息（划分 sha256、`feature_config` sha256、模型 sha256、种子、增强/降噪开关、设备），使同一实验集合可复现。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做训练**（`SPEC-T-04`）；**不做量化导出**（`SPEC-T-07`）；**不做消融实验的运行**（`SPEC-T-06`，本功能只汇总其表）。
- **不做超参调优**：`test_public` / `test_mobile` **绝不参与**任何选型决策（`SPEC-T-02` 断言 D）。
- **不做阈值标定**：FF-20b 的三档阈值标定属端侧 `P-06`/`T-05` 协作，本功能**只提供置信度分布直方图数据**（`confidenceHistogram` 字段），标定结论由 `PLAN-P-06` 落地。
- **🔴 绝对禁止编造或预测任何准确率/置信区间/延迟/参数量数字**：计划书、SPEC、PLAN、PPT 中**不得出现预测值**；三个矩阵的数字**全部由 D3/D4 实测产出，实测多少写多少**。这是本项目已犯过一次并被纠正的错误（主方案 v3.1 自查删除了 85–95% / 55–80% 这类自造预测值），**不得重犯**。
- **不报「最好一次」的数字**：禁止挑选最好 seed、最好 epoch 后单独报告；每个矩阵只报告**一个**冻结模型的完整结果。
- 不做 McNemar / bootstrap 等高级显著性检验（10 天窗口内 Wilson 区间已足够），登记为推迟项。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 模型冻结 | `SPEC-T-04` 的 `SavedModel`（及 `SPEC-T-07` 的 INT8 TFLite）已产出且 sha256 登记 |
| 划分冻结 | 四个划分 CSV 的 sha256 与本功能记录的溯源一致 |
| 消融 | `SPEC-T-06` 的 `ablations.json` 已产出（D3） |
| 延迟数据 | 桌面 TFLite interpreter 基准（A）+ 端侧真机实测（B，`PLAN-P-05`）分别提供，**不得混用** |
| 目标日 | **D3**（E2 跨域出数，CP1 需要）与 **D7**（最终指标表 / 混淆矩阵 / Wilson CI） |

### 2.2 主流程（编号步骤）
1. `evaluate.py --matrix E1,E2,E3 --model ai/artifacts/saved_model --out ai/artifacts/metrics.json`；读 `shared/feature_config.json`（只读）。
2. 对每个矩阵，把评估集的每个 patch 过**同一条** FF-02→FF-08 特征管线与模型前向，收集 `y_true`、`y_pred`、`confidence`。
3. 计算 `overall.top1` 与 **Wilson 95% CI**（公式与理由见 §8 首段）；计算 `perClass[]` 的 P/R/F1 与 `support`、`macroAvg`、`weightedAvg`（比例量一律附 Wilson 区间与 `n`）。
4. 构建 `confusionMatrix`（默认 6×6；若启用「未识别」口径则 7×7，第 7 类标签写作 `未识别` 且置于末位）。
5. 记录每类 `support`；断言 `Σ support == overall.n`。
6. 延迟：写 `latency.patchInferenceMs.{p50,p90,max,deviceModel,delegate}` 与 `latency.endToEndConfirmSeconds.{median,p90}`；桌面基准与端侧真机实测各出一份 `metrics.json`，以 `deviceModel` 区分。
7. 汇总 `SPEC-T-06` 的消融摘要（不复制完整表），写 `ablations[]`，与 `ablations.json` 的同名条目数值一致。
8. 渲染混淆矩阵 PNG 到 `ai/artifacts/confusion_matrix.png`（轴标签顺序 == `confusionMatrix.labels`，`API-06` §8）。
9. 自检：`metrics.json` 通过 `docs/common/docs_api/schemas/metrics.schema.json` 校验；项目内**不存在**任何预测常数（grep 断言，§7 判据 12）。
10. 输出控制台摘要表，**不输出任何未实测的数字**。

### 2.3 状态与状态迁移
**无状态**（纯计算 + 文件产出）。同输入（模型 + 划分 + 种子）必须产出**逐字段相等**的 `metrics.json`（除 `generatedAtMs`）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 某类 support == 0 | schema 不允许 `perClass` 少于 6 项：该类仍须列出，数值字段按 0 报告并在控制台标注「该类无测试样本，指标无意义」；**不得**伪造非零值 |
| 评估集样本数 < 30 | 仍报告，但缺少的字段不得留空；须在控制台与报告中标注「样本量不足，区间极宽」；Wilson 在 n<30 时仍有效（优于正态近似），不得改用 `±1.96·σ` |
| 准确率为 0 或 1 | Wilson 区间自动收窄（公式天然处理），禁止除零；`p̂=1` 时不得用 `sqrt(p̂(1−p̂)/n)` 的 Wald 近似 |
| 「未识别」口径启用 | 需说明判据来源（FF-20 的 τ 阈值）与阈值值；6×6 与 7×7 **不得同时**作为结论 |
| 端侧延迟数据缺失 | 端侧那一份 `metrics.json` **不得**用桌面值填入；须标注为待补（`latency.pendingSide = "B"`，属报告随附说明，不写入 schema 字段），D7 前补齐 |
| 模型 sha256 与 `model_card.json` 不一致 | 报错退出（`exit 10`）：说明评估对象不是待交付制品 |
| `schemaVersion` 与 schema 不符 | schema 为 `const: "1.0"`；写 `"1.0.0"` 会被判失败，属 `ACD-ART-001` |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/evaluate.py --matrix E1,E2,E3 --out ai/artifacts/metrics.json` | 模型目录 / TFLite、四个划分 CSV、`feature_config` | 退出码 0；`metrics.json`、`confusion_matrix.png` | 非零退出码（1/6/10） |
| Schema | `python -m jsonschema -i ai/artifacts/metrics.json docs/common/docs_api/schemas/metrics.schema.json` | `metrics.json` | 退出码 0 | 校验失败退出码 1 |
| 消费方 | `PLAN-T-06`（消融表引用）、`PLAN-C-05`（回归）、PPT/报告（数字来源） | — | — | — |
| 跨域 | `SPEC-T-08` 复用同一评估集的 50 条固定样例 | — | — | — |

> 本功能不跨端；`metrics.json` 为**离线产物**（`API-06` §1 第 3 行），不进 App 制品清单。字段的**唯一权威是 `API-06` §4 + `docs/common/docs_api/schemas/metrics.schema.json`**；本 SPEC §4 只做「必报项 ↔ 字段路径」的对照说明，不另立字段。

## 4. 数据契约

`ai/artifacts/metrics.json`（**字段结构与 `docs/common/docs_api/schemas/metrics.schema.json` 逐字段一致**；该 schema 由 `API-06` §4 定义，根级 `additionalProperties: false`。下列示意中所有数值字段必须由 D3/D4 实测写入，`0` / `0.0` / 空串仅为占位，**禁止预填任何数值**）：

```json
{
  "schemaVersion": "1.0",
  "generatedAtMs": 0,
  "modelRef": "ai/artifacts/model_card.json",
  "nFrames": 0,
  "overall": { "testSet": "test_mobile", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } },
  "perClass": [
    { "label": "chips", "support": 0, "precision": 0.0, "recall": 0.0, "f1": 0.0 }
  ],
  "macroAvg": { "precision": 0.0, "recall": 0.0, "f1": 0.0 },
  "weightedAvg": { "precision": 0.0, "recall": 0.0, "f1": 0.0 },
  "confusionMatrix": { "labels": ["chips"], "matrix": [[0]] },
  "domainComparison": [
    { "testSet": "test_public", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } },
    { "testSet": "test_mobile", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } }
  ],
  "experimentMatrix": [
    { "id": "E1", "trainOn": ["public"], "evalOn": "test_public", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } },
    { "id": "E2", "trainOn": ["public"], "evalOn": "test_mobile", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } },
    { "id": "E3", "trainOn": ["public", "mobile_adapt"], "evalOn": "test_mobile", "n": 0, "top1": 0.0, "wilson95": { "low": 0.0, "high": 0.0 } }
  ],
  "latency": {
    "patchInferenceMs": { "p50": 0.0, "p90": 0.0, "max": 0.0, "deviceModel": "<机型>", "delegate": "xnnpack" },
    "endToEndConfirmSeconds": { "median": 0.0, "p90": 0.0 }
  },
  "ablations": [
    { "id": "baseline", "name": "无增强基线", "toggle": "augment=off,denoise=off", "n": 0, "top1": 0.0, "deltaVsBaseline": 0.0 }
  ]
}
```

- **字段与必报项的对应（`API-06` §4）**：① `overall.{top1,wilson95}`；② `perClass[]` + `macroAvg` + `weightedAvg`；③ `confusionMatrix.{labels,matrix}`；④ `perClass[].support`；⑤ `domainComparison[]`；⑥ `experimentMatrix[]`（E1/E2/E3 各一项，`minItems = maxItems = 3`）；⑦ `latency.patchInferenceMs` + `latency.endToEndConfirmSeconds`；⑧ `ablations[]`（含基线行）。
- `nFrames` **必须等于 `feature_config.n_frames`**，即 **128**（`ADR-21` 修订；旧值 ~~`const: 129`~~）；⚠️ `metrics.schema.json` 是否已随之更新**本 SPEC 未复核**（见 §10.1 与 `SPEC-C-03` §10 #5）；`modelRef` 是**字符串**，固定指向 `ai/artifacts/model_card.json`。
- `perClass[].label` 与 `confusionMatrix.labels` 的枚举为 FF-19 六类，第 7 类写作 **`未识别`**（不是 `unknown`），且置于**末位**。
- `Σ perClass[].support == overall.n`；`confusionMatrix.matrix[i]` 行和 == 第 i 类 `support`。
- `latency.patchInferenceMs` 的 `deviceModel` / `delegate` 是**实测凭据**（`delegate ∈ {xnnpack, nnapi, cpu}`），不得留空；桌面基准与端侧真机实测各出一份 `metrics.json`（以 `deviceModel` 区分），**不得混填**（见 §2.4）。
- `metrics.json.ablations[]` 与 `ai/artifacts/ablations.json`（`API-06` §6）中**同名条目必须数值一致**；本 SPEC 只写摘要，完整表在 `T-06`。
- 缺失任一必报项 → `ACD-ART-005`，报告不得定稿（`API-06` §4/§11）。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 输入张量形状 | FF-14 |
| 六类枚举 | FF-19 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 首次确认耗时 | FF-20a（**约 4–5 s**；端到端延迟字段的对照基准，禁止宣称「2 秒内出结果」） |
| 阈值标定范围 | FF-20b（`τ_confirm` / `τ_low` 见 FF-20） |
| 推理运行时 | FF-18（`tflite_flutter` + XNNPACK；NNAPI 失败静默回退 CPU）—— 端侧延迟的测量环境 |
| 参数量 | FF-15（实测，禁止照抄 2.5M） |
| 体积目标 | FF-16（FP32 ≤ 6 MB；**INT8 ≤ 2.5 MB** —— **两档都可交付**，`ADR-21` 起按模型卡申报档位取上限） |
| 归一化 | FF-07 / FF-08（**patch 相对 dB 参考 + per-patch min-max**，评估侧必须与训练侧一致；`ADR-21` 反转了旧规则 ~~「固定 dB 截断，禁止 `ref=np.max`」~~） |

**本域自有常量（非 FF）**：Wilson 置信水平 `95%`（`z = 1.96`）；置信度直方图 `binWidth = 0.05`；桌面延迟基准的重复次数 `n ≥ 30`；「样本量不足」提示阈值 `n < 30`。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 某类 support 为 0 | 计数 | 该类仍须出现在 `perClass`（schema 要求 ≥6 项），数值按 0 报告并标注「无测试样本，指标无意义」；**不伪造数值** | 报告脚注 |
| 混淆矩阵无法渲染 | matplotlib 报错 | 保留 `metrics.json`（数值不受影响）；`confusion_matrix.png` 属必报项 ③ 的可视化产物，缺失即 `ACD-ART-005`，须在 D7 前修复 | 报告缺图 |
| schema 校验失败 | `jsonschema` 退出码 ≠ 0 | 报 `ACD-ART-001`；修复字段后重跑。**不得**为通过校验而放宽 schema（schema 属 `docs/common/docs_api/schemas/`，修改须走 `SPEC-C-03`） | 无 |
| 端侧延迟未就绪 | 缺 `deviceModel`/`delegate` 的实测值 | 报告随附说明标注「端侧延迟待补（归属 B / `PLAN-P-05`）」；**不得**用桌面值填端侧那一份 `metrics.json`；D7 前必须补齐 | 报告缺项 |
| 模型 sha256 不符 | 比对 `model_card.json` | 非零退出 `exit 10`（`ACD-ART-003`） | 无 |
| E2 样本量过小 | `overall.n < 30` | 照实报告 + 报告说明区间极宽；**不得**因此改用 Wald 近似或省略区间 | 报告脚注 |
| 溯源信息无处安放 | 想在 `metrics.json` 中加自定义字段 | schema 根级 `additionalProperties: false` → **禁止**；溯源（划分 sha256、种子、设备、路线）写入测试报告附录（§8） | — |
| 需要「更好看」的数字 | 人为改数 | 禁止；`PLAN-C-05` 回归断言「重跑两次 `metrics.json` 逐字段相等」 | — |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 评估可完成 | `python ai/src/evaluate.py --matrix E1,E2,E3 --out ai/artifacts/metrics.json` | 退出码 == 0 |
| 2 | Schema 通过 | `python -m jsonschema -i ai/artifacts/metrics.json docs/common/docs_api/schemas/metrics.schema.json` | 退出码 == 0（该 schema 已落盘，`$id` = `…/schemas/metrics.schema.json`） |
| 3 | 三个矩阵齐全 | `test_metrics.py::test_experiment_matrix` | `experimentMatrix` **恰含** `E1`/`E2`/`E3` 三项（schema：`minItems = maxItems = 3`） |
| 4 | 每个准确率都有 Wilson 区间 | `test_metrics.py::test_wilson_present` | `overall`、`domainComparison[]`、`experimentMatrix[]` 的每处 `top1` 都同层带 `wilson95`，且 `low < top1 < high` |
| 5 | 每类 P/R/F1 | `test_metrics.py::test_per_class` | `perClass` ≥6 且 ≤7 项，每项含 `label/support/precision/recall/f1`；同时存在 `macroAvg` 与 `weightedAvg` 的三项 |
| 6 | support 守恒 | `test_metrics.py::test_support_sum` | `Σ perClass[].support == overall.n` |
| 7 | 混淆矩阵形状 | `test_metrics.py::test_confusion_shape` | `confusionMatrix.matrix` 为 6×6 或 7×7，`labels` 顺序 == `feature_config.class_labels`（第 7 类 `未识别` 置末位），且行和 == 该类 `support` |
| 8 | 混淆矩阵图存在 | 文件检查 | `ai/artifacts/confusion_matrix.png` 存在且字节数 > 10 000；轴标签与 `confusionMatrix.labels` 一致（`API-06` §8） |
| 9 | 跨域矩阵口径正确 | `test_metrics.py::test_eval_sets` | `E1.evalOn == "test_public"`；`E2.evalOn == E3.evalOn == "test_mobile"`；`overall.testSet == "test_mobile"`（对外只宣传跨域数字） |
| 10 | 延迟字段来自实测 | `test_metrics.py::test_latency_measured` | `latency.patchInferenceMs.{p50,p90,max}` 均 > 0，`deviceModel` 非空，`delegate ∈ {xnnpack,nnapi,cpu}`；`endToEndConfirmSeconds.{median,p90}` 均 > 0 |
| 11 | 消融摘要与全表一致 | `test_metrics.py::test_ablations_consistency` | `ablations[]` 含基线行，且与 `ai/artifacts/ablations.json` 的同名条目数值逐字段相等 |
| 12 | **无编造数字** | grep 全仓 docs/ 与 ai/ | 不出现「准确率 85%」「预计 XX%」「可达 XX%」等预测式表述（人工 + `PLAN-C-05` 清单核对） |
| 13 | 可复现 | 同输入重跑两次并 diff | 除 `generatedAtMs` 外逐字段相等 |
| 14 | 制品引用有效 | `test_metrics.py::test_model_ref` | `modelRef == "ai/artifacts/model_card.json"` 且该文件存在；`nFrames == feature_config.n_frames` |

## 8. 非功能约束

**为什么必须报 Wilson 置信区间（本节的核心口径，写进 SPEC 的理由）**：
> **样本量决定数字的可信度，而我们的跨域测试集很小。**
> 自采测试集的规模是「3 人 × 6 类 × 8 段」量级（`SPEC-T-02` 断言 12：144 段，对应 patch 数更少）。以**演示性算例**说明量级（此算例是**统计方法的说明，不是本项目的预测值**）：
> 若某次评估的实测准确率为 60%（36/60），则 **Wilson 95% CI 约为 [47%, 72%]** —— 区间跨度 **25 个百分点**。
> 此时若只写「准确率 60.0%」，评委会立刻按样本量算出这个数字**几乎没有分辨力**；而写出区间，反而证明我们**知道自己的不确定性在哪里**，且 47% 的下界与 72% 的上界都诚实可辩护。
> **因此**：① 任何比例型指标（准确率、每类 recall）**必须**附 Wilson 区间与 `n`；② **禁止**用 Wald 正态近似 `p̂ ± 1.96·sqrt(p̂(1−p̂)/n)`（小样本与极端比例下会给出越界或无意义的区间）；③ **禁止**只报点估计。
> Wilson 公式（`z = 1.96`，`n` 为样本数）：
>
> ```
> center = (p̂ + z²/(2n)) / (1 + z²/n)
> half   = z·sqrt(p̂(1−p̂)/n + z²/(4n²)) / (1 + z²/n)
> CI     = [center − half, center + half]     # 天然落在 (0,1) 内
> ```

**其他约束**：
- **可复现**：同模型 + 同划分 + 同种子 → 同一 `metrics.json`（`generatedAtMs` 除外）。
- **溯源（schema 之外的强制要求）**：`docs/common/docs_api/schemas/metrics.schema.json` 根级 `additionalProperties: false`，**不允许**在 `metrics.json` 中自行添加 `provenance` 等字段。因此下列溯源信息**必须**写入测试报告附录（D3/D7 各一版）：`feature_config` sha256、四个划分 CSV 的 sha256、模型制品 sha256、随机种子、增强/降噪开关、训练实际设备（GPU/CPU）、实际路线（Keras 直训或备用路线）。评委按 `n` 复核区间时，附录是唯一的可追溯凭据。
- **性能**：E1+E2+E3 三次全量评估在 CPU ≤ 40 min。
- **无预测值**：本 SPEC 及由其派生的任何材料**不得**出现未经实测的指标数字（`SPEC-00` §8.1）。
- **术语**：模型输入一律称 **patch**（FF-09），不得用「帧」单独指代模型输入（`SPEC-00` §3.10）。
- **隐私**：`metrics.json` 不含任何音频样本内容，只有统计量与哈希；自采参与者仅以 `P0x` 出现。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| `X-06` RIR/Mixup | 其消融**不做**（`SPEC-T-06` §9）；故 E1–E3 的「增强」因子只覆盖噪声/增益/LUFS/SpecAugment 组合。 |
| k 折交叉验证 / bootstrap 显著性检验 | **不做**（10 天窗口）；后果：不做方差估计与模型间显著性检验，只以 Wilson 区间表达不确定性。此点**必须在答辩 Q&A 中主动说明**。 |
| 7 类「未识别」口径 | **默认不启用**；若启用，`perClass` 与 `confusionMatrix.labels` 的第 7 项必须写作 `未识别` 并置于末位（`API-06` §4），且不得与 6×6 结论混用。 |
| 若本功能被裁剪 | 后果：CP1 的判据「跨域实测结果」无产出，`T-06` 消融表无归属，PPT 的「实测数字」全部消失 —— 只能给出「模型已训练」的定性主张，**属交付主张崩塌**。本功能**不可裁剪**。 |
| 不可裁剪声明 | 本功能不在主方案 §8.2.1 五项的字面列表中，但它是 CP1、CP4 的材料来源与 `T-07` 的验收凭据，**实际不可裁剪**。 |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`）**：`docs/common/docs_api/schemas/metrics.schema.json` 已落盘并与本 SPEC 对齐（根级 `additionalProperties: false`，必报项 ①–⑧ 均有对应字段路径）。该 schema 的 `nFrames` 为 `"const": 129`，**与 2026-09-10 拍板的选项 B（~~`n_frames = 129`~~ → 该值已由 `ADR-21`（2026-09-12）修订为 `n_frames = 128`）一致** —— 原「一旦拍板为选项 A（128 帧）就必须同步改该 schema」的风险**已随 `ADR-P1` 消除**；若日后改选 A，仍须走 `SPEC-C-03` 同步该 schema，否则评估输出无法通过校验。
2. **✅ `API-06` 已落盘**：本 SPEC §4 的字段路径已与其 §4 逐字段对齐（`overall` / `perClass` / `macroAvg` / `weightedAvg` / `confusionMatrix` / `domainComparison` / `experimentMatrix` / `latency` / `ablations`）。**差异登记**：任务书要求 `metrics.json` 含 Wilson 区间与混淆矩阵等必报项，已全部满足；但 `API-06` §4 未收录「实验溯源」（划分 sha256 / 种子 / 设备），本 SPEC 已把溯源改到报告附录（§8），**不再写入 `metrics.json`**（schema 不允许）。**需 A 确认这一落位方式。**
3. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）」**已冻结为 ~~`n_frames = 129`（选项 B，输入 `[1, 128, 129, 1]`）~~ → 已由 `ADR-21`（2026-09-12）修订为 `n_frames = 128`（输入 `[1, 128, 128, 1]`）**，`nFrames` 与全部评估的张量形状因此确定，E1–E3 的数字可一次产出、无需重跑。选项 A（128 / 4.064 s / 65024 样本）**已否决**；若日后改选，`metrics.json` 的 `nFrames` 与 E1–E3 全部数字**必须重跑**（旧数字对应另一形状的模型，不可混用），且须同步 `metrics.schema.json` 的 `const`。
4. **端侧延迟的测量责任与设备**：端侧真机延迟由 B 在 `PLAN-P-05` 产出，本 SPEC 只汇总。**需 A+B 确认交付时间（D4/D7）与机型**；若端侧数据在 D7 仍缺失，必须报「未测量」而非用桌面值顶替。
5. **「未识别」口径是否启用**：取决于 FF-20 的三档阈值是否在 D3 标定完成（FF-20b）。**需 A 在 D3 决策。**
6. **E3 的域适应方式未定**：可选（a）用 `P04/P05` 做少量微调、（b）只用其实例化 LayerNorm/BN 统计量、（c）仅合并自采样本进训练集。三者结论不同，**需 A 在 D3 前拍板并回写本 SPEC**。

**文档结束**

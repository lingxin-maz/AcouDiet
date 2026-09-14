# PLAN-T-05 评估与指标报告

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-05` |
| 负责 | A（主责）；B 提供端侧真机延迟数据（`PLAN-P-05`）；C 负责把数字搬进 PPT/报告（`PLAN-C-04`） |
| 目标日 | **D3**（E2 跨域出数，CP1）与 **D7**（最终指标表 / 混淆矩阵 / Wilson CI） |
| 前置依赖 | `PLAN-T-04` 的 `SavedModel`；`PLAN-T-02` 的划分 sha256；`PLAN-T-07` 的 INT8 TFLite（D4，供最终报告）；`PLAN-T-06` 的 `ablations.json`（D3）；`docs/common/docs_api/schemas/metrics.schema.json`（🔴 尚未落盘） |
| 预估工时 | 10 h（D3 6 h + D7 4 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/evaluate.py` | 三级矩阵评估、Wilson CI、混淆矩阵渲染 |
| 2 | `ai/artifacts/metrics.json` | 全指标（E1/E2/E3 + 每类 P/R/F1 + Wilson + support + 延迟 + 溯源） |
| 3 | `ai/artifacts/confusion_matrix.png` | 6×6（或 7×7）混淆矩阵图 |
| 4 | `ai/tests/test_metrics.py` | §7 的 14 条判据单测（并入 `PLAN-C-05`） |
| 5 | 控件台摘要表 | D3 给 CP1、D7 给最终报告 |
| 6 | 置信度分布直方图数据 | `metrics.json` 内的 `confidenceHistogram`，供 FF-20b 的阈值标定（`PLAN-P-06`） |
| 7 | 溯源记录 | 划分 sha256、`feature_config` sha256、模型 sha256、种子、设备 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 复现评估管线（FF-02→FF-08 + 模型前向，与训练侧同源） | `evaluate.py` 前向路径 | 1.5 h | `PLAN-T-04` |
| 2 | Wilson CI 实现 + 单元自检（含 36/60 → [47%,72%] 回归例） | `wilson_ci()` + 单测 | 1 h | — |
| 3 | 每类 P/R/F1 + 宏/加权平均 + support | 指标计算 | 1 h | #1 |
| 4 | 混淆矩阵（6×6 / 7×7）+ PNG 渲染 | `confusion_matrix.png` | 1 h | #3 |
| 5 | E1/E2/E3 三矩阵编排（E3 的域适应方式按 §6 决策） | `--matrix` 参数 | 1.5 h | #3 |
| 6 | 延迟字段（桌面基准 + 端侧汇总） | `latency` 字段 | 1 h | B 侧数据 |
| 7 | 溯源字段 + 可复现自检（重跑 diff） | `provenance` | 1 h | `PLAN-T-02` |
| 8 | schema 校验接入 + 无预测值 grep 清单 | 验收脚本 | 1 h | #4 + schema 落盘 |
| 9 | D7 最终报告（含 `T-06` 消融表引用） | 最终 `metrics.json` + PPT 数字 | 1 h | `PLAN-T-06` `PLAN-T-07` |

## 3. 技术方案

```python
# 骨架（≤30 行，非完整实现）
import json, math, numpy as np
Z = 1.96                                   # 95%

def wilson_ci(k, n, z=Z):
    """k 次成功 / n 次试验的 Wilson 区间；n 小时仍给出 (0,1) 内的合法区间。"""
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)

def evaluate(model, feats, labels, class_labels, test_set):
    logits = model.predict(feats)                    # 同一 FF-02..FF-08 管线
    pred = logits.argmax(1); conf = logits.max(1)
    n = len(labels); k = int((pred == labels).sum())
    low, high = wilson_ci(k, n)
    per_class = [prf(labels, pred, i, c) for i, c in enumerate(class_labels)]
    return {"overall": {"testSet": test_set, "n": n, "top1": k / n,
                        "wilson95": {"low": low, "high": high}},   # API-06 §4 字段名
            "perClass": per_class, "macroAvg": macro(per_class), "weightedAvg": weighted(per_class),
            "confusionMatrix": {"labels": class_labels, "matrix": confusion(labels, pred)}}

# 自检：方法学回归例（SPEC-T-05 §8 首段，用例本身不是本项目预测值）
assert abs(wilson_ci(36, 60)[0] - 0.474) < 0.01   # ≈ [47%, 72%]
```

**关键约定**：
- 评估侧与训练侧**共用同一个特征函数**（`ai/src/features.py`），**不得**为评估另写一份实现。
- 所有比例量统一走 `wilson_ci()`；**禁止** `p ± 1.96*sqrt(p(1-p)/n)`。
- 输出**必须**逐字段符合 `docs/common/docs_api/schemas/metrics.schema.json`（根级 `additionalProperties: false`）：`schemaVersion` 固定 `"1.0"`，`modelRef` 为字符串，`nFrames` 取自 `feature_config`；**不得**自行添加 `provenance` / `runId` / `notes` 等字段（溯源写报告附录）。
- `metrics.json` 写入前先做 `assert not PREDICTED_CONSTANTS`：脚本内不出现任何指标常数（只允许 `Z = 1.96` 这类方法学常数）。
- E3 的域适应方式在 D3 拍板（§6），实现时以 `--adapt {finetune,bnstats,merge}` 区分，实际方式写入报告附录。
- 端侧延迟由 B 提供，A 只做汇总；端侧那份 `metrics.json` 的 `deviceModel` / `delegate` 必须是真机实测值；未就绪时**不写**该份文件并在报告中标注待补。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `pytest ai/tests/test_metrics.py` | 单测 | §7 的 14 条判据 | D3 起，每次改动 |
| Wilson 方法学回归 | 单测 | `wilson_ci(36,60) ≈ [0.474, 0.714]`；`wilson_ci(0,10)` 下界 == 0；`wilson_ci(10,10)` 上界 == 1 | D3 |
| schema 校验 | CLI | `jsonschema` 退出码 0 | D3、D7 |
| support 守恒 | 单测 | `Σ perClass[].support == overall.n` | D3、D7 |
| 混淆矩阵行和 | 单测 | 每行和 == 对应类 support | D3、D7 |
| 可复现 | diff | 重跑两次除时间戳外逐字段相等 | D3、D7 |
| 无预测值 | grep 清单 | docs/ 与 ai/ 中无「预计/可达 XX%」类表述 | D7（并入 `PLAN-C-05`） |
| 端侧延迟就绪 | 字段检查 | D7 前 `latency.patchInferenceMs.onDeviceInt8.p50 != null` | D7 |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-05` §7 全部 14 条判据通过。
- [ ] `metrics.json` 通过 `docs/common/docs_api/schemas/metrics.schema.json` 校验（根级 `additionalProperties: false`，无多余字段）。
- [ ] 8 项必报项**无一缺失**（含 `confusion_matrix.png` 与端侧延迟）。
- [ ] D3 的 E2 跨域数字已交给 C 用于 CP1 判定与测试报告骨架（`PLAN-00` §1 D3 行）。
- [ ] E3 的域适应方式已在 `SPEC-T-05` §10.6 回写，并写入报告附录（`metrics.json` 无溯源字段）。
- [ ] 全项目材料中**不存在**任何预测式准确率（`SPEC-00` §8.1）。
- [ ] `T-06` 的消融摘要已写入 `metrics.json.ablations[]`，且与 `ablations.json` 的同名条目数值一致（不复制完整表，避免两处漂移）。
- [ ] 报告附录含 `feature_config` / 划分 CSV / 模型制品的 sha256 与随机种子（`metrics.json` 装不下，见 `SPEC-T-05` §8）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **schema 与产出不一致**（字段名/枚举/`schemaVersion`） | `jsonschema` 退出码 ≠ 0 并报 `ACD-ART-001` | 按 `docs/common/docs_api/schemas/metrics.schema.json` 修正产出侧代码；**不得**为"通过"而放宽 schema（schema 属 `docs/common/docs_api/schemas/`，改动须走 `SPEC-C-03`） |
| schema 与 `nFrames` 冻结值的关系（FF-11 = **`n_frames = 128`**，`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~；见 `SPEC-00` §3.5） | 有人试图改选已否决的选项 A（128 帧 / 4.064 s / 65024 样本）或缩短窗口 | **✅ 已修订**：`metrics.schema.json` 与 `feature_config.schema.json` 的该字段应随 `ADR-21` 收敛到新值（`129` → `128`，另立 `raw_mel_frames = 129`）—— ⚠️ **该 schema 的同步状态本 SPEC 未复核**，须由 schema 维护方核验（见 `SPEC-C-03` §10 #5）。任何改动都会使 E1–E3 数字作废，须走 `SPEC-C-03` 变更传播并同步 `model_card.nFrames` / Kotlin 常量 / Dart 常量 |
| E2 样本量过小 → 区间极宽 | `overall.n < 30` 或区间跨度 > 40 pp | 照实报告并在报告附录声明；不修饰、不改用 Wald；把「样本量不足」写进 PPT 的局限页 |
| 端侧延迟 D7 未就绪 | 端侧那份 `metrics.json` 的 `deviceModel` 为空 | 报「未测量」并说明原因；**禁止**用桌面值顶替或用 FF-20a 的 4–5 s 当作实测值 |
| 数字"不好看"被要求修改 | 有人要求调数 | 直接拒绝；`PLAN-C-05` 的「重跑两次逐字段相等」断言是硬防线 |
| E3 域适应方式未定 | D3 无结论 | 默认 (c)「仅合并自采样本进训练集」并注明；不得默认声称做了微调 |
| 评估与训练特征不一致（静默） | E1 `top1` 异常低 | 用 `SPEC-T-08` 的 50 条固定样例做端到端对拍，先排除管线不一致再解释指标 |
| 混淆矩阵图渲染失败 | matplotlib 报错 | 用 seaborn heatmap 或文本矩阵兜底；`confusionMatrix` 数值字段不受影响 |

## 7. 与检查点的关系
- **CP1（D3 晚）**：判据是「跨域实测结果 + 现场 10 次实拍成功率 ≥6/10」。本功能 D3 产出的 **E2 跨域数字是 CP1 的实测依据**；注意 CP1 **不写死准确率阈值**（`PLAN-00` §2），准确率如实报告但不作决策开关。
- **CP4（D7 晚）**：报告页数据接通真实记录；本功能 D7 的最终指标表是 PPT「实测数字」的唯一来源。
- **与 `PLAN-C-05` 的关系**：`test_metrics.py`（含 Wilson 方法学回归与「无预测值」清单）属其回归套件必含项，D9 演示前回归必须包含。
- **不可裁剪**：本功能是 CP1/CP4 与 `T-07` 验收凭据的来源，**任何新增功能不得占用其窗口**（`PLAN-00` §6）。

**文档结束**

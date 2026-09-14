# PLAN-T-06 消融实验

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-06` |
| 负责 | A |
| 目标日 | D3 |
| 前置依赖 | `PLAN-T-03` 的 `--augment` 开关；`PLAN-T-04` 的 `--denoise` 开关与两个既有 run（`baseline` = off/off、`aug` = off/on）；`PLAN-T-05` 的 `evaluate.py` |
| 预估工时 | 6 h（含 2 个补训 run 的等待时间） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/ablations.py` | 2×2 编排、可比性断言、汇总输出 |
| 2 | `ai/artifacts/ablations.json` | 消融表（4 行 + 边际差值 + 溯源） |
| 3 | 补训 run | `run_id=abl_on_off`（降噪 on、增强 off）与 `run_id=abl_on_on`（降噪 on、增强 on） |
| 4 | 每 run 的指标片段 | `ai/artifacts/metrics_abl_*.json`（由 `evaluate.py` 产出） |
| 5 | `ai/tests/test_ablations.py` | §7 的 12 条判据单测（并入 `PLAN-C-05`） |
| 6 | 可比性证据 | 4 行非因子超参逐字段相等的比对输出 |
| 7 | 消融结论（写进 `PLAN-T-05` 报告） | 「观测到的差值」表述，**不含**显著性断言 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 训练侧谱减法实现 + `--denoise` 开关接进 `dataset.py` | 降噪开关 | 1.5 h | `PLAN-T-04` |
| 2 | 确认两个既有 run 可复用（超参逐字比对） | 复用结论 | 0.5 h | `PLAN-T-04` |
| 3 | 补训 `abl_on_off` | 模型 + 配置 | 1 h（含等待） | #1 |
| 4 | 补训 `abl_on_on` | 模型 + 配置 | 1 h（含等待） | #3 |
| 5 | 4 个 run 各跑 E1/E2 评估（复用 `evaluate.py`） | `metrics_abl_*.json` | 0.5 h | `PLAN-T-05` |
| 6 | `ablations.py` 汇总 + 可比性断言 + 禁用键断言 | `ablations.json` | 1 h | #5 |
| 7 | `test_ablations.py` + 与 `metrics.json.ablations[]` 的摘要一致性检查 | 单测 + 引用 | 0.5 h | #6 |

## 3. 技术方案

**设计矩阵（2×2）与 `ablations.json` 的 `id` 映射（`API-06` §6）**：

| 内部 runId | `ablations.json` 的 `id` | `toggle` | 降噪 | 增强 | 来源 |
|---|---|---|---|---|---|
| `baseline` | `baseline`（写在 `baseline` 对象中） | — | off | off | 复用 `PLAN-T-04` D2 的 run |
| `aug` | `aug_on` | `augment=on` | off | on | 复用 `PLAN-T-04` D3 的 run |
| `abl_on_off` | `denoise_on` | `denoise=on` | on | off | **D3 补训** |
| `abl_on_on` | `denoise_on_aug_on` | `denoise=on,augment=on` | on | on | **D3 补训** |

```python
# 骨架（≤30 行，非完整实现）
import json, itertools
from evaluate import evaluate_split          # 复用，禁止另写指标计算

COMBOS = list(itertools.product([False, True], [False, True]))   # (denoise, augment)
NON_FACTORS = ["lr", "batch", "epochs", "loss", "labelSmoothing", "optimizer", "seed"]
IDS = {(False,False): "baseline", (False,True): "aug_on",
       (True,False): "denoise_on", (True,True): "denoise_on_aug_on"}

runs, ref, baseline = [], None, None
for d, a in COMBOS:
    cfg = load_config(run_id(d, a))            # 缺失则由 train.py 补训
    ref = ref or cfg                           # 以第一个 run 为基准比对
    assert all(cfg[k] == ref[k] for k in NON_FACTORS), "非因子超参必须逐字相同"
    e2 = evaluate_split(cfg.model, "test_mobile")     # 主指标 = E2 跨域 top1
    row = {"id": IDS[(d, a)], "name": name_of(d, a),
           "toggle": "denoise=on,augment=on" if (d and a) else ("denoise=on" if d else ("augment=on" if a else "augment=off")),
           "top1": e2["overall"]["top1"], "n": e2["overall"]["n"], "macroF1": e2["macroAvg"]["f1"],
           "deltaVsBaseline": 0.0, "note": ""}
    runs.append(row)
base = next(r for r in runs if r["id"] == "baseline")
for r in runs: r["deltaVsBaseline"] = r["top1"] - base["top1"]      # 实测差值，可为负
blob = json.dumps({"schemaVersion": "1.0", "baseline": {"id": base["id"], "top1": base["top1"], "n": base["n"]},
                   "runs": runs})
assert "rir" not in blob and "mixup" not in blob and "nuts" not in blob   # X-06 / FF-19
blob = json.dumps({"runs": runs})
assert "rir" not in blob and "mixup" not in blob      # X-06 必须保持裁剪状态
```

**关键约定**：
- **可比性是本功能的生命线**：4 个 run 除两个开关/时间戳/设备外必须逐字段相等；不一致的 run 一律不可比，宁可少报一行也不混入。
- 输出**必须**符合 `API-06` §6 的字段集（`schemaVersion` / `generatedAtMs` / `baseline` / `runs[]`），**不得**自行添加 `design` / `budget` / `provenance` / `marginalEffects` 等字段；epoch 预算差异、E1 对照、模型 sha256 等元信息写入**报告附录**。
- 评估**必须**调用 `evaluate.py` 的函数，禁止在 `ablations.py` 里另写指标计算（否则两处口径会漂移）。
- 主指标 `top1` 取 **E2（`test_mobile`）**；E1 只作报告附录中的对照。
- D3 只有 2 个 run 需要补训（约 2 h 等待），与 `T-05`、`T-03` 同日并行：训练等待期间做 `T-05` 的 Wilson 实现与 `T-06` 的汇总脚本。
- 谱减法只在训练侧开关，**不改变** FF-08 的归一化方式。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `pytest ai/tests/test_ablations.py` | 单测 | §7 的 13 条判据 | D3 |
| 字段与 `API-06` §6 一致 | 单测 | 顶层恰为 `schemaVersion`/`generatedAtMs`/`baseline`/`runs`；无多余字段 | D3 |
| 组合完备性 | 单测 | `len(runs) == 4`，`toggle` 覆盖四组合 | D3 |
| 可比性 | 单测 | 非因子超参 4 个 run 逐字相等 | D3 |
| 禁用键 | 单测 | `rir`/`mixup`/`nuts` 命中 0 | D3、D9 回归 |
| 差值定义 | 单测 | `deltaVsBaseline == top1 − baseline.top1`（逐行核对） | D3 |
| 口径同源 | 代码检查 | `ablations.py` 只调用 `evaluate.py` 的函数 | D3 |
| `T-05` 一致 | 集成 | `metrics.json.ablations[]` 含基线行且与 `ablations.json` 同名条目数值相等 | D7 |
| 可复现 | diff | 重跑除时间戳外逐字段相等 | D3 |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-06` §7 全部 13 条判据通过。
- [ ] 4 个 run 的可比性证据（非因子超参比对输出）已留存。
- [ ] `ablations.json` 字段符合 `API-06` §6，且其摘要已写入 `PLAN-T-05` 的 `metrics.json.ablations[]`，两处同名条目数值一致。
- [ ] 消融结论在 `PLAN-T-05` 报告中以「观测到的差值」表述，**无**显著性断言。
- [ ] `X-06` 的 RIR/Mixup（及 `nuts`）在 JSON 与代码中均不存在。
- [ ] epoch 预算与 E1 对照已记录在**报告附录**；若预算与主线 50 epoch 不同，已声明不可直接比较。
- [ ] 未修改 `shared/feature_config.json`。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| D3 时间不足（补训 2 个 run + `T-05` 同日） | 补训单 run 超 2 h | 4 行**统一**降到 30 epoch 并记录 `budget`；若连补训都排不下，则只报 off/off 与 off/on 两行 + `notes` 声明「降噪因子未完成」——**不得**编造另两行 |
| 训练侧谱减与端侧 `P-03` 算法不同 | 与 B 对拍不一致 | 在 `notes` 登记差异；消融结论限定为「训练侧降噪」；**不得**据此声称端侧降噪有效 |
| 降噪 on 导致训练不收敛/指标崩塌 | loss 异常 | 如实报告（这是有价值的负结论）；不删行、不挑种子重跑 |
| 4 行超参不一致 | 比对失败 | 重训不一致的那一行；仍不可比则删除该行并声明 |
| 指标口径漂移 | `T-05` 与 `T-06` 同配置数字不一致 | 以 `evaluate.py` 为唯一实现，修正调用方；属于必须当日修掉的缺陷 |
| 有人要求"补一行 Mixup 做对比" | 需求变更 | 直接拒绝：`X-06` 已签字裁剪（`PLAN-00` §6），新增须等额删除一项功能 |

## 7. 与检查点的关系
- **CP1（D3 晚）**：消融与 `T-05` 同日，共用 `T-04` 的两个 run；E2 跨域数字在消融中以「同口径」再报一次，可用于交叉核对 `T-05` 的主表（若两者不一致，以 `evaluate.py` 的输出为准并当日查因）。
- **答辩材料（D9/D10）**：「每个设计决策都有数据支撑」这一主张由本功能的 4 行表承载；缺表则只能定性说明。
- **范围冻结（已批准，依据 `ADR-P5`，2026-09-10：40 项交付 / 7 项裁剪，内容不变）**：本功能**不得**扩大因子数（例如加 RIR/Mixup 或结构开关）——任何新增须等额删除一项（`PLAN-00` §6、风险 R-14）。
- **不可裁剪**：它承载 `SPEC-T-05` 必报项 ⑦；若被裁剪，`T-05` 的验收也一并失败。

**文档结束**

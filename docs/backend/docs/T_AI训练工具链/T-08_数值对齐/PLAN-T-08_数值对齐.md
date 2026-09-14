# PLAN-T-08 数值对齐

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-08` |
| 负责 | **A + B**（A 主责 Python 侧与比对脚本；B 主责 Kotlin `MelFrontend` 的导出入口与数值实现） |
| 目标日 | **D3**（②跨语言 Mel 对齐）与 **D4**（①部署对齐） |
| 前置依赖 | `PLAN-T-07` 的 `model_int8.tflite`；`PLAN-P-04` 的 `MelFrontend`（B）；**`n_frames` 已修订（`ADR-21`，2026-09-12；FF-11 = `n_frames = 128` + `raw_mel_frames = 129`；原 `ADR-P1` 冻结值为 ~~129~~）**；`PLAN-P-01` 的 wav 样例集 |
| 预估工时 | 8 h（A 5 h + B 3 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 负责 | 说明 |
|---|---|---|---|
| 1 | `ai/scripts/parity_test.py` | A | `--n`、`--mel-align`、`--update-model-card` |
| 2 | `ai/artifacts/parity_samples.csv` | A | 50 条固定样例清单（含 sha256，一次冻结） |
| 3 | `ai/artifacts/parity_report.json` | A | `API-06` §7 字段：`sampleCount` / `labelMatch` / `maxConfDelta` / `thresholds` / `mismatches` / `melParity` / `pipeline` |
| 4 | `ai/artifacts/mel_python.npy` / `mel_kotlin.bin` | A / B | 跨语言对齐的两侧产物（可删除自检产物） |
| 5 | Kotlin Mel 导出入口 | B | 对给定 wav 输出 `mel.bin`（行主序 `Float32List`） |
| 6 | `ai/tests/test_parity.py` | A | §7 的 14 条判据单测（并入 `PLAN-C-05`） |
| 7 | 回填后的 `model_card.json` | A | `parityLabelMatch` / `parityMaxConfDelta` 实测值 |
| 8 | 合成信号布局自检证据 | A+B | `mel_syn[m,t] = m*1000 + t` 的逐元素相等输出 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 冻结 50 条样例清单 + sha256 | `parity_samples.csv` | 0.5 h | `PLAN-T-01` |
| 2 | Python 侧 Mel 参考实现（`librosa` + FF-01/03/04/05/07/08/10） | `mel_python.npy` | 1 h | — |
| 3 | **B**：Kotlin Mel 导出入口（CLI 或测试） | `mel.bin` 可产出 | 2 h | `PLAN-P-04` |
| 4 | **合成信号布局自检**（`mel_syn[m,t]=m*1000+t`） | 布局结论 | 1 h | #3 |
| 5 | `np.allclose(atol=1e-3)` 比对 + 差异归因（域偏移/参数/布局） | `melParity` 字段 | 1 h | #4 |
| 6 | Keras 侧与 TFLite 侧前向（同一份 Mel，量化隔离） | `samples[]` | 1 h | `PLAN-T-07` |
| 7 | 报告生成 + 退出码语义（0/2/10） | `parity_report.json` | 0.5 h | #6 |
| 8 | 回填 `model_card.json` + `test_parity.py` | 制品卡 | 1 h | #7 |

## 3. 技术方案

```python
# 骨架（≤30 行，非完整实现）
import json, numpy as np, tensorflow as tf
CFG = json.loads(open("shared/feature_config.json", encoding="utf-8").read())   # 只读
NM, NF = CFG["n_mels"], CFG["n_frames"]          # FF-05 / FF-11（修订值 128；raw_mel_frames 129，ADR-21）
ATOL, LABEL_TH, CONF_TH = 1e-3, 0.98, 0.05

def mel_layout_selftest(kotlin_bin: bytes):
    """合成信号证明行主序：mel_syn[m,t] = m*1000 + t。列主序或 t*NM+m 必然失败。"""
    a = np.frombuffer(kotlin_bin, "<f4").reshape(NM, NF)     # 直接还原，禁 transpose
    syn = np.arange(NM)[:, None] * 1000 + np.arange(NF)[None, :]
    assert a.shape == (NM, NF) and np.array_equal(a, syn), "Kotlin Mel 布局错误"

def compare_keras_vs_tflite(mel: np.ndarray, keras_model, intr):
    """同一份 Mel 两侧前向 —— 差异只可能来自量化（量化隔离）。"""
    k = keras_model(mel[None, ..., None], training=False).numpy()[0]
    i = intr.get_input_details()[0]; intr.set_tensor(i["index"], mel[None, ..., None].astype("float32"))
    intr.invoke(); t = intr.get_tensor(intr.get_output_details()[0]["index"])[0]
    return int(k.argmax()), float(k.max()), int(t.argmax()), float(t.max())

# 判据（SPEC-00 §7 的验收形式）
assert label_match_rate >= LABEL_TH, "标签一致率 ≥ 0.98 未达标 -> 阻塞 App 联调"
assert max_conf_delta <= CONF_TH, "最大置信度偏差 ≤ 0.05 未达标 -> 阻塞 App 联调"
assert np.allclose(py_mel, kt_mel, atol=ATOL), "Python/Kotlin Mel 未对齐"
```

**关键约定**：
- **两侧都必须用 patch 相对 `ref`**（`ADR-21` 反转）：统一 FF-07/FF-08 的 `power_to_db(ref = patch_max, top_db = 80)` → 丢尾帧 → per-patch min-max。~~原约定「两侧都不许 `ref=np.max`，统一 `clip(x, −80.0, 0.0)` + min-max」已作废~~ —— 交付模型按 patch 相对刻度训练，禁用它等于制造训练/推理偏斜。差异归因时必须先排除这一项（它的典型症状是标签一致但置信度整体偏移）。
- **禁止在 Python 侧加 `transpose` 迁就 Kotlin**：布局错误必须由 B 修 `P-04`，否则等于把错误固化进契约。
- 两侧输入刻意用**同一份** Mel 做 ①，使差异只可能来自量化；Kotlin Mel 的差异由 ② 单独覆盖。两者的乘积即全链路差异，在报告 `notes` 中说明。
- **B 的责任边界**：只交付「wav → `mel.bin`」的导出能力，不必依赖真机 UI；`melVersion` 的递增由 B 决定（`API-01` §2.1）。
- 失败即阻塞：三项判定（`labelMatch` / `maxConfDelta` / `melParity.passed`）未同时满足时，`PLAN-P-05` 不得开工；这是 `SPEC-T-08` §1.2 的闸门语义。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `parity_test.py --mel-align` | CLI | 退出码 0；`allclose(atol=1e-3) == True` | **D3**（与 B 联调） |
| 布局自检 | 单测 | 合成信号逐元素相等；`size == NM*NF*4` | D3 |
| `parity_test.py --n 50` | CLI | 退出码 0；stdout 含 `标签一致率 ≥ 0.98`、`最大置信度偏差 ≤ 0.05` | **D4** |
| `pytest ai/tests/test_parity.py` | 单测 | §7 的 14 条判据（样例数/字段/清单哈希/布局/值域/回填） | D3、D4 |
| dB 参考/归一化双侧一致 | grep + 值域 | 两侧**均为** patch 相对 `ref`（`patch_max`），且**均无**绝对刻度 `ref=1.0` / 固定 dB 截断 `clip(x,−80,0)` / `db_clip_range`；Mel 值域 ⊂ [0,1]（`ADR-21`） | D3、D4 |
| 制品哈希 | 比对 | `tfliteSha256` 与 `model_card` / `app/assets` 一致 | D4 |
| 闸门联动 | 流程检查 | `SPEC-P-05` 开工前 `parity_report.json` 的三项判定已同时满足 | D4 站会 |
| 可复现 | diff | 重跑除时间戳外逐字段相等 | D4 |
| D9 复跑 | CLI | 演示前重跑一次仍 PASS（制品未被替换） | D9（`PLAN-C-05`） |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-08` §7 全部 14 条判据通过。
- [ ] `parity_report.json` 的 `labelMatch ≥ thresholds.labelMatch`、`maxConfDelta ≤ thresholds.maxConfDelta`、`melParity.passed == true` 三项同时成立，且 stdout 同时出现 `标签一致率 ≥ 0.98` 与 `最大置信度偏差 ≤ 0.05`。
- [ ] `melParity.maxAbsDiff ≤ 1e-3`（`atol = 1e-3`），且合成信号布局自检通过。
- [ ] `model_card.json` 的 `parityLabelMatch` / `parityMaxConfDelta` 已回填为实测值。
- [ ] 50 条样例清单已冻结（sha256 登记），D9 复跑使用同一清单。
- [ ] 若曾 FAIL：定位过程与修复动作已留档（区分「量化损失」「Kotlin Mel 不一致」「布局错误」三类）。
- [ ] 未修改 `shared/feature_config.json`；未在 Python 侧加 `transpose` 迁就布局错误。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **B 的 Kotlin Mel 未在 D3 就绪** | `mel.bin` 拿不到 | ②报 `PENDING_SIDE_B`（退出码 2），闸门未闭合；**D5 联调不得放行**。升级路径：在 D3 站会把它列为 B 的最高优先级；仍不通则触发 `PLAN-00` §3.1 的 **Plan-S**（TF Task Library 的 `AudioClassifier`/`TensorAudio` 内置 Mel 前端，参数与 FF-01~FF-05 一致） |
| Mel 对齐失败归于两侧**参考刻度不一致** | 标签一致但置信度整体偏移 | 两侧统一改为 `power_to_db(ref = patch_max)` + 丢尾帧 + per-patch min-max 后重跑（`ADR-21` 链路）；**禁止**只改一侧。~~原「改回 FF-08 固定 dB 截断」已作废~~ |
| 布局错误（列主序） | 合成信号断言失败 | B 修 `P-04`；同步递增 `melVersion`；A **不得**在 Python 侧迁就 |
| 标签一致率 < 0.98 | 报告 | 先查量化（回 `SPEC-T-07` 调代表性数据集），再查是否一侧管线参数不一致；**不得**放宽阈值（改阈值须走 `SPEC-C-03`） |
| 置信度偏差 > 0.05 | 报告 | 逐样本定位偏差来源（某类集中偏移 → 量化；全类均匀偏移 → 归一化）；如实报告 |
| 样例清单被误改 | sha256 | 恢复清单；重跑并登记新哈希（须说明原因） |
| 制品在 D4 之后被替换 | 哈希不符 | 退出码 10；重新导出并回填制品卡，D9 前再复跑 |
| 端侧真机与桌面 TFLite 行为不同 | `P-05` 报异常 | 属 FF-18 委托问题（NNAPI 应静默回退 CPU）；先看自检面板 `getDiagnostics()`，再决定是否把真机一致性升级为第三个测试（须三方确认） |

## 7. 与检查点的关系
- **D3 硬验收**：`PLAN-00` §1 D3 行的 B 侧验收就是「**`atol < 1e-3`**」——本功能的 ② 即该项；它是 **CP1 当天的技术动作之一**（跨域准确率出数与 Mel 对齐同日完成）。
- **D4 硬验收**：`PLAN-00` §1 D4 行为「★模型按申报档位 ≤ FF-16 上限（fp32 6 MB / int8 2.5 MB；`ADR-21`）；★**parity 通过**；★无 INTERNET 权限」。本功能的 ① 即「parity 通过」。
- **CP2（D5 晚）**：本闸门是 `PLAN-P-05` 与端到端闭环的**前置**；`parity_report.json` 的三项判定未同时满足即不得进入 App 联调。
- **CP3（D9 午）**：Demo 前需再跑一次（制品替换检测）。
- **不可裁剪**：主方案 §8.2.1 第 ④ 项，与「①实时检测闭环」「⑤三种 Demo 模式」绑定；**任何情况下不得裁剪或降级**。这也是 `docs/00_功能清单` §6 明确要求在各 SPEC §9 声明的五项之一。

**文档结束**

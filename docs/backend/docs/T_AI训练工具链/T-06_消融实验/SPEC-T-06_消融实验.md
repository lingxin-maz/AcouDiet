# SPEC-T-06 消融实验

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付（**简化版**） |
| 上游依据 | 主方案 §3.7 / §8.2.2（`X-06`）；`SPEC-00` §3.2 FF-17、§3.1 FF-08/FF-11、§7、§8.3；`SPEC-T-03`（增强开关）、`SPEC-T-04`（训练与降噪开关）、`SPEC-T-05`（指标口径） |
| 依赖的 SPEC | `SPEC-T-02` `SPEC-T-03` `SPEC-T-04`。下游：`SPEC-T-05`（消融表引用） |

## 1. 目标与范围

### 1.1 一句话目标
用 **2×2 因子设计**测出「降噪 on/off」与「增强组合 on/off」各自对跨域指标的影响，产出消融表 `ai/artifacts/ablations.json`，使答辩时「每一个设计决策都有数据支撑」这句话有据可查。

### 1.2 范围内（In Scope）
1. **因子 A：降噪 on/off** —— 谱减法（对应主方案 §3.7，端侧 `P-03` 的同一算法族，默认 off）。
2. **因子 B：增强组合 on/off** —— 即 `SPEC-T-03` 的四项在线增强整体开关。
3. **2×2 因子设计 = 4 个 run**，所有非因子超参**逐字相同**（FF-17），仅两个开关不同。
4. 每个 run 报告**同一套指标口径**（与 `SPEC-T-05` 完全一致）：E1 与 E2 的准确率 + Wilson 95% CI、宏 F1、每类 support。
5. 产出 `ai/artifacts/ablations.json`（字段见 §4），并在 `SPEC-T-05` 的 `metrics.json.ablations[]` 中写摘要。
6. 复用 `SPEC-T-04` 已产出的两个 run（`baseline` = off/off、`aug` = off/on），**只补训 2 个 run**（on/off、on/on）。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做 RIR 混响与 Mixup 的消融**（`X-06` 已裁剪，见 §9）。
- **不做**逐项增强的单独消融（噪声 / 增益 / LUFS / SpecAugment 各自 on/off）——**简化版**只做「增强组合」一个因子；逐项消融登记为推迟项（§9）。
- **不做**网络结构消融（MobileNetV3 的 SE / Hardswish 开关、宽度倍率）——架构由 FF-13 冻结。
- **不做**输入特征消融（`n_mels`、`fmin/fmax`、`top_db`）——全部由 FF-05/FF-07/FF-08 冻结，改动会破坏 `SPEC-T-08` 的对齐基线。
- **不做**超参消融（lr / batch / epoch / 损失）——FF-17 冻结。
- **不做**统计显著性检验（无 bootstrap / McNemar）；只报区间与差值，**不做「显著提升」的断言**。
- **不做模型选型决策**：消融的目的是解释，不是选型；模型选择只看 `val`（`SPEC-T-02` 断言 D）。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 训练/增强/划分 | `SPEC-T-03` 的 `--augment` 与 `SPEC-T-04` 的 `--denoise` 开关均可用 |
| 复用的 run | `SPEC-T-04` 的 `baseline`（off/off）与 `aug`（off/on）已产出并 sha256 登记 |
| 指标口径 | `SPEC-T-05` 的 `evaluate.py` 已可用（消融**必须复用**同一评估实现，不得另写） |
| 目标日 | D3（与 `T-05` 同日，共用 `T-04` 的两个 run） |

### 2.2 主流程（编号步骤）
1. `python ai/src/ablations.py --out ai/artifacts/ablations.json` 读取消融矩阵定义（§5）。
2. 对 4 个因子组合，检查是否已有对应 run 的 `train_config.json`；缺失的组合调用 `train.py --denoise {on,off} --augment {on,off}` 补训（D3 需补 2 个 run）。
3. 对每个 run，用 `evaluate.py` 在 **E2（`test_mobile`）** 上评估取主指标 `top1`（跨域准确率）与 `macroF1`，并在报告附录中给出 **E1（`test_public`）** 对照与 Wilson 95% CI。**主指标 = E2 跨域准确率**（域差异核心数字）。
4. 汇总为 `ablations.json`：`baseline` 对象 + 4 行 `runs`（含 `id`/`name`/`toggle`/`top1`/`n`/`macroF1`/`deltaVsBaseline`/`note`），字段与 `API-06` §6 逐字一致。
5. 断言 4 行的非因子超参逐字相同（除开关/时间戳/设备），不一致即报错退出（不可比）。
6. 断言 `ablations.json` 内**不含** `rir` / `mixup` / `nuts` 任何键或名称（证明未"顺手做了"裁剪项，`API-06` §12 判据 8）。
7. 断言 `baseline.id` 与 `metrics.json.ablations[]` 的基线行 `id` 一致，且两处同名条目数值相等。
8. 在 `SPEC-T-05` 的 `metrics.json.ablations[]` 写入摘要（不复制完整表，避免两处漂移）。

### 2.3 状态与状态迁移
**无状态**：一次批处理。4 个 run 各自独立训练；已存在的 run 直接复用（复用判据 = `train_config.json` 超参逐字相同 + 模型 sha256 存在），**不重复训练**。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 某组合的 run 缺模型 | 触发补训；补训仍失败则该行**不得**写入（宁可少一行），并在报告附录说明「该因子未完成」，**不得**用其他组合的数字填入 |
| 补训时间不足（D3 窗口） | 允许把 4 个 run 统一降到**相同的**更小 epoch 预算（如 30），但**必须 4 行一致**，并在报告附录写明预算差异（`ablations.json` 无 `budget` 字段，不得自行新增，`API-06` §6） |
| 非因子超参不一致 | 报错退出（`exit 11`，`ACD-ART-005`）：该行不可比 |
| E2 样本量 <30 | 照实报 + 报告附录声明区间极宽（同 `SPEC-T-05` §2.4） |
| 增强组合 on 反而更差 | **如实保留**该结果（这本身是有价值的结论）；禁止删行或换种子重跑挑最好 |
| 降噪与增强存在交互 | 只报 2×2 四格与各自 `deltaVsBaseline`，**不做**交互显著性断言；文字上只能说「观察到的差值」 |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/ablations.py --out ai/artifacts/ablations.json` | 4 个 run 的模型与配置、划分 CSV | 退出码 0；`ablations.json` | 非零退出码（1/11） |
| CLI（复用） | `python ai/src/train.py --denoise {on,off} --augment {on,off} --run-id abl_<a><b>` | 见 `SPEC-T-04` §3 | 新 run | 同 `SPEC-T-04` |
| CLI（复用） | `python ai/src/evaluate.py --matrix E1,E2` | 见 `SPEC-T-05` §3 | 指标片段 | 同 `SPEC-T-05` |
| 消费方 | `SPEC-T-05` 的 `metrics.json.ablations[]`（摘要） | — | — | — |

## 4. 数据契约

`ai/artifacts/ablations.json`（**字段清单与 `API-06` §6 逐字段一致**；数值必须实测，占位符 `0`/`0.0` 不得作为最终内容）：

```json
{
  "schemaVersion": "1.0",
  "generatedAtMs": 0,
  "baseline": { "id": "baseline", "top1": 0.0, "n": 0 },
  "runs": [
    { "id": "aug_off", "name": "无增强", "toggle": "augment=off", "top1": 0.0, "n": 0,
      "macroF1": 0.0, "deltaVsBaseline": 0.0, "note": "" },
    { "id": "aug_on", "name": "增强组合 on", "toggle": "augment=on", "top1": 0.0, "n": 0,
      "macroF1": 0.0, "deltaVsBaseline": 0.0, "note": "" },
    { "id": "denoise_on", "name": "降噪 on", "toggle": "denoise=on", "top1": 0.0, "n": 0,
      "macroF1": 0.0, "deltaVsBaseline": 0.0, "note": "" },
    { "id": "denoise_on_aug_on", "name": "降噪 on + 增强 on", "toggle": "denoise=on,augment=on",
      "top1": 0.0, "n": 0, "macroF1": 0.0, "deltaVsBaseline": 0.0, "note": "" }
  ]
}
```

- `runs` 必须**恰好 4 行**，`(denoise, augment)` 四组合各一行且不重复；基线以 `baseline` 对象单独表示（`API-06` §6）。
- `baseline.id` 必须与 `metrics.json.ablations[]` 中基线行的 `id` 一致；两处**同名条目数值必须相等**（`API-06` §6）。
- 每行的 `top1` 为**主指标**（E2 跨域），`n` 为该评估的样本数；`macroF1` 与 `deltaVsBaseline` 为实测值（后者可为负）。
- **禁止**出现 `rir` / `mixup` / `nuts` 等键或名称（`API-06` §6/§12 判据 8；`X-06`/FF-19）。
- `deltaVsBaseline` 只允许写**实测差值**；**禁止**「预期提升 / 显著提升 / 显著优于」等措辞（无显著性检验）。
- 错误码：字段缺失或类型不符 → `ACD-ART-001`；缺必报条目 → `ACD-ART-005`（`API-06` §11）。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 训练配置（非因子超参） | FF-17（**4 个 run 必须逐字相同**） |
| 输入张量形状 | FF-14 |
| 归一化 | FF-07 / FF-08（`ADR-21`：`power_to_db(ref = "patch_max")` → 丢尾帧 → `per_patch_minmax`；~~固定 dB 截断~~；降噪开关**不得**改变归一化方式） |
| 六类枚举 | FF-19 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 参数量 / 体积 | FF-15 / FF-16（4 个 run 架构相同，参数量应一致，须断言相等） |

**本域自有常量（非 FF）**：因子数 `2`、水平数 `2`、run 数 `4`；主指标 = E2 跨域准确率；Wilson 置信水平 95%（与 `SPEC-T-05` 一致）；降噪算法 = 谱减法（与端侧 `P-03` 同族，默认 off，主方案 §3.7）。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 某 run 补训失败 | 训练非零退出 | 该行**不写入** `runs`，在报告附录写"未完成"；**不得**填他人数字 | 报告缺一格 |
| 非因子超参不一致 | 读 `train_config.json` 比对 | 非零退出 `exit 11`（`ACD-ART-005`），该行不可比 | 无 |
| 参数量在 4 个 run 间不等 | 比对实测 `paramCount` | 视为实现缺陷（开关不应改架构），非零退出 | 无 |
| D3 时间不足 | 补训预算超 2 h/run | 4 行统一下调 epoch，并在报告附录记录；**不允许只降一行** | 无 |
| 降噪实现与端侧 `P-03` 不一致 | 与 B 对拍同一段音频 | 在报告附录登记差异；消融结论只能解释**训练侧**降噪的影响，不得据此声称端侧降噪有效 | 报告脚注 |
| 出现 RIR/Mixup 开关 | 静态检查 | 视为违反 `X-06`；删除该开关，并把命中的键从 JSON 移除 | 无 |
| 想在 JSON 中加元信息字段 | 代码审查 | `API-06` §6 未定义 `design`/`budget`/`provenance` 等字段，**禁止自行新增**；此类信息写入报告附录 | — |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 消融可完成 | `python ai/src/ablations.py --out ai/artifacts/ablations.json` | 退出码 == 0 |
| 2 | 字段与 `API-06` §6 一致 | `pytest ai/tests/test_ablations.py::test_fields` | 顶层恰为 `schemaVersion`/`generatedAtMs`/`baseline`/`runs`；`schemaVersion == "1.0"`；`baseline` 含 `id`/`top1`/`n` |
| 3 | 4 行且组合齐全 | `test_ablations.py::test_four_combos` | `len(runs) == 4`，`toggle` 覆盖 `augment=off`/`augment=on`/`denoise=on`/`denoise=on,augment=on` |
| 4 | 每行字段完整 | `test_ablations.py::test_run_fields` | 每行含 `id`/`name`/`toggle`/`top1`/`n`/`macroF1`/`deltaVsBaseline`/`note` |
| 5 | 非因子超参一致 | `test_ablations.py::test_same_hyperparams` | 4 个 run 的 FF-17 非因子超参与架构参数逐字段相等 |
| 6 | 无裁剪项残留 | `test_ablations.py::test_no_cut_features` | `rir`/`mixup`/`nuts` 在所有 `id`/`name`/`toggle` 中命中数 == 0 |
| 7 | 无显著性断言措辞 | grep `ablations.json` + 报告 | 不含「显著」「significantly」「预期提升」 |
| 8 | 主指标口径正确 | `test_ablations.py::test_primary_metric` | `top1` 取自 E2（`test_mobile`）；E1 对照只出现在报告附录 |
| 9 | 与 `metrics.json` 一致 | 读 `metrics.json.ablations[]` | 基线 `id` 相同，且同名条目的 `n`/`top1`/`deltaVsBaseline` 逐字段相等 |
| 10 | 评估实现同源 | 代码检查 | `ablations.py` 调用 `evaluate.py` 的函数，**不另写**指标计算 |
| 11 | 未使用测试集选型 | `SPEC-T-02` 判据 9 的 grep | 命中数 == 0 |
| 12 | 可复现 | 重跑并 diff | 除 `generatedAtMs` 外逐字段相等 |
| 13 | 缺失字段报错码 | 构造缺 `baseline` 的 JSON 后运行校验 | 退出码 ≠ 0 且 stderr 首行含 `ACD-ART-001`（`API-06` §11） |

## 8. 非功能约束
- **成本**：只补训 2 个 run（复用 `T-04` 的两个），D3 内完成；单 run ≤ 2 h（`SPEC-T-04` 的 R-ENV-2 止损线同样适用）。
- **可比性**：4 个 run 必须共享同一划分 sha256、同一 `feature_config` sha256、同一随机种子、同一 epoch 预算。
- **不选型**：消融结果**不得**用于改变模型选择（选择只看 `val`，`SPEC-T-02` 断言 D）。
- **统计诚实**：只报观测差值 + 区间；**不报** p 值、不做显著性断言（10 天窗口内不做检验）。
- **无预测值**：`ablations.json` 的任何数值都必须来自实测（`SPEC-00` §8.1）。
- **术语**：模型输入一律称 patch（FF-09），不得用「帧」指代（`SPEC-00` §3.10）。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| **`X-06` RIR 混响的消融** | **不做**。理由：RIR 数据集未获取（`SPEC-T-01` §9），且已裁剪，无"开关"可消融。 |
| **`X-06` Mixup 的消融** | **不做**。同上；`augment.py` 中不得存在 Mixup 代码路径。 |
| 逐项增强消融（噪声/增益/LUFS/SpecAugment 各自 on/off） | **不做**（简化版，10 天窗口）。后果：若「增强组合」整体无收益，**无法定位**是哪一项拖累；须在报告中主动声明这个局限。 |
| 结构消融（SE / Hardswish / 宽度倍率） | **不做**（FF-13 冻结架构）。 |
| 超参消融 | **不做**（FF-17 冻结）。 |
| 统计显著性检验 | **不做**；后果：只能说「观察到差值」，不能说「显著提升」。 |
| 若本功能被裁剪 | 后果：答辩时「每个设计决策都有数据支撑」的主张退化为定性说明；`SPEC-T-05` 的必报项 ⑦（消融表）缺失 → `T-05` 验收也不通过。**两者互相依赖，不可单方面裁剪。** |
| 不可裁剪声明 | 本功能不在主方案 §8.2.1 五项内，但它承载 `T-05` 的第 7 项必报项，**实际不可裁剪**。 |

## 10. 开放问题
1. **降噪算法的训练侧实现是否与端侧 `P-03` 同源（需 A+B 确认）**：若训练侧用 `librosa`/`noisereduce` 的谱减法、端侧用 Kotlin 自写谱减，则消融结论只能解释**训练侧**。两侧算法若不同，`T-08` 的对齐测试范围是否需覆盖降噪路径也需一并确认（当前 `T-08` 的 ①只比较 Top-1 与置信度，**不含**降噪开关差异）。
2. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）」**已冻结为 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订为 `n_frames = 128`（选项 B）**，4 个 run 的输入形状因此确定，**不存在 4 个 run 作废重训的风险**。选项 A（128 / 4.064 s / 65024 样本）**已否决**；若日后改选，4 个 run 仍会全部作废并需重训、消融表随之重做，故任何改动须走 `SPEC-C-03` 变更传播，**不得**就地修改 FF-11。
3. **4 个 run 的 epoch 预算是否统一下调**：若 D3 时间不足，统一降到 30 epoch 会使消融结论与 `T-04` 的 50 epoch 主线**不可直接比较**。**需 A 在 D3 现场决策并记录**；建议优先保 50 epoch 的 off/off 与 off/on，另两行注明预算差异。
4. **主指标是否同时报 E1**：本 SPEC 选 E2 为主指标（域差异核心数字），E1 作参考。若评委关注域内表现，可在 PPT 中并列 E1，但**不得**用 E1 的更好看数字替换 E2 作为结论。
5. **`docs/common/docs_api/schemas/` 是否需要 `ablations.schema.json`**：`API-06` §8 目前只为 `metrics.json` 与 `feature_config.json` 提供机器可读 schema，`ablations.json` 的字段以 `API-06` §6 为权威。**需契约负责人确认是否补齐**；若补齐，本 SPEC §4 的字段清单须与其逐字段同步。
6. **`API-06` §6 未给 `top1` 指定评估集（需人工确认）**：本 SPEC 规定 `top1` = **E2 跨域**数字（与「域差异核心数字」的定位一致），E1 对照放报告附录。但 `API-06` §6 字段说明未写死评估集，若契约方希望 `top1` 取 E1，则本 SPEC 与 `PLAN-T-06` 必须同步修改。

**文档结束**

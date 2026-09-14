# PLAN-P-03 音频预处理与响度归一化

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-03 |
| 负责 | B（主责）；A 协助预处理链的 Python 侧同步与对齐口径确认 |
| 目标日 | D2 |
| 前置依赖 | `PLAN-P-01` 的 65536 样本快照可用；`PLAN-C-03` 的**预处理顶层键**常量生成；**§10 开放问题 1（高通）已随 `ADR-17` 关闭** —— **高通已从 v1.0 移除**，无需裁定 |
| 预估工时 | 4.5 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `android/app/src/main/kotlin/com/acoudiet/app/audio/Preprocess.kt` | **预加重（流式边界：取 patch 开始前最后一个原始样本，源起点 `0.0`，`ADR-21`）** + RMS 归一化；**不含高通**（ADR-17 / FF-08c）；**不含去直流**（`ADR-21` 已从链路删除） |
| 2 | ~~BiquadHighpass.kt~~ | **不实现**：高通已于 v1.0 移除（`ADR-17` / FF-08c），该文件**不得创建** |
| 3 | `android/app/src/main/kotlin/com/acoudiet/app/audio/SpectralSubtraction.kt` | 实验性谱减法（**默认不启用**） |
| 4 | `android/app/src/test/kotlin/com/acoudiet/app/audio/PreprocessTest.kt` | 公式、确定性、边界、错误码 |
| 5 | `ai/scripts/preprocess_parity_test.py` | Kotlin ↔ Python 预处理链对齐脚本 |
| 6 | `ai/scripts/assert_no_hardcoded_preprocess.py` | 参数硬编码扫描 |
| 7 | `shared/feature_config.json` 的**预处理顶层键**（`preemphasis` / `preemphasis_boundary` / `loudness_normalization` / `target_lufs`）—— **SSOT 里没有 `preprocess` 对象** | 参数单一真源 |
| 8 | `docs/reports/p03_preprocess.md` | **增益上限**（推理侧 RMS 路径）的实测标定记录；目标响度 `target_lufs=−23.0` 已冻结（仅训练侧） |
| 9 | `android/app/src/main/kotlin/com/acoudiet/app/audio/PreprocessConfig.kt` | 只读配置访问器（禁止硬编码） |
| 10 | `test/native/preprocess_pipeline_test.dart` | 端到端断言：预处理后的样本数仍为 FF-09 且全为有限值 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | **三项已裁定并写入 `SPEC-P-03`**：高通**移除**（`ADR-17`）；预加重边界**已由 `ADR-21`（2026-09-12）修订为流式**（~~`x[−1]=x[0]`~~）；**去直流已由 `ADR-21` 从链路中删除**。本任务改为**核对实现与冻结值一致** | §10 开放问题结论（写入 `SPEC-P-03`） | 0.5 h | A 确认 |
| 2 | 核对**预处理顶层键**（4 个，见交付物 7）已在 SSOT 中，且与 `SPEC-P-03` §5 一致 | 交付物 7 | 0.5 h | 1 |
| 3 | 实现 PCM16 → float32 + 预加重（FF-02）。**~~去直流~~ 不做**（`ADR-21` 删除） | 交付物 1 | 1 h | 2 |
| 4 | 实现**预加重（流式边界：取 patch 开始前最后一个原始样本，源起点 `0.0`，`ADR-21`）与 RMS 归一化（含增益钳制）** | 交付物 1 | 1 h | 3 |
| 5 | 谱减法实验开关（默认关，仅消融用） | 交付物 3 | 0.5 h | 3 |
| 6 | 单测：公式、确定性、纯静音、错误码 | 交付物 4 | 0.5 h | 4 |
| 7 | Python 侧同链实现 + 对齐脚本 | 交付物 5 | 0.5 h | 4（与 `PLAN-T-08` 共用脚本骨架） |
| 8 | 参数标定（**增益上限**（推理侧 RMS 路径）标定；`target_lufs = −23.0` 已冻结、**仅训练侧**，ADR-17 / FF-08b）与静态扫描 | 交付物 8/6 | 0.5 h | D2 实测 |
| 9 | 只读配置访问器 + 生成常量接线 | 交付物 9 | 0.25 h | 2 |
| 10 | 端到端管线断言（长度/有限值） | 交付物 10 | 0.25 h | 4 |

**合计：5 h**，计入域 P 总工时（`PLAN-00` §5）。

## 3. 技术方案
**位置**：`SPEC-P-01` 快照 → **本功能** → `SPEC-P-04` Mel。本功能是**纯函数、无状态**，便于双侧对齐。

**关键骨架（≤30 行，仅示意结构）**：
```kotlin
object Preprocess {                                   // 无可变字段：保证无跨 patch 状态
    fun apply(pcm16: ShortArray, cfg: PreprocessConfig, enableDenoise: Boolean,
              previousRawSample: Float): FloatArray {  // ADR-21：流式前驱（源起点传 0f）
        require(pcm16.size == cfg.patchSamples) { AcdError("ACD-MEL-002") }   // FF-09
        val x = FloatArray(pcm16.size) { pcm16[it] / 32768f }
        // 去直流已于 ADR-21 从链路删除：不接线、不保留 enableDcRemoval 开关
        // 高通滤波已于 v1.0 移除（ADR-17 / FF-08c）：不接线、不保留 enableHighpass 开关
        preemphasis(x, cfg.preemphCoef, previousRawSample)   // FF-02
        if (enableDenoise) SpectralSubtraction(cfg).apply(x)   // 默认 false
        applyRmsGain(x, cfg.targetRms, cfg.gainCapDb)   // 逐 patch，不跨 patch
        return x
    }
}
```
**要点**：
1. **不是**「每个 patch 做 `ref=np.max` 归一化」——~~那是 FF-08 明确禁止的域偏移陷阱~~ **该禁令已由 `ADR-21`（2026-09-12）反转**：FF-07/FF-08 现行链路**就是**用 patch 相对刻度。本功能的归一化仍只做**时域响度**，频谱侧（`power_to_db(patch_max)` + 逐 patch min-max）由 P-04 负责，两者不得合并。
2. 预加重系数只来自生成常量（FF-02），任何硬编码即判失败。
3. **高通已于 v1.0 移除**（`ADR-17` / FF-08c），不存在 `enableHighpass` 开关；**不得为"可选路径"接线**——那会让 Kotlin 与 Python 两侧的预处理链不再逐位可比，直接冲垮 `PLAN-T-08` 的 `atol=1e-3`。
4. 谱减法即使启用，也必须用本 patch 内低能量段估计噪声，保持无状态。
5. 中间量（预处理后波形）只能写在离线测试产物目录用于对齐，**不得写进 App**（FF-24 §1）。
6. 输出必须是**时域波形**（长度 == FF-09 的样本数）；本功能不得返回任何长度为 `128 × n_frames` 的量——那是 P-04 的契约。
8. **预加重不得逐 patch 重启**（`ADR-21`）：`n=0` 用调用方传入的 `previousRawSample`（patch 开始前的最后一个**原始**样本），源起点传 `0f`。实现上由环形缓冲多取 1 个样本得到该前驱（`patch_samples + 1`），**零跨 patch 记账**；单测必须用**非零 offset 的中间 patch** 才具备区分力。
7. **目标响度（`target_lufs`，仅训练侧）与增益上限**经 `PreprocessConfig` 读取（`PreprocessConfig` 从 SSOT 的**顶层键**加载，**不是** `preprocess` 对象——SSOT 里没有该对象）；业务文件里出现字面量即由 `assert_no_hardcoded_preprocess.py` 判失败。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `PreprocessTest.preemphasis_matchesFormula` | Kotlin 单测 | 脉冲输入下逐元素差 < 1e-6 | D2 每次提交 |
| `PreprocessTest.deterministic_sameInputSameOutput` | Kotlin 单测 | 10 次跑结果逐元素相等 | D2 |
| `PreprocessTest.allZeroInput_staysZero` | Kotlin 单测 | 输出 RMS == 0，无 NaN/Inf | D2 |
| `PreprocessTest.wrongLength_throwsACD_MEL_002` | Kotlin 单测 | 错误码 == `ACD-MEL-002` | D2 |
| `PreprocessTest.denoise_defaultOff` | Kotlin 单测 | 默认分支不进入谱减法 | D2 |
| `PreprocessTest.noCrossPatchState` | Kotlin 单测（反射） | `Preprocess` 无 `var` 静态字段（**预加重前驱由入参传入**，不构成业务状态，`ADR-21`） | D2 |
| `PreprocessTest.preemphasis_usesPreviousRawSample` | Kotlin 单测 | **非零 offset 中间 patch** 的首样本用前一**原始**样本；与「取 0.0」差 > 1e-3（`ADR-21`） | D2 |
| `preprocess_parity_test.py --wav <f> --n 20` | 跨语言数值对齐 | `np.allclose(kotlin, python, atol=1e-3)` 为真，退出码 0 | D2 起，D3 定稿（与 `PLAN-T-08` 同批） |
| `assert_no_hardcoded_preprocess.py` | 静态扫描 | 命中数 == 0 | D2 / D10 |
| `forbid_audio_write.py` | 静态扫描 | 命中数 == 0 | D2 / D10 |
| **增益上限**（推理侧 RMS 路径）标定 | 离线实验 | 自采集上增益分布表产出（`target_lufs = −23.0` 已冻结、**仅训练侧**，ADR-17 / FF-08b；**数值为实测产出**） | D2 起，D3 定稿 |
| `preprocess_pipeline_test.dart` | Dart 单测 | 输出样本数 == FF-09；全为有限值；无 NaN | D2 |
| `PreprocessTest.gainCap_limitsAmplification` | Kotlin 单测 | 极低电平输入下峰值不超增益上限 | D2 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-03` §7 全部 **12** 条判据通过（**必需项**）。
- [ ] 交付物 **1、3–8** 全部存在且路径一致（**交付物 2 例外** —— `BiquadHighpass.kt` 已随 `ADR-17` 移除，**该文件不得存在**，故本项应断言它**不存在**）。
- [ ] FF-02 预加重系数与公式与 `SPEC-00 §3.1` 一致，且**只**来自生成常量。
- [ ] 谱减法默认关闭，且在 `getCapabilities.denoiseAvailable` 为 `true` 时 UI 仍不得默认开启。
- [ ] `preprocess_parity_test.py` 在 D3 与 `PLAN-T-08` 一并出结论（`atol=1e-3`）。
- [ ] **✅ 已完成**：`SPEC-P-03` §10 第 1/2 条已随 `ADR-17` 关闭并回写（高通移除、~~`x[−1]=x[0]`~~）；其中预加重边界**已由 `ADR-21`（2026-09-12）改写为流式**、**去直流已删除**（§10 新增第 1b 条）。
- [ ] **预处理顶层键**（`preemphasis`/`preemphasis_boundary`/`loudness_normalization`/`target_lufs`）已在 `feature_config` 中并完成 `PLAN-C-03` 变更传播登记（**SSOT 里没有 `preprocess` 对象**）。
- [ ] 输出确认为时域波形（非频谱量），且 `Preprocess` 无静态可变字段。
- [ ] **✅ 已完成**：高通**不启用**（v1.0 移除，`ADR-17` / FF-08c），已回写 `SPEC-P-03` §10 第 1 条。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 高通导致与训练侧口径不一致 | `preprocess_parity_test.py` `allclose` 为假 | **高通已在 v1.0 移除**（`ADR-17`），无开关可关；此时应逐项核对**预加重流式边界（`ADR-21`：取前一原始样本）** 与 **FF-07/FF-08 的 dB/归一化口径**两侧是否一致，并重跑 `SPEC-P-03` §7 判据 4 与判据 11。 |
| 响度归一化把静默段放大 | 真机静默 patch 的 Mel 与训练侧差异明显 | 调小增益上限或对静默 patch 直接跳过归一化（`voiced=false` 时增益 = 1.0） |
| LUFS 口径与 `T-03` 不一致 | 增强后跨域准确率无提升 | 默认路径不启用 LUFS（本 PLAN 已按此设计） |
| D2 与 `P-01`/`P-04` 同日争抢 | D2 中午预处理未完成 | 先交付「预加重（流式边界）+ RMS 归一化」最小链（**不含去直流**，`ADR-21` 已删除该步），Mel 前端（`P-04`）优先级最高 |
| 参数标定缺数据 | D2 自采集样本不足 | 用配置初值上线，标定推迟到 D3（与 FF-20b 同批），记录未标定状态 |

## 7. 与检查点的关系
- 本功能是 `PLAN-00` §3 关键路径的**辅助环**：`P-03 → P-04 → T-08`。D2 当日 `P-01`/`P-03`/`P-04` 同为 B 的全天任务（关键路径）。
- 直接影响 **CP2（D5 端到端闭环）** 与 D3 的 `T-08` 对齐硬闸门：**预处理链两侧不一致时，`atol=1e-3` 不可能通过**。
- 未完成时的 CP 处置：D3 `T-08` 不通过 → 按 `PLAN-00` §3 先砍 D6–D8 增强功能，绝不动 D5 与 D9；**高通已在 v1.0 移除**（`ADR-17`），无需为其做降级；此时按 `SPEC-P-03` **§6（异常与降级）** 的降级顺序处理（谱减法开关本就默认关，可裁剪的只剩它）。
- 本功能属「不可砍」五项之①实时检测闭环的一环；但其中的 **LUFS 增强（仅训练侧，ADR-17）**与谱减法实验开关属可裁剪增强项；**推理侧本无 LUFS 路径**，其 RMS 归一化必做。

**文档结束**

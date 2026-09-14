# PLAN-P-02 端点检测与静默跳过

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-02 |
| 负责 | B（主责）；A 协助阈值标定（与 FF-20b 同批） |
| 目标日 | D6 |
| 前置依赖 | `PLAN-P-01` 完成（patch 节拍可用）；`PLAN-C-03` 的 `feature_config` 新增 **`behavior` 块的 4 个 VAD 键**（`noise_floor_init` / `noise_floor_min` / `voiced_margin_db` / `noise_floor_alpha`，`ADR-18`/FF-21k）并生成 Dart/Kotlin 常量；D3 自采跨域测试集可用于阈值标定 |
| 预估工时 | 5 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `android/app/src/main/kotlin/com/acoudiet/app/audio/Vad.kt` | 能量阈值 VAD + **819 点 RMS 包络产出（与 VAD 判定同一次分帧，FF-21h）** + 自适应噪声底 + 静默计时 |
| 2 | `android/app/src/main/kotlin/com/acoudiet/app/audio/VadConfig.kt` | 只读配置访问器（禁止硬编码阈值） |
| 3 | `android/app/src/test/kotlin/com/acoudiet/app/audio/VadSilenceEndTest.kt` | FF-21a 触发与暂停不累加 |
| 4 | `android/app/src/test/kotlin/com/acoudiet/app/audio/VadNoiseFloorTest.kt` | 噪声底更新与下限保护 |
| 5 | `test/native/silent_patch_delivered_test.dart` | 静默 patch 仍投递 |
| 6 | `test/native/inference_skip_test.dart` | 静默 patch 不触发推理 |
| 7 | `test/domain/vote_aggregator_silent_test.dart` | 静默 patch 仍进入聚合（与 `PLAN-P-06` 共管） |
| 8 | `ai/scripts/assert_no_hardcoded_vad.py` | 阈值硬编码静态扫描 |
| 9 | `shared/feature_config.json` 的 **`behavior` 块 VAD 键**（4 个，经 `PLAN-C-03` 登记）—— **SSOT 里没有 `vad` 对象** | 阈值单一真源 |
| 10 | `docs/reports/p02_vad_calibration.md` | D3/D6 标定记录（复核 `ADR-18`/FF-21k 冻结值的**实测产出**） |
| 11 | `android/app/src/main/kotlin/com/acoudiet/app/audio/EnvelopeFraming.kt` | **分帧与短时 RMS 的唯一实现**（FF-21h）：帧长 / hop 只在此处定义一次；`Vad` 的判定与 `rmsEnvelope` 产出共用它，`PLAN-P-07` 只消费其输出，**不得另写一遍 hop/帧长** |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 核对 **`behavior` 的 4 个 VAD 键**（`ADR-18`/FF-21k 已冻结值）已在 SSOT 中且与本文档一致，提交 `PLAN-C-03` 变更单（分帧帧长/hop **直接引用 FF-21h**，不另立配置值） | 交付物 9 | 0.5 h | `PLAN-C-03` |
| 2 | 实现**共享分帧 + 819 点 RMS 包络**、二值判定、静默计时（FF-21h，交付物 11 为唯一实现处） | 交付物 1/11 | 1.5 h | 1 |
| 3 | 实现自适应噪声底（仅静默 patch 更新 + 下限保护） | 交付物 1/4 | 1 h | 2 |
| 4 | 接入事件投递（`voiced` + **`rmsEnvelope` / `envelopeHopMs`** + `patchesVoiced` 计数） | 交付物 5 | 0.5 h | `PLAN-P-01` |
| 5 | FF-21a 静默结束串联到会话状态机 | 交付物 3 | 0.5 h | `PLAN-P-01` |
| 6 | Dart 侧调用约定（`voiced` 决定是否推理，但必须调聚合器） | 交付物 6/7 | 0.5 h | `PLAN-P-06` |
| 7 | 阈值标定（自采跨域集，与 FF-20b 同批） | 交付物 10 | 1 h | D3 数据 |
| 8 | 静态扫描脚本 + 回归 | 交付物 8 | 0.5 h | — |

**合计：6 h**（含 1 h 标定），计入域 P 总工时。

## 3. 技术方案
**位置**：`Vad` 位于 `SPEC-P-01` 的 patch 组装路径上，在 P-03/P-04 **之前**（用原始 RMS 判定，不受预处理影响，保证判定口径与 Mel 无关）。

**关键骨架（≤30 行，仅示意结构）**：
```kotlin
object EnvelopeFraming {                        // ★ 分帧与短时 RMS 的唯一实现（FF-21h）
    // 帧长 / hop 来自 FF-21h 生成的常量，只在本文件出现一次
    fun rmsEnvelope(patch: ShortArray): FloatArray   // 长度 == envelopeLength（FF-21h）
    fun patchRms(envelope: FloatArray): Double       // 由同一份包络汇总，不再二次分帧
}

class Vad(private val cfg: VadConfig) {          // cfg 来自 feature_config.behavior 的 4 个 VAD 键（ADR-18；无 vad 对象）
    private var noiseFloor = cfg.noiseFloorInit           // ← noise_floor_init（线性 RMS）
    private var silentMs = 0L
    private var sawVoiced = false

    fun evaluate(rms: Double, patchMs: Long): Boolean {   // 签名不变（SPEC-P-02 §3）
        // 判定式：rms > noiseFloor × 10^(voicedMarginDb / 20)
        val gate = noiseFloor * Math.pow(10.0, cfg.voicedMarginDb / 20.0)   // ← voiced_margin_db（分贝）
        val voiced = rms > gate
        if (voiced) { silentMs = 0; sawVoiced = true }
        else {
            silentMs += patchMs
            // 仅静默 patch 更新噪声底，且钳制下限
            noiseFloor = max(cfg.noiseFloorMin,               // ← noise_floor_min（线性 RMS）
                (1 - cfg.noiseFloorAlpha) * noiseFloor + cfg.noiseFloorAlpha * rms)   // ← noise_floor_alpha（无量纲）
        }
        return voiced
    }
    fun shouldEndSession(): Boolean = silentMs >= cfg.silenceEndSeconds * 1000  // FF-21a
}

// patch 组装处（一次分帧、两样产出）：
val envelope = EnvelopeFraming.rmsEnvelope(patch)                    // ① 819 点 RMS 包络
val voiced = vad.evaluate(EnvelopeFraming.patchRms(envelope), patchMs) // ② 同一份包络汇总出的判定
emitPatch(voiced = voiced, rmsEnvelope = envelope,                   // 两者同源，随事件下发
          envelopeHopMs = EnvelopeFraming.hopMs)
```
**要点**：
1. **静默 patch 不丢、不裁**：`voiced` 只是标记；投递义务在 `SPEC-P-01` 侧，本功能不得短路事件发送。
2. **Dart 侧调用约定**必须写成「两分支都调 `add()`」，用 `inference_skip_test.dart` 与 `vote_aggregator_silent_test.dart` 双测试钉死（见 `SPEC-P-02` §3 代码块）。
3. 判定用**原始 RMS**，不使用归一化后的响度，避免 P-03 的归一化把静默段增益抬起来导致误判。
4. 噪声底不落盘、不入库、不跨会话。
5. 暂停期间不累加静默计时（`API-01` §2.4）。
6. 阈值一律从生成常量读取（`PLAN-C-03`），本功能提交静态扫描脚本防止硬编码。
7. **一次分帧、两样产出**（FF-21h）：包络与 VAD 判定共用交付物 11 的 `EnvelopeFraming`；帧长 / hop **只允许在该处出现一次**，`SPEC-P-07` 只消费事件里的 `rmsEnvelope`，**不得另写一遍**（FF-21i）。
8. 包络随 `patch` 事件下发（`includeEnvelope = true`，**默认开**；`API-01` §2.3）；`envelopeHopMs` 随事件下发，Dart 侧**不得硬编码**；`getEnvelopeCapability()` 的出参必须与本地分帧参数一致（`API-01` §2.8）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `VadSilenceEndTest.silenceTriggersEnd_afterFF21a` | Kotlin 单测 | 静默累计到 FF-21a 时发 `sessionEnded(reason="silence90s")`；少一个 patch 不触发 | D6 每次提交 |
| `VadSilenceEndTest.pause_doesNotAccumulateSilence` | Kotlin 单测 | 暂停期间静默计时不变 | D6 |
| `VadNoiseFloorTest.noiseFloor_neverBelowFloor_andNotUpdatedOnVoiced` | Kotlin 单测 | 200 个全静默 patch 后 `noiseFloor ≥ 下限`；`voiced=true` 不改噪声底 | D6 |
| `silent_patch_delivered_test.dart` | Dart 单测 | 静默 30 s 的事件数 == 期望值 ±1 | D6 |
| `envelope_shape_test`（`includeEnvelope = true`） | Dart + Kotlin 单测 | **连续 20 个 `patch`** 的 `rmsEnvelope.length == 819` 且 `envelopeHopMs == 5`（与 `API-01` §5 第 9 条同判据） | D6 每次提交 |
| 包络可用性一致性 | Dart 单测 | `getEnvelopeCapability().supported == true` 且 `envelopeLength` 与 `startSession` 出参一致（`API-01` §5 第 12 条） | D6 |
| 分帧实现唯一性 | 静态扫描（`assert_no_hardcoded_vad.py` 扩展包络帧长/hop 检查） | 除交付物 11 的 `EnvelopeFraming.kt` 外，帧长 / hop 字面量命中数 == 0（**与 `PLAN-P-07` 共用同一份实现**） | D6 / D10 |
| `inference_skip_test.dart` | Dart 单测（mock engine） | `voiced=false` 时 `run()` 增量 == 0 | D6 |
| `vote_aggregator_silent_test.dart` | Dart 单测 | `voiced=false` 仍推进 EMA，`reset()` 未调用 | D6（与 `PLAN-P-06` 联跑） |
| `assert_no_hardcoded_vad.py` | 静态扫描 | 命中数 == 0 | D6 / D10 |
| 自采跨域集阈值标定 | 离线实验 | 逐样本 `voiced` 与人工标注一致性表产出（阈值取 `ADR-18`/FF-21k 的**冻结值**；本项只做实测验证，不重新预设阈值） | D3 起，D6 定稿 |
| 真机连续进食 30 s | 人工核对（限文案/观感） | 结果稳定不闪烁（`PLAN-00` D6 硬验收）；逐项核对表见 `docs/reports/p02_vad_calibration.md` | D6 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-02` §7 全部 **10** 条判据通过（**必需项**）。
- [ ] 交付物 1–**11** 全部存在且路径一致。
- [ ] 包络判据通过：`includeEnvelope = true` 时连续 20 个 patch 的 `rmsEnvelope.length == 819` 且 `envelopeHopMs == 5`；`includeEnvelope = false` 时字段不存在（`API-01` §5 第 9 条）。
- [ ] **分帧实现唯一**：帧长 / hop 只在交付物 11（`EnvelopeFraming.kt`）定义一次，`PLAN-P-07` 共用同一份，静态扫描命中数 0（FF-21h/FF-21i）。
- [ ] `PLAN-00` D6 硬验收达成：**连续吃 30 s，结果稳定不闪烁**。
- [ ] **`behavior` 的 4 个 VAD 键**已在 `feature_config` 中并完成 `PLAN-C-03` 变更传播登记（**SSOT 里没有 `vad` 对象**）。
- [ ] `assert_no_hardcoded_vad.py` 命中数 0。
- [ ] `voiced` 字段在 `getDiagnostics` 与 `M-04` 面板可见（`patchesVoiced`）。
- [ ] 与 `PLAN-P-06` 联合回归：静默 patch 进入 EMA 的语义双方一致（见 `SPEC-P-02` §10 第 2 条）。
- [ ] `patch.voiced` 与 `level.voiced` 由同一判定函数产出，不存在两套阈值（代码审查 + 单测）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 阈值标定后仍误判（风机/空调场景） | `patchesVoiced` 长期异常偏高或为 0 | 收紧/放宽 `voiced_margin_db`（必要时连同 `noise_floor_min`）并重跑标定；仍不行则将该场景写入演示脚本规避（`M-01`） |
| 静默结束与用户意图冲突（吃得很慢） | 用户报告会话提前结束 | 保持 FF-21a 不变（冻结值），改为在 UI 提示「已因静默结束」；**不得改 30 s** |
| 与 `PLAN-P-06` 的静默语义分歧 | 联测 EMA 行为不一致 | 以本 PLAN §5 最后一条为门禁，先对齐接口再改代码 |
| 与 `PLAN-P-07` 的**分帧参数漂移**（各写一遍 hop / 帧长） | 两侧包络长度或 `hopMs` 不一致；`SPEC-P-07` §7 判据 16 失败 | 以 **FF-21h** 为唯一口径：分帧只在交付物 11（`EnvelopeFraming.kt`）实现一次，由静态扫描与 `SPEC-P-02` §7 判据 10 双向钉死 |
| D6 与 `PLAN-P-06` 争抢同一人日 | D6 中午未完成 VAD | 优先保证 `P-06`（聚合是 CP2/CP4 判定对象），VAD 先上 `ADR-18` / FF-21k 的冻结值版（4 个 `behavior` VAD 键仍读自配置，只留 `voiced_margin_db` 的现场复核延后） |

## 7. 与检查点的关系
- 本功能是 **CP2（D5 晚：端到端闭环）** 之后、**CP4 / D8 完整闭环** 之前的必需件；`PLAN-00` 把 `P-02` 与 `P-06` 同排在 D6，D6 的硬验收「连续吃 30 s，结果稳定不闪烁」由两者共同承担。
- 未完成时的 CP 处置：CP2 已过则不影响 CP2；若 D7 仍未完成，**优先砍 D6–D8 的增强功能，不动 D5 与 D9**（`PLAN-00` §3）。
- 本功能属「不可砍」五项之①实时检测闭环，**不得通过裁剪本功能腾出工时**。
- 本功能额外承担 **`P-07`（D7）的输入产出**（`rmsEnvelope`，FF-21h）：D6 未按时，`P-07` 的硬验收「约 45 次，偏快」同样无法达成 —— 包络产出不可延后。

**文档结束**

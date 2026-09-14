# PLAN-P-04 Mel 频谱前端（Kotlin 原生）

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-04 |
| 负责 | B（主责，关键路径）；A 协助数值口径裁定（填充模式 / `ref` / `htk` / `norm`） |
| 目标日 | D2（硬验收当日）；D3 由 `PLAN-T-08` 完成对齐定稿 |
| 前置依赖 | `PLAN-P-03` 输出 65536 样本；`PLAN-C-03` 的 **Mel 顶层音频键**常量生成（无 `mel` 对象）；**FF-11 `n_frames` 已修订（`ADR-21`，2026-09-12）= 128（另见 `raw_mel_frames = 129`；原 `ADR-P1` 冻结值为 ~~129~~）**；**§10 开放问题 2–4 的数值口径裁定**（A，D0–D1；`power_to_db_ref` 与 `normalization` 已由 `ADR-21` 改写）；D0 的 Plan-S 调研结论 |
| 预估工时 | 14 h（本域最大单项，含 Plan-S 调研 2 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `android/app/src/main/kotlin/com/acoudiet/app/audio/MelFrontend.kt` | 分帧→Hann→FFT→Mel→dB→布局 主实现 |
| 2 | `android/app/src/main/kotlin/com/acoudiet/app/audio/Fft.kt` | 实数 FFT（`n_fft`，FF-03） |
| 3 | `android/app/src/main/kotlin/com/acoudiet/app/audio/MelFilterBank.kt` | 滤波器组构建与缓存 |
| 4 | `android/app/src/main/kotlin/com/acoudiet/app/audio/MelBackend.kt` | 后端抽象：`KotlinMel` / `TaskLibraryMel`（Plan-S） |
| 5 | `android/app/src/main/kotlin/com/acoudiet/app/audio/TaskLibraryMelBackend.kt` | Plan-S 实现（`AudioClassifier` + `TensorAudio`） |
| 6 | `android/app/src/test/kotlin/com/acoudiet/app/audio/MelFrontendTest.kt` | 形状、布局、值域、确定性、错误码、bench |
| 7 | `android/app/src/test/kotlin/com/acoudiet/app/audio/CapabilitiesDriftTest.kt` | `melVersion` 漂移捕获 |
| 8 | `test/native/patch_payload_type_test.dart` | `Float32List` 载荷类型断言 |
| 9 | `test/native/mel_backend_switch_test.dart` | 两种后端可切换且同形状 |
| 10 | `ai/scripts/mel_parity_test.py` | **跨语言对齐测试**（与 `PLAN-T-08` 共用，本 PLAN 为端侧出口） |
| 11 | `docs/reports/p04_mel_bench.md` | 单 patch 耗时**实测产出** |
| 12 | `docs/reports/p04_plan_s.md` | Plan-S 调研结论 + 触发时的降级记录 |
| 13 | `shared/feature_config.json` 的 **Mel 顶层音频键**（`n_mels` / `mel_htk` / `mel_norm` / `pad_mode` / `power_to_db_ref` / `power_to_db_amin` / `top_db` / `normalization` / `normalization_epsilon` / `normalization_output_min` / `normalization_output_max` / `raw_mel_frames` / `n_frames` / `frame_selection` / `operation_order` / `n_fft` / `hop_length` / `fmin` / `fmax`）—— **SSOT 里没有 `mel` 对象** | 数值单一真源 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | **D0 Plan-S 调研**：`AudioClassifier` + `TensorAudio` 跑通，记录其 Mel 默认参数与 FF-01~FF-05 的符合性、与 FF-08 的冲突点 | 交付物 12 | 2 h | Android 许可（D0） |
| 2 | 与 A 对齐数值口径：填充模式、`power_to_db` 的 `ref`/`amin`、Mel 的 `htk`/`norm`、归一化与丢尾帧顺序 | 口径写入 `feature_config` 的**顶层音频键**（`pad_mode` / `power_to_db_ref` / `power_to_db_amin` / `top_db` / `mel_htk` / `mel_norm` / `normalization` / `frame_selection` / `operation_order`，`ADR-16` 起、`ADR-21` 修订） | 1 h | A 裁定 |
| 3 | 实数 FFT + Hann 窗 + 分帧（含 `center` 填充） | 交付物 2 | 3 h | 2 |
| 4 | Mel 滤波器组构建 + 缓存 | 交付物 3 | 1.5 h | 2 |
| 5 | dB 压缩（FF-07，`ref = "patch_max"`，`ADR-21`）+ 丢尾帧 + per-patch min-max（FF-08，`ADR-21`） | 交付物 1 | 1 h | 4 |
| 6 | 行主序布局输出与 patch 载荷组装（`Float32List`） | 交付物 1 | 1 h | 5 |
| 7 | `MelBackend` 抽象 + Plan-S 后端接线 | 交付物 4/5/9 | 1.5 h | 1、6 |
| 8 | 端侧测试：形状/布局/值域/确定性/错误码/bench | 交付物 6/11 | 1.5 h | 6 |
| 9 | `melVersion` 握手与漂移注入用例 | 交付物 7 | 0.5 h | 6 |
| 10 | 与 A 合跑 `mel_parity_test.py`（`atol=1e-3`） | 交付物 10 | 1 h | 3–6（**与 `PLAN-T-08` 同批**） |

**合计：15 h**（含 D0 调研 2 h 与对齐 1 h）；与 `PLAN-00` §5 域 P 总工时口径一致。

## 3. 技术方案
**位置**：`SPEC-P-01` 快照 → `SPEC-P-03` 预处理 → **本功能** → `SPEC-P-05` 推理。

**关键骨架（≤30 行，仅示意结构，不得作为完整实现）**：
```kotlin
class MelFrontend(private val cfg: MelConfig) {          // cfg 来自 feature_config 的顶层音频键（无 mel 对象）
    private val window = hann(cfg.nFft)                   // FF-03
    private val filterBank = buildMelFilterBank(cfg)      // FF-05，会话内缓存

    fun compute(x: FloatArray): Float32List {
        require(x.size == cfg.patchSamples) { AcdError("ACD-MEL-002") }   // FF-09
        val frames = frame(x, cfg.nFft, cfg.hopLength, center = cfg.center) // FF-03/04/10
        require(frames.size == cfg.nFrames) {                              // FF-11
            AcdError("ACD-MEL-001", detail = mapOf("expectedFrames" to cfg.nFrames,
                                                  "actualFrames" to frames.size))
        }
        val out = Float32List(cfg.nMels * cfg.nFrames)
        for (t in 0 until cfg.nFrames) {
            val power = fftPower(frames[t] * window, cfg.power)            // FF-06
            val mel = filterBank.apply(power)                              // FF-05
            val db  = powerToDb(mel, cfg.topDb)                            // FF-07
            for (m in 0 until cfg.nMels) {
                val v = db[m].coerceIn(-80.0, 0.0)                         // FF-08
                out[m * cfg.nFrames + t] = v                          // 行主序！
            }
        }
        return minMaxTo01(out)                                             // FF-08
    }
}
```
> 上面片段中的 `-80.0` 与 `0.0` 仅示意位置，**实际必须取自生成常量**（FF-08），不得硬编码。

**要点（按出错概率排序）**：
1. **行主序方向**：`out[m * nFrames + t]`，`m` 是 Mel 频带、`t` 是 Mel 时间帧。写成 `t * nMels + m` 会导致「形状对、数值全错」，且 `PLAN-T-08` 的 `allclose` 会立刻抓到。
2. **帧数**：`center=True` 时帧数 = `样本数 // hop + 1`（FF-10 + FF-11）；不等即抛 `ACD-MEL-001`，**不得自行截断到 128**。
3. **必须使用 patch 相对 `ref`**（`ADR-21` 反转）：`power_to_db` 的 `ref` 取本 patch 最大值，再丢尾帧、再 per-patch min-max。~~原禁令「禁止 `ref=np.max`」已作废~~ —— 交付模型正是按 patch 相对刻度训练的（`feature_config.power_to_db_ref = "patch_max"`）。顺序承重：dB 参考与 `top_db` 算在**全部 129 帧**上，min-max 窗口是**留下的 128 帧**。
4. **滤波器组与窗只构建一次**，但不得因缓存改变数值。
5. **`melVersion` 递增纪律**：改任何数值行为（填充、截断、滤波器组）必须递增，否则 `ACD-CFG-001` 无法触发。
6. **Plan-S 后端**：`MelBackend` 抽象使 `KotlinMel` 与 `TaskLibraryMel` 可切换；上层（`SPEC-P-05`/`SPEC-P-06`）只依赖 `Float32List` 与 `nFrames`，切换对上层透明。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `MelFrontendTest.shape_is128xNFrames` | Kotlin 单测 | `mel.size == 128 × n_frames`（FF-11 常量） | D2 每次提交 |
| `MelFrontendTest.rowMajorIndex_isMelBandMajor` | Kotlin 单测 | 构造可区分频带/时间的输入，索引方向正确 | D2 |
| `MelFrontendTest.range_within01` | Kotlin 单测 | `min ≥ 0`，`max ≤ 1` | D2 |
| `MelFrontendTest.wrongFrameCount_throwsACD_MEL_001` | Kotlin 单测 | 错误码 + detail 字段 | D2 |
| `MelFrontendTest.deterministic_sameInputSameOutput` | Kotlin 单测 | 10 次逐元素相等 | D2 |
| `MelFrontendTest.bench_singlePatch` | Kotlin bench | 记录耗时（**实测产出**，不设通过线） | D2 |
| `CapabilitiesDriftTest` | Kotlin 单测 | 数值改动未递增 `melVersion` 时必须抛 `ACD-CFG-001` | D2 / D4 |
| **`ai/scripts/mel_parity_test.py --n 20`** | **跨语言数值对齐（硬闸门，与 `PLAN-T-08` 同批）** | 退出码 0；`np.allclose(py, kt, atol=1e-3)` 为真；stdout 含 `allclose_ok=true` | **D3**（`PLAN-T-08`），D2 先跑 1 个样本冒烟 |
| `patch_payload_type_test.dart` | Dart 单测 | 载荷运行时类型为 `Float32List` | D2 |
| `mel_backend_switch_test.dart` | Dart 单测 | `KotlinMel` / `TaskLibraryMel` 同形状输出 | D2 起（Plan-S 触发时启用） |
| `assert_terms.py` | 静态扫描 | `hop.*160`、`帧移 10`、`3s 窗` 命中数 == 0 | D2 / D10 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-04` §7 全部 14 条判据通过（**必需项**，其中第 4 条在 D3 由 `PLAN-T-08` 出结论）。
- [ ] 交付物 1–13 全部存在且路径一致。
- [ ] **D2 硬验收达成：Kotlin 输出 `[128, n_frames]` 数组**（`PLAN-00` §1 D2 行）。
- [ ] `mel_parity_test.py` 在 D3 与 A 合跑通过（`atol=1e-3`）；**未通过则不得进入 D4**。
- [ ] Plan-S 调研结论已归档至 `docs/reports/p04_plan_s.md`（含 D0 调研 + 是否触发的判定）；若触发，`SPEC-T-08` 判据口径已同步修改并留痕。
- [ ] `melVersion` 值已在 `feature_config` 与 `getCapabilities` 双侧一致。
- [ ] `mel` 载荷确认使用 `Float32List`（非 `List<double>`、非 Base64）。
- [ ] 单 patch 耗时实测值已写入 `docs/reports/p04_mel_bench.md`。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **D2 结束仍无 `[128,128]` 数组** | D2 傍晚形状测试仍失败 | **立即执行 Plan-S**（`SPEC-P-04` §6.2）：切 `TaskLibraryMelBackend`；同时把 `T-08` 的判据从「Mel 逐元素」降级为「端到端标签级」，并在模型卡/测试报告留痕 |
| 数值口径不一致导致 `atol` 失败 | `mel_parity_test.py` 报 `allclose_ok=false` | 按「填充模式 → `power_to_db_ref`（`patch_max`）→ 滤波器组 → 丢尾帧顺序 → per-patch min-max」顺序二分定位；每修一项必须递增 `melVersion` |
| 帧数混用（128 vs 129） | 形状断言失败 | FF-11 已修订为 **`n_frames = 128`（张量宽度）+ `raw_mel_frames = 129`（STFT 原始帧数）**（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值 ~~129~~，选项 A 仍未采纳）—— **先核对常量真源与 `feature_config`**，不得自行改窗口时长或 hop 来凑数
| 性能超 hop 预算 | D2 bench 记录偏高 | 优化 FFT 与滤波器组（查表、复用缓冲）；仍超则 `PLAN-P-05` 提高推理步长到 1.0 s |
| 工时超支（D2 同时承载 `P-01`/`P-03`/`P-04`） | D2 中午 FFT 未跑通 | 优先级：**形状先对（可全 0 占位）→ 数值再准**；仅「形状对」不足以过闸门，但能解锁 `P-05` 的并行开发 |
| Plan-S 与 FF-08 不可调和 | 触发 Plan-S 时出现 | 按 §6.2 代价 1/6 处理：修改 `T-08` 判据口径，需 A/B 三方确认 |

## 7. 与检查点的关系
- **本功能在 `PLAN-00` §3 关键路径上**：`D0 → P-04 → T-08 → T-07 → P-05 → D5 闭环 → D9 Demo`。任何一环延期，优先砍 D6–D8 的增强功能，**绝不动 D5 与 D9**。
- **D2 当日硬验收**：`PLAN-00` §1 D2 行「Kotlin 输出 `[128,128]` 数组」（`n_frames = 128`，`ADR-21`；旧口径 ~~`[128,129]`~~）。
- **D3 硬验收**：`SPEC-00` §3.1 与 `PLAN-00` §1 D3 行的「`atol < 1e-3`」，与 `PLAN-T-08` 同批出结论；这是 `docs/README.md` §6 的四项硬闸门之一。
- **CP1（D3 晚）** 的排期不被本功能单独决定，但 **CP2（D5 晚端到端闭环）** 直接依赖本功能；CP2 未通 → D6 全天扑联调，UI 与报告页砍到最简。
- 本功能属「不可砍」五项之①实时检测闭环，且是四项硬闸门之首，**任何情况下不得裁剪**；Plan-S 是唯一被认可的降级路径。

**文档结束**

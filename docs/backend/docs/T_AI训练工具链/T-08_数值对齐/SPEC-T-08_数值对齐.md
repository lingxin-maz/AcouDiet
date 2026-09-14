# SPEC-T-08 数值对齐

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | **A + B** |
| 状态 | ✅ v1.0 交付 · **硬闸门** |
| 上游依据 | 主方案 §3.6 / §4.1.2 / §8.2.1（第 4 项 `parity_test` 不可砍）；`shared/feature_config.json`；`SPEC-00` §3.1 FF-01/FF-03/FF-04/FF-05/FF-07/FF-08/FF-09/FF-11、§3.2 FF-14、§3.5、§7；`API-01` §2.1/§3.2/§5 测试清单第 4 项；`API-05` §7/§7.1；`SPEC-T-07`、`SPEC-P-04` |
| 依赖的 SPEC | `SPEC-T-07`（INT8 制品）、`SPEC-P-04`（Kotlin Mel 前端）。下游：`SPEC-P-05`（端侧集成，被本闸门阻塞） |

## 1. 目标与范围

### 1.1 一句话目标
用两个数值对齐测试证明「训练侧的模型」与「手机侧实际跑的模型」算的是同一件事：① **部署对齐**（Keras 侧 vs TFLite 侧的逐条标签与置信度），② **跨语言 Mel 对齐**（Python `mel.npy` vs Kotlin `mel.bin`，`np.allclose(atol=1e-3)`），从而暴露量化静默损失与 Kotlin Mel 与 `librosa` 不一致（风险 R-4）。

### 1.2 范围内（In Scope）
1. **测试①·部署对齐**：取 **50 条固定音频**，同一份特征输入分别过 **Keras 侧**与 **TFLite 侧**管线，逐条比较 Top-1 标签与置信度。
   - 判据：**标签一致率 ≥ 98%**，**置信度最大绝对偏差 ≤ 0.05**。
   - 不通过 → **不允许进入 App 联调阶段**（阻塞 `SPEC-P-05` / CP2）。
2. **测试②·跨语言 Mel 对齐（A+B 共同）**：同一条 wav，Python 侧输出 `mel.npy`、Kotlin 侧输出 `mel.bin`，`np.allclose(a, b, atol=1e-3)` **必须为真**。
3. **`mel` 内存布局的强制定义**（§4）：`Float32List`、长度 `nMels × nFrames`、行主序 `mel[m * nFrames + t]`，且 Python 侧 `np.frombuffer(buf, '<f4').reshape(nMels, nFrames)` 必须能**直接还原**。
4. **`power_to_db` 与归一化口径的双方一致性**（FF-07 / FF-08，`ADR-21` 修订）：本项目采用 **`power_to_db(ref = patch_max, top_db = 80)` → 丢尾帧 → per-patch min-max**，**两侧都必须如此**，**不得**一侧用绝对刻度 `ref = 1.0` 或固定 dB 截断。~~原规则「固定 dB 截断 `clip(x, −80.0, 0.0)`，**不得**一侧用逐 patch `ref=np.max`（域偏移陷阱）」已由 `ADR-21`（2026-09-12）反转~~ —— 交付模型正是按 patch 相对刻度训练的，继续禁用它等于让推理与训练不一致。**顺序同样承重**：dB 参考与 `top_db` 算在全部 **129** 帧上，min-max 窗口是留下的 **128** 帧（见 `feature_config.operation_order`）。
5. 产出 `ai/artifacts/parity_report.json`（字段与 `API-06` §7 一致：`sampleCount` / `labelMatch` / `maxConfDelta` / `thresholds` / `mismatches` / `melParity` / `pipeline`），逐样本明细另存 `parity_samples.csv`。
6. 通过后**回填** `model_card.json` 的 `parityLabelMatch` / `parityMaxConfDelta`（`SPEC-T-07` 的闸门字段）。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做模型训练/量化导出**（`SPEC-T-04` / `SPEC-T-07`）；本功能只验证制品。
- **不做精度评估报告**（`SPEC-T-05`）：本功能只回答"两侧算得一样不一样"，**不**回答"准不准"。
- **不改 `MelFrontend` 的 `melVersion`**：若对齐失败需要改 Kotlin 实现，其版本号递增由 B 决定并走 `API-01` §2.1 的语义。
- **不引入第三个 Mel 实现**：Python 侧一律用 `librosa` + FF 参数；Kotlin 侧一律用 `P-04` 的实现；**禁止**为"对齐方便"在任一侧另写一份。
- **不做性能/延迟对齐**（属 `SPEC-T-05` 的延迟字段与 B 的实测）。
- **不做端到端录制链路对齐**（真机麦克风采集引入设备差异，属 `M-01` 现场实测范畴）；本功能只做"内存中的 wav → Mel → 推理"的数值对齐。
- 不修改 `shared/feature_config.json`（本域只读）。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 制品 | `ai/artifacts/model_int8.tflite` 已产出（`SPEC-T-07`） |
| Kotlin 侧 | `P-04` 的 `MelFrontend` 可对给定 wav 输出 `mel.bin`（可由 B 提供命令行/测试入口，**不必**依赖真机 UI） |
| `n_frames` | **✅ 已修订（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~）**：FF-11 = `n_frames = 128`（另见 `raw_mel_frames = 129`）；两侧的 `nFrames` 一律取 128（§10.1） |
| 固定样例 | 50 条固定音频清单（`ai/artifacts/parity_samples.csv`，含 sha256），**一次冻结、每次复用**；来源可含 `test_public`/`test_mobile`（对齐测试不是调参，但**不得**用其结果反向调超参） |
| 环境 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`；装包经 `_toolchain\pip_runner.py` |
| 目标日 | **D3**（②与 B 的 Mel 对齐）与 **D4**（①部署对齐） |

### 2.2 主流程（编号步骤）
1. `python ai/scripts/parity_test.py --n 50` 读取冻结的 50 条样例清单（校验清单 sha256 未变，变了即报错退出）。
2. 对每条 wav，用 Python 侧（`librosa` + FF-01/03/04/05/07/08/10，`ADR-21` 链路）计算 Mel：
   - 断言形状 `[nMels, nFrames]`（= `[128, 128]`）、`dtype=float32`、值域 `[0,1]`；
   - **`power_to_db(ref = 本 patch 最大值, top_db = 80)` → 丢尾帧 → per-patch min-max**（`ADR-21`）；~~原「固定 dB 截断 `clip(x,−80,0)` + min-max」已作废~~。
3. **Keras 侧**：同一份 Mel 喂 Keras 模型（`SavedModel`）→ `kerasTop1`、`kerasConf`。
4. **TFLite 侧**：**同一份** Mel 喂 `tf.lite.Interpreter`（INT8 制品）→ `tfliteTop1`、`tfliteConf`。两侧输入刻意相同，使差异**只可能来自量化**（量化隔离）。
5. 逐条登记 `labelMatch = (kerasTop1 == tfliteTop1)`、`confDelta = |kerasConf − tfliteConf|`（逐样本明细写 `ai/artifacts/parity_samples.csv`，不一致的 `path` 汇总进 JSON 的 `mismatches[]`）。
6. 汇总 `labelMatch = ΣlabelMatch / sampleCount`、`maxConfDelta = max(confDelta)`；判据：`labelMatch ≥ thresholds.labelMatch`（0.98）**且** `maxConfDelta ≤ thresholds.maxConfDelta`（0.05）。
7. **测试②**：`parity_test.py --mel-align` —— 对同一批 wav，Python 写 `ai/artifacts/mel_python.npy`，Kotlin 写 `ai/artifacts/mel_kotlin.bin`；Python 侧 `np.allclose(a, b, atol=1e-3)` 必须为真，结果写入 `melParity.{sampleCount,atol,maxAbsDiff,passed}`；同时断言 `mel_kotlin.bin` 字节数 == `nMels × nFrames × 4`。
8. **布局自检（合成信号）**：构造 `mel_syn[m, t] = m * 1000 + t`，Kotlin 输出该矩阵到 `mel.bin`；Python `np.frombuffer(buf, '<f4').reshape(nMels, nFrames)` 后必须**逐元素相等**。若 Kotlin 误用列主序或 `t * nMels + m`，本断言必然失败。
9. 写 `ai/artifacts/parity_report.json`（字段见 §4）；退出码 0 仅当 ① ② 与布局自检全部通过（`API-06` §7 的判定式）。
10. 通过后 `--update-model-card` 回填 `model_card.json` 的 `parityLabelMatch` / `parityMaxConfDelta`。
11. 打印判据结论行（供 `SPEC-00` §7 的验收形式引用）：`标签一致率 ≥ 0.98`、`最大置信度偏差 ≤ 0.05`、`melParity.passed = true`。

### 2.3 状态与状态迁移
```
SAMPLES_FROZEN → MEL_REF_READY → PARITY_RUN(KERAS|TFLITE) → REPORT_WRITTEN → (三项判定全过) → MODEL_CARD_PATCHED
                                                                      │
                                                                      └─ (任一不满足) → BLOCK_APP_INTEGRATION（阻塞 SPEC-P-05 / CP2）
```
- 一次运行的结论不可"部分通过"：三项判定（标签一致率 / 置信度偏差 / `melParity.passed`）必须**同时**满足。
- 失败后**必须**先定位（是量化损失还是 Kotlin Mel 不一致）再决定改哪一侧；改完**必须**重跑两个测试（不能只跑一个）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 50 条样例清单被改动 | 校验 sha256 不符 → 非零退出（不可比） |
| 样例数 < 50 | 非零退出；`--n` 允许 >50，但**不得** <50 |
| 标签一致率恰好 = 0.98（49/50） | 通过（判据是 ≥ 而非 >） |
| 置信度偏差恰为 0.05 | 通过（≤） |
| Kotlin 输出字节数不符 | 判为布局/帧数错误（`ACD-MEL-001`），先查 FF-11 的修订值（~~`n_frames = 129`~~ → `n_frames = 128`，`ADR-21`）与布局，再查实现 |
| Kotlin 输出列主序 | 合成信号自检失败（步骤 8）→ 判 `Kotlin 布局错误`，与数值精度问题**分开归因** |
| 一侧仍用绝对刻度 `ref = 1.0` 或固定 dB 截断 `clip(x,−80,0)` | 交付模型按 patch 相对刻度训练，两侧口径不一致时表现为 `allclose` 假、或标签一致但置信度整体偏移；判「**推理/训练偏斜**」，**必须**两侧统一改为 `power_to_db(ref = patch_max)` + 丢尾帧 + per-patch min-max（`ADR-21` 链路，FF-07/FF-08）。~~本行原为「一侧用 `ref=np.max` → 域偏移陷阱 → 改回 FF-08」~~ **已反转** |
| 样例 wav 采样率 ≠ FF-01 | 非零退出；**不得**隐式重采样（`SPEC-T-01` §2.2 同规则） |
| Kotlin 侧未就绪（D3 前） | ②报 `PENDING_SIDE_B`，退出码 2；闸门**判定为未闭合**，不等于通过 |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/scripts/parity_test.py --n 50` | 50 条清单、`SavedModel`、`model_int8.tflite`、`feature_config` | 退出码 0；`parity_report.json`；stdout 判据行 | 非零退出码（1/2/10）；帧数不符沿用 `ACD-MEL-001`（`API-00` §3.5） |
| CLI | `python ai/scripts/parity_test.py --mel-align` | 同一批 wav；Kotlin 侧 `mel.bin` | 退出码 0；`mel_python.npy`、`mel_kotlin.bin`、`allclose` 结论 | 退出码 2（Kotlin 未就绪） |
| CLI | `python ai/scripts/parity_test.py --update-model-card` | 三项判定全过的 `parity_report.json`、`model_card.json` | 回填 `parityLabelMatch` / `parityMaxConfDelta` | 退出码 10（判定未全过时拒绝回填） |
| Kotlin 侧 | `P-04` 的 Mel 导出入口（B 提供） | 一条 wav 路径 | `mel.bin`（`Float32List` 行主序） | `ACD-MEL-001` / `ACD-MEL-002` |
| 消费方 | `SPEC-P-05`（被本闸门阻塞）、`SPEC-T-07`（制品卡回填） | — | — | — |

## 4. 数据契约

**`mel` 的内存布局（强制，全项目最易错的一处）**：

```
类型      : Float32List（Flutter StandardMessageCodec 原生支持；禁 List<double>、禁 Base64）
长度      : nMels × nFrames
索引      : 行主序 mel[m * nFrames + t]      m ∈ [0, nMels) 是 Mel 频带，t ∈ [0, nFrames) 是时间帧
Python    : np.frombuffer(buf, '<f4').reshape(nMels, nFrames)   # 必须能直接还原，无需 transpose
字节数     : nMels × nFrames × 4
值域      : [0.0, 1.0]，dtype float32
归一化     : FF-08（ADR-21）：power_to_db(ref = patch_max, top_db=80) → 丢尾帧 → per-patch min-max；两侧一致
```

`ai/artifacts/parity_report.json`（**字段清单与 `API-06` §7 逐字段一致**；数值必须实测）：

| 字段 | 类型 | 说明 | 与任务书的差异 |
|---|---|---|---|
| `schemaVersion` | string | `"1.0"` | — |
| `generatedAtMs` | int | 生成时刻（epoch ms） | — |
| `sampleCount` | int | 参与比对的样本数（`--n` 的实际值，≥50） | 任务书写作 `n`，**以 `API-06` 的 `sampleCount` 为准** |
| `labelMatch` | double | 训练侧管线 vs TFLite 部署管线的 Top-1 标签一致率，`[0,1]` | 🔴 任务书写作 `labelMatchRate`；**以 `API-06` 的 `labelMatch` 为准**（见 §10.4） |
| `maxConfDelta` | double | 最大置信度偏差，`≥ 0` | — |
| `thresholds` | object | `{labelMatch: 0.98, maxConfDelta: 0.05}`；`API-06` §7 声明「取值见主方案 §5.2 THRESH（与 SPEC-T-08 一致）」，即**本 SPEC 是这两个数的权威处** | — |
| `mismatches` | array\<string\> | 标签不一致的样本路径清单；空数组 = 全部一致 | 任务书写「逐样本清单」；完整逐样本明细写入同目录的 `parity_samples.csv` + 报告附录，JSON 内只放不一致项 |
| `melParity` | object | `{sampleCount, atol: 1e-3, maxAbsDiff, passed}`：Python `librosa` 与 Kotlin `MelFrontend` 的 `np.allclose` 结果 | 任务书写作 `melAlignment`；**以 `API-06` 的 `melParity` 为准** |
| `pipeline` | object | `{pythonVersion, kerasVersion, tfliteRuntimeVersion}` | — |

- **判定语义（`API-06` §7）**：`labelMatch ≥ thresholds.labelMatch` **且** `maxConfDelta ≤ thresholds.maxConfDelta` **且** `melParity.passed == true` → 闸门通过；任一不满足 → **禁止**把该 `.tflite` 放入 `app/assets/models/`，也禁止进入 App 联调。
- 逐样本明细（`path`、`trueLabel`、`kerasTop1/kerasConf`、`tfliteTop1/tfliteConf`、`confDelta`、`layoutCheck`）写入 `ai/artifacts/parity_samples.csv`（与冻结清单同文件或相邻文件，须在报告中说明），**不塞进 `parity_report.json`**，以符合 `API-06` §7 的字段集。
- `ai/artifacts/mel_python.npy` 与 `ai/artifacts/mel_kotlin.bin` 为**自检产物**（体积小、可删除）；`mel.npy`/`mel.bin` 的命名沿用 `API-01` §5 测试清单第 4 项。
- 错误码：字段缺失 → `ACD-ART-001`；hash 闭环失败 → `ACD-ART-003`（`API-06` §11）。
- `docs/common/docs_api/schemas/` 下当前无 `parity_report.schema.json`；建议补齐（§10.5）。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 采样率 / 声道 / 位深 | FF-01 |
| 窗函数 / `win_length` / `n_fft` | FF-03 |
| `hop_length` | FF-04 |
| `n_mels` / `fmin` / `fmax` | FF-05 |
| 压缩 / `top_db` | FF-07 |
| **归一化（patch 相对 dB + per-patch min-max）** | **FF-07 / FF-08**（`ADR-21`：`ref = "patch_max"`、`top_db = 80`、丢尾帧、`per_patch_minmax`；~~旧 `clip(x,−80,0)`、~~ ~~禁 `ref=np.max`~~） |
| patch 采样数 / 秒数 | FF-09 |
| `center` | FF-10 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 推理滑窗步长 | FF-12（本功能不使用，登记以说明推理时序不参与对齐） |
| 输入张量形状 | FF-14 |
| 运行时 | FF-18（端侧真机加载时的一致性由 `P-05` 验收） |

**本域自有常量（非 FF）**：固定样例数 `n ≥ 50`；标签一致率阈值 `0.98`；置信度最大绝对偏差阈值 `0.05`；Mel 对齐容差 `atol = 1e-3`（`API-01` §5）；退出码语义 `0=通过 / 2=Kotlin 未就绪 / 10=制品不符`（`n_frames` 已冻结，不再产生"待拍板"退出码）。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 标签一致率 < 0.98 | 汇总 | 判定不通过；**禁止进入 App 联调**，也禁止把制品放入 `app/assets/models/`；先查量化损失（回 `SPEC-T-07`） | 无 UI（无制品交付） |
| 置信度偏差 > 0.05 | 汇总 | 同上；同时检查两侧 dB 参考与归一化是否一致（FF-07/FF-08，`ADR-21` 链路） | 无 |
| `allclose` 假 | 逐元素比对 | 定位三类原因：① 两侧 dB 参考/归一化口径不一致（`ADR-21` 后应为 `ref = patch_max`，绝对刻度或固定 dB 截断即为缺陷）② 窗/帧/`top_db` 参数不一致或**丢尾帧顺序错**③ 布局错误（用合成信号区分） | 无 |
| 布局错误 | 合成信号自检 | 判 `Kotlin 布局错误`，由 B 修 `P-04`；**不得**在 Python 侧加 `transpose` "将就一下" | 无 |
| Kotlin 未就绪 | `mel.bin` 缺失 | 退出码 2，`PENDING_SIDE_B`；闸门未闭合，D5 联调**不得**放行 | 无 |
| 样例清单被改 | sha256 | 非零退出；恢复清单后重跑 | 无 |
| 制品被替换 | `tfliteSha256` 比对 | 退出码 10；重跑 `SPEC-T-07` 的 `--check-card` | 无 |
| 两侧 dB 参考口径不一致 | grep 静态检查（判据 10） | 判「**推理/训练偏斜**」：一侧用绝对刻度 `ref = 1.0` 或固定 dB 截断即为缺陷（`ADR-21` 反转了旧禁令）；两侧统一改 patch 相对 `ref` + 丢尾帧 + per-patch min-max | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 部署对齐可执行 | `python ai/scripts/parity_test.py --n 50` | 退出码 == 0 |
| 2 | **标签一致率达标** | 同上，stdout + `parity_report.json` | `labelMatch ≥ thresholds.labelMatch`（0.98）；stdout 含 `标签一致率 ≥ 0.98` |
| 3 | **置信度偏差达标** | 同上 | `maxConfDelta ≤ thresholds.maxConfDelta`（0.05）；stdout 含 `最大置信度偏差 ≤ 0.05` |
| 4 | 样例数达标 | 读报告 | `sampleCount ≥ 50` |
| 5 | 不一致样本可定位 | `pytest ai/tests/test_parity.py::test_mismatches` | `mismatches` 为数组（全一致时为空数组）；逐样本明细存在于 `parity_samples.csv` 且行数 == `sampleCount` |
| 6 | 清单冻结 | 哈希比对 | `parity_samples.csv` 的 sha256 与冻结登记相等 |
| 7 | **Mel 跨语言对齐** | `python ai/scripts/parity_test.py --mel-align` | 退出码 == 0 且 `melParity.passed == True`、`melParity.atol == 1e-3` |
| 8 | Mel 字节数正确 | 文件检查 | `size(mel_kotlin.bin) == nMels × nFrames × 4` |
| 9 | **布局可直接还原** | `test_parity.py::test_row_major_layout` | 合成信号 `mel_syn[m,t] = m*1000 + t` 经 `np.frombuffer(buf,'<f4').reshape(nMels,nFrames)` 后逐元素相等 |
| 10 | **patch 相对 dB 参考 + per-patch min-max（双侧）** | grep 静态检查 + 值域断言 | 两侧代码**均为** patch 相对 `ref`（`power_to_db_ref = "patch_max"`）且**均无**绝对刻度 `ref = 1.0` / 固定 dB 截断 `clip(x,−80,0)` / `db_clip_range`（命中 0）；Mel 值域 ⊂ `[0,1]`。⚠️ **本判据已随 `ADR-21`（2026-09-12）反转**：原文为「固定 dB 截断（双侧）——两侧代码均**无** `ref=np.max`（命中 0）」，与当年冻结链路自洽，但**与交付制品直接冲突**（模型按 patch 相对刻度训练） |
| 11 | 报告字段完整 | `test_parity.py::test_report_fields` | `API-06` §7 的 9 个字段全部存在（`schemaVersion`/`generatedAtMs`/`sampleCount`/`labelMatch`/`maxConfDelta`/`thresholds`/`mismatches`/`melParity`/`pipeline`），且无多余字段 |
| 12 | 制品卡已回填 | 读 `model_card.json` | `parityLabelMatch` / `parityMaxConfDelta` 与报告一致（`API-06` §5 要求非空） |
| 13 | 闸门与联调解耦 | 流程检查 | 三项判定未同时满足时，`SPEC-P-05` **不得**被标记为开工（`PLAN-C-05` 清单） |
| 14 | 可复现 | 重跑并 diff | 除 `generatedAtMs` 外逐字段相等 |
| 15 | 缺失字段报错码 | 构造缺 `thresholds` 的报告后运行校验 | 退出码 ≠ 0 且 stderr 首行含 `ACD-ART-001`（`API-06` §11） |

## 8. 非功能约束
- **运行时长**：50 条样例的两次前向 + 两次 Mel ≤ 3 min；`--mel-align` 单条 ≤ 10 s。
- **跨人协作**：A 提供 Python 侧与比对脚本，B 提供 Kotlin 侧导出入口；**接口只有两个文件**（`mel_python.npy` / `mel_kotlin.bin`）与一个清单，减少联调成本。
- **无网络**：脚本不得引入任何网络调用。
- **隐私**：样例音频仅在本机读入内存并产出数值文件，**不上传**；`mel_*.npy/bin` 属可删除自检产物。
- **术语**：Mel 帧（时间帧）与 **patch**（模型输入，FF-09）严格区分（`SPEC-00` §3.10）。
- **纪律**：对齐测试的样例可含测试集音频，但其结果**不得**用于调超参（`SPEC-T-02` 断言 D）。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| **不可裁剪声明** | 🔴 **本功能属主方案 §8.2.1「五项不可砍」的第 ④ 项（`parity_test`）**，并与「①实时检测闭环」「⑤三种 Demo 模式」直接绑定。**任何情况下不得裁剪、不得降级为"抽样人工看几条"、不得只在 D9 补做。** |
| `X-06` RIR/Mixup | 与本功能无关；但其裁剪使模型缺失混响鲁棒性，**对齐测试也因此不覆盖混响场景**——此局限须在报告中说明。 |
| 与 `X-02`（手动二选一确认） | 本功能不涉及；但低置信度路径（FF-20 的三档阈值）的正确性依赖推理数值一致，故本闸门是其**隐含前置**。 |
| 端到端真机链路对齐 | **不做**（属 `M-01` 现场实测）；后果：麦克风增益/设备差异带来的偏差不在本闸门覆盖范围内，只能由 CP1 的现场 10 次实拍成功率兜住。 |
| 逐层量化误差分析 | **不做**；后果：量化损失只能通过 ① 的汇总值发现，无法定位到层。 |
| 若本功能被裁剪 | 后果：**量化静默精度损失与 Kotlin/librosa 不一致（风险 R-4）将在答辩现场才暴露**，且此时已无时间修复；这是全项目唯一能提前发现该类问题的手段。**属于绝对不可裁剪项。** |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）对本功能的直接后果」**已随 2026-09-10 拍板解除、并已由 `ADR-21`（2026-09-12）修订**：~~`n_frames = 129`（选项 B）~~ → `n_frames = 128`（`raw_mel_frames = 129`），`mel` 的长度 `nMels × nFrames` 两侧一律用 128，判据 8 的字节数断言（`mels*nFrames*4`）因此**可闭合**；若一侧误用 129 则断言立即失败。**结论：本功能不再是"拍板前不可能通过"的功能之一**；选项 A（128 / 4.064 s / 65024 样本）已否决，改选须走 `SPEC-C-03` 变更传播。
2. **Kotlin 侧 Mel 导出入口的交付形式（需 B 确认）**：是 CLI 工具、单元测试，还是仅真机日志导出？后者会显著增加 A 的比对成本。**须在 D2 前定**。
3. **置信度偏差 0.05 的合理性**：INT8 量化在 6 类 Softmax 上的偏差通常小于该阈值，但**本 SPEC 不预判实测值**；若实测普遍接近 0.05，需在报告中如实说明并评估是否收紧到 0.03（**改动判据须走 `SPEC-C-03`**）。
4. **✅ `API-06` 已落盘（字段名有差异，需人工确认）**：`API-06` §7 定义的是 `sampleCount` / `labelMatch` / `melParity`，而任务书要求的是 `labelMatchRate` / 逐样本清单。本 SPEC **以 `API-06` 为准**（它自述为这些制品的权威契约，且 `SPEC-00` §5.3 规定跨层签名以 `API-0x` 为权威），并把逐样本明细放到 `parity_samples.csv` 与报告附录。**若 A 认为必须保留 `labelMatchRate` 字段名，须同时修改 `API-06` §7 与本 SPEC，并走 `SPEC-C-03`。**
5. **是否需要 `docs/common/docs_api/schemas/parity_report.schema.json`**：当前无（`metrics.schema.json` 已落盘，但本制品的字段仍只由 `API-06` §7 约束）；建议与其同批补齐，使判据 11 可机器校验。
6. **真机一致性是否纳入本闸门**：FF-18 的 XNNPACK/NNAPI 路径可能与桌面 `Interpreter` 有微小差异。当前决定：**不纳入**（桌面 TFLite 即代表量化制品的行为），真机差异由 `P-05` 与 `M-04` 自检覆盖；**若 D4 出现端侧异常，再升级为本闸门的第三个测试（须三方确认）**。
7. **✅ 已关闭（依据 `ADR-21`，2026-09-12）—— 本 SPEC 的 §1.2 第 4 条与 §7 判据 10 已反转**：原冻结规则「本项目采用**固定 dB 截断** `clip(x, −80.0, 0.0)`，**不得**一侧用逐 patch `ref=np.max`（域偏移陷阱）」**已作废**。交付的模型按 **patch 相对刻度**训练（`power_to_db_ref = "patch_max"`），继续禁用它等于让推理与训练不一致 —— 而本闸门此前**看不见**这一点：两侧都忠实实现旧链路时 `atol` 绿灯，喂给模型的张量却与训练分布不同（`ADR-21` 描述的正是这层偏斜）。**现行口径**：`power_to_db(ref = patch_max, top_db = 80)` → 丢尾帧 → per-patch min-max，顺序不可调换。**这不改变本闸门的不可裁剪地位** —— 它反而从「防语言差异」升级为「同时防语言差异与训练/推理偏斜」。

**文档结束**

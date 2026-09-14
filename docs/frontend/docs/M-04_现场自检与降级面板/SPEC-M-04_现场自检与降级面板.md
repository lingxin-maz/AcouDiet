# SPEC-M-04 现场自检与降级面板

| 项 | 值 |
|---|---|
| 域 | M · 演示与现场保障 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §9（三模式切换的现场操作面）、§9.2 现场执行 SOP、§8.2.1 第⑤项、§8.2.4；**`API-04 §7`（`DemoMode` / `DemoController` / `SelfCheckReport` / `SelfCheckItem` 与 **14 项**自检清单的权威定义）**、`§6`（`DemoDataController`）、`§7.1`（14 项 `key`/`label` 权威清单）、`§7.2`（模式状态机）、`§8`（错误码）；`API-01 §2.1/§2.2/§2.3/§2.8`、`§3.3`、`§3.4`；`SPEC-00 §3.5 FF-11`、`§3.3 FF-19`、`§3.6 FF-21h`、`§3.8 FF-23`、`§3.9 FF-24`、`§3.10 FF-25`；**ADR-02、ADR-03、ADR-04** |
| 依赖的 SPEC | `SPEC-M-01`、`SPEC-M-02`、`SPEC-M-03`、`SPEC-P-05`、`SPEC-D-01`、`SPEC-A-04`、`SPEC-U-05` |

## 1. 目标与范围

### 1.1 一句话目标
提供**一键自检 + 模式切换面板**：一次点击回答「是麦克风问题还是模型问题」，并能在三种 Demo 模式间可靠切换、失败时给出明确原因——这是现场唯一的救命手段，**必须在 D9 前可用**。

### 1.2 范围内（In Scope）
| # | 内容 |
|---|---|
| 1 | `DemoController.runSelfCheck()`：一键执行自检项清单（**`API-04 §7.1` 冻结的 14 项**，`key` 与顺序逐字以该处为准） |
| 2 | `SelfCheckReport` / `SelfCheckItem` 的结果呈现与逐项 `observed` / `hint` |
| 3 | 面板上一键切换 Mode A / B / C（`DemoController.switchTo`，规则遵 `API-04 §7.2`） |
| 4 | 切换失败的**明确原因**：错误码 + 人类可读原因 + 建议动作（映射表见 §6） |
| 5 | 面板入口可达性（不依赖任何活跃会话，冷启动即可用）；与 `SPEC-M-01`/`M-02`/`M-03` **共用同一个** `runSelfCheck()` 实现（单一真源，禁止两份） |

### 1.3 范围外（Out of Scope）——防止实现方自由发挥
| 不做 | 归属 / 理由 |
|---|---|
| 采集 / Mel / 推理 / 聚合实现 | `SPEC-P-01`~`SPEC-P-06` |
| 数据清除与临时音频清理实现 | `SPEC-D-05`（面板只**展示**计数并提供入口） |
| 演示数据集的构造与加载实现 | `API-04 §6` / `SPEC-A-04` / `SPEC-M-03` |
| 独立第 5 个页面或新 Tab | ❌ 违反 FF-23（页面数 = 4）；须挂在现有页面/设置入口下 |
| 远程诊断 / 日志上报 | ❌ 违反 FF-24 第 4 条（无 `INTERNET`） |
| 自动修复（自动重试权限、自动改配置、自动停会话后切换）；现场「临时改代码」开关 | ❌ 前者违反 `API-04 §7.2`（会话运行中的切换必须报错，不得乐观切换）；后者违反 SOP 第 5 条 |

## 2. 功能行为

### 2.1 触发与前置条件
1. 入口：从现有页面（AI 检测页或设置入口）进入；**不新增 Tab**（FF-23）。面板**不依赖**麦克风、活跃会话、模型已加载、数据库可写——**任何一项失败时面板本身仍须可用**（这是它作为救命手段的前提）。
2. 一键自检：用户点按钮 → `runSelfCheck()`；各子项**独立执行、独立超时**，单项失败不影响其余项。

### 2.2 主流程（编号步骤）
1. 点「一键自检」→ `DemoController.runSelfCheck()`。
2. 采三类数据源：`API-01 §2.8` 的 `getDiagnostics()`（**`micAvailable` / `micInUse` / `micInUseKnown` / `recordAudioPermission` / `sessionState` / `activeSessionId` / `patchesEmitted` / `droppedPatches` / `tempAudioFiles` / **`modelVersion` / `modelNFrames`**）、`API-01 §2.1` 的 `getCapabilities()`（与 `feature_config.json` 比对，`API-00 §3.6`）+ `API-01 §2.8` 的 `getEnvelopeCapability()`、本地探针（DB、知识库、演示数据集、推理引擎、环境噪声）。
   > **两个诊断字段的来源（ADR-03，必须写清）**：`modelVersion` / `modelNFrames` 由 Dart 在 `InferenceEngine.load()` 成功后通过 **`setDiagnosticsModelInfo({version, nFrames})`** 回填，**默认 `null`**；面板**只读** `getDiagnostics()` 的回显值。**禁止**为了填这两个字段而让原生加载模型——那会把推理分裂成两份。未回填时第 11 项 `modelInfo` 判失败，**但不得抛异常**。
3. 每项产出 `SelfCheckItem{key, label, passed, observed, hint}`；`observed` 必须是**实际读到的值/状态**，不得为空、不得写泛化词。
4. `SelfCheckReport.allPassed` ⇔ **每一项** `passed == true`（`API-04 §7.1`）；空列表视为 `false`。
5. 渲染两项内容：①逐项列表（**文字 + 颜色双通道**）②「问题定位」结论行：仅麦克风相关项失败 → 「麦克风侧问题」；仅模型相关项失败 → 「模型侧问题」；两侧均失败 → 「原生桥接/配置问题」。
6. 点模式按钮 → `switchTo(mode)`；成功即刷新 `currentMode`。
7. 切换失败 → 捕获异常，展示 `code` + 人类可读原因 + 建议动作（§6），**不得只显示「切换失败」**。

### 2.3 状态与状态迁移
```
IDLE ──点自检──▶ CHECKING ──全部子项结束──▶ RESULTS
                    │                          │
                    │ 面板不可用（视为缺陷）    │ 点模式按钮
                    ▼                          ▼
                 DEGRADED                  SWITCHING ──成功──▶ RESULTS(mode 已更新)
                                               │
                                               └──失败▶ RESULTS(附 code + 原因 + 建议)
```
| 迁移 | 触发 | 允许 |
|---|---|---|
| IDLE → CHECKING | `runSelfCheck()` | ✅ |
| CHECKING → CHECKING | 重复点击（并发自检） | ❌ `CHECKING` 期间按钮禁用 |
| CHECKING → RESULTS | 全部子项结束或超时 | ✅ |
| RESULTS → SWITCHING | `switchTo(mode)` | ✅ |
| SWITCHING → RESULTS | 成功或失败（失败必须带原因） | ✅ |
| RESULTS → CHECKING / DEGRADED → RESULTS | 再次点自检；修复数据源后重试 | ✅ |

> 模式迁移本身以 `API-04 §7.2` 为唯一权威（含「会话运行中 → 任意模式 ❌ → `ACD-DEMO-003`」「`X → X` 幂等」）；本节只描述面板的 UI 状态。

### 2.4 边界条件
| 边界 | 行为 |
|---|---|
| 权限被永久拒绝 / 麦克风被占用 | `permission` / `mic` 失败，`hint` 按 `API-04 §7.1` 给「去设置」或「关闭其他录音应用」；结论行指向麦克风侧 |
| 无活跃会话 | 第 10 项 `session` 判为**通过**，`observed="IDLE"` |
| `getDiagnostics()` 抛错 / 单项超时 | 面板**不崩溃**；相关项 `passed=false`，`observed` 为 `"unavailable"` 或 `"timeout"` 并给排查方向；其余项继续 |
| `droppedPatches` 无会话数据 | **必须区分「无数据」与「0 丢包」**：第 13 项 `dropRate` 的 `observed="无会话数据"`（`patchesEmitted == 0`），`passed=true`，**不计入失败** |
| `skipAudioRecord=true` 的未启用麦克风会话 | 第 2 项 `mic` 的 `observed="未启用麦克风"`（`micInUseKnown == false`）且 `passed=true`，**不得判失败**（ADR-02） |
| 演示数据集不可解析 / 标识与库内状态不一致 | 第 14 项 `demoData` 判失败，`hint`「改用实时模式」（Mode C 兜底失效） |
| 行为包络通道不可用 | 第 12 项 `envelope` 判失败（`getEnvelopeCapability().supported == false`，或长度与 `startSession` 出参不一致），`hint`「行为指标将不可用」（`ACD-BEH-001`） |
| `delegate == "cpu"` | **算通过**（FF-18 允许回退），但 `observed` 必须显示实际值（`API-04 §7.1` 第 4 项） |
| 模型未加载（第 3 项） | `model.passed=false`，`hint` 为「重试加载模型」；**现场动作 = 切 Mode C**（第 3 项判「模型能否用」） |
| 模型信息未回填（第 11 项） | `modelInfo.passed=false`（`modelVersion` / `modelNFrames` 为 `null` 或 `modelNFrames` ≠ 握手实际值），`hint`「重试加载模型」；**现场动作 = 禁止演示**（第 11 项判「用的是哪个模型、输入形状对不对」）——与第 3 项的现场动作**不同**（ADR-04） |
| 会话运行中点切换 / 演示数据集未加载即切 `reportOnly` | **不自动停会话**，按 `API-04 §7.2` 报 `ACD-DEMO-003`，提示先停止会话或先加载数据集 |

## 3. 接口契约
> 类名与签名**不得改名**。**权威定义在 `API-04 §7`**（`API-00 §1`：跨层接口签名以 `docs/*/docs_api/` 为准），本节逐字照抄；`API-01` 的方法直接引用，不得另造。任何改动须走 `API-00 §3.9`。

```dart
enum DemoMode { realtime, sampleAudio, reportOnly }

class DemoController {
  DemoMode get currentMode;
  Future<void> switchTo(DemoMode mode);
  Future<SelfCheckReport> runSelfCheck();
  Future<void> startRealtimeSession();
  Future<void> startSamplePlayback({required String assetPath});
  Future<void> loadReportDemo();
}

class SelfCheckReport { bool allPassed; List<SelfCheckItem> items; }
class SelfCheckItem { String key; String label; bool passed; String observed; String? hint; }
```

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5→L4 | `runSelfCheck()` | 无 | `Future<SelfCheckReport>` | **任何单点失败都不得抛出**（`API-04 §7`） |
| L5→L4 | `switchTo(DemoMode)` | `DemoMode` | `Future<void>` | `ACD-DEMO-003`（非法迁移 / 前置未就绪）、`ACD-DEMO-002`、`ACD-DEMO-001`、`ACD-CFG-001`、`ACD-INF-001`、`ACD-PERM-001/002`、`ACD-IO-001`（`API-04 §7.2`） |
| L5→L4 | `currentMode` | — | `DemoMode` | 只读，默认 `realtime`（`API-04 §7`） |
| L4→L1 | `getDiagnostics()` | `{}` | 诊断 Map | 无（`API-01 §2.8`：**必须永不失败**） |
| L4→L1 | `getCapabilities()` | `{}` | `NativeCapabilities` | 无（`API-01 §2.1`：必须永不失败） |
| L4→L1 | **`getEnvelopeCapability()`** | `{}` | `{supported, envelopeHopMs, envelopeLength}` | 无（`API-01 §2.8`：第 12 项 `envelope` 的数据源） |
| L4→L1 | **`setDiagnosticsModelInfo({version, nFrames})`** | `version` / `nFrames`（**取握手实际值，禁止硬编码**） | `{ok:true}` | 无（`API-01 §2.8`：**由 Dart 在 `InferenceEngine.load()` 成功后调用一次**，供第 11 项 `modelInfo` 回显） |

## 4. 数据契约

### 4.1 结果模型字段
| 字段 | 类型 | 可空 | 说明 |
|---|---|---|---|
| `SelfCheckReport.allPassed` | `bool` | 否 | `items` 每一项 `passed` 时为 `true`；**空列表视为 `false`** |
| `SelfCheckItem.key` / `.label` | `String` | 否 | `key` 取自 §4.2，**唯一且稳定**（UI / 测试 / 日志都依赖）；**全部 14 项的 `key` 与 `label` 均以 `API-04 §7.1` 为准** |
| `SelfCheckItem.passed` / `.hint` | `bool` / `String?` | 否 / ✅ | `passed == false` 时 `observed` 与 `hint` **均必须非空**；`passed == true` 时 `hint` 可空（`API-04 §7.1`） |
| `SelfCheckItem.observed` | `String` | 否 | 可机读实测值（如 `'granted'` / `'xnnpack'` / `'0'` / `'未启用麦克风'` / `'无会话数据'`）；**不得为空字符串**（`API-04 §7.1`） |

### 4.2 自检项清单（总 14 项）

**4.2.A 前 9 项基础集**——`key` 与**顺序**逐字取自 `API-04 §7.1`；判定依据、`observed` 口径与 `hint` **一律以 `API-04 §7.1` 为准，本节不复制**（遵 `SPEC-00 §5.2` 只写一次原则）：

`permission` → `mic` → `model` → `delegate` → `featureConfig` → `db` → `knowledge` → `tempAudio` → `sampleAudio`

**4.2.B 第 10~14 项（现场判定必需，非可选扩展）**——已由 **ADR-04** 裁定并**写入 `API-04 §7.1`**（原「本 SPEC 增补、须回写」的状态已终结）；`key` / `label` / 判定依据 / `hint` 均以 `API-04 §7.1` 为准，下表只登记**本 SPEC 对每项的现场用途**：

| # | `key` / `label` | 判定依据（`API-04 §7.1` 第 10~14 项） | 覆盖的现场判定需求（主方案 §9） |
|---|---|---|---|
| 10 | `session` / 当前会话状态 | `API-01 §2.8` 的 `sessionState`；运行中为 `RUNNING`，无会话为 `IDLE` | 当前会话状态（决定能否切模式） |
| 11 | `modelInfo` / 模型版本与 `n_frames` | `getDiagnostics().modelVersion` 与 `modelNFrames` **均非 `null`**，且 `modelNFrames` **等于握手实际值**（**不得硬编码 128 或 129**，`SPEC-00 §3.5`；FF-11 现为 `n_frames = 128`，`ADR-21`） | 用的是哪一个模型、输入形状对不对 |
| 12 | `envelope` / 行为包络通道 | `getEnvelopeCapability().supported == true`，且 `envelopeLength` 与 `startSession` 出参一致（FF-21h） | 行为指标（咀嚼次数 / 进食速度）会不会缺席 |
| 13 | `dropRate` / 推理丢帧比例 | `patchesEmitted > 0` 时 `droppedPatches / patchesEmitted ≤ 0.05`（`API-01 §3.3`）；`patchesEmitted == 0` 时 `passed=true`、`observed='无会话数据'` | 推理是否跟得上（丢包比例） |
| 14 | `demoData` / 预置演示数据就绪 | `app/assets/demo_dataset.json` 可解析且标识与库内状态一致 | 预置演示数据是否就绪（Mode C 兜底前提） |

> 🔴 **第 10~14 项不是可选扩展（ADR-04 的理由，须在评审与验收时引用）**：主方案 §9 的现场降级判据需要「会话状态 / 模型版本与 `n_frames` / 丢帧比例 / 演示数据就绪」四类信息，而前 9 项**覆盖不到**；`SPEC-M-04` 的**现场 SOP 依赖它们区分「麦克风问题」与「模型问题」**。
> **第 3 与第 11 项的分工**：第 3 项判「模型**能否**用」，第 11 项判「用的是**哪个**模型、输入形状对不对」——**两者失败时的现场动作不同**（前者切 Mode C，后者禁止演示）。

> **需求覆盖的其余映射**：录音权限状态 → 第 1 项 `permission`；麦克风可用性与是否被占用 → 第 2 项 `mic`（**一个 key 同时判定两者**，`micInUseKnown == false` 时 `observed='未启用麦克风'` 且不判失败）；原生 Mel 版本 → 第 5 项 `featureConfig` 的 `observed` **必须回显** `getDiagnostics().nativeMelVersion` 实际值；数据库可写 → 第 6 项 `db`，**语义取「`DietRepo.countAll()` 不抛错」**——不做写探针，避免污染现场库；临时音频文件数 → 第 8 项 `tempAudio`。

**schema 引用**：`docs/common/docs_api/schemas/`。自检结果模型的字段真源为 `API-04 §7`，**14 项 `key`/`label`/判定依据的真源为 `API-04 §7.1`**；本 SPEC **不再持有第二份自检项定义**（原 4.2.B 的第二份定义已随 ADR-04 收敛，遵 `SPEC-00 §5.2` 只写一次原则）。

## 5. 参数与常量
| 编号 | 本功能的用途 |
|---|---|
| FF-11 | `n_frames` = **128**（**已修订**，`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~，`129` 现为 `raw_mel_frames`；见 FF-11）；面板只回显握手值（第 11 项 `modelInfo` 的 `modelNFrames`），**不得硬编码 128 或 129** |
| FF-18 / FF-19 | `delegate == cpu` 属允许的静默回退 → 第 4 项**判通过**；第 7 项 `knowledge` 的 `FoodKnowledgeBase.all.length == 6` 来源 |
| FF-21h | 第 12 项 `envelope` 的判据真源：包络长度 819 / hop 5 ms，须与 `startSession` 出参一致 |
| FF-23 | 页面数 = 4 → 面板**不得**成为独立第 5 页 |
| FF-24 | 第 2/4/6 条：临时文件清理可观测、无 `INTERNET`、无后台常驻 |
| FF-25 | 文案红线：面板文案不得出现绝对化表述 |
| `API-01 §3.3` | 第 13 项 `dropRate` 的判据阈值真源（`droppedPatches / patchesEmitted ≤ 0.05`） |
| `API-04 §6` | 第 14 项 `demoData` 的库内状态真源（`isDemoActive` ⇔ 库内存在 `source == 'demo'`） |

**本功能自定义常量（登记于本 SPEC，禁止散落字面值）**：`selfCheckItemTimeoutMs = 2000`（单项自检超时上限；**这是行为设计常量，不是性能预测值**）。若需现场可调，须走 `PLAN-C-03` 变更传播登记。

## 6. 异常与降级

**切换失败原因映射（必须展示 `code` + 人类可读原因 + 建议动作；`code` 取值域与 `API-04 §7.2/§8` 一致）**

| `code` | 人类可读原因 | 建议动作 |
|---|---|---|
| `ACD-DEMO-003` | 模式切换非法：会话运行中，或前置数据未就绪 | 先停止会话；或先加载演示数据集 |
| `ACD-DEMO-002` / `ACD-DEMO-001` | 演示数据集缺失/校验失败；示例音频缺失或损坏 | 检查 `app/assets/demo_dataset.json`（`API-05 §7`）；或按 `SPEC-M-02 §7 B7` 校验资产 |
| `ACD-CFG-001` / `ACD-INF-001` | 原生与 Dart 端配置不一致；模型加载失败 | 前者**重启应用**（仍失败 = 发布阻断缺陷）；后者重试加载（**模型侧问题**） |
| `ACD-PERM-001/002`、`ACD-AUD-001/002` | 未授予 / 被永久拒绝录音权限；`AudioRecord` 初始化失败 / 麦克风被占用 | 重试授权；永久拒绝 → 系统设置；设备类失败 → 重启应用或切其他模式 |
| `ACD-DB-003` / `ACD-IO-001` | 数据库事务失败 / 临时音频清理失败 | 前者重试一次，持续失败 → 用 Mode A/B；后者仅记日志，**不阻断演示** |

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `getDiagnostics()` 抛错 / 自检项超时 / 全部项超时 | try/catch + 逐项超时 | 面板**不崩溃**；相关项 `passed=false`，`observed` 为 `"unavailable"` 或 `"timeout"`；全部超时 → 结论行为「原生桥接异常」 | 「诊断接口不可用」/「原生桥接异常」+ 排查方向 |
| 切换失败 | `switchTo` 抛错 | 保留原模式，展示原因 | `code` + 原因 + 建议动作 |
| 面板在无模型 / 无权限下不可用，或无法给出「麦克风 / 模型」结论 | — | **均视为缺陷**（违背 §2.1 第 2 条与 §2.2 第 5 条） | 不适用 |

## 7. 验收标准（可机器判定）
> **本功能是 CP3 的组成部分。** CP3（D9 午）的判据是「三种 Demo 模式全部可用」，而**判定"可用"、并在失败时把三者切到可用状态的现场工具就是本面板**；因此本功能的完成时限早于 CP3（D8 晚可用，D9 午前完成 ≥3 轮实测，详见 `PLAN-M-04 §7`）。

| # | 判据 | 验证方式（命令 / 测试名） | 通过阈值 |
|---|---|---|---|
| D1 | 前 9 项同名同序 | `flutter test test/demo/self_check_test.dart --plain-name "core nine keys in api04 order"` | `items.take(9).map(key)` 逐项等于 §4.2.A 的 9 个 key（与 `API-04 §7.1` 第 1~9 项逐字一致） |
| D2 | 总项数与本 SPEC 一致 | 同上 `--plain-name "total item count is fourteen"` | `items.length == 14`，且第 10~14 项 `key` 依次为 `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`（`API-04 §7.1`） |
| D3 | 失败项必须带信息 | 同上 `--plain-name "failed item has observed and hint"` | 每个 `passed==false` 项：`observed` 非空且非泛化词、`hint` 非空、`allPassed==false`，**且不抛异常** |
| D4 | 三种模式均可切换 | 同上 `--plain-name "panel switches all three modes"` | `switchTo` 三次均成功，`currentMode` 每次正确 |
| D5 | 切换失败给出明确原因 | 同上 `--plain-name "switch failure exposes reason"` | 抛出的 `code ∈ {ACD-DEMO-003, ACD-DEMO-002, ACD-DEMO-001, ACD-PERM-001, ACD-PERM-002, ACD-AUD-001, ACD-AUD-002, ACD-CFG-001, ACD-INF-001, ACD-DB-003, ACD-IO-001}`；UI 原因字符串含建议动作 |
| D6 | 会话运行中切换必须报错 | 同上 `--plain-name "switch during session raises demo003"` | `code == "ACD-DEMO-003"`，且**未调用 `stopSession`**（不得乐观切换，`API-04 §7.2`） |
| D7 | 诊断接口故障不崩溃 | 同上 `--plain-name "selfcheck survives diagnostics failure"` | `runSelfCheck()` 正常返回，相关项 `passed=false` |
| D8 | 自检项独立超时 | 同上 `--plain-name "item timeout does not block others"` | 其余项仍完成，超时项 `observed=="timeout"` |
| D9 | 无会话时丢帧项语义正确 | 同上 `--plain-name "dropped ratio N/A without session"` | 第 13 项 `dropRate` 的 `observed=="无会话数据"`（`patchesEmitted == 0`），**不计入失败** |
| D10 | `delegate == cpu` 判通过 | 同上 `--plain-name "cpu delegate still passes"` | `passed==true` 且 `observed=="cpu"` |
| D11 | `n_frames` 不硬编码 | `pwsh -Command "Select-String -Path app/lib/**/*.dart -Pattern 'nFrames\\s*[:=]\\s*12[89]'"` | 命中数 **0**（FF-11 **已修订为 `128`**，`ADR-21`；面板仍**只回显握手值**，故零硬编码） |
| D12 | 结论行能区分麦克风 / 模型 | 同上 `--plain-name "verdict distinguishes mic vs model"` | 构造「仅麦克风项失败」「仅模型项失败」两种场景，结论行文本不同且语义正确 |
| D13 | 面板可达性 | `flutter test integration_test/panel_reachability_test.dart --plain-name "panel reachable within one tap"` | 冷启动后 ≤1 次点击进入面板 |
| D14 | 文案红线零命中 | `pwsh -Command "Select-String -Path docs/**/*.md,app/lib/**/*.dart -Pattern '2\\s*秒|2\\s*s\\s*内'"` | 命中数 **0**（FF-25）；同时 `aapt dump badging` 输出不含 `INTERNET`（FF-24 第 4 条，与 `SPEC-C-01` 同口径） |
| D18 | **免麦克风会话下 `mic` 项不判失败** | 同上 `--plain-name "mic passes when audio record skipped"` | `skipAudioRecord=true` 的会话下：`mic.passed == true` 且 `mic.observed == "未启用麦克风"`（`micInUse == null`、`micInUseKnown == false`）；`session` 项 `observed == "IDLE"` 或有效值（ADR-02 / `API-04 §7.1` 第 2、10 项） |
| D19 | **`envelope` 项判据完整** | 同上 `--plain-name "envelope capability gate"` | `getEnvelopeCapability().supported == false`（或 `envelopeLength` ≠ `startSession` 出参）时 `envelope.passed == false` 且 `hint` 非空（FF-21h，`API-01 §2.8`） |
| D20 | **`modelInfo` 未回填时不抛异常** | 同上 `--plain-name "modelInfo missing is a failure not a throw"` | 未调用 `setDiagnosticsModelInfo` 时 `modelInfo.passed == false`、`observed` 非空，`runSelfCheck()` **正常返回**（ADR-03） |
| D21 | **`demoData` 项与库内状态一致** | 同上 `--plain-name "demoData reflects library state"` | 数据集可解析且与库内 `source=='demo'` 状态一致 → `passed == true`；不一致 / 不可解析 → `passed == false` 且 `hint` 非空（ADR-04 第 14 项） |
| D22 | **第 3 与第 11 项现场动作可区分** | 同上 `--plain-name "model vs modelInfo differ in action"` | 仅第 3 项失败 → 结论行/建议指向**切 Mode C**；仅第 11 项失败 → 建议指向**禁止演示**；两者 `hint` 文本不同（ADR-04） |

> **编号说明**：**D18–D22 为 ADR-04 同步时新增**（对应第 10~14 项自检项落地），**D15–D17 为既有空缺，未占用**——它们**不是** §7 的自动化判据编号，而是下方两张人工表的既有标签（`D16 现场逐项核对表` / `D17 实测记录表`）。**不存在独立的 D15 条目**；凡引用「D15」的表述均为无效引用，已按实际标签修正。

**D16 现场逐项核对表（面板 · 人工核对，仅限 UI 视觉与文案）**

| # | 核对项 | 通过判据 | ☐ |
|---|---|---|---|
| 1 | 飞行模式下自检可用 | 全项有结果 | ☐ |
| 2 | 逐项列表 **14 项**齐全且顺序与 `API-04 §7.1` 一致 | 第 10~14 项依次为会话状态 / 模型版本与 `n_frames` / 包络通道 / 丢帧比例 / 演示数据 | ☐ |
| 3 | 失败项显示实测值而非「异常」 | `observed` 含具体值 | ☐ |
| 4 | 文字 + 颜色双通道 | 不依赖颜色也能分辨 | ☐ |
| 5 | 三个模式按钮可点且状态正确 | A/B/C 各点一次 | ☐ |
| 6 | 结论行明确指向「麦克风」或「模型」 | 刻意制造两类故障验证 | ☐ |
| 7 | 切换失败时显示 `code` + 建议动作 | 人为造 `ACD-AUD-002` 与会话中切换 | ☐ |
| 8 | **演示数据项反映库内真实状态** | 加载 / 清除演示数据后第 14 项 `demoData` 的 `observed` 随之改变 | ☐ |

**D17 实测记录表**

| 字段 | 说明 |
|---|---|
| 记录产物路径 | `docs/demo/D9_三模式实测记录.md`（面板段）+ 证据 `docs/demo/evidence/D9_selfcheck_*.log`（每次自检的完整 `SelfCheckReport` 快照） |
| 必填列 | 轮次 / 时间 / 场地 / 14 项 passed 汇总 / 失败项 key / `observed` / 结论行 / 随后切换到的模式 / 切换是否成功 / 是否与结论一致 |
| 轮次要求 / 时间证据 | ≥3 轮：①进场前（D9 早）②首次完整演示前 ③人为制造一类故障后。**缺失任一轮视为未实测**；记录表须含**时间戳**以证明「D9 前已可用」 |

## 8. 非功能约束
| 类别 | 约束 |
|---|---|
| 可用性（最高优先） | 面板**不依赖**麦克风、会话、模型、数据库可写；任一子系统故障时仍须给出结论 |
| 离线 | 全部数据来自进程内 `getDiagnostics()`（`API-01 §2.8`）、`getCapabilities()`（`API-01 §2.1`）、`getEnvelopeCapability()`（`API-01 §2.8`）与本地探针，**零网络**（FF-24 第 4 条） |
| 隐私 / 文案 / 无障碍 | 只展示计数与版本号，**不得展示任何音频内容或含个人信息的文件路径**；`observed` 必须是可信实测值，禁止「正常」等无法证伪的措辞；通过/失败必须**文字 + 颜色**双通道表达（`API-04 §7.1` 同义要求） |
| 数据来源唯一性 | 第 11 项 `modelInfo` 的值**只读** `getDiagnostics()` 的回显（该回显由 Dart 侧 `setDiagnosticsModelInfo` 回填）；**禁止**面板自行去 `InferenceEngine` 取第二份值，否则两处会不一致（ADR-03） |
| 可维护性 | `runSelfCheck()` 是 Mode A/B/C 前置校验的**唯一实现**；禁止各处复制一份；**14 项判定依据的唯一真源是 `API-04 §7.1`**，面板不持有第二份 |
| 时限 | **D9 前必须可用**（主方案 §9；`API-01 §2.8` 亦明示） |

## 9. 裁剪与未做
> **本功能不可裁剪。** 理由：①它是主方案 §8.2.1 第⑤项「三种 Demo 模式」的**唯一入口与故障判定面**——砍掉它，三种模式在现场无法被可靠启动与诊断；②CP3 判据是「三种 Demo 模式是否全部可用」，而"可用"的**现场证明手段**就是本面板；③主方案 §8.2.4 规定 CP3 未过时 Mode B + Mode C 必须可用，而切换动作由本面板承载。任何削减须经 A/B/C 三方确认并登记 `PLAN-00 §6`。

| 项 | 状态 |
|---|---|
| 独立第 5 个页面 / 新 Tab；远程诊断 / 日志上报 | ❌ 不做（FF-23；FF-24 第 4 条） |
| 自动修复 / 乐观切换；多种自检预设模板 | ❌ 不做（`API-04 §7.2`）；一次点击跑全量 |
| 性能剖析面板（CPU/内存曲线） | 🔵 推迟；本窗口只做「能不能演示」的判定 |

## 10. 开放问题
1. ✅ **已关闭（依据 ADR-04）** 原开放问题「14 项 vs `API-04 §7.1` 的 9 项」。**结论**：`API-04 §7.1` 已由 9 项**扩为 14 项**——原 9 项**同名同序保留**，追加 `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`。**这 5 项不是可选扩展**：`SPEC-M-04` 的现场 SOP 依赖它们区分「麦克风问题」与「模型问题」（原 9 项里第 3 项只判「模型能否用」，与「用的是哪个模型、输入形状对不对」是两件事，失败时的现场动作也不同——前者切 Mode C，后者禁止演示）。`allPassed` ⇔ 14 项**全部** `passed == true`；`observed` 不得为空字符串；`hint` 可空，**仅失败项必须给可执行动作**。本 SPEC §4.2 已按该清单收敛，**不再持有第二份自检项定义**。
2. ✅ **已关闭（依据 ADR-04）** 原开放问题「`ambientNoise` 的测量方式与真源未定；`selfCheckItemTimeoutMs` 的归属未定」。**结论**：**`ambientNoise` 不进自检清单**——`API-04 §7.1` 已把自检项冻结为**恰好 14 项且顺序一致**（ADR-04），`ambientNoise` 不在其中，**也不得加进去**。它是**进场前的人工 SOP 实测**（主方案 §9.2「提前 30 分钟到场，实测一次完整流程……环境噪声 >65 dB 直接走 Mode B」）：由**人拿外部工具（声级计 / 手机测噪 App）现场测**，**不经过 `DemoController.runSelfCheck()`**，由 **`SPEC-M-01 §7 A6`** 作为人工核对项承载（实测 dB 值 + 所用工具名写入 A12 记录表）。因此本 SPEC 原先把 `ambientNoise` 写成「本 SPEC 增补的第 14 项」是**错误口径，已作废**；`items` 必须恰好 14 项，**任何噪声相关 key 都不得出现**。`selfCheckItemTimeoutMs` 仍为本 SPEC 自定义常量（**不是性能预测值**）；若将来要登记进 `feature_config`，须走 `SPEC-C-03`。
3. ✅ **已关闭（依据 ADR-03）** 原开放问题「模型版本与 `n_frames` 的数据源缺口」。**结论**：`API-01 §2.8` 的 `getDiagnostics()` 新增 **`modelVersion` / `modelNFrames`**（**默认 `null`**）；新增 **`setDiagnosticsModelInfo({version, nFrames})`**，由 Dart 在 `InferenceEngine.load()` 成功后回填（`nFrames` 取握手实际值，**禁止硬编码**）；并**明确禁止**为了填这两个字段而让原生加载模型——那会把推理分裂成两份。第 11 项 `modelInfo` 因此有了单一数据源：`getDiagnostics()` 的回显值。**原问题里「`n_frames` 没有确定值」这一半随 `ADR-P1` 一并解除**——`n_frames` = `129`（**已冻结**，见 FF-11 / `ADR-P1`），面板仍**只回显握手值、不硬编码**。未回填时 `modelInfo.passed == false` 且**不抛异常**（D20）。第 12 项 `envelope` 同理以 `getEnvelopeCapability()` 为数据源。
4. **`ACD-DEMO-002` / `ACD-DEMO-003` 尚未生效**：`API-04 §8` 尾注明确「3 个新增码须先补登 `API-00 §3.5` 才生效」。本 SPEC 已按新码撰写，**补登动作需在 D9 前完成**，否则现场错误码无权威依据。

**文档结束**

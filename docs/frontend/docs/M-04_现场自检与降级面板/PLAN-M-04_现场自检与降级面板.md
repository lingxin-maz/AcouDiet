# PLAN-M-04 现场自检与降级面板

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-M-04` |
| 负责 | **B 主责**（自检实现、面板、切换与原因映射）；C 协助（面板文案、现场核对表与演练）；A 支撑（模型版本与 `n_frames` 的数据源） |
| 目标日 | **D9**（**硬要求：D8 晚必须可用**，D9 午 CP3 前完成 ≥3 轮实测） |
| 前置依赖 | `PLAN-P-01`（`getDiagnostics` / `getEnvelopeCapability` 可用）、`PLAN-P-05`（模型加载状态可读）、`PLAN-D-01`（DB 探针）、`PLAN-A-04`（演示数据就绪探针）、**`API-04 §7.1` 已冻结 14 项自检清单**、**ADR-02 / ADR-03 / ADR-04 已裁定** |
| 预估工时 | **5 h**（B 3.5 h ｜ C 1 h ｜ A 0.5 h） |

## 1. 交付物（Deliverables）
| # | 产物 | 说明 |
|---|---|---|
| 1 | `app/lib/features/demo/demo_controller.dart` | `DemoController` 完整实现（本 PLAN 与 `PLAN-M-01`/`M-02`/`M-03` 共用同一文件） |
| 2 | `app/lib/features/demo/self_check.dart` | `SelfCheckReport` / `SelfCheckItem` + `API-04 §7.1` 冻结的 **14 项**（前 9 项基础集 + 第 10~14 项 `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`） |
| 3 | `app/lib/features/demo/widgets/self_check_panel.dart` | 面板 UI：逐项列表 + 结论行 + 三个模式按钮 + 失败原因 |
| 4 | `app/lib/features/demo/switch_error_messages.dart` | SPEC §6 的错误码 → 人类可读原因 + 建议动作映射表 |
| 5 | `app/test/demo/self_check_test.dart` | SPEC §7 的 D1–D14、D18–D22（**D15–D17 为既有空缺，见 SPEC §7 表下注**） |
| 6 | `app/integration_test/panel_reachability_test.dart` | **D13**（面板可达性） |
| 7 | `docs/demo/面板现场核对表.md` | **D16** 现场逐项核对表的可打印版本（与 `docs/demo/现场SOP卡片.md` 同批携带） |
| 8 | `docs/demo/D9_三模式实测记录.md` | 面板段；含 SPEC §7 **D17** 实测记录表 |
| 9 | `docs/demo/evidence/D9_selfcheck_*.log` | 每次自检的完整 `SelfCheckReport` 快照（含时间戳） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 落 `DemoMode` / `DemoController` / `SelfCheckReport` / `SelfCheckItem` 签名并与 `API-04 §7` 逐字对齐 | 交付物 1、2（骨架） | 0.5 h | `API-04 §7` |
| 2 | 实现前 9 项基础集（`API-04 §7.1`：`permission` / `mic` / `model` / `delegate` / `featureConfig` / `db` / `knowledge` / `tempAudio` / `sampleAudio`），顺序一致 | 交付物 2 | 1.0 h | 任务 1、`PLAN-P-01`、`PLAN-A-04` |
| 3 | 实现第 10~14 项（`session` / `modelInfo` / `envelope` / `dropRate` / `demoData`）；`modelInfo` 只读 `getDiagnostics()` 回显、由 `setDiagnosticsModelInfo` 回填（**禁止硬编码 `n_frames`、禁止让原生加载模型**）；`envelope` 用 `getEnvelopeCapability()` | 交付物 2 | 0.5 h | 任务 1、`PLAN-P-05`；ADR-03 / ADR-04 |
| 4 | 单项独立超时与故障隔离（诊断接口抛错也不崩）；`delegate==cpu` 判通过；**`micInUseKnown==false` 时 `mic` 项 `observed='未启用麦克风'` 且不判失败**（ADR-02） | 交付物 2 | 0.5 h | 任务 2 |
| 5 | 切换失败原因映射表 + `switchTo` 非法迁移报 `ACD-DEMO-003`（**不做乐观切换、不自动 stopSession**） | 交付物 4、1 | 0.5 h | 任务 1；`API-04 §7.2` |
| 6 | 面板 UI：逐项列表（文字 + 颜色）、结论行、三按钮、失败原因 | 交付物 3、7 | 0.75 h | 任务 5；C 提供文案 |
| 7 | 结论行判定逻辑（仅麦克风失败 / 仅模型失败 / 两侧失败） | 交付物 3 | 0.25 h | 任务 6 |
| 8 | 自动化测试 D1–D14、D18–D22 | 交付物 5、6 | 0.5 h | 任务 4、7 |
| 9 | 现场 3 轮实测 + 记录表 + 快照归档（D16/D17） | 交付物 8、9 | 0.5 h | 任务 8；**D8 晚起可用** |

## 3. 技术方案
> 与 `SPEC-M-04 §3/§4/§6` 契约一致；签名权威在 `API-04 §7`。**`runSelfCheck()` 是全项目唯一实现**，Mode A/B/C 的前置校验都调它。骨架 ≤30 行。

```dart
class DemoController {
  DemoMode _mode = DemoMode.realtime;                        // API-04 §7: 默认 realtime
  DemoMode get currentMode => _mode;

  Future<SelfCheckReport> runSelfCheck() async {
    final items = await Future.wait(_checks.map(_runOne));    // 每项独立超时、独立失败
    return SelfCheckReport(allPassed: items.isNotEmpty &&
        items.every((i) => i.passed), items: items);          // 空列表 => false
  }

  Future<SelfCheckItem> _runOne(_Check c) async {
    try {
      final v = await c.probe().timeout(_kItemTimeout);       // selfCheckItemTimeoutMs
      return SelfCheckItem(key: c.key, label: c.label,
        passed: c.judge(v), observed: c.observe(v), hint: c.hint(v));
    } catch (_) {
      return SelfCheckItem(key: c.key, label: c.label, passed: false,
        observed: 'unavailable', hint: c.failureHint);        // 面板不得崩溃
    }
  }

  Future<void> switchTo(DemoMode m) async {
    if (_activeSessionId != null) throw _err('ACD-DEMO-003'); // API-04 §7.2: 不得乐观切换
    await _assertPrereq(m);                                   // 前置未就绪亦 -> ACD-DEMO-003
    await _activate(m);
    _mode = m;                                                // 成功后才更新
  }

  // ADR-03：模型信息回填（InferenceEngine.load() 成功后一次），
  // 供第 11 项 modelInfo 从 getDiagnostics() 单一来源回显。
  Future<void> _onModelLoaded(int nFramesFromHandshake) =>
    _native.setDiagnosticsModelInfo({
      'version': _engine.version, 'nFrames': nFramesFromHandshake }); // 禁止硬编码（FF-11 = 128，ADR-21）
}
```

**关键实现约定**
1. `items` 顺序 = `API-04 §7.1` 的**前 9 项基础集**（在前，`key` 与顺序**不得改动**）+ **第 10~14 项** `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`（在后），共 14 项；**14 项判定依据的唯一真源是 `API-04 §7.1`**，本 PLAN 与 SPEC 都不得持有第二份。
2. `observed` 必须是**实测值**（如 `"granted"`、`"xnnpack"`、`"0"`、`"未启用麦克风"`、`"无会话数据"`），禁止「正常」「异常」等泛化词（`API-04 §7.1`）。
3. `runSelfCheck()` **不抛异常**：所有失败都编码进 `items`（`API-04 §7`）。
4. `dropRate`（第 13 项）在 `patchesEmitted == 0` 时 `observed="无会话数据"` 且 `passed=true`——**不得**当作 0 丢帧上报（`API-04 §7.1`）。
5. `delegate == "cpu"` 判通过（FF-18 允许回退），但 `observed` 必须显示实际值。
6. `modelInfo`（第 11 项）的值**只读** `getDiagnostics()` 的 `modelVersion` / `modelNFrames`；回填动作在 `InferenceEngine.load()` 成功后调 `setDiagnosticsModelInfo({version, nFrames})` 一次，`nFrames` 取**握手实际值**（FF-11 = **`128`**，`ADR-21` 修订；原 `ADR-P1` 冻结值 ~~129~~；`SPEC-00 §3.5`）——**禁止硬编码 128 或 129，禁止让原生加载模型来填这两个字段**（ADR-03）。D11 静态扫描零硬编码。
7. `mic`（第 2 项）在 `skipAudioRecord=true` 的会话下 `micInUseKnown == false`、`micInUse == null`：`observed="未启用麦克风"`、`passed=true`（ADR-02），**不得判失败**。
8. 面板 UI 挂到现有页面/设置入口下，**不新增 Tab**（FF-23）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `--plain-name "core nine keys in api04 order"` | 单元 | 前 9 项 `key` 与顺序逐项等于 `API-04 §7.1` | 每次提交 |
| `--plain-name "total item count is fourteen"` | 单元 | `items.length == 14`，增补 5 项在末尾 | 每次提交 |
| `--plain-name "failed item has observed and hint"` | 单元 | 失败项 `observed`/`hint` 非空且非泛化词；不抛异常 | 每次提交 |
| `--plain-name "panel switches all three modes"` | 单元 | 三模式切换均成功 | 每次提交 |
| `--plain-name "switch during session raises demo003"` | 单元 | `code=="ACD-DEMO-003"` 且**未调用 `stopSession`** | 每次提交 |
| `--plain-name "switch failure exposes reason"` | 单元 | `code ∈ API-04 §7.2` 集合；原因含建议动作 | 每次提交 |
| `--plain-name "selfcheck survives diagnostics failure"` | 单元 | 不崩溃，相关项失败 | 每次提交 |
| `--plain-name "item timeout does not block others"` | 单元 | 其余项仍完成，超时项 `observed=="timeout"` | 每次提交 |
| `--plain-name "dropped ratio N/A without session"` | 单元 | 无会话时不计失败 | 每次提交 |
| `--plain-name "cpu delegate still passes"` | 单元 | `passed==true` 且 `observed=="cpu"`（FF-18） | 每次提交 |
| `--plain-name "mic passes when audio record skipped"`（D18） | 单元 | `skipAudioRecord=true` 会话下 `mic.passed==true` 且 `observed=="未启用麦克风"` | 每次提交 |
| `--plain-name "envelope capability gate"`（D19） | 单元 | `supported==false` 或长度不一致时 `envelope.passed==false` 且 `hint` 非空 | 每次提交 |
| `--plain-name "modelInfo missing is a failure not a throw"`（D20） | 单元 | 未回填 → `modelInfo.passed==false`，`runSelfCheck()` 正常返回 | 每次提交 |
| `--plain-name "demoData reflects library state"`（D21） | 单元 | 与库内 `source=='demo'` 状态一致时通过，否则失败且 `hint` 非空 | 每次提交 |
| `--plain-name "model vs modelInfo differ in action"`（D22） | 单元 | 第 3 / 第 11 项失败时建议动作不同（切 Mode C vs 禁止演示） | 每次提交 |
| `--plain-name "verdict distinguishes mic vs model"` | 单元 | 两类故障结论不同 | 每次提交 |
| `panel_reachability_test.dart --plain-name "panel reachable within one tap"` | 集成 | 冷启动 ≤1 次点击 | 每次提交 |
| `n_frames` 硬编码扫描（D11） | 静态 | 命中数 0 | 每次提交 |
| 文案红线扫描（D14） | 静态 | 命中数 0 | D9 前 |
| `aapt dump badging`（D14 附） | 产物 | 无 `INTERNET` | D9 出包后 |
| 现场 3 轮自检（D16/D17） | 人工核对表 + 记录表 | 记录表含时间戳、无空列 | **D8 晚 + D9 早 + D9 现场** |

## 5. 完成定义（DoD）
- [ ] `SPEC-M-04 §7` 的 **D1–D14、D18–D22 全部判据通过**（测试全绿 / 扫描零命中）。
- [ ] 前 9 项 `key` 与顺序**与 `API-04 §7.1` 逐字一致**；第 10~14 项依次为 `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`，共 14 项（ADR-04）。
- [ ] **D8 晚面板已可运行**（`docs/demo/evidence/D9_selfcheck_*.log` 中存在 D8 晚时间戳的快照）——这是本功能的硬时限。
- [ ] D17 记录表 ≥3 轮齐备（含时间戳），结论行与实际故障类型一致。
- [ ] **D16 现场核对表 8 项** 100% 勾选并签字；打印件与 `docs/demo/现场SOP卡片.md` 同批携带。
- [ ] `runSelfCheck()` 被 `PLAN-M-01`/`M-02`/`M-03` 复用（代码审查：仓库内仅一份自检实现）。
- [ ] `SPEC-M-04 §10` 开放问题 **1（14 项）、2（`ambientNoise` 口径）、3（模型版本数据源）均已关闭并回写本 SPEC**（分别依据 ADR-04 / ADR-04 / ADR-03）；开放问题 4（`ACD-DEMO-002/003` 补登 `API-00 §3.5`）已闭环。
- [ ] 代码合入 D8 节点分支；D9 之后仅允许改面板文案，**不允许改自检判定逻辑**。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 14 项与 `API-04 §7.1` 不一致（`key` / 顺序 / 项数） | 任一自检项键名或顺序漂移 | ✅ 已裁定：**ADR-04 已将 `API-04 §7.1` 扩为 14 项**，前 9 项同名同序、追加 `session`/`modelInfo`/`envelope`/`dropRate`/`demoData`。实现**只以 `API-04 §7.1` 为真源**，本 PLAN 与 SPEC 不持有第二份定义；D1/D2 直接断言 |
| `ACD-DEMO-002/003` 未补登 `API-00 §3.5` | `SPEC-M-04 §10` 开放问题 4 未决 | 现场错误码暂以 `API-04 §8` 为据；**D9 前必须补登**（`API-02 §8` 新增码亦同批处理） |
| 模型版本 / `n_frames` 取不到值 | 第 11 项 `modelInfo.passed == false`（`modelVersion`/`modelNFrames` 为 `null`） | ✅ 数据源已裁定（**ADR-03**）：`setDiagnosticsModelInfo({version, nFrames})` 在 `InferenceEngine.load()` 成功后回填，`nFrames` 取握手实际值；面板只读 `getDiagnostics()` 回显。回填前该项判失败但**不抛异常**（D20），**禁止**让原生加载模型来填 |
| 行为包络通道不可用 | 第 12 项 `envelope.passed == false` | 启动时以 `getEnvelopeCapability()` 断言（`API-01 §2.8`）；不通过则**行为指标缺席**，现场讲解不得声称会出咀嚼次数（D19） |
| 环境噪声项无统一测量方式（`SPEC-M-04 §10` 开放问题 2） | 试图把噪声读数塞进 `items` | **口径已修正**：`ambientNoise` **不是** 14 项之一（`API-04 §7.1`），噪声读数由进场前 SOP 实测记录承载；**不得**加为第 15 项，否则 D2 失败 |
| 诊断接口在部分机型上不可用 | `getDiagnostics()` 抛错 | 面板仍渲染，相关项标 `unavailable` 并给排查方向（`SPEC-M-04 §7` 的 **D7** 已覆盖） |
| 面板实际做成第 5 页 | 与 FF-23 冲突 | 立即改为设置入口下的抽屉/子页；`PLAN-U-05` 复核 |
| 自检全绿但现场仍演不出来 | 自检与实况不符 | 记录表中登记「自检结论 vs 实际」差异，作为下一轮自检项增补依据（**不得在 D9 临时改代码**，SOP 第 5 条） |
| 现场时间紧张、跳过自检 | 未跑 D17 第 2 轮 | SOP 卡片把「演示前一次自检」列为强制步骤；记录表缺轮即视为未实测 |
| `switchTo` 切换时丢记录 | 实时会话中切换 | `API-04 §7.2` 已裁定「会话运行中 → 任意模式 ❌」：现场约定「先停止再切换」，**不切换进行中的会话**（该约定与 `ADR-P1` 无关，不因 `n_frames` 已冻结而放宽） |

## 7. 与检查点的关系
> **本功能是 CP3 的组成部分。**

| 项 | 内容 |
|---|---|
| 涉及检查点 | **CP3（D9 午）**：判据「三种 Demo 模式全部可用」 |
| 本功能的 CP3 判据 | 面板可一键给出 14 项自检结果与「麦克风 / 模型」结论行；A/B/C 三模式均可从面板切换；D17 记录表 ≥3 轮且结论与实际一致 |
| 本功能对 CP3 的特殊意义 | CP3 的判据要求「可用」，而**判定"可用"的现场工具就是本面板**。因此本 PLAN 的完成时限早于 CP3：**D8 晚可用**，D9 午前完成实测 |
| CP3 未过时的处置 | `PLAN-00 §2`：停止一切新功能，3 人扑 Demo 稳定性；主方案 §8.2.4：Mode B + Mode C 必须可用——**面板是将三者切到可用状态的唯一手段，不退让** |
| 与其他 PLAN 的耦合 | `PLAN-M-01`/`M-02`/`M-03` 的前置校验均调用本 PLAN 的 `runSelfCheck()`；本 PLAN 依赖 `PLAN-P-01` 的 `getDiagnostics()`（`API-01 §2.8` 明示「必须在 D9 前可用」） |

**文档结束**

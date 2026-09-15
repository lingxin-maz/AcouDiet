# PLAN-M-01 Demo Mode A · 实时识别

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-M-01` |
| 负责 | **B 主责**（编排与联调）；C 协助（演示脚本、现场核对表、SOP 卡片）；A 支撑（真机延迟与耗时实测） |
| 目标日 | **D9**（D8 晚完成可演示版本，D9 上午实测） |
| 前置依赖 | `PLAN-P-01`（采集）、`PLAN-P-06`（三级聚合）、`PLAN-U-02`（检测页）、`PLAN-U-06`（波形组件）、`PLAN-M-04`（自检面板）、**`API-04 §7` 接口已冻结**、**CP2（D5 端到端闭环）已通过**、`n_frames = 128`（**`ADR-21`，2026-09-12 修订**：旧值 ~~`n_frames = 129`~~，`129` 现为 `raw_mel_frames`；FF-11 / `ADR-21`） |
| 预估工时 | **5 h**（B 3.5 h ｜ C 1 h ｜ A 0.5 h） |

## 1. 交付物（Deliverables）
| # | 产物 | 说明 |
|---|---|---|
| 1 | `app/lib/features/demo/demo_mode.dart` | `enum DemoMode { realtime, sampleAudio, reportOnly }` |
| 2 | `app/lib/features/demo/demo_controller.dart` | `DemoController`：`currentMode` / `switchTo` / `runSelfCheck` / `startRealtimeSession` |
| 3 | `app/lib/features/detection/widgets/unconfirmed_prediction.dart` | 未确认实时预测（灰显 + 「未确认」字样） |
| 4 | `app/lib/features/detection/widgets/noise_gate_banner.dart` | 噪声 >65 dB 提示 + 一键切 Mode B（**判据为进场前人工 SOP 实测值，非自检项**，`SPEC-M-01 §7 A6`） |
| 5 | `app/test/demo/demo_mode_a_test.dart` | SPEC §7 的 A1–A5、A9 自动化判据（**A6 已改为人工核对项，不再有自动化断言**） |
| 6 | `records/demo/D9_三模式实测记录.md` | Mode A 段；含 SPEC §7 A12 记录表 |
| 7 | `records/demo/evidence/D9_modeA_*.log` | 原始证据：`getDiagnostics()` 快照 + 事件时序日志 |
| 8 | `records/demo/现场SOP卡片.md` | 主方案 §9.2 六条 SOP 的现场可打印卡片（内容载体见 `PLAN-M-03` §1） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 落 `DemoMode` 枚举与 `DemoController` 骨架（`switchTo` / `currentMode`） | 交付物 1、2 | 0.5 h | `PLAN-M-04` 接口冻结 |
| 2 | 启动前置自检编排：`runSelfCheck()` → 阻断 / 放行 | `demo_controller.dart` 中 `_precheck()` | 0.5 h | 任务 1 |
| 3 | 接 `startSession` / 订阅事件 / `ackPatch` 配对 / `stopSession` 收尾 | 会话闭环 | 1.0 h | `PLAN-P-01` |
| 4 | 双路消费：单 patch 未确认预测 + 聚合确认卡片 | 交付物 3 | 1.0 h | `PLAN-P-06` |
| 5 | 噪声门限提示与一键切 Mode B（**读人工实测 dB 值，不读自检项**）；`droppedPatches` 阈值提示；**现场处置表分支（含麦克风故障 → 带 `skipAudioRecord=true` 的 Mode B）** | 交付物 4 | 0.5 h | 任务 2、`SPEC-M-04` |
| 6 | 自动化测试 A1–A5、A9 | 交付物 5 | 0.75 h | 任务 3、4 |
| 7 | 真机 3 轮实测 + 记录表 + 证据归档（A10、A11） | 交付物 6、7 | 0.5 h | 任务 5；CP2 已通 |
| 8 | 演示脚本 Mode A 段文案与口径复核（FF-25 / A7） | `records/demo/现场SOP卡片.md` 第 7 项 | 0.25 h | C |

## 3. 技术方案
> 与 `SPEC-M-01 §3` 契约一致；**不另立参数**。以下为骨架（≤30 行）。

```dart
enum DemoMode { realtime, sampleAudio, reportOnly }

class DemoController {
  DemoMode _mode = DemoMode.realtime;
  DemoMode get currentMode => _mode;

  Future<void> startRealtimeSession() async {
    final r = await runSelfCheck();
    if (!r.allPassed) throw _blockingError(r);          // §6 错误码映射，不新造码
    if (_activeSessionId != null) await _stop();        // 不做隐式替换
    final id = _newSessionId();                         // S-<epochMs>-<4hex>
    await _native.startSession({ 'sessionId': id,
      'enableDenoise': false, 'autoEndOnSilence': true,
      'silenceEndSeconds': FF21a.silenceEndSeconds });   // 见 SPEC-M-01 §5
    _sub = _events.listen(_onEvent);                    // level / patch / sessionEnded
  }

  void _onEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'level':  _wave.push(e);                     // 仅动画，不参与判定
      case 'patch':  _unconfirmed.update(e);            // 路 1：立即刷新灰显预测
                     _aggregator.feed(e).then((d) =>    // 路 2：累积出确认结果
                       _native.ackPatch({'sessionId': e['sessionId'], 'seq': e['seq']}));
      case 'sessionEnded': _finalize(e);                // 落库 + clearTempAudio
    }
  }
}
```

**关键实现约定**
1. `ackPatch` 必须在**推理完成后**发出（`API-01 §3.3`），且与收到的 `patch` 一一配对。
2. 未确认预测**只读单 patch**，不得写入数据库、不得进入 EMA 之外的统计。
3. `voiced == false` 的 patch 仍要喂 `_aggregator`（FF-20c）。
4. 所有阈值取自 `feature_config` 生成的 Dart 常量，**禁止手写字符串键名**（`API-00 §3.1`）。
5. 未经握手校验不得进入实时会话（`ACD-CFG-001` fail fast）。
6. **现场处置表的三条分支必须可一键到达**（`SPEC-M-01 §6`）：设备类故障（`ACD-AUD-001/002`、`ACD-PERM-002`）走「Mode B + `skipAudioRecord:true`」（`API-01 §2.3`），环境噪声走普通 Mode B，`ACD-INF-001` 直接转 Mode C。切换前**必须** `await stopSession` 完成（`API-01 §4` 单会话约束），不得乐观切换。
7. `startRealtimeSession` 的 `startSession` 调用**不传** `skipAudioRecord`（取默认 `false`）——本模式的价值就在实时麦克风；`skipAudioRecord:true` 只属于 Mode B 的切换路径（`API-01 §2.3`）。
8. **环境噪声**：`noise_gate_banner` 的显隐由**现场人工实测的 dB 值**驱动（声级计 / 手机测噪 App，主方案 §9.2），**不读取 `SelfCheckReport.items`**——`ambientNoise` **不是**自检项，`API-04 §7.1` 的 14 项已冻结且不含它。实测 dB 值与工具名写入 `SPEC-M-01 §7 A12` 记录表（A6 为人工核对项）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `demo_mode_a_test.dart --plain-name "modeA blocked by selfcheck"` | 单元 | 未调用 `startSession`；`currentMode` 不变 | 每次提交 |
| `--plain-name "modeA blocked by cfg mismatch"` | 单元 | `PlatformException.code == "ACD-CFG-001"` | 每次提交 |
| `--plain-name "modeA session lifecycle"` | 单元（mock channel） | 调用序列正确；`ackPatch` 次数 == `patch` 次数 | 每次提交 |
| `--plain-name "unconfirmed prediction independent of aggregation"` | Widget | 未确认更新 ≥3 次；未确认阶段不渲染确认卡片 | 每次提交 |
| `--plain-name "aggregation state persists across patches"` | 单元 | EMA 与连续计数跨 patch 不归零 | 每次提交 |
| `--plain-name "noise banner is manual, not selfcheck"` | 单元 | 噪声横幅的显隐由**入参的实测 dB 值**驱动，**不读取 `SelfCheckReport.items`**；`items` 长度为 14 且**不含任何噪声相关 key**（ADR-04） | 每次提交 |
| `--plain-name "mic failure falls back with skipAudioRecord"` | 单元（mock channel） | 构造 `startSession` 抛 `ACD-AUD-002` → 切到 Mode B 时 `startSession` 载荷含 `skipAudioRecord == true`（`API-01 §2.3`） | 每次提交 |
| `--plain-name "temp audio cleared after session"` | 单元 | `audio_*` 文件数 == 0 | 每次提交 |
| 文案红线扫描（SPEC §7 A7） | 静态 | 命中数 0 | D9 演示前 |
| `aapt dump badging`（SPEC §7 A8） | 产物 | 无 `INTERNET` | D9 出包后 |
| 真机 3 轮实测（SPEC §7 A10/A11/A12） | 人工核对表 + 记录表 | 逐项勾选 + 记录表无空列 | **D9 上午** |

## 5. 完成定义（DoD）
- [ ] `SPEC-M-01 §7` 的 **A1–A5、A9 自动化判据全部通过**（命令退出码 0）；**A6 改为人工核对项**，随 A11/A12 一并验收。
- [ ] A10 的**真机实测值已记录**（不是预测值），并标注「D9 实测产出」。
- [ ] A11 现场核对表 **8 项** 100% 勾选并签字（含第 8 项：现场噪声已用外部工具实测并记录 dB 值 + 工具名）。
- [ ] A12 记录表 ≥3 轮有效，产物路径 `records/demo/D9_三模式实测记录.md` 与 `records/demo/evidence/` 可点开。
- [ ] `records/demo/现场SOP卡片.md` 六条 SOP 齐备且可打印。
- [ ] 演示脚本 Mode A 段无「2 秒」类表述（A7 零命中）。
- [ ] **现场处置表三分支均已在真机或 mock 上验证**（`SPEC-M-01 §6`）：设备类故障路径确实带上 `skipAudioRecord:true`（ADR-02），`ACD-INF-001` 路径转 Mode C。
- [ ] 代码合入 D9 节点分支；**D10 之后不得再提交**（`PLAN-00 §4`）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 现场噪声导致实时识别失败（R-5） | **人工实测**噪声读数 >65 dB 或实拍连续失败 | 一键切 Mode B（`SPEC-M-02`）；SOP 第 3 条。噪声判断**不经自检面板**（`SPEC-M-01 §7 A6`） |
| 首次确认耗时观感偏慢（R-21） | 现场有人质疑「卡」 | 强调双路展示：波形 + 未确认预测在确认前已给出反馈；讲解 FF-20a 原理，**不给预测数字** |
| 麦克风被占用（`ACD-AUD-002`）或硬件故障（`ACD-AUD-001`） | 启动即报错 | 按 `SPEC-M-01 §6` 现场处置表第 2 行：切 Mode B 并**必须带 `skipAudioRecord=true`**（`API-01 §2.3`，ADR-02）；仍失败则转 Mode C（`SPEC-M-03`）。**禁止**用普通参数切 Mode B——那仍会打开 `AudioRecord` |
| 背压丢包超阈 | `droppedPatches / patchesEmitted > 0.05` | 提高推理步长至 `PLAN-P-05` 的降级档；仍不行则切 Mode B |
| 双机型号差异导致行为不同 | 备用机实测异常 | 现场固定使用已实测通过的那台；记录表登记机型 |
| 模式切换失败 | `switchTo` 抛错 | 展示自检面板给出的**明确原因**（`SPEC-M-04 §6`），人工按 SOP 处置 |
| 现场临时改代码 | 有人在 D9/D10 提交 | SOP 第 5 条禁止；改代码即视为放弃本次实测结果 |

## 7. 与检查点的关系
> **本功能是 CP3 的组成部分。**

| 项 | 内容 |
|---|---|
| 涉及检查点 | **CP3（D9 午）**：判据「三种 Demo 模式全部可用」 |
| 本功能的 CP3 判据 | Mode A 可在真机上完成「开始进食 → 波形 + 未确认预测 → 确认结果 → 落库」全流程，且 `SPEC-M-01 §7` A1–A9 全通过、A11 全勾选 |
| CP3 未过时的处置 | 按 `PLAN-00 §2`：**停止一切新功能**，3 人全部扑 Demo 稳定性；按主方案 §8.2.4，**Mode B + Mode C 必须可用**（Mode A 可退让，B/C 不退让） |
| 与 CP2 的关系 | CP2（D5）已要求端到端闭环跑通；本功能在 CP2 通过的链路上**只加编排与观感层**，不得引入新的原生契约 |
| 与其他 PLAN 的耦合 | `PLAN-M-02`（Mode B 复用同一聚合路径）、`PLAN-M-04`（自检面板是 Mode A 的入口前置） |

**文档结束**

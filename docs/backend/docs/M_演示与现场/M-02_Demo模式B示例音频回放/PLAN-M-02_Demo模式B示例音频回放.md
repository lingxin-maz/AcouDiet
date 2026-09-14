# PLAN-M-02 Demo Mode B · 示例音频回放

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-M-02` |
| 负责 | **B 主责**（注入链路与等价性验证）；C 协助（自采 30 段资产、清单登记、现场核对）；A 支撑（等价性判定的统计口径） |
| 目标日 | **D9**（资产自采自 **D2** 开始，D8 前收齐并冻结，D9 实测） |
| 前置依赖 | `PLAN-P-01`（环形缓冲）、`PLAN-P-04`（Mel 前端）、`PLAN-P-06`（聚合）、`PLAN-P-07`（行为包络消费方）、`PLAN-T-08`（数值对齐已通过）、`PLAN-M-04`（面板入口）、**`API-04 §7` 已冻结 `startSamplePlayback`**、**ADR-02（`skipAudioRecord`）与 ADR-01（注入路径须产出包络）已裁定** |
| 预估工时 | **6 h**（B 4 h ｜ C 1.5 h ｜ A 0.5 h） |

## 1. 交付物（Deliverables）
| # | 产物 | 说明 |
|---|---|---|
| 1 | `app/assets/demo_audio/*.wav` | 6 类 × 5 段 = **30 段**自采 wav，随 APK 打包 |
| 2 | `app/assets/demo_audio/manifest.json` | SPEC-M-02 §4.1 表结构的 30 行实例（单一真源） |
| 3 | `docs/demo/示例音频资产清单.md` | 人可读版清单表（类别 / 文件名 / 时长 / 采样率 / 设备 / 日期 / 备注） |
| 4 | `app/lib/features/demo/sample_injector.dart` | wav 解码 + 分片 + 实时节拍投喂（`feedRealtime=true`） |
| 5 | `app/lib/features/demo/demo_controller.dart` | `switchTo(sampleAudio)` / `startSamplePlayback({required String assetPath})` |
| 6 | `tool/verify_demo_audio.dart` | 资产完整性 + 清单一致性校验器（退出码判定） |
| 7 | `app/test/demo/injection_equivalence_test.dart` | B1 / B3 / B4 / B5 |
| 8 | `app/test/demo/demo_mode_b_test.dart` | B6 / B8 |
| 9 | `docs/demo/D9_三模式实测记录.md` | Mode B 段；含 SPEC §7 B13 记录表 |
| 10 | `docs/demo/evidence/D9_modeB_*.log` | 逐片 `injectPcm` 时间戳 + Top-1/置信度 |

> ⚠️ **本 PLAN 不产出任何实现代码文件中的音频数据**；30 段 wav 由 C 用真机自采（`SPEC-C-02` 的同意书范围），不得来源于公开数据集（来源必须可追溯，见 SPEC §4.1 的 `device` / `capturedOn`）。

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 自采 30 段示例音频（每类 5 段，模拟现场食用场景） | 交付物 1 | 1.5 h（C，D2 起分摊） | D2 |
| 2 | 生成并登记 `manifest.json` + 人可读清单 | 交付物 2、3 | 0.5 h（C） | 任务 1 |
| 3 | 写 `tool/verify_demo_audio.dart`（B7 / B9 判据） | 交付物 6 | 0.5 h（B） | 任务 2 |
| 4 | wav → PCM16 解码 + 分片（`injectChunkMs`） | 交付物 4 | 1.0 h（B） | 任务 2 |
| 5 | 实时节拍投喂（墙钟驱动，误差 ≤10%）与 `isLast` 收尾 | 交付物 4 | 1.0 h（B） | 任务 4 |
| 6 | `switchTo` / `startSamplePlayback` 与资产校验阻断（`ACD-DEMO-001`）；**`skipAudioRecord:true` + `includeEnvelope:true` 固定启动参数与包络自检** | 交付物 5 | 0.5 h（B） | 任务 2、`PLAN-M-04`；ADR-01/ADR-02 |
| 7 | UI「示例演示」标识（`source == inject`）接入 | SPEC §7 B6 | 0.25 h（B，挂在 `U-02`） | 任务 5 |
| 8 | 注入等价性测试与真机复现（B1，≥3 段） | 交付物 7、9、10 | 0.5 h（B） | 任务 5；`PLAN-T-08` 已通 |
| 9 | 现场核对表与口径复核（B12、FF-25） | 交付物 9 | 0.25 h（C） | 任务 7 |
| 10 | 等价性统计口径确认（标签一致 + 置信度差 ≤0.05 的取样方式） | SPEC §7 B1 定义 | 0.5 h（A） | 任务 8 |

## 3. 技术方案
> 与 `SPEC-M-02 §2.1/§3` 契约一致。**核心是「不许有第二条管线」**；骨架 ≤30 行。

```dart
Future<void> startSamplePlayback({required String assetPath}) async {
  final row = await _manifest.lookup(assetPath);        // ACD-DEMO-001 由 lookup 抛出
  _assertSpec(row);                                     // sampleRate==FF-01, ch==1, bits==16
  final pcm = await _wav.decodePcm16(assetPath);        // 仅内存，不落盘（FF-24 第 1 条）
  final id  = _newSessionId();
  await _native.startSession({'sessionId': id, 'enableDenoise': false,
    'autoEndOnSilence': false, 'silenceEndSeconds': FF21a.silenceEndSeconds,
    'skipAudioRecord': true,                            // ADR-02: 不开麦克风、不请求权限
    'includeEnvelope': true});                          // ADR-01: 注入必须产出 rmsEnvelope(819)
  _ui.showDemoBadge(true);                              // 不等第一个 patch
  final chunk = row.sampleRate * row.injectChunkMs ~/ 1000;
  for (var i = 0; i < pcm.length; i += chunk) {         // 墙钟节拍，与 FF-01 对齐
    final last = i + chunk >= pcm.length;
    await _native.injectPcm({'sessionId': id,
      'pcm16': pcm.sublist(i, min(i + chunk, pcm.length)).buffer.asUint8List(),
      'isLast': last, 'feedRealtime': true});           // 必须 true
    await _clock.tick(row.injectChunkMs);               // 实时节奏，误差 ≤ ±10%
  }
  // 之后完全复用 Mode A 的事件消费与聚合路径，无任何 inject 专属分支
}
```

**关键实现约定**
1. `_assertSpec` 失败**必须**在 `startSession` 之前抛出 `ACD-DEMO-001`，**不做重采样**。
2. `feedRealtime` 参数为常量 `true`，不接受外部传入。
3. 推理层与聚合层**不得**出现任何 `source` 相关的分支；`source` 只影响 UI 标识。
4. `injectionQueueDepth > 0` 时不得丢样本，只降低投喂速率。
5. 资产校验通过 `tool/verify_demo_audio.dart` 作为 CI 前置（B7/B9）。
6. `skipAudioRecord` 与 `includeEnvelope` 在本路径中是**常量 `true`**（ADR-02 / ADR-01），不接受外部传入；`startSession` 出参须断言 `audioRecordActive == false` 且 `envelopeLength == 819`。切换进 Mode B 前**必须** `await stopSession` 完成（`API-01 §4` 单会话约束）。
7. 启动时先调 `getEnvelopeCapability()` 断言 `supported == true`，与 `startSession` 出参的 `envelopeLength` 一致后**才**开始投喂（`API-01 §5` 第 12 项）——避免「跑起来才发现没有行为指标」。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `injection_equivalence_test.dart --plain-name "mic vs inject top1 parity"` | 集成 | Top-1 一致且 `\|Δconfidence\| ≤ 0.05` | 每次提交 + D9 |
| `--plain-name "single aggregation path"` | 单元 | 两条路径共用同一聚合器类型与配置 | 每次提交 |
| `--plain-name "inject always realtime"` | 单元 | 所有 `injectPcm` 载荷 `feedRealtime == true` | 每次提交 |
| `--plain-name "inject session needs no mic"`（B14） | 集成（mock） | 麦克风被占用时 `startSession({skipAudioRecord:true})` 仍成功；`audioRecordActive == false`、`micInUseKnown == false`、未请求权限 | 每次提交 |
| `--plain-name "inject emits envelope"`（B15） | 集成（mock） | 连续 20 个注入 `patch` 均含 `rmsEnvelope` 且长度 819、`envelopeHopMs == 5` | 每次提交 |
| `--plain-name "inject pacing within 10 percent"` | 单元 | 投喂总时长相对误差 ≤ 10% | 每次提交 |
| `demo_mode_b_test.dart --plain-name "inject source shows demo badge"` | Widget | 标识与 `source` 一一对应 | 每次提交 |
| `--plain-name "missing asset raises ACD-DEMO-001"` | 单元 | 错误码正确且未调 `startSession` | 每次提交 |
| `dart run tool/verify_demo_audio.dart --strict` | 脚本 | 30 段齐全、规格相符、清单差 ≤ 0.02 s | 每次提交 + D9 前 |
| 播放通路禁用扫描（B2） | 静态 | `AudioTrack/MediaPlayer/playSound` 命中 0 | D9 前 |
| 文案红线扫描（B10） | 静态 | 命中数 0 | D9 前 |
| `aapt dump badging`（B11） | 产物 | 无 `INTERNET` | D9 出包后 |
| 真机 6 轮实测（B12 / B13） | 人工核对表 + 记录表 | 勾选齐全；等价性 ≥3 段复现 | **D9 上午** |

## 5. 完成定义（DoD）
- [ ] `SPEC-M-02 §7` 的 **B1–B11、B14、B15 全部判据通过**（脚本退出码 0 / 测试全绿）。
- [ ] **B1 注入等价性在 ≥3 段示例上真机复现**，结果写入 `docs/demo/D9_三模式实测记录.md`（标注「D9 实测产出」）。
- [ ] `manifest.json` 30 行无空必填列；`docs/demo/示例音频资产清单.md` 可与之一一对照。
- [ ] 静态扫描证明**不存在播放通路**（B2）与**不存在 inject 专属推理/聚合分支**（B3）。
- [ ] B12 现场核对表 **8 项** 100% 勾选并签字；B13 记录表 ≥6 轮无空列。
- [ ] **`SPEC-M-02 §10` 开放问题 1、2 已按 ADR-02 / ADR-01 关闭并回写本 SPEC**：Mode B 固定 `skipAudioRecord:true`（B14 通过）；注入路径固定 `includeEnvelope:true` 且包络长度 819（B15 通过）；演示记录写入 `DietRecord.source="demo"` 且与 Track 1 互不混算。
- [ ] 代码合入 D9 节点分支；D10 冻结后不提交（`PLAN-00 §4`）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 资产自采不到位（<30 段） | 任务 1 在 D8 未收齐 | 允许 ≥18 段（每类 ≥3 段）先行演示，但 `manifest` 必须如实标注不完整；**不得用公开数据集冒充自采** |
| 麦克风被占用 / 硬件故障时 Mode B 起不来 | `startSession` 返回 `ACD-AUD-002`/`ACD-AUD-001` **且载荷未带 `skipAudioRecord:true`** | 立即修 `startSamplePlayback` 的启动参数（ADR-02 已裁定，不是环境问题）；修正前按 `SPEC-M-02 §6` 现场处置表切 Mode C（`SPEC-M-03`） |
| 等价性验收不过（`\|Δconfidence\| > 0.05`） | B1 失败 | 优先查 `feedRealtime` 是否被误设为 `false`、`injectChunkMs` 是否过大导致状态断裂；仍不过则按 `PLAN-T-08` 回查 Mel 对齐，**不得调低阈值** |
| APK 体积超预期 | `flutter build apk` 体积报告 | 降低单段时长（保持每类 5 段与规格不变），走 `PLAN-C-04` 记录 |
| 现场资产文件损坏 | B7 校验失败 | 备用手机上有同一套资产的副本；现场用 `dart run tool/verify_demo_audio.dart` 先验 |
| 观察者识破「放录音」 | 评委质疑 | 主动说明是**注入缓冲、与实时同管线**（`SPEC-M-02 §2.1`），并现场展示 `source` 标识与 `injectPcm` 日志 |

## 7. 与检查点的关系
> **本功能是 CP3 的组成部分。**

| 项 | 内容 |
|---|---|
| 涉及检查点 | **CP3（D9 午）**：判据「三种 Demo 模式全部可用」 |
| 本功能的 CP3 判据 | 6 类示例段可在真机上一键演示，识别链路与 Mode A 完全一致（B1/B3/B4/B5 通过），UI 正确显示「示例演示」标识 |
| CP3 未过时的处置 | `PLAN-00 §2`：停止一切新功能，3 人扑 Demo 稳定性；主方案 §8.2.4 规定 **Mode B + Mode C 必须可用**——**本功能是 CP3 失败时唯一不允许再退让的防线之一** |
| 与其他 PLAN 的耦合 | 依赖 `PLAN-P-04`/`PLAN-T-08`（数值对齐是全项目硬闸门）；与 `PLAN-M-01` 共用事件消费与聚合代码路径；入口由 `PLAN-M-04` 面板承载 |
| 前置阻塞 | ✅ 已解除：`SPEC-M-02 §10 开放问题 1` 已按 **ADR-02** 裁定为「`startSession` 新增 `skipAudioRecord`」（不新增注入专用会话，`API-01` 已冻结），本 PLAN 无需顺延；`API-01` 的 `skipAudioRecord` 若未按期实现，则本 PLAN 的第 6 项任务阻塞，须在 D8 前闭环 |

**文档结束**

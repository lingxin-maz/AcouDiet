# API-01 原生桥接：MethodChannel / EventChannel

**层间**：L1 原生采集层（Kotlin）↔ L4 域层（Dart）
**上游**：`API-00` §3、`SPEC-00` §3.1/§3.4/§3.9
**实现计划**：`PLAN-P-01`（采集）、`PLAN-P-02`（VAD）、`PLAN-P-03`（预处理）、`PLAN-P-04`（Mel 前端）、`PLAN-M-02`（缓冲注入）

---

## 1. 频道定义

| 频道 | 类型 | 方向 | 用途 |
|---|---|---|---|
| `com.acoudiet.app/audio` | `MethodChannel` | Dart → Kotlin（请求/响应） | 会话控制、能力握手、诊断、清理 |
| `com.acoudiet.app/audio_stream` | `EventChannel` | Kotlin → Dart（单向流） | 电平事件 + Mel patch 事件 + 会话结束事件 |

**约定**：
- 所有方法名 `lowerCamelCase`。
- 所有入参用**单个命名参数 `Map<String, Object?>`**，不用位置参数（便于向后兼容地加字段）。
- 所有返回值用 `Map<String, Object?>`，**禁止返回裸标量或裸数组**（无法扩展）。
- 失败一律 `result.error(code, message, detail)`，`code` 取自 `API-00` §3.5 的错误码表。

---

## 2. 方法契约（MethodChannel `com.acoudiet.app/audio`）

### 2.1 `getCapabilities`

```
入参 : {}
出参 : NativeCapabilities
错误 : 无（此方法必须永不失败）
```

```json
{
  "melVersion": "1.1.0",
  "sampleRate": 16000,
  "channels": 1,
  "bitDepth": 16,
  "nFft": 1024,
  "hopLength": 512,
  "nMels": 128,
  "rawMelFrames": 129,
  "nFrames": 128,
  "fmin": 20.0,
  "fmax": 8000.0,
  "preemphasis": 0.97,
  "preemphasisBoundary": "continuous_stream_previous_raw_sample_or_zero_at_source_start",
  "powerToDbRef": "patch_max",
  "topDb": 80.0,
  "normalization": "per_patch_minmax",
  "patchSamples": 65536,
  "patchSeconds": 4.096,
  "levelEventHz": 10,
  "patchEventHz": 2,
  "maxConcurrentSessions": 1,
  "denoiseAvailable": true,
  "injectionSupported": true,
  "ndkAbis": ["arm64-v8a", "armeabi-v7a", "x86_64"]
}
```

> **其中参与启动握手的是 15 个字段**（`ADR-21`（2026-09-12）由 12 字段扩至 15 字段，逐字与顺序见 `API-00` §3.6）：`melVersion` · `sampleRate` · `nFft` · `hopLength` · `nMels` · `rawMelFrames` · `nFrames` · `fmin` · `fmax` · `preemphasis` · `preemphasisBoundary` · `powerToDbRef` · `topDb` · `normalization` · `patchSamples`。其余字段（`channels` / `bitDepth` / `patchSeconds` / 事件频率 / ABI 等）是能力描述，**不参与逐字段比对**。~~`dbClipMin` / `dbClipMax`~~ 已随 `ADR-21` 出列（`db_clip_range` 键已删除）。

**用途**：`API-00` §3.6 的启动握手。Dart 侧读 assets 中的 `feature_config.json`，与本返回值逐字段比对，不符即抛 `ACD-CFG-001` 并**禁止进入检测页**。
**`melVersion` 语义**：Kotlin `MelFrontend` 的实现版本号，**当且仅当 Mel 数值行为发生变化时递增**（例如改了窗函数边界处理、dB 截断方式）。它是握手的主开关。

### 2.2 `requestPermission`

```
入参 : {}
出参 : { "granted": true, "permanentlyDenied": false }
错误 : 无（拒绝是正常返回值，不是错误）
```

- 原生侧用 `ActivityCompat.requestPermissions` 请求 `RECORD_AUDIO`。
- `granted=false && permanentlyDenied=true` → Dart 侧展示「去设置」按钮（`ACD-PERM-002` 的触发场景）。

### 2.3 `startSession`

```
入参 : {
  "sessionId": "S-1757462400000-a3f1",
  "enableDenoise": false,
  "autoEndOnSilence": true,
  "silenceEndSeconds": 90,
  "includeEnvelope": true,
  "skipAudioRecord": false
}
出参 : {
  "sessionId": "S-1757462400000-a3f1",
  "startedAtMs": 1757462400000,
  "appliedConfig": { /* NativeCapabilities 的子集 */ },
  "denoiseEnabled": false,
  "envelopeHopMs": 5,
  "envelopeLength": 819,
  "audioRecordActive": true
}
错误 : ACD-PERM-001 / ACD-PERM-002 / ACD-SESS-002 / ACD-AUD-001 / ACD-AUD-002
```

**约束**：
- `sessionId` 由 Dart 生成（规则见 `API-00` §3.4），原生**不得自行生成**，以保证日志可对齐。
- `enableDenoise` 默认 `false`：谱减法只作实验开关（主方案 §3.7）。
- `autoEndOnSilence=true` 时，原生侧按 FF-21a 的 90 s 静音判据自动结束并发 `sessionEnded`。
- 若已有活跃会话 → `ACD-SESS-002`（`maxConcurrentSessions = 1`），**不做隐式替换**，由 Dart 侧先 `stopSession`。

**`includeEnvelope`（默认 `true`）—— 行为分析的数据源，架构裁定见 §7**：
- `true` 时，每个 `patch` 事件附带 `rmsEnvelope`（见 §3.2）。
- 关闭后 `patch` 事件不含该字段，`P-07` 将收到 `ACD-BEH-001`。**只有明确不需要行为指标的诊断/压测场景才允许关闭。**

**`skipAudioRecord`（默认 `false`）—— 修掉 Mode B 的保命漏洞**：
> ⚠️ **这是一个真实的设计缺陷修补（`SPEC-M-02` 与 `SPEC-M-04` 交叉评审发现）**：
> 若不提供该参数，`startSession` 必然初始化 `AudioRecord`；麦克风**被其他 App 占用或硬件故障**时返回 `ACD-AUD-002`/`ACD-AUD-001`，于是 —— **恰恰在设备出问题时，作为保命方案的 Mode B（示例音频回放）也起不来**。而 Mode B 存在的全部意义就是"现场出问题时还能演"。
>
> **`skipAudioRecord = true` 的语义**：不打开 `AudioRecord`，只创建环形缓冲与事件发射器，仅接受 `injectPcm` 喂入的数据。
> - 出参 `audioRecordActive = false`；`getDiagnostics().micInUse` 为 `null`（**不是 `false`** —— `false` 会被误读为"麦克风可用"）。**`SPEC-M-04` 的自检面板必须据此区分「麦克风不可用」与「未启用麦克风」两种情况。**
> - 该模式下**不得**请求 `RECORD_AUDIO` 权限，也不得因权限缺失而失败。
> - `pauseSession`/`resumeSession` 仍合法（暂停期间停止发 patch）。
> - 该模式**允许在已有活跃 mic 会话之外独立存在**（`maxConcurrentSessions` 对该模式不适用），因为它的用途是"替代当前会话"。切换由 Dart 侧 `DemoController` 负责：先 `stopSession`，再 `startSession({skipAudioRecord: true})`。
>
> **现场处置口径（写入 `SPEC-M-04`）**：
> | 故障类型 | 处置 |
> |---|---|
> | 环境噪声大（>65 dB） | 切 **Mode B**（麦克风仍可用） |
> | 麦克风被占用 / 硬件故障 / 权限被永久拒绝 | 切 **Mode B（`skipAudioRecord=true`）**；若仍失败则切 **Mode C** |
> | 模型加载失败（`ACD-INF-001`） | 直接切 **Mode C**（Model B 同样依赖推理引擎） |

### 2.4 `pauseSession` / `resumeSession`

```
pauseSession 入参 : { "sessionId": String }
pauseSession 出参 : { "pausedAtMs": int, "state": "PAUSED" }
resumeSession 入参 : { "sessionId": String }
resumeSession 出参 : { "resumedAtMs": int, "state": "RUNNING" }
错误 : ACD-SESS-001（会话不存在）/ ACD-SESS-002（状态非法）
```

**暂停期间的行为（明确写清，避免歧义）**：
- `AudioRecord` **保持录制**（避免反复初始化带来的爆音与延迟），但**不产生 patch 事件**。
- 环形缓冲**继续写入**（保持 Mel 上下文连续），恢复后第一个 patch 是完整的 4.096 s 窗口。
- 暂停时长**不计入**进食时长统计；恢复时以新的「首次进食」重新计时。

### 2.5 `stopSession`

```
入参 : { "sessionId": String }
出参 : SessionSummary
错误 : ACD-SESS-001
```

```json
{
  "sessionId": "S-1757462400000-a3f1",
  "startedAtMs": 1757462400000,
  "stoppedAtMs": 1757462463000,
  "durationMs": 63000,
  "patchesEmitted": 126,
  "patchesVoiced": 118,
  "droppedPatches": 0,
  "firstVoicedAtMs": 1757462405000,
  "lastVoicedAtMs": 1757462451000,
  "endReason": "userStop",
  "rmsStats": { "mean": 0.042, "p95": 0.121, "peak": 0.238 }
}
```

**用途**：`P-07` 行为分析所需的会话级原始量；也是 `M-04` 现场自检的数据来源。
**`endReason` 枚举**：`userStop` / `silence90s` / `error`。

### 2.6 `injectPcm`（Demo Mode B 的唯一实现方式）

```
入参 : {
  "sessionId": String,
  "pcm16": Uint8List,          // 小端 PCM16，单声道，16 kHz
  "isLast": false,
  "feedRealtime": true          // true 时按 16 kHz 实时节奏喂入
}
出参 : { "acceptedSamples": 16000, "bufferedSamples": 42112 }
错误 : ACD-SESS-001 / ACD-DEMO-001
```
**硬性设计约束（主方案 §9 Mode B）**：
> ❌ **禁止**用「播放音箱 → 麦克风收回」的方式做示例演示 —— 那是二次采集，会引入房间响应与噪声，演示效果不可控，且会被评委看出是"放录音"。
> ✅ **必须**直接把示例 wav 解码成 PCM16 后**注入环形缓冲**，走**完全同一条** Mel → 推理 → 聚合管线。

**`feedRealtime=true` 的必要性**：注入若瞬间完成，patch 事件会在毫秒级全部涌出，UI 动画与 4–5 s 确认机制（FF-20a）都会失真。按实时节奏喂入才能复现真实观感。
**`isLast=true`** 时原生在缓冲排空后发 `sessionEnded(reason="userStop")`。

**注入会话的数据归属（`SPEC-M-02` / `SPEC-A-04` 交叉评审结论，必须遵守）**：
- 注入会话产生的 patch 事件 `source = "inject"`（见 §3.2），UI 必须显示「示例演示」标识。
- **是否写数据库由 Dart 侧决定，不由原生决定**：`DemoController.startSamplePlayback()` 默认**写入**记录并置 `DietRecord.source = "demo"`（这样演示后报告页立刻有数据可看），但必须在 `SPEC-A-04` 的 `demo_dataset.json` 之外单独标记，**不得混入 Track 1 的真实累积数据**。
- `SPEC-A-04` 的「加载演示数据集」与「Mode B 注入」是两条不同的入口，二者产出的记录都标 `source="demo"`，可用同一个「清除演示数据」动作回收。
- 🔴 **原生侧只负责缓冲注入与事件发射，不得自行写库**（`API-00` §1 分层规则 3）。

### 2.7 `clearTempAudio`

```
入参 : {}
出参 : { "filesDeleted": 3, "bytesFreed": 245760, "failed": 0 }
错误 : 无（清理失败只记日志，见 ACD-IO-001 的 retryable=false 语义）
```

**调用时机（FF-24 第 2 条）**：App 冷启动时一次 + **每次 `stopSession` 之后一次**。
**验收**：`PLAN-D-05` 与 `PLAN-C-01` 的测试断言「会话结束后 `cacheDir` 中匹配 `audio_*` 的文件数为 0」。

### 2.8 `getDiagnostics`

```
入参 : {}
出参 : {
  "micAvailable": true,
  "micInUse": false,
  "micInUseKnown": true,          // false 表示「本次会话未启用麦克风」（skipAudioRecord=true），此时 micInUse 无意义
  "recordAudioPermission": "granted",
  "activeSessionId": "S-…" | null,
  "sessionState": "RUNNING",
  "audioRecordActive": true,
  "bufferedSamples": 65536,
  "patchesEmitted": 126,
  "droppedPatches": 0,
  "envelopeHopMs": 5,
  "envelopeLength": 819,
  "injectionQueueDepth": 0,
  "tempAudioFiles": 0,
  "lastError": null,
  "nativeMelVersion": "1.1.0",
  "modelVersion": null,
  "modelNFrames": null
}
错误 : 无
```

**用途**：`M-04` 现场自检面板的数据源。**必须在 D9 前可用**，因为现场唯一的救命手段就是快速判断「是麦克风问题还是模型问题」。

**字段归属的两点说明（`SPEC-M-04` 交叉评审结论）**：

| 字段 | 为什么在这里 | 为什么可能是 `null` |
|---|---|---|
| `micInUse` / `micInUseKnown` | `M-04` 第 1 项自检「麦克风可用性与是否被占用」必须能区分**不可用**与**未启用**。没有 `micInUseKnown` 时，`micInUse=false` 会被误读为"麦克风正常" | `skipAudioRecord=true` 时 `micInUseKnown=false` |
| `modelVersion` / `modelNFrames` | `M-04` 第 3 项自检要求回显**当前生效的模型版本与 `n_frames`**。这两个值在原生侧可从编译期固化的常量给出 | **原生侧不加载模型**（推理在 Dart，`API-00` §1），因此默认 `null`；由 Dart 侧在 `InferenceEngine.load()` 成功后**回填**（`setDiagnosticsModelInfo({version, nFrames})`），或由 `DemoController.runSelfCheck()` 并行读取 `InferenceEngine` 与 `getCapabilities()` 后自行合并 |

> ⚠️ **不要为了填满这两个字段而让原生去加载模型** —— 那会把推理分裂成两份（见 §6「明确不做」）。`SPEC-M-04` 的自检面板必须接受这两项来自 Dart 侧的事实。

**附加方法：`setDiagnosticsModelInfo`**

```
入参 : { "version": "1.1.0", "nFrames": 128 }   // nFrames 取握手实际值，禁止硬编码
出参 : { "ok": true }
错误 : 无
```

调用时机：`InferenceEngine.load()` 成功后一次。用途：让 `getDiagnostics()` 能一致地回显模型信息，使自检面板只需一个数据源。

**附加方法：`getEnvelopeCapability`**

```
入参 : {}
出参 : { "supported": true, "envelopeHopMs": 5, "envelopeLength": 819 }
错误 : 无
```

用途：`SPEC-M-04` 与 `SPEC-P-07` 在启动时断言包络通道可用，避免"跑起来才发现拿不到行为指标"。

---

## 3. 事件契约（EventChannel `com.acoudiet.app/audio_stream`）

### 3.1 订阅方式

```dart
final stream = const EventChannel('com.acoudiet.app/audio_stream')
    .receiveBroadcastStream({'sessionId': sessionId});
```

- 参数 `Map` 经 `onListen(Object? arguments)` 传给原生侧；原生据此过滤会话。
- **取消订阅（`onCancel`）时必须停止发送事件并释放引用**，不得泄漏。
- 同一时刻只允许一个活跃订阅（`maxConcurrentSessions = 1`）。

### 3.2 事件类型

所有事件都是 `Map<String, Object?>`，公共字段：`type`、`sessionId`、`tMs`。

#### `type = "level"`（10 Hz，仅用于波形动画）

```json
{ "type": "level", "sessionId": "S-…", "tMs": 1757462405100,
  "rms": 0.031, "peak": 0.089, "voiced": true }
```

- `rms` / `peak` 均为线性幅度 `[0,1]`，**不参与任何业务判定**（`API-00` §3.3）。
- 载荷 < 100 B，不设缓冲，直接投递。

#### `type = "patch"`（2 Hz，核心事件）

```json
{ "type": "patch", "sessionId": "S-…", "seq": 42,
  "tStartMs": 1757462419000, "tEndMs": 1757462423096,
  "melVersion": "1.1.0",
  "nMels": 128, "nFrames": 128,
  "mel": Float32List(16384),
  "rmsEnvelope": Float32List(819),
  "envelopeHopMs": 5,
  "rms": 0.038, "voiced": true,
  "source": "mic" }
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `seq` | `int` | 自 0 开始单调递增，**不跳号、不重复**（会话内）。用于 `P-06` 的连续判据计数 |
| `tStartMs` / `tEndMs` | `int` | 该 patch 覆盖的墙钟时间区间（`tEndMs − tStartMs ≈ 4096`） |
| `mel` | `Float32List` | **长度 `nMels × nFrames`，行主序，`mel[m * nFrames + t]`** |
| `rmsEnvelope` | `Float32List` | **`P-07` 行为分析的数据源**。短时 RMS 包络，帧长 10 ms / hop 5 ms（FF-21h）；长度 `floor(patchSamples × 1000 / (sampleRate × envelopeHopMs))` = **819**。仅当 `startSession.includeEnvelope = true` 时存在 |
| `envelopeHopMs` | `int` | 包络帧移，当前冻结为 **5**；随事件下发以便 Dart 侧算法不硬编码 |
| `voiced` | `bool` | 本 patch 是否通过 VAD（`P-02`）；`false` 的 patch **仍要投递**并进入 EMA（否则平滑会断档） |
| `source` | `"mic"` \| `"inject"` | 数据来源；UI 在 `inject` 时须显示「示例演示」标识 |

> 🔴 **`rmsEnvelope` 是本版新增字段，用于修补一个真实的设计漏洞。** 背景：`P-07` 的算法（`librosa` 风格的 RMS 包络 → 平滑 → 峰值检测）需要**时域信息**，而原 `patch` 事件只带 `mel`/`rms`/`voiced` —— 于是 `P-07` 根本没有数据源，D7 的硬验收「能输出约 45 次，偏快」无法达成。完整裁定与权衡见 **§7**。
> **`rms` 与 `rmsEnvelope` 的区别（不要混用）**：`rms` 是**整个 patch 的单一标量**，仅供 UI 波形动画；`rmsEnvelope` 是**逐帧序列**，供行为分析。**行为分析不得读取 `rms`** —— 单个标量无法分辨 200 ms 的咀嚼峰间距（FF-21b）。

**`mel` 的传输方式（重要）**：
> 用 **`Float32List`（Flutter `StandardMessageCodec` 原生支持的类型）直接传输**，**不要**用 `List<double>`，也**不要** Base64 字符串。
> 理由：`List<double>` 会被逐元素装箱，16512 个元素的开销远超载荷本身；Base64 增加 33% 体积且需要双侧编解码。
> 参考开销：`128 × 128 × 4 B = 65 536 B/事件`（载荷是**丢弃尾帧后**的 128 帧；旧的 ~~`128 × 129 × 4 B = 66 048 B`~~ 属 `ADR-21` 之前的口径），2 事件/秒 → **约 128 KB/s**，在平台通道上完全可接受。

**布局的强制要求**：`mel` 必须能被 Python 侧 `np.frombuffer(buf, '<f4').reshape(nMels, nFrames)` 直接还原，且与训练侧 `librosa.feature.melspectrogram` 的输出**逐元素对齐**（验收见 `PLAN-T-08`）。这是全项目数值风险最高的单点。

#### `type = "sessionEnded"`

```json
{ "type": "sessionEnded", "sessionId": "S-…", "tMs": 1757462463000,
  "reason": "userStop", "code": null, "summary": { /* SessionSummary */ } }
```

- `reason` 枚举：`userStop` / `silence90s` / `error`。
- `reason = "error"` 时 `code` 为 `API-00` §3.5 的错误码。
- **收到此事件后原生侧停止发送任何该会话的事件**；Dart 侧据此收尾（提交数据库事务、清理临时文件）。

### 3.3 背压规则（`API-00` §3.8 的落地）

```
原生发送 patch 前：
  if (上一个 patch 尚未被 Dart 确认消费) {
      droppedPatches++
      丢弃该 patch          // drop-oldest，永不阻塞原生线程
  }
```

- Dart 侧在**推理完成后**通过 `MethodChannel.ackPatch({sessionId, seq})` 确认消费。
- `droppedPatches` 出现在 `SessionSummary` 与 `getDiagnostics()` 中；`M-04` 自检面板须展示该值。
- **判据**：正常真机环境下 `droppedPatches / patchesEmitted ≤ 0.05`；超出说明推理过慢，触发 `PLAN-P-05` 的延迟降级（提高推理步长到 1.0 s）。

### 3.4 附加方法：`ackPatch`

```
入参 : { "sessionId": String, "seq": int }
出参 : { "ok": true }
错误 : 无
```

---

## 4. 会话状态机（L1 侧权威定义）

```
                    ┌──────────────────────────────┐
                    ▼                              │
  IDLE ──startSession──▶ STARTING ──成功──▶ RUNNING ⇄ PAUSED
   ▲                        │                 │        │
   │                        │ 失败             │        │
   │                        ▼                 │        │
   │                     ERROR ───────────────┘        │
   │                        │                          │
   └──── stopSession / sessionEnded / 错误恢复 ◀────────┘
```

| 迁移 | 触发 | 允许？ | 非法时错误码 |
|---|---|---|---|
| IDLE → STARTING | `startSession` | ✅ | — |
| STARTING → RUNNING | `AudioRecord` 启动成功 | ✅ | — |
| STARTING → ERROR | 启动失败 | ✅ | `ACD-AUD-001` / `ACD-AUD-002` |
| RUNNING → PAUSED | `pauseSession` | ✅ | — |
| PAUSED → RUNNING | `resumeSession` | ✅ | — |
| RUNNING/PAUSED → IDLE | `stopSession` | ✅ | — |
| RUNNING → IDLE | 90 s 静音自动结束 | ✅ | — |
| IDLE → RUNNING | 直接 `resumeSession` | ❌ | `ACD-SESS-002` |
| PAUSED → PAUSED | 重复 `pauseSession` | ❌ | `ACD-SESS-002` |
| 任意 → IDLE 后调 `pauseSession` | 会话已结束 | ❌ | `ACD-SESS-001` |

---

## 5. 一致性测试清单（写入 `PLAN-P-01` / `PLAN-P-04` 的 §4）

| # | 测试 | 断言 |
|---|---|---|
| 1 | 握手一致 | `getCapabilities()` 的 **15 个字段**（`ADR-21`；原 ~~12 个~~）与 `feature_config.json` 全等；构造不一致场景必须抛 `ACD-CFG-001` |
| 2 | 会话生命周期 | IDLE→RUNNING→PAUSED→RUNNING→IDLE 全通；表 §4 的 3 个非法迁移均返回对应错误码 |
| 3 | patch 载荷形状 | 连续 20 个 patch 事件的 `mel.length == 128 × 128`（`nMels × nFrames`，`ADR-21`）且 `seq` 严格递增无跳号 |
| 4 | Mel 数值对齐 | 同一 wav：Python 出 `mel.npy`、Kotlin 出 `mel.bin`，`np.allclose(a, b, atol=1e-3)` 为真（`PLAN-T-08`） |
| 5 | 注入等价性 | 同一 wav 分别走 mic 录制与 `injectPcm`，Top-1 标签与置信度差 ≤ 0.05（`PLAN-M-02`） |
| 6 | 临时文件清理 | `startSession` → `stopSession` 后 `cacheDir` 中 `audio_*` 文件数 == 0（`PLAN-D-05`） |
| 7 | 背压 | 人为把推理延迟调到 2 s，`droppedPatches > 0` 且原生线程未阻塞、`sessionEnded` 正常（`PLAN-P-05`） |
| 8 | 无网络 | 运行全流程后抓包为 0，且 `aapt dump badging` 中无 `INTERNET`（`PLAN-C-01`） |
| 9 | 包络形状 | `includeEnvelope=true` 时连续 20 个 patch 的 `rmsEnvelope.length == 819` 且 `envelopeHopMs == 5`；`includeEnvelope=false` 时字段不存在且 `P-07` 抛 `ACD-BEH-001` |
| 10 | 注入会话无麦克风 | `startSession({skipAudioRecord: true})` 在**麦克风被占用**的设备上仍成功；`getDiagnostics().micInUseKnown == false`；不触发权限请求 |
| 11 | 诊断模型信息 | `setDiagnosticsModelInfo` 后 `getDiagnostics().modelVersion / modelNFrames` 回显成功；回显值取自握手实际值（**`nFrames = 128`**；`ADR-21` 前为 ~~129~~），**不得硬编码** |
| 12 | 包络可用性 | `getEnvelopeCapability().supported == true` 且长度与 `startSession` 出参的 `envelopeLength` 一致 |

---

## 6. 明确不做（防止实现方扩展）

| 不做 | 理由 |
|---|---|
| 双向流（`EventChannel` 反向下发） | 控制面用 `MethodChannel` 已足够，双通道会引入时序竞态 |
| 原生侧做推理 | Mel 在原生、推理在 Dart 是刻意分工（主方案 §3.3）；原生推理会让 `P-06` 的聚合状态分裂成两份 |
| 原生侧直接写数据库 | 违反 `API-00` §1 的分层规则；且 Android 侧 SQLite 与 `sqflite` 会产生两个数据源 |
| 音频落盘 / 上传 | **违反 FF-24，绝对禁止** |
| 多会话并发 | `maxConcurrentSessions = 1`；Demo 需要的是切换而不是并发 |
| **把原始 PCM 塞进 `patch` 事件** | 单事件 131 KB（PCM16）或 262 KB（float32），是包络方案的 **40–80 倍**；见 §7 |
| **原生侧做峰值检测 / 咀嚼计数** | 阈值（FF-21b/21c/21d）需要在 D7 现场快速调参；放在 Kotlin 意味着每次调参都要重新编译 APK。**DSP 下沉、判定留在 Dart** 是本契约的分工边界 |
| **原生侧加载模型来填 `modelVersion`** | 会把推理分裂成两份；`modelVersion` 由 Dart 回填（§2.8） |

---

## 7. 架构裁定：行为分析的包络为什么在原生侧算

**问题（`SPEC-P-07` 与 `API-01` 交叉评审发现）**：`P-07` 的算法需要**时域信息**（短时 RMS 包络 → 平滑 → 峰值检测），但本契约的 `patch` 事件原本只带 `mel` / `rms` / `voiced`，**不含任何逐帧时域量**。因此 `P-07` 没有数据源，`PLAN-00` D7 的硬验收无法达成。这是两个并行设计的文档之间的真实缺口，不是笔误。

**三个候选方案**

| 方案 | 数据量/秒 | 代价 | 判定 |
|---|---|---|---|
| A. `patch` 事件附带**原始 PCM16** | `131 KB × 2 = 262 KB/s`（在 mel 的 132 KB/s 之外） | 通道总带宽升至约 394 KB/s（约 3 倍）；Dart 侧需自行算包络 | ❌ 否决 |
| B. `patch` 事件附带**原生算好的 RMS 包络**（hop 5 ms） | `3.3 KB × 2 = 6.6 KB/s` | 需在 Kotlin 增加约 30 行 DSP | ✅ **采用** |
| C. 原生侧直接产出**咀嚼峰值候选** | `< 1 KB/s` | 阈值调参要重编译 APK（FF-21b/21c/21d 在 D7 现场必然要调） | ❌ 否决 |

**采纳 B 的四条理由**
1. **与项目自身已冻结的原则一致**：主方案 §3.3 的裁定是「在 Android 原生层完成采集 + 特征计算，只把算好的数组传给 Flutter」，并把这条原则称为最优解。包络是同一类 DSP，适用同一原则。
2. **几乎不增加带宽**：`819 × 4 B = 3.3 KB/事件`，相对 `mel` 的 66 KB 只有 5%。
3. **复用了既有计算**：`P-02` 的 VAD 本来就要算短时能量。包络与 VAD 共用同一遍分帧，增量成本接近于零。
4. **把需要现场调参的部分留在了 Dart**：峰值检测、动态阈值、伪峰过滤、速度评级全在 `P-07`（Dart），可热重载调参；只有「分帧 + RMS」这个确定性的、无参数的步骤下沉原生。

**代价与缓解**
| 代价 | 缓解 |
|---|---|
| Kotlin 侧多约 30 行，且必须与 `P-02` 的分帧参数严格一致 | `PLAN-P-02` 与 `PLAN-P-07` 共用同一个分帧实现；`SPEC-P-07` 的验收断言包络长度恒为 819 |
| Dart 侧拿不到原始波形，无法用其它包络口径复算 | 允许：`FF-21h` 只是**默认口径**；若 D7 实测 MAE 超 FF-21g 的降级线，可改包络参数（如 hop 10 ms），**但必须走 `API-00` §3.9 变更并重跑 `SPEC-P-07` 的验收** |
| `P-07` 无法独立于原生层做纯 Dart 单测 | 提供 `FakeEnvelopeSource`（用固定包络数组喂入），使峰值检测逻辑可在无设备时单测 —— 写入 `PLAN-P-07` §4 |

**同步要求**：本裁定已在 `SPEC-00` §3.6 登记为 `FF-21h` / `FF-21i`。`SPEC-P-02`（产出方）、`SPEC-P-07`（消费方）、`SPEC-M-02`（注入路径也必须产出包络）三处的接口签名须与本节一致。

---

**文档结束**

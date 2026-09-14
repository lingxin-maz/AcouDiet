# SPEC-M-02 Demo Mode B · 示例音频回放

| 项 | 值 |
|---|---|
| 域 | M · 演示与现场保障 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §9「Mode B · 示例音频回放」、§8.2.1 第⑤项、§8.2.4；**`API-04 §7`（`startSamplePlayback` 权威定义，「解码失败 → `ACD-DEMO-001`」）与 `§7.1` 第 9 项（`sampleAudio` 自检项）**；`API-01 §2.6`（`injectPcm` 是 Mode B 的唯一实现方式）、`§3.2`（`source` 字段）、`§5` 一致性测试第 5 项；`SPEC-00 §3.1 FF-01/FF-09`、`§3.3 FF-19`、`§3.4 FF-20a/FF-20c`、`§3.9 FF-24`、`§3.10 FF-25` |
| 依赖的 SPEC | `SPEC-P-04`、`SPEC-P-05`、`SPEC-P-06`、`SPEC-U-02`、`SPEC-M-01`、`SPEC-M-04` |

## 1. 目标与范围

### 1.1 一句话目标
把内置自采示例 wav 解码为 PCM16 后经 `injectPcm` **直接注入环形缓冲**、按实时节奏喂入，与 Mode A **共用完全同一条** Mel → 推理 → 聚合路径，作为现场实时识别失败时的保命模式。

### 1.2 范围内（In Scope）
| # | 内容 |
|---|---|
| 1 | 示例音频资产的组织、清单（每类 5 段，共 30 段）与完整性校验 |
| 2 | wav → PCM16（16 kHz / 单声道，FF-01）解码与分片投喂 |
| 3 | `feedRealtime=true` 的实时节奏喂入与 `isLast=true` 收尾 |
| 4 | UI 在 `patch.source == "inject"` 时**必须**显示「示例演示」标识 |
| 5 | 资产缺失 / 损坏 / 规格不符 → `ACD-DEMO-001` 的完整失败处理 |
| 6 | 注入等价性验收：同一 wav 走 mic 录制与 `injectPcm`，Top-1 一致且置信度差 ≤ 0.05 |
| 7 | **注入路径必须产出行为包络**（ADR-01）：注入会话的 `patch` 事件同样携带 `rmsEnvelope`（长度 819，FF-21h），否则 Mode B 演示**没有任何行为指标** |

### 1.3 范围外（Out of Scope）——防止实现方自由发挥
| 不做 | 归属 / 理由 |
|---|---|
| 用系统播放器播放 wav | **本 SPEC §2.1 明令禁止**，见下 |
| 用扬声器播放再由麦克风收回（二次采集） | **本 SPEC §2.1 明令禁止** |
| Mel 计算、推理、聚合的任何改动 | `SPEC-P-04`~`SPEC-P-06`；Mode B **不得**有独立管线 |
| 音频播放器 UI、进度条拖拽、音效 | 不在 v1.0 范围 |
| 运行时下载示例音频 | 违反 FF-24 第 4 条（无网络） |
| 示例音频的后期制作（降噪 / 增益归一化后另存） | 违反「与 Mode A 同管线」的可比性前提 |
| 会话音频落盘（运行时 PCM 写文件） | 违反 FF-24 第 1 条 |

## 2. 功能行为

### 2.1 ⚠️ 核心设计约束（**本 SPEC 最重要的一节，实现前必须逐字读完**）

> **❌ 禁止**：用「播放音箱 → 麦克风收回来」的方式做示例演示。
> 理由（三条，缺一不可）：
> 1. 那是**二次采集**，会引入**房间响应与环境噪声**，演示效果完全不可控；
> 2. 现场环境噪声一旦升高（主方案 §9.2 的 >65 dB 场景正是 Mode B 的触发条件），二次采集**必然同时劣化**，保命方案自我否定；
> 3. 会被评委**看出是「放录音」**，直接击穿演示的可信度。
>
> **✅ 必须**：把示例 wav 解码为 PCM16 后，经 `API-01 §2.6` 的 `injectPcm` **直接注入环形缓冲**，与 Mode A **共用** Mel → 推理 → 聚合路径。
> **⚠️ 必须**实现 `feedRealtime=true`：注入若瞬间完成，patch 会在**毫秒级全部涌出**，波形动画与约 4–5 s 的确认机制（FF-20a）都会失真，观感与真实进食完全不同。按 16 kHz 实时节奏喂入才能复现真实观感。

**推论（实现方必须遵守的等价性要求）**：
| 要求 | 说明 |
|---|---|
| 单一管线 | `injectPcm` 之后的路径与 Mode A **逐行相同**；禁止为 Mode B 分支推理或分支聚合 |
| 单一节奏 | 注入节奏由墙钟驱动，与 FF-01 采样率一致，相对误差 ≤ ±10% |
| 单一标识 | 唯一差异是 `patch.source` 与 UI 标识，**不得影响数值** |

### 2.2 触发与前置条件
1. 入口二选一：①AI 检测页的「示例演示」按钮 ②`SPEC-M-04` 自检面板切到 `DemoMode.sampleAudio`。
2. `DemoController.switchTo(DemoMode.sampleAudio)` 成功。
3. 资产校验通过（§4 清单每行均存在且规格相符），否则 `ACD-DEMO-001`。
4. Mode B 的自检子集（自检项权威清单见 `API-04 §7.1`，**共 14 项**）：**不要求**第 2 项 `mic` 通过；**仍要求**第 1 项 `permission`、第 3 项 `model`、第 5 项 `featureConfig` 通过；第 9 项 `sampleAudio` 在当前模式下必须通过；**第 12 项 `envelope` 必须通过**（`getEnvelopeCapability().supported == true`），否则注入路径拿不到行为指标（§1.2 第 7 项）。
5. **启动参数固定**：`startSession({skipAudioRecord: true, includeEnvelope: true, …})`（`API-01 §2.3`）。
   > `skipAudioRecord` **必须为 `true`**（ADR-02）：不打开 `AudioRecord`、不请求 `RECORD_AUDIO`、也不得因权限缺失而失败，出参 `audioRecordActive == false`。这正是 Mode B 作为保命模式的前提——否则麦克风被占用或硬件故障时，Mode B 会在同一次故障中一起失效。
   > `includeEnvelope` **必须为 `true`**（ADR-01）：注入会话的 `patch` 事件必须带 `rmsEnvelope`（长度 819，FF-21h）。**禁止**为省带宽把它关掉——关掉后 `SPEC-P-07` 收到 `ACD-BEH-001`，Mode B 演示将**没有咀嚼次数与进食速度**，而这正是 Mode B 要展示的核心行为指标。

### 2.3 主流程（编号步骤）
1. `DemoController.startSamplePlayback({required String assetPath})`。
2. 读资产清单 → 定位 `assetPath` 行 → 校验：文件存在、wav 头合法（RIFF/WAVE/fmt/data）、`sampleRate == FF-01`、`channels == 1`、`bitsPerSample == 16`、实测时长与清单差值 ≤ 0.02 s。任一不符 → `ACD-DEMO-001`，**不进入会话**。
3. 若 `activeSessionId != null` → 先 `stopSession`。
4. 生成 `sessionId` → `startSession({enableDenoise:false, autoEndOnSilence:false, silenceEndSeconds:90, skipAudioRecord:true, includeEnvelope:true})`（`API-01 §2.3`）。
   > `autoEndOnSilence` 在 Mode B 下置 `false`：示例音频的段间静音**不得**触发 FF-21a 的 90 s 自动结束逻辑；结束由 `isLast=true` 驱动。
   > `skipAudioRecord:true` 使本次会话**不开麦克风**（ADR-02），`includeEnvelope:true` 使注入产生的每个 `patch` 都带 `rmsEnvelope`（ADR-01）。
5. 订阅 `audio_stream`；UI 立即显示「示例演示」标识（不等第一个 patch）。
6. 解码 wav 为 `Int16List`（小端）→ 按清单的 `injectChunkMs` 切片，墙钟节拍逐片调用 `injectPcm({sessionId, pcm16, isLast:false, feedRealtime:true})`。
7. 最后一片以 `isLast: true` 调用；原生在缓冲排空后发 `sessionEnded(reason="userStop")`（`API-01 §2.6`）。
8. 收到 `sessionEnded` → 收尾（`clearTempAudio()`；**是否写数据库由 Dart 侧决定，不由原生决定**——`DemoController.startSamplePlayback()` 默认写入并置 `DietRecord.source = "demo"`，**不得混入 Track 1 的真实累积数据**；原生侧只负责缓冲注入与事件发射，**不得自行写库**（`API-01 §2.6`）。
9. 全程 `patch.source == "inject"`；未确认预测与确认卡片的行为与 Mode A **完全一致**。

### 2.4 状态与状态迁移
```
IDLE ──switchTo(sampleAudio)──▶ ASSET_CHECK ──通过──▶ INJECTING ──isLast──▶ DRAINING ──sessionEnded──▶ IDLE
                                     │                                                  ▲
                                     └── 失败 ▶ BLOCKED（ACD-DEMO-001）                  │
INJECTING ──用户停止──▶ stopSession ───────────────────────────────────────────────────────┘
```
| 迁移 | 触发 | 允许 |
|---|---|---|
| IDLE → ASSET_CHECK | `switchTo(sampleAudio)` / `startSamplePlayback` | ✅ |
| ASSET_CHECK → INJECTING | 清单校验通过 | ✅ |
| ASSET_CHECK → BLOCKED | 文件缺失 / 头非法 / 采样率不符 | ✅ |
| INJECTING → DRAINING | `isLast=true` 已投递 | ✅ |
| INJECTING → INJECTING | 连续切换示例段（不重建会话） | ✅（仅在同一会话内换段） |
| BLOCKED → INJECTING | 未修复资产即重试 | ❌ 必须重跑清单校验 |
| INJECTING → Mode A 会话 | 未 `stopSession` 直接切 | ❌ 禁止双会话（`maxConcurrentSessions = 1`） |

### 2.5 边界条件
| 边界 | 行为 |
|---|---|
| 文件缺失 / wav 头非法或截断 / 采样率·声道·位深不符 / 清单时长差 > 0.02 s | 一律 `ACD-DEMO-001`；**不做运行时重采样、不静默跳过**；先修资产或清单再演示 |
| 示例段全为静音 | `voiced` 全 false，不产生确认结果；面板提示该段不可用 |
| 注入队列积压 | `getDiagnostics().injectionQueueDepth` 持续 > 0 时降低投喂速率至实时节奏，**不得丢弃样本** |
| 注入中途用户停止 | `stopSession` 立即收尾；`injectPcm` 收到 `ACD-SESS-001` 属正常 |
| 会话中切回 Mode A | 必须 `stopSession` → `switchTo(realtime)` |
| 现场无 30 段全量资产 | 允许 ≥1 个类别可用时演示，但**必须在面板标明资产不完整** |

## 3. 接口契约
> 完整签名以 `API-01` 为准；本节只列本功能用到的部分。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5→L4 | `DemoController.switchTo(DemoMode.sampleAudio)` | `DemoMode` | `Future<void>` | `ACD-DEMO-003`（会话运行中 / 前置未就绪，`API-04 §7.2`） |
| L5→L4 | `DemoController.startSamplePlayback({required String assetPath})` | 资产路径 | `Future<void>` | **`ACD-DEMO-001`**（`API-04 §7`） |
| L4→L1 | `getDiagnostics()`（`API-01 §2.8`） | `{}` | 含 `injectionQueueDepth` / `injectionSupported` | 无 |
| L4→L1 | `startSession`（`API-01 §2.3`） | `sessionId` / `enableDenoise` / `autoEndOnSilence=false` / **`skipAudioRecord: true`** / **`includeEnvelope: true`** | 会话头部（含 `audioRecordActive == false`、`envelopeLength == 819`） | `ACD-SESS-002`（`skipAudioRecord=true` 下**不请求权限、不因权限缺失失败**，故 `ACD-PERM-*` / `ACD-AUD-*` 不应出现） |
| L4→L1 | `getEnvelopeCapability()`（`API-01 §2.8`） | `{}` | `{supported, envelopeHopMs, envelopeLength}` | 无（启动时必须断言 `supported == true`） |
| L4→L1 | **`injectPcm`（`API-01 §2.6`）** | `sessionId` / `pcm16: Uint8List` / `isLast` / **`feedRealtime: true`** | `{acceptedSamples, bufferedSamples}` | `ACD-SESS-001`、**`ACD-DEMO-001`** |
| L4→L1 | `stopSession`（`API-01 §2.5`） | `sessionId` | `SessionSummary` | `ACD-SESS-001` |
| L4→L1 | `ackPatch`（`API-01 §3.4`） | `sessionId` / `seq` | `{ok:true}` | 无 |
| L4→L1 | `clearTempAudio()`（`API-01 §2.7`） | `{}` | 清理计数 | 无 |
| L1→L4 | 事件 `patch` | — | **`source == "inject"`**；**必须含 `rmsEnvelope`（长度 819）与 `envelopeHopMs == 5`** | — |
| L1→L4 | 事件 `sessionEnded` | — | `reason == "userStop"` | — |

## 4. 数据契约

### 4.1 示例音频资产清单（**表结构**，单一真源 `app/assets/demo_audio/manifest.json`）
| 列名 | 类型 | 单位 / 值域 | 必填 | 校验规则 |
|---|---|---|---|---|
| `category` | `String` | FF-19 的 6 类之一 | ✅ | 每类恰好 5 段，共 30 段 |
| `fileName` | `String` | `app/assets/demo_audio/<category>_<NN>.wav` | ✅ | 存在于 assets 且长度 > 44 B |
| `durationSeconds` | `double` | s | ✅ | 与解码实测时长差 ≤ 0.02 s |
| `sampleRate` | `int` | Hz | ✅ | **必须 == FF-01** |
| `channels` | `int` | — | ✅ | **必须 == 1**（FF-01） |
| `bitsPerSample` | `int` | — | ✅ | **必须 == 16** |
| `device` | `String` | — | ✅ | 采集设备型号（自采来源可追溯） |
| `capturedOn` | `String` | `yyyy-MM-dd` | ✅ | 采集日期 |
| `note` | `String` | — | ⬜ | 备注（环境、增益、是否含噪声） |
| `injectChunkMs` | `int` | ms | ✅ | ≤ 200，见 §5 |

**清单表（30 行实例）结构示例**（完整 30 行由 `PLAN-M-02` §1 产出）：

| 类别 | 文件名 | 时长(s) | 采样率(Hz) | 采集设备 | 采集日期 | 备注 |
|---|---|---|---|---|---|---|
| `chips` | `chips_01.wav` | 见表内实测值 | == FF-01 | 见清单 | 见清单 | 见表内实测值 |
| `chips` | `chips_02.wav` … `chips_05.wav` | 同上 | 同上 | 同上 | 同上 | 同上 |
| `cabbage` | `apple_01.wav` … `apple_05.wav` | 同上 | 同上 | 同上 | 同上 | 同上 |
| … `gummies` / `noodles` / `carrot` / `drink` 同构，各 5 段 | | | | | | |

> **禁止在本 SPEC 中写死时长 / 增益等实测值**：这些是 D2 自采产出（`PLAN-M-02` §1），写入 `manifest.json` 并随资产冻结。**任何填不出的格子视为资产未就绪。**

### 4.2 运行时字段
| 字段 | 类型 | 值域 | 说明 |
|---|---|---|---|
| `injectPcm.pcm16` | `Uint8List` | 小端 PCM16 单声道 16 kHz | 每片 `injectChunkMs` 对应的样本数 |
| `injectPcm.feedRealtime` | `bool` | 本功能**必须** `true` | `API-01 §2.6` |
| `patch.source` | `String` | `"inject"` | UI 「示例演示」标识的**唯一**触发依据 |
| `patch.rmsEnvelope` | `Float32List` | 长度 **819**（FF-21h） | **注入会话同样必须产出**（ADR-01）：`includeEnvelope` 必须为 `true`，否则该字段不存在，Mode B 演示没有行为指标 |
| `patch.envelopeHopMs` | `int` | 当前冻结为 **5**（FF-21h） | 随事件下发，Dart 侧算法**不得硬编码** |
| `getDiagnostics().injectionQueueDepth` | `int` | ≥ 0 | 投喂速率调节依据 |

## 5. 参数与常量
| 编号 | 本功能的用途 |
|---|---|
| FF-01 | 采样率；清单 `sampleRate` 与 `channels` 的校验基准 |
| FF-09 | patch 时长；确认结果时机的口径（**旧文档的短窗长口径已被 `SPEC-00 §3.10` 术语禁令废止，本 SPEC 不写出其字面值**） |
| FF-19 | 清单 `category` 的 6 类取值来源 |
| FF-20a | UI 上的确认结果时机口径（**只能写「约 4–5 s」**） |
| FF-20c | `feedRealtime=true` 的必要性依据：状态跨 patch 保持才有意义 |
| FF-21h | `rmsEnvelope` 的长度（819）与 hop（5 ms）真源；**注入会话必须同样产出**（ADR-01，本 SPEC §1.2 第 7 项） |
| FF-21i | 包络算在原生、峰值检测在 Dart 的分工边界——Mode B 与 Mode A 因此**共用同一份包络口径** |
| FF-24 | 第 1/2/4 条：运行时 PCM 不落盘、临时文件清理、无 `INTERNET` |
| FF-25 | 文案红线：不得写「2 秒内出结果」 |

**本功能自定义常量（唯一真源 = `manifest.json`，禁止在代码里散落字面值）**：`injectChunkMs`（≤ 200 ms）。若需支持现场可调，须走 `PLAN-C-03` 变更传播登记。

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 示例资产缺失 / wav 头非法或截断 / 采样率或声道或位深不符 / 清单时长不符 | 清单查无文件、RIFF·WAVE·fmt·data 头校验失败、头字段与 FF-01 不符 | 一律 `ACD-DEMO-001`；**中止启动，不进入会话，不做重采样** | 「示例音频缺失 / 损坏 / 规格不符：`<fileName>`」+ 面板定位 |
| 注入队列积压 | `injectionQueueDepth > 0` 持续 | 降低投喂速率至实时节奏 | 无感（不丢样本） |
| `injectPcm` 返回 `ACD-SESS-001` | 会话已结束仍投喂 | 停止投喂并收尾 | 无感 |
| 注入会话拿不到行为包络（ADR-01） | `getEnvelopeCapability().supported == false`，或 `patch.rmsEnvelope` 缺失 / 长度 ≠ 819 | **启动前即阻断**（自检第 12 项 `envelope` 失败）；不得带病演示——没有包络就没有咀嚼次数与进食速度 | 「行为指标将不可用」（`ACD-BEH-001`） |
| 资产只有部分类别可用 | 清单校验统计 | 允许演示可用类别 | 面板标注「资产不完整（n/30）」 |
| 运行时临时音频残留 | `tempAudioFiles > 0` | `clearTempAudio()` 重试一次 | 无感 |

**现场处置表（依据 ADR-02；与 `API-01 §2.3` 冻结口径逐字一致）**：

| 故障类型 | 处置 |
|---|---|
| 环境噪声大（>65 dB） | 切 **Mode B**（麦克风仍可用） |
| 麦克风被占用 / 硬件故障 / 权限被永久拒绝 | 切 **Mode B（`skipAudioRecord=true`）**；若仍失败则切 **Mode C** |
| 模型加载失败（`ACD-INF-001`） | 直接切 **Mode C**（Mode B 同样依赖推理引擎） |

> ⚠️ **第 1 行是本模式存在的理由，第 2 行是本模式的启动形态**：Mode B 的入口本身就带 `skipAudioRecord=true`，因此**麦克风被占用时 Mode B 仍可启动**（`API-01 §2.3` 一致性测试第 10 项）。若现场切到 Mode B 却报 `ACD-AUD-002`，说明 `skipAudioRecord` **未按 `true` 传入**，属实现缺陷而非环境问题。第 3 行说明 Mode B 的下限：模型不可用时它同样起不来，只能切 Mode C。

> **错误码**：本功能统一使用 `ACD-DEMO-001`（`API-00 §3.5`：示例音频缺失或损坏；与 `API-04 §7` 的「解码失败 → `ACD-DEMO-001`」一致）。`ACD-DEMO-002`（演示数据集）与 `ACD-DEMO-003`（模式切换非法）由 `API-04 §8` 定义，**其尾注要求先补登 `API-00 §3.5` 才生效**。本 SPEC 不新造错误码。

## 7. 验收标准（可机器判定）
> **本功能是 CP3 的组成部分。** CP3（D9 午）的判据是「三种 Demo 模式全部可用」，本功能是其中 Mode B（失败保命模式）的实测对象；主方案 §8.2.4 规定 **CP3 未过时 Mode B + Mode C 必须可用**——本功能不退让（详见 `PLAN-M-02 §7`）。

| # | 判据 | 验证方式（命令 / 测试名） | 通过阈值 |
|---|---|---|---|
| B1 | **注入等价性（核心）** | `flutter test test/demo/injection_equivalence_test.dart --plain-name "mic vs inject top1 parity"` | 同一 wav 分别走 mic 录制与 `injectPcm`：**Top-1 标签一致**，且 `|Δconfidence| ≤ 0.05`（`API-01 §5` 第 5 项） |
| B2 | 禁止二次采集 | `pwsh -Command "Select-String -Path app/lib/**/*.dart,app/android/**/*.kt -Pattern 'AudioTrack|MediaPlayer|playSound|SystemSound'"` | 命中数 **0**（实现层禁止播放通路） |
| B3 | 复用同一管线 | `flutter test test/demo/injection_equivalence_test.dart --plain-name "single aggregation path"` | Mode A 与 Mode B 的聚合器实例类型与配置全等；无 `if (mode == sampleAudio)` 分支于推理/聚合层 |
| B4 | `feedRealtime=true` 强制 | 同上 `--plain-name "inject always realtime"` | 所有 `injectPcm` 调用载荷的 `feedRealtime == true`（mock 断言） |
| B5 | 实时节奏正确 | 同上 `--plain-name "inject pacing within 10 percent"` | 投喂墙钟总时长与 `durationSeconds` 相对误差 ≤ 10% |
| B6 | UI 标识 | `flutter test test/demo/demo_mode_b_test.dart --plain-name "inject source shows demo badge"` | `source=="inject"` 时「示例演示」标识存在；`source=="mic"` 时不存在 |
| B7 | 资产完整性 | `dart run tool/verify_demo_audio.dart`（读 `manifest.json`） | 6 类 × 5 段 = 30 段全部存在，`sampleRate == FF-01`、`channels == 1`、`bitsPerSample == 16`，退出码 0 |
| B8 | 缺失资产 → `ACD-DEMO-001` | `flutter test test/demo/demo_mode_b_test.dart --plain-name "missing asset raises ACD-DEMO-001"` | 抛出的 `AcouDietError.code == "ACD-DEMO-001"`，且 `startSession` 调用次数 == 0 |
| B9 | 清单与素材一致 | `dart run tool/verify_demo_audio.dart --strict` | 每行 `durationSeconds` 与实测差 ≤ 0.02 s；`capturedOn` / `device` 无空值 |
| B10 | 文案红线零命中 | `pwsh -Command "Select-String -Path docs/**/*.md,app/lib/**/*.dart -Pattern '2\\s*秒|2\\s*s\\s*内'"` | 命中数 **0**（FF-25） |
| B11 | 无 `INTERNET` 权限 | `aapt dump badging build/app/outputs/flutter-apk/app-release.apk` | 输出不含 `android.permission.INTERNET` |
| B14 | **注入模式免麦克风（ADR-02）** | `flutter test test/demo/injection_equivalence_test.dart --plain-name "inject session needs no mic"` | 在**麦克风被占用**的 mock 环境下 `startSession({skipAudioRecord:true, …})` 仍成功；出参 `audioRecordActive == false`；`getDiagnostics().micInUseKnown == false` 且 `micInUse == null`；**未触发权限请求**（`API-01 §2.3`、`§5` 第 10 项） |
| B15 | **注入路径必须产出包络（ADR-01）** | 同上 `--plain-name "inject emits envelope"` | 注入产生的连续 20 个 `patch` 事件均含 `rmsEnvelope` 且 `length == 819`、`envelopeHopMs == 5`；且 `startSession` 载荷中 `includeEnvelope == true`（`API-01 §5` 第 9 项） |

**B12 现场逐项核对表（Mode B · 人工核对，仅限 UI 视觉与文案）**

| # | 核对项 | 通过判据 | ☐ |
|---|---|---|---|
| 1 | 「示例演示」标识在会话开始即出现 | 不等第一个 patch | ☐ |
| 2 | 波形动画节奏与真实进食相近 | 无「毫秒级涌出」观感 | ☐ |
| 3 | 确认结果仍约在 FF-20a 时机出现 | 与 Mode A 观感一致 | ☐ |
| 4 | 全程无声源播放（手机未外放） | 现场可听到「没有外放声音」 | ☐ |
| 5 | 段间静音不触发自动结束 | 无 `silence90s` 结束 | ☐ |
| 6 | 类别与所演示食物明显对应 | 6 类各演一次 | ☐ |
| 7 | 讲解口径为「注入缓冲、与实时同管线」 | 口头表述与 SPEC §2.1 一致 | ☐ |
| 8 | **行为指标可见（咀嚼次数 / 进食速度）** | 注入演示中 `P-07` 有输出（证明 `rmsEnvelope` 到位，ADR-01）；无 `ACD-BEH-001` | ☐ |

**B13 实测记录表**

| 字段 | 说明 |
|---|---|
| 记录产物路径 | `docs/demo/D9_三模式实测记录.md`（Mode B 段）+ 证据 `docs/demo/evidence/D9_modeB_*.log`（含 `injectPcm` 逐片调用时间戳） |
| 必填列 | 段名 / 类别 / 清单时长(实测) / 投喂总时长(实测) / Top-1 / 置信度 / 与 mic 路径标签是否一致 / 置信度差 / 是否通过 |
| 轮次要求 | 每类至少 1 段，共 ≥6 轮；**B1 的等价性必须在 ≥3 段上复现** |

## 8. 非功能约束
| 类别 | 约束 |
|---|---|
| 实时性 | 投喂节奏由墙钟驱动，相对误差 ≤ ±10%；不得因投喂阻塞 UI isolate |
| 内存 | 单段 PCM16 解码后驻留内存；**禁止写临时 wav 文件**（FF-24 第 1 条） |
| APK 体积 | 30 段资产计入 APK；须在 `PLAN-C-04` 出包时报告体积并在 §10 登记（本 SPEC 不设体积预测值） |
| 隐私 | 运行时 PCM 只在内存；内置资产是**随 APK 打包的静态资源**，不属于 FF-24 第 1 条所指的会话音频 |
| 无网络 | 资产全部本地打包，**运行时零网络**（FF-24 第 4 条） |
| 可演示性 | Mode B 的定位是「实时失败时的保命模式」，必须在 D9 前可用 |

## 9. 裁剪与未做
> **本功能不可裁剪。** 三种 Demo 模式是主方案 §8.2.1 五项「不可砍」之一（第⑤项）；且 §8.2.4 明确：**CP3 未过时 Mode B + Mode C 必须可用**（Mode B 是最后防线之一）。

| 项 | 状态 |
|---|---|
| 二次采集（放音 + 收音） | ❌ **明令禁止**，不是「暂不做」 |
| 示例音频播放器 UI | ❌ 不做 |
| 运行时重采样 | ❌ 不做（规格不符即报错） |
| 为 Mode B 另建推理 / 聚合分支 | ❌ 不做（破坏等价性验收） |
| 运行时下载资产 | ❌ 不做（FF-24 第 4 条） |
| 音频后期处理（降噪后另存） | ❌ 不做（破坏与 Mode A 的可比性） |

## 10. 开放问题
1. ✅ **已关闭（依据 ADR-02）** 原开放问题「Mode B 仍依赖 `startSession`（会初始化 `AudioRecord`），麦克风被占用时 Mode B 同样不可用」。**结论**：`API-01 §2.3` 的 `startSession` 新增 `skipAudioRecord`（默认 `false`）；**Mode B 固定以 `skipAudioRecord=true` 启动**——不打开 `AudioRecord`、只建环形缓冲与事件发射器、仅接受 `injectPcm` 喂入，**不请求 `RECORD_AUDIO` 权限、也不得因权限缺失而失败**；出参 `audioRecordActive=false`，`getDiagnostics().micInUse` 返回 **`null` 而非 `false`**（`false` 会被误读为「麦克风可用」），并由新增的 `micInUseKnown=false` 显式区分「不可用」与「未启用」。保命漏洞解除，**本项不再需要三方确认**。
2. ✅ **已关闭（依据 ADR-01）** 原开放问题「Mode B 会话是否写数据库未定」。**结论**：**是否写数据库由 Dart 侧决定，不由原生决定**；写入时 `DietRecord.source = "demo"`，**不得混入 Track 1 的真实累积数据**；`DemoController.startSamplePlayback()` 默认写入（这样演示后报告页立刻有数据可看），并与 `SPEC-A-04` 的「加载演示数据集」共用同一个「清除演示数据」动作回收。**原生侧只负责缓冲注入与事件发射，不得自行写库**（`API-01 §2.6`）。
3. **`ACD-DEMO-001` 不区分子类**：`ACD-DEMO-002/003` 已由 `API-04 §8` 占用（数据集 / 模式切换），故「缺失 / 损坏 / 规格不符」三者仍统一为 `001`。若需细分，须走 `API-00 §3.9` 变更流程。**是否细分需拍板**（低优先）。
4. **`injectChunkMs` 的归属**：本 SPEC 将其单一真源放在 `manifest.json`。若评审认为它属于运行参数，则须登记进 `feature_config`（`SPEC-C-03`）。**需拍板。**
5. **FF-24 第 1 条与内置资产的界定**：本 SPEC 明确「内置 wav 是 APK 静态资产，不属于会话音频落盘」。**该界定需在 `SPEC-C-01` / 合规审查中确认**，避免答辩时被追问。

**文档结束**

# SPEC-M-01 Demo Mode A · 实时识别

| 项 | 值 |
|---|---|
| 域 | M · 演示与现场保障 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §9「三大 Demo 模式」Mode A、§9.2 现场执行 SOP、§8.2.1 第⑤项；**`API-04 §7`（`DemoMode` / `DemoController` 权威定义）与 `§7.2`（模式状态机）**；`API-01 §2.3`、`§2.5`、`§3.2`、`§3.3`；`SPEC-00 §3.4 FF-20a`、`§3.6 FF-21a`、`§3.9 FF-24`、`§3.10 FF-25` |
| 依赖的 SPEC | `SPEC-P-01`、`SPEC-P-05`、`SPEC-P-06`、`SPEC-U-02`、`SPEC-U-06`、`SPEC-M-04` |

## 1. 目标与范围

### 1.1 一句话目标
用一个入口把「真机麦克风实时采集 → Mel → TFLite 推理 → 三级聚合」整条链路跑起来，并按「先出波形动画与未确认实时预测、约 4–5 s 后出确认结果（FF-20a）」的双路演示脚本展示，作为现场主打模式。

### 1.2 范围内（In Scope）
| # | 内容 |
|---|---|
| 1 | `DemoMode.realtime` 的启动 / 停止入口及其在 `DemoController.switchTo` 中的落点 |
| 2 | 启动前的**环境自检前置条件**：先调 `DemoController.runSelfCheck()`，未全通过则不得进入实时会话 |
| 3 | 三路展示的编排：①`level` 事件驱动的波形动画 ②单 patch 的**未确认实时预测**（灰显）③聚合后的**确认结果卡片** |
| 4 | `patch.source` 标识规则：`mic` 不显示「示例演示」，`inject` 必显示（`API-01 §3.2`） |
| 5 | 现场环境噪声 >65 dB（主方案 §9.2）时提示并一键切 Mode B 的判据与入口（**判据来自进场前人工 SOP 实测，非自检项**，见 §7 A6） |
| 6 | 停止收尾：`stopSession` → 落库 → `clearTempAudio`（`API-01 §2.7`） |
| 7 | 演示脚本文档中 Mode A 段落的**观感配合**写法（不写延迟预测值） |

### 1.3 范围外（Out of Scope）——防止实现方自由发挥
| 不做 | 归属 |
|---|---|
| 采集、VAD、预处理、Mel 计算 | `SPEC-P-01`~`SPEC-P-04` |
| 模型加载与推理 | `SPEC-P-05` |
| EMA / 连续判据 / 低置信度二选一确认 | `SPEC-P-06` |
| 波形组件与确认卡片的视觉实现 | `SPEC-U-02`、`SPEC-U-06` |
| 示例音频注入 | `SPEC-M-02` |
| 自检面板 UI 的完整实现 | `SPEC-M-04` |
| 后台常驻监听 / 自动开始检测 | FF-24 第 6 条明令不做 |
| 任意修改识别类别 | `X-02` 已降级为二选一确认 |

## 2. 功能行为

### 2.1 触发与前置条件
1. 用户进入 AI 检测页（`U-02`）；`DemoController.currentMode` 默认为 `DemoMode.realtime`。
2. 启动前**必须**依次满足（任一不满足即不启动，见 §6）：
   - 启动握手通过（`getCapabilities()` 与 `feature_config.json` 逐字段一致，否则 `ACD-CFG-001`，`API-00 §3.6`）；
   - `recordAudioPermission == "granted"`（`getDiagnostics()`，`API-01 §2.8`）；
   - `micAvailable == true` 且 `micInUse == false`（`getDiagnostics()`，`API-01 §2.8`）；若 `micInUseKnown == false`（`skipAudioRecord=true` 的未启用麦克风会话），本项按 `API-04 §7.1` 第 2 项判通过、`observed` 记「未启用麦克风」，**不判失败**；
   - `activeSessionId == null`（`maxConcurrentSessions = 1`）；
   - 演示前 30 分钟 SOP 实测判定环境噪声 ≤ 65 dB（主方案 §9.2）。
3. 现场纪律前置：飞行模式 + 免打扰 + 屏幕常亮（主方案 §9.2）。

### 2.2 主流程（编号步骤）
1. UI 触发 → `DemoController.startRealtimeSession()`。
2. 内部先 `runSelfCheck()`；`SelfCheckReport.allPassed == false` → 中止，展示首个失败项的 `hint`。
3. 若 `activeSessionId != null` → 先 `stopSession` 再继续（**不做隐式替换**，`API-01 §2.3`）。
4. 生成 `sessionId`（格式 `S-<epochMs>-<4位hex>`，`API-00 §3.4`）→ `startSession({enableDenoise:false, autoEndOnSilence:true, silenceEndSeconds:90})`（`FF-21a`）。
5. 订阅 `com.acoudiet.app/audio_stream`（携带 `sessionId`）。
6. `level` 事件（10 Hz）→ 仅驱动波形动画，**不参与任何业务判定**（`API-00 §3.3`）。
7. `patch` 事件（2 Hz）**分两路并行消费**：
   - 路 1（未确认）：对单 patch 出 `InferenceResult` → 立刻刷新「当前预测（未确认）」灰显文案；
   - 路 2（确认）：交给 `VoteAggregator` 累积 → `AggregatedDecision`，其 `VoteStage` 达到确认判据后才出确认卡片。
8. 路 2 在每次推理完成后调 `ackPatch({sessionId, seq})`（`API-01 §3.4`）。
9. 用户点停止 / 90 s 静音自动结束 → `stopSession` → 收到 `sessionEnded`。
10. 收到 `sessionEnded` 后提交数据库事务并调 `clearTempAudio()`（`FF-24` 第 2 条）。

### 2.3 状态与状态迁移
Demo 层状态（`DemoController` 持有，UI 只读）：

```
IDLE ──startRealtimeSession──▶ PRECHECK ──allPassed──▶ RUNNING
                                  │                       │
                                  │ 任一失败               │ stopSession / sessionEnded
                                  ▼                       ▼
                              BLOCKED（附 reason）      STOPPING ──▶ IDLE
                                                          │
                                                          └─ 噪声 >65 dB ▶ SUGGEST_MODE_B（非终态，可留在 IDLE）
```

| 迁移 | 触发 | 允许 |
|---|---|---|
| IDLE → PRECHECK | `startRealtimeSession()` | ✅ |
| PRECHECK → RUNNING | 自检全通过且 `startSession` 成功 | ✅ |
| PRECHECK → BLOCKED | 自检失败 / 握手失败 / 权限失败 | ✅ |
| RUNNING → STOPPING → IDLE | `stopSession` 或 `sessionEnded` | ✅ |
| RUNNING → PRECHECK | 运行中再次 `startRealtimeSession` | ❌ 必须先用 `stopSession`（会话运行中调 `switchTo` 会抛 `ACD-DEMO-003`，`API-04 §7.2`） |
| BLOCKED → RUNNING | 直接启动 | ❌ 必须先重跑 `runSelfCheck()` |
| SUGGEST_MODE_B → RUNNING | 未处理噪声提示即启动 | ❌ 提示必须被显式确认或切模式 |

> 原生会话状态机以 `API-01 §4` 为唯一权威，本节只描述 Demo 层的编排状态。

### 2.4 边界条件
| 边界 | 行为 |
|---|---|
| 环境噪声 >65 dB | 不自动切模式；给 `hint="建议切换到 Mode B（示例演示）"` 并暴露一键切换入口（**判据来自现场人工实测，非自检项**，见 §7 A6） |
| `recordAudioPermission == "permanentlyDenied"` | 展示「去设置」按钮（`ACD-PERM-002` 场景） |
| 麦克风被其他 App 占用 / 硬件故障 / 权限被永久拒绝 | `ACD-AUD-002` / `ACD-AUD-001` / `ACD-PERM-002`；**一律按 §6 现场处置表执行**——切 Mode B 时**必须带 `skipAudioRecord=true`**（见 §6 表第 2 行），不得只做普通切换 |
| `droppedPatches / patchesEmitted > 0.05` | 提示推理过慢；按 `PLAN-P-05` 延迟降级（提高推理步长），**不得静默继续** |
| 会话中用户切到 Mode B / C | 先 `stopSession` 收尾再切，禁止双会话 |
| 90 s 静音自动结束 | 正常收尾路径，`sessionEnded.reason == "silence90s"` |
| 演示中来电 / 弹窗 | 由 SOP（飞行模式 + 双机备份）规避；`sessionEnded(code)` 非空时展示错误码 |
| `n_frames` 已修订（FF-11 = **`n_frames = 128`**，`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~，`129` 现为 `raw_mel_frames`） | 本功能不依赖具体帧数；通过握手取值，**不得硬编码** |

## 3. 接口契约
> 只写与本功能直接相关的契约；`DemoController` / `DemoMode` 的**权威定义在 `API-04 §7`**（本节不复制签名，遵 `SPEC-00 §5.2`），完整签名以 `docs/*/docs_api/` 为准。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5→L4 | `DemoController.switchTo(DemoMode.realtime)` | `DemoMode` | `Future<void>` | `ACD-DEMO-003`（会话运行中 / 前置未就绪，`API-04 §7.2`） |
| L5→L4 | `DemoController.startRealtimeSession()` | 无 | `Future<void>` | 透传 `ACD-PERM-001/002`、`ACD-AUD-001/002`、`ACD-SESS-002`（`API-04 §7`）；自检失败见 §6 |
| L5→L4 | `DemoController.runSelfCheck()` | 无 | `Future<SelfCheckReport>` | 无（失败即 `allPassed=false`） |
| L4→L1 | `getDiagnostics()`（`API-01 §2.8`） | `{}` | 诊断 Map | 无 |
| L4→L1 | `startSession`（`API-01 §2.3`） | `sessionId` / `enableDenoise` / `autoEndOnSilence` / `silenceEndSeconds` | `SessionSummary` 头部字段 | `ACD-PERM-001/002`、`ACD-SESS-002`、`ACD-AUD-001/002` |
| L4→L1 | `stopSession`（`API-01 §2.5`） | `sessionId` | `SessionSummary` | `ACD-SESS-001` |
| L4→L1 | `ackPatch`（`API-01 §3.4`） | `sessionId` / `seq` | `{ok:true}` | 无 |
| L1→L4 | 事件 `level` | — | `rms` / `peak` / `voiced` | — |
| L1→L4 | 事件 `patch` | — | `seq` / `tStartMs` / `tEndMs` / `mel` / `source` / `voiced` | — |
| L1→L4 | 事件 `sessionEnded` | — | `reason` / `code` / `summary` | `reason=="error"` 时 `code` 非空 |
| L4→L1 | `clearTempAudio()`（`API-01 §2.7`） | `{}` | 清理计数 | 无 |

## 4. 数据契约

| 字段 | 类型 | 单位 / 值域 | 可空 | 来源 |
|---|---|---|---|---|
| `DemoMode` | `enum` | `realtime` / `sampleAudio` / `reportOnly` | 否 | **`API-04 §7`**（权威定义） |
| `patch.seq` | `int` | 自 0 单调递增，会话内不跳号不重复 | 否 | `API-01 §3.2` |
| `patch.mel` | `Float32List` | 长度 `nMels × nFrames`，行主序 `mel[m * nFrames + t]` | 否 | `API-01 §3.2` + FF-11 |
| `patch.source` | `String` | `"mic"` \| `"inject"` | 否 | `API-01 §3.2` |
| `patch.voiced` | `bool` | `false` 的 patch **仍要进入 EMA** | 否 | FF-20c |
| `InferenceResult` | Dart 类 | `top1` 6 类之一 + `confidence ∈ [0,1]` | 否 | `API-02`（域 P） |
| `VoteStage` | `enum` | 未确认 / 待确认 / 已确认 | 否 | `API-02`（域 P） |
| `AggregatedDecision` | Dart 类 | 含 `stage`、`top1`、`confidence`、`recordId?` | 否 | `API-02`（域 P） |
| 环境噪声实测记录 | 人工填写（**非自检项**） | 现场 SOP 实测的 dB 读数 + 所用工具名（声级计 / 手机测噪 App） | — | **非自检项**；由现场 SOP 人工实测记录（本 SPEC §7 A6），**不进入 `SelfCheckReport.items`**；`API-04 §7.1` 的 14 项已冻结，不得追加 `ambientNoise` |

**schema 引用**：`docs/common/docs_api/schemas/`（schema 集由 `SPEC-C-03` / `API-00 §4` 收口）。本功能涉及的 `patch` / `sessionEnded` 载荷以 `API-01 §3.2` 为字段真源；自检结果模型以 **`API-04 §7`** 为字段真源。**禁止在 `docs/*/docs_api/` 之外复制第二份接口签名**（`API-00 §3.9`）。

## 5. 参数与常量
> 逐项引用 `SPEC-00 §3` 的 FF 编号；**本节不写出可漂移的字面值**。

| 编号 | 本功能的用途 |
|---|---|
| FF-01 | 麦克风采集采样率（由 `getCapabilities()` 回读校验） |
| FF-04 | `hop_length`，决定原生单帧处理耗时上限（`API-00 §3.7`） |
| FF-09 | patch 时长（演示脚本中「一个 patch 的时长」的唯一合法口径） |
| FF-12 | 推理滑窗步长 → `patch` 事件速率来源 |
| FF-20 | 三级聚合判据（EMA / 连续判据 / 低置信度二选一） |
| FF-20a | **首次确认结果耗时**；本功能只允许写「约 4–5 s」并标 FF-20a |
| FF-20c | 聚合状态必须跨 patch 保持（禁止每 patch 重置） |
| FF-21a | `silenceEndSeconds` 的取值来源 |
| FF-24 | 第 1/2/4/6 条：不落盘、临时文件清理、无 `INTERNET`、无后台常驻 |
| FF-25 | 宣传红线：禁止「2 秒内出结果」等绝对化表述 |
| FF-11 | `n_frames` = **128**（**已修订**，`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~，`129` 现为 `raw_mel_frames`；见 FF-11）；本功能通过握手取值 |

## 6. 异常与降级

**错误码映射（取值域与 `API-04 §7.2/§8` 一致；本 SPEC 不新造错误码）**：

| 自检失败项 | 对外错误码 |
|---|---|
| 录音权限被拒 / 永久拒绝 | `ACD-PERM-001` / `ACD-PERM-002` |
| 麦克风不可用 / 被占用 | `ACD-AUD-001` / `ACD-AUD-002` |
| 握手不一致 | `ACD-CFG-001`（**fail fast，禁止进入检测页**） |
| 已有活跃会话 | `ACD-SESS-002`（`API-01 §2.3`） |
| 模式切换非法 / 前置数据未就绪 | `ACD-DEMO-003`（`API-04 §7.2`） |
| 模型加载失败 | `ACD-INF-001` |
| 数据库不可用 | `ACD-DB-003` |

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 自检未全通过 | `SelfCheckReport.allPassed == false` | 不启动，停在 `BLOCKED` | 显示失败项 `label` + `observed` + `hint` |
| 握手失败 | `getCapabilities()` 与 `feature_config.json` 不符 | fail fast | 「配置不一致，请重启应用」+ `ACD-CFG-001` |
| 环境噪声超阈 | **现场人工实测**噪声 >65 dB（声级计 / 手机测噪 App，主方案 §9.2） | 按 §6 处置表切 Mode B，不自动切；**该判断不经自检面板** | 横幅「环境噪声偏大，建议使用示例演示」 |
| 背压丢包超阈 | `droppedPatches / patchesEmitted > 0.05` | 按 `PLAN-P-05` 提高推理步长 | 角标提示「推理负载偏高」 |
| 会话中途 `sessionEnded(reason="error")` | 事件 `code` 非空 | 立即收尾，不写半条记录 | 展示错误码 + 重试按钮 |
| 停止后临时音频未清零 | `clearTempAudio().filesDeleted` 与 `getDiagnostics().tempAudioFiles` 不一致 | 再清一次并记日志（`ACD-IO-001` 不阻断） | 无感 |
| 现场噪声持续超阈且 Mode B 亦不可用 | SOP 判据 | 降级到 Mode C（`SPEC-M-03`） | 切换到报告演示 |

**现场处置表（依据 ADR-02；与 `API-01 §2.3` 冻结口径逐字一致，Mode A 失败时的唯一现场动作依据）**：

| 故障类型 | 处置 |
|---|---|
| 环境噪声大（>65 dB） | 切 **Mode B**（麦克风仍可用） |
| 麦克风被占用 / 硬件故障 / 权限被永久拒绝 | 切 **Mode B（`skipAudioRecord=true`）**；若仍失败则切 **Mode C** |
| 模型加载失败（`ACD-INF-001`） | 直接切 **Mode C**（Mode B 同样依赖推理引擎） |

> ⚠️ **第 2 行是本表的要点**：麦克风故障时若按普通参数切 Mode B，`startSession` 仍会初始化 `AudioRecord` 并返回 `ACD-AUD-002`/`ACD-AUD-001`，**保命模式在同一次故障中再次失效**。因此「切 Mode B」在设备故障场景下**等价于**「切 Mode B 且 `skipAudioRecord=true`」；该参数不打开 `AudioRecord`、不请求 `RECORD_AUDIO`，出参 `audioRecordActive=false`，`micInUseKnown=false`。Mode A 关闭麦克风后无实时数据源，故本模式**不提供**该参数的入口，只在切换到 Mode B 时透传。

## 7. 验收标准（可机器判定）

> **本功能是 CP3 的组成部分。** CP3（D9 午）的判据是「三种 Demo 模式全部可用」，本功能是其中 Mode A（主打模式）的实测对象。CP3 未过时按 `PLAN-00 §2` 处置：**停止一切新功能**，3 人全部扑 Demo 稳定性；主方案 §8.2.4 同时规定 Mode B + Mode C 必须可用（详见 `PLAN-M-01 §7`）。

| # | 判据 | 验证方式（命令 / 测试名） | 通过阈值 |
|---|---|---|---|
| A1 | 自检未通过时禁止启动 | `flutter test test/demo/demo_mode_a_test.dart --plain-name "modeA blocked by selfcheck"` | 未调用 `startSession`（mock 计数 0），`currentMode` 不被改写 |
| A2 | 握手不一致 fail fast | 同上 `--plain-name "modeA blocked by cfg mismatch"` | `PlatformException.code == "ACD-CFG-001"`，且未进入检测页 |
| A3 | 会话生命周期与确认配对 | 同上 `--plain-name "modeA session lifecycle"` | 调用序列 `getDiagnostics → startSession → (events) → stopSession → clearTempAudio`；`ackPatch` 次数 == 收到的 `patch` 事件数 |
| A4 | 双路并行不互相阻塞 | 同上 `--plain-name "unconfirmed prediction independent of aggregation"` | 连续注入 3 个 patch 后，未确认预测更新 ≥ 3 次；`AggregatedDecision.stage != 已确认` 时确认卡片不渲染 |
| A5 | 聚合状态跨 patch 保持 | 同上 `--plain-name "aggregation state persists across patches"` | 连续 2 个 patch 之间 EMA 与连续计数不归零（FF-20c） |
| A6 | 现场噪声 >65 dB 时切 Mode B | **人工核对**（A11 第 8 项 + A12 记录表）：用外部工具（声级计 / 手机测噪 App）实测现场环境噪声 | 记录表 `环境噪声读数` 列**写出实测 dB 值且注明所用工具**；`>65 dB` 时按 §6 处置表切 Mode B 且实测记录可追溯。**该判断不经自检面板，不引用任何 `SelfCheckItem.key`** |
| A7 | 文案红线零命中 | `pwsh -Command "Select-String -Path docs/**/*.md,app/lib/**/*.dart -Pattern '2\\s*秒|2\\s*s\\s*内' "` | 命中数 **0**（FF-25） |
| A8 | 无 `INTERNET` 权限 | `aapt dump badging build/app/outputs/flutter-apk/app-release.apk` | 输出**不含** `android.permission.INTERNET`（FF-24 第 4 条） |
| A9 | 会话结束临时音频清零 | `flutter test test/demo/demo_mode_a_test.dart --plain-name "temp audio cleared after session"` | `cacheDir` 中匹配 `audio_*` 的文件数 == 0 |
| A10 | 首次确认耗时（**D9 实测产出**，禁止预测） | 真机实测 3 次并写入记录表 | 3 次实测值全部落在 FF-20a 所述区间；越界则按 §6 处置并登记 |

**A11 现场逐项核对表（Mode A · 人工核对，仅限 UI 视觉与文案）**

| # | 核对项 | 通过判据 | ☐ |
|---|---|---|---|
| 1 | 波形动画随进食实时变化 | 停止进食后波形回落至基线 | ☐ |
| 2 | 「当前预测（未确认）」灰显且标明未确认 | 文案含「未确认」二字 | ☐ |
| 3 | 确认结果在未确认预测之后出现 | 时间戳顺序正确 | ☐ |
| 4 | `source=mic` 时**不显示**「示例演示」标识 | 屏幕上无该字样 | ☐ |
| 5 | 低置信度走二选一确认，不写日志 | FF-20 Level 3 行为可见 | ☐ |
| 6 | 全程无网络相关提示 / 无联网行为 | 已开飞行模式仍正常 | ☐ |
| 7 | 讲解口径为「约 4–5 s」 | 口头与 PPT 均无「2 秒内」 | ☐ |
| 8 | **现场噪声已用外部工具实测并记录** | 记录表写出实测 dB 值 + 工具名；`>65 dB` 时已按 §6 处置表切 Mode B（**不经自检面板**） | ☐ |

**A12 现场实测记录表（逐项填写，禁止事后补写）**

| 字段 | 说明 |
|---|---|
| 记录产物路径 | `docs/demo/D9_三模式实测记录.md`（Mode A 段）+ 原始证据 `docs/demo/evidence/D9_modeA_<HHMM>.log` |
| 必填列 | 轮次 / 时间 / 场地 / **环境噪声读数（实测 dB 值 + 所用工具名）** / 首次确认耗时(实测) / Top-1 标签 / 是否通过 / 异常码 / 操作人 |
| 轮次要求 | ≥ 3 轮有效实测；**任一列留空视为该轮无效** |

## 8. 非功能约束
| 类别 | 约束 |
|---|---|
| 实时性 | 单次 Mel 处理与推理耗时约束见 `API-00 §3.7`；本功能不新增耗时预算 |
| 线程 | 推理必须在不阻塞 UI 的 isolate（`API-00 §3.7`）；波形动画在 UI isolate |
| 内存 | `patch.mel` 用 `Float32List` 传输，**禁止 `List<double>` 或 Base64**（`API-01 §3.2`） |
| 隐私 | 音频仅存在于内存环形缓冲，**不落盘、不上传**（FF-24 第 1/4 条） |
| 功耗 | 无后台常驻 Service；会话结束即释放麦克风（FF-24 第 6 条） |
| 无障碍 | 未确认与已确认状态必须有**文字**区分，不得仅靠颜色（`U-06` 设计系统约束） |

## 9. 裁剪与未做
> **本功能不可裁剪。** 三种 Demo 模式是主方案 §8.2.1 五项「不可砍」之一（第⑤项），Mode A 是该清单中的主打模式。任何削减须经 A/B/C 三方确认并登记 `PLAN-00 §6`。

| 项 | 状态 |
|---|---|
| `X-02` 手动修正（任意改类别） | ❌ 不做；本功能只呈现二选一确认结果 |
| `X-05` 检测页识别历史列表 | ❌ 不做；历史见饮食记录页（`U-03`） |
| 后台常驻 / 自动开始检测 | ❌ 不做（FF-24 第 6 条） |
| 推理延迟优化专项 | 🔵 推迟；仅保留 `PLAN-P-05` 的步长降级开关 |
| Mode B / Mode C | 不在本功能范围，见 `SPEC-M-02` / `SPEC-M-03` |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`；后经 `ADR-21`（2026-09-12）修订）**：原问题「`n_frames` 未拍板」（FF-11）**已冻结为 ~~`n_frames = 129`~~ → 修订为 `n_frames = 128`**（`129` 现为 `raw_mel_frames`）—— 本功能通过握手取值，不受影响，但演示记录表中的 `nFrames` 列仍须取**实测握手值**（不得硬编码）。
2. **`ACD-DEMO-002` / `ACD-DEMO-003` 尚未生效**：`API-04 §8` 已定义这两码（分别为「演示数据集缺失/校验失败」与「模式切换非法」），但其尾注明确「3 个新增码须先补登 `API-00 §3.5` 才生效」。本 SPEC 已按新码撰写，**补登动作须在 D9 前完成**。
3. ✅ **已关闭（依据 ADR-04）** 原开放问题「现场噪声 >65 dB 的读数工具未定」及「是否作为自检项」。**结论**：`API-04 §7.1` 的自检清单**冻结为恰好 14 项**，**`ambientNoise` 不在其中，也不得加进去**。环境噪声是**进场前的人工 SOP 实测**（主方案 §9.2「提前 30 分钟到场，实测一次完整流程……>65 dB 直接走 Mode B」）——由**人拿外部工具现场测**，**不经过 `DemoController.runSelfCheck()`**。本 SPEC §4/§6/§7 A6 已据此改写：A6 改为**人工 SOP 核对项**（用声级计 / 手机测噪 App 实测，把「实测 dB 值 + 所用工具」写进 A12 记录表，`>65 dB` 按 §6 处置表切 Mode B），**不引用任何 `SelfCheckItem.key`**。具体工具型号与校准方式仍可由 B 在 `PLAN-M-01` / `PLAN-M-04` 中细化，但**性质已定：人工实测，非 App 自检项**。

**文档结束**

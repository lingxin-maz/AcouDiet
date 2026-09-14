# SPEC-P-01 音频采集会话与环形缓冲

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.3 / §5.1；`API-01` §2.1–§2.8、§3、§4、§6；`API-00` §3.2/§3.4/§3.5/§3.7/§3.8；`SPEC-00` §3.1（FF-01/FF-04/FF-09/FF-12）、§3.8（FF-23）、§3.9（FF-24） |
| 依赖的 SPEC | 无（域 P 最上游） |

## 1. 目标与范围

### 1.1 一句话目标
`AudioRecord` 以 16 kHz / 单声道 / PCM16 采集（FF-01），维护 65536 样本环形缓冲（≈4.096 s，FF-09），提供开始/暂停/停止与录音权限流程，并产出 `SessionSummary`。

### 1.2 范围内（In Scope）
- `RECORD_AUDIO` 权限请求与「永久拒绝」判定（`API-01` §2.2）。
- 能力握手 `getCapabilities`（**15 字段**，`API-00` §3.6；`ADR-21`（2026-09-12）由 12 字段扩至 15 字段）。
- 会话五态生命周期与 `API-01` §4 迁移表（含 3 条非法迁移）。
- 65536 样本环形缓冲的写入、覆盖、快照读取（FF-09）。
- 原生后台采集线程（专用 `HandlerThread`，`API-00` §3.7）。
- 10 Hz `level` 事件、2 Hz `patch` 事件节拍（FF-12）；`patch` 的 Mel 载荷由 P-04 填充。
- 背压 drop-oldest、`droppedPatches` 计数、`ackPatch` 消费确认（`API-01` §3.3/§3.4）。
- `pauseSession` / `resumeSession` 期间的缓冲持续写入语义（`API-01` §2.4）。
- `stopSession` 返回 `SessionSummary`；`getDiagnostics` 返回现场自检所需字段。
- 调用 `clearTempAudio` 的时机（冷启动一次 + 每次 `stopSession` 后一次，FF-24 §2）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| Mel 频谱计算（分帧/加窗/FFT/滤波器组/dB） | P-04 |
| 预加重、高通、响度归一化 | P-03 |
| VAD、静默判定、90 s 静音自动结束的**判据本身** | P-02（本功能按 `P-02` 的 `voiced` 与静音计时结果执行 `sessionEnded`） |
| TFLite 推理与三级聚合 | P-05 / P-06 |
| 行为指标计算 | P-07 |
| 音频落盘、缓存音频文件、上传 | **FF-24 §1/§2：绝对禁止** |
| 后台常驻 `Service` | **FF-24 §6：禁止**；检测必须由用户主动发起 |
| 原生侧直接写 SQLite | `API-01` §6：禁止（会产生两个数据源） |
| 多会话并发 / 隐式替换会话 | `maxConcurrentSessions = 1`；已活跃时返回 `ACD-SESS-002` |
| 蓝牙耳机 / 手表采集源 | 推迟到第三阶段（`00_功能清单` §5） |

## 2. 功能行为

### 2.1 触发与前置条件
1. 用户在「AI 检测」页主动点击「开始检测」（无后台自动启动，FF-24 §6）。
2. `getCapabilities` 已完成且与 assets 中 `feature_config.json` 逐字段一致；不一致则抛 `ACD-CFG-001` 且**禁止进入检测页**（`API-00` §3.6）。
3. `RECORD_AUDIO` 已授权；未授权时先走 `requestPermission`。
4. 当前无活跃会话（否则 `ACD-SESS-002`）。
5. `sessionId` 由 Dart 生成并按 `API-00` §3.4 规则传入，**原生不得自行生成**。

### 2.2 主流程（编号步骤）
1. Dart 生成 `sessionId` → 调 `startSession{sessionId, enableDenoise, autoEndOnSilence, silenceEndSeconds}`。
2. 原生校验状态为 `IDLE` → 进入 `STARTING` → 按 FF-01（采样率/声道/位深）初始化 `AudioRecord`。
3. 初始化成功 → `RUNNING`，启动后台采集线程，返回 `appliedConfig` 子集。
4. 采集线程按 512 样本（FF-04 的 hop）粒度 `read()`，写入环形缓冲（容量 65536 样本，FF-09）。
5. 每 100 ms 发一个 `level` 事件（10 Hz）；每 512 ms 发一个 `patch` 事件（FF-12）。
6. 每个 `patch` 事件：取最近 65536 样本快照 → 交 P-03 → P-04 得 Mel → 组装载荷 → 投递。
7. 投递前检查上一个 patch 是否已 `ackPatch`；未确认则 `droppedPatches++` 并丢弃本次（drop-oldest，永不阻塞采集线程）。
8. 用户暂停 → `PAUSED`：`AudioRecord` 保持录制、缓冲继续写入，但**不发 `patch` 事件**；恢复后第一个 patch 是完整 4.096 s 窗口。
9. 结束触发（用户 `stopSession` / `P-02` 判定静音达 FF-21a / 不可恢复错误）→ 停止采集 → 返回 `SessionSummary` → Dart 侧再调 `clearTempAudio`。

### 2.3 状态与状态迁移
以 `API-01` §4 为权威定义，本功能实现该表全部迁移与错误码：

| 迁移 | 触发 | 结果 |
|---|---|---|
| `IDLE → STARTING` | `startSession` | ✅ |
| `STARTING → RUNNING` | `AudioRecord` 启动成功 | ✅ |
| `STARTING → ERROR` | 启动失败 | `ACD-AUD-001` / `ACD-AUD-002` |
| `RUNNING ⇄ PAUSED` | `pauseSession` / `resumeSession` | ✅ |
| `RUNNING/PAUSED → IDLE` | `stopSession` | ✅ |
| `RUNNING → IDLE` | 静音自动结束（FF-21a，由 P-02 判定） | ✅，`endReason = silence90s` |
| `IDLE → RUNNING`（直接 `resumeSession`） | — | ❌ `ACD-SESS-002` |
| `PAUSED → PAUSED` | 重复 `pauseSession` | ❌ `ACD-SESS-002` |
| 已结束会话调 `pauseSession` | — | ❌ `ACD-SESS-001` |

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 会话时长 < 4.096 s（缓冲未填满） | 不发 `patch`；`SessionSummary.patchesEmitted = 0` |
| 采集线程被系统降频/短暂阻塞 | 允许丢样本，但 `seq` 必须连续不跳号（`API-01` §3.2） |
| 同一毫秒重复 `startSession` | 第二个请求返回 `ACD-SESS-002`，不隐式替换 |
| 麦克风被其他 App 占用 | `ACD-AUD-002`，会话进入 `ERROR` 并回收资源 |
| `onCancel`（Dart 取消订阅） | 停止发事件、释放引用、**不自动结束会话**（需显式 `stopSession`） |
| 暂停时长 | 不计入进食时长（`API-01` §2.4），恢复后按新「首次进食」重新计时 |
| Demo Mode B 注入 | 会话由 `startSession` 建立，PCM 经 `injectPcm` 入缓冲，`source = inject` |

## 3. 接口契约
> 权威定义见 `API-01`。本功能实现 §2.1–§2.8 与 §3、§4 的原生侧；此处只列本功能用到的部分。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Dart → Kotlin | `getCapabilities` | `{}` | `NativeCapabilities`（**15 字段**，`ADR-21`；原 ~~12~~） | 无（永不失败） |
| Dart → Kotlin | `requestPermission` | `{}` | `{granted, permanentlyDenied}` | 无（拒绝是正常返回值） |
| Dart → Kotlin | `startSession` | `{sessionId, enableDenoise, autoEndOnSilence, silenceEndSeconds}` | `{sessionId, startedAtMs, appliedConfig, denoiseEnabled}` | `ACD-PERM-001/002`、`ACD-SESS-002`、`ACD-AUD-001/002` |
| Dart → Kotlin | `pauseSession` | `{sessionId}` | `{pausedAtMs, state}` | `ACD-SESS-001/002` |
| Dart → Kotlin | `resumeSession` | `{sessionId}` | `{resumedAtMs, state}` | `ACD-SESS-001/002` |
| Dart → Kotlin | `stopSession` | `{sessionId}` | `SessionSummary` | `ACD-SESS-001` |
| Dart → Kotlin | `injectPcm` | `{sessionId, pcm16, isLast, feedRealtime}` | `{acceptedSamples, bufferedSamples}` | `ACD-SESS-001`、`ACD-DEMO-001` |
| Dart → Kotlin | `clearTempAudio` | `{}` | `{filesDeleted, bytesFreed, failed}` | 无（失败仅记日志） |
| Dart → Kotlin | `getDiagnostics` | `{}` | 诊断字段集 | 无 |
| Dart → Kotlin | `ackPatch` | `{sessionId, seq}` | `{ok: true}` | 无 |
| Kotlin → Dart | 事件 `level` | — | `{type, sessionId, tMs, rms, peak, voiced}` | — |
| Kotlin → Dart | 事件 `patch` | — | 见 §4 | — |
| Kotlin → Dart | 事件 `sessionEnded` | — | `{type, sessionId, tMs, reason, code, summary}` | — |

## 4. 数据契约
> 字段与类型权威定义见 `API-01` §2.5/§2.8/§3.2。
> ⚠️ **本契约没有 JSON Schema**：schema 集**固定为 6 份**（`feature_config` / `diet_record` / `health_score` / `foods` / `metrics` / `sync_envelope`），**不覆盖原生桥接载荷**。`SessionSummary` 的形状由 `API-01` §5 一致性测试的第 2 条（会话生命周期）机械保证，而非 JSON Schema —— 因为它是**方法返回值而非持久化文档**，用侧侧对称的 Dart/Kotlin 单测验证比 schema 更直接。

| 结构 | 关键字段 | 类型 | 值域 / 约束 |
|---|---|---|---|
| `SessionSummary` | `sessionId` / `startedAtMs` / `stoppedAtMs` / `durationMs` | `String` / `int` | 时间统一 epoch 毫秒（`API-00` §3.2） |
| `SessionSummary` | `patchesEmitted` / `patchesVoiced` / `droppedPatches` | `int` | `patchesVoiced ≤ patchesEmitted`；`droppedPatches` 可为 0 |
| `SessionSummary` | `firstVoicedAtMs` / `lastVoicedAtMs` | `int?` | 会话内无 `voiced` patch 时为 `null` |
| `SessionSummary` | `endReason` | `enum` | `userStop` / `silence90s` / `error` |
| `SessionSummary` | `rmsStats{mean,p95,peak}` | `double` | 线性幅度 `[0,1]`，仅统计不判定 |
| 事件 `patch` | `seq` | `int` | 会话内自 0 单调递增，不跳号不重复 |
| 事件 `patch` | `tStartMs` / `tEndMs` | `int` | `tEndMs − tStartMs ≈ 4096` |
| 事件 `patch` | `mel` | `Float32List` | 长度 `nMels × nFrames` = `128 × 128`（`ADR-21`；**丢弃尾帧后**的载荷），行主序 `mel[m * n_frames + t]`；由 P-04 填充 |
| 事件 `patch` | `voiced` | `bool` | 由 P-02 判定；`false` 的 patch **仍要投递**并进入 EMA |
| 事件 `patch` | `source` | `enum` | `mic` / `inject` |
| `getDiagnostics` | `bufferedSamples` | `int` | `[0, 65536]` |

## 5. 参数与常量
> 一律引用 `SPEC-00 §3`；本处不复制可能漂移的字面值。

| 项 | 引用 |
|---|---|
| 采样率 / 声道 / 位深 | FF-01 |
| `hop_length`（采集线程粒度） | FF-04 |
| 环形缓冲样本数（patch 采样数） | FF-09 |
| patch 事件频率 / 推理滑窗步长 | FF-12 |
| `patch` 事件节拍与 `n_frames` | FF-11（**`n_frames = 128`**；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 静音自动结束秒数 | FF-21a（判据由 P-02 实现） |
| 平台 / `minSdk` / 包名 | FF-23 |
| 隐私约束（不落盘、清理、无 INTERNET、仅 RECORD_AUDIO） | FF-24 |
| 线程约定（原生后台线程、投递主线程） | `API-00` §3.7 |
| 背压比例阈值 | `API-01` §3.3（`droppedPatches / patchesEmitted ≤ 0.05`） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 录音权限拒绝 | `requestPermission` 返回 `granted=false` | 停在 `IDLE`，不启动 `AudioRecord` | 提示需授权后才能检测，给「授权」按钮（`ACD-PERM-001`） |
| 权限被永久拒绝 | `permanentlyDenied=true` | 不再重复弹系统框 | 给「去设置」按钮（`ACD-PERM-002`） |
| `AudioRecord` 初始化失败 | 构造/`startRecording` 抛错 | 释放资源 → `ERROR` → `IDLE` | 「麦克风初始化失败，请重试」 |
| 麦克风被占用 | `read()` 持续返回错误/0 | 结束会话，`endReason=error` | 「麦克风被其他应用占用」 |
| 配置握手不一致 | **15 字段**逐一比对失败（`ADR-21`；原 ~~12~~） | **fail fast**，禁止进入检测页 | 「配置不一致，请重装应用」（`ACD-CFG-001`） |
| 推理过慢导致丢 patch | `droppedPatches / patchesEmitted > 0.05` | 上报诊断；由 P-05 提高推理步长至 1.0 s | 不出错误提示，仅自检面板数值上升 |
| 临时音频清理失败 | `clearTempAudio` 返回 `failed > 0` | **不阻断主流程**，仅记日志 | 无（`ACD-IO-001`，`retryable=false`） |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 能力握手字段与配置一致 | `flutter test test/native/capabilities_handshake_test.dart`（mock 通道），断言 `NativeCapabilities` **15 字段**（`ADR-21`；原 ~~12~~）与 `feature_config.json` 全等 | 测试退出码 0；不一致场景抛 `ACD-CFG-001` |
| 2 | 会话生命周期合法迁移全通 | `android/app/src/test/kotlin/com/acoudiet/app/audio/SessionStateMachineTest.kt` 的 `lifecycle_allLegalTransitions` | 断言数 = `API-01` §4 表 7 条合法迁移；全绿 |
| 3 | 非法迁移返回正确错误码 | 同上 `lifecycle_illegalTransitions` | 3 条非法迁移分别返回 `ACD-SESS-002`/`ACD-SESS-002`/`ACD-SESS-001` |
| 4 | 环形缓冲容量与覆盖语义 | `RingBufferTest.kt` 的 `capacity_isFF09_and_overwritesOldest` | `capacity == 65536`（FF-09）；写入 70000 样本后最旧 4464 样本被覆盖 |
| 5 | patch 载荷形状与 `seq` 单调 | `flutter test test/native/patch_stream_shape_test.dart` | 连续 20 个事件 `mel.length == 128 × 128`（`nMels × nFrames`，`ADR-21`）且 `seq` 严格递增 |
| 6 | 背压 drop-oldest 不阻塞 | `BackpressureTest.kt` 的 `dropOldest_whenPreviousUnacked`（人为把消费延迟调到 2 s） | `droppedPatches > 0`、采集线程未阻塞、`sessionEnded` 正常发出 |
| 7 | 停止会话产出 `SessionSummary` | `flutter test test/native/session_summary_test.dart` | 字段齐全；`patchesVoiced ≤ patchesEmitted`；`endReason ∈ {userStop, silence90s, error}` |
| 8 | 临时音频清理 | `flutter test test/native/clear_temp_audio_test.dart` | `startSession` → `stopSession` 后 `cacheDir` 中 `audio_*` 文件数 == 0 |
| 9 | 无网络出口 | `aapt dump badging build/app/outputs/flutter-apk/app-release.apk`（`PLAN-C-01`） | stdout 中 `uses-permission` 不含 `INTERNET`；仅含 `RECORD_AUDIO` |
| 10 | 音频不落盘 | 代码审查脚本 `python ai/scripts/forbid_audio_write.py`（静态扫描 `java.io.File.write` 与音频缓冲关联调用） | 命中数 == 0 |
| 11 | 抓包为 0 | 全流程运行后 `adb shell dumpsys netstats` 比对（`PLAN-C-01`） | 本应用 UID 网络字节数 == 0 |

## 8. 非功能约束
- **线程**：`AudioRecord.read()` 与缓冲写入必须在原生后台线程；EventChannel 投递在 Android 主线程（`API-00` §3.7）。
- **实时性**：单次 512 样本读取与入缓冲必须在 32 ms（FF-04 对应的 hop 时长）预算内完成；实际耗时在 D2 实测产出，本 SPEC 不预设数字。
- **内存**：环形缓冲固定 65536 × 2 B（PCM16），不随会话时长增长；无第二份音频副本。
- **隐私**：见 FF-24 §1/§2/§6；本功能是 FF-24「音频不落盘」的第一责任人。
- **功耗**：无后台常驻；停止会话即释放 `AudioRecord`。
- **无障碍**：无 UI，不适用。

## 9. 裁剪与未做
- **本功能属于「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）**（`00_功能清单` §6）。**不得裁剪。**
- `X-01` 登录/账号体系：**不做**，会话无用户鉴权，用户身份由本地档案（`D-04`）承接。
- `X-05` 检测页「识别历史」列表：**不做**，本功能不保留任何历史会话列表。
- 蓝牙耳机 / 智能手表采集：**不做**（推迟第三阶段），采集源只有内置麦克风与 `injectPcm`。
- 多会话并发、原生侧推理、原生侧写库、音频落盘：**不做**（`API-01` §6）。
- 后台常驻 Service：**不做**（FF-24 §6）。

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`，2026-09-10；后经 `ADR-21`（2026-09-12）修订）**：`n_frames` 原冻结为 ~~`129`~~ → 现为 **`n_frames = 128`**（`129` 现为 `raw_mel_frames`，见 FF-11 / `ADR-21`）。本 SPEC 的验收判据 5 以 `128 × n_frames` 表达，**数值变更后判据形式不变**。
2. `AudioRecord` 的 `AudioSource` 选型（`MIC` vs `VOICE_RECOGNITION` vs `UNPROCESSED`）未定：影响是否被系统 AGC/降噪预处理，进而影响与训练侧的一致性。**需 A/B 确认后写入 `API-01` §2.3 的 `appliedConfig`。**
3. `silenceEndSeconds` 由 Dart 传入，但 FF-21a 是冻结值；是否允许 Dart 覆盖需 A 拍板（当前实现按不覆盖处理，仅作参数占位）。

**文档结束**

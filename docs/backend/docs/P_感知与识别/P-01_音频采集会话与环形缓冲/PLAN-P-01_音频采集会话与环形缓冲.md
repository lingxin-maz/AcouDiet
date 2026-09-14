# PLAN-P-01 音频采集会话与环形缓冲

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-01 |
| 负责 | B（主责）；A 协助 `AudioSource` 与训练侧一致性核对 |
| 目标日 | D2 |
| 前置依赖 | D0 环境验收 `PASS=28/FAIL=0`（`PLAN-00` §7）；`API-01` 已冻结；`PLAN-C-03` 的 `feature_config.json` 与 Dart 常量生成可用；Android 许可已接受 |
| 预估工时 | 8 h（B 1 人日） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `android/app/src/main/kotlin/com/acoudiet/app/audio/AudioCapture.kt` | `AudioRecord` 生命周期 + 后台采集线程 |
| 2 | `android/app/src/main/kotlin/com/acoudiet/app/audio/RingBuffer.kt` | 65536 样本环形缓冲（FF-09） |
| 3 | `android/app/src/main/kotlin/com/acoudiet/app/audio/SessionStateMachine.kt` | `API-01` §4 五态机 |
| 4 | `android/app/src/main/kotlin/com/acoudiet/app/audio/AudioBridge.kt` | MethodChannel + EventChannel 注册与事件投递、背压计数 |
| 5 | `android/app/src/main/kotlin/com/acoudiet/app/audio/TempAudioCleaner.kt` | `clearTempAudio` 实现 |
| 6 | `android/app/src/test/kotlin/com/acoudiet/app/audio/SessionStateMachineTest.kt` | 合法/非法迁移用例 |
| 7 | `android/app/src/test/kotlin/com/acoudiet/app/audio/RingBufferTest.kt` | 容量与覆盖语义 |
| 8 | `android/app/src/test/kotlin/com/acoudiet/app/audio/BackpressureTest.kt` | drop-oldest 不阻塞 |
| 9 | `test/native/capabilities_handshake_test.dart` | 握手 **15 字段**一致性（mock 通道；`ADR-21`；原 ~~12~~） |
| 10 | `test/native/patch_stream_shape_test.dart` | patch 载荷形状与 `seq` 单调 |
| 11 | `test/native/session_summary_test.dart` | `SessionSummary` 字段完整性 |
| 12 | `test/native/clear_temp_audio_test.dart` | 结束后 `audio_*` 文件数 == 0 |
| 13 | `ai/scripts/forbid_audio_write.py` | 「音频不落盘」静态扫描脚本 |
| 14 | `android/app/src/main/AndroidManifest.xml` | 仅声明 `RECORD_AUDIO`（与 `PLAN-C-01` 共用） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 冻结桥接契约（频道名、方法名、事件字段）对齐 `API-01` | 代码常量文件 | 0.5 h | `API-01` 已冻结 |
| 2 | `RingBuffer` 实现 + 单测 | 交付物 2/7 | 1 h | — |
| 3 | `AudioRecord` 采集与后台线程（FF-01/FF-04） | 交付物 1 | 2 h | 2 |
| 4 | 五态状态机 + 错误码映射 | 交付物 3/6 | 1.5 h | `API-01` §4 |
| 5 | 事件投递、10 Hz/2 Hz 节拍（FF-12）、背压 | 交付物 4/8 | 1.5 h | 3、4 |
| 6 | 握手、`getDiagnostics`、`clearTempAudio` | 交付物 5/9/12 | 1 h | 3 |
| 7 | Dart 侧 Stream 客户端与 mock 通道测试 | 交付物 10/11 | 0.5 h | 5 |
| 8 | 静态扫描脚本 + Manifest 复核 | 交付物 13/14 | 0.5 h | — |

**合计：8.5 h**（含 0.5 h 机动），与 `PLAN-00` §5 的域 P 总工时口径一致。

## 3. 技术方案
**分层**：`AudioBridge`（通道/线程边界）→ `SessionStateMachine` → `AudioCapture` → `RingBuffer` → （P-03 → P-04）。

**关键骨架（≤30 行，仅示意结构，不得作为完整实现）**：
```kotlin
class RingBuffer(val capacity: Int = 65536) {          // FF-09
    private val buf = ShortArray(capacity)
    private var writePos = 0; private var filled = 0
    fun write(src: ShortArray, len: Int) { /* 覆盖最旧 */ }
    fun snapshot(): ShortArray { /* 按时间顺序返回最近 filled 个样本 */ }
    val bufferedSamples get() = filled
}

class SessionStateMachine {
    var state: State = State.IDLE; private set
    fun onStart(sessionId: String): State {                 // 非法 → ACD-SESS-002
        if (state != State.IDLE) throw AcdError("ACD-SESS-002")
        state = State.STARTING; return state
    }
    fun onPause(): State { /* RUNNING 才允许 */ }
    fun onStop(): State { /* RUNNING/PAUSED → IDLE */ }
}
```
**要点**：
1. 采集线程粒度 = FF-04 的 `hop_length`；patch 组装仅为**快照 65536 样本**（FF-09），不含任何 DSP。
2. patch 节拍与 `tStartMs/tEndMs` 由**采集样本计数**换算，不用 `System.currentTimeMillis()` 差值（避免抖动累积）。
3. 暂停时保持 `read()` 与入缓冲，仅关闭 patch 投递（`API-01` §2.4）。
4. 背压只丢最新未确认的 patch 之前的旧 patch，**绝不阻塞采集线程**（`API-00` §3.8）。
5. `sessionId` 一律来自 Dart（`API-00` §3.4），原生不得生成。
6. 停止会话后由 Dart 侧调 `clearTempAudio`（FF-24 §2）；原生只在冷启动时自清一次。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `SessionStateMachineTest.lifecycle_allLegalTransitions` | Kotlin 单测 | `API-01` §4 七条合法迁移全通 | D2 每次提交 |
| `SessionStateMachineTest.lifecycle_illegalTransitions` | Kotlin 单测 | 三条非法迁移返回 `ACD-SESS-002`/`ACD-SESS-002`/`ACD-SESS-001` | D2 每次提交 |
| `RingBufferTest.capacity_isFF09_and_overwritesOldest` | Kotlin 单测 | `capacity == 65536`（FF-09）；溢出后最旧样本被覆盖 | D2 每次提交 |
| `BackpressureTest.dropOldest_whenPreviousUnacked` | Kotlin 单测 | `droppedPatches > 0` 且线程未阻塞、`sessionEnded` 正常 | D2 / D5 |
| `capabilities_handshake_test.dart` | Dart 单测（mock 通道） | **15 字段**全等（`ADR-21`；原 ~~12~~）；不一致抛 `ACD-CFG-001` | D2 / D4 |
| `patch_stream_shape_test.dart` | Dart 单测 | 20 个事件 `mel.length == 128 × 128`、`seq` 严格递增 | D2 起每次回归 |
| `session_summary_test.dart` | Dart 单测 | 字段齐全 + 值域约束 | D2 |
| `clear_temp_audio_test.dart` | Dart 单测 | 结束后 `cacheDir` 中 `audio_*` 数为 0 | D2 / D8（`D-05` 联调） |
| `forbid_audio_write.py` | 静态扫描 | 命中数 == 0 | D2 / D10 冻结前 |
| `aapt dump badging app-release.apk` | 构建产物检查 | 无 `INTERNET`、仅 `RECORD_AUDIO` | D4（`PLAN-C-01`）/ D10 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-01` §7 全部 11 条判据通过（**必需项**）。
- [ ] 交付物 1–14 全部存在且路径与文件名一致。
- [ ] `API-01` §5 一致性测试清单第 1、2、3、6、7、8 项全绿。
- [ ] 真机（`minSdk 24` 及以上，FF-23）连续采集 ≥60 s，`seq` 无跳号、无重复。
- [ ] `getDiagnostics` 的 12 个字段在 `M-04` 面板可显示（与 `PLAN-M-04` 对齐）。
- [ ] Manifest 仅含 `RECORD_AUDIO`；`forbid_audio_write.py` 命中数 0。
- [ ] 无后台常驻 `Service`（代码审查 + `adb shell dumpsys activity services` 断言本应用无 service 记录）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `AudioSource` 选型导致与训练侧不一致 | D3 Mel 对齐或 D3 跨域评估偏差 | 切 `UNPROCESSED`（需机型支持）；不支持则记录机型白名单，写入 SPEC §10 开放问题 |
| 采集线程被系统降频导致丢 patch | `droppedPatches / patchesEmitted > 0.05` | 交由 `PLAN-P-05` 提高推理步长至 1.0 s；本功能不改节拍 |
| 机型权限弹窗行为差异（永久拒绝不返回） | 真机复现 | 统一以 `getDiagnostics.requestAudioPermission` 兜底判定，D9 前锁定机型 |
| 暂停期间缓冲写入与 patch 边界错位 | 恢复后首个 patch 时长 ≠ 4.096 s | 恢复时清空「已发字节」游标并对齐到 hop 边界（FF-04） |
| 工时超支（P-01 与 P-03/P-04 同在 D2） | D2 中午未完成事件投递 | 先把 patch 投递打通（哪怕 Mel 为全 0 占位），Mel 交由 P-04 当日续做 |

## 7. 与检查点的关系
- 本功能是 **CP2（D5 晚：端到端闭环跑通）** 的输入侧第一环，也是 `PLAN-00` §3 关键路径的起点（D0 技能预演即验证「Kotlin 录 4.096 s PCM 并打印 RMS」）。
- D2 当日的硬验收：**Kotlin 输出 `[128, n_frames]` 数组**（`PLAN-00` §1 D2 行；`n_frames = 128`，**已由 `ADR-21`（2026-09-12）修订**：旧值 ~~`n_frames = 129`~~，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`）——该数组由 P-04 产出，但**数据源与节拍由本功能保证**；本功能 D2 未完成则 D3 的 `T-08` 对齐测试无法启动。
- 未完成时的 CP 处置：CP2 未通 → D6 全天扑联调，UI 与报告页砍到最简（`PLAN-00` §2）。
- 本功能属「不可砍」五项之①实时检测闭环，**任何情况下不通过裁剪本功能来腾工时**。

**文档结束**

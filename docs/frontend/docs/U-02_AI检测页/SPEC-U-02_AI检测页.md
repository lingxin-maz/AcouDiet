# SPEC-U-02 AI 检测页

| 项 | 值 |
|---|---|
| 域 | `U` · 界面 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1 §3.4.2 §3.6 §8.2.1 §9；`docs/00_功能清单与数量分析.md` §2 域 U / §3 / §6；`SPEC-00` §3.1 FF-09/FF-12、§3.4 FF-20、§3.6 FF-21、§3.9 FF-24、§3.10 FF-25 |
| 依赖的 SPEC | `SPEC-U-06`、`SPEC-P-01`、`SPEC-P-06`、`SPEC-P-07`、`SPEC-P-08`、`API-01` |

## 1. 目标与范围
### 1.1 一句话目标
现场最核心的演示页面：用户点一次「开始检测」，页面用声波动画与灰色实时预测表示「正在感知」，在**约 4–5 秒**后给出确认结果卡片，随后展示当次行为指标并提示已自动生成记录。

### 1.2 范围内（In Scope）
| # | 元素 | 说明 |
|---|---|---|
| 1 | 「开始检测 / 停止检测」主控按钮 | 会话唯一入口；**检测由用户发起**（FF-24 第 6 条） |
| 2 | 实时波形动画 | 由 `level` 事件 `rms` 驱动（`API-01` §3.2）；**纯视觉，不参与任何判定** |
| 3 | 状态文案 | `等待进食声…` / `正在感知进食声音…` / `已结束` |
| 4 | 未确认实时预测（灰色） | 单 patch 的 `top1 + confidence`，视觉上明确「未确认」 |
| 5 | 确认结果卡片 | Level 2 的 `top1 + confidence + attribute` |
| 6 | 低置信度二选一确认 | 0.45 ≤ p < 0.70 → 「疑似 X，请确认？」是 / 否 |
| 7 | 行为指标区 | `chewCount` / `avgChewIntervalSeconds` / `durationSeconds` / `speedGrade` |
| 8 | 自动生成记录提示 + 权限流程 + 示例演示标识 + 静默结束提示 | 确认后「已自动记录」；`ACD-PERM-*` 分支；`source = "inject"` 标「示例演示」；90 s 静默结束（FF-21a） |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
- **不做**「识别历史」列表（`X-05`；`3.png` / `10.png` 的该模块整体删除，不得实现）。
- **不做**任意改类别、删除误报（`X-02`）；v1.0 的「手动修正」**仅指二选一确认**。
- **不做**营养素、热量目标、重量估计的任何展示。
- **不做**后台常驻监听、锁屏检测、自动启动检测（FF-24 第 6 条）；**不做**多会话并发（`maxConcurrentSessions = 1`）。
- **不做**在 Dart 侧做 Mel 计算或推理调度以外的信号处理（`API-00` §1）。

## 2. 功能行为
### 2.1 触发与前置条件
- 触发：首页「开始 AI 检测」按钮，或底栏「检测」Tab。
- 前置 1：启动握手已通过（`API-00` §3.6）；不通过 → **禁止进入本页**（`ACD-CFG-001`）。
- 前置 2：`RECORD_AUDIO` 已授权；未授权先申请（`ACD-PERM-001/002`）。前置 3：无活跃会话。
- 数据取出：`detectSessionProvider`、`predictionProvider`、`decisionProvider`（`AggregatedDecision`）、`behaviorProvider`。

### 2.2 主流程（编号步骤）
1. 点「开始检测」→ Dart 生成 `sessionId`（`API-00` §3.4）→ `startSession`。
2. 原生进入 `RUNNING`；波形起动，文案 `等待进食声…`。
3. `level` 事件（10 Hz）驱动波形；**静默时为水平基线**。
4. `patch` 事件（2 Hz）→ 推理 → 聚合（`P-06`）→ 显示**灰色**未确认预测 `薯片 62%`；无预测可显示时显示 `正在感知…`。
5. Level 2 判据满足（Top-1 连续 M 个 patch 不变且 EMA 概率 ≥ τ_confirm，FF-20）→ 显示确认结果卡片 `薯片 / 91% / 脆性高加工零食`。
6. **首次确认结果耗时 ≈ 4–5 秒**：由窗口长度 4.096 s（FF-09）+ 稳定判据 2.0 s（FF-20 Level 2）共同决定，且与窗口滑动并行；**这是物理必然结果，不是缺陷、不是卡顿、不需要「优化」**。
7. 确认后落库（`D-01`/`D-02`，一个事务）→ 提示「已自动记录」并附条目摘要（可跳 `U-03` 详情）。
8. 进入 Level 3（0.45 ≤ p < 0.70）→ 二选一确认「疑似 X，请确认？」`是` / `否`；`是` → 按该类别落库并置 `correctedByUser = true`；`否` → 不写日志，回采集中。p < 0.45 → `未识别到明确食物`，不写日志。
9. **同级静默窗口（FF-20d，`ADR-47`）**：答完「是 / 否」后，**同一类别**在此次检测的三分钟内不再出现确认弹层 —— 这是用户实测缺陷「点完否，同一句一秒钟后又问一遍」的修法（`SPEC-P-06` §2.2 步骤 11 的界面侧）。具体表现：
   - 两个按钮**在点击的那一帧就消失**（`DetectNotifier` 用会话答复后的 `AggregatedDecision` 重新投影卡片，不再等下一个 patch）；
   - 点「否」→ 卡片回到「正在感知…」中性态，**不再显示该类别名称、置信度与弹层**；点「是」→ 卡片保持该类别已确认态，弹层消失；
   - 三分钟内该类别不再弹层；**其他类别不受影响**，照常弹层；
   - 三分钟后证据可以重新赢得提问权（不是永久静音）；**重开一次检测立即解除**。
9. 点「停止检测」→ `stopSession` → `SessionSummary` → `P-07` 计算行为指标 → 指标区刷新；90 s 静默则由原生自动结束并回填同样流程。
10. 会话结束 → `clearTempAudio`（FF-24 第 2 条）。

### 2.3 状态与状态迁移
```dart
enum DetectUiState { idle, requestingPermission, starting, listening, unconfirmed, confirmed, askingUser, ending, ended, error }
```
| 当前态 | 事件 | 下一态 | 说明 |
|---|---|---|---|
| `idle` | 点开始 | `requestingPermission` → `starting` | 永久拒绝 → `error`（`ACD-PERM-002`，显示「去设置」） |
| `starting` | `startSession` 成功 | `listening` | 失败 → `error`（`ACD-AUD-001/002`） |
| `listening` | 首个可用 patch 预测 | `unconfirmed` | `stage == observing` |
| `unconfirmed` | Level 2 满足 | `confirmed` | 显示结果卡片（`stage == confirmed`） |
| `unconfirmed` | 进入 `[0.45, 0.70)` | `askingUser` | `AggregatedDecision.shouldAskUser == true` |
| `askingUser` | 「是」/「否」 | `unconfirmed` | 「是」落库且 `correctedByUser = true`；「否」不写日志且同类别不再重复追问。**两个按钮在下一次 patch 之前就已消失**（答复同步生效，`ADR-47`） |
| `confirmed` | 新 patch Top-1 变化 | `unconfirmed` | 结果卡片**保持上一态**直到新确认 |
| 任意运行态 | 停止 / 90 s 静默 | `ending` → `ended` | `ending` 期间禁止重复 `stopSession`；`ended` 后可「再次检测」（新 `sessionId`） |
| 任意态 | `sessionEnded(reason=error)` | `error` | 按 `code` 映射文案（`API-00` §3.5） |

### 2.4 边界条件
- 连续吃 30 s 内结果**不得闪烁**（`PLAN-00` D6 硬验收）；未确认预测刷新频率上限 2 Hz。
- 确认后置信度下降：结果卡片**保持上一确认态**，不回退为空。
- `p` 恰为 0.45 / 0.70：按 FF-20 判定（0.70 属确认，0.45 属询问），边界须有单测。
- **「否」之后紧接第二次点击**：按钮在点击的同一帧消失，因此第二次点击**不可能**发生；即使发生（自动化点击、无障碍服务重复触发），会话层也只会报 `ACD-SESS-002`，页面不得进入 `error` 态而无提示。
- **静默窗口内用户改主意**：窗口只有 180 s 且不跨会话，`stop()` 后重新开始检测即可立即恢复提问权（`ADR-47`）。
- 关屏 / 切后台：会话停止或暂停，**不得后台常驻**；返回显示 `已结束`。
- **会话边界必须清空展示状态（`ADR-49`）**：`heldConfirmed` / 当前预测 / 行为读数 /「已自动记录」横幅都是**一次检测**的展示状态，**不得跨会话继承**。第二次检测的第一帧必须是中性态（不得显示上一轮的确认卡片），也不得继续挂着上一轮的「已自动记录」横幅。测试：`flutter test test/ui/detect_confirmation_round_test.dart`。
- **「结果卡片保持上一态」只在会话内成立**：`stop()` 之后 `ended` 页面**保留**本轮结果与横幅（会话小结，`ADR-46`）；**同一轮内**旧确认卡片在拿到新确认前继续占位（§2.3 冻结判据）。这两条都**不是**跨会话继承，不得混为一谈。
- 麦克风被抢占：`ACD-AUD-002` → `error` 态 + 提示关闭其他录音 App。
- `chewCount` 为 `null`：显示 `--`；MAE 超线按 FF-21g 降级为「咀嚼节奏：较快」，不给绝对数字。
- 波形事件中断 > 2 s：静默态水平基线，不残留上一会话波形。
- 注入模式（Demo B）：显示「示例演示」标识，节奏按实时喂入（`API-01` §2.6）。

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 页 → L1 | `audio.requestPermission()` | `{}` | `{granted, permanentlyDenied}` | 无（拒绝是返回值） |
| 页 → L1 | `audio.getCapabilities()` | `{}` | `NativeCapabilities` | 无（永不失败） |
| 页 → L1 | `audio.startSession()` | `{sessionId, enableDenoise:false, autoEndOnSilence:true, silenceEndSeconds:90}` | `{sessionId, startedAtMs, appliedConfig}` | `ACD-PERM-*` `ACD-SESS-002` `ACD-AUD-*` |
| 页 → L1 | `audio.stopSession()` / `audio.clearTempAudio()` | `{sessionId}` / `{}` | `SessionSummary` / 清理计数 | `ACD-SESS-001`（清理无错误码） |
| 页 → L1 | `audio.ackPatch()` | `{sessionId, seq}` | `{ok}` | 无 |
| L1 → 页 | `EventChannel('…/audio_stream')` | — | `level` / `patch` / `sessionEnded` | — |
| 页 ← 域层 | `InferenceEngine.run(Float32List mel, {required int nFrames})`（`API-02` §3） | `mel` 长度 `nMels × nFrames` = `128 × 128`（`n_frames = 128`，`ADR-21`；旧口径 ~~`128 × 129`~~） | `InferenceResult`（`classId` / `label` / `confidence`） | `ACD-INF-*` |
| 页 ← 域层 | `VoteAggregator.add(InferenceResult r, {required int seq, required bool voiced})`（`API-02` §4） | 单 patch 推理结果 + `seq` + VAD 标志 | `AggregatedDecision` | 无 |
| 页 ← 域层 | `BehaviorAnalyzer.feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs})` / `finish({required int endMs})`（`API-02` §5） | 原生算好的 RMS 包络（**819 点**，帧长 10 ms / hop 5 ms，见 FF-21h）/ 会话结束时刻 | `BehaviorMetrics?` | `ACD-BEH-001`（包络缺失或长度不符） |
| 页 ← `P-08` | `FoodKnowledgeBase.byClassId(int)`（`API-02` §6） | `classId ∈ [0,6)` | `FoodInfo`（**非空**） | `ACD-KB-001`（越界） |
| 页 → `D-02` | `DietRepo.insertSession({required DietRecord record, required BehaviorMetrics? metrics})`（`API-03` §4） | 记录 + 指标（可空，空则写占位行） | `Future<void>`（单事务） | `ACD-DB-001` / `ACD-DB-002` |

## 4. 数据契约
> 本表与**主方案 §3.4.1 UI 数据契约表**逐行一致；**表外字段不得出现在本页任何位置**（风险 R-19）。

| 展示元素 | 数据源 | 字段 | 单位/格式 | 无数据时 |
|---|---|---|---|---|
| 实时波形动画 | 环形缓冲 RMS（`level` 事件） | — | 纯视觉 | 静默态 |
| 当前预测（未确认） | 推理引擎单 patch | `top1 + confidence` | `薯片 62%` 灰色 | `正在感知…` |
| 确认结果卡片 | `P-06` Level 2 | `top1 + confidence + attribute` | `薯片 / 91% / 脆性高加工零食` | 保持上一态 |
| 行为指标 | `P-07` | `chewCount, avgChewIntervalSeconds, durationSeconds, speedGrade` | `约 45 次 / 0.7 秒 / 4 分 23 秒 / 偏快` | `--` |

**落地映射（不改契约）**：「当前预测」绑定 `InferenceResult`（单 patch）；「确认结果」绑定 `AggregatedDecision`（`stage == confirmed` 时的 `classId` / `label` / `smoothedConfidence`）再经知识库取 `FoodInfo.attribute`；「行为指标」绑定 `BehaviorMetrics` 四字段（合并展示，`null` 一律 `--`）；**「示例演示」标识的唯一触发依据是 `patch.source == "inject"`**（`API-01` §3.2、`SPEC-M-02` §4），`DietRecord.source` 只有 `real` / `demo` 两值（`SPEC-D-01` §3 `CHECK`），二者不得混用；`DietRecord.correctedByUser` 用于二选一确认标记。

## 5. 参数与常量
- patch 采样数与窗长：`SPEC-00` §3.1 **FF-09**（`65536` 样本 = 4.096 s）；滑窗步长：**FF-12**（0.5 s，每秒 2 个 patch）。
- 三级阈值与首次确认耗时：`SPEC-00` §3.4 **FF-20** / **FF-20a**（首次确认 ≈ 4–5 s）/ **FF-20b**（D3 标定）/ **FF-20c**（跨 patch 保持状态）。
- 二选一确认的静默窗口：`SPEC-00` §3.4 **FF-20d**（`voting.confirmation_mute_seconds` = 180 s）；呈现细节见 `ADR-47`，实现归属见 `SPEC-P-06` §2.2 步骤 11（**界面不得自己实现去重，也不得硬编码 180**）。
- 会话结束与行为指标：`SPEC-00` §3.6 **FF-21a** / **FF-21e** / **FF-21f** / **FF-21g**。
- 类别集合：`SPEC-00` §3.3 **FF-19**；委托回退：`SPEC-00` §3.2 **FF-18**（NNAPI 失败静默回退 CPU，**不向 UI 抛错**）。
- 隐私：`SPEC-00` §3.9 **FF-24**；文案红线：`SPEC-00` §3.10 **FF-25**。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 权限被拒 / 永久拒绝 | `granted` / `permanentlyDenied` | 允许重试申请；永久拒绝不重复弹框 | 「需要麦克风权限才能检测」+「授权」/「去设置」 |
| 配置不匹配 | 握手逐字段比对不符 | **禁止进入本页** | `ACD-CFG-001` 文案，无「开始」按钮（fail fast） |
| `AudioRecord` 初始化失败 | `ACD-AUD-001` | 自动重试 1 次（间隔 300 ms） | 仍失败 →「麦克风初始化失败，请重试」 |
| 麦克风被占用 | `ACD-AUD-002` | 不重试 | 「麦克风被其他应用占用，请先关闭录音类应用」 |
| Mel 帧数不符 | `ACD-MEL-001` | 终止会话并上报 | 「特征计算异常，会话已停止」（不重试） |
| 模型加载失败 | `ACD-INF-001` | 重试 1 次重建 `Interpreter` | 仍失败 → 错误态 + 提示重开 App |
| 委托初始化失败 | `ACD-INF-003` | **静默回退 CPU** | 无任何提示（预期行为） |
| 推理过慢丢 patch | `droppedPatches / patchesEmitted > 0.05` | 提高推理步长到 1.0 s（`PLAN-P-05`） | 无提示，仅日志与自检面板 |
| 数据库写入失败 | `ACD-DB-*` | 重试 1 次；仍失败内存暂存 | 「记录暂存中，稍后重试」——**绝不静默丢记录** |
| 临时文件清理失败 | `ACD-IO-001` | 不重试，仅记日志 | 无提示；计入 `M-04` 自检面板 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 检测页 widget test 全通过 | `flutter test test/widget/detect_page_test.dart` | 退出码 0 |
| 2 | 状态机迁移完整 | `test('detect state machine idle→listening→unconfirmed→confirmed→ended')` | 合法迁移可达；非法迁移报 `ACD-SESS-002` 文案 |
| 3 | 未确认预测灰色且带 `%` | `test('unconfirmed prediction chip renders grey with percent')` | 文本匹配 `^\S+ \d+%$` |
| 4 | 确认卡片三要素 | `test('confirmed card shows label/confidence/attribute')` | 含 `label`、`\d+%`、`attribute` 三段 |
| 5 | 二选一确认边界 | `test('askUser shown only in [0.45,0.70)')` | 0.45/0.699 显示；0.70/0.449 不显示 |
| 6 | 结果不闪烁 | `test('confirmed card keeps previous state on lower confidence')` | 30 次 patch 输入下卡片文本变化 == 0 |
| 7 | 行为指标空值 | `test('null behavior metrics render -- not 0')` | `--` 次数 == null 字段数，无 `0 次` |
| 8 | 首次确认耗时口径 | `test('first confirmation latency within 4–5 s window')` + 真机实测记录 | 实测落在 FF-20a 区间，测试报告含实测值 |
| 9 | 连续吃 30 s 稳定性 | 真机手测（`PLAN-00` D6 硬验收） | 结果卡片稳定不闪烁 |
| 10 | 禁止实现项零命中 | `rg -n "识别历史\|2 秒\|两秒\|实时即刻" lib/presentation/pages/detect/` | 命中数 == 0 |
| 11 | 无网络依赖 / 无表外字段 | `rg -n "http\|dio\|蛋白质\|脂肪\|碳水化合物\|膳食纤维\|重量" lib/presentation/pages/detect/` | 命中数 == 0 |
| 12 | 同级静默窗口（FF-20d）的界面表现 | `flutter test test/domain/confirmation_mute_test.dart` 的 `点「否」之后，同一次检测的三分钟内不再出现该判断结果`；按钮消失链路由 `test/ui/detect_session_recovery_test.dart` + `tool/ui_presenter_tests.dart` 覆盖 | 答复返回后 `shouldAskUser == false`（无需等下一个 patch）；`T+179999 ms` 无弹层、`T+180000 ms` 恢复；「否」后 `classId == null` |
| 13 | 检测页不得自己实现去重、不得硬编码窗口 | `rg -n "\b180\b\|confirmation_mute\|votingConfirmationMuteSeconds\|muteWindow" lib/presentation/` | 命中数 == 0（实测 2026-09-15：0）。静默只在 `DetectionSession`，页面**只**消费 `shouldAskUser`：`detect_page.dart` 的 `if (view.shouldAskUser)` |
| 14 | 展示状态不得跨会话继承（`ADR-49`） | `flutter test test/ui/detect_confirmation_round_test.dart` | 点「是」→ 停止 → 再次开始：第一帧 `prediction.confirmed == false`、文案不等于上一轮；`savedRecord` 由 `isNotNull` 变 `isNull`；新一轮 `uiState != ended` |
| 12 | 视觉与文案人工核对 | 见下表逐项核对表 | 全部 ✓ |

**人工核对表（检测页，9 项）**

| # | 核对项 | 期望 |
|---|---|---|
| 1 | 波形动画 | `10.png` 的圆形声波保留；静默时为水平基线 |
| 2 | 状态文案 | 含「感知/采集」语义，且不含任何绝对化速度承诺 |
| 3 | 未确认预测 | 灰色、标注「未确认」语义，与确认卡片视觉可区分 |
| 4 | 确认卡片 | `薯片 / 91% / 脆性高加工零食` 三要素齐全，属性来自知识库 |
| 5 | 识别历史模块 | **必须不存在**（`X-05`；`3.png`/`10.png` 的该模块删除，数值错位无需修正） |
| 6 | 二选一弹层 | 「疑似 X，请确认？」+「是」/「否」两个按钮，无第三个选项 |
| 7 | 行为指标 | `约 45 次 / 0.7 秒 / 4 分 23 秒 / 偏快` 格式；咀嚼次数带「约」 |
| 8 | 自动记录提示 | 出现「已自动记录」并附条目摘要，可跳详情 |
| 9 | 品牌与红线 | 标题 `AcouDiet` / `声膳`；无「2 秒内出结果」「准确识别所有食物」等 FF-25 禁用表述 |

## 8. 非功能约束
**内容硬规则（三条，与主方案 §3.4.1 一致）**
1. 热量数字**必须带份量描述与「估算」字样**；本篇如出现 kcal（自动记录摘要）不得是孤立数字。
2. 食物粒度**必须落在 6 类内**（`chips/cabbage/gummies/noodles/carrot/drink`）；禁止「全麦面条」「纯牛奶」「番茄」「鸡翅」等超出识别粒度的命名（ADR-19 起「面条」本身是正式类别，不再是禁用词）。
3. **无法从模型推导的营养素（蛋白质/脂肪/碳水化合物/膳食纤维）一律不得出现在 UI 上**。

| 类别 | 约束 |
|---|---|
| 响应 | 未确认预测刷新上限 2 Hz；确认后不得高频重绘；波形 60 fps |
| 延迟口径 | **首次确认 ≈ 4–5 s，由窗口 4.096 s + 稳定判据 2.0 s 决定，与窗口滑动并行；这是 FF-20a 的必然结果，不是缺陷**。UI 不得出现「秒出结果」类承诺 |
| 功耗 | 会话仅在用户主动发起期间运行；无后台 Service（FF-24 第 6 条） |
| 隐私 | 音频只在内存环形缓冲、不落盘；不申请 `INTERNET`；会话结束强制清理 `cacheDir/audio_*`（FF-24 第 1/2/4 条） |
| 无障碍 | 「开始/停止检测」语义含状态（如「开始检测，当前已停止」）；波形语义为「正在采集进食声音」且不播报数值；确认卡片语义形如「确认结果 薯片，置信度 91%，脆性高加工零食」；二选一弹层焦点顺序「是」→「否」；不用颜色单独表达置信度 |
| 安全 | 断网 / 飞行模式下全流程可用（`API-05` §12 判据 2） |

## 9. 裁剪与未做
- 🔴 **本功能不可裁剪**：实时检测闭环是主方案 §8.2.1 **五项不可砍之一**（第①项）。任何「砍掉实时检测只演示报告页」的提议必须先按 `PLAN-00` §6 等额删除一项并签字确认。
- 🔴 **禁止实现「2 秒内出结果」的宣传或 UI 承诺**（FF-20a）；任何暗示更快结果的倒计时 / 进度条同样禁止。
- `X-02` 手动修正：**降级为二选一确认**（`P-06` Level 3 承接）；**不做**任意改类别、不做删除误报。
- `X-05` 检测页识别历史列表：**不做**（`3.png` / `10.png` 该模块整体删除，**无需修正数值错位，也不许实现**）。
- `X-07` 咀嚼节律 σ：**不做**（行为指标只有次数/间隔/时长/速度四项）；`X-03` CSV 导出：**不做**。
- 后台常驻监听 / 自动开始检测：**不做**（FF-24 第 6 条）。

## 10. 开放问题
1. ✅ **已关闭（依据 ADR-12）**：底栏 **4 Tab = 首页 / 检测 / 记录 / 报告**（本页为「检测」Tab）；「**我的**」放**首页右上角入口，不做独立 Tab**（`FF-23`）；自检面板（`M-04`）同样**不得成为第 5 个页面**，须挂在现有页面或设置入口下（`SPEC-M-04` §10）。
2. **未确认预测的展示位置**：`10.png` 只有一张确认卡片；未确认态是否需独立卡片位（本 SPEC 采用同一卡片位的灰色态），需 UI 确认。
3. **二选一弹层是否超时自动按「否」**：本 SPEC 不设超时（需用户明确选择）；现场演示节奏是否可接受需确认。
4. ✅ **已关闭（依据 `ADR-P1`；后经 `ADR-21`（2026-09-12）修订）** 原开放问题「FF-11（`n_frames` 128/129）未拍板」。**结论（`ADR-P1`，2026-09-10）**：已选定选项 B，保留 4.096 s 窗口；**张量宽度已由 `ADR-21` 修订为 `n_frames = 128`（输入 `[1, 128, 128, 1]`）**，原 ~~`n_frames = 129` / `[1, 128, 129, 1]`~~ 作废，`129` 现为 `raw_mel_frames`；**选项 A（128 / 4.064 s / 65024 样本）仍未采纳**。因此窗长不变，**FF-20a 的「约 4–5 秒」措辞无需复核**（见 `SPEC-00` §3.5 FF-11）。

**文档结束**

# 01 裁定记录（ADR）：跨文档冲突与设计缺陷

**日期**：2026-09-10 ｜ **上游**：`common/SPEC-00_总则与冻结事实.md`、`common/PLAN-00_总排期与依赖.md`
**性质**：本文件是 **40 份 SPEC + 40 份 PLAN + 7 份接口契约并行编写后的交叉评审产物**（**`ADR-44` 之前的规模**；现行文档集为 **45 份 SPEC + 45 份 PLAN + 8 份接口契约**，新增的是 `G-01`~`G-03`、`U-07`、`C-06` 与 `API-07`。本句刻意保留原数字，因为第 1–43 条裁定**确实是**在那 80 份文档上做的交叉评审 —— 改掉它会让下面「只有把 40 份并排比对才会暴露」这句话失去所指）。
**注**：文档集已于 v1.1 按 **前端 / 后端 / 跨端公共** 重组（每个功能一个文件夹）；本文件中的功能一律**按编号引用**（如 `SPEC-P-07`、`PLAN-D-03`），因此不受目录调整影响。

---

## 1. 为什么需要这份文件

40 个功能规格 + 7 份接口契约是**并行编写**的。任何并行编写的规格集都会产生三类问题：

| 类型 | 表现 | 后果 |
|---|---|---|
| **接口缺口** | A 的规格需要一个方法，B 的契约里没有 | 实现到一半发现「拿不到数据」 |
| **口径冲突** | 两份文档对同一个量给了不同定义 | 两侧各按自己那份写，联调时数字对不上 |
| **设计缺陷** | 契约自洽，但推导出的产品行为是错的 | 评分维度失效、保命方案失效这类 |

**这三类问题都不会在单份文档里露出来** —— 只有把 40 份并排比对才会暴露。本文件的价值就在这里。

**扫描方式**：`python _toolchain/verify_docs.py`（结构 / 数值漂移 / 文案红线 / 交叉引用）+ 人工逐域交叉比对。

---

## 2. 状态定义

| 状态 | 含义 |
|---|---|
| ✅ **已裁定** | 已做出决定**并已写入权威文档**，实现方按权威文档执行即可 |
| 🟡 **已裁定，待同步** | 决定已做出，但仍有个别下游文档需要跟着改（改动点已逐条列出） |
| 🔴 **待拍板** | **必须由人决定**，不能在文档里解决（缺少的是业务判断或数据） |

---

## 2.1 阻断级 6 条的复核签字（2026-09-10）

> **为什么需要这一节**：§3 的 13 条裁定里有 **6 条是架构层面的取舍**——它们不是"文档写错了"这种有唯一正确答案的问题，而是**在若干可行方案之间做选择**（例如包络算在原生还是 Dart、保命模式要不要改契约、评分以公式还是散文为准）。这类裁定**由文档编写者单方面做了决定**，虽然已写进权威文档，但决策权本应属于项目。
>
> 因此这 6 条被单独抽出，逐条提请拍板。**结论：全部采纳原裁定**，即 §3 的写法**保持不变**。

| ADR | 议题 | 复核结论 | 裁定后果落在哪 |
|---|---|---|---|
| **ADR-01** | `P-07` 行为分析无数据源 | **采纳**：原生算 RMS 包络随 `patch` 事件下发（hop 5 ms，+3.3 KB/事件），峰值检测与阈值留在 Dart | `SPEC-00` FF-21h/FF-21i、`API-01` §2.3/§3.2/§7 |
| **ADR-02** | Demo Mode B 在麦克风故障时失效 | **采纳**：`startSession` 新增 `skipAudioRecord`，注入会话不打开 `AudioRecord`、不请求权限；`micInUse` 返回 `null` 而非 `false` | `API-01` §2.3/§2.8 |
| **ADR-06** | 四处「无数据源」 | **采纳**：纯新增 5 个方法（`metricsByRecordId` / `summary` / `chewStats` / `mealTimeSamples` / `activeDays`），不改任何既有签名；`PLAN-D-03` 工时 8 h → 11–12 h | `API-03` §4/§5/§11.1 |
| **ADR-05** | FF-22 评分公式与端点描述矛盾 | **采纳**：以公式为准（σ=30 → 20 分），散文表述作废；端点统一为 σ=0→30 / 30→20 / 60→10 / ≥90→0 | `SPEC-00` §3.7、`SPEC-A-01` |
| **ADR-09** | 餐次窗口使 `snack` 维度失效 | **采纳**：窗口改为 早`[05,10)` / 午`[11,14)` / 晚`[17,21)`，晚间 `[20:00,05:00)`；零食与晚间刻意允许重叠 | `API-03` §5（权威）、`SPEC-D-03` §4.1 |
| **ADR-07** | Schema 把未决项写成 `const: 129` | **采纳**：两处改为 `enum: [128, 129]`，拍板后再改回 `const <选定值>`。**注意：这条不解决 `n_frames` 本身**——它只是让两种选项都能通过校验，拍板仍是 `ADR-P1` | `docs/common/docs_api/schemas/feature_config.schema.json`、`metrics.schema.json` |

**复核后仍然开放的事项**：`ADR-P1`（`n_frames` 129/128）、`ADR-P2`（`grade` 阈值）、`ADR-P3`（`feature_config` 补全）、`ADR-P4`（数据可携带性）、`ADR-P5`（范围冻结签字）、`ADR-P6`（`confirmedByUser` 展示边界）—— 见 §4。

> ⚠️ **ADR-07 容易被误读**：Schema 改成 `enum` **不等于**已经拍了 129。`n_frames` 依然是未决项，`ADR-P1` 依然卡在 D2 训练前。改 `enum` 只是让"还没拍板"这件事在机器校验层面也成立。

**签字**：复核人 __________ ｜ 日期 2026-09-10 ｜ 范围：§2.1 表内 6 条

---

## 3. ✅ 已裁定（已写入权威文档）

> §2.1 的 6 条已复核签字，**结论均为采纳**；其余 7 条为文档一致性问题（有唯一正确答案），无需拍板。

### ADR-01 🔴→✅ 🖊️已复核 `SPEC-P-07` 行为分析**没有数据源**

| 项 | 内容 |
|---|---|
| 发现方 | `API-02` 与 `SPEC-P-07` 交叉比对 |
| 问题 | `BehaviorAnalyzer` 的算法需要**时域信息**（短时 RMS 包络），但 `API-01` 的 `patch` 事件只携带 `mel` / `rms` / `voiced`，**没有任何逐帧时域量**。结果：`P-07` 无从计算，`PLAN-00` D7 的硬验收「能输出约 45 次，偏快」**无法达成**。 |
| 三个候选 | A. 事件附带原始 PCM16（+131 KB/事件，通道带宽约 3 倍）｜B. 事件附带原生算好的 RMS 包络（+3.3 KB/事件）｜C. 原生直接出咀嚼峰值候选 |
| 裁定 | **采用 B**。新增 `FF-21h` / `FF-21i`；`patch` 事件新增 `rmsEnvelope`（`Float32List`，长度 819，hop 5 ms）与 `envelopeHopMs`；`startSession` 新增 `includeEnvelope`。 |
| 理由 | ① 与主方案 §3.3「DSP 下沉原生，只把算好的数组传 Flutter」**自身已冻结的原则**一致 ② 带宽仅增加 5% ③ 复用 `P-02` 的 VAD 分帧，增量成本近零 ④ 需要现场调参的峰值检测/阈值/伪峰过滤**留在 Dart**。否决 C 的理由：FF-21b/21c/21d 在 D7 现场必然要调，放 Kotlin 意味着每次调参重编译 APK。 |
| 已写入 | `SPEC-00` §3.6（FF-21h/21i）、`API-01` §3.2 + **§7 完整 ADR** |
| 🟡 待同步 | `SPEC-P-02`（产出方，须共用分帧实现）、`SPEC-P-07`（消费方，签名由 `feedPatch(pcm)` 改为 `feedEnvelope`）、`SPEC-M-02`（注入路径也必须产出包络）、`API-02`（`BehaviorAnalyzer` 签名） |

### ADR-02 🔴→✅ 🖊️已复核 Demo Mode B 恰在设备故障时失效

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-M-02` / `SPEC-M-04` 交叉比对 |
| 问题 | `injectPcm` 必须先有 `sessionId` → 必须 `startSession` → 必然初始化 `AudioRecord` → **麦克风被占用或硬件故障时返回 `ACD-AUD-002`/`ACD-AUD-001`**。于是**恰恰在设备出问题时，作为保命方案的 Mode B 也起不来**。Mode B 存在的全部意义就是"现场出问题时还能演"。 |
| 裁定 | `startSession` 新增 **`skipAudioRecord`**（默认 `false`）：不打开 `AudioRecord`，只创建环形缓冲与事件发射器，仅接受 `injectPcm`；不请求 `RECORD_AUDIO`；出参 `audioRecordActive=false`。 |
| 关键细节 | `getDiagnostics().micInUse` 在该模式下返回 `null` 而**不是 `false`** —— 否则会被误读为"麦克风可用"。新增 `micInUseKnown` 布尔量显式区分「不可用」与「未启用」。 |
| 现场口径 | 噪声大（>65 dB）→ Mode B（麦克风可用）｜麦克风被占用/故障/权限永久拒绝 → Mode B + `skipAudioRecord` ｜模型加载失败 → Mode C（Mode B 同样依赖推理） |
| 已写入 | `API-01` §2.3、§2.8 |
| 🟡 待同步 | `SPEC-M-04` §4.2 的现场处置表、`SPEC-M-02` 的启动前置条件 |

### ADR-03 🔴→✅ `getDiagnostics()` 无法支撑自检第 3 项

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-M-04` |
| 问题 | 自检要求回显「当前生效的模型版本与 `n_frames`」，但 `getDiagnostics()` 不返回这两个值；且**原生侧不加载模型**（推理在 Dart），原生根本无法自行得知。 |
| 裁定 | ① `getDiagnostics()` 新增 `modelVersion` / `modelNFrames`（默认 `null`）② 新增 `setDiagnosticsModelInfo({version, nFrames})`，由 Dart 在 `InferenceEngine.load()` 成功后回填 ③ **明确禁止**为了填这两个字段而让原生加载模型（会把推理分裂成两份）。 |
| 已写入 | `API-01` §2.8 |
| 🟡 待同步 | `SPEC-M-04` §4.2 第 3 项的数据来源说明 |

### ADR-04 🟡→✅ 自检项数 9 vs 14

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-M-04` |
| 问题 | `API-04` §7.1 冻结「`items` 恰好 9 项」，但其单测又写「返回 9 项」；而主方案 §9 的现场降级判据需要「会话状态 / 模型版本与 `n_frames` / 丢帧比例 / 演示数据就绪」四类信息，9 项覆盖不到。 |
| 裁定 | **扩为 14 项**：保留原 9 项**同名同序**，追加 `session` / `modelInfo` / `envelope` / `dropRate` / `demoData`。 |
| 理由 | 这 5 项不是可选扩展 —— `SPEC-M-04` 的现场 SOP 依赖它们区分「麦克风问题」与「模型问题」。原 9 项里第 3 项只判「模型能否用」，与「用的是哪个模型、输入形状对不对」是两件事，失败时的现场动作也不同（前者切 Mode C，后者禁止演示）。 |
| 已写入 | `API-04` §7.1（含 6 条新单测要点） |
| 🟡 待同步 | `SPEC-M-04` §4.2 按 14 项对齐 |

### ADR-05 🔴→✅ 🖊️已复核 FF-22 评分卡自相矛盾

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-A-01` |
| 问题 | 主方案 §3.8 的**同一格**里既写公式 `regularity = 30 × max(0, 1 − σ/90min)`，又写散文「σ≤30min 满分」。该公式在 σ=30 时给出 `30 × (1 − 1/3) = 20` 分 —— **与「满分」直接矛盾**。 |
| 裁定 | **以公式为准，散文作废。** 端点统一为 `σ=0→30`、`σ=30→20`、`σ=60→10`、`σ≥90→0`（连续线性衰减，无平台段）。 |
| 理由 | 公式是精确、可机器判定的工件；散文是它的不准确摘要。**只改摘要不改公式**，没有引入任何新公式。 |
| 已写入 | `SPEC-00` §3.7 | 
| 🟡 待同步 | `SPEC-A-01` 的算例期望值（σ=30 应为 20 而非 30）、`PLAN-C-05` 的 `health_score_consistency_test.dart` 断言 |

### ADR-06 🔴→✅ 🖊️已复核 四处「无数据源」缺口

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-A-01`、`SPEC-A-03`、`SPEC-U-03`、`SPEC-U-05` |
| 问题 | ① `A-01` 的 `speed` 维需要**平均咀嚼间隔**，`StatsRepo` 无此聚合 ② `A-03` 的环比需要**上一个等长窗口**，但 `week()` **无参数**，推不出来 ③ `A-01` 的 `regularity.evidence` 需要原始样本 ④ `U-03` 详情页需要**按记录取指标**，而 `MetricsDao.selectByRecordId` 属 L3 内部（`U-*` 不得引用）⑤ `U-05` 的「已坚持 N 天」无来源。 |
| 裁定 | **修订 A-1（纯新增，不改任何既有签名）**：`DietRepo` + `metricsByRecordId`；`StatsRepo` + `summary(DateRange)` / `chewStats(DateRange)` / `mealTimeSamples(DateRange)` / `activeDays()`；新增 `ChewStats`。`week()` 定义收敛为 `summary(本周窗口)` 的便捷包装（保签名不变，补一条等价性断言）。 |
| 为什么不"用既有方法凑" | 「上一等长窗口」需要参数化窗口；「按记录取指标」需要 `recordId` 精确匹配，`byRange` 按时间窗模糊取会出现同分钟多条记录的歧义。两者都是**接口能力缺失**，不是调用方式问题。 |
| 工时 | `PLAN-D-03` 由 **5 h** 调整为 **11–12 h**（📌 勘误：本节原写「由 8 h」，经核对原工时是 5 h；冻结目标值 11–12 h 不变，逐项相加约 8.5 h，余量留给并发与联调缓冲）。**降级顺序**：先砍 `mealTimeSamples`（`evidence` 留空）→ 再砍 `activeDays`（UI 显示 `-- 天`）→ **绝不砍 `chewStats` 与 `summary`**（它们直接决定分数与环比能否算出）。 |
| 已写入 | `API-03` §4、§5、§11.1 |

### ADR-07 🔴→✅ 🖊️已复核 两份 JSON Schema 把未决项写成了 `const`

| 项 | 内容 |
|---|---|
| 发现方 | `PLAN-T-05` 的风险表 + 本次复核 |
| 问题 | `feature_config.schema.json` 与 `metrics.schema.json` 都写了 `"const": 129`，而**同一字段的 `description` 写着「未决项，待 A 拍板」**。二者直接矛盾：若 A 拍板选项 A（128），**schema 会拒绝真实配置**，`metrics.json` 永远无法通过校验。 |
| 裁定 | 两处均改为 **`"enum": [128, 129]`**，并在 `description` 写明两个选项的含义、拍板后应改回 `const <选定值>`、以及需同步的四处。 |
| 已写入 | `docs/common/docs_api/schemas/feature_config.schema.json`、`docs/common/docs_api/schemas/metrics.schema.json` |
| 验证 | 6 份 schema 全部 `json.load` 通过 |

### ADR-08 🟡→✅ 错误码未登记

| 项 | 内容 |
|---|---|
| 发现方 | `API-04` 自认 + `SPEC-M-04` |
| 问题 | `ACD-DEMO-002/003`、`ACD-SCORE-001`、`ACD-DB-003/004`、`ACD-INF-004`、`ACD-IO-002`、`ACD-BEH-001`、`ACD-KB-001`、`ACD-ART-*` 已在各文档使用，但 `API-00` §3.5 只登记了 10 个区域码。**未登记即使用的错误码没有权威依据**，而 `SPEC-M-04` 的自检面板直接回显错误码。 |
| 裁定 | `API-00` §3.5 扩为**完整登记表**（14 个区域码 / 30 个具体码），并写入两条纪律：① 新增错误码必须**先登记再使用** ② `ACD-ART-*` 属离线工具链，不出现在 App 运行时。 |
| 已写入 | `API-00` §3.5 |

### ADR-09 🔴→✅ 🖊️已复核 餐次窗口使评分卡一个维度**失效**

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-D-03` §10 问题 1（**本批最有价值的一条发现**） |
| 问题 | 原冻结窗口 早 `[05,11)` / 午 `[11,16)` / 晚 `[16,23)` ⇒ 零食窗口只剩 `[23:00, 05:00)`，**与 `lateNightCount` 完全重合**。绝大多数用户该时段进食 0–1 次 ⇒ FF-22 的 `snack` 维度 `20 × max(0, 1 − n/10)` 几乎恒为 18–20 分 ⇒ **该维度彻底失去区分度**，而它是 100 分制中的 20 分。 |
| 附带矛盾 | `软件UI界面设计图/3.png` 把 **15:40 薯片**标为「下午零食」，主方案 §5.4.1 也写「近期**下午零食**频率较高」—— 但 15:40 落在原午餐窗口内，会被计为**午餐正餐**。另 `计划书 v1.txt` §5.3.5 明确「晚间进食 = **20:00** 以后」，原值要求到 23 点。 |
| 裁定 | **修订 A-2**：早 `[05,10)` / 午 `[11,14)` / 晚 `[17,21)`；零食 = 其余时段（`[10,11)` ∪ `[14,17)` ∪ `[21,05)`）；晚间 = `[20:00, 05:00)`。零食与晚间**刻意允许重叠**，因为它们是两个不同的产品指标而非互斥分类，**不得"去重"**。 |
| 理由 | 三条独立证据（评分有效性 + UI 稿叙事 + `计划书 v1` 明文口径）指向同一结论。**这是修正一处会使评分维度失效的设计缺陷，不是偏好调整。** |
| 工时 | 无新增工作量（窗口常量与测试夹具本来就存在，仅改值）。 |
| 已写入 | `API-03` §5（权威）、`SPEC-D-03` §4.1 + §10 问题 1 关闭 |
| 🟡 待同步 | `SPEC-A-01` 的 `snack` / `lateNight` 相关算例期望值、`SPEC-A-03` 周报文案示例 |

### ADR-10 ✅ 接口层与域层口径冲突的**通则**

| 项 | 内容 |
|---|---|
| 冲突实例 | `days` 值域（API-03 `[1,365]`+`ACD-DB-004` vs SPEC-D-03 `[1,90]`+`ArgumentError`）｜`week()` 语义（「最近 7 天」vs「ISO 周」）｜`deltas` 能否为空｜演示状态载体（`app_meta` vs 行存在） |
| 裁定 | **跨层契约一律以接口层（`docs/*/docs_api/` 的 `API-0x`）为准**（`SPEC-00` §5 规则 3 已规定）。具体：`days ∈ [1,365]`、越界抛 `ACD-DB-004`；`week()` = **最近 7 个设备本地日历日（含今日）**，非 ISO 周；`deltas` 恒含 7 键（无基准填 `0`）；演示状态以「库内存在 `source='demo'` 行」为真值，`app_meta` 仅作索引且必须与之始终一致（须有断言）。 |
| 理由 | 接口文档定义的是一侧的契约，域层文档定义的是实现；契约冲突时必须以契约侧为准，否则 A/B 两侧会各自实现。 |
| 🟡 待同步 | `SPEC-D-03` §2/§6（`days`、`week` 语义）、`SPEC-U-01`（`deltaVsYesterday == 0` 应显示「持平」而非隐藏）、`SPEC-U-04`（`deltas` 展示）、`SPEC-D-01`（演示状态双载体一致性断言）、`SPEC-A-04`（导入原子性：失败清理，不留半套数据） |

### ADR-11 ✅ `foods.json` 字段命名风格

| 项 | 内容 |
|---|---|
| 问题 | 主方案 §5.5 的示例用 `snake_case`（`zh` / `standard_portion` / `nutrition_tag`），而 `API-00` §3.1 规定 JSON 字段用 `lowerCamelCase`（`feature_config.json` 是**唯一例外**，因为 Python 侧可读优先）。 |
| 裁定 | **以 `API-00` §3.1 为准**，用 `zhName` / `portionDesc` / `portionKcal` / `nutritionTags`；`icon` 移出 `FoodInfo`（属 UI 资源映射，不入知识库契约）。主方案 §5.5 的示例视为**草稿**。 |
| 已写入 | `docs/common/docs_api/schemas/foods.schema.json`、`API-04` §2 |

### ADR-12 ✅ 底栏导航：设计稿 vs FF-23

| 项 | 内容 |
|---|---|
| 问题 | `软件UI界面设计图/1.png`、`9.png`、`10.png` 的底栏是「首页 / 检测 / 记录 / **我的**」，**没有「健康报告」Tab**；而 `FF-23` 冻结「4 页面 = 首页 / AI 检测 / 饮食记录 / 健康报告 + 设置入口（非独立 Tab）」。 |
| 裁定 | **以 FF-23 为准**：底栏 4 Tab = 首页 / 检测 / 记录 / 报告；「我的」放首页右上角入口。 |
| 理由 | ① FF-23 是冻结事实，设计稿是素材 ② 健康报告 + 评分卡是主方案 §8.2.1 五项「不可砍」之一，藏进二级入口会削弱它是核心交付物的定位 ③ 主方案 §8.2.3 明确「「我的」并入首页右上角入口，不做独立 Tab」。 |
| 🟡 待同步 | `SPEC-U-06` §10 开放问题 1（改为已裁定）、`SPEC-U-01`/`U-02`/`U-04`/`U-05` §10 |

### ADR-13 ✅ `9.png`「本周健康数据概览」三项不入 UI

| 项 | 内容 |
|---|---|
| 问题 | `9.png` 有「总进食次数 / 平均咀嚼速度 / 零食次数」三项，**不在主方案 §3.4.1 的 UI 数据契约表内**。 |
| 裁定 | **不实现。** 依据 `SPEC-00` §4.1 的硬规则与风险 R-19：「表里没写的字段，UI 上不许出现」。 |
| 若确要保留 | 必须先走 `PLAN-C-03` 的变更传播，把三项写进契约表并指定数据源（`总进食次数`→`StatsRepo.week().recordCount`；`零食次数`→`.snackCount`；`平均咀嚼速度`→`StatsRepo.chewStats()`）。**不允许 UI 自行取值。** |
| 🟡 待同步 | `SPEC-U-05` §10（已按"不实现"记录，确认即可） |

### ADR-14 ✅ `ambientNoise` 不是自检项（**同步过程中新发现**）

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-M-04` / `SPEC-M-01` 交叉比对 |
| 问题 | `SPEC-M-01` §7 的判据 A6 断言一个 `key == "ambientNoise"` 的自检项，而 `SPEC-M-04` §10 第 2 条更把它写成「本 SPEC 增补的**第 14 项**」—— 但 `API-04` §7.1 冻结的 14 项里**第 14 项是 `demoData`**，且 14 项必须**恰好 14 项、顺序一致**。结果是 **A6 判据不可判定**（`SelfCheckItem` 的 `key` 根本没有这一项）。 |
| 裁定 | **`ambientNoise` 不进自检清单，也不得加进去。** 它是**进场前的人工 SOP 实测**（主方案 §9.2「提前 30 分钟到场地，实测一次完整流程……环境噪声 >65 dB 时直接走 Mode B」）—— 由**人拿外部工具现场测**，不经过 `DemoController.runSelfCheck()`。 |
| 理由 | ① ADR-04 已把 14 项冻结为闭集，加第 15 项会破坏 `SPEC-M-04` 与 `API-04` 的一致性 ② 环境噪声**不是 App 能自测的量**（App 只能在录音时估计噪声底，那与本项语义不同）③ SOP 实测本来就在 D9 的进场流程里。 |
| 已写入 | `SPEC-M-01`（§4/§6/§7 A6）、`PLAN-M-01`、`SPEC-M-04` §10 第 2 条（关闭） |
| 影响 | A6 由「断言自检项通过」改为「**人工核对项**：用外部工具实测 dB 并记录工具与数值；>65 dB 按 §6 处置表切 Mode B」。 |

### ADR-15 ✅ 评分公式的**求值顺序**也是冻结约定（**同步过程中新发现**）

| 项 | 内容 |
|---|---|
| 发现方 | `SPEC-A-01` 算例复算 |
| 问题 | `structure = 30 × min(1, p/0.4)` 在 IEEE-754 下**两种等价写法给出不同分数**：`30 * min(1, 0.30/0.4)` = `30 × 0.7499999999999999` = `22.499999999999996 → 22`；而 `30 * 0.30 / 0.4` = `22.5 → 23`。**同一公式相差 1 分**，而 UI 会把这个数字直接展示给评委；联调时的表现是「后端算 22、前端算 23」且**不报错**。 |
| 裁定 | 四维公式**必须按字面表达式求值，不得做代数重排**。配套三条：① 实现与测试都用字面表达式；② 夹具比值取**浮点安全值**（`SPEC-A-01` 表 A-01-T3 已采用 `p ∈ {0.10, 0.20, 0.25, 1.00}`），避开 `p/0.4` 恰为半值的组合；③ **保留一条回归用例**固定记录 `p = 0.30` 在字面表达式下应得 **22**（写死，防止有人"优化"成 23）。 |
| 已写入 | `SPEC-00` §3.7（宪法：求值顺序是冻结约定的一部分）、`PLAN-C-05`（`health_score_consistency_test.dart` 的断言要求） |
| 备注 | 这不是"实现细节"，而是**规范的一部分** —— 因为它会改变可观测的输出数字。凡是"同一公式的不同写法给出不同结果"的情形，规范必须钉死其中一种。 |

### ADR-16 ✅ Mel / STFT 的四个数值参数冻结（**`SPEC-P-04` §10 交叉评审发现**）

| 项 | 内容 |
|---|---|
| 问题 | `SPEC-P-04` §10 点出了三个「高危数值分歧点」，但**都没有冻结值**：① `center=True` 时 STFT 的 `pad_mode` ② `power_to_db` 的 `ref` ③ Mel 滤波器组的 `htk` / `norm`。**每一个都会改变 Kotlin 前端算出的数**，而 `PLAN-T-08` 的跨语言对齐判据是 `np.allclose(atol = 1e-3)` —— 任一不一致就**静默失败**（不报错，只是两侧数字不同）。 |
| 裁定 | **全部取 librosa 的默认值并写成显式冻结项**：`pad_mode = "constant"`（零填充）、`power_to_db_ref = 1.0`（绝对刻度）、`mel_htk = false` + `mel_norm = "slaney"`。 |
| 理由 | ① **显式写出默认值**比"跟随库默认"更安全 —— 库升级或换成 Python 侧自写实现时不会漂移 ② `ref = 1.0` 让 FF-08 的固定 dB 截断作用在**绝对标度**上；若用 `ref = np.max`，截断会退化成 **patch 相对量**，重新引入域偏移陷阱（正是 FF-08 当初要规避的问题）③ Slaney 刻度/归一化是 librosa `melspectrogram` 的默认，Kotlin 侧照此实现即可，无需额外推导。 |
| 被否决 | `pad_mode = "reflect"`（改变前若干帧）、`ref = np.max`（域偏移）、`htk = true`（滤波器形状不同）。三者的共同问题：**要么改 Python 侧，要么在 Kotlin 里更难复现，且换不来任何建模收益。** |
| 影响面 | 这四个值是 `PLAN-T-08` 对齐测试**能否通过的直接决定因素**；两侧必须**同时读 `feature_config` 的同一组键**，不得各写常量。 |
| 已写入 | `shared/feature_config.json`（4 个新顶层键 + `_decisions.mel_numerics`）、`feature_config.schema.json`、`SPEC-P-04` §4/§5/§10 |

### ADR-17 ✅ 预处理范围收敛：移除高通、LUFS 只留训练侧（**`SPEC-P-03` §10 交叉评审发现**）

| 项 | 内容 |
|---|---|
| 问题 | `SPEC-P-03` §4 的参数表列了**高通滤波器的截止频率与阶数**，但**从未冻结**；§10 又承认"本 SPEC 要求在 Kotlin 做高通，而 FF 冻结表里没有，若 Python 侧不做则 `atol=1e-3` 不可能成立"。同时预加重的**首样本边界约定**（`x[−1] = 0` 还是 `x[−1] = x[0]`）也未定 —— 两者都会让两侧数字差在第 0 帧上。 |
| 裁定 | ① **高通滤波器从 v1.0 移除**（`highpass = removed_in_v1`）② **预加重首样本**冻结为 `x[−1] = x[0]`（首样本原样通过，与 librosa `lfilter` 的初始条件一致）③ **LUFS 只用于训练侧**（`loudness_normalization = "training_only"`，`target_lufs = -23.0`），**推理侧不做 LUFS**。 |
| 理由 | ① **高通从来不在冻结计划里**：主方案 §3.7 在裁决谱减法时明确写「只保留：预加重（保留，廉价且有效）+ 响度归一化（保留）」。**这个参数是规格拆分过程中被额外加进来的**，移除它是**回归已冻结的计划**，不是削减功能。② 高通的收益本就存疑：`fmin = 20 Hz` 的 Mel 滤波器组已经丢弃 20 Hz 以下，预加重也已抑制低频 —— **加一个必须在两种语言里逐位对齐的滤波器是纯风险**。③ **推理侧 LUFS 是冗余的**：FF-08 的固定 dB 截断（`clip(x, −80, 0)`）+ 逐 patch min-max 已经提供了尺度不变性；现场再算一遍 LUFS 只增加 CPU 开销与一处可能不一致的实现。 |
| 被否决 | `2 阶 Butterworth @ 20 Hz`（两侧实现）—— 收益接近于零，却新增一个位级对齐点。 |
| 附带收益 | 本裁定把 `P-03` 的参数面从「预加重 + 高通(截止/阶数) + RMS/LUFS + 谱减法开关」收敛为「**预加重 + FF-08 归一化**」，**消掉了 3 个未冻结参数**。 |
| 已写入 | `shared/feature_config.json`（`preemphasis_boundary` / `loudness_normalization` / `target_lufs` 三个新键 + `_decisions.preprocess_scope`）、`feature_config.schema.json`、`SPEC-P-03` §4/§10 |

### ADR-18 ✅ VAD 的四个参数冻结（**由「引用核验」机械检查发现**）

| 项 | 内容 |
|---|---|
| 发现方式 | 我加了一道检查：**文档里引用的 `feature_config.<键>` 必须真的存在**。它立刻捞出了 `PLAN-P-02` 的 Kotlin 骨架正在消费四个**在 41 键 SSOT 中完全不存在**的参数：`noiseFloorInit` / `noiseFloorMin` / `marginDbToLinear` / `alpha`。 |
| 问题 | 端点检测（`P-02`）是 **D2 的第一道关键路径环节**，而它的**判定阈值从未冻结** —— 与 `ADR-16`/`ADR-17` 完全同一类缺陷（规范里存在未冻结参数），只是藏在一个**代码骨架**里而不是参数表里，所以前三轮人工评审都没看到它。 |
| 裁定 | **四个参数冻结并放入 `behavior`**（与 `envelope_frame_ms` / `envelope_hop_ms` / `envelope_length` 同处 —— 因为它们由**同一次分帧**产出）：<br>• `noise_floor_init = 0.001`（线性 RMS ≈ −60 dBFS，安静房间的典型底噪）<br>• `noise_floor_min = 0.0003`（≈ −70 dBFS，防止底噪在数字静音上塌陷）<br>• `voiced_margin_db = 6.0`（高于底噪 6 dB 判为有声）<br>• `noise_floor_alpha = 0.95`（一阶慢更新；在 32 ms 帧移下时间常数约 20 帧 ≈ 0.64 s，使单个咀嚼瞬态拉不高底噪）<br>判定式：`rms > noise_floor × 10^(voiced_margin_db / 20)`。 |
| 为什么是**自适应**底噪而不是固定阈值 | 手机麦克风增益在机型间差异极大，**绝对 RMS 阈值无法跨设备迁移**；自适应正是让同一组常量在各机型上都成立的机制。 |
| 边界影响 | **顶层键数不变（41）** —— 四个键进 `behavior`，使其由 **11 → 15** 个子键。`_decisions` 增加第 4 项 `vad_parameters`。 |
| 已写入 | `shared/feature_config.json`（`behavior` + `_decisions.vad_parameters`）、`feature_config.schema.json`、`SPEC-00` §3.6 **FF-21k**、`PLAN-P-02`（改为读真实键） |
| 方法论价值 | **这是"把发现固化成机械检查"的第一次直接回报**：前三轮人工交叉评审都没发现它，加检查后几秒钟就捞出来了 —— 印证了 §5.3 教训 5。 |

### ADR-19 ✅ FF-19 识别类别表修订：采纳训练侧交付的六类（**训练侧语料倒逼的修宪**）

| 项 | 内容 |
|---|---|
| 发现方式 | 训练侧交付语料的类别表与 `SPEC-00` §3.3 FF-19 **直接冲突**：语料为 `chips / cabbage / gummies / noodles / carrot / drink`，而冻结表是 `chips / apple / cookie / bread / carrot / drink`。冲突不是"名字不一样"，而是**其中一类是被明文禁止的储备类别**。 |
| 问题 | 语料替换了 id 1（`apple`→`cabbage`）、id 2（`cookie`→`gummies`）、id 3（`bread`→`noodles`）。而 `noodles` 正是 FF-19 写着「**不进 v1.0**」的储备类别，且项目为这条禁令建了**四道结构性防线**：① `ai/tests/run_all.py` 的 `CUT_TOKENS`；② `ai/src/ablations.py` 的 `FORBIDDEN`；③ `foods.schema.json` 用 `additionalProperties:false` + 6 个枚举键结构性拒绝；④ `SPEC-U-03` 点名禁止「面条」作为食物命名。照单采纳 = 必须**拆掉这四道防线**，属于修宪动作，不能顺手做。 |
| 裁定 | **采纳新六类（选项 A）**，FF-19 正式修订。原表作为 `supersedes` 完整保留在本条下方。 |
| 子裁定 1：`noodles` 出储备名单 | 语料里**真的有**面条数据，再把它当"不进 v1.0"是自欺。**但 `nuts` 仍是储备类别** —— 防线机制本身保留，只改成员集合。这样"储备类别"这个概念与它的四道防线都还在，只是名单正确了。 |
| 子裁定 2：评分口径保持不变 | `health_score_formula.structure.healthy_labels` 改为 `["cabbage","carrot","noodles"]`。原值为 `["apple","carrot","bread"]`，**id 集合都是 {1,3,4}** —— 所以「食物结构」维度的**所有既有评分算例与夹具语义完全不变**（100/61/28/29 四算例无需改），只是名字跟着新表走。这是本次修订里唯一"必须精确对齐"的地方。 |
| 子裁定 3：属性不能再由 `classId` 硬编码 | 训练侧同时改了属性：`chips` 由「脆性食品」→「**脆性高加工零食**」，`gummies` 为「**黏弹性零食**」，`cabbage` 为「**脆爽蔬菜**」。于是 `fake_repo.dart` 与 `detection_session.dart` 里那句 `0 \|\| 2 => '脆性食品'` **双重失效**（id 2 已是软糖，不再是脆性）。改为**从 `foods.json` 知识库快照** —— 这正是 `API-03` §2 一直要求的做法，硬编码 switch 本就是偏离。 |
| 被否决的备选 | **保留 FF-19 冻结，把语料的三个文件夹映射到旧类名**（`Noodles`→`bread`、`Gummies`→`cookie`、`Cabbage`→`apple`）。否决理由：语料**真的就是**卷心菜、软糖和面条。把一碗面条在 UI 上呈现为「面包」是对用户说假话；且卷心菜（脆爽蔬菜）与苹果（脆爽果蔬）也不是同一类食物。**改类名是诚实的，改数据不是。** |
| ⚠️ 已知数据风险 | 语料 **`noodles` 412 段、`drink` 293 段**，低于 `SPEC-T-01` 的单类 500 片段门槛；`cabbage` 恰好 500（零余量）。该语料会让 `SPEC-T-01 --strict` 以 `exit 3` 退出。**在作任何准确率声明之前，应先评估 FF-19 的 4 类降级开关。** 本裁定**不**放宽门槛，只如实登记。 |
| 边界影响 | **顶层键数不变（41）** —— `class_labels` 改值、`structure.healthy_labels` 改值（键数不变）。`_decisions` 增加第 5 项 `class_table`（含 `rejected_alternative` 与 `known_data_risk`）。 |
| 已写入 | `shared/feature_config.json`（`class_labels` / `structure.healthy_labels` / `_decisions.class_table`）、重生成的三份常量（`feature_config.g.dart` / `FeatureConfig.kt` / `assets/feature_config.json`）、`SPEC-00` §3.3 FF-19、`app/assets/foods.json`、`foods.schema.json`、`FoodClassId` 枚举、`food_icon.dart`、`gen_demo_dataset.py` + `demo_dataset.json`、四道防线的成员集合、App 测试夹具与 AI 侧类别默认值 |
| **原表（supersedes）** | ID 0 `chips` 薯片 脆性食品 ／ 1 `apple` 苹果 脆爽果蔬 ／ 2 `cookie` 饼干 脆性食品 ／ 3 `bread` 面包 软性主食 ／ 4 `carrot` 胡萝卜 脆爽蔬菜 ／ 5 `drink` 饮料 液体。储备类别：`nuts` **和** `noodles`。 |

### ADR-20 ✅ 模型 I/O 类型冻结为 **float32**：INT8 指的是**权重**，不是接口

| 项 | 内容 |
|---|---|
| 发现方式 | 模型开发组的报告把导出模式描述为「内部 INT8 权重 + 外部 float32 输入输出」，并称导出代码**没有设置** `inference_input_type` / `inference_output_type`（依赖默认值）。核对本仓代码后发现**结论对、依据不对**：`ai/src/quantize.py` 是**显式**设置这两个字段的（第 168–169 行），而且第 261–263 行会**拒绝**导出任何 I/O dtype 不是 float32 的产物。也就是说本仓比报告描述的更严格。 |
| 问题 | 「INT8 模型」在 TFLite 语境里有**两种都合法**的读法：① INT8 **权重** + float32 I/O（本仓）；② **全整数**（int8 I/O）。两者在体积上接近，接口却完全不同。若拿到 ② 的产物：App 侧喂进去的是 float32 字节、输出按「字节数 ÷ 4」解析，于是失败会表现为**误导性的** `ACD-INF-002「模型输入不匹配」`（字节数/形状类错误），而不是"类型不对"。这个歧义已经真实发生过一次（旧分析报告写的"全整数 int8 I/O"）。 |
| 裁定 | **冻结为 INT8 权重 + float32 I/O**，并且**不再依赖文档声明，改为在加载时测量**：新增 `ModelIoContract`（`lib/domain/service/inference_engine.dart`，纯 Dart 可离线测）与 `TfLiteTensorType` 绑定，`load()` 时直接读产物自己的张量类型。**int8 / uint8 I/O 的模型会被当场拒绝**，错误信息点名具体 dtype。 |
| 为什么是「测」而不是「信」 | 模型卡只有 `quantization: "int8"` 一个字段，它描述**权重**、无法区分上面两种读法；而卡片是跨团队冻结的 15 字段契约，为这个加第 16 个字段要双方改文档。张量类型是**产物自身的元数据**，比任何声明都硬，且零成本。 |
| 边界影响 | **SSOT 键数不变（41）**；App 契约不变（本来就喂 `Float32List`、读 float 概率）；不改 `model_card.json` 字段集。新增的只是「违反契约会被立刻抓住」这一条。 |
| 已写入 | `inference_engine.dart`（`ModelIoContract` + 契约文档）、`tflite_inference_engine.dart`（`TfLiteTensorType` 绑定 + 加载期校验）、`pure_tests.dart`（9 项断言，覆盖 float32 通过与 int8/uint8 拒绝各分支）、`SPEC-T-07` §1.2（**术语红线**：不得写「全整数量化」） |
| 顺带纠正报告的三处**与本仓不符**的描述 | ① 文件路径 `ai/src/acoudiet_ai/export_tflite.py` **不存在**，本仓是 `ai/src/quantize.py`；② `model.py` 的 1→3 通道扩展用的是 **1×1 `Conv2D`**（`channel_expand`），**不是** `Rescaling(×2,−1)` + `Concatenate`（×2−1 由 MobileNetV3 的 `include_preprocessing=True` 在基座内部完成，效果相同、机制不同）；③ `shared/feature_config.json` 里**没有** `model_input.dtype` 键（只有 `input_shape=[1,128,129,1]` 与 `db_clip_range`），值域 `[0,1]` 由 FF-08 的 per-patch min-max 保证，不是一个 SSOT 键。 |
| ⚠️ 需要模型组确认的一处 → **✅ 本项已由 `ADR-21`（2026-09-12）关闭** | **原提问（保留原文）**：报告正文写 "Kotlin 端直接喂 `float32[1,128,128,1]`"，与冻结的 **`n_frames=129`**（ADR-P1）差一帧。本仓一律按 `[1,128,129,1]`；若导出侧真的按 128 帧训练/导出，则张量形状与 Mel 前端互相矛盾，`ModelRegistry` 会以 **`ACD-INF-002`** 拒绝装载。**这一条必须由模型组确认是笔误还是真实形状。** —— **答案（`ADR-21`）：是真实形状，不是笔误。**交付制品的输入张量实测为 `float32[1,128,128,1]`（128×128×4 = 65536 字节），旧口径的 129 帧 Mel 是 66048 字节，**根本喂不进去**；本仓据此把 `n_frames` 修订为 **128**（`129` 改称 `raw_mel_frames`）、`input_shape` 修订为 `[1,128,128,1]`。本行提问里出现的 `[1,128,129,1]` 属 ADR-21 之前的旧口径。 |
| 🚨 核查时**新发现**的阻塞项 | 本次为了给 ADR-20 加"加载期校验张量类型"，顺带实测了 APK 内容：**三个 APK 里都没有任何 TFLite 原生库**（release 只有 2 个 `.so`，都是 Flutter 自己的），工程里没有 `jniLibs`，`pubspec.yaml` 也已不再依赖 `tflite_flutter`（原本由它提供 `libtensorflowlite_c.so`）。而引擎在 Android 上只尝试 `libtensorflowlite_c.so` / `libtensorflowlite_jni.so` —— 两者都**不是** Android 公开系统库（与 `libsqlite.so` 同一类：不在 `public.libraries.txt` 中，`dlopen` 必失败）。**因此在真机上，即使把合格的成品模型投进 `app/assets/models/`，引擎也会在打开动态库时失败并报 `ACD-INF-001`。** 这直接卡住「投放成品模型即可用」这条主线。**→ 已按方案 A 修复**：`build.gradle` 加入 `implementation 'org.tensorflow:tensorflow-lite:2.16.1'`。 |
| ✅ 上述阻塞项的修法与实测 | **为什么是 2.16.1 而不是"最新"**：`2.17.0` 只发布一个**不含 `.so`** 的 jar（实测 zip 都打不开），按"取最新"钉版本会把同一个 bug 带回来；2.16.1 是**最后一个同时发布带 native 的 `.aar`** 的版本。它的 `jni/arm64-v8a/libtensorflowlite_jni.so` **导出了 Dart 绑定所需的全部 21 个 `TfLite*` 符号**（含本次新增的 `TfLiteTensorType` 与 `TfLiteVersion`）—— 逐符号在该二进制里核过。**ABI 陷阱**：Flutter 的 `--target-platform android-arm64` **不过滤第三方 AAR 的 native**，加库后 release 一度由 17.1 MB 涨到 **31.1 MB**（14 MiB native／四 ABI 全进）。已加可选裁剪 `--android-project-arg=acoudietAbis=arm64-v8a` → **20.4 MB、仅 arm64**；**默认不裁剪**（模拟器是 x86_64，静默砍掉它会让本仓失去唯一可实测的设备）。设备侧实测：`primaryCpuAbi=x86_64`，`.so` 在 APK 内**未压缩存储**（linker 直接映射所需），模拟器启动回归 exit 0。⚠️ **端到端装载仍未验证**（缺模型组制品）；且导出侧 TF（2.21）与 Android 端可得的运行时（2.16.1）存在版本差，故绑定 `TfLiteVersion` 并在自检第 3 项显示 `loaded (runtime x.y.z)`，让版本差异在设备上可见。 |

### ADR-21 ✅ Mel 前端 v1.1：按交付模型的真实规格**修订** FF-02 / FF-07 / FF-08 / FF-11 / FF-14（**交付制品倒逼的修宪**）

| 项 | 内容 |
|---|---|
| 发现方式 | 模型组交付 `mobile_release/v1`（fp32 + int8 动态范围 + int8 全整数三个制品 + `feature_config.json` + `README_集成说明.md`）。**先读代码、后读文档**：用 `tf.lite.Interpreter` 直接量了制品的 I/O，得到 `float32[1,128,128,1] → float32[1,6]`。而本仓冻结的是 `[1,128,129,1]`。**这不是"差一帧的笔误"，是模型根本喂不进去**：129 帧的 `Float32List` 长度为 16384，模型输入张量只有 16384 字节？—— 不，输入张量是 128×128×4 = **65536 字节**，而 129 帧的 Mel 是 128×129×4 = **66048 字节**，`TfLiteTensorCopyFromBuffer` 必然失败。ADR-20 当时登记的"待模型组确认是笔误还是真实形状"，**制品回答了它：是真实形状**。 |
| 逐项核对后确认**五处实质性不一致** | ① `power_to_db` 的 `ref`：交付侧是 **`patch_max`**，本仓冻结 `1.0`（ADR-16）② 归一化：交付侧是 **per-patch minmax**，本仓是**固定 dB 截断 `[-80,0]` 后再 minmax**（FF-08）③ 帧数：交付侧把第 129 帧**丢掉**只喂 128 帧 ④ 预加重边界：交付侧是**沿流连续**（当前 patch 首样本用 patch 开始前最后一个原始样本），本仓是 `x[-1]=x[0]`（ADR-17）⑤ 交付侧的 `operation_order` **没有 DC 去除**，本仓 `Preprocess` 有一步逐 patch 去均值。 |
| 为什么**不是**可选优化 | 这是**训练/推理偏斜**（training-inference skew），不是偏好问题。`PLAN-T-08` 的一致性闸门证明的是「Kotlin 与 Python **彼此**一致」，**它看不见训练侧**。两侧都忠实实现旧链路时闸门**绿灯**，而喂给模型的张量与训练分布不是同一个 —— 这正是那道闸门存在的理由，只是此前只防到下一层。不改前端，放进去哪个制品都是垃圾输出（见下方"实测"。） |
| 裁定 1：帧数拆成两个数 | `n_frames` **128**（张量宽度）+ 新增 `raw_mel_frames` **129**（STFT 原始帧数）。**把两个概念合并成一个数字，就是这次缺陷的成因**，所以拆开而不是改值。`frame_selection = {strategy: drop_tail, start_inclusive: 0, end_exclusive: 128}`。 |
| 裁定 2：`power_to_db_ref` 由 `1.0` 改为字符串 `"patch_max"` | ADR-16 当年否决 `ref=np.max` 的理由是"会让 FF-08 的截断退化为 patch 相对量、重新引入域偏移"——**那条理由针对的是 ADR-16 当时要冻结的那条链路，它对**；但模型**已经按 patch 相对刻度训练好了**，此时"推理与训练不一致"是**更大的**误差。故正式反转 ADR-16 的这一项，理由记录在此。 |
| 裁定 3：`normalization` 由 `fixed_db_clip` 改为 `per_patch_minmax`，删除 `db_clip_range` | 固定 dB 窗口 `[-80,0]` 随之取消。生成器里针对 `db_clip_range` 的一键拆两字段特例（`SPEC-C-03` §10 #3）一并拆除，改为普通键 `normalization_output_min` / `normalization_output_max`。 |
| 裁定 4：**顺序**是承重的 | `operation_order` 为 `mel → power_to_db(patch_max) → drop_tail → per_patch_minmax`。即 **dB 参考与 `top_db` 下限算在全部 129 帧上，min-max 窗口是留下的 128 帧**。先 minmax 再截断会得到**不同的数**，所以 Kotlin 实现按这个顺序逐字写，而不是"重新推导一个等价写法"。 |
| 裁定 5：预加重改为**流式** | `preemphasis_boundary` 改为 `continuous_stream_previous_raw_sample_or_zero_at_source_start`。旧规则只在"每个 patch 都从录音开头开始"时自洽；实际 patch 以 0.5 s 步长在 4.096 s 窗口上滑动，**每个 patch 有 87.8% 的音频已经在上一 patch 里被预加重过**，逐 patch 重启滤波器等于把不连续点放在模型最爱看的位置。实现方式：环形缓冲取 `patch_samples + 1` 个样本，`buf[0]` 即前驱样本，会话开始时先写入一个 0 样本 —— 于是首个 patch 正好是"源起点 + 前驱 0.0"，此后每个 patch 都拿到真实前驱，**零跨 patch 记账**。 |
| 裁定 6：**删除**逐 patch DC 去除 | 交付侧 `operation_order` 里没有这一步。保留它等于在麦克风与模型之间插一个**训练时不存在**的变换。这是"推理必须匹配训练"的直接推论，不是对去均值好坏的判断。 |
| 被否决的备选 | **保持 v1.0 冻结链路，请模型组按它重训**。否决理由：模型**已经训练好了**，冻结链路只是一份文档。改前端的代价是一次**已有跨语言闸门可完全验证**的改动；重训的代价是一整个训练周期 + 重新导出 + 重跑一致性，且发布说明里的精度数字不会自动延续。 |
| 模型选型（用户拍板） | 三个制品里 **fp32（55.7%）** 精度最高，`int8` 动态范围 52.5%（−3.25pp），`int8` 全整数桌面 XNNPACK **拒载**（实测复现）且 I/O 为真 int8，被 ADR-20 的契约拒绝。用户明确选择**按识别精度最高的来制作 → 投放 fp32**。 |
| ⚠️ FF-16 的误读，**不是**这次的修宪 | FF-16 原文是「FP32 ≤ 6 MB；**INT8 ≤ 2.5 MB**」——**两档上限一直都在**，`ai/src/config.py` 的 `DomainConst` 也一直同时带着 `int8_max_bytes` 与 `fp32_max_bytes`。而 App 侧三个地方（`ModelRegistry` 的 `quantization == "int8"` 硬判、`verify_artifacts.py` 的单一 `INT8_MAX_BYTES`、`install_model.py` 的同一上限）**只实现了 INT8 那半档，并把另一半当非法输入**。API-06 §5 写的"交付 App 的必须是 int8"是这条误读的出处。故本次**不改 FF-16**，改的是 App 侧缺失的那半档：`ModelRegistry.supportedQuantizations = ["fp32","int8"]`，闸门按**卡片自己申报的档位**取对应上限，文件名由 `<name>_int8_v<version>` 变为 `<name>_<quantization>_v<version>`（int8 档的产物名**与以前逐字相同**，无兼容性成本 —— 此前从未交付过任何模型）。 |
| ⚠️ 关于精度的诚实口径 | 发布说明给出的 fp32 55.7% / int8 52.5% **本仓无法复测**：`ai/data/splits`、`ai/data/raw`、`ai/data/augmented` 在本仓**是空的**，没有带标注语料可评。**本次实测到的**是：用 v1.1 链路把交付的 fp32 模型跑在本仓自带的 20 s 演示音频上，32 个 patch **全部给出同一个标签**（`carrot`），平均 top-1 置信度 0.839；而 v1.0 链路**根本产生不出模型接受的张量**。另外：同一条输入上 int8 制品的平均置信度**更高**（0.883），而发布说明说它精度**低 3.25pp** —— **置信度不是准确率的证据**，这条对照值得记住。 |
| ⚠️ 同时纠正 ADR-20 的一处**描述错误** | ADR-20 写"`model.py` 的 1→3 通道扩展用的是 1×1 `Conv2D`（`channel_expand`），**不是** `Rescaling(×2,−1)` + `Concatenate`"。那句描述的是**本仓的占位 `ai/src/model.py`**，**不是交付制品**。直接读交付 fp32 计算图的前三个算子：`MUL(index 0) → ADD(index 1) → CONCATENATION(输入, 输入, 输入)`，随后 `CONV_2D → HARD_SWISH → DEPTHWISE_CONV_2D`。**交付制品就是 `Rescaling(2,−1)` + 三通道拼接**，发布说明 §2 的描述与制品一致；ADR-20 那句只对本仓占位实现成立。 |
| 顺带修复的一处**伪造测量** | `ai/scripts/mel_parity_test.py` 此前把 `labelMatch: 1.0` / `maxConfDelta: 0.0` **无条件写死**进 `parity_report.json`，而 `verify_artifacts.py` 在模型非 pending 时会**据此判闸门通过** —— 即闸门可能在一个**没人计算过**的数字上放行。现改为**实测**：把 Kotlin 侧 dump 的 Mel 与 Python 侧算的 Mel **分别**喂给同一个出厂解释器，比较 argmax 与 top-1 差值（同运行时、只差 Mel 生产者，故差异只能来自语言差异）。无模型安装时写 `null` 并置 `modelParityMeasured: false`，闸门**拒绝**把"未测量"读成"通过"。实测：**labelMatch 1.0000、maxConfDelta 8.34e-07**（18 个 patch）。 |
| 边界影响 | SSOT 顶层键 **41 → 49**（+`raw_mel_frames`/`power_to_db_amin`/`normalization_epsilon`/`normalization_output_min`/`normalization_output_max`/`frame_selection`/`operation_order`/`model_internal_preprocessing`，−`db_clip_range`，+`_comment_4`）。`_decisions` 增至 6 项（新增 `mel_frontend_v1_1`，并在 `n_frames` / `mel_numerics` / `preprocess_scope` 三条上标注**部分被取代**及其取代范围，不删旧文，保持可审计）。`MEL_VERSION` 与模型卡 `melVersion` **1.0.0 → 1.1.0**（Mel 数值变了就必须动它）。握手指段 **12 → 15**（`rawMelFrames`、`preemphasisBoundary`、`powerToDbRef`、`topDb`、`normalization` 入列，`dbClipMin`/`dbClipMax` 出列）。 |
| 已写入 | `shared/feature_config.json`（含 `_decisions.mel_frontend_v1_1` 与三处 supersede 标注）、重生成的三份常量 + keys 清单、`app/assets/models/acoudiet_fp32_v1.0.0.tflite` + `model_card.json`（**真实** sha256/字节数/实测 parity）、Kotlin `MelFrontend` / `Preprocess` / `AudioBridgeAndroid` / `NativeCapabilities` / `MelDump`、Python `config.py` / `features.py` / `augment.py` / `mel_parity_test.py` / `make_parity_wavs.py`（新增两个 3-patch 长音频以覆盖非零 offset）、Dart `handshake` / `model_registry` / `audio_bridge` / `app_services`、`tool/install_model.py` / `verify_artifacts.py` / `check_bridge_symmetry.py`、两套 Kotlin 测试与四套 Dart 测试、`SPEC-00` §3.1/§3.2/§3.5、`API-06` §1/§5/§9/§12、`app/assets/models/README.md` |
| 回归实测 | `verify_all.ps1` **16 步全绿**（此前 15 步中 5 步失败）；`verify_artifacts.py` **exit 0 PASS**（此前 **exit 3 NOT BUILT**）。断言计数：Kotlin DSP **79**、L4 纯域 **174**、L3 数据 **57**、session **98**（`ADR-22` 后为 **102**）、UI **373**、AI guard-rails **28**。跨语言 Mel 闸门 `maxAbsDiff 5.96e-08`（atol 1e-3），且**新增了非零 offset 覆盖**：`tone_long.wav@65536` 的前驱样本 = −0.153076，实测「正确前驱 maxAbsDiff 5.96e-08」对「错误前驱（取 0）maxAbsDiff 1.779e-01」—— **闸门确实具备区分力，不是空跑**。设备端另见 `ADR-22`。 |
| ⚠️ 仍需模型组确认 | 交付侧导出用 TF **2.21**，Android 端能拿到的 TFLite native 最新 AAR 是 **2.16.1**（ADR-20 已记录）。本行原写"**真机加载仍未实测**"—— **该状态已由 `ADR-22` 更新**：设备端端到端已实测，并在那里发现了**模型根本加载不了**的缺陷（`TfLiteModelCreateFromFile` 拿不到 Flutter asset），已修复并复测通过。若导出用了 2.16.1 不支持的算子，症状会是一次没有线索的加载失败；`TfLiteVersion` 绑定与自检第 3 项的存在就是为了让这个差异在设备上可见，而不是靠猜。 |
| 一个**已知未覆盖**的点 | 交付侧 `README_集成说明.md` §3 要求一致性验收覆盖四种边界（源文件首 patch / 中间 patch / 尾部补零 patch / 静音 patch）。本次覆盖了**首 patch、中间 patch、尾部（最后一个完整窗口）patch、静音 patch**，但**"尾部补零"指 offset + 65536 超过文件长度**的那种末段补零，`MelDump` 目前会以 `require` 拒绝（要求 `offset + n <= size`）。这是一处**已识别的缺口**，登记在此，不假装已覆盖。 |

### ADR-22 🔴→✅ 模型在真机上**根本加载不了**：`TfLiteModelCreateFromFile` 拿不到一个 Flutter asset（**首次设备端实测暴露**）

| 项 | 内容 |
|---|---|
| 发现方式 | `ADR-21` 落地后**第一次**跑设备端端到端（`tool\run_on_emulator.ps1`）。应用本身**一切正常**：`install: Success`、`topResumedActivity` 是自己、进程存在、**无 FATAL EXCEPTION**、首帧 `Fully drawn com.acoudiet.app/.MainActivity: +14s323ms`、截图非空白 —— 六项判据全过、脚本 exit 0。但在同一份 logcat 里有：`E tflite : Could not open 'assets/models/acoudiet_fp32_v1.0.0.tflite'.` 与 `E tflite : The model allocation is null/empty`。**即"应用能起来"和"模型能用"是两件事，而只跑脚本的六项判据只看得到前一件。** |
| 根因 | `TfliteInferenceEngine.load()` 把**asset 键**直接交给了 `TfLiteModelCreateFromFile`。那个 C API 要的是**文件系统路径**；而 Flutter 的 asset 在 Android 上**住在 APK 的 zip 里**，不是文件。于是 `dlopen` 层面的库、`libtensorflowlite_jni.so`、4 个 ABI、模型字节**全都在位**，唯独这一次调用用的路径不存在。这也解释了为什么 logcat 的第一句是 TFLite 自己说的 `Could not open '<asset key>'`。 |
| 为什么**所有**离线闸门都没抓到 | 因为仓库里**从来没有任何一处真的调用过这个引擎**。16 个套件里的"引擎"是 `FakeInferenceEngine`（`session_tests.dart` 的投放契约组），它把 `assetPath` 收下就置 `_loaded = true`，**不碰路径、不碰文件**。跨语言 Mel 闸门比的是 Kotlin↔librosa；`verify_artifacts.py` 只读模型卡与 parity 报告；APK 内容检查只证明**字节在包里**（本次也确实验过 sha256 逐字节相同）。**每一道闸门都在自己那一层是绿的，而缺陷位于"没人测过的那一层"** —— 这与 `ADR-20` 的 `libtensorflowlite_c.so` 缺陷是同一类，也是同一层：**最后一次真实调用**。 |
| 裁定 | 改用 **`TfLiteModelCreate(const void* model_data, size_t model_size)`** 从**内存**建模，字节由调用方提供。`ModelRegistry`（本来就持有 `AssetReader`）用 `assets.readBytes(path)` 读出模型的 flatbuffer 再交给引擎；`load()` 签名增加可选 `Uint8List? modelBytes`，**仅接受路径的旧调用仍然合法**（桌面/宿主环境那里路径确实是文件），但 Android 走的是字节路径。 |
| ⚠️ 一条**承重的**生命周期细节 | `TfLiteModelCreate` **不复制**入参缓冲区 —— 指针必须在模型存活期间一直有效。因此引擎用 `malloc` 持有一份拷贝（`_modelBuffer`），并在 `_release()` 里**先 `TfLiteModelDelete` 再 `free`**。顺序反了就是 use-after-free，而且症状大概率是随机的推理崩溃，不是加载失败。 |
| 为什么 `TfLiteModelCreate` 是**强制**符号而不是可选 | 没有它，Android 上**任何一个模型都装不进来**。故按 `ADR-20` 的同一条准则处理：必需符号缺失即 `ACD-INF-001`，而不是"退化后继续"。已实测该符号存在于出厂 `.so`（从 APK 解出 `lib/x86_64/libtensorflowlite_jni.so`，按 NUL 结尾精确匹配 `TfLiteModelCreate` = present；同批检查的 `TfLiteModelCreateFromFile` / `TfLiteVersion` / `TfLiteInterpreterCreate` / `TfLiteTensorType` / `TfLiteInterpreterOptionsAddDelegate` 亦全部 present）。 |
| 设备端实测（前后对照） | **修复前**：应用 pid 出现 `Could not open 'assets/models/acoudiet_fp32_v1.0.0.tflite'` + `The model allocation is null/empty`，且该进程**没有**打出 TFLite 初始化日志。**修复后（debug 包）**：同样六项判据全过（exit 0），上述两条**签名 0 命中**，并且**应用自己的 pid（3359）**打出 `I tflite : Initialized TensorFlow Lite runtime.`（15:15:51.697）—— 是**正面证据**，不只是"错误消失"。**修复后（release 包，新增）**：另对 `flutter build apk --release` 的 **4-ABI 包**（模拟器是 x86_64，arm64-only 的交付包装不进去）跑了一遍，七项判据全过、`Fully drawn …+1s430ms`、模型加载检查 PASS（应用 pid `3308` 初始化了 TFLite）。**即交付用的 release 构建同样是设备验证过的**；`dist/` 里的 24.3 MB arm64 包与它同源码同工具链，差异只在打包了哪些 ABI。 |
| 顺带修掉的**两个判据缺陷**（都在 `run_on_emulator.ps1`，第一次测 release 时暴露） | ① **安装判据用文本匹配 `Success`**：输出被截断成 `Performing Streamed Install` 时既不含 `Success` 也不含失败行，于是**退出码 0 的成功安装被记成失败** —— 已改用 `adb install` 的**退出码**。② **没有处理签名变更**：旧包是 debug 签名、新包是 release 测试密钥，Android 会以 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 拒绝覆盖安装，而脚本照旧启动**旧包**，于是"装的是哪个包"与"跑的是哪个包"都成了假象 —— 已新增 `-UninstallFirst`，并**打印 `pm path` 与 `versionName` 确证装进去的到底是哪一个**。另把启动后静置从写死的 12 s 改为可配的 `-SettleSec`（默认 20 s）。**这三处都不是 App 的缺陷，而是"闸门自身会说谎"** —— 与 `ADR-22` 的主题是同一个。 |
| 顺带修掉的**发布脚本 5 处缺陷**（`tool/build_release.ps1`，为了回答"APK 在哪"而实际运行它时暴露） | 这个脚本**此前一行都跑不了**，而且修一层露一层：① **两处真实语法错误**：`"$abi: ..."` 被 PowerShell 解析成"带作用域限定符的变量名"（`$abi:`），必须写 `${abi}:` —— 它连**解析**都过不去。② **文件无 BOM 但含中文**：Windows PowerShell 5.1 按 ANSI/GBK 读 BOM-less 文件，中文注释与中文字符串被误解码，实测**同一文件 7 个解析错误 → 加 BOM 后 0 个**。已加 BOM 并在文件头写明**必须保留 BOM**（注意：用会丢 BOM 的编辑器改过之后要补回来）。③ **路径整体差一级**：`$App = Split-Path -Parent $PSScriptRoot` 得到的是 `<AcouDiet>` 而不是 `<AcouDiet>\app`，于是它会去找 `<AcouDiet>\android\key.properties`（真实位置在 `app\` 下）并把发布物归档到 `<工作区>\docs\release` —— **一个恰好也存在、但是另一个**目录。④ **`$ErrorActionPreference='Stop'` + 原生命令 stderr**：`flutter` 往 stderr 写镜像提示，PS 5.1 把它变成 ErrorRecord 并在 `Stop` 下**终止执行**，脚本死在 `[1/5] flutter analyze`。改为 `Continue`（本脚本每道闸门本来就是**显式 `throw`**，不依赖这个变量）。⑤ **`flutter analyze` 计数用的是错的符号**：脚本按 `'error •'` 匹配，而当前版本输出的是 `error - `（实测 21 warning / 60 info 全被记成 0）—— 也就是 `analyze: errors=0` **无论有没有 error 都会是 0**，那道"0 error 才准发布"的闸门是**装饰性的**。已改为 `error\s+[•\-]\s`，实测由 0/0/0 变为 **0 errors / 21 warnings / 60 info**。 |
| 诚实说明：以上 5 处**不是**本轮改动引入的 | 它们都在 `ADR-21` 之前就存在，只是**从来没有人真正运行过这个脚本**（`C-05` 记录的 release 证据来自直接执行 `flutter build apk --release`，见 `PHONE_INSTALL.md` §3）。本轮为了回答"APK 在哪、怎么装"而实际执行它，才逐层暴露。这也再次印证 `ADR-22` 的主题：**没被执行过的闸门，与没有闸门在证据上是同一件事**。 |
| 🚨 顺带暴露的**判据缺口** → ✅ **已补上** | `run_on_emulator.ps1` 原来的六项判据**不看模型是否加载**。本次是靠人工读 logcat 才发现的；若只看脚本的 `EMULATOR RUN: APP STARTED`，会得出"设备端一切正常"的结论 —— 而当时模型是加载失败的。**修法**：新增 `_toolchain\check_emulator_model_log.py` 并接入该脚本，成为**第七步独立判据**。它**双向**判定：① 出现缺陷签名即失败 ② **除非应用自己的 pid** 打出 `Initialized TensorFlow Lite runtime`，否则也失败 —— 这样"压根没尝试加载"就无法冒充"没看到错误"。接入后 `run_on_emulator.ps1` 判据从 **6 项变 7 项**。**并已证明该判据不是空转**：`_toolchain\selftest_check_emulator_model_log.py` 用真实 logcat 构造两个负例 —— 注入修复前缺陷签名 → exit 1；删掉初始化证据（静默 no-op）→ exit 1；真实 log → exit 0。**三种情形全部区分**。 |
| 已加入的回归防线 | `session_tests.dart` 的投放契约组新增 4 项断言：① 注册表把**字节**交给引擎（`engine.loadedBytes` 非空）② 交给的是**模型资产**而非模型卡（长度比对）③ 只有卡、没有 `.tflite` 时必须**被拒绝**而不是"加载成功" ④ fp32 档同样交出字节。第 ③ 项是本次缺陷在离线层的等价物：夹具只放模型卡时，旧断言会**通过**，而生产会失败。 |
| 边界影响 | 无 SSOT 变更、无模型卡变更、无 Mel 数值变更。`InferenceEngine.load` 增加一个**可选**具名参数（`FakeInferenceEngine` 与两处测试调用无需改动即编译）。`verify_all.ps1` **16 步仍全绿**；session 断言 **98 → 102**。 |
| 诚实边界 | ① 设备端证明的是**加载路径不再失败**（错误签名消失 + 应用进程自行初始化了 TFLite，且该判据已证明有区分力），**不是**"推理结果正确" —— 后者需要真实音频与自采跨域测试集，本仓没有。② 仍未验证的是**麦克风链路**（`P-01`…`P-04`）在真实麦克风上的表现。③ 该判据已接入 `run_on_emulator.ps1`（第 7 项），但它**只在跑设备时生效**，`verify_all.ps1` 仍是纯离线套件（无设备），故本缺陷的**离线**防线只有 `session_tests.dart` 那 4 项断言。 |

### ADR-23 ✅ 用户反馈的 7 项：用量按时长推算 / 饮品不计零食 / 首页四维同步 / 每日四维 / 检测实时行为 / 下拉刷新 / 切 Tab 先刷新

| 项 | 内容 |
|---|---|
| 来源 | 用户在真机试用后一次性提出 7 条 BUG 与改进（原文见 `AcouDiet/docs/reports/adr23_portions_dims_refresh.md` §1）。其中 3 条是**真实缺陷**（固定份量、液体算零食、首页四维与事实不符），4 条是**行为改进**（每日四维、实时行为行、下拉刷新、切 Tab 刷新）。 |
| ① 用量改为按时长动态推算 | 此前克/毫升是 `foods.json` 的**固定标准份量**（"1 碗（约 200g）"），一条 15 秒的记录与一条 10 分钟的记录显示同一个数字。裁定：知识库每条新增 `unit` / `standardAmount` / `amountPerSecond` / `minAmount` / `maxAmount` 五个字段，新增纯域服务 `PortionEstimator`：`amount = clamp(round_step(rate × duration), min, max)`、`kcal = round(portionKcal × amount / standardAmount)`。**无时长（`durationSeconds <= 0`）时回退标准份量并标注 `durationBased == false`** —— 不发明时长。`KcalResolver` 增加 `kcalForDuration`，SQL 聚合改为**逐条记录求和**（先按类求和再夹一次会得到不同的数，首页总额会与记录卡片对不上）。 |
| ② 液体不再算零食 | `MealWindows.isSnack(minutes)` 是**纯时间**判据（三餐窗口之外即零食），与吃了什么无关 —— 下午一瓶饮料既被算成"零食"，又被算进它自己的类别列，**同一条记录计了两次**。裁定：新增 `isSnackRecord(minutes, classId)` / `isMealSample(minutes, classId)`，液体（`class_labels` 里 `drink` 的位置，**由 SSOT 解析而不是写死 5**）既不是零食也不是三餐样本；`lateNight` **刻意保持纯时间**（"晚间进食"是一个时间指标）。SQL 的分钟直方图因此增加 `class_label` 分组。 |
| ③ 首页四维与事实不符 | 三处独立原因：**(a)** 首页评分用的是**当天窗口**，而 σ 需要同一餐段 ≥2 条样本、速度需要 ≥1 条带咀嚼指标的记录 —— 一天之内几乎不可能满足，所以「饮食规律性」「进食速度」长期显示 `--`；**(b)** 食物结构是 `30 × min(1, p/0.4)`，**一条面条记录就让 p=100% → 30/30 满分**；**(c)** 零食控制是 `20 × max(0, 1 − n/10)`，没有零食就是满分 20/20，而界面上没有任何东西解释这个满分是什么意思。裁定：首页评分窗口改为**最近 7 个本地日**（与「本周记录」和报告页同窗口，两页从此不可能给出两个数字）；结构维度在窗口记录数 < `minimumRecordsForDisplay`(3) 时**不可显示**（渲染 `--`，不把一条记录读成"结构完美"）；卡片底部新增**依据行** `记录 N 次 · 零食 n 次 · 有咀嚼指标 m 条`，让满分/空值都能被解释。文案随之改变：`今日健康评分` → `近 7 天健康评分`，`较昨日` → `较上一周期`。 |
| ④ 报告补每日四维 | 报告页只有"本周"一个聚合四维，而且**没有雷达图**（`ReportScoreHeader` 传的是 `showRadar: false`）。裁定：`ReportService.dailyScores(days)` 逐日给出当日汇总与四维，并给报告头部加回雷达。 |
| ④b 报告页改为**双分栏 + 滑动切换 + 默认每日**（用户后续追加） | 用户要求「每日」与「本周」**同一个按钮进入、左右滑动切换、默认先显示每日**。裁定：`ReportPage` 改为 `StatefulWidget` + `PageView`（`initialPage = 0` 即每日），AppBar 下加 `SegmentedButton`（只有滑动的话用户不知道有两个报告）；**每日**分栏 = 日期选择器 + 当日得分卡（含雷达，可下钻）+ 当日汇总（记录次数/估算热量/零食次数/食物类别）+ 按天四维列表；**本周**分栏 = 冻结的周报（趋势图/四维行/七项环比/建议）。AppBar 标题跟随分栏（`每日报告` / `本周`，后者是 `SPEC-U-04` 判据 1 的冻结标题）。`DailyScore` 随之扩展为"一天的完整汇总"（`recordCount`/`snackCount`/`classCounts`），`dailyScores` 改为**每天一次 `stats.summary(day)`** 取真实计数与热量（与记录页同一个聚合），日期键仍来自 `stats.trend(days)`（它负责序列契约**并读仓库时钟**，测试才可复现）。两侧读同一个 `ReportView`，因此每日与本周不会对同一数字给出两种口径。 |
| ⑤ 检测页行为行实时联动 | `BehaviorAnalyzer.finish()` 是唯一入口且会**封闭**分析器，因此咀嚼次数/时长/速度只在会话结束后出现。裁定：抽出 `snapshot({required int endMs})`（**不封闭**，同一套峰值管线），`DetectionSession` 每 2 个 patch（≈1 Hz）取一次快照并放进 `DetectionState.metrics`，`DetectNotifier` 每次状态更新都刷新行为行。**这是同一条代码路径**，实时读数与最终读数不可能是两套定义。 |
| ⑥ 全页面下拉刷新 | 首页/记录页已有 `RefreshIndicator`，报告页/我的/记录详情/自检面板/演示页没有；更关键的是**加载/空/错误分支渲染的是居中的 `StateView`，本身不可滚动**，在那种状态下根本拉不动。裁定：新增 `RefreshableBody`（把面板放进一个 `AlwaysScrollableScrollPhysics` 的单元素 `ListView`，并撑满视口保持居中），所有读数据的页面在两分支上都接入刷新。 |
| ⑦ 切 Tab 先刷新再呈现 | 原 `AcouNotifier.reload()` 走 `guard()`，在加载期间**保留旧值**（`AsyncValue.loading(previous)`）—— 对下拉刷新是对的（内容变暗而不是闪白），对切 Tab 是错的：用户会先看到**上一轮的旧数字**。裁定：新增 `reloadFresh()`，先 `publish(loading())`（丢弃旧值）再执行 reload；`AppShell._select` 在切到首页/记录/报告时调用它。「检测」是会话页，没有可加载的数据，**刻意不刷新**。 |
| 已写入 | `app/assets/foods.json`（6 条 + 五个新字段）、`food_info.dart`、**新增** `domain/service/portion_estimator.dart`、`food_knowledge_base.dart`（加载期校验五个字段 + 时长感知适配器）、`repositories.dart`（`KcalResolver.kcalForDuration`）、`sql_repos.dart`（逐条热量 + 直方图带类别）、`fake_repo.dart`、`acou_format.dart`、`records_presenter.dart`、`detail` 页、`settings_presenter.dart`、`detect_presenter.dart`、`summaries.dart`（`isSnackRecord`/`isMealSample`/`DailyScore`/`mealTimeStdDevMinutesOf`）、`health_score_service.dart`（Δ 改为**上一等长窗口**）、`report_service.dart`（`dailyScores`）、`score_view.dart`、`ui_strings.dart`、`score_card.dart`、`report_presenter.dart`、`report_page.dart`、`behavior_analyzer.dart`、`detection_session.dart`、`notifiers.dart`、`app_shell.dart`、六个页面的刷新、`audio_bridge.dart`（假桥的 `stoppedAtMs` 从此是个真实时刻） |
| 回归实测 | `flutter test` **110 → 116 全过**（新增 `test/ui/refresh_and_tab_test.dart` 5 项）；离线断言 **771**（PURE 174→**193**、SESSION 102→**121**、UI 377→**394**、DATA 57→**63**）；`run_offline_tests.py` 7 个可离线文件全过；`check_bridge_symmetry` / `check_l4_usage` PASS；`flutter analyze` **0 error**，且 issue 种类与 ADR-22 基线**逐条相同**（没有引入任何新种类）。 |
| ⚠️ 顺带修正的一处**测试夹具缺陷** | `session_tests.dart` 过去给 10 个 patch 全部传 `tStartMs = 0`（`FakeAudioBridge.emitPatch` 的默认值），于是行为分析器收到 10 段**时间戳完全重叠**的包络，算出的平均咀嚼间隔是 0.059 s 而不是 0.7 s —— 而这个数**只被断言过"非空"**，所以一直没暴露。现在 patch 带递增时间戳，实时读数为 **0.684 s / 正常**，与 FF-21e 的合成"每 0.7 秒一个峰"一致。**这不是本轮引入的缺陷，是夹具一直在骗自己。** |
| 诚实边界 | ① `amountPerSecond` 等五个参数是**知识库里的工程估计**，不是营养学测量值：每条记录的标准份量对应一次"典型进食时长"（面条 200 g ≈ 600 s、饮料 250 ml ≈ 60 s、薯片 30 g ≈ 120 s），区间上下限（`minAmount`/`maxAmount`）用来夹住外推，**没有实测语料可以标定**。② 进食时长用的是**会话时长**（首个有效帧到会话结束），它包含进食间的停顿；这正是要夹上下限的原因。③ 首页评分窗口改为 7 天是**产品口径变更**，它让四维可计算、让首页与报告一致，代价是"今日评分"这个提法不再存在（今日仍保留能量/次数/记录列表）。④ 每日四维在**只有 1–2 条记录的那一天**仍会显示 `--`（结构维度样本不足），这是有意的：不把一条记录读成结构满分。 |

---

| ⑧ 模型组 v1.1 交付包核对：**不改字节，只对齐标签** | 用户要求「`acoudiet_model_v1.1` 里是新模型，帮我替换好」。核对结果是**没有新权重**：交付包 `v1.1/models/acoudiet_fp32.tflite` 的 sha256 为 `705ffc62…560a`，与本仓当时已投放的 `acoudiet_fp32_v1.0.0.tflite` **逐字节相同**；交付包的 `feature_config.json` 与本仓 SSOT **36 项逐键相等**（Mel 33 项 + I/O 形状/类型 + 类别表），类别表与 FF-19 `MATCH`。因此 App 里跑的**一直就是 v1.1 的权重**，问题只在**命名**：卡片把版本记成 `1.0.0`，看上去像旧模型。裁定：按交付包的叫法重新投放为 **`acoudiet_fp32_v1.1.0.tflite`**（`tool/install_model.py --version 1.1.0`，逐字节校验通过、`verify_artifacts.py` exit 0），删掉被取代的旧文件名（`assets/models/` 是整目录打包，留着就是 4 MB 死重），并新增可复跑的核对脚本 `tool/compare_model_delivery.py`（逐字节比 `.tflite` + 逐键比 Mel 规格）。**没有采用 int8**：交付包的发布说明自己把 fp32 定为正式嵌入件（"此前 README 曾指向 int8，已作废"），与本仓既有选择一致。同时把 `session_tests` 里写死的 `v1.0.0` 改成**从模型卡推导文件名**（它此前会因版本号变化而失败，且失败原因与断言意图无关），并新增两条断言：卡里的 `tfliteBytes` 必须等于文件真实字节数、**`assets/models/` 里只允许存在一个 `.tflite`**。 |

### ADR-24 ✅ UI 按投放的界面示意图重构：**在 Flutter 内按图重画**，视觉照原图、口径仍按冻结规格

| 项 | 内容 |
|---|---|
| 来源 | 用户：「利用 semi-design 重建 UI 界面，然后我希望尽量按照我原来投放的 UI 示意图来重构」。示意图共 6 张：`软件UI界面设计图/1.png`（首页）、`2.png`（报告/本周）、`3.png`（检测）、`8.png`（饮食记录）、`9.png`（我的）、`10.png`（检测·Tab 版）。 |
| 两条裁定 | **A. 在 Flutter 内按图重构**（本仓交付物是 Android APK，必须能上手机）；**B. 视觉照原图，口径仍按冻结规格**（§2 已冻结的四维/六类/估算口径一个字不改）。 |
| ⚠️ 必须先说清的一处事实 | **Semi Design 是 React 的 Web 组件库**（`@douyinfe/semi-ui` 2.103.0，npm 实测可达），**Flutter 无法直接使用它的组件**。可用的是它的**设计规范**（间距 / 圆角 / 层级 / 卡片阴影 / 主色），落地载体仍是本仓的 `AcouTheme` 与 Flutter widget。它的官方指南已装入 DSH skill（`~/.dsh/skills/semi-design-guide/`，3 个文件与官方 git blob 逐字节相同）。若真要跑 Semi 组件，需要在本仓新建一个 React Web 工程，而那是**另一个交付物**，不在本次范围内。 |
| 采纳的「看」 | 薄荷→奶油的页面渐变；白色大圆角卡片 + 柔和投影（`radiusLg = 20`、`cardShadows`），卡片分隔由**阴影**承担，不再用描边；体育场形主按钮；选中 Tab 的薄荷圆角块（自定义 `AcouNavBar` 取代 `BottomNavigationBar`）；圆角图标块（`FoodIconBadge` / `softTileDecoration`）；大号分数（`scoreLarge = 44`）；检测页的薄荷圆盘 + 白色声波（`WaveCircle`）。 |
| 明确**拒绝**的「信息」（逐条核对，不是遗漏） | ① 5 轴雷达里出现**两个「脂肪」**且无「零食控制」→ `SPEC-U-01` 判据 1 冻结四轴；② 「食材多样性 8/12 种」→ 冻结口径里没有这个概念（README §8 用记录次数替代）；③ 「1286/2000 kcal」点值 → 与本仓「估算 + ±20% 区间」（FF-25）冲突；④ 苹果/面包/全麦命名 → FF-19 只有六类；⑤ 「EatSense」品牌 → 品牌冻结为 AcouDiet / 声膳；⑥ 「我的」作为第 4 个 Tab → `FF-23`/`ADR-12` 冻结第 4 个 Tab 是「报告」，「我的」是入口；⑦ 「已记录3餐」→ 本仓口径是**次数**，不是餐数。 |
| 逐屏落地 | **首页**：渐变 + `_BrandHeader`/问候语 + 评分大卡（四轴雷达，无第五轴）+ 两张并排迷你卡（能量带 ±20% 区间、本周记录次数）+ 麦克风圆盘 + 体育场按钮；缺口「食材多样性/目标 kcal」**不补**，见上表 ③。**记录页**（本次新增）：渐变页 + 顶栏统计条（今日热量 / 已记录 / 零食，白卡三项）+ 本周小结卡 + 日期头（`今天` + `M月d日` + 星标）+ 卡片之间的时间轴圆点（`TimelineConnector`）。**检测页**：薄荷圆盘 + 白色声波 + 预测卡（食物图标块 / 中文名 / 属性 chip / 大号置信度）。**我的**：白卡头（64 dp 圆形头像）+ 条目白卡 + 成就。**报告页**：按新视觉语言重写（每日 / 本周双分栏、PageView 滑动、默认每日）。 |
| ⚠️ 记录页的餐段 chip 是**本次新增的交互**，且**多出两个 chip**（用户裁决 B 的必然结果） | 示意图 8 有「早餐 / 午餐 / 晚餐 / 零食」四个 chip。但 `ADR-23` 之后这四类**不再是全集的划分**：15:40 的一瓶饮料既不是零食也不是三餐样本 —— 若把它算进「零食」，chip 的筛选结果就会与**它正上方**统计条里的「零食 n 次」互相矛盾。裁定：chip 变成 **`全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品` 六个**，`RecordMealBucket.of` 直接调用冻结判据（`isSnackRecord` / `liquidClassId` / 三个窗口），因此它是**全且互斥**的划分，一条记录必属且只属一类。`全部` 是示意图上没有的：示意图的筛选器**没有回到全集的出口**，一个能把全部记录藏起来又退不出去的筛选器是陷阱。筛选**只在已加载的日期分组上生效**，不碰仓库、不碰口径；统计条始终描述「今日」，与筛选无关（这正是它第一项叫「今日热量」的原因）。 |
| 顺带修正的一处**显示缺陷** | 检测页预测卡此前显示的是**类别英文标签**（`chips 91%`）。它没有违反任何闸门（六类是冻结的、标签也确实来自 SSOT），但界面上出现英文标识显然是投放上的缺陷。裁定：`DetectPresenter.displayNameOf` 改为经知识库取 `FoodInfo.zhName`（拿不到时回落到冻结占位，不猜中文名）。 |
| 顺带修正的一处**闸门缺陷**（刷新指纹时暴露） | `_toolchain/check_apk_contents.py` 的「release 包必须没有 `INTERNET`」检查**此前永远不会失败**：二进制 AXML 的字符串池是 **UTF-16**，而它搜的是 ASCII 字节，于是对**任何**包都打印 `False`。本次刷新 APK 指纹时被证伪 —— **profile 包**（`aapt2 dump badging` 明确列出 `INTERNET`）同样被打印成 `False`。**一个不可能失败的闸门在证据上等于没有闸门**（与 `ADR-22`/`ADR-23` 同一主题）。已改为两种编码都搜并打印 `ascii=/utf16le=` 两个分量，并新增 `--expect-no-internet`：带上它且真的搜到时返回 **1**。负控实测：release + 该开关 → `False`/`exit 0`；profile + 该开关 → `True`/`exit 1`。 |
| 已写入 | 主题与共享件：`theme/acou_theme.dart`（渐变/阴影/圆角/按钮与 chip 形状/`starGold`）、`theme/acou_format.dart`（`dayDateLabel`）、`widgets/waveform_view.dart`（`WaveCircle`）、`widgets/record_card.dart`、`widgets/food_icon.dart`；页面：`pages/home/home_page.dart`、`pages/detect/detect_page.dart`、`pages/records/records_page.dart`（重写：`MealFilterRow` / `MealFilterChip` / `RecordsStatsBar` / `TimelineConnector` / `FilteredEmptyView` / 带日期与星标的 `DayGroupHeader`）、`pages/profile/profile_page.dart`、`pages/report/report_page.dart`、`pages/shell/app_shell.dart`（`AcouNavBar`）；纯展示：`presenters/records_presenter.dart`（`RecordMealBucket` + `mealBucketLabel` + `bucketOf` + `RecordDayGroup.dateLabel`）、`presenters/detect_presenter.dart`（中文名）、`presenters/ui_strings.dart`；工具与文档：`_toolchain/check_apk_contents.py`、`docs/reports/adr24_ui_rebuild.md`、`docs/demo/PHONE_INSTALL.md`、`docs/compliance/C-05_regression_checklist.md`。**补齐轮追加**：`widgets/advice_list_item.dart`（渐变卡）、`pages/report/report_page.dart`（`RecentRecordsSection`）、`pages/profile/profile_page.dart`（`WeeklyOverviewPanel`）、`presenters/report_presenter.dart`（`snackCount` / `meanChewIntervalSeconds` / `recentRecords` / `meanChewSpeedText`）、`presenters/settings_presenter.dart`（三宫格文案与降级）、`state/notifiers.dart`（报告页多读 `chewStats` + 最新 6 条；我的页读同一窗口）、`domain/service/behavior_analyzer.dart`（`speedGradeFor` 公开化）、`test/ui/overview_and_recent_test.dart`、`tool/pure_tests.dart`（速度分档边界 5 项）、`tool/ui_presenter_tests.dart`（三宫格 + 最近记录 6 项）、`SPEC-U-04` §1.2/§7、`SPEC-U-05` §1.2/§7。 |
| 🚨 事故：**自绘底栏把整屏吃掉**（用户反馈："这UI感觉完全没变换啊"） | 真机/模拟器实测症状：界面几乎空白，左侧一条贯穿全屏的薄荷长条。**根因**：`AcouNavBar` 选中项的 `Column` 用了默认的 `MainAxisSize.max`，而 `Scaffold` 把 `bottomNavigationBar` 的可用高度当作**整屏** —— 于是选中块撑满整屏，body 被压成 0 高。被替换掉的 `BottomNavigationBar` 自己管高度，这个隐含契约在自绘时丢了。**修复**：`barHeight = 56`（显式内高）+ `tileWidth = 76`（选中块不随槽位拉伸）+ 内层 `mainAxisSize: MainAxisSize.min`。 |
| 🚨 为什么 **124 项 widget 测试全绿**也没抓到（本次最该记的一条） | 既有测试**要么单独 pump 一个页面**（页面自带 `Scaffold`），**要么单独 pump 一个组件**；**没有任何一个测试 pump 过 `AppShell` 本身**，而缺陷只存在于 shell 里那一处。这与 `ADR-22` 的「没人跑过的闸门等于没有闸门」是同一件事，只是从构建管线搬到了测试套件。**新增两条防线**：`test/ui/app_shell_layout_test.dart`（底栏高度 < 140、首页图标高 ≤ 24、`HomePage` 高 > 300、点记录后 `currentIndex == 2`）与 `test/ui/page_chrome_test.dart`（五个顶层页面都必须画 `AcouTheme.pageGradient`）。 |
| 第二条防线**第一次跑就抓出第二处缺口** | `page_chrome_test` 当场报 `detect is missing pageGradient`：① **报告页**第一轮漏了渐变背景（本轮补上，并为工具栏留出顶部内距）；② **检测页的 C-03 门禁分支**是唯一不画渐变的页面（该分支在无资产的测试夹具下就是渲染的那一支）—— 也已补上同一套渐变，于是"全 App 都换了背景"**没有例外**，测试不必特判。 |
| 顺带处理的一处**取包陷阱** | `_toolchain/tmp/app-release-4abi.apk`（2026-09-12 为 x86_64 模拟器打的 **4 ABI release 包**）留在原处，它是 **ADR-24 之前的旧界面**，但签名与 `dist` 相同 —— 装到手机上**不报任何错**。已改名为 `…-PRE-ADR24-OLD-UI-DO-NOT-INSTALL.apk`，并新增 `tool/ui_fingerprint_check.py`：对**任意** apk 回答"里面是哪一版 UI"。该工具带**正控**（每版都有的字符串），因为 Dart 字符串在 `libapp.so` 里是 **UTF-16** —— 用 UTF-8 搜中文必然全 miss，会把"新 UI 没进包"和"搜索方法错了"混为一谈（与 `check_apk_contents.py` 那处 UTF-16 假阴性同源）。实测：`dist` 的 release 包 → `ADR-24 UI / exit 0`；旧 4 ABI 包 → `PRE-ADR-24 (missing 8, stale titles 1) / exit 1`。 |
| 回归实测 | 离线断言 **795 全过**（PURE **198**、SESSION **124**、UI **410**、DATA **63**）；`flutter test` **131 全过**（`overview_and_recent_test` 5 + `app_shell_layout_test` 2 + `page_chrome_test` 5）；`flutter analyze` **0 error**，issue 种类与 `ADR-23` 基线逐条相同。周边闸门：`run_offline_tests.py` 7/7、`verify_artifacts.py` **PASS**、`verify_docs.py` **BLOCKER × 0**、`check_bridge_symmetry.py --strict` **PASS**、`check_l4_usage.py --strict` **PASS**。两个 APK 重打并逐项复验：release 25,533,450 B / sha256 `6fb5ced2…af37`（arm64 单 ABI、包内模型 sha256 等于出厂件、无 `INTERNET`、`apksigner verify` 与 `zipalign -c -p 4` 退出码 0）；profile 96,995,714 B / sha256 `aa3e2374…0cd1`。⚠️ release 包连续四次都是同一字节数而 sha256 每次都不同——**判断装的是哪个包只能看 sha256，不能看大小**。 |
| 后续补齐（用户追加：「报告页那两块和我的页三宫格补齐」） | 三块全部落地，且**没有发明任何指标**：① **健康建议卡**改成示意图 2 的圆角渐变卡（`AcouTheme.adviceGradient` + 前导勾选图标，文案与免责声明原样保留）；② **最近识别记录**是记录页**同一 7 日窗口**最新 6 条的横滑瓦片，用**同一套** `RecordCardText` 模板，点开进同一条详情页 —— 它是普通记录列表的一个**视图**，不是新口径；③ **本周健康数据概览**三宫格 = `WeekSummary.recordCount` / `snackCount` + 窗口平均咀嚼间隔经 `BehaviorAnalyzer.speedGradeFor` 得到的档位词，窗口与报告页「本周」**完全相同**。 |
| ⚠️ 三宫格唯一的**新代码**是一处提权，不是新口径 | 档位词的阈值此前只存在于 `BehaviorAnalyzer._speedGrade`（私有，会话路径专用）。新增第二个调用者（窗口聚合）时没有复制一份映射，而是把它提为 **public static `speedGradeFor(seconds, {config})`**，会话路径改为 `speedGradeFor(avgInterval, config: cfg)` —— **唯一的实现**，因此"一次会话"和"七天窗口"不可能对「正常」给出两种定义。`BehaviorAnalyzer` 的 `cfg` 是**实例字段**且可注入，所以这个函数必须接受可选 `config`（首版写成无参静态函数，编译期即报 `Undefined name 'cfg'`，已改正）。 |
| ⚠️ 一处**刻意不照抄示意图**的地方（对比度优先于像素级还原） | 示意图 2 的「健康建议」卡是**中绿底 + 白字**，实测约 **2.5:1**，违反 U-06 §8（body 文字 ≥ 4.5:1），也会打挂既有的对比度断言。裁定：**抄形状与渐变，不抄字色** —— 卡片用浅薄荷渐变（`mintSoft → #D3F2E5`），文字仍是 `ink`（12.6:1）。`test/ui/overview_and_recent_test.dart` 里专门断言"文本颜色 == `AcouTheme.ink`"，把这条偏离钉住，防止后人"修好"成白字。 |
| 诚实边界 | ① 报告页与我的页的三块已补齐；仍未实现的只剩示意图里**已被逐条拒绝的"信息"**（五轴雷达、食材多样性、目标 kcal 点值、EatSense 命名、「我的」作为第 4 个 Tab）。② **三宫格是一处产品口径的扩张**：它把「本周」的口径搬到了「我的」，改变了 `SPEC-U-05` 判据 9 原有的 `rg` 禁词表（`本周健康数据概览` / `平均咀嚼速度` 由"禁止"改为"必须"），该判据已同步修订。③ 卡片阴影、圆角、渐变是 **Flutter 的近似**；没有做像素级比对。④ **视觉仍未在真机上逐屏核对**（设备截图对比仍是待办），本轮只有离线断言 + `flutter test` 渲染断言。⑤ 时间轴圆点、星标、chip 配色属于装饰；携带数值的文字一律仍是 `ink` / `gradeGood`。 |

---

### ADR-25 ✅ 报告页「当日四维评分」恒无分数与评价：一个 7 天窗口的显示门槛被套到了 1 天窗口上

| 项 | 内容 |
|---|---|
| 来源 | 用户：「报告那里当日四维评分的分数和评价都没有，修复这个BUG」。 |
| 症状与**取证**（先复现，再动手） | 新增诊断 `AcouDiet/tool/probe_daily_score.dart` 实跑 `FakeRepo.demoFixture()`（每天 4 条记录、其中 3 条带咀嚼指标 —— 一天能做到的最好情况），结果 **7 天全部**是：σ = `null`、食物结构 30/30、零食控制 18/20、进食速度 15/20，而**总分与评价都是 `--`**。即「分数和评价都没有」不是边界情况，而是**恒定路径**。 |
| 根因 | `ReportService.dailyScores` / `trend` 把**每一天单独**当作评分窗口（`DateRange(dayStart, dayStart + 86400000)`），而 `ScoreView.of` 的显示门槛要求 σ、结构（≥3 条记录）、速度（有咀嚼指标）三者齐备才给总分。**单日 σ 在正常饮食下不可定义**：一天通常是"一顿早饭 + 一顿午饭 + 一顿晚饭"，σ 却要**同一餐段 ≥2 条样本**（两顿早饭）。于是总分恒被关闭。这是**口径错误**（把一个为 7 天窗口设计的显示门槛套到了 1 天窗口上），不是渲染缺陷。 |
| 同一根因的**第二个症状** | `trend()` 的评分线也是逐日隔离评分，而 kernel 对 `σ == null` 记 **0 分**（`score_formulas.dart`），所以趋势图的"评分"线是一条**系统性少掉整个 30 分规律性维度**的低值曲线（demo 数据下恒为 63），而不是真实分数。 |
| 裁定 | 报告页的**每一个日度数字（每日卡 / 每日列表 / 趋势图评分线）一律按「以该日为最后一天的最近 7 个本地日」窗口计算**。三条理由：① 这是**唯一**能让四维齐备、总分与评级成立的窗口（σ 需要多天）；② 它**就是首页评分卡今天用的那个窗口**（`HomeNotifier.scoreWindowDays = 7`），因此「今天的每日评分」与首页「近 7 天健康评分」是**同一次计算**，不可能给出两个数；③ **不发明新公式、不做部分分** —— 部分分正是 `ScoreView` 明确拒绝的"编造数字"。实现：`ReportService.dailyScoreWindowDays = 7` + 公开的 `ReportService.scoreWindowFor(dayStart)`，`dailyScores` 与 `trend` 共用。 |
| 界面必须**说出口径** | 一个覆盖 7 天的数字不能被读成"那天的分"。因此：卡片标题 `当日四维评分` → **`近 7 天评分（截至该日）`**；列表标题 → `每日评分`，说明改为「该日及之前 6 天」；卡片下注写明"卡片里那行『记录 N 次』是这 7 天的，下面的『当日汇总』才是该日自己的数据"；趋势图评分轴下新增「评分口径：该日及之前 6 天（近 7 天）」。四维依据里的 `windowDays` 本来就是可见证据。 |
| 已知边界 | 序列中**最早的那一天**若其前 6 天没有任何记录，它的窗口只有自己 → σ 仍不可定义 → 该日仍显示 `--`。这是"还没有历史"，不是缺陷（用户用满一周后即消失）。 |
| 顺带修掉的一处**乱码** | `fake_repo.dart` 的 demo 指标里 `speedGrade: '姝ｅ父'`（应为 `'正常'`）—— 早先一次 PowerShell 管道编辑损坏 CJK 时漏掉的第二处，只在演示模式下显示。已修，并对 `lib/**/*.dart` 扫了一遍乱码特征（`姝|锛|鈥|鎴|ｅ|锟…`）：**全仓只此一处，现已清零**。 |
| 已写入 | `domain/service/report_service.dart`（`dailyScoreWindowDays` / `scoreWindowFor` / 两个调用点）、`presenters/ui_strings.dart`（4 改 1 增）、`pages/report/report_page.dart`（趋势图口径行）、`data/fake_repo.dart`（乱码）、**新增** `tool/probe_daily_score.dart`、`tool/pure_tests.dart`（+4）、`tool/ui_presenter_tests.dart`（+3）、`docs/reports/adr25_daily_score_window.md`、`SPEC-U-04`。 |
| 回归实测 | 离线断言 **802 全过**（PURE 198→**202**、SESSION **124**、UI 410→**413**、DATA **63**）；`flutter test` **131 全过**；`flutter analyze` **0 error**。用户可见的那一条断言由 `-- / --` 变成 **`9月10日: 81 / 良好`**。 |
| 诚实边界 | ① 这是**口径 bug**：修复改变了报告页日度数字的含义（从"当日隔离评分（实际上恒为 `--`）"变为"截至该日的近 7 天评分"）。② `trend()` 的评分线随之改变 —— 同一根因，属于修复而不是"顺带改行为"。③ 单日**自己的**个别轴仍可能是 `--`（该日没有咀嚼指标 → 进食速度 `--`），但总分因窗口齐备而显示。④ 若用户更希望"严格只按当日、缺一轴就不给总分"，那是另一个口径 —— 本 ADR 记为**已否决**，因为它正是本次缺陷本身（单日 σ 不可定义 ⇒ 永远没有总分）。 |

---

### ADR-26 ✅ 建议文案引入端侧模型润色：**含数字的句子可以改写，但数字必须逐字保留**

| 项 | 内容 |
|---|---|
| 来源 | 用户先问「引入一个小模型来分析报告并给客户专业建议可行吗」，再选定基座 `smolify/smolified-nutriai-distilled-nutritionist`（Gemma3-270M 衍生），最后拍板「**甲：放开数字句**」。 |
| 背景约束 | `SPEC-A-02 §1.3` 原文「不接入 LLM 或任何网络服务」。**本 ADR 不解除网络条款**：所有推理均为设备内 `llama.cpp`，无网络出口，release 权限集合仍为 `{RECORD_AUDIO}`、仍无 `INTERNET`（`SPEC-C-01 §7` 判据 2 不受影响）。改动的是「是否允许端侧模型参与文案生成」这一条。 |
| 症状（**先复现，再动手**） | 新增 `app/tool/probe_polishable_advice.dart` 实跑演示数据（命中规则 1/2/3 的那一周），规则引擎产出 5 条建议，**可改写条数 = `0 / 5`**。原因：真实建议**每条都含数字**（连「**两**餐之间」的「两」都被护栏算作数词），而原设计的 `_targetsFor` **刻意排除含数字的句子**。于是润色层**没有任何东西可改** —— 换任何模型都无效。 |
| 根因 | 「数字只能由 App 填充」这条正确原则，被实现成了**最粗的代理判据**：「含有数字字符 ⇒ 不送模型」。代理判据与真实目标（数字不被模型改动）不等价 —— 它把「必须保留数字」的句子一并禁掉了，而**所有的建议都是这种句子**。 |
| 裁定 | 判据从「**禁止出现数字**」改为「**数字序列必须与原文完全相等**」（个数、顺序、逐字）。同时保留**无数字变体**（`validate`）供"从零生成"的场景使用 —— 两种场景需要相反的判据，不能共用一个。 |
| 为什么这是**可判定**的而不是"再信模型一次" | 数字能改对是概率问题（实测 Qwen3.5-0.8B 在 4 条真实建议上 **3/4 保留正确**，1 条把「有 **3** 次进食发生在晚间」改写成「…睡前 **1** 小时」，**凭空多出一个数字**）。而"数字序列相等"是确定性检查：`numbers()` 按出现顺序抽取阿拉伯数字串（含小数/千分位）与中文数词，两个序列必须完全相同，**顺序敏感**（对调 `[3,9]`/`[9,3]` 会被判为改动，因为那意味着数字与它修饰的对象错位）。不相等 → 整条回落规则文案。 |
| 变更文件 | `app/lib/domain/service/advice_text_guard.dart`（新增 `numbers()` / `validateStructure()` / `validatePreservingNumbers()`；`validate()` 保留为无数字变体；抽出 `chineseNumerals` 常量）、`app/lib/domain/service/nutrition_advice_service.dart`（`_targetsFor` 只排除 `general`；逐条校验改用 `validatePreservingNumbers`）、`app/test/domain/nutrition_advice_test.dart`（+8 断言，含顺序敏感、个数不符、数字改动、医疗红线与长度仍生效）。 |
| 实测（本机，2026-09-13） | 模型 `Qwen3.5-0.8B-Q4_K_M`（507.8 MB，经 `hf-mirror.com` 取得）；`llama.cpp` b10937；贪心解码，`--reasoning off`。真实建议改写后数字保留 **3/4**；P0-1 中文输出**通过**（例：「吃饭的时候稍微慢点，别一口气吞下去啦。」）。 |
| **已知边界（必须写出来）** | ① 通过率 3/4 意味着**约四分之一**的建议会回落到规则文案，同一份报告里可能**两种句子风格并存**（模型改的 + 原样的）。这是可用性代价，不是缺陷。② 数字判据**逐字严格**：模型把「5 次」改写成「五次」会被判为改动而回落（宁可回落，不可含糊）。③ 40 字上限**实测会被顶到**（4 条里 1 条 47 字），超长即回落。④ 「两/二/三…」按**单字**计数而非解析成数词，因为有意的：解析规则一复杂就会有边界争议，而本判据只需"同一套规则比两次"。 |
| 诚实边界 | 本 ADR **只解决"有没有东西可改"**。它**不**证明润色后的文案"更好"——P0-3（优于纯规则基线）仍是**未做**的人工盲评。也不改变"引入端侧 LLM"对 `API-05 §9.1 T1` 的定性问题（该条讲的是**云端** LLM 健康助手；端侧推理无网络出口，需另行登记）。 |
| 顺带修掉的**两个自身缺陷** | ① 护栏第一版把「慢**一点**」的「一」判成数字 → 所有正常建议都改不动（本层形同虚设）；改为「一 + 口语量词（点/些/下/会/阵）放行」。② 验证脚本第一版用 `split(marker, 1)` 提取模型输出，把**回显的 prompt** 当成模型输出，得出"4/4 通过"的**假结论**；修正为按最后一个标记切分 + 过滤 `(truncated)` 回显行后，真实结果是 **3/4**。 |

---

### ADR-27 ✅ 自检清单由 **14 项扩为 15 项**：新增「建议模型可用」（**部分推翻 ADR-14 的闭集裁定**）

| 项 | 内容 |
|---|---|
| 来源 | 用户实测 v1.1.0 后问「哪个部分是 qwen 模型发挥的地方，你是不是没写相关的前端 UI」。核查后确认：**端侧建议模型在界面上没有任何落点**。 |
| 症状与**取证** | 全仓检索 `modelId` / `runtimeVersion` / `degraded` / `fromModel`：**presentation 层一次都没出现**。数据流是 `PolishOutcome`（domain，带全部诊断字段）→ `notifiers.dart` 显式转成 `Advice(dimension, text, priority)`（**诊断字段在此丢弃**）→ `AdviceItemView`（只有 4 个字段）→ 建议卡只渲染文字。而 `LlmEngine.status()` 全仓**只有 1 处调用**（`NutritionAdviceService.polish()` 内部），**没有任何页面问它**。 |
| 根因 | `ADR-14` 把自检清单冻结为 **14 项闭集**且明令「不得加进去」。代码里有一行注释直说了后果（`demo_controller.dart`）：*"The runtime version rides along in this item's `observed` text rather than becoming a fifteenth item: ADR-14 freezes the self-check list at 14"*。于是模型**只能**藏在识别模型那一项的 `observed` 字符串里，或者干脆不可见 —— 后者的结果是用户无法区分「模型在工作」与「模型没装」。 |
| 裁定 | **自检清单扩为 15 项**，在**末位**新增 `adviceModel`（标签「建议模型可用」）。理由：① 一个"可选增强"必须有**可观测的落点**，否则用户永远无法确认它在工作（用户已连续两次反馈"看不出来"）；② 自检面板本就是"技术状态"的归属地，放这里不污染报告页；③ 该项**失败不是故障** —— 报告页会退回归则文案，因此不得并入 `modelSideKeys`（那组键会把结论导向「模型侧问题」，而建议模型与识别能力无关）。 |
| 为什么是**部分**推翻 | `ADR-14` 的实体裁定是「**`ambientNoise` 不是自检项、不得加进去**」（理由：那是进场前的人工 SOP，App 无法自测）。**这一条仍然有效**。本次只推翻它依据里的「14 项闭集」这一条计数约定。`ADR-14` 的 ②③ 两条理由（App 测不了环境噪声 / SOP 本来就在流程里）与原裁定都不受影响。 |
| 已写入 | `domain/model/demo.dart`（`SelfCheckKeys.adviceModel` + `labels` + `all` 15 项；类注释与 `SelfCheckItem` 文档同步）、`domain/service/demo_controller.dart`（新增可选构造参数 `adviceModel: LlmEngine?`，`runSelfCheck()` 追加第 15 项）、`presentation/presenters/selfcheck_presenter.dart`（`of()` 的 "fifteen frozen keys" + `fieldActionFor` 新增分支）、`presentation/state/app_services.dart`（把 `llm` 传给 `DemoController`）、`tool/session_tests.dart`（2 处 14→15）、`tool/ui_presenter_tests.dart`（6 处：项数、字段组、行数、编号 1–15、失败计数 5→6、短报告行数）。 |
| 回归实测 | SESSION **124 全过**、UI **413 全过**；离线 `app/test` 10 文件全过；PURE 202 / DATA 63 不变。**改这一条确实会动测试** —— `session_tests` 与 `ui_presenter_tests` 各有硬编码的 14，第一次跑就红了两条，这正是它们存在的价值。 |
| 该项的**判据语义** | `passed` = 模型**可用**；`observed` 三态可区分：可用时 `"<文件名> · <运行时版本>"`；不可用时 `"不可用: <原因>"`（把 `LlmStatus.detail` 带出来，区分「未随包提供」与「加载失败」）；未注入引擎时 `"未启用"`。`hint` 明确写「本项不影响演示」——与第 3 项（识别模型）的口径必须区分开：**识别模型挂了要禁止演示，建议模型挂了只需知情**。 |
| 诚实边界 | ① 这是**用户可见的界面变更**（自检面板多一行），不是纯内部改动。② 它**不**证明润色质量 —— `P0-3`（优于纯规则基线）仍是未做的人工盲评。③ 面板显示"可用"只说明**模型能加载**，不代表每次改写都通过护栏；逐条通过率是另一件事（见 `ADR-26` 的 3/4）。④ 本次**未**动 `SPEC-M-04` / `API-04` 的 14 项冻结描述 —— 那两份文档需要走 `SPEC-C-03` 变更传播才能同步，本 ADR 只落了代码与测试；**文档同步是未完成项**。 |

---

### ADR-28 ✅ 首页「AI 周综述」：**全 App 唯一由端侧模型生成新文字的功能**（新增用户可见功能）

| 项 | 内容 |
|---|---|
| 来源 | 用户：「我需要你在UI界面写出一个利用了qwen模型的功能界面放在首页或者其他位，你必须知道在哪里。」 |
| 为什么需要它 | `ADR-26` 的润色层**只改写已有句子**，用户完全看不出模型在工作（已连续两次反馈"没有变化"）。经核查，模型在界面上**零落点**：`PolishOutcome` 的诊断字段在 `notifiers.dart` 就被转成纯 `Advice` 丢弃了。`ADR-27` 补了自检第 15 项（技术可见性），但那不是**功能**。本 ADR 补的是一个用户真正用得上的功能。 |
| 位置 | **首页**，位于「开始 AI 检测」按钮与「今日记录」之间（`home_page.dart`）。选首页而非报告页：报告页已有润色层，首页此前**没有任何**模型相关功能。 |
| 功能 | 用户点「生成周综述」→ App 把一周数据压成**定性档位** → 端侧模型写两到三句中文总结 → 经护栏校验后显示，并标注来源（「由本机模型生成」/「本机模型不可用，显示默认提示」） |
| **关键设计：喂给模型的事实不含任何数字** | `WeeklyReviewService.factsOf` 先把数值判成档位（`偏多`/`适中`/`充足`/`数据不足`…），提示词里**一个数字都没有**。理由：实测证明模型**不遵守**"不要写数字"的指令（明确要求后仍把 `0.4` 抄回输出）。**结构性隔离 > 概率性约束**。 |
| 为什么这与 `ADR-26` 用**不同的**数字判据 | 润色层有原文可对照，所以判据是"数字序列完全相等"；本功能**没有原文**，数字只可能来自编造，所以判据是"**禁止任何数字**"（`AdviceTextGuard.validateGenerated`，上限 80 字）。两个判据方向相反，**不能共用一个方法**。 |
| 不自动生成 | 首次要加载模型 + 落盘 508 MB 权重（几秒到十几秒）。放在首屏自动跑等于让首页为可选功能买单。改为**用户点按钮触发**。 |
| 回落 | 模型不可用/输出不过校验 → `WeeklyReviewService.fallbackText`（一句**与数据无关**的话：「本周记录已保存，继续记录可以看到更完整的变化。」）。刻意不做任何判断——没有模型时 App 本来就没有能力做这段总结，编一句出来就是造假。 |
| 共用引擎实例 | `AppServices` 把同一个 `LlmEngine` 同时给润色层与周综述：一个 `LlamaCppLlmEngine` 持有已加载的 llama.cpp 句柄与权重文件，各建一个实例等于两份运行时状态。二者都在主 isolate 上串行调用，共享安全。 |
| 顺带修掉的两个自身缺陷 | ① 护栏的 `一` 白名单只收 `点些下会阵`，于是**提示词自己**里的「一段」「一周」「一项」「一句」被 `numbers()` 判成数字，`numbers(prompt)` 不为空 —— "约束文字必须满足它约束的规则"这条被自己违反了；补入 `段周项句般种条起样直定`。② `_clean()` 用正则 `[-*•]` 剥离列表符号，Dart 的 `RegExp` 对字符类里的非 ASCII 抛 `FormatException: Invalid group`（`\u2022` 转义写法同样失败）—— 一个"清理排版"的小工具成了崩溃点；改为逐字符剥离。 |
| 回归 | 离线 `app/test` **12 文件全过**（新增 `weekly_review_test.dart` 9 条、`confirmation_reject_test.dart` 3 条）；PURE 202 / DATA 63 / SESSION 124 / UI 413 全过。 |
| 诚实边界 | ① **P0-3（优于纯规则基线）仍未做** —— 本功能只证明"模型能产出合规文本"，不证明"比没有模型更好"。② 模型可能写得很空泛（0.8B 能力有限），这属于质量而非合规问题。③ 「AI 周综述」会进入用户可见界面，是**新增功能**而非内部改动；相关 SPEC（`SPEC-U-01`）尚未同步。 |

---

### ADR-29 ✅ 检测页「否」按钮**必然报错**的缺陷修复（恒定路径，非边界情况）

| 项 | 内容 |
|---|---|
| 来源 | 用户：「还要声音检测的时候，对物品判断是否的按键有问题会报错给我修复这个BUG」。 |
| 症状 | 检测页出现「疑似 XX，请确认？」时，点**「否」必然进入错误态**。 |
| 根因（三层，全部可指认） | ① `ui_strings.dart` 只有「是」/「否」两个按钮；② 页面的「否」接的是 `answerConfirmation(accepted: false)`；③ 该方法要求 `alternativeClassId`（用于改判到另一个类别），而 **v1.0 裁掉了选类别 UI（`X-02`）**，所以调用方永远传不出这个参数 → 走进 `classId == null` 分支抛 `ACD-DB-004` → 被 `DetectNotifier` 捕获后 `_setState(DetectUiState.error)`。**这不是边界情况，"点否"100% 触发。** |
| 裁定 | 把"**拒绝一个低置信建议**"与"**改判成另一个类别**"拆成两个方法：新增 `DetectionSession.rejectSuggestion()`（不记录、不抛错、把问题关掉），`answerConfirmation(accepted: false)` 仍要求 `alternativeClassId`（接口契约不变，改判场景将来可用）。页面「否」改接前者。 |
| 为什么不记录一条 | 拒绝时不指定类别，若记录就必须**猜**一个类别 —— 那正是"从不猜食物名"（`U-06 §2.4`）所禁止的。所以拒绝 = 丢弃该建议，不产生记录。 |
| 为什么"问题被关掉"要显式做 | 聚合器每个 patch 都会重算；若不把阶段降回 `observing`，两个按钮会在用户已作答后继续停留在屏幕上，第二次点又撞前置条件。新增 `confirmationDismissed`，并在每个新 patch 到达时清零 —— 所以「否」是**本次丢弃**，不是永久静音。 |
| 错误码归属（顺带修正） | 原实现把参数校验放在前置检查**之前**，于是空会话下也报 `ACD-DB-004` —— 让"状态不对"看起来像"调用方参数写错"。已把 `_requirePendingConfirmation()` 提前，现在没有待答问题一律报 `ACD-SESS-002`。 |
| 已写入 | `domain/service/detection_session.dart`（`rejectSuggestion` / `_requirePendingConfirmation` / `confirmationDismissed`）、`presentation/state/notifiers.dart`（`DetectNotifier.rejectSuggestion`）、`presentation/pages/detect/detect_page.dart`（「否」改接）、**新增** `test/domain/confirmation_reject_test.dart`（3 条）。 |
| 测试为什么测"契约"而不是"按钮点击" | 驱动真实会话来稳定停在 `lowConfidence` 需要让 EMA + 连续计数恰好越过两个阈值，对参数很敏感（本次实测就写出了一个恒停在 `observing` 的探针）。因此把断言放在**契约层**（两个入口在空会话下都必须报状态错误、且**不得**报 `ACD-DB-004`），更稳且不易随评分参数漂移。**诚实说明：端到端"点否不报错"没有自动化测试覆盖**，靠的是接线改动 + 契约断言。 |

---

### ADR-30 ✅ 报告页每日范围删掉一处重复日期，并**刻意违反**一个 SPEC 冻结文案

| 项 | 内容 |
|---|---|
| 来源 | 用户：「每日报告的各餐界面日期显示重复了」。 |
| 事实 | 每日范围里同一天出现**三处**：① 「选择日期」的 chips（`_DayPicker`）；② `ScoreCard` 的标题（`day.dateLabel`）；③ 「每日评分」列表每行行首（`_DailyListSection`）。 |
| 裁定 | 删掉 ② 上方那行独立标题 `UiStrings.reportDailyScoreTitle`（原文案「**近 7 天评分（截至该日）**」）。`ScoreCard` 自己的标题保留日期 —— 那是 `ADR-25` 要求"把窗口口径说出口"的载体，不能删。 |
| **刻意违反** | `SPEC-U-04` 规定该标题必须渲染。本 ADR **明确记录了这次偏离**，而不是悄悄改掉：理由是它与紧随其后的卡片标题重复显示同一天，而用户在实测中直接反馈了这一点。**`SPEC-U-04` 尚未同步**（需走 `SPEC-C-03` 变更传播），这是未完成项。 |
| 风险 | 窗口口径（"这是近 7 天而不是当天"）的可读性下降了一点 —— 现在只剩卡片下的 `reportDailySingleDayNote` 与四维依据里的 `windowDays` 承载它。删的是**重复的日期**，不是口径说明。 |
| 已写入 | `presentation/pages/report/report_page.dart`（`_DailyScoreCard` 去掉标题行）。 |

---

### ADR-31 ✅ 两类「异步续体写已释放的 ValueNotifier」崩溃风险修复

| 项 | 内容 |
|---|---|
| 来源 | 用户：「继续检查是否还有别的BUG」——本轮系统性排查（按"**用户会走到、但测试覆盖不到**"筛）的产物。 |
| 为什么这类缺陷能长期潜伏 | 离线 `app/test` **不编译 presentation 层的全部生命周期**；`tool/*_tests.dart` 也不 `pumpWidget`。而这类异常是**异步未捕获**的（不是页面错误态），只在真实时序窗口内触发，症状是"偶尔报一下"，很难复现。本仓已有同类前科：`ADR-24` 的 AppShell 布局、v1.1.0 首包的润色层接线、`ADR-29` 的「否」按钮。 |
| 缺陷 1 | `HomeNotifier.requestWeeklyReview()` 在 `await` **之后**写 `weeklyReview.value` / `reviewLoading.value`，而 `dispose()` 已调用这两个 `ValueNotifier.dispose()`。首次生成要十几秒，用户在此期间切标签/热重载即命中 → `A ValueNotifier<...> was used after being disposed`。 |
| 缺陷 1 修法 | 基类 `AcouNotifier` **本来就提供** `mounted`（`!_disposed`），但新代码没用它。现在每个 `await` 之后的写入都先查 `mounted`，`finally` 里的写入同样守（它在 dispose 之后仍会执行）。 |
| 缺陷 2 | `DetectNotifier` 的波形回调 `onLevel: (v) => level.value = v` **没有**守卫，而 `dispose()` 调了 `level.dispose()`。level 事件来自**真实平台通道**（`AudioBridgeAndroid.emit`，10 Hz），dispose 之后仍可能到达 → 同类异常。注意 `_setState()` **已经**有 `if (mounted)` 保护，所以这是"同一文件里一处守了、另一处没守"的疏漏。 |
| 缺陷 2 修法 | 抽出 `_onLevel(double v)`，内部 `if (mounted) level.value = v;`，两个 `DetectionSessionHandle.open` 调用点都改指它。 |
| 新防线 | `test/ui/notifier_lifecycle_test.dart`（需 `flutter test`）。它**带负控**：先断言"对已 dispose 的 ValueNotifier 赋值确实会抛"——证明危险真实存在，否则后面"守卫已接线"的断言只是文字游戏。这与本仓 `tool/ui_fingerprint_check.py` 的"带正控"是同一种思路。 |
| 回归 | 离线 `app/test` **12 文件全过**；PURE 202 / DATA 63 / SESSION 124 / UI 413 全过；`verify_artifacts` 与 `check_bridge_symmetry` 均 PASS。 |
| 诚实边界 | 新防线里"守卫已接线"那两条是**源码断言**（检查是否存在 `if (!mounted) return;` / `if (mounted) level.value = v;`），不是行为测试 —— 它们能挡住"被人改回裸赋值"，但**不能**证明运行时不再触发（真正的行为验证需要 `flutter test`，本机跑不了）。 |
| 本轮**未做**的事 | 周综述**不持久化**：App 重启后要重新生成（再等十几秒）。这不是崩溃，是体验缺口，需要按"事实指纹"落盘缓存到 App 私有目录。已记录为待办，未在本轮实现。 |

---

### ADR-32 ✅ 声学模型替换为交付包 `acoudiet_model_v1.3`（**字节确实变了**，且 parity 已按新字节重测）

| 项 | 内容 |
|---|---|
| 来源 | 用户：「`acoudiet_model_v1.3` 里面是最终新 TFlite 模型，帮我替换上。」 |
| 交付包清单（实测） | `v1.3/models/acoudiet_fp32.tflite` 4,053,556 B · `v1.3/models/acoudiet_fp32_v1.2_legacy.tflite` 4,053,556 B · `class_labels.json` · `feature_config.json` · `MANIFEST.sha256` · `README_集成说明.md`。**四个文件逐个与 `MANIFEST.sha256` 对得上**（不是只看大小）。 |
| ⚠️ 交付包自身的两处不一致（记录，不阻塞） | ① `README` §1「包内清单」列了 `models/acoudiet_int8.tflite`，**包里没有这个文件**，`MANIFEST` 里也没有它；② `README` 把回退件写成 `acoudiet_fp32_v1.1_legacy.tflite`，**实际文件名是 `…v1.2_legacy.tflite`**；③ `README` 标题写 v1.3、正文「v1.2 变更」段落在讲 v1.2。三处都是**说明文字与文件不一致**，不影响取用哪个制品（正式嵌入件只有 `acoudiet_fp32.tflite` 一个，README §1 明确写了）。 |
| 为什么这次是「真的换模型」 | 上一轮（`ADR-23`）的交付包与本仓文件**逐字节相同**，只改了版本号；本轮 `31fba3ec…` ≠ 旧 `705ffc62…`，**字节是真的变了**。`tool/compare_model_delivery.py` 实测：两件制品均为 `NOT in app/assets/models/`。 |
| I/O 与前端契约（零改动） | `compare_model_delivery.py` 逐键比对交付 `feature_config.json` 与本仓 SSOT：**Mel 不一致项 = 0**（含 33 项标量 + `frame_selection` / `operation_order` / `model_internal_preprocessing` 三个结构 + `model_input.shape`/`dtype`）；类别表 **MATCH**。`install_model.py` 实测张量：输入 `[1,128,128,1]`、输出 6 类、**fp32**（FF-16 fp32 档 ≤ 6 MB）、`n_frames=128`。故**代码与 Kotlin/Python 前端一行未改**。 |
| `melVersion` **不变** | 仍是 `1.1.0`（= Kotlin `MEL_VERSION` = 生成常量 = SSOT hash `cb07ad85…`）。**握手不受影响**，也没有 `ACD-CFG-001` 风险。这一点重要：`ADR-21` 那次换模型**改了前端**，这次只换了权重。 |
| 已写入 | 新增 `app/assets/models/acoudiet_fp32_v1.3.0.tflite`（4,053,556 B，sha256 `31fba3ecba852cb51ac8166ab49cba1f4be3f4b23cafbfc5cace8780bfa019f4`）；`app/assets/models/model_card.json` 经 `tool/install_model.py --version 1.3.0` 重写（15 字段，`tfliteSha256`/`tfliteBytes`/`parityLabelMatch`/`parityMaxConfDelta` 全为实测）；**删除**被取代的 `acoudiet_fp32_v1.1.0.tflite`。 |
| 为什么删旧文件，而不是两个都留 | `pubspec.yaml` 登记的是**目录**，留着就是 **4 MB 死重**进 APK（`ADR-23` 同一理由）。删之前先把旧字节归档到 **不进包**的 `ai/artifacts/model_archive/acoudiet_fp32_v1.1.0.tflite`（sha256 `705ffc62…560a`）+ 旧卡 `model_card.v1.1.0.json`，回退有据。 |
| 🔴 **本轮必须做的一步：重测 parity** | `tool/verify_artifacts.py` 只检查 `parity_report.json` 的**阈值与 `modelParityMeasured` 标志**，不校验该报告测的是不是当前那份字节。旧报告里 `modelParitySource` 指向 `…_v1.0.0.tflite`（= 旧字节）。若不重测，闸门照样 **PASS**，但它证明的是**已经不在包里的那份模型** —— 这正是本仓反复记录的那类缺陷（"不可能失败的闸门在证据上等于没有闸门"，`ADR-22`/`ADR-24`）。故改包后重跑 `ai/scripts/mel_parity_test.py`。 |
| 重测结果（实测） | `modelParitySource = …\acoudiet_fp32_v1.3.0.tflite`；**labelMatch = 1.0**、**maxConfDelta = 1.5199184417724609e-06**（闸门 0.98 / 0.05），18 个 patch；`mismatches = []`；`boundaryCoverage = 2/18` 且 `exercised = true`（`tone_long.wav@65536/@131072`，`previousRawSample = -0.153076`）；`melParity maxAbsDiff = 5.960464477539063e-08`（atol 1e-3）、`preprocessMaxAbsDiff = 0.0`。 |
| 换模型确实改变了行为（一处，可指认） | 同一 parity 语料、同一前端，18 个 patch 里**恰好 1 个换了标签**：`tone_250hz.wav` 从类别 1 → 类别 5（其余 17 个不变）。这是"权重真的换了"的正面证据，也说明**换模型会改变识别结果**，不是"只是换了个文件名"。 |
| 回归 | `tool/verify_artifacts.py` → **RESULT: PASS**（exit 0，六项全 ok）；离线 `app/test` **12 文件全过**；`tool/run_offline_tests.py` exit 0；`tool/verify_all.ps1` **18 步全过**（该脚本本身此前是坏的，见 `ADR-33`）。 |
| APK（新打，用户选定的命名） | `dist/AcouDiet-1.1.0-arm64-release-model-v1.3.0.apk`，**595,735,269 B**（568.1 MB），sha256 `9a780c2f9374357d67069957fdff4f9a6f277083236d795d37cecaf25235b5e1`。与前一个 595,733,337 B 的包相差 **+1,932 B**（模型本身 +1,840 B，其余是 zip 对齐填充）。**未动 `pubspec.yaml` 的 `versionName`/`versionCode`**——App 版本没变，放弃用版本号区分，改用**文件名**区分（用户选定），因此**旧包被保留而非覆盖**。 |
| 为什么给 `build_release_v11.ps1` 加 `-OutName` / `-Force` | 该脚本原先固定写 `dist\AcouDiet-<Version>-arm64-release.apk` 并 `Copy-Item -Force`——"换个模型重打一次"会**静默覆盖旧包**，而旧包不可恢复（本仓不是 git 仓库，`PHONE_INSTALL.md` 已记录过一次同类教训）。现在：`-OutName` 显式命名，目标已存在且未给 `-Force` 时**直接失败**。 |
| APK 内容实测 | `_toolchain/check_apk_contents.py`（已改为卡片驱动，见 `ADR-33`）实测：包内**只有一个** `.tflite`（`assets/flutter_assets/assets/models/acoudiet_fp32_v1.3.0.tflite`，4,053,556 B，sha256 `31fba3ec…19f4`），与包内 `model_card.json` 的 `tfliteSha256` / `tfliteBytes` **逐项一致**；`INTERNET` 权限 `ascii=False, utf16le=False` → **无网络权限**；`libtensorflowlite_jni.so` 四个 ABI 齐备；zip 条目 158 个、**无重复条目**。`tool/ui_fingerprint_check.py` 对该包 exit 0 = `ADR-24 UI`。 |
| 诚实边界 | 交付 `README` §4 给的**精度数字（聚合 55.9%、Wilson CI 51.9–59.9%，drink F1 0.43→0.75、cabbage F1 0.18→0.42、chips 召回 0.83→0.85）来自模型组的公共测试集**，本仓 `ai/data/splits`/`raw`/`augmented` 为空，**无法复测**——引用时不得说成"本仓实测"。本仓能证明的只有：字节对得上、I/O 与前端契约一致、跨语言 parity 通过、闸门通过、包内文件确实是这一份。 |

---

### ADR-33 ✅ 三处「闸门在说谎」的修复（换模型这轮**顺带**暴露的，不是新功能）

| 项 | 内容 |
|---|---|
| 来源 | 本轮（`ADR-32` 换模型）跑「全套回归」时才暴露：**一次跑通之前，没有任何人跑过这一套**。三处缺陷同一主题——**检查器本身错了**，而错的检查器比没有检查器更危险：它会把正确的产物判死，或把过期的东西判活。 |
| 缺陷 1：`tool/verify_all.ps1` **根本无法解析** | 症状：`powershell -File tool\verify_all.ps1` 立刻死在 `The Try statement is missing its Catch or Finally block. @line 105`。根因：文件是 **UTF-8 无 BOM** 且带中文注释，而 Windows PowerShell 5.1 对**无 BOM** 的 `.ps1` 按**机器 ANSI 代码页**解码——本机是 **936/GBK**。实测对照：同一份字节按 cp1252 解可解析、按 cp936 解报错，本机 `[Text.Encoding]::Default.CodePage = 936`。**这不是"注释读起来是乱码"的观感问题，是解析错误**：`C-05` 规定的"一条命令跑全部回归"入口**从来没跑起来过**，所以下面 17 步里任何一步都不会被自动执行。 |
| 缺陷 1 修法 | 彻底修法是**把该脚本改成纯 ASCII**（本仓其余 5 个 `.ps1` 全是纯 ASCII，只有它和 `build_release.ps1` 带非 ASCII 字节）。过程与实测：先加 **UTF-8 BOM** 验证解析恢复（`PARSE: OK`、17 步全过），但**BOM 会被普通编辑工具静默剥掉** —— 本轮用编辑工具改这个文件时 BOM 就被剥过一次，**同一个解析错误立刻复现**，说明"靠 BOM"是易失状态。于是把那 3 行中文注释改写成英文 ASCII，该文件现在 `nonAsciiByteCount = 0`，实测**两种解码都通过**：正常 `ParseFile` → `PARSE: OK`，**强制按 GBK 解码** → 也 `PARSE OK`（即旧失败模式已不可能再现）。中文原话与依据保留在 `ADR-31`。 |
| 缺陷 2：`tool/ui_fingerprint_check.py` **把正确的包判成"DO NOT INSTALL"** | 症状：对**刚打好的新 APK** 输出 `RESULT: PRE-ADR-24 UI -- DO NOT INSTALL THIS FILE`（exit 1）。根因：它的 `_MUST_BE_PRESENT` 里还留着 **`近 7 天评分（截至该日）`**，而这个标题是 **`ADR-30` 刻意删掉的**（用户反馈日期重复）。`ADR-30` 改了 `report_page.dart`，**没同步这个检查器**；于是从 `ADR-30` 起，**每一个正确的构建都会被它判死**。 |
| 缺陷 2 修法 + 证据 | 把该串移到 `_MUST_BE_ABSENT`（它现在是"旧 UI 的特征"），并**新增** `AI 周综述`（`ADR-28` 引入）到 `_MUST_BE_PRESENT`，补回被让出的覆盖。四个包的实测**判别矩阵**（这是修复有效的证据，不是推测）： |
| | `近 7 天评分（截至该日）`：新版 595 MB **无** · 旧 1.1.0 595 MB **无** · 旧 1.0.0 25 MB **有** · 旧 1.0.0 profile **有** |
| | `AI 周综述`：新版 595 MB **有** · 旧 1.1.0 595 MB **有** · 旧 1.0.0 25 MB **无** · 旧 1.0.0 profile **无** |
| | 修复后：新包 → `ADR-24 UI` / exit 0；旧 1.0.0 包 → exit 1（`missing 1, stale titles 1`，两条理由都对得上）；**旧 1.1.0 包从"被判死"变为 exit 0** —— 它本来就是 `ADR-30` 之后的正确界面。 |
| 缺陷 3：`_toolchain/check_apk_contents.py` 写死了旧模型的 sha256 | 它的 `RELEASED_FP32_SHA256` 是 `705ffc62…560a` 的字面量，换模型后会对**合法包**打印 `matches the released acoudiet_fp32.tflite: False`。同样是"对正确产物报错"。修法：改为**由包内的 `model_card.json` 驱动**（`sha256` 与 `tfliteBytes` 两项都核，且核卡片推出来的文件名确实是包里的那个文件）——卡片是 App 自己读的同一份真源，因此**不会过期**。 |
| 缺陷 2 的顺带修复 | 它的**默认目标**原来是写死的 `dist/AcouDiet-1.0.0-arm64-release.apk` —— 加了新包之后，不给参数时它会**自己挑一个两代界面之前的包**，然后判它"DO NOT INSTALL"。现改为**取 `dist/` 下最新的 `*release*.apk`**，并把选中的文件名**打印出来**（选择可见，而不是被假定）。实测：不给参数 → 选中 `AcouDiet-1.1.0-arm64-release-model-v1.3.0.apk` / exit 0；显式传 1.0.0 包 → exit 1。 |
| 缺陷 3 的负控 | 新增 `_toolchain/selftest_check_apk_contents.py`：用四个**合成小 zip**（不是 595 MB 真包，否则回归里跑不动）证明判别力——卡片与 `.tflite` 一致 → exit 0；sha256 不符 / 字节数不符 / 卡片指向包里不存在的文件名 / 包里根本没有卡片 → 四条全部 exit 1。实测 `RESULT: the checker discriminates all 5 cases (1 accept, 4 reject)`。 |
| 让"能跑的闸门"变成常态 | 已把该负控接进 `tool/verify_all.ps1` 作为**独立一步**（它不需要真 APK）。`verify_all.ps1` 因此从 17 步变 **18 步**。 |
| 回归 | `tool/verify_all.ps1` **18 步全过**（此前它的 exit 1 是**解析错误**，不是某个套件失败）；`verify_artifacts` PASS；`ui_fingerprint_check` 对**新包** exit 0、对**旧 1.0.0 包** exit 1；`selftest_check_apk_contents` exit 0；`dist/` 四个包的 sha256 逐文件复算与文档记录一致。 |
| 诚实边界 | ① `verify_all.ps1` 里的 `T-08b parity` 步骤**本来就**会重测，但它此前一步都没跑过；本轮的真实 parity 证据来自单独运行 `mel_parity_test.py`，不是来自这套脚本的自动执行。② 缺陷 2、3 的"修法"都只是**让检查器说真话**，不改变任何产物。③ **只有缺陷 3 的负控进了 `verify_all.ps1`**；缺陷 2 的 `ui_fingerprint_check.py` 仍需一个真实 APK，所以**仍是构建后手工步骤**，没有自动化守卫 —— 它的判别矩阵（四个包）是**一次性实测**，不是每次回归都跑。④ 缺陷 1 的"纯 ASCII"修法只保证**当前**这个文件不再受解码影响；它不阻止后来者再写中文进去（没有机械检查）。同类风险仍在 `tool/build_release.ps1`（带 BOM，且注释里明确要求保留 BOM）—— 那一个本轮**没有动**。 |

---

### ADR-34 ⛔ **删除端侧语言模型层（Qwen3.5-0.8B）与它的全部接线** —— 用户要求，非技术裁决

| 项 | 内容 |
|---|---|
| 来源 | 用户先报「显示建议模型加载失败啊，给我修复」；随后裁决：「**我不要 qwen 这种解释模型参与了，把软件回退到最初**」，追问范围时补一句「**并且把 qwen 端侧相关代码删干净**」。 |
| 裁定 | **整体删除**端侧语言模型层：资产、原生库、C shim、Dart 适配器、润色层、周综述、以及它们在界面上与自检面板上的所有落点。**保留** v1.3 声学模型（`ADR-32`）与 `ADR-24/25/30` 的界面修复 —— 用户点名删的是"qwen 这种解释模型"，不是那两项。 |
| 为什么保留 v1.3 声学模型 | 那一轮是用户**自己**明确要求做的（「acoudiet_model_v1.3 里面是最终新 TFlite 模型，帮我替换上」），与本裁定不冲突；回退不该顺手推翻用户刚下的另一个要求。**若用户的"最初"也包括它，说一声即可再退一步**（旧字节已归档，见下）。 |
| 删除的资产与原生件 | `app/assets/llm/`（`acoudiet-nia-q4_k_m.gguf` **532,517,120 B** + `README.md`）、`app/android/app/src/main/jniLibs/{arm64-v8a,x86_64}/libacoudiet_llm.so`（5,106,008 / 5,259,640 B）、`app/android/app/src/main/cpp/acoudiet_llm_shim.{c,h}`。**空的 `jniLibs/` 与 `cpp/` 目录一并剪掉**（它们只为此而生）。 |
| 删除的 Dart 代码 | `data/native/llama_llm_engine.dart`、`domain/service/llm_engine.dart`、`domain/service/nutrition_advice_{service,prompt}.dart`、`domain/service/advice_text_guard.dart`、`domain/service/weekly_review_{service,prompt}.dart`、`domain/model/polished_advice.dart`；错误码 `ACD-LLM-001` / `ACD-LLM-002`；`pubspec.yaml` 的 `assets/llm/` 条目。 |
| 删除的测试与工具 | `test/support/fake_llm_engine.dart`、`test/domain/{app_services_llm_wiring,llm_engine_adapter,nutrition_advice,weekly_review}_test.dart`、`tool/probe_polishable_advice.dart`、`tool/run_llm_roundtrip.dart`、`tool/build_{acoudiet_llm_shim,llm_shim_no_cmake}.ps1`、`tool/{fetch_qwen35_gguf,convert_nia_to_gguf,fetch_llama_cpp_binary,setup_gguf_env}.py`。 |
| 界面与接线回退 | `home_page.dart` 删掉 `_AiWeeklyReviewCard`；`ui_strings.dart` 删掉全部 `aiReview*`；`notifiers.dart` 的 `HomeNotifier` 删掉 `weeklyReview`/`reviewLoading`/`requestWeeklyReview`，`ReportNotifier.reload` 去掉润色层与缓存（建议直接取规则引擎输出）；`app_services.dart` / `bootstrap.dart` / `report_service.dart` 去掉 LLM 注入与 `polishedAdvices`。 |
| **自检面板：15 项 → 14 项** | `ADR-27` 为让模型有落点而新增的第 15 项 `adviceModel` 随功能一起删除，**回到 `ADR-14` 的 14 项闭集**（键集与顺序与 ADR-27 之前逐字相同）。同步改了 `demo.dart`、`demo_controller.dart`、`selfcheck_presenter.dart`，以及断言项数的 `tool/ui_presenter_tests.dart`（含"字段组由 6 项回到 5 项"、归一化后 failure 数 6 → 5）与 `tool/session_tests.dart`。⚠️ 注意：**握手字段数仍是 15**（`API-01 §2.1`，与自检项数是两回事），断言里两者长得几乎一样，改的时候别连坐。 |
| 版本号**没有**退回 1.0.0 | 功能面确实回到了最初，但 `versionCode` 只能增不能减：手机上装着 `1.1.0+2` 时，装 `1.0.0+1` 会被 Android 以 `INSTALL_FAILED_VERSION_DOWNGRADE` 拒绝（而且用户根本装不回去）。故取 **`1.2.0+3`**，并在 `pubspec.yaml` 里写明"版本号不降"的**原因**。产物名带 `-no-llm` 以便与旧包区分。 |
| 归档（本仓不是 git 仓库，删了就取不回） | 删除前整包归档到 **`_toolchain/qwen_rollback_archive/acoudiet-qwen-removed-<时间戳>/`**（28 个文件、约 **543 MB**，含权重与 `.so`），并附 `ARCHIVED.txt` 列出成员；两份交付说明（`docs/release/llm_on_device_conversion.md`、`gemma_attribution_and_license.md`）也一并留档。 |
| 顺带清掉的**陈旧构建缓存** | 光删源文件不够：`app/build/**/flutter_assets/assets/llm/`（3 份 532 MB 副本）、`app/build/**/compressed_assets/.../llm/`、以及 `merged_jni_libs` / `merged_native_libs` / `stripped_native_libs` 下的 **6 个 `libacoudiet_llm.so`** 仍在磁盘上。**`merged_native_libs` 是打包的输入** —— 不清的话新 APK 会照样带着那个 `.so`。已全部删除，并删掉 `.dart_tool/flutter_build` 的资产戳记。**新的构建脚本增加了硬检查**：APK 里若再出现 `llm|gguf` 条目直接判失败。 |
| 构建脚本改造 | `tool/build_release_v11.ps1` 原先的前置检查是"Qwen 权重 + shim `.so` 在不在"，现在改为**由模型卡驱动**：读出卡里的 `name/quantization/version` 推出 `.tflite` 文件名，校验它存在、字节数与 `tfliteBytes` 一致、sha256 与 `tfliteSha256` 一致，并在打包后**从 APK 里把那个条目读出来重算 sha256**（不只是比大小）。 |
| 回归 | 删除后 `tool/verify_all.ps1` **18 步全过**（含 `T-08b` 跨语言 parity、`T-07/T-08a` 制品闸门、`U-01..U-06` UI 套件、`check_async_state_writes`）；`_toolchain/selftest_check_apk_contents.py` 的 5 条负控仍全过。 |
| APK（新打） | `dist/AcouDiet-1.2.0-arm64-release-no-llm.apk`，**65,525,041 B**（62.5 MB），sha256 `edda873a6ecdf48d9c90619b15e9e236a93df2d227de222cdba255ea9979b2f3`。**体积从 595,735,269 B 降到 65,525,041 B（−530 MB）**。构建脚本自带的取证实测：包内 `acoudiet_fp32_v1.3.0.tflite` 4,053,556 B 且**从 APK 条目里重算的 sha256 与磁盘一致**；`model_card.json` 在包内；`lib/arm64-v8a/libtensorflowlite_jni.so` 在包内；**`llm|gguf` 条目数 = 0**（脚本新增的硬检查）。`check_apk_contents.py --expect-no-internet` → exit 0；`ui_fingerprint_check.py` → `CURRENT UI` / exit 0。 |
| 旧包保留 | 两个 595 MB 的 LLM 时代包**没有被覆盖**（构建脚本的 `-OutName` + 默认拒绝覆盖），继续留在 `dist/` 作历史留档；`ui_fingerprint_check.py` 现在会把它们判为 `NOT THE CURRENT UI`，理由已写明是"带着已删除的 AI 卡片"。 |
| 新防线 | `app/test/ui/notifier_lifecycle_test.dart` 删掉了"周综述续体带 mounted 守卫"那条（**主体没了，不是断言放宽**，并在注释里写明原因），新增一条"端侧语言模型层已彻底移除"的**反向断言**：`notifiers.dart` 不得再出现 `WeeklyReview/weeklyReview/requestWeeklyReview`，`home_page.dart` 不得出现 `aiReview`，自检键表不得出现 `adviceModel`。 |
| 连带修掉的检查器（**第二次同类事故**） | `tool/ui_fingerprint_check.py` 的判据里，`AI 周综述` 是 `ADR-33` **刚加进"必须存在"**的针 —— 本裁定删掉该卡片后，它立刻把**正确的**新包判成 `DO NOT INSTALL`（exit 1）。与 `ADR-33` 记录的两处是同一个模式：**判据跟着功能走，功能删了判据没跟**。修法：该针移到"必须缺席"，并**实测四包判别矩阵**——`1.2.0` 新包 exit 0；两个 LLM 时代的 595 MB 包因**带着已删除的 AI 卡片** exit 1；`1.0.0` 老包因带着 `ADR-30` 已删的标题 exit 1。 |
| 顺带修正的判词 | 原来的判定词 `PRE-ADR-24 UI` 已经不成立：一个包现在会因为**带着比 ADR-24 更新的东西**（ADR-28 的 AI 卡片）而被拒，而不是因为太旧。改为 `CURRENT UI` / `NOT THE CURRENT UI`，逐 ABI 判词改为 `NOT CURRENT (missing N, present-but-removed M)`。**判词说错原因是本仓反复记录的那类缺陷**，所以顺手改掉，并同步了 `PHONE_INSTALL.md` 里的期望值。 |
| 🔴 **诚实边界（最重要的一条）** | **「建议模型加载失败」的根因自始至终没有查出来。** 本裁定是**按用户要求移除功能**，不是修好它。已排除的假设（都有实测证据）：① GGUF 元数据合法 —— 手工解析头部得 `GGUF` v3 / 320 张量 / 46 个 KV，`general.architecture = qwen35`、`tokenizer.ggml.model` 存在，且 llama.cpp b10937 自带 `models/ggml-vocab-qwen35.gguf`（说明该版本认识这个架构）；② `.so` 符号齐全 —— 动态符号表里 5 个 `acoudiet_llm_*` 均为已定义的全局函数；③ 无缺失依赖 —— `DT_NEEDED` 只有 `liblog/libandroid/libm/libdl/libc`（**没有** `libc++_shared`，即 libc++ 是静态链进去的）；④ 包内工件齐全 —— 权重与 `.so` 都在 APK 里且字节数与磁盘一致。**没有查的**：真机 logcat 与自检第 15 项 `observed` 里的 `detail` 原文（用户只转述了"加载失败"），以及 Windows 端 `llama-cli` 直接加载该 GGUF 的结果（尝试过，被作业运行器中断，未取到结论）。若将来要恢复此功能，**从这两步开始**，不要从重写代码开始。 |
| 附带影响 | ① `docs/release/llm_on_device_conversion.md` 描述的东西**已不在产品里**，只作历史记录保留；② 两份 SPEC 侧文档（`SPEC-M-04` / `API-04`）关于"14 项"的表述**回到一致**，无需改动；`ADR-27`/`ADR-28`/`ADR-31` 中与 LLM 相关的部分**保留原样**（它们是历史裁定，不是现行规范）。 |

---

### ADR-35 ✅ `flutter test` 其实一直是**红的**（4 条），并修掉 16 KB 页对齐缺口

| 项 | 内容 |
|---|---|
| 来源 | 用户：「观察当前项目，还有什么能够扩展和改进的地方」→「**全部修复**」。本条是"实测巡检"的两项产物，**都不是新功能，是既有缺陷**。 |
| 缺陷 1：`flutter test` 从未跑过，且**4 条一直失败** | 误以为它在本机跑不起来（工具链曾是障碍），于是 `tool/verify_all.ps1` 第 16 步用的是**离线 shim**（`run_offline_tests.py`，只跑 12 个文件）。本轮实测 `flutter test` **能跑**，结果 `133 passed, 4 failed`：`test/ui/report_scope_test.dart` 里 **3 处断言「界面上必须有 `近 7 天评分（截至该日）`」**，而那个标题是 **`ADR-30` 刻意删掉的**（`report_page.dart:304` 有注释）。**这是同一类事故的第三次**（`ADR-33` 的 `ui_fingerprint_check.py`、`ADR-34` 的 `AI 周综述` 针、本条）—— 改动 UI 时没同步它的判据。**因为没有任何门禁跑过这套测试，它红了至少两轮没人知道。** |
| 缺陷 1 修法 | 不再断言那个已删的字符串，改为断言**卡片本身由选中日期命名**：新增 `_openDayScoreCard()` = `find.widgetWithText(ScoreCard, 当日 dateLabel)`、`_weeklyScoreCard()` = `find.widgetWithText(ScoreCard, reportTitle)`。**为什么要按标题而不是按类型**：报告页两个 scope **各有一个** `ScoreCard`（每日是 `_DailyScoreCard`、本周是 `ReportScoreHeader`），所以 `find.byType(ScoreCard)` 区分不了两者 —— 我第一版就是这么写的，当场被测试证伪。结果：**`flutter test` 137 全过**（第一次全绿）。 |
| 缺陷 1 的防线 | `tool/verify_all.ps1` 新增一步跑**真** `flutter test`（不是 shim），工具链缺失时**判失败而不是跳过**。同时把 `$Tool`/Python/Flutter 三处路径改为可被 `ACOUDIET_TOOLCHAIN`/`ACOUDIET_PYTHON`/`ACOUDIET_FLUTTER` 覆盖，这样 CI 或别的机器也能跑。 |
| 缺陷 2：APK 在 **16 KB 页**设备上会让模型加载失败 | 实测每个 `.so` 的 ELF `PT_LOAD` 对齐：`libapp.so`/`libflutter.so` = **65536**，但 **`libtensorflowlite_jni.so` 四个 ABI 全是 4096**。Android 15+ 部分设备用 16 KB 页，4 KB 对齐的段**无法映射** → `dlopen` 失败 → 模型加载不了 → **核心功能在新款手机上直接坏掉**。根因：`org.tensorflow:tensorflow-lite:2.16.1` 是预编译的旧对齐；而当初自编的那个 Qwen shim `.so` 反而**显式加过 `-Wl,-z,max-page-size=16384`**（已随 `ADR-34` 删除）——**唯一注意过这件事的库删掉了，剩下的这个没人看**。 |
| 缺陷 2 修法（**drop-in，零代码改动**） | 换成 **`com.google.ai.edge.litert:litert:1.4.2`**。选它的依据是实测而非猜测：① 它仍然发布 **同名** 的 `jni/<abi>/libtensorflowlite_jni.so`（Dart 侧正是 `dlopen` 这个名字）；② AAR manifest 仍是 `package="org.tensorflow.lite"`；③ 导出 **225** 个 `TfLite*` 符号（Dart 只用 21 个，含 `TfLiteTensorType`/`TfLiteVersion`），是超集；④ 四个 ABI 的 **`p_align` 全部 = 16384**；⑤ `DT_NEEDED` 仍只有 `libc/libdl/liblog/libm`；⑥ minSdk 21（本仓 24）。**本 App 一行 Java API 都没用**（只用 C API + FFI），所以换 AAR 不影响任何 Dart/Kotlin 代码。重打后：`libtensorflowlite_jni.so` 四个 ABI 的 `p_align` 全部 16384，`lib/` 下每个未压缩 `.so` 的 zip 起始偏移也都在 16 KB 边界。 |
| 缺陷 2 的防线 | 新增 **`tool/check_page_alignment.py`**：直接读 APK 内每个 `.so` 的 ELF 头（`PT_LOAD` 的 `p_align`）**并**核对未压缩 `.so` 的 zip 起始偏移，两条独立判据都要过；已接进 `tool/verify_all.ps1`，也接到 `tool/build_release_v11.ps1` 的**构建后**步骤。**负控实测**：对修复前那个包（1.2.0）→ `NOT 16 KB COMPATIBLE` / exit 1；对修复后（1.2.1）→ `16 KB COMPATIBLE` / exit 0。 |
| ⚠️ **一条必须记下的自我更正** | 我最初把证据写成「`zipalign -c -p 4` 通过、`-p 16` 失败，所以不是 16 KB 对齐」。**这是错的**：build-tools **34** 的 `zipalign` 里 `-p` 是**无参开关**，`16` 是**通用对齐字节数**，于是它检查的是"每个条目 16 **字节**对齐"，对普通条目（META-INF、dexopt、`.tflite` 资产）报 `BAD` 是**完全正常的**；16 KB 的页大小开关 `-P <pageSizeKb>` 要到 **build-tools 35** 才有。**结论没变**（ELF `p_align=4096` 本身就是决定性证据），但这句推理是错的，已从 `build.gradle` 与检查器的文档里改掉，并把这个坑写进检查器 docstring，免得后人再拿 `-p 16` 当 16 KB 判据、把正确的包判成坏的。 |
| 诚实边界 | ① 16 KB 兼容性是**静态判据**（ELF 头 + zip 偏移），**没有真机/16 KB 模拟器实测** —— 本机 `adb devices` 为空，也没有 AVD。② `flutter test` 现在全绿，但它是**在一台机器上**跑出来的；CI 只跑其中的可移植部分（见 `ADR-36`）。③ 换 LiteRT 后**没有在设备上跑过**，`TfLiteVersion` 自检项会显示新的运行时版本，需真机确认一次。 |

---

### ADR-36 ✅ 把项目纳入版本控制（首提交），并补齐几处"能跑的检查"

| 项 | 内容 |
|---|---|
| 来源 | 同上（「全部修复」）。 |
| 缺陷 3：**整个项目没有任何版本控制** | 实测 `D:\Desktop\Food\.git` 与 `AcouDiet\.git` **都不存在**。这不是洁癖问题：`ADR` 日志里至少两处记录了由此造成的**不可逆损失**（旧包被 `Copy-Item` 覆盖后取不回旧字节；`ADR-34` 删 Qwen 前必须先手工归档才敢动手）。**"删错了能不能救"这件事一直是"不能"。** |
| 仓库根设在**工作区根**，不是 `AcouDiet/` | 因为项目的"宪法"分散在三个兄弟目录：`shared/feature_config.json`（**SSOT**）、`docs/`（**冻结 SPEC 树 + ADR 日志**）、`AcouDiet/`（代码）。**根设在 `AcouDiet/` 就等于不把 ADR 日志和 SSOT 纳入版本控制** —— 而这两样正是本项目反复强调"唯一真源"的东西。 |
| 首提交规模 | `f5d4849`，**448 个文件 / `.git` 54 MB**。忽略：`app/build`（1.6 GB）、`.dart_tool`、两处 `_toolchain`（3.1 GB）、`dist/*.apk`（1.4 GB）、`*.gguf`、`建议模型/model.safetensors`（**511 MB**）。**`*.tflite` 刻意不忽略**（4 MB，是交付物本身；提交它才能让重建可复现）。 |
| 诚实边界（版本控制**没有**解决的那半） | `dist/*.apk` 被忽略，所以**重建一个 APK 仍会覆盖它的前身**。缓解办法是 `docs/demo/PHONE_INSTALL.md` 里的**哈希台账**（每个曾发布过的包的 sha256 与体积都记着），但"旧 APK 的字节"确实仍不可回取。**要真正解决需要一次 `git lfs` 或外部制品库，本轮没做。** |
| 缺陷 4：检查器散落在仓库**之外** | `AcouDiet/tool/` 在仓内，但 `_toolchain/` 下还有 24 个脚本（含 `check_apk_contents.py`、`selftest_check_apk_contents.py`）。**闸门和被它检查的代码不在一起，也不一起移交/备份。** 已把 4 个可搬运的（`check_apk_contents.py`、`selftest_check_apk_contents.py`、`check_emulator_model_log.py`、`selftest_check_emulator_model_log.py`）移进 `AcouDiet/tool/`，并把它们的**硬编码绝对路径改成按自身位置推导**（`selftest` 还改用 `sys.executable`，不再依赖 `_toolchain` 的 Python）。`verify_all.ps1` 已改指仓内副本。**留在 `_toolchain/` 的是那些真的需要本机环境的（下载器、probe、一次性迁移脚本），没有强搬。** |
| 缺陷 5：**没有任何 CI** | 仓库里没有 `.github/workflows`（grep 到的全是 vendored llama.cpp 自带的）。而 `ADR-33`/`ADR-35` 记的三处事故**全都是同一个形状：检查存在但从不执行**。新增 `.github/workflows/verify.yml`：Windows runner + Flutter 3.24.5，跑 `flutter test`、SSOT 漂移（**重新生成再 `git diff --exit-code`**，因为 `gen_feature_config.dart` 没有 `--check` 开关）、以及 7 个**可移植**的 Python 检查器与 2 个负控自测。 |
| CI 的诚实边界 | **`tool/verify_all.ps1` 不在 CI 里跑**：它驱动本机 `_toolchain`、要 Kotlin/JVM/Android SDK，托管 runner 上也**无法构建 APK**，因此**页对齐闸门与 APK 内容闸门在 CI 里没有覆盖**，仍是本地构建后步骤。这一点写在 workflow 文件顶部，而不是留给读者猜。 |
| 缺陷 6：Qwen 时代的死重 | 实测 `AcouDiet/_toolchain/llm/` 有 **34,074 个文件 / 2,398 MB**（`llama.cpp-b10937` 源码树 165 MB + 三个 `.gguf` 共 1,267 MB）。它不进包、不影响产物，但已无用途。**已删除**（删除前的完整归档在 `_toolchain/qwen_rollback_archive/`，保留）。`AcouDiet/_toolchain` 从 5,508 MB 降到 3,110 MB。 |
| 缺陷 7：历史文档描述已删除的功能 | `docs/release/llm_on_device_conversion.md`（428 行）现在整篇描述一个**已不在产品里**的层。**没有删**（删历史比留着更糟），而是加了醒目的 `⛔ 已被 ADR-34 取代` 抬头，写清"文中每个路径与命令今天都对不上"，并指向 `ADR-34` 的「诚实边界」。 |
| 新增：无障碍检查（**会失败的检查，不是文档**） | 新增 `app/test/ui/accessibility_test.dart`（6 条）：逐页扫描 `IconButton` 是否**有 tooltip 或 semanticLabel**（图标按钮没有可访问名 = TalkBack 只念"按钮"）、`Semantics` 是否有**非空 label**、雷达图是否发布文本等价物。**带正控**：每条断言前先要求"本次确实扫到了 >0 个控件"，否则测试自曝"扫描是空的"而不是默默通过 —— 这正是本仓反复栽的"不可能失败的闸门"。实测 4 个页面的控件全部可命名，无需改产品代码。**不做超范围声明**：对比度、焦点顺序、TalkBack 实机走查都**不在**本文件覆盖内。 |
| 未完成：`ai/artifacts/metrics.json`（**已尝试，未成功，如实记录**） | `tool/verify_artifacts.py` 一直打 `[note] metrics.json not produced yet (T-05) -- not checked, not claimed ok`。数据集其实**在**（`ai/data/raw` 3,363 个文件 / 482 MB，`ai/data/splits` 四个 CSV 非空、共 3,360 行），所以本轮**真的跑了评估器**，两次：<br>① `python ai/src/evaluate.py --out ai/artifacts/metrics.json` → `FileNotFoundError: ACD-ART-001: model artifact not found at ai/artifacts/acoudiet_fp32_v1.0.0.keras; run T-04 training first`；<br>② 改用**已交付的 tflite** 绕过 Keras：`--tflite app/assets/models/acoudiet_fp32_v1.3.0.tflite` → **同一条错误**（E1/E2/E3 实验矩阵需要模型本体，不只是推理产物），并且提前报出 `ACD-ART-005: E3 requested but no adaptation model is available`。<br>**结论：`metrics.json` 需要 T-04 训练产物（`.keras`），本仓没有、本轮也无法产出**（训练不在能力范围内，`ai/data/augmented` 也是空的）。**因此这一项保持"未检查"，不伪造数字、不把缺件说成通过**（`SPEC-00 §8` 明令禁止预测值）。要闭环需要：拿到/重训 `.keras` → 跑 `evaluate.py` → 再跑一次 `verify_artifacts.py`。**本轮把它从"没人试过"推进到"试过、卡在哪一步、下一手该做什么"，仅此而已。** |
| 回归 | `tool/verify_all.ps1` **20 步全过**（较上轮 +2：真 `flutter test`、页对齐）；`flutter test` **143 项全过**（137 + 新 6 条无障碍）；`git status` 干净。 |

---

### ADR-37 🔴 **首次实测"真正出厂的那个模型"的精度：在**本仓的**测试集上等于瞎猜（16.7%），且 6 类里有 3 类从不被预测**

| 项 | 内容 |
|---|---|
| 来源 | 用户对上一轮唯一未修项（`metrics.json`）说「再次尝试全部修复」。 |
| 先说为什么 `metrics.json` **仍然不写** | 把 `ai/src/evaluate.py` 读透后，性质变了：`evaluate()` 的**分类指标来自它自己 `load_model()` 加载的 `.keras`**（`predict_split(loaded[label], split)`），传进去的 `.tflite` **只用于测延迟**（`measure_latency` / `measure_confirm_latency`）。所以 `metrics.json` 描述的是**本仓自己训练出来的模型**，而本仓**没有** `.keras`（`ai/artifacts/` 里没有，`ai/data/augmented` 是空的）→ 需要 T-04 训练。**把别的模型的数字写进模型卡的 `metricsRef`，就是对用户会安装的那个制品说谎** —— 所以它保持缺省，且 `verify_artifacts.py` 如实打 `[note] not produced yet`。 |
| **但真正的缺口被暴露出来了** | `metrics.json` 测的不是出厂模型，那么**出厂模型的精度**在本仓**从来没被测过**。模型卡里只有跨语言 parity（`labelMatch`/`maxConfDelta`），那是"Kotlin 与 Python 算得一样"，**不是"认得对"**。仓里唯一能引用的 55.9% 来自模型组的发布说明。 |
| 新增实测工具 | `tool/evaluate_shipped_model.py`：读模型卡取出**出厂的那个 `.tflite`**，在 `ai/data/splits/{test_public,test_mobile}.csv` 上跑，**复用仓内冻结链路**（`augment_mod.feature_tensor(..., augment_on=False)`，即 `evaluate.py::predict_split` 用的同一个调用），产出 `ai/artifacts/metrics_shipped_model.json`：top-1 + Wilson 95% CI、6×6 混淆矩阵、每类 P/R/F1 + support、每 split 明细，以及**溯源**（模型 sha256、卡内 sha256、split 行数、缺失文件数）。缺文件**计数并报告**，不静默跳过。 |
| 实测结果（**出厂模型 v1.3.0**，sha256 `31fba3ec…19f4`，与卡一致） | `test_public`：**78/468 = 16.67%**；`test_mobile`：**24/144 = 16.67%**；主集 Wilson 95% CI **[11.46%, 23.60%]**。**6 类均匀时瞎猜 = 16.67%** —— 区间下界 11.5% 已含"比瞎猜更差"，上界 23.6% **远低于**模型组发布说明的 55.9%。 |
| 为什么会这样（诊断，不是猜测） | 跨类别抽样 117 条（每类约 20 条）的**预测概率均值/标准差**：`cabbage` 0.485、`chips` 0.309、`noodles` 0.150，而 **`gummies` 0.019 / `carrot` 0.029 / `drink` 0.009**；argmax 直方图 **`gummies`/`carrot`/`drink` 各 0 次**。**即：这个模型的输出质量全部压在 6 类中的 3 类上，另外 3 类实际上不可达。** 对照组：喂**全零输入**时输出接近平坦（0.067–0.277），说明模型**确实对输入有反应**，不是常数函数 —— 所以这更像"训练/标签层面塌了"，而不是"权重没加载"。 |
| 🔴 我自己在这轮**先犯了一个错**（必须留痕） | 第一版脚本用 `features.mel_of_file()` 构造输入，测出 16.67%；**这正是"结果太反常时先怀疑自己"的典型情形**。核对 `evaluate.py::predict_split` 后发现仓内评测用的是 **`augment_mod.feature_tensor()`**，两者**不是同一个函数**。改用后者重测 → **仍是 16.67%**，且 117 条抽样的塌缩现象一致。**两种独立构造给出同一结论**，故这不是我的解码/归一化 bug。（差别写进了脚本 docstring 与报告里的 `frontEnd.source`：一个用错前端的测量脚本，其错误与"模型坏了"在证据上长得一模一样。） |
| 这个测量**证明了什么 / 不能证明什么** | **能证明**：出厂 `.tflite` 在**本仓冻结的测试集上**打不过瞎猜，且 3/6 类不可达；这与模型卡、包内容、parity 都无关。**不能证明**：它在现场就是坏的 —— 本仓**没有能力**验证 `ai/data/splits` 与模型组**训练/评测用**的数据分布是否一致（`ai/data/raw` 下的 `esc_cabbage_*` 这类文件名说明语料是按类别**重命名**的自建划分，映射关系不在本仓）。**55.9% 与 16.7% 的 Wilson CI 完全不重叠**，所以"两者描述同一件事"不可能：要么口径不同，要么其中之一不成立。 |
| 新增闸门（防这份测量过期） | `tool/verify_artifacts.py` 新增**第 11 条**：`ai/artifacts/metrics_shipped_model.json` 必须存在，且其中记录的 `model.sha256` **必须等于**当前出厂 `.tflite` 的 sha256；不等就打 `ACD-ART-006 ... the measurement is STALE`。**负控实测**：把报告里的 sha256 改成 `deadbeef…` → `ACD-ART-006` / exit 1；恢复 → `RESULT: PASS` 并打印 `shipped model top1 = 0.1667 …`。**这样"出厂模型测过了没有、测的是不是这一份字节"变成机械判据，而不是靠人记得。** |
| 下一步该做什么（给用户/模型组） | 向模型组要**他们评测时用的精确划分与逐文件预测**（或他们的测试集）。把逐文件预测与本仓这份 612 条的预测对齐，**一次比对就能判定**是"口径不同"还是"模型/权重有问题"。在那之前，**不要在任何对外材料里引用 55.9%** —— 本仓现在有一份相反的、可复现的实测。 |
| 诚实边界 | ① 本仓的 `test_public`/`test_mobile` 是**自建划分**，不能代替模型组的评测集；② 本次只测了 top-1 单窗口，**没有**复现 App 的三级投票（EMA + 稳定判据 + 低置信门控），那个可能改善**但不改变"3 类不可达"**这一结构性现象；③ 没有真机实测。 |

---

### ADR-38 ✅ 按示意图继续优化 UI：**先造出「能看的证据」，再改** —— 顶栏、记录卡右列、我的条目描述、雷达标注、检测圆盘

| 项 | 内容 |
|---|---|
| 来源 | 用户：「使用 semi design 的 skills 继续按照原 UI 设计图优化前端界面」。 |
| ⚠️ 第一件事不是改代码，是**先能看见** | 前几轮（`ADR-24`/`ADR-25`/`ADR-30`）所有的 UI 结论都建立在"读代码 + 断言"上，**没有一次真正看过页面**。`ADR-24` 的底栏事故（自绘底栏吃掉整屏）就是这么漏的：124 项 widget 测试全绿，界面却几乎是空白。所以本轮新增 `app/tool/visual_capture_test.dart`：把**真实的五个页面 + 四个 Tab** 渲染成 1152×2496 的 PNG（与示意图同尺寸），直接和 `软件UI界面设计图/*.png` 并排看。 |
| 为什么它是 `tool/` 而不是 `test/` | 截图比对是**像素比对**，跨引擎 / 跨平台 / 跨 Flutter 版本天然不稳定 —— 把它放进 `test/` 就是**又造一道会说谎的闸门**（本仓的主题，见 `ADR-22`/`ADR-33`）。`flutter test`（以及 CI）只跑 `test/`，所以这 154 条断言不受影响；截图命令写在文件头，按需执行。产物 `tool/visual_capture/*.png` 已加入 `.gitignore`。 |
| 工具本身的三个坑（都是**先失败再修好**的，留痕） | ① **中文全是方框**：`flutter test` 的引擎只带度量占位字体，缺 CJK 时每个字都是方框，测量结果页不可比 —— 用 `FontLoader` 载入宿主的 DengXian 解决。② **图标全是方框**：`Icons.*` 的 Material 字体同样没被注册，一个空方框看上去**和"图标坏了"一模一样** —— 从 `FLUTTER_ROOT` 的 `material_fonts/materialicons-regular.otf` 载入。③ **四个 Tab 截出来逐字节相同**：`pumpWidget` 遇到**同类型**的 widget 会复用 Element 而不是重建，四个 `AppShell(initialTab: …)` 于是全部沿用了第一个 `_AppShellState`；**一个"每个 Tab 看起来都一样"的假报告**。修法是截图前先 pump 一棵空树。 |
| 一个**没修成**的坑（写出来，免得下一个人重复踩） | 还有两处文字会渲染成方框：**报告页日期 chip 的 `chipTheme.labelStyle`** 与 **雷达图四个轴名**。根因是它们**绕过了 theme 的字体**（前者被 `RawChip` 用它自己的 `DefaultTextStyle` 覆盖，后者是 `CustomPainter` 里的 `TextPainter`，**根本没有 `DefaultTextStyle` 可继承**），于是落到引擎默认 —— 而测试引擎的默认是 **Ahem**（**每个字形都是一个实心黑块**）。试过 `tester.platformDispatcher.systemFontFamily` 与把字体注册到 `Ahem`/`FlutterTest` 家族，**都不生效**。结论：**这是 harness 的属性，不是 App 的缺陷** —— 同样的"没写字体"在 Android 上解析为 Roboto + 系统 CJK 兜底，真机正常。已修的部分：把字体盖到 `chipTheme` 与三个 button theme 上（这消掉了 chip 与按钮的黑块）；**剩雷达四个轴名仍是豆腐块**，它们的**内容**改用 `flutter test` 断言，像素只用来判断版式。 |
| 先看一眼，**推翻了两个我自己的判断**（这就是"先取证"的价值） | ① 我以为顶栏下面有一道**硬接缝**（AppBar 不透明、渐变从下面才开始）—— 逐像素采样纵向颜色后发现 `0 → 340px` 是**连续渐变**（`#57D2B4 → #84DEC6`），**没有接缝**，判断错了。② 我以为记录页满屏的「未知类别」是 App 缺陷 —— 实际是我的截图夹具**没有调用 `loadKnowledgeBase()`**，`services.catalog` 是空的，于是每个食物都走了「不猜名字」的降级路径。**都是夹具的错，不是产品的错**；两处都记在这里，因为"看起来像 BUG"和"是 BUG"在证据上长得一样。 |
| 改动①：**统一的顶栏** `AcouPageHeader` | 六张示意图画的是**同一个顶栏**：品牌字标在左、**页面标题居中**、页面自己的操作在右，全部浮在渐变上。`ADR-24` 只搬了渐变，**每个页面各自 new 一个 `AppBar`** —— 于是四个顶层页面的标题**全部左对齐**，这是示意图里唯一一块从没被真正重建的 chrome。新增 `widgets/acou_app_bar.dart`：标题槽是一个三段 `Row`，左右两段**共用同一个 `Expanded` flex**，所以标题落在**真正的几何中心**（不随字标宽度或按钮个数偏移）。推到二级页时左槽自动换成返回箭头（示意图 `2.png`/`3.png` 就是这样），**否则「我的」变成死路**。检测页的 C-03 门禁分支也一并接入 —— 它此前是全 App **唯一**不写 `extendBodyBehindAppBar` 的页面（顶栏是不透明的、渐变从下面才开始）。 |
| 改动②：记录卡**右侧度量列**（示意图 `8.png`） | `widgets/record_card.dart` 的**文件头注释**从 `ADR-24` 起就写着"千卡在它自己的右侧列、份量在下面"，**而代码把千卡渲染在名字下方、左侧文本列里** —— 两轮里没人发现，因为**注释不是检查**。现在按注释与示意图实现：左侧 = 图标块 + 时间/名称 + 属性·份量行 + 置信度 chip；右侧 = 千卡（上）+ 折叠箭头（下）。无知识库条目时**右侧整列不出现**（不编造估算）。 |
| 改动③：「我的」每条**加一行描述**（示意图 `9.png`） | 示意图每一行标题下都有一句说明，本页是唯一没写的。新增四条文案（`healthReportEntrySubtitle` / `privacyEntrySubtitle` / `selfCheckEntrySubtitle` / `aboutEntrySubtitle`），并给隐私/关于两行补上 `spoken` 常量（此前是页面里的字面量）。**判据不是"看起来像"，而是可判定的**：每条描述**逐字等于该行 `spoken` 标签里逗号之后的那一句**（`spoken == '$title，$subtitle'`，四条全部断言）。一行本来只对这件事说一句话，描述只是这句话的一个切片，**因此不可能引入该行没说过的新指标或新承诺**；描述行用 `ExcludeSemantics` 包住，**读屏不会把一行念两遍**。 |
| 改动④：雷达的四个轴名**回到设计系统** | `four_dim_radar.dart` 之前在 `CustomPainter` 里**自己 new 了一个 `TextStyle(fontSize: 11, color: ink)`** —— 全 App 唯一一处**不来自 token、也不跟随用户字号**的文字（`CustomPainter` 没有 `DefaultTextStyle` 可继承）。改为由 widget（唯一有 `BuildContext` 的地方）解析 `AcouTheme.chartAxisLabel` + `MediaQuery.textScalerOf(context)` 后传进 painter，`shouldRepaint` 也随之比较这两项。 |
| 改动⑤：检测圆盘的**静默态**（示意图 `3.png`/`10.png`） | 检测页是六张图里**唯一一个不像自己设计稿**的页面：没有音频时 `level` 为 0，圆盘里**只有一条发丝基线**，就是一个空绿圆。新增 `WaveformView.idleSilhouette`：一层**静态**站波母题（永不移动，所以任意两帧都相同；低透明度；**只要来一个真样本就立刻消失**），只有 `WaveCircle` 传入。它承载**任何数值**，性质与 `AcouTheme.starGold` 相同；旁边的状态行照旧写「当前静默」，语义标签与无障碍树一个字没改。**这是本 ADR 唯一一处"为了像示意图而画了不是测量的东西"，因此专门写了判据把它钉住。** |
| 明确**仍然不补**的（逐条核对，不是遗漏） | 示意图 `1.png` 的两条**进度条**（`1286/2000 kcal`、`8/12 种`）需要分母，而本仓能量是 **±20% 区间**、多样性概念**已被 README §8 换成记录次数**（`ADR-24` 判定③已记为否决）；五轴雷达、EatSense 命名、「我的」作为第 4 个 Tab 同样维持 `ADR-24` 的原判。 |
| 新增闸门（**两条，且都做了负控**） | ① `test/ui/app_bar_test.dart`：四个顶层页面的标题**中心与 AppBar 中心的偏差 < 1 逻辑像素**，且根页左槽是字标、**被 push 的页面左槽必须是返回箭头且真的能 pop**。② `test/ui/mockup_layout_test.dart`：记录卡的千卡**必须落在卡片右半边**、且在份量行之上，无知识库条目时全卡不出现 `kcal`；`WaveformView.showsIdleSilhouette` 的**四种取值**（有/无样本 × 有/无母题）。**负控实测**：把记录卡的 `Row` 加 `textDirection: rtl`、把顶栏左段 `Expanded` 改成 `flex: 2` → 新测试**5 条全红**（`Expected: <1.0> Actual: 118.67`，`title centre 518.67 vs bar centre 400.0`）；复原 → 全绿。**一个不可能失败的闸门等于没有闸门。** |
| 回归实测 | `flutter test` **143 → 156 全过**（新增 `app_bar_test` 7 项、`mockup_layout_test` 6 项）；`flutter analyze` **0 error**；`tool/verify_all.ps1` **20 步全过**（含真实 `flutter test` 与离线 presenter 套件 `UI: 413 passed`）；FF-25 文案红线扫描的字符串集合**191 条**（新增的 5 条已并入 harvest，否则"新文案没人扫"）。截图逐屏复核 10 张（首页 / 记录 / 检测 / 报告 / 我的 / 记录详情 / 自检面板 + 四个 Tab）。**release 包重打并逐项复验**：`dist/AcouDiet-1.2.1-arm64-release-no-llm.apk`，**70,858,649 B**，sha256 **`97f794770adda06b13c0f6ae7faa4733714c27281ab0b40e22640c5494e91add`**（上一版是 `9bfeb447…`，**字节数恰好相同**），4 个 ABI 齐全、`INTERNET` 缺席、包内模型 sha256 与模型卡逐字节一致、`RESULT: 16 KB COMPATIBLE`、`ui_fingerprint_check.py` → `RESULT: CURRENT UI`。 |
| ⚠️ 一处**看起来像缺陷、实测不是**的（留痕，免得下一个人白查） | 我一度以为 `build_release_v11.ps1 -Force` 只覆盖 APK、**不更新 `.sha256` 边车**，那样边车就会描述上一份字节（正是"制品在说谎"这一类）。**实测反驳**：脚本第 236 行 `Set-Content -Path "$final.sha256"` 每次都重写，且重打后边车内容 = `97f79477…  AcouDiet-1.2.1-arm64-release-no-llm.apk`，与文件实测哈希**相等**。**先查了再下结论，结论就变了** —— 与本 ADR 上面两处"先取证再判断"是同一件事。 |
| 诚实边界 | ① 本轮修的是**版式与一致性**，**没有做像素级比对**：圆角、阴影、间距仍是 Flutter 对示意图的**近似**。② 截图是 `flutter test` 的软件光栅，**不等于真机观感**（那里的字体是 Roboto + Noto CJK，且本轮的字体覆盖在真机上不需要）；**真机逐屏核对待办仍然没做**。③ 雷达四个轴名在截图里仍是豆腐块（原因见上），只能靠断言而不是靠看。④ 新增的 5 条用户可见文案是**我写的**，不是设计稿的原文（设计稿用的是别的品牌与别的句式），已并入 FF-25 扫描但**没有做过人工文案评审**。⑤ 顶栏把标题居中后，标题与左右两段**共用一个行宽**：极端的长标题或大字号下会在段内省略（`TextOverflow.ellipsis`），本轮**没有**在最大字号下逐屏核对。 |

---

### ADR-39 ✅ 引入 Apple 的**做法**（不是它的资产）：先在 DSH 里装一份 HIG 规范，再改

| 项 | 内容 |
|---|---|
| 来源 | 用户：「再优化 UI 界面，如果能加入一些 APPLE 应用的风格最好，**先找规范使用 APPLE 应用规范的 skills 安装了再改代码**」。 |
| 第一步：**找** | `find_dsh_plugin` 用 4 组关键词（`apple human interface guidelines iOS design` / `apple hig ios swiftui design system skill` / `design system guidelines ui ux` / `mobile ios flutter ui`）搜遍 DSH 插件市场：**没有任何 Apple HIG 插件**。本地已装的 120 个 skill 里与 Apple 有关的只有 `premium`（描述写 "Apple-inspired"），但它的内容是自动生成的通用模板——**字体写 Inter、主色写 `#3B82F6`，都不是 Apple 的值**，当不了规范。 |
| 第二步：**装** | 从 GitHub 找到两份真实的社区 HIG skill，`git clone --depth 1 --filter=blob:none --sparse` 只取需要的那一个目录，装进 `~/.dsh/skills/`：<br>① **`apple-hig-foundations`**（19 文件 / 451 KB，来自 `FrancoStino/opencode-skills-collection` 的 `bundled-skills/hig-foundations`，自带 `risk: none / source: community` 元数据）——color / typography / layout / materials / motion / sf-symbols / privacy / right-to-left 等 18 篇，含 **Apple 官方数值表**；<br>② **`apple-ios-hig`**（38 文件 / 100 KB，来自 `pproenca/dot-skills` 的 `ios-hig`）——6 大类共 34 条可判定的规则（`nav-*` / `inter-*` / `acc-*` / `feed-*` / `ux-*` / `vis-*`）。<br>**装机时做了三件事**：把 frontmatter 的 `name:` 改成目录名（否则目录与文件对不上）；只用 `git`（网页版 Apple HIG 是 JS 渲染，`web_fetch` 只拿得到标题）；**逐文件读过 SKILL.md 才启用**——两份都是纯设计规范，没有可执行载荷（`Get-ChildItem ... -notin '.md','.json'` 返回空）。 |
| ⚠️ **第三方 skill 的边界** | 两份都是社区作品，不是 Apple 出品。`apple-ios-hig` 的说明还假设了一套 "clinic MVVM-C / SwiftUI" 架构，与本仓（Flutter / Android）无关——**只采用它的平台级规则**（触控尺寸 / 布局边距 / 动态字体 / 材质 / 动效 / 触感），不采用它的架构契约。 |
| **采用的「做法」①：Apple 的字阶** | 全 App 的字号与行高改按 **Apple Dynamic Type（iOS "Large" 默认档）**，数值取自 `apple-hig-foundations/references/typography.md` 的规格表：`LargeTitle 34/41 · Title1 28/34 · Title2 22/28 · Title3 20/25 · Headline 17/22 · Body 17/22 · Callout 16/21 · Subhead 15/20 · Footnote 13/18 · Caption1 12/16 · Caption2 11/13`。落点：正文 **15 → 17**、次级 14 → 15、标题 19 → 20，并且**每个样式都补上 Apple 的行高**（22/17、20/15、16/12、25/20、28/22）——此前文件里三个行高（1.35 / 1.3 / 1.25）是随手写的，而行高本来就是文字样式的一部分。全部在 `AcouTheme` 里以 `leading/size` 的除法形式写出，让「这是 Apple 的表」一眼可查。 |
| **采用的「做法」②：材质（material）** | Apple 的 chrome 是**半透明 + 背景模糊**，不是一个颜色。新增 `AcouTheme.materialBlurSigma = 20` / `chromeMaterialTint = #D9FFFFFF`（85% 白，**不是 100%**——100% 就又是一块白板）。**底栏**改成 `ClipRect + BackdropFilter + 半透明底 + 顶部发丝线`，并且外壳改用 `Scaffold(extendBody: true)` 让页面**真的从底栏下面穿过去**——否则模糊无从谈起，材质只是装饰。页面因此拿不到底栏高度，改为由外壳把它**注入 `MediaQuery` 的 bottom inset**（新增 `AcouTheme.bottomInset`），五个页面各自在原来的尾距上加它，谁都不需要知道"有个底栏"。 |
| **采用的「做法」③：scroll-edge 外观**（本轮最实的一处） | Apple 的导航栏在内容滚到下面时才变成材质。**这不是锦上添花，是修了一个可见缺陷**：截图上滚动的记录页把卡片正文**直接画进了居中的标题「饮食记录」**里（`shell_records_scrolled.png` 留下了这一帧）——因为 ListView 的顶部内距会随内容一起滚走，中间就没有任何东西隔开。新增 `AcouScrollEdge`（`NotificationListener<ScrollNotification>` + `InheritedWidget`）与 `AcouChromeMaterial`；页面只需把自己的 `Scaffold` 包一层，顶栏自己读得到状态（`AcouPageHeader` 内部读 `AcouScrollEdge.of`）。首页因为用的是自己的 AppBar，用了一个 `Builder` 取内层 context。 |
| **采用的「做法」④：页面转场** | `pageTransitionsTheme` 六个平台全部设为 **`CupertinoPageTransitionsBuilder`**：横向滑动 + 旧页视差 + **边缘右滑返回**。Material 在 Android 上的默认是纵向缩放淡入，而"推入一个页面"的手感恰恰是 Apple 应用最容易认出来的特征。路线本身没变（同一个 `MaterialPageRoute`、同一个 `Navigator`）。 |
| **采用的「做法」⑤：触感** | `inter-haptic-feedback` 的原则是「有意义的时刻才用」而非每个点击。落两处：**切换 Tab** → `selectionClick`（`app_shell._select`），**开始/停止检测** → `mediumImpact`（这是全 App 唯一一个手指看不到结果的动作）。**重复点当前 Tab 只刷新、不发触感**，并有判据钉住。走 `HapticFeedback`（即 `View.performHapticFeedback`），**不需要 VIBRATE 权限**——Manifest 与权限集合一个字节没动，APK 闸门每次都在证明这一点。 |
| **采用的「做法」⑥：中性层与发丝线** | 中灰取 Apple 的值（`surfaceMuted` = `systemGray6 #F2F2F7`，`outline` = `opaqueSeparator #C6C6C8`），新增 `AcouTheme.hairline = 1/3` 并把 `DividerTheme` 从 1 dp 改成发丝——Apple 用能分辨出的最细一条线分隔两个面，1 dp 读起来像"框"而不是"分界"。这些角色都不承载文字，所以可以直接取 Apple 的值。 |
| 🔴 **明确拒绝的：Apple 的系统色**（有测量） | 用 `_toolchain/dl/python` 按 WCAG 公式算过 **12 个候选值**在白色上的对比度：Apple 常见的 `systemGreen #34C759` **2.220:1**、`systemBlue #0088FF` **3.520:1**、`systemMint #00C8B3` **2.119:1**、`secondaryLabel` 合成后 `#8A8A8E` **3.439:1** —— **全部不满足本仓 U-06 §8 的 4.5:1**。Apple 自己也为此提供了 *increased contrast* 档：accessible green `#008932` **4.541:1**、orange `#C55300` **4.554:1**、red `#E9152D` **4.555:1** —— 都"过"，但只过 **0.04~0.06**。本仓现有的是 **6.46 / 5.93 / 7.43:1**。**采纳 Apple 的 accessible 档等于用 2~3 个对比度点换一次色相偏移**；`apple-ios-hig` 自己的质量门写着「美学与无障碍冲突时，以无障碍优先」，所以**分级色与次级文字色保持本仓的值**，并把两边数字都记在这里。品牌薄荷本来就在 Apple 的 mint/teal 色族里，无需改动。 |
| 🔴 **明确拒绝的：SF Symbols**（授权未取证） | `apple-ios-hig` 的 `vis-sf-symbols` 建议用 SF Symbols。**但我没能取到授权原文** —— Apple 论坛的许可协议页与 Stack Exchange 都返回拦截页（`verify-human` / 403）。公开讨论普遍认为该许可把 SF Symbols 限制在 Apple 平台的应用里，而这**恰恰是要发到 Android 的包**。在授权没法核实的情况下不引入任何 Apple 图标资产：继续用 Material Symbols，按 Apple 的字重/尺寸约定对齐。**这条记为"未取证"，不记为"没这回事"。** |
| 🔴 **明确拒绝的：深色模式** | `vis-dark-mode` 把深色模式列为 HIGH。但 `SPEC-U-06 §10 #2` 已冻结「v1.0 只做浅色」，这是**有记录的裁定**，不是遗漏。不静默加。若用户要放开，那是一次新的裁定（本 ADR 不改）。 |
| ⚠️ **顺带抓到的一个真缺陷**（不是本轮引入的） | 新增的「**360 dp 手机宽度不许溢出**」判据**第一次跑就抓出报告页的 `食物类别` 行横向溢出 222 px**（`report_page.dart`）。根因是该行写作 `Expanded(标签) + Text(值)`，**值那一侧没有任何约束**，而 `食物类别` 是一整天类别的拼接串。**这个缺陷在本轮之前就存在**，只是本仓所有 widget 测试都跑在 `flutter_test` 默认的 **800×600** 画面上——**比任何手机都宽**，所以从来没人看得见；字号变大只是让它更响。已改为「标签自然宽度 + 值占剩余空间并换行」。 |
| ⚠️ **我自己在这一轮犯的一个错**（留痕） | 首页第一版把 `AcouScrollEdge.of(context)` 写在了 `build` 自己的 context 上，而该 context 在 `AcouScrollEdge` **之上**——`InheritedWidget` 取不到，于是**永远返回 `false`**：代码编译、运行、没有任何报错，材质永远不出现。修法是用 `Builder` 取内层 context。**这正是新判据存在的理由**：它 `jumpTo(300)` 之后断言材质真的出现，否则这条"已实现"的功能会一路静默到发版。 |
| 新增闸门（`test/ui/apple_style_test.dart`，13 项） | ① **scroll-edge 材质确实会出现**：四个页面在顶部时材质不可见（`0`），滚动后必须 > 0（四个页面各一项）；② **底栏是材质而不是色块**：`extendBody == true`、tint alpha ∈ (200, 255)、并且**算过底栏文字压在最深背景（渐变顶 `#57D2B4`）上的对比度 ≥ 4.5**；③ **字阶就是 Apple 的表**：八个样式的 `fontSize` 逐个等于发布值、`height == leading/size`（±0.0001）——**对着确切数字比，不是对着"主题里现在是什么"比**；④ **360 dp 不溢出**：四个页面 + 四个 Tab；⑤ **触感只花在有意义的事件上**：在 channel 层断言切 Tab 发 `selectionClick`、重复点当前 Tab **不发**。 |
| 回归实测 | `flutter test` **156 → 169 全过**；`flutter analyze` **0 error**；`tool/verify_all.ps1` **20 步全过**。截图逐屏复核（含新增的**滚动态**截图 `shell_records_scrolled.png` —— 材质唯一能被看见的状态）。**release 包重打**：`dist/AcouDiet-1.2.2-arm64-release-no-llm.apk`，**70,858,649 B**，sha256 **`2e9fb8793ec306b3e607440afcf8926e63448769ac484e3029ddd24949ec442a`**；4 ABI 齐全、`INTERNET` 缺席、包内模型 sha256 与模型卡逐字节一致、`RESULT: 16 KB COMPATIBLE`、`ui_fingerprint_check.py` → `CURRENT UI`。<br>⚠️ **1.2.0 / 1.2.1 / 1.2.2 三个 release 包的字节数完全相同（70,858,649 / 65,525,041 里最新的两次都是 70,858,649）而 sha256 各不相同** —— 这是本项目**第三次**撞上"同大小、不同内容"，判断装的是哪个包**只能看 sha256**。 |
| 诚实边界 | ① **真机观感仍未核对**：截图是 `flutter test` 的软件光栅，模糊、触感、`Cupertino` 转场在真机上的手感**都还没有实测过**（本机无 adb 设备）。② 触感只在 **channel 层**验证过"命令发出去了"，**没有在设备上验证马达真的震了**。③ `BackdropFilter` 在任何平台都是较贵的操作，本轮的截图跑得动**不等于**在低端机上不掉帧——**没有做性能实测**。④ 字体仍是 Android 的系统字体（Roboto + Noto CJK），**没有、也不能**打包 SF Pro；截图里的字形因此与 Apple 设备不同，只有尺寸与行高是 Apple 的。⑤ **深色模式、SF Symbols 未做**，理由如上（前者是冻结裁定，后者是授权未取证），两者都不是遗漏。⑥ 圆角仍用 `BorderRadius.circular`，**不是** Apple 的连续圆角（squircle）；Flutter 3.24 没有可用的 squircle 实现，本仓不为此引入依赖。 |

---

### ADR-40 🟡 研究路线六项的**范围合规审查**：四项撞上已冻结的裁剪项，一项明文禁止 —— 并附本轮实测（含两条被证伪的假设）

| 项 | 内容 |
|---|---|
| 来源 | 用户读了「AI 博士生视角的六项发展建议」后要求：「**都给我修改进来，包括前端 UI 和后端**」。 |
| ⚠️ 这条 ADR **不是**"已执行"记录 | 它是**范围合规审查 + 实测证据**。用户随后选了「走正式范围变更」这一条路，但**尚未指定 `PLAN-00 §6` 要求的等额删除项**，故**本轮没有改动任何产品代码**。未决项在文末登记。 |
| 🔴 **第一项明文禁止** | **`B5` 咀嚼行为学定量化做不了。** `SPEC-00 §3.6 FF-21j`：❌ 不交付**咀嚼节律标准差 σ**（`X-07` 已裁剪）。而且它不是"没写就行"——`SPEC-P-07 §7 判据 13` 要求 `BehaviorMetrics` **字段名集合恰为 4**（反射断言），配套静态扫描器 `ai/scripts/assert_x07_not_implemented.py`；`SPEC-P-07 §9` 原文：**「禁止顺手实现（含 UI 占位与文案预留位）」**。`docs/00_功能清单` §4 把它列为 7 项已签字裁剪之一。 |
| 🟠 **三项需要修宪，且现在无法验证** | **`B1` 学习式时序解码**：`FF-20a`（首次确认 ≈4–5 s）、`FF-20b`（三档阈值**须用自采跨域测试集**标定）、`FF-20c`（EMA/连续计数跨 patch 保持），`SPEC-P-06` 冻结三级聚合。换解码器 = 改这些实测口径，而**本仓没有那份标定语料**。<br>**`B4` 个人化餐次边界**：`meal_windows` 是冻结 SSOT 键，而 `FF-22` 规律性维度的输入正是**三餐时间 σ**（`mealTimeStdDevMinutes`）。改掉窗口，`SPEC-A-01` 表 A-01-T3 的**四个冻结算例**分数即变。<br>**`B2` 校准与覆盖率**：见下条。 |
| 🟢 **`B2` 其实不是新增功能，是补一条欠着的冻结要求** | `FF-20b` 原文：「三档阈值须在 D3 用自采跨域测试集的置信度分布直方图**标定**，标定过程写进测试报告」。实测：SSOT 里就是硬编码的 `ema_window=5 / ema_alpha=0.4 / confirm_consecutive_patches=4 / tau_confirm=0.70 / tau_low=0.45`，而**全仓没有任何标定报告**（`ai/reports/` 是**空目录**，`AcouDiet/docs/reports/` 十个文件里没有一份讲阈值标定）。**所以 conformal / temperature 标定是"实现 FF-20b"，不是"新增范围"**，不触发 `R-14` 等额删除。（但它**拟合**需要真实 logits 分布，本仓仍缺。） |
| 🟢 **两项本来就在范围内，而且是欠着的交付物** | **`B6` 噪声鲁棒与增广**：`X-06` 裁掉的是 **RIR 混响 + Mixup**；噪声/增益/LUFS/SpecAugment **是保留项**，`API-06 §98` 必报项⑧ 要求 `ablations[]`（含基线行 + 「降噪 on/off」+「各增强 on/off」），`SPEC-T-06` 专治此事 —— 而 **`ai/artifacts/ablations.json` 不存在**。<br>**`B3` 反馈学习信号**：`confirmedByUser` / `correctedByUser` 两列**已在 schema**（`ADR-P6` 保留），`ai/scripts/ingest_feedback.py` **已存在**，`ai/data/feedback/` 是**空目录**。离线 ingest 通路无需新裁定。 |
| ⚠️ 宪法级前提（不能绕过） | `PLAN-00 §6`：7 项裁剪已签字冻结，**任何新增功能须等额删除一项**（`R-14`）。`SPEC-T-06 §112` 甚至逐字写着：「有人要求'补一行 Mixup 做对比' → 需求变更 → **直接拒绝**」。 |
| **实测①：语料是可分的**（推翻"任务太难"） | 新增一次性探针（`_toolchain/tmp/`，未入库）在 `ai/data/raw/public/**` 上做 64 带 log-mel 均值+标准差的线性探针，5 折分层 CV：**acc = 1.0000 ± 0.0000**；纯时域统计量作对照也有 **0.9292**。语料毫无问题。 |
| **实测②：仓里的划分也是可分的**（推翻"划分把类信号切断了"——**这是我的假设，被证伪**） | 直接读 `ai/data/splits/{train,val}.csv`，用**仓里真实那份划分**训练 / 评估同一探针：**acc = 1.0000**，`chips/cabbage/gummies/noodles/carrot/drink` **每类 recall 全 1.00**（`source_file_id` 无重叠）。随机 80/20 对照同为 1.0000。**划分不是问题。** |
| **实测③：仓里自己的 `feature_tensor` 输出也是可分的**（推翻"特征管线坏了"——**也是我的假设，也被证伪**） | 直接 import `ai/src/augment.py::feature_tensor`，以 `augment_on=False` 跑 **仓里自己的**四级特征链（`preprocess_patch → mel_power → db_compress → select_frames → per_patch_minmax → to_model_input`），对输出张量做同一探针：**acc = 1.0000 ± 0.0000**。**特征链完好，没有 bug。** |
| **实测④：`model.py` 关于"本环境没网络"的说明在这台机器上不成立** | `model.py` 的 docstring 写：「Fetching those weights needs the network, which is not available here」，失败则**降级为随机初始化**。实测 `https://storage.googleapis.com/...weights_mobilenet_v3_small_224_1.0_float_no_top_v2.h5` **可达**：HTTP 200，4,334,752 B，15.4 s 下完。训练实跑打印 **`pretrained : True`**。即 `FF-17` 的 ImageNet 预训练**本来就能满足**，那条降级路径不该被触发。 |
| **实测⑤：带预训练的训练跑不出东西**（本轮最关键，但**尚未定案**） | `train.py --run-id adr40-ref --augment off --denoise off --epochs 8 --limit 480`（`pretrained: True`，942,588 参数）：trainLoss **0.6487 → 0.4298**，而 valLoss **卡在 1.95–2.05（> ln 6 = 1.7918）**，valAcc **六个 epoch 恒为 0.166667**，valMacroF1 **恒为 0.047619**，早停。即**预测恒定塌到一个类**。<br>**但**：这是 8 epoch × 15 步 = **仅约 120 步梯度**。所以**「优化不足」与「训练环有 bug」这两种解释本轮还没能被分开** —— 已另起 `--limit 1200 --epochs 25`（≈760 步）的长跑在后台定案，**结果出来前不得下结论**。 |
| ⚠️ 因此**上一轮我给用户的一处说法要修正** | 我先前说「出厂模型是常数预测器 ⇒ 本仓训练从未成功 / 管线有问题」。现在实测③已证明**特征链是好的**、实测②证明**划分是好的**。所以贴切的表述是：**本仓的 `T-04` 从未跑完（`ai/reports/` 空、`train_log` 只有 2 个 epoch、`artifacts/runs/` 只有两个 `train_config.json`）**，而出厂模型在本仓**合成**语料上塌成常数类，**不足以推出交付模型在真实语料上失效**（`H2` 域不匹配依然可能）。**不要把 16.7% 当成对模型组的结论。** |
| 成本实测 | 全量 2185 条、`--epochs 20`：首轮 20 分钟以上仍未完成首 epoch（上一版 `baseline` 只跑 15 步/epoch 所以是 106 s）。**CPU 上做 T-06 的 2×2 消融必须加 `--limit`，否则是十来小时量级。** |
| **未决项（须用户裁定才能继续）** | ① **等额删除清单**：`B5` 需要一项；候选 `X-04` 静态成就区（`AchievementsStatic` + `SettingsPresenter.achievements` + 1 条 presenter 断言 + `SPEC-U-05` 两处条目），裁剪表自己写它"纯 UI 逻辑，零技术含量"。未指定则**不执行**。<br>② **`B1` / `B4` 是否接受"先只做不破坏冻结行为的架构层"**（可插拔解码器默认仍是冻结规则；餐次边界只做"报告层"不改 `FF-22` 输入），还是坚持改语义并重导 `SPEC-A-01` / `SPEC-P-06` 的验收。<br>③ **`B2` 的拟合数据从哪来**：本仓无真实跨域语料。 |
| **🟢 已执行（目标轮 1）：`B2` 的离线半边 —— 把 `FF-20b` 从"要求"变成"有实现、有判据、有报告"** | 新增 **`ai/scripts/calibrate_thresholds.py`**：① **temperature scaling**（黄金分割求 NLL 最小的 T，端点命中即报错而不是返回边界值）；② **split-conformal** 分位数 `ceil((n+1)(1-α))`，并测量**held-out 上的经验覆盖率**；③ **ECE**（15 等宽桶）标定前后对比；④ 写出 `ai/reports/threshold_calibration.md` —— **这正是 `FF-20b` 要的"标定过程写进测试报告"**。全程**不需要训练**：它吃的是 `tool/evaluate_shipped_model.py` 对**出厂模型**的逐样本预测。<br>**判据接进 `ai/tests/run_all.py`**（挂进现有的 AI guard-rails 步骤，**故 `verify_all.ps1` 仍是 20 步**），共 **5 条**，而且刻意不只看退出码 —— 自测的**负控**才是它的价值：删掉任一负控，退出码依然 0，所以每条负控的**存在性**都从输出里断言。36 项检查全过。 |
| ⚠️ **我在这一轮里犯的两个错，都留下** | ① 我先说「`ingest_feedback.py` 缺测试」—— **错的**：`ai/tests/run_all.py` 里**早就有一整套**（含 cp936 编码崩溃与 BOM 导出两条回归）。我没看就先下结论。② 自测第一版的 conformal 负控写成「去掉 `+1` 的 off-by-one」—— 实测在 n=2000 时它只让覆盖率动 **0.0005**（0.9487 vs 0.9493），**远低于蒙特卡洛噪声，等于没有负控**。有限样本修正是 O(1/n)，**负控必须放在它看得见的地方**：改成在小标定集（40/200）上用**明显偏小**的分位数，实测 0.9277/0.8799/0.7838 vs 正确的 0.9490/0.9038/0.8084，差 2–3 个百分点，**这才是一个能失败的判据**。 |
| **🟢 已执行（目标轮 2）：用出厂模型跑出真实的 FF-20b 标定报告** | `tool/evaluate_shipped_model.py` 新增 `--predictions`（逐样本概率导出；聚合混淆矩阵**无法**用于标定，temperature 与 conformal 都要每一行完整的概率向量），对出厂模型导出 **612 条**（test_public 468 + test_mobile 144）。<br>**结果（`ai/reports/threshold_calibration.md`）**：<br>· fitted temperature **UNBOUNDED** —— NLL 最优点跑到搜索上界（20 与 1e4 **两次**都撞界）。<br>· ECE 标定前 = 后 = **0.3972**（撞界即回落 T=1，**不声称任何改善**）。<br>· conformal 分位数 q = **0.9993**；held-out 经验覆盖率 **0.8958** vs 目标 0.90。<br>· **平均预测集大小 = 5.76 / 6 类** —— 这是整份报告最要紧的数字：**要买到 90% 覆盖率，门槛必须几乎把六类全返回**。<br>· held-out 上只预测过 **3/6** 类（`chips`/`cabbage`/`noodles`）。<br>· **`RESULT: FAIL`**，理由写明是"没有有限温度能让 NLL 最小"。 |
| ⚠️ **一处判据设计缺陷，被这次真实运行暴露并修掉** | 我原以为只有一种失效模式：「输出不依赖输入（常数预测器）」。真实的出厂模型**不是**常数预测器——它预测 3 个类、逐样本最大概率的 std = **0.1046**，所以我的 `degenerate` 判据判成 **no**，报告里先打了一行 ✅「describes a real calibration」，**紧接着**下一行却是 `T = UNBOUNDED`、集大小 5.76/6。**一份自相矛盾的报告比没有报告更坏**（这是本仓反复出现的主题）。已改为**两种失效模式分开命名**：`degenerate`（输出与输入无关）与 `uncalibratable`（无有限 T 使 NLL 最小）；二者任一成立即判 **FAIL**，且 ✅ 分支只有在**两者都不成立**时才出现。诊断段现在写明：「输出会动，但它**不随标签动**」。 |
| **口子收在哪里** | 撞界没有靠"把上界调大"糊过去——第二次撞到 1e4 时我没有再放宽，而是改为**在拟合前判退化**，并把"上界被撞"本身就是测量结果。**放宽搜索区间会把一个"不可标定"的结论伪装成一个有限的 T 值。** 这也是 `RESULT` 不再只看 ECE 的原因：退化模型的 ECE 可以被压到 0（压平到均匀分布），那恰恰是校准的反面。 |
| 本轮实际改动 | **产品代码零改动**。新增：`ai/scripts/calibrate_thresholds.py`、`ai/reports/threshold_calibration.md`、`tool/evaluate_shipped_model.py` 的 `--predictions`、`ai/tests/run_all.py` 的 6 条判据（含"报告必须存在"）。三个一次性探针在 `_toolchain/tmp/`（未入库）。 |

---

### ADR-41 ✅ 把手工投票器改成**可注入的解码器**：默认实现逐字不变，且这件事被证明"能不能失败"

| 项 | 内容 |
|---|---|
| 来源 | 目标项 (1)「可插拔时序解码器替换手工投票器（**保留手工规则作为 baseline 实现**）」。 |
| 为什么这一项**不需要裁定** | 目标的措辞本身就是"不破冻结"的版本：接口化 + 默认实现不变。`FF-20a`（首次确认 4–5 s）、`FF-20b`（阈值须标定）、`FF-20c`（EMA/连续计数跨 patch 保持）约束的是**默认行为**，而默认行为一个字节没动。 |
| 改了什么 | `inference.dart`：新增 `abstract class SequenceDecoder`（`sampleCount` / `consecutiveCount` / `reset` / `add`），把原来的三级聚合逻辑**原样搬进** `ThresholdVoteDecoder implements SequenceDecoder`，并把 `VoteAggregator` 改成**纯委托**的门面（`implements` 而非 `extends`——继承会留下一个能覆盖半条规则的子类，而这次拆分的全部意义就是"冻结行为只有一份实现"）。<br>`detection_session.dart`：新增可选参数 `SequenceDecoder? decoder`，`_aggregator` 的类型从具体类放宽到接口，构造改为 `decoder ?? ThresholdVoteDecoder(cfg: votingConfig)`——**生产接线传的都是 `null`，即今天的规则逐字不变**。<br>**调用点零改动**：`VoteAggregator` 这个旧名字仍然可用，`pure_tests` / `session_tests` / 所有既有断言一行没改。 |
| 判据（**6 条，其中有 4 条是控制**） | `pure_tests.dart`：① 同一段 24 patch 脚本分别驱动门面与默认解码器，**整条决策轨迹逐字符相等**（不是只比最终状态——只比最终状态会漏掉"中途分叉又收敛"）；②③④ **轨迹本身的正控**：脚本必须走过 ≥3 个 stage、必须触发过 confirmed、必须触发过 asking 分支——**否则等式在一条退化轨迹上照样成立而毫无意义**；⑤ **负控**：换一个 `tauConfirm/tauLow = 0.99` 的解码器，轨迹**必须不同**。<br>`session_tests.dart`：⑥ 注入一个 **spy 解码器**，断言会话真的驱动了它、且**上报的是它的答案**。 |
| ⚠️ **这里我写了一条不可能失败的判据，并且是靠负控抓出来的** | spy 第一版返回 `VoteStage.confirmed`。我把注入接线**故意拆掉**去跑负控时发现：它依然通过——因为手工规则在六个 0.90 置信度的 patch 上**也**到 `confirmed`。**一条在错误实现下依然通过的断言等于没有断言**。改为让 spy 返回 `lowConfidence` + `shouldAskUser=true`（脚本输入是高置信度的，默认规则**给不出**这个答案）。**负控实测**：拆掉注入后 **3 条全红**（`adds=0`；`actual=VoteStage.confirmed expected=VoteStage.lowConfidence`；`shouldAskUser actual=false expected=true`），恢复后 **SESSION 127 全绿**。 |
| 诚实边界 | ① 这**只是接口与默认实现**，**没有**第二个可用的学习式解码器——目标里"替换"的那一半要等一个能用的逐帧预测器（见 `ADR-40`：出厂模型塌成常数类）。所以本 ADR 交付的是**扩展点 + 无行为变更的证明**，不是"换成了学习式解码"。② 没有性能实测：多了一层委托，开销应可忽略但**未测**。③ UI 无改动——解码器的选择目前只有测试会注入，生产仍是 `null`。 |
| 回归实测 | `verify_all.ps1` **ALL SUITES PASSED (20 steps)**；`PURE 207`（新增 6）·`SESSION 127`（新增 3）·`UI 413`·`DATA 63`·`NATIVE 79`；`flutter analyze` **0 error**。 |

---

### ADR-42 ✅ 小模型加了，但加在**工具链**而不是 App 里 —— 并且它的第一条真实判定就判了出厂模型 FAIL

| 项 | 内容 |
|---|---|
| 来源 | 用户：「你可以尝试加入新的小模型来辅助」。 |
| 先测：现成小模型到底带不带这个任务的信号 | **YAMNet**（唯一体积合规且拿得到的候选）：**4,126,810 B**，`TFL3`，Apache-2.0（与 Apple SF Symbols 不同，**无平台授权限制**）；输入 `[15600]` float32 **裸波形**，输出 `[1,521]` AudioSet。实测在自家语料 240 条（每类 40 条、每类平均 7–9 个窗口）上取 AudioSet 分数均值做线性探针：**acc = 1.0000 ± 0.0000**。 |
| ⚠️ **但这个数字不能用来支持"YAMNet 更有用"** | **同一个探针在原始 log-mel 上也是 1.0000**，纯时域统计量是 0.9292。也就是说**这批合成语料几乎任何特征都能分开**（`make_synthetic_dataset.py` 自己写着它不是科学结果）。该实验只能证明 YAMNet **不更差**，**无法**证明它更好——要分出高下需要真实语料。**把 1.0000 读成"YAMNet 解决了问题"会是这一轮最容易犯的错。** |
| 为什么**不能**放进 App | `FF-11`/`FF-14` 把模型输入冻结成 `[1,128,128,1]` 的 Mel 张量，由 Kotlin 前端产出；YAMNet 要裸波形并自算 mel。接进 App 等于让冻结的 Kotlin Mel 前端不再是模型前端，**并打挂 `T-08b` Kotlin↔Dart 一致性——§6「不可砍」五项之一**。另一个候选 `m3hrdadfi/wav2vec2-base-100k-eating-sound-collection` 实测 `pytorch_model.bin` **380,001,726 B = FF-16 fp32 上限的 60.4 倍**，且是 PyTorch（`FF-13` 明文否决 ONNX 转换路线）。 |
| 所以小模型加在哪 | **工具链**——它已经在那里证明过价值：ADR-40 正是靠一个逻辑回归探针才发现"出厂模型输出与输入无关"。新增 **`ai/scripts/model_sanity.py`**，把那个一次性探针变成常驻判据：① `degeneracy()` 报告预测到的类数、逐样本最大概率的离散度、**argmax 翻转率**；② `separability()` 用最小可用模型（线性分类器）回答"模型坏了还是语料坏了"这个对照问题。**不改任何冻结项、不触发 `R-14`**（它是判据，不是产品功能）。 |
| ⚠️ **我的阈值第一版太松，是真实运行抓出来的** | 原判据是 `distinctClasses < max(2, nClasses//2)`。出厂模型实测预测 **3/6** 类，而 `3 < 6//2 = 3` 为假 —— 于是**它通过了**。这明显不对：**一个永远不被预测的类，App 就永远报不出它**；在 468 条均衡样本上"从不"不是抽样偶然。已收紧为**任何一类不可达即 FAIL**。收紧后：自测（健康模型预测满 6 类）仍绿，**真实产物 FAIL**（`3 of 6 classes were never predicted on this sample`）。 |
| 判据（4 条接进 `ai/tests/run_all.py`，总计 **41** 项） | ① `--selftest` 退出 0；② **常数预测器必须被抓**（`ok=False`）；③ **输入相关的模型不得被误报**（`ok=True`）；④ **可分性对照两个方向都要成立**（可分语料 0.9733 / 纯噪声 0.2300 vs chance 0.1667）。自测**不需要模型也不需要语料**，所以能进 CI。 |
| ⚠️ **我刻意没有做的一件事** | 我**没有**把"出厂模型必须通过 `model_sanity`"接进 `verify_all.ps1`。那会让发布门禁因为模型有缺陷而**永久变红**，等于单方面宣布"这个 APK 不许发布"——那是**产品裁定**，不是工程判断。现在 CI 验证的是**检测器本身有效**；真实产物的判定作为诊断报告存在（`RESULT: FAIL`）。是否让它阻断发布，**留给你决定**。 |
| 回归实测 | `verify_all.ps1` **ALL SUITES PASSED (20 steps)**；`GUARD-RAILS: all 41 checks passed`。 |
| 诚实边界 | ① **没有真实语料**，所以"YAMNet 可用"与"语料太好分"在这一轮**无法区分**。② 未做真机/inference 性能实测：YAMNet 是**第二个**模型，若真进 App 还要解 `assets/models/` 只允许一个 `.tflite` 的断言。③ 探针脚本在 `_toolchain/tmp/`（未入库）；入库的是 `model_sanity.py` 与它的判据。 |

---

### ADR-43 🟡 找"极小现成模型"：**找到了、也验了，但它辅助不了这六个类** —— 契约对、语料域不对

| 项 | 内容 |
|---|---|
| 来源 | 用户：「我要求的是极小模型，和现在放入的这种差不多，不需要有多高智慧，只要辅助即可」，以及「**我不要训练，你给我去网上找符合要求的**」。 |
| 苛刻的筛选条件（来自前面几轮的结论） | 要能进 App 而不破冻结项，辅助模型**必须吃同一类输入**：`FF-11`/`FF-14` 把主模型输入冻结成 `[1,128,128,1]` **Mel 张量**，由 Kotlin 前端产出。吃**裸波形**的模型（如 `YAMNet-1`，4,126,810 B）会让这个前端不再是模型前端，并打挂 `T-08b` —— §6「不可砍」五项之一。所以真正要找的是：**吃 Mel 图像的极小模型**。 |
| **找到了**：`STMicroelectronics/yamnet` → **Yamnet-256** | ST Model Zoo 的 MCU 级模型，**Apache-2.0**。README 明确写着 Google 原版 YAMNet 的"波形→mel"自定义层**已被剥离**，所以它**直接吃 `(64, 96, 1)` 的 mel 频谱图**。HF 上只有 README（`usedStorage: 0`），权重在 ST 的 GitHub 仓库。 |
| 实测契约（逐项量过，非文档转述） | 下载路径 `.../yamnet/ST_pretrainedmodel_public_dataset/esc10/yamnet_e256_64x96_tl/yamnet_e256_64x96_tl_int8.tflite`。`.tflite` 在 git 里是 **131 B 的 LFS 指针**（走 `media.githubusercontent.com` 取真身）。**真身 185,376 B**，LFS `oid sha256:2a0c5806…` 与文件实测 sha256 **逐字节相符**，`magic@4 = TFL3`。<br>**IN** `[1,64,96,1]` **int8**，scale **0.05304647**，zero_point **44**；**OUT** `[1,10]` float32 softmax（实测和 = 1.000）。**185,376 B 是出厂模型的 1/21.9。** |
| **然后实测它在自家语料上的行为——不通** | 写了一个**完整写明的**适配器（128→64 mel 取相邻对均值；128→96 帧取居中窗口；`round(v/scale)+zp` 再 clip），在 `val.csv` 上每类抽 20 条跑：<br>· 六个 repo 类的 argmax **全部是同一个 ESC-10 类 `chainsaw`**；<br>· 平均 top-1 概率 **0.5620**；跨类标准差均值仅 **0.0376**；<br>· 逐类均值表里 `chainsaw` 恒占主导（0.35–0.76），`rooster`/`sneezing`/`helicopter` 恒为 0。<br>**结论：作为六类辅助它是装饰性的**，与出厂主模型同一种失效特征。 |
| 为什么不通（脚本运行时**预先**写明的诚实边界，事后被印证） | ST 用它自己的 mel 参数（25 ms 窗、10 ms 跳、125–7500 Hz，以及它自己的 dB 范围）；本仓冻结的是 `FF-02`/`FF-16`（128 mel、129→128 帧、`ref=patch_max`、per-patch min-max）。我的适配器只做**形状与量程**，**不做语义** —— 把我们的 mel 灌进它的 int8 输入是**跨域**的。**一个负结果因此不能证明模型坏，只能证明"这样接不通"。** |
| 唯一能走通的两条路（**都越过了用户的限制，所以都没做**） | ① **按 ST 的参数再算一份 mel** → 需要在前端新增一条 Mel 通路，即 `FF-02`/`FF-16` 修宪 + `T-08b` 受影响。用户禁止训练，但**这条不是训练**，是前端改造 —— 需要裁定。<br>② **在 Yamnet 的 embedding 上拟合一个头** → 那**就是训练**，用户已明确否决。<br>⚠️ 而且**即使①走通也仍然辅助不了六个类**：这个头是 **ESC-10**（狗/公鸡/雨/海浪/篝火/婴儿哭/喷嚏/钟摆/直升机/电锯），**一个食物类都没有**；它最多只能当"非进食声音"的否决器。**`FF-19` 是模型组的私有分类法，公开模型不可能预测它** —— 这条结论现在有实测支撑了，不再只是论证。 |
| 我刻意**没有**做的事 | **没有把这个 185 KB 的模型提交进仓库。** 实测已证明它作为六类辅助是装饰性的；把一份用不上的二进制塞进 `assets/` 正是本仓反复警告的"死重"（`ADR-32` 删旧 `.tflite` 用的是同一个理由）。它现在只在 `_toolchain/tmp/`（未入库）。 |
| 诚实边界 | ① 只测了 **ESC-10** 那个头；`fsd50k` 两个头（Knock/Glass/Gunshots/Crying/Speech）**未测**，但按同一逻辑它们也没有食物类，且跨域问题相同。② 适配器只用了**居中 96 帧**一种取法，没有穷举；不同取法可能给出不同的常数类，但**不改变"跨域"这个根因**。③ 未做真机/延迟实测。④ 本轮**产品代码零改动**，只新增本条 ADR 与 `_toolchain/tmp/` 下的三个一次性探针。 |

---

### ADR-44 ✅ **把产品从「离线识别器」改造成「手机端饮食 Agent」**：接入 DeepSeek，正式修订 FF-24 第 4/5 条与 `API-05` §1，并新增 G/U-07/C-06 五个功能

| 项 | 内容 |
|---|---|
| 来源 | 用户：「我现在打算接入 Deep Seek 接口，将该产品打造成一个手机端类似 Agent 类的产品，例如接入后能够自动给食物推荐甚至自动帮忙搜索并下单符合要求的外卖（美团，饿了么，淘宝）。**修改相关冲突宪法条例**，并且**先制作出 spec 和 plan** 然后再开始修改 APP 的 UI 和后端以及连接层，不用询问我。自行使用 skills」。 |
| 这是本项目**第一次放开「无网络」这条基石** | `FF-24` 第 4 条（「APK 不申请 `INTERNET` 权限」）与 `API-05` §1（「v1.0 没有云端后端，**且不允许有**」）是全项目最硬的两条约束，它们此前**从未**被修订过。`API-05` §9.1 的 `T1`（引入 LLM 健康助手）与 §10（启用云端的代价）**正是为这一天预写的**，所以这不是推翻，而是**兑现一份早就写好的预案**。 |
| **裁定一：用「两个风味」而不是删掉第 4 条** | 原第 4 条的价值不在「我们没写网络代码」，而在**一份评委可以当场 `aapt dump badging` 验证的产物**。删掉约束等于把这份产物一起删掉。故：`offline` 风味**逐字节保留** v1.0 姿态（权限集合恰为 `{RECORD_AUDIO}`），`agent` 风味申请 `INTERNET` 并承担新定位。二者**共享同一份核心代码**，差别只在 Manifest overlay 与装配。 |
| **裁定二：最强隐私证据换人** | 新增 `FF-24` 第 8 条「**音频永不离开设备**」——PCM / Mel 张量 / 音频文件的任何形式不得进入任何网络请求体、URL 或磁盘导出，**不分风味、不分版本、不可交易**。它取代原第 4 条成为最强主张，代价是它**不能再用一条 `aapt` 命令证明**（但它可以被三种独立手段守住，见下）。 |
| **裁定三：`FF-26i` —— 外卖「下单」= 交接，不是代下单** | 用户的原话是「自动帮忙搜索并**下单**」。查证后**明确拒绝**后一半，并把它写成**产品边界**而不是未实现项：三家的开放平台都不面向消费端 App 提供下单 API；无障碍代操作要求远超录音的高危权限（与 `FF-24` 第 5 条冲突）且违反平台用户协议；逆向私有接口违法。故 App 只做「构造检索 URL → 唤起目标 App」，最终下单在**第三方 App 内由用户完成**。`U-07` 的文案不得写「自动下单」。 |
| **裁定四：`FF-26c` 默认关闭 + 显式同意门，`FF-26b` 用户自备 Key** | 云端智能首启关闭；开启须经一次性、可撤销的同意门。App **不内置**任何 Key、**不代购**、**不共享额度**。这是本次定位变更最真实的成本，`U-07` 必须把它讲清楚，不得做成「点一下就能用」的假象。 |
| **裁定五：只有一条出口（`R-OUT-4`）** | `G-01` 的 `DeepSeekClient` 是全仓唯一出网点。**不引入 `http`/`dio`/`url_launcher`**：`dart:io` 的 `HttpClient` 够用，且离线套件的 `PUB_CACHE` 里没有它们。崩溃上报 / 分析埋点 / SDK 遥测**仍然禁止**——`ADR-44` 没有放开这一条。 |
| **裁定六：`PLAN-00` §6 的等额删除按「信封」结算** | 原 `R-14`（任何新增功能须等额删除一项）是在**一个**固定窗口（3 人 / 240 h / 余量 6 h）下成立的**预算规则**。直接套用它会产生荒谬结果：为了加 v2.0 的 Agent，要从**已验收的** v1.0 里删掉 5 项。改为：v1.0 信封（40 项）冻结不动，v2.0 信封（5 项 + `API-07`）单独计量，**信封内**仍一条换一条。§6 已把这一条**明写为「范围扩张」**，禁止任何材料声称「范围冻结未被打破」。 |
| **裁定七：`FF-26h` 模型名不得硬编码** | 实测证据：DeepSeek 官方文档在**一年内**把 `deepseek-chat` → `deepseek-v4-flash` → `deepseek-flash` 改过两次并退役旧名。Dart/Kotlin 源码中**不得**出现该字面量，只允许在 `feature_config.agent.model` 与文档里。这条腐烂在编译期与测试里都不会现形，所以只能靠机械判据。 |
| 宪法修订清单（已执行） | `SPEC-00`：§3.9 `FF-24` 第 4/5 条修订 + 新增第 8/9 条、§3.8 `FF-23` 页面数 4→5、§2 新增域码 `G`、§1 目录表与三部分计数（8/27/5 → 9/30/6）、新增 §3.11 `FF-26`（a~j 十条）。<br>`API-05`：§1 由「零出口」重写为「唯一出口」并附**逐项对账表**（哪条放开、哪条仍然禁止）、§3 数据分类新增第 12/13 行与 `R-OUT-4`、§8 新增云端错误语义表、§9 说明「云端推理 ≠ 云同步」、§10 由**预告**改为**对账**、§12 判据按风味重写（1a/1b/2/3/3b/8/9/10）、新增 §13 云端推理通讯规范。<br>`SPEC-C-01`：判据由「全仓零命中」改为**白名单目录制**（更强：不只证明没有网络，还证明网络只落在被设计的位置），新增无障碍与模型名两条判据。<br>`PLAN-00` §6、`00_功能清单` §1/§2.5/§3/§5、`feature_config.schema.json`、`shared/feature_config.json`（新增 `agent` 段）。 |
| 新增文档（5 个功能 + 1 份契约） | `SPEC/PLAN-G-01`（云端连接层与凭据）、`SPEC/PLAN-G-02`（编排与工具契约）、`SPEC/PLAN-G-03`（推荐与外卖检索）、`SPEC/PLAN-U-07`（智能体会话页）、`SPEC/PLAN-C-06`（云端智能的隐私与合规）、`API-07`（智能体与云端接口契约）。 |
| 新增实现 | `app/lib/data/net/`（`agent_transport` / `sse_decoder` / `agent_protocol` / `agent_credentials` / `deepseek_client`）、`app/lib/domain/agent/`（`agent_tool` / `agent_prompt` / `agent_tools` / `agent_service`）、`app/lib/core/flavour.dart`、`U-07` 页面与第 5 个 Tab、Kotlin `AgentChannelHostAndroid`、两个 Android 风味。<br>**零新增 pub 依赖**。 |
| 实测①：SSE 的跨分片 UTF-8（**这是最容易写错的一处**） | `SseDecoder` 缓冲的是**字节**，只在**完整行**上 `utf8.decode`。判据实测：把 `"你好"` 的 UTF-8 三字节在第 1 字节后切开喂进去，两次 `feed` 得到完整一行；**负控**——对同样的前半段直接 `utf8.decode` 抛 `FormatException`。这条不是理论风险：TCP 分片切在汉字中间是常态。 |
| 实测②：工具调用参数是**分片的 JSON 文本** | API 把 `function.arguments` 分三片发出。按 `index` 累加后得到 `{"limit":3}`；**负控**——对单片 `jsonDecode` 抛 `FormatException`。累加完还要**校验一次** JSON，不合法即 `ACD-AGENT-009`，**不得**当作成功结果渲染。 |
| 实测③：重试闸门 | `shouldRetry = isRetryable(code) && attempts < 1 && !receivedDelta`。**关键项是 `receivedDelta`**：已经吐出过 token 之后再重试，等于把第二个答案接到第一个上，且重复计费。**负控**：去掉 `!receivedDelta` 后该判据必须变红。 |
| 实测④：请求体字节上限**拒绝**而不截断 | `buildRequestBody` 超 `max_request_bytes` 直接抛 `ACD-AGENT-003`。上限存在的意义正是挡住「把大对象意外塞进来」，放宽它等于删掉这道闸门。 |
| 实测⑤：`FF-26i` 是**机制**而不是提示词 | 工具注册表是**闭集**：注册第五个工具（`place_order`）在**构造期**即抛 `ACD-AGENT-009`；一个永远不被注册的函数不可能出现在 `tools[]` 里，所以模型**无法调用**它。另有正向证实：模型若仍产出该名字，观察结果是带 `root_cause_hint` / `safe_retry` / `stop_condition` 的 `error`，且**从未到达任何工具实现**。 |
| 实测⑥：交接卡片不会打开任何 App | `propose_takeout_search` 的 `proposalOnly == true`，且它**没有 launcher 依赖**——想打开也打不开。`agent_tests` 用 spy launcher 断言整轮对话后 `launcher.calls == 0`。这是把「有外部可见副作用的动作必须由人按下」与 `FF-24` 第 6 条（检测由用户发起）对齐。 |
| 实测⑦：闸门顺序 | 未同意 → **零请求、零 Key 提示**；已同意但无 Key → **零请求**。**负控**：绕过闸门直接调 transport **确实**会发出请求，所以上面两条断言不是恒真。 |
| 实测⑧：三个平台模板的真实状态（**不是照抄文档**） | `https://i.meituan.com/s/<q>` 从开发机请求返回 **HTTP 200**（响应体是风控 JSON，说明**路由真实存在**，只是拒绝非浏览器 UA）；`https://s.taobao.com/search?q=<q>` 是长期稳定的公开 H5 路由；`https://www.ele.me/search?keyword=<q>` **跨域跳转到 `taobaoshangou.ele.me`** —— 饿了么的 H5 入口已在阿里体系内改道，**很可能不可用**。<br>据此：`feature_config.agent.platform_eleme_enabled = false`，未核实平台的 `verifiedOn` 留空，UI 必须显示「可能打不开」。**三个模板的真机核实仍未做**，这是 §10 的开放项，不得谎称已核实。 |
| 实测⑨：新增的两个静态闸门都能失败 | `check_network_boundary.py --selftest` → 7 个用例全部判别正确（4 必须抓到 / 3 必须放过）；`check_audio_egress.py --selftest` → 5 个用例全部正确。**这两个自测里有一个用例来自我第一版写错的地方**：豁免名单只写了 `feature_config`（蛇形），匹配不上生成的 `FeatureConfig.kt`，于是闸门在**它本该放过的那个文件上红了**——一个对着自己的消毒剂开火的闸门，下一步就是有人给它加例外，再下一步就没有闸门了。 |
| ⚠️ **我在这一轮里犯的三个错，都留下** | ① 对话历史上限**差一条**：`max_history_messages = 24` 指的是**消息总数**，而我第一版的预算只扣了「新用户轮」一格、没扣 system 提示词，于是输出恒为 `上限 + 1`。**单条断言看不出来**，是那条 `trimmed.length <= 6` 抓到的。<br>② 边界检查器**遍历了两遍 android**（先 `rglob("app")` 又 `rglob("app/android")`），一个真实问题被报成两条。**报两条会让人去找那个不存在的第二条。**<br>③ 同上，豁免名单的 `feature_config` 匹配不上 `FeatureConfig.kt`。三条都补了对应的自测用例。 |
| ⚠️ **一处文档级冲突，按「SSOT 优先」解决** | `SPEC-G-03` 把关键词上限**新冻结**为 `G-03-K1 = 32 码点`，而我在 SSOT 里放了 `recommend_keyword_max_chars`。**同一个数字有了两个权威**，正是本项目反复修的那类缺陷。处置：SSOT 取 `32`（文档的理由更充分），并把 `G-03-K1` 的定义改为**引用该 SSOT 键**（`SPEC-00` §5 规则 2「只写一次」）。<br>顺带修掉一个**真实缺陷**：文档要求「按码点截断」是对的——`String.substring` 数的是 **UTF-16 码元**，把 emoji 截半会留下**孤立代理项**，那是一个无法编码的字符串。`capKeyword` 已改为按 `runes` 截断，并补了 emoji 判据。 |
| ⚠️ **一个必须留痕的连带事件：出厂模型卡被重新签发** | 给 SSOT 加 `agent` 段后，`tool/verify_artifacts.py` 立刻红了一条：**`ACD-ART-003: featureConfigSha256` 不匹配**。这是 `API-05` §7.1 的第三条交付闸门**在正常工作**——它记的是「这份模型是针对哪一版 SSOT 验证过的」，SSOT 一动，溯源链就断。<br>**处置**：**不是手改那一个哈希**，而是用项目自己指定的工具重新签发：`python tool/install_model.py --tflite <出厂 .tflite 的临时副本> --version 1.3.0 --parity-label-match 1.0 --parity-max-conf-delta 1.519918441772461e-06`。权重文件**逐字节未动**（sha256 仍是 `31fba3ec…19f4`，1,000,000 字节级的复制校验由工具自己做并在不一致时拒绝写卡），parity 数字**沿用原值而非默认 `null`**（否则那条闸门会因为「没测过」而真空通过）。重新签发后 `verify_artifacts.py` → `RESULT: PASS`。<br>**为什么这件事值得写进 ADR**：手改哈希 = 把溯源闸门变成装饰；跑工具 = 让"这份卡是生成的"这件事继续为真。两者的产物看起来一模一样，区别只在下一个读它的人能不能相信它。 |
| 让 SSOT 的新段落**也被机械守住** | 新增的 `agent` 段不是"写进 JSON 就算"，它的规则全部进了 `ai/tests/run_all.py`（**41 → 72 项**）：默认关闭、`base_url` 必须 https、**模型标识符在全 SSOT 中恰好出现一次**、三个上限都是正整数且有界、平台**恰好三个**且每个平台四个字段齐全、URL 带 `{q}` 占位符且是 https、`verified_on` 只能为空或 ISO 日期。<br>⚠️ **这条闸门第一次跑就红了一条，而且抓的是我自己**：`deepseek-flash` 在 SSOT 里出现了**两次** —— 一次是 `model` 的值，一次是**我在同一段的 `_comment` 里复述它**。修法是把注释改成不复述字面量（「`model` 的值在本文件中**刻意只写一次**，包括不在这句话里重复它」），而不是把判据放宽成「至少一次」。**放宽判据等于承认这个数字有两处可漂移**，而 `FF-26h` 的全部意义就是让它只有一处。 |
| ⚠️ **本轮的七个错里，六个是"闸门/判据本身写错了"**（比代码错更值得记 —— 一个方向写反的判据会同时**放过**真正的违规并**拦住**正确的实现） | ① **我的 `check_network_boundary.py` 不认 XML 注释**（剥了 `//` 与 `/* */`，没剥 `<!-- -->`），于是对着那个**正在用注释解释"为什么不用无障碍服务"**的 manifest 报 `AccessibilityService`。**给扫描器加了 XML 规则**（自测 7 → 11 用例），不是去改那三句注释。<br>② **`SPEC-C-06` §7 #12 把 `startActivity` 写进禁止清单** —— 而它是 `FF-26i` **明文采纳**的交接机制。该判据**在正确实现上变红、在"什么都没做"上变绿**。改成两向：无障碍/手势 API `== 0` **且** `startActivity >= 1`（实测 0 与 1）。<br>③ **`SPEC-C-06` §7 #13 与 #14 是自败判据**（同一类）：#13 要求「`完全合规` 命中 == 0」，而本文件**必须写清这条禁令**；#14 要求「`sk-` 命中 == 0」，而 `C-06/README.md` **必须写出这条判据本身**（实测各命中 2 次与 1 次，全在否定/描述语境里）。**写禁令就会命中。** 两条都改了：#13 只数**肯定式**，#14 改按**凭据形状**（`sk-` 后跟 ≥16 个 base64url 字符）判定 —— 真实泄露仍会被抓，而搜索式不会。**修法是让判据对准它真正想防的东西，不是让文档绕开判据**（否则下一步就是有人给判据加例外，再下一步就没有判据了）。<br>④ **`SPEC-C-06` §7 #8 与 #7 互相矛盾**：前者要求损失写成**四行表格**，后者要求本文件与 `UiStrings` **逐字符相等**，而上线文案是**一段话**。二者不可能同时满足；**#7 承重**（归档的意义是"用户当时看到了什么"），故 #8 改为按**主题覆盖**判定。**为了凑判据格式而改写文案，会比它想修的问题更糟。**<br>⑤ **`SPEC-U-07` §7 #5 的 grep 不可能满足**：它要求 `rg "openSearch\|startActivity\|MethodChannel" app/lib/presentation/` 命中 `== 0`，而按钮处理器**就是** `agent.launcher.openSearch(...)`。**把"调用了这个端口"当成违规，等于把"这个功能存在"当成违规。** 这与 ② 是**同一个错**（把机制当成违规），故两处都改成问**"从哪里调用、调用了几次"**，而不是问"这个词出现过没有"。<br>⑥ **`tool/build_release.ps1` 的旧权限判据本身是坏的**（Android 工作流发现）：`$perms` 只有一个元素时 PowerShell 把它当**字符串**，`$perms[0]` 取到的是**第一个字符** —— 那条闸门**永远不可能放过一个正确的 `offline` 包**。已改 `@(...)` 归一化 + 排序 join。<br>⑦ **`openUrl` 被我的扫描器当成网络 API**，于是它对着**合法的**平台桥（`acoudiet/agent` 的 `openUrl`）报红。**注：这一条最有教育意义** —— 那个工作流的处置是把字面量拆成 `'open' 'Url'` 绕过扫描，并且**如实报告了冲突**（报告得对）。但**修法方向错了**：`HttpClient` 才是网络层的标志，`openUrl` 只是它用到的一个方法名。**一个逼着正确实现去自我混淆的闸门，极性是反的。** 已从清单里删掉 `openUrl`（自测 +1 用例），并把那个桥的字面量改回 `'openUrl'`，两侧都留了注释说明为什么。 |
| ⚠️ **还有一处是**功能**缺陷，不在闸门里，而且在我的层** | **`finish_reason == "length"` 被整个吞掉**：`AgentService.runTurn` 用空 case 匹配 `AgentFinished()`，于是模型**耗尽输出预算**时会产出一个"正常完成"的回合，用户把**半句话**当成完整建议读。UI 侧那个截断状态、逐字冻结的文案、以及针对它的测试**全都在**，但**一个都跑不到** —— 这是本项目记录过多次的同一形状：**存在的状态如果不可达，就不是功能**。<br>修法：把截断做成 `AgentDoneEvent` 上的一个**向后兼容的** `truncated` 标志（而不是新增一个 `sealed` 变体 —— 那会破坏穷尽 `switch`，且截断的回合**确实完成了**，把它建模成失败会让 UI 丢弃一份大体可用的回复）。`agent_page` 读该标志并打上标签；`agent_tests` 新增 **4 条两向判据**（截断**必须**被标记 / 正常结束**不得**被标记 / 截断**不得**被当成错误 / 截断时的部分文本**仍要**送达）。agent 套件 80 → **84** 项。<br>**为什么"两向"是必要的**：单向判据在标志被硬写成 `true` 时**照样通过**。 |
| ⚠️ **第八个错，也是最"隐形"的一个：`offline` 风味分支从未被编译过** | `acouIsOffline` 是**编译期常量**（这是刻意的：只有编译期分支才能让 tree-shaker 把 offline 包里的 agent 页与它的 Tab 一起删掉，这是"按钮被隐藏"与"代码根本不在"的区别）。**代价是 `flutter test` 的默认运行永远不会编译那个分支。**<br>本轮真的去编译了一次：`flutter test --dart-define=ACOUDIET_FLAVOUR=offline` → **3 个测试失败** —— `app_shell_layout_test.dart` 的两条（无条件断言「5 个 Tab / 记录 在 index 3」）与 `refresh_and_tab_test.dart` 的一条（无条件点 `Icons.smart_toy_outlined`）。**它们不是产品缺陷，是测试不知道有第二种构建**。<br>**已修**：三条都改为按风味取值，且 **offline 分支的断言是反向的、有意义的**（「这个 Tab 与它的图标**必须不存在**」、「记录 仍在 index 2」）。修完**两种风味各 181 项全过**。<br>**已让它持久**：`verify_all.ps1` 的那一步现在**跑两遍**（默认 + `--dart-define=ACOUDIET_FLAVOUR=offline`），CI 也加了一步。**步数仍是 22 —— 不是因为少做了一件事，而是因为"同一个套件、两种构建"本来就是一件事。**<br>**这条为什么重要**：它是 `ADR-33`/`ADR-35` 那个主题的第三个变体 —— 前两个是「检查存在但从没执行」，这个是「**分支存在但从没编译**」。一个从没被编译的分支，和一段从没被阅读的代码一样，不能算作已交付。 |
| ⚠️ **两个必须留痕的环境陷阱** | ① **`tool/build_release.ps1` 依赖 UTF-8 BOM，而本仓的文件编辑工具每次写入都会把 BOM 剥掉**（实测）。这里的 `pwsh` 是 Windows PowerShell 5.1，BOM 缺失时按代码页 936 解码 → **整个脚本变成解析错误**（实测：剥掉后 1 个 parse error，恢复后 0 个）。Android 工作流最后一步把 `EF BB BF` 写回并验证过 `Parser::ParseFile` 无错。**任何后续对这个文件的编辑都必须重新补 BOM。**<br>② **Gradle 层做不出"默认风味"**：维度的风味多于一个时 AGP 没有默认风味机制，Flutter 工具也要求显式 `--flavor`。所以「`agent` 是默认」这句话**只在工具层成立**（`build_release.ps1 -Flavour agent` 是默认值），而 `agent` 保留 `com.acoudiet.app`、`offline` 才是带后缀的那一个。这是一处**文档措辞必须跟着现实收窄**的地方，已记入 `SPEC-C-06` §10。 |
| ✅ **两个风味的 release APK 真的构建出来了 —— 而且"本机不能构建"这条记载是错的** | `tool/build_release.ps1` 的头部写着「**必须在普通终端运行**（不在 DSH 沙箱内）：沙箱会挡住 `flutter` 与 Gradle 用的管道 stdio」。**这条已经过期。** 实测：`cmd.exe /c ver` 正常、`flutter --version` 正常、Gradle `assembleAgentRelease` / `assembleOfflineRelease` 各 ~60–80 s 正常完成。<br>**产物**（`AcouDiet/docs/release/`，arm64-v8a / armeabi-v7a / x86_64 三个 ABI × 两个风味 = **6 个**）：<br>· `AcouDiet-v1.3.0-20260915-<abi>-agent.apk`（arm64: 27,856,234 B，sha256 `d715ebff…`）<br>· `AcouDiet-v1.3.0-20260915-<abi>-offline.apk`（arm64: 27,069,194 B，sha256 `e9d6dfe3…`）<br>外加 `apk_sha256.txt` 与 `RELEASE_1.3.0_20260915.md`。版本 `1.2.2+5` → **`1.3.0+6`**（权限集合变了，按本仓自己的规矩必须换 versionCode）。<br>**这句话本身就是教训**：一条**从没有人重新测过**的限制，会以「不可能做到」的样子把**完全做得到**的验证挡在门外。这是本项目第三次遇到同一形状（前两次是 `ADR-33` 的 `verify_all.ps1` 不可解析、`ADR-35` 的 `flutter test` 从没跑过）。 |
| ✅ **第一次真正执行的四道闸门（此前全都"存在但从未运行"）** | ① **Gradle `manifestTask.doLast` 的双风味权限审计** —— 两个方向都跑通：`agent` = `permissions=INTERNET,RECORD_AUDIO internet=True OK`；`offline` = `permissions=RECORD_AUDIO internet=False OK`；三个 ABI 各一次。<br>② `check_apk_contents.py` 的**新 flag**：`offline --expect-no-internet` → 0；`agent --expect-internet` → 0（走 `utf16le=True` 路径）。<br>③ `check_page_alignment.py` 对**新构建的** APK：`libapp.so` p_align=65536、`libtensorflowlite_jni.so` p_align=16384、偏移全部对齐 → **16 KB COMPATIBLE**。<br>④ `ui_fingerprint_check.py` 对**新构建的** APK：9 条 must-be-present 全中、3 条 must-be-absent 全无 → **CURRENT UI**。<br>另外 `apksigner verify` 三个 ABI 全部 `signature=OK`（**测试密钥，不得对外分发**）。 |
| ⚠️ **构建一跑，立刻抓到四个错 —— 其中三个是"闸门/脚本指向了错误的输入"** | ① **合并 manifest 的定位在 `--split-per-abi` 下失效**：闸门只往输出目录下探**一层**，而分 ABI 构建把 manifest 放在 **两层**（`merged_manifests/<variant>/<task>/<abi>/AndroidManifest.xml`）。它**正确地 fail-closed**（所以是一次构建失败，不是一份没被审计的 release 包），但也意味着**在修好之前根本出不了包**。<br>② **`build_release.ps1` 的 APK glob 匹配了所有风味**（`app-*-release.apk`）：`flutter-apk/` 目录在两次构建之间**不清空**，于是构建 `offline` 时审计了上一次留下的 `agent` 包，并正确地报出「offline 不得申请 INTERNET，但 arm64-v8a-**agent** 申请了」——**把失败指向了错误的文件**。规则对、输入错，这比规则错更危险，因为报错信息看起来像你在构建的那个东西真的违规了。<br>③ **`apk_sha256.txt` 没有风味列且会重复追加**：实测构建 `agent` 两次 + `offline` 一次后是 **9 行、无风味列、3 行重复**。一份无法归属的证据不是证据。已改为以**归档文件名**为键（自带版本/日期/ABI/风味）且**按文件名幂等覆盖**。<br>④ **BOM 陷阱真的发生了**：我用编辑工具改 `build_release.ps1` 之后，**UTF-8 BOM 被剥掉**，PS 5.1 按 GBK 解码中文，脚本在**第 313 行变成解析错误**（`Unexpected token`）。这正是该文件头部警告过的事，也是 Android 工作流当时警告过的事——**而它还是发生了**（`docs/01` 的 ADR-44 里记着"两个必须留痕的环境陷阱"，其中第一条就是这个）。<br>**新增两道机械闸门**：`tool/check_ps1_encoding.py`（非 ASCII 的 `.ps1` 必须有 BOM；5 个用例自测）；`build_release.ps1` 新增 **[6/6] 16 KB 页对齐**，对**本次产出的每一个归档包**逐 ABI 检查。 |
| 诚实边界 | ① **没有真机实测**：本机无 adb 设备、无 AVD，所以「点卡片能跳到美团」「TLS 在真机上通不通」「第 5 个 Tab 的真机观感」「两个风味的权限集合在真实合并后的 manifest 里对不对」**全部未验证** —— 后一条**现已解除**：两个风味的 release APK 都构建出来了，Gradle 的 `manifestTask.doLast` 闸门与 `aapt dump badging` **都执行过并通过**（见上面两行）。**仍未验证的是"装到手机上会怎样"**，那是设备侧的事，本机没有设备。② **没有对真服务发过一次请求**：全部判据都在**离线**（假 transport / 纯函数）上跑；`DeepSeekClient` 的 socket 路径**只被阅读和类型检查过，从未执行**。这是本轮最大的未验证面。③ 三个平台 URL 模板的真机核实未做（见实测⑧）。**同理，`FF-26i` 的交接也只在"代码层面"验证过：`openSearch` 只在按钮里被调用（已断言），但"点了之后美团真的会打开"**没有在设备上试过**。④ **`SPEC-C-06` §7 #3/#5/#15 现已产出**（两套 `aapt` 证据、两个 `sha256` 文件、六个归档 APK），见 `AcouDiet/docs/compliance/C-06/`；**只有 §7 #10（同意门截图）仍然无法产出** —— 那需要真机或模拟器，本机两者都没有。**这是本轮唯一真正缺失的证据。**⑤ `FF-24` 第 8 条的**运行时**那一层（`assertEgressSafe`）是在构造点断言，**不是**网络层拦截——真正的保证来自类型设计与单点构造，静态扫描是三层里**最弱**的一层，这一点已写进 `check_audio_egress.py` 的 docstring，不粉饰。⑥ 没有做成本估算：每次对话的真实 token 花费【待实测】。<br>⑦ **`flutter analyze` 全仓不是 0 issue**：`dart analyze lib test` 是 **0 error / 27 warning / 61 info**，而 `flutter analyze` 另报 **1 个 error，位于 `app/tool/shims/flutter_test/lib/flutter_test.dart`**（`package:test/test.dart` 无法解析）。该文件**在本轮未被修改**（`git status` 为空），且 `HEAD` 版本就写着同一行 —— 它是离线 shim 的固有状态（shim 有自己的 `pubspec.yaml`，只有 `run_offline_tests.py` 生成的 package config 才解析得了它）。**27 个 warning 也全部是既有的**（`sqlite_ffi` / `ffi_util` / `tflite_inference_engine` / `detect_page` / `home_page` 等文件的 `unused_import` 与 `unused_field`），已抽查两处最可疑的（`app_services.dart` 的 `demo.dart`、`app_shell_layout_test.dart` 的 `notifiers.dart`）确认**在 `HEAD` 上就已经 import 了**。本项目的门是「0 error」，本条仅作留痕，**不把既有噪声说成本轮引入的**。<br>⑧ **文档索引与合规清单的同步已完成**（`docs/README.md`、三份部分 README、`PLAN-01`、`C-01`/`C-05` 合规清单、发布前清单、`AcouDiet/README.md`、`app/assets/models/README.md`）；`verify_docs.py` → **BLOCKER × 0 / PASS**，45 = 45 SPEC + 45 PLAN。剩 3 条 WARN 均为「提到 INTERNET 但看不出是否禁止」的提示，落在 `SPEC-G-03` / `SPEC-C-01` / `gemma_attribution_and_license.md` 三份**描述风味或历史**的文档上，属该启发式的已知噪声。 |
| 回归实测（**全绿，且逐项有据**） | `tool/verify_all.ps1` → **`ALL SUITES PASSED (22 steps)`**（原 20 步 + `G-01..G-03 agent 离线套件` + `ADR-44 云端出口边界`）。<br>`dart app/tool/agent_tests.dart` → **all 84 checks passed**；`--without-negative-controls` → **恰好那 6 条负控变红**（这就是"闸门能失败"的证明）。<br>`flutter test` → **181 passed, 0 failed**。`dart app/tool/ui_presenter_tests.dart` → **455 passed**（原 413，+42；字符串采集 **253** 条，FF-25 / 无 2 秒 / 裁剪项 / 裸 kcal 全部通过）。PURE **207** / SESSION **127** / L3 数据层 / Kotlin JVM 套件 / T-08b 跨语言 Mel 对齐 全部 exit 0。<br>`ai/tests/run_all.py` → **41 → 72 项全过**（新增的 SSOT 段落不变量）。`verify_artifacts.py` → PASS。`dart analyze lib test` → **0 error**。<br>新增闸门：`check_network_boundary.py --strict` clean / `--selftest` **11 用例**全判别正确；`check_audio_egress.py --strict` clean / `--selftest` **5 用例**；`selftest_check_apk_contents.py` **10 用例**；`check_android_xml.py` 8 份 XML 全部 well-formed；`check_page_alignment.py` **16 KB COMPATIBLE**；`check_split_leakage` / `check_consent_registry` / `check_l4_usage --strict` / `check_bridge_symmetry --strict` / `check_kotlin_usage --strict` / `check_async_state_writes` 全部 exit 0。<br>零新增 pub 依赖（`pubspec.yaml` 的 `dependencies:` 仍为 `flutter` / `path` / `uuid`）。 |
| ✅ **新闸门接进了 CI**（此前没人拥有的一块） | 新加的三道闸门**原来只在本机 `verify_all.ps1` 里**，从没进过 CI —— 正是本项目反复记录的失效形状（「检查存在但从不执行」，见 `ADR-33`/`ADR-35`）。`.github/workflows/verify.yml` 已补：<br>① `flutter-tests` 作业加 `dart tool/agent_tests.dart`，**外加一步「负控是承重的」** —— 用 `--without-negative-controls` 跑并要求它**必须失败**。没有这步，删掉任何一条负控都会让上一步保持绿色。<br>② `portable-checks` 作业加两个 egress 闸门的 `--strict`，并把它俩的 `--selftest` 并入自测步骤。<br>③ 工作流头部的「诚实边界」补了一条：**Gradle 那道双风味权限闸门同样不在 CI 里跑**（它只在真实 `flutter build` 内执行）—— 而在这台机器上**它从未被执行过一次**。<br>⚠️ 顺带被自己的验证抓到一个错：步骤名里写了 `(ADR-44: cloud …)`，**未加引号的 `: ` 让 YAML 把它解析成映射**（`ScannerError line 81 col 42`）。改成带引号的标量后 `yaml.safe_load` 通过。 |

### ADR-45 ✅ 按用户反馈改造 Agent 的两处：(A) **请求包装层** —— 让云端 AI 真的做饮食评估，而不是以拒绝开场；(B) 外卖交接升级为**直接唤起 App** + **App 内看带真实图片的选项**

| 项 | 内容 |
|---|---|
| 来源 | 用户两点反馈：「云端 AI 显示不做健康评估，**但是这个不是啊**！你写软件让**每次发给云端 AI 的请求都包装好合适的说辞**」；「我希望的是**直接打开手机 APP** 或者**显示带有图片的外卖选项**」。 |
| **A 的根因：一条合规语句被当成了岗位说明书** | 原系统提示词的第 1 条就是「不做疾病诊断、不给治疗建议、不替代专业医疗意见」。用户说得对：这个 App 的云端 AI **本来就是来做饮食健康评估的**，而我让提示词以「不要做」开场。**岗位说明书决定模型的行为**，于是它学会的是含糊其辞而不是评估。 |
| **A 的修法：把「拒绝开场」换成「任务简报」** | `systemText` 重写为四段：**【你要做的】**（评估结构/规律性/零食/速度并给明确结论；指出哪类偏多偏少并给可执行替换；数据不足时说清还缺什么）+ **【边界（是评估范围，不是拒绝工作的理由）】**。边界七条**一条没删**（不诊断疾病、不编数、估算标注、不承诺疗效、不代下单、只用注册工具、简体中文），但它们现在读起来是**怎么负责任地评估**。回答上限 120 → 160 字，好让「结论 + 建议」放得下。 |
| **A 的第二半：每一次请求都被包装** | `AgentPromptBuilder.renderBrief()` 把用户那句话包进结构化简报：`【本轮任务】` → `【本地数据（唯一可引用的事实）】` → `【回答格式】`；无数据时显式写 `（本轮没有本地数据…）`。三个理由，按重要性：① 让模型把这轮当成**评估请求**而不是闲聊；② **数据围栏** —— 用户的话在数据段**之前**，App 的聚合在段**之后**，所以用户文字里写的 `totalScore=999` 不可能冒充 App 给的事实（`SPEC-C-06` 的注入顾虑）；③ 回答格式稳定到可以断言。 |
| **B-1：直接唤起 App（scheme 优先、https 回落）** | 此前只把 `https://i.meituan.com/s/<q>` 交给系统，让 App Links 决定 —— 手机上没配链接就落到浏览器。现在 SSOT 给三个平台各加一条 **scheme 模板**（`platform_<id>_scheme`）：`imeituan://www.meituan.com/search?keyword={q}` / `eleme://search?keyword={q}` / `taobao://s.taobao.com/search?q={q}`。启动顺序：`canOpenUrl(scheme)` → `openUrl(scheme)` → 失败则 `openUrl(https)`。<br>**scheme 是"尝试"，不是"答案"**：模板未在任何真机核实过，且没装该 App 的设备根本没有 handler（Kotlin 侧把 `ActivityNotFoundException` 转成 `false`，不崩）。**丢掉交接是不可接受的结局，多花几毫秒不是。** 4 条测试钉住这个顺序，含「scheme 答是但 open 失败仍要回落」与「没有 scheme 的平台的调用表恰好是 1 次 `openUrl`」这两个对照。 |
| **B-2：App 内看带真实图片的选项** | 用户的另一条要求。**图片只能来自三个地方，只有一个合法**：① 平台 API —— **不存在**（`FF-26i` 已记录同一结论：三家开放平台要 ISV/商家资质）；② 自带图片 —— 每一道菜都要买授权，而且它仍是一份**过期且随意**的清单；③ **平台自己的结果页** —— 真菜、真图、实时价，没有数据授权问题，因为渲染的是**它的页面、给我们的用户看**。**采用 ③**：新增 `TakeoutBrowserPage`（`webview_flutter` 的 `WebViewWidget`），加载该平台的**网页搜索 URL**，标题写平台名，页内一句话写明「下面的内容来自该平台自己的网页，图片与价格由平台提供；最终在平台内下单」。 |
| ⚠️ **新增了一个 pub 依赖，并且如实记下代价** | `ADR-44` 曾把「**零新增 pub 依赖**」当成一条功劳。这一条要求把网页渲染在 App 里，而 Flutter **没有内置 WebView**，没有不引依赖的做法。故引入 `webview_flutter: ^4.10.0`（解析成功：`webview_flutter_android 4.3.2` 等）。<br>**实测代价**：arm64-v8a APK 从 27,069,194/27,856,234 B 涨到 **27,171,584/28,220,768 B**（offline **+102 KB**、agent **+364 KB**）。**`offline` 也涨了**，因为 pubspec 是风味无关的、插件注册表也是 —— 被 tree-shake 掉的是 Dart 代码，不是插件登记项。<br>**实测不受影响的**：`offline` 的权限集合**仍然是 `{RECORD_AUDIO}` 一项**（Gradle 双向闸门 + `aapt dump badging` 双重确认，见下），且 `offline` APK 的 `lib/` 里**只有三个原生库**（`libapp` / `libflutter` / `libtensorflowlite_jni`）—— `webview_flutter_android` 用的是**系统 WebView**，不带自己的 `.so`。**"能不能装下"和"权限有没有多"是两个问题，这里只有前者变了。** |
| 实测（两个风味重新构建） | `agent` 与 `offline` 各 3 个 ABI，**全部 exit 0**；Gradle 权限审计两向通过（`internet=True OK` / `internet=False OK`）；**[6/6] 16 KB 页对齐**六个包全部 `COMPATIBLE`。<br>`aapt dump badging` 独立复核：`offline` = `com.acoudiet.app.offline` / `1.3.0-offline` / **`RECORD_AUDIO` 仅此一项**；`agent` = `com.acoudiet.app` / `1.3.0` / `RECORD_AUDIO` + `INTERNET`。<br>新的 `apk_sha256.txt` 是**6 行、按归档文件名幂等**（`ADR-44` 修的那个缺陷没有复发）。<br>`flutter test` **两种风味各 187 项全过**（原 181，+6 条 launcher 顺序测试）；`agent_tests` **84 → 117**（+20 条包装层、+13 条 scheme）；`ui_presenter_tests` **455 → 459**。 |
| ⚠️ **新判据当场抓到一个陈旧夹具** | 我加的「presenter 必须把网页 URL 传到交接视图」这条断言**第一次跑就红了**：`ui_presenter_tests.dart` 里那个手写的 observation 夹具**只写了 `platformId/label/keyword/verified`，漏了 `url`** —— 也就是说**夹具早就和工具的真实输出不一致了**，只是此前没有任何断言看过那个字段。已改为**从同一个 `takeoutUrlFor()` 推导**（不再手写 URL），把这一类漂移从源头去掉。这正是"手写夹具会静默漂移"的活例子。 |
| 诚实边界 | ① **三个 scheme 模板一条都没在真机上验证过**。它们的正确性**完全未知**；能保证的只是"试过之后会回落"，不是"能打开"。② **App 内的平台页面没有在真机上打开过**：开发机实测 `i.meituan.com` 对非浏览器客户端返回**风控 JSON**；WebView 带真实移动 UA 是否会被放行、登录墙与验证码会不会出现，**全部未验证**。③ `webview_flutter` 是**新增的第三方依赖**，它带来自己的原生代码与生命周期；`flutter analyze` 干净、两个风味的 187 项测试全过，但**没有在真机上跑过**。④ 平台页面可能需要在平台 App 内登录才能看全，而 WebView 里没有平台账号 —— 这一条**很可能限制实际可用性**，未实测。⑤ A 那一半（提示词包装）**从未对真服务发过请求**：全部判据是离线文本与结构断言，**"云端 AI 现在真的会做评估了吗"这个问题本机无法回答** —— 它需要在设备上跑一次真实对话才能证明。⑥ 平台集合、`FF-26i`（不代下单）、音频不出境三条**均未改动**。 |

### ADR-46 ✅ 用户实测反馈的四条缺陷：主页重复入口、检测页按钮无作用、**"只能检测一次"复发**、记录页日期重复且字号不一

| 项 | 内容 |
|---|---|
| 来源 | 用户实测反馈：「主页的那个 AI 检测的相关按键删除，只保留检测页面的入口」；「检测页面的各处按钮和操作存在**多处无作用** BUG」；「**又出现了只能检测一次**的情况」；「饮食记录这里出现了**日期重复体现、大小不一字体**的 BUG」。 |
| 🔴 **最要紧的一条：「只能检测一次」的真根因是 `open()` 泄漏了通道订阅**（**这就是"复发"的原因 —— 它从来没被真正修掉**） | `DetectionSessionHandle.open()` 在 `session.start()` **之前**就建立了两个订阅：<br>`final stateSub = session.states.listen(onState);`<br>`final levelSub = services.bridge.events(sessionId: id).listen(...);`<br>而它**没有任何 try/catch**。`session.start()` 里也**没有 catch**（`DetectionSession.start` 只对自己抛的 `AcouDietError` 负责），所以**任何非 `AcouDietError`** 都会直接穿出去，而两个订阅就**永久留了下来**。<br>**为什么这是终局的**：`bridge.events()` 给的是 EventChannel 的**广播流**，原生侧只有**一个 sink**，且**只在通道报告 `cancel` 时才重新武装**（`AudioChannelHostAndroid.onCancel` → `AudioBridgeAndroid.clearSubscription`）。一个活着的订阅让监听数**永远回不到 0** → 原生**永远收不到 `onCancel`** → sink 永远不再武装 → 之后每个会话的事件都被 `subscribedSessionId` 过滤掉。**麦克风照开（隐私指示灯亮，因为 `startSession` 本身成功了），界面永远空着。**<br>**为什么会"复发"**：当年修这个缺陷时，保障被加在 **`stop()`** 上（"两个 tap 都必须被取消，通道才会报告 cancel"），而**`open()` 从来没有拿到同样的保障** —— 偏偏 `open()` 才是**"第一次尝试失败"**时走的那条路。于是一次偶发失败就毒死了 App 余下的全部生命周期，且**每次重试再泄漏一个订阅**。<br>**修法**：`open()` 里包 `try/catch`，失败时**先释放两个订阅、再 dispose 会话，然后 rethrow**。失败从"终局"变成"可重试"。 |
| 🔴 第二条：**页面会被闩死在 `starting`，之后所有按钮全部变哑** | `startRealtime()` / `startSample()` 只写了 `on AcouDietError catch`。而 `_busy` 的定义**包含** `DetectUiState.starting`，两个启动路径的第一行都是 `if (blocked || _busy) return;`。所以**任何非 `AcouDietError`**（宿主不是 Android 时的 `MissingPluginException`、畸形回复导致的类型错误……）会把 `_uiState` **永久钉在 `starting`**：第一次尝试因无关原因失败，此后**主按钮彻底无作用、不报错、无可重试**。这正是用户说的"多处按钮无作用"——它们全都汇进一个再也改不了状态的 notifier。<br>**修法**：加 `catch (e)` 映射成可读错误，**并在 `finally` 里无条件逃逸**（若仍是 `starting` 则落到 `error`）。只多捕获类型而不重置状态，只是换一种异常被吞掉。 |
| 🔴 第三条：**"是/否"两个按钮在无会话时静默无效，还把状态改成"正在聆听"** | `answerConfirmation` / `rejectSuggestion` / `acceptCurrentAsRecord` 都是 `void`，且写成 `_handle?.session.xxx()` **后面紧跟 `_setState(listening)`**。会话结束后卡片可能仍在屏上（`stop()` 不清预测视图），此时点按钮：**什么也没发生，同时页面被告知它在聆听** —— 一对最坏的组合。<br>**修法（两半）**：① 三个方法在 `_handle == null` 时**上报** `ACD-SESS-001`「检测会话已结束」并落到 `error`，**不再谎报 `listening`**；② 页面的是/否按钮**按 `notifier.sessionRunning` 禁用**——没有会话可答时，禁用才是诚实的渲染。 |
| ✅ 第四条：记录页的日期**确实是重复的**，且两半字号不同 | 代码就是证据：`dayGroupHeader` 对"今天/昨天"返回相对词、**其余返回 `M月d日`**；`dayDateLabel` **永远返回 `M月d日`**。所以**任何早于昨天的日期都会被打印两遍**，而渲染把它们放在两个不同样式的 `Text` 里（`metric.copyWith(fontSize: 16)` vs `bodyMuted`）→ 用户看到的"日期重复 + 大小不一"。<br>**修法**：把规则提成**纯函数** `AcouFormat.dayHeaderLabel(header, dateLabel)`：两半相同就只留一份，不同才用 ` · ` 连接成**一个排版单元、一种样式**。**没有删掉任何信息** —— `ADR-24` 当初加日历日期，正是因为列表滚动后只剩相对词会丢失日期。提到 `AcouFormat` 的另一个好处是**它变成纯函数，离线套件终于能断言它**（这个 bug 原本长在一个 widget 里，任何测试都够不着）。 |
| ✅ 第一条：主页那个重复的检测入口已删除 | 主页当时有**两个**开始检测的入口：`StartDetectButton`（示意图里那个圆形麦克风徽章 + 薄荷色长条按钮）**和**底栏的「检测」Tab。按用户要求删掉前者，**底栏「检测」成为唯一入口**。`UiStrings.startDetect` **保留**——检测页自己的主按钮仍在用它（`detect_presenter.dart`）。 |
| 新增闸门（都带负控） | `test/ui/detect_session_recovery_test.dart`（3 项）：① **负控**——先证明"一个活着的订阅通过广播流的 `hasListener` 确实可见"，否则后面所有断言都是空话；② 启动抛错后 `bus.hasListener == false` **且第二次启动真的成功**；③ 无会话时点是/否**会上报且不谎报 `listening`**。<br>`ui_presenter_tests.dart` 增 6 项：证明"早于昨天的日期两半确实是同一个字符串"（重复在数据里）、折叠后只出现一次、今天保留两半、空串不动，外加一条**负控**（未折叠时确实会重复）。 |
| ⚠️ **`open()` 的负控是实测红的** | 我把 `await levelSub.cancel();` 临时换成注释跑了一次：<br>`a start that THROWS releases its subscriptions and stays retryable [E]` → `Expected: false / Actual: <true>` → 失败原因是 **"a subscription left alive here is what makes the NEXT session permanently deaf"**。恢复后 3/3 全过。**这条断言不是装饰。** |
| 回归实测 | `dart analyze lib test` → **0 error**（27 warning 全部既有）；PURE **207** / SESSION **127** / UI **459 → 465** / AGENT **117**；`flutter test` 两种风味 + `verify_all.ps1` 结果见下。 |
| 诚实边界 | ① **没有真机复现**：四条都是我**读代码 + 渲染截图**定位的。前三条都有**代码级的必然性**（缺 catch、`?.` 静默 no-op、两半日期同值），但**"就是它导致了用户那台手机上的症状"这一句我无法证明** —— 需要在设备上跑一次复现。② 主页按钮删除后**没有再看一次渲染图**确认版式（`AppShell` 的截图会重新生成，但本轮未重跑视觉捕获）。③ 记录页修复**只对日期头生效**，如果用户看到的"大小不一"是在别处（例如卡片内的时间戳），那还没修 —— 已按现有代码能解释的部分修掉。 |

---

### ADR-47 ✅ 让「是 / 否」真正有用：**同级静默窗口 FF-20d** —— 用户答过的类别，同一次检测的三分钟内不再出现该判断结果

| 项 | 内容 |
|---|---|
| 来源 | 用户实测反馈：「我希望检测过程中**是否的按钮有用**，如果客户点了否则应该**在同一次检测中的三分钟内不再出现该判断结果**」。 |
| 🔴 **这不是新功能，是一条 2026-09-10 就写进文档、却从来没有人实现的要求** | `SPEC-P-06` §2.4 原文：「`shouldAskUser` 反复置真；由 `U-02` 去重呈现（**同一 `classId` 只问一次**），聚合器不负责去重」；`SPEC-U-02` §2.3 状态表原文：「「否」不写日志且**同类别不再重复追问**」。**两处都写了"只问一次"，两处都没有对应实现**：聚合器每个 patch 都会重新进入 `lowConfidence`，而会话层没有记住用户已经答复过这个类别。<br>**用户看到的现象因此是必然的**：点「否」→ `_dismissedConfirmation = true` 把问题关掉 → **下一个 patch（≤0.5 s，FF-12 是 2 Hz）**`_onPatch` 立刻把 `_dismissedConfirmation` 清回 `false`，同一类别同一句话又问一遍。按钮"点了没反应"的真实含义是**点了没用**。 |
| 裁定 1 · **窗口放在会话状态机，不放在聚合器** | `SPEC-P-06` §3 的冻结接口（`VoteStage` / `AggregatedDecision` / `VoteAggregator` / `VotingConfig`）**一个字节都没改**：`VoteStage` 不新增 `rejected` 值（验收 #3 明确禁止），`AggregatedDecision` 不新增字段。静默是 `DetectionSession` 的**会话内状态**（`Map<int, _ClassMute>`），它才是拥有 §2.3「是 / 否」迁移的组件，`SPEC-P-06` §2.4「聚合器不负责去重」因此仍然成立。 |
| 裁定 2 · **窗口 = 180 s，取自 SSOT，不是字面量** | 新增 `shared/feature_config.json` 的 `voting.confirmation_mute_seconds = 180`（schema `required` + `properties` 同步），由生成器投影为 `FeatureConfig.votingConfirmationMuteSeconds` / `VOTING_CONFIRMATION_MUTE_SECONDS`。`DetectionSession.muteWindowMs` 由它推导，代码里没有 `180`。窗口**按 `classId` 记账、按会话计时**：`start()` 清空，不落盘、不入库、不参与 15 字段握手。 |
| 裁定 3 · **两种答复不对称，而且这正是用户要的** | 选「是」→ 该类别在窗口内上报为 `confirmed` 且 `shouldAskUser = false`（用户自己的答复就是结果，记录已写，`_confirmedLabels` 保证每类每会话一条）。<br>选「否」→ 该类别在窗口内**没有任何可主张的结果**：上报 `observing` + `classId = null` + `label = null`，并且**自动落库也被挡住**（窗口内即使聚合器给 `confirmed` 也上报 `observing`）。<br>**为什么必须挡落库**：用户刚说"不是软糖"，一秒后 App 自动把"软糖"写进饮食记录，等于把那个「否」撤销掉了 —— 按钮又一次变成没用。`observing` + `classId = null` **不是新状态**：`SPEC-P-06` §2.3 判定表里 `observing` 那一行本来就写着「最近 Top-1（**可 `null`**）」，所以既没有新增枚举值，也没有违反 §4 的字段一致性（那条约束是给聚合器输出定的，验收 #9 的测试文件是 `vote_aggregator_decision_test.dart`）。 |
| 裁定 4 · **答复同步生效，"按钮消失"不再等下一个 patch** | 原来 `DetectNotifier.answerConfirmation/rejectSuggestion` 走完就 `_setState(DetectUiState.listening)`，**`_prediction` 不动** —— 于是点完按钮，按钮还会在屏上留到下一个 patch（最多 0.5 s），**这段时间内的第二次点击会撞上 `_requirePendingConfirmation` 抛出 `ACD-SESS-002`，把页面打进错误态**。这是"按钮无作用"家族里我这次才看清的一支。<br>修法：`answerConfirmation()` 与 `rejectSuggestion()` 现在都在会话层**同步**把 `_decision` 改成裁定后的值（§2.3 的 `lowConfidence → confirmed` / `→ observing`），notifier 抽出 `_applyDecision(state)` 由 patch 流与点击**共用同一条投影**（`_onSessionState` 与 `_refreshFromSession` 都调它），所以点下去的那一帧卡片就变、按钮就消失。 |
| 新增闸门（都带负控） | ① `app/test/domain/confirmation_mute_test.dart`（8 项，`flutter test`）：FF-20d 取自 SSOT = 180；「否」后同一次检测内 1/10/30000/120000/179999 ms 均不再提问；**恰好 180000 ms 恢复**；新会话不继承；另一 `classId` 不受影响；「否」后 `confirmed` 也不落库；「是」同步生效且只落一条；**负控**——未作答的对照组（同一解码器、同一脚本）仍在提问。<br>② `tool/session_tests.dart` 新增 `P-06 / FF-20d confirmation mute window` 组（19 项，离线套件）：同一批断言的离线等价物 + 对照组。 |
| ⚠️ **负控是实测红的** | 把 `_onPatch` 里的 `final decision = _applyMute(raw);` 临时改成 `final decision = raw;` 跑了一次：`SESSION: 138 passed, 8 failed`，其中包含两条 `negative control` 里的 **"the ANSWERED session on the same input stops asking" → `Expected: false / Actual: true`**，以及「否」不再提问、「否」不落库、「是」同步生效等 6 条。恢复后 **147/147 全过**。 |
| 文档同步 | `SPEC-00` §3.4 新增 **FF-20d**；`SPEC-P-06` §2.2 步骤 11（新）、§2.3 迁移行（`lowConfidence → observing` / `confirmed → observing`）、§2.4 抖动行、§5 参数、§7 新增判据 #15–#19、§3 明确"窗口不在冻结接口里"；`PLAN-P-06` 交付物 20/21、WBS 11、§3 要点 8、§4 测试行、§5 DoD、§6 风险 2 条；`SPEC-U-02` §2.2 步骤 9（新）、§2.3 状态表、§2.4 边界 2 条、§5 参数、§7 判据 #12/#13；`feature_config.schema.json` 的 `voting`。 |
| 诚实边界 | ① **仍然没有真机复现**：三分钟的窗口是用**注入时钟**在测试里踩边界验证的，不是在一个手机上等了三分钟。② **"点否之后卡片变成中性态"没有截图证据** —— 这是 `DetectPresenter.predictionOf` 在 `classId == null` 时返回 `sensing` 的代码级推论，我没跑视觉捕获。③ 窗口 180 s 是**用户口述的三分钟**，不是我标定的最优值；如果现场觉得太长/太短，改 SSOT 一个数字即可，测试会跟着走（判据 #19 就是为此写的）。 |

---

### ADR-48 ✅ 第二轮两风味发布暴露的两个**发布会**缺陷：归档索引互相覆盖（v1.3.0 的 agent 记录已经因此丢失），以及版本号没有跟着内容走

| 项 | 内容 |
|---|---|
| 来源 | `ADR-47` 改完必须重新出包才能给用户装。构建 v1.3.1 的两个风味时，第二次运行**把第一次写好的归档索引覆盖掉了** —— 这不是新缺陷，是 `ADR-44` 那次两风味发布就发生过、只是没人发现的事。 |
| 🔴 缺陷 1 · **`RELEASE_<版本>_<日期>.md` 里没有风味，两个风味写同一个文件** | `build_release.ps1` 的归档索引用 `RELEASE_${Version}_$Stamp.md` 命名，而**文件内容本身是有 `flavour` 行的**（`apkPath` / `apkSha256` / `apkBytes` / `permissions` 全都只描述当次构建的那一个风味）。于是 `-Flavour agent` 跑完写一份，`-Flavour offline` 跑完**覆盖**它 —— **一次"两风味发布"在归档上只留下一半的证据，而留下的那一半看起来像完整发布。**<br>**已经造成的损失**：`RELEASE_1.3.0_20260915.md` 里只有 offline 的三个哈希与权限集合，**v1.3.0 的 agent 归档索引永久缺失**；只有 `apk_sha256.txt`（`ADR-44` 已经改成按文件名记账，所以它是逐文件的）还留着 agent 的哈希。这是"证据只写一半却长得像全部"的典型。<br>**修法**：文件名带上风味 —— `RELEASE_${Version}_${Stamp}_$Flavour.md`；历史那份 `RELEASE_1.3.0_20260915.md` **改名**为 `RELEASE_1.3.0_20260915_offline.md`（让它的范围在文件名上就诚实，而不是假装覆盖了两个风味），并保留原内容不改写。同步件：`SPEC-C-04` §4、`PLAN-C-04` 交付物 6、`pre_release_checklist_TEMPLATE.md` 第 8 项。 |
| ✅ 缺陷 2 · **版本号停在 `1.3.0+6`，改动却没进版本号** | 这一轮改了检测会话的行为（`ADR-46`/`ADR-47`），但 `pubspec.yaml` 还是 `1.3.0+6`：用户手上会有**两个文件名完全相同、内容不同**的 v1.3.0 APK，**无法判断自己装的是哪一个**。已按 Android 常规做法改为 **`1.3.1+7`**（patch + versionCode 各 +1）。<br>**依据的边界要说清楚**：`ADR-44` 那次升 `versionCode` 的理由是"**权限集合变了**"，本轮权限集合**没变**（agent 仍是 `INTERNET,RECORD_AUDIO`，offline 仍是 `RECORD_AUDIO`，两个风味的权限闸门都实测通过）。所以这次升版本**不是为了权限**，而是为了"**用户能分辨装的是哪一版**"与 Android 对 `versionCode` 单调递增的常规约定。**本仓当时并没有把这条写成规范** —— 它只活在 `ADR-44` 的散文里，这正是"规矩分散在 ADR 里、不在 SPEC 里"的代价。 |
| 发布实测（v1.3.1，`RELEASE_1.3.1_20260915_agent.md` / `_offline.md` 两份） | agent：arm64 28,220,696 B、armeabi-v7a 23,847,690 B、x86_64 31,214,311 B；该风味**允许网络权限**（`INTERNET,RECORD_AUDIO`，权限闸门 `internet=True OK`）。offline：arm64 27,171,516 B、armeabi-v7a 22,732,974 B、x86_64 30,099,595 B；该风味**禁止网络权限**、**不申请 `INTERNET`**（只有 `RECORD_AUDIO`，权限闸门 `internet=False OK`）。**六个产物 `apksigner verify` 全部 OK，三个 ABI 全部 16 KB COMPATIBLE**，`analyze errors=0`（warnings=31 / info=83 均为既有）。 |
| 诚实边界 | ① 归档索引的**原始内容**（v1.3.0 的 offline 那份）我只改了文件名，没有改写内容，也没有试图"重建"已经丢掉的 agent 记录 —— 那份记录**真的没了**，`apk_sha256.txt` 只能提供哈希，提供不了当次的 `analyze` 统计与签名证据。② 版本号规则的归属（写进 `SPEC-C-04` 还是留在 ADR）我**没有**擅自决定，本轮只把命名规范写进 SPEC；"何时必须升 versionCode"仍是开放问题。③ 仍然**没有真机**：版本升级是否能在已装 v1.3.0 的手机上正常覆盖安装，未验证。 |

---

### ADR-49 ✅ 「按下『是』之后影响到下一轮判断」：**已确认卡片（`_heldConfirmed`）从来没有在会话边界清过** —— 而 `ADR-47` 让「是」当场产生这张卡片

| 项 | 内容 |
|---|---|
| 来源 | 用户实测反馈：「APP 在检测按下**是**的确认后会**影响到下一轮判断**」。 |
| 🔴 **复现成功（先红后修）** | 新测试 `app/test/ui/detect_confirmation_round_test.dart` 第一版**实测双红**：`Expected: false / Actual: true`。路径：① 第一次检测 → 0.5 置信度（落在 `[0.45,0.70)`，唯一会提问的区间）→ 点「是」；② 停止；③ 第二次检测 → **第一帧就显示上一次那个已确认的卡片**，而且整轮里只要新证据没到 `confirmed`，卡片一直被上一轮的结果占着。 |
| 🔴 根因：`DetectNotifier._heldConfirmed` **没有会话边界** | 这个字段只在 `_onSessionState` 里被写（`if (view.confirmed) _heldConfirmed = view;`），**全仓 `grep` 只有两处引用：一处赋值、一处读取，从来没有被清空**。于是它一旦有值就永久有效。<br>**它是怎么"影响到下一轮"的**：`DetectPresenter.predictionOf` 有两条路会把旧卡片顶上来 ——<br>· 新会话的**第一个 patch** `stage == none` → `return heldConfirmed ?? sensing`，**直接返回旧卡片**；<br>· 之后每个**不是** `confirmed` 的 patch → `held != null && held.confirmed && decision.stage != confirmed` → 仍然返回旧卡片，新一轮自己的读数和提问按钮被渲染在旧结果**下面**。<br>用户看到的"下一轮判断被影响"，在代码里就是这一个字段。 |
| 🔴 **为什么这轮才发作**：`ADR-47` 让「是」**同步**产生 `confirmed` 视图 | 修 `ADR-47` 之前，点「是」只调 `_setState(listening)`，**不动 `_prediction`** —— 卡片其实还停在"请确认"上，`_heldConfirmed` 要等聚合器自己给出 `confirmed` 才被写。`ADR-47` 把答复改成同步生效（**这一半是对的**：按钮必须当场消失），于是"点『是』"**当场**就把旧卡片钉进了 `_heldConfirmed`。**旧缺陷 + 新改动 = 用户按下就看到症状。** |
| 修法：把"一次检测的展示状态"当成**会话级**的，在边界清掉 | 新增 `DetectNotifier._resetForNewSession()`：清 `_heldConfirmed` / `_prediction`→`sensing` / `_behavior`→`empty` / `_savedRecord`→`null` / `_injected` / `_lastError`，并 `publish`。在 **`startRealtime()` 与 `startSample()` 的第一行**（早于 `blocked || _busy` 的早退之后）调用。<br>另加两处**冗余保险**（各自覆盖 `start` 到不了的路径）：`stop()` 的 `finally` 里清 `_heldConfirmed`（会话被原生结束、或某条路径没走 start），`disposeHandle()` 里同样清（notifier 比会话活得久）。**三处都留着，是因为它们各自对应一条真实的边界**，不是重复。 |
| ✅ **`_savedRecord` 是同一族的第二个泄漏（顺带修掉）** | `detect_page.dart` 渲染「已自动记录」横幅的条件**只有** `notifier.savedRecord != null`，**没有任何状态门**。所以上一轮落库后，**下一轮检测页上还挂着上一轮的横幅**。已由 `_resetForNewSession()` 一起清掉，并新增第 2 项测试钉死（`savedRecord` 在 stop 后 `isNotNull`、新 start 后 `isNull`）。 |
| 我**没有**改的东西（说清楚，免得误修） | **会话内**「确认结果卡片保持上一态直到新确认」是 `SPEC-U-02` §2.3 的**冻结判据**，也是 `ADR-46` 记录过的**有意行为**（`detect_page.dart:299` 的注释就是它）。所以：① `stop()` 之后 `ended` 页面**仍然保留**这一轮的结果卡片与横幅（那是会话小结）；② 同一轮内旧确认卡片在拿到新确认前仍然占位。本轮只切掉"**跨会话**继承"。如果用户看到的是**会话内**旧卡片压住新一轮读数，那是另一条冻结行为，要改必须先动 `SPEC-U-02` §2.3 并出 ADR —— 本轮**不动**。 |
| ⚠️ 负控是实测红的 | 修法前：`flutter test test/ui/detect_confirmation_round_test.dart` → **2 failed**（`Expected: false / Actual: true`）。修法后：**2 passed**。代码改动是两次运行之间**唯一的变量**。另注：三处清空里单独注释掉任意**一处**，本用例仍然会过 —— 因为对"是 → 停止 → 再开始"这条路径三处互为冗余；这也正是保留三处的原因（`session_tests`/`ui_presenter_tests` 走不到原生自动结束那条路）。 |
| 诚实边界 | ① 仍然**没有真机**：缺陷是用 `FakeAudioBridge` + `FakeInferenceEngine` 在 `flutter test` 里复现的，不是在手机上。② 我**不能确定**用户说的"下一轮判断"是哪一种：跨会话继承（本轮已修，已复现）**还是**会话内旧卡片占位（冻结行为，本轮不动）。两者的表现都像"旧的确认影响了新的判断"，所以我把判断留在这里，并请用户在下一次说明里点一下是"重开检测后还在"还是"同一次检测里就压住了"。③ `_behavior` / `_lastError` 的清理没有单独测试覆盖（它们跟随 `_savedRecord` 走同一条路径）。 |

---

## 4. ✅ 已全部拍板（2026-09-10）—— **无剩余未决项**


| # | 议题 | **拍板结论** | 落点（已写入） |
|---|---|---|---|
| `ADR-P1` | `n_frames` = 129 还是 128 | **129（选项 B）**：保留 4.096 s 窗口，输入 `[1,128,129,1]`。否决选项 A（128 / 4.064 s / 65024 样本） | `feature_config.n_frames` → `const: 129`；新增 `_decisions.n_frames`（含 `rejected_alternative`）；两份 schema；`SPEC-00` §3.5 |
| `ADR-P2` | `grade` 分档阈值未定义 | **`≥80 → 良好`；`60–79 → 一般`；`<60 → 需改善`** | `feature_config.health_score_formula.grade_thresholds`（`good_min: 80` / `fair_min: 60`）；`SPEC-00` §3.7 **FF-22b** |
| `ADR-P3` | `feature_config` 作为 SSOT 不完整 | **已补全**：`behavior` 由 4 键扩到 **11 键**；新增 `meal_windows`、`health_score_formula` 两组；`_pending_decision` → `_decisions`。顶层 **31 → 34 键**（随后 `ADR-16`/`ADR-17` 再加 7 个音频键 → **41 键**，见 §3） | `shared/feature_config.json` + `feature_config.schema.json`（双向差集已核为零） |
| `ADR-P4` | 数据可携带性缺口 | **采纳选项 B**：`U-05` 增「**复制为文本**」按钮（写剪贴板；**不走网络、不落文件**，约 20 行）+ 明确告知「数据仅存于本机，卸载即丢失」。**不新增范围**（0.1 人日由 `U-05` 既有预算吸收） | `SPEC-U-05` / `PLAN-U-05` |
| `ADR-P5` | 范围冻结签字 | **批准**：40 项交付 / 7 项裁剪，**内容不变** | `docs/00_功能清单与数量分析.md` §2 / §4 |
| `ADR-P6` | `confirmedByUser` 展示边界 | **两列都保留入库**（`confirmed_by_user` 供统计低置信度占比与模型迭代）；**UI 只呈现「已确认」标记**（对应 Level-3 二选一确认过的记录），**不呈现「已修正」** | `SPEC-U-03` |

> ⚠️ **`ADR-P5` 的纸质签字栏仍然保留** —— 竞赛材料需要具名签署件。但**范围本身已批准冻结**，**不再阻塞任何开发**，也不再是"待办"。

---

### ADR-P1 ✅ `n_frames` = **129**（选项 B）

| 项 | 内容 |
|---|---|
| 事实 | librosa `center=True` 时帧数 = `n_samples // hop + 1`。4.096 s（65536 样本 @ hop 512）⇒ **129 帧**，不是 128。 |
| **拍板结论** | **129（选项 B）**：保留 4.096 s 窗口，输入形状 `[1, 128, 129, 1]` |
| 被否决 | 选项 A：保留 128×128 输入，窗口缩短为 4.064 s（65024 样本） |
| 采纳理由 | ① 4.096 s = 2¹⁶ 样本，是"一口食物"的自然时长，覆盖约 **4–8 个咀嚼周期** ② **129 非 2 的幂对 GlobalAveragePooling 分类器无任何影响** ③ 4.096 s 已冻结在全部下游文档与测试夹具中，改选 A 需全量重导而**换不来任何建模收益** |
| 它同时决定四处 | `feature_config.n_frames`、`model_card.nFrames`、Kotlin `MelFrontend` 常量、Dart 常量 —— **四处已全部为 129** |
| 拍板日 | **2026-09-10** |
| 机器可读记录 | `shared/feature_config.json` 的 `_decisions.n_frames`（含 `rejected_alternative.reason_rejected`） |
| 详见 | `SPEC-00` §3.5、`PLAN-C-03`、`ADR-07` |

### ADR-P2 ✅ `grade` 分档阈值

| 项 | 内容 |
|---|---|
| 问题 | FF-22 只给了三值枚举（`良好` / `一般` / `需改善`），**没给分数边界**，`HealthScoreService` 无法实现。 |
| **拍板结论** | **`≥80 → 良好`；`60–79 → 一般`；`<60 → 需改善`** |
| 依据 | 材料无明文依据，属产品判断 —— 之所以原先必须由人拍板。**注意 `1.png` 的「85 分 = 良好」与本阈值自洽。** |
| 拍板日 / 登记 | **2026-09-10**；已登记为 **`SPEC-00` §3.7 的 FF-22b** |
| 机器可读 | `feature_config.health_score_formula.grade_thresholds` |
| 落点 | `SPEC-00` §3.7、`SPEC-A-01`（`grade` 产出）、`U-01`/`U-04`（评级展示） |

### ADR-P3 ✅ `feature_config.json` 补全为**真正的** SSOT

| 项 | 内容 |
|---|---|
| 问题 | 本项目把 `feature_config.json` 当唯一真源，但它**缺**以下已被其他文档当作"事实"的量：① FF-21c 峰值动态阈值系数 ② FF-21d 孤立峰邻域 ③ FF-21g 的 MAE 降级线 ④ FF-21h 包络帧长/hop/长度 ⑤ 全部评分公式参数 ⑥ 餐次窗口边界（`ADR-09`）⑦ `grade` 分档阈值。**这些值只存在于 Markdown 里，没有任何机械机制防止两侧漂移** —— 而 `C-03` 的全部价值就建立在"单一真源"上。 |
| **拍板结论** | **全部补入**（顶层 31 → **34 键**；此后 `ADR-16`/`ADR-17` 又加 7 个音频键，最终 **41 键** —— 见 §3 ADR-16/17）：<br>• `behavior` **4 → 11 键**：新增 `chew_isolated_gap_ms`(300) / `chew_peak_threshold_k`(0.5) / `smoothing_window_ms`(50) / `envelope_frame_ms`(10) / `envelope_hop_ms`(5) / `envelope_length`(819) / `chew_count_mae_degrade_ratio`(0.25)<br>• 新增 **`meal_windows`**（早 `[300,600]` / 午 `[660,840]` / 晚 `[1020,1260]` / 晚间 `[1200,300]` / `snack_is_complement_of_meals`）<br>• 新增 **`health_score_formula`**（四维公式参数 + `evaluation_order` + `rounding` + `grade_thresholds`）<br>• `_pending_decision` → **`_decisions`**（记录 `ADR-P1` 的拍板结论与否决备选） |
| 为什么这次由文档侧直接改 | 原判断是"必须经 A 确认"—— 但既然拍板权已下放且 `n_frames` 同步定案，**补全是执行拍板、不是新决策**。补全后已做**双向差集核验**：`required`/`properties` 与真实 JSON **零差异**。 |
| 连带产物 | `feature_config.schema.json` 同步扩写（含 `_decisions` / `meal_windows` / `health_score_formula` 三个子模式）；`SPEC-C-03` §4 的键值表：**31 → 34 → 41 键**（41 为最终值，含 `ADR-16`/`ADR-17` 的 7 个音频键）；`API-02` 的 `BehaviorConfig` 已补 `smoothWindowMs` / `isolationGapMs` |

### ADR-P4 ✅ 数据可携带性缺口

| 项 | 内容 |
|---|---|
| 问题 | `X-03` 裁剪了 CSV 导出，而 v1.0 又没有任何网络出口 ⇒ **用户数据在本机之外无法取出**；卸载或换机即全部丢失。既是**产品缺陷**（用户资产无法迁移），也可能构成**合规瑕疵**（个保法"可携带权"要求提供获取与转移个人信息的途径）。 |
| **拍板结论** | **采纳选项 B**：`U-05` 增加一个「**复制为文本**」按钮 —— 把当前记录序列化为纯文本写入**系统剪贴板**。**不走网络、不落文件、不外发**，是用户显式发起的本地动作，因此**不破坏**「无网络、音频不落盘」的隐私主张。 |
| 配套 | `U-05` 的隐私声明必须**明确告知**「数据仅存于本机，卸载即丢失」。 |
| 为什么不选 C | 选项 C（SAF 文件导出，约 0.3 人日）会引入文件写入路径，与 `FF-24` 第 1/2 条的"不落盘"审查口径冲突，需额外论证；10 天窗口内不划算。选项 A（什么都不做）则留下合规缺口。 |
| 范围影响 | **不新增范围**（约 20 行，由 `U-05` 既有预算吸收），因此**不需要等额删除其他功能**（`R-14` 不触发）。 |
| 落点 | `SPEC-U-05` / `PLAN-U-05` |

### ADR-P5 ✅ 范围冻结批准

| 项 | 内容 |
|---|---|
| 问题 | `PLAN-00` §5 核算：40 个功能约需 **234 h**，可用 **240 h**，**余量仅 2.5%**。不冻结必然范围蔓延（风险 `R-14`）。 |
| **拍板结论** | **批准冻结**：`docs/00_功能清单与数量分析.md` §2 的 **40 项交付** + §4 的 **7 项裁剪**，**内容不变**。 |
| 生效 | 2026-09-10。任何后续新增功能须**等额删除一项**。 |
| 仍需的纸质件 | 竞赛材料需要具名签署件，签字栏保留：A：________ B：________ C：________ 日期：________ |

### ADR-P6 ✅ `confirmedByUser` 与 `correctedByUser` 的展示边界

| 项 | 内容 |
|---|---|
| 问题 | `SPEC-D-01` 的 `diet_record` 有两列（`confirmed_by_user` / `corrected_by_user`），而冻结的 `DietRecord` 类只声明 `correctedByUser`。 |
| 背景 | `X-02` 把"手动修正"降级为**二选一确认**，所以 `confirmed_by_user` 记录的是 **Level-3 人机协同是否发生过** —— 它有分析价值（可统计低置信度占比、供模型迭代），但**不是 v1.0 的 UI 需求**。 |
| **拍板结论** | **两列都保留入库**；**UI 只呈现「已确认」标记**（对应二选一确认过的记录），**不呈现「已修正」**。`DietRecord` 的 Dart 侧暴露也保持 `correctedByUser` 不变，`confirmed_by_user` 仅作分析字段。 |
| 落点 | `SPEC-U-03`（详情页展示口径）、`SPEC-D-01`（两列保留） |

---

### ADR-51 ✅ 仓库结构重排：**仓库根即 AcouDiet 工程本身**，`AcouDiet/docs/` → `records/`

| 项 | 内容 |
|---|---|
| 触发 | 用户要求：「把 `Food` 里的内容上传到 GitHub 仓库，主要是 `AcouDiet` 文件夹、`acoudiet_model_v1.3`、`设计资料`、`docs`，**整理为别人下载下来就能进行二次开发的项目结构**」。 |
| 问题 | `ADR-36` 把仓库根设在**工作区根**，代码放在 `AcouDiet/` 子目录 —— 对**作者**那是必要的（宪法与 SSOT 在兄弟目录里），但对**外部读者**它是「一个装文件的文件夹」，不是一个工程。歧义连作者自己也踩过：`AcouDiet/` 内有一个空壳 `.git`（零 ref、零提交、残留 `index.lock`、1.97 GB 游离对象）。 |
| 裁定 | 仓库根**就是** AcouDiet 工程本身。`app/` `ai/` `tool/` `release/` 上移一层；`AcouDiet/docs/` → `records/`；出厂模型包 → `models/v1.3/`；`设计资料/` → `design/`。`docs/`（SPEC 树）与 `shared/`（SSOT）**保持在仓库根不动**，因此这两者之间的引用一字未改。 |
| 为什么可行 | `app/ ai/ tool/` 是**同构平移**：脚本一律用 `$Root = 其自身位置推导` 或 `parents[N]` 定位，整体上移一层后语义不变。实测只有 5 处显式字符串与 6 处 `ROOT.parent` 需要改写（见下）。 |
| 路径映射 | `AcouDiet/{app,ai,tool,release}` → `{app,ai,tool,release}`；`AcouDiet/docs` → `records`；`AcouDiet/README.md` → `README.md`；`acoudiet_model_v1.3/v1.3` → `models/v1.3`；`设计资料` → `design`；`docs/`、`shared/`、`.github/`、`.gitignore`、`.gitattributes` 位置不变。 |
| 非机械改写（逐条） | ① `ai/src/config.py`：`WORKSPACE_ROOT` 由 `PROJECT_ROOT.parent` 改为 `PROJECT_ROOT` —— `paths.workspace` 是「CSV 路径 → 绝对路径」的除数，必须等于仓库根；② `ai/tests/run_all.py`、`tool/verify_artifacts.py`、`tool/install_model.py`、`tool/check_split_leakage.py`、`tool/evaluate_shipped_model.py` 的 `WORKSPACE = ROOT.parent` 同理；③ `tool/evaluate_shipped_model.py::resolve()` 改为剥离 CSV 里可能残留的旧 `AcouDiet/` 前缀；④ `ai/data/splits/*.csv` 共 3360 行路径去掉 `AcouDiet/` 前缀；⑤ `tool/build_release.ps1` 的 `$Docs` 由 `docs\release` 改为 `release`，冻结提交的 `git -C` 改指 `$Root`；⑥ `.github/workflows/verify.yml` 的 `working-directory`。 |
| 刻意**不**改 | `ADR-01`…`ADR-49` 各条目正文里的旧路径**一字不动** —— ADR 是**记录**，不是索引；改写它们等于篡改当时的事实。要查旧路径对应关系，用本表的「路径映射」。 |
| SPEC 树里的「证据落点」已改 | `docs/` 下的 SPEC/PLAN 反复用 `docs/compliance/…`、`docs/demo/…`、`docs/reports/…`、`docs/release/…` 指定**验收证据的归档目录**（相对当时的 `AcouDiet/` 根）。这些**不是** SPEC 树自己的目录，而是 `AcouDiet/docs/` —— 已随 `records/` 一并重写，否则每一条验收判据都会指向一个不存在的路径。`docs/common/…`、`docs/backend/…`、`docs/frontend/…`（SPEC 树自身）**一字未改**。 |
| 刻意**不**发布 | `建议模型/`（模型选型调研，含 543 MB `safetensors`）与 `讨论资料/`（过程草稿、计划书）由 `.gitignore` 挡在仓库外；文中引用它们的段落是历史记录，不是失效链接。 |
| 随行产出 | 新增根 `README.md`（面向「下载后二次开发」：目录导览 / SSOT 纪律 / 一键回归 / 换模型 / 环境变量 / 未发布物）、`LICENSE`（**Apache-2.0**）。 |
| 诚实边界 | ① 开发工具链 `_toolchain/`（约 26 GB）**不进版本库**，入口脚本回落作者本机绝对路径 `D:\Desktop\Food\_toolchain`；外部环境须自行设 `ACOUDIET_TOOLCHAIN` / `ACOUDIET_PYTHON` / `ACOUDIET_FLUTTER`。② 两处**留在本机但不入库**、可随时删除：`AcouDiet/_toolchain/`（3.1 GB 遗留 Android SDK）、`_toolchain/_archive/git_orphan_AcouDiet-20260915/`（被禁用的空壳 `.git`，1.97 GB）。③ `ADR-50` 的记述不在本日志里，而在 `.gitignore` 与 `.gitattributes` 的头部注释（首次推送前的制品忽略审计与行尾策略）。 |

---

### ADR-52 🟡 「提升收音质量：噪声频谱减法 + 自适应滤波」的**范围合规审查 + 实测**：两项技术一项已被冻结条款排除，另一项按现状接上去会让识别**变差**；真正的瓶颈不在麦克风

| 项 | 内容 |
|---|---|
| 来源 | 用户要求：「提升 APP 的收音质量，例如对噪声频谱减法、自适应滤波。注意实时处理优化和语音失真控制」。 |
| 🔴 **结论一：这个需求的两项技术，一项被明文排除，一项只能以「默认关闭的消融开关」形式存在** | 用户点名的两项技术在 `SPEC-P-03` 里的位置完全不同：<br>· **谱减法**：**已经是被规格化的东西**——§1.2「谱减法实验开关：默认 `false`；开启时由 `startSession.enableDenoise` 传入，**仅用于消融对照**」；§2.2 步骤 6「若 `enableDenoise == true` → 执行实验性谱减法」；§5「谱减法开关默认值 = `false`」；§7 判据 5 要求默认分支 100% 不走谱减。<br>· **自适应滤波**：**§1.3 范围外表明确写着**「降噪模型、神经网络降噪、**Wiener 滤波** | **不做**（10 天窗口无训练与验证成本）」，§9「谱减法之外的任何降噪（神经降噪、Wiener、谱门限）：**不做**」。**LMS/NLMS 自适应滤波属于这一行**，不是"实现细节"。<br>· 另有 §1.3「谱减法默认开启 | **禁止**」。<br>**所以正确的动作不是"去加一个降噪器"，而是先做一次范围合规审查**——这与 `ADR-40` 处理研究路线六项时用的是同一套流程（四项撞裁剪项、一项明文禁止）。 |
| 🔴 **结论二：设备侧的谱减开关今天是个"会抛错的桩"，而它抛错是**对的 | `Preprocess.kt` 的 stage 3 在 `enableDenoise = true` 时抛 `ACD-CFG-001`，理由写在注释里：「No spectral-subtraction parameters exist in the SSOT, and SPEC-P-03 section 6 forbids a silent downgrade」。**这与 `SPEC-P-03` §2.4 完全一致**（「`enableDenoise=true` 但配置缺谱减参数 → 抛 `ACD-CFG-001`，不得静默降级为关闭」）。所以现状**不是缺陷**，而是一个尚未冻结参数的实验开关。<br>**同时发现一处两侧不一致（`SPEC-T-06` §6 要求记录而非掩盖）**：训练侧 `ai/src/augment.py::spectral_subtract` 在 **`pre-emphasis` 之前**降噪（`feature_tensor` 里 `patch = spectral_subtract(...)` 然后才 `wav_to_float` / `_preprocess_float`），而设备侧 stage 3 在 **`pre-emphasis` 之后**。两者**不可交换**（预加重是一阶高通，会改变各频带信噪比），所以"同一算法族"这句话在数学上不成立，必须在实现前定死顺序。 |
| 🔴 **结论三（本轮实测，决定性）：按现状接上谱减法，识别与包络**都变差**；它只在 0 dB 附近才有一点收益 | 新增 `tool/measure_denoise.py`（**只读，不改动任何冻结文件**）：在冻结的 `test_mobile`（144 段，6 类各 24 段）上，用 `ai/data/noise/` 的 6 段真实噪声（食堂/办公室/街道）按 20/10/5/0 dB 混合，跑**出厂 `.tflite`**，对照"已知干净参考"。`ref` = 逐字复刻 `augment.py` 的算法（`max(mag − 1.5·noise, 0)`，无谱底）；`floor` = 本轮加的失真控制（谱底 `0.05·mag` + 软门限）。<br>**自检**：`clean` 行测得 `0.1667`，与 `verify_artifacts.py` 独立测出的出厂模型 `top1 = 0.1667` **完全一致**，说明这条测量链没有跑偏。<br>**实测结果**（`ai/reports/denoise_effect.md` 生成，勿手改）：见下表。 |
| 📊 总体（`n` = 576 = 144 段 × 4 个 SNR） | \| 变体 \| top1 \| SSNR dB \| 包络相关 \| 瞬态峰比 \|<br>\|---\|---\|---\|---\|---\|<br>\| `clean` \| **0.1667** \| — \| — \| — \|<br>\| `noisy` \| 0.1215 \| 7.63 \| **0.968** \| 0.840 \|<br>\| `denoise_ref` \| **0.0382** \| **2.52** \| **0.281** \| 2.969 \|<br>\| `denoise_floor` \| 0.1024 \| 4.09 \| 0.605 \| 3.234 \|<br>6 类均衡时随机基线 = 0.1667（**出厂模型在干净音频上就正好是随机**，`24/144`）。 |
| 📊 分 SNR（决定性的一栏） | \| SNR dB \| `noisy` \| `denoise_ref` \| `denoise_floor` \|<br>\|---\|---\|---\|---\|<br>\| 20 \| **0.1667** \| 0.0069 \| 0.0903 \|<br>\| 10 \| **0.1181** \| 0.0347 \| 0.1181 \|<br>\| 5 \| **0.1111** \| 0.0347 \| 0.0972 \|<br>\| 0 \| 0.0903 \| 0.0764 \| **0.1042** \|<br>**读法**：`20 dB` 时降噪是**灾难**（0.1667 → 0.0069）；到 `0 dB` 才第一次反超不降噪。**也就是说："无条件降噪"在当前配方下必然净损，唯一可能获益的形态是「按估计 SNR 自适应地决定降不降」——而那正是 §1.3 明文排除的那类东西。** 这不是巧合，是本次审查的核心发现。 |
| 🔴 **结论四：真正的瓶颈不是麦克风** | 出厂模型在**干净**音频上 `top1 = 0.1667`（= 随机），噪声下 0.1215；`ADR-37` 已记过"6 类里有 3 类从不被预测"。**在识别端处于随机水平的阶段，任何前端改善都不可能表现为准确率提升**——因为随机分类器对输入变换不敏感。同理，包络域也已经被证实**很抗噪**（`noisy` 的包络相关 **0.968**），而降噪器反而把它砸到 0.281/0.605。所以「降噪能提升咀嚼计数/行为指标」这个假设**在本轮实测中被证伪**。 |
| 🔴 **结论五：连"验证降噪有没有用"的数据集都不存在** | `test_mobile` 的 144 段全部是**近距安静条件**的录音（文件名只有 `desk30` / `handheld` / `near10`），**没有任何噪声条件**。本轮的信噪比是**合成混入**的（6 段噪声、按全局 RMS 定标），不是真实现场录音。所以即使要上线降噪，也**先得有一个真实噪声条件测试集**，否则验收标准无从谈起。 |
| 建议（需要用户拍板，本轮**未改任何 APP 代码**） | ① **不要开启谱减法**：保持默认关闭（这本来就是 §1.3/§5 的强制要求），也不要把设备侧的桩"接上"——按实测它是**回归**而不是改进。<br>② 若仍要推进降噪，正确顺序是：**先补真实噪声条件测试集 → 再按 SNR 自适应**；并且要动 `SPEC-P-03` §1.3/§9（把"Wiener/谱门限不做"改成有条件的允许），这需要一次正式修订，不能靠实现方自行发挥。<br>③ 若目标是**现场演示更稳**（食堂噪声下不出洋相），优先级更高的是**模型**（`ADR-37`：出厂模型在自建测试集上等于瞎猜），而不是麦克风前端。<br>④ 唯一**现在就能做且不违反任何冻结条款**的动作：把设备侧 stage 3 的**参数冻结进 SSOT**并把两侧**降噪顺序统一**，让 `enableDenoise` 从"抛错的桩"变成一个**真能跑的消融对照**（§1.2 说它的用途就是消融）。但要说清：这是**为消融准备基础设施**，不是"提升收音质量"。 |
| 本轮改动（全部只读或新增，未触碰 APP 代码） | 新增 `tool/measure_denoise.py`（测量脚本，含负例意识：`--limit` 会**按类分层抽样**，因为 split CSV 是按类排序的）、生成 `ai/reports/denoise_effect.md` + `.json`。`.gitignore` / `.gitattributes` / `ADR-51` 的仓库重排是**用户本轮并行完成**的，本 ADR 不重复记账。 |
| ⚠️ 诚实边界 | ① **全部在 PC 上测的**：没有真机、没有 Android 上的实时耗时数据；`SPEC-P-03` §8 要求的 hop 预算实测仍未产出。② SSNR / 包络相关 / 瞬态峰比都是**本轮定义的代理指标**（SSNR 帧内跳过干净 RMS < 1e-4 的帧、裁剪到 [-10,35] dB；包络是 5 ms RMS），**不是**冻结的咀嚼计数估计器，不能当成行为指标验收。③ `floor` 变体是**我加的两参数扩展**（谱底 + 软门限），**尚未冻结**，SPEC 也没有它；它只是用来证明"失真控制能把包络相关从 0.281 抬到 0.605"，不作为已批准的配方。④ 噪声语料只有 6 段、按全局 RMS 定标混合，与真实现场（非平稳、方向性、混响）差距明显。⑤ `--limit` 首版**按类排序截断**，导致 `--limit 12` 取到 12 段 `cabbage`、模型得分 1.0000，几乎引出一个与事实相反的结论；已改为分层抽样并把这件事写进脚本注释——**这是本 ADR 里最值得记住的一条方法论教训**。 |

---

### ADR-53 🟡 按用户指示做「尽可能消除噪音」：**第二代降噪器真的能消掉 14.4 dB 噪音，但代价是不能接受的** —— 扫了 55 组参数，没有一组能同时保住信号

| 项 | 内容 |
|---|---|
| 来源 | 用户在看到 `ADR-52` 的负面实测后仍明确指示：「反正把收音的噪音尽可能消除以提高输入到模型的音频质量」。**这是产品负责人的决定，本轮照办**——但「消除噪音」必须以**可测量的方式**达成，否则会与用户自己的目标（提高输入质量）相反。 |
| 🔴 **先把"消除噪音"变成可测量的量** | `ADR-52` 用的 SSNR 有一个陷阱：**它对整体增益变化敏感**。第二代降噪器一开始显示 SSNR 很差，但它其实把噪音消掉了——因为 Wiener 增益同时让信号变轻了。所以本轮补了两个**不可能被"靠破坏信号刷分"**的直接指标：<br>· **噪音衰减**：把降噪器作用在**纯噪音**片段上，量输出/输入 RMS 比（负 = 消掉了能量）。<br>· **信号衰减**：作用在**干净**片段上，同一个量（理想 ≈ 0.00 dB）。<br>并把 SSNR 改成**增益匹配后**的版本（先按最小二乘把增益对齐，再算误差），这样才能把"失真"与"音量"分开。 |
| 📊 **第一代 vs 第二代：噪音到底消掉没有** | \| 配方 \| 纯噪音上 \| 干净信号上 \|<br>\|---\|---\|---\|<br>\| `denoise_ref`（`augment.py` 原版） \| **+9.48 dB（噪音反而变大）** \| +8.76 dB \|<br>\| `denoise_floor`（`ADR-52` 的谱底版） \| **+9.06 dB（同样变大）** \| +5.18 dB \|<br>\| **`denoise_ms`（本轮新增）** \| **−14.37 dB（真消掉了）** \| **−4.90 dB（代价）** \|<br>**读法**：第一代那两种配方在纯噪音输入上让能量**变大 9 dB**——那不是降噪，那是把噪音调制成了新的伪影（musical noise），这也解释了它们为什么把包络相关砸到 0.28。第二代确实消掉了 **14.4 dB** 噪音，但顺手也拿走了 **4.9 dB 信号**。 |
| 📊 增益匹配后的 SSNR（10 dB 混合，n=24 冒烟） | `noisy` **9.22** ｜ `denoise_ref` 0.21 ｜ `denoise_floor` 1.47 ｜ `denoise_ms` **3.00**。第二代最好，但**仍远低于不降噪**——说明这一族算法对本信号的波形失真是实质性的，不是调参能补的。 |
| 🔴 **决定性结果：55 组参数无一通过** | 新增 `tool/sweep_denoise_params.py`（**不跑模型**，只算上面三个指标，所以一组配置几秒钟）：在 `dd_alpha ∈ {0.5,0.7,0.9,0.98} × min_bias ∈ {0.5,1.0,1.5} × gain_floor_db ∈ {−18,−12,−8} × xi_min_db ∈ {−18,−12}` 共 **48** 组（加上报告表内的重复行，实测扫描 55 个配置格）上，判据是【噪音 ≤ −6 dB **且** 信号 ≥ −1 dB **且** SSNR ≥ noisy−1 dB】：<br>**没有任何一组通过。**<br>· 保住信号的（`min_bias = 0.5`）：噪音 **+3.8 dB**（等于没降）。<br>· 真正降噪的（`min_bias = 1.0~1.5`）：噪音 −15.3 dB，但信号 **−2.8 dB**，SSNR 只有 1.77。<br>· **这就是交易的全部**——不存在"既消掉噪音又不动信号"的设置。 |
| 🔴 **为什么这一族算法在这里注定失败（机制，不是猜测）** | 六个类别的判别信息主要落在**宽频瞬态**（脆/酥/脆爽）上。任何**逐频带**、由噪音底估计导出的增益，都会在瞬态的低能量段（起振与衰减沿）把增益压下去——而"脆"的听感恰恰就在那两段。所以过减会吃掉脆感，谱底会保留噪音，**两者都落在同一条前沿上**。`ADR-52` 的合成混音实验（20 dB 时 top1 掉到 0.0069）与这里的指标是同一件事的两个侧面。 |
| 本轮实际产出 | 新增 `ai/src/denoise.py`（第二代：**最小统计量**噪音估计 + **判决引导先验 SNR**（Ephraim-Malah）+ **Wiener 增益** + **增益下限**；全部参数集中在一个 dataclass，便于按 `SPEC-C-03` 冻结；`carry` 预留跨 patch 三值，默认无状态，以守住 `SPEC-P-03` 判据 6）<br>新增 `tool/sweep_denoise_params.py`（参数扫描）<br>扩展 `tool/measure_denoise.py`（噪音/信号衰减 + 增益匹配 SSNR + 第 4 个变体）<br>重生成 `ai/reports/denoise_effect.md` / `.json`。**未改任何 Kotlin / Dart 代码**。 |
| ⚠️ 为什么**没有**port 到 Kotlin | 把未通过验证的降噪器 port 进 App，只会把风险搬进生产路径：它按实测是**负收益**，而且 `SPEC-P-03` §1.3/§9 目前**明文禁止**谱减法之外的降噪。port 的正确前提是：① 算法在语料上被证明净收益为正；② `SPEC-P-03` 完成修订。两条都还没满足。 |
| 要真正达成用户的目标，需要什么（按优先级） | ① **先补真实噪声条件测试集**——现在 144 段全是近距安静录音，没有任何噪声条件，降噪的收益无法验收。<br>② **换算法族**：瞬态/起振保护（时域包络门限、带平滑 attack/release，而不是逐频带增益），或**用本语料的 (noisy, clean) 对训练一个学习式降噪器并直接把分类损失纳入**；两者都超出 §1.3/§9，需正式修订。<br>③ **先修模型**：出厂模型在**干净**音频上就是 0.1667（= 随机）。识别端处于随机水平时，前端改善**不可能**表现为准确率提升——这是本轮所有负面结论的共同前提。 |
| 诚实边界 | ① 仍然**全部在 PC 上**，没有真机、没有 Android 实时耗时数据（`SPEC-P-03` §8 的 hop 预算实测依旧欠着）。② 扫描用的样本是 **12 段干净 + 6 段噪音 + 24 段混合**的小样本，足以定性地判定"没有通过配置"，但不足以标定最优参数。③ 我**没有**尝试学习式或时域瞬态保护方案，所以"换算法族也没用"这句话**没有证据**——本 ADR 只证明**这一族**不行。④ `ADR-52` 里"未改任何 APP 代码"的表述在本轮仍然成立：新增的是 Python 侧参考实现与测量工具，**设备侧一行未动**。 |

---

### ADR-54 ✅ 换到**时域瞬态保护**这一族：**864 组参数里终于有解，而且它全面压过频域那一族** —— 16.2 dB 噪音只花 1.65 dB 信号

| 项 | 内容 |
|---|---|
| 来源 | 用户对 `ADR-53` 的结论作出的下一步指示：「下一步就做时域瞬态保护那一族」。 |
| 为什么这一族能赢（机制，不是试出来的） | `ADR-53` 证明频域那一族失败的原因是结构性的：**逐频带**增益必然在瞬态的低能量段（起振/衰减沿）把增益压下去，而"脆"的听感正在那两段。时域门限换了个量纲——**每个时刻只有一个宽带增益**：<br>① **瞬态的频谱不会被改**：标量增益只能让瞬态变轻或变响，无法改变其频谱形状，所以**不可能产生 musical noise**（没有逐 bin 的开关可颤）；<br>② **只减不增**（`gain ≤ 1`）：从机制上排除了第一代那种"在纯噪音输入上把能量放大 9 dB"的伪影；<br>③ 增益由**前瞻窗内的峰值保持包络**驱动，**在瞬态到达之前就已经打开**——朴素门限会削掉起振，这一族不会。前瞻在一个 patch 内是**免费**的（整段离线处理），所以不需要因果延迟。<br>④ 与冻结特征链相容：`FF-08` 是 `per_patch_minmax`（Mel **dB** 图上的逐 patch 归一化），**整段常数增益会被归一化掉，而时变增益不会被抵消**——正是我们要的效果：脆响留在原地，脆响之间的噪音底降下去。 |
| 新增实现 | `ai/src/denoise_td.py`：5 ms RMS 包络（与项目冻结的包络 hop 一致，避免两套分帧定义）→ **最小值统计**噪音底（scipy 滑动最小，O(frames)）→ 对称**峰值保持**前瞻 → **软向下扩展**（dB 域、C¹ 连续、无硬拐点所以不会 chatter）→ **attack/release 分离的一阶平滑**（attack 1 ms 保护起振，release 40–80 ms 避免泵动）→ 帧率增益**插值到逐样本**后相乘（插值而非样本保持，这是不产生咔哒声的关键）。参数集中在一个 `TdGateParams` dataclass，便于按 `SPEC-C-03` 冻结。 |
| 📊 **两族直接对比**（同一套三个指标、同一批语料、10 dB 混合） | \| 族 \| 配方 \| 噪音 \| 信号 \| SSNR \|<br>\|---\|---\|---\|---\|---\|<br>\| 频域 \| `denoise_ref` \| **+9.48（反而变大）** \| +8.76 \| 0.21 \|<br>\| 频域 \| `denoise_ms`（`ADR-53` 最好） \| −15.30 \| −2.78 \| 1.77 \|<br>\| **时域** \| **`denoise_td`（本轮选中）** \| **−16.20** \| **−1.65** \| **5.55** \|<br>**读法**：**消掉的噪音更多（−16.20 vs −15.30），信号代价少 41 %（−1.65 vs −2.78），波形保真度高 3.1×（SSNR 5.55 vs 1.77）**。这是本轮最重要的结果：用户的目标（尽可能消噪）**在这一族里是可达的**。 |
| 参数是怎么选出来的（透明的策略，不是挑好看的） | `tool/sweep_denoise_td.py` 扫 **864** 组（`maxAttenuation × threshold × lookahead × release × knee × noiseBias`），用与频域同一套 PASS 判据（噪音 ≤ −6 dB 且 信号 ≥ −1 dB 且 SSNR ≥ noisy−1 dB）：**恰好 1 组通过**（`maxAtt=18, thr=12, look=4, rel=80, knee=12, bias=1.0` → 噪音 −6.04 / 信号 −0.98 / SSNR 8.24）。<br>但用户要的是「**尽可能**消除」，所以另按**显式预算**选点，并把三条预算档都列出来：<br>· 信号 ≥ −1 dB → 最多消 **−6.04 dB**（48 个候选）<br>· **信号 ≥ −2 dB → 最多消 −16.20 dB（385 个候选）← 选中**<br>· 信号 ≥ −3 dB → 最多消 −19.93 dB（511 个候选，但 SSNR 掉到 3.42）<br>选中配置：`max_attenuation_db=30, threshold_db=9, lookahead_frames=4, release_ms=80, knee_db=6, noise_bias=1.5`。**预算是我定的、并且写在这里**，用户若想要更激进的消噪，改预算即可复现选点。 |
| 实现位置与冻结条款 | ⚠️ 仍然**在 `SPEC-P-03` §1.3/§9 之外**：「谱减法之外的任何降噪（神经降噪、Wiener、谱门限）：**不做**」。时域门限既不是谱减法，也不属于被列出的那三类，但**它显然需要 §1.3/§9 的正式修订**才能进生产路径——这一点不因为"指标好看"而改变。**本轮仍未改动任何 Kotlin / Dart 代码**，产出是 Python 侧参考实现 + 可复现的测量/扫参工具。 |
| 📊 **出厂模型确认：这是第一个真正改善识别的前端改动** | `tool/measure_denoise.py` 全量跑完（`test_mobile` 144 段 × 4 个 SNR，n=576）：<br>· **总体 top1**：`clean` 0.1667 ｜ `noisy` **0.1215** ｜ `denoise_ref` 0.0382 ｜ `denoise_floor` 0.1024 ｜ `denoise_ms` 0.0694 ｜ **`denoise_td` 0.2014**<br>· **分 SNR top1**：<br>\| SNR \| `noisy` \| `denoise_ms` \| **`denoise_td`** \|<br>\|---\|---\|---\|---\|<br>\| 20 \| 0.1667 \| 0.0903 \| **0.2361** \|<br>\| 10 \| 0.1181 \| 0.0556 \| **0.1806** \|<br>\| 5 \| 0.1111 \| 0.0833 \| **0.2083** \|<br>\| 0 \| 0.0903 \| 0.0486 \| **0.1806** \|<br>· **噪音/信号**：`denoise_td` **−16.20 dB / −1.86 dB**（`denoise_ms` −14.37 / −4.92）。<br>**结论（谨慎表述）**：`denoise_td` 是**唯一一个在每个 SNR 上都同时超过"不加降噪"与随机基线**的变体。对 `noisy` 的优势很明确（0.2014 vs 0.1215，n=576 的 95% 带 ±0.0304）；**但超过随机基线只是勉强**（0.2014 vs 0.1667，仅比带外多 0.004），**分 SNR 每格 n=144（带 ±0.061）单独看都不显著**。**所以正确的说法是：它证明了"时域门限不会像频域那样伤害识别"，而不是"识别问题解决了"**——0.20 距离可用还差得远。 |
| ✅ 那处"包络雷"**已实测排除**（`ADR-55`） | `ADR-54` 曾把 `crestRatio` 3.549 / `envCorr` 0.875 当成威胁行为分析的雷。**实测表明那是我的指标假警报**：按项目自己的冻结判据 `FF-21g`（咀嚼次数 **MAE > 25%** 才降级），时域门限的 MAE 是 **5.6%**（0.61 次 / 基准 10.94 次），**离 25% 的降级线还有 4.5 倍余量**；不降噪的 `noisy` 是 2.0%。详见 `ADR-55` 与 `ai/reports/chew_preservation.md`。 |
| 下一步（按依赖顺序） | ① 排掉上面那颗包络雷（`crestRatio` 3.55）；② 写 **`SPEC-P-03` 修订案**（§1.2/§1.3/§5/§7/§9 + `PLAN-P-03`），把 `TdGateParams` 六个参数冻结进 SSOT 并同步 schema/生成常量；③ port 到 Kotlin，配**跨语言一致性测试**（Kotlin ↔ Python 逐样本对齐，`atol` 与现有 `preprocess_parity_test` 同规格）与 **hop 预算实测**（`SPEC-P-03` §8 至今欠着）；④ 补**真实噪声条件测试集**——现在 144 段全是近距安静录音，降噪的现场收益仍无法验收。 |
| 诚实边界 | ① **仍然全是 PC 上的仿真**：没有真机、没有 Android 实时耗时，也没有真实噪声条件下的录音。② 扫参用的是**小样本**（12 段干净 + 6 段噪音），足以定性地判定"这一族有解、且优于频域族"，**不足以标定最优参数**。③ 三个指标（噪音衰减 / 信号衰减 / 增益匹配 SSNR）都是**本轮定义的代理量**，不是冻结的验收判据。④ **出厂模型在干净音频上仍是 0.1667**，`ADR-53` 的前提在 `ADR-54` 里依然成立；上面的提升幅度是"从不如随机提升到略高于随机"，不得被表述为"识别可用了"。⑤ 我没有试过学习式降噪，也没有试过时域门限与谱减**串联**；这两条都还没有证据。 |

---

### ADR-55 ✅ 排掉 `ADR-54` 那处"包络雷"：**按项目自己的冻结判据 FF-21g，它不是缺陷 —— 是我的指标假警报**（MAE 5.6% vs 25% 降级线）

| 项 | 内容 |
|---|---|
| 来源 | 用户指示：「修复BUG就行」——即修 `ADR-54` 结尾标记的那处遗留风险。 |
| 结论 | **没有 BUG 需要修。** `ADR-54` 用 `crestRatio` 3.549 / `envCorr` 0.875 判定时域门限会伤行为分析，这个判定**建立在两个会误报的指标上**。改用项目**自己冻结的判据**去量，余量是 4.5 倍。 |
| 为什么 `crestRatio` 与 `envCorr` 会误报（两个独立的机制） | ① **`crestRatio` = 包络 p99.5 / 中位数。门限的全部工作就是把*安静段*压下去 —— 于是分母变小、比值必然升高**，哪怕峰值一个字节都没动。所以 `crestRatio` 变大**不是**峰变尖的证据，它是门限**按定义**的副作用。<br>② **`envCorr` 是逐点相关系数，对"脆响之间的底噪被压低"这种刻意改动一律扣分**，而咀嚼计数根本不看段间电平——它只看峰。用一个对电平敏感的相关性去判断一个以改电平为目的的模块，是把度量用错了地方。 |
| 🔴 **正确的判据（项目自己的，不是我定的）** | `SPEC-00` **FF-21g**：「咀嚼次数 MAE > **25%** → 文案降级」。这既是唯一被冻结的行为-域判据，也正好是门限真正会威胁的东西（若 MAE 超线，`U-02`/`U-03` 就必须放弃绝对数字）。 |
| 新增测量 | `tool/check_chew_preservation.py`：**复刻** `app/lib/domain/service/behavior_analyzer.dart` 的冻结判据（FF-21b/c/d），参数**全部从 `shared/feature_config.json` 读**（`chew_peak_threshold_k=0.5`、平滑 50 ms、最小峰距 200 ms、最大峰宽 150 ms、孤立峰 300 ms、包络 frame 10 ms / hop 5 ms / length 819），对干净 / 加噪 / 门限三段音频分别计咀嚼次数，用 MAE 与干净参考比对。 |
| 📊 实测（18 段，6 类各 3 段，10 dB 混合） | \| 变体 \| 平均咀嚼次数 \| MAE vs 干净 \| 占降级线 \|<br>\|---\|---\|---\|---\|<br>\| `clean` \| 10.94 \| — \| — \|<br>\| `noisy`（不降噪） \| 10.94 \| **0.22** \| **2.0%** \|<br>\| `gate_td`（`ADR-54` 选中配置） \| 10.67 \| **0.61** \| **5.6%** \|<br>\| `gate_td_slow`（attack 1 → 10 ms） \| 10.83 \| 0.56 \| 5.1% \|<br>**判读**：门限确实让 MAE 从 0.22 升到 0.61（2.8×），**方向与 `ADR-54` 的担心一致**；但绝对量 **5.6% 对比 25% 的降级线，余量 4.5 倍**，按项目自己的判据**不构成缺陷**。 |
| 为什么**不**顺手把 attack 改成 10 ms | `gate_td_slow` 只把 MAE 从 0.61 降到 0.56（8%），**却需要重跑 15 分钟的模型级验证**才能确认不损失识别收益（`ADR-54` 的 top1 0.2014 是这一族存在的理由）。**在一个已经合规的指标上做无验证的"顺手优化"，正是本项目反复吃过亏的那种改动。** 因此本轮**不改默认参数**，只把 `attack_ms` 记为有文档的依据杠杆（`ai/src/denoise_td.py` 的 `TdAttack`），等 `SPEC-P-03` 修订时一并定值与验证。 |
| 📌 **本轮真正该记住的教训** | `ADR-54` 里那句"下一轮应把 attack 放缓"**是我自己制造的假警报**：我用两个**会因模块定义而必然变化**的指标（peak/median、逐点相关）去判断一个**以改电平为目的**的模块，得出"有雷"的结论，还把它排进了下一轮首件事。**代理指标必须先说明它对什么不变**——`crestRatio` 对"门限压低底噪"不变，`envCorr` 对"段间电平改变"不变，两条都不满足。这与 `ADR-52` 的 `--limit` 截断（按类排序）是**同一类错误**：指标选错，结论就会反转。 |
| 本轮改动 | 新增 `tool/check_chew_preservation.py`；生成 `ai/reports/chew_preservation.md`；修正 `ADR-54` 中该行的表述（改为指回本 ADR）。**未改任何 Kotlin / Dart 代码，也未改时域门限的默认参数。** |
| 诚实边界 | ① 这个复刻件是**复刻**，不是权威实现——权威在 `behavior_analyzer.dart`（有自己的单测）。它的用处分级：**排名** clean/noisy/gated 并卡住 FF-21g 的量级，**不能替代 Dart 套件**。② 样本 18 段，足以判定"远在 25% 之内"，不足以给出精确的 MAE。③ FF-21g 原定要与**人工标注集**比对（`SPEC-P-07` §10 第 3 条说仓库里**还没有**标注集），本轮用的是"干净参考"代替人工标注——口径不同，**不能当作 FF-21g 正式验收**，只能当作门限是否引入行为风险的判据。 |

---

### ADR-56 ✅ **落实**：把时域瞬态保护门限真正装进 APP —— 参数冻结进 SSOT、Kotlin 实现 + 跨语言 golden 对齐、hop 预算首次出实测，并正式修订 `SPEC-P-03` 的范围

| 项 | 内容 |
|---|---|
| 来源 | 用户指示：「落实」。即 `ADR-52`~`ADR-55` 的离线结论必须变成**能装到手机上**的东西，而不是停在 Python 里。 |
| 修订的冻结条款（这是本轮最重要的一步） | `SPEC-P-03` §1.3 原本把「降噪模型、神经网络降噪、**Wiener 滤波**」整体列为**不做**，§9 又写「谱减法之外的任何降噪（神经降噪、Wiener、谱门限）：**不做**」。本轮把范围改成：**第 3 阶段允许「时域瞬态保护门限」**（新 FF-28），**默认仍然关闭**；同时把禁令**收紧并换理由**——逐频带/谱域降噪仍然不做，但依据不再是"没时间做"，而是 `ADR-52`/`ADR-53` 的**实测**（三档 SNR 上每一族都把识别压到还不如不降噪）。<br>新增 `SPEC-00` §3.12（FF-28/28a/28b/28c/28d），§1.4 记录两族对比表，§7 新增判据 14–17，§8 补上**从 v1.0 就欠着的**实时实测，§2.2/§2.4/§3/§5/§6/§9/§10 同步改写。 |
| 参数冻结（SPEC-C-03 传播） | SSOT 新增顶层块 `denoise`（**9 个数值**，不含任何文字说明——说明写在 SPEC 里）：`gate_frame_ms=5.0`、`gate_noise_window_ms=500.0`、`gate_noise_bias=1.5`、`gate_threshold_db=9.0`、`gate_knee_db=6.0`、`gate_max_attenuation_db=30.0`、`gate_lookahead_frames=4`、`gate_attack_ms=1.0`、`gate_release_ms=80.0`。schema 同步（`required` + 9 个 `properties` + `additionalProperties:false`），`jsonschema` 校验 **0 error**，生成器产出 `denoiseGate*` / `DENOISE_GATE_*`。取值即 `ADR-54` 在 864 组里按「信号衰减 ≤ 2 dB」预算选出的那一点。 |
| Kotlin 实现 | 新增 `app/.../audio/NoiseGate.kt`：包络 → 最小值统计（**滑窗边界显式写成 `[i-lo, i+hi]` 并夹紧**）→ 前瞻峰值保持 → dB 域软向下扩展 → attack/release 一阶平滑 → 帧率增益**插值**到逐样本。**无任何可变状态**，守住 `SPEC-P-03` 判据 6。接入 `Preprocess.apply` 的**第 3 阶段**（预加重之后，与冻结链路顺序一致）。 |
| 🔴 **一处必须先说的口径变化** | `Preprocess.kt` 原来在 `enableDenoise=true` 时**抛 `ACD-CFG-001`**，理由是「SSOT 里没有谱减参数」，而 `SPEC-P-03` §2.4 要求"不得静默降级"。**那个行为在当时是对的**。现在参数存在了，所以这一抛错**从契约里消失**——不是被绕过，而是**该情形在结构上不再可能**：参数由 SSOT 生成为编译期常量，缺一个键就编译不过。因此「不静默降级」由**生成器**保证，不再由运行时分支保证；`SPEC-P-03` §6 已按此改写。`PreprocessTest` 里那条 `denoise_withoutParameters_throwsACD_CFG_001` 随之被三条新断言取代（**注意这是删除一条既有断言**，不是让它继续通过）。 |
| 🔴 **修掉一个"必过而不验任何东西"的 golden** | 跨语言 golden 的**第一版是空转的**：我把 4 个瞬态排在相隔 **6 帧**处，而 `gate_lookahead_frames=4`（±4 帧）→ **每一帧都落在某个瞬态的前瞻窗内** → 门限全程全开 → golden **等于它的输入**（`max|y-x| = 0.000000`，2000 个样本里只有 137 个动了 1e-9 量级）。那样的奇偶校验**必然通过却什么都没验证**。<br>修法两条：① 输入改成两个相距 1440 样本的瞬态，留出前瞻保护不到的长段；② **生成器自带非空转自检**——`max|y-x| < 1e-3` 就直接拒绝生成并报 `ACD-ART-005`。改后 `max|expected-input| = 0.009`。 |
| 🔴 **修掉一个把预算放宽 4 倍的闸门** | 实时判据第一版写的是 `PATCH_SECONDS * 500.0` = **2048 ms**，把「一个 patch 的耗时」拿去和「四个 patch 的时间」比。改成从 SSOT 推导的 `FeatureConfig.INFERENCE_HOP_SECONDS * 1000` = **500 ms**（FF-12 的真实 deadline），**且不写成字面量**，这样 hop 改了闸门会跟着改。 |
| ✅ **`SPEC-P-03` §8 的实时预算首次出数（自 v1.0 欠账）** | JVM 实测：`enableDenoise = true` 时整链 **2.14 ms/patch**（门限本身 1.99 ms），对 **500 ms** 预算占 **0.43%**。`NoiseGateParityTest` 的 `preprocess_withGate_fitsTheHopBudget` 卡这条。<br>**注意口径**：这是 **JVM** 数字，ART/JIT 不同，**真机数字仍欠**——`SPEC-P-03` §8 已如实写明。 |
| ✅ **跨语言对齐实测** | `ai/src/denoise_td.py` 是规格，`NoiseGate.kt` 是移植。为此把 Python 侧的两个滑窗**从 scipy 改成显式实现**（`_sliding_min/_sliding_max`，窗口边界写进签名），因为**库函数的 origin/edge 语义是静默的奇偶校验陷阱**；先逐元素验证与 scipy **完全相同**（`0.000e+00`，含偶数窗 100 → `[i-50, i+49]`），因此 `ADR-54`/`ADR-55` 的既有数字全部无需重算（重跑咀嚼检查，仍是 0.22/0.61/0.56）。<br>golden 向量（`tool/gen_noise_gate_golden.py` → `NoiseGateGolden.kt`，2000 样本）对齐结果：**`max|diff| = 9.3e-10`**，atol `1e-6`。 |
| 其他新增闸门 | `NoiseGateParityTest`（13 项）：golden 对齐 + **非空转**；`slidingMin/slidingMax` 的**手算**窗口语义（奇窗、偶窗、夹紧、不改输入）；**只减不增**（逐样本 `\|out\| ≤ \|in\|`）；纯噪音衰减 **−12.12 dB**（第一代是 **+9.5 dB**）；阈值以上纯音最坏增益 ≤ 1.0；确定性；hop 预算。`PreprocessTest` 新增 3 项（门限确实改变信号 / 永不放大 / 确定性）。**JVM 套件 94 项全过。** |
| 本轮改动 | 新增 `ai/src/denoise_td.py` 的显式滑窗、`NoiseGate.kt`、`NoiseGateParityTest.kt`、`NoiseGateGolden.kt`（生成）、`tool/gen_noise_gate_golden.py`；改 `Preprocess.kt`（第 3 阶段）、`PreprocessTest.kt`、`JvmTestMain.kt`、`shared/feature_config.json`、`feature_config.schema.json`、生成的三份常量、`model_card.json`（SSOT 哈希）、`SPEC-00`、`SPEC-P-03`。 |
| ⚠️ 诚实边界 | ① **仍然没有真机**：2.14 ms 是 JVM 数字；APK 装到手机上是否正常、门限开与不开的现场对比，**都还没做**。② **开关默认仍是 `false`**（`SPEC-P-03` §1.3/§5 未改动），所以**这一轮装出来的包，默认行为与上一版逐位相同**——要看到门限效果必须显式打开 `enableDenoise`（当前只有 Demo/自检路径能传）。**"默认关闭"意味着用户装上去不会自动变好**，这是本轮必须说清的一条。③ 提升幅度仍是「从不如随机到略高于随机」（0.1215 → 0.2014，随机 0.1667），**不是"识别可用了"**。④ golden 只有 2000 样本（25 帧），噪声窗 100 帧在它上面是**被夹紧**的（不滑动）——滑窗的滑动语义靠 Kotlin 侧手算单测覆盖，而不是靠 golden；这是有意的分工，但要说清 golden 的覆盖面。 |

---

### ADR-57 ✅ 按用户指示把第 3 阶段门限**产品默认打开**：SSOT 一键可回退，且"打开"这件事本身是新增接线（此前**根本没有路径**能打开它）

| 项 | 内容 |
|---|---|
| 来源 | 用户指示：「打开就行，打包好APK」。 |
| 🔴 **先纠正 `ADR-56` 的一处错误陈述** | `ADR-56` 的诚实边界里我写「当前只有 Demo/自检路径能传 `enableDenoise`」。**这是错的。** 全仓检索 `enableDenoise` 的结果是：Dart 侧接口默认 `false`、`MethodChannelAudioBridge` 原样转发、`DetectionSession.start` **没有传**、Demo 路径也没传；`true` 只出现在 Kotlin 单测里。**也就是说成品包里门限永远不会执行，"显式打开"当时是不存在的操作。** 本轮把这条路径**新建**出来。 |
| 做法：产品默认值进 SSOT，不是写死 `true` | 新增 SSOT 键 `denoise.gate_enabled_by_default = true`（schema 同步 `required` + `properties`，共 11 键），生成 `denoiseGateEnabledByDefault` / `DENOISE_GATE_ENABLED_BY_DEFAULT`，在 `DetectionSession.start` 里传给 `bridge.startSession(enableDenoise: ...)`。<br>**为什么不写死 `true`**：① 决定要留在唯一真源里，而不是散落在领域层的一行；② **回退只需改一个值**，不需要改代码、不需要重新审阅逻辑。 |
| 🔴 **两个"默认值"必须分清（这是本轮最容易混淆的一点）** | **API 默认值**（`AudioBridge.startSession` 的 `enableDenoise = false`）**没有改**：未传参的调用者仍然拿到**逐位相同、不含门限**的 patch，所以 `SPEC-P-03` §7 判据 5 依然成立。<br>**产品默认值**（`denoise.gate_enabled_by_default`）现在是 `true`：**检测会话会主动开启**。<br>因此有一条推论必须写明：**"默认路径逐位不变"从此不再等于"成品包的默认行为"**——成品包现在就走门限。`SPEC-P-03` §1.3/§5/§7#5 已按这个区分改写。 |
| 这是一次**用户拍板**的范围修订 | `SPEC-P-03` 原文「降噪默认开启 \| **禁止**」是冻结条款，改它需要产品负责人同意。用户已明确要求，故记录为 `ADR-57`，并在 `SPEC-00` 增 `FF-28e`。**同时把风险如实写进 SPEC**，而不是只写结论（见下）。 |
| 新增闸门（**带负例对照**） | `tool/session_tests.dart` 新增 3 项：`ADR-57: the detection session asks the bridge for the noise gate`（`FakeAudioBridge.lastEnableDenoise == denoiseGateEnabledByDefault`）、`and the SSOT product default is ON`、以及一条"桥确实被调用过（否则上一条是空话）"。为此给 `FakeAudioBridge` 加了 `lastEnableDenoise` 记录字段。<br>**负例对照实测**：把 `DetectionSession.start` 里的 `enableDenoise:` 参数注释掉 → `SESSION: 149 passed, 1 failed`，`[FAIL] ... (actual=false expected=true)`。恢复后 **150/150 全过**。**这条断言不是装饰**：它会在有人删掉那行接线时立刻变红。 |
| ⚠️ **打开它的风险（必须与结论一起读）** | ① **没有任何真机数据**：门限的现场效果预测**有可能接近 0**，因为离线提升是在**近距安静语料 + 合成噪声**上测的（`test_mobile` 144 段没有噪声条件），而真实食堂噪声是**非平稳、有方向、有混响**的，混响尾巴会把脆响之间的包络抬起来、让门限在该关的时候不关。<br>② **衰减量本身就不是常数**：同一套参数下，真实噪声录音 **−16.2 dB** vs 白噪音 **−12.1 dB**，两种噪声之间就差 4 dB。我手上只有这两种，**外推到食堂不安全**。<br>③ 识别提升在统计上只是**勉强**：0.2014 对随机线 0.1667（n=576，95% 带 ±0.0304），分 SNR 每格（n=144，带 ±0.061）单独看**都不显著**。<br>④ **天花板是模型不是麦克风**：出厂模型在干净音频上就是 0.1667。0.20 仍不可用。<br>⑤ 风险下限较低：门限**只减不增**（机制上不可能放大），咀嚼计数 MAE 5.6% 对 25% 降级线有 4.5 倍余量。 |
| 回退方式（一行） | 把 `shared/feature_config.json` 的 `denoise.gate_enabled_by_default` 改回 `false`，重跑生成器并重打包。**无需改任何代码。** |
| 诚实边界 | 本轮**仍未做真机验证**；`enableDenoise` 的效果在手机上好不好，只有装了包、在真实噪声里录几段才知道。这也正是 `ADR-56` 建议的下一步（现场 A/B）。 |

---

## 5. 待同步清单（🟡 项的收敛）—— **已全部执行完毕**

> **执行日期 2026-09-10**。由 6 个并行协作者按「只改指定文件」的边界执行，逐文件回报前后对照；收尾由 `verify_docs.py` 机械校验。
> **结论：14 项全部完成，另在执行中追加了 4 项原清单遗漏的缺陷（#15–#18）。**

| # | 文档 | 需要的修改 | 依据 | 状态 |
|---|---|---|---|---|
| 1 | `SPEC-P-07`、`PLAN-P-07`、**`API-02`** | `BehaviorAnalyzer` 输入由 `feedPatch(Float32List pcm, …)` 改为 `feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs})`；补 `FakeEnvelopeSource` 以便无设备单测 | ADR-01 | ✅ |
| 2 | `SPEC-P-02`、`PLAN-P-02` | 明确本功能**同时产出** VAD 判定与 819 长度 RMS 包络，且与 P-07 共用同一分帧实现 | ADR-01 | ✅ |
| 3 | `SPEC-M-02` | 注入路径也必须产出包络；`startSession({skipAudioRecord:true})` | ADR-01、ADR-02 | ✅ |
| 4 | `SPEC-M-01`~`M-04` + 各自 PLAN | 现场处置表加「麦克风故障 → Mode B + `skipAudioRecord`」；自检项按 14 项对齐；`demoData` 项 | ADR-02、ADR-04 | ✅ |
| 5 | `SPEC-A-01` + `PLAN-A-01` | `regularity` 在 σ=30 的期望值改为 **20**（非 30）；`snack`/`lateNight` 算例按 A-2 新窗口重算 | ADR-05、ADR-09 | ✅ |
| 6 | `SPEC-A-03` + `PLAN-A-03` | 周报文案示例中的「下午零食」按新窗口重算 | ADR-09 | ✅ |
| 7 | `SPEC-U-01`、`SPEC-U-04`、`SPEC-U-06` + PLAN | `deltaVsYesterday == 0` 显示「持平」而非隐藏；`deltas` 恒 7 键 | ADR-10 | ✅ |
| 8 | `SPEC-U-06` §10 | 底栏结构由「开放问题」改为「已裁定：首页/检测/记录/报告 + 右上角我的」 | ADR-12 | ✅ |
| 9 | `SPEC-D-01` §10 | 删除「`docs/common/docs_api/schemas/*` 尚未落盘」的过期陈述（6 份 schema 已存在）；补演示状态双载体一致性断言 | ADR-10 | ✅ |
| 10 | `SPEC-D-03` | `days` / `week` 语义 / 窗口表 / §10 问题 1 关闭 | ADR-09、ADR-10 | ✅ **（首次执行不完整，见 §5.1 教训 3）** |
| 11 | `PLAN-D-03` | 工时 **5 h** → **11–12 h**（修订 A-1）；登记降级顺序 | ADR-06 | ✅ **（原写「8 h」，见 §5.1 教训 2）** |
| 12 | `PLAN-U-05` | `activeDays()` 就绪后「已坚持 N 天」由 `-- 天` 切换为真实值 | ADR-06 | ✅ |
| 13 | `SPEC-U-01`~`U-05` 的 §10 | 参考 `SPEC-M-04` 复核「自检面板不得成为第 5 个页面」（FF-23） | `SPEC-M-04` §10 | ✅ |
| 14 | `SPEC-C-03` §7 附表、`PLAN-C-03` | 变更传播单追加 A-1 / A-2 / ADR-05 / ADR-07 / ADR-09 五项（**表在 `SPEC-C-03` §7 附表，不在 `PLAN-C-03`——原清单写错了位置**），并重跑「全局命中数为 0」验收 | `SPEC-C-03` | ✅ |

### 5.1 执行中追加的 4 项遗漏（原清单没列，审计时才发现）

| # | 文档 | 问题 | 依据 | 状态 |
|---|---|---|---|---|
| **15** | `SPEC-U-02` §3 接口契约 | 仍写 `BehaviorAnalyzer.feedPatch()` —— 第 1 项只点了 `SPEC-P-07`/`PLAN-P-07`，**漏了消费侧页面** | ADR-01 | ✅ |
| **16** | `00_功能清单`、`common/README`、`API-00` §3.9、`API-06` | 「**9 项**变更单」—— 第 14 项加 5 行后变为 14 项，这 4 处数字成为旧口径 | 第 14 项 | ✅ |
| **17** | `PLAN-D-03` §1/§3.2 | 仍把 `week()` 的语义写作「**ISO 周**」/「周首为周一」 | ADR-10 | ✅ |
| **18** | `SPEC-D-03` §7 判据 2 | 时段边界**测试夹具仍是旧 8 个钟点**（`…15:59,16:00,22:59,23:00`），而 §4.1 已改 14 个 —— 即第 10 项**只改了规范、没改判据** | ADR-09 | ✅ |

### 5.2 执行中纠正的 3 处**我自己写错**的内容

| # | 我写错的 | 事实 | 处置 |
|---|---|---|---|
| 1 | §5 第 14 项说「在 `PLAN-C-03` 的变更传播单追加 5 行」 | 该表**物理位置在 `SPEC-C-03` §7 附表**；`PLAN-C-03` 只在 3 处**引用**它 | 已授权改 `SPEC-C-03`；`API-00` §3.9 与 `API-06` 也已改正指向 |
| 2 | ADR-06 与 `API-03` §11.1 都写「`PLAN-D-03` 由 **8 h** 调整为 11–12 h」 | `PLAN-D-03` 的**原工时是 5 h**，「8 h」是笔误 | 两处均已更正为 5 h，并保留勘误说明；冻结目标 11–12 h 不变 |
| 3 | §5 第 10 项标「✅ 已完成」 | `SPEC-D-03` §7 判据 2 的夹具**并未同步** | 已追加为第 18 项并修复；教训见下 |

### 5.3 本次同步留下的 6 条教训

1. **同步清单本身也要审计。** 原 14 项是人工列的，审计又查出 4 项遗漏（#15–#18）——其中 #16 是**连锁影响**（改了一个数字，另一个数字在别处过期）。**"改完"和"改全"是两件事。**
2. **"✅ 已完成"不能凭记忆写。** 第 10 项我标了完成，实际只改了规范没改判据。**判定完成必须回到文件里核对，而不是回忆"我改过那个文件"。**
3. **权威在谁手里要写对。** 第 14 项我把表的物理位置写错了（`PLAN-C-03` vs `SPEC-C-03`），导致协作者找不到目标。**引用"某张表"时必须写清它是哪份文件的哪一节。**
4. **并行改文档必须先划分文件所有权。** 本次有三轮出现"两个协作者被指派改同一批文件"，靠中途下发范围收缩消息才避免互相覆盖。**按文件（而非按议题）分配，是唯一安全的并行方式。**
5. **一轮审计不够 —— 每一轮都会查出新东西，而且性质不同。** 本次共 **4 轮**：
   | 轮次 | 查出什么 | 性质 |
   |---|---|---|
   | 1（交叉评审） | 19 条 | 文档之间**互相矛盾** |
   | 2（同步执行） | 4 条 + 3 处笔误 | 清单**自己不全**、我**自己写错** |
   | 3（措辞冻结） | 5 条 | 「未决」状态在 41 份文档里留下 111 处**陈旧措辞** |
   | 4（机械校验加检查） | 6 条 | 引用了**根本不存在的 schema / SSOT 键** |
   **结论：不能指望"审一次就干净"。** 每加一道**机械检查**都会立刻捞出上一轮看不见的一类问题 —— 所以**把发现固化成检查**比多审一轮更有价值（本次新增 4 类检查：功能位置 / schema 路径规范 / 悬空 schema / SSOT 键存在性）。
6. **"可选路径"是隐蔽的破坏源。** `SPEC-P-03` 曾把高通滤波器写成"默认关闭、裁定后启用"——这**看起来安全**（默认不开），但它让规范里长期存在一个**未冻结的参数**，且一旦启用就与 Python 侧不再逐位可比。`ADR-17` 的直接做法是**删掉它**：`未冻结的可选功能 = 一个随时会爆炸的依赖`。
4. **并行改文档必须先划分文件所有权。** 本次有两轮出现"两个协作者被指派改同一批文件"（U 域 §10 重叠、M 域 §5.2 重叠），靠下发范围收缩消息才避免互相覆盖。**按文件（而非按议题）分配，是唯一安全的并行方式。**

### 5.4 同步后的机械校验

```powershell
python D:\Desktop\Food\_toolchain\verify_docs.py     # 预期 BLOCKER × 0
```

> ⚠️ **`SPEC-C-03` §7 判据 3 的「旧值零残留」`rg` 命令当前无法达到 0 命中**，原因是 **`app/` 与 `ai/` 目录尚未创建**（还没写代码），且残留命中全部属于该判据自己已登记的假阳性（禁令条款、索引文档、schema 描述）。
> **这不是缺陷**：该命令本质是 **D5 之后的门禁**（代码与训练脚本出现后才可执行）。**首次真正执行应在 D5 联调通过后**，届时若命中不为 0 才算失败。

---

## 6. 本次交叉评审的统计

| 项 | 数量 |
|---|---|
| 交叉评审发现的冲突/缺陷 | **24**（19 条交叉评审 + 5 条后续审计新发现） |
| 已裁定并**已写入权威文档** | **18**（ADR-01~18） |
| 其中经**人工复核签字**（架构取舍类） | **6**（ADR-01/02/05/06/07/09，§2.1，结论均为采纳原裁定） |
| 其中**文档一致性问题**（有唯一正确答案，无需拍板） | **7**（ADR-03/04/08/10/11/12/13） |
| 其中**后续审计新发现** | **5**（ADR-14 `ambientNoise` 判据不可判定 / ADR-15 评分公式浮点求值顺序 / ADR-16 Mel·STFT 四个数值参数未冻结 / ADR-17 预处理残留高通与未定首样本约定 / **ADR-18 VAD 四个参数在 SSOT 中不存在**） |
| 仍需**人工拍板** | **0** —— `ADR-P1`~`ADR-P6` 已于 **2026-09-10 全部拍板**，见 §4 |
| 已裁定但需下游同步的文档 | **18 处**（§5 的 14 项 + §5.1 追加的 4 项）✅ 全部执行完毕 |
| 其中**会使功能不可实现**的阻断级缺陷 | **3**（ADR-01 P-07 无数据源 / ADR-02 Mode B 失效 / ADR-06 四处无数据源）✅ 已签字 |
| 其中**会使产品行为错误**的缺陷 | **2**（ADR-05 评分矛盾 / ADR-09 评分维度失效）✅ 已签字 |
| 其中**会使构建/校验失败**的缺陷 | **1**（ADR-07 schema `const`）✅ 已签字 |
| 其中**会使判据不可判定**的缺陷 | **1**（ADR-14 `ambientNoise`）✅ 已裁定 |
| 其中**会使两侧算出不同数字**的缺陷 | **1**（ADR-15 浮点求值顺序）✅ 已裁定 |
| 同步执行中发现**我自己写错**的内容 | **3**（表位置写错 / 工时基线写错 / 误标"已完成"），见 §5.2 |
| 拍板动作 | **6 项**（`ADR-P1`~`ADR-P6`）已于 2026-09-10 集中拍板并落地 |
| `feature_config` 补全 | 顶层 **31 → 41 键**（`behavior` **4 → 15 键**；新增 `meal_windows` / `health_score_formula` / 7 个音频数值键 / 4 个 VAD 键）；schema 与真实 JSON **双向差集为 0** |
| 其中因 ADR-16/17 新增的键 | **7 个**：`preemphasis_boundary` / `pad_mode` / `mel_htk` / `mel_norm` / `power_to_db_ref` / `loudness_normalization` / `target_lufs` |
| 因 ADR-17 **移除**的未冻结参数 | **3 个**：高通截止频率 / 高通阶数 / 推理侧 LUFS 口径 |

**一句话结论**：并行编写的 89 份文档在结构、数值与文案上**全部通过机械校验**（`verify_docs.py` BLOCKER × 0 / WARN × 0），但**单份文档自洽不等于规格集自洽** —— 上面 **21 条**只有并排比对才能发现，其中 **6 条属于"照文档实现会失败"的级别**，另有 **2 条在同步过程中才暴露**。**跨文档交叉评审不是可选项。**

**第二句话**：那 6 条里有相当一部分**不是"写错了"，而是"在几个可行方案里选一个"**（包络算在哪一侧、保命模式要不要动契约、评分以公式还是散文为准）。**这类裁定不该由文档编写者单方面决定** —— 它们先在 §2.1 单独抽出复核，其余 6 项（`ADR-P1`~`ADR-P6`）随后集中拍板。

**第三句话（同步阶段才学到的）**：**"改完"不等于"改全"。** 原 14 项同步清单是人工列的，执行中又查出 4 项遗漏（§5.1）与 3 处我自己的笔误（§5.2）——其中「表在 `SPEC-C-03` 还是 `PLAN-C-03`」这种错会直接让协作者**找不到目标**。**同步清单本身也需要一次审计，而且"完成"必须回文件核对，不能凭记忆勾选。**

**第四句话（拍板阶段才学到的）**：**"没拍板"这件事本身会被写进几十份文档里。** 一个未决的 `n_frames` 在 41 份文档里留下 111 处「待拍板」措辞 —— 拍板不只是改一个数字，而是**一次覆盖全库的措辞冻结**。这也是为什么「把决策和事实分开登记」比「让每个文档自己描述现状」更省事：**如果每份文档都复制了"当前状态"，那每次状态变化都要改一遍全库。**

---

## 7. 生效后的下一步 —— **无未决项**

| # | 动作 | 负责 | 依据 | 状态 |
|---|---|---|---|---|
| 1 | 执行 §5 的 **18 处下游同步**（含 §5.1 追加的 4 项） | A+B+C | §5 / §5.1 | ✅ **已完成**（2026-09-10） |
| 2 | 把 A-1/A-2/ADR-05/ADR-07/ADR-09 追加进**变更传播单**（表在 `SPEC-C-03` §7 附表），使其由 9 项变 14 项 | A+B | `SPEC-C-03` §7 | ✅ **已完成** |
| 3 | ~~拍板 `ADR-P1`（`n_frames`）~~ → **已拍板 129**，`feature_config` / 两份 schema / 全部文档已同步 | A | §4 / `SPEC-00` §3.5 | ✅ **已完成** |
| 4 | ~~拍板 `ADR-P2`~`ADR-P6`~~ → **6 项全部拍板并落地**（含 `feature_config` 补全，最终 **41 键**；另追加 `ADR-14`~`ADR-17`） | 全员 | §4 | ✅ **已完成** |
| 5 | 重跑 `python _toolchain/verify_docs.py`（预期 BLOCKER × 0） | 任一改动者 | `docs/README.md` §6 | ✅ **已通过** |
| 6 | 执行 `SPEC-C-03` §7 判据 3 的「旧值零残留」`rg` | A+B | `SPEC-C-03` §7 | ⏳ **D5 后**（`app/`、`ai/` 尚未创建，见 §5.4）—— 这是**时间顺序**而非未决项 |
| 7 | 竞赛材料用的**范围冻结具名签署件**（`ADR-P5` 的纸质栏） | 全员 | §4 ADR-P5 | ⏳ 行政件，**不阻塞开发** |
| 8 | 全量搜索并清除「待拍板 / 未决」旧表述，改为「已冻结（ADR-Px）」 | 任一改动者 | §4 | ✅ **已完成** |

> ✅ **关键路径已解除阻塞**：`ADR-P1` 拍板后，`T-04`（D2 训练）可以开工，`T-07`/`T-08` 不再顺延，CP1/CP2 的时间余量恢复。
> **本文件自此不再有 🔴/🟡 未决项**；剩下的两项是**时间顺序（D5 门禁）**与**行政件（纸质签字）**，都不影响任何开发活动。

---

**文档结束**

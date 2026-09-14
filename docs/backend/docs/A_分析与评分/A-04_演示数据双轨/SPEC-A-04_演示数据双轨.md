# SPEC-A-04 演示数据双轨

| 项 | 值 |
|---|---|
| 域 | A · 分析与评分 |
| 归属 | **B + C**（B 主责导入与清除，C 负责数据集构造与文案校验） |
| 状态 | ⚠️ 降级交付（`00_功能清单` §2 列 `A-04` 为三项降级之一） |
| 上游依据 | 主方案 §9.1（Demo C 报告数据双轨）、§3.8（已知缺口 D-1：`1.png` 85 vs `2.png` 82）、§3.4.1（UI 数据契约）、§6.1（隐私）；`SPEC-00 §3.3 FF-19`、`§3.6 FF-21e/FF-21f`、`§3.9 FF-24`、`§3.10 FF-25`；**`API-04 §6`（`DemoDataController` 语义权威）**、`API-03 §2/§4/§5`（`DietRecord`/`BehaviorMetrics`/`Repo` 冻结方法）、`API-05 §3/§5/§7`、`docs/common/docs_api/schemas/diet_record.schema.json` |
| 依赖的 SPEC | `SPEC-D-01`（`source` 列）、`SPEC-D-02`（事务与 DAO）、`SPEC-D-03`（按 `source` 过滤，**未成稿**）、`SPEC-A-01`/`A-02`/`A-03`（被验对象）、`SPEC-C-05`；下游 `SPEC-M-03`、`SPEC-M-04`、`SPEC-U-01`/`U-03`/`U-04`/`U-05`（标识落点） |

## 1. 目标与范围

### 1.1 一句话目标

用**真实累积（Track 1）+ 预置数据集（Track 2）**双轨保证 D9 演示时报告数据自洽：演示数据可一键加载、可一键清除，加载期间 **UI 明确标注为演示数据**，且**从当前生效数据集跑出的评分输出逐字段等于 UI 显示的数字**。

### 1.2 范围内（In Scope）

- **Track 1 执行口径**：D6 起全队每人每天用 App 真实检测 3–4 次（早/午/晚/零食），持续到 **D9 上午截止**；达标线见 A-04-K4。
- **Track 2 数据集**：`app/assets/demo_dataset.json`，约 7 天 × 3–4 餐 ≈ 25 条，每条含时间 / 食物 / 置信度 / 咀嚼次数 / 时长 / 速度评级（§4）。
- `DemoDataController{loadDemoDataset, clearDemoDataset, isDemoActive}`，语义**以 `API-04 §6` 为准**：`isDemoActive == true` ⇔ 库内存在 `source == 'demo'` 的记录。
- `source` 字段区分 `real` / `demo`（`API-03 §2.1` 已冻结该列），以及**演示数据标识**文案与状态。
- 统计口径隔离：演示模式生效时只统计 `source == 'demo'`，**真实记录不参与**、也**不被删除**。
- **核心验收**：单元测试从当前生效数据集跑评分引擎，断言输出逐字段等于 UI 显示的数字。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

- **不重算评分 / 建议 / 周报**：一致性验证的对象是 `SPEC-A-01`/`A-02`/`A-03` 的输出，本域只提供数据与开关。
- **不新增 `DietRepo` 方法**：清除只允许使用 `API-03 §4` 的冻结方法组合（`byRange` → 过滤 `source == 'demo'` → 逐条 `deleteById`）；如需新增须走 `API-00 §3.9` 变更流程（`API-04 §9` OQ-6）。
- **不落库展示字段**：`portionDesc` / `portionKcal` / `zhName` / `nutritionTags` / `riskNote` 一律不入表（`API-03 §2.4`），热量由 `KcalResolver` + 知识库在 L3 计算。
- 不做 CSV / 文件 / 网络导出（`X-03`；`FF-24` 第 4 条）。
- 不做手工改类别或改分数（`X-02`）。
- 不提供「隐藏演示标识」开关；不得把 Demo C 改成静态截图/录屏。
- 不改 UI 视觉设计（标识样式属 `U-06`，本域只冻结文案与状态判定）。

## 2. 功能行为

### 2.1 触发与前置条件

| # | 前置条件 | 来源 |
|---|---|---|
| 1 | `diet_record.source` 列存在且取值为 `'real'` / `'demo'` | `API-03 §2.1`（`SPEC-D-01`） |
| 2 | `demo_dataset.json` 已随 APK 打包在 `app/assets/`（`API-05 §7` 制品表） | 本 SPEC §4 |
| 3 | 写入一律经 `DietRepo.insertSession`（1 条记录 + 1 条指标行，**单事务**；`metrics == null` 时写占位行） | `API-03 §2.3`、`§4` |
| 4 | 入口存在：`U-05` 设置页「加载演示数据 / 清除演示数据」；`M-04` 降级面板同入口 | `SPEC-U-05`、`SPEC-M-04` |

### 2.2 主流程（编号步骤）

**A. `loadDemoDataset()`**

1. 读取并校验 `demo_dataset.json`（§4）：JSON 结构、条数区间（A-04-K1）、`dayOffset ∈ [0,6]`、`classLabel` 与 `classId` 在 FF-19 中**同序**、`confidence ∈ [0,1]`、`speedGrade` 与 `avgChewIntervalSeconds` 按 `FF-21e` 自洽；任一不符 → 抛 `ACD-DEMO-002`（`API-04 §6`）。
2. **先清后写（幂等，`API-04 §6`）**：先按步骤 B 的同一路径删除既有 `source == 'demo'` 行，再写入本次数据；因此重复调用不产生重复 `recordId`、不触发 `ACD-DB-002`。
3. 计算导入锚点：`anchorMs` = **导入当日的本地日历日 00:00**（A-04-K5）。这是本功能**唯一一次**读取系统时钟，且发生在导入期。
4. 物化时间戳：`eatenAtMs = anchorMs − dayOffset × 1 天 + HH:mm 偏移`（本地日历算术，不用毫秒相减，避免夏令时偏移）；`endedAtMs = eatenAtMs + durationSeconds × 1000`。
5. 逐条 `DietRepo.insertSession(record: source = 'demo', metrics: BehaviorMetrics(...))`；`chewCount` / `avgChewIntervalSeconds` 缺失时传 `null` → 写占位指标行（**不得缺行**，`API-03 §2.3`）。
6. 校验写入后自洽性（`API-04 §6`）：`eatenAtMs ≤ endedAtMs`；`endedAtMs − eatenAtMs` 与 `durationSeconds` 一致（容差 ≤ 1 s）。
7. 写入 `app_meta` 的三个演示键（`SPEC-D-01 §4.3`）：`demo_data_enabled = '1'`、`demo_dataset_id = <数据集标识>`、`demo_data_loaded_at_ms = <导入时刻 ms>`。
8. 任一步失败 → 已写入的 `demo` 行须回滚或清理干净（§6），**不得**留下半套数据。

**B. `clearDemoDataset()`**

1. 若库内无 `source == 'demo'` 记录 → 直接返回（幂等，不抛错）。
2. 用 `API-03 §4` 冻结方法组合删除：`byRange(全量区间)` → 过滤 `source == 'demo'` → 逐条 `deleteById(recordId)`（指标行级联删除）。
3. 置 `app_meta.demo_data_enabled = '0'`，并清空 `demo_dataset_id` / `demo_data_loaded_at_ms`（`SPEC-D-01 §4.3`）。
4. **绝不触碰 `source == 'real'` 的记录**，也不触碰 `user_profile`。

**C. 统计口径（对 A-01/A-02/A-03 的强制约定）**

- 库内存在 `source == 'demo'` 记录（`isDemoActive == true`）→ 所有分析、评分、建议、周报、趋势**只统计 `source == 'demo'`**。
- 否则只统计 `source == 'real'`。
- 两种口径**不混合**；混合会同时污染真实档案与演示数字。过滤由 `SPEC-D-03` 的聚合实现承担（`SPEC-A-03 §10` OQ-A03-1 同源）。

### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）

| 当前状态 | 动作 | 迁移后 | 库内效果 |
|---|---|---|---|
| `real`（无 demo 行） | `loadDemoDataset()` | `demo` | 写入 N 行 `source='demo'`；`real` 行数不变 |
| `demo` | `loadDemoDataset()` | `demo` | 先清后写：行数仍为 N，内容为本次数据集 |
| `demo` | `clearDemoDataset()` | `real` | 删除全部 `source='demo'` 行；`real` 行数不变 |
| `real` | `clearDemoDataset()` | `real` | **no-op**（不抛错） |
| 任意 | 校验失败 / 写入失败 | 原状态 | 无残留 demo 行（回滚或清理） |

`isDemoActive` **由数据本身承载**（是否存在 demo 行，`API-04 §6`）；getter 为**同步**，只读已缓存状态，不得在 getter 内发起查询（由 `load`/`clear` 或页面进入时刷新缓存）。**双载体一致性要求**：`app_meta.demo_data_enabled`（`SPEC-D-01 §4.3`，'0'/'1'）必须与「库内是否存在 demo 行」始终一致 —— 两个载体由同一对 `load`/`clear` 同时更新，任一不一致即视为缺陷（§7 #4 断言）。

### 2.4 边界条件

| # | 场景 | 处理（确定性） |
|---|---|---|
| 1 | 库内已有真实记录时加载演示数据 | 允许；真实记录保留且不参与演示统计 |
| 2 | 清除演示数据 | 只删 `demo`；真实记录与档案设置不受影响 |
| 3 | 重复点击加载 / 清除 | 幂等（先清后写 / no-op），无异常、无重复行 |
| 4 | 数据集缺字段、类别非法、`classId`/`classLabel` 不同序 | `ACD-DEMO-002`，不写入 |
| 5 | 数据集含**预计算分数**字段（如 `totalScore`） | 视为校验失败（消除已知缺口 D-1 的根因） |
| 6 | 条数 < 20 | 校验失败（A-04-K1 下限），不足以撑起 7 天报告 |
| 7 | 导入跨越时区变更 / 夏令时 | 用日历算术物化；同日导入结果按 §7 #5 断言可复现 |
| 8 | 数据集不存在（assets 缺失） | `ACD-DEMO-002`（`API-04 §6`/`§8`）；`ACD-IO-002` 亦为可能来源 |
| 9 | Track 1 真实累积 ≥ 达标线 | 默认用 Track 1；Track 2 仅在 Track 1 不足时启用（CP4 规定动作） |
| 10 | 演示行残留且用户未清除 | 标识常显 + 设置页常驻清除入口；`M-04` 自检项提示 |

## 3. 接口契约

> 只写与本功能直接相关的契约；完整签名以 `docs/*/docs_api/` 为准，此处给「本功能用到的部分」并标注 API 编号。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5 → L4 | `DemoDataController.loadDemoDataset` | — | `Future<void>` | `ACD-DEMO-002`、`ACD-DB-003`、`ACD-DB-004`、`ACD-IO-002` |
| L5 → L4 | `DemoDataController.clearDemoDataset` | — | `Future<void>` | `ACD-DB-003`、`ACD-DB-004` |
| L5 → L4 | `DemoDataController.isDemoActive` | — | `bool`（**同步** getter，读缓存） | — |
| L4 → 资产 | `AssetBundle.loadString('assets/demo_dataset.json')` | — | JSON 文本 | `ACD-DEMO-002` / `ACD-IO-002` |
| L4 → L3 | `DietRepo.byRange` / `deleteById` / `insertSession` | 见 `API-03 §4` | 行数 / void | `ACD-DB-002/003/004` |
| L4 → L3 | `MetaDao.get/put`（`app_meta` 演示键） | `demo_data_enabled` / `demo_dataset_id` / `demo_data_loaded_at_ms` | 值 | `ACD-DB-004` |
| L4 → L5 | 标识文案常量 `kDemoBannerText` | — | `String`（编译期常量） | — |

**权威归属**：`DemoDataController` 的语义、`isDemoActive` 定义、幂等要求与错误码以 `API-04 §6`/`§8` 为准；本 SPEC 只补充数据集契约、文案与验收。`loadReportDemo()`（`API-04 §7`）等价于「加载数据集 + 切到 reportOnly 模式」，属 `M-03`，不在本域实现。

## 4. 数据契约

> 涉及的字段、类型、单位、值域、可空性。引用 `docs/common/docs_api/schemas/` 中的 schema 文件名。

**文件**：`app/assets/demo_dataset.json`（`API-05 §7` 制品；建议同步产出 `docs/common/docs_api/schemas/demo_dataset.schema.json`，见 §10 OQ-A04-4）

| 字段 | 类型 | 值域 | 可空 | 说明 |
|---|---|---|---|---|
| `version` | `String` | `1.0.0` | 否 | 与 `SPEC-C-03` 制品版本口径一致 |
| `generatedAtMs` | `int` | epoch ms | 否 | 数据集生成时刻（仅记录，不参与计算） |
| `note` | `String` | ≤ 60 字 | 否 | 必须说明数据来源（自采回填 / 合成） |
| `records` | `List<DemoRecord>` | 20–30 条 | 否 | A-04-K1 |

**每条 `DemoRecord`（字段名与 `DietRecord`/`BehaviorMetrics` 对齐，`API-03 §2`）**

| 字段 | 类型 | 单位/值域 | 可空 | 落库映射 |
|---|---|---|---|---|
| `dayOffset` | `int` | 0–6 | 否 | 物化为 `eatenAtMs`（A-04-K5） |
| `timeLocal` | `String` | `HH:mm` | 否 | 同上；决定餐次窗归属（`API-03 §5`） |
| `classLabel` | `String` | `FF-19` 英文类名 | 否 | `DietRecord.classLabel` |
| `classId` | `int` | `[0,6)` | 否 | `DietRecord.classId`（必须与 `classLabel` 同序） |
| `confidence` | `double` | `[0,1]` | 否 | `DietRecord.confidence`（**不存百分比**） |
| `durationSeconds` | `int` | `>0` | 否 | `DietRecord.durationSeconds` = `BehaviorMetrics.durationSeconds` |
| `chewCount` | `int` | `>0` | 是 | `BehaviorMetrics.chewCount`（上屏文案必须带「约」，`FF-21f`） |
| `avgChewIntervalSeconds` | `double` | `>0` | 是 | `BehaviorMetrics.avgChewIntervalSeconds` |
| `speedGrade` | `String` | `偏快`/`正常`/`偏慢` | 是 | `BehaviorMetrics.speedGrade`；必须由 `FF-21e` 阈值重算验证 |

- **`attribute` 不入数据集**：由加载器在写入时从 `foods.json` 快照（`API-03 §2.1` 要求快照，理由：知识库更新后历史记录不得改口径）。
- **`source` 不入数据集**：由加载器固定写 `'demo'`（防止数据文件自述与实现不一致）。
- **禁止出现的字段**（出现即校验失败）：`totalScore`、`grade`、`regularity`、`structure`、`snack`、`speed`、`deltas`、`percent`、`portionKcal`、`portionDesc` 等任何预计算分数或展示字段（分数只能由 `SPEC-A-01` 运行时算出；展示字段不落库，`API-03 §2.4`）。

## 5. 参数与常量

> 逐项引用 SPEC-00 §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。

**FF / API 引用表**

| 引用 | 用途 |
|---|---|
| `FF-19` | 类别表与 4 类降级开关（`classLabel`/`classId` 合法值域与同序校验） |
| `FF-21e` | 速度评级阈值（校验 `speedGrade` 与 `avgChewIntervalSeconds` 自洽） |
| `FF-21f` | 咀嚼次数上屏必须带「约」 |
| `FF-25` | 热量只能以估算区间出现并标注「估算」；禁止宣传口径红线词 |
| `FF-24` | 演示数据同样不出设备：无上传、无导出、无网络 |
| `API-03 §2.1/§2.3/§2.4` | `source` 列与取值；占位指标行；不落库字段清单 |
| `API-03 §4` | 允许使用的 `DietRepo` 冻结方法（**不得新增**） |
| `API-05 §3` | 数据分类第 11 类「演示数据集：预置 JSON / assets，不出境」 |
| `API-05 §5` | 记录与行为指标必须同事务、不得缺行 |
| `API-05 §6.1` | 可复现：评分服务禁读当前时间（**导入器例外，见 A-04-K5**） |

**表 A-04-T1 本域新增常量（FF 未定义，待 A/B/C 确认，见 §10）**

| 编号 | 常量 | 取值 | 说明 |
|---|---|---|---|
| A-04-K1 | 数据集条数区间 | `[20, 30]` | 主方案 §9.1「7 天 × 3–4 餐 ≈ 25 条」；<20 不足以撑 7 天报告 |
| A-04-K2 | `dayOffset` 值域 | 0–6（共 7 天） | 与报告页 7 天趋势一致 |
| A-04-K3 | 演示标识文案 | `演示数据`（横幅/角标）；说明串：`当前展示的是预置演示数据，用于功能演示` | 逐字冻结；`U-01`/`U-03`/`U-04`/`U-05` 共用同一常量 |
| A-04-K4 | Track 1 达标线 | 真实累积记录 ≥ 20 条（D9 上午截止时判定） | 未达标 → 启用 Track 2（CP4 规定动作） |
| A-04-K5 | 导入锚点 | 导入当日的本地日历日 00:00 | 允许导入器读**一次**时钟；物化后固化入库，评分仍为纯函数 |
| A-04-K6 | 幂等语义 | 加载 = 先清后写；清除 = 无 demo 行时 no-op | 与 `API-04 §6` 一致 |
| A-04-K7 | 失败清理语义 | 写入中途失败 → 删除本次已写入的 `demo` 行后再抛错 | 保证「无半套数据」；不删除既有 `real` 行 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| assets 缺失 / 读取失败 | 读文件抛错 | 抛 `ACD-DEMO-002`（`ACD-IO-002` 亦可），不写库 | 提示「演示数据不可用」+ 重试入口 |
| 结构 / 自洽性校验失败 | 逐条校验 | 抛 `ACD-DEMO-002`，**零写入** | 提示校验失败（含首个失败原因） |
| 写入中途失败 | `ACD-DB-003` | 清理本次已写入的 `demo` 行（A-04-K7）后抛错 | 提示失败，可重试 |
| 重复加载 | 已有 demo 行 | 先清后写（幂等） | 无异常提示 |
| 重复清除 | 无 demo 行 | no-op，不抛错 | 无提示 |
| 演示数据残留（用户忘记清除） | 库内存在 demo 行且非演示场景 | 标识常显 + 设置页常驻清除入口 | 标识不可隐藏 |
| Track 1 不足 20 条 | D9 上午统计 | 启用 Track 2 | 正常演示 |
| 演示数据被当成真实档案 | 数据审查发现 `source` 混淆 | 视为缺陷：`source` 必须显式写入，**不得**依赖列默认值 | — |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 数据集结构、条数与字段完整 | `flutter test app/test/data/demo_dataset_schema_test.dart` → `Schema与条数` | 条数 ∈ [20,30]；§4 的 9 个字段全部存在且类型正确；`dayOffset` 覆盖 0–6 全部取值 |
| 2 | 无预计算分数 / 无展示字段 | 同上 → `禁止预计算与展示字段` | JSON 源文本对 `totalScore|grade|regularity|structure|deltas|percent|portionKcal|portionDesc` 命中数为 **0** |
| 3 | 类别与速度评级自洽 | 同上 → `类别同序与速度自洽` | 每条 `classId`/`classLabel` 在 FF-19 同序；每条 `speedGrade` 等于按 `FF-21e` 重算结果；`confidence ∈ [0,1]` |
| 4 | 加载幂等、数据隔离与双载体一致 | `flutter test app/test/data/demo_data_controller_test.dart` → `加载幂等与清除隔离` | 首次 load 后 demo 行数 == N；再次 load 行数仍为 N 且 `recordId` 不重复（`ACD-DB-002` 未触发）；clear 后 demo 行数 == 0 且 `real` 行数不变；再次 clear 不抛错；`isDemoActive` 与 `app_meta.demo_data_enabled` 在四种状态下逐状态一致 |
| 5 | 指标行 1:1 与占位行 | 同上 → `指标行一一对应` | 每条 demo 记录恰有 1 行 `behavior_metrics`；`chewCount` 为 `null` 的条目写入占位行（`chew_count IS NULL`），无孤儿行（对齐 `SPEC-C-05 §5` #11 `tx_atomicity_test.dart`） |
| 6 | 评分与导入锚点无关（可复现） | 同上 → `两次导入_分数逐字段相等` | 同一数据集以相差 1 天的锚点导入两次（各自对齐窗口），`totalScore` 与四维 `score` 逐字段相等 |
| 7 | 标识在四个页面可见 | `flutter test app/test/ui/demo_banner_widget_test.dart` | 库内存在 demo 行时 `U-01`/`U-03`/`U-04`/`U-05` 均 `find.text('演示数据')` 命中 ≥1；清除后命中数为 **0** |
| 8 | **核心验收（PLAN-C-05）**：引擎输出逐字段等于 UI 显示数字 | `flutter test app/test/domain/demo_track_consistency_test.dart`（`SPEC-C-05 §5` 表 #2 权威测试名） | 从**当前生效数据集**跑 `HealthScoreService` / `ReportService.weekly` / `AdviceEngine.generate`，三者的每个字段（总分、四维 `score/max`、`grade`、7 个 `deltas` 键、`summaryText` 数字、每条建议文案）与 UI presenter 输出**逐字段相等**，差异字段数 == 0；并同时与测试内**独立实现**的四维公式交叉验证相等（双重记账） |
| 9 | Track 1 达标判定可机器执行 | `docs/evidence/PLAN-A-04_Track1累积.md` + 一条聚合查询输出 | D9 上午统计 `source == 'real'` 且 `recordCount ≥ 20` → 用 Track 1；否则用 Track 2，判据与结论写入证据文件 |
| 10 | 无网络、无导出路径 | 静态检查 | `app/lib/demo/**.dart` 中 `http`/`dio`/`socket`/`url_launcher` 命中数各为 **0**；无文件导出调用 |
| 11 | 清除后无音频残留 | `flutter test` + 设备检查（复用 `D-05`） | 清除演示数据后 `cacheDir` 中匹配 `audio_*` / `*.wav` / `*.pcm` 的文件数为 **0** |
| 12 | 隐私确认留痕 | 人工核对清单（仅文案/流程） | 若数据集取自团队成员真实饮食，须有口头同意记录（主方案 §9.1）；`note` 字段说明数据来源 |

## 8. 非功能约束

> 性能 / 内存 / 功耗 / 隐私 / 无障碍，只写与本功能相关的。

- **性能**：导入 N 条 = N 次 `insertSession`（每次 1+1 行单事务）；清除 = 1 次 `byRange` + M 次 `deleteById`。两者耗时均属**实测产出**，本 SPEC 不预设数字。
- **存储**：按 `API-05 §5.8` 的单条预算，数据集规模对库容量的增量可忽略；不做分页/归档。
- **隐私**：演示数据同样只存本机、无上传、无导出（`FF-24`、`API-05 §3` R-OUT-1/2）；数据集不得含他人个人信息；真实累积数据用于公开演示前须取得团队成员口头同意。
- **可复现**：导入器是**唯一**允许读系统时钟的组件（A-04-K5），读取结果立即物化入库；此后所有评分/报告仍满足 `API-05 §6.1`。
- **无障碍**：演示标识必须是**文本**并带读屏语义，不得只用颜色或角标图形区分。

## 9. 裁剪与未做

> 显式列出本功能相关的 `X-*` 裁剪项与推迟项，避免实现方"顺手也做了"。

| 项 | 决定 |
|---|---|
| **本功能不可裁剪** | 它是 CP4/CP3 的规定兜底（`PLAN-00 §2` CP4「未通 → 启用预置演示数据集」），也是主方案 §8.2.1 第 ⑤ 项「三种 Demo 模式」的组成部分。**不得用静态截图/PDF/录屏替代真实数据链路。** |
| `X-02` 手动修正 | 不做。演示数据不允许手工改类别或改分。 |
| `X-03` CSV 导出 | 不做。演示数据不提供导出入口（入口置灰标「v1.1」）。 |
| `X-05` 检测页识别历史列表 | 不做。 |
| `X-07` 咀嚼节律 σ | 不做。数据集的 `speedGrade` 由 `FF-21e` 阈值判定，不含节律 σ。 |
| 推迟项 | 云端同步、多设备同步、账号体系（`X-01`）、LLM 健康助手一律**不做**（`00_功能清单` §5；`API-05 §9` `DISABLED`）。 |

## 10. 开放问题

> 本节只登记**仍开放**的事项；已冻结项不再列入（`FF-11` 的 `n_frames` 于 **2026-09-10** 由 `ADR-P1` 冻结为 ~~`129`~~ → **`ADR-21`（2026-09-12）已修订为 `n_frames = 128`**，`129` 现为 `raw_mel_frames`，故不再作为本节示例）。无则写「无」。

| 编号 | 问题 | 影响 | 谁拍板 / 截止 |
|---|---|---|---|
| OQ-A04-1 | **演示模式与真实记录会混合参与聚合**：`SPEC-D-03 §10` #2 已确认 `StatsRepo` 四个方法的冻结签名**没有 `source` 参数**，分流只能二选一：① 演示模式整体清库重载（会丢掉真实累积），② 走 `API-00 §3.9` 变更单加可选 `source` 参数 | 不支持则演示数据会污染真实档案分数（`SPEC-D-03` 建议方案 ②） | A + C（`SPEC-D-03`），**D7 前** |
| OQ-A04-2 | `API-04 §6` 要求「单事务批量写入」，但 `API-03 §4` 只有逐条 `insertSession`（每条各自事务） | 导入的非原子性只能靠 A-04-K7 的失败清理补偿 | B（`API-03`/`SPEC-D-02`），D7 前 |
| OQ-A04-3 | `SPEC-U-04 §6` 把「演示数据加载失败」记为 `ACD-DEMO-001`（示例音频缺失用码），而 `API-04 §6/§8` 将数据集失败定为 `ACD-DEMO-002` | UI 错误文案与测试断言不一致 | C（`SPEC-U-04`）+ 文档负责人，D8 前 |
| OQ-A04-4 | 是否需要产出 `docs/common/docs_api/schemas/demo_dataset.schema.json`（`API-05 §7` 只登记了 JSON 制品） | 决定校验方式：代码内校验 vs 机器可读 Schema | 文档负责人，D8 前 |
| OQ-A04-5 | 25 条数据集由谁构造、是「团队自采真实样本回填」还是「合成数据」 | 影响答辩可信度与 `note` 文案 | B 主 + C 校验，**D8 前** |
| OQ-A04-6 | Track 1 达标判定（A-04-K4）的执行时点与责任人（CP4 D7 晚 / CP3 D9 午之间） | 决定最终演示用哪条轨 | 全员，D8 站会定 |
| OQ-A04-7 | 演示标识的四个页面落点需写入 `SPEC-U-01`/`U-03`/`U-04`/`U-05`（`U-04` 已含该条，其余需确认） | 标识缺失即违反本 SPEC §7 #7 | C，D8 前 |
| OQ-A04-8 | 演示状态有**两个载体**：`API-04 §6`（库内存在 demo 行）与 `SPEC-D-01 §4.3`（`app_meta.demo_data_enabled`）。本 SPEC 要求两者并存且始终一致（§2.3、§7 #4）；若上游希望只留一个，须走 `API-00 §3.9` 变更 | 状态判定与自检面板实现方式 | B + 文档负责人，D7 前 |
| OQ-A04-9 | ✅ **已关闭（依据 `ADR-10`）**：`SPEC-D-01` §10 #4 的「schema 尚未落盘」已改为 **已关闭** —— 6 份 Schema 均已就位（`feature_config` / `diet_record` / `health_score` / `foods` / `metrics` / `sync_envelope`），收口方为 `SPEC-C-03` §4 与 `API-00` §4。**本 SPEC 引用的 schema 全部存在**，无需新增文件 | `demo_dataset.json` 的校验方式 | ✅ 已裁定（`ADR-10`），无需再签字 |

**文档结束**

# SPEC-M-03 Demo Mode C · 报告演示

| 项 | 值 |
|---|---|
| 域 | M · 演示与现场保障 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §9「Mode C · 报告展示」、§9.1 双轨准备、§9.2 现场执行 SOP、§8.2.1 第⑤项、§3.8 已知缺口 D-1；风险 R-10；**`API-04 §6`（`DemoDataController` 权威定义）、`§7`（`loadReportDemo`）与 `§7.1` 第 14 项 `demoData`（自检项权威清单共 14 项）**；`API-01 §2.3`（`skipAudioRecord`）、`API-03 §4`（`DietRecord.source`）；`API-05 §7`（演示数据集文件路径）；`SPEC-A-01`（`isDemoActive` 下的聚合口径）；`SPEC-00 §3.7 FF-22`、`§3.6 FF-21e/FF-21f`、`§3.9 FF-24` 第 7 条、`§3.10 FF-25`；ADR-01、ADR-02、ADR-04 |
| 依赖的 SPEC | `SPEC-A-01`、`SPEC-A-02`、`SPEC-A-03`、`SPEC-A-04`、`SPEC-D-01`、`SPEC-D-05`、`SPEC-U-01`、`SPEC-U-04`、`SPEC-U-05`、`SPEC-M-04` |

## 1. 目标与范围

### 1.1 一句话目标
用预置的 7 天历史数据驱动完整报告页（评分卡 + 四维雷达 + 7 天趋势 + 建议），保证屏幕上**每一个数字都可由「当前生效数据集」经评分引擎复算得出**，并明确标注为演示数据、可一键清除，作为演示兜底模式。

### 1.2 范围内（In Scope）
| # | 内容 |
|---|---|
| 1 | Track 2 预置数据集的载入 / 卸载编排：`DemoDataController.loadDemoDataset()` / `clearDemoDataset()` / `isDemoActive`（**权威定义在 `API-04 §6`**；数据集文件 `app/assets/demo_dataset.json`，`API-05 §7`） |
| 2 | Track 1（真实累积）与 Track 2（预置）的**优先级与互斥生效**规则 |
| 3 | 报告页数字自洽：**评分卡与雷达图数字 == 用当前生效数据集复算的结果**（消除主方案 §3.8 缺口 D-1 与风险 R-10） |
| 4 | UI 的「演示数据」标识（不可省略、不可弱化为小字脚注） |
| 5 | 一键清除**且只清除演示数据**（不动 Track 1 真实记录） |
| 6 | **现场执行 SOP 卡片的内容载体**（主方案 §9.2 六条）；演示讲解口径：首屏确认时机写 FF-20a，文案遵 FF-25 |

### 1.3 范围外（Out of Scope）——防止实现方自由发挥
| 不做 | 归属 |
|---|---|
| 评分公式与四维打分实现 | `SPEC-A-01`（FF-22） |
| 建议规则引擎与免责声明文案 | `SPEC-A-02` |
| 周报文案与趋势序列计算 | `SPEC-A-03` |
| 双轨数据集的底层实现与切换开关 | `SPEC-A-04` |
| 报告页视觉、图表组件 | `SPEC-U-04`、`SPEC-U-06` |
| 数据清除的底层实现（含 `cacheDir`） | `SPEC-D-05` |
| 伪造「真实使用 N 天」的叙事 | ❌ 禁止；演示数据必须可见地标注 |
| CSV 导出；成就解锁逻辑 | `X-03`：入口置灰标「v1.1」；`X-04`：仅静态展示 |

## 2. 功能行为

### 2.1 触发与前置条件
1. 入口：①设置 / 首页的「加载演示数据」按钮 ②`SPEC-M-04` 自检面板切 `DemoMode.reportOnly` ③CP4（D7 晚）未过时按主方案 §8.2.4 启用 Track 2。
2. 前置条件：`runSelfCheck()` 全通过（关键项为 `db`、**第 14 项 `demoData`（预置演示数据就绪，ADR-04）**、`session`，判定依据与 `hint` 以 `API-04 §7.1` 为准）；**无活跃检测会话**。
3. **Track 选择规则（主方案 §9.1）**：Track 1 真实累积优先；真实记录数不足（主方案 §9.1 的阈值）时启用 Track 2。**生效判定为 `DemoDataController.isDemoActive`（`API-04 §6`）**：`true` ⇔ 库内存在 `source == 'demo'` 的记录；聚合口径由 `SPEC-A-01` 限定为「仅 `source == 'demo'`」。

### 2.2 主流程（编号步骤）
1. `DemoController.loadReportDemo()` ≡ `DemoDataController.loadDemoDataset()` + `switchTo(DemoMode.reportOnly)`（`API-04 §7`）；本功能**不得**自行组合出第二套流程。
2. `loadDemoDataset()` 读 `app/assets/demo_dataset.json` → Schema 与自洽性校验 → 以 `source == 'demo'` **单事务批量**写入；校验失败 → `ACD-DEMO-002`。
3. 载入后**立即用同一数据集跑一次评分引擎**，把 `HealthScore` 与 `WeeklyReport` 写入 Provider 缓存；报告页与该缓存同源渲染。
4. 报告页渲染四块：①总分 + 评级 ②四维下钻（字段名见 §4）③四维雷达 ④7 天趋势 + 建议 + 免责声明。
5. 首屏顶部展示**「演示数据」标识**，报告页与雷达图区域各展示一次（共 ≥2 处）。
6. 用户点「清除演示数据」→ `clearDemoDataset()` → **只删除 `source == 'demo'` 的行**，真实累积数据一条不动 → 评分回落到真实数据结果。
7. 演示结束后按 SOP 卡片（§7 C10）执行现场纪律核对。
8. **演示数据就绪自检（ADR-04 第 14 项）**：进入 Mode C 前读 `runSelfCheck()` 结果中 `key == "demoData"` 的项；`passed == false` → 阻断并展示该项的 `observed` + `hint`（「改用实时模式」），**不得带病进入报告演示**。

### 2.3 状态与状态迁移
```
NONE ──loadDemoDataset()──▶ LOADING ──成功──▶ DEMO_ACTIVE
                             │                  │
                             │ 校验失败          │ clearDemoDataset()
                             ▼                  ▼
                     BLOCKED(ACD-DEMO-002)   CLEARING ──▶ NONE
REAL_ONLY ──真实记录不足（主方案 §9.1）──▶ DEMO_ACTIVE（loadDemoDataset）
```
| 迁移 | 触发 | 允许 |
|---|---|---|
| NONE → LOADING | `loadDemoDataset()` | ✅ |
| LOADING → DEMO_ACTIVE | 校验通过且事务提交成功 | ✅ |
| LOADING → BLOCKED | Schema / 自洽性校验失败 | ✅（`ACD-DEMO-002`） |
| DEMO_ACTIVE → CLEARING → NONE | `clearDemoDataset()` | ✅ |
| REAL_ONLY → DEMO_ACTIVE | 真实记录低于主方案 §9.1 阈值 | ✅ |
| **两轨同时参与聚合** | — | ❌ **禁止**（见 §2.4） |
| BLOCKED → DEMO_ACTIVE | 未修复即重试 | ❌ 必须重跑校验 |
| 会话运行中 → `reportOnly` | `switchTo` | ❌ `ACD-DEMO-003`（`API-04 §7.2`） |

### 2.4 边界条件
| 边界 | 行为 |
|---|---|
| **两轨混算** | **禁止**。混算会使「数字 == 复算结果」不成立。聚合**只按 `DietRecord.source` 单一过滤**：`isDemoActive == true` → 仅 `source == 'demo'`（`API-04 §6` + `SPEC-A-01`） |
| 演示数据集缺失 / 校验失败 | `ACD-DEMO-002`（`API-04 §8`）；不进入演示并展示明确原因 |
| 数据库事务失败 | `ACD-DB-003`（`API-03 §9`）；回滚并保持真实数据可读 |
| 重复点击加载 | `loadDemoDataset` 幂等（先清后写），**不得**产生重复 `recordId`（`API-04 §6`） |
| 一键清除误删真实数据 | 仅删 `source == 'demo'` 的行；断言 `source == 'real'` 行数在清除前后相等 |
| 清除后评分为空态 | 展示空态而非 0 分（0 分会被误读为「健康极差」） |
| 7 天跨度跨月 / 跨时区 | 日期分组按设备本地时区日历日（`API-00 §3.2`） |
| 进食速度 / 咀嚼次数文案 | MAE 降级线触发 → 按 FF-21g 改为「咀嚼节奏：较快」，**不给绝对数字**；未降级时必须带「约」（FF-21f） |

## 3. 接口契约
> `DemoController` / `DemoDataController` / `DemoMode` 的**权威定义在 `API-04 §6/§7`**，本节不复制签名（`SPEC-00 §5.2`）。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L5→L4 | `DemoController.loadReportDemo()` | 无 | `Future<void>` | `ACD-DEMO-002`、`ACD-DEMO-003`、`ACD-DB-003` |
| L5→L4 | `DemoController.switchTo(DemoMode.reportOnly)` | `DemoMode` | `Future<void>` | `ACD-DEMO-003`（数据集未加载 / 会话运行中） |
| L5→L4 | `DemoController.runSelfCheck()` | 无 | `Future<SelfCheckReport>` | 无（失败即 `allPassed=false`） |
| L4 内部 | `DemoDataController.loadDemoDataset()` | — | `Future<void>` | `ACD-DEMO-002`、`ACD-DB-003`、`ACD-DB-004`、`ACD-IO-002` |
| L4 内部 | `DemoDataController.clearDemoDataset()` | — | `Future<void>` | `ACD-DB-003` |
| L4 内部 | `DemoDataController.isDemoActive` | — | `bool`（同步 getter，只读缓存） | — |
| L4 内部 | `HealthScoreService` / `ReportService` | 按 `source` 过滤后的数据集 | `HealthScore` / `WeeklyReport` | `ACD-SCORE-001`、`ACD-DB-003/004` |
| L3→L4 | DAO 区间查询（`API-03 §4`） | 起止日（本地日历日） | 记录列表 | `ACD-DB-003/004` |
| L4→L1 | `getDiagnostics()`（`API-01 §2.8`） | `{}` | 含 `activeSessionId` | 无 |

## 4. 数据契约

| 字段 | 类型 | 值域 / 单位 | 可空 | 来源 |
|---|---|---|---|---|
| `HealthScore.totalScore` | `int` | 0–100 | 否 | FF-22 |
| 四项维度分 `regularity` / `structure` / `snack` / `speed` | `int` | 各自满分以 FF-22 为准（**本 SPEC 不复写数值**） | 否 | `SPEC-A-01` |
| `HealthScore.grade` | `enum` | FF-22 的三值评级 | 否 | FF-22 |
| `WeeklyReport.trend` | `List<DailyPoint>` | 7 个本地日历日 | 否 | `SPEC-A-03` |
| `WeeklyReport.advice` | `List<String>` | 文案列表，含免责声明 | 否 | `SPEC-A-02` |
| `DietRecord.source` | `enum` | `'real'` \| `'demo'` | 否 | **`API-03 §4` / `API-04 §6`**（演示记录必须为 `'demo'`） |
| `datasetVersion` | `String` | 语义化版本 | 否 | **本 SPEC 增补要求**（`API-04 §6` 未定义，见 §10） |
| 自检第 14 项 `demoData` | `SelfCheckItem` | `app/assets/demo_dataset.json` 可解析且标识与库内状态一致 | 否 | **`API-04 §7.1` 第 14 项**（ADR-04；判定依据与 `hint` 以该处为准） |
| 演示数据集条数 / Track 1 启用阈值 | `int` | 按主方案 §9.1；**本 SPEC 不复写数字** | 否 | 主方案 §9.1 / `SPEC-A-04` |

**schema 引用**：`docs/common/docs_api/schemas/`。`HealthScore` 与 `WeeklyReport` 的字段真源在 `API-04 §3/§5` 与 `SPEC-A-01`/`SPEC-A-03`；本 SPEC 只声明**报告页可见数字必须与它们同源**。

## 5. 参数与常量
| 编号 | 本功能的用途 |
|---|---|
| FF-22 | 四维评分公式、满分与评级枚举；**本功能不复制公式，只断言「UI 数字 == 复算结果」** |
| FF-21e / FF-21f / FF-21g | 速度三档文案；咀嚼次数必须带「约」；MAE 降级线触发时不展示绝对数字 |
| FF-19 | 食物结构维度涉及的类别口径 |
| FF-24 | 第 7 条「一键清除全部数据」；本功能额外要求「可只清演示数据」 |
| FF-25 | 文案红线：不得写「2 秒内出结果」，不得绝对化 |
| FF-20a | 现场讲解中「开始进食 → 确认结果」的唯一合法口径 |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 演示数据集缺失 / Schema 或自洽性校验失败 | `loadDemoDataset()` 抛 `ACD-DEMO-002` | 不载入，停在该模式 | 「演示数据集不可用」+ 原因 |
| **自检第 14 项 `demoData` 失败**（数据集不可解析，或标识与库内 `source='demo'` 状态不一致） | `SelfCheckReport` 中 `key == "demoData" && passed == false` | **不进入 Mode C**；先修数据集或先清除残留演示数据（`clearDemoDataset()`）使标识与库内状态一致 | 面板显示该失败项的 `observed` + `hint`「改用实时模式」 |
| 数据库不可用 / 载入事务失败 | 自检项 `db` 失败；`ACD-DB-003` | 回滚，保持真实数据可读 | 「本地存储不可用」+ 重试按钮 |
| 两轨同时参与聚合 | `isDemoActive` 与查询过滤不一致 | 立即中止渲染并报缺陷 | 「数据源冲突，请清除演示数据」 |
| UI 数字与复算不符 | C1/C2/C3 测试失败 | **阻断缺陷**：冻结 UI 修数据或修公式（风险 R-10 的处置） | 不进入现场演示 |
| 一键清除误删真实数据 | 清除前后 `source=='real'` 行数比对 | 回滚事务 | 无感（失败则提示） |
| 清除后评分为空态 | 无有效记录 | 展示空态（**不显示 0 分**） | 「暂无数据，先开始一次检测」 |
| 现场 Track 1 数据不足 | CP4（D7 晚）未过 | 启用 Track 2（主方案 §8.2.4） | 顶部出现「演示数据」标识 |

> 错误码取值域与 `API-04 §8` 一致，**本功能不新造错误码**；`ACD-DEMO-002` 仍待补登 `API-00 §3.5`（见 §10）。

**现场处置表（依据 ADR-02；与 `API-01 §2.3` 冻结口径逐字一致）**：

| 故障类型 | 处置 |
|---|---|
| 环境噪声大（>65 dB） | 切 **Mode B**（麦克风仍可用） |
| 麦克风被占用 / 硬件故障 / 权限被永久拒绝 | 切 **Mode B（`skipAudioRecord=true`）**；若仍失败则切 **Mode C** |
| 模型加载失败（`ACD-INF-001`） | 直接切 **Mode C**（Mode B 同样依赖推理引擎） |

> ⚠️ **Mode C 是上表唯一不依赖麦克风与推理引擎的终点**：本模式不打开 `AudioRecord`、不加载模型，只用预置数据集驱动报告页（§8）。因此前两行降级失败、第三行触发时，**Mode C 都会成为最终落点**；反过来说，Mode C 的成败**完全取决于自检第 14 项 `demoData`**（ADR-04）——它就是本条兜底路径的数据前置条件。第 3 行落在 Mode C 时，报告页必须展示「演示数据」标识（§2.2 第 5 步）。

## 7. 验收标准（可机器判定）
> **本功能是 CP3 的组成部分。** CP3（D9 午）的判据是「三种 Demo 模式全部可用」，本功能是其中 Mode C（兜底模式）的实测对象；同时承接 **CP4（D7 晚）未过时的兜底动作**（主方案 §8.2.4）。主方案 §8.2.4 规定 **CP3 未过时 Mode B + Mode C 必须可用**（详见 `PLAN-M-03 §7`）。

| # | 判据 | 验证方式（命令 / 测试名） | 通过阈值 |
|---|---|---|---|
| C1 | **评分卡数字 == 复算结果（核心）** | `flutter test test/demo/report_demo_consistency_test.dart --plain-name "scorecard matches preset dataset"` | UI 渲染的 `totalScore` 与四维分**逐字段等于**用同一数据集调用 `HealthScoreService` 的结果，且 `totalScore == 四维之和`（FF-22） |
| C2 | 雷达图与评分卡同源 | 同上 `--plain-name "radar uses same HealthScore instance"` | 雷达图 4 个数值 == 评分卡 4 个数值（同一对象，无第二次计算） |
| C3 | 7 天趋势 == 查询结果 | 同上 `--plain-name "weekly trend matches preset records"` | 7 个数据点逐点等于 SQL 聚合结果（`API-04 §5`） |
| C5 | 演示数据标识存在 | 同上 `--plain-name "demo data labelled"` | 至少 2 处「演示数据」标识可被 finder 命中 |
| C6 | 一键清除只清演示行 | 同上 `--plain-name "clear demo removes only demo rows"` | 清除后 `source=='demo'` 行数 == 0 **且** `source=='real'` 行数不变 |
| C7 | 禁止两轨混算 | 同上 `--plain-name "no mixed source aggregation"` | 聚合仅按单一 `source` 过滤；混算场景抛错 |
| C8 | 一键清除全部数据 | `flutter test test/data/clear_all_test.dart --plain-name "clear all removes every table"` | 全部业务表行数 == 0（FF-24 第 7 条，`SPEC-D-05`） |
| C9 | 文案红线零命中 | `pwsh -Command "Select-String -Path docs/**/*.md,app/lib/**/*.dart -Pattern '2\\s*秒|2\\s*s\\s*内'"` | 命中数 **0**（FF-25） |
| C10 | **SOP 卡片六条要点齐备** | `pwsh -Command "$p='docs/demo/现场SOP卡片.md'; @('30','飞行模式','65','备用','禁止.*改代码','脚本') \| ForEach-Object { if (-not (Select-String -Path $p -Pattern $_)) { exit 1 } }"` | 6 组关键词**每组 ≥1 命中**，退出码 0 |
| C11 | 报告页数据来源可追溯 | 同上 `--plain-name "report cites active dataset version"` | `datasetVersion` 与 `isDemoActive` 可在 UI/日志中读到，且与数据集文件一致 |
| C14 | **演示数据就绪自检项（ADR-04 第 14 项）** | `flutter test test/demo/self_check_test.dart --plain-name "demoData reflects library state"` | `items` 中存在 `key=="demoData"` 的项；数据集可解析且与库内 `source=='demo'` 状态一致时 `passed==true`；**不一致或不可解析时 `passed==false` 且 `hint` 非空（「改用实时模式」）**，`observed` 非空 |

**C12 现场逐项核对表（Mode C · 人工核对，仅限 UI 视觉与文案）**

| # | 核对项 | 通过判据 | ☐ |
|---|---|---|---|
| 1 | 「演示数据」标识醒目且非脚注 | 首屏可见 | ☐ |
| 2 | 点总分可下钻出四项明细 | 四项与 §4 字段一一对应 | ☐ |
| 3 | 雷达图 4 轴名称与评分卡一致 | 无营养素轴 | ☐ |
| 4 | 7 天趋势点数 == 7 | 无空点无断裂 | ☐ |
| 5 | 咀嚼次数文案带「约」 | FF-21f | ☐ |
| 6 | 有免责声明 | FF-25 / `SPEC-A-02` | ☐ |
| 7 | 一键清除后回到空态 | 误清真实数据则视为失败 | ☐ |

**C13 实测记录表**

| 字段 | 说明 |
|---|---|
| 记录产物路径 | `docs/demo/D9_三模式实测记录.md`（Mode C 段）+ 证据 `docs/demo/evidence/D9_modeC_*.log`（含 `isDemoActive`、`datasetVersion`、`source` 分布、复算结果快照） |
| 必填列 | 轮次 / 时间 / 生效 Track / 数据集版本 / 记录条数 / UI 总分 / 复算总分 / 差异 / 雷达四项是否一致 / 是否通过 |
| 轮次要求 | ≥2 轮（Track 2 一轮 + 清除后 Track 1 一轮）；**C1–C4 的差异列必须为 0** |

## 8. 非功能约束
| 类别 | 约束 |
|---|---|
| 性能 | 报告页查询与渲染的单次查询 < 20 ms（`API-00 §3.7`）；载入 7 天数据用**单个事务** |
| 隐私 | 演示数据为**构造数据**，不含任何真实受试者音频或身份信息；Track 1 若被展示，须先取得成员口头确认（主方案 §9.1，归 `SPEC-C-02`） |
| 无网络 | 演示数据全部本地，**运行时零网络**（FF-24 第 4 条） |
| 可清除性 | 一键清除全部数据（FF-24 第 7 条）+ 仅清除演示数据（本 SPEC 追加要求） |
| 文案 | 必须让观者明确区分演示与真实；讲解不得声称「我们用了 7 天」而实为预置数据 |
| 演示可靠性 | 本模式不依赖麦克风、不依赖模型，**是三种模式中可用性最高的兜底路径** |

## 9. 裁剪与未做
> **本功能不可裁剪。** 三种 Demo 模式是主方案 §8.2.1 五项「不可砍」之一（第⑤项）；主方案 §8.2.4 进一步规定：**CP3 未过时 Mode B + Mode C 必须可用**——Mode C 是最后一道防线。

| 项 | 状态 |
|---|---|
| `X-03` CSV 导出 | ❌ 不做；入口置灰标「v1.1」（FF-25 口径） |
| `X-04` 成就解锁系统 | ❌ 不做；「已坚持 N 天」仅静态展示，**天数取 `API-03 §5` 的 `StatsRepo.activeDays()` 口径**（ADR-06 修订 A-1，见 §10 开放问题 3） |
| `X-05` 检测页识别历史列表 | ❌ 不做 |
| 演示数据的「真实感」包装 | ❌ 不做；标识必须显眼 |
| 演示数据集的可视化编辑器 | ❌ 不做；数据集以静态文件随包发布 |

## 10. 开放问题
1. **`ACD-DEMO-002` 尚未生效**：`API-04 §8` 已定义该码（演示数据集缺失 / 字段校验或自洽性校验失败），但其尾注明确「须先补登 `API-00 §3.5` 才生效」。本 SPEC 已按新码撰写，**补登动作须在 D9 前完成**。
2. **`datasetVersion` 未被 `API-04 §6` 定义**：本 SPEC 追加要求记录数据集版本以支撑 C11 的可追溯性，需要 `DemoDataController` 暴露版本字段或由数据集文件自带。**须 A/B 拍板并回写 `API-04 §6`。**
3. ✅ **已关闭（依据 ADR-06 修订 A-1）** 原开放问题「『已坚持 N 天』（`X-04` 静态成就）与演示数据的天数口径冲突」。**结论**：天数**取 `API-03 §5` 的 `StatsRepo.activeDays()` 口径**——库内**存在至少一条记录**的设备本地日历日数量，**跨全部历史，不分 `real` / `demo`**；它是唯一数据源，**UI / 页面不得自行扫表，也不得自行改口径**。`PLAN-D-03` 就绪前显示 `已坚持 -- 天`，**就绪后（D8）切真实值**（`PLAN-U-05`）。因此原诉求「**演示模式下天数同步切换或标注**」**作废**——「已坚持 N 天」不因加载演示数据而虚增这一顾虑，**不是页面要判断的事**，而是由 `activeDays()` 的口径定义决定的。
   > 本项与自检第 14 项 `demoData`（ADR-04）**是两件事**：`demoData` 判「预置演示数据是否就绪（文件可解析且标识与库内状态一致）」，本项判「『已坚持 N 天』的数值从哪里取」。二者不得互相替代。
4. **数据集文件与条数**：文件名 `app/assets/demo_dataset.json` 由 `API-05 §7` 冻结；**条目数未冻结**（`API-04 §9` 开放问题 5 明确留给 `SPEC-A-04`）。Track 1 → Track 2 的启用阈值是常量还是可配置项亦未定（若可配置须登记 `feature_config`，`SPEC-C-03`）。**需在 D8 前落定**，否则 CP4 的兜底无数据可用。
5. ✅ **已关闭（依据 ADR-04）** 原开放问题「Mode C 的就绪判定无权威自检项」：`API-04 §7.1` 已把自检清单由 9 项冻结为 **14 项**，其中**第 14 项 `demoData`（预置演示数据就绪）**就是本模式的数据前置条件（判定依据：`app/assets/demo_dataset.json` 可解析且标识与库内状态一致）。**结论**：本模式**不另立就绪判据**，一律读自检第 14 项；`allPassed` ⇔ 14 项全部 `passed == true`，`observed` 不得为空字符串，`hint` 仅失败项必须给出可执行动作。

**文档结束**

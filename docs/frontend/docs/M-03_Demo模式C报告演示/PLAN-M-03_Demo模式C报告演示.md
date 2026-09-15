# PLAN-M-03 Demo Mode C · 报告演示

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-M-03` |
| 负责 | **C 主责**（数据集构造、报告页数字自洽、SOP 卡片、现场演练）；B 协助（`A-04` 双轨实现、清除事务）；A 支撑（评分引擎复算口径） |
| 目标日 | **D9**（数据集与自洽测试在 D8 完成，D9 实测与演练） |
| 前置依赖 | `PLAN-A-01`（评分卡）、`PLAN-A-03`（周报）、`PLAN-A-04`（双轨双数据集）、`PLAN-D-05`（清除）、`PLAN-U-04`（报告页）、`PLAN-M-04`（自检第 14 项 `demoData` 的权威定义） |
| 预估工时 | **4 h**（C 2.5 h ｜ B 1 h ｜ A 0.5 h） |

## 1. 交付物（Deliverables）
| # | 产物 | 说明 |
|---|---|---|
| 1 | `app/assets/demo_dataset.json` | Track 2 预置数据集（路径由 `API-05 §7` 冻结）：7 天记录 + `datasetVersion`（条数按主方案 §9.1） |
| 2 | `app/lib/features/demo/demo_data_loader.dart` | `DemoDataController.loadDemoDataset()` / `clearDemoDataset()` / `isDemoActive` 的调用编排（`API-04 §6`） |
| 3 | `app/test/demo/report_demo_consistency_test.dart` | SPEC §7 的 C1–C7、C11 |
| 4 | `records/demo/现场SOP卡片.md` | **主方案 §9.2 六条 SOP 的现场可打印卡片**（内容载体） |
| 5 | `records/demo/演示脚本_D9.md` | 0–1 min 痛点 / 1–5 min 核心 Demo / 5–8 min 健康分析 / 8–10 min 技术的分镜 |
| 6 | `records/demo/演示数据集说明.md` | 数据集人可读说明（每条的构造依据、来源、`datasetVersion`） |
| 7 | `records/demo/D9_三模式实测记录.md` | Mode C 段；含 SPEC §7 C13 记录表 |
| 8 | `records/demo/evidence/D9_modeC_*.log` | `isDemoActive` / `datasetVersion` / `source` 分布 / UI 总分与复算总分快照 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 构造 Track 2 数据集（7 天、条数按主方案 §9.1，四维分布覆盖良好/一般两档） | 交付物 1、6 | 0.75 h（C） | `PLAN-A-01` 公式冻结 |
| 2 | `DietRecord.source` 与查询过滤落地（`'real'` / `'demo'` 互斥，禁止混算） | 交付物 2 | 1.0 h（B） | 任务 1；`PLAN-A-04`、`API-03 §4` |
| 3 | 载入 / 清除事务编排与空态处理 | 交付物 2 | 0.5 h（B） | 任务 2 |
| 4 | 「演示数据」标识落位（首屏 + 报告页 ≥2 处） | SPEC §7 C5 | 0.25 h（C） | 任务 3、`PLAN-U-04` |
| 5 | 自洽测试 C1–C3、C5、C7、C11（UI 数字 vs 复算）；**C14 演示数据就绪自检项** | 交付物 3 | 0.5 h（C + A） | 任务 3、4；`PLAN-M-04`；ADR-04 |
| 6 | 清除范围测试 C6、C8 | 交付物 3 | 0.25 h（C） | 任务 3 |
| 7 | 写 `records/demo/现场SOP卡片.md`（六条）+ 分镜脚本 | 交付物 4、5 | 0.5 h（C） | 主方案 §9.2 |
| 8 | 真机 2 轮实测 + 记录表 + 证据（C12/C13） | 交付物 7、8 | 0.25 h（C） | 任务 6、7 |

## 3. 技术方案
> 与 `SPEC-M-03 §2.2/§3` 契约一致；**不在报告页做任何二次计算**。骨架 ≤30 行。

```dart
Future<void> loadReportDemo() async {                     // API-04 §7 冻结的等价关系
  final r = await runSelfCheck();
  if (!r.allPassed) throw _blockingError(r);              // 复用既有错误码
  final demo = _demo;                                     // DemoDataController, API-04 §6
  if (!demo.isDemoActive) await demo.loadDemoDataset();   // 单事务写入；失败回滚
  final records = await _repo.recordsInRange(             // 只按 source 单一过滤
      _last7LocalDays(), source: demo.isDemoActive ? 'demo' : 'real');
  final score  = _scoreService.score(records);            // 唯一一次计算
  final report = _reportService.weekly(records);
  _providers.score.state  = score;                        // 评分卡与雷达同源
  _providers.report.state = report;                       // 趋势与建议同源
  // 禁止：UI 层任何形式的独立求和 / 独立取整 / 硬编码示例数字
}

Future<void> switchTo(DemoMode m) async {
  if (_activeSessionId != null) throw _err('ACD-DEMO-003'); // API-04 §7.2：不得乐观切换
  await _assertPrereq(m);                                   // reportOnly 需演示数据集已加载
  _mode = m;
}
```

**关键实现约定**
1. 报告页**只渲染** `HealthScore` / `WeeklyReport`，禁止出现字面量分数（这是 D-1 缺口的根因）。
2. 载入 / 清除必须单事务；一旦失败必须回滚且保持真实数据可读。
3. 聚合**只按 `DietRecord.source` 单一过滤**（`isDemoActive == true` → 仅 `'demo'`），**禁止两轨混算**（`API-04 §6` + `SPEC-A-01`）。
4. 标识文案与 `isDemoActive` 绑定，禁止只在某一种入口显示。
5. 清除演示数据**不得**触碰 `'real'` 行；清除全部数据走 `SPEC-D-05` 的路径。
6. **演示数据就绪自检（ADR-04 第 14 项 `demoData`）是本模式的硬前置**（`SPEC-M-03 §2.2` 第 8 步）：切 `reportOnly` 前先读 `SelfCheckReport` 中 `key == "demoData"` 的项，`passed == false` 即阻断并展示 `observed` + `hint`。若失败原因是「库内残留演示数据与数据集标识不一致」，先用 `clearDemoDataset()` 清空后重试，**不得跳过自检直接渲染报告页**。
7. 报告页可见数字的诊断来源固定为 `API-01 §2.8` 的 `getDiagnostics()`（`activeSessionId`、`sessionState`），**不得**由 UI 自行推算会话状态。

**`records/demo/现场SOP卡片.md` 必含六条**（主方案 §9.2，逐条对应、缺一即 C10 失败）：
①提前 **30** 分钟到场实测完整流程；②手机开**飞行模式**（隐私设计保证不需要网络）；③环境噪声 >**65**dB 直接走 Mode B；④准备**备用**手机（型号不同更好）；⑤现场**禁止临时改代码**；⑥按**脚本**分镜演示（0–1/1–5/5–8/8–10 min）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `report_demo_consistency_test.dart --plain-name "scorecard matches preset dataset"` | 单元 | UI 数字逐字段 == 复算结果；总分 == 四维之和（FF-22） | 每次提交 + D9 |
| `--plain-name "radar uses same HealthScore instance"` | Widget | 雷达 4 值 == 评分卡 4 值 | 每次提交 |
| `--plain-name "weekly trend matches preset records"` | 单元 | 7 点逐点等于 SQL 聚合 | 每次提交 |
| `--plain-name "demo data labelled"` | Widget | 「演示数据」标识 ≥2 处 | 每次提交 |
| `--plain-name "clear demo removes only demo rows"` | 单元 | `source=='demo'` 行 0 且 `'real'` 行不变 | 每次提交 |
| `--plain-name "no mixed source aggregation"` | 单元 | 聚合仅按单一 `source` 过滤；混算抛错 | 每次提交 |
| `--plain-name "report cites active dataset version"` | 单元 | `datasetVersion` / `isDemoActive` 与数据集一致 | 每次提交 |
| `self_check_test.dart --plain-name "demoData reflects library state"`（C14） | 单元 | 第 14 项 `demoData` 存在；数据集与库内状态一致时通过，否则 `passed==false` 且 `hint` 非空 | 每次提交 |
| `clear_all_test.dart --plain-name "clear all removes every table"` | 单元 | 全表行数 0（FF-24 第 7 条） | 每次提交 |
| SOP 卡片关键词扫描（SPEC §7 C10） | 脚本 | 6 组关键词每组 ≥1 命中 | D8 末 + D9 前 |
| 文案红线扫描（C9） | 静态 | 命中数 0 | D9 前 |
| 真机 2 轮实测（C12/C13） | 人工核对表 + 记录表 | 差异列全 0 | **D9 上午** |

## 5. 完成定义（DoD）
- [ ] `SPEC-M-03 §7` 的 **C1–C3、C5–C11、C14 全部判据通过**（测试全绿 / 脚本退出码 0）。
- [ ] **C1–C3 的「差异」列在真机上实测为 0**，结果写入 `records/demo/D9_三模式实测记录.md`（标注「D9 实测产出」）。
- [ ] `records/demo/现场SOP卡片.md` 六条齐备、可打印、现场已实际携带（C10 通过）。
- [ ] `records/demo/演示脚本_D9.md` 四个时段分镜完成，且首屏确认时机口径为 FF-20a。
- [ ] C12 现场核对表 7 项 100% 勾选并签字；C13 记录表 ≥2 轮无空列。
- [ ] `SPEC-M-03 §10` 开放问题 1（`ACD-DEMO-002` 补登 `API-00 §3.5`）、2（`datasetVersion` 回写 `API-04 §6`）、4（数据集条数与阈值口径）已闭环；**开放问题 3 已按 ADR-06 修订 A-1 关闭**——「已坚持 N 天」取 `StatsRepo.activeDays()` 口径（跨全部历史、不分 real/demo），原「演示模式下天数同步切换或标注」诉求作废；**开放问题 5 已按 ADR-04 关闭**——本模式的就绪判据统一读自检第 14 项 `demoData`（C14 通过）。
- [ ] 代码与数据集合入 D8 节点分支；D9 之后仅允许改数据集文案，**不允许改评分或报告逻辑**。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **预置数据与评分卡数字不一致**（R-10） | C1–C3 任一失败 | **阻断缺陷**：冻结 UI，修数据集或修公式；禁止调整测试阈值（主方案 §9.1 的处置） |
| Track 1 数据不足（低于主方案 §9.1 阈值） | CP4（D7 晚）实测 | 启用 Track 2（主方案 §8.2.4）；顶部标识必须出现 |
| 两轨数据同时参与聚合 | `isDemoActive` 与查询过滤不一致 | 立即停止渲染，人工清除演示数据，复查 `source` 过滤 |
| 一键清除误删真实数据 | C6 失败 | 回滚事务并在 D9 前修复；修复前**禁止现场点清除** |
| `ACD-DEMO-002` 未补登 `API-00 §3.5` | `API-04 §8` 尾注未闭环 | 现场错误码暂以 `API-04 §8` 为据；**D9 前必须补登** |
| `datasetVersion` 未被 `API-04 §6` 定义（开放问题 2） | `DemoDataController` 无版本字段 | 临时由数据集文件自带版本号并在日志中打印；**须在 SPEC §10 登记为技术债与回写任务** |
| 数据集来源被质疑（伦理） | 评委追问 | 主动说明为**构造的演示数据集**（不声称真实使用天数）；Track 1 展示前取得成员口头确认（主方案 §9.1） |
| 「已坚持 N 天」被质疑随演示数据变化 | 评委追问天数来源 | **口径由 `API-03 §5` 的 `StatsRepo.activeDays()` 定义，不由页面判断**（ADR-06 修订 A-1）：统计库内存在至少一条记录的本地日历日，**跨全部历史、不分 `real`/`demo`**；页面只渲染该值，**禁止**自行扫表或改口径。`PLAN-D-03` 就绪前显示 `已坚持 -- 天`，就绪后（D8）切真实值（`PLAN-U-05`） |
| 演示数据就绪自检未通过（第 14 项 `demoData`，ADR-04） | `demoData.passed == false` | **不得带病演示**：先按 `observed`/`hint` 修数据集或清残留演示数据（`clearDemoDataset()`）后重跑自检；仍失败则现场按 `SPEC-M-03 §6` 现场处置表回落 Mode A/B |
| 现场临时改代码 | D9/D10 有人提交 | SOP 第 5 条禁止；改代码即视为放弃本次实测结果 |

## 7. 与检查点的关系
> **本功能是 CP3 的组成部分。**

| 项 | 内容 |
|---|---|
| 涉及检查点 | **CP3（D9 午）**：判据「三种 Demo 模式全部可用」；同时承接 **CP4（D7 晚）** 的兜底动作 |
| 本功能的 CP3 判据 | 报告页可在 Track 2 一键盘演示，UI 全部数字与复算一致（C1–C4 差异为 0），且演示标识存在、可一键清除 |
| 与 CP4 的关系 | CP4 未过（报告页未接通真实记录）→ 按主方案 §8.2.4 **启用预置演示数据集**，本功能即为该兜底路径；CP4 通过时本功能仍需可用（答辩与演练用途） |
| CP3 未过时的处置 | `PLAN-00 §2`：停止一切新功能，3 人扑 Demo 稳定性；主方案 §8.2.4：**Mode B + Mode C 必须可用**——本功能不退让 |
| 与其他 PLAN 的耦合 | 依赖 `PLAN-A-04` 的双轨实现与 `PLAN-A-01` 的评分公式冻结（D1 接口先行）；报告页视觉归 `PLAN-U-04`；本 PLAN 只负责「数据 → 数字自洽 → 现场可用」 |

**文档结束**

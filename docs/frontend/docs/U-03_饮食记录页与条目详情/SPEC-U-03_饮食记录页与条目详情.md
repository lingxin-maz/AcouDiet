# SPEC-U-03 饮食记录页与条目详情

| 项 | 值 |
|---|---|
| 域 | `U` · 界面 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1（含记录条目标准模板）§3.4.2 §8.2；`docs/00_功能清单与数量分析.md` §2 域 U / §3 / §6；`SPEC-00` §3.3 FF-19、§3.6 FF-21、§3.9 FF-24、§3.10 FF-25 |
| 依赖的 SPEC | `SPEC-U-06`、`SPEC-D-01`、`SPEC-D-02`、`SPEC-D-03`、`SPEC-A-03`、`SPEC-P-07`、`SPEC-P-08` |

## 1. 目标与范围
### 1.1 一句话目标
以时间轴形态呈现全部饮食记录（按日期分组），顶部给出今日汇总，条目严格按冻结的标准模板渲染，点击条目进入**衍生详情页**查看置信度、进食时长、咀嚼次数、食物属性与当次行为分析。

### 1.2 范围内（In Scope）
| # | 元素 | 说明 |
|---|---|---|
| 1 | 顶部汇总条 | `今日总热量 / 已记录次数 / 零食次数` |
| 2 | 时间轴 | 按日期分组（今天 / 昨天 / M月d日），组内按 `eatenAtMs` 倒序 |
| 3 | 条目卡片 | 严格按 §4.2 的标准模板三行布局 |
| 4 | 本周小结卡片 | `A-03` 的 `summaryText`（一句话） |
| 5 | 条目详情页（衍生页） | 置信度、进食时长、咀嚼次数、食物属性、当次行为分析、来源标识 |
| 6 | 入口承接 + 空状态 + 演示标识 | 从 `U-01`「查看全部」与 `U-02`「已自动记录」跳入并定位今日；空态文案；`A-04` 数据显示「演示数据」 |
| 7 | 餐段筛选 chip（`ADR-24`） | `全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品` 六枚药丸，**只在已加载的日期分组上做客户端过滤**：不改 §4.1 的汇总口径、不碰仓库、不重排。分类直接复用冻结判据（`MealWindows.isSnackRecord` / `liquidClassId` / 三个窗口），因此是**全且互斥**的划分。示意图只画了四枚（早餐/午餐/晚餐/零食），`饮品` 是 `ADR-23` 的必然结果（液体既不是零食也不是三餐样本），`全部` 是示意图缺的回到全集的出口 —— 依据见 `ADR-24` |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
- **不需要**独立的「饮食详情」主界面：详情是记录页的**衍生页**（从条目 push 进入），**不占底栏 Tab、不计入 4 个页面**（FF-23）。
- **不做** CSV / 文件导出（`X-03`）；**不做**手动任意改类别、删除误报、编辑时间（`X-02`）。
- **不做**营养素（蛋白质/脂肪/碳水化合物/膳食纤维）字段的展示与计算。
- **不做**份量调整（加/减份数）——**`ADR-23`：份量由本次进食时长推算**（`PortionEstimator`：`clamp(rate × durationSeconds)`），用户不可改；无时长证据时回退知识库标准份量并如实标注。
- **不做**搜索、筛选、月度统计、分页归档（单条约 300 B，无容量压力，`API-05` §5.8）；**不做**任何网络请求与云同步（`API-05` §1）。

## 2. 功能行为
### 2.1 触发与前置条件
- 触发：底栏「记录」Tab；或首页「查看全部」；或检测页「已自动记录」提示。
- 前置：SQLite 已打开；`diet_record` 与 `behavior_metrics` **同事务写入**（`API-05` §5.5，**不允许缺行**）。
- 数据取出：`StatsRepo.today()`（今日汇总，`API-03` §5）、`DietRepo.byRange(DateRange)`（时间轴记录，`API-03` §4）、`ReportService.weekly(range).summaryText`（本周小结，`API-04` §5）。
- 分页：不分页；首屏只查最近 7 天，向下滚动按周懒加载（不预加载全表，`API-05` §5.4）。

### 2.2 主流程（编号步骤）
1. 进入记录页 → 并行请求今日汇总、本周小结、最近 7 天记录（`DietRepo.byRange` 一次查出，半开区间）。
2. 汇总条渲染 `315 kcal / 3 次 / 1 次`；无记录时三项均为 `0`。
3. 记录按设备本地日历日分组（`API-00` §3.2），组标题 `今天 / 昨天 / M月d日`；**组内顺序直接沿用 `DietRepo.byRange` / `DietDao.selectByRange` 的 `eatenAtMs ASC`（`API-03` §3.1 冻结，UI 不得再排序）**，顺序争议见 §10 开放问题 5。
4. 每条记录按 §4.2 标准模板渲染为 `RecordCard`（三行）。
5. 本周小结卡片渲染 `summaryText`；数据不足时 `数据不足`。
6. 点击条目 → push 详情页，展示 §4.3 的全部可用字段；返回后列表滚动位置保留。
7. 检测页新增记录后返回 → 汇总条与对应分组刷新，新条目短暂高亮。

### 2.3 状态与状态迁移
```dart
enum RecordsStatus { idle, loading, ready, empty, error }   // 复用 SPEC-U-06 的 ViewStatus 语义
```
| 当前态 | 事件 | 下一态 | 说明 |
|---|---|---|---|
| `idle` → `loading` | 首帧请求 | `loading` | 骨架屏 |
| `loading` | 返回非空 / 空集合 / 抛错 | `ready` / `empty` / `error` | 空态文案；汇总条仍显示 `0`；错误态 `StateView(error)` + 重试 |
| `ready` | 新增记录（检测页写入） | `loading` → `ready` | 不整页白屏，仅刷新受影响分组 |
| `ready` | 清空全部数据（`D-05`） | `empty` | 不得残留上一份列表 |

### 2.4 边界条件
- 同分钟两条记录：按 `eatenAtMs` 精确排序，不合并；跨天按本地时区日历日（23:59 与 00:01 必须分属不同分组）。
- `confidence` 处于 0.45–0.70 且用户完成 Level-3 二选一确认：详情页显示「已确认」标记（**只呈现这一种标记**，依据 `ADR-P6`）。**不呈现「已修正」**；`confirmed_by_user` 与 `corrected_by_user` 两列**都保留入库**，UI 只消费「已确认」这一种呈现。
- 记录无行为指标：按 `API-05` §5.5 必须存在**空指标占位行**，详情页各项显示 `--`；取指标的方法缺口见 §10 开放问题 4。
- 食物名超长：单行省略，语义标签给全名。
- 检测期间的「示例演示」标识由 `patch.source == "inject"` 触发（属 `U-02`）；本页按落库 `DietRecord.source ∈ {real, demo}` 显示「演示数据」标识（`SPEC-D-01` §3 `CHECK` 约束、`SPEC-A-04` §7 A-04-K3 文案）。
- 记录条数很多（> 500）：滚动流畅（懒加载），无卡顿。

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 记录页 ← `D-03` | `StatsRepo.today()`（`API-03` §5） | 无（内部取今日区间） | `TodaySummary`（含 `records`） | `ACD-DB-001` / `ACD-DB-003` |
| 记录页 ← `D-02` | `DietRepo.byRange(DateRange)`（`API-03` §4） | 半开区间 `[startMs, endMs)`，最近 7 天 | `List<DietRecord>`（`eatenAtMs` 升序） | `ACD-DB-001` / `ACD-DB-004`（区间反序） |
| 记录页 ← `A-03` | `ReportService.weekly({required DateRange range})`（`API-04` §5） | 本周范围 | `WeeklyReport.summaryText` | `ACD-DB-*` |
| 详情页 ← `D-02` | `DietRepo.byId(String recordId)`（`API-03` §4） | `recordId` | `DietRecord?`（未命中 `null`，不抛错） | — |
| 详情页 ← `D-02` | `MetricsDao.selectByRecordId(String recordId)`（`API-03` §3.1，**L3 内部**） | `recordId` | `BehaviorMetrics?` | 见 §10 开放问题 4（L5 不得直调 DAO） |
| 详情页 ← `P-08` | `FoodKnowledgeBase.byClassId(int)`（`API-02` §6） | `classId ∈ [0,6)` | `FoodInfo`（**非空**） | `ACD-KB-001`（越界） |
| 记录页 → 详情 | 路由 `RecordDetailPage(recordId)` | `recordId` | — | — |
| 记录页 ← `U-01` | 路由入参 `initialGroup: today` | — | — | — |
| 任意 → `D-05` | `MaintenanceRepo.clearAllData()` 后重建 Provider | — | 清除行数 | `ACD-DB-003` |

## 4. 数据契约
### 4.1 页面级契约（与主方案 §3.4.1 UI 数据契约表逐行一致）
> **表外字段不得出现在本页任何位置**（风险 R-19）。

| 展示元素 | 数据源 | 字段 | 单位/格式 | 无数据时 |
|---|---|---|---|---|
| 时间轴条目 | SQLite | `time, food, kcalRange, confidence, attribute` | 见下方标准模板 | 空状态 |
| 顶部汇总条 | `D-03` 聚合 | `今日总热量 / 已记录次数 / 零食次数` | `315 kcal / 3 次 / 1 次` | `0` |
| 本周小结卡片 | `A-03` | `summaryText` | 一句话 | `数据不足` |

**落地映射（不改契约）**：`time` ← `DietRecord.eatenAtMs`（`HH:mm`）；`food` ← `classLabel` + `FoodInfo.zhName`；`attribute` ← `DietRecord.attribute` / `FoodInfo.attribute`；`confidence` ← `DietRecord.confidence`；`kcalRange` ← `FoodInfo.portionDesc` + `portionKcal`（单条）或 `TodaySummary.estimatedKcal` 的 ±20% 区间（汇总与小结）；汇总三项 ← `TodaySummary.estimatedKcal` / `recordCount` / `snackCount`。

### 4.2 条目标准模板（**逐字照此实现，消除设计稿粒度失控**）
```
┌────────────────────────────────────────────┐
│ 12:20  面条                    ≈120 kcal   │
│        软性主食 · 1 片（估算）              │
│        置信度 88%                      ›   │
└────────────────────────────────────────────┘
```
| 行 | 内容 | 来源 |
|---|---|---|
| 第 1 行左 / 右 | `HH:mm` + 食物名（FF-19 六类内） / `≈{portionKcal} kcal` | `eatenAtMs` + `classLabel` / `FoodInfo.portionKcal` |
| 第 2 行 | `{attribute} · {本次估算用量}（估算）` | `attribute` + `PortionEstimator.of(FoodInfo, record.durationSeconds).amountText`（`ADR-23`：如 `约 150 g` / `约 250 ml`；无时长则退回 `FoodInfo.portionDesc`） |
| 第 3 行 + 行尾 | `置信度 {round(p×100)}%` + 箭头 `›`（可进入详情） | `DietRecord.confidence` |

### 4.3 条目详情页字段（衍生页，只读）

| 分组 | 字段 | 来源 | 无数据时 |
|---|---|---|---|
| 基本信息 | 食物名、属性、记录时间 | `classLabel`、`attribute`、`eatenAtMs` | `--` |
| 识别信息 | 置信度、是否已确认 | `confidence`、`correctedByUser`（Dart 侧暴露**保持不变**；`confirmed_by_user` 仅入库供分析，不上 UI） | `--` |
| 当次行为分析 | 咀嚼次数、平均咀嚼间隔、进食时长、速度评级 | `BehaviorMetrics` 四字段 | `--` |
| 知识库信息 | **本次估算用量**、标准份量描述、估算热量、风险提示 | `PortionEstimator.amountText` / `FoodInfo.portionDesc` / 本次估算 `kcal` / `riskNote`（`ADR-23`：两条份量行**并列**，读者要能分清"这次吃了多少"与"知识库的标准份量"） | 隐藏该行 |
| 来源 | `mic` / `inject` / 演示数据 | `DietRecord.source` | — |

> `FoodInfo.nutritionTags` **仅在详情页可读**，且必须与模型置信度**视觉分离**（不同区块、不并列），区块标题注明「来自食物知识库估算，非模型输出」。

> ✅ **展示边界已冻结（`ADR-P6`，2026-09-10）**：`confirmed_by_user` 与 `corrected_by_user` **两列都保留入库**（前者供统计低置信度占比与模型迭代）；**UI 只呈现「已确认」标记**（对应 Level-3 二选一确认过的记录），**不呈现「已修正」**；`DietRecord` 的 Dart 侧暴露**保持 `correctedByUser` 不变**。本口径与 `X-02`（手动修正已降级为二选一确认，`SPEC-00` §3.10 术语禁令）一致，详情页不得为此新增字段（风险 R-19）。

## 5. 参数与常量
- 类别集合与粒度：`SPEC-00` §3.3 **FF-19**（6 类；禁止「全麦面条」「纯牛奶」「番茄」「鸡翅」等超出识别粒度的命名）。
  > ADR-19 起「面条」是**正式类别**（`noodles`，中文名「面条」），不再是禁用词；禁用词改为泛指**更细的**命名（如「全麦面条」「番茄」「鸡翅」）。
- 热量展示规则（份量 + 估算）：主方案 §3.4.1、§5.5；文案红线：`SPEC-00` §3.10 **FF-25**。
- 行为指标口径：`SPEC-00` §3.6 **FF-21e**（速度分级）/ **FF-21f**（咀嚼次数带「约」）/ **FF-21g**（MAE 降级不给绝对数字）；`X-07` 的 σ **不交付**。
- 置信度展示：`API-00` §3.3（`round(p × 100)`）；时间与分组：`API-00` §3.2（存储 epoch 毫秒；按本地时区日历日分组；**域层不得产出格式化字符串**）。
- 一致性红线：`API-05` §5.5（记录与行为指标同事务，不允许缺行）；隐私：`SPEC-00` §3.9 **FF-24**。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 记录查询失败 | Provider `error` | 只降级列表 | 列表区错误态 + 重试；汇总条保留上次值并标注「旧数据」 |
| 汇总查询失败 | Provider `error` | 只降级汇总条 | 汇总条显示 `-- / -- / --` |
| 本周小结失败 | Provider `error` | 只降级小结卡 | `数据不足` |
| 详情查不到记录 | `DietRepo.byId` 返回 `null` | 关闭详情并提示 | 「记录已不存在」+ 返回列表 |
| 行为指标缺行 | `MetricsDao.selectByRecordId` 返回 `null` | 全部显示 `--`（不报错） | 详情页行为区全 `--` |
| `classId` 越界（脏数据） | `byClassId` 抛 `ACD-KB-001` | 捕获后占位渲染并记日志 | 占位图标 + `未知类别`，无份量无热量 |
| 时间轴顺序与产品直觉不符 | 人工核对 | 沿用 `eatenAtMs ASC`（`API-03` §3.1 冻结，UI 不得重排） | 见 §10 开放问题 5 |
| 数据库迁移失败 | `ACD-DB-001` | 整页错误态 | 「数据初始化失败，请重开 App」 |
| 数据量过大导致首屏慢 | 实测 > 500 ms | 缩短首屏窗口到 3 天 | 无感知（懒加载） |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 页面 widget test 全通过 | `flutter test test/widget/records_page_test.dart` | 退出码 0 |
| 2 | 条目模板三行结构 | `test('record card renders 3-line standard template')` | 三行分别匹配 `^\d{2}:\d{2} `、含 `（估算）`、`^置信度 \d+%$` |
| 3 | 单条热量必带份量与估算 | `test('record kcal always paired with portion and estimate marker')` | `（估算）` 命中率 == 100%，无孤立 `\d+ kcal` 行 |
| 4 | 汇总条格式 | `test('summary bar matches N kcal / N 次 / N 次')` | 正则 `\d+ kcal / \d+ 次 / \d+ 次` |
| 5 | 空态 | `test('records empty state shows deterministic copy')` | 空态文案存在且汇总为 `0` |
| 6 | 按日期分组正确 | `test('records group by local calendar day, cross-midnight splits')` | 23:59 与 00:01 落入不同分组 |
| 7 | 详情字段完整性 | `test('detail page renders confidence/duration/chews/attribute/source')` | 5 类字段各至少 1 个 widget；缺值渲染 `--` |
| 8 | 无 CSV / 无改类别 | `rg -n "csv\|export\|导出\|修正类别\|删除记录" lib/presentation/pages/records/` | 命中数 == 0 |
| 9 | 营养素与表外字段零命中 | `rg -n "蛋白质\|脂肪\|碳水化合物\|膳食纤维\|全麦\|纯牛奶\|番茄\|鸡翅\|面条" lib/presentation/pages/records/` | 命中数 == 0 |
| 10 | 文案红线 | `rg -n "零操作\|完全无感\|2 秒内出结果" lib/presentation/pages/records/` | 命中数 == 0 |
| 11 | 视觉与文案人工核对 | 见下表逐项核对表 | 全部 ✓ |

**人工核对表（记录页与详情，8 项）**

| # | 核对项 | 期望 |
|---|---|---|
| 1 | 条目标准模板 | 与 §4.2 图例逐行一致（时间/食物名/热量；属性·份量（估算）；置信度 + 箭头） |
| 2 | 食物命名 | 全部落在 FF-19 六类内；**无**「全麦面条」「纯牛奶」「1高蛋白高钙」 |
| 3 | 顶部汇总条 | `315 kcal / 3 次 / 1 次` 三项齐全，kcal 前带「估算」语义 |
| 4 | 时间轴分组 | 今天 / 昨天 / M月d日 三种标题；组内倒序；本周小结为「本周」口径 |
| 5 | 旧版稿 | 不按 `4.png` / `5.png`（已作废）实现；以 `8.png` / `9.png` / `10.png` 为准 |
| 6 | 页面结构 | 无独立「饮食详情」主界面（仅衍生页，不占底栏 Tab） |
| 7 | 来源标识 | `inject` 显示「示例演示」；演示数据集显示「演示数据」；空态无「去添加记录」等误导按钮 |
| 8 | 品牌与红线 | 标题 `AcouDiet` / `声膳`；无 FF-25 禁用表述 |
| 9 | 餐段 chip 不与汇总条矛盾（`ADR-24`） | 选「零食」后列表只剩固体零食，而顶部「零食 N 次」**不变**（筛选只看列表，汇总始终是「今日」整体；两者同源于 `MealWindows.isSnackRecord`）；`饮品` 独立成一类；筛空时给出「这一餐段还没有记录」，不是空白页 |
| 10 | 日期头（`ADR-24`） | 分组标题仍由 `AcouFormat.dayGroupHeader` 产出（`今天 / 昨天 / M月d日`，§4.1 不变），其**旁边**另显示一枚 `M月d日` 日期标签；星标是**装饰**，不承载数值 |

## 8. 非功能约束
**内容硬规则（三条，与主方案 §3.4.1 一致）**
1. 热量数字**必须带份量描述与「估算」字样**；禁止孤立出现 `120 kcal`。
2. 食物粒度**必须落在 6 类内**（`chips/cabbage/gummies/noodles/carrot/drink`）；禁止「全麦面条」「纯牛奶」「番茄」「鸡翅」等超出识别粒度的命名（ADR-19 起「面条」本身是正式类别，不再是禁用词）。
3. **无法从模型推导的营养素（蛋白质/脂肪/碳水化合物/膳食纤维）一律不得出现在 UI 上**；`nutritionTags` 仅在详情页以「知识库估算」区块呈现且与置信度视觉分离。

| 类别 | 约束 |
|---|---|
| 性能 | 首屏（最近 7 天）渲染 ≤ 500 ms；滚动 60 fps；单次查询 ≤ 20 ms（`API-00` §3.7）；列表懒加载，不一次物化全表 |
| 数据完整性 | 展示的记录必须与 `behavior_metrics` 一致（同事务）；发现孤儿记录按 `ACD-DB-*` 记录并隐藏该条 |
| 无障碍 | 每条记录语义形如「12 点 20 分，面条，约 120 千卡，软性主食 1 片，估算，置信度 88%，双击查看详情」；汇总条语义为「今日已记录 3 次，估算总热量 315 千卡，其中零食 1 次」；详情页各字段独立语义标签，`--` 朗读为「无数据」；点击区 ≥ 48×48 dp |
| 隐私 | 不申请权限、不发网络请求、不打点（FF-24）；记录只在本地 SQLite（`API-05` §3 R-OUT-2） |

## 9. 裁剪与未做
- 🔴 **本功能不可裁剪**：自动生成记录是主方案 §8.2.1 五项不可砍之第②项（`D-01`~`D-03` + `P-06`）；本页是该能力的用户可见面。
- `X-03` CSV 导出：**不做**（导出入口只在 `U-05` 且置灰标 `v1.1`）；`X-02` 手动修正：**不做**任意改类别与删除误报，条目在 v1.0 **只读**。
- `X-05` 检测页识别历史列表：**不做**（避免与记录页重复）；`X-07` 咀嚼节律 σ：**不做**（行为分析只有次数/间隔/时长/速度）。
- 独立「饮食详情」主界面：**不做**（详情为衍生页，页面数仍为 4）。
- 搜索 / 筛选 / 月度报表 / 分页归档：**不做**；份量调整（加/减份）：**不做**。

## 10. 开放问题
1. **汇总条 kcal 与硬规则 1 的措辞边界**：契约表规定汇总条格式为 `315 kcal / 3 次 / 1 次`（聚合值无法逐条带份量）。本 SPEC 处置：**汇总条标签须含「估算」字样**，单条热量严格按标准模板带份量 + 「估算」。需 A/B/C 确认，避免两处规则互相打脸。
2. **详情页是否展示 `nutritionTags`**：本 SPEC 允许但要求视觉分离并标注来源；若可能被误读为模型输出，建议直接不展示。
3. **时间轴首屏窗口**：7 天 vs 3 天（性能相关），待 D8 实测后定。
4. **`2.png` 底部缩略图归属**：若属记录页而非首页，需与 `U-01` 协调避免重复实现（当前按首页归属处理）。
5. ✅ **已关闭（依据 ADR-06 修订 A-1）**：`DietRepo` **新增** `Future<BehaviorMetrics?> metricsByRecordId(String recordId)`（`API-03` §4），详情页按 `recordId` 精确取行为指标，**不直调** `MetricsDao`（`API-00` §1 规则 1）。约定：行存在但指标为占位（`chewCount == null`）→ 返回**全 null 的 `BehaviorMetrics`**；记录不存在 → `null`；两种情形的 `null` 字段一律渲染 `--`。
6. **时间轴组内顺序**：`API-03` §3.1 冻结为 `eatenAtMs ASC` 且「UI 不得再排序」，与常见的「最新在上」交互不同 → 需确认接受正序，或走变更改契约。
7. ✅ **已关闭（`ADR-P6`，2026-09-10）**：`SPEC-D-01` 的 `diet_record` 含 `confirmed_by_user` 与 `corrected_by_user` 两列，而冻结的 `DietRecord` 类只声明 `correctedByUser` → 原处置为「只展示 `correctedByUser`」，需拍板。**裁定：两列都保留入库**（`confirmed_by_user` 供统计低置信度占比与模型迭代）；**UI 只呈现「已确认」标记**（对应 Level-3 二选一确认过的记录），**不呈现「已修正」**；`DietRecord` 的 Dart 侧暴露**保持 `correctedByUser` 不变**（展示口径见 §4.3）。

**文档结束**

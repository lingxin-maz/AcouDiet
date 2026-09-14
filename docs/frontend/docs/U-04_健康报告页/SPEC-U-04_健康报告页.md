# SPEC-U-04 健康报告页

| 项 | 值 |
|---|---|
| 域 | `U` · 界面 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1 §3.4.2 §3.8 §9.1；`docs/00_功能清单与数量分析.md` §2 域 U / §3 / §6；`SPEC-00` §3.7 FF-22、§3.9 FF-24、§3.10 FF-25 |
| 依赖的 SPEC | `SPEC-U-06`（折线/雷达/空态）、`SPEC-A-03`（周报与趋势）、`SPEC-A-01`（评分卡）、`SPEC-A-02`（建议规则引擎）、`SPEC-D-03`（聚合查询）、`SPEC-A-04`（演示数据双轨） |

## 1. 目标与范围

### 1.1 一句话目标
用一屏展示本周饮食趋势（折线）、四维评分的可下钻明细与规则引擎给出的健康建议，并在数据不足时**确定性降级**为可理解的空态而非编造数字。

### 1.2 范围内（In Scope）
> **`ADR-23` 修订**：本页由「一页长列表」改为**一个入口、两个可滑动切换的分栏** —— **「每日」（默认）** 与
> **「本周」**。AppBar 下是 `SegmentedButton`（每日 / 本周），主体是 `PageView`（`initialPage = 0` 即每日），
> 左右滑动与点击都能切换；AppBar 标题跟随分栏（「每日报告」 / 「本周」，后者的措辞仍是判据 1 的冻结标题）。
> 下列元素中的 1–6 属于**本周**分栏；**每日**分栏为：日期选择器（只列有记录的天）+ 当日四维雷达与分数卡
> （可下钻）+ 当日汇总（记录次数 / 估算热量 / 零食次数 / 食物类别）+ 按天四维评分列表。两个分栏读同一个
> `ReportView`，因此不可能对同一个数字给出两种口径。

| # | 元素 | 说明 |
|---|---|---|
| 1 | 7 天趋势折线 | 纵轴可切 `kcal` / `score` 两种口径（`TrendSeries.points`，`API-04` §5） |
| 2 | 四维评分下钻 | 四个维度逐项 `label score/max`，可展开看 `evidence` |
| 3 | 健康建议列表 | `Advice[]` 按 `priority` 排序 |
| 4 | 本周小结文案 | `WeeklyReport.summaryText` |
| 5 | 环比变化 | `WeeklyReport.deltas` |
| 6 | 免责声明 | 固定文案，常驻页面底部（两个分栏都渲染） |
| 7 | 数据来源标识 | 使用 `A-04` Track 2 演示数据时显示「演示数据」标识 |
| 8 | 总分与评级 | `HealthScore.totalScore` / `grade`（与首页同一套数据） |
| 9 | **每日分栏**（`ADR-23` / `ADR-25`） | 日期选择器 + 四维雷达/分数卡 + 当日汇总（记录/估算热量/零食/类别）+ 按天评分列表。⚠️ `ADR-25`：**分数卡与每日列表里的分数是"以该日为最后一天的最近 7 个本地日"窗口的评分**（单日 σ 不可定义，逐日隔离评分会让总分恒为 `--`），口径与首页「近 7 天健康评分」相同；「当日汇总」四项仍是该日自己的数据。卡片标题、列表说明、卡片下注与趋势图评分轴**都必须点明这个 7 天口径** |
| 10 | **健康建议卡片化**（`ADR-24`） | 建议块画成示意图 `2.png` 的圆角渐变卡片（标题 `健康建议` + 前导勾选图标），文案仍逐字渲染 `Advice.text`，免责声明仍在卡内常驻 |
| 11 | **最近识别记录横滑瓦片**（`ADR-24`） | 与记录页**同一 7 日窗口**里最新的 6 条记录，用**同一套** `RecordCardText` 模板渲染，点开进同一条详情页。**不是新指标**：它是普通记录列表的一个视图，标题旁注明条数上限；窗口为空时整块不渲染（该状态已有 `insufficient` 句子） |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
- **不做**营养素（蛋白质/脂肪/碳水化合物/膳食纤维）的任何图表、占比或标签。
- **不做**热量目标线（没有 2000 kcal 目标这一概念）。
- **不做**周报导出、分享、截图保存、CSV（`X-03`）。
- **不做**月度/季度报告、长期预测、LLM 健康助手（属 `00_功能清单` §5 后续阶段；LLM 是唯一需要云端的项，见 `API-05` §9）。
- **不做**医学结论式文案（不得出现「你有营养不良风险」等诊断口径）。
- **不做**在报告中引入任何网络请求（FF-24 第 4 条）。

## 2. 功能行为

### 2.1 触发与前置条件
| 项 | 内容 |
|---|---|
| 触发 | 底栏「报告」Tab；或 `U-05` 设置页「健康报告」入口 |
| 前置 | `A-01` 评分服务与 `A-03` 报告服务可用；数据来自当前生效数据集（Track 1 真实累积或 Track 2 预置） |
| 数据取出 | `ReportService.weekly({required DateRange range})` 与 `ReportService.trend({required int days})`（`A-03`，`API-04` §5）、`HealthScoreService.score({required DateRange range})`（`A-01`）、`AdviceEngine.generate({required HealthScore score, required WeekSummary agg})`（`A-02`）、`DemoDataController.isDemoActive`（`A-04`） |
| 可复现性 | 同一数据库 + 同一周 → 同一份报告（`API-05` §6.1，评分服务为纯函数） |

### 2.2 主流程（编号步骤）
1. 进入报告页 → 并行请求趋势、评分、建议、小结。
2. 趋势返回 → 折线渲染恰好 7 个日期位（`points.length == days`）；`estimatedKcal` 为 `null` 的日期**断线不插值**、不画 0；`score` 口径的 `totalScore` 由 `ReportService.trend()` 在 **L4 填充**（`StatsRepo.trend()` 恒为 `null`，`API-03` §5 / `API-04` §5），页面不自行计算、**不得把 `null` 当作 0**。
3. 评分返回 → 显示总分（与首页一致）+ 四维逐项 `label score/max`。
4. 用户点某一维 → 展开 `evidence`（如 σ 值、占比 p、零食次数 n、平均咀嚼间隔 t 的**原始量**，不展示公式外的推导）。
5. 建议返回 → 按 `priority` 升序渲染文案列表。
6. 小结返回 → 显示一句话；`deltas` **恒含 7 键**（`API-04` §5），逐键渲染环比；**无对比基准的键值为 `0`**（不是缺键、不是 `null`，`ADR-10`），`0` 表示**确实持平**而非无数据；环比是**差值**不是比率（原 `↓20%` 的百分比写法作废）。
7. 数据不足 → 按 §6 的确定性降级：空图 + 提示，而非伪造数据。
8. 页面底部常驻免责声明。

### 2.3 状态与状态迁移

```dart
enum ReportStatus { idle, loading, ready, insufficient, error }   // insufficient = 数据不足
```

| 当前态 | 事件 | 下一态 | 说明 |
|---|---|---|---|
| `idle` | 首帧请求 | `loading` | 骨架屏 |
| `loading` | 数据充足（≥ 阈值，见 §2.4） | `ready` | 三区块正常渲染 |
| `loading` | 数据不足 | `insufficient` | 空图 + 明确提示；总分仍可显示或 `--` |
| `loading` | 抛错 | `error` | `StateView(error)` + 重试 |
| `ready` | 数据被清空（`D-05`） | `insufficient` | 不得残留旧图 |
| `ready` | 切换演示数据（`A-04`） | `loading` → `ready` | 显示「演示数据」标识 |
| `ready` | 纵轴口径切换 | `ready` | 仅重绘折线，不重新请求 |

### 2.4 边界条件
- 记录总数为 0：趋势空图 + `暂无足够数据`；四维全 `--`；建议区 `暂不生成建议`。
- 本周记录 < 3 条：视为「数据不足」，进入 `insufficient`（阈值需与 `A-03` 一致，见 §10）。
- 某天无记录：该点 `null` → 折线断开，不画 0。
- 只有 1 天有数据：折线退化为单点标记 + 数值，不画线。
- 四维中某维无可计算依据（如 σ 无定义）：该维 `--`，总分显示 `--`（**不做部分求和**）。
- `deltas` **恒含 7 键**（`API-04` §5、`ADR-10`），**不存在「为空」的情形**；无对比基准时 7 键均为 `0`（数值型，非缺键、非 `null`），**不得因值为 `0` 而判定为「无数据」并隐藏环比区块**。
- 演示数据生效：页面顶部显示「演示数据」标识（`A-04` 要求可标识）。
- 系统字号 200%：建议列表不裁切，折线图例可换行。

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 报告页 ← `A-03` | `ReportService.weekly({required DateRange range})`（`API-04` §5） | 本周范围 | `WeeklyReport` | `ACD-DB-*` |
| 报告页 ← `A-03` | `ReportService.trend({required int days})`（`API-04` §5） | `days = 7` | `TrendSeries`（`points.length == days`，日期连续升序） | `ACD-DB-004`（越界） |
| 报告页 ← `A-01` | `HealthScoreService.score({required DateRange range})`（`API-04` §3） | 本周范围 | `HealthScore` | `ACD-DB-*` |
| 报告页 ← `A-02` | `AdviceEngine.generate({required HealthScore score, required WeekSummary agg})`（`API-04` §4） | 评分 + `StatsRepo.week()` 聚合 | `List<Advice>`（可为空列表） | 无（可为空） |
| 报告页 ← `D-03` | `StatsRepo.week()`（`API-04` §4 的 `agg` 入参来源） | 无 | `WeekSummary` | `ACD-DB-001` / `ACD-DB-003` |
| 报告页 ← `A-04` | `DemoDataController.isDemoActive`（`API-04` §6） | — | `bool` | — |
| 报告页 → `U-05` | 设置页入口回跳 | — | — | — |
| 报告页 → `U-03` | 从某一维下钻跳记录页（按维度过滤不实现，仅跳转） | — | — | — |

## 4. 数据契约

> 本表与**主方案 §3.4.1 UI 数据契约表**逐行一致；**表外字段不得出现在本页任何位置**（风险 R-19）。

| 展示元素 | 数据源 | 字段 | 单位/格式 | 无数据时 |
|---|---|---|---|---|
| 7 天趋势折线 | `D-03` 聚合 | `daily[kcal 或 score]` | 折线 | 空图 + 提示 |
| 四维评分下钻 | `A-01` | 四项分数 | `饮食规律 26/30` | `--` |
| 健康建议 | `A-02` | `advice[]` | 文案列表 | `暂不生成建议` |

**落地映射（不改契约）**：
- `daily[kcal 或 score]` ← `TrendSeries.points`（`TrendPoint.date` / `estimatedKcal` / `totalScore`），长度 == 7、日期连续升序；**L3 的 `StatsRepo.trend()` 恒把 `totalScore` 置 `null`，由 `ReportService.trend()` 在 L4 填充**（`API-03` §5）；纵轴口径由 `ChartAxis.kcal | .score` 切换。
- 「四项分数」← `HealthScore.regularity / structure / snack / speed`，各渲染 `DimensionScore.label` + `score/max`；下钻展开 `DimensionScore.evidence`。
- `advice[]` ← `WeeklyReport.advices`（`Advice.dimension` / `text` / `priority`）。
- 小结与环比 ← `WeeklyReport.summaryText` / `WeeklyReport.deltas`（**恒含 7 键**：`totalScore` / `regularity` / `structure` / `snack` / `speed` / `recordCount` / `estimatedKcal`；无基准时值为 `0`，`API-04` §5）。
- **页面标题按视觉稿修正清单统一为「本周」**（`2.png`「近 7 天」→「本周」）；口径冲突见 §10 开放问题 1。**`ADR-23`**：新增**「每日」分栏**后，标题跟随当前分栏 —— 每日分栏为「每日报告」，本周分栏仍为「本周」（本条判据的冻结措辞不撤销，只是不再覆盖整个页面）。

## 5. 参数与常量
- 评分四维、满分与公式可下钻要求：`SPEC-00` §3.7 **FF-22**（`regularity` 30 / `structure` 30 / `snack` 20 / `speed` 20；σ≥90 min 零分等端点值以 FF-22 为准，本文件不重抄公式字面）。
- 总分与评级分档（**已拍板**，`ADR-P2` / FF-22b）：`总分 ≥ 80 → 良好`、`60–79 → 一般`、`< 60 → 需改善`，登记于 `SPEC-00` §3.7；本页与 `U-01` 同值同文案（`85 分 = 良好`）。
- 四维取整规则：`API-05` §6.2（**四维各自取整后求和**，根治主方案 §3.8「已知缺口 D-1」）。
- 单位与舍入（kcal 区间、置信度、时长）：`API-05` §6.2。
- 速度分级依据：`SPEC-00` §3.6 **FF-21e**；咀嚼次数文案：**FF-21f**；MAE 降级：**FF-21g**。
- 隐私：`SPEC-00` §3.9 **FF-24**；文案红线：`SPEC-00` §3.10 **FF-25**（禁止「可以测热量/营养素」式表述）。
- 演示数据双轨与标识：`SPEC-A-04`；报告数据自洽要求：主方案 §9.1。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 记录总数为 0 | 聚合结果为空 | 进入 `insufficient` | 空图 + `暂无足够数据`；建议区 `暂不生成建议` |
| 记录数 < 阈值（默认 3 条） | 计数判断 | 进入 `insufficient` | `本周记录较少，暂不生成完整报告`（阈值与 `A-03` 对齐） |
| 某维无可计算依据 | `DimensionScore.score == null` 语义（UI 层判空） | 该维 `--`，总分 `--` | **不做部分求和**，避免出现"假总分" |
| 趋势服务失败 | Provider `error` | 只降级折线 | 折线区错误态 + 重试，其余区块正常 |
| 建议引擎失败 | Provider `error` | 只降级建议 | `暂不生成建议` |
| 评分服务抛错 | `AcouDietError` | 只降级评分区 | 评分与四维 `--` |
| 演示数据加载失败 | `ACD-DEMO-001` | 回退真实数据 | 无标识；提示「演示数据不可用」 |
| 数据源切换中 | `A-04` 切换状态 | 保持 `loading` | 顶部细进度条，不闪白屏 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 报告页 widget test 全通过 | `flutter test test/widget/report_page_test.dart` | 退出码 0 |
| 2 | 折线点位与空洞处理 | `test('report trend renders exactly 7 date slots and skips null days')` | 日期位数 == 7；渲染 spot 数 == 非空点数 |
| 3 | 纵轴口径切换 | `test('report axis toggle switches kcal/score without refetch')` | 切换后请求计数不变，刻度单位正确 |
| 4 | 四维下钻格式 | `test('report dimension drill shows label score/max')` | 四条文本均匹配 `\S+ \d+/\d+` |
| 5 | 四维之和 == 总分 | `test('report four dims sum equals totalScore')`（`SPEC-C-05`） | 逐字段相等 |
| 6 | 首页与报告页分数一致 | `test('home score equals report score for same dataset')` | 相等（消除 D-1 缺口） |
| 7 | 数据不足确定性降级 | `test('report insufficient state shows empty chart and no fabricated numbers')` | 无折线 spot，文案存在，页面无 `\d+ kcal` 区域数值 |
| 8 | 建议列表降级文案 | `test('report advice empty shows 暂不生成建议')` | 文本逐字一致 |
| 9 | 免责声明常驻 | `test('report shows disclaimer')` | 声明 widget 存在（`ready` 与 `insufficient` 两态都要有） |
| 10 | 无营养素 / 无目标线 | `rg -n "蛋白质\|脂肪\|碳水化合物\|膳食纤维\|2000\|目标热量" lib/presentation/pages/report/` | 命中数 == 0 |
| 11 | 文案红线 | `rg -n "可以测热量\|零操作\|完全无感\|识别所有食物" lib/presentation/pages/report/` | 命中数 == 0 |
| 12 | 环比键集恒为 7 个 | `test('weekly deltas always contain exactly 7 keys')`（`API-04` §5 单测要点①） | 键集 == {totalScore, regularity, structure, snack, speed, recordCount, estimatedKcal}；无基准时值为 `0`（非 `null`、非缺键） |
| 13 | 视觉与文案人工核对 | 见下表逐项核对表 | 全部 ✓ |
| 14 | 健康建议卡是**浅色**渐变卡（`ADR-24`） | `test('the advice block is a light gradient card')` | 卡容器带 `AcouTheme.adviceGradient`；建议文本颜色 == `AcouTheme.ink`（示意图的**白字放薄荷**约 2.5:1，违反 U-06 §8，故只抄形状不抄字色） |
| 15 | 最近识别记录瓦片（`ADR-24`） | `test('the recent-records strip lists every card it was given')` + `ui_presenter_tests` 的「the recent-records list is unmodifiable」 | 每张卡各渲染一次；标题与「最新 6 条」说明各一次；列表**不可变**；窗口为空时整块不渲染 |
| 16 | **每日评分必须是可显示的分数与评级**（`ADR-25`） | `ui_presenter_tests` 的「ADR-25: the day the report opens on shows a real score and grade, not --」 | 报告页默认打开的那一天（最新有记录的日子）**总分与评级都不是 `--`**；修复前此判据在**每一天**都失败 |
| 17 | 每日评分口径 = 近 7 天且**写明**（`ADR-25`） | `pure_tests`：窗口天数 == 7、每个有记录的日子 σ 有定义、三个显示门槛全过；`ui_presenter_tests`：卡片标题与趋势图口径行都含「7」 | `windowDays == 7`；`reportDailyScoreTitle` 与 `reportTrendScoreNote` 都点明 7 天；窗口 `endMs == 该日的次日零点`（含当日） |

**人工核对表（报告页，11 项）**

| # | 核对项 | 期望 |
|---|---|---|
| 1 | 页面标题 | 本周分栏的标题为 `本周`（`2.png` 的「近 7 天」须改；该分栏标题不得写「近 7 天」）；`ADR-23`：每日分栏标题为 `每日报告`，并存在 `每日 / 本周` 分段控件与左右滑动切换 |
| 2 | 分数一致性 | 报告页分数与首页分数来自**同一套 Demo 数据**（消除 `2.png` 82 与 `1.png` 85 的冲突） |
| 3 | 四维下钻 | 四行形如 `饮食规律 26/30`；点击展开 `evidence` |
| 4 | 折线口径 | 纵轴单位随 kcal/score 切换，不出现热量目标线 |
| 5 | 空洞处理 | 无记录日折线断开，不连成直线、不显示 0 |
| 6 | 建议列表 | 文案为知识库/规则引擎产出的生活方式建议，无医学诊断口径 |
| 7 | 免责声明 | 常驻底部，明确「估算值，不作为医学依据」 |
| 8 | 数据不足态 | 空图 + `暂无足够数据`；无任何编造数字 |
| 9 | 演示数据标识 | 使用 Track 2 时顶部有「演示数据」标识 |
| 10 | 旧版稿 | 不按 `4.png` / `5.png`（作废）实现；以 `8.png` / `9.png` / `10.png` 为准 |
| 11 | 品牌与红线 | 标题 `AcouDiet` / `声膳`；无 FF-25 禁用表述 |

## 8. 非功能约束

**内容硬规则（三条，与主方案 §3.4.1 一致）**
1. 热量数字**必须带「估算」表述**；报告中出现的 kcal 一律是「知识库 × 标准份量」估算值，禁止表述为实测摄入量。
2. 食物粒度**必须落在 6 类内**；建议文案若提及食物，只能用 `chips/cabbage/gummies/noodles/carrot/drink` 六类中文名。
3. **无法从模型推导的营养素（蛋白质/脂肪/碳水化合物/膳食纤维）一律不得出现在 UI 上**。

| 类别 | 约束 |
|---|---|
| 性能 | 报告页计算在主 isolate（周级聚合，数据量小，`API-00` §3.7）；进入页面 ≤ 800 ms 出首屏（实测产出） |
| 可复现 | 同一数据库 + 同一周 → 同一分数（`API-05` §6.1）；页面不得使用当前时刻作为判据 |
| 无障碍 | 折线图提供文本等价物，形如「本周趋势：周一 1100 千卡，周二 1200 千卡，周三无数据……」；雷达提供四维文本等价物；维度下钻行语义含「双击展开依据」；折线图在开关口径时朗读当前口径；点击区 ≥ 48×48 dp |
| 隐私 | 不申请权限、不发网络请求、不打点（FF-24）；报告不生成任何文件 |
| 文案 | 免责声明必须出现，措辞遵守 FF-25（不得自称可测热量/营养素） |

## 9. 裁剪与未做
- 🔴 **本功能不可裁剪**：健康报告 + 评分卡是主方案 §8.2.1 五项不可砍之第③项；评分下钻是答辩必答题「85 怎么算的」的现场证据（主方案 §10.1）。
- `X-03` CSV 导出：**不做**，报告页无导出/分享入口（导出入口仅在 `U-05` 且置灰标 `v1.1`）。
- `X-07` 咀嚼节律 σ：**不做**，报告不展示节律标准差（`evidence` 中亦不得出现）。
- 月度/季度报告、趋势预测、LLM 健康助手：**不做**（`00_功能清单` §5 后续阶段；LLM 唯一需云端，`API-05` §9 状态 `DISABLED`）。
- 热量目标线 / 营养素占比：**不做**（本文件 §8 硬规则 1、3）。
- 报告导出图片：**不做**。

## 10. 开放问题
1. ✅ **已关闭（依据 ADR-10）**：`week()` / `summary()` 的窗口**已由接口层权威定义为「最近 7 个设备本地日历日（含今日）」**（`API-03` §5），非 ISO 周；本 SPEC 的处置（数据取 `ReportService.trend(days: 7)`，UI 标题统一为「本周」）**即为该口径**，无需再确认，也不再产生两种「本周」语义。
2. **「数据不足」阈值**：本 SPEC 暂定「本周记录 < 3 条」，需与 `A-03` 的降级判据统一，避免页面与服务的判据打架。
3. **四维 `evidence` 的展示粒度**：`API-04` §3 已把 `evidence` 的**键集冻结为契约**（`sigmaMinutes` / `healthyRatio` / `snackCount` / `avgChewIntervalSeconds` 等），本 SPEC 据此**直接渲染键值对 + 中文释义**，不在 UI 重算公式；若需增删键，须走 `API-00` §3.9 变更流程。
4. ✅ **已关闭（依据 ADR-12）**：报告页**作为底栏第 4 个 Tab** —— 底栏 **4 Tab = 首页 / 检测 / 记录 / 报告**；「**我的**」放**首页右上角入口，不做独立 Tab**（`SPEC-U-06` §10 同批裁定、`FF-23`）；自检面板（`M-04`）同样**不得成为第 5 个页面**（`SPEC-M-04` §10）。

**文档结束**

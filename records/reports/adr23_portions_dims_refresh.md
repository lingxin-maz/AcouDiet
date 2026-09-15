# ADR-23 执行记录：用户反馈的 7 项（用量 / 零食 / 首页四维 / 每日四维 / 实时行为 / 下拉刷新 / 切 Tab）

**状态**：✅ 已实现并通过全部离线与 Flutter 套件；**未做真机复测**（本机 `adb devices` 为空）
**裁定理由**：`docs/01_裁定记录ADR.md` → **ADR-23**
**影响面**：L3 聚合、L4 域层（部分量模型、零食判定、评分窗口、逐日评分、行为快照）、L5 页面与状态层

---

## 1. 用户原话与逐条裁定

> 1. 毫升数和克数现在是怎么推测、怎么换算的？我感觉现在不是根据实际情况推算的，更像是一个固定值……
>    能不能改成按照一定时间来算，比如结合进食时长，来推算一个合理的进食量。
> 2. 液体为什么会被分类成零食？现在感觉啥都算零食……饮品不要算进零食里，也不要在零食统计里重复计入。
> 3. 首页上的食物结构和进食速度，好像没有和实际数据同步，只是食物控制那一项直接拉满了。
> 4. 报告里的四维评分没有显示，建议把每日四维评分也加进去。
> 5. 检测的时候，下面的咀嚼次数、进食时长和进食速度，我希望它们能同步显示、实时变化。
> 6. 所有页面都统一改成支持下拉刷新。
> 7. 每次点击底部按钮切换界面时，我希望界面先自动刷新一次，把最新数据拉取完再呈现，不要先显示旧数据。

开工前就 4 个有**多种合理实现**的点向用户确认，回答如下（本节即据此实现）：

| 问 | 用户选择 |
|---|---|
| 用量规则 | **每类食物一个进食速率 × 本次时长**（放入知识库，不动冻结的评分公式） |
| 饮品归类 | **饮品单独一类，完全不计入零食**（不新增单独的"饮品次数"指标） |
| 首页四维 | **四项都要改**：随"吃了多少 / 吃了什么"动态变化；规律性与速度不该老是 `--`；零食控制不该无条件满分；食物结构不该一顿就满分 |
| 每日四维 | **新增「每日四维评分」列表**（并给报告页补回四维雷达） |

## 2. 第 1 条：用量按时长动态推算

### 2.1 缺陷（实测）

修复前 `AcouFormat.recordKcalBadge/recordEstimateLine` 直接读 `FoodInfo.portionKcal` 与 `portionDesc`：
**任何一条记录都显示同一个标准份量**。一条 15 秒的薯片记录与一条 10 分钟的薯片记录都显示
`脆性高加工零食 · 1 小包（约 30g）（估算）≈160 kcal` —— 数字与进食时长无关，正如用户所述"像一个固定值"。

### 2.2 模型

知识库（`app/assets/foods.json`）每条新增五个字段，`amountPerSecond` 是**整段进食的平均摄入速率**（含停顿）：

| 类别 | 单位 | 标准份量 | 速率 | 下限 | 上限 | 标准份量对应的时长 |
|---|---|---|---|---|---|---|
| chips 薯片 | g | 30 | 0.25 /s | 10 | 60 | ≈120 s |
| cabbage 卷心菜 | g | 150 | 0.50 /s | 50 | 300 | ≈300 s |
| gummies 软糖 | g | 25 | 0.28 /s | 8 | 60 | ≈90 s |
| noodles 面条 | g | 200 | 0.33 /s | 60 | 400 | ≈600 s |
| carrot 胡萝卜 | g | 100 | 0.55 /s | 30 | 250 | ≈180 s |
| drink 饮料 | ml | 250 | 4.20 /s | 100 | 600 | ≈60 s |

```
amount = clamp(round_to_step(amountPerSecond × durationSeconds), minAmount, maxAmount)
kcal   = round(portionKcal × amount / standardAmount)
```

* 取整步长：固体 5 g、液体 10 ml（`PortionEstimator.gStep/mlStep`，全仓唯一一处声明）；
* `durationSeconds <= 0`（占位指标行）**回退标准份量**并置 `durationBased = false` —— 不发明时长；
* 上限/下限的作用是**夹住外推**：会话忘了停、开了 20 分钟，也不会算出五公斤的面条。

### 2.3 一致性：聚合热量必须逐条算

`TodaySummary.estimatedKcal` 原来是 `Σ kCalFor(classId) × 条数`。若改成"按类汇总时长再夹一次"，
结果与逐条估算**不相等**（夹取发生在每条记录上），首页的"估算能量参考"就会与它下面那几张记录卡片对不上。
因此 `StatsRepoImpl.summary()` 与 `trend()` 都改为**逐条记录**调用 `KcalResolver.kcalForDuration`：

```sql
-- summary: 每个类别的条数（结构/热量口径分离）
SELECT class_label AS label, COUNT(*) AS c FROM diet_record WHERE ... GROUP BY class_label
-- summary: 逐条时长 → 热量
SELECT class_label AS label, duration_seconds AS d FROM diet_record WHERE ...
-- summary: 分钟 × 类别（零食 / 晚间 / σ）
SELECT strftime('%H',...) AS h, strftime('%M',...) AS m, class_label AS label, COUNT(*) AS c
  FROM diet_record WHERE ... GROUP BY h, m, label
```

仍是**固定三条语句**，没有 N+1。

## 3. 第 2 条：液体不再算零食

`MealWindows.isSnack(minutes)` 是纯时间判据（三餐窗口之外即零食），与"吃了什么"无关。后果是
**下午的一瓶饮料同时进入"零食次数"和它自己的类别列** —— 同一条记录被计两次，而且"零食控制"因为喝水被扣分。

裁定：

```dart
/// ADR-23: a snack is a SOLID food eaten outside the three meal windows.
static bool isSnackRecord(int minutes, int classId) =>
    isSnack(minutes) && classId != liquidClassId;

/// A liquid inside a meal window is not a meal sample either (it must not enter σ).
static bool isMealSample(int minutes, int classId) =>
    !isMainMeal(minutes) && classId != liquidClassId;
```

* `liquidClassId` 由 **SSOT 的 `class_labels.indexOf('drink')`** 解析（不写死 `5`；解析不到就抛），所以
  类别表再改一次（`ADR-19` 已经改过一次）不会静默失效；
* 「晚间进食」**刻意保持纯时间**：那是一个时间指标，晚间的饮料仍算晚间进食；
* SQL 与 `FakeRepo` 用**同一条规则**（两条实现必须一致，`data_tests` 有断言）。

## 4. 第 3 条：首页四维与事实不符

三处独立原因，逐一修：

| 现象 | 根因 | 修法 |
|---|---|---|
| 「饮食规律性」「进食速度」长期 `--` | 首页评分窗口是**当天**；σ 需要同一餐段 ≥2 条样本，速度需要 ≥1 条带咀嚼指标的记录 —— 一天之内几乎不可能满足 | 首页评分窗口改为**最近 7 个本地日**（与「本周记录」、报告页同窗口） |
| 「食物结构」一顿就 30/30 | `30 × min(1, p/0.4)`，一条面条记录 p=100% → 满分 | 窗口记录数 < `minimumRecordsForDisplay`(3) 时该维度**不可显示**（渲染 `--`，不把一条记录读成"结构完美"） |
| 「零食控制」无条件 20/20，界面上无从解释 | 公式 `20 × max(0, 1 − n/10)`，n=0 就是满分 | 卡片底部新增**依据行** `记录 N 次 · 零食 n 次 · 有咀嚼指标 m 条` |

配套文案变更（`UiStrings`）：`今日健康评分` → **`近 7 天健康评分`**；`较昨日` → **`较上一周期`**；
`HealthScoreService` 的 Δ 从"窗口前一天"改为**上一等长窗口**（`range.previous`）。这一条原来写死为
`startOfLocalDay(range.startMs - 1)`，对 1 天窗口正确，对 7 天窗口就会拿"一天"去比"七天" —— 数字看着合理，
含义是错的。

> 副作用（有意）：首页与报告页从此读**同一个窗口**，`SPEC-C-05` 的"两页不能给出两个数字"由构造保证。
> 今日的数据仍在同一屏幕上：估算能量参考、本周记录次数、今日记录列表。

## 5. 第 4 条：报告页 = 一个入口、两个可滑动切换的分栏（默认「每日」）

用户后续追加：**「每日」与「本周」同一个按钮进入，可以左右滑动切换，而且默认先显示「每日」**。
因此报告页从"一页长列表"改成 **`PageView` 双分栏**：

| | 分栏 | 进入方式 | 内容 |
|---|---|---|---|
| 0（**默认**） | **每日报告** | 底栏「报告」Tab / 分段控件 / 左右滑动 | 日期选择器（只列有记录的天，默认最新一天）→ 该日**得分卡 + 四维雷达**（可下钻）→ 该日**汇总**（记录次数 / 估算热量 / 零食次数 / 食物类别）→ **「每日四维评分」按天列表**（点一天即切换上方明细） |
| 1 | **本周** | 同上 | 冻结的周报：四维雷达 + 分数卡、趋势图（评分/热量切换）、四维评分行、七项环比、建议与免责声明 |

* `ReportScope.daily` 刻意排在**第一位**，`PageController()` 的 `initialPage = 0` 即"默认每日"；
* 除了滑动，AppBar 下方还有一个 **`SegmentedButton`（每日 / 本周）** —— 只有滑动的话用户不知道有两个报告；
* AppBar 标题跟随当前分栏：`每日报告` / `本周`（后者是 `SPEC-U-04` 判据 1 冻结的标题，仍然保留）；
* 分栏位置存在页面 `State` 里（不是 notifier），所以切换底栏 Tab 时不会跳回第一天分栏；
* **两侧读同一个 `ReportView`**，因此每日与本周不可能对同一个数字给出两种口径；本周的数字与首页同源。

### 域层与展示层的配套改动

* `DailyScore` 从"只有分数"扩展为**一天的完整汇总**：`recordCount` / `snackCount` / `classCounts` / `estimatedKcal` / `score`；
* `ReportService.dailyScores(days)` 改为**每天一次 `stats.summary(day)`** 取真实计数与热量（与记录页同一个聚合），
  日期键仍由 `stats.trend(days)` 提供（那一条序列负责"每本地日一个点、升序且无缺口"的契约**并且读仓库的时钟**，
  测试才能复现）；单日不可评分时 `score == null`，不拖垮序列；
* `DailyScoreView` 增加 `scoreView`（当日四维投影，与本周头部的 `ScoreView` 同一实现）、
  `kcalText` / `countText` / `snackText` / `classSummary`（`面条 ×2 · 胡萝卜 ×1`，按条数降序、同数按 FF-19 次序，
  确定性排序而不是依赖 `List.sort` 的稳定性）；
* `report_page.dart` 重写为 `StatefulWidget` + `PageView`；`report_demo_page` 与自检面板的入口未变。

### 新增回归（`app/test/ui/report_scope_test.dart`，4 项）

| 断言 | 结果 |
|---|---|
| 打开时在**每日**：标题 `每日报告`、当日四维与每日列表在屏，`本周趋势` **不可见** | ✅ |
| 左右滑动真的切换分栏（左滑出本周内容、右滑回每日） | ✅ |
| 分段控件用点击也能切换（不必会滑动） | ✅ |
| 点另一天的日期 chip 后，日期不会"回弹" | ✅ |


## 6. 第 5 条：检测页行为行实时联动

```dart
// BehaviorAnalyzer
BehaviorMetrics? finish({required int endMs}) {          // 封闭
  _sealed = true;
  return snapshot(endMs: endMs);
}
BehaviorMetrics? snapshot({required int endMs}) { ... }   // 不封闭，同一套管线
```

`DetectionSession` 每 `liveMetricsEveryPatches = 2` 个 patch（patch 为 2 Hz，故约 1 Hz）取一次快照，
放进 `DetectionState.metrics`；`DetectNotifier._onSessionState` 每次都刷新 `_behavior`。
**实时读数与最终读数走的是同一个函数**，不存在两套"咀嚼速度"定义。

## 7. 第 6 / 7 条：下拉刷新与切 Tab 刷新

* **下拉刷新**：新增 `RefreshableBody`（把不可滚动的状态面板包进 `AlwaysScrollableScrollPhysics` 的
  单元素 `ListView` 并撑满视口），首页、记录、报告、我的、记录详情、自检面板、演示页**全部接入**；
  有列表的页面另外把 `physics` 改成 `AlwaysScrollableScrollPhysics`，否则空列表同样拉不动。
* **切 Tab**：新增 `AcouNotifier.reloadFresh()` —— 先 `publish(loading())`（丢弃旧值）再 reload。
  `AppShell._select` 在切到首页 / 记录 / 报告时调用；再点当前 Tab 也刷新一次。
  「检测」是会话页，**没有可加载的数据，刻意不刷新**。
  与 `reload()` 的区别被测试钉住：下拉刷新要**保留旧值**（内容变暗，不闪白），切 Tab 要**丢弃旧值**（不能先给旧数字）。

## 8. 验证（全部实测）

| 命令 | 结果 |
|---|---|
| `dart tool/pure_tests.dart` | **193 / 193**（174 → 193：新增份量模型、液体规则、7 天窗口 Δ、逐日四维） |
| `dart tool/session_tests.dart` | **121 / 121**（102 → 121：知识库份量模型、实时行为快照） |
| `dart tool/ui_presenter_tests.dart` | **400 / 400**（377 → 394 → 400：估算用量文案、依据行、窗口文案、每日分栏的汇总字段） |
| `dart tool/data_tests.dart`（真实 SQLite） | **63 / 63**（57 → 63：15:40 饮品不计零食、饮品不做 σ 样本、逐条时长热量聚合） |
| `flutter test` | **119 / 119 全过**（110 → 119：`refresh_and_tab_test` 5 项 + `report_scope_test` 4 项） |
| `flutter analyze` | **0 error**；issue **种类**与 `ADR-22` 基线逐条相同（无新种类引入） |
| `python tool/run_offline_tests.py` | 7 个可离线文件全过（9 个需真实 `flutter test`） |
| `python tool/check_bridge_symmetry.py --strict` | PASS |
| `python tool/check_l4_usage.py --strict` | PASS |
| 离线断言合计 | **777**（L4 纯域 193 + L3 数据 63 + 会话 121 + UI 400）+ `flutter test` 119 |

> 计数口径说明：`817 → 777` **不是删了断言**。上一版把 `flutter test` 的 110 项**没有**计入合计，
> 而本轮新增的 `flutter test` 文件（`refresh_and_tab_test` 5 + `report_scope_test` 4）同样不计；
> 纯离线部分由 809 变为 777 的差额来自重新登记：`session`（102→121）与 `UI`（377→400）都**增加**，
> 而本表不再把 AI guard-rails 28 项计入 `app/` 侧合计。**app 侧实际断言数是从 809/817 上升到
> 777 + 119（flutter test）= 896。**

## 9. 第 8 条（用户追加）：模型组 v1.1 交付包 —— **没有新权重，只有命名不一致**

用户要求「`acoudiet_model_v1.1` 里是新模型，帮我替换好」。先核对，不先替换：

| 核对项 | 方法 | 结果 |
|---|---|---|
| 交付包与本仓的 `.tflite` 是否同一份 | 逐文件 sha256 | `v1.1/models/acoudiet_fp32.tflite` = `705ffc62…560a`，与当时已投放的 `acoudiet_fp32_v1.0.0.tflite` **逐字节相同** |
| 交付包的 Mel 前端是否与本仓冻结规格一致 | `tool/compare_model_delivery.py`（33 项 Mel/IO 键逐键比对） | **不一致项 = 0**（抽样：`n_fft=1024`、`hop_length=512`、`raw_mel_frames=129`、`patch_frames=128`、`power_to_db_ref='patch_max'`、`normalization='per_patch_minmax'`、`operation_order` 逐项相同） |
| 类别表 | 交付 `class_labels.json` vs SSOT | **MATCH**（`chips, cabbage, gummies, noodles, carrot, drink`） |
| 另两个制品 | 同批核对 | `int8` / `int8_fullint` **未在**仓内（本仓只投放 fp32），交付包说明自己把 fp32 定为正式嵌入件 |

**结论**：App 里跑的**一直就是 v1.1 的权重**，不一致的只是**标签** —— 模型卡 `version` 是 `1.0.0`，
而交付包叫 `v1.1`，于是 `assets/models/` 里显示为 `…_v1.0.0.tflite`，看上去像旧模型。

### 9.1 复核"是不是真的同一份"（用户追问「模型组重新训练过一次」）

用户随后指出模型组**重训过一次**，要求直接替换。于是把范围扩到**整个工作区 + zip 内部**重新测了一遍：

| 位置 | 文件 | 字节 | sha256 |
|---|---|---|---|
| `acoudiet_model_v1.1/v1.1/models/` | `acoudiet_fp32.tflite` | 4,051,716 | `705ffc62…560a` |
| `acoudiet_model_v1.1.zip` **内部同一条目** | `v1.1/models/acoudiet_fp32.tflite` | 4,051,716 | `705ffc62…560a`（与解压后的副本**相同**） |
| `app/assets/models/` | `acoudiet_fp32_v1.1.0.tflite` | 4,051,716 | `705ffc62…560a` |
| `acoudiet_model_v1.1/v1.1/models/` | `acoudiet_int8.tflite` | 1,209,272 | `b7e90022…2f4c` |
| `acoudiet_model_v1.1/v1.1/models/` | `acoudiet_int8_fullint.tflite` | 1,316,896 | `5aa1aaff…fbed` |
| `ai/artifacts/` | `acoudiet_int8_PIPELINECHECK.tflite`（本仓管线自检产物，非交付件） | 1,096,936 | `a285e480…c9c26` |

全工作区（排除 Flutter SDK 与构建中间件）**只有这 5 个 `.tflite`**，其中**只有一个 fp32**，
三处副本哈希逐字节相同。另外还扫了 `D:\Desktop`、`D:\Downloads`、用户目录的 Downloads/Desktop，
没有第二个模型包。

**判定**：sha256 相同 ⇒ **字节完全相同** ⇒ 权重完全相同。重新训练不可能复现同一串字节
（浮点权重逐比特一致的概率可以忽略）。而且那个包的 `README_集成说明.md` 自己把 v1.1 的变更列为
**打包口径**四条（① 正式件定为 `acoudiet_fp32.tflite`；② `class_labels.json` 的 `model_name` 更正；
③ 两个模型 I/O 一致、切换只需换 assets；④ 不含会话临时文件），**没有任何一条声称重训**。

因此：**重训后的那份权重不在本机**。已把这一条如实登记，并新建 `D:\Desktop\Food\_incoming_model\`
（含 `README.md`，写明投放命令）——新模型丢进去，我就能在同一步里给出「装前/装后 sha256」。
本轮**没有**用任何占位件或旧件冒充"已替换"。

### 9.2 用户最终裁决：**就按这份替换**（照办）

用户看过上述证据后仍要求「反正给我替换成这份」。于是**以 zip 为准重新投放了一次**，
让"装的是不是你给的那份"这件事在流程上无可争议：

| 步骤 | 命令/动作 | 实测 |
|---|---|---|
| 1 | 用 Python `zipfile` 把 `acoudiet_model_v1.1.zip` 解到**干净临时目录**（不用已解压的目录） | 成员 `v1.1/models/acoudiet_fp32.tflite` = `705ffc62…560a` |
| 2 | **对解出的那份**跑 `install_model.py --version 1.1.0` | fp32 / 4,051,716 B / `[1,128,128,1]` / 6 类 / `n_frames=128`，逐字节校验通过 |
| 3 | **装前 / 装后**资产哈希 | 装前 `705ffc62…560a` → 装后 `705ffc62…560a`（**字节相同，故哈希不变**；变化的是模型卡 `createdAtMs`，等价于"重新登记一次"） |
| 4 | 独立闸门 | `verify_artifacts.py` **exit 0 = PASS**；`session_tests` **124 项**全过（含"卡里字节数 == 文件真实字节数"与"只允许一个 `.tflite`"） |
| 5 | 重打 APK 并核对包内 | `assets/models/acoudiet_fp32_v1.1.0.tflite` 4,051,716 B、`705ffc62…560a`，检查脚本自打 **"matches the released acoudiet_fp32.tflite: True"**；权限仍只有 `RECORD_AUDIO`、无 `INTERNET`、仅 arm64 |

**一句话**：你要的那份**已经在包里**——`sha256` 相等就意味着**同一个文件**，所以"替换"前后哈希一致
不是没执行，而是**这份交付的字节本来就与旧件相同**。若之后拿到的是**字节不同**的重训件
（哈希会变），同一套流程会立刻在「装前/装后」两个哈希上体现出来。

> 📌 **顺带发现、仅登记不改动的一处规格差异**：交付包的 `class_labels.json` 里
> `reserve_labels` 是 **`pizza` / `fries`**，`removed_labels` 含 `apple` / `cookie` / `bread` / **`nuts`**
> （理由均为 `not_present_in_eating_sound_collection_v1`）。而本仓 `FF-19` / `ADR-19` 规定
> **储备类别是 `nuts`**（`noodles` 已于 ADR-19 转正）。两者对"储备类别"的定义不同 ——
> 训练侧的语料库里 `nuts` 根本不存在，本仓却把它当作 v1.0 之外的储备命名。这不影响 v1.0 的六个类别
> （`class_labels` 三处比对已 MATCH），但它是一条**需要规格owner裁定的口径差异**，登记在此，
> 本轮不动 FF-19（改它要走一次 ADR）。

**实际动作**（不替换字节，只对齐标签 + 加闸门）：

1. `tool/install_model.py --tflite <delivery>/models/acoudiet_fp32.tflite --version 1.1.0`
   （校验形状/类别/帧数/float32 I/O/体积，逐字节校验复制，卡里的 `tfliteSha256`/`tfliteBytes` 为实测）；
2. 删掉被取代的 `acoudiet_fp32_v1.0.0.tflite` —— `pubspec.yaml` 打包的是**整个目录**，留着就是 4 MB 死重；
3. `session_tests` 里写死的 `v1.0.0` 改为**从模型卡推导文件名**（原先这个断言会因版本号变化而失败，
   且失败原因与它的意图无关），并新增：卡里 `tfliteBytes` 必须等于文件真实字节数、`assets/models/` 里
   **只允许一个 `.tflite`**；
4. 新增可复跑脚本 `tool/compare_model_delivery.py <交付包目录>`：逐字节比 `.tflite` + 把交付包的
   `feature_config.json` 与 SSOT 逐键比对 + 比对类别表。**下次再来"新模型"，先跑它**。

**证据**：`verify_artifacts.py` **exit 0 = PASS**（含"卡与文件一致、体积在 FF-16 上限内、三 hash 闭环、
parity 实测"）；`session_tests` **124 项**（含 3 条新断言）；APK 内资产名与 sha256 见 §10。

## 10. 已知边界（如实登记）

1. **参数是工程估计，不是测量值**：六个 `amountPerSecond` 由"标准份量 ÷ 一次典型进食时长"反推
   （见 §2.2 的表）。本仓没有带标注的进食量语料，无法标定或验证；改一个数只需改 `foods.json`。
2. **时长 = 会话时长**（首个有效帧 → 会话结束），含进食间停顿。这正是需要上下限的原因。
3. **每日四维在样本少的那天仍显示 `--`**（结构维度要求 ≥3 条），这是有意的诚实降级。
4. **首页口径变更**：`今日健康评分` 不再存在，改称 `近 7 天健康评分`；今日的能量/次数/列表不变。
   若产品坚持"今日评分"，需要另加一条"当日四维"入口（本仓已有每日四维列表可复用）。
5. **未做真机复测**：本机无 `adb` 设备。`flutter build apk` 已重打（见 `PHONE_INSTALL.md`）。
6. **顺带修正的夹具缺陷**：`session_tests.dart` 曾给 10 个 patch 全部传 `tStartMs = 0`，行为分析器因此
   收到 10 段时间戳重叠的包络，平均咀嚼间隔实测 0.059 s（而不是合成峰列的 0.7 s）—— 该值过去只被断言
   "非空"。现已给每个 patch 递增时间戳，实时读数为 **0.684 s / 正常**。
7. **一处工具链事故（已修复，留作教训）**：本轮用 `Get-Content | Set-Content -Encoding UTF8` 改
   `fake_repo.dart` 的一行代码时，Windows PowerShell 5.1 把 BOM-less UTF-8 当 GBK 读入、再以 UTF-8 写回，
   **把该文件里的中文属性串全部变成乱码**（并顺带把行尾改成 CRLF）。已用显式 `encoding='utf-8'` 的
   Python 脚本按 `FoodClassId.kbAttribute` 的权威值逐字恢复，并核对无残留 CR。**改动 `.dart`/`.kt` 文件一律
   用文件工具（`edit`/`write`），不要用 PowerShell 的字符串管道**——`README.md` 里那条"NOTE FOR EDITORS"
   说的就是这个坑，本轮以身试法验证了它。
8. **知识库 Schema 已同步**：`foods.schema.json` 是 `additionalProperties: false` 的，新增五个字段后
   旧 Schema 会**拒绝真实资产**。已同步六个类别（`required` + `properties`），并新增可复跑的校验脚本
   `tool/update_foods_schema.py`（`--check` 只校验），实测 **schema 与资产逐字段一致（每类 14 个字段）**。
9. **文档一致性**：`python _toolchain/verify_docs.py` **PASS（BLOCKER × 0）**；已同步 `SPEC-U-01`
   （7 天窗口 / 依据行 / 结构维度样本门槛）、`SPEC-U-03`（记录卡第二行改为本次估算用量、详情页两行份量）、
   `API-04`（`FoodInfo` 五个新字段、`deltaVsYesterday` 改为"上一等长窗口"、FF-25 说明）。

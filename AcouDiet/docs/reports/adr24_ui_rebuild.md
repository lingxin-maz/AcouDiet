# ADR-24 · UI 按投放的界面示意图重构（Flutter 内按图重画）

> 本文件是 `ADR-24` 的证据与逐屏对照记录。裁定正文见 `docs/01_裁定记录ADR.md` 的 `ADR-24` 条目。
> 一句话结论：**视觉照原图，口径仍按冻结规格**；示意图里属于「信息」的部分逐条核对后拒绝，属于「看」的部分全部采纳。

---

## 1. 用户原始要求

> 「利用 semi-design 重建 UI 界面，然后我希望尽量按照我原来投放的 UI 示意图来重构。」

投放的示意图共 **6 张**（`软件UI界面设计图/`）：

| 文件 | 画面 | 本仓对应页 |
|---|---|---|
| `1.png` | 首页（评分大卡 + 四/五轴雷达 + 两张迷你卡 + 麦克风按钮） | `pages/home/home_page.dart` |
| `2.png` | 报告页（本周健康摘要折线卡 + 今日饮食记录 + 健康建议 + 最近识别记录） | `pages/report/report_page.dart` |
| `3.png` | 检测页（带返回箭头：薄荷圆盘声波 + 预测卡 + 识别历史） | `pages/detect/detect_page.dart` |
| `8.png` | 饮食记录（餐段 chip + 统计条 + 时间轴卡片 + 本周小结） | `pages/records/records_page.dart` |
| `9.png` | 我的（头像卡 + 条目卡 + 本周健康数据概览三宫格） | `pages/profile/profile_page.dart` |
| `10.png` | 检测页（Tab 版：品牌栏 + 刷新 + 声波 + 预测卡 + 识别历史） | `pages/detect/detect_page.dart` |

## 2. 两条用户裁定

| 编号 | 裁定 | 后果 |
|---|---|---|
| **A** | **在 Flutter 内按图重构** | 交付物仍是 Android APK，能上手机；不使用 React/Semi 运行时 |
| **B** | **视觉照原图，口径仍按冻结规格** | 四维（饮食规律性/食物结构/零食控制/进食速度）、六类、`估算 + ±20%` 一个字不改 |

## 3. 关于 Semi Design 的一处必须先说清的事实

**Semi Design 是 React 的 Web 组件库（`@douyinfe/semi-ui` 2.103.0），Flutter 不能直接使用它。**

- npm 实测：`npm view @douyinfe/semi-ui version` → `2.103.0`（沙箱内需把 npm cache 指到工程内才可写）。
- 官方指南已装入 DSH skill：`~/.dsh/skills/semi-design-guide/`，含 `SKILL.md` / `WORKFLOWS.md` / `BEST_PRACTICES.md`，三个文件与官方 git blob **逐字节相同**。
- 可用的是它的**设计规范**（间距 / 圆角 / 层级 / 卡片阴影 / 主色 / 状态色），载体仍是本仓的 `AcouTheme` 与 Flutter widget。
- 若确实要跑 Semi 组件，需要在本仓新建一个 React Web 工程 —— 那是**另一个交付物**，不在本次范围内（本仓目前没有任何 React 工程）。

## 4. 采纳的「看」

| 示意图里的做法 | 本仓落点 |
|---|---|
| 薄荷 → 奶油页面渐变 | `AcouTheme.pageGradient` / `pageGradientDecoration()`，所有顶层页面统一铺底 |
| 白色大圆角卡片 + 柔和投影（不再用描边分隔） | `AcouTheme.cardDecoration()`（`radiusLg = 20` + `cardShadows`） |
| 体育场形主按钮 | `filledButtonTheme` / `outlinedButtonTheme`（`StadiumBorder`） |
| 选中 Tab 的薄荷圆角块 | `AcouNavBar`（自定义，取代 `BottomNavigationBar`） |
| 圆角图标块（食物缩略图 / 条目图标） | `FoodIconBadge` + `softTileDecoration()` |
| 大号分数 | `AcouTheme.scoreLarge = 44` |
| 检测页薄荷圆盘 + 白色声波 | `WaveCircle`（`widgets/waveform_view.dart`） |
| 记录页卡片之间的时间轴圆点 | `TimelineConnector` |

## 5. 明确**拒绝**的「信息」（逐条核对，不是遗漏）

| 示意图里的内容 | 为什么不能用 | 冻结依据 |
|---|---|---|
| 5 轴雷达（出现**两个「脂肪」**，且没有「零食控制」） | 轴的数量与含义是冻结的 | `SPEC-U-01` 判据 1（FF-22 四轴） |
| 「食材多样性 8/12 种」 | 冻结口径里没有这个概念；首页该位置用记录次数 | `README §8` |
| 「1286/2000 kcal」目标点值 | 本仓一律「估算 + ±20% 区间」，不给单点目标 | FF-25 |
| 「苹果 / 面包 / 全麦 / 纯牛奶」命名 | 类别表只有六类 | FF-19（ADR-19 修订） |
| 「EatSense」品牌 | 品牌是 AcouDiet / 声膳 | FF-23 |
| 「我的」作为第 4 个 Tab | 第 4 个 Tab 冻结为「报告」，「我的」是入口 | FF-23 / ADR-12 |
| 「已记录 3 餐」 | 本仓口径是**次数**不是餐数 | `SPEC-U-03 §4.1` |

## 6. 记录页的餐段 chip：本次新增的交互，且**多出两个 chip**

示意图 8 有 `早餐 / 午餐 / 晚餐 / 零食` 四个 chip。`ADR-23` 之后这四类**不再是全集的划分**：

```
15:40 的一瓶饮料  ->  isSnack(minutes) == true   （纯时间判据）
                  ->  isSnackRecord(minutes, classId) == false  （液体排除）
```

若把这条记录算进「零食」chip，筛选结果就会与**它正上方**统计条里的「零食 n 次」互相矛盾 —— 这正是 `ADR-23` 修掉的那个"同一条记录计两次"的缺陷在界面上的翻版。

裁定：chip 变成 **六个** —— `全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品`。

- `RecordMealBucket.of(minutes, classId)` **直接调用冻结判据**（`MealWindows.liquidClassId` / `isSnackRecord` / 三个窗口），不重新实现一遍；
- 因此它是**全且互斥**的划分：一条记录必属且只属一类；
- `饮品` 是 `ADR-23` 的必然结果；
- `全部` 是示意图上没有的补充：示意图的筛选器**没有回到全集的出口**，一个能把全部记录藏起来又退不出去的筛选器是陷阱；
- 筛选**只在已加载的日期分组上生效**：不碰仓库、不碰口径，统计条始终描述「今日」，与筛选无关（这正是它第一项叫「今日热量」的原因）；某个日期分组被筛空时，**连它的日期头一起去掉**，避免出现"今天"下面什么都没有。

## 7. 顺带修正的一处显示缺陷

检测页预测卡此前显示**类别英文标签**：`chips 91%`。

- 它没有违反任何闸门：六类确实冻结，标签也确实来自 SSOT；
- 但界面上出现英文标识是投放上的缺陷；
- 裁定：`DetectPresenter.displayNameOf` 改为经知识库取 `FoodInfo.zhName`，拿不到时回落到冻结占位（`UiStrings.unknownCategory`），**不猜中文名**。

## 8. 补齐轮：报告页两块 + 我的页三宫格

用户追加「报告页那两块（健康建议渐变卡、最近识别记录瓦片）和我的页三宫格补齐」后落地。**三块都没有引入新指标**：每一块都能追溯到已有的冻结字段。

| 块 | 数据来源 | 关键决定 |
|---|---|---|
| **健康建议卡** | `Advice[].text`（原样渲染） | 画成示意图 `2.png` 的圆角渐变卡：`AcouTheme.adviceGradient`（`mintSoft → #D3F2E5`）+ 前导勾选图标 + 标题 `健康建议`；免责声明仍在卡内常驻。**不抄白字**：示意图是中绿底白字，实测约 **2.5:1**，违反 U-06 §8（≥ 4.5:1），会打挂既有对比度断言 —— 只抄形状与渐变，文字仍是 `ink`（12.6:1）。该偏离由 `test/ui/overview_and_recent_test.dart` 直接断言文本颜色 == `AcouTheme.ink` 钉住 |
| **最近识别记录** | 记录页**同一个 7 日窗口**的 `DietRepo.byRange`，取最新 **6** 条，经**同一套** `RecordsView.cardOf` 得到 `RecordCardText` | 它不是新口径，而是普通记录列表的一个**视图**：横滑瓦片（食物图标块 + 中文名 + 时间），点开进同一条 `RecordDetailPage`；标题下写明「记录页同一窗口里最新的 6 条」，避免被读成完整历史。窗口为空时**整块不渲染**（该状态已有 `insufficient` 句子），不自造第二个空态 |
| **本周健康数据概览三宫格** | `WeekSummary.recordCount` / `snackCount` + `StatsRepo.chewStats(7 日窗口).meanChewIntervalSeconds` | 三格 = `总进食次数` / `平均咀嚼速度` / `零食次数`，窗口与报告页「本周」**完全相同**（`ReportNotifier.trendDays`）。速度格是**档位词**而不是数字；降级契约：任一查询失败 → 三格**一起** `--`；窗口内没有咀嚼样本 → `无样本`，**不是** `正常` |

### 8.1 唯一的**新代码**：一处提权，不是新口径

档位词的阈值此前只存在于 `BehaviorAnalyzer._speedGrade`（私有，会话路径专用）。出现第二个调用者（窗口聚合）时没有复制一份映射，而是提为公开纯函数：

```dart
static String speedGradeFor(double seconds, {BehaviorConfig? config}) { ... }
```

会话路径改为 `speedGradeFor(avgInterval, config: cfg)` —— 全仓**唯一**实现，因此「一次会话」和「七天窗口」不可能对「正常」给出两种定义。

> 首版把它写成无参静态函数，编译期立刻报 `Undefined name 'cfg'`：`BehaviorAnalyzer.cfg` 是**实例字段**（且可注入），静态上下文取不到。改成接受可选 `config` 后既保留可注入性，也让没有分析器实例的调用方不必构造一个。

### 8.2 一处**产品口径的扩张**（已同步改规格）

三宫格把「本周」的口径搬到了「我的」，因此 `SPEC-U-05` 判据 9 里原有的 `rg` 禁词表（`本周健康数据概览` / `平均咀嚼速度`）由「禁止」变为「必须」，判据已同步修订并新增判据 14/15。`SPEC-U-04` 同步新增 §1.2 第 10/11 项与判据 14/15。

## 9. 🚨 一次真实事故：自绘底栏把整屏吃掉了（以及 124 项测试为何全绿）

**症状**（用户原话：「这UI感觉完全没变换啊」）：装上重建后的包，界面看起来**几乎空白**——左侧一条贯穿全屏的薄荷长条，页面本体什么都没有。

**根因**：`AcouNavBar` 里选中项那个 `Column` 用了默认的 `MainAxisSize.max`。`Scaffold` 把
`bottomNavigationBar` 的可用高度当作**整屏**，于是这个 Column 撑满了整屏，`Scaffold` 的 body
只剩 0 高。被替换掉的 `BottomNavigationBar` 自己管高度，所以这个隐含契约在自绘时丢了 —— 换组件
的时候没人把它写下来。

**修复**（三处一起才够）：
- `AcouNavBar.barHeight = 56`：给 bar 一个**显式内高**（`SizedBox`）；
- `AcouNavBar.tileWidth = 76`：选中块有自己的尺寸，不再随 tab 槽位拉伸；
- 内层 `Column` 补上 `mainAxisSize: MainAxisSize.min`。

**为什么 124 项 widget 测试全绿也没抓到** —— 这是本次最该记的一条：

> 既有测试**要么单独 pump 一个页面**（页面自带 `Scaffold`），**要么单独 pump 一个组件**；
> **没有任何一个测试 pump 过 `AppShell` 本身**，而缺陷只存在于 shell 里那一处。

这与 `ADR-22` 的「没人跑过的闸门等于没有闸门」是同一件事，只是从构建管线搬到了测试套件。

**新增防线（两条，都在这次补上）**：

| 文件 | 断言 |
|---|---|
| `test/ui/app_shell_layout_test.dart` | 底栏整体高度 < 140、首页图标高度 ≤ 24、`HomePage` 渲染高度 > 300（三处一起保证「栏是栏、页是页」）；点「记录」后 `currentIndex == 2` |
| `test/ui/page_chrome_test.dart` | 五个顶层页面**都**画 `AcouTheme.pageGradient` —— 防的是"漏了一个页面"这类逐页测试看不见的缺口 |

`page_chrome_test` 第一次跑就抓出第二处真实缺口：**报告页**没有渐变背景（第一轮漏了），以及
**检测页的 C-03 门禁分支**是唯一不画渐变的页面。两处都已修（报告页加渐变 + 为工具栏留出顶部内距；
门禁分支也画同一套渐变，这样"全 App 都换了背景"没有例外、测试也不必特判）。

## 10. 逐屏截图证据（模拟器 API 34 / x86_64，2026-09-13）

`docs/demo/emulator_run/` 下，全部来自**装到设备上跑起来**的构建（不是 widget 测试渲染，也不是设计稿）：

| 文件 | 内容 |
|---|---|
| `adr24_before_blank_screen.png` | **修复前**：选中块被拉成全屏高，页面空白 —— 事故现场 |
| `adr24_after_home.png` | 修复后首页：渐变 + 品牌栏 + 问候语 + 「近 7 天健康评分」大卡（四轴雷达）+ 两张迷你卡 + 薄荷圆角块底栏 |
| `adr24_after_detect.png` | 检测页：薄荷圆盘 + 白色静默波形 + 待确认卡 + 行为四行 |
| `adr24_after_records.png` | 记录页：`全部 / 早餐 / 午餐 / 晚餐 / …` 药丸筛选 + 三项统计条（含薄荷圆点）+ 本周小结卡 + 空态 |
| `adr24_after_report.png` | 报告页（修复渐变后）：`每日 / 本周` 分段控件 + 渐变背景 + 空态 |
| `adr24_after_profile.png` | 我的：白卡头像 + 五个条目卡 + **本周健康数据概览三宫格**（`0 次 / 无样本 / 0 次`）+ 说明行 |

> 生产截图同时验证了降级文案：三宫格里**「无样本」**是真的在界面上出现（此刻窗口内没有咀嚼样本），
> 而不是只存在于断言里。

## 11. 回归实测

| 闸门 | 结果 |
|---|---|
| `dart tool/pure_tests.dart` | **198 / 198**（+5：速度分档边界，阈值从 SSOT 读取而非写死） |
| `dart tool/session_tests.dart` | **124 / 124** |
| `dart tool/ui_presenter_tests.dart` | **410 / 410**（+10：三宫格降级 + 最近记录不可变） |
| `dart tool/data_tests.dart` | **63 / 63** |
| 合计离线断言 | **795 全过** |
| `flutter test` | **131 全过**（`overview_and_recent_test` 5 项 + `app_shell_layout_test` 2 项 + `page_chrome_test` 5 项） |
| `flutter analyze` | **0 error**；issue 种类与 `ADR-23` 基线**逐条相同** |
| `tool/ui_fingerprint_check.py`（新增） | `dist` 的 release 包 → `RESULT: ADR-24 UI` / `exit 0` |

两个 APK 已重打并逐项复验：release `25,533,450 B` / sha256 见 `PHONE_INSTALL.md` §0（arm64 单 ABI、
包内模型 sha256 与出厂件相同、无 `INTERNET`、`apksigner verify` 与 `zipalign -c -p 4` 退出码 0）。

> ⚠️ **同一字节数 ≠ 同一个包**：release 包连续三次都是 `25,533,450 B`，而 sha256 每次都不同。
> 判断"装的是哪个包"只能看 sha256。

## 12. 诚实边界

1. 报告页与我的页的三块**已补齐**；仍未实现的只剩示意图里**已被逐条拒绝的"信息"**（五轴雷达、食材多样性、目标 kcal 点值、EatSense 命名、「我的」作为第 4 个 Tab）—— 见 §5。
2. **三宫格是产品口径的扩张**（不是 bug 修复）：它把「本周」三数搬到「我的」，并改了 `SPEC-U-05` 判据 9 的禁词表；用户明确要求后才做。
3. 卡片阴影、圆角、渐变都是**Flutter 的近似**，不是示意图的渐变描边与投影；没有做像素级比对。
4. §10 的截图是**模拟器（x86_64, API 34）**上的构建，**不是用户那台手机**。真机上"装的是哪一版"用
   `tool/ui_fingerprint_check.py` 判定（它可以对**任意** apk 文件回答这个问题）。
5. 时间轴圆点、星标、chip 配色属于**装饰**，不承载数值；携带数值的文字一律仍是 `ink` / `gradeGood`，对比度断言不变。
6. 「最近识别记录」的 6 条上限是**产品选择**，不是性能结论：瓦片只是"最近几条"的一瞥，完整历史仍在记录页。

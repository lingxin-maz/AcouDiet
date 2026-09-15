# C-05 测试与回归套件 · 映射与执行清单

**SPEC 对应**：`SPEC-C-05`；**PLAN 对应**：`PLAN-C-05`
**入口**：`pwsh -File tool\verify_all.ps1`（一键跑完全部可离线执行的套件，**22 步**）

---

## 1. 为什么不是 `flutter test`

`SPEC-C-05` 的判据以 `flutter test app/test/...` 命名。本实现环境**无网络**，
`flutter pub get` 无法解析依赖，因此 `flutter test` / `gradlew` 无法启动
（详见 `records/reports/c04_dependency_deviation.md`）。

**处置**：把承载逻辑的代码全部写成**纯 Dart / 纯 Kotlin**，用 Dart SDK 与 JDK 直接执行；
测试断言与 `SPEC-C-05` 逐条对应（下表第 4 列）。恢复网络后，`app/test/**` 中的
`flutter_test` 版本可直接跑同一批断言（域层不需改动）。

---

## 2. 套件清单（实测，非预测）

| 套件 | 命令 | 覆盖 | 实测 |
|---|---|---|---|
| 配置生成 | `dart tool/gen_feature_config.dart` | C-03 判据 1 | ✅ 退出码 0；assets 与 SSOT 字节相等 |
| Kotlin DSP | `powershell -File tool/jvm_build.ps1 -Run` | P-01/P-02/P-03/P-04 + T-08b 对齐 | ✅ **79 项** 0 失败（`ADR-21`：+1 项「−82 dB patch 仍能解析出 `[0,1]`」，即 patch 相对 dB 的判别式） |
| L4 纯逻辑 | `dart app/tool/pure_tests.dart` | A-01/A-02/A-03、P-06、P-07、API-03 契约、FakeRepo、**ADR-20 模型 I/O 契约**、**ADR-23 份量估算**、**ADR-24 速度分档边界**、**ADR-25 日度评分窗口** | ✅ **202 项** 0 失败（含 13 项 I/O dtype 断言；`ADR-21`：握手名单断言由 `eq(12,12)` 改为**真的比对两侧名单**） |
| **`G-01..G-03` agent 离线套件**（`ADR-44`） | `dart app/tool/agent_tests.dart` | 云端出口与交接规则：同意门零请求、工具词表闭集、`proposalOnly` 不触发 launcher、SSE 跨分片 UTF-8、分片 `arguments` 累积、重试闸门、请求体上限 | ✅ **80 项** 0 失败；`--without-negative-controls` → **74/80，恰好 6 条负控变红**（这正是它们存在的证明） |
| L3 数据层 | `dart app/tool/data_tests.dart` | D-01…D-05、I-1/I-2/I-3、聚合口径、可复现、**v2 类别改名迁移**、**ADR-23 液体不计零食与逐条时长热量** | ✅ 63 项 0 失败（含 10 项 ADR-19 迁移断言、6 项 ADR-23 断言） |
| 会话/演示 | `dart app/tool/session_tests.dart` | C-03 握手、P-08、P-05/P-06/P-07 编排、M-01…M-04、模型投放契约、**ADR-23 份量模型 + 实时行为快照** | ✅ **124 项** 0 失败 |
| **SPEC 点名套件** | `python tool/run_offline_tests.py` | `app/test/**` 中 7 个非 widget 文件 | ✅ **66 项 0 失败**（见 §2.1） |
| Mel 对齐闸门 | `python ai/scripts/mel_parity_test.py --n 14` | T-08b（硬闸门）+ **模型 parity（实测）** | ✅ `maxAbsDiff=5.96e-08` ≤ `1e-3`；**`labelMatch=1.0000`、`maxConfDelta=8.34e-07`**（18 patch）。⚠️ 这两个数此前是**写死**的 `1.0`/`0.0`，现为实测 |
| 伦理准入 | `python tool/check_consent_registry.py --strict` | C-02 / R-11 | ✅ 4 条规则；未声明即 `ACD-ART-002` |
| **切分防泄漏（独立实现）** | `python tool/check_split_leakage.py --strict` | T-02 / `API-06` §3.3 六条断言 | ✅ 六条全过：`path` 两两不相交、`test_mobile` ⊆ `{P01,P02,P03}`、train/val 主体与录音均不相交、六类齐全、标签与 `split` 列一致 |
| **L5→L4 调用面一致性** | `python tool/check_l4_usage.py --strict` | `API-00` §1 分层规则 + 冻结签名 | ✅ 69 文件 / 195 类：相对 import 全部可解析、冻结构造器命名实参全部存在、被调成员确实存在。**负例实测**：注入 2 处断链 import + 1 处假命名实参 + 1 处想象出来的成员 → 4 条全被拦下 |
| **API-01 桥接对称性** | `python tool/check_bridge_symmetry.py --strict` | `API-01` §5 第 2 项「侧侧对称」 | ✅ 13 个方法双向一致（含 `getStorageDir`）、3 个事件类型一致、**15 个握手字段**同名同序（`ADR-21`；判定式由写死的 `!= 12` 改为**指名道姓的字段集合**，字段被静默丢弃时会点名报出） |
| **Kotlin 调用面** | `python tool/check_kotlin_usage.py --strict` | Android 宿主 → 纯 DSP 类（JVM 套件覆盖不到） | ✅ 16 文件 / 17 类：`com.acoudiet.*` import 全部可解析、被调成员确实存在 |
| **Android XML 合法性** | `python tool/check_android_xml.py --strict` | 清单与 `res/**` 必须真是 XML | ✅ 7 个文件全部合法（含"注释内不得出现 `--`"）——此门禁因两个清单长期非法而新增 |
| **模型投放契约** | `dart app/tool/session_tests.dart`（`Model drop-in contract` 组） | `assets/models/` 投放契约 | ✅ 含**未知档位** / 帧数不符 / 卡缺失三条拒绝路径（`ACD-INF-001/002`、`ACD-IO-002`）。`ADR-21` 起 fp32 **不再**是拒绝原因（FF-16 两档都可交付），故该组改为「fp32 卡被接受且解析出 `_fp32_` 文件名」+「未知档位被拒」，并**断言出厂卡确有对应 `.tflite` 文件** |
| **T-07/T-08a 管线** | `python ai/scripts/t07_export_int8.py --pipeline-check` | T-07 导出 + T-08a 对齐（**未训练权重的管线校验，不投放**） | ✅ 1.05 MB ≤ 2.5 MB；`labelMatch=1.000000`、`maxConfDelta=0.001302`；`melParity` 保留 |
| **交付制品闸门** | `python tool/verify_artifacts.py` | `API-06` §9 判定式（**独立于生产者的第二实现**） | ✅ **exit 0 = PASS**：fp32 4,051,716 B ≤ 6 MB、三 hash 闭环、parity 实测通过。新增判定 ⑧：`modelParityMeasured` 非 true 即**拒绝**（把"未测量"读成"通过"正是此门禁存在的理由） |
| **AI 工具链自检** | `python ai/tests/run_all.py` | SSOT 不变量 / 裁剪项 / 术语 / 不落盘 / **反馈回路实跑**（**28 项**） | ✅ 全过（`ADR-21`：帧数不变量拆成 `raw_mel_frames` 与 `frame_selection` 两条，并新增"无固定 dB 截断键"检查） |
| UI presenter | `dart app/tool/ui_presenter_tests.dart` | U-01…U-06、M-03/M-04 展示口径、**ADR-23 估算用量文案 / 依据行 / 窗口文案 / 报告每日分栏**、**ADR-24 速度分档边界 / 三宫格取值与降级 / 最近记录列表不可变**、**ADR-25 每日评分的显示与口径文案** | ✅ **413 项** 0 失败 |
| **报告页双分栏（默认每日 + 滑动切换）** | `flutter test test/ui/report_scope_test.dart` | ADR-23：打开即在「每日」、左右滑动真的切换、「本周」内容默认不在屏、分段控件可点、点日期后不回弹 | ✅ **4 项** 0 失败 |
| **下拉刷新 + 切 Tab 刷新** | `flutter test test/ui/refresh_and_tab_test.dart` | ADR-23：不可滚动状态也能下拉、四个数据页都有 `RefreshIndicator`、`reloadFresh()` 丢弃旧值而 `reload()` 保留、切 Tab 触发目标页刷新、首页评分覆盖 7 天窗口 | ✅ **5 项** 0 失败 |
| **事件通道会话绑定** | `flutter test test/data/audio_event_channel_test.dart` | `API-01` §3.1/§3.2：`listen`/`cancel` 的载荷必须绑定**当前** `sessionId`；`stop()` 必须把两个订阅都释放 | ✅ **5 项** 0 失败。**负例实测**：把 `events()` 改回 `_stream ??=` 后立刻红（`Expected ['S-1','S-2'] / Actual ['S-1','S-1']`）。见 `records/reports/u02_second_session_event_binding.md` |
| AI 工具链 | `python ai/tests/run_all.py` | T-01…T-08、制品闸门 | 见 `ai/reports/` |
| **一键** | `pwsh -File tool\verify_all.ps1` | 以上全部（**22 步**；原 20 + `G-01..G-03` agent 套件 + `ADR-44` 云端出口边界） | ✅ `ALL SUITES PASSED (22 steps)` |
| **Flutter 官方工具链**（需网络，一次性） | `flutter analyze` / `flutter test` / `flutter build apk --debug` | UI 层 28 个此前从未编译过的文件 | ✅ **0 error** / **131 项全过**（`ADR-24`；`ADR-23` 时为 91）/ 出包成功（`app-debug.apk`）；release 按 `SPEC-C-04` 如期要求 `key.properties` |
| **设备端逐屏截图**（`ADR-24`） | 模拟器（API 34 / x86_64）安装 4 ABI release 包后 `adb screencap` | 首页 / 检测 / 记录 / 报告 / 我的 各一张 | ✅ 五张都在 `records/demo/emulator_run/adr24_after_*.png`；修复前的空白屏为 `adr24_before_blank_screen.png`。logcat 无 `FATAL EXCEPTION` |
| **UI 按示意图重构**（`ADR-24`） | `flutter test` + `dart app/tool/ui_presenter_tests.dart` | 主题令牌（渐变/圆角/阴影）、`AcouNavBar`、记录页 `MealFilterRow` 与 `TimelineConnector`、检测页中文名、**健康建议渐变卡 / 最近识别记录瓦片 / 本周健康数据概览三宫格** | ✅ 离线 **795 全过**（PURE 198 / SESSION 124 / UI 410 / DATA 63）、`flutter test` **131 全过**、`flutter analyze` **0 error**。逐屏对照、拒绝项、两处偏离（白字改 ink、`speedGradeFor` 提权）与**一次真实事故**见 `records/reports/adr24_ui_rebuild.md` |
| **每日评分的显示与口径**（`ADR-25`） | `dart app/tool/pure_tests.dart` + `ui_presenter_tests.dart` + `tool/probe_daily_score.dart`（诊断） | 报告页日度数字（每日卡 / 每日列表 / 趋势图评分线）的窗口口径 | ✅ 离线 **802 全过**（PURE **202** / SESSION 124 / UI **413** / DATA 63）。用户可见断言：`9月10日: 81 / 良好`（修复前是 `-- / --`）。根因与取证见 `records/reports/adr25_daily_score_window.md` |
| **底栏不吃屏 / 全页同一套 chrome**（`ADR-24` 事故后补） | `flutter test test/ui/app_shell_layout_test.dart test/ui/page_chrome_test.dart` | 自绘底栏高度、图标不被拉伸、body 有高度；五个顶层页面都画 `pageGradient` | ✅ **7 项** 0 失败。事故：`AcouNavBar` 的 `MainAxisSize.max` 把选中块拉成全屏高、body 压成 0 —— **124 项测试全绿也没抓到，因为没有任何一个测试 pump 过 `AppShell`**（`ADR-22`「没人跑过的闸门不是闸门」的测试版）。第二条防线首次运行即抓出报告页漏渐变 + 检测门禁分支漏渐变 |
| **三宫格降级契约**（`ADR-24`） | `flutter test test/ui/overview_and_recent_test.dart` | 三格齐全且口径冻结；任一查询失败 → 三格一起 `--`；无咀嚼样本 → `无样本` 而非 `正常`；建议卡文字为 `ink` 而非白字 | ✅ **5 项** 0 失败（另：`ui_presenter_tests` 6 项断言三宫格取值与最近记录列表不可变） |
| **APK 权限闸门**（`ADR-24` 修；`ADR-44` 扩为两方向） | `python tool\check_apk_contents.py <apk> --expect-no-internet` / `--expect-internet` | `offline` 包必须**没有** `INTERNET`；`agent` 包必须**有**它（`SPEC-C-01` §7 #1a/#1b） | ✅ release `exit 0` / `INTERNET present: False`；**负控**：profile 包（`aapt2` 实测含 `INTERNET`）+ `--expect-no-internet` → **`exit 1`**。两个开关互斥，同时给出即 `ACD-ART-001`；都不给则只**观察**并打印提示（不再伪造结论）。此前该检查搜的是 ASCII 而清单字符串池是 UTF-16，对**任何**包都打印 `False` —— 一个不可能失败的闸门，见 `PHONE_INSTALL.md` §0。<br>⚠️ 路径自 `ADR-24` 起为 `tool\check_apk_contents.py`（早前写成 `_toolchain\...`，该文件早已移入 `tool/`） |
| **`ADR-44` 云端出口边界**（两个静态闸门 + 各自自测） | `python tool/check_network_boundary.py --selftest/--strict`；`python tool/check_audio_egress.py --selftest/--strict` | 唯一出网点（`R-OUT-4`）+ 音频零出境（`FF-24` 第 8 条） | ✅ 两个 `--strict` 均 clean；`check_network_boundary.py --selftest` 7 个用例（4 必须抓到 / 3 必须放过）、`check_audio_egress.py --selftest` 5 个用例全部判别正确 —— 含第一版**放过名单写错**（`feature_config` 匹配不上生成的 `FeatureConfig.kt`）的那一个案例 |
| **"这个 APK 是哪一版 UI"**（`ADR-24` 加） | `python tool/ui_fingerprint_check.py <apk>` | 判定包内是 `ADR-24` 新 UI 还是旧 UI | ✅ `dist` 的 release 包 → `RESULT: ADR-24 UI` / `exit 0`；**负控**：`_toolchain/tmp` 里那份 4 ABI 旧包（2026-09-12 为模拟器所打）→ `PRE-ADR-24 (missing 8, stale titles 1)` / **`exit 1`**。内含**正控**（每版都有的字符串）—— 正控不中时判定式报"方法坏了"而不是"UI 缺失"，因为 Dart 字符串在 `libapp.so` 里是 UTF-16，用 UTF-8 搜必然全miss |
| **模拟器实际启动** | `powershell -File tool/run_on_emulator.ps1` | 六项判据：boot / install / top-resumed / 活进程 / 无崩溃 / 首帧+截图非空白 | ✅ exit 0；`Fully drawn …MainActivity: +4s668ms` |
| **设备端持久化** | `python tool/device_db_probe.py --insert --dump` + 冷启动 | 数据库真的建立、迁移真的跑过、数据真的读得回来 | ✅ `files/acoudiet.db` 49,152 B、`integrity_check=ok`、`user_version=1`、四表列名逐字符合 DDL；冷启动后首页 `本周记录 1 次` / `约 104–156 kcal` |
| **Android SQLite 通道** | `flutter test test/data/channel_sqlite_test.dart` + `python tool/check_bridge_symmetry.py --strict` | 通道名与 7 个方法的侧侧对称、参数形状、错误码映射 | ✅ 13 项协议测试全过；对称性门禁含负例实测（改错一个方法名立即 FAIL） |

> 📌 **为什么需要 `check_l4_usage.py`**：本环境**无法**对 Flutter 代码跑 `dart analyze`
> （框架依赖 `characters` / `material_color_utilities` / `vector_math`，本机与 pub 缓存里都不存在；
> `tool/analyze_flutter.py` 记录了这次尝试与所需包）。于是"调用了不存在的参数/成员"这一整类缺陷
> 都不可见 —— 而它不是假设：人工审查就在 `bootstrap.dart` 里发现
> `AppServices.assemble(maintenance: ...)`，而参数名是 `maintenanceRepo:`，这一处**任何纯 Dart 测试
> 都编译不到**。该检查器把这类问题变成可执行判据，并用注入负例证明它不是空转。

**合计（app/ 侧，离线）：777 项断言**（L4 纯域 193 + L3 数据 63 + 会话 121 + UI 400）
+ **`flutter test` 119 项**。
另有 18 个 patch 的跨语言逐元素比对 + 模型 parity 实测 + 六条防泄漏断言，0 失败。

> 📌 **为什么防泄漏要有一个独立实现**：`SPEC-T-02` 要求这六条断言跑在切分代码里 —— 那意味着
> 同一个程序既产生切分又宣称它干净。`tool/check_split_leakage.py` 只读四个 CSV 与 SSOT，
> 是第二份实现，切分器自身的 bug 藏不住。它在本轮就抓到了**我自己**的一处错误假设
> （曾以为 `val.csv` 全是公共语料，而 `API-06` §3.2 明确允许 `P04`/`P05` 只进验证集）。

### 2.1 `app/test/**` 如何在无网络环境下执行

`SPEC-C-05` 的判据以 `flutter test app/test/...` 命名，而 `flutter pub get` 在本环境不可用。
`tool/run_offline_tests.py` 通过手工构造 `package_config.json` **真正执行**了这些文件：

| 文件 | 项数 | 结果 |
|---|---|---|
| `test/cfg/generated_constants_test.dart` | 5 | ✅ |
| `test/cfg/handshake_test.dart` | 5 | ✅ |
| `test/data/placeholder_metrics_test.dart` | 13 | ✅ |
| `test/domain/advice_rules_test.dart` | 11 | ✅ |
| `test/domain/behavior_analysis_test.dart` | 13 | ✅ |
| `test/domain/health_score_formula_test.dart` | 11 | ✅ |
| `test/domain/weekly_report_test.dart` | 8 | ✅ |
| **合计** | **66** | **✅ 0 失败** |

需要 Flutter 引擎的 10 个 widget/绑定文件（`test/ui/**`、`test/data/audio_event_channel_test.dart`）
被脚本识别并标注为「需真实 `flutter test`」，
**不计入通过**（它们在本轮真实 `flutter test` 下共 119 项全过）。两处必须踩对的环境细节记录在
`app/test/README.md` §2（语言版本下界、
子进程 UTF-8 解码），都是会**静默丢掉输出**的坑。

---

## 3. `SPEC-C-05` §5 判据 → 本仓测试名映射

| `SPEC-C-05` 判据 | 本仓对应断言 | 状态 |
|---|---|---|
| #1 预置演示数据分数 == UI 数字 | `session_tests.dart`：`demo dataset loads 28 records` + UI 套件的 `every drill-down number equals the domain evidence` | ✅ 域层；UI 侧见 §4 |
| #2 评分算例 A–D 逐值一致 | `pure_tests.dart`：`SPEC-A-01 worked example A/B/C/D` | ✅ 100 / 61 / 28 / 29 |
| #3 报告数字 == 域服务输出 | `pure_tests.dart`：`report score equals a direct service call` | ✅ |
| #4 总分 == 四维之和 | `pure_tests.dart`：`total = sum of rounded dimensions` + 算例 6 组 | ✅ |
| #5 `evidence` 键集无多键缺键 | `pure_tests.dart`：`evidence key sets` 四组 | ✅ |
| #6 ADR-15 求值顺序（p=0.30→22） | `pure_tests.dart`：`ADR-15 literal expression: p=0.30 -> 22 (not 23)` | ✅ |
| #7 ADR-05 端点（σ=30→20） | `pure_tests.dart`：`C.regularity = 20` | ✅ |
| #8 ADR-09 窗口（15:40 计入零食） | `pure_tests.dart`：`14 window boundaries` + `B.snackCount = 6`；`data_tests.dart`：SQL 侧同样计数 | ✅ |
| #9 防泄漏断言（T-02） | `ai/` 侧套件 | 见 `ai/reports/` |
| #10 parity 三判据 | `mel_parity_test.py` + `ai/` 的 `t08` | ✅ Mel 侧通过 |
| #11 1:1 不变量与占位行 | `data_tests.dart`：`I-1: a placeholder metrics row exists` | ✅ |
| #12 单事务回滚 | `data_tests.dart`：`I-3: failed transaction leaves no partial record` | ✅ |
| #13 无 BLOB / 无音频列 | `data_tests.dart`：`no BLOB / audio / mel / pcm column exists` + `binding a BLOB parameter is refused` | ✅ |
| #14 区间语义左闭右开 | `data_tests.dart`：`range is left-closed` / `right-open` | ✅ |
| #15 键集完整（6 类 / 24 小时） | `data_tests.dart` + `pure_tests.dart` | ✅ |
| #16 可复现（同库同窗两次相同） | `data_tests.dart`：`same database + same window -> identical aggregate`；`pure_tests.dart`：`same database + same window -> identical output` | ✅ |
| #17 `week() ≡ summary(本周窗口)` | `data_tests.dart`：`week() equals summary(last 7 local days)`；`pure_tests.dart` 同断言 | ✅ |
| #18 纯函数性（无 `DateTime.now`/`Random`/`http`） | `rg -n "DateTime\.now|Random\(|http" app/lib/domain` → 域层仅 `TimeUtil.nowMs()` 一处（**唯一时钟入口**，且以 `clock:` 注入，测试全部固定） | ⚠️ 见下 |
| #19 文案红线（FF-25） | `pure_tests.dart`：`no FF-25 banned wording`；`session_tests.dart` 全部自检 `observed` 文本；UI 套件 | ✅ |
| #20 静默 patch 仍进 EMA 且不触发推理 | `pure_tests.dart`：`a silent patch still advances the EMA`；`session_tests.dart`：`a silent patch does not run inference` | ✅ |
| #21 90 s 静音自动结束 | JVM 套件：`silenceEndsAt90s_patchCount == 180`、`30sOfSilence_doesNotEndSession` | ✅ |
| #22 包络形状 819 / hop 5 | JVM 套件 + `pure_tests.dart` + `session_tests.dart` | ✅ |

**#18 的诚实说明**：域层**没有**在计算路径里读时钟 —— `HealthScoreService` / `ReportService`
的窗口由调用方传入，`StatsRepoImpl` 的"当前窗口"查询通过可注入的 `clock` 参数取得
（生产值为 `TimeUtil.nowMs()`，测试固定为夹具锚点）。也就是说 `DateTime.now` 在
`app/lib/domain/**` 的命中数为 **0**，`TimeUtil.nowMs()` 只在 `core/` 与装配层出现。

---

## 4. 待完成的验证（诚实记录）

| 项 | 为什么未完成 | 何时做 |
|---|---|---|
| `flutter test` / `flutter build apk` | 无网络，依赖与 Gradle 缓存均不可解析 | 恢复网络后在普通终端执行 |
| 真机握手与端到端闭环（CP2） | 需要 Android 设备（`adb`） | D5 |
| `delegateInUse` 实测（XNNPACK/NNAPI/CPU） | 需要真机与 `libtensorflowlite_c.so` | D4 |
| `T-07` 制品三 hash 闭环 | 需要训练产物（`ai/` 侧正在生成） | D4 |
| UI presenter 套件 | 由 UI 子任务收尾中（`app/tool/ui_presenter_tests.dart`） | 本日 |
| 三种 Demo 模式现场实测（CP3） | 需要真机与现场 | D9 |

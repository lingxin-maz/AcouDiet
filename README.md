# AcouDiet（声膳）

**基于端侧 AI 声学感知的无感饮食识别与健康管理助手。** 手机麦克风听咀嚼声，识别正在吃什么，据此给出健康评分与建议 —— 不录像、不说话、不联网、音频不离开设备。

| | |
|---|---|
| **平台** | Flutter 3.24.5 / Dart 3.5.4 ｜ Android `minSdk 24` / `targetSdk 34` ｜ 包名 `com.acoudiet.app` |
| **端侧模型** | TFLite FP32，`128×128` Mel 张量 → 6 类（`chips / cabbage / gummies / noodles / carrot / drink`） |
| **隐私** | 核心链路完全离线；`offline` 风味连 `INTERNET` 权限都不申请；**音频在任何风味下都不离开设备**（`FF-24` 第 4/5/8/9 条，`ADR-44`） |
| **许可** | [Apache-2.0](LICENSE) |
| **依据** | `docs/common/PLAN-01_开发顺序与依赖图.md` 的依赖序（序 1–29 为 v1.0；序 30–33 为 `ADR-44` 的 v2.0 工作流，见其 §10） |

---

## 0. 拿到仓库后从哪开始

### 0.1 目录导览

| 你想做什么 | 去哪 |
|---|---|
| 读 / 改 App（界面、域逻辑、数据层） | `app/` —— Flutter 工程，含 Kotlin 原生音频层 |
| 训练 / 评估 / 量化 / 导出模型 | `ai/` —— 离线训练工具链 `T-01…T-08` |
| 跑回归、出包、换模型 | `tool/` —— 生成器与全部验证闸门 |
| 换上自己训练的出厂模型 | `models/v1.3/`（随仓库交付的模型包）+ `tool/install_model.py` |
| 查「为什么这么设计」 | `docs/01_裁定记录ADR.md`（ADR 日志，60+ 条裁定）、`docs/common/SPEC-00_总则与冻结事实.md`（宪法） |
| 查「具体做什么、怎样算做对」 | `docs/` —— 按 `frontend/` `backend/` `common/` 拆分的 SPEC 树，每功能一个文件夹 |
| 看实测证据、合规材料 | `records/` —— `reports/`（实测与裁定）、`compliance/`（C-01…C-06）、`demo/`（设备跑测记录） |
| 看 UI 设计稿与功能汇总 | `design/` —— 软件 UI 界面设计图、APP 期望功能汇总、计划书文本提取件 |
| 看发布账本（发过哪些字节） | `release/` —— `RELEASE_*.md`、`apk_sha256.txt`、`analyze_*.txt`（APK 本体不入库，见 §0.5） |

### 0.2 唯一真源（SSOT）—— 动手前必读

`shared/feature_config.json` 是本项目**唯一真源**：Mel 参数、三档阈值、评分权重、类别表全部只在这里定义一次。
**任何常量都不要手改**，改 SSOT 然后重新生成：

```bash
dart run tool/gen_feature_config.dart
```

它会同时重写三处生成物：`app/lib/core/feature_config.g.dart`、`app/android/.../config/FeatureConfig.kt`、`app/assets/feature_config.json`（字节相等副本）。
`tool/verify_all.ps1` 的第一步与 CI 都是「重新生成，然后要求 `git diff` 为空」，所以生成物与 SSOT 不可能长期不一致。

### 0.3 跑一遍完整回归

```powershell
pwsh -File tool/verify_all.ps1          # 20 步，全过才 exit 0
```

它驱动 Kotlin JVM 套件、Dart L3/L4/L5 套件、真实 `flutter test`（两个风味各一次）、跨语言 Mel 对齐闸门、以及 15 个 Python 静态闸门（网络边界 / 音频出境 / SSOT 漂移 / 模型制品 / Android XML / PS1 编码 …）。
单跑其中某一步、以及这些闸门各自在防什么，见 `records/compliance/C-05_regression_checklist.md`。

### 0.4 换一个出厂模型

`models/v1.3/` 是随仓库交付的模型包（`models/acoudiet_fp32.tflite` + `class_labels.json` + `MANIFEST.sha256` + 集成说明）：
出厂 `.tflite` 直接放进仓库是**刻意的**（4 MB），提交它才能让构建可复现。

```bash
python tool/evaluate_shipped_model.py     # 用仓内冻结链路实测出厂模型的精度与延迟
python tool/install_model.py              # 校验 sha256 后装进 app/assets/models/
python tool/verify_artifacts.py           # 制品闸门：size / sha256 / 与 model_card 一致
```

`tool/verify_artifacts.py` 有一条闸门（`ACD-ART-006`）要求实测报告的 `model.sha256` 等于当前出厂的 `.tflite` —— 换了模型而不更新报告，闸门会红。

### 0.5 环境变量与「什么东西不在仓库里」

本项目的开发环境在 `_toolchain/`（Flutter、JDK 17、便携 CPython + site-packages、Android SDK，约 26 GB），
**刻意不进版本库**；`*.apk` / `*.aab` / `*.safetensors` / `*.docx` / `*.zip` 同样忽略（原因逐条写在 `.gitignore` 里，含一次「1.95 GB APK 差点被推上去」的事故记录）。

所有入口脚本都**优先读环境变量**，不设时才回落到作者本机的绝对路径 `D:\Desktop\Food\_toolchain`：

| 变量 | 指向 |
|---|---|
| `ACOUDIET_TOOLCHAIN` | 工具链根目录（内含 `flutter/`、`jdk17/`、`android-sdk/`、`dl/python/`、`site-packages/`） |
| `ACOUDIET_PYTHON` | Python 解释器可执行文件 |
| `ACOUDIET_FLUTTER` | `flutter.bat` |
| `ACOUDIET_SQLITE` | Windows 上跑 L3 数据层套件所需的 `sqlite3.dll` |
| `ACOUDIET_SSOT` | 覆盖 SSOT 路径（默认 `shared/feature_config.json`） |

另两处**故意不发布**的目录：`建议模型/`（模型选型调研，含 543 MB safetensors）与 `讨论资料/`（过程草稿与计划书）。它们已被 `.gitignore` 挡在仓库外，文中提到它们的段落（如 `docs/release/llm_on_device_conversion.md`）是历史记录。

### 0.6 本次整理对应的 ADR

仓库根从「工作区根 + `AcouDiet/` 子目录」重排为「仓库根就是 AcouDiet 工程本身」，
`AcouDiet/docs/` 重命名为 `records/`。改动清单、路径映射表与不改变的项见
`docs/01_裁定记录ADR.md` 的 **ADR-51**。

---

> 🆕 **`ADR-44`（2026-09-16）：产品交付两个 Android 风味。** `offline` 风味**不申请** `INTERNET` 权限（v1.0 姿态逐字节保留，可当场 `aapt dump badging` 验证）；`agent` 风味（**默认产品**）申请 `INTERNET`，并在其上叠加一个**默认关闭、需用户自备 DeepSeek API Key** 的云端智能体 —— App **不内置**任何 Key、**不代购**、**不共享额度**，首启须经一次可撤回的显式同意门。核心检测 / 记录 / 报告 / 三种 Demo 在 `agent` 风味下仍然完全离线可用（`FF-26f`），且**全仓只有一个出网点**（`G-01` 的 `DeepSeekClient`，`API-05` §1 的 `R-OUT-4`）；崩溃上报 / 分析埋点 / SDK 遥测仍然禁止。**音频（PCM / Mel 张量 / 音频文件）在任何风味、任何版本下都不离开设备**（`FF-24` 第 8 条，现行最强主张）。外卖是**检索 URL 交接**，不是代下单（`FF-26i`）。详见 `API-07`、`SPEC-C-06` 与 `records/compliance/C-01_privacy_checklist.md`。

---

## 1. 目录结构

```
<仓库根>                            ★ 仓库根就是 AcouDiet 工程本身（ADR-51）
├── README.md                        本文件
├── LICENSE                          Apache-2.0
├── .github/workflows/verify.yml     CI：SSOT 漂移 + flutter test
│
├── tool/                          ★ 生成器与验证脚手架
│   ├── gen_feature_config.dart      C-03：SSOT → Dart / Kotlin 常量 + assets 副本
│   ├── gen_demo_dataset.py          A-04：生成 app/assets/demo_dataset.json
│   ├── jvm_build.ps1                P-02/P-03/P-04：编译并运行 Kotlin DSP 的 JVM 套件
│   ├── pure_tests.dart / data_tests.dart / session_tests.dart / agent_tests.dart
│   │                                App 侧四套离线套件（L3 / L4 / L5 / 云端智能体）
│   ├── verify_all.ps1               **一键回归入口**（C-05）
│   └── check_*.py                   15 个静态闸门（网络边界 / 音频出境 / SSOT 漂移 / 制品 …）
│
├── app/                           ★ Flutter 工程（含 Kotlin 原生层）
│   ├── pubspec.yaml
│   ├── assets/                       feature_config.json（SSOT 字节相等副本）、foods.json、
│   │                                 demo_dataset.json、demo/sample_chews.wav、models/
│   ├── lib/
│   │   ├── core/                     feature_config.g.dart（生成物）、errors.dart、time.dart
│   │   ├── domain/                   L4 域层（**纯 Dart，无 Flutter 依赖**）
│   │   │   ├── model/                DietRecord / WeekSummary / HealthScore / Advice …
│   │   │   ├── repository/           API-03 契约（DietRepo / StatsRepo / ProfileRepo / MaintenanceRepo）
│   │   │   └── service/              ScoreFormulas / HealthScoreService / AdviceEngine /
│   │   │                             ReportService / VoteAggregator / BehaviorAnalyzer /
│   │   │                             FoodKnowledgeBase / Handshake / DetectionSession /
│   │   │                             DemoController
│   │   ├── data/                     L2+L3：SQLite（dart:ffi）、DAO、Repo、桥接、TFLite
│   │   ├── presentation/             L5：主题、组件、页面、状态管理
│   │   └── (main.dart)
│   ├── android/app/src/main/kotlin/com/acoudiet/app/
│   │   ├── config/FeatureConfig.kt   （生成物：编译期常量 + 15 字段握手，ADR-21）
│   │   ├── config/NativeCapabilities.kt
│   │   ├── audio/                    **纯 Kotlin DSP（可在 JVM 上单测）**：
│   │   │                             RingBuffer / Preprocess / Fft / MelFilterBank /
│   │   │                             MelFrontend / EnvelopeExtractor / Vad /
│   │   │                             SessionStateMachine / AcouDietException
│   │   ├── android/                  Android 宿主：AudioRecord 采集、会话管理、
│   │   │                             MethodChannel/EventChannel、cacheDir 清理
│   │   ├── agent/                    ADR-44 `agent` 风味的平台交接与同意门
│   │   └── MainActivity.kt
│   └── android/app/src/test/kotlin/  JVM 套件（79 断言）+ MelDump 对齐工具
│
├── ai/                            ★ 离线训练工具链 T-01…T-08
│   ├── src/config.py                 SSOT 读取（唯一写入口仍是 shared/）
│   ├── src/features.py               冻结音频→Mel 链（Python 侧，T-08 的一半）
│   ├── scripts/mel_parity_test.py    **跨语言 Mel 对齐闸门 + 模型 parity 实测**
│   ├── scripts/make_parity_wavs.py   确定性对齐语料（14 个 wav，含 2 个 3-patch 长音频）
│   ├── data/splits/                  train / val / test_public / test_mobile（防泄漏已校验）
│   └── artifacts/                    parity_report.json / metrics_shipped_model.json / runs/ …
│
├── models/v1.3/                   ★ 随仓库交付的出厂模型包
│   ├── models/acoudiet_fp32.tflite   出厂权重（sha256 见 MANIFEST.sha256）
│   ├── class_labels.json  feature_config.json  MANIFEST.sha256
│   └── README_集成说明.md
│
├── shared/feature_config.json     ★ 唯一真源（SSOT）—— 改常量只改这里
│
├── docs/                          ★ 规格与裁定（「为什么这么做」）
│   ├── 00_功能清单与数量分析.md · 01_裁定记录ADR.md（ADR-01…ADR-51）
│   ├── common/SPEC-00_总则与冻结事实.md     宪法：冻结参数、术语与文案禁令
│   ├── common/ · backend/ · frontend/       每功能一个文件夹：SPEC-*（做什么）+ PLAN-*（怎么交）
│   └── release/                             LLM 选型与许可归档（历史）
│
├── records/                       ★ 交付记录与证据（原 `AcouDiet/docs/`）
│   ├── reports/                      实测记录与事故复盘
│   ├── compliance/                   C-01…C-06 合规证据（隐私清单 / 同意 / 构建签名 / 回归 …）
│   └── demo/                         三模式演示与模拟器跑测记录（含截图与 logcat）
│
├── design/                        ★ 设计资料
│   ├── 软件UI界面设计图/              6 张独立设计稿
│   ├── APP期望功能汇总/               架构定版 + 页面功能规格
│   └── 计划书文本提取件/              计划书 docx 的纯文本版（可搜索）
│
└── release/                       ★ 发布账本（APK 本体已忽略，这里只留可核验的字节凭据）
    ├── RELEASE_1.3.*.md              归档索引
    ├── apk_sha256.txt                历次发布 APK 的 sha256
    └── analyze_*.txt                 `flutter analyze` 原始输出
```

---

## 2. 怎么跑

```powershell
# 每个新终端一次（提供工具链）
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1   # 或指向你自己的工具链

cd D:\Desktop\Food          # 仓库根

# ① 重新生成双侧常量（改了 shared/feature_config.json 之后必须跑）
& "$env:ACOUDIET_HOME\flutter\bin\cache\dart-sdk\bin\dart.exe" tool\gen_feature_config.dart

# ② Kotlin DSP（P-01/P-02/P-03/P-04）编译 + JVM 单测
powershell -File tool\jvm_build.ps1 -Run

# ③ L4 纯逻辑（评分算例 / 建议 / 周报 / 聚合 / 行为分析）
& "$env:ACOUDIET_HOME\flutter\bin\cache\dart-sdk\bin\dart.exe" app\tool\pure_tests.dart

# ④ L3 数据层（真实 SQLite；Windows 上把 ACOUDIET_SQLITE 指向 sqlite3.dll）
$env:ACOUDIET_SQLITE = "D:\Anaconda\DLLs\sqlite3.dll"
& "$env:ACOUDIET_HOME\flutter\bin\cache\dart-sdk\bin\dart.exe" app\tool\data_tests.dart

# ⑤ 握手 / 会话 / 演示 / 14 项自检
& "$env:ACOUDIET_HOME\flutter\bin\cache\dart-sdk\bin\dart.exe" app\tool\session_tests.dart

# ⑥ 执行 SPEC 点名的 app/test/** 套件（离线，无需 pub get）
$env:PYTHONPATH = "$env:ACOUDIET_SITE"
& "$env:ACOUDIET_PY" tool\run_offline_tests.py

# ⑦ C-02 伦理准入（先签后用）
& "$env:ACOUDIET_PY" tool\check_consent_registry.py --strict

# ⑧ 跨语言 Mel 对齐闸门（Kotlin ↔ librosa）
& "$env:ACOUDIET_PY" ai\scripts\mel_parity_test.py --n 12

# ⑨ 以上全部（推荐）
pwsh -File tool\verify_all.ps1
```

> ✅ **App 现在能构建、能跑测试、能出包了。**（此前本仓记录「无网络、无法 `pub get`」是**测量错误** ——
> 那是 PowerShell/curl 在本机的 schannel 凭证链坏掉所致（`SEC_E_NO_CREDENTIALS`），
> 换 Python/Dart/Java 走 HTTPS 一直通。）补齐 `flutter` 框架自身缺的三个包之后：
> `flutter pub get` 成功（62 个依赖）、`flutter analyze` **0 error**、`flutter test` **91 项全过**、
> `flutter build apk --debug` **出包成功**；`flutter build apk --release` 按 `SPEC-C-04` 如期
> 要求 `key.properties`。这个过程修掉了 **6 个从未被编译器看过的代码缺陷**（含 FFI 签名错误、
> 两个非法 XML 清单、一个让 debug 构建必失败的 Gradle 配置），完整清单见
> `records/reports/c04_dependency_deviation.md` §6。
>
> ⚠️ 仍未做：**真机上的实际启动**（本机 `adb devices` 为空），以及**成品 `.tflite` 的投放**
> （按用户决定不训练；未投放时检测页如实显示 `ACD-INF-001`，不假装模型可用）。

> 🔄 **2026-09-12 · 模型 I/O 契约已冻结并改为可执行校验（ADR-20）**：模型组报告的结论
> 「INT8 **权重** + **float32** I/O」与本仓一致 —— 但依据不同：`ai/src/quantize.py`
> 是**显式**设置 `inference_input_type` / `inference_output_type = tf.float32` 的（并拒绝导出
> I/O 非 float32 的产物），不是"依赖默认值"。由于「INT8 模型」有两种都合法的读法，App 侧
> 新增 `ModelIoContract` 与加载期校验：张量字节数必须与 float32 一致（主判据，不依赖任何可选
> 符号），`TfLiteTensorType` 可用时再交叉验证。int8/uint8 I/O 的模型会被**当场拒绝并点名
> dtype**，而不是以误导性的「模型输入不匹配」收场。
>
> ✅ **同轮修掉了它**：`app/android/app/build.gradle` 已加
> `implementation 'org.tensorflow:tensorflow-lite:2.16.1'`。选它而不是"最新"是实测结果 ——
> `2.17.0` 只发布**不含 `.so`** 的 jar，按"取最新"钉版本会把同一个 bug 带回来；2.16.1 的 AAR
> **导出 Dart 绑定所需的全部 21 个 `TfLite*` 符号**（逐符号核过）。另修了一个 ABI 陷阱：
> Flutter 的 `--target-platform` **不过滤第三方 AAR 的 native**，加库后 release 一度 17.1 → 31.1 MB；
> 现在可用 `--android-project-arg=acoudietAbis=arm64-v8a` 裁到 **20.4 MB**（默认保留全部 ABI，
> 因为模拟器是 x86_64）。⚠️ 端到端装载仍需模型组制品；导出侧 TF 2.21 与 Android 端 2.16.1
> 有版本差，故自检第 3 项会显示 `loaded (runtime 2.16.1)`，让差异在设备上可见。

> 🔄 **2026-09-12 · FF-19 类别表已正式修订（ADR-19）**：训练侧交付的语料六类为
> `chips / cabbage / gummies / noodles / carrot / drink`，替换了原 `apple`(1)、`cookie`(2)、
> `bread`(3)。其中 `noodles` 原本是明文「不进 v1.0」的**储备类别**，因此这是一次**修宪**：
> 拆掉了它身上的四道结构性防线（制品门禁 / 消融禁用清单 / Schema 枚举 / SPEC 禁词），
> **`nuts` 仍是储备类别**。id 位置不变，所以 `structure.healthy_labels` 的 id 集合仍是 {1,3,4}，
> 四个评分算例的算术完全不变。执行记录、改动清单与设备实测证据见
> `records/demo/ADR19_class_table_change.md`；裁定理由见 `docs/01_裁定记录ADR.md` ADR-19。
>
> ⚠️ 同一次设备实测还暴露并修复了**第二个缺陷**：改类表后，数据库里**先于本次修订**写入的记录
> 带有已退休的 label（如 `bread`），而按类聚合会主动对未知 label 抛 `ACD-KB-001` —— 一条这样的
> 老记录就能让**整个首页**变成错误页。已新增 **schema 迁移 v2**（`schemaVersion` 1 → 2）按位置
> 无损改名；三条语句同时校验 id 与旧 label，因此可重复执行、且 id/label 矛盾的脏数据不会被「猜」。
> `attribute` 刻意不改（`API-03` §2 规定它是写入时快照）。

> 🔄 **2026-09-13（第二批）· 用户反馈的 7 项已落地（`ADR-23`）**：
> ① **用量按时长动态推算**：知识库每条新增 `unit`/`standardAmount`/`amountPerSecond`/`minAmount`/`maxAmount`，
> 新增纯域 `PortionEstimator`（`amount = clamp(rate×时长)`、`kcal` 按量等比），SQL 热量改为**逐条**求和
> —— 修复前任何记录都显示同一句固定标准份量（「1 碗（约 200g）」）。
> ② **液体不再算零食**：新增 `isSnackRecord`/`isMealSample`，`drink` 类既不计零食也不进 σ 样本（此前下午的
> 饮料既算零食又进自己的类别列 = 同一条计两次）；「晚间进食」刻意保持纯时间。
> ③ **首页四维与事实同步**：评分窗口由**当天**改为**最近 7 天**（σ 与速度在单日窗口下几乎永远无定义，
> 这正是「规律性/速度总是 `--`」的原因）；「食物结构」在记录数 < 3 时不再显示 30/30；卡片新增依据行
> `记录 N 次 · 零食 n 次 · 有咀嚼指标 m 条`；文案改为「近 7 天健康评分 / 较上一周期」，Δ 改为**上一等长窗口**。
> ④ **报告补「每日四维评分」**：`ReportService.dailyScores` 逐日评分，报告页新增按天列表并**补回四维雷达**。
> **④b 报告页改为双分栏**（用户后续追加）：底栏「报告」**一个入口**，AppBar 下 `SegmentedButton`（每日 / 本周）
> 且**左右滑动即可切换**，`PageView` 的 `initialPage = 0` 使**默认停在「每日」**；每日分栏 = 日期选择器 +
> 当日得分卡（含雷达、可下钻）+ 当日汇总（记录次数 / 估算热量 / 零食次数 / 食物类别）+ 按天四维列表。
> `DailyScore` 随之扩展为「一天的完整汇总」，`dailyScores` 每天一次 `stats.summary(day)` 取真实计数与热量。
> ⑤ **检测页行为行实时联动**：`BehaviorAnalyzer.snapshot()`（不封闭）+ `DetectionState.metrics`，约 1 Hz 刷新。
> ⑥ **全页面下拉刷新**：新增 `RefreshableBody`，**空态/错误态也能拉**（此前那些分支不可滚动，拉不动）。
> ⑦ **切 Tab 先刷新完再呈现**：新增 `AcouNotifier.reloadFresh()`（先丢弃旧值再加载），`AppShell._select` 调用。
> 证据：`flutter test` **119 全过**、离线 **777 项**（PURE 193 / SESSION 121 / UI 400 / DATA 63）、
> `flutter analyze` 0 error 且 issue 种类与上一版基线逐条相同、两个 checker PASS；
> `dist/` 两个 APK 已重打（release 指纹见 `records/demo/PHONE_INSTALL.md` §0）。
> 报告：`records/reports/adr23_portions_dims_refresh.md`；裁定：`docs/01_裁定记录ADR.md` ADR-23。
> ⚠️ 同轮修正了一处**测试夹具缺陷**：`session_tests` 过去给所有 patch 传 `tStartMs = 0`，行为分析器收到
> 时间戳重叠的包络，平均咀嚼间隔实测 0.059 s（合成峰列应是 0.7 s），而该值只被断言过"非空"。

> 🔄 **2026-09-13 · 真机缺陷「只能识别一次」已修复（本次修复的第三个设备端缺陷）**：
> 用户真机反馈「第一次能识别，之后点再次检测只看到麦克风开了，波形和识别都不动」。
> 根因不在识别链路，而在**事件流的会话绑定**：`EventChannel.receiveBroadcastStream` 的参数是
> **调用时捕获一次**的（`platform_channel.dart:676` 每次 0→1 监听都用同一份 `arguments` 重发
> `listen`），而 `MethodChannelAudioBridge.events()` 用 `_stream ??=` 把**第一个会话的流**缓存给了
> 所有后续会话；原生 `AudioBridgeAndroid.emit()` 又按 `subscribedSessionId` 过滤，于是第二个会话的
> `level` 与 `patch` **被全部静默丢弃**（麦克风由 `startSession` 打开，与订阅无关 —— 所以隐私指示灯
> 亮着、采集在跑、界面全死）。还有两处必须同时修：`DetectNotifier.stop()` 从不释放 `level` 订阅
> （广播流监听数永远不归零 → 原生收不到 `onCancel`，而且旧流重订阅时会把旧 id 再发一遍），以及
> 原生 `onCancel` 无条件清空（迟到的旧 `cancel` 会掐掉正在跑的新会话）。
> 修法：流**按会话**缓存并重建、`stop()` 里 `await handle.dispose()`、原生改为
> `clearSubscription(sessionId)` 只释放 id 对得上的订阅；另按 `SPEC-U-02 §2.3` 把 `confirmed`/`ending`
> 归入运行态（修复前结果卡片旁边会冒出第二个「开始 AI 检测」，点下去必被 `ACD-SESS-002` 拒绝，
> 把在跑的会话变成没有入口可停）。
> 证据：新增 `app/test/data/audio_event_channel_test.dart`（5 项，直接断言 `listen`/`cancel` 载荷）；
> **负例对照实测**——把 `events()` 改回 `_stream ??=` 后该套件立刻红：
> `Expected: ['S-1','S-2'] / Actual: ['S-1','S-1']`。`flutter test` **110 项全过**、
> `flutter analyze` 0 error 且 **81 issues 与上一版基线逐条相同**（未引入新问题）、离线套件
> UI 373→**377**、pure 174、session 102、L3 57、`run_offline_tests.py` 7 个可离线文件全过、
> `check_bridge_symmetry`/`check_l4_usage` 均 PASS。**`dist/` 两个 APK 已重打并核对**
> （release 25,466,638 B / `sha256 9c67a61f…14c4`，权限仍只有 `RECORD_AUDIO`、无 `INTERNET`、
> 仅 arm64-v8a、模型 sha256 与交付件逐字节相同；`apksigner verify` 与 `zipalign -c -p 4` 均 exit 0。
> profile 同批重打以保证 `dist/` 与源码一致）。报告：`records/reports/u02_second_session_event_binding.md`。
> ⚠️ 同一次排查发现**另一条尚未修复**的邻近缺陷（已登记在该报告 §5）：90 s 静默由原生自动结束时
> Dart 侧不知情（`sessionEnded` 被 `break` 忽略），页面不会自动进入 `ended`，该次会话的
> **已确认食物不会落库**；Demo 模式 B 经同一路径结束，记录同样不落库。

> ✅ **模拟器上已实测启动成功**（`tool/run_on_emulator.ps1`，exit 0）：`boot_completed=1` →
> `install: Success` → `top resumed activity is ours: True` → 无 `FATAL EXCEPTION` →
> `Fully drawn com.acoudiet.app/.MainActivity: +4s668ms` → 截图非空白。
> C-02 隐私说明弹窗、C-03 握手门禁、空态全 `--` 降级都在设备上真实生效。
> 截图与逐项证据见 `records/demo/emulator_run/RUN_RECORD.md`。
>
> ✅ **同一次实测暴露的 SQLite 缺陷已修复**（方案 A，零新依赖）：Android 无法 `dlopen` 系统
> SQLite（`libsqlite3.so` 不存在；`libsqlite.so` 不在 `/system/etc/public.libraries.txt` 里），
> 原先 App 会降级到内存实现、**数据不持久化**。现在改走独立通道
> `com.acoudiet.app/sqlite` → **平台自带**的 `android.database.sqlite`。
> 实测：设备上出现 `files/acoudiet.db`（49,152 B、`integrity_check=ok`、`user_version=1`、
> 四表列名逐字符合 DDL），冷启动后首页读到 `本周记录 1 次`、`约 104–156 kcal` 与真实记录卡片。

> ⚠️ **离线套件仍是一等公民**：`flutter pub get` 可用之前，本仓把承载逻辑的代码都写成
> **纯 Dart / 纯 Kotlin**，用 `dart.exe` 与 JDK 直接编译执行 —— 上面的 ①② 与 ③④⑤ 就是官方套件
> 在无 Flutter 工具链时的等价执行方式，现在依然全绿（**22 步**）。

---

## 3. 已完成与验证状态（实测，非预测）

| 层 | 内容 | 验证方式 | 结果 |
|---|---|---|---|
| 配置 SSOT | `feature_config.json` → Dart/Kotlin 常量 + assets 字节相等副本 | `tool/gen_feature_config.dart` | ✅ 44 数值键（顶层键 49），`assets/feature_config.json` 与 SSOT 字节相等 |
| **P-04 Mel 前端** | 手写 FFT + Slaney 滤波器组 + **patch 相对 `power_to_db`** + **丢弃尾帧** + **per-patch minmax**（`ADR-21`） | `jvm_build.ps1 -Run` | ✅ 张量 `128×128`（STFT 原始 129 帧）、值域 `[0,1]`、行主序、确定性（**79 项**） |
| **T-08b 跨语言对齐** | Kotlin `MelFrontend` vs `librosa`，含**非零 offset**（流式预加重前驱）与模型 parity | `ai/scripts/mel_parity_test.py --n 14` | ✅ **`maxAbsDiff = 5.96e-08`**（阈值 `1e-3`），预处理逐元素 `0.0`；**`labelMatch = 1.0000`、`maxConfDelta = 8.34e-07`**（18 patch，实测非写死） |
| P-01/P-02 | 环形缓冲、会话状态机、VAD、90 s 静音、819 点包络 | JVM 套件 | ✅ 含 3 条非法迁移、容量覆盖语义 |
| P-03 预处理 | **无去直流**（`ADR-21` 移除）/ 流式预加重（前驱样本跨 patch 传递）/ 无高通 / 无跨 patch 可变状态 | JVM 套件 | ✅ 含「取了 0 当假前驱」的对照断言 |
| A-01 评分卡 | FF-22 四维 + `evidence` 键集 + ADR-15 字面求值 | `pure_tests.dart` + `app/test/domain/health_score_formula_test.dart` | ✅ **算例 A/B/C/D 逐值一致：100 / 61 / 28 / 29**；`p=0.30→22`（非 23） |
| A-02 建议 | 五条规则 + 唯一 `general` 免责声明 + 40 字上限 | `pure_tests.dart` + `app/test/domain/advice_rules_test.dart` | ✅ 含 FF-25 禁用词扫描、100 次排序稳定 |
| A-03 周报 | `summaryText` 模板、7 键 `deltas`、趋势补点 | `pure_tests.dart` + `app/test/domain/weekly_report_test.dart` | ✅ 含 `+20%` 环比由真实数据算出 |
| P-06 聚合 | EMA / 连续判据 / `tau` 分档 / 静默仍进 EMA | `pure_tests.dart` | ✅ 13 项 |
| P-07 行为 | 平滑 / 动态阈值 / 宽峰与孤立峰过滤 / 速度三档 | `pure_tests.dart` + `app/test/domain/behavior_analysis_test.dart` | ✅ 含 1 峰→三字段 null（不用 0） |
| D-01…D-05 | 建表 / 迁移 / DAO / 仓储 / 统计聚合 / 档案 / 清除 | `data_tests.dart`（真实 SQLite）+ `app/test/data/placeholder_metrics_test.dart` | ✅ I-1/I-2/I-3 全绿、窗口边界、键集完整、可复现 |
| C-03 握手 | **15 字段**逐字段比对（`ADR-21`），不符即 `ACD-CFG-001` | `session_tests.dart` + `app/test/cfg/handshake_test.dart` | ✅ 含篡改构造用例；`rawMelFrames`/`preemphasisBoundary`/`powerToDbRef`/`normalization` 四个新字段各有陈旧值被拒的断言 |
| P-05/P-06/P-07 会话 | 静默不推理但仍进 EMA、确认落库、I-1 指标行 | `session_tests.dart` | ✅ 17 项 |
| M-01…M-04 | 三模式切换、Mode B 注入、14 项自检 | `session_tests.dart` | ✅ 14 项顺序一致；`micInUseKnown=false` 不判失败；丢帧 >5% 给出步长提示 |
| C-02 伦理准入 | 「先签后用」变成可执行判据（含合成语料显式声明） | `tool/check_consent_registry.py --strict` | ✅ 4 条规则；未声明即报 `ACD-ART-002` |
| **L5→L4 调用面一致性** | 无 Flutter 分析器时的替代门禁：相对 import 可解析、冻结 API 的命名实参存在、被调成员确实存在 | `tool/check_l4_usage.py --strict` | ✅ 69 文件 / 195 类；**负例实测拦下 4 类注入缺陷** |
| **API-01 桥接对称性** | Kotlin 方法集 ↔ Dart 调用集、事件类型、**15 字段**握手名单（`API-01` §5 第 2 项「侧侧对称」） | `tool/check_bridge_symmetry.py --strict` | ✅ 13 个方法双向一致、3 个事件类型一致、15 个握手字段同名同序 |
| **模型投放契约** | 模型卡驱动加载；fp32/int8 两档均可投放；未知档位、帧数不符、卡缺失三类反例 | `app/tool/session_tests.dart` → `Model drop-in contract` | ✅ 含 `ACD-INF-001` / `ACD-INF-002` / `ACD-IO-002` 三条拒绝路径；并断言出厂卡**确有对应 `.tflite` 文件**而不只是契约 |
| **T-07/T-08a 管线** | INT8 导出 + 训练/部署对齐（未训练权重的管线校验，**不投放**） | `python ai/scripts/t07_export_int8.py --pipeline-check` | ✅ 1.05 MB ≤ 2.5 MB；`labelMatch=1.000000`、`maxConfDelta=0.001302`；`melParity` 保留 |
| **交付制品闸门** | 形状/类别/帧数/体积/**按档位取上限**/三 hash 闭环（独立于生产者的第二实现） | `python tool/verify_artifacts.py` | ✅ **exit 0 = PASS**（此前 exit 3 = 尚未投放）；实测 fp32 4,051,716 B ≤ 6 MB |
| U-01…U-06 / M-03 / M-04 | presenter 展示口径（含「预置演示数据分数 == UI 数字」） | `app/tool/ui_presenter_tests.dart` | ✅ **400 项** |

**合计（app/ 侧离线）已执行断言 777 项**（L4 纯域 193 + L3 数据 63 + 会话 121 + UI 400）
**+ `flutter test` 119 项 + 18 个 patch 的跨语言逐元素比对 + 模型 parity 实测 + 6 条防泄漏断言，0 失败。**

> ⚠️ **本轮验证边界（如实登记）**：交付模型的精度数字（fp32 55.7% / int8 52.5%）来自模型组，
> **本仓无法复测** —— `ai/data/splits`、`ai/data/raw`、`ai/data/augmented` 在本仓是空的，没有带标注语料。
> 本仓实测到的是：v1.1 链路下该 fp32 模型跑在本仓 20 s 演示音频上，32 个 patch 全部同一标签、
> 平均 top-1 置信度 0.839；v1.0 链路根本产生不出模型接受的张量。
> **真机/模拟器上的端到端装载已实测** —— 而这次实测抓到了本轮第二个真缺陷（`ADR-22`）：
> 第一次设备端运行时**应用一切正常**（安装成功、首帧绘制、无崩溃、截图非空白），但模型
> **加载失败**：`E tflite : Could not open 'assets/models/…_v1.0.0.tflite'.`（当时那份的文件名）
> 根因是 `TfLiteModelCreateFromFile` 要文件路径，而 Flutter asset 在 Android 上住在 APK 里；
> 已改为从内存建模（`TfLiteModelCreate`），修复后同一套判据全过且应用进程自行打出
> `Initialized TensorFlow Lite runtime`、`Could not open` 签名 0 命中。
> **教训**：`run_on_emulator.ps1` 的六项判据只看得到"应用能起来"，看不到"模型能用"。

**一键复跑**：`pwsh -File tool\verify_all.ps1`（**22 步**；修复 `ADR-21` 引入的缺陷后从「15 步中 5 步失败」变为全绿；`ADR-44` 再加入 `G-01..G-03` agent 离线套件与「云端出口边界」两个静态闸门。制品闸门此前在未投放模型时如实回报 exit 3「尚未构建」，现在模型已投放，回报 exit 0 = PASS）。

### 3.1 关于 `app/test/**`（`SPEC-C-05` §5 点名的测试名）

`SPEC-A-01`/`A-02`/`A-03`/`C-05` 把判据命名为 `flutter test app/test/...`。本环境无法 `pub get`，
因此 `tool/run_offline_tests.py` 手工构造 `package_config.json`（把 `flutter_test` 指向
`tool/shims/flutter_test`，并从本地 pub 缓存按 **每个包自己的 SDK 下界** 设定语言版本），
从而**真正执行**了这些文件：

```
test/cfg/generated_constants_test.dart      +5   全部通过
test/cfg/handshake_test.dart                +5   全部通过
test/data/placeholder_metrics_test.dart     +13  全部通过
test/domain/advice_rules_test.dart          +11  全部通过
test/domain/behavior_analysis_test.dart     +13  全部通过
test/domain/health_score_formula_test.dart  +11  全部通过
test/domain/weekly_report_test.dart         +8   全部通过
                                            ─── 66 项
```

需要 Flutter 引擎的 10 个 widget/绑定测试文件（`test/ui/**`、`test/data/audio_event_channel_test.dart`）
由脚本识别并标注为「需真实 `flutter test`」，不会被误报为通过。这 10 个文件在本轮真实
`flutter test` 下 **119 项全过**（见 §3 上方的 2026-09-13 记录）。

---

## 4. 交付记录

| 文件 | 内容 |
|---|---|
| `records/reports/t08_mel_parity.md` | 跨语言对齐的实测结果与判读 |
| `records/reports/p07_isolation_rule.md` | **FF-21d 孤立峰判据的冲突裁定**（按字面实现会让所有真实咀嚼归零） |
| `records/reports/u02_second_session_event_binding.md` | **真机缺陷「只能识别一次」的根因与修法**：`EventChannel` 订阅参数被缓存的会话绑定缺陷（含负例对照与重打 APK 的指纹） |
| `records/reports/adr23_portions_dims_refresh.md` | **`ADR-23` 执行记录**：用量按时长推算 / 饮品不计零食 / 首页四维同步 / 每日四维 / 检测实时行为 / 下拉刷新 / 切 Tab 刷新（含用户原话、逐条裁定与全部实测数字） |
| `records/reports/c04_dependency_deviation.md` | **依赖替换记录**：离线环境下 sqflite / Riverpod / fl_chart / tflite_flutter 的等价实现与代价 |
| `records/reports/p03_no_inference_gain.md` | 推理侧不施加响度增益的裁定（FF-08b 的直接推论） |
| `records/compliance/C-01_privacy_checklist.md` | 按风味的权限 / 唯一出口 / 音频不落盘与零出境的证据清单与验证命令 |
| `records/compliance/C-03_change_propagation_checklist.md` | 14 项变更传播单的本仓落地与机械验收 |
| `records/compliance/C-05_regression_checklist.md` | 回归套件映射（`SPEC-C-05` §5 表 → 本仓可执行命令） |

---

## 5. 成品模型：投放位置与低成本反馈

**本仓不训练模型。** 训练好的成品模型投放到 `app/assets/models/`，App 自动使用；
App 侧只保留一个几乎不耗电的反馈信号。完整契约见
`records/reports/model_dropin_and_feedback.md`。

**当前已投放**：`assets/models/acoudiet_fp32_v1.3.0.tflite`（4,053,556 字节，sha256 `31fba3ec…19f4`，
FF-16 的 fp32 档上限 6 MB 以内）。为什么是 fp32 而不是 int8：交付的三个制品里 fp32 公共测试集精度最高
（v1.3 交付说明称聚合 55.9%；int8 动态范围 52.5%），而第三个 `int8_fullint` 桌面 XNNPACK 直接拒载、
且 I/O 是真 int8，被 `ADR-20` 的 float32 I/O 契约拒绝。用户明确要求"按识别精度最高的来制作"；
**模型组 v1.3 的发布说明也已把 fp32 定为正式嵌入件**，两边结论一致。

> 📌 **`ADR-32`：v1.3 是真正的换模型（字节变了）。** `models/v1.3/models/acoudiet_fp32.tflite`
> 的 sha256 是 `31fba3ec…19f4`，取代了 `ADR-23` 那轮的 `705ffc62…560a`（那次交付件与本仓**逐字节相同**，
> 只改版本号；这次不是）。**I/O 与 Mel 前端契约完全不变**：`tool/compare_model_delivery.py` 实测
> Mel 不一致项 = 0、类别表 MATCH，`melVersion` 仍是 `1.1.0` —— 所以这次**只换文件，代码零改动**。
> 旧的 4 MB 字节已归档到不进包的 `ai/artifacts/model_archive/`（不是留在 `assets/` 里当死重）。
>
> ⚠️ **换模型必须重测 parity**：`tool/verify_artifacts.py` 只检查报告里的阈值与标志，
> **不校验报告测的是不是当前这份字节**。本轮已重跑 `ai/scripts/mel_parity_test.py --n 20`，
> 报告里的 `modelParitySource` 现在指向 v1.3.0 文件，实测 `labelMatch = 1.0`、
> `maxConfDelta = 1.52e-06`（闸门 0.98 / 0.05）、`melParity maxAbsDiff = 5.96e-08`。
>
> ```powershell
> python tool\compare_model_delivery.py D:\Desktop\Food\models\v1.3
> # 逐字节比对交付的 .tflite + 把交付包的 feature_config.json 与 SSOT 逐键比对 + 类别表
> ```

> ⚠️ **投放模型 ≠ 复制文件**。交付模型的 `feature_config.json` 描述的 Mel 前端与本仓原先冻结的
> 那套**不是同一套**（patch 相对 dB、per-patch minmax、丢弃尾帧、流式预加重、无 DC 去除）。
> `ADR-21` 已把 SSOT 与两侧前端改成交付规格，`melVersion` 随之 **1.0.0 → 1.1.0**。**换模型时若
> 前端规格又变了，必须重跑 `mel_parity_test.py`** —— 否则跨语言闸门仍会绿，但它只证明
> "Kotlin 与 Python 彼此一致"，看不见训练侧。

```powershell
# 手上已有成品模型（最省事的路径）
python tool\install_model.py --tflite D:\path\to\model.tflite --version 1.0.0
#   → 校验形状/类别/帧数/float32 I/O → 按档位量出 fp32|int8 → 算 sha256 与字节数 → 写模型卡 → 规范命名复制

# AI 侧正常产出（有可达标训练时）
python ai\src\quantize.py

# 独立复核（形状、类别、帧数、体积按档位取上限、三 hash 闭环）
python tool\verify_artifacts.py      # exit 0=通过 / 2=失败 / 3=尚未投放模型
```

* **文件名由模型卡推导**（`assets/models/<name>_<quantization>_v<version>.tflite`），不写在代码里，
  所以换模型不需要改代码，也不可能"静默加载旧模型"。
* `pubspec.yaml` 登记的是**目录** `assets/models/`，新投放的 `.tflite` 会被自动打包。
* 模型缺失或不合规时**不崩溃**：自检面板第 3 项（模型已加载）与第 11 项（版本与 `n_frames`）
  如实失败，检测页由 C-03 握手 + 自检门禁挡住。
* **反馈闭环（不在设备上训练）**：App 只写两个布尔列（`confirmed_by_user` / `corrected_by_user`，
  ADR-P6 已批准）加一个置信度；离线侧用 `python ai\scripts\ingest_feedback.py --input feedback.jsonl`
  把它变成"下一轮该补哪类数据"的优先级信号（设备不存音频，所以它是标签而不是样本）。

> ✅ **当前状态（`ADR-21` / `ADR-23` / `ADR-32`）**：`app/assets/models/` 里**已有成品模型** ——
> `acoudiet_fp32_v1.3.0.tflite`（4,053,556 字节，sha256 `31fba3ec…19f4`）。模型组交付了三个制品，
> 用户明确要求「按识别精度最高的来制作」，故选公共测试集精度最高的 fp32（`ADR-20` 契约同时排除了
> 真 int8 I/O 的 `int8_fullint`）。已实测：该 `.tflite` 以**逐字节相同的 sha256** 进了 APK、
> 模型卡与 `feature_config` 也一并打包、TFLite native 库四个 ABI 齐备，且跨语言 Mel/模型 parity
> 已**按新字节重测**（`ADR-32`）。见 `app/assets/models/README.md`。
>
> 本仓自身的导出/对齐**管线**同样已实测跑通（1.05 MB INT8、`labelMatch=1.000000`、
> `maxConfDelta=0.001302`），见 `records/reports/t07_t08_pipeline.md`；那里也记录了一个真实的
> 本机工具链缺陷（Keras 3.15 + TF 2.21 下 `from_keras_model` 必然失败，已加
> `from_concrete_functions` 回退）。
>
> ⚠️ **交付模型的精度数字本仓无法复测**（`ai/data/splits` 等为空，没有带标注语料），
> 引用时不得说成"本仓实测"。

---

## 6. 与文档不一致之处（必须知悉）

1. **第三方依赖**：`sqflite` / Riverpod / `fl_chart` / `tflite_flutter` 在本环境**无法解析**（无网络）。
   已用**同契约的自研实现**替代（`dart:ffi` → SQLite / TFLite；`ChangeNotifier` + `InheritedWidget`；
   `CustomPainter` 图表）。契约（`API-03` / `API-04`）与全部不变量保持不变。详见
   `records/reports/c04_dependency_deviation.md`。
2. **FF-21d 孤立峰**：字面实现与 `SPEC-P-07` §7 判据 5 自相矛盾，已按"3 个及以上峰视为咀嚼序列、
   1–2 个峰才做 300 ms 邻域判定"落地，并在报告中留痕。
3. **`melVersion` 来源**：SSOT 无 `mel_version` 键（`SPEC-C-03` §10 #2 未决）。本仓取
   `assets/models/model_card.json` 的 `melVersion`（即 `API-05` §7.1 闸门②的同一真源），缺失时回退 `1.1.0`；
   生成器据此产出 `FeatureConfig.melVersion` / Kotlin `MEL_VERSION`。⚠️ **这个回退值不是装饰**：
   它是"模型卡缺失时 App 拿什么去比对握手"的答案，`ADR-21` 之前它写死成 `1.0.0`，于是 Mel 前端
   升到 1.1.0 之后，所有没显式传版本的调用方都会拿一个**已经不能描述本构建**的数字去比对。
   另有一处同类缺陷一并修掉：`AppServices.expectedMelVersion` 的回退值也是 `'1.0.0'`，现改为读生成常量。
4. **训练数据**：`T-01` 需要下载公共数据集，本环境无网络。`ai/` 侧提供合成语料路径才能跑通全链路，
   真实数据的下载路径保留但会以 `ACD-ART-001` 明确失败。指标一律以实测记录，不填预测值。

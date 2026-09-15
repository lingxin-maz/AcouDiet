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

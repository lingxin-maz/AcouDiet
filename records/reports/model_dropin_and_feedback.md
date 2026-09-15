# 成品模型投放与低成本反馈闭环

**结论先说**：本仓**不训练模型**。训练好的成品模型由外部产出，直接投放到
`app/assets/models/`，App 自动使用；App 侧只保留一个**几乎不耗电**的反馈信号
（两个布尔列 + 置信度），供下一轮训练取舍数据。

理由（也是用户在本轮的明确指示）：离线环境无法完成一次可达标的训练（实测 2 个 epoch、
合成语料、`valAcc = 0.167`），继续训练只会消耗时间而不产生可交付物。**模型是可替换件，
不是本仓的产物。**

---

## 1. 投放位置与契约（唯一真源）

```
app/assets/models/
├── README.md                        ← 投放说明（人读）
├── model_card.json                  ← 15 字段模型卡（API-06 §5）
└── （~~acoudiet_int8_v1.0.0.tflite ← 成品 INT8 模型（≤ 2.5 MB，FF-16）~~ 旧表述，见下）
```

> 📌 **FF-16 两档都可交付（`ADR-21` 纠正）**：FF-16 原文一直是「FP32 ≤ 6 MB；INT8 ≤ 2.5 MB」。
> 本文件旧版只列 INT8 一件、并把 fp32 当成「打包错误」拒绝 —— 那不是 FF-16 的规定，而是 App 侧
> 只实现了 INT8 半档。本次交付并装载的是 **fp32 制品**（4,051,716 字节 ≤ 6 MB，见 §5）；
> INT8 档同样是合法交付档，文件名沿用旧规则不变。
> **APK 体积会随模型文件大小增长**（本模型约 3.9 MB）：它是新增投放资产的净增，
> 构建体积复核时应把它计入。

**文件名由模型卡推导，不写在代码里**：`ModelRegistry`（`app/lib/data/native/model_registry.dart`）
读 `model_card.json` 的 `name` + `quantization` + `version`，拼出
`assets/models/<name>_<quantization>_v<version>.tflite` 再加载（`ADR-21` 起档位参与命名；
INT8 档的名字与旧规则逐字相同 —— `acoudiet_int8_v1.0.0.tflite`，无兼容性成本）。因此：

* 换模型 = 换文件 + 改卡；**不改代码**；
* 不可能出现"代码里写死旧路径、换模型后静默加载旧文件"。

`pubspec.yaml` 里登记的是**目录** `assets/models/`，所以新投放的 `.tflite` 会被自动打包，
不需要同步修改构建配置。

## 2. 三条投放路径

| 场景 | 命令 |
|---|---|
| AI 侧正常产出（T-07） | `python ai/src/quantize.py` |
| 手上已有成品 `.tflite` | `python tool/install_model.py --tflite <你的.tflite> --version 1.0.0 [--quantization auto]` |
| 手工复制 | 自己保证卡里的 `tfliteSha256` / `tfliteBytes` 与文件一致 |

`tool/install_model.py` 在复制**之前**校验：输入张量必须是
`[1, 128, 128, 1]`（形状取自 SSOT；`ADR-21` 起张量宽度是 `n_frames = 128`，~~`[1,128,129,1]`~~
中的 129 是 `raw_mel_frames`，不是张量宽度）、输出必须是 6 类、体积按**模型卡自己申报的档位**取
FF-16 的对应上限（fp32 ≤ 6 MB / int8 ≤ 2.5 MB；~~统一的 ≤ 2.5 MB~~），并重新计算两个测量字段；
`melVersion` 从 Kotlin 常量读取，避免与 App 侧漂移。它同时会**拒绝 I/O 不是 float32 的制品**
（`ADR-20` 的 float32 I/O 契约 —— `int8_fullint` 那类真 int8 I/O 会被当场拒绝），
并按 `<name>_<quantization>_v<version>.tflite` 命名复制。

## 3. App 侧的加载与失败语义

`AppServices.bootstrap()` 的顺序是 **知识库 → C-03 握手 → 模型加载 → 演示数据**。
模型必须在握手之后，因为它的 `nFrames` 要与握手值比对。

`ModelRegistry.ensureLoaded()` 的检查链（任一步失败都**不抛崩溃**，而是如实上报）：

| # | 检查 | 失败码 | 现场表现 |
|---|---|---|---|
| 1 | 模型卡可解析且带 `name`/`version`/`nFrames`/`melVersion` | `ACD-IO-002` | 自检第 3 项失败 |
| 2 | `quantization` ∈ `{"fp32","int8"}`（`ADR-21`；此前硬判 `== "int8"`，把合法的 fp32 当非法交付） | `ACD-INF-001` | 自检第 3 项失败 |
| 3 | `card.nFrames == 握手 nFrames`（FF-11 = 128，`ADR-21`；~~129~~） | `ACD-INF-002` | 自检第 11 项失败 |
| 4 | 引擎可加载该 asset 且自报 `modelNFrames` 一致 | `ACD-INF-001` / `ACD-INF-002` | 自检第 3/11 项失败 |
| 5 | 回填 `setDiagnosticsModelInfo` 给原生侧 | —（失败不致命） | 自检第 11 项显示身份 |

**现场口径**：模型加载失败 → 切 **Mode C（报告演示）**；麦克风失败 → 切 **Mode B**。
两者在自检面板上是不同条目（第 3 项 vs 第 2 项），这正是 `M-04` 存在的意义。

## 4. 低成本反馈闭环（不在设备上训练）

App 侧的全部成本 = **写两个布尔列**（`ADR-P6` 已批准入库，UI 只显示「已确认」）：

| 列 | 含义 | 谁写 |
|---|---|---|
| `confirmed_by_user` | 用户点了「是」（Level-3 二选一确认） | `DetectionSession.answerConfirmation(accepted: true)` |
| `corrected_by_user` | 用户选了另一个类别 | `answerConfirmation(accepted: false, alternativeClassId: …)` |
| `confidence` | 当时的平滑置信度 | 聚合器输出 |
| `class_label` / `class_id` | 模型当时的判断 | 聚合器输出 |

**设备上不做任何训练、不做特征缓存、不存音频**（FF-24 第 1 条）。反馈的消费在离线侧：

```powershell
# 从设备导出 feedback.jsonl（每行一条记录，字段见脚本 docstring）
python ai/scripts/ingest_feedback.py --input feedback.jsonl
```

产出 `ai/data/feedback/feedback_train.csv`，列与 `splits/*.csv` 一致（外加 `origin` /
`confidence`），因此 `T-03`/`T-04` **不需要新的加载器**。脚本同时打印
「predicted → chosen」的现场混淆对，这是下一轮采集**最该补哪一类数据**的直接依据。

> ⚠️ **必须如实说明的限制**：`path` 列为空 —— 设备不存音频，所以这些行是**标签**而不是样本。
> 它们要变成训练数据，必须按同样的条件**重新录制**对应音频。因此该文件的正确定位是
> 「下一轮数据采集的优先级信号」，脚本本身也会打印这条警告，不假装它是可直接训练的集合。

### 4.1 这条回路是被**执行**验证的，不是被阅读验证的

`ai/tests/run_all.py` 第 5 组会在临时夹具上**真的跑一遍** `ingest_feedback.py`，断言六件事：
只有落在冻结六类内的行进得来、**每一行的 `path` 都是空的**（这条是承重断言）、
用户纠正会把纠正后的类别作为训练目标、单纯确认保留模型判断、`origin` 不越出
`{confirmed, corrected, auto}`。

**跑这套检查当场抓到两个真实缺陷**（都已修）：

| 缺陷 | 症状 | 修法 |
|---|---|---|
| 输出含 `⚠️`，而 zh-CN 控制台是 cp936 | `UnicodeEncodeError` 发生在**写完所有行之后**：CSV 完全正确，进程却 `exit 1` —— 调用方会把一次成功的摄入读成失败 | `_make_console_safe()`：对 stdout/stderr 设 `errors="replace"`，把不可编码字符降级为 `?` 而不是崩掉 |
| 输入按 `utf-8` 读 | 带 BOM 的导出（或记事本另存的文件）在第 1 行报「不是合法 JSON」 | 改读 `utf-8-sig` |

这两条都不是「读代码」能发现的：第一个只在中文 Windows 上出现，而中文 Windows 恰好是本项目的
主要环境；它的后果还是最阴的那种 —— 输出完全正确，退出码却是失败。

---

## 5. 当前状态

| 项 | 状态 |
|---|---|
| 投放目录与契约 | ✅ `app/assets/models/` + `README.md` + `ModelRegistry` |
| 投放工具 | ✅ `tool/install_model.py`（校验 + 写卡 + 命名复制 + 独立复核入口） |
| App 自动加载 | ✅ 接入 `bootstrap()`，失败即为自检第 3/11 项 |
| 加载失败语义测试 | ✅ `tool/session_tests.dart` 的 `Model drop-in contract` 组（13 项，含未知档位拒绝、`nFrames=129` 不符、卡缺失三个反例；`ADR-21` 起 fp32 卡是**合法**的，~~fp32 误投~~ 不再是反例） |
| 成品 `.tflite` | ✅ **已投放**：`acoudiet_fp32_v1.1.0.tflite`（fp32，4,051,716 字节，FF-16 fp32 档 ≤ 6 MB；`ADR-23` 把版本号对齐到交付包的 v1.1，**字节未变** —— sha256 `705ffc62…560a` 与旧文件名下的那份逐字节相同）；`tool/verify_artifacts.py` 返回 **exit 0 = PASS**（~~**尚无**（离线无法训练到达标）；`model_card.json` 为显式占位件，返回 exit 3 = NOT BUILT~~；与 exit 2 失败仍明确区分） |
| 交付模型倒逼的前端修订 | ⚠️ 交付模型的前端规格与本仓原冻结链路**不是同一套**，故按交付规格修订为 **`ADR-21`（Mel 前端 v1.1）**：`power_to_db_ref = "patch_max"`、per-patch minmax、归一化前丢弃尾帧得 128 帧、流式预加重、取消逐 patch DC 去除；`MEL_VERSION` / `melVersion` `1.0.0 → 1.1.0` |
| 反馈信号（两个布尔列） | ✅ 已入库并由 `DetectionSession` 写入 |
| 反馈消费脚本 | ✅ `ai/scripts/ingest_feedback.py` |
| 设备上训练 | ❌ 明确不做（耗电，且 v1.0 无此范围） |

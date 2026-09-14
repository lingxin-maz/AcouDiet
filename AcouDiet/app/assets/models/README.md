# `assets/models/` — 成品模型的投放位置（drop-in）

**这个目录就是"把训练好的模型放进来"的地方。** 不需要改任何代码。

---

## 放什么

| 文件 | 必须 | 说明 |
|---|---|---|
| `<name>_<quantization>_v<version>.tflite` | ✅ | FF-16 的**两档都可交付**：`fp32` **≤ 6 MB**、`int8` **≤ 2.5 MB**。文件名必须与模型卡里的 `name` + `quantization` + `version` 三者对应 |
| `model_card.json` | ✅ | 15 个字段，权威定义见 `docs/backend/docs_api/API-06_AI训练侧数据契约.md` §5 |

命名示例（当前实测值）：`acoudiet_fp32_v1.3.0.tflite`（本目录**同时只有一个** `.tflite`：被取代的那份会删掉，理由见下方「当前状态」）

**为什么是这两个文件**：`ModelRegistry`（`app/lib/data/native/model_registry.dart`）只读模型卡，
从卡里的 `name` + `quantization` + `version` **推导**出 tflite 的文件名，然后加载它。因此
**换模型 = 换文件**，不涉及代码改动，也不会出现"代码里写死了一个路径、换模型后静默加载旧文件"的情况。

> ⚠️ **历史修正（`ADR-21`）**：本目录的早期版本只承认 `int8` 一档，并把 `fp32` 当作"打包错误"拒绝。
> 那**不是 FF-16 的规定** —— FF-16 原文就是「FP32 ≤ 6 MB；INT8 ≤ 2.5 MB」，`ai/src/config.py` 的
> `DomainConst` 也一直同时带着两个上限；是 App 侧只实现了 INT8 那半档。现在两档都支持，闸门按
> **卡片自己申报的档位**取对应上限。文件名规则相应扩展为 `<name>_<quantization>_v<version>.tflite`
> —— INT8 档的名字**与旧规则逐字相同**，故无兼容性成本（此前从未交付过任何模型）。

---

## 怎么放（三种方式，任选）

### 方式 1：AI 侧直接产出到这里（T-07 的正常路径）
```powershell
python ai/src/quantize.py           # 转换 → 自检 → 写模型卡 → 投放到本目录
```

### 方式 2：手上已有 `.tflite`（例如别处训练好的成品）
```powershell
python tool\install_model.py --tflite D:\path\to\your_model.tflite --version 1.0.0
```
它会校验输入形状 / 类别数 / 帧数 / 体积，计算 `sha256` 与字节数，写好模型卡，
再按规范命名复制进来。**这是"把手上的成品模型塞进去"最省事的路径。**

### 方式 3：手工复制 + 手工改卡
可以，但要自己保证卡里的 `tfliteSha256` / `tfliteBytes` 与文件一致，否则交付闸门会失败
（这是刻意的：卡与文件不一致时，App 与报告说的就不是同一个模型）。

---

## 放进去之后，App 会自动做什么

`ModelRegistry.ensureLoaded()` 在启动装配阶段（`bootstrap.dart`）按顺序检查：

1. 模型卡能解析，且带 `name` / `version` / `nFrames` / `melVersion`；
2. `quantization` 是 `ModelRegistry.supportedQuantizations` 里的档位（`fp32` / `int8`）。
   名字写错或写成 `"pending"` 会被明确报出 —— 档位**决定文件名**，档位不认识就等于路径不存在；
3. `card.nFrames == feature_config.n_frames`（FF-11 = 128，`ADR-21`）—— 不一致就是张量形状与 Mel 前端互相矛盾；
4. 引擎能加载该 asset，且引擎自报的 `modelNFrames` 与卡一致；
5. 加载成功后把模型身份回填给原生侧（`setDiagnosticsModelInfo`），使 `M-04` 自检面板
   第 3 项（模型已加载）与第 11 项（模型版本与 `n_frames`）读的是同一份事实。

**任何一步失败都不会抛出崩溃**：检测页会被 C-03 握手 + 自检门禁挡住，并如实显示
`ACD-INF-001`（模型加载失败）或 `ACD-IO-002`（模型卡不可用），而不是假装模型可用。

---

## 当前状态（诚实说明）

**已交付并已装载**：`acoudiet_fp32_v1.3.0.tflite`（4,053,556 字节，sha256 `31fba3ec…19f4`，FF-16 的 fp32 档
上限 6 MB 以内）。模型卡里的 `tfliteSha256` / `tfliteBytes` / `parityLabelMatch` / `parityMaxConfDelta`
都是**实测值**，`tool/verify_artifacts.py` 返回 **exit 0 = PASS**。

> 📌 **`ADR-32`：v1.3 交付包是真正的换模型（字节变了）。** 与 `ADR-23` 那次（交付件逐字节相同、只改版本号）
> 不同，本轮交付的 `acoudiet_model_v1.3/v1.3/models/acoudiet_fp32.tflite` sha256 是 `31fba3ec…19f4`，
> 取代了原来的 `705ffc62…560a`。**I/O 与 Mel 前端契约完全不变**（`compare_model_delivery.py` 实测
> Mel 不一致项 = 0、类别表 MATCH），`melVersion` 仍是 `1.1.0`，所以**这次真的只换文件、代码零改动**。
>
> 被取代的旧字节**没有留在本目录**（`pubspec.yaml` 打的是整个目录，留着就是 4 MB 死重），
> 而是归档到**不进包**的 `ai/artifacts/model_archive/`。核对交付包与本仓差异：
>
> ```powershell
> python tool\compare_model_delivery.py D:\Desktop\Food\acoudiet_model_v1.3\v1.3
> # 逐字节比对交付的 .tflite + 把交付包的 feature_config.json 与 SSOT 逐键比对 + 类别表
> ```
>
> ⚠️ **换模型必须重测 parity，否则闸门会"绿着说谎"。** `tool/verify_artifacts.py` 只检查
> `parity_report.json` 的阈值与 `modelParityMeasured` 标志，**不校验该报告测的是不是当前这份字节**。
> 因此改包后重跑：
>
> ```powershell
> python ai\scripts\mel_parity_test.py --n 20   # → modelParitySource 指向新的 v1.3.0 文件
> ```
>
> 本轮重测结果：`labelMatch = 1.0`、`maxConfDelta = 1.5199184417724609e-06`（闸门 0.98 / 0.05）、
> `melParity maxAbsDiff = 5.96e-08`、`boundaryCoverage 2/18 exercised = true`。

为什么选 **fp32** 而不是 int8：**v1.3 交付说明 §1 已把 `models/acoudiet_fp32.tflite` 定为「正式嵌入模型」**
（KD 训练、parity 100%、桌面延迟 0.54 ms），另附一份只作回退用的 `…_v1.2_legacy.tflite`。
`ADR-20` 的 **float32 I/O 契约**同样排除了"真 int8 I/O"那一类制品。用户也明确要求"按识别精度最高的来制作"。
两边结论一致，本仓照做。

> ⚠️ **v1.3 交付包自身的两处说明与文件不一致**（记录，不影响取用）：① `README` §1 的「包内清单」列了
> `models/acoudiet_int8.tflite`，但**包里没有这个文件**，`MANIFEST.sha256` 里也没有；② 它把回退件写成
> `acoudiet_fp32_v1.1_legacy.tflite`，**实际文件名是 `acoudiet_fp32_v1.2_legacy.tflite`**。
> 已用 `MANIFEST.sha256` **逐个文件核过**：包里 4 个文件的哈希全部对得上。取用哪个制品以 `README` §1
> 明确点名的 `acoudiet_fp32.tflite` 为准。

⚠️ **本仓复测不了交付说明里的精度数字**：`ai/data/splits`、`ai/data/raw`、`ai/data/augmented` 在本仓是空的，
没有带标注语料可评。v1.3 交付说明称聚合精度 55.9%（Wilson CI 51.9–59.9%；drink F1 0.43→0.75、
cabbage F1 0.18→0.42），**那是模型组公共测试集的数字**，不是本仓实测。
**本仓能实测的**是：字节与 `MANIFEST.sha256` 对得上、I/O 与前端契约一致、跨语言 parity 通过、
闸门通过，以及**换权重确实改变了识别结果**——同一 parity 语料 18 个 patch 里恰好 1 个换了标签
（`tone_250hz.wav`：类别 1 → 类别 5）。

### 装进 APK 之后还要核对什么

模型"进了包"与"源目录里存在"是两件事（`ADR-22` 的教训）。构建后可执行：

```powershell
python _toolchain\check_apk_contents.py <你的.apk> --expect-no-internet
#   → 包内 .tflite 的 sha256 / 字节数与**包内** model_card.json 逐项一致？
#     （ADR-32 起由卡片驱动；此前写死 v1.1 的哈希，换模型后会对合法包打印 False）
python tool\ui_fingerprint_check.py <你的.apk>
#   → 这个包是哪一版界面？（同样修过一次：ADR-30 删掉的标题曾被当成"必须有"，见 ADR-33）
```

### ⚠️ 前端必须与模型规格一致（`ADR-21`）

投放模型**不只**是复制文件。交付模型的 `feature_config.json` 描述的前端与本仓原先冻结的那套**不是同一套**
（`power_to_db` 用 patch 最大值、per-patch minmax、丢弃尾帧得到 128 帧、预加重沿流连续、没有 DC 去除）。
`ADR-21` 已把 SSOT 与 Kotlin/Python 两侧前端改成交付规格，`melVersion` 随之 **1.0.0 → 1.1.0**。
**换模型时如果前端规格又变了，必须重跑 `ai/scripts/mel_parity_test.py`**，否则跨语言闸门仍然会绿，
但它证明的只是"Kotlin 与 Python 彼此一致"，看不见训练侧。

### ✅ 之前缺的 TFLite 运行时已补上（ADR-20）

**曾经的问题**：ADR-20 核查时实测发现**三个 APK 里都没有任何 TFLite 原生库**，工程里也没有
`jniLibs`，`pubspec.yaml` 早已不再依赖 `tflite_flutter`（它本来是提供 `libtensorflowlite_c.so`
的那一方）。而 `tflite_inference_engine.dart` 在 Android 上按顺序尝试
`libtensorflowlite_c.so` → `libtensorflowlite_jni.so`，两者都**不是** Android 公开系统库
（与 `libsqlite.so` 同一类：不在 `/system/etc/public.libraries.txt`，`dlopen` 必失败）。
结论是：把模型放进本目录也跑不起来，会在打开动态库时失败。

**现在的状态**：`app/android/app/build.gradle` 已加入

```groovy
dependencies { implementation 'org.tensorflow:tensorflow-lite:2.16.1' }
```

选 **2.16.1** 而不是"最新"，是实测的结果：`2.17.0` 只发布了一个**不含 `.so` 的 jar**，
按"取最新"来钉版本会把同一个 bug 悄悄带回来。2.16.1 的 AAR 带四个 ABI 的
`libtensorflowlite_jni.so`，且**导出 Dart 绑定所需的全部 21 个 `TfLite*` 符号**
（含 `TfLiteTensorType` 与 `TfLiteVersion`）—— 逐符号在二进制里 grep 过，不是推测。

实测结果（同一台模拟器、同一个脚本）：

| | 之前 | 现在 |
|---|---|---|
| release APK 里的 TFLite | **无** | `lib/arm64-v8a/libtensorflowlite_jni.so` |
| release APK 体积 | 17.1 MB | **20.4 MB** |
| 安装后 `primaryCpuAbi` | — | `x86_64`（模拟器），`.so` 在 APK 内**未压缩存储**，由 linker 直接映射 |

> 📌 **ABI 过滤**：Flutter 的 `--target-platform android-arm64` 只过滤 *Flutter 自己*的库，
> **不过滤第三方 AAR 的 native**。加了 TFLite 之后 release 一度从 17.1 涨到 **31.1 MB**
> （14 MiB native，四个 ABI 全进来了）。现在支持按需裁剪：
>
> ```powershell
> flutter build apk --release --target-platform android-arm64 `
>     --android-project-arg=acoudietAbis=arm64-v8a      # → 20.4 MB，只有 arm64
> ```
>
> **默认不裁剪**（保留全部 ABI）是刻意的：模拟器是 x86_64，静默砍掉它的 ABI 会让本仓
> 失去唯一能实测的设备。

⚠️ **仍需与模型组对齐 TF 版本**：导出侧钉的是 `tensorflow>=2.16`（实际 2.21），而 Android 端
能拿到 native 库的最新 AAR 是 2.16.1。若导出用的算子/版本明显更新，模型可能要求比设备更新的
运行时，症状是一次没有线索的加载失败。为此已绑定 `TfLiteVersion`，自检面板第 3 项的
`observed` 会显示 `loaded (runtime 2.16.1)` —— 让版本差异**在设备上可见**，而不是靠猜。

**端到端装载已在模拟器上实测通过（`ADR-22`）**。过程本身值得记住：第一次设备端实测时，
应用**一切正常**（安装成功、首帧已绘制、无崩溃、截图非空白），但 logcat 里是
`E tflite : Could not open 'assets/models/…_v1.0.0.tflite'.`（当时那份的文件名）—— 因为
`TfLiteModelCreateFromFile` 要的是**文件系统路径**，而 Flutter 的 asset 在 Android 上
**住在 APK 的 zip 里**。修复方式是改用 `TfLiteModelCreate` 从**内存**建模（字节由
`ModelRegistry` 经 `AssetReader.readBytes` 读出后交给引擎）。修复后同一套判据全过，且
应用自己的进程打出 `Initialized TensorFlow Lite runtime`，`Could not open` 签名 0 命中。

> ⚠️ **给后来者的教训**：那次"应用启动正常"与"模型可用"是两个不同的事实，而
> `run_on_emulator.ps1` 的六项判据**只看得到前者**。只看脚本的 `APP STARTED` 会得出错误结论。

复核命令：

```powershell
python tool\verify_artifacts.py      # 独立复核：形状/类别/帧数/体积/三 hash 闭环
python ai\scripts\mel_parity_test.py --n 14   # 跨语言 Mel + 模型 parity（写 parity_report.json）
powershell -File tool\verify_all.ps1 # 全套回归（16 步）
```

# 依赖替换记录（C-04 / FF-23 偏离说明）

**状态**：⚠️ 环境强制偏离，已按 `SPEC-00 §8.4` 登记待 A/B/C 确认
**影响**：`app/pubspec.yaml`、`app/lib/data/**`、`app/lib/presentation/**`

---

## 1. 事实（**本节已按实测更正**）

> ⚠️ **更正记录**：本报告初版写着「本实现环境完全没有网络出口」。**那个结论是错的**，
> 它是测量工具的产物，不是环境的事实。当时的探测走 PowerShell `Invoke-WebRequest` / `curl.exe`，
> 而这两个在本机都做不了 TLS：
>
> ```
> curl: (35) schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)
> PowerShell: 基础连接已经关闭: 接收时发生错误
> ```
>
> 换用 Python 的 `urllib`（自带 OpenSSL）立刻就通了 —— `HTTP 200, 11566 bytes`。
> 后续 `flutter pub get` 下载 62 个依赖、Gradle 拉取 AGP/Kotlin/androidx 也全部成功，
> 进一步证明网络一直是通的。**Windows 的 schannel 凭证链坏了，不是网线断了。**

实测（本次）：

* 网络**可达**：`pub.dev` / `pub.flutter-io.cn` / `storage.flutter-io.cn` / `pypi.org` 均 443 通，
  且经 Python / Dart / Java 三种客户端实际完成过 HTTPS 传输；
* 本机唯一的 pub 缓存 `_toolchain/cache/pub`（镜像 `pub.flutter-io.cn`）里原有 96 个包；
  **`flutter` 框架包自身声明的三个硬依赖缺失**，这才是真正的阻塞点：

  | `_toolchain/flutter/packages/flutter/pubspec.yaml` 要求 | 当时 | 现状 |
  |---|---|---|
  | `characters: 1.3.0` | ❌ 全机不存在 | ✅ 已 `dart pub cache add` 装入 |
  | `material_color_utilities: 0.11.1` | ❌ 全机不存在 | ✅ 同上 |
  | `vector_math: 2.1.4` | ❌ 全机不存在 | ✅ 同上 |
  | `collection` / `meta` / `sky_engine` | ✅ 在 | ✅ 在 |

* 补齐这三个包之后：`flutter pub get` **成功**（`Changed 62 dependencies!`），
  `flutter analyze` **0 error**，`flutter test` **91 项全过**，
  `flutter build apk --debug` **成功出包**。详见 §6。

### 1.1 那么「替换四个包」还算不算被迫的？

**不算了 —— 它现在是设计选择，不是环境所迫。** 这一点必须说清楚，否则本报告的立论就是假的。

`FF-23` 指定的 `sqflite` / Riverpod / `fl_chart` / `tflite_flutter` 现在**都可以下载**。
但它们已经被自研实现替代，且这四套实现**已由 799 项断言 + 91 项 widget 测试真实验证通过**，
并保持了 `API-02`/`API-03`/`API-04` 的逐条契约。当下把它们换回第三方库，收益是"与 FF-23 字面一致"，
代价是重新引入四个运行时依赖、重跑全部验证、并放弃「APK 依赖面为零」这一已经拿到的属性。

**本仓的处置**：保留自研实现，把偏离如实记为**主动选择**，而不是继续挂在一个已被推翻的
"无网络"理由上。若项目决定回到字面 FF-23，§5 给出了最小改动路径，且现在它确实可执行了。

---

## 2. 处置：同契约替换，而不是删功能

原则：**冻结的是契约（`API-02`/`API-03`/`API-04` 的类、方法、语义与不变量），不是库名。**
因此四个包各自被一个自研实现替代，接口面与语义**逐条对齐**，并全部由同一套离线套件验证。

| FF-23 指定 | 本仓实现 | 契约保持方式 | 代价 |
|---|---|---|---|
| `sqflite` | `lib/data/db/sqlite_ffi.dart`（`dart:ffi` → `sqlite3`） | 单文件 SQLite、**唯一 `openDatabase` 调用点**、真实事务、`onUpgrade` 幂等、无 BLOB（I-2 由 schema + 参数绑定双重拦截） | 需自行维护 FFI 绑定（约 400 行）；Windows 上要指定 `ACOUDIET_SQLITE` 才能跑测试 |
| Riverpod | `lib/presentation/state/*`（`ChangeNotifier` + `InheritedNotifier` + `AsyncValue` 包装） | L5 只调 L4、不碰 DAO / MethodChannel（`API-00 §1` 规则 1）；loading/error/ready 三态与 `retryable` 语义一致 | 无代码生成、无 `override` 能力；跨页面共享需手写 provider |
| `fl_chart` | `lib/presentation/widgets/`（`CustomPainter` 雷达图 + 折线图） | U-06 要求的图表语义（四维雷达、7 天趋势、可读屏文本替代） | 无内置交互（tooltip 需自绘） |
| `tflite_flutter` + XNNPACK | `lib/data/native/tflite_inference_engine.dart`（`dart:ffi` → TFLite C API） | `InferenceEngine` 契约不变：`load/run/dispose/isLoaded/delegateInUse`，float32 I/O、`[1,128,128,1]`（`ADR-20` 的 float32 I/O 契约 + `ADR-21` 的张量宽度 128，~~INT8、`[1,128,129,1]`~~）、NNAPI 失败**静默回退 CPU** | 委托创建为 best-effort：XNNPACK/NNAPI 符号不存在时直接 CPU（FF-18 允许）；真机 D4 需实测确认 `delegateInUse` |

**未替换的能力**：无。四项功能（本地持久化、状态管理、图表、端侧推理）都已实现，且**其逻辑**
已被离线套件执行验证。但请连同 §6 一起读：这些代码**尚未被编译器编译过**，也**从未在设备上运行过**。

---

## 2.1 因替换而产生的两处接口新增（需按 `API-00` §3.9 登记）

替换 `sqflite` 时暴露出一个**不能靠"少一个包"绕过**的问题：数据库文件放在哪里。

* `sqflite` 的常规配套是 `path_provider` 的 `getDatabasesPath()`；
* 没有它时最容易写成的替代是 `Directory.systemTemp` —— 而它在 Android 上映射到
  **`cacheDir`**，系统在存储紧张时**可以直接清空**。对一个"本地累积、无云端备份"的健康记录
  App 来说，这等于**静默删除用户的全部历史**。

因此本仓在 `API-01` 的 `MethodChannel` 上新增一个方法，取设备上唯一正确的目录：

| 新增 | 位置 | 返回值 |
|---|---|---|
| `getStorageDir` | `API-01` 的 `com.acoudiet.app/audio` 方法集 | `{ "path": Context.getFilesDir().absolutePath }`（Dart 侧 `Future<String?> getStorageDir()`） |

* 原生实现：`AudioChannelHostAndroid.onMethodCall` 的 `"getStorageDir"` 分支；
* Dart 契约：`AudioBridge.getStorageDir()`；`MethodChannelAudioBridge` 实现；
  `FakeAudioBridge` 返回 `null`（桌面上没有"应用私有目录"这个概念，返回 `null` 让调用方
  **显式**回退，而不是假装拿到了真目录）；
* 装配：`bootstrap.dart` 的 `_resolveDatabasePath()` 优先用原生目录，仅在桥不可用时回退
  `systemTemp`，并在 `BootstrapResult` 中如实体现；
* `FakeRepo`（占位装配）不涉及数据库文件，不受影响。

> **按 `API-00` §3.9 的处置**：这是**纯新增**方法，未修改任何既有签名或语义；
> 但它确实扩展了 `API-01` 的方法集，故在此登记，并建议后续在 `API-01` §2 补一行。
> 另一处新增是 `app/android/app/src/main/res/mipmap-*/ic_launcher.png`（5 个密度），
> 因为没有 Flutter 工具链来 `flutter create` 生成图标，而 `AndroidManifest.xml` 引用了
> `@mipmap/ic_launcher` —— 缺它会让资源链接失败、根本无法出包。
> 图标由 `tool/gen_launcher_icons.py` 直接写 PNG 生成（可复现），正式发布前应替换为正式素材。

## 3. 这带来了什么（正向）* **APK 依赖面为零**：除 Flutter SDK 外无第三方运行时依赖，体积与供应链风险同时下降；
* **离线可验证**：所有承载逻辑的代码保持纯 Dart / 纯 Kotlin，因此本仓的 343 项断言 + 跨语言
  对齐闸门**在没有网络、没有 Android 设备的情况下真实执行过**（见 `README.md` §3）；
* **隐私故事更硬**：无任何第三方包，也就没有第三方网络调用面，与 `FF-24` 第 4 条相互印证。

## 4. 代价与风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| FFI 绑定的正确性 | SQLite 与 TFLite 的绑定未经真机验证 | SQLite 已在真实引擎上跑通 47 项；TFLite 需在 D4 真机验证并与 `ai/` 的 `model_card` 闭环 |
| 图表体验 | 自绘图表没有成熟库的交互细节 | U-06 只要求静态可读 + 文本替代；交互留到后续版本 |
| 与文档的字面冲突 | `FF-23` 写的是四个包名 | 本记录即为偏离备案；若必须回到原库，只需替换 `data/` 与 `presentation/state/` 两层，契约与测试不动 |

---

## 5. 若恢复网络后的最小改动路径

1. `pubspec.yaml` 加回四个依赖；
2. `lib/data/db/sqlite_ffi.dart` → `sqflite` 适配层（DAO 中的 SQL 与 `SqlExecutor` 语义一一对应）；
3. `lib/data/native/tflite_inference_engine.dart` → `tflite_flutter` 实现（`InferenceEngine` 契约不变）；
4. `lib/presentation/state/` 的 `ChangeNotifier` → Riverpod provider（presenter 全部不动）；
5. `lib/presentation/widgets/` 的 `CustomPainter` → `fl_chart`。

**域层（`lib/domain/**`）与全部离线套件无需改动** —— 这正是把逻辑写成纯 Dart 的收益。

---

## 6. 现在这个 App 能启动吗？—— **能了**（附：为达到这一点修掉的 6 个真实缺陷）

**结论：能编译、能跑测试、能出包。** 但这句话是**做出来的**，不是本来就成立的 ——
本节记录把「不能」变成「能」的全过程，因为途中暴露的 6 个缺陷全部属于同一类：
**从未被编译器看过的代码**。

### 6.1 步骤（精确到命令）

```powershell
# ① 补齐 flutter 框架自身缺失的三个硬依赖（需要网络；Python/Dart 可用，PowerShell/curl 不行）
dart pub cache add characters               --version 1.3.0
dart pub cache add material_color_utilities --version 0.11.1
dart pub cache add vector_math              --version 2.1.4

# ② 解析依赖（Flutter 工具要把状态写到 APPDATA，且要能 spawn 带管道的子进程）
flutter pub get          # → Changed 62 dependencies!

# ③ 分析 / 测试 / 出包
flutter analyze --no-pub # → 0 error
flutter test    --no-pub # → 91 项全过
flutter build apk --debug
```

所需环境变量（本机路径）：`PUB_CACHE=_toolchain/cache/pub`、
`ANDROID_HOME=ANDROID_SDK_ROOT=_toolchain/android-sdk`、`JAVA_HOME=_toolchain/jdk17`、
`GRADLE_USER_HOME=_toolchain/cache/gradle`。

### 6.2 修掉的 6 个缺陷（全部是「只被静态检查过」的代码）

| # | 文件 | 缺陷 | 只有真实编译能发现的原因 |
|---|---|---|---|
| 1 | `widgets/four_dim_radar.dart:146` | `num` 传给 `Offset(double, double)` | `.clamp()` 声明在 `num` 上、返回 `num`，需 `.toDouble()` |
| 2 | `widgets/waveform_view.dart:32` | `ValueListenable` 未定义 | 它不被 `material.dart` 转导出，需显式 `import foundation` |
| 3 | `pages/home/home_page.dart:214` | `UiStrings.todayLabel` 不存在 | 该常量从未被定义；已补 `homeTodayRecordsTitle`（§见下） |
| 4 | `pages/report/report_page.dart:104` | `ReportNotifier` 未定义 | 类存在，但页面没 import `state/notifiers.dart` |
| 5 | `pages/demo/self_check_panel.dart:81` | `SelfCheckNotifier` 未定义 | 同上 |
| 6 | `data/native/tflite_inference_engine.dart:88,205` | FFI 签名错误 + `Uint8List` 当 `Pointer<Uint8>` 用 | `TfLiteInterpreterOptionsAddDelegate` 是**两个**指针参数（绑定只声明了一个）；输入张量必须**拷进本地内存**，`Float32List.buffer.asUint8List()` 是视图不是指针 |

另有 2 个 **widget 测试**层面的缺陷：

| # | 文件 | 缺陷 | 判断依据 |
|---|---|---|---|
| 7 | `test/ui/score_card_render_test.dart:52` | 全局 `find.text('30/30')` 期望 1 个 | 演示数据里 `饮食规律性` 与 `食物结构` **都是 30/30**，渲染 2 个是**对的**；已改为在该维度自己的 `Row` 子树内断言 |
| 8 | `widgets/score_card.dart:72` | `Text('${UiStrings.deltaRowLabel} ')` 尾部带空格 | 冻结文案是 `较昨日`，而 `SPEC` 用 `find.text(UiStrings.deltaRowLabel)` **逐字**校验；间距应由布局负责，已改为 `SizedBox` |

还有 2 个**构建配置**缺陷（`flutter build apk --debug` 直接失败，意味着 `flutter run` 也必失败）：

| # | 文件 | 缺陷 | 说明 |
|---|---|---|---|
| 9 | `android/app/build.gradle` | `buildTypes { release { throw ... } }` 在**配置期**求值 | Gradle 配置期对**所有**任务都会执行该闭包，于是 debug 构建也抛「release 需要 key.properties」。已改为 `gradle.taskGraph.whenReady` 内判定，**release 缺 key 仍然失败**（已实测），debug 不再受影响 |
| 10 | `android/app/src/main/AndroidManifest.xml`、`src/debug/AndroidManifest.xml` | **不是合法 XML**：注释里含 `--` | XML 禁止注释内出现 `--`。main 里是 `claim -- not an oversight`，debug 里是 `` `flutter build apk --profile` ``。清单文件是"装得上"的唯一前提，而它**从未被任何解析器读过** |

### 6.3 修完之后的实测结果

| 项目 | 结果 |
|---|---|
| `flutter analyze` | **0 error**（75 条 warning/info，主要是项目自开的 `prefer_const_constructors`） |
| `flutter test` | **91 项全过**（UI 层**首次**被执行） |
| `flutter build apk --debug` | ✅ `build/app/outputs/flutter-apk/app-debug.apk`（189 MB，未裁剪的 debug 包） |
| `aapt2 dump badging` | `package: com.acoudiet.app`、`versionName 1.0.0`、`application-label: AcouDiet`；权限 = `INTERNET`(debug 覆盖层) + `RECORD_AUDIO` |
| `flutter build apk --release` | ❌ 按 `SPEC-C-04` **如期失败**并要求 `key.properties`（证明第 9 项的修法没有放松要求） |
| `python tool/check_android_xml.py --strict` | ✅ 7 个 Android XML 全部合法（新增门禁，防第 10 类回归） |

### 6.4 仍然没有的东西

* **成品 `.tflite` 未投放** —— 按用户决定不训练。检测页会如实显示 `ACD-INF-001`，不假装模型可用；
* **真机未测**（本机没插真机），**模拟器已实测启动成功**：见
  `records/demo/emulator_run/RUN_RECORD.md`。

### 6.5 ✅ 已修复：Android 上数据库从未建立

在 Android 上 `dlopen` SQLite **必然失败**，原先 App 会静默降级到内存实现、**数据不持久化**：

* `libsqlite3.so` 在 Android 上不存在；
* `libsqlite.so` 存在，但**不在 `/system/etc/public.libraries.txt`** 里 —— Android 7 起的
  linker namespace 隔离只允许 app 加载该列表内的库；
* APK 未自带 sqlite（只有 `libflutter.so`）。

**已按方案 A 修复**：新增独立通道 `com.acoudiet.app/sqlite`，用**平台自带**的
`android.database.sqlite`（零新依赖）；`sqlite_ffi.dart` 抽出 `SqlExecutor` 抽象，FFI 与通道
两个后端共存，`bootstrap.dart` 按平台选择。这不是"新增第 5 个替换"——它是让
「本地持久化」这一项**在 Android 上真正成立**。

实测（模拟器）：设备上出现 `files/acoudiet.db`（49,152 B）、`integrity_check=ok`、
`user_version=1`、四张表列名逐字符合 DDL；冷启动后首页读到 `本周记录 1 次`、
`约 104–156 kcal` 与一条真实记录卡片。完整证据与复现命令见
`records/demo/emulator_run/RUN_RECORD.md` §4。

> Win 端的 47 项 SQLite 测试用的是 `ACOUDIET_SQLITE` 指向的 Anaconda `sqlite3.dll` ——
> 一个 Android 上不存在的条件。所以那 47 项**只覆盖桌面后端**；Android 后端另由
> `app/test/data/channel_sqlite_test.dart`（13 项，跑在 mock messenger 上）+
> `tool/check_bridge_symmetry.py`（通道名与 7 个方法侧侧对称）覆盖。


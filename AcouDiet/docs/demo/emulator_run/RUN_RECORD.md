# 真机 / 模拟器实际启动记录

本文件是一次**真实启动**的原始记录，不是设计描述。目标是把"能编译、能过测试"推进到
"在 Android 运行时里真的起来了"。

一键复跑：

```powershell
powershell -File tool\run_on_emulator.ps1
```

---

## 0. 最新一次：`ADR-21` / `ADR-22` 之后的实测（**本文最重要的部分**）

**日期**：2026-09-12（`ADR-21`/`ADR-22` 同日）｜ **APK**：230,219,564 B（含 `acoudiet_fp32_v1.0.0.tflite`）

六项判据**全部通过，exit 0**：`boot_completed=1` / `pm ready: True` / `install: Success` /
`top resumed activity is ours: True` / `app pid: 3359` / 无 `FATAL EXCEPTION` /
`Fully drawn com.acoudiet.app/.MainActivity: +14s323ms` / 截图 187,766 B、`stddev=17.77`、`HAS_CONTENT`。

> 🚨 **但"六项全过"这一次并**不**等于"模型能用"。** 同一份 logcat（**第一次** `ADR-21` 后的设备端
> 运行）里是：
>
> ```
> E tflite : Could not open 'assets/models/acoudiet_fp32_v1.0.0.tflite'.
> E tflite : The model allocation is null/empty
> ```
>
> 即**应用起来了、模型加载失败了**。根因与修法见 `ADR-22`：`TfLiteModelCreateFromFile`
> 要文件系统路径，而 Flutter 的 asset 在 Android 上住在 APK 的 zip 里。已改为用
> `TfLiteModelCreate` 从**内存**建模（`ModelRegistry` 经 `AssetReader.readBytes` 供字节）。

**修复前后对照**（同一脚本、同一 AVD、同一判据）：

| | 应用 pid | `Could not open 'assets/models…'` | `model allocation is null/empty` | 应用自身打出 `Initialized TensorFlow Lite runtime` |
|---|---|---|---|---|
| 修复前 | 3396 | **1 命中** | **1 命中** | **否**（该次 logcat 里的 Initialized 来自 pid 3463，不是应用） |
| 修复后 | 3359 | 0 命中 | 0 命中 | **是**（`09-12 15:15:51.697 3359 3456 I tflite: Initialized TensorFlow Lite runtime.`） |

复核命令（新增工具，按"缺陷签名 + **应用自己 pid** 的正面初始化日志"双向判定）：

```powershell
python _toolchain\check_emulator_model_log.py
# → RESULT: PASS -- the app loaded the shipped model on device
#    (no defect signature + the app's own pid initialised the TFLite runtime)

# 证明该判据不是空转（用真实 logcat 构造负例）
python _toolchain\selftest_check_emulator_model_log.py
# → 真实 log PASS(0) / 注入修复前缺陷 FAIL(1) / 删掉初始化证据 FAIL(1)
```

> ✅ **判据缺口已补上**：`run_on_emulator.ps1` 原来只看得到"应用能起来"。现已接入上面这个检查器，
> 成为**第七项独立判据**（`ADR-22`）；它**双向**判定 —— 既拒绝缺陷签名，也拒绝"根本没有加载过"
> 的静默 no-op。因此本文件 §2 的"六项判据"在最新脚本里是**七项**。

> 仍未验证：**推理结果是否正确**（需要真实音频与自采跨域测试集，本仓没有）；以及
> **麦克风链路**（`P-01`…`P-04`）在真实麦克风上的表现。设备端证明的是**加载路径不再失败**。

### 0.1 release 构建的设备端实测（同日，追加）

上面 §0 测的是 **debug** 包。因为"要交付到手机上的其实是 release 包"，所以又对 **release** 构建跑了一遍：

```powershell
flutter build apk --release        # 4 个 ABI，62.2 MB —— 模拟器是 x86_64，必须多 ABI 才装得上
powershell -File tool\run_on_emulator.ps1 `
    -Apk <4-ABI release>.apk -UninstallFirst
```

结果：**`EMULATOR RUN: APP STARTED (all checks passed)`，七项判据全过** ——
`adb install` 退出码 **0**、`Fully drawn com.acoudiet.app/.MainActivity: +1s430ms`（AOT，比 debug 快得多）、
无 `FATAL EXCEPTION`、截图非空白、**模型加载检查 PASS**（应用 pid `3308` 打出
`Initialized TensorFlow Lite runtime`，缺陷签名 0 命中）。

> ⚠️ **第一次测 release 时脚本报了 FAIL，而那是脚本自身的问题，不是 App 的问题。** 两个真实缺陷：
> ① 安装判据用**文本匹配 `Success`** —— 输出被截断成 `Performing Streamed Install` 时既不含
> `Success` 也不含失败行，于是**退出码 0 的成功安装被记成失败**；② 旧包（debug 签名）还在设备上，
> 与新包（release 测试密钥）**签名不一致**，Android 会拒绝覆盖安装，而脚本照旧启动**旧包**，
> 结果两边都是假象。**修法**：安装判据改用 `adb install` 的**退出码**，并新增 `-UninstallFirst`
> 开关；另外打印 `pm path` 与 `versionName` 以**确证装进去的到底是哪一个包**，并把启动后静置时间
> 从 12 s 改为可配的 `-SettleSec`（默认 20 s，冷启动 AOT 包比 debug 慢）。

---

## 1. 环境

> ⚠️ 以下 §1–§6 是**更早一次**运行的记录（`ADR-19` 时期，APK 189,405,034 B、app pid 6465、
> 不含 `ADR-21`/`ADR-22` 的改动）。保留原文以存史；**结论以 §0 为准**。

| 项 | 值 |
|---|---|
| 主机 | Windows 10.0.26200（WHPX 加速可用） |
| Android SDK | `_toolchain/android-sdk`（`platforms/android-34`、`build-tools/34.0.0`、`platform-tools 34.0.5`） |
| 模拟器 | `emulator 37.1.11`（本次新装） |
| 系统镜像 | `system-images;android-34;google_apis;x86_64`（本次新装） |
| JDK | `_toolchain/jdk17` |
| AVD | `acoudiet_api34`（device `pixel_5`，1080×2340 @440dpi） |
| 启动方式 | `-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 2048` |
| APK | `app-debug.apk`（189,405,034 B，未裁剪的 debug 包） |

> 真机：`adb devices` 为空 —— **本机没有插真机**，因此本次全部结论来自模拟器。
> 麦克风链路（`P-01`…`P-04`）仍只在 JVM 层验证过 67 项，**未在真实麦克风上跑过**。

---

## 2. 六项判据逐项实测（`tool/run_on_emulator.ps1`，exit 0）

| # | 判据 | 实测 |
|---|---|---|
| 1 | 模拟器启动到 `sys.boot_completed=1` 且 `pm` 可用 | ✅ `boot_completed=1`、`pm ready: True` |
| 2 | `adb install` 成功 | ✅ `install: Success` |
| 3 | `am start` 成功且成为 **top resumed** activity | ✅ `Status: ok`、`LaunchState: COLD`、`top resumed activity is ours: True` |
| 4 | 包有活进程 | ✅ `app pid: 6465` |
| 5 | logcat 无崩溃 | ✅ 无 `FATAL EXCEPTION` |
| 6 | 首帧真的画出来了 + 截图非空白 | ✅ `Fully drawn com.acoudiet.app/.MainActivity: +4s668ms`；PNG `1080x2340`，156,991 B，`HAS_CONTENT` |

冷启动到首帧 **4.7 秒**（首次安装那次是 15.2 秒，含资源解压与 dex 预热）。

截图与日志：
`home_screen.png`（首屏）、`step2_detect.png`（检测页 + 隐私说明弹窗）、
`step3_consent_ok.png`、`step5_demo.png`、`step6_home_after.png`、`step7_selfcheck.png`、
`logcat.txt`、`emulator.log`。

---

## 3. 界面上真实渲染出的东西（人工核对，非断言）

* 首屏：标题 `AcouDiet · 声膳`；`今日健康评分` 卡片显示 `-- 分`、`--` 评级、四维全 `--`，
  雷达图带四个轴标签（饮食规律性 / 食物结构 / 零食控制 / 进食速度）；
  `估算能量参考` → `暂无数据`；`本周记录 0 次`；`今天还没有记录`；主按钮 `开始 AI 检测`；
  底部导航 首页 / 检测 / 记录 / 报告。
  **空态没有编造任何数字** —— 这正是 `SPEC-U-01` 要求的降级行为。
* 检测页：`当前静默`、`等待进食声…`、`从开始进食到首次确认结果约 4–5 秒`、
  `未确认 / 正在感知…`、`咀嚼次数/平均咀嚼间隔/进食时长/进食速度` 全 `--`。
* **C-02「先签后用」在设备上真的生效**：首次进入检测页弹出「隐私说明 ——
  音频只在内存中处理，不写入存储；本应用不申请网络权限。」并需点「知道了」。
* **C-03 握手通过**：检测页可达（握手失败时该页应被 `ACD-CFG-001` 挡住且无开始按钮）。

---

## 4. ✅ 已修复：Android 上数据库从未建立 → 现已持久化

### 4.1 原缺陷（实测确认）

设备上 `run-as com.acoudiet.app` 列目录，**没有数据库文件**，全盘也搜不到任何 `*.db`；
首屏在重启后依然全空 —— 数据只存在于内存里。

根因链，每一环都有客观证据：

1. `sqlite_ffi.dart` 在 Android 上尝试 `DynamicLibrary.open('libsqlite.so')` / `'libsqlite3.so'`；
2. `libsqlite3.so` 在 Android 上**根本不存在**；
3. `libsqlite.so` 存在（`/system/lib64/libsqlite.so`），但**不在公开库列表里** ——
   `cat /system/etc/public.libraries.txt` 里没有任何 `sqlite` 条目。Android 7 起的
   linker namespace 隔离只允许 app `dlopen` 该列表内的库，因此这一步**必然失败**；
4. APK 里也没有自带 sqlite（`unzip -l` 只有 `libflutter.so`）；
5. 于是 `SqliteFfi.load()` 抛错 → `bootstrap.dart` 按设计降级到内存实现。

### 4.2 修法（已实施，方案 A）

在两侧加一条独立通道 `com.acoudiet.app/sqlite`，用**平台自带的** `android.database.sqlite`：

| 层 | 新增/改动 |
|---|---|
| L1 Kotlin | 新增 `android/SqliteChannelHostAndroid.kt`（`open/execute/query/begin/commit/rollback/close` 七个方法）+ `MainActivity` 注册；`AcouDietException` 增补三个 **已注册**的 `ACD-DB-*` 工厂 |
| L2 桥 | 新增 `data/native/method_channel_sqlite.dart`（`MethodChannelSqlExecutor`） |
| L3 数据 | `sqlite_ffi.dart` 抽出 `SqlExecutor` 抽象（含共享的 `transaction` / `user_version`），原实现改名 `FfiSqlExecutor`；`app_database.dart` 改为后端无关，新增 `openWith(executor, path)` |
| L4/L5 装配 | `bootstrap.dart` 按平台选择后端：Android 走通道，其余走 FFI |

**关键约束**：`transaction` 走 Android 自己的 `beginTransaction` / `setTransactionSuccessful` /
`endTransaction`，而**不是**发 `BEGIN`/`COMMIT` SQL —— `SQLiteDatabase` 自己维护事务状态，
发裸 SQL 会与之失步、破坏不变量 I-3。

**一次自我纠正**：方案 A 的第一版把通道实现放在 L3（`data/db/`），结果 `app_database.dart`
被拖进 `package:flutter/services.dart` → `dart:ui`，**整个 L3 离线套件在纯 Dart VM 下直接跑不起来**。
通道属于 L2（和 `method_channel_audio_bridge.dart` 同级），装配点负责选择后端并把 executor
交给 L3 —— L3 依旧与 Flutter 无关。

### 4.3 修复后的实测证据

| 证据 | 结果 |
|---|---|
| 设备上出现数据库文件 | ✅ `files/acoudiet.db`，49,152 B |
| 是合法 SQLite | ✅ magic `SQLite format 3\0`，`PRAGMA integrity_check = ok` |
| **迁移真的在设备上跑过** | ✅ `PRAGMA user_version = 1`，四张表齐全且列名逐字符合 DDL |
| 冷启动后数据仍在（读盘） | ✅ 首页显示 `本周记录 1 次`、`估算能量参考 约 104–156 kcal` |
| 今日记录列表渲染 | ✅ `今日记录` 小节 + 卡片 `04:39 面包 / 正餐 · 1 片（约 35g）/ ≈130 kcal` |
| 数据不足时如实降级 | ✅ 只有 1 条记录，`饮食规律性` 显示 `--`（不用 0 冒充） |
| 无崩溃 | ✅ logcat 无 `FATAL EXCEPTION` |

复现命令：

```powershell
python tool\device_db_probe.py --insert --dump   # 用设备时钟写一条记录，再 dump 出来
adb shell am start -W -n com.acoudiet.app/.MainActivity   # 冷启动，首页应读到这条记录
```

> `tool/device_db_probe.py` 通过 `adb shell run-as` + **stdin** 喂 SQL：把 SQL 当 argv 传会让
> 设备端的 shell 二次解析，括号与 UTF-8 字面量都会被弄坏（这是第一次尝试失败的原因）。

### 4.4 仍未覆盖的部分

* `query` 走 Android 的 `rawQuery(sql, String[])`，选择参数只能以文本绑定。SQLite 会按**列的
  affinity** 处理比较，数值列与文本绑定值仍按数值比较；写入路径用 `execSQL(sql, Object[])`
  保留完整类型。这一点已由首页聚合数字正确（`本周记录 1 次`、`104–156 kcal`）间接验证，
  但**没有**逐类型对拍测试。
* **真机未测**（本机没插真机），以上全部来自模拟器。
* 麦克风链路（`P-01`…`P-04`）仍只在 JVM 层验证过 67 项，未在真实麦克风上跑过。

---

## 5. 顺带修掉的第二个「从未执行过」的缺陷：release 清单门禁

给手机准备 release 包时才第一次走到 `:app:processReleaseManifest`，于是发现
`app/build.gradle` 里那条 **FF-24 items 4/5 门禁本身是坏的**：

```
Could not get unknown property 'outputFile' for task ':app:processReleaseManifest'
```

`output.getProcessManifestProvider().get()` 返回的是**一个 Task**
（`ProcessMultiApkApplicationManifest`），它没有 `outputFile` 属性。这条门禁是 enforcement
「release 包不含 INTERNET、且只有 RECORD_AUDIO」的唯一机制 —— 也就是说**它以前从未真正跑过**
（更早的 release 构建在 `key.properties` 那一步就抛了，根本到不了这里）。

修法：改为从该 task 自己声明的 outputs 里定位合并后的清单（不依赖随 AGP 版本变化的属性名），
并在定位不到时**失败关闭**（无法审计就不许出包）。

**负例实测**：往 `src/main/AndroidManifest.xml` 注入一条
`<uses-permission android:name="android.permission.INTERNET" />`，release 构建立刻失败：

```
> FF-24 item 4 violated: the merged RELEASE manifest requests INTERNET.
```

**正向实测**（独立于 Gradle 自述，直接读产物）：
`aapt2 dump badging app-release.apk` → 权限只有 `RECORD_AUDIO`
（+ Android 自行添加的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`），**无 `INTERNET`**。
装到手机上测试的完整说明见 `docs/demo/PHONE_INSTALL.md`。

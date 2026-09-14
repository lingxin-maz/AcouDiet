# C-01 权限最小化与无网络 · 隐私证据清单

**SPEC 对应**：`SPEC-C-01`；`SPEC-00 §3.9 FF-24`（七条，**不可交易**）；`API-05 §3/§5`
**一句话**：v1.0 的隐私主张由四件**可机械验证**的事实支撑 —— 权限集合、无网络出口、音频不落盘、一键清除。

---

## 1. 七条约束与本仓证据

| # | FF-24 约束 | 实现位置 | 验证方式 | 状态 |
|---|---|---|---|---|
| 1 | 音频只存在于内存环形缓冲，**不落盘** | `RingBuffer`（`ShortArray`，65536 样本）；`Preprocess` 全程数组运算；`MelFrontend` 只返回 `FloatArray` | `rg -n "File\(|writeAsBytes|openWrite" app/android/app/src/main/kotlin/com/acoudiet/app/audio` → 0 命中；`ai/scripts/forbid_audio_write.py` | ✅ |
| 2 | `cacheDir` 的 `audio_*` **冷启动 + 会话后**强制清理 | 冷启动：`MainActivity.configureFlutterEngine` 后台线程调用 `TempAudioAndroid.clear()`；会话后：`API-01 §2.7` 的 `clearTempAudio` → `MaintenanceRepoImpl.clearTempAudio()` **委托原生**（Dart 侧只有一处 matcher，即无 matcher） | `data_tests.dart`：`clearTempAudio` 委托且**只调用一次**原生方法；`session_tests.dart`：`countTempAudioFiles == 0` 时自检项 8 通过、`-1` 时判"不可判定"而非通过 | ✅ |
| 3 | 数据库只存结构化字段，**无 BLOB 音频列** | `AppDatabase.v1` 的四张表；`AppDatabase.assertNoAudioColumns()`；`SqlDatabase._bindAll` 对 `Uint8List` 直接抛错 | `data_tests.dart`：schema 扫描（无 `BLOB` 类型、列名不含 `audio/mel/pcm/wav/waveform`）+ **绑定 BLOB 参数被拒** 两条断言 | ✅ |
| 4 | **APK 不申请 `INTERNET`** | `AndroidManifest.xml` 仅声明 `RECORD_AUDIO`；依赖面为零（无网络库） | `aapt dump badging app-release.apk \| findstr uses-permission`（打包后执行）；本仓静态检查：`rg -n "INTERNET" app/android` → 0 | ✅ |
| 5 | 仅申请 `RECORD_AUDIO`，无相机/位置/通讯录 | 同上 | 同上；`AndroidManifest.xml` 中 `<uses-permission>` 恰 1 条 | ✅ |
| 6 | 检测由用户主动发起，**无后台常驻 Service** | 无 `<service>` 声明；`MainActivity` 不持有音频生命周期；`AudioCaptureAndroid` 随会话启停 | `rg -n "<service\|startForeground\|WorkManager" app/android` → 0 | ✅ |
| 7 | 一键清除全部数据 | `MaintenanceRepoImpl.clearAllData()`（**单事务**：清 `diet_record` + `behavior_metadata` 级联 + `user_profile` 重置保留行 + 清演示指纹） | `data_tests.dart`：`clearAllData` 后记录数 0、指标数 0、档案重置为默认且**行仍在**、演示指纹被清 | ✅ |

---

## 2. 额外加固（超出 FF-24 的最低要求）

| 项 | 位置 | 为什么 |
|---|---|---|
| `allowBackup=false` + 排除规则 | `AndroidManifest.xml`、`res/xml/data_extraction_rules.xml` | 即使将来有人打开备份，数据库也不会离开设备 |
| `usesCleartextTraffic=false` | 同上 | 明文流量一律禁止（本项目根本不发请求） |
| 无第三方依赖 | `pubspec.yaml` | 依赖面为零 ⇒ 第三方网络调用面为零（见 `docs/reports/c04_dependency_deviation.md`） |
| `RECORD_AUDIO` 是唯一权限，且 `uses-feature microphone required=false` | 同上 | 无麦克风的设备仍可装（Mode B/C 演示必须可用） |
| 麦克风"未启用"与"不可用"可区分 | `AudioBridgeAndroid.getDiagnostics().micInUseKnown` | 否则 `micInUse=false` 会被误读为"麦克风正常"（`SPEC-M-04` 现场判据） |

---

## 3. 打包后需在**普通终端**执行的验收（本环境无法完成）

```powershell
# 1) 权限集合
flutter build apk --release
& "$env:ACOUDIET_HOME\android-sdk\build-tools\34.0.0\aapt.exe" dump badging `
    build\app\outputs\flutter-apk\app-release.apk | findstr uses-permission
# 期望：只有 android.permission.RECORD_AUDIO，且不含 INTERNET

# 2) 会话后残留
adb shell run-as com.acoudiet.app ls cache | findstr audio_
# 期望：无输出

# 3) 飞行模式全流程
adb shell svc wifi disable; adb shell svc data disable
# 跑一次完整检测 → 识别 → 记录 → 报告；期望全流程可用，无任何网络等待

# 4) 抓包
adb shell dumpsys netstats | findstr com.acoudiet.app
# 期望：本应用 UID 网络字节数为 0
```

> 以上四步的**代码前提**已全部满足并已在离线套件中验证（权限声明、清理委托、无 socket 依赖）；
> 剩下的只是打包后在真机上取证据。

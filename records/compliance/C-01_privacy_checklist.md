# C-01 权限最小化与按风味的网络权限 · 隐私证据清单

**SPEC 对应**：`SPEC-C-01` §7（`ADR-44` 起**按风味**判定）；`SPEC-00 §3.9 FF-24`（现行九条：第 1/2/3/6/7 条无条件，第 4/5 条按风味修订，第 8/9 条新增）；`API-05 §1/§3/§5/§13`
**一句话**：隐私主张由四件**可机械验证**的事实支撑 —— 权限集合（分风味）、唯一出网点、音频不落盘、一键清除。**音频在任何风味下都不离开设备**是现行最强的那条证据。
**诚实边界**：`offline` 的「不申请 `INTERNET`」证据**只对 `offline` 风味成立**。若只出 `agent` 包，这一条**不适用**（`SPEC-C-01` §7 的修订摘要与 §7 #1a/#1b 已写明）。

---

## 1. 九条约束与本仓证据

| # | FF-24 约束 | 实现位置 | 验证方式 | 状态 |
|---|---|---|---|---|
| 1 | 音频只存在于内存环形缓冲，**不落盘** | `RingBuffer`（`ShortArray`，65536 样本）；`Preprocess` 全程数组运算；`MelFrontend` 只返回 `FloatArray` | `rg -n "File\(|writeAsBytes|openWrite" app/android/app/src/main/kotlin/com/acoudiet/app/audio` → 0 命中；`ai/scripts/forbid_audio_write.py` | ✅ |
| 2 | `cacheDir` 的 `audio_*` **冷启动 + 会话后**强制清理 | 冷启动：`MainActivity.configureFlutterEngine` 后台线程调用 `TempAudioAndroid.clear()`；会话后：`API-01 §2.7` 的 `clearTempAudio` → `MaintenanceRepoImpl.clearTempAudio()` **委托原生**（Dart 侧只有一处 matcher，即无 matcher） | `data_tests.dart`：`clearTempAudio` 委托且**只调用一次**原生方法；`session_tests.dart`：`countTempAudioFiles == 0` 时自检项 8 通过、`-1` 时判"不可判定"而非通过 | ✅ |
| 3 | 数据库只存结构化字段，**无 BLOB 音频列** | `AppDatabase.v1` 的四张表；`AppDatabase.assertNoAudioColumns()`；`SqlDatabase._bindAll` 对 `Uint8List` 直接抛错 | `data_tests.dart`：schema 扫描（无 `BLOB` 类型、列名不含 `audio/mel/pcm/wav/waveform`）+ **绑定 BLOB 参数被拒** 两条断言 | ✅ |
| 4 | **`offline` 风味不申请 `INTERNET`；`agent` 风味恰多这一项**（`ADR-44` 修订） | 两个风味各自的 Manifest overlay；依赖面为零（无 `http` / `dio` / `url_launcher`） | **对两个风味分别** `aapt dump badging`（打包后执行，见 §3）；`python tool/check_network_boundary.py --strict` 白名单外命中 0 | ✅ |
| 5 | 权限集合最小（两档都查） | 同上；`offline` 的 `<uses-permission>` 恰 1 条、`agent` 恰 2 条 | 同上；两档均无相机/位置/通讯录/`READ_MEDIA_*`/`VIBRATE` | ✅ |
| 6 | 检测由用户主动发起，**无后台常驻 Service** | 无 `<service>` 声明；`MainActivity` 不持有音频生命周期；`AudioCaptureAndroid` 随会话启停 | `rg -n "<service\|startForeground\|WorkManager" app/android` → 0 | ✅ |
| 7 | 一键清除全部数据 | `MaintenanceRepoImpl.clearAllData()`（**单事务**：清 `diet_record` + `behavior_metadata` 级联 + `user_profile` 重置保留行 + 清演示指纹）；`ADR-44` 起**一并删除** `<filesDir>/agent/credentials.json` | `data_tests.dart`：`clearAllData` 后记录数 0、指标数 0、档案重置为默认且**行仍在**、演示指纹被清；`agent_tests`：清除后 `AgentCredentialsStore.read() == null` | ✅ |
| **8** | 🆕 **音频永不离开设备**（`ADR-44` 新增，**取代第 4 条成为最强主张**；不分风味、不分版本、不可交易） | 构造点唯一（`G-02` 的 `AgentPromptBuilder`）；网络层不引用任何音频类型 | `python tool/check_audio_egress.py --strict`：静态（网络层不得引用 `Float32List`/`Uint8List`/音频类型）+ 运行时断言（请求体是纯结构化 JSON）；负控必须变红 | ✅ |
| **9** | 🆕 **云端智能默认关闭**（`ADR-44` 新增） | `AgentService.enabled` 首启为 `false`；开启须经 `SPEC-C-06` 的显式同意门 | `test/ui/agent_consent_test.dart`：未同意时 `enabled == false` 且**不发出任何请求**；负控（强行置真）必须变红 | ✅ |

> 🔴 **只有 `offline` 风味的 `aapt dump badging` 输出支持「不申请 `INTERNET` 权限」这条主张。** `agent` 风味的输出**含**该权限，它的证据是「权限集合恰好多且只多这一项」与「出口唯一 + 音频零出境」，**不是**「无网络」。两者**不得**互相替代，也不得把 `agent` 的取证说成 `offline` 的。
>
> `SPEC-C-01` §7 的判据编号对应：`#1a` = `offline` 不含该权限、`#1b` = `agent` 权限集合逐字相等、`#2` = 两档都不含相机/位置/通讯录/`READ_MEDIA_*`/`VIBRATE`、`#3` = 网络调用只在白名单目录内、`#3b` = 音频不出境、`#8`/`#9`/`#10` = 无障碍代操作 / 模型名 / Key 不泄露。

---

## 2. 额外加固（超出 FF-24 的最低要求）

| 项 | 位置 | 为什么 |
|---|---|---|
| `allowBackup=false` + 排除规则 | `AndroidManifest.xml`、`res/xml/data_extraction_rules.xml` | 即使将来有人打开备份，数据库也不会离开设备 |
| `usesCleartextTraffic=false` | 同上 | 明文流量一律禁止：`agent` 风味的唯一出口也必须走 TLS；`offline` 风味本来就不发任何请求 |
| 零新增 pub 依赖 | `pubspec.yaml` | 依赖面为零 ⇒ 第三方网络调用面为零（`ADR-44` 明确不引入 `http`/`dio`/`url_launcher`，见 `records/reports/c04_dependency_deviation.md`） |
| `RECORD_AUDIO` 是唯一权限，且 `uses-feature microphone required=false` | 同上 | 无麦克风的设备仍可装（Mode B/C 演示必须可用）；`agent` 风味只在这之上加 `INTERNET` |
| 麦克风"未启用"与"不可用"可区分 | `AudioBridgeAndroid.getDiagnostics().micInUseKnown` | 否则 `micInUse=false` 会被误读为"麦克风正常"（`SPEC-M-04` 现场判据） |
| API Key 只存应用私有目录、模式 `0600` | `AgentCredentialsStore`（`API-07` §2） | 不进 SQLite、不进日志、不进诊断快照、不进截图；UI 只显示后 4 位 |

---

## 3. 打包后需在**普通终端**执行的验收（本环境无法完成）

```powershell
# 1) 权限集合 —— 两个风味都要出包、都要留证（SPEC-C-01 §7 #1a/#1b/#2，PLAN-C-01 的验收）
flutter build apk --release --flavor offline
& "$env:ACOUDIET_HOME\android-sdk\build-tools\34.0.0\aapt.exe" dump badging `
    build\app\outputs\flutter-apk\app-offline-release.apk | findstr uses-permission
# 期望：只有 android.permission.RECORD_AUDIO，不含 INTERNET

flutter build apk --release --flavor agent
& "$env:ACOUDIET_HOME\android-sdk\build-tools\34.0.0\aapt.exe" dump badging `
    build\app\outputs\flutter-apk\app-agent-release.apk | findstr uses-permission
# 期望：恰好多一项 android.permission.INTERNET（集合逐字相等）

# 包内容 / 权限闸门（同一检查器的两个方向；见 tool/check_apk_contents.py）
python tool\check_apk_contents.py app-offline-release.apk --expect-no-internet   # 期望 exit 0
python tool\check_apk_contents.py app-agent-release.apk  --expect-internet      # 期望 exit 0

# 2) 会话后残留
adb shell run-as com.acoudiet.app ls cache | findstr audio_
# 期望：无输出

# 3) 飞行模式全流程（跑 agent 包；Agent 页允许显示降级态，其余页面必须照常）
adb shell svc wifi disable; adb shell svc data disable
# 跑一次完整检测 → 识别 → 记录 → 报告；期望全流程可用，无任何网络等待

# 4) 抓包（只对 offline 包成立：期望本应用 UID 网络字节数为 0）
adb shell dumpsys netstats | findstr com.acoudiet.app
```

> 以上四步的**代码前提**已全部满足并已在离线套件中验证（权限声明、清理委托、无 socket 依赖、唯一出口、音频零出境）；
> 剩下的只是打包后在真机上取证据。**两个风味的证据必须来自同一次构建**（`PLAN-C-06` §7 #3）。

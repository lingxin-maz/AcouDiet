# U-02 真机缺陷：「只能识别一次」——事件流被绑死在第一个 sessionId 上

**状态**：✅ 已定位、已修复、已加回归测试（未做真机复测：本机 `adb devices` 为空）
**报告来源**：用户真机反馈 —— 「安装到手机上后只能识别一次，之后点再次检测打开了麦克风，
但是检测程序和声波体现都没在工作」
**影响文件**：`app/lib/data/native/method_channel_audio_bridge.dart`、
`app/lib/presentation/state/notifiers.dart`、`app/lib/presentation/presenters/detect_presenter.dart`、
`app/lib/presentation/pages/detect/detect_page.dart`、
`app/android/.../AudioBridgeAndroid.kt`、`app/android/.../AudioChannelHostAndroid.kt`
**相关文档**：`API-01 §3.1`（订阅方式）、`SPEC-U-02 §2.2 步骤 9/10`、`§2.3`（状态迁移）

---

## 1. 症状与复现路径

| 步骤 | 期望 | 实测（修复前） |
|---|---|---|
| 装好 App，进「检测」页点「开始 AI 检测」 | 波形动、约 4–5 s 出结果卡片 | ✅ 正常 |
| 点「停止检测」 | 回到「再次检测」 | ✅ 正常 |
| 点「再次检测」 | 波形动、能识别 | ❌ **系统隐私指示灯亮（麦克风确实开了），波形是一条水平线，永远不出预测** |

「波形不动 + 永远不出预测」这两件事**同时**发生，是定位的关键：`level` 与 `patch` 是两类事件，
唯一能让两者一起消失的环节就是**原生事件流本身没有送到 Dart**。

## 2. 根因：三处代码共同造成，缺一处都构不成这个现象

### 2.1 `EventChannel` 的订阅参数是「调用时捕获一次」的

`flutter/packages/flutter/lib/src/services/platform_channel.dart:676`：

```dart
controller = StreamController<dynamic>.broadcast(onListen: () async {
  ...
  await methodChannel.invokeMethod<void>('listen', arguments);   // arguments 是闭包捕获的
}, onCancel: () async {
  ...
  await methodChannel.invokeMethod<void>('cancel', arguments);
});
```

`receiveBroadcastStream(arguments)` 返回的是**一个**广播流，`arguments` 在**调用时**被闭包捕获。
以后每一次「监听者从 0 变 1」都会把**同一份参数**再发一次 `listen`。

### 2.2 桥接层把这个流缓存了起来（`_stream ??=`）

`method_channel_audio_bridge.dart` 修复前：

```dart
Stream<Map<Object?, Object?>>? _stream;

Stream<Map<Object?, Object?>> events({required String sessionId}) {
  _stream ??= _event.receiveBroadcastStream({'sessionId': sessionId})...;
  return _stream!;                       // ★ 第二个会话拿到的是第一个会话的流
}
```

第二个会话于是**重新订阅了第一个会话的 `sessionId`**。

### 2.3 原生按 `sessionId` 过滤，于是把所有事件丢掉

`AudioBridgeAndroid.emit()`（第 466 行）：

```kotlin
val sid = event["sessionId"]           // 新会话的真实 id
val subscribed = subscribedSessionId   // 仍然是第一个会话的 id
if (subscribed != null && sid != subscribed) return   // ★ 静默丢弃
```

麦克风由 `startSession` 打开（与订阅无关），所以**隐私指示灯亮着、采集在跑、事件全被扔掉** ——
正好是用户描述的现象。

### 2.4 第二处：那个流永远不会收到 `cancel`

`DetectNotifier.stop()` 修复前只做了 `_handle = null`，**没有取消 `level` 那个订阅**
（它由 `dispose()` 取消，而 `stop()` 从不调用）。于是：

* 广播控制器的监听数从 2 降到 1，**永远不会归零** → `onCancel` 不触发 → 原生侧收不到
  `cancel`，`subscribedSessionId` 一直停在第一个会话；
* 就算它归零了，2.2 的缓存也会在重新订阅时把**旧 id** 再发一遍。

两条路都通向同一个结果，所以**必须一起修**，只修一条仍然是坏的。

### 2.5 第三处：`onCancel` 无条件清空

`AudioChannelHostAndroid.onCancel()` 原来无条件 `setSubscription(null) + attachSink(null)`。
Dart 侧的取消是异步的，**上一个流的 `cancel` 完全可能在新会话 `listen` 之后才到**；
到那一刻就会把**正在跑的会话**的 sink 清掉。

## 3. 修复

| # | 位置 | 修法 |
|---|---|---|
| 1 | `method_channel_audio_bridge.dart:150-166` | 流按**会话**缓存：`_streamSessionId != sessionId` 时重建 `receiveBroadcastStream`；同一会话的多次 `events()` 仍共用**一个**实例（否则会出现两条 `listen`，第二条会把原生的 sink 顶掉） |
| 2 | `notifiers.dart:469-497`（`stop()`） | `ended` 之前 `await handle.dispose()`：把 `patch` 与 `level` **两个**订阅都放掉，广播流归零 → `onCancel` → 原生释放订阅。顺带把 `session.stop()` 排队的那个 `DetectionState` 丢掉，避免 `ended` 之后被翻回 `listening` |
| 3 | `AudioBridgeAndroid.kt:118-135` + `AudioChannelHostAndroid.kt:140-148` | `clearSubscription(sessionId)`：**只有 id 对得上当前订阅才释放**；上一个流的迟到 `cancel` 不再能掐掉新会话 |
| 4 | `detect_presenter.dart:370-392` + `detect_page.dart:267-272` | `confirmed` / `ending` 归入运行态，按钮仍是「停止检测」。修复前 `confirmed` 会被当成空闲态，结果卡片旁边直接出现第二个「开始 AI 检测」，点下去原生会以 `ACD-SESS-002` 拒绝（`maxConcurrentSessions = 1`），把正在跑的会话变成**没有入口可停**的状态。按 `SPEC-U-02 §2.3`，`confirmed` 与 `ending` 都是运行态 |
| 5 | `notifiers.dart:360-365`、`startRealtime`/`startSample` | `_busy` 守卫：请求权限中/启动中/结束中/已有会话时不再开第二个会话 |

## 4. 验证（全部为实测）

### 4.1 新回归套件 `app/test/data/audio_event_channel_test.dart`（5 项）

直接断言**平台消息**（`listen` / `cancel` 的载荷），因为坏掉的正是这条契约：

| 断言 | 结果 |
|---|---|
| 第二个会话的 `listen` 携带**自己的** `sessionId` | ✅ |
| 同一会话的两个订阅只发一次 `listen` | ✅ |
| 平台推来的 `level` / `patch` 真的到达两个订阅 | ✅ |
| `stop()` 之后两个订阅都释放（`liveTaps == 0`），第二个会话拿到**新的**流并照常消费事件（`ackedSeq == [0, 0]`） | ✅ |
| 运行态按钮固定为「停止检测」 | ✅ |

**负例对照（证明测试真的抓得住这个缺陷）**：把 `events()` 临时改回修复前的 `_stream ??=` 写法后：

```
Expected: ['S-1', 'S-2']
  Actual: ['S-1', 'S-1']        ← 第二个会话确实又订阅了第一个会话
Some tests failed.
```

恢复修复后 5 项全过。这正是「测试先红后绿」的证据，而不是一条恰好通过的断言。

### 4.2 既有套件（无回归）

| 命令 | 结果 |
|---|---|
| `flutter test`（app/test 全量） | **110 项全过**（修复前 105 + 新增 5） |
| `flutter analyze` | 0 error；**81 issues，与 `docs/release/analyze_20260912.txt` 逐条相同**（只有我改过的 `ui_presenter_tests.dart` 里三条 info 的行号随新增行平移），即**未引入任何新问题** |
| `dart tool/ui_presenter_tests.dart` | **377 / 377**（373 → 377，新增 4 项断言） |
| `dart tool/pure_tests.dart` | 174 / 174 |
| `dart tool/session_tests.dart` | 102 / 102 |
| `python tool/run_offline_tests.py` | 7 个可离线文件全过（8 个需真实 `flutter test`，含本套件） |
| `python tool/check_bridge_symmetry.py --strict` | PASS |
| `python tool/check_l4_usage.py --strict` | PASS（71 文件 / 200 类） |

### 4.3 重新出包（同时证明 Kotlin 改动可编译）

```
flutter build apk --release --target-platform android-arm64 --android-project-arg=acoudietAbis=arm64-v8a
→ √ Built build\app\outputs\flutter-apk\app-release.apk (24.3MB)   exit 0
```

产物核对（`aapt2 dump badging` + `_toolchain/check_apk_contents.py`）：

| 项 | 值 |
|---|---|
| 字节数 | 25,466,638（与修复前同尺寸；本修复只改 Dart/Kotlin 逻辑） |
| sha256 | `9c67a61fe1e20d50844a91778f820902996aac451eaccf59d6c9dfa3db1f14c4` |
| 权限 | `RECORD_AUDIO` + `com.acoudiet.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`，**无 `INTERNET`** |
| 签名 | `CN=AcouDiet TEST`（测试密钥）· `apksigner verify` exit 0 · `zipalign -c -p 4` exit 0 |
| ABI | 仅 `arm64-v8a`（`lib/arm64-v8a/libtensorflowlite_jni.so` 3,401,672 B 在内） |
| 模型 | `acoudiet_fp32_v1.0.0.tflite` 4,051,716 B，sha256 `705ffc62…560a`，与模型组交付件逐字节相同 |

> 📌 指纹取自**最后一次重打**。第一次重打（00:26）之后 `notifiers.dart` 又改了一处
> （`stop()` 里把 `handle.dispose()` 包进 `try/catch`，避免拆订阅异常把页面卡在 `ending`），
> 因此两个包都重打过一遍（release 00:38 / profile 00:39），并核对 `app/lib/**` 与
> `app/android/**` 中没有文件晚于 APK —— 即**包确实来自当前源码树**。
> profile 包同批重打：100,845,954 B / sha256 `63648927911a5dd064ea668ac756f7e59d460e62f5376339f4b1d0d11cd94bd3`。

已按 `docs/demo/PHONE_INSTALL.md §3` 的命名覆盖 `dist/AcouDiet-1.0.0-arm64-release.apk` 与
`dist/AcouDiet-1.0.0-arm64-profile.apk`。

## 5. 尚未修复、但已实测发现的邻近缺陷（同一处生命周期）

**90 s 静默自动结束时，Dart 侧完全不知情。** `DetectionSession._onEvent` 对
`sessionEnded` 是 `break`（注释写「`stop()` 拥有收尾路径」），但原生
`autoEndOnSilence()` 会自己结束会话并关闭麦克风。后果：

1. 页面仍显示「正在感知进食声音…」（波形是上一次会话的残留），而不是 `SPEC-U-02 §2.3`
   要求的「90 s 静默 → `ending` → `ended`」；
2. 用户此时点「停止检测」→ 原生 `sm.stop(id)` 抛 `ACD-SESS-001`（会话早已 IDLE）→
   页面显示错误码；
3. 这次会话里**已确认的食物不会落库**（`_persist` 只在 `stop()` 里被调用）。

同一条 `break` 还使 **Demo 模式 B（示例演示）** 用同一路径结束注入会话，因此它的记录同样
不会落库。**本报告不修这一条**：它需要给 `DetectionSession` 增加「原生结束」的收尾与结果回调、
并让 `DetectionNotifier` 据此进入 `ended`，属于另一次改动，且本机无法真机复测。

**用户可用的绕行**：静默自动结束后点一次「停止检测」（会显示一次 `ACD-SESS-001` 提示），
页面即回到「再次检测」，再点就能正常开始新会话 —— 修复后这条路径**不再破坏第二次检测**，
只是那一次的记录会丢。

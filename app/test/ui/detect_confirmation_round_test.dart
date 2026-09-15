// ADR-49 · 用户实测缺陷：「按下『是』的确认后会影响到下一轮判断」
//
// 复现路径（这就是用户在真机上看到的东西）：
//   1. 第一次检测：识别到 0.5 置信度的类别 → 弹层「疑似 薯片，请确认？」→ **点「是」**；
//   2. 停止检测；
//   3. 第二次检测开始 → **第一帧就显示上一次那个已确认的卡片**；而且整个第二轮里，只要新证据
//      还没到 `confirmed`，卡片就一直被上一轮的结果占着（`DetectPresenter.predictionOf` 的
//      `heldConfirmed` 分支：`held != null && held.confirmed && stage != confirmed` → 直接返回
//      旧卡片）。用户的话是「影响到下一轮判断」，代码里就是这一个字段。
//
// 根因不在会话层，在 `DetectNotifier`：`_heldConfirmed`（以及 `_prediction` / `_behavior` /
// `_savedRecord`）**从来没有在会话边界被清空**。`ADR-47` 让「是」**同步**产生一个 `confirmed`
// 视图（这是对的，按钮要立刻消失），于是"点『是』"这一步**当场**就把旧卡片钉进了 `_heldConfirmed`
// —— 缺陷一直存在，但这轮改动把它从"可能要等到下一个 patch"变成"按下就发生"。
//
// 本文件先写红断言把路径钉死，再验证修法：会话边界（开始 / 结束）必须丢掉上一轮的展示状态。
import 'dart:typed_data';

import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/data/fake_repo.dart';
import 'package:acoudiet/data/native/audio_bridge.dart';
import 'package:acoudiet/domain/service/demo_controller.dart' show AssetReader;
import 'package:acoudiet/presentation/presenters/detect_presenter.dart' show DetectUiState;
import 'package:acoudiet/presentation/state/acou_scope.dart';
import 'package:acoudiet/presentation/state/app_services.dart';
import 'package:flutter_test/flutter_test.dart';

const int _anchorMs = 1789308169834;

class _NoAssets implements AssetReader {
  const _NoAssets();

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<String> readString(String path) async => '{"records":[]}';
}

Float32List _mel() =>
    Float32List(cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames)
      ..fillRange(0, cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames, 0.5);

/// `_uniform(top, classId)` with the same shape the fake engine produces.
Float32List _probs(double top, int classId) {
  final p = Float32List(cfg.FeatureConfig.numClasses);
  final rest = (1 - top) / (cfg.FeatureConfig.numClasses - 1);
  for (var i = 0; i < p.length; i++) {
    p[i] = i == classId ? top : rest;
  }
  return p;
}

/// Keeps the base `events()`/`emitPatch` behaviour (filtered by session id) so the patches below
/// travel the same path the native side uses. The other recovery tests replace the event stream,
/// which is exactly why they cannot drive a patch at all.
class _Bridge extends FakeAudioBridge {}

Future<({AcouNotifiers notifiers, _Bridge bridge})> _host(
  Float32List Function() probs,
) async {
  final bridge = _Bridge();
  final repo = FakeRepo(records: const [], baseDayMs: _anchorMs);
  final engine = FakeInferenceEngine(scripted: (i) => probs());
  final services = AppServices.assemble(
    assets: const _NoAssets(),
    dietRepo: repo,
    statsRepo: repo,
    profileRepo: repo,
    maintenanceRepo: PlaceholderMaintenanceRepo(
      diet: repo,
      profile: repo,
      bridge: FakeAudioBridge(),
    ),
    bridge: bridge,
    engine: engine,
    nowMsOverride: _anchorMs,
  );
  // The C-03 gate is not advisory: `DetectNotifier.blocked` is `services.detectionBlocked`, which is
  // true until the handshake has run, and both start paths return early on it.
  await services.runHandshake();
  // A patch that reaches an unloaded engine throws `ACD-INF-001`; load it the way the registry does.
  await engine.load(assetPath: 'assets/models/model.tflite');
  return (notifiers: AcouNotifiers(services), bridge: bridge);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pushes patches until [predicate] holds, then gives up. Returns how many were needed.
  Future<int> pushUntil(
    _Bridge bridge,
    bool Function() predicate, {
    int max = 40,
  }) async {
    for (var i = 0; i < max; i++) {
      bridge.emitPatch(seq: i, tStartMs: i * 4096, mel: _mel());
      await Future<void>.delayed(Duration.zero);
      if (predicate()) return i + 1;
    }
    return max;
  }

  test('REPRO: 点「是」之后开始的下一次检测不得继承上一轮的已确认卡片', () async {
    // 0.5 sits in [tauLow 0.45, tauConfirm 0.70): the only band that asks the two-choice question.
    var probs = _probs(0.50, 0);
    final (:notifiers, :bridge) = await _host(() => probs);
    final detect = notifiers.detect;

    // ---- detection #1: reach the question, then answer 「是」 ---------------------------------
    await detect.startRealtime();
    expect(detect.sessionRunning, isTrue, reason: '前置：会话必须真的起来');
    await pushUntil(bridge, () => detect.prediction.shouldAskUser);
    expect(detect.prediction.shouldAskUser, isTrue,
        reason: '前置：0.5 置信度必须落在会提问的区间');

    detect.answerConfirmation(accepted: true);
    expect(detect.prediction.confirmed, isTrue,
        reason: 'ADR-47：「是」同步生效，卡片当场变已确认');
    final firstText = detect.prediction.text;
    expect(firstText, isNotEmpty);

    await detect.stop();
    expect(detect.sessionRunning, isFalse);
    // The ENDED page keeps the finished session's own result: that is the session summary, and
    // ADR-46 records it as intended ("the prediction view is not cleared on stop"). What must not
    // happen is that result following the user into the next detection -- asserted below.
    expect(detect.uiState, DetectUiState.ended);
    expect(detect.prediction.text, firstText,
        reason: '停止后留下的必须是**这一轮**的结果，页面不会凭空清空');

    // ---- detection #2: a brand new session must start from nothing ---------------------------
    probs = _probs(0.50, 3); // noodles now, a different class
    await detect.startRealtime();
    expect(detect.sessionRunning, isTrue);
    // Before a single patch of the new session has arrived:
    expect(detect.prediction.confirmed, isFalse,
        reason: '第二次检测一开始就不得还挂着上一次的已确认卡片');
    expect(detect.prediction.text, isNot(firstText),
        reason: '也不能把上一轮那个食物的文案带到新一轮');

    // The very first frame of the new session: `stage == none` renders `heldConfirmed ?? sensing`.
    bridge.emitPatch(seq: 0, tStartMs: 0, mel: _mel());
    await Future<void>.delayed(Duration.zero);

    expect(detect.prediction.confirmed, isFalse,
        reason: '第二次检测的第一帧不得显示上一次检测的确认卡片');
    expect(detect.prediction.text, isNot(firstText),
        reason: '也不能把上一轮那个食物的文案带到新一轮');

    // And it must stay honest for the rest of the round.
    await pushUntil(bridge, () => detect.prediction.shouldAskUser, max: 20);
    expect(detect.prediction.shouldAskUser, isTrue,
        reason: '新一轮必须自己走到提问，而不是被旧卡片占位');
    expect(detect.prediction.confirmed, isFalse,
        reason: 'heldConfirmed 的旧值会在这里把新一轮的提问卡片顶掉');
    expect(detect.prediction.labelText, isNot(cfg.FeatureConfig.classLabels[0]),
        reason: '新一轮问的是面条，不是上一轮的薯片');

    await detect.stop();
    await notifiers.dispose();
    bridge.dispose();
  });

  test('上一轮的「已自动记录」横幅不得出现在下一轮里', () async {
    // The `ended` page is SUPPOSED to keep the finished session's outcome (ADR-46: behaviour rows +
    // 「已自动记录」 banner + the last card). What must not happen is that outcome following the user
    // into the *next* detection: `detect_page.dart` renders the banner on `savedRecord != null`
    // alone, with no state gate, so an uncleared `savedRecord` pins it to the new round too.
    final (:notifiers, :bridge) = await _host(() => _probs(0.90, 0));
    final detect = notifiers.detect;

    await detect.startRealtime();
    await pushUntil(bridge, () => detect.prediction.confirmed, max: 40);
    await detect.stop();

    expect(detect.savedRecord, isNotNull,
        reason: '前置：这一轮确实落了一条记录，ended 页面正是要显示它');
    expect(detect.uiState, DetectUiState.ended);

    await detect.startRealtime();
    expect(detect.savedRecord, isNull,
        reason: '新一轮开始，上一轮的「已自动记录」不得继续挂在页面上');
    expect(detect.prediction.confirmed, isFalse,
        reason: '新一轮的第一帧必须是干净的中性态');
    expect(detect.uiState, isNot(DetectUiState.ended),
        reason: '新一轮不得继续停留在 ended 状态');

    await detect.stop();
    await notifiers.dispose();
    bridge.dispose();
  });
}

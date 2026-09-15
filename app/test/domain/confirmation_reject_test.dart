// ADR-29 回归防线：检测页「否」按钮**不得抛错**。
//
// 实测缺陷：`U-02` 只有「是 / 否」两个按钮，而「否」无法提供 `alternativeClassId`
// （v1.0 裁掉了选类别 UI）。旧实现把「否」接到 `answerConfirmation(accepted: false)`，
// 它走进 `alternativeClassId == null` 分支抛 `ACD-DB-004`，被 notifier 捕获后把页面
// 打进错误态 —— **点「否」100% 必然报错**，是恒定路径而不是边界情况。
//
// 本文件锁定两条**不依赖聚合器积累过程**的契约，因此测得稳、也不容易随评分参数漂移：
//   1. `rejectSuggestion()` 在没有待答问题时报 `ACD-SESS-002`（前置契约），
//      **不是** `ACD-DB-004` —— 后者正是"合法操作被当成参数错误"的旧症状；
//   2. `answerConfirmation(accepted: false)` 缺 `alternativeClassId` 时报错，
//      即"想拒绝就必须走 rejectSuggestion()"，不允许记录一个猜出来的类别。
//
// 为什么不驱动真实会话来测「否」：那需要让聚合器稳定停在 `lowConfidence`，
// 而 EMA + 连续计数的组合对阈值很敏感（本次实测就写出了一个恒停在 `observing` 的探针）。
// 把断言放在契约层更可靠；端到端的按钮接线由 `ui_presenter_tests` 的页面测试覆盖。

import 'package:acoudiet/core/errors.dart';
import 'package:acoudiet/data/fake_repo.dart';
import 'package:acoudiet/data/native/audio_bridge.dart';
import 'package:acoudiet/domain/model/diet_record.dart';
import 'package:acoudiet/domain/model/inference.dart';
import 'package:acoudiet/domain/service/detection_session.dart';
import 'package:acoudiet/domain/service/inference_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个永远说"还没加载"的引擎：本文件不触发推理，只用它满足构造参数。
class _IdleEngine implements InferenceEngine {
  @override
  bool get isLoaded => false;
  @override
  String get delegateInUse => 'cpu';
  @override
  String? get modelVersion => null;
  @override
  int? get modelNFrames => null;
  @override
  String? get runtimeVersion => null;
  @override
  Future<void> load({required String assetPath, dynamic modelBytes}) async {}
  @override
  Future<InferenceResult> run(dynamic mel, {required int nFrames}) async =>
      throw StateError('not used in this test');
  @override
  Future<void> dispose() async {}
}

DetectionSession _idleSession() => DetectionSession(
      bridge: FakeAudioBridge(),
      engine: _IdleEngine(),
      diet: FakeRepo(),
      votingConfig: VotingConfig.fromFeatureConfig(),
      behaviorConfig: BehaviorConfig.fromFeatureConfig(),
    );

void main() {
  test('没有待答问题时 rejectSuggestion 报会话状态错误，不是参数错误', () {
    final session = _idleSession();
    // 会话从未 start，`_decision` 是 idle（stage == none）→ 前置契约不满足。
    expect(
      () => session.rejectSuggestion(),
      throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.illegalTransition)),
    );
  });

  test('空会话下两个方法都报会话状态错误，不报参数错误', () {
    // 这条断言的价值在于**错误码的归属**：
    // 旧缺陷的现象就是"点否"报出 `ACD-DB-004`（参数错误），让一个合法的用户操作看起来像
    // 调用方写错了参数。现在没有待答问题时，两个入口都必须报 `ACD-SESS-002`（状态错误）。
    for (final action in <void Function(DetectionSession)>[
      (s) => s.rejectSuggestion(),
      (s) => s.answerConfirmation(accepted: false),
    ]) {
      final session = _idleSession();
      try {
        action(session);
        fail('空会话下不应成功');
      } on AcouDietError catch (e) {
        expect(e.code, Codes.illegalTransition);
        expect(e.code, isNot(Codes.dbInvalidArgument),
            reason: 'ACD-DB-004 正是"点否必然报错"那次的错误码，不应再出现');
      }
    }
  });

  test('confirmationDismissed 初始为 false，且会话未启动时也能安全读取', () {
    final session = _idleSession();
    expect(session.confirmationDismissed, isFalse);
  });
}

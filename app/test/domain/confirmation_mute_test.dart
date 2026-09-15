// ADR-47 · FF-20d 会话内确认静默窗口（用户要求：三分钟）
//
// 用户实测缺陷：检测时点「否」，**同一条判断一秒钟后又问一遍** —— 按钮看起来"没用"。
//
// 根因不是按钮没接线（那已经修过），而是 `SPEC-P-06` §2.4 早就写下、却从来没有人实现的一条要求：
// 「同一 `classId` 只问一次」。聚合器每个 patch 都会重新进入 `lowConfidence`，会话层却没有记住
// 用户已经答复过这个类别。
//
// 本文件把用户要求的语义逐条锁死：
//   1. 「否」之后，同一 `classId` 在 `confirmation_mute_seconds`（180 s）内不得再次提问；
//   2. 窗口按**会话内**计时，同一次检测内有效，新会话从零开始；
//   3. 窗口到期后证据可以重新赢回提问权（不是永久静音）；
//   4. 只静默被答复的那个类别，别的类别不受牵连；
//   5. 「否」之后不得自动落库该类别 —— 否则「否」等于没点。
//
// 时间由 `DetectionSession.clock` 注入，所以"三分钟"是用 180000 ms 的边界断言的，而不是靠 sleep。
import 'dart:typed_data';

import 'package:acoudiet/core/feature_config.g.dart' as cfg;
import 'package:acoudiet/data/fake_repo.dart';
import 'package:acoudiet/data/native/audio_bridge.dart';
import 'package:acoudiet/domain/model/diet_record.dart';
import 'package:acoudiet/domain/model/inference.dart';
import 'package:acoudiet/domain/service/detection_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按测试的指令作答的解码器。
///
/// `SPEC-P-06` §2.4 明确「聚合器不负责去重」，所以验收测试必须能直接说"聚合器说：class 0 又是
/// `lowConfidence`，而且它会一直这么说"，而不必去跟 EMA 预热和阈值标定缠斗。这样被测对象就只剩
/// 会话层自己的行为。
class _AskDecoder implements SequenceDecoder {
  int classId = 0;
  VoteStage stage = VoteStage.lowConfidence;
  int adds = 0;

  @override
  int get sampleCount => adds;

  @override
  int get consecutiveCount => adds;

  @override
  void reset() => adds = 0;

  @override
  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) {
    adds++;
    final asking = stage == VoteStage.lowConfidence;
    return AggregatedDecision(
      stage: stage,
      classId: classId,
      label: cfg.FeatureConfig.classLabels[classId],
      smoothedConfidence: asking ? 0.50 : 0.90,
      consecutiveCount: adds,
      shouldAskUser: asking,
      smoothedProbs: r.probs,
    );
  }
}

Float32List _mel() =>
    Float32List(cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames)
      ..fillRange(0, cfg.FeatureConfig.nMels * cfg.FeatureConfig.nFrames, 0.5);

Float32List _probs() {
  final p = Float32List(cfg.FeatureConfig.numClasses);
  p[0] = 0.90;
  for (var c = 1; c < p.length; c++) {
    p[c] = 0.10 / (p.length - 1);
  }
  return p;
}

FakeRepo _repo() => FakeRepo(
      baseDayMs: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch,
      kcalOverride: FakeRepo.defaultKcalTable,
    );

void main() {
  late int nowMs;
  late FakeAudioBridge bridge;
  late FakeInferenceEngine engine;
  late _AskDecoder decoder;
  late DetectionSession session;
  var seq = 0;

  setUp(() async {
    nowMs = 1800000000000; // 任何固定的 epoch 都行；窗口只做减法
    bridge = FakeAudioBridge();
    engine = FakeInferenceEngine(scripted: (i) => _probs());
    await engine.load(assetPath: 'assets/models/model.tflite');
    decoder = _AskDecoder();
    session = DetectionSession(
      bridge: bridge,
      engine: engine,
      diet: _repo(),
      votingConfig: VotingConfig.fromFeatureConfig(),
      behaviorConfig: BehaviorConfig.fromFeatureConfig(),
      decoder: decoder,
      clock: () => nowMs,
    );
    seq = 0;
  });

  tearDown(() async {
    await session.dispose();
    bridge.dispose();
  });

  /// 投递一个 patch 并等异步监听器跑完。
  Future<void> patch() async {
    bridge.emitPatch(seq: seq, tStartMs: seq * 4096, mel: _mel());
    seq++;
    await Future<void>.delayed(Duration.zero);
  }

  test('FF-20d 取自 SSOT，正好是用户要求的三分钟', () {
    expect(cfg.FeatureConfig.votingConfirmationMuteSeconds, 180);
    expect(session.muteWindowMs, 180000);
  });

  test('点「否」之后，同一次检测的三分钟内不再出现该判断结果', () async {
    await session.start(sessionId: 'S-mute');

    await patch();
    expect(session.state.decision.stage, VoteStage.lowConfidence,
        reason: '前置：聚合器确实在问');
    expect(session.state.decision.shouldAskUser, isTrue);

    session.rejectSuggestion();
    final rejectedAt = nowMs;

    // 下一个 patch 就不得再问 —— 这正是用户报的现象。
    await patch();
    expect(session.state.decision.shouldAskUser, isFalse,
        reason: '点了否，界面上的两个按钮必须立刻消失并保持消失');
    expect(session.state.decision.classId, isNull,
        reason: '而且不得继续把用户刚否掉的类别当成结果显示出来');
    expect(session.state.decision.label, isNull);
    expect(session.state.decision.stage, VoteStage.observing,
        reason: '没有可主张的结果：observing + classId=null 是 SPEC-P-06 §2.3 判定表允许的行');

    // 窗口内反复来 patch，都不得重新提问。
    for (final step in <int>[1, 10, 30000, 120000, 179999]) {
      nowMs = rejectedAt + step;
      await patch();
      expect(session.state.decision.shouldAskUser, isFalse,
          reason: 'T+${step}ms 仍在三分钟窗口内');
    }
  });

  test('恰好三分钟时提问权恢复：不是永久静音', () async {
    await session.start(sessionId: 'S-boundary');
    await patch();
    session.rejectSuggestion();
    final rejectedAt = nowMs;

    nowMs = rejectedAt + 179999;
    await patch();
    expect(session.state.decision.shouldAskUser, isFalse, reason: '窗口内');

    nowMs = rejectedAt + 180000;
    await patch();
    expect(session.state.decision.shouldAskUser, isTrue,
        reason: '窗口到期后证据可以重新赢得提问权');
    expect(session.state.decision.stage, VoteStage.lowConfidence);
  });

  test('窗口是"同一次检测"的：新会话不继承静默', () async {
    await session.start(sessionId: 'S-first');
    await patch();
    session.rejectSuggestion();
    await patch();
    expect(session.state.decision.shouldAskUser, isFalse);

    await session.stop();
    // 时钟不动：窗口在时间上还没过期，但这是**另一次检测**。
    seq = 0;
    await session.start(sessionId: 'S-second');
    await patch();
    expect(session.state.decision.shouldAskUser, isTrue,
        reason: '「同一次检测中的三分钟」= 窗口属于会话，不属于全局');
  });

  test('只静默被答复的类别，别的类别照常提问', () async {
    await session.start(sessionId: 'S-scope');
    await patch();
    session.rejectSuggestion();

    decoder.classId = 1;
    nowMs += 1000;
    await patch();
    expect(session.state.decision.shouldAskUser, isTrue);
    expect(session.state.decision.classId, 1,
        reason: '静默是按 classId 记账的，不是"静音一切"');
  });

  test('点「否」之后，同一类别在窗口内不得被自动落库', () async {
    await session.start(sessionId: 'S-norecord');
    await patch();
    session.rejectSuggestion();

    // 证据变强：聚合器直接给 confirmed。用户刚说"不是这个"，不能一秒后自动记成这个。
    decoder.stage = VoteStage.confirmed;
    nowMs += 1000;
    await patch();
    expect(session.state.decision.stage, VoteStage.observing,
        reason: '被拒绝的类别在窗口内没有可主张的结果');
    expect(session.state.decision.classId, isNull,
        reason: '「否」不能在后台被自动撤销');
    expect(session.state.decision.shouldAskUser, isFalse);

    final outcome = await session.stop();
    expect(outcome.records, isEmpty, reason: '「否」不能在后台被自动撤销');
  });

  test('点「是」同样结束追问，并且只落一条记录', () async {
    await session.start(sessionId: 'S-yes');
    await patch();
    expect(session.state.decision.shouldAskUser, isTrue);

    session.answerConfirmation(accepted: true);
    // 同一 tick 内就不得再问：答复是同步生效的。
    expect(session.state.decision.shouldAskUser, isFalse);
    expect(session.state.decision.stage, VoteStage.confirmed,
        reason: 'SPEC-P-06 §2.3：选「是」→ lowConfidence → confirmed');

    await patch();
    expect(session.state.decision.shouldAskUser, isFalse);
    await patch();

    final outcome = await session.stop();
    expect(outcome.records.length, 1);
    expect(outcome.records.single.confirmedByUser, isTrue);
  });

  test('未作答的对照组：同一解码器、同一脚本，仍然在问', () async {
    // 负例对照：证明上面的静默来自"用户的答复"，而不是来自解码器或脚本本身。
    // 把 `_applyMute` 去掉，这个对照组仍然提问，而上面那些断言会一起变红。
    final controlBridge = FakeAudioBridge();
    final control = DetectionSession(
      bridge: controlBridge,
      engine: engine,
      diet: _repo(),
      votingConfig: VotingConfig.fromFeatureConfig(),
      behaviorConfig: BehaviorConfig.fromFeatureConfig(),
      decoder: _AskDecoder(),
      clock: () => nowMs,
    );
    await control.start(sessionId: 'S-control');
    controlBridge.emitPatch(seq: 0, tStartMs: 0, mel: _mel());
    await Future<void>.delayed(Duration.zero);

    expect(control.state.decision.shouldAskUser, isTrue,
        reason: '同样的输入，没点过任何按钮的会话仍在提问');

    await control.dispose();
    controlBridge.dispose();
  });
}

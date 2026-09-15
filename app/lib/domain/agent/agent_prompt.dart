// app/lib/domain/agent/agent_prompt.dart
//
// ADR-44 -- THE single construction site for everything that leaves the device
// (`API-07` section 5.2, `API-05` section 13.2).
//
// Why one file matters: `FF-26d` (the seven allowed field classes) and `FF-26e` (the forbidden
// list) are only auditable if there is exactly one place that assembles a request. Reviewing
// one file is a review; reviewing "everywhere we call send()" is a hope.
//
// The enforcement is mechanical, not editorial:
//   * [allowedFactKeys] is a closed set. A fact whose key is not in it is refused, so adding a
//     new field is a deliberate act that shows up in a diff.
//   * [assertEgressSafe] walks the value tree and refuses any numeric array of length
//     >= [maxNumericArrayLength]. A PCM patch is 65536 samples and an RMS envelope is 819; the
//     Mel tensor is 16384 floats. All of them are far above the threshold, while every
//     legitimate fact (a score, a count, a timestamp) is a scalar.
//
// The threshold is the load-bearing number. It is not a magic constant: it is chosen so that
// the SMALLEST audio-shaped object in this project (the 819-point envelope) cannot pass, with
// room to spare for an aggregate like a 7-element trend series.

import 'dart:typed_data';

import '../../core/errors.dart';
import '../../data/net/agent_transport.dart';

/// Refuses any numeric array at or above this length. See the file header for the derivation.
const int kMaxEgressNumericArrayLength = 1024;

/// `FF-26d`: the ONLY fact keys that may be serialised into a message.
///
/// Nothing here identifies a person or a device, and nothing here is audio.
const Set<String> allowedFactKeys = <String>{
  // local record facts
  'classLabel',
  'classId',
  'eatenAtMs',
  'confidence',
  'chewCount',
  'chewMeanIntervalSeconds',
  'eatingDurationSeconds',
  'speedBand',
  'recordCount',
  'mealCount',
  'snackCount',
  // score facts
  'regularityScore',
  'structureScore',
  'snackScore',
  'speedScore',
  'totalScore',
  'grade',
  // conversation metadata (not user content, not device identity)
  'range',
};

/// Walks a value and throws when it could not legitimately appear in a request body.
///
/// Throws `ACD-AGENT-009` -- the same code the tool-call path uses, because this is the same
/// class of event: "the thing we were about to do is not a thing we can do."
void assertEgressSafe(Object? value, {String path = r'$'}) {
  if (value == null) return;

  // Typed buffers are audio-shaped by construction: nothing in the allowed fact set is one.
  if (value is Uint8List || value is Float32List || value is Int32List || value is Int16List) {
    throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
      'reason': 'typed buffer may not leave the device (FF-26e)',
      'path': path,
    });
  }
  if (value is num || value is bool || value is String) return;
  if (value is List) {
    final allNumeric = value.isNotEmpty && value.every((e) => e is num);
    if (allNumeric && value.length >= kMaxEgressNumericArrayLength) {
      throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
        'reason': 'numeric array is long enough to be audio (FF-26e)',
        'path': path,
        'length': value.length,
      });
    }
    for (var i = 0; i < value.length; i++) {
      assertEgressSafe(value[i], path: '$path[$i]');
    }
    return;
  }
  if (value is Map) {
    for (final e in value.entries) {
      assertEgressSafe(e.value, path: '$path.${e.key}');
    }
    return;
  }
  throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
    'reason': 'value type is not serialisable into an agent message',
    'path': path,
    'type': value.runtimeType.toString(),
  });
}

/// Assembles the message list. The only place `messages` is ever built.
class AgentPromptBuilder {
  const AgentPromptBuilder();

  /// The invariant frame of every request: WHO the model is, WHAT its job is, and the boundaries
  /// it works inside (`API-05` section 13.2.5).
  ///
  /// ⚠️ **REWRITTEN (user requirement, ADR-45).** The first version opened with a list of refusals
  /// -- 「不做疾病诊断、不给治疗建议、不替代专业医疗意见」 -- as rule 1. That is a *compliance*
  /// sentence being used as a *job description*, and it produced what a job description produces:
  /// a model that hedges and declines instead of assessing. The user's feedback was blunt and
  /// correct: the cloud AI is supposed to **do dietary health assessment**, and the app was
  /// telling it not to.
  ///
  /// The boundaries are all still here -- they are the honest limits of a diet app -- but they now
  /// read as *how to assess responsibly* rather than *don't assess*:
  ///
  ///   * the JOB section states that assessing diet structure, regularity, snacking and eating
  ///     speed IS the task, and that naming what is too much or too little is part of it;
  ///   * the BOUNDARY section confines the assessment to diet and lifestyle (no disease
  ///     diagnosis, refer symptoms to a doctor) -- a limit on SCOPE, not a refusal to work;
  ///   * the anti-fabrication and estimate-labelling rules are unchanged, because they protect the
  ///     user rather than the model.
  ///
  /// It is deliberately NOT templated from user data: a frame assembled from data can silently
  /// lose a rule when a template is edited, and the loss is invisible to every test that only
  /// exercises the happy path.
  static const String systemText = '你是 AcouDiet（声膳）的饮食健康助手。'
      '你的工作是对用户的饮食记录做**饮食层面的健康评估**，并给出可执行的改进建议。\n'
      '\n'
      '【你要做的】\n'
      'a. 评估饮食结构、规律性、零食频率、进食速度是否合理，并给出明确结论'
      '（良好 / 需注意 / 需改善）。\n'
      'b. 指出哪一类食物偏多、哪一类偏少，并给出具体可执行的替换或调整建议。\n'
      'c. 数据不足时，直接说清楚还需要记录什么，而不是含糊其辞。\n'
      '\n'
      '【边界（是评估范围，不是拒绝工作的理由）】\n'
      '1. 你评估的是**饮食与生活方式**；不做疾病诊断、不判断病情、不替代专业医疗意见。'
      '用户描述具体症状或疾病时，建议其就医。\n'
      '2. 数字只能来自【本地数据】或用户原话，不得编造；工具没返回的就不说。\n'
      '3. 能量与营养来自知识库 + 标准份量的**估算**，提到时必须写「估算」。\n'
      '4. 不承诺任何疗效。\n'
      '5. 你不能替用户下单、支付或填写收货地址。用户想点外卖时，调用 '
      'propose_takeout_search；它只会生成一张需要用户自己点击的卡片。\n'
      '6. 只使用已注册的工具，不要臆造工具名。\n'
      '7. 用简体中文；先给评估结论，再给 1–3 条建议；不超过 160 字。';

  /// The section headers of the per-request brief.
  ///
  /// Exposed as constants so the tests assert the STRUCTURE rather than one particular sentence
  /// -- a text assertion that breaks every time the wording is tuned teaches people to delete
  /// assertions, which is how a suite becomes decorative.
  static const String taskHeader = '【本轮任务】';
  static const String dataHeader = '【本地数据（唯一可引用的事实）】';
  static const String formatHeader = '【回答格式】';
  static const String noDataMarker = '（本轮没有本地数据；请只依据用户的话作答，需要数据时先调用工具）';

  /// Builds the message list: system + trimmed history + one wrapped user turn.
  ///
  /// **Every request is wrapped** (user requirement, `ADR-45`): the user's sentence is never sent
  /// bare. It travels inside a structured brief that names the task, fences the fact source, and
  /// restates the answer shape. Three reasons, in order of importance:
  ///
  ///   1. it is what makes the model treat the turn as an assessment request instead of
  ///      open-ended chat -- the whole point of the assistant, and the thing the previous
  ///      refusal-first prompt talked it out of doing;
  ///   2. it marks the local data as DATA. The user's own sentence and the App's aggregate now
  ///      arrive in visibly different sections, so text inside the user's message cannot
  ///      masquerade as App-provided fact (`SPEC-C-06`'s injection concern);
  ///   3. it keeps the answer shape stable enough to assert in a test.
  ///
  /// Trimming drops the OLDEST non-system messages first (`FF-26g`). The system message is
  /// never dropped: without it the boundaries disappear, which would be a silent behavioural
  /// change rather than a smaller context.
  List<AgentMessage> build({
    required List<AgentMessage> history,
    required String userText,
    Map<String, Object?> contextFacts = const <String, Object?>{},
    required int maxHistoryMessages,
  }) {
    for (final key in contextFacts.keys) {
      if (!allowedFactKeys.contains(key)) {
        throw Errors.agent(Codes.agentToolCallUnparsable, detail: <String, Object?>{
          'reason': 'fact key is not in the FF-26d whitelist',
          'key': key,
        });
      }
    }
    assertEgressSafe(contextFacts);

    final user = renderBrief(userText: userText, contextFacts: contextFacts);

    final tail = <AgentMessage>[...history];
    // TWO slots are reserved, not one: the system prompt is always present in the OUTPUT list,
    // and the new user turn takes the other. Reserving only one produced a list of
    // `maxHistoryMessages + 1` messages -- the cap was off by exactly the system prompt, which
    // no individual assertion would have noticed.
    final budget = (maxHistoryMessages - 2).clamp(0, maxHistoryMessages);
    while (tail.length > budget) {
      // Remove the oldest message that is not the system prompt.
      final idx = tail.indexWhere((m) => m.role != 'system');
      if (idx < 0) break;
      tail.removeAt(idx);
    }
    return <AgentMessage>[
      const AgentMessage.system(systemText),
      ...tail,
      AgentMessage.user(user),
    ];
  }

  /// The per-request wrapper. Pure and public so a test can assert its structure directly,
  /// without driving a whole turn.
  String renderBrief({
    required String userText,
    Map<String, Object?> contextFacts = const <String, Object?>{},
  }) {
    final buf = StringBuffer()
      ..writeln(taskHeader)
      ..writeln(userText.trim())
      ..writeln()
      ..writeln(dataHeader);
    if (contextFacts.isEmpty) {
      buf.writeln(noDataMarker);
    } else {
      buf.writeln(_renderFacts(contextFacts));
    }
    buf
      ..writeln()
      ..writeln(formatHeader)
      ..writeln('1) 评估：一句结论（良好 / 需注意 / 需改善）。')
      ..writeln('2) 建议：1–3 条，每条都能照着做。')
      ..writeln('3) 数据不足时，只说还需要记录什么。');
    return buf.toString();
  }

  /// Renders facts as `key=value` pairs rather than raw JSON.
  ///
  /// Deliberate: the model handles `零食次数=5` at least as well as `{"snackCount":5}`, the flat
  /// form makes a leaked field visible to a human reading a capture (the point of `SPEC-C-06`'s
  /// evidence chain), and `；`-separated pairs cannot be mistaken for the user's own sentence --
  /// which is what keeps the data fence in [renderBrief] meaningful.
  String _renderFacts(Map<String, Object?> facts) {
    final keys = facts.keys.toList()..sort();
    return keys.map((k) => '$k=${facts[k]}').join('；');
  }
}

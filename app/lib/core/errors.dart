/// AcouDiet unified domain error (API-02 section 2).
///
/// Codes come from the single registry in `API-00` section 3.5. `message` is a short
/// user-facing Chinese sentence (no stack traces, no file paths, no raw English error
/// text); `detail` carries machine-readable diagnostics only.
///
/// `retryable` must stay consistent with the retry table in `API-05` section 8 -- only a
/// `true` value makes the UI offer a "retry" affordance.
library;

class AcouDietError implements Exception {
  AcouDietError(this.code, this.message, {this.detail, this.retryable = false});

  final String code;
  final String message;
  final Map<String, Object?>? detail;
  final bool retryable;

  /// Wraps a `PlatformException`-shaped failure coming from the native bridge
  /// (`API-01`). The conversion point belongs to the bridge adapter (PLAN-P-01).
  factory AcouDietError.fromPlatform({
    required String? code,
    required String? message,
    Object? detail,
  }) {
    final c = (code == null || code.isEmpty) ? Codes.unknown : code;
    return AcouDietError(
      c,
      (message == null || message.isEmpty) ? _defaultMessage(c) : message,
      detail: detail is Map ? detail.cast<String, Object?>() : null,
      retryable: isRetryable(c),
    );
  }

  bool get isConfigMismatch => code == Codes.cfgMismatch;

  @override
  String toString() => 'AcouDietError($code): $message'
      '${detail == null ? '' : ' $detail'}';
}

/// Every code this app may raise, with its frozen `retryable` value.
abstract final class Codes {
  // permission
  static const permDenied = 'ACD-PERM-001';
  static const permPermanentlyDenied = 'ACD-PERM-002';
  // session lifecycle
  static const sessionNotFound = 'ACD-SESS-001';
  static const illegalTransition = 'ACD-SESS-002';
  // audio device
  static const audioRecordInitFailed = 'ACD-AUD-001';
  static const audioDeviceBusy = 'ACD-AUD-002';
  // feature computation
  static const melFrameCount = 'ACD-MEL-001';
  static const melSampleCount = 'ACD-MEL-002';
  // inference
  static const inferLoad = 'ACD-INF-001';
  static const inferShape = 'ACD-INF-002';
  static const inferDelegate = 'ACD-INF-003';
  static const inferCall = 'ACD-INF-004';
  // behaviour
  static const behaviorInput = 'ACD-BEH-001';
  // knowledge base
  static const kbLookup = 'ACD-KB-001';
  // scoring / report
  static const scoreInput = 'ACD-SCORE-001';
  // database
  static const dbMigration = 'ACD-DB-001';
  static const dbUniqueConstraint = 'ACD-DB-002';
  static const dbTransaction = 'ACD-DB-003';
  static const dbInvalidArgument = 'ACD-DB-004';
  // configuration
  static const cfgMismatch = 'ACD-CFG-001';
  // io
  static const ioCleanup = 'ACD-IO-001';
  static const ioAsset = 'ACD-IO-002';
  // ADR-34: `ACD-LLM-001` / `ACD-LLM-002` were removed with the on-device language model.
  // They were never a user-visible product error -- both mapped to "已使用标准建议", i.e. a
  // silent fallback -- so nothing in the product loses a failure signal here.
  // demo
  static const demoAsset = 'ACD-DEMO-001';
  static const demoDataset = 'ACD-DEMO-002';
  static const demoModeSwitch = 'ACD-DEMO-003';
  // ADR-44: the cloud agent (FF-26). These are the ONLY codes that may be raised by
  // `app/lib/data/net/**`. Every one of them is contained to the agent path: none of them
  // may reach the detection / records / report / demo call stacks (FF-26f).
  static const agentOffline = 'ACD-AGENT-001';
  static const agentUnconsented = 'ACD-AGENT-002';
  static const agentNoKey = 'ACD-AGENT-003';
  static const agentUnauthorized = 'ACD-AGENT-004';
  static const agentRateLimited = 'ACD-AGENT-005';
  static const agentServerError = 'ACD-AGENT-006';
  static const agentTimeout = 'ACD-AGENT-007';
  static const agentStreamBroken = 'ACD-AGENT-008';
  static const agentToolCallUnparsable = 'ACD-AGENT-009';
  static const agentToolRoundsExceeded = 'ACD-AGENT-010';
  // unknown
  static const unknown = 'ACD-UNK-000';
}

/// `API-05` section 8 retry semantics, mirrored per code.
///
/// The three agent codes below are `true` **only** because `DeepSeekClient` gates them
/// further: it retries at most once AND never after the first streamed delta
/// (`API-05` section 13.1.8). A `true` here is the outer bound, not the whole rule.
bool isRetryable(String code) => switch (code) {
      Codes.audioRecordInitFailed => true,
      Codes.inferLoad => true,
      Codes.dbTransaction => true,
      Codes.agentRateLimited => true,
      Codes.agentServerError => true,
      Codes.agentTimeout => true,
      _ => false,
    };

String _defaultMessage(String code) => switch (code) {
      Codes.permDenied || Codes.permPermanentlyDenied => '需要录音权限才能开始检测',
      Codes.sessionNotFound => '检测会话不存在或已结束',
      Codes.illegalTransition => '当前状态不允许该操作',
      Codes.audioRecordInitFailed => '麦克风初始化失败，请重试',
      Codes.audioDeviceBusy => '麦克风被其他应用占用',
      Codes.melFrameCount || Codes.melSampleCount => '音频特征计算失败，请重新开始检测',
      Codes.inferLoad => '模型加载失败，请重试',
      Codes.inferShape => '模型输入不匹配',
      Codes.inferCall => '推理调用失败',
      Codes.behaviorInput => '行为数据不完整',
      Codes.kbLookup => '食物知识库查询失败',
      Codes.scoreInput => '数据不足，无法评分',
      Codes.dbMigration => '数据库升级失败',
      Codes.dbUniqueConstraint => '记录标识重复',
      Codes.dbTransaction => '数据保存失败，请重试',
      Codes.dbInvalidArgument => '请求参数非法',
      Codes.cfgMismatch => '配置不一致，请更新应用',
      Codes.ioCleanup => '临时文件清理失败',
      Codes.ioAsset => '资源文件缺失或损坏',
      Codes.demoAsset => '示例音频不可用',
      Codes.demoDataset => '演示数据集不可用',
      Codes.demoModeSwitch => '当前状态不允许切换演示模式',
      Codes.agentOffline => '当前离线，核心功能可正常使用',
      Codes.agentUnconsented => '云端智能尚未开启',
      Codes.agentNoKey => '请先在设置里填入你自己的 API Key',
      Codes.agentUnauthorized => 'Key 无效或额度不足',
      Codes.agentRateLimited => '请求过于频繁，请稍后再试',
      Codes.agentServerError => '服务暂时不可用',
      Codes.agentTimeout => '请求超时，请重试',
      Codes.agentStreamBroken => '回复不完整',
      Codes.agentToolCallUnparsable => '工具调用无法解析',
      Codes.agentToolRoundsExceeded => '已达到本次请求的工具调用上限',
      _ => '发生未知错误',
    };

/// Convenience constructors used across the layers.
abstract final class Errors {
  static AcouDietError notLoaded() =>
      AcouDietError(Codes.inferCall, _defaultMessage(Codes.inferCall));

  static AcouDietError shapeMismatch({required int expectedFrames, required int actualFrames}) =>
      AcouDietError(
        Codes.inferShape,
        _defaultMessage(Codes.inferShape),
        detail: {'expectedFrames': expectedFrames, 'actualFrames': actualFrames},
      );

  static AcouDietError behavior(String reason, Map<String, Object?>? detail) =>
      AcouDietError(Codes.behaviorInput, _defaultMessage(Codes.behaviorInput),
          detail: {'reason': reason, ...?detail});

  static AcouDietError kb(String reason) => AcouDietError(
        Codes.kbLookup,
        _defaultMessage(Codes.kbLookup),
        detail: {'reason': reason},
      );

  static AcouDietError score(String dimension, String reason) => AcouDietError(
        Codes.scoreInput,
        _defaultMessage(Codes.scoreInput),
        detail: {'dimension': dimension, 'reason': reason},
      );

  static AcouDietError dbInvalid(String reason) => AcouDietError(
        Codes.dbInvalidArgument,
        _defaultMessage(Codes.dbInvalidArgument),
        detail: {'reason': reason},
      );

  static AcouDietError demoMode(String reason) => AcouDietError(
        Codes.demoModeSwitch,
        _defaultMessage(Codes.demoModeSwitch),
        detail: {'reason': reason},
      );

  static AcouDietError asset(String path, String reason) => AcouDietError(
        Codes.ioAsset,
        _defaultMessage(Codes.ioAsset),
        detail: {'path': path, 'reason': reason},
      );

  /// ADR-44: the one constructor the cloud agent path should use.
  ///
  /// `detail` must never carry the API key or any part of a request body that could contain
  /// it (`FF-26b`). It carries a machine-readable reason and, at most, non-identifying
  /// numbers such as the HTTP status or the elapsed milliseconds.
  static AcouDietError agent(String code, {Map<String, Object?>? detail}) =>
      AcouDietError(code, _defaultMessage(code), detail: detail, retryable: isRetryable(code));

  /// The message for a code, for callers that already have an `AcouDietError`.
  static String messageFor(String code) => _defaultMessage(code);
}

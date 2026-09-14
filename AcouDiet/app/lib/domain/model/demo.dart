/// Demo modes (M-01/M-02/M-03) and the on-site self-check panel (M-04).
library;

enum DemoMode {
  /// Mode A: live microphone, the normal path (M-01).
  realtime,

  /// Mode B: a bundled sample wav injected into the ring buffer, no speaker/room involved
  /// (M-02). Works even when the microphone is broken, thanks to `skipAudioRecord`.
  sampleAudio,

  /// Mode C: preloaded demo records only, no audio path at all (M-03).
  reportOnly,
}

/// One line of the self-check (API-04 section 7.1). The order of the keys is frozen.
///
/// **ADR-27 变更 / ADR-34 回退**：ADR-27 曾把项数由 14 扩为 15，新增第 15 项
/// [SelfCheckKeys.adviceModel]，好让端侧建议模型（A-02 润色层）在界面上有落点。
/// **ADR-34 按用户要求删除了整个端侧语言模型层**（含那一项），因此这里**回到 ADR-14 的
/// 14 项闭集** —— 冻结顺序与 14 项集合都与 ADR-27 之前逐字相同。
class SelfCheckItem {
  const SelfCheckItem({
    required this.key,
    required this.label,
    required this.passed,
    required this.observed,
    this.hint,
  });

  final String key;
  final String label;
  final bool passed;

  /// Machine-readable observation (e.g. `'xnnpack'`, `'granted'`); never empty.
  final String observed;

  /// Actionable hint; required when [passed] is false.
  final String? hint;
}

/// Aggregate self-check result.
class SelfCheckReport {
  const SelfCheckReport(this.items);

  final List<SelfCheckItem> items;

  bool get allPassed => items.every((i) => i.passed);

  SelfCheckItem? byKey(String key) {
    for (final i in items) {
      if (i.key == key) return i;
    }
    return null;
  }
}

/// The self-check keys, in render order (API-04 section 7.1).
///
/// **ADR-34**：回到 `ADR-14` 的 **14 项闭集**。`ADR-27` 增加的第 15 项 `adviceModel`
/// 随端侧语言模型一起被删除（用户要求"把 qwen 端侧相关代码删干净"）。
/// ⚠️ 若将来再加项，先读 `ADR-14`：这个集合是**冻结**的，改它要留痕。
abstract final class SelfCheckKeys {
  static const permission = 'permission';
  static const mic = 'mic';
  static const model = 'model';
  static const delegate = 'delegate';
  static const featureConfig = 'featureConfig';
  static const db = 'db';
  static const knowledge = 'knowledge';
  static const tempAudio = 'tempAudio';
  static const sampleAudio = 'sampleAudio';
  static const session = 'session';
  static const modelInfo = 'modelInfo';
  static const envelope = 'envelope';
  static const dropRate = 'dropRate';
  static const demoData = 'demoData';

  static const List<String> all = [
    permission,
    mic,
    model,
    delegate,
    featureConfig,
    db,
    knowledge,
    tempAudio,
    sampleAudio,
    session,
    modelInfo,
    envelope,
    dropRate,
    demoData,
  ];

  static const Map<String, String> labels = {
    permission: '录音权限',
    mic: '麦克风可用',
    model: '模型已加载',
    delegate: '推理后端',
    featureConfig: '特征配置一致',
    db: '数据库可用',
    knowledge: '知识库已加载',
    tempAudio: '临时音频残留',
    sampleAudio: '示例音频可用',
    session: '当前会话状态',
    modelInfo: '模型版本与 n_frames',
    envelope: '行为包络通道',
    dropRate: '推理丢帧比例',
    demoData: '预置演示数据就绪',
  };
}

/// Native capability handshake payload (API-01 section 2.1).
class NativeCapabilities {
  const NativeCapabilities(this.raw);

  final Map<String, Object?> raw;

  Object? operator [](String key) => raw[key];

  int intOf(String key) => (raw[key] as num?)?.toInt() ?? -1;

  double doubleOf(String key) => (raw[key] as num?)?.toDouble() ?? double.nan;

  String stringOf(String key) => raw[key] as String? ?? '';

  bool boolOf(String key) => raw[key] as bool? ?? false;

  /// The fifteen fields compared one by one at start-up (`API-00` section 3.6).
  ///
  /// ADR-21 grew this from twelve. `rawMelFrames` and `nFrames` are both present on purpose:
  /// the STFT frame count (129) and the tensor frame count (128) became two different numbers,
  /// and the old list carried only one of them.
  static const List<String> handshakeFields = [
    'melVersion',
    'sampleRate',
    'nFft',
    'hopLength',
    'nMels',
    'rawMelFrames',
    'nFrames',
    'fmin',
    'fmax',
    'preemphasis',
    'preemphasisBoundary',
    'powerToDbRef',
    'topDb',
    'normalization',
    'patchSamples',
  ];
}

/// Native capabilities plus the session/diagnostic payloads (API-01 sections 2.3 / 2.8).
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot(this.raw);

  final Map<String, Object?> raw;

  Object? operator [](String key) => raw[key];

  bool boolOf(String key) => raw[key] as bool? ?? false;

  int intOf(String key) => (raw[key] as num?)?.toInt() ?? 0;

  String stringOf(String key) => raw[key] as String? ?? '';

  bool get micInUseKnown => boolOf('micInUseKnown');

  int get patchesEmitted => intOf('patchesEmitted');

  int get droppedPatches => intOf('droppedPatches');

  double get dropRate {
    final emitted = patchesEmitted;
    if (emitted <= 0) return 0;
    return droppedPatches / emitted;
  }
}

/// Native session summary (API-01 section 2.5).
class SessionSummary {
  const SessionSummary(this.raw);

  final Map<String, Object?> raw;

  Object? operator [](String key) => raw[key];

  int intOf(String key) => (raw[key] as num?)?.toInt() ?? 0;

  String stringOf(String key) => raw[key] as String? ?? '';

  int get startedAtMs => intOf('startedAtMs');
  int get stoppedAtMs => intOf('stoppedAtMs');
  int get patchesEmitted => intOf('patchesEmitted');
  int get patchesVoiced => intOf('patchesVoiced');
  int get droppedPatches => intOf('droppedPatches');
  int? get firstVoicedAtMs => (raw['firstVoicedAtMs'] as num?)?.toInt();
  int? get lastVoicedAtMs => (raw['lastVoicedAtMs'] as num?)?.toInt();
  String get endReason => stringOf('endReason');
}

/// One `patch` event from the native EventChannel (API-01 section 3.2).
class PatchEvent {
  const PatchEvent(this.raw);

  final Map<String, Object?> raw;

  Object? operator [](String key) => raw[key];

  int get seq => (raw['seq'] as num?)?.toInt() ?? -1;
  int get tStartMs => (raw['tStartMs'] as num?)?.toInt() ?? 0;
  int get tEndMs => (raw['tEndMs'] as num?)?.toInt() ?? 0;
  int get nMels => (raw['nMels'] as num?)?.toInt() ?? 0;
  int get nFrames => (raw['nFrames'] as num?)?.toInt() ?? 0;
  bool get voiced => raw['voiced'] as bool? ?? true;
  String get source => raw['source'] as String? ?? 'mic';
  bool get isInjected => source == 'inject';

  /// Row-major Mel tensor `mel[m * nFrames + t]`.
  Object? get mel => raw['mel'];

  /// Short-time RMS envelope, present only when `includeEnvelope` was true.
  Object? get rmsEnvelope => raw['rmsEnvelope'];

  int? get envelopeHopMs => (raw['envelopeHopMs'] as num?)?.toInt();

  double get rms => (raw['rms'] as num?)?.toDouble() ?? 0;
}

/// One `level` event (10 Hz, waveform animation only).
class LevelEvent {
  const LevelEvent(this.raw);

  final Map<String, Object?> raw;

  double get rms => (raw['rms'] as num?)?.toDouble() ?? 0;
  double get peak => (raw['peak'] as num?)?.toDouble() ?? 0;
  bool get voiced => raw['voiced'] as bool? ?? false;
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../core/time.dart';
import '../../data/native/audio_bridge.dart';
import '../../data/wav_decoder.dart';
import '../model/demo.dart';
import '../model/diet_record.dart';
import '../repository/repositories.dart';
import 'detection_session.dart';
import 'food_knowledge_base.dart';
import 'handshake.dart';
import 'inference_engine.dart';

/// Reads bundled assets. Abstracted so the offline suite can supply its own bytes.
abstract class AssetReader {
  Future<Uint8List> readBytes(String path);

  Future<String> readString(String path);
}

/// Loads and clears the preloaded demo dataset (`API-04` section 6, `SPEC-A-04`).
class DemoDataController {
  DemoDataController({
    required this.diet,
    required this.assets,
    this.datasetPath = 'assets/demo_dataset.json',
  });

  final DietRepo diet;
  final AssetReader assets;
  final String datasetPath;

  bool _demoActive = false;

  /// Synchronous getter: reads only the cached flag, never issues a query (the report page
  /// calls it during build).
  bool get isDemoActive => _demoActive;

  /// Reads, validates and writes the dataset as `source == 'demo'`.
  ///
  /// Re-running is idempotent: the previous demo rows are removed first, so `recordId`s are
  /// never duplicated (which would raise `ACD-DB-002`).
  Future<int> loadDemoDataset() async {
    final parsed = await _parseAndValidate();
    await clearDemoDataset();

    for (final entry in parsed) {
      await diet.insertSession(record: entry.$1, metrics: entry.$2);
    }
    _demoActive = parsed.isNotEmpty;
    return parsed.length;
  }

  /// Removes only `source == 'demo'` rows; real accumulated data is untouched.
  ///
  /// Implemented exclusively through the frozen `API-03` methods (scan + delete by id), as
  /// the contract requires -- no new repository method was added for this.
  Future<int> clearDemoDataset() async {
    final all = await diet.byRange(DateRange(0, 1 << 62));
    var removed = 0;
    for (final r in all) {
      if (!r.isDemo) continue;
      removed += await diet.deleteById(r.recordId);
    }
    _demoActive = false;
    return removed;
  }

  /// Refreshes the cached flag from the database (call on page entry).
  Future<bool> refreshActive() async {
    final all = await diet.byRange(DateRange(0, 1 << 62));
    _demoActive = all.any((r) => r.isDemo);
    return _demoActive;
  }

  /// Validates structure, field ranges and the 1:1 metrics block, then rebases the fixture
  /// onto the current local week (so the demo always shows a populated report).
  Future<List<(DietRecord, BehaviorMetrics?)>> _parseAndValidate() async {
    final text = await assets.readString(datasetPath);
    final decoded = _jsonDecode(text);
    final rawRecords = switch (decoded) {
      List<Object?> l => l,
      Map<Object?, Object?> m when m['records'] is List => m['records']! as List<Object?>,
      _ => throw AcouDietError(Codes.demoDataset,
          'demo dataset must be a list or an object with a "records" array'),
    };

    final out = <(DietRecord, BehaviorMetrics?)>[];
    for (final raw in rawRecords) {
      if (raw is! Map) {
        throw AcouDietError(Codes.demoDataset, 'each demo record must be an object');
      }
      final m = raw.cast<String, Object?>();
      final record = _recordFrom(m);
      final problems = record.validate();
      if (problems.isNotEmpty) {
        throw AcouDietError(Codes.demoDataset, 'record ${record.recordId}: '
            '${problems.join("; ")}');
      }
      final metrics = _metricsFrom(m['metrics']);
      out.add((record, metrics));
    }
    return out;
  }

  DietRecord _recordFrom(Map<String, Object?> m) {
    final metrics = m['metrics'];
    if (metrics is! Map) {
      // I-1: the metrics key is mandatory -- a missing row silently changes the report's
      // denominators, so it is a validation failure rather than a default.
      throw AcouDietError(Codes.demoDataset, 'record ${m['recordId']} has no metrics block');
    }
    return DietRecord(
      recordId: '${m['recordId']}',
      eatenAtMs: _int(m['eatenAtMs']),
      endedAtMs: _int(m['endedAtMs']),
      classLabel: '${m['classLabel']}',
      classId: _int(m['classId']),
      attribute: '${m['attribute']}',
      confidence: _double(m['confidence']),
      durationSeconds: _int(m['durationSeconds']),
      source: '${m['source']}',
      correctedByUser: m['correctedByUser'] == true,
      confirmedByUser: m['confirmedByUser'] == true,
    );
  }

  BehaviorMetrics? _metricsFrom(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, Object?>();
    final hasAny = m.values.any((v) => v != null);
    if (!hasAny) return BehaviorMetrics.placeholder;
    return BehaviorMetrics(
      chewCount: m['chewCount'] == null ? null : _int(m['chewCount']),
      avgChewIntervalSeconds:
          m['avgChewIntervalSeconds'] == null ? null : _double(m['avgChewIntervalSeconds']),
      durationSeconds: m['durationSeconds'] == null ? null : _int(m['durationSeconds']),
      speedGrade: m['speedGrade'] as String?,
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw AcouDietError(Codes.demoDataset, 'expected an integer, got $v');
  }

  static double _double(Object? v) {
    if (v is num) return v.toDouble();
    throw AcouDietError(Codes.demoDataset, 'expected a number, got $v');
  }
}

/// Parses the dataset JSON. `dart:convert` is a core library, so it is safe to use here --
/// the "no packages" constraint only rules out third-party dependencies.
Object? _jsonDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    throw AcouDietError(Codes.demoDataset, 'demo dataset is not valid JSON: ${e.message}');
  }
}

/// `DemoController`: the three demo modes and the 14-item on-site self-check
/// (`API-04` section 7, `SPEC-M-01`…`SPEC-M-04`).
///
/// The self-check **never throws** on a failed item: the result carries the observation and
/// an actionable hint, because the panel's whole purpose is to tell "microphone problem"
/// from "model problem" while the judges are watching.
class DemoController {
  DemoController({
    required this.bridge,
    required this.engine,
    required this.diet,
    required this.knowledge,
    required this.maintenance,
    required this.assets,
    required this.demoData,
    required this.handshake,
    this.registry,
    this.sampleAssetPath = 'assets/demo/sample_chews.wav',
  });

  final AudioBridge bridge;
  final InferenceEngine engine;
  final DietRepo diet;
  final FoodKnowledgeBase knowledge;
  final MaintenanceRepo maintenance;
  final AssetReader assets;
  final DemoDataController demoData;

  /// Cached start-up handshake (`API-00` section 3.6). A null value means the handshake has
  /// not been performed, which self-check item 5 reports as a failure.
  final HandshakeResult? handshake;

  /// Optional registry so the panel can also observe a live detection session.
  final DetectionSessionRegistry? registry;

  final String sampleAssetPath;

  DemoMode _mode = DemoMode.realtime;

  DemoMode get currentMode => _mode;

  Future<void> switchTo(DemoMode mode) async {
    if (mode == _mode) return; // same mode is an idempotent no-op
    final active = registry?.current;
    if (active != null && active.isRunning) {
      throw Errors.demoMode('a session is running; stop it before switching');
    }
    if (mode == DemoMode.reportOnly) {
      final activeDemo = await demoData.refreshActive();
      if (!activeDemo) {
        throw Errors.demoMode('the demo dataset is not loaded');
      }
    }
    _mode = mode;
  }

  Future<void> loadReportDemo() async {
    await demoData.loadDemoDataset();
    _mode = DemoMode.reportOnly;
  }

  /// Starts a Mode A live session.
  Future<DetectionSession> startRealtimeSession({required DetectionSession Function() build}) async {
    final session = build();
    await session.start(sessionId: _newSessionId());
    registry?.register(session);
    return session;
  }

  /// Starts a Mode B injection session: the sample is decoded and pushed straight into the
  /// ring buffer at real-time pace (`API-01` section 2.6).
  Future<void> startSamplePlayback({
    required DetectionSession Function() build,
    String? assetPath,
  }) async {
    final path = assetPath ?? sampleAssetPath;
    final bytes = await assets.readBytes(path);
    final wav = WavDecoder.decode(bytes);

    final session = build();
    session.source = 'demo';
    await session.start(
      sessionId: _newSessionId(),
      skipAudioRecord: true, // survives a broken or busy microphone
    );
    registry?.register(session);

    // Feed in 1-second chunks so the UI animation and the 4-5 s confirmation behave like a
    // live session; `isLast` lets the native side end the session when it drains.
    const chunkBytes = cfg.FeatureConfig.sampleRate * 2;
    for (var offset = 0; offset < wav.pcm16.length; offset += chunkBytes) {
      final end = (offset + chunkBytes) <= wav.pcm16.length
          ? offset + chunkBytes
          : wav.pcm16.length;
      final chunk = Uint8List.sublistView(wav.pcm16, offset, end);
      await bridge.injectPcm(
        sessionId: _sessionIdOf(session),
        pcm16: chunk,
        isLast: end >= wav.pcm16.length,
        feedRealtime: false,
      );
    }
  }

  static String _sessionIdOf(DetectionSession session) => session.sessionId ?? '';

  String _newSessionId() {
    // API-00 section 3.4: S-<epochMs>-<4 hex>, generated by Dart so logs line up.
    final ms = TimeUtil.nowMs();
    final hex = (ms % 0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'S-$ms-$hex';
  }

  /// Runs the 14 self-check items of `API-04` section 7.1, in the frozen order.
  Future<SelfCheckReport> runSelfCheck() async {
    final items = <SelfCheckItem>[];

    DiagnosticsSnapshot diagnostics;
    try {
      diagnostics = await bridge.getDiagnostics();
    } on AcouDietError catch (e) {
      diagnostics = DiagnosticsSnapshot({'lastError': e.code});
    }

    // 1. recording permission
    final permission = diagnostics.stringOf('recordAudioPermission');
    items.add(SelfCheckItem(
      key: SelfCheckKeys.permission,
      label: SelfCheckKeys.labels[SelfCheckKeys.permission]!,
      passed: permission == 'granted',
      observed: permission.isEmpty ? 'unknown' : permission,
      hint: permission == 'permanentlyDenied' ? '去设置中开启录音权限' : '重试授权',
    ));

    // 2. microphone availability -- "not in use" must be distinguishable from "not enabled"
    final micInUseKnown = diagnostics.micInUseKnown;
    final micAvailable = diagnostics.boolOf('micAvailable');
    final micInUse = diagnostics.raw['micInUse'] == true;
    final micPassed = !micInUseKnown || (micAvailable && !micInUse);
    items.add(SelfCheckItem(
      key: SelfCheckKeys.mic,
      label: SelfCheckKeys.labels[SelfCheckKeys.mic]!,
      passed: micPassed,
      observed: !micInUseKnown
          ? '未启用麦克风'
          : (micAvailable && !micInUse ? '可用' : '不可用/被占用'),
      hint: micPassed ? null : '关闭其他录音应用',
    ));

    // 3. model loaded
    // The runtime version rides along in this item's `observed` text rather than becoming a
    // fifteenth item: ADR-14 freezes the self-check list at 14, and a converter/runtime version
    // gap is exactly the thing that otherwise fails with no visible cause on a device.
    final runtime = engine.runtimeVersion;
    final runtimeNote = runtime == null ? '' : ' (runtime $runtime)';
    items.add(SelfCheckItem(
      key: SelfCheckKeys.model,
      label: SelfCheckKeys.labels[SelfCheckKeys.model]!,
      passed: engine.isLoaded,
      observed: engine.isLoaded ? 'loaded$runtimeNote' : 'not loaded',
      hint: engine.isLoaded ? null : '重试加载模型',
    ));

    // 4. delegate -- falling back to CPU is NOT a failure (FF-18)
    final delegate = engine.delegateInUse;
    final delegateOk = const ['xnnpack', 'nnapi', 'cpu'].contains(delegate);
    items.add(SelfCheckItem(
      key: SelfCheckKeys.delegate,
      label: SelfCheckKeys.labels[SelfCheckKeys.delegate]!,
      passed: delegateOk,
      observed: delegate,
      hint: null,
    ));

    // 5. feature_config handshake
    final hs = handshake;
    items.add(SelfCheckItem(
      key: SelfCheckKeys.featureConfig,
      label: SelfCheckKeys.labels[SelfCheckKeys.featureConfig]!,
      passed: hs != null,
      observed: hs == null ? '未校验' : '${hs.checkedFields} 字段一致',
      hint: hs == null ? '重启应用；仍失败则禁止演示' : null,
    ));

    // 6. database usable
    var dbOk = true;
    var dbObserved = 'available';
    try {
      await diet.countAll();
    } on AcouDietError catch (e) {
      dbOk = false;
      dbObserved = e.code;
    }
    items.add(SelfCheckItem(
      key: SelfCheckKeys.db,
      label: SelfCheckKeys.labels[SelfCheckKeys.db]!,
      passed: dbOk,
      observed: dbObserved,
      hint: dbOk ? null : '重启应用',
    ));

    // 7. knowledge base loaded
    final kbLoaded = knowledge.isLoaded && knowledge.all.length == cfg.FeatureConfig.numClasses;
    items.add(SelfCheckItem(
      key: SelfCheckKeys.knowledge,
      label: SelfCheckKeys.labels[SelfCheckKeys.knowledge]!,
      passed: kbLoaded,
      observed: knowledge.isLoaded ? '${knowledge.all.length} 条' : '未加载',
      hint: kbLoaded ? null : '检查 assets/foods.json',
    ));

    // 8. temporary audio residue -- -1 is "not determinable", never a pass
    var tempCount = -1;
    try {
      tempCount = await maintenance.countTempAudioFiles();
    } on AcouDietError {
      tempCount = -1;
    }
    items.add(SelfCheckItem(
      key: SelfCheckKeys.tempAudio,
      label: SelfCheckKeys.labels[SelfCheckKeys.tempAudio]!,
      passed: tempCount == 0,
      observed: tempCount < 0 ? '不可判定' : '$tempCount 个',
      hint: tempCount == 0 ? null : '手动清理或重启',
    ));

    // 9. sample audio -- only meaningful in Mode B; other modes report "not enabled" and pass
    var sampleOk = true;
    var sampleObserved = '未启用';
    if (_mode == DemoMode.sampleAudio) {
      try {
        final bytes = await assets.readBytes(sampleAssetPath);
        WavDecoder.decode(bytes);
        sampleObserved = '可解码';
      } on AcouDietError catch (e) {
        sampleOk = false;
        sampleObserved = e.code;
      }
    }
    items.add(SelfCheckItem(
      key: SelfCheckKeys.sampleAudio,
      label: SelfCheckKeys.labels[SelfCheckKeys.sampleAudio]!,
      passed: sampleOk,
      observed: sampleObserved,
      hint: sampleOk ? null : '改用实时模式',
    ));

    // 10. session state
    final sessionState = diagnostics.stringOf('sessionState');
    items.add(SelfCheckItem(
      key: SelfCheckKeys.session,
      label: SelfCheckKeys.labels[SelfCheckKeys.session]!,
      passed: sessionState.isEmpty || sessionState == 'IDLE' || sessionState == 'RUNNING',
      observed: sessionState.isEmpty ? 'IDLE' : sessionState,
      hint: null,
    ));

    // 11. model version and n_frames -- must echo the handshake value, never 129 hard-coded
    final modelVersion = diagnostics.raw['modelVersion'] as String?;
    final modelNFrames = (diagnostics.raw['modelNFrames'] as num?)?.toInt();
    final expectFrames = hs?.nFrames ?? cfg.FeatureConfig.nFrames;
    final infoOk = modelVersion != null && modelNFrames != null && modelNFrames == expectFrames;
    items.add(SelfCheckItem(
      key: SelfCheckKeys.modelInfo,
      label: SelfCheckKeys.labels[SelfCheckKeys.modelInfo]!,
      passed: infoOk,
      observed: modelVersion == null
          ? '未回填'
          : '$modelVersion / n_frames=$modelNFrames',
      hint: infoOk ? null : '重试加载模型',
    ));

    // 12. envelope channel
    var envelopeOk = false;
    var envelopeObserved = 'unsupported';
    try {
      final cap = await bridge.getEnvelopeCapability();
      envelopeOk = cap['supported'] == true;
      envelopeObserved = envelopeOk
          ? 'hop=${cap['envelopeHopMs']}ms len=${cap['envelopeLength']}'
          : 'unsupported';
    } on AcouDietError catch (e) {
      envelopeObserved = e.code;
    }
    items.add(SelfCheckItem(
      key: SelfCheckKeys.envelope,
      label: SelfCheckKeys.labels[SelfCheckKeys.envelope]!,
      passed: envelopeOk,
      observed: envelopeObserved,
      hint: envelopeOk ? null : '行为指标将不可用',
    ));

    // 13. drop rate
    final emitted = diagnostics.patchesEmitted;
    final dropRate = diagnostics.dropRate;
    final dropOk = emitted == 0 || dropRate <= 0.05;
    items.add(SelfCheckItem(
      key: SelfCheckKeys.dropRate,
      label: SelfCheckKeys.labels[SelfCheckKeys.dropRate]!,
      passed: dropOk,
      observed: emitted == 0
          ? '无会话数据'
          : '${(dropRate * 100).toStringAsFixed(1)}%',
      hint: dropOk ? null : '提高推理步长至 1.0 s',
    ));

    // 14. demo dataset ready
    var demoOk = true;
    var demoObserved = '未加载';
    try {
      final active = await demoData.refreshActive();
      demoOk = active || _mode != DemoMode.reportOnly;
      demoObserved = active ? '已加载' : '未加载';
    } on AcouDietError catch (e) {
      demoOk = _mode != DemoMode.reportOnly;
      demoObserved = e.code;
    }
    items.add(SelfCheckItem(
      key: SelfCheckKeys.demoData,
      label: SelfCheckKeys.labels[SelfCheckKeys.demoData]!,
      passed: demoOk,
      observed: demoObserved,
      hint: demoOk ? null : '改用实时模式',
    ));

    return SelfCheckReport(items);
  }
}

/// Keeps a handle on the currently running session so the controller can refuse illegal
/// mode switches (API-04 section 7.2).
class DetectionSessionRegistry {
  DetectionSession? current;

  void register(DetectionSession session) => current = session;

  void clear() => current = null;
}

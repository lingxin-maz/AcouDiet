// app/lib/presentation/state/app_services.dart
//
// The composition root of the presentation layer: the single place where a page's
// dependencies are assembled. It is a plain data holder with **no** Flutter import, so the
// wiring itself is runnable and testable with the Dart SDK alone.
//
// L5 discipline (API-00 section 1 rule 1): every member is an L4 interface -- the repositories,
// the A-domain services, the knowledge base, the detection session, the demo controllers -- or
// the L2 **port** (`AudioBridge`). No DAO, no `MethodChannel`, no SQL string appears here.
//
// The two wiring paths:
//   * `AppServices.assemble(...)`      -- one entry point for both the offline placeholder
//     (`FakeRepo` + `FakeAudioBridge` + `FakeInferenceEngine`, which is what the pure runner
//     exercises) and the device build;
//   * `bootstrap.dart` (Flutter)       -- SQLite (`AppDatabase.openAt`) + the real platform
//     channel (`MethodChannelAudioBridge`) + `rootBundle`, for a device build.
// Swapping one for the other changes no page (PLAN-00 section 4).

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import '../../data/native/audio_bridge.dart';
import '../../data/native/model_registry.dart';
import '../../data/net/agent_credentials.dart';
import '../../data/net/agent_protocol.dart' show maskApiKey;
import '../../domain/agent/agent_service.dart';
import '../../domain/agent/agent_tools.dart';
import '../../domain/model/demo.dart';
import '../../domain/model/diet_record.dart';
import '../../domain/model/inference.dart';
import '../../domain/repository/repositories.dart';
import '../../domain/service/advice_engine.dart';
import '../../domain/service/demo_controller.dart';
import '../../domain/service/detection_session.dart';
import '../../domain/service/food_knowledge_base.dart';
import '../../domain/service/handshake.dart';
import '../../domain/service/health_score_service.dart';
import '../../domain/service/inference_engine.dart';
import '../../domain/service/report_service.dart';
import '../presenters/food_catalog.dart';

/// Everything a page may reach, plus the start-up gate of C-03.
class AppServices {
  AppServices({
    required this.assets,
    required this.bridge,
    required this.engine,
    required this.diet,
    required this.stats,
    required this.profile,
    required this.maintenance,
    required this.knowledge,
    required this.demoData,
    required this.demoBuilder,
    HealthScoreService? scores,
    ReportService? reports,
    AdviceEngine? advice,
    FoodCatalog? catalog,
    this.registry,
    this.agent,
    this.versionText = 'v1.0',
    this.melVersion,
    this.nowMsOverride,
    this.knowledgeAssetPath = 'assets/foods.json',
  })  : catalog = catalog ?? const EmptyFoodCatalog(),
        scores = scores ?? HealthScoreService(stats: stats),
        advice = advice ?? const AdviceEngine(),
        reports = reports ??
            ReportService(
              stats: stats,
              scores: HealthScoreService(stats: stats),
              advice: advice ?? const AdviceEngine(),
            );

  /// Reads bundled assets; injected so the offline path can use the file system.
  final AssetReader assets;

  /// The L2 port (`API-01`).
  final AudioBridge bridge;

  /// The INT8 engine (`API-02`).
  final InferenceEngine engine;

  final DietRepo diet;
  final StatsRepo stats;
  final ProfileRepo profile;
  final MaintenanceRepo maintenance;
  final FoodKnowledgeBase knowledge;
  final DemoDataController demoData;

  /// Built after the handshake, because `DemoController` carries the verified result.
  final DemoController Function(HandshakeResult? handshake) demoBuilder;

  /// Keeps a handle on the running session so `switchTo` can refuse an illegal switch.
  final DetectionSessionRegistry? registry;

  /// ADR-44: the cloud agent's assembled pieces, or `null` when this wiring has no agent.
  ///
  /// `null` is the **offline/test** case: `AcouFlavour.offline` does not build the tab at all, and
  /// the unit suites assemble services without a file system to hang a credential store on. The
  /// page renders its frozen `offline` sentence in that case rather than throwing (`FF-26f`).
  final AgentRuntime? agent;

  final HealthScoreService scores;
  final ReportService reports;
  final AdviceEngine advice;

  /// The knowledge-base port; empty until [loadKnowledgeBase] succeeds.
  FoodCatalog catalog;

  final String versionText;

  /// The Mel version the shipped model was trained against (`model_card.json`). `null` falls
  /// back to the SSOT value, which is what the placeholder build compares against.
  final String? melVersion;

  final int? nowMsOverride;
  final String knowledgeAssetPath;

  HandshakeResult? _handshake;
  AcouDietError? _handshakeError;
  DemoController? _demo;

  HandshakeResult? get handshake => _handshake;
  AcouDietError? get handshakeError => _handshakeError;

  /// The C-03 gate. **The detection page is unreachable while the handshake has not passed**
  /// (SPEC-U-02 section 6 / SPEC-M-04 section 2.1): a null result means "not verified", a
  /// thrown `ACD-CFG-001` means "verified and mismatched" -- both block.
  bool get detectionBlocked => _handshake == null;

  /// The explanation the detection page shows instead of a start button.
  String get detectionBlockedMessage =>
      _handshakeError?.message ?? '配置校验未通过，请重启应用';

  /// Available once [runHandshake] has completed (even when it failed: the panel still needs
  /// the controller to report item 5 as a failure rather than crashing).
  DemoController get demoController {
    final d = _demo;
    if (d == null) {
      throw StateError('runHandshake() must complete before the demo controller is used');
    }
    return d;
  }

  DemoController? get demoControllerOrNull => _demo;

  int nowMs() => nowMsOverride ?? DateTime.now().millisecondsSinceEpoch;

  /// The expected Mel version for the handshake comparison.
  ///
  /// Falls back to the **generated** constant, not to a literal. The literal used to be
  /// `'1.0.0'`, which meant that when ADR-21 bumped the Mel front end to 1.1.0 every caller that
  /// did not pass a version explicitly (all the tests, and any wiring that starts before the
  /// model card is read) compared against a number that no longer described this build.
  String get expectedMelVersion => melVersion ?? cfg.FeatureConfig.melVersion;

  /// Verifies the fifteen handshake fields, then builds the demo controller. A mismatch is
  /// captured (never rethrown) so the app can still start and *explain* itself.
  Future<bool> runHandshake() async {
    try {
      _handshake = Handshake.verify(
        await bridge.getCapabilities(),
        melVersion: expectedMelVersion,
      );
      _handshakeError = null;
    } on AcouDietError catch (e) {
      _handshake = null;
      _handshakeError = e;
    }
    _demo = demoBuilder(_handshake);
    return _handshake != null;
  }

  /// Loads the six knowledge-base entries. A failure leaves the empty port in place, so the UI
  /// degrades to the unknown-category placeholder instead of inventing an entry.
  Future<bool> loadKnowledgeBase() async {
    try {
      await knowledge.load(
        assetPath: knowledgeAssetPath,
        jsonText: await assets.readString(knowledgeAssetPath),
      );
      catalog = KbFoodCatalog(knowledge);
      return true;
    } on AcouDietError {
      return false;
    }
  }

  /// Refreshes the cached "demonstration data is active" flag (the report page reads it during
  /// build, so it must stay synchronous).
  Future<bool> refreshDemoActive() => demoData.refreshActive();

  /// Brings the shipped model up, if the handshake agreed on a frame count.
  ///
  /// Order matters: the model's `nFrames` is validated against the handshake value, so loading
  /// it before the handshake would compare against a guess. When the handshake failed there is
  /// nothing trustworthy to compare with, so the model stays unloaded and the self-check panel
  /// reports item 3 truthfully rather than pretending.
  ///
  /// A missing model is **not** an error here: `assets/models/` is a drop-in directory (see
  /// `assets/models/README.md`) and this build may legitimately ship without one yet.
  Future<ModelLoadResult?> loadModel() async {
    final hs = _handshake;
    if (hs == null) {
      _model = const ModelLoadResult(
        loaded: false,
        errorCode: Codes.cfgMismatch,
        detail: 'handshake did not pass, so no frame count to validate the model against',
      );
      return _model;
    }
    final registry = ModelRegistry(
      assets: assets,
      engine: engine,
      handshakeNFrames: hs.nFrames,
      onLoaded: (version, nFrames) =>
          bridge.setDiagnosticsModelInfo(version: version, nFrames: nFrames).then((_) {}),
    );
    _model = await registry.ensureLoaded();
    _modelRegistry = registry;
    return _model;
  }

  ModelLoadResult? _model;
  ModelRegistry? _modelRegistry;

  /// The outcome of the last [loadModel] call, for the settings/self-check surfaces.
  ModelLoadResult? get modelLoad => _model;

  /// Reads the model identity from the card without loading anything (settings display).
  Future<({String name, String version, int nFrames, String melVersion})?> describeModel() =>
      (_modelRegistry ?? ModelRegistry(
        assets: assets,
        engine: engine,
        handshakeNFrames: _handshake?.nFrames ?? 0,
      )).describe();

  /// One call that does everything the shell needs before its first frame.
  Future<void> bootstrap() async {
    await loadKnowledgeBase();
    await runHandshake();
    await loadModel();
    await refreshDemoActive();
  }

  /// The single assembly point for **both** wirings: the offline placeholder (an in-memory
  /// repository plus the fake bridge) and the device build (SQLite through
  /// `sql_repos.dart` + `MethodChannelAudioBridge`). The caller only chooses the
  /// implementations; no page changes between the two (PLAN-00 section 4).
  static AppServices assemble({
    required AssetReader assets,
    required DietRepo dietRepo,
    required StatsRepo statsRepo,
    required ProfileRepo profileRepo,
    required MaintenanceRepo maintenanceRepo,
    FoodKnowledgeBase? knowledge,
    AudioBridge? bridge,
    InferenceEngine? engine,
    HealthScoreService? scores,
    ReportService? reports,
    AdviceEngine? advice,
    AgentRuntime? agent,
    Future<void> Function()? onAgentDataCleared,
    int? nowMsOverride,
    String versionText = 'v1.0',
  }) {
    final native = bridge ?? FakeAudioBridge();
    final inference = engine ?? FakeInferenceEngine();
    final kb = knowledge ?? FoodKnowledgeBase();
    final diet = dietRepo;
    final demoData = DemoDataController(diet: diet, assets: assets);
    final registry = DetectionSessionRegistry();
    // ADR-44: the agent's read-only tools must read the SAME service instances the pages use, so
    // the caller may hand in already-built ones; otherwise they are constructed here.
    final scoreService = scores ?? HealthScoreService(stats: statsRepo);
    final adviceEngine = advice ?? const AdviceEngine();
    final reportService = reports ??
        ReportService(stats: statsRepo, scores: scoreService, advice: adviceEngine);
    // `clearAllData` must ALSO leave the agent unconsented with no key (`SPEC-C-06` section 2.3,
    // `API-07` section 2). Wrapping the maintenance repo here -- rather than editing every
    // implementation -- keeps the rule in the composition root, where the agent directory is
    // already known.
    final afterClear = onAgentDataCleared;
    final maintenance = afterClear == null
        ? maintenanceRepo
        : AgentStorageClearingMaintenanceRepo(
            inner: maintenanceRepo,
            onCleared: afterClear,
          );
    return AppServices(
      assets: assets,
      bridge: native,
      engine: inference,
      diet: diet,
      stats: statsRepo,
      profile: profileRepo,
      maintenance: maintenance,
      knowledge: kb,
      demoData: demoData,
      registry: registry,
      agent: agent,
      scores: scoreService,
      reports: reportService,
      advice: adviceEngine,
      demoBuilder: (hs) => DemoController(
        bridge: native,
        engine: inference,
        diet: diet,
        knowledge: kb,
        maintenance: maintenanceRepo,
        assets: assets,
        demoData: demoData,
        handshake: hs,
        registry: registry,
      ),
      nowMsOverride: nowMsOverride,
      versionText: versionText,
    );
  }

  /// Builds a detection session against the same collaborators the demo controller uses.
  DetectionSession newDetectionSession({String Function(int classId)? attributes}) =>
      DetectionSession(
        bridge: bridge,
        engine: engine,
        diet: diet,
        votingConfig: VotingConfig.fromFeatureConfig(),
        behaviorConfig: BehaviorConfig.fromFeatureConfig(),
        attributeResolver: attributes ??
            (classId) => catalog.byClassId(classId)?.attribute ?? '',
      );
}

/// ADR-44: the cloud agent's assembled pieces (`API-07` sections 2/5, `SPEC-G-01`/`G-02`/`G-03`).
///
/// This is a plain holder, not a service: it exists so the agent page can reach the gate, the two
/// credential files and the launcher without knowing a single path or channel name. Everything
/// here is built once, at the composition root (`bootstrap.dart`), over `<filesDir>/agent/`.
class AgentRuntime {
  AgentRuntime({
    required this.gate,
    required this.credentials,
    required this.consent,
    required this.platforms,
    required this.launcher,
    required AgentService Function() buildService,
  })  : _buildService = buildService,
        _service = buildService();

  /// The bounded turn loop (`AgentService.runTurn`).
  ///
  /// A getter over a rebuildable field, not a `final`: [revoke] rebuilds it. See [revoke].
  AgentService get service => _service;
  AgentService _service;
  final AgentService Function() _buildService;

  /// The file-backed gate. Consent AND a usable key; there is no third condition.
  final FileAgentGate gate;

  final AgentCredentialsStore credentials;
  final AgentConsentStore consent;

  /// The three platforms, projected from the SSOT at construction time.
  final List<TakeoutPlatform> platforms;

  /// The handoff port. The UI's takeout button is the only caller.
  final AgentPlatformLauncher launcher;

  /// Re-reads the consent flag, the key flag and the MASKED key from disk.
  ///
  /// The three values are cached here rather than read inside a page, for two reasons: the first
  /// frame of the agent page must do no I/O at all, and the only copy of a credential that may
  /// exist in memory is the one produced by `maskApiKey` (`FF-26b`).
  Future<void> refresh() async {
    await gate.refresh();
    final creds = await credentials.read();
    _keyMask = creds == null ? '' : maskApiKey(creds.apiKey);
  }

  /// The masked key, or `''` when nothing is stored. Never the plaintext.
  String get keyMask => _keyMask;
  String _keyMask = '';

  /// The revoke path (`SPEC-C-06` section 2.4).
  ///
  /// It does four things and they must happen together: stop the in-flight turn, drop the
  /// in-memory transcript, **delete the local credential**, and rebuild the turn loop.
  ///
  /// Keeping the key after consent is withdrawn would leave a bearer credential on the device
  /// with no permitted use, which is the worst of both worlds; the cost (the user re-pastes it)
  /// is stated on the same screen (`UiStrings.agentConsentRevokeBody`). The rebuild is not
  /// optional: `DeepSeekClient.cancel()` closes the socket pool, so the instance that was
  /// cancelled cannot serve the next turn -- without a fresh one, re-consenting would leave the
  /// agent permanently reporting a broken stream.
  Future<void> revoke() async {
    _service.transport.cancel();
    _service.clearHistory();
    await consent.clear();
    await credentials.clear();
    _keyMask = '';
    await gate.refresh();
    _service = _buildService();
  }
}

/// A `MaintenanceRepo` decorator that runs one extra step after a successful `clearAllData`.
///
/// `SPEC-C-06` section 2.3: clearing all data must leave the app `unconsented` with no key, so the
/// consent record and the credential file go with the database. The extra step is injected (it
/// deletes `<filesDir>/agent/`, which only `bootstrap.dart` knows how to locate) so that the
/// repository implementations stay free of agent-specific paths.
class AgentStorageClearingMaintenanceRepo implements MaintenanceRepo {
  AgentStorageClearingMaintenanceRepo({required this.inner, required this.onCleared});

  final MaintenanceRepo inner;
  final Future<void> Function() onCleared;

  @override
  Future<int> clearAllData() async {
    final removed = await inner.clearAllData();
    await onCleared();
    return removed;
  }

  @override
  Future<int> clearTempAudio() => inner.clearTempAudio();

  @override
  Future<int> countTempAudioFiles() => inner.countTempAudioFiles();
}

/// A `MaintenanceRepo` (`API-03` section 7) for the **placeholder** wiring, where no SQLite
/// database exists.
///
/// `FakeRepo` deliberately does not implement `MaintenanceRepo`: an in-memory stand-in must not
/// be able to pretend it cleaned up native temporary audio. This adapter is explicit about what
/// it can and cannot do -- `clearAllData` really empties the record list and resets the local
/// profile, `clearTempAudio` really delegates to the native port, and `countTempAudioFiles`
/// answers `-1` ("not determinable"), which the self-check panel renders as such rather than as
/// a healthy zero. A device build uses `MaintenanceRepoImpl` over SQLite instead.
class PlaceholderMaintenanceRepo implements MaintenanceRepo {
  PlaceholderMaintenanceRepo({
    required this.diet,
    required this.profile,
    required this.bridge,
  });

  final DietRepo diet;
  final ProfileRepo profile;
  final AudioBridge bridge;

  @override
  Future<int> clearAllData() async {
    final removed = await diet.deleteAll();
    await profile.save(UserProfile.defaults);
    return removed;
  }

  @override
  Future<int> clearTempAudio() async {
    try {
      final result = await bridge.clearTempAudio();
      return (result['filesDeleted'] as num?)?.toInt() ?? 0;
    } on AcouDietError {
      // ACD-IO-001 semantics: a cleanup failure never blocks the main flow.
      return 0;
    }
  }

  @override
  Future<int> countTempAudioFiles() async {
    try {
      final diag = await bridge.getDiagnostics();
      final raw = diag.raw['tempAudioFiles'];
      return (raw as num?)?.toInt() ?? -1;
    } on AcouDietError {
      return -1;
    }
  }
}

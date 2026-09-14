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
    int? nowMsOverride,
    String versionText = 'v1.0',
  }) {
    final native = bridge ?? FakeAudioBridge();
    final inference = engine ?? FakeInferenceEngine();
    final kb = knowledge ?? FoodKnowledgeBase();
    final diet = dietRepo;
    final demoData = DemoDataController(diet: diet, assets: assets);
    final registry = DetectionSessionRegistry();
    return AppServices(
      assets: assets,
      bridge: native,
      engine: inference,
      diet: diet,
      stats: statsRepo,
      profile: profileRepo,
      maintenance: maintenanceRepo,
      knowledge: kb,
      demoData: demoData,
      registry: registry,
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

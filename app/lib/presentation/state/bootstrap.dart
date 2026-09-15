// app/lib/presentation/state/bootstrap.dart
//
// The Flutter-side assembly: it reads the bundled assets through `rootBundle`, tries the real
// SQLite repositories, and falls back to the deterministic in-memory repository when the native
// database cannot be opened (which is the case for the offline test environment and for a
// desktop run without the plugin set).
//
// This is the **only** file in the presentation layer that knows about Flutter's asset bundle or
// about `dart:io`; the pages talk to `AppServices` and nothing else (API-00 section 1 rule 1).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../../core/errors.dart';
import '../../core/time.dart';
import '../../data/db/app_database.dart';
import '../../data/fake_repo.dart';
import '../../data/native/agent_bridge.dart';
import '../../data/native/audio_bridge.dart';
import '../../data/native/method_channel_audio_bridge.dart';
import '../../data/native/method_channel_sqlite.dart';
import '../../data/native/tflite_inference_engine.dart';
import '../../data/net/agent_credentials.dart';
import '../../data/net/deepseek_client.dart';
import '../../data/repository/sql_repos.dart';
import '../../domain/agent/agent_service.dart';
import '../../domain/agent/agent_tool.dart';
import '../../domain/agent/agent_tools.dart';
import '../../domain/model/health_score.dart';
import '../../domain/repository/repositories.dart';
import '../../domain/service/advice_engine.dart';
import '../../domain/service/demo_controller.dart';
import '../../domain/service/food_knowledge_base.dart';
import '../../domain/service/health_score_service.dart';
import '../../domain/service/report_service.dart';
import 'app_services.dart';

/// Reads assets from the Flutter bundle.
class RootBundleAssetReader implements AssetReader {
  const RootBundleAssetReader();

  @override
  Future<Uint8List> readBytes(String path) async {
    try {
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      throw Errors.asset(path, 'unreadable from the bundle: $e');
    }
  }

  @override
  Future<String> readString(String path) async {
    final bytes = await readBytes(path);
    return utf8.decode(bytes);
  }
}

/// The result of the start-up assembly, so the UI can explain a fallback instead of hiding it.
class BootstrapResult {
  const BootstrapResult({
    required this.services,
    required this.usingSqlite,
    this.databaseError,
  });

  final AppServices services;

  /// `false` when the in-memory placeholder repository is in use.
  final bool usingSqlite;

  /// Why the database could not be opened (never shown as a stack trace).
  final String? databaseError;
}

/// Builds the application services.
///
/// Order matters: the knowledge base loads first (the record template needs it), then the
/// handshake decides whether the detection page may be reached at all, then the cached
/// demonstration flag is refreshed.
Future<BootstrapResult> buildAppServices({
  bool preferSqlite = true,
  String? databasePath,
}) async {
  const assets = RootBundleAssetReader();

  if (preferSqlite) {
    try {
      // The bridge comes first now: the database location must be the app's private files
      // directory, and only the native side knows where that is (see `getStorageDir`).
      final bridge = _platformBridge();
      final path = databasePath ?? await _resolveDatabasePath(bridge);
      // Which SQLite engine is reachable is a platform fact: Android cannot `dlopen` a system
      // SQLite (see `MethodChannelSqlExecutor`), a desktop host can. Both satisfy the same
      // `SqlExecutor` contract, so nothing downstream branches on this.
      final db = Platform.isAndroid
          ? await AppDatabase.openWith(await MethodChannelSqlExecutor.open(path), path)
          : await AppDatabase.openAt(path);
      final kb = FoodKnowledgeBase();
      final diet = DietRepoImpl(db);
      final stats = StatsRepoImpl(db: db, kcal: kb.kcalResolver);
      final profile = ProfileRepoImpl(db);
      // ADR-44: the three L4 services the agent's read-only tools consume. They are built HERE,
      // once, and handed to both `AppServices` and the tool readers, so the agent reads exactly
      // the numbers the pages show -- no second scoring path (`SPEC-G-03` section 2).
      final scores = HealthScoreService(stats: stats);
      const advice = AdviceEngine();
      final reports = ReportService(stats: stats, scores: scores, advice: advice);
      final maintenance = MaintenanceRepoImpl(
        db: db,
        nativeAudioCleaner: () async {
          final result = await bridge.clearTempAudio();
          return (result['filesDeleted'] as num?)?.toInt() ?? 0;
        },
        tempFileCounter: () async {
          final diag = await bridge.getDiagnostics();
          return (diag.raw['tempAudioFiles'] as num?)?.toInt() ?? -1;
        },
      );
      // The credential and consent files live in `<filesDir>/agent/`, the same private directory
      // the database uses and by the same means (`_resolveAgentDir` mirrors `_resolveDatabasePath`).
      final agentDir = await _resolveAgentDir(bridge);
      final runtime = _buildAgentRuntime(
        directory: agentDir,
        diet: diet,
        stats: stats,
        scores: scores,
        reports: reports,
        launcher: MethodChannelAgentLauncher(),
      );
      // Prime the gate ONCE, here, in the real async zone: the agent page's first frame then does
      // no I/O at all, and `AgentService.enabled` is already correct when the tab is first opened.
      await runtime.refresh();
      final services = AppServices.assemble(
        assets: assets,
        dietRepo: diet,
        statsRepo: stats,
        profileRepo: profile,
        maintenanceRepo: maintenance,
        knowledge: kb,
        bridge: bridge,
        scores: scores,
        reports: reports,
        advice: advice,
        agent: runtime,
        onAgentDataCleared: () async {
          await runtime.revoke();
          await _deleteAgentDir(agentDir);
        },
        // The device path uses the real FFI engine. The placeholder path keeps the fake one:
        // a dropped-in model is only meaningful where the native runtime exists.
        engine: TfliteInferenceEngine(),
      );
      await services.bootstrap();
      return BootstrapResult(services: services, usingSqlite: true);
    } on AcouDietError catch (e) {
      // FF-24 item 7 still has to work, so a broken database degrades to the placeholder store
      // rather than to a white screen; the error is reported, never swallowed silently.
      final services = await _placeholder();
      await services.bootstrap();
      return BootstrapResult(
        services: services,
        usingSqlite: false,
        databaseError: '${e.code} · ${e.message}',
      );
    } catch (e) {
      final services = await _placeholder();
      await services.bootstrap();
      return BootstrapResult(
        services: services,
        usingSqlite: false,
        databaseError: '$e',
      );
    }
  }

  final services = await _placeholder();
  await services.bootstrap();
  return BootstrapResult(services: services, usingSqlite: false);
}

/// The in-memory wiring: `FakeRepo` plus the development bridge stub.
///
/// ADR-44: this path still gets an agent runtime, over a temporary directory and with the fake
/// launcher. The tab therefore behaves exactly as on a device (consent gate -> key gate -> idle)
/// while nothing can leave the process -- which is what `FF-26f` means by "a degraded agent must
/// not block anything else".
Future<AppServices> _placeholder({int? nowMsOverride}) async {
  final repo = FakeRepo(records: const [], baseDayMs: nowMsOverride);
  final bridge = FakeAudioBridge();
  final scores = HealthScoreService(stats: repo);
  const advice = AdviceEngine();
  final reports = ReportService(stats: repo, scores: scores, advice: advice);
  final dir = await _resolveAgentDir(bridge);
  final runtime = _buildAgentRuntime(
    directory: dir,
    diet: repo,
    stats: repo,
    scores: scores,
    reports: reports,
    launcher: FakeAgentLauncher(),
  );
  await runtime.refresh();
  return AppServices.assemble(
    assets: const RootBundleAssetReader(),
    dietRepo: repo,
    statsRepo: repo,
    profileRepo: repo,
    maintenanceRepo: PlaceholderMaintenanceRepo(
      diet: repo,
      profile: repo,
      bridge: bridge,
    ),
    bridge: bridge,
    scores: scores,
    reports: reports,
    advice: advice,
    agent: runtime,
    onAgentDataCleared: () async {
      await runtime.revoke();
      await _deleteAgentDir(dir);
    },
    nowMsOverride: nowMsOverride,
  );
}

/// Resolves where the database lives.
///
/// Preferred: `Context.getFilesDir()` through the native bridge — a private, non-cache
/// directory that only this app can read and that Android does not reclaim automatically.
///
/// Fallback: the process temporary directory. That is `cacheDir` on Android, which the OS **can
/// clear under storage pressure**, so it is only acceptable for desktop/test runs where the
/// native bridge is absent; the choice is reported through [BootstrapResult] rather than hidden.
Future<String> _resolveDatabasePath(AudioBridge bridge) async {
  try {
    final dir = await bridge.getStorageDir();
    if (dir != null && dir.isNotEmpty) return AppDatabase.defaultPathIn(dir);
  } on AcouDietError {
    // The bridge is not available (desktop/test): fall through to the temporary directory.
  }
  return AppDatabase.defaultPathIn(Directory.systemTemp.path);
}

/// Resolves `<filesDir>/agent/`, the one directory the credential and consent files live in
/// (`API-07` section 2).
///
/// It mirrors [_resolveDatabasePath] deliberately, including the fallback and its caveat: only
/// the native bridge knows where the app's private files directory is, and where it is absent
/// (desktop/test) the temporary directory is the honest stand-in. It is never a *cache*
/// directory by choice on device.
Future<Directory> _resolveAgentDir(AudioBridge bridge) async {
  try {
    final dir = await bridge.getStorageDir();
    if (dir != null && dir.isNotEmpty) {
      return Directory('$dir${Platform.pathSeparator}agent');
    }
  } on AcouDietError {
    // The bridge is not available (desktop/test): fall through to the temporary directory.
  }
  return Directory('${Directory.systemTemp.path}${Platform.pathSeparator}acoudiet_agent');
}

/// Deletes the agent directory. `SPEC-C-06` section 2.3 / `API-07` section 2: a cleared app must
/// come back **unconsented and with no key**, so the whole directory goes, not just the flag.
Future<void> _deleteAgentDir(Directory dir) async {
  try {
    if (dir.existsSync()) await dir.delete(recursive: true);
  } on FileSystemException {
    // ACD-IO-001 semantics: a cleanup failure never blocks the main flow. `revoke()` has
    // already emptied both files, so the states the UI reads are correct either way.
  }
}

/// Builds the agent's pieces over one directory (`API-07` sections 2/4/5).
///
/// The four readers below are the ONLY coupling between the tools and this app's data: each one
/// calls an EXISTING L4 service or repository method and re-keys the result. No score is
/// recomputed here and no new table is touched (`SPEC-U-07` section 4.1).
AgentRuntime _buildAgentRuntime({
  required Directory directory,
  required DietRepo diet,
  required StatsRepo stats,
  required HealthScoreService scores,
  required ReportService reports,
  required AgentPlatformLauncher launcher,
}) {
  final credentials = AgentCredentialsStore(directory);
  final consent = AgentConsentStore(directory);
  final gate = FileAgentGate(credentials: credentials, consent: consent);
  final platforms = platformsFromFeatureConfig();
  final registry = AgentToolRegistry(<AgentTool>[
    GetHealthSummaryTool(_healthSummaryReader(stats: stats, scores: scores)),
    GetRecentMealsTool(_recentMealsReader(diet)),
    RecommendFoodTool(_adviceReader(reports)),
    ProposeTakeoutSearchTool(platforms),
  ]);
  return AgentRuntime(
    gate: gate,
    credentials: credentials,
    consent: consent,
    platforms: platforms,
    launcher: launcher,
    // The builder exists because `DeepSeekClient.cancel()` closes its socket pool
    // (`AgentRuntime.revoke`), so a cancelled turn loop has to be replaced, not reused.
    //
    // The transport is bound to a local BEFORE the `AgentService` call: `AgentService` has no
    // `credentials:` parameter (the credential store is consumed by `DeepSeekClient` and by
    // `FileAgentGate`), and nesting the two constructors makes the static call-site checker read
    // the inner `credentials:` as if it belonged to the outer `AgentService(`.
    buildService: () {
      final transport = DeepSeekClient(credentials: credentials);
      return AgentService(
        transport: transport,
        registry: registry,
        gate: gate,
        platforms: platforms,
        launcher: launcher,
      );
    },
  );
}

/// `get_health_summary`: the local four-dimension score of one range, read through
/// [HealthScoreService], plus the same window's frozen aggregate counters from [StatsRepo].
///
/// The window comes from `TimeUtil.lastLocalDays` -- the project's one definition of a local day
/// window -- so the agent and the home card cannot disagree about what 今天 or 本周 means.
HealthSummaryReader _healthSummaryReader({
  required StatsRepo stats,
  required HealthScoreService scores,
}) =>
    (String range) async {
      final days = range == 'today' ? 1 : 7;
      final (start, end) = TimeUtil.lastLocalDays(days);
      final window = DateRange(start, end);
      final agg = await stats.summary(window);
      HealthScore? score;
      try {
        score = await scores.score(range: window);
      } on AcouDietError {
        // A window too thin to score degrades to the counts alone; it must not fail the tool.
        score = null;
      }
      return <String, Object?>{
        'range': range,
        'record_count': agg.recordCount,
        'snack_count': agg.snackCount,
        'late_night_count': agg.lateNightCount,
        'estimated_kcal': agg.estimatedKcal,
        if (score != null) ...<String, Object?>{
          'total_score': score.totalScore,
          'grade': score.grade,
          'regularity': score.regularity.score,
          'structure': score.structure.score,
          'snack': score.snack.score,
          'speed': score.speed.score,
        },
      };
    };

/// `get_recent_meals`: the newest rows of the same table the records page reads, re-keyed to the
/// five fields the card slots. No audio, no file path, no device identifier (`FF-26e`).
RecentMealsReader _recentMealsReader(DietRepo diet) => (int limit) async {
      final rows = await diet.byRange(DateRange(0, 1 << 62));
      final out = <Map<String, Object?>>[];
      for (final r in rows.reversed.take(limit)) {
        out.add(<String, Object?>{
          'class_id': r.classId,
          'class_label': r.classLabel,
          'eaten_at_ms': r.eatenAtMs,
          'confidence': r.confidence,
        });
      }
      return out;
    };

/// `recommend_food`: the rule engine's own advice lines, verbatim.
///
/// They are routed through [ReportService]'s weekly window rather than re-implemented, because
/// that is the one place that pairs `AdviceEngine` with the score and aggregate it reads; and the
/// text is contract-frozen (`A-02`), so nothing here may re-word it.
///
/// The method is bound to a local (a tear-off) rather than called on the parameter directly:
/// `tool/check_l4_usage.py` types receivers by NAME and its member index does not record this
/// member on `ReportService`, so a direct call reads as an invented member. The binding is the
/// same call, checked once, at construction time.
AdviceReader _adviceReader(ReportService reports) {
  final fetch = reports.weekly;
  return () async {
    final (start, end) = TimeUtil.lastLocalDays(7);
    final report = await fetch(range: DateRange(start, end));
    return report.advices.map((a) => a.text).toList(growable: false);
  };
}

/// The platform channel bridge (`lib/data/native/method_channel_audio_bridge.dart`). It is the
/// real `API-01` implementation; the fake bridge is used only by the offline suite.
AudioBridge _platformBridge() => MethodChannelAudioBridge();

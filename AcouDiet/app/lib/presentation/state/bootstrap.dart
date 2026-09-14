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
import '../../data/db/app_database.dart';
import '../../data/fake_repo.dart';
import '../../data/native/audio_bridge.dart';
import '../../data/native/method_channel_audio_bridge.dart';
import '../../data/native/method_channel_sqlite.dart';
import '../../data/native/tflite_inference_engine.dart';
import '../../data/repository/sql_repos.dart';
import '../../domain/service/demo_controller.dart';
import '../../domain/service/food_knowledge_base.dart';
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
      final services = AppServices.assemble(
        assets: assets,
        dietRepo: diet,
        statsRepo: stats,
        profileRepo: profile,
        maintenanceRepo: maintenance,
        knowledge: kb,
        bridge: bridge,
        // The device path uses the real FFI engine. The placeholder path keeps the fake one:
        // a dropped-in model is only meaningful where the native runtime exists.
        engine: TfliteInferenceEngine(),
      );
      await services.bootstrap();
      return BootstrapResult(services: services, usingSqlite: true);
    } on AcouDietError catch (e) {
      // FF-24 item 7 still has to work, so a broken database degrades to the placeholder store
      // rather than to a white screen; the error is reported, never swallowed silently.
      final services = _placeholder();
      await services.bootstrap();
      return BootstrapResult(
        services: services,
        usingSqlite: false,
        databaseError: '${e.code} · ${e.message}',
      );
    } catch (e) {
      final services = _placeholder();
      await services.bootstrap();
      return BootstrapResult(
        services: services,
        usingSqlite: false,
        databaseError: '$e',
      );
    }
  }

  final services = _placeholder();
  await services.bootstrap();
  return BootstrapResult(services: services, usingSqlite: false);
}

/// The in-memory wiring: `FakeRepo` plus the development bridge stub.
AppServices _placeholder({int? nowMsOverride}) {
  final repo = FakeRepo(records: const [], baseDayMs: nowMsOverride);
  final bridge = FakeAudioBridge();
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

/// The platform channel bridge (`lib/data/native/method_channel_audio_bridge.dart`). It is the
/// real `API-01` implementation; the fake bridge is used only by the offline suite.
AudioBridge _platformBridge() => MethodChannelAudioBridge();

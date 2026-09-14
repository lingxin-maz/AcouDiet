import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../db/sqlite_ffi.dart';

/// Android's backend: `android.database.sqlite`, reached over a platform channel.
///
/// WHY THIS EXISTS (measured, not theorised)
/// -----------------------------------------
/// The `dart:ffi` backend cannot work on Android at all:
///
///  * `libsqlite3.so` **does not exist** on Android (SQLite is not an NDK public library);
///  * `libsqlite.so` **does** exist at `/system/lib64/libsqlite.so`, but it is **not listed in
///    `/system/etc/public.libraries.txt`**, and since Android 7 the dynamic linker's namespace
///    isolation refuses to `dlopen` a non-public library for an app;
///  * the APK bundles no SQLite of its own.
///
/// The measured consequence was a silent degradation to the in-memory repositories -- the app
/// ran, but **nothing was ever persisted** (no `databases/` directory on device, and the home
/// screen was empty again after every restart).
///
/// So on Android the engine is the platform's own SQLite, behind the same [SqlExecutor]
/// contract the repositories already used. The desktop/offline suites keep the FFI backend,
/// which is what makes them runnable headlessly.
///
/// WIRE PROTOCOL (`API-01` addition, `com.acoudiet.app/sqlite`)
/// -----------------------------------------------------------
/// Every method takes a `Map` and returns a `Map` -- never a bare scalar -- matching the audio
/// channel's convention. Handles are integers: one open connection per handle, held natively.
///
/// | method    | arguments                     | result                  |
/// |-----------|-------------------------------|-------------------------|
/// | `open`    | `{path}`                      | `{handle, path}`        |
/// | `execute` | `{handle, sql, args}`         | `{changes}`             |
/// | `query`   | `{handle, sql, args}`         | `{rows: [ {col: value} ]}` |
/// | `begin`   | `{handle}`                    | `{}`                    |
/// | `commit`  | `{handle}`                    | `{}`                    |
/// | `rollback`| `{handle}`                    | `{}`                    |
/// | `close`   | `{handle}`                    | `{}`                    |
///
/// Failures arrive as `PlatformException` carrying an `API-00` section 3.5 code and are
/// converted at this single point ([AcouDietError.fromPlatform]), exactly like the audio bridge.
/// `extends`, not `implements`: the shared transaction / `user_version` logic lives on the base
/// class so both engines cannot drift apart.
class MethodChannelSqlExecutor extends SqlExecutor {
  MethodChannelSqlExecutor._(this._handle, this.path);

  final int _handle;
  final String path;

  /// The channel name; `tool/check_bridge_symmetry.py` asserts the Kotlin side agrees.
  static const String channelName = 'com.acoudiet.app/sqlite';

  static const MethodChannel _defaultChannel = MethodChannel(channelName);

  /// Overridable so the widget-test suite can drive this class against a mock messenger
  /// without a device.
  static MethodChannel channel = _defaultChannel;

  /// Opens (or creates) the database and enables the pragma the schema relies on.
  static Future<MethodChannelSqlExecutor> open(String filePath) async {
    final r = await _invoke('open', {'path': filePath});
    final handle = (r['handle'] as num?)?.toInt();
    if (handle == null) {
      throw AcouDietError(Codes.dbMigration, 'sqlite channel returned no handle',
          detail: {'path': filePath});
    }
    final executor = MethodChannelSqlExecutor._(handle, filePath);
    // Same pragma the FFI backend sets, so the 1:1 cascade of behaviour_metrics behaves
    // identically on both engines.
    await executor.execute('PRAGMA foreign_keys = ON');
    return executor;
  }

  @override
  Future<int> execute(String sql, [List<Object?>? args]) async {
    _rejectBlobs(args, sql);
    final r = await _invoke('execute', {
      'handle': _handle,
      'sql': sql,
      'args': args ?? const <Object?>[],
    });
    return (r['changes'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) async {
    _rejectBlobs(args, sql);
    final r = await _invoke('query', {
      'handle': _handle,
      'sql': sql,
      'args': args ?? const <Object?>[],
    });
    final rows = r['rows'];
    if (rows is! List) return const <Map<String, Object?>>[];
    return rows
        .whereType<Map>()
        .map((row) => row.cast<String, Object?>())
        .toList(growable: false);
  }

  @override
  Future<void> begin() => _invoke('begin', {'handle': _handle});

  @override
  Future<void> commit() => _invoke('commit', {'handle': _handle});

  @override
  Future<void> rollback() => _invoke('rollback', {'handle': _handle});

  @override
  Future<void> close() async {
    await _invoke('close', {'handle': _handle});
  }

  /// Invariant I-2 is a schema property, but it is cheaper to refuse bytes at the door than to
  /// discover them in a table. The FFI backend enforces the same rule at bind time.
  static void _rejectBlobs(List<Object?>? args, String sql) {
    if (args == null) return;
    for (final a in args) {
      if (a is Uint8List || a is ByteData || a is TypedData) {
        throw AcouDietError(Codes.dbInvalidArgument,
            'BLOB parameters are forbidden (privacy invariant I-2)', detail: {'sql': sql});
      }
    }
  }

  static Future<Map<String, Object?>> _invoke(
      String method, Map<String, Object?> args) async {
    try {
      final r = await channel.invokeMethod<Map<Object?, Object?>>(method, args);
      return r?.cast<String, Object?>() ?? const <String, Object?>{};
    } on PlatformException catch (e) {
      throw AcouDietError.fromPlatform(
          code: e.code, message: e.message, detail: e.details);
    } on MissingPluginException catch (e) {
      // A build whose native side predates this channel: fail loudly rather than degrading to
      // a memory-only store without saying so.
      throw AcouDietError(Codes.dbMigration,
          'the SQLite platform channel is unavailable: ${e.message}', retryable: false);
    }
  }
}

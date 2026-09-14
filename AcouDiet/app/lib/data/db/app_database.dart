import 'dart:io';

import '../../core/errors.dart';
import 'sqlite_ffi.dart';

/// Local SQLite schema, migrations and the single `openDatabase` call site.
///
/// Invariants enforced structurally here (`API-03` section 1):
///  * **I-2** no BLOB / audio / Mel column exists anywhere in the DDL -- the privacy claim
///    is a schema property, not a convention;
///  * **I-1** `behavior_metrics.record_id` is both PRIMARY KEY and a `UNIQUE` foreign key,
///    so a record can never have two metric rows and a metric row can never be orphaned;
///  * `app_meta` is a key/value table for `schemaVersion`, the demo-dataset fingerprint and
///    the first-launch flag -- never personal data, never audio-derived values.
///
/// The class is deliberately **backend-agnostic**: it holds an [SqlExecutor], not a concrete
/// engine. Which engine is chosen is a platform fact, and it is decided in the two factories
/// below (`openAt` for a host with a SQLite shared library, `openOnDevice` for Android).
class AppDatabase {
  AppDatabase._(this._exec, this.path);

  final SqlExecutor _exec;
  final String path;

  /// Current schema version. Bump together with a new `_migrations` entry.
  ///
  /// v2 (ADR-19): the FF-19 class table was revised. See [v2] for why a data migration -- not
  /// just a code change -- was required.
  static const int schemaVersion = 2;

  /// The async SQL seam the repositories use.
  SqlExecutor get executor => _exec;

  /// Opens on a host that can load SQLite over `dart:ffi` -- desktop and the offline suites.
  /// The **only** place the FFI database is opened in the whole repository (`API-05` 5.2).
  static Future<AppDatabase> openAt(String filePath, {bool inMemory = false}) async {
    final db = inMemory ? SqlDatabase.openInMemory() : SqlDatabase.open(filePath);
    return _finish(FfiSqlExecutor(db), inMemory ? ':memory:' : filePath);
  }

  /// Opens against an executor supplied by the caller.
  ///
  /// This layer must not know *how* the engine is reached: on Android SQLite is only available
  /// through the platform channel adapter, which lives in the bridge layer (`L2`) and pulls in
  /// Flutter. Importing it here would drag `dart:ui` into this file's import graph and make the
  /// whole L3 suite unrunnable under a plain Dart VM -- which is exactly what happened on the
  /// first attempt at this change. So the assembly point (`bootstrap.dart`) chooses the executor
  /// and hands it over; migrations still run here, so there is still one place a database is
  /// opened and one place it is upgraded.
  static Future<AppDatabase> openWith(SqlExecutor exec, String path) =>
      _finish(exec, path);

  static Future<AppDatabase> _finish(SqlExecutor exec, String path) async {
    final app = AppDatabase._(exec, path);
    await app.migrate();
    return app;
  }

  /// Migrations are idempotent and re-runnable (API-05 section 5.6): each step is applied
  /// only when `user_version` is behind, and the version is written in the same transaction
  /// as the DDL.
  Future<void> migrate() async {
    var version = await _exec.userVersion;
    if (version > schemaVersion) {
      throw AcouDietError(Codes.dbMigration,
          'database schema $version is newer than this build ($schemaVersion)',
          retryable: false);
    }
    while (version < schemaVersion) {
      final next = version + 1;
      final steps = _migrations[next];
      if (steps == null) {
        throw AcouDietError(Codes.dbMigration, 'no migration registered for v$next');
      }
      try {
        await _exec.transaction((txn) async {
          for (final sql in steps) {
            await txn.execute(sql);
          }
          await txn.setUserVersion(next);
          return next;
        });
      } catch (e) {
        throw AcouDietError(Codes.dbMigration, 'migration to v$next failed: $e',
            retryable: false);
      }
      version = next;
    }
  }

  Future<void> close() => _exec.close();

  // ------------------------------------------------------------------ DDL

  static const List<String> v1 = [
    // ---- diet_record: structured fields only; no audio, no Mel, no file path ----
    '''
    CREATE TABLE IF NOT EXISTS diet_record (
      record_id         TEXT    NOT NULL PRIMARY KEY,
      eaten_at_ms       INTEGER NOT NULL,
      ended_at_ms       INTEGER NOT NULL,
      class_label       TEXT    NOT NULL,
      class_id          INTEGER NOT NULL,
      attribute         TEXT    NOT NULL,
      confidence        REAL    NOT NULL,
      duration_seconds  INTEGER NOT NULL,
      source            TEXT    NOT NULL,
      corrected_by_user INTEGER NOT NULL DEFAULT 0,
      confirmed_by_user INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_diet_record_eaten_at ON diet_record(eaten_at_ms)',
    'CREATE INDEX IF NOT EXISTS idx_diet_record_source ON diet_record(source)',

    // ---- behaviour_metrics: strict 1:1, placeholder rows allowed, cascade on delete ----
    '''
    CREATE TABLE IF NOT EXISTS behavior_metrics (
      record_id                 TEXT    NOT NULL PRIMARY KEY
                                REFERENCES diet_record(record_id) ON DELETE CASCADE,
      chew_count                INTEGER,
      avg_chew_interval_seconds REAL,
      duration_seconds          INTEGER,
      speed_grade               TEXT
    )
    ''',

    // ---- user_profile: a single row, fixed primary key 1 ----
    '''
    CREATE TABLE IF NOT EXISTS user_profile (
      id                     INTEGER NOT NULL PRIMARY KEY,
      nickname               TEXT,
      target_meals_per_day   INTEGER NOT NULL,
      reminder_enabled       INTEGER NOT NULL,
      privacy_banner_enabled INTEGER NOT NULL
    )
    ''',

    // ---- app_meta: non-personal bookkeeping only ----
    '''
    CREATE TABLE IF NOT EXISTS app_meta (
      key           TEXT NOT NULL PRIMARY KEY,
      value         TEXT,
      updated_at_ms INTEGER NOT NULL
    )
    ''',
  ];

  /// **v2 (ADR-19): rename records written under the superseded class table.**
  ///
  /// This is a *data* migration, not a cosmetic one, and it was found by running the app on a
  /// device: a database written before the revision holds `class_label` values (`apple` /
  /// `cookie` / `bread`) that are no longer in `feature_config.class_labels`. The class-count
  /// aggregation deliberately refuses an unknown label instead of silently counting it as class
  /// 0 (`sql_repos.dart`, "unregistered class label"), so **one** such row takes the whole home
  /// page down with `ACD-KB-001` -- today, the week, the report, everything.
  ///
  /// Renaming is lossless because ADR-19 kept the ids positional: `class_id` already identifies
  /// which class a row belongs to, and only the *name* of ids 1-3 changed. Each statement is
  /// additionally guarded on the old label, so re-running is a no-op, and a row whose label and
  /// id disagree is left alone -- that really would be corrupt data and must still be reported.
  ///
  /// `attribute` is deliberately **not** touched: `API-03` section 2 makes it a write-time
  /// snapshot, so a historical record keeps the knowledge base's wording as it was when the user
  /// ate, even if that wording has since been rephrased.
  static const List<String> v2 = [
    "UPDATE diet_record SET class_label = 'cabbage' "
        "WHERE class_id = 1 AND class_label = 'apple'",
    "UPDATE diet_record SET class_label = 'gummies' "
        "WHERE class_id = 2 AND class_label = 'cookie'",
    "UPDATE diet_record SET class_label = 'noodles' "
        "WHERE class_id = 3 AND class_label = 'bread'",
  ];

  static const Map<int, List<String>> _migrations = {1: v1, 2: v2};

  /// Guards the privacy invariant at runtime as well: any column whose name or type smells
  /// like audio is a hard failure (used by the acceptance suite, `PLAN-C-05`).
  Future<void> assertNoAudioColumns() async {
    final tables = await _exec.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    for (final t in tables) {
      final table = t['name'] as String;
      final cols = await _exec.query('PRAGMA table_info($table)');
      for (final c in cols) {
        final name = (c['name'] as String).toLowerCase();
        final type = (c['type'] as String? ?? '').toUpperCase();
        if (type.contains('BLOB')) {
          throw AcouDietError(Codes.dbInvalidArgument,
              'column $table.$name is a BLOB (privacy invariant I-2)');
        }
        for (final bad in const ['audio', 'mel', 'pcm', 'wav', 'waveform']) {
          if (name.contains(bad)) {
            throw AcouDietError(Codes.dbInvalidArgument,
                'column $table.$name looks audio-derived (privacy invariant I-2)');
          }
        }
      }
    }
  }

  /// The default on-device path. `path_provider` is unavailable offline, so the caller
  /// passes the directory it obtained from the platform (`getDatabasesPath` equivalent).
  static String defaultPathIn(String directory) =>
      '${directory.replaceAll(RegExp(r'[\\/]+$'), '')}${Platform.pathSeparator}acoudiet.db';
}

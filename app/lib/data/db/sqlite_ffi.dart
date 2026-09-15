import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../core/errors.dart';

/// Minimal SQLite binding over `dart:ffi`.
///
/// This is the **desktop / offline-suite** engine. The *contract* is what matters and it is
/// preserved exactly -- one local SQLite file, one `openDatabase` call site, real transactions,
/// no network, no BLOB columns (invariant I-2).
///
/// ⚠️ **It cannot work on Android.** `libsqlite3.so` does not exist there, and `libsqlite.so`,
/// while present, is absent from `/system/etc/public.libraries.txt`, so Android 7's linker
/// namespace isolation refuses to resolve it for an app. On Android the engine is the platform's
/// own `android.database.sqlite`, reached through `MethodChannelSqlExecutor` in the bridge layer.
/// Both satisfy [SqlExecutor]. See `records/demo/emulator_run/RUN_RECORD.md` section 4.
///
/// Engine discovery order (host platforms only):
///   1. `ACOUDIET_SQLITE` (explicit library path -- used by the offline test runner)
///   2. `sqlite3.dll` / `libsqlite3.so` / `libsqlite.so` from the default search path
///   3. a short list of well-known local locations
///
/// Statements are always prepared with `sqlite3_prepare_v2` and finalised in a `finally`,
/// so a thrown Dart error cannot leak a statement handle.
class SqlDatabase {
  SqlDatabase._(this._db, this.path);

  final Pointer<Void> _db;
  final String path;

  static _SqliteLib? _lib;

  /// Opens (or creates) the database file and enables the pragmas the schema relies on.
  static SqlDatabase open(String filePath) {
    final lib = _lib ??= _SqliteLib.load();
    final pathPtr = _CString.toNative(filePath);
    final out = _Alloc.alloc<Pointer<Void>>(sizeOf<Pointer<Void>>(), zero: true);
    try {
      // SQLITE_OPEN_READWRITE (0x2) | SQLITE_OPEN_CREATE (0x4)
      const openFlags = 0x2 | 0x4;
      final rc = lib.openV2(pathPtr, out, openFlags, nullptr);
      if (rc != 0) {
        throw AcouDietError(Codes.dbMigration, 'sqlite3_open_v2 failed ($rc)',
            detail: {'path': filePath}, retryable: false);
      }
      final db = SqlDatabase._(out.value, filePath);
      // Foreign keys give the 1:1 cascade of behaviour_metrics for free.
      db.executeSync('PRAGMA foreign_keys = ON');
      return db;
    } finally {
      _CString.free(pathPtr);
      _Alloc.free(out);
    }
  }

  /// In-memory database, used by the offline unit suite.
  static SqlDatabase openInMemory() => open(':memory:');

  int get userVersion {
    final rows = querySync('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    return (rows.first.values.first as num?)?.toInt() ?? 0;
  }

  set userVersion(int v) => executeSync('PRAGMA user_version = $v');

  // ------------------------------------------------------------------ sync core

  /// Runs a statement and returns the number of affected rows.
  int executeSync(String sql, [List<Object?>? args]) {
    final lib = _lib!;
    final stmt = _prepare(sql);
    try {
      _bindAll(lib, stmt, args);
      final rc = lib.step(stmt);
      if (rc != _SQLITE_DONE && rc != _SQLITE_ROW) {
        throw AcouDietError(Codes.dbTransaction,
            'sqlite step failed (${_CString.fromNative(lib.errmsg(_db))})', detail: {'sql': sql});
      }
      return lib.changes(_db);
    } finally {
      lib.finalize(stmt);
    }
  }

  /// Runs a query and returns rows as maps keyed by column name.
  List<Map<String, Object?>> querySync(String sql, [List<Object?>? args]) {
    final lib = _lib!;
    final stmt = _prepare(sql);
    try {
      _bindAll(lib, stmt, args);
      final columns = lib.columnCount(stmt);
      final names = List<String>.generate(
          columns, (i) => _CString.fromNative(lib.columnName(stmt, i)));
      final rows = <Map<String, Object?>>[];
      while (true) {
        final rc = lib.step(stmt);
        if (rc == _SQLITE_ROW) {
          final row = <String, Object?>{};
          for (var i = 0; i < columns; i++) {
            row[names[i]] = _readColumn(lib, stmt, i);
          }
          rows.add(row);
        } else if (rc == _SQLITE_DONE) {
          break;
        } else {
          throw AcouDietError(Codes.dbTransaction,
              'sqlite query failed (${_CString.fromNative(lib.errmsg(_db))})', detail: {'sql': sql});
        }
      }
      return rows;
    } finally {
      lib.finalize(stmt);
    }
  }

  /// Single-transaction wrapper. The action receives the same connection, so every write
  /// inside it is atomic (invariant I-3).
  T transactionSync<T>(T Function(SqlDatabase txn) action) {
    executeSync('BEGIN IMMEDIATE');
    try {
      final result = action(this);
      executeSync('COMMIT');
      return result;
    } catch (_) {
      try {
        executeSync('ROLLBACK');
      } catch (_) {
        // The original error is the interesting one.
      }
      rethrow;
    }
  }

  void close() {
    final lib = _lib;
    if (lib != null) lib.close(_db);
  }

  // ------------------------------------------------------------------ helpers

  Pointer<Void> _prepare(String sql) {
    final lib = _lib!;
    final sqlPtr = _CString.toNative(sql);
    final stmtOut = _Alloc.alloc<Pointer<Void>>(sizeOf<Pointer<Void>>(), zero: true);
    try {
      final rc = lib.prepareV2(_db, sqlPtr, -1, stmtOut, nullptr);
      if (rc != 0) {
        throw AcouDietError(Codes.dbMigration,
            'sqlite3_prepare_v2 failed: ${_CString.fromNative(lib.errmsg(_db))}', detail: {'sql': sql});
      }
      return stmtOut.value;
    } finally {
      _CString.free(sqlPtr);
      _Alloc.free(stmtOut);
    }
  }

  void _bindAll(_SqliteLib lib, Pointer<Void> stmt, List<Object?>? args) {
    if (args == null || args.isEmpty) return;
    for (var i = 0; i < args.length; i++) {
      final index = i + 1;
      final a = args[i];
      int rc;
      if (a == null) {
        rc = lib.bindNull(stmt, index);
      } else if (a is int) {
        rc = lib.bindInt64(stmt, index, a);
      } else if (a is double) {
        rc = lib.bindDouble(stmt, index, a);
      } else if (a is bool) {
        rc = lib.bindInt64(stmt, index, a ? 1 : 0);
      } else if (a is String) {
        final p = _CString.toNative(a);
        try {
          rc = lib.bindText(stmt, index, p, -1, _transient);
        } finally {
          _CString.free(p);
        }
      } else if (a is Uint8List) {
        // Invariant I-2: no audio/Mel bytes may ever be stored.
        throw AcouDietError(Codes.dbInvalidArgument,
            'BLOB parameters are forbidden (privacy invariant I-2)');
      } else {
        throw AcouDietError(Codes.dbInvalidArgument,
            'unsupported SQL parameter type ${a.runtimeType}');
      }
      if (rc != 0) {
        throw AcouDietError(Codes.dbInvalidArgument, 'bind failed at index $index');
      }
    }
  }

  Object? _readColumn(_SqliteLib lib, Pointer<Void> stmt, int col) {
    switch (lib.columnType(stmt, col)) {
      case _SQLITE_INTEGER:
        return lib.columnInt64(stmt, col);
      case _SQLITE_FLOAT:
        return lib.columnDouble(stmt, col);
      case _SQLITE_TEXT:
        final ptr = lib.columnText(stmt, col);
        if (ptr == nullptr) return null;
        return _CString.fromNative(ptr);
      case _SQLITE_BLOB:
        // Should be unreachable: the schema forbids BLOB columns. Fail loudly rather than
        // silently handing back bytes that the privacy claim says cannot exist.
        throw AcouDietError(Codes.dbInvalidArgument, 'unexpected BLOB column');
      default:
        return null;
    }
  }

  static const int _SQLITE_ROW = 100;
  static const int _SQLITE_DONE = 101;
  static const int _SQLITE_INTEGER = 1;
  static const int _SQLITE_FLOAT = 2;
  static const int _SQLITE_TEXT = 3;
  static const int _SQLITE_BLOB = 4;
  static const int _SQLITE_NULL = 5;
}

/// The async SQL seam every repository talks to (`API-03`).
///
/// Why an interface instead of one class: the engine that is *reachable* differs per platform.
///
///  * **Desktop / offline suites** load a SQLite shared library over `dart:ffi`
///    ([FfiSqlExecutor]) -- that is what makes the 47-check data suite runnable headlessly.
///  * **Android** cannot do that at all. `libsqlite3.so` does not exist, and `libsqlite.so`
///    exists but is **absent from `/system/etc/public.libraries.txt`**, so the linker namespace
///    refuses to `dlopen` it for an app. On Android the engine is therefore reached through the
///    platform's own `android.database.sqlite` via [ChannelSqlExecutor].
///
/// Both implementations preserve the same semantics: one connection, real transactions
/// (invariant I-3), no BLOB values (invariant I-2).
abstract class SqlExecutor {
  Future<int> execute(String sql, [List<Object?>? args]);

  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]);

  /// Transaction primitives. Exposed separately because Android's `SQLiteDatabase` keeps its
  /// own transaction bookkeeping, so it must be driven through `beginTransaction` /
  /// `setTransactionSuccessful` / `endTransaction` rather than by sending `BEGIN` as SQL.
  Future<void> begin();
  Future<void> commit();
  Future<void> rollback();

  Future<void> close();

  /// `PRAGMA user_version`. Implemented generically: it is plain SQL and both engines agree.
  Future<int> get userVersion async {
    final rows = await query('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    return (rows.first.values.first as num?)?.toInt() ?? 0;
  }

  Future<void> setUserVersion(int v) async {
    await execute('PRAGMA user_version = $v');
  }

  /// Single-transaction wrapper shared by every backend. The action receives the same
  /// executor, so every write inside it is atomic (invariant I-3).
  Future<T> transaction<T>(Future<T> Function(SqlExecutor txn) action) async {
    await begin();
    try {
      final result = await action(this);
      await commit();
      return result;
    } catch (_) {
      try {
        await rollback();
      } catch (_) {
        // The original failure is the interesting one.
      }
      rethrow;
    }
  }
}

/// The `dart:ffi` backend. Wraps the synchronous [SqlDatabase] in the async seam so the
/// repositories can expose `Future` APIs (`API-03`) without the engine becoming async.
///
/// `extends` (not `implements`) on purpose: `transaction`, `userVersion` and `setUserVersion`
/// are concrete and are shared by every backend, so they must be inherited rather than copied.
class FfiSqlExecutor extends SqlExecutor {
  FfiSqlExecutor(this.db);

  final SqlDatabase db;

  @override
  Future<int> execute(String sql, [List<Object?>? args]) async =>
      db.executeSync(sql, args);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) async =>
      db.querySync(sql, args);

  @override
  Future<void> begin() async => db.executeSync('BEGIN IMMEDIATE');

  @override
  Future<void> commit() async => db.executeSync('COMMIT');

  @override
  Future<void> rollback() async => db.executeSync('ROLLBACK');

  @override
  Future<void> close() async => db.close();
}

// --------------------------------------------------------------------------- ffi glue

typedef _OpenV2Native = Int32 Function(
    Pointer<Char>, Pointer<Pointer<Void>>, Int32, Pointer<Void>);
typedef _OpenV2Dart = int Function(
    Pointer<Char>, Pointer<Pointer<Void>>, int, Pointer<Void>);

typedef _PrepareNative = Int32 Function(
    Pointer<Void>, Pointer<Char>, Int32, Pointer<Pointer<Void>>, Pointer<Void>);
typedef _PrepareDart = int Function(
    Pointer<Void>, Pointer<Char>, int, Pointer<Pointer<Void>>, Pointer<Void>);

typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);

typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);

typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);

typedef _ErrmsgNative = Pointer<Char> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Char> Function(Pointer<Void>);

typedef _ChangesNative = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);

typedef _BindIntNative = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindIntDart = int Function(Pointer<Void>, int, int);

typedef _BindDoubleNative = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);

typedef _BindTextNative = Int32 Function(
    Pointer<Void>, Int32, Pointer<Char>, Int32, Pointer<Void>);
typedef _BindTextDart = int Function(
    Pointer<Void>, int, Pointer<Char>, int, Pointer<Void>);

typedef _BindNullNative = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);

typedef _ColumnCountNative = Int32 Function(Pointer<Void>);
typedef _ColumnCountDart = int Function(Pointer<Void>);

typedef _ColumnNameNative = Pointer<Char> Function(Pointer<Void>, Int32);
typedef _ColumnNameDart = Pointer<Char> Function(Pointer<Void>, int);

typedef _ColumnTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColumnTypeDart = int Function(Pointer<Void>, int);

typedef _ColumnIntNative = Int64 Function(Pointer<Void>, Int32);
typedef _ColumnIntDart = int Function(Pointer<Void>, int);

typedef _ColumnDoubleNative = Double Function(Pointer<Void>, Int32);
typedef _ColumnDoubleDart = double Function(Pointer<Void>, int);

typedef _ColumnTextNative = Pointer<Char> Function(Pointer<Void>, Int32);
typedef _ColumnTextDart = Pointer<Char> Function(Pointer<Void>, int);

/// Resolved SQLite entry points.
class _SqliteLib {
  _SqliteLib._(this._lib)
      : openV2 = _lib.lookupFunction<_OpenV2Native, _OpenV2Dart>('sqlite3_open_v2'),
        prepareV2 =
            _lib.lookupFunction<_PrepareNative, _PrepareDart>('sqlite3_prepare_v2'),
        step = _lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step'),
        finalize = _lib.lookupFunction<_FinalizeNative, _FinalizeDart>('sqlite3_finalize'),
        close = _lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close_v2'),
        errmsg = _lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg'),
        changes = _lib.lookupFunction<_ChangesNative, _ChangesDart>('sqlite3_changes'),
        bindInt64 = _lib.lookupFunction<_BindIntNative, _BindIntDart>('sqlite3_bind_int64'),
        bindDouble =
            _lib.lookupFunction<_BindDoubleNative, _BindDoubleDart>('sqlite3_bind_double'),
        bindText = _lib.lookupFunction<_BindTextNative, _BindTextDart>('sqlite3_bind_text'),
        bindNull = _lib.lookupFunction<_BindNullNative, _BindNullDart>('sqlite3_bind_null'),
        columnCount =
            _lib.lookupFunction<_ColumnCountNative, _ColumnCountDart>('sqlite3_column_count'),
        columnName =
            _lib.lookupFunction<_ColumnNameNative, _ColumnNameDart>('sqlite3_column_name'),
        columnType =
            _lib.lookupFunction<_ColumnTypeNative, _ColumnTypeDart>('sqlite3_column_type'),
        columnInt64 =
            _lib.lookupFunction<_ColumnIntNative, _ColumnIntDart>('sqlite3_column_int64'),
        columnDouble = _lib
            .lookupFunction<_ColumnDoubleNative, _ColumnDoubleDart>('sqlite3_column_double'),
        columnText =
            _lib.lookupFunction<_ColumnTextNative, _ColumnTextDart>('sqlite3_column_text');

  final DynamicLibrary _lib;
  final _OpenV2Dart openV2;
  final _PrepareDart prepareV2;
  final _StepDart step;
  final _FinalizeDart finalize;
  final _CloseDart close;
  final _ErrmsgDart errmsg;
  final _ChangesDart changes;
  final _BindIntDart bindInt64;
  final _BindDoubleDart bindDouble;
  final _BindTextDart bindText;
  final _BindNullDart bindNull;
  final _ColumnCountDart columnCount;
  final _ColumnNameDart columnName;
  final _ColumnTypeDart columnType;
  final _ColumnIntDart columnInt64;
  final _ColumnDoubleDart columnDouble;
  final _ColumnTextDart columnText;

  static _SqliteLib? _cached;

  /// Tries every plausible engine location and reports all failures at once.
  static _SqliteLib load() {
    final cached = _cached;
    if (cached != null) return cached;

    final candidates = <String>[
      if (Platform.environment['ACOUDIET_SQLITE'] != null)
        Platform.environment['ACOUDIET_SQLITE']!,
      if (Platform.isAndroid) 'libsqlite.so',
      if (Platform.isAndroid) 'libsqlite3.so',
      if (Platform.isWindows) 'sqlite3.dll',
      if (Platform.isLinux) 'libsqlite3.so',
      if (Platform.isMacOS) 'libsqlite3.dylib',
      if (Platform.isWindows) r'D:\Anaconda\DLLs\sqlite3.dll',
      if (Platform.isWindows) r'C:\Program Files\Anaconda3\DLLs\sqlite3.dll',
    ];

    final errors = <String>[];
    for (final c in candidates) {
      try {
        final lib = _SqliteLib._(DynamicLibrary.open(c));
        _cached = lib;
        return lib;
      } catch (e) {
        errors.add('$c: $e');
      }
    }
    throw AcouDietError(
      Codes.dbMigration,
      'no SQLite engine available; set ACOUDIET_SQLITE to a sqlite3 library path',
      detail: {'tried': errors.join(' | ')},
    );
  }
}

/// UTF-8 helpers plus the native allocator, implemented over `dart:ffi` alone.
///
/// `package:ffi` would be the idiomatic choice, but the offline build cannot resolve any
/// package, so the two things it is used for here -- `malloc`/`free` and
/// `Pointer<Char>.toDartString()` -- are reimplemented directly against the C runtime.
class _CString {
  static Pointer<Char> toNative(String s) {
    final units = s.codeUnits;
    final buf = _Alloc.alloc<Uint8>(units.length * 3 + 1);
    var len = 0;
    for (final unit in units) {
      if (unit < 0x80) {
        buf[len++] = unit;
      } else if (unit < 0x800) {
        buf[len++] = 0xC0 | (unit >> 6);
        buf[len++] = 0x80 | (unit & 0x3F);
      } else {
        buf[len++] = 0xE0 | (unit >> 12);
        buf[len++] = 0x80 | ((unit >> 6) & 0x3F);
        buf[len++] = 0x80 | (unit & 0x3F);
      }
    }
    buf[len] = 0;
    return buf.cast<Char>();
  }

  static void free(Pointer<Char> p) => _Alloc.free(p);

  /// Decodes a NUL-terminated UTF-8 string.
  static String fromNative(Pointer<Char> p) {
    final bytes = p.cast<Uint8>();
    final units = <int>[];
    var i = 0;
    while (true) {
      final b0 = bytes[i];
      if (b0 == 0) break;
      if (b0 < 0x80) {
        units.add(b0);
        i += 1;
      } else if ((b0 & 0xE0) == 0xC0) {
        units.add(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
        i += 2;
      } else {
        units.add(((b0 & 0x0F) << 12) |
            ((bytes[i + 1] & 0x3F) << 6) |
            (bytes[i + 2] & 0x3F));
        i += 3;
      }
    }
    return String.fromCharCodes(units);
  }
}

/// Native heap allocation via the C runtime (`malloc`/`free`).
class _Alloc {
  static DynamicLibrary? _crt;
  static Pointer<NativeFunction<_MallocNative>>? _malloc;
  static Pointer<NativeFunction<_FreeNative>>? _free;

  static void _ensure() {
    if (_malloc != null) return;
    DynamicLibrary lib;
    if (Platform.isWindows) {
      // The UCRT is always present on Windows 10+; msvcrt is the fallback.
      try {
        lib = DynamicLibrary.open('ucrtbase.dll');
      } catch (_) {
        lib = DynamicLibrary.open('msvcrt.dll');
      }
    } else {
      lib = DynamicLibrary.process();
    }
    _crt = lib;
    _malloc = lib.lookup<NativeFunction<_MallocNative>>('malloc');
    _free = lib.lookup<NativeFunction<_FreeNative>>('free');
  }

  static Pointer<T> alloc<T extends NativeType>(int bytes, {bool zero = false}) {
    _ensure();
    final fn = _malloc!.asFunction<_MallocDart>();
    final p = fn(bytes);
    if (p == nullptr) {
      throw StateError('native allocation of $bytes bytes failed');
    }
    if (zero) {
      p.cast<Uint8>().asTypedList(bytes).fillRange(0, bytes, 0);
    }
    return p.cast<T>();
  }

  static void free(Pointer<NativeType> p) {
    _ensure();
    _free!.asFunction<_FreeDart>()(p.cast<Void>());
  }
}

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// `SQLITE_TRANSIENT` is the C macro `((sqlite3_destructor_type)-1)`, i.e. the address -1.
final Pointer<Void> _transient = Pointer<Void>.fromAddress(-1);

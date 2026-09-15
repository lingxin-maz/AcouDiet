// app/test/data/channel_sqlite_test.dart
//
// The Android SQLite channel, tested on the **Dart side of the wire** against a mock messenger.
//
// WHY THIS TEST EXISTS
// --------------------
// `MethodChannelSqlExecutor` exists because Android cannot open SQLite over `dart:ffi` at all (see the
// class docs). Its correctness therefore depends on a protocol shared with Kotlin, and the
// failure mode if the two sides disagree is nasty: the app falls back to the in-memory
// repositories and **silently stops persisting** -- which is exactly the defect this whole path
// was written to fix.
//
// The Kotlin half is checked statically by `tool/check_bridge_symmetry.py`. This file checks the
// Dart half for real: method names, argument shapes, result parsing and error mapping.

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/errors.dart';
import '../../lib/data/native/method_channel_sqlite.dart';
import '../../lib/data/db/sqlite_ffi.dart';

/// Records every call so the test can assert on the *wire*, not just the outcome.
class _FakeEngine {
  final List<MethodCall> calls = <MethodCall>[];
  final Map<int, String> paths = <int, String>{};
  final Map<int, List<String>> executed = <int, List<String>>{};
  int nextHandle = 1;
  bool inTransaction = false;

  /// Rows returned by the next `query`, keyed by the sql text.
  final Map<String, List<Map<String, Object?>>> rows = <String, List<Map<String, Object?>>>{};
  PlatformException? failWith;
  /// A non-`PlatformException` failure (e.g. `MissingPluginException`) to throw instead.
  Object? failWithOther;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final other = failWithOther;
    if (other != null) {
      failWithOther = null;
      throw other;
    }
    final f = failWith;
    if (f != null) {
      failWith = null;
      throw f;
    }
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    switch (call.method) {
      case 'open':
        final h = nextHandle++;
        paths[h] = args['path'] as String;
        return <String, Object?>{'handle': h, 'path': paths[h]};
      case 'execute':
        final h = args['handle'] as int;
        executed.putIfAbsent(h, () => <String>[]).add(args['sql'] as String);
        return <String, Object?>{'changes': 1};
      case 'query':
        return <String, Object?>{
          'rows': rows[args['sql'] as String] ?? const <Map<String, Object?>>[],
        };
      case 'begin':
        inTransaction = true;
        return <String, Object?>{};
      case 'commit':
        inTransaction = false;
        return <String, Object?>{};
      case 'rollback':
        inTransaction = false;
        return <String, Object?>{};
      case 'close':
        paths.remove(args['handle'] as int);
        return <String, Object?>{};
      default:
        throw PlatformException(code: 'MISSING', message: call.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;
  const codec = StandardMethodCodec();

  setUp(() {
    engine = _FakeEngine();
    MethodChannelSqlExecutor.channel = MethodChannel(MethodChannelSqlExecutor.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelSqlExecutor.channel, (call) async {
      final result = await engine.handle(call);
      return result;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelSqlExecutor.channel, null);
    MethodChannelSqlExecutor.channel = MethodChannel(MethodChannelSqlExecutor.channelName);
  });

  group('the channel name is the one Kotlin registers', () {
    test('channelName matches MainActivity / SqliteChannelHostAndroid.CHANNEL', () {
      expect(MethodChannelSqlExecutor.channelName, 'com.acoudiet.app/sqlite');
    });

    test('every method sent is one the Kotlin handler implements', () async {
      final exec = await MethodChannelSqlExecutor.open('/data/x/acoudiet.db');
      await exec.execute('INSERT INTO t VALUES (?)', [1]);
      await exec.query('SELECT 1');
      await exec.transaction((_) async => 0);
      await exec.close();
      final sent = engine.calls.map((c) => c.method).toSet();
      expect(
        sent,
        containsAll(<String>['open', 'execute', 'query', 'begin', 'commit', 'close']),
      );
      // Nothing invented: the Kotlin `when` has no `else` branch that would silently accept these.
      expect(
        sent.difference(<String>{
          'open', 'execute', 'query', 'begin', 'commit', 'rollback', 'close',
        }),
        isEmpty,
      );
    });
  });

  group('open', () {
    test('returns a handle and enables foreign keys', () async {
      final exec = await MethodChannelSqlExecutor.open('/data/x/acoudiet.db');
      expect(engine.paths.values, contains('/data/x/acoudiet.db'));
      // The pragma the schema relies on must be issued on both backends.
      expect(engine.executed.values.expand((e) => e), contains('PRAGMA foreign_keys = ON'));
      expect(exec.path, '/data/x/acoudiet.db');
    });

    test('a missing handle is a reported failure, never a silent success', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannelSqlExecutor.channel, (call) async => <String, Object?>{});
      await expectLater(
        MethodChannelSqlExecutor.open('/x.db'),
        throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.dbMigration)),
      );
    });
  });

  group('execute', () {
    test('args travel as a list and changes come back', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      final n = await exec.execute('INSERT INTO t (a, b) VALUES (?, ?)', ['s', 7]);
      expect(n, 1);
      final call = engine.calls.last;
      expect(call.method, 'execute');
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['sql'], 'INSERT INTO t (a, b) VALUES (?, ?)');
      expect(args['args'], ['s', 7]);
      expect(args['handle'], isA<int>());
    });

    test('a BLOB argument is refused before it reaches the wire (I-2)', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      final before = engine.calls.length;
      await expectLater(
        exec.execute('INSERT INTO t VALUES (?)', [Uint8List.fromList([1, 2, 3])]),
        throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.dbInvalidArgument)),
      );
      // Nothing was sent: the refusal is local, exactly like the FFI binder's.
      expect(engine.calls.length, before);
    });
  });

  group('query', () {
    test('rows come back as column-keyed maps', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      engine.rows['SELECT a, b FROM t'] = [
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': null},
      ];
      final rows = await exec.query('SELECT a, b FROM t');
      expect(rows, hasLength(2));
      expect(rows.first['a'], 1);
      expect(rows.first['b'], 'x');
      expect(rows[1]['b'], isNull);
    });

    test('a non-list result degrades to no rows rather than throwing mid-screen', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannelSqlExecutor.channel, (call) async {
        if (call.method == 'query') return <String, Object?>{'rows': 'nonsense'};
        return engine.handle(call);
      });
      expect(await exec.query('SELECT 1'), isEmpty);
    });
  });

  group('transactions ride Android bookkeeping, not SQL', () {
    test('transaction() issues begin/commit and no BEGIN statement', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      await exec.transaction((txn) async => txn.execute('INSERT INTO t VALUES (1)'));
      final methods = engine.calls.map((c) => c.method).toList();
      expect(methods, containsAllInOrder(<String>['begin', 'execute', 'commit']));
      expect(methods, isNot(contains('rollback')));
      final sql = engine.executed.values.expand((e) => e).join(' ');
      expect(sql.toUpperCase(), isNot(contains('BEGIN')));
      expect(sql.toUpperCase(), isNot(contains('COMMIT')));
    });

    test('a throwing action rolls back and the error propagates', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      await expectLater(
        exec.transaction((_) async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      final methods = engine.calls.map((c) => c.method).toList();
      expect(methods, containsAllInOrder(<String>['begin', 'rollback']));
      expect(methods, isNot(contains('commit')));
      expect(engine.inTransaction, isFalse);
    });
  });

  group('failures map to API-00 codes at this single point', () {
    test('a PlatformException becomes an AcouDietError with its code', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      engine.failWith = PlatformException(
        code: Codes.dbTransaction,
        message: 'SQLiteConstraintException: UNIQUE constraint failed: diet_record.record_id',
      );
      await expectLater(
        exec.execute('INSERT INTO diet_record VALUES (?)', ['r1']),
        throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.dbTransaction)),
      );
    });

    test('the engine text is preserved so the UNIQUE mapping still works', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      engine.failWith = PlatformException(
        code: Codes.dbTransaction,
        message: 'SQLiteConstraintException: UNIQUE constraint failed: diet_record.record_id',
      );
      try {
        await exec.execute('INSERT INTO diet_record VALUES (?)', ['r1']);
        fail('expected a throw');
      } on AcouDietError catch (e) {
        // sql_repos.dart maps ACD-DB-002 by looking for this substring; losing it would turn a
        // duplicate-key caller error into a generic "save failed".
        expect('${e.message}', contains('UNIQUE'));
      }
    });

    test('a missing plugin is reported, never treated as an empty database', () async {
      final exec = await MethodChannelSqlExecutor.open('/x.db');
      engine.failWithOther = MissingPluginException('no implementation found');
      await expectLater(
        exec.query('SELECT 1'),
        throwsA(isA<AcouDietError>().having((e) => e.code, 'code', Codes.dbMigration)),
      );
    });
  });
}

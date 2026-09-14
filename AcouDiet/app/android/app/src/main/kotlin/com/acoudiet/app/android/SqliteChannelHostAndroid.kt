package com.acoudiet.app.android

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.acoudiet.app.audio.AcouDietException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Flutter platform-channel host for the SQLite contract (`API-01` addition).
 *
 * WHY THIS EXISTS
 * ---------------
 * Dart cannot reach SQLite on Android over `dart:ffi`:
 *
 *  * `libsqlite3.so` does not exist on Android;
 *  * `libsqlite.so` exists under `/system/lib64`, but it is **not** in
 *    `/system/etc/public.libraries.txt`, and Android 7's linker namespace isolation refuses to
 *    resolve a non-public library for an app;
 *  * the APK bundles no SQLite of its own.
 *
 * The measured effect was that `SqliteFfi.load()` always threw, the app degraded to its
 * in-memory repositories, and **nothing was ever persisted on device**. This host provides the
 * engine that is actually there -- the platform's own `android.database.sqlite`.
 *
 * PROTOCOL
 * --------
 * One channel, seven methods, every one taking a `Map` and returning a `Map` (never a bare
 * scalar), which is the same convention the audio channel uses. Handles are ints; the
 * connection objects stay here.
 *
 * | method     | arguments              | result                    |
 * |------------|------------------------|---------------------------|
 * | `open`     | `{path}`               | `{handle, path}`          |
 * | `execute`  | `{handle, sql, args}`  | `{changes}`               |
 * | `query`    | `{handle, sql, args}`  | `{rows: [{col: value}]}`  |
 * | `begin`    | `{handle}`             | `{}`                      |
 * | `commit`   | `{handle}`             | `{}`                      |
 * | `rollback` | `{handle}`             | `{}`                      |
 * | `close`    | `{handle}`             | `{}`                      |
 *
 * Transactions go through Android's own bookkeeping (`beginTransaction` /
 * `setTransactionSuccessful` / `endTransaction`) rather than by sending `BEGIN`/`COMMIT` as
 * SQL, because `SQLiteDatabase` maintains its own transaction state and would desynchronise.
 * That keeps invariant I-3 (a failed write leaves nothing behind) real on this engine.
 */
class SqliteChannelHostAndroid : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.acoudiet.app/sqlite"

        /** Value used when a cursor cell is SQL NULL. */
        private val NULL_MARKER: Any? = null
    }

    private val nextHandle = AtomicInteger(1)
    private val connections = HashMap<Int, SQLiteDatabase>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> result.success(open(call))
                "execute" -> result.success(execute(call))
                "query" -> result.success(query(call))
                "begin" -> {
                    database(call).beginTransaction()
                    result.success(emptyMap<String, Any?>())
                }
                "commit" -> {
                    val db = database(call)
                    db.setTransactionSuccessful()
                    db.endTransaction()
                    result.success(emptyMap<String, Any?>())
                }
                "rollback" -> {
                    // `endTransaction` without `setTransactionSuccessful` is the rollback path.
                    database(call).endTransaction()
                    result.success(emptyMap<String, Any?>())
                }
                "close" -> result.success(close(call))
                else -> result.notImplemented()
            }
        } catch (e: AcouDietException) {
            result.error(e.code, e.message, e.detail)
        } catch (t: Throwable) {
            result.error("ACD-DB-003", t.message ?: "sqlite channel error", null)
        }
    }

    // ------------------------------------------------------------------ methods

    private fun open(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("path")
            ?: throw AcouDietException.dbInvalidArgument("open requires a path")
        val db = try {
            SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.CREATE_IF_NECESSARY)
        } catch (t: Throwable) {
            throw AcouDietException.dbOpenFailed("$path: ${t.message}")
        }
        val handle = nextHandle.getAndIncrement()
        connections[handle] = db
        return linkedMapOf("handle" to handle, "path" to path)
    }

    private fun execute(call: MethodCall): Map<String, Any?> {
        val db = database(call)
        val sql = call.argument<String>("sql")
            ?: throw AcouDietException.dbInvalidArgument("execute requires sql")
        val args = bindArgs(call)
        try {
            db.execSQL(sql, args)
        } catch (t: Throwable) {
            throw statementFailure(sql, t)
        }
        return linkedMapOf("changes" to changes(db))
    }

    private fun query(call: MethodCall): Map<String, Any?> {
        val db = database(call)
        val sql = call.argument<String>("sql")
            ?: throw AcouDietException.dbInvalidArgument("query requires sql")
        // `SQLiteDatabase.rawQuery` accepts only `String[]` selection args. SQLite applies the
        // *column's* affinity to the comparison operand, so numeric columns still compare
        // numerically against a text-bound parameter; the alternative (leaving the host to
        // build SQL by hand) would be worse for injection safety.
        val selectionArgs = bindArgs(call).map { it?.toString() }.toTypedArray()
        val rows = ArrayList<Map<String, Any?>>()
        try {
            db.rawQuery(sql, selectionArgs).use { cursor ->
                val names = cursor.columnNames
                while (cursor.moveToNext()) {
                    val row = LinkedHashMap<String, Any?>(names.size)
                    for (i in names.indices) {
                        row[names[i]] = readCell(cursor, i)
                    }
                    rows.add(row)
                }
            }
        } catch (t: Throwable) {
            throw statementFailure(sql, t)
        }
        return linkedMapOf("rows" to rows)
    }

    private fun close(call: MethodCall): Map<String, Any?> {
        val handle = handleOf(call)
        connections.remove(handle)?.close()
        return emptyMap()
    }

    // ------------------------------------------------------------------ helpers

    private fun database(call: MethodCall): SQLiteDatabase {
        val handle = handleOf(call)
        return connections[handle]
            ?: throw AcouDietException.dbInvalidArgument("no open database for handle $handle")
    }

    private fun handleOf(call: MethodCall): Int =
        call.argument<Number>("handle")?.toInt()
            ?: throw AcouDietException.dbInvalidArgument("${call.method} requires a handle")

    @Suppress("UNCHECKED_CAST")
    private fun bindArgs(call: MethodCall): Array<Any?> {
        val raw = call.arguments as? Map<String, Any?> ?: return emptyArray()
        val list = raw["args"] as? List<Any?> ?: return emptyArray()
        return list.toTypedArray()
    }

    /**
     * `sqlite3_changes()` for the statement just run -- the same value the FFI backend returns
     * from `lib.changes(db)`.
     */
    private fun changes(db: SQLiteDatabase): Long =
        db.rawQuery("SELECT changes()", null).use { c ->
            if (c.moveToFirst()) c.getLong(0) else 0L
        }

    /**
     * Mirrors the FFI backend's error shape: the engine's own text is **preserved**, because
     * `sql_repos.dart` maps a duplicate key to `ACD-DB-002` by looking for `UNIQUE` /
     * `PRIMARY KEY` in it. Replacing this with friendly copy would silently break that mapping.
     */
    private fun statementFailure(sql: String, t: Throwable): AcouDietException {
        val text = "${t.javaClass.simpleName}: ${t.message}"
        return AcouDietException.dbStatementFailed("$text [sql: ${sql.take(120)}]")
    }

    private fun readCell(cursor: Cursor, index: Int): Any? = when (cursor.getType(index)) {
        Cursor.FIELD_TYPE_NULL -> NULL_MARKER
        Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
        Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index)
        Cursor.FIELD_TYPE_STRING -> cursor.getString(index)
        // Invariant I-2 is a schema property; if a BLOB ever appears, fail loudly rather than
        // handing bytes to a layer whose contract says they cannot exist.
        Cursor.FIELD_TYPE_BLOB -> throw AcouDietException.dbInvalidArgument(
            "unexpected BLOB value in column ${cursor.getColumnName(index)}",
        )
        else -> null
    }
}

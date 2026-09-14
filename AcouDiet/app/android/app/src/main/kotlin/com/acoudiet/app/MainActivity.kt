package com.acoudiet.app

import com.acoudiet.app.android.AudioBridgeAndroid
import com.acoudiet.app.android.AudioChannelHostAndroid
import com.acoudiet.app.android.SqliteChannelHostAndroid
import com.acoudiet.app.android.TempAudioAndroid
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter host activity: wires the three platform channels and nothing else.
 *
 *  * `com.acoudiet.app/audio`        -- `API-01` control plane
 *  * `com.acoudiet.app/audio_stream` -- `API-01` event stream
 *  * `com.acoudiet.app/sqlite`       -- the on-device database engine (see
 *    [SqliteChannelHostAndroid] for why Android cannot use the `dart:ffi` backend)
 *
 * No background Service exists on purpose (FF-24 item 6: detection is always user-initiated),
 * which is also why this class has no `onStart`/`onResume` audio logic.
 */
class MainActivity : FlutterActivity() {

    private var host: AudioChannelHostAndroid? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = AudioBridgeAndroid(applicationContext)
        val h = AudioChannelHostAndroid(this, bridge)
        host = h

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AudioChannelHostAndroid.METHOD_CHANNEL)
            .setMethodCallHandler(h)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AudioChannelHostAndroid.EVENT_CHANNEL)
            .setStreamHandler(h)

        // The SQLite engine: Android's own `android.database.sqlite`. `dart:ffi` cannot reach
        // SQLite on Android (see SqliteChannelHostAndroid), so this channel is what makes the
        // local database exist at all on a device.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SqliteChannelHostAndroid.CHANNEL)
            .setMethodCallHandler(SqliteChannelHostAndroid())

        // FF-24 item 2: clear `audio_*` leftovers once at cold start. Never blocks start-up.
        Thread {
            try {
                TempAudioAndroid(applicationContext).clear()
            } catch (_: Throwable) {
                // ACD-IO-001 semantics: log only.
            }
        }.start()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        host?.onPermissionResult(requestCode, grantResults)
    }
}

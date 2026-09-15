package com.acoudiet.app.android

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import com.acoudiet.app.audio.AcouDietException
import com.acoudiet.app.config.NativeCapabilities
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter platform-channel host for `API-01`.
 *
 * Channels:
 *  * `com.acoudiet.app/audio`        -- MethodChannel, Dart -> Kotlin (control plane)
 *  * `com.acoudiet.app/audio_stream` -- EventChannel, Kotlin -> Dart (level/patch/ended)
 *
 * Every method returns a `Map<String, Object?>` (never a bare scalar) and reports failures
 * through `result.error(code, message, detail)` so the Dart side sees a `PlatformException`
 * carrying an `API-00` section 3.5 code.
 */
class AudioChannelHostAndroid(
    private val activity: Activity,
    private val bridge: AudioBridgeAndroid,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.acoudiet.app/audio"
        const val EVENT_CHANNEL = "com.acoudiet.app/audio_stream"
        private const val PERMISSION_REQUEST_CODE = 4101
        private const val PREFS = "acoudiet"
        private const val KEY_ASKED = "permissionAsked"
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // API-01 section 2.1: must never fail.
                "getCapabilities" -> result.success(NativeCapabilities.asMap())

                "requestPermission" -> requestPermission(result)

                "startSession" -> result.success(bridge.startSession(call.argumentsMap()))
                "pauseSession" -> result.success(bridge.pauseSession(call.argumentsMap()))
                "resumeSession" -> result.success(bridge.resumeSession(call.argumentsMap()))
                "stopSession" -> result.success(bridge.stopSession(call.argumentsMap()))
                "injectPcm" -> result.success(bridge.injectPcm(call.argumentsMap()))
                "ackPatch" -> result.success(bridge.ackPatch(call.argumentsMap()))
                "setDiagnosticsModelInfo" ->
                    result.success(bridge.setDiagnosticsModelInfo(call.argumentsMap()))

                "getDiagnostics" -> result.success(bridge.getDiagnostics())
                "getEnvelopeCapability" -> result.success(bridge.getEnvelopeCapability())

                "clearTempAudio" -> result.success(TempAudioAndroid(activity).clearDetailed())

                // `Context.getFilesDir()`: the app's private, non-cache directory. The SQLite
                // database lives here because `Directory.systemTemp` on Android maps to the
                // cache directory, which the OS may clear at any time -- unacceptable for an
                // app whose value is locally accumulated history with no cloud backup.
                "getStorageDir" -> result.success(
                    linkedMapOf("path" to activity.filesDir.absolutePath),
                )

                else -> result.notImplemented()
            }
        } catch (e: AcouDietException) {
            result.error(e.code, e.message, e.detail)
        } catch (t: Throwable) {
            result.error("ACD-UNK-000", t.message ?: "unexpected native error", null)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun MethodCall.argumentsMap(): Map<String, Any?> =
        (arguments as? Map<String, Any?>) ?: emptyMap()

    // ------------------------------------------------------------------ permission

    private fun requestPermission(result: MethodChannel.Result) {
        if (bridge.hasRecordPermission()) {
            result.success(linkedMapOf("granted" to true, "permanentlyDenied" to false))
            return
        }
        val permanentlyDenied = !ActivityCompat.shouldShowRequestPermissionRationale(
            activity, android.Manifest.permission.RECORD_AUDIO,
        ) && hasAskedBefore()

        if (permanentlyDenied) {
            result.success(linkedMapOf("granted" to false, "permanentlyDenied" to true))
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST_CODE,
        )
    }

    private fun hasAskedBefore(): Boolean =
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false)

    /** Called by the host activity from `onRequestPermissionsResult`. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ASKED, true).apply()
        val permanentlyDenied = !granted && !ActivityCompat.shouldShowRequestPermissionRationale(
            activity, android.Manifest.permission.RECORD_AUDIO,
        )
        pendingPermissionResult?.success(
            linkedMapOf("granted" to granted, "permanentlyDenied" to permanentlyDenied),
        )
        pendingPermissionResult = null
        return true
    }

    // ------------------------------------------------------------------ event stream

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        bridge.setSubscription(args?.get("sessionId") as? String)
        bridge.attachSink { payload ->
            try {
                events?.success(payload)
            } catch (_: Throwable) {
                // The Dart side went away mid-flight; onCancel will clean up.
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        // API-01 section 3.1: stop emitting and release references. The session itself is
        // NOT ended here -- that requires an explicit stopSession. The session id is passed
        // through so a late cancel of a *previous* stream cannot silence the live one.
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        bridge.clearSubscription(args?.get("sessionId") as? String)
    }
}

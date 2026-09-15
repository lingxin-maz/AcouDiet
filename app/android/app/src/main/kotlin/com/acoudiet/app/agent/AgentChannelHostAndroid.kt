package com.acoudiet.app.agent

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter platform-channel host for the platform handoff contract (`API-07` section 3, `FF-26i`).
 *
 * Channel: `acoudiet/agent` (MethodChannel, Dart -> Kotlin).
 *
 *  * `canOpenUrl` -> `{url: String}` -> `Boolean`: may this device open the URL at all?
 *  * `openUrl`    -> `{url: String}` -> `Boolean`: did the handoff actually start?
 *
 * `FF-26i` permits a **handoff only**: this host launches a search result URL in whichever app
 * declares it and the user finishes the order inside that app. There is deliberately no
 * accessibility service, no simulated tap and no proxy ordering anywhere in this project.
 *
 * Both methods return a plain `Boolean` and NEVER throw: "the target app is not installed" is an
 * ordinary answer the UI renders as a disabled button, not an app crash. `canOpenUrl` is also
 * what makes a platform button honest on Android 11+, where package visibility hides other apps
 * unless the manifest declares the matching `<queries>` intent (see `src/agent/AndroidManifest.xml`).
 */
class AgentChannelHostAndroid private constructor(
    private val appContext: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "acoudiet/agent"

        /**
         * Builds the host the same way [AudioChannelHostAndroid] is built from [MainActivity]:
         * the caller passes its Activity. The launch context that is kept is the application
         * Context, so a rotation cannot leave the channel holding a destroyed Activity, which is
         * also why `openUrl` adds `FLAG_ACTIVITY_NEW_TASK` when the context is not an Activity.
         */
        fun attach(owner: Activity): AgentChannelHostAndroid =
            AgentChannelHostAndroid(owner.applicationContext)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any?>
        val url = args?.get("url") as? String
        if (url.isNullOrBlank()) {
            // A missing or unusable URL is answered, never thrown (`API-07` section 3.2).
            result.success(false)
            return
        }
        when (call.method) {
            "canOpenUrl" -> result.success(canOpenUrl(url))
            "openUrl" -> result.success(openUrl(url))
            else -> result.notImplemented()
        }
    }

    /**
     * `PackageManager.resolveActivity` with `MATCH_DEFAULT_ONLY`: exactly the query Android 11+
     * gates behind `<queries>`. Any failure (malformed URL, restricted profile, platform refusal)
     * is reported as `false` rather than propagated.
     */
    private fun canOpenUrl(url: String): Boolean {
        return try {
            val pm = appContext.packageManager
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * `Intent(ACTION_VIEW, url)` handed to the platform. `FLAG_ACTIVITY_NEW_TASK` is required
     * when the context is not an Activity. Returns `false` instead of throwing
     * `ActivityNotFoundException` when no installed app accepts the URL.
     */
    private fun openUrl(url: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        if (appContext !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            appContext.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            // FF-26i: the platform app simply is not installed, so the handoff did not happen.
            false
        } catch (_: Throwable) {
            // A malformed URL or an OS level refusal must not crash the UI thread either.
            false
        }
    }
}

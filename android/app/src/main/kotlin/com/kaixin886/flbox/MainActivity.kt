package com.kaixin886.flbox

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Holds the channel so the VpnService (a separate component) can
// report the established TUN fd back to Dart.
object VpnBridge {
    var channel: MethodChannel? = null
}

class MainActivity : FlutterActivity() {
    private var pendingPrepare: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flbox/vpn")
        VpnBridge.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success("granted")
                    } else {
                        pendingPrepare = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQUEST_VPN)
                    }
                }
                "startVpn" -> {
                    val bypass = call.argument<List<String>>("bypass") ?: emptyList()
                    startService(
                        Intent(this, FlboxVpnService::class.java)
                            .setAction(FlboxVpnService.ACTION_START)
                            .putStringArrayListExtra(
                                FlboxVpnService.EXTRA_BYPASS,
                                ArrayList(bypass)
                            )
                    )
                    result.success(null)
                }
                "stopVpn" -> {
                    startService(
                        Intent(this, FlboxVpnService::class.java)
                            .setAction(FlboxVpnService.ACTION_STOP)
                    )
                    result.success(null)
                }
                "startCoreService" -> {
                    startService(
                        Intent(this, FlboxCoreService::class.java)
                            .setAction(FlboxCoreService.ACTION_START)
                    )
                    result.success(null)
                }
                "stopCoreService" -> {
                    startService(
                        Intent(this, FlboxCoreService::class.java)
                            .setAction(FlboxCoreService.ACTION_STOP)
                    )
                    result.success(null)
                }
                "listApps" -> {
                    result.success(listLaunchableApps())
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Apps the user can pick in the per-app bypass list. */
    private fun listLaunchableApps(): List<Map<String, String>> {
        val pm = packageManager
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val infos = pm.queryIntentActivities(query, 0)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, String>>()
        for (info in infos) {
            val appInfo = info.activityInfo.applicationInfo
            if (!seen.add(appInfo.packageName)) continue
            apps.add(
                mapOf(
                    "pkg" to appInfo.packageName,
                    "label" to pm.getApplicationLabel(appInfo).toString()
                )
            )
        }
        return apps.sortedBy { it["label"]?.lowercase() ?: "" }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(
                if (resultCode == Activity.RESULT_OK) "granted" else "denied"
            )
            pendingPrepare = null
        }
    }

    companion object {
        private const val REQUEST_VPN = 4242
    }
}

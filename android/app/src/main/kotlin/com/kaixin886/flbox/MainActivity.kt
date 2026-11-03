package com.kaixin886.flbox

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
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
                "appSettings" -> {
                    // Deep-link to this app's system info page, where the
                    // per-app "allow network access" switch lives on ROMs
                    // that enforce one (a REJECT_ALL uid policy otherwise
                    // silently kills all of the app's traffic).
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(intent)
                    result.success(null)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        @Suppress("DEPRECATION")
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQUEST_NOTIFICATIONS
                        )
                    }
                    result.success(null)
                }
                "batteryState" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "openBatterySettings" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                        )
                    } catch (e: Exception) {
                        startActivity(
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        )
                    }
                    result.success(null)
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
        private const val REQUEST_NOTIFICATIONS = 4243
    }
}

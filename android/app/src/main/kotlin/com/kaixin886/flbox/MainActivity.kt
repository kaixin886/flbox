package com.kaixin886.flbox

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
                    // Backstop: if the service has not stopped
                    // itself shortly after (lost intent, ROM
                    // quirk), stopService makes the system tear
                    // it down and onDestroy closes the tunnel.
                    // A no-op when it already stopped.
                    Handler(Looper.getMainLooper()).postDelayed({
                        stopService(Intent(this, FlboxVpnService::class.java))
                    }, 600)
                    result.success(null)
                }
                "startCoreService" -> {
                    startService(
                        Intent(this, FlboxCoreService::class.java)
                            .setAction(FlboxCoreService.ACTION_START)
                    )
                    result.success(null)
                }
                "vpnActive" -> {
                    result.success(FlboxVpnService.active)
                }
                "vpnServiceAlive" -> {
                    result.success(FlboxVpnService.alive)
                }
                "tunFd" -> {
                    result.success(FlboxVpnService.tunFd)
                }
                "coreActive" -> {
                    result.success(FlboxCoreService.active)
                }
                "stopCoreService" -> {
                    startService(
                        Intent(this, FlboxCoreService::class.java)
                            .setAction(FlboxCoreService.ACTION_STOP)
                    )
                    // Same backstop as stopVpn above.
                    Handler(Looper.getMainLooper()).postDelayed({
                        stopService(Intent(this, FlboxCoreService::class.java))
                    }, 600)
                    result.success(null)
                }
                "listApps" -> {
                    result.success(listLaunchableApps())
                }
                "extractGeoData" -> {
                    // ~25 MB copy: keep it off the main thread, reply
                    // on it as MethodChannel requires.
                    val force = call.argument<Boolean>("force") ?: false
                    Thread {
                        val ok = extractBundledGeoData(force)
                        runOnUiThread { result.success(ok) }
                    }.start()
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
                "updateVpnStatus" -> {
                    FlboxVpnService.updateStatus(
                        call.argument<String>("title"),
                        call.argument<String>("text")
                    )
                    result.success(null)
                }
                "notifyStatus" -> {
                    val title = call.argument<String>("title") ?: "FlBox"
                    val text = call.argument<String>("text") ?: ""
                    showStatusNotification(title, text)
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

    /**
     * Copies the rule databases bundled in the APK assets (the geo folder,
     * downloaded at build time by the downloadGeoData Gradle task)
     * into filesDir, where the core's asset lookup points. Skips
     * files that are already in place unless [force]. Returns true
     * when both files are present and sane-sized afterwards.
     */
    private fun extractBundledGeoData(force: Boolean): Boolean {
        var allOk = true
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val target = File(filesDir, name)
            if (!force && target.exists() && target.length() > 1_000_000) {
                continue
            }
            try {
                val tmp = File(filesDir, "$name.tmp")
                assets.open("geo/$name").use { input ->
                    tmp.outputStream().use { output -> input.copyTo(output) }
                }
                if (tmp.length() <= 1_000_000) {
                    tmp.delete()
                    allOk = false
                    continue
                }
                if (!tmp.renameTo(target)) {
                    tmp.copyTo(target, overwrite = true)
                    tmp.delete()
                }
            } catch (e: Exception) {
                allOk = false
            }
        }
        return allOk
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

    // Status notifications (start summary, subscription
    // auto-update): a separate low-key channel from the VPN
    // foreground notification, posted on demand from Dart.
    private fun showStatusNotification(title: String, text: String) {
        try {
            val manager = getSystemService(NotificationManager::class.java)
                ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        STATUS_CHANNEL_ID,
                        "状态通知",
                        NotificationManager.IMPORTANCE_DEFAULT
                    )
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, STATUS_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            manager.notify(
                STATUS_NOTIF_ID,
                builder
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                    .setAutoCancel(true)
                    .build()
            )
        } catch (_: Exception) {
        }
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
        private const val STATUS_CHANNEL_ID = "flbox_status"
        private const val STATUS_NOTIF_ID = 1001
    }
}

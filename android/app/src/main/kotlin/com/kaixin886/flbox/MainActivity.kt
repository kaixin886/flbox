package com.kaixin886.flbox

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.SELinux
import android.system.Os
import android.system.OsConstants
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

// Holds the channel so the VpnService (a separate component) can
// report the established TUN fd back to Dart.
object VpnBridge {
    var channel: MethodChannel? = null
}

class MainActivity : FlutterActivity() {

    private var pendingPrepare: MethodChannel.Result? = null

    // The root daemon ships as a jniLibs "library" (it is a
    // full executable), but modern packaging may leave native
    // libs unextracted inside the APK, where nothing can be
    // exec'd. Copy it into filesDir and mark it executable;
    // refreshed whenever the packaged size differs.
    private fun daemonBinary(): File? {
        return try {
            val src = File(applicationInfo.nativeLibraryDir, "libflboxd.so")
            if (!src.exists()) return null
            val dst = File(filesDir, "flboxd")
            if (!dst.exists() || dst.length() != src.length()) {
                src.inputStream().use { input ->
                    dst.outputStream().use { input.copyTo(it) }
                }
            }
            dst.setExecutable(true, false)
            dst
        } catch (e: Exception) {
            null
        }
    }

    private fun uidFor(pkg: String): Int? {
        return try {
            @Suppress("DEPRECATION")
            packageManager.getApplicationInfo(pkg, 0).uid
        } catch (e: Exception) {
            null
        }
    }

    // Builds the su script for the eBPF mode netfilter
    // steering. Ports and marks mirror core/ebpfconfig.go:
    // TCP lands on the redirect listener at 7892, UDP is
    // TPROXY-marked 0x2B2C into the local-route table 100
    // and the tproxy listener at 7893, and the daemon's own
    // sockets carry mark 0x2B2B, which every chain exempts
    // first - self-capture is impossible. The IPv6 chain
    // drops non-local v6 instead of leaking it (this stage
    // steers IPv4 only). Clearing unhooks and deletes all
    // three chains and is safe to run anytime.
    private fun buildNetRulesScript(
        install: Boolean,
        includePkgs: List<String>,
        excludePkgs: List<String>,
    ): String {
        val lines = mutableListOf<String>()
        if (!install) {
            lines += "iptables -t nat -D OUTPUT -j FLBOX_NAT 2>/dev/null"
            lines += "iptables -t nat -F FLBOX_NAT 2>/dev/null"
            lines += "iptables -t nat -X FLBOX_NAT 2>/dev/null"
            lines += "iptables -t mangle -D OUTPUT -j FLBOX_MNG 2>/dev/null"
            lines += "iptables -t mangle -F FLBOX_MNG 2>/dev/null"
            lines += "iptables -t mangle -X FLBOX_MNG 2>/dev/null"
            lines += "ip6tables -D OUTPUT -j FLBOX_6 2>/dev/null"
            lines += "ip6tables -F FLBOX_6 2>/dev/null"
            lines += "ip6tables -X FLBOX_6 2>/dev/null"
            lines += "ip rule del fwmark 0x2B2C lookup 100 2>/dev/null"
            lines += "ip route flush table 100 2>/dev/null"
            lines += "true"
            return lines.joinToString("\n")
        }
        val includeUids = includePkgs.mapNotNull { uidFor(it) }
        val excludeUids = excludePkgs.mapNotNull { uidFor(it) }
        fun steer(chain: String, table: String, action: String) {
            lines += "iptables -t $table -A $chain -m mark --mark 0x2B2B -j RETURN"
            lines += "iptables -t $table -A $chain -m addrtype --dst-type LOCAL -j RETURN"
            if (includeUids.isNotEmpty()) {
                for (uid in includeUids) {
                    lines += "iptables -t $table -A $chain -m owner --uid-owner $uid $action"
                }
                lines += "iptables -t $table -A $chain -j RETURN"
            } else {
                for (uid in excludeUids) {
                    lines += "iptables -t $table -A $chain -m owner --uid-owner $uid -j RETURN"
                }
                lines += "iptables -t $table -A $chain $action"
            }
        }
        lines += "echo == nat =="
        lines += "iptables -t nat -N FLBOX_NAT 2>/dev/null"
        lines += "iptables -t nat -F FLBOX_NAT"
        steer("FLBOX_NAT", "nat", "-p tcp -j REDIRECT --to-ports 7892")
        lines += "iptables -t nat -C OUTPUT -j FLBOX_NAT 2>/dev/null || iptables -t nat -A OUTPUT -j FLBOX_NAT"
        lines += "echo == mangle =="
        lines += "iptables -t mangle -N FLBOX_MNG 2>/dev/null"
        lines += "iptables -t mangle -F FLBOX_MNG"
        steer("FLBOX_MNG", "mangle", "-p udp -j TPROXY --on-port 7893 --tproxy-mark 0x2B2C")
        lines += "iptables -t mangle -C OUTPUT -j FLBOX_MNG 2>/dev/null || iptables -t mangle -A OUTPUT -j FLBOX_MNG"
        lines += "echo == route =="
        lines += "ip rule del fwmark 0x2B2C lookup 100 2>/dev/null"
        lines += "ip rule add fwmark 0x2B2C lookup 100 pref 8000"
        lines += "ip route replace local 0.0.0.0/0 dev lo table 100"
        lines += "echo == v6 =="
        lines += "ip6tables -N FLBOX_6 2>/dev/null"
        lines += "ip6tables -F FLBOX_6"
        lines += "ip6tables -A FLBOX_6 -m mark --mark 0x2B2B -j RETURN"
        lines += "ip6tables -A FLBOX_6 -m addrtype --dst-type LOCAL -j RETURN"
        lines += "ip6tables -A FLBOX_6 -p tcp -j DROP"
        lines += "ip6tables -A FLBOX_6 -p udp -j DROP"
        lines += "ip6tables -C OUTPUT -j FLBOX_6 2>/dev/null || ip6tables -A OUTPUT -j FLBOX_6"
        // Verification greps the live rule lists instead of
        // trusting -C exit codes (the 0.59 build reported
        // failure while its chains were in fact installed),
        // then dumps the ground truth either way so the
        // error dialog can show exactly what the kernel has.
        lines += "echo == verify =="
        lines += "iptables -t nat -S OUTPUT | grep FLBOX_NAT && iptables -t mangle -S OUTPUT | grep FLBOX_MNG && echo FLBOX_ALL_OK"
        lines += "iptables -t nat -S OUTPUT"
        lines += "iptables -t mangle -S OUTPUT"
        lines += "iptables -t nat -S FLBOX_NAT"
        lines += "iptables -t mangle -S FLBOX_MNG"
        return lines.joinToString("\n")
    }

    // The device block for the start-failure dialog, in the
    // same shape other proxy apps print: app version,
    // model, Android, kernel, SELinux - the facts a log
    // reader needs before anything else.
    private fun buildDeviceInfo(): String {
        val appLine = try {
            val info = packageManager.getPackageInfo(packageName, 0)
            @Suppress("DEPRECATION")
            val legacyCode = info.versionCode
            val code = if (Build.VERSION.SDK_INT >= 28) {
                info.longVersionCode
            } else {
                legacyCode.toLong()
            }
            "app: ${info.versionName} ($code)"
        } catch (e: Exception) {
            "app: unknown"
        }
        val kernel = System.getProperty("os.version") ?: "unknown"
        val pageSize = try {
            Os.sysconf(OsConstants._SC_PAGESIZE)
        } catch (e: Exception) {
            -1L
        }
        val pageText = if (pageSize > 0) "${pageSize / 1024} KB" else "unknown"
        val selinux = if (SELinux.isSELinuxEnforced()) "enforcing" else "permissive"
        return listOf(
            appLine,
            "model: ${Build.MODEL} (${Build.DEVICE})",
            "android: ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "build: ${Build.ID} ${Build.TAGS}",
            "abi: ${Build.SUPPORTED_ABIS.joinToString(", ")}",
            "kernel: $kernel",
            "page size: $pageText",
            "selinux: $selinux",
        ).joinToString("\n")
    }

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
                            .putExtra(
                                FlboxVpnService.EXTRA_IPV6,
                                call.argument<Boolean>("ipv6") ?: false
                            )
                            .putExtra(
                                FlboxVpnService.EXTRA_SPLIT_ON,
                                call.argument<Boolean>("splitOn") ?: false
                            )
                            .putExtra(
                                FlboxVpnService.EXTRA_SPLIT_ALLOW,
                                call.argument<Boolean>("splitAllow") ?: false
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
                "vpnActive" -> {
                    result.success(FlboxVpnService.active)
                }
                "vpnServiceAlive" -> {
                    result.success(FlboxVpnService.alive)
                }
                "tunFd" -> {
                    result.success(FlboxVpnService.tunFd)
                }
                "listApps" -> {
                    // Rendering ~200 app icons takes a moment;
                    // keep it off the main thread, reply on it as
                    // MethodChannel requires.
                    Thread {
                        val apps = listLaunchableApps()
                        runOnUiThread { result.success(apps) }
                    }.start()
                }
                "startTestService" -> {
                    try {
                        startService(Intent(this, FlboxTestService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopTestService" -> {
                    try {
                        stopService(Intent(this, FlboxTestService::class.java))
                    } catch (e: Exception) {
                    }
                    result.success(null)
                }
                "testProcessAlive" -> {
                    var alive = false
                    try {
                        val am = getSystemService(ActivityManager::class.java)
                        val target = "$packageName:tasks"
                        for (p in am.runningAppProcesses ?: emptyList()) {
                            if (p.processName == target) {
                                alive = true
                                break
                            }
                        }
                    } catch (e: Exception) {
                    }
                    result.success(alive)
                }
                "killTestProcess" -> {
                    // Force-stops the speed test process (same
                    // uid, so the signal is permitted) when a run
                    // wedged it: stopping the service alone cannot
                    // unstick a native runtime stuck inside the
                    // process, and the next launch must start from
                    // a truly fresh process.
                    var killed = false
                    try {
                        val am = getSystemService(ActivityManager::class.java)
                        val target = "$packageName:tasks"
                        for (p in am.runningAppProcesses ?: emptyList()) {
                            if (p.processName == target) {
                                android.os.Process.killProcess(p.pid)
                                killed = true
                            }
                        }
                    } catch (e: Exception) {
                    }
                    result.success(killed)
                }
                "rootCheck" -> {
                    // "ok" when su grants uid 0 and the root
                    // daemon binary is packaged; distinct codes
                    // so the UI can say which leg is missing.
                    Thread {
                        var code = "nosu"
                        if (daemonBinary() == null) {
                            code = "nodaemon"
                        } else {
                            try {
                                val proc = ProcessBuilder("su", "-c", "id -u")
                                    .redirectErrorStream(true)
                                    .start()
                                val out = proc.inputStream
                                    .bufferedReader()
                                    .readText()
                                    .trim()
                                val exit = proc.waitFor()
                                if (exit == 0 && out == "0") code = "ok"
                            } catch (e: Exception) {
                            }
                        }
                        runOnUiThread { result.success(code) }
                    }.start()
                }
                "rootStart" -> {
                    // Launches the daemon detached through su;
                    // the daemon itself reports readiness in
                    // the status file Dart polls.
                    val args = call.arguments as? Map<*, *>
                    val configPath = args?.get("config") as? String
                    val statusPath = args?.get("status") as? String
                    val logPath = args?.get("log") as? String
                    if (configPath == null || statusPath == null || logPath == null) {
                        result.error("badargs", "missing daemon paths", null)
                    } else {
                        Thread {
                            var ok = false
                            try {
                                val daemon = daemonBinary()?.absolutePath
                                    ?: throw IllegalStateException("no daemon")
                                // Append, never truncate: a restart
                                // must not erase the previous run's
                                // log - the failure window lives
                                // there (0.58 diagnosis fix).
                                val cmd = "nohup '$daemon' '$configPath' " +
                                    "'$statusPath' >>'$logPath' 2>&1 &"
                                val proc = ProcessBuilder("su", "-c", cmd)
                                    .redirectErrorStream(true)
                                    .start()
                                proc.waitFor()
                                ok = true
                            } catch (e: Exception) {
                            }
                            runOnUiThread { result.success(ok) }
                        }.start()
                    }
                }
                "rootStop" -> {
                    val pid = (call.arguments as? Number)?.toInt() ?: 0
                    Thread {
                        try {
                            if (pid > 0) {
                                ProcessBuilder("su", "-c", "kill $pid")
                                    .redirectErrorStream(true)
                                    .start()
                                    .waitFor()
                            }
                        } catch (e: Exception) {
                        }
                        runOnUiThread { result.success(null) }
                    }.start()
                }
                "netRules" -> {
                    // eBPF mode steering: installs or clears
                    // the netfilter chains that feed the
                    // daemon's redirect and tproxy listeners.
                    // Replies with a map: ok plus the script's
                    // own output, so a failure shows which
                    // section died and what iptables said -
                    // a bare boolean cost a whole evening
                    // in 0.59.
                    val args = call.arguments as? Map<*, *>
                    val install = (args?.get("action") as? String) == "install"
                    val include = (args?.get("includePkgs") as? List<*>)
                        ?.mapNotNull { it as? String } ?: emptyList()
                    val exclude = (args?.get("excludePkgs") as? List<*>)
                        ?.mapNotNull { it as? String } ?: emptyList()
                    Thread {
                        var ok = false
                        var log = ""
                        try {
                            val script = buildNetRulesScript(install, include, exclude)
                            val proc = ProcessBuilder("su", "-c", script)
                                .redirectErrorStream(true)
                                .start()
                            val out = proc.inputStream.bufferedReader().readText()
                            val exit = proc.waitFor()
                            log = out.trim()
                            if (log.length > 4000) {
                                log = log.substring(log.length - 4000)
                            }
                            ok = if (install) log.contains("FLBOX_ALL_OK") else exit == 0
                        } catch (e: Exception) {
                            log = "exception: $e"
                        }
                        runOnUiThread { result.success(mapOf("ok" to ok, "log" to log)) }
                    }.start()
                }
                "deviceInfo" -> {
                    result.success(buildDeviceInfo())
                }
                "writeTestJob" -> {
                    // Writes the speed test job file and clears
                    // the previous run's outputs; the reply lands
                    // only after the file is on disk, so the test
                    // service started right after sees it.
                    val job = call.arguments as? String
                    Thread {
                        var ok = false
                        try {
                            File(filesDir, FlboxTestService.RESULTS_FILE).delete()
                            File(filesDir, FlboxTestService.DONE_FILE).delete()
                            if (job != null) {
                                File(filesDir, FlboxTestService.JOB_FILE)
                                    .writeText(job)
                                ok = true
                            }
                        } catch (e: Exception) {
                        }
                        runOnUiThread { result.success(ok) }
                    }.start()
                }
                "readTestResults" -> {
                    Thread {
                        var lines = ""
                        var done = false
                        try {
                            val f = File(filesDir, FlboxTestService.RESULTS_FILE)
                            if (f.exists()) lines = f.readText()
                            done = File(filesDir, FlboxTestService.DONE_FILE).exists()
                        } catch (e: Exception) {
                        }
                        runOnUiThread {
                            result.success(mapOf("lines" to lines, "done" to done))
                        }
                    }.start()
                }
                "extractGeoData" -> {
                    // ~25 MB copy: keep it off the main thread, reply
                    // on it as MethodChannel requires.
                    val force = call.argument<Boolean>("force") ?: false
                    val dir = call.argument<String>("dir")
                    Thread {
                        val ok = extractBundledGeoData(force, dir)
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
    // The Dart side owns the location: the core reads the rule
    // databases from the documents directory it passes in, so
    // the bundled copies must land exactly there (an earlier
    // version wrote to filesDir, which the core never reads -
    // fresh installs then failed to start in rules mode).
    private fun extractBundledGeoData(force: Boolean, dirPath: String?): Boolean {
        val dir = if (dirPath != null) File(dirPath) else filesDir
        dir.mkdirs()
        var allOk = true
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val target = File(dir, name)
            if (!force && target.exists() && target.length() > 1_000_000) {
                continue
            }
            try {
                val tmp = File(dir, "$name.tmp")
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

    /** Apps the user can pick on the per-app proxy page, with
     * their launcher icons as PNG bytes for the list rows. */
    private fun listLaunchableApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val infos = pm.queryIntentActivities(query, 0)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any?>>()
        for (info in infos) {
            val appInfo = info.activityInfo.applicationInfo
            if (!seen.add(appInfo.packageName)) continue
            apps.add(
                mapOf(
                    "pkg" to appInfo.packageName,
                    "label" to pm.getApplicationLabel(appInfo).toString(),
                    "icon" to drawableToPng(pm.getApplicationIcon(appInfo))
                )
            )
        }
        return apps.sortedBy { (it["label"] as? String)?.lowercase() ?: "" }
    }

    /** Renders a launcher icon to a small PNG for the Dart side. */
    private fun drawableToPng(drawable: Drawable): ByteArray? {
        return try {
            val size = 96
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            if (drawable is BitmapDrawable && drawable.bitmap != null) {
                val scaled = Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
                canvas.drawBitmap(scaled, 0f, 0f, null)
            } else {
                drawable.setBounds(0, 0, size, size)
                drawable.draw(canvas)
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
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

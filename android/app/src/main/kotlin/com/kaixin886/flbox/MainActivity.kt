package com.kaixin886.flbox

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.os.Handler
import android.os.Process
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

    // The bpf2socks bridge (0.64 eBPF mode), packaged and
    // materialized exactly like the daemon: flboxd looks
    // for it next to its own binary in filesDir.
    private fun bridgeBinary(): File? {
        return try {
            val src = File(applicationInfo.nativeLibraryDir, "libbpf2socks.so")
            if (!src.exists()) return null
            val dst = File(filesDir, "bpf2socks")
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

    // android.os.SELinux is a hidden API and not in the
    // SDK stubs, so read the state the way native tools
    // do: the enforce node, with getenforce as fallback.
    private fun selinuxState(): String {
        try {
            val v = File("/sys/fs/selinux/enforce").readText().trim()
            if (v == "1") return "enforcing"
            if (v == "0") return "permissive"
        } catch (e: Exception) {
        }
        try {
            val proc = ProcessBuilder("getenforce")
                .redirectErrorStream(true)
                .start()
            val out = proc.inputStream.bufferedReader().readText().trim()
            proc.waitFor()
            // getenforce merges its stderr into the reply
            // when the state is unreadable as the app uid
            // (0.60 dialog showed the raw error text); only
            // a real one-word answer is a state.
            val word = out.lowercase()
            if (word == "enforcing" || word == "permissive" ||
                word == "disabled"
            ) {
                return word
            }
        } catch (e: Exception) {
        }
        return "unknown"
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
        val selinux = selinuxState()
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
                "bridgeCheck" -> {
                    result.success(bridgeBinary() != null)
                }
                "packageUids" -> {
                    // Resolves the split-routing package list
                    // to Android uids for the bridge policy;
                    // unknown packages are skipped.
                    val pkgs = (call.arguments as? List<*>)?.mapNotNull { it as? String }
                        ?: emptyList()
                    result.success(pkgs.mapNotNull { uidFor(it) })
                }
                "rootStart" -> {
                    // Launches the daemon detached through su;
                    // the daemon itself reports readiness in
                    // the status file Dart polls.
                    val args = call.arguments as? Map<*, *>
                    val configPath = args?.get("config") as? String
                    val statusPath = args?.get("status") as? String
                    val logPath = args?.get("log") as? String
                    val bridgePath = args?.get("bridge") as? String
                    if (configPath == null || statusPath == null || logPath == null) {
                        result.error("badargs", "missing daemon paths", null)
                    } else {
                        Thread {
                            var ok = false
                            try {
                                val daemon = daemonBinary()?.absolutePath
                                    ?: throw IllegalStateException("no daemon")
                                // Bridge mode: materialize the
                                // bridge next to the daemon copy;
                                // flboxd refuses with a clear
                                // status error if it is absent.
                                if (bridgePath != null && bridgeBinary() == null) {
                                    throw IllegalStateException("no bridge")
                                }
                                // Append, never truncate: a restart
                                // must not erase the previous run's
                                // log - the failure window lives
                                // there (0.58 diagnosis fix).
                                var cmd = "nohup '$daemon' '$configPath' " +
                                    "'$statusPath'"
                                if (bridgePath != null) {
                                    cmd += " '$bridgePath'"
                                }
                                cmd += " >>'$logPath' 2>&1 &"
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
                "bootStartSet" -> {
                    // Root-mode boot autostart (0.68), the
                    // AsteriskNG design: a Magisk service.d
                    // script starts flboxd at boot with the
                    // configs the app last published - no app
                    // process and no BootReceiver involved.
                    // Enabling writes the script (0755) with
                    // the daemon path and config paths baked
                    // in; disabling removes it. The daemon
                    // and bridge binaries are materialized
                    // first so the script never points at
                    // files that do not exist yet.
                    val args = call.arguments as? Map<*, *>
                    val enabled = args?.get("enabled") as? Boolean ?: false
                    val configPath = args?.get("config") as? String
                    val statusPath = args?.get("status") as? String
                    val logPath = args?.get("log") as? String
                    val prevLogPath = args?.get("prevLog") as? String
                    val bridgePath = args?.get("bridge") as? String
                    Thread {
                        var ok = false
                        try {
                            if (!enabled) {
                                val proc = ProcessBuilder(
                                    "su", "-c",
                                    "rm -f /data/adb/service.d/flbox.sh"
                                ).redirectErrorStream(true).start()
                                ok = proc.waitFor() == 0
                            } else if (configPath != null && statusPath != null &&
                                logPath != null && prevLogPath != null && bridgePath != null
                            ) {
                                val daemon = daemonBinary()?.absolutePath
                                if (daemon != null && bridgeBinary() != null) {
                                    val script = StringBuilder()
                                        .append("#!/system/bin/sh\n")
                                        .append("# FlBox root-mode boot start, installed by the app.\n")
                                        .append("# Turn it off in FlBox settings (Root mode, boot autostart).\n")
                                        .append("until [ \"\$(getprop sys.boot_completed)\" = \"1\" ]; do sleep 3; done\n")
                                        .append("sleep 5\n")
                                        .append("rm -f '").append(statusPath).append("'\n")
                                        .append("[ -f '").append(logPath).append("' ] && mv '")
                                        .append(logPath).append("' '").append(prevLogPath).append("'\n")
                                        .append("printf '===== flboxd session (boot autostart) mode=ebpf ipv6=false =====\n' > '")
                                        .append(logPath).append("'\n")
                                        .append("nohup '").append(daemon).append("' '")
                                        .append(configPath).append("' '").append(statusPath)
                                        .append("' '").append(bridgePath).append("' >> '")
                                        .append(logPath).append("' 2>&1 &\n")
                                        .toString()
                                    val tmp = File(cacheDir, "flbox-boot.sh")
                                    tmp.writeText(script)
                                    val cmd = "mkdir -p /data/adb/service.d && " +
                                        "cp '" + tmp.absolutePath + "' /data/adb/service.d/flbox.sh && " +
                                        "chmod 755 /data/adb/service.d/flbox.sh"
                                    val proc = ProcessBuilder("su", "-c", cmd)
                                        .redirectErrorStream(true).start()
                                    ok = proc.waitFor() == 0
                                }
                            }
                        } catch (e: Exception) {
                        }
                        runOnUiThread { result.success(ok) }
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
                "ownUid" -> {
                    result.success(Process.myUid())
                }
                "systemDnsServers" -> {
                    // DNS servers of the underlying network,
                    // never the VPN's own: the root-mode core
                    // cannot use the system stub, so the app
                    // hands it the carrier's resolver IPs to
                    // use as its direct DNS server.
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                        as ConnectivityManager
                    val candidates = cm.allNetworks.sortedBy { n ->
                        val caps = cm.getNetworkCapabilities(n)
                        when {
                            caps == null -> 3
                            caps.hasTransport(
                                NetworkCapabilities.TRANSPORT_CELLULAR
                            ) -> 0
                            caps.hasTransport(
                                NetworkCapabilities.TRANSPORT_WIFI
                            ) -> 1
                            else -> 2
                        }
                    }
                    val servers = mutableListOf<String>()
                    for (n in candidates) {
                        val caps = cm.getNetworkCapabilities(n)
                            ?: continue
                        if (caps.hasTransport(
                                NetworkCapabilities.TRANSPORT_VPN
                            )
                        ) {
                            continue
                        }
                        val lp = cm.getLinkProperties(n) ?: continue
                        for (addr in lp.dnsServers) {
                            val host = addr.hostAddress ?: continue
                            servers.add(host)
                        }
                        if (servers.isNotEmpty()) break
                    }
                    result.success(servers)
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

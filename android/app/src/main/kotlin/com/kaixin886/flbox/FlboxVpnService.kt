package com.kaixin886.flbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor

// Establishes the system TUN device and hands its fd to the Go core,
// which reads packets through Xray's tun inbound. The service keeps
// ownership of the fd (Xray's Android tun never closes it); closing
// it here is what tears the tunnel down.
//
// Lifecycle rule (v2rayNG-style, user-requested 2026-11-04): the
// session belongs to this foreground service, not to the UI task.
// Swiping FlBox out of recents must NOT stop anything - the tunnel
// and the core stay up, and reopening the app shows the session as
// running (Dart reconciles against the flags below) with the main
// toggle able to stop it. The service is still NOT sticky: if the
// process itself dies (MIUI background kill, OOM), the tunnel dies
// with it, and a null-intent restart never resurrects a coreless
// zombie tunnel that would black-hole all traffic.
class FlboxVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var lastNetwork: Network? = null

    override fun onCreate() {
        super.onCreate()
        alive = true
        instance = this
        registerNetworkWatcher()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                START_NOT_STICKY
            }
            ACTION_START -> {
                startVpn(
                    intent?.getStringArrayListExtra(EXTRA_BYPASS) ?: emptyList(),
                    intent?.getBooleanExtra(EXTRA_IPV6, false) ?: false,
                    intent?.getBooleanExtra(EXTRA_SPLIT_ON, false) ?: false,
                    intent?.getBooleanExtra(EXTRA_SPLIT_ALLOW, false) ?: false
                )
                START_NOT_STICKY
            }
            else -> {
                // Null intent = system restart after process death.
                // The core that owned the old tunnel is gone; never
                // resurrect a tunnel with nothing behind it.
                stopSelf()
                START_NOT_STICKY
            }
        }
    }

    private fun startVpn(
        bypass: List<String>,
        ipv6: Boolean,
        splitOn: Boolean,
        splitAllow: Boolean
    ) {
        if (tun != null) return
        // Android 14+ refuses startForeground without a declared type
        // (MissingForegroundServiceTypeException). The manifest declares
        // systemExempted (the VPN case); pass it explicitly too, and
        // never let a promotion failure kill the tunnel itself.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIF_ID,
                    buildNotification(),
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
                )
            } else {
                startForeground(NOTIF_ID, buildNotification())
            }
        } catch (_: Exception) {
        }
        val builder = Builder()
            .setSession("FlBox")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
        // The v6 address and ::/0 route are installed in
        // both switch states (0.70): with the switch on,
        // the dual-stack forwarder carries the traffic;
        // with it off, the v4-only forwarder drops every
        // v6 packet the route delivers - break, not leak.
        // Without the route, IPv6 bypasses the tunnel
        // entirely on the carrier interface. The address
        // matches the forwarder's tun config either way.
        builder.addAddress("fdfe:dcba:9876::1", 126)
        builder.addRoute("::", 0)
        // In allowlist split mode the checked apps are the only
        // ones routed into the tunnel; this app is then outside
        // automatically, which is exactly what the core needs.
        // In every other mode the core's own outbound connections
        // must be kept out of the tunnel explicitly, or they loop
        // back into it.
        if (!(splitOn && splitAllow)) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: PackageManager.NameNotFoundException) {
            }
        }
        // User-chosen per-app split (set on the per-app page):
        // bypass mode excludes the checked apps from the VPN;
        // allowlist mode routes only the checked apps into it.
        if (splitOn) {
            for (pkg in bypass) {
                if (pkg == packageName) continue
                try {
                    if (splitAllow) {
                        builder.addAllowedApplication(pkg)
                    } else {
                        builder.addDisallowedApplication(pkg)
                    }
                } catch (_: PackageManager.NameNotFoundException) {
                }
            }
        }
        val pfd = builder.establish()
        if (pfd == null) {
            stopSelf()
            return
        }
        tun = pfd
        tunFd = pfd.fd
        active = true
        VpnBridge.channel?.invokeMethod("onTunReady", pfd.fd)
    }

    private fun stopVpn() {
        active = false
        tunFd = -1
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // No onTaskRemoved override on purpose: swiping the task away
    // leaves this foreground service (and the session it hosts)
    // running, v2rayNG-style. The manifest also sets
    // stopWithTask="false" on this service so the system does not
    // stop it when the task that started it is removed.

    override fun onDestroy() {
        active = false
        alive = false
        instance = null
        statusTitle = null
        statusText = null
        tunFd = -1
        unregisterNetworkWatcher()
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
    }

    // The core's outbound sockets are bound to whatever network was
    // default when it started; after a Wi-Fi to mobile switch they
    // silently rot (pages load a little, then stall) until the core
    // is restarted. Watch the default network and tell Dart to
    // restart the core in place when it actually changes. This app
    // is disallowed from its own tunnel, so the callback tracks the
    // underlying network, which is the one the core dials on.
    private fun registerNetworkWatcher() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        try {
            val cm = getSystemService(ConnectivityManager::class.java) ?: return
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val prev = lastNetwork
                    lastNetwork = network
                    if (prev != null && prev != network) {
                        Handler(Looper.getMainLooper()).post {
                            VpnBridge.channel?.invokeMethod("onNetworkChanged", null)
                        }
                    }
                }

                override fun onLost(network: Network) {
                    if (lastNetwork == network) lastNetwork = null
                }
            }
            netCallback = cb
            cm.registerDefaultNetworkCallback(cb)
        } catch (_: Exception) {
        }
    }

    private fun unregisterNetworkWatcher() {
        try {
            netCallback?.let {
                getSystemService(ConnectivityManager::class.java)
                    ?.unregisterNetworkCallback(it)
            }
        } catch (_: Exception) {
        }
        netCallback = null
        lastNetwork = null
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "FlBox VPN",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        // Tapping the resident notification reopens the app,
        // where the adopted session can be stopped from the
        // main toggle - the v2rayNG flow the user asked for.
        val launch = Intent(this, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )
        return builder
            .setContentTitle(statusTitle ?: "FlBox VPN 运行中")
            .setContentText(statusText ?: "系统代理已接管流量")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pending)
            .build()
    }

    // Re-posts the foreground notification with the current
    // status line. Same id as the startForeground call, so the
    // resident notification updates in place.
    private fun refreshNotification() {
        try {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIF_ID, buildNotification())
        } catch (_: Exception) {
        }
    }

    companion object {
        const val ACTION_START = "com.kaixin886.flbox.VPN_START"
        const val ACTION_STOP = "com.kaixin886.flbox.VPN_STOP"
        const val EXTRA_BYPASS = "com.kaixin886.flbox.EXTRA_BYPASS"
        const val EXTRA_IPV6 = "com.kaixin886.flbox.EXTRA_IPV6"
        const val EXTRA_SPLIT_ON = "com.kaixin886.flbox.EXTRA_SPLIT_ON"
        const val EXTRA_SPLIT_ALLOW = "com.kaixin886.flbox.EXTRA_SPLIT_ALLOW"
        private const val CHANNEL_ID = "flbox_vpn"
        private const val NOTIF_ID = 1

        // True while this process holds an established tunnel. Dart
        // reads it at startup to reconcile its state with reality.
        @Volatile
        var active: Boolean = false

        // True from onCreate to onDestroy. Dart polls this after a
        // stop: "active" flips at the start of stopVpn(), long
        // before the system has actually torn the service down,
        // so it cannot prove the VPN is gone - this flag can,
        // because a service the system still holds a VPN binding
        // on is never destroyed.
        @Volatile
        var alive: Boolean = false

        // The established tunnel's fd, so a recreated Dart engine
        // in the same process can adopt the live session.
        @Volatile
        var tunFd: Int = -1

        // Live status line pushed from Dart (node, latency,
        // rates): shown by the resident foreground notification
        // whenever set; cleared when the service dies.
        @Volatile
        var statusTitle: String? = null

        @Volatile
        var statusText: String? = null

        @Volatile
        private var instance: FlboxVpnService? = null

        fun updateStatus(title: String?, text: String?) {
            statusTitle = title
            statusText = text
            instance?.refreshNotification()
        }
    }
}

package com.kaixin886.flbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
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
// Lifecycle rule: a session belongs to the process that started it.
// The service is NOT sticky: if the process dies (task swiped away,
// MIUI background kill), the tunnel dies with it instead of being
// resurrected by the system as a coreless zombie that black-holes
// all traffic and cannot be stopped from the UI.
class FlboxVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var lastNetwork: Network? = null

    override fun onCreate() {
        super.onCreate()
        alive = true
        registerNetworkWatcher()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                START_NOT_STICKY
            }
            ACTION_START -> {
                startVpn(intent?.getStringArrayListExtra(EXTRA_BYPASS) ?: emptyList())
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

    private fun startVpn(bypass: List<String>) {
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
        try {
            // The core's own outbound connections must not loop back
            // into the tunnel it is serving.
            builder.addDisallowedApplication(packageName)
        } catch (_: PackageManager.NameNotFoundException) {
        }
        // User-chosen per-app bypass (set in FlBox settings).
        for (pkg in bypass) {
            if (pkg == packageName) continue
            try {
                builder.addDisallowedApplication(pkg)
            } catch (_: PackageManager.NameNotFoundException) {
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

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping FlBox out of recents ends the session: a
        // tunnel that outlives its UI reads as "the VPN won't
        // turn off". Dart gets a brief window to run its
        // orderly stop (forwarder, core, tunnel); the delayed
        // local teardown fires only if that never landed.
        try {
            VpnBridge.channel?.invokeMethod("onTaskRemoved", null)
        } catch (_: Exception) {
        }
        Handler(Looper.getMainLooper()).postDelayed({ stopVpn() }, 800)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        active = false
        alive = false
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
        return builder
            .setContentTitle("FlBox VPN 运行中")
            .setContentText("系统代理已接管流量")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
    }

    companion object {
        const val ACTION_START = "com.kaixin886.flbox.VPN_START"
        const val ACTION_STOP = "com.kaixin886.flbox.VPN_STOP"
        const val EXTRA_BYPASS = "com.kaixin886.flbox.EXTRA_BYPASS"
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
    }
}

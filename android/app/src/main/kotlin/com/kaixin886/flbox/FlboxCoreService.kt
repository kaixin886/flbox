package com.kaixin886.flbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Hosts the proxy core while it runs, including in local (non-VPN) mode.
 *
 * Reference clients (v2rayNG, sing-box) never let the core live in a bare
 * UI process: an unhosted process gets cached/frozen in the background
 * and the system silently drops its socket traffic. A foreground
 * service keeps the process at foreground importance for as long as the
 * core runs. Rule taken from the reference projects: startForeground is
 * the FIRST thing onStartCommand does.
 *
 * Like the VPN service, this host is NOT sticky: the core it hosts
 * lives in the same process, so after process death a resurrected
 * host would just be a notification claiming a core that is gone.
 * It also watches the default network so Dart can restart the core
 * when a Wi-Fi to mobile switch rots its outbound sockets.
 */
class FlboxCoreService : Service() {

    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var lastNetwork: Network? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        registerNetworkWatcher()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            // Explicit stop, or a null-intent restart: either way the
            // session this host existed for is over.
            active = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (e: Exception) {
            // Losing the foreground promotion must not kill the session.
        }
        active = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        active = false
        unregisterNetworkWatcher()
        super.onDestroy()
    }

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
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "核心服务", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("FlBox 核心运行中")
            .setContentText("系统代理模式 · 本地端口 7890")
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .build()
    }

    companion object {
        const val ACTION_START = "com.kaixin886.flbox.core.START"
        const val ACTION_STOP = "com.kaixin886.flbox.core.STOP"
        private const val CHANNEL_ID = "flbox_core"
        private const val NOTIFICATION_ID = 2

        // True while this host is in its started state. Dart reads
        // it at startup to reconcile its state with reality.
        @Volatile
        var active: Boolean = false
    }
}

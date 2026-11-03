package com.kaixin886.flbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

// Establishes the system TUN device and hands its fd to the Go core,
// which reads packets through Xray's tun inbound. The service keeps
// ownership of the fd (Xray's Android tun never closes it); closing
// it here is what tears the tunnel down.
class FlboxVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                START_NOT_STICKY
            }
            else -> {
                startVpn()
                START_STICKY
            }
        }
    }

    private fun startVpn() {
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
        val pfd = builder.establish()
        if (pfd == null) {
            stopSelf()
            return
        }
        tun = pfd
        VpnBridge.channel?.invokeMethod("onTunReady", pfd.fd)
    }

    private fun stopVpn() {
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
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
        private const val CHANNEL_ID = "flbox_vpn"
        private const val NOTIF_ID = 1
    }
}

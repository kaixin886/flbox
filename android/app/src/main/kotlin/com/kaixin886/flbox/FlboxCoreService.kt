package com.kaixin886.flbox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Hosts the proxy core while it runs, including in local (non-VPN) mode.
 *
 * Reference clients (v2rayNG, sing-box) never let the core live in a bare
 * UI process: an unhosted process gets cached/frozen in the background
 * and the system silently drops its socket traffic. A foreground
 * service keeps the process at foreground importance for as long as the
 * core runs. Rule taken from the reference projects: startForeground is
 * the FIRST thing onStartCommand does.
 */
class FlboxCoreService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
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
        return START_STICKY
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
    }
}

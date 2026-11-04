package com.kaixin886.flbox

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// After a reboot, when the user opted into boot restore and the
// core was running when the phone went down, bring the app to
// the front; the Dart side then reconnects through the same
// path as auto-connect on open. Some ROMs block background
// activity launches unless the user allowed autostart - then
// nothing happens here, and the in-app restore still applies on
// the next manual open.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val restore = prefs.getBoolean("flutter.restore_on_boot", false)
        val wasRunning = prefs.getBoolean("flutter.was_running", false)
        if (!restore || !wasRunning) return
        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(launch)
        } catch (e: Exception) {
            // Background launch blocked by the ROM; see class doc.
        }
    }
}

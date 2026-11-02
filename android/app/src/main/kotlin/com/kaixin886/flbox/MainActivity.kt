package com.kaixin886.flbox

import android.app.Activity
import android.content.Intent
import android.net.VpnService
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
                    startService(
                        Intent(this, FlboxVpnService::class.java)
                            .setAction(FlboxVpnService.ACTION_START)
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
                else -> result.notImplemented()
            }
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
    }
}

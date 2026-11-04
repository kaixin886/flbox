package com.kaixin886.flbox

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Hosts the bulk speed test in its own process (declared with a
// separate android:process in the manifest), mirroring how
// v2rayNG keeps its test service out of the UI process. A test
// run spins up dozens of throwaway native core instances, and
// on the user's phone that work eventually aborts the hosting
// process mid-run no matter how the instances are scheduled.
// In this process the abort costs only the test run: the UI
// keeps every result written so far and marks the rest timed
// out, instead of the whole app flash-closing.
//
// The two processes talk through filesDir, which the app
// sandbox shares across its own processes: the UI writes the
// job file and asks MainActivity to start this service; a
// second Flutter engine here runs the Dart "testMain"
// entrypoint, which pulls the job and streams results back
// through the channel below; each result is appended to the
// results file the UI polls.
class FlboxTestService : Service() {

    private var engine: FlutterEngine? = null
    private val ioLock = Any()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (engine == null) {
            try {
                startEngine()
            } catch (e: Exception) {
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val eng = FlutterEngine(applicationContext)
        MethodChannel(eng.dartExecutor.binaryMessenger, "flbox/testhost")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getJob" -> {
                        Thread {
                            val job = try {
                                val f = File(filesDir, JOB_FILE)
                                if (f.exists()) f.readText() else null
                            } catch (e: Exception) {
                                null
                            }
                            Handler(Looper.getMainLooper()).post {
                                result.success(job)
                            }
                        }.start()
                    }
                    "postResult" -> {
                        val line = call.arguments as? String
                        if (line != null) {
                            Thread {
                                synchronized(ioLock) {
                                    try {
                                        File(filesDir, RESULTS_FILE)
                                            .appendText(line + "\n")
                                    } catch (e: Exception) {
                                    }
                                }
                            }.start()
                        }
                        result.success(null)
                    }
                    "done" -> {
                        try {
                            File(filesDir, DONE_FILE).writeText("1")
                        } catch (e: Exception) {
                        }
                        result.success(null)
                        stopSelf()
                    }
                    else -> result.notImplemented()
                }
            }
        eng.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "testMain"
            )
        )
        engine = eng
    }

    override fun onDestroy() {
        try {
            engine?.destroy()
        } catch (e: Exception) {
        }
        engine = null
        super.onDestroy()
    }

    companion object {
        const val JOB_FILE = "speedtest_job.json"
        const val RESULTS_FILE = "speedtest_results.jsonl"
        const val DONE_FILE = "speedtest_done"
    }
}

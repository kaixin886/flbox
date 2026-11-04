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
//
// When a job finishes, this process KILLS ITSELF (see the
// "done" handler). stopSelf alone only stops the service -
// the process, with the native library and all the state it
// accumulated over the job (instances, connections,
// goroutines), lingers on as a cached process, and the next
// start would build its engine on top of that residue. The
// 0.51 phone run showed exactly that cost: chunked testing
// completed, but past roughly thirty nodes the measures
// slowed down and reported timeouts for nodes that work fine
// - the "fresh process per chunk" the design assumed was
// never guaranteed, because the UI-side kill depends on a
// process listing the platform may not even show it. A
// process killing itself needs no one's permission and
// always works, so the next chunk provably starts from zero.
class FlboxTestService : Service() {

    private var engine: FlutterEngine? = null
    private val ioLock = Any()
    private var startGeneration = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startGeneration++
        // A start always carries a new job: tear down any engine
        // left from a previous launch and build a fresh one.
        // Relaunches depend on this - when the process could not
        // be killed, or the start raced the old instance's
        // teardown, an ignored start would leave the new job
        // unrun and the UI would see a silent zero-result launch
        // (the 0.48 phone run ended exactly that way: first half
        // measured, remainder never started).
        if (engine != null) {
            try {
                engine?.destroy()
            } catch (e: Exception) {
            }
            engine = null
        }
        try {
            startEngine()
        } catch (e: Exception) {
            stopSelf()
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
                        // Terminate this process shortly after
                        // the reply, so the next chunk's start
                        // creates a genuinely fresh one (see the
                        // class comment). The generation guard
                        // keeps the delayed kill from firing if
                        // a new start already reused this process
                        // inside the grace window - that start
                        // rebuilt the engine and owns the
                        // process now.
                        val gen = startGeneration
                        Handler(Looper.getMainLooper()).postDelayed({
                            if (startGeneration == gen) {
                                android.os.Process.killProcess(
                                    android.os.Process.myPid()
                                )
                            }
                        }, 400)
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

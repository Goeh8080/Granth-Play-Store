package com.wnm.granthprabandhan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Keeps the full offline download going when the app is closed or swiped away: a quiet
 * foreground service (type dataSync) with one silent "पेज सेव हो रहे हैं 412/985" notification.
 *
 * The pages are downloaded by the Dart code (one pipeline, one live count); like
 * [PdfService], this service keeps the cached Flutter engine — and so that download — alive
 * while the activity is gone. If Android kills the whole process anyway, the sticky service
 * is restarted and starts the engine headless; the download resumes from what is on disk.
 * It stops when Dart reports the download finished (or stopped), on the Android 15 dataSync
 * time limit, and by itself after [IDLE_MS] without any progress report.
 */
class PageSyncService : Service() {
    companion object {
        const val CH = "page_sync_v1"
        const val NOTE_ID = 4300
        const val TAG = "GranthPages"
        const val ENGINE_ID = "granth-main"
        private const val EXTRA_DONE = "done"
        private const val EXTRA_TOTAL = "total"
        private const val IDLE_MS = 5 * 60 * 1000L

        @Volatile
        var running = false
            private set

        @Volatile
        private var stopRequested = false
        private var instance: PageSyncService? = null

        /** True while MainActivity exists (a headless engine is destroyed when the service ends). */
        @Volatile
        var activityAlive = false

        fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            try {
                val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
                nm.createNotificationChannel(NotificationChannel(CH, "पेज सेव हो रहे हैं", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "ऑफलाइन पढ़ने के लिए पेज डाउनलोड"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                })
            } catch (e: Exception) {
                Log.w(TAG, "channel: $e")
            }
        }

        @Suppress("DEPRECATION")
        private fun note(ctx: Context, done: Int, total: Int): Notification {
            ensureChannel(ctx)
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CH) else Notification.Builder(ctx).setPriority(Notification.PRIORITY_LOW)
            val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: Intent(ctx, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return b.setSmallIcon(R.drawable.ic_stat_granth)
                .setContentTitle(PageNotes.title(done, total))
                .setContentText("ऑफलाइन पढ़ने के लिए")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setProgress(maxOf(total, 1), done.coerceIn(0, maxOf(total, 1)), total <= 0)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setGroup(PdfService.GROUP)
                .setContentIntent(PendingIntent.getActivity(ctx, 1, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                .build()
        }

        /** Start (first call) or update. Never throws. */
        fun update(ctx: Context, done: Int, total: Int) {
            val app = ctx.applicationContext
            stopRequested = false
            val svc = instance
            if (svc != null && running) {
                svc.touch()
                try {
                    (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTE_ID, note(app, done, total))
                } catch (e: Exception) {
                    Log.w(TAG, "notify: $e")
                }
                return
            }
            val i = Intent(app, PageSyncService::class.java).putExtra(EXTRA_DONE, done).putExtra(EXTRA_TOTAL, total)
            try {
                if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
            } catch (e: Exception) {
                // Android 12+ refuses a start from the background: the download still runs
                // while the process lives, it just isn't protected.
                Log.w(TAG, "start refused: $e")
            }
        }

        fun stop(ctx: Context) {
            val svc = instance
            if (svc != null && running) svc.finish() else {
                stopRequested = true
                try {
                    (ctx.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTE_ID)
                } catch (_: Exception) {}
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val idle = Runnable {
        Log.w(TAG, "no progress for ${IDLE_MS / 1000}s — stopping")
        finish()
    }

    fun touch() {
        main.removeCallbacks(idle)
        main.postDelayed(idle, IDLE_MS)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val done = intent?.getIntExtra(EXTRA_DONE, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        try {
            val n = note(this, done, total)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(NOTE_ID, n)
            running = true
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: $e")
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        touch()
        if (stopRequested) {
            stopRequested = false
            finish()
            return START_NOT_STICKY
        }
        // intent == null: Android restarted us after killing the process. No engine is
        // running then; start it headless so the Dart download resumes from disk.
        if (intent == null) ensureEngine()
        return START_STICKY
    }

    private fun ensureEngine() {
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) return
        try {
            Log.i(TAG, "restarted after process death: starting the engine headless")
            val engine = FlutterEngine(applicationContext)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            MainActivity.attachChannels(applicationContext, engine)
        } catch (e: Throwable) {
            Log.w(TAG, "headless engine: $e")
            finish()
        }
    }

    /** Android 15: daily dataSync limit. The download resumes on the next app start. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "onTimeout — stopping")
        finish()
    }

    @Suppress("DEPRECATION")
    fun finish() {
        running = false
        main.removeCallbacks(idle)
        try {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
        } catch (_: Exception) {}
        stopSelf()
        // A headless engine (or one kept after a swipe) is not needed any more.
        if (!activityAlive && !PdfService.running) {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let {
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
                main.post { try { it.destroy() } catch (_: Throwable) {} }
            }
        }
    }

    override fun onDestroy() {
        running = false
        main.removeCallbacks(idle)
        if (instance === this) instance = null
        super.onDestroy()
    }
}

/** Pure helpers, unit-tested on the JVM. */
object PageNotes {
    fun title(done: Int, total: Int): String =
        if (total > 0) "पेज सेव हो रहे हैं ${done.coerceIn(0, total)}/$total" else "पेज सेव हो रहे हैं"
}

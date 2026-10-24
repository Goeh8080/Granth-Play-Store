package com.wnm.granthprabandhan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps PDF making alive while the app is in the background: a foreground service
 * (type dataSync on Android 14+) with one ongoing notification, e.g. "2 PDF बन रही हैं — 45%".
 *
 * The PDFs themselves are made by the Dart code; this service only keeps the process at
 * foreground priority and shows progress. It stops when every PDF is finished or stopped,
 * and on the Android 15 dataSync time limit ([onTimeout]).
 */
class PdfService : Service() {
    companion object {
        // v2: the first channels were IMPORTANCE_LOW, which some phones (Vivo/OPPO-style
        // "silent notifications" folds) hide completely. A channel's importance can't be
        // raised after it is created, so new ids are used and the old ones are deleted.
        const val CH_PROGRESS = "pdf_progress_v2"
        const val CH_DONE = "pdf_done_v2"
        private val OLD_CHANNELS = listOf("pdf_progress", "pdf_done")
        const val NOTE_ID = 4100

        /** The ONE finished/failed notification of a run (fixed id: it is replaced, never stacked). */
        const val SUMMARY_ID = 4101
        const val GROUP = "granth_work"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PERCENT = "percent"
        const val TAG = "GranthPdf"

        /** True while the service is in the foreground (MainActivity keeps the engine then). */
        @Volatile
        var running = false
            private set

        /** A stop that arrived before the service reached onStartCommand (very short PDFs). */
        @Volatile
        private var stopRequested = false

        private var instance: PdfService? = null

        /** Creates the channels (idempotent). Called at app start and before every notify. */
        fun ensureChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            try {
                val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
                for (old in OLD_CHANNELS) {
                    if (nm.getNotificationChannel(old) != null) nm.deleteNotificationChannel(old)
                }
                nm.createNotificationChannel(NotificationChannel(CH_PROGRESS, "PDF बन रही है", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "PDF बनते समय प्रगति"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                })
                nm.createNotificationChannel(NotificationChannel(CH_DONE, "PDF तैयार", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "PDF बनने पर सूचना"
                })
            } catch (e: Exception) {
                Log.w(TAG, "channels: $e")
            }
        }

        /** Whether anything we post can be seen: app notifications on, and both channels on. */
        fun notificationsVisible(ctx: Context): Boolean {
            return try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (!nm.areNotificationsEnabled()) return false
                if (Build.VERSION.SDK_INT >= 26) {
                    ensureChannels(ctx)
                    listOf(CH_PROGRESS, CH_DONE).all { (nm.getNotificationChannel(it)?.importance ?: 1) != NotificationManager.IMPORTANCE_NONE }
                } else {
                    true
                }
            } catch (e: Exception) {
                true
            }
        }

        private fun openApp(ctx: Context): PendingIntent {
            val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                ?: Intent(ctx, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(ctx, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        @Suppress("DEPRECATION")
        private fun builder(ctx: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel) else Notification.Builder(ctx)

        private fun progressNote(ctx: Context, title: String, text: String, percent: Int): Notification {
            ensureChannels(ctx)
            return builder(ctx, CH_PROGRESS)
                .setSmallIcon(R.drawable.ic_stat_granth)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setProgress(100, PdfNotes.clampPercent(percent), percent <= 0)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setGroup(GROUP)
                .setContentIntent(openApp(ctx))
                .apply { if (Build.VERSION.SDK_INT >= 31) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
                .build()
        }

        /** Start (first call) or update the ongoing notification. Never throws. */
        fun update(ctx: Context, title: String, text: String, percent: Int) {
            val app = ctx.applicationContext
            stopRequested = false
            val svc = instance
            if (svc != null && running) {
                try {
                    val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTE_ID, progressNote(app, title, text, percent))
                } catch (e: Exception) {
                    Log.w(TAG, "update notify: $e")
                }
                return
            }
            cancelSummary(app)
            Log.i(TAG, "start service ($percent%), notifications visible=${notificationsVisible(app)}")
            val i = Intent(app, PdfService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_PERCENT, percent)
            try {
                if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
            } catch (e: Exception) {
                // Android 12+ refuses to start a foreground service from the background:
                // just show the progress as a normal notification.
                Log.w(TAG, "startForegroundService refused: $e")
                try {
                    val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTE_ID, progressNote(app, title, text, percent))
                } catch (e2: Exception) {
                    Log.w(TAG, "fallback notify: $e2")
                }
            }
        }

        fun stop(ctx: Context) {
            val svc = instance
            Log.i(TAG, "stop (service ${if (svc == null) "not started yet" else "running"})")
            if (svc != null && running) {
                svc.finish()
            } else {
                // The start may still be on its way: onStartCommand must still call
                // startForeground (or Android kills the app), then it stops at once.
                stopRequested = true
                try {
                    val nm = ctx.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.cancel(NOTE_ID)
                } catch (_: Exception) {}
            }
        }

        private fun cancelSummary(app: Context) {
            try {
                (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(SUMMARY_ID)
            } catch (_: Exception) {}
        }

        /**
         * Round 8: the ONE notification for a whole run of PDFs, posted once when the last one
         * ends ("PDF तैयार" / "50 PDF तैयार" / "48 तैयार, 2 नहीं बनीं"). Fixed id, so it is replaced
         * by the next run's progress and never stacks; a tap opens the PDF when there is exactly
         * one finished PDF, else the app.
         */
        fun summary(ctx: Context, done: Int, failed: Int, names: List<String>, uri: String?, error: String) {
            val app = ctx.applicationContext
            if (done + failed <= 0) return
            try {
                ensureChannels(app)
                var tap = openApp(app)
                if (done == 1 && failed == 0 && uri != null && uri.startsWith("content://")) {
                    val view = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(Uri.parse(uri), "application/pdf")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    if (view.resolveActivity(app.packageManager) != null) {
                        tap = PendingIntent.getActivity(app, 2, view, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    }
                }
                val text = PdfNotes.summaryText(done, failed, names, error)
                val n = builder(app, CH_DONE)
                    .setSmallIcon(R.drawable.ic_stat_granth)
                    .setContentTitle(PdfNotes.summaryTitle(done, failed))
                    .setContentText(text)
                    .setStyle(Notification.BigTextStyle().bigText(text))
                    .setCategory(if (done == 0) Notification.CATEGORY_ERROR else Notification.CATEGORY_STATUS)
                    .setGroup(GROUP)
                    .setOnlyAlertOnce(true)
                    .setAutoCancel(true)
                    .setContentIntent(tap)
                    .build()
                (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(SUMMARY_ID, n)
                Log.i(TAG, "summary posted: $done done, $failed failed (visible=${notificationsVisible(app)})")
            } catch (e: Exception) {
                Log.w(TAG, "summary notify: $e")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "PDF बन रही है"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val percent = intent?.getIntExtra(EXTRA_PERCENT, 0) ?: 0
        val n = progressNote(this, title, text, percent)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTE_ID, n)
            }
            running = true
            Log.i(TAG, "startForeground ok")
        } catch (e: Exception) {
            // Not allowed right now (e.g. started too late from the background): plain notification.
            Log.w(TAG, "startForeground failed: $e")
            running = false
            try {
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTE_ID, n)
            } catch (_: Exception) {}
            stopSelf()
        }
        if (PdfNotes.stopRightAway(stopRequested, running)) {
            // Every PDF already ended while the service was starting.
            stopRequested = false
            finish()
        }
        // Not restarted by the system: PDFs are made by the app process, not by the service.
        return START_NOT_STICKY
    }

    /** Android 15: dataSync services have a daily time limit. Stop cleanly when it is hit. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "onTimeout (Android 15 dataSync limit) — stopping")
        finish()
    }

    @Suppress("DEPRECATION")
    fun finish() {
        running = false
        try {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
        } catch (_: Exception) {}
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        if (instance === this) instance = null
        super.onDestroy()
    }
}

/** Small pure helpers, unit-tested on the JVM (test/.../PdfNotesTest.kt). */
object PdfNotes {
    fun clampPercent(p: Int): Int = p.coerceIn(0, 100)

    /** onStartCommand: stop straight after startForeground when the stop came first. */
    fun stopRightAway(stopRequested: Boolean, inForeground: Boolean): Boolean = stopRequested && inForeground

    fun summaryTitle(done: Int, failed: Int): String = when {
        failed == 0 && done == 1 -> "PDF तैयार"
        failed == 0 -> "$done PDF तैयार"
        done == 0 && failed == 1 -> "PDF नहीं बनी"
        done == 0 -> "$failed PDF नहीं बनीं"
        else -> "$done तैयार, $failed नहीं बनीं"
    }

    /** Up to 3 names, then "+N और"; a failure shows its reason when it is the only news. */
    fun summaryText(done: Int, failed: Int, names: List<String>, error: String): String {
        val shown = names.filter { it.isNotBlank() }.take(3)
        val more = (done + failed - shown.size).coerceAtLeast(0)
        val list = if (shown.isEmpty()) "" else shown.joinToString(", ") + if (more > 0) " +$more और" else ""
        return when {
            done == 0 && error.isNotBlank() && failed == 1 -> if (list.isEmpty()) error else "$list — $error"
            list.isNotEmpty() -> list
            else -> "ऐप खोलकर देखें"
        }
    }
}

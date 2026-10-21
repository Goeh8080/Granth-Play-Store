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
        private const val CH_PROGRESS = "pdf_progress"
        private const val CH_DONE = "pdf_done"
        private const val NOTE_ID = 4100
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PERCENT = "percent"

        /** True while the service is in the foreground (MainActivity keeps the engine then). */
        @Volatile
        var running = false
            private set

        private var instance: PdfService? = null

        private fun channels(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(NotificationChannel(CH_PROGRESS, "PDF बन रही है", NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            })
            nm.createNotificationChannel(NotificationChannel(CH_DONE, "PDF तैयार", NotificationManager.IMPORTANCE_DEFAULT))
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
            channels(ctx)
            return builder(ctx, CH_PROGRESS)
                .setSmallIcon(R.drawable.ic_stat_pdf)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setProgress(100, percent.coerceIn(0, 100), percent <= 0)
                .setContentIntent(openApp(ctx))
                .apply { if (Build.VERSION.SDK_INT >= 31) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
                .build()
        }

        /** Start (first call) or update the ongoing notification. Never throws. */
        fun update(ctx: Context, title: String, text: String, percent: Int) {
            val app = ctx.applicationContext
            val svc = instance
            if (svc != null && running) {
                try {
                    val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTE_ID, progressNote(app, title, text, percent))
                } catch (_: Exception) {}
                return
            }
            val i = Intent(app, PdfService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_PERCENT, percent)
            try {
                if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
            } catch (_: Exception) {
                // Android 12+ refuses to start a foreground service from the background:
                // just show the progress as a normal notification.
                try {
                    val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTE_ID, progressNote(app, title, text, percent))
                } catch (_: Exception) {}
            }
        }

        fun stop(ctx: Context) {
            val svc = instance
            if (svc != null) {
                svc.finish()
            } else {
                try {
                    val nm = ctx.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.cancel(NOTE_ID)
                } catch (_: Exception) {}
            }
        }

        /** "PDF तैयार" notification; a tap opens the PDF (or the app when it can't be opened). */
        fun done(ctx: Context, id: Int, name: String, uri: String?) {
            val app = ctx.applicationContext
            try {
                channels(app)
                var tap = openApp(app)
                if (uri != null && uri.startsWith("content://")) {
                    val view = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(Uri.parse(uri), "application/pdf")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    if (view.resolveActivity(app.packageManager) != null) {
                        tap = PendingIntent.getActivity(app, id, view, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    }
                }
                val n = builder(app, CH_DONE)
                    .setSmallIcon(R.drawable.ic_stat_pdf)
                    .setContentTitle("PDF तैयार")
                    .setContentText(name)
                    .setAutoCancel(true)
                    .setContentIntent(tap)
                    .build()
                val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTE_ID + 1 + (id and 0xFFFF), n)
            } catch (_: Exception) {}
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
        } catch (_: Exception) {
            // Not allowed right now (e.g. started too late from the background): plain notification.
            running = false
            try {
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTE_ID, n)
            } catch (_: Exception) {}
            stopSelf()
        }
        // Not restarted by the system: PDFs are made by the app process, not by the service.
        return START_NOT_STICKY
    }

    /** Android 15: dataSync services have a daily time limit. Stop cleanly when it is hit. */
    override fun onTimeout(startId: Int, fgsType: Int) {
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

package com.wnm.granthprabandhan

import android.Manifest
import android.app.ActivityManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Native side of the Flutter port. Replaces the React Native `GranthDownloads` module:
 * copies finished PDFs into Downloads and saved pages into Pictures/ग्रंथ प्रबंधन,
 * and closes the app after the in-app exit confirmation.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.wnm.granthprabandhan/downloads"
    private val album = "ग्रंथ प्रबंधन"
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null

    // PDF page pictures are scaled / re-encoded here, off the UI thread, with the platform's
    // JPEG codec (much faster than pure Dart, and big photos are decoded at reduced size).
    private val imageWorkers = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors().coerceIn(2, 4))

    // ---- keep PDFs going when the app is swiped away ----
    // The Flutter engine (where the PDFs are made) normally dies with the activity. It is
    // created here and cached, and kept alive while the PDF service runs; the next launch
    // attaches to it and shows the PDFs where they are.
    private val engineId = "granth-main"

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        FlutterEngineCache.getInstance().get(engineId)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(engineId, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = !PdfService.running

    override fun onDestroy() {
        val destroyEngine = !PdfService.running
        super.onDestroy()
        if (destroyEngine) FlutterEngineCache.getInstance().remove(engineId)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyToDownloads", "saveImage" -> withLegacyPermission(call, result)
                "prepareImage" -> prepareImage(call, result)
                "deviceInfo" -> result.success(deviceInfo())
                "freeBytes" -> result.success(freeBytes())
                "pdfProgress" -> {
                    PdfService.update(applicationContext, call.argument<String>("title") ?: "PDF", call.argument<String>("text") ?: "", call.argument<Int>("percent") ?: 0)
                    result.success(null)
                }
                "pdfStop" -> {
                    PdfService.stop(applicationContext)
                    result.success(null)
                }
                "pdfDone" -> {
                    PdfService.done(applicationContext, call.argument<Int>("id") ?: 0, call.argument<String>("name") ?: "PDF", call.argument<String>("uri"))
                    result.success(null)
                }
                "askNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
                    }
                    result.success(null)
                }
                "exitApp" -> {
                    result.success(null)
                    finishAffinity()
                }
                else -> result.notImplemented()
            }
        }
    }

    // A shared link opened while the app is already running arrives here (singleTask).
    // Keep it as the current intent so the link plugin and a later re-create see the new link.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    /** Lets the PDF maker size itself to the phone: low-RAM phones build one PDF at a time. */
    private fun deviceInfo(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am?.getMemoryInfo(mi)
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "lowRam" to (am?.isLowRamDevice ?: false),
            "memClassMb" to (am?.memoryClass ?: 128),
            "largeMemClassMb" to (am?.largeMemoryClass ?: 256),
            "totalMem" to mi.totalMem,
            "availMem" to mi.availMem,
        )
    }

    /**
     * Reads a page picture from [src], scales it so the longer side is at most [maxSide]
     * (decoding big photos at 1/2, 1/4… size to save memory), flattens transparency on
     * white and writes a JPEG to [out]. Returns width/height, or an error the Dart side
     * turns into a "picture not available" placeholder.
     */
    private fun prepareImage(call: MethodCall, result: MethodChannel.Result) {
        val src = call.argument<String>("src")
        val out = call.argument<String>("out")
        val maxSide = call.argument<Int>("maxSide") ?: 1800
        val quality = call.argument<Int>("quality") ?: 85
        if (src == null || out == null) {
            result.error("args", "src/out missing", null)
            return
        }
        imageWorkers.execute {
            try {
                val r = scaleToJpeg(File(src), File(out), maxSide, quality)
                runOnUiThread { result.success(r) }
            } catch (e: Throwable) {
                File(out).delete()
                runOnUiThread { result.error("image", e.toString(), null) }
            }
        }
    }

    private fun scaleToJpeg(src: File, out: File, maxSide: Int, quality: Int): Map<String, Int> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(src.absolutePath, bounds)
        val w0 = bounds.outWidth
        val h0 = bounds.outHeight
        if (w0 <= 0 || h0 <= 0) throw IllegalArgumentException("not an image")
        var sample = 1
        while (maxOf(w0, h0) / (sample * 2) >= maxSide) sample *= 2
        var bmp: Bitmap? = null
        var tries = 0
        while (bmp == null) {
            try {
                bmp = BitmapFactory.decodeFile(src.absolutePath, BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }) ?: throw IllegalArgumentException("decode failed")
            } catch (e: OutOfMemoryError) {
                if (++tries > 3) throw e
                sample *= 2 // low-RAM phone: try a smaller decode
            }
        }
        var b: Bitmap = bmp
        val side = maxOf(b.width, b.height)
        if (side > maxSide) {
            val k = maxSide.toFloat() / side
            val scaled = Bitmap.createScaledBitmap(b, maxOf(1, (b.width * k).toInt()), maxOf(1, (b.height * k).toInt()), true)
            if (scaled != b) b.recycle()
            b = scaled
        }
        if (b.hasAlpha()) {
            val flat = Bitmap.createBitmap(b.width, b.height, Bitmap.Config.ARGB_8888)
            Canvas(flat).apply {
                drawColor(Color.WHITE)
                drawBitmap(b, 0f, 0f, null)
            }
            b.recycle()
            b = flat
        }
        val w = b.width
        val h = b.height
        out.parentFile?.mkdirs()
        val part = File(out.absolutePath + ".part")
        try {
            FileOutputStream(part).use { if (!b.compress(Bitmap.CompressFormat.JPEG, quality, it)) throw IllegalStateException("encode") }
            if (!part.renameTo(out)) throw IllegalStateException("rename")
        } catch (e: Throwable) {
            part.delete()
            throw e
        } finally {
            b.recycle()
        }
        return mapOf("w" to w, "h" to h)
    }

    /** Free space (bytes) where the app keeps its PDFs. */
    private fun freeBytes(): Long = try {
        StatFs(filesDir.absolutePath).availableBytes
    } catch (e: Exception) {
        -1L
    }

    private fun withLegacyPermission(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            pending = call to result
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 4711)
            return
        }
        run(call, result)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 4711) return
        val p = pending ?: return
        pending = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            run(p.first, p.second)
        } else {
            p.second.error("denied", "storage permission denied", null)
        }
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val name = call.argument<String>("name") ?: "granth"
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (path == null || !File(path).exists()) {
            result.error("missing", "file not found", null)
            return
        }
        Thread {
            try {
                val out = if (call.method == "copyToDownloads") toDownloads(File(path), name, mime) else toAlbum(File(path), name, mime)
                runOnUiThread { result.success(out) }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message, null) }
            }
        }.start()
    }

    private fun toDownloads(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("insert")
            try {
                val out = contentResolver.openOutputStream(uri) ?: throw IllegalStateException("open")
                out.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            } catch (e: Exception) {
                // Never leave a half-written, hidden (pending) file behind in Downloads.
                try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        dir.mkdirs()
        val dest = unique(dir, name)
        try {
            src.copyTo(dest, overwrite = false)
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
        MediaScannerConnection.scanFile(this, arrayOf(dest.absolutePath), arrayOf(mime), null)
        return dest.absolutePath
    }

    private fun toAlbum(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, if (mime.startsWith("image/")) mime else "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/" + album)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("insert")
            try {
                val out = contentResolver.openOutputStream(uri) ?: throw IllegalStateException("open")
                out.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            } catch (e: Exception) {
                try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), album)
        dir.mkdirs()
        val dest = unique(dir, name)
        try {
            src.copyTo(dest, overwrite = false)
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
        MediaScannerConnection.scanFile(this, arrayOf(dest.absolutePath), arrayOf(mime), null)
        return dest.absolutePath
    }

    private fun unique(dir: File, name: String): File {
        var f = File(dir, name)
        if (!f.exists()) return f
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (f.exists()) {
            f = File(dir, "$base ($i)$ext")
            i++
        }
        return f
    }
}

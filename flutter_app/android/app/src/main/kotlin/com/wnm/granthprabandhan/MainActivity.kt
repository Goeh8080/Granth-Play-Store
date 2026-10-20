package com.wnm.granthprabandhan

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Native side of the Flutter port. Replaces the React Native `GranthDownloads` module:
 * copies finished PDFs into Downloads and saved pages into Pictures/ग्रंथ प्रबंधन,
 * and closes the app after the in-app exit confirmation.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.wnm.granthprabandhan/downloads"
    private val album = "ग्रंथ प्रबंधन"
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyToDownloads", "saveImage" -> withLegacyPermission(call, result)
                "exitApp" -> {
                    result.success(null)
                    finishAffinity()
                }
                else -> result.notImplemented()
            }
        }
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
            contentResolver.openOutputStream(uri)?.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        dir.mkdirs()
        val dest = unique(dir, name)
        src.copyTo(dest, overwrite = false)
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
            contentResolver.openOutputStream(uri)?.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), album)
        dir.mkdirs()
        val dest = unique(dir, name)
        src.copyTo(dest, overwrite = false)
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

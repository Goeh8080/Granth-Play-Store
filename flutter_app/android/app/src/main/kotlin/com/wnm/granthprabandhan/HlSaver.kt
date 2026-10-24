package com.wnm.granthprabandhan

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream

/**
 * Saving finished files into the phone's public folders (shared by the main activity channel
 * and the native Photo Highlighter): PDFs / exports into Downloads, pages into
 * Pictures/ग्रंथ प्रबंधन. Never leaves a half-written file behind.
 */
object HlSaver {
    const val ALBUM = "ग्रंथ प्रबंधन"

    fun toDownloads(ctx: Context, src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("insert")
            try {
                val out = ctx.contentResolver.openOutputStream(uri) ?: throw IllegalStateException("open")
                out.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            } catch (e: Exception) {
                // Never leave a half-written, hidden (pending) file behind in Downloads.
                try { ctx.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            ctx.contentResolver.update(uri, values, null, null)
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
        MediaScannerConnection.scanFile(ctx, arrayOf(dest.absolutePath), arrayOf(mime), null)
        return dest.absolutePath
    }

    fun toAlbum(ctx: Context, src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, if (mime.startsWith("image/")) mime else "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/" + ALBUM)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = ctx.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("insert")
            try {
                val out = ctx.contentResolver.openOutputStream(uri) ?: throw IllegalStateException("open")
                out.use { o -> FileInputStream(src).use { it.copyTo(o) } }
            } catch (e: Exception) {
                try { ctx.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            ctx.contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), ALBUM)
        dir.mkdirs()
        val dest = unique(dir, name)
        try {
            src.copyTo(dest, overwrite = false)
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
        MediaScannerConnection.scanFile(ctx, arrayOf(dest.absolutePath), arrayOf(mime), null)
        return dest.absolutePath
    }

    fun unique(dir: File, name: String): File {
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

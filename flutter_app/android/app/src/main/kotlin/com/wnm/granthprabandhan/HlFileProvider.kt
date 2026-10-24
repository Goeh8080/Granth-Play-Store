package com.wnm.granthprabandhan

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/**
 * Photo Highlighter files: camera captures (the camera app writes the photo into cache/hl-camera
 * through this provider and the WebView reads it back) and files shared from the page
 * (cache/hl-out/<stamp>/<name>, read-only). Only those two folders are reachable; nothing is
 * exported (access is granted per share).
 */
class HlFileProvider : ContentProvider() {
    companion object {
        fun authority(ctx: Context) = "${ctx.packageName}.hlfiles"
        fun dir(ctx: Context) = File(ctx.cacheDir, "hl-camera").apply { mkdirs() }
        fun uriFor(ctx: Context, f: File): Uri = Uri.parse("content://${authority(ctx)}/camera/${f.name}")
        fun outDir(ctx: Context) = File(ctx.cacheDir, "hl-out").apply { mkdirs() }

        /** content:// address of a finished page download `hl-out/<stamp>/<name>`. */
        fun outUri(ctx: Context, f: File): Uri =
            Uri.Builder().scheme("content").authority(authority(ctx)).appendPath("out").appendPath(f.parentFile?.name ?: "").appendPath(f.name).build()

        /** Which file a path (`camera/<name>` or `out/<stamp>/<name>`) names, only inside the two folders. */
        fun resolve(camera: File, out: File, seg: List<String>): File? {
            val root: File
            val rel: List<String>
            when {
                seg.size == 2 && seg[0] == "camera" -> { root = camera; rel = listOf(seg[1]) }
                seg.size == 3 && seg[0] == "out" -> { root = out; rel = listOf(seg[1], seg[2]) }
                else -> return null
            }
            val d = root.canonicalFile
            val f = rel.fold(d) { acc, n -> File(acc, n) }.canonicalFile
            // Exactly `depth` levels below the folder: no "..", no symlink games, no folder itself.
            var p: File? = f
            repeat(rel.size) { p = p?.parentFile }
            return if (p == d) f else null
        }

        /** Page downloads kept for sharing are removed after a day. */
        fun cleanupOut(ctx: Context) {
            val cut = System.currentTimeMillis() - 24 * 3600 * 1000L
            outDir(ctx).listFiles()?.forEach { if (it.lastModified() < cut) it.deleteRecursively() }
        }

        /** Old captures (a day+) are removed when a new one starts. */
        fun cleanup(ctx: Context) {
            val cut = System.currentTimeMillis() - 24 * 3600 * 1000L
            dir(ctx).listFiles()?.forEach { if (it.lastModified() < cut) it.delete() }
        }
    }

    private fun fileOf(uri: Uri): File? {
        val ctx = context ?: return null
        return resolve(dir(ctx), outDir(ctx), uri.pathSegments)
    }

    private fun isOut(uri: Uri) = uri.pathSegments.firstOrNull() == "out"

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val f = fileOf(uri) ?: throw SecurityException("not allowed")
        if (isOut(uri) && mode != "r") throw SecurityException("read only")
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode))
    }

    override fun getType(uri: Uri): String {
        if (!isOut(uri)) return "image/jpeg"
        return HlLogic.mimeFor(uri.lastPathSegment ?: "", "")
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val f = fileOf(uri) ?: return null
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val c = MatrixCursor(cols)
        c.addRow(cols.map<String, Any?> { if (it == OpenableColumns.SIZE) f.length() else if (it == OpenableColumns.DISPLAY_NAME) f.name else null }.toTypedArray<Any?>())
        return c
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

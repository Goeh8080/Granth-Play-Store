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
 * Photo Highlighter camera captures: the camera app writes the photo into our cache
 * (cache/hl-camera) through this provider, and the WebView reads it back. Only that one
 * folder is reachable; nothing is exported.
 */
class HlFileProvider : ContentProvider() {
    companion object {
        fun authority(ctx: Context) = "${ctx.packageName}.hlfiles"
        fun dir(ctx: Context) = File(ctx.cacheDir, "hl-camera").apply { mkdirs() }
        fun uriFor(ctx: Context, f: File): Uri = Uri.parse("content://${authority(ctx)}/camera/${f.name}")

        /** Old captures (a day+) are removed when a new one starts. */
        fun cleanup(ctx: Context) {
            val cut = System.currentTimeMillis() - 24 * 3600 * 1000L
            dir(ctx).listFiles()?.forEach { if (it.lastModified() < cut) it.delete() }
        }
    }

    private fun fileOf(uri: Uri): File? {
        val ctx = context ?: return null
        val seg = uri.pathSegments
        if (seg.size != 2 || seg[0] != "camera") return null
        val d = dir(ctx).canonicalFile
        val f = File(d, seg[1]).canonicalFile
        return if (f.parentFile == d) f else null
    }

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val f = fileOf(uri) ?: throw SecurityException("not allowed")
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode))
    }

    override fun getType(uri: Uri): String = "image/jpeg"

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

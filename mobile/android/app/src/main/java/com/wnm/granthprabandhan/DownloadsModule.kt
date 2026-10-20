package com.wnm.granthprabandhan

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.uimanager.ViewManager
import com.wnm.granthprabandhan.back.GranthBack
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import android.util.Base64

class DownloadsModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  override fun getName() = "GranthDownloads"

  private val streams = HashMap<String, FileOutputStream>()

  private fun fileOf(path: String): File = File(path.removePrefix("file://"))

  @ReactMethod
  fun getAppVersion(promise: Promise) {
    try {
      val info = reactApplicationContext.packageManager.getPackageInfo(reactApplicationContext.packageName, 0)
      promise.resolve(info.versionName ?: "")
    } catch (error: Exception) {
      promise.reject("version", error.message, error)
    }
  }

  @ReactMethod
  fun beginWrite(path: String, promise: Promise) {
    try {
      val file = fileOf(path)
      file.parentFile?.mkdirs()
      streams.remove(path)?.close()
      if (file.exists()) file.delete()
      streams[path] = FileOutputStream(file, false)
      promise.resolve(true)
    } catch (error: Exception) {
      promise.reject("begin", error.message, error)
    }
  }

  @ReactMethod
  fun appendWrite(path: String, base64: String, promise: Promise) {
    try {
      val out = streams[path] ?: throw IllegalStateException("file not open")
      val bytes = Base64.decode(base64, Base64.DEFAULT)
      out.write(bytes)
      promise.resolve(bytes.size)
    } catch (error: Exception) {
      promise.reject("append", error.message, error)
    }
  }

  @ReactMethod
  fun finishWrite(path: String, promise: Promise) {
    try {
      val out = streams.remove(path) ?: throw IllegalStateException("file not open")
      out.flush()
      out.close()
      val file = fileOf(path)
      val size = file.length()
      if (size < 64) {
        file.delete()
        promise.reject("empty", "empty file")
        return
      }
      if (file.name.endsWith(".pdf", true)) {
        FileInputStream(file).use { input ->
          val head = ByteArray(5)
          val read = input.read(head)
          val magic = if (read >= 4) String(head, 0, 4, Charsets.US_ASCII) else ""
          if (magic != "%PDF") {
            file.delete()
            promise.reject("badpdf", "not a pdf")
            return
          }
        }
      }
      promise.resolve(size.toDouble())
    } catch (error: Exception) {
      promise.reject("finish", error.message, error)
    }
  }

  @ReactMethod
  fun copyToDownloads(filePath: String, displayName: String, mime: String, promise: Promise) {
    try {
      val source = File(filePath.removePrefix("file://"))
      if (!source.exists()) {
        promise.reject("missing", "file missing")
        return
      }
      val name = displayName.ifBlank { source.name }
      val type = mime.ifBlank { "application/pdf" }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = reactApplicationContext.contentResolver
        val values = ContentValues().apply {
          put(MediaStore.MediaColumns.DISPLAY_NAME, name)
          put(MediaStore.MediaColumns.MIME_TYPE, type)
          put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
          put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
          ?: throw IllegalStateException("downloads insert failed")
        resolver.openOutputStream(uri)?.use { output ->
          FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("downloads stream failed")
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        promise.resolve(uri.toString())
        return
      }
      val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
      if (!dir.exists()) dir.mkdirs()
      val dest = File(dir, name)
      source.copyTo(dest, overwrite = true)
      promise.resolve(dest.absolutePath)
    } catch (error: Exception) {
      promise.reject("download", error.message, error)
    }
  }

  /** Copy a picture into the phone gallery (Pictures/Granth). No storage permission is needed on Android 10+. */
  @ReactMethod
  fun copyToPictures(filePath: String, displayName: String, mime: String, promise: Promise) {
    try {
      val source = File(filePath.removePrefix("file://"))
      if (!source.exists()) {
        promise.reject("missing", "file missing")
        return
      }
      val name = displayName.ifBlank { source.name }
      val type = mime.ifBlank { "image/jpeg" }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = reactApplicationContext.contentResolver
        val values = ContentValues().apply {
          put(MediaStore.MediaColumns.DISPLAY_NAME, name)
          put(MediaStore.MediaColumns.MIME_TYPE, type)
          put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Granth")
          put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
          ?: throw IllegalStateException("gallery insert failed")
        try {
          resolver.openOutputStream(uri)?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
          } ?: throw IllegalStateException("gallery stream failed")
        } catch (error: Exception) {
          resolver.delete(uri, null, null)
          throw error
        }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        promise.resolve(uri.toString())
        return
      }
      val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Granth")
      if (!dir.exists()) dir.mkdirs()
      val dest = File(dir, name)
      source.copyTo(dest, overwrite = true)
      android.media.MediaScannerConnection.scanFile(reactApplicationContext, arrayOf(dest.absolutePath), arrayOf(type), null)
      promise.resolve(dest.absolutePath)
    } catch (error: Exception) {
      promise.reject("gallery", error.message, error)
    }
  }

  /** Open a content:// URI in the user's viewer app. Rejects with "no-viewer" when none is installed. */
  @ReactMethod
  fun viewUri(uri: String, mime: String, promise: Promise) {
    val activity = reactApplicationContext.currentActivity
    if (activity == null) {
      promise.reject("no-activity", "app not in foreground")
      return
    }
    val intent = Intent(Intent.ACTION_VIEW).apply {
      setDataAndType(Uri.parse(uri), mime.ifBlank { "application/pdf" })
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    activity.runOnUiThread {
      try {
        activity.startActivity(intent)
        promise.resolve(true)
      } catch (error: ActivityNotFoundException) {
        promise.reject("no-viewer", "no app can open this file", error)
      } catch (error: Exception) {
        promise.reject("open", error.message, error)
      }
    }
  }

  @ReactMethod
  fun exitApp() {
    val activity = reactApplicationContext.currentActivity ?: return
    GranthBack.allowExit = true
    activity.runOnUiThread { activity.finishAffinity() }
  }
}

class DownloadsPackage : ReactPackage {
  override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> =
    listOf(DownloadsModule(reactContext))

  override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> =
    emptyList()
}

package com.wnm.granthprabandhan

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.MimeTypeMap
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Photo Highlighter in its own native Activity: a plain full-screen android.webkit.WebView
 * (hardware accelerated) on the page the app serves from 127.0.0.1. There is no Flutter view,
 * PlatformView or gesture arena in the touch path, so pointer / touch events and pinch-zoom
 * go straight from the screen to the page, the way they do in Chrome.
 *
 * Flutter starts the local server, then opens this with the page address ([EXTRA_URL]);
 * the Hindi first-use notice is polled from the server's /__status.
 */
class HighlighterActivity : Activity() {
    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_KEEP_AWAKE = "keepAwake"
        private const val REQ_PICK = 4731
        private const val REQ_CAMERA = 4732
        private const val REQ_STORAGE = 4733
        private const val BG = 0xFF111111.toInt()
        private const val BROWN = 0xFF4A2C0A.toInt()
        private const val CREAM = 0xFFFDF6E3.toInt()
        private const val TAG = "GranthHL"
    }

    private lateinit var web: WebView
    private lateinit var banner: TextView
    private val ui = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val statusIo = Executors.newSingleThreadExecutor()
    private var transfer: HlTransfer? = null
    private var chooser: ValueCallback<Array<Uri>>? = null
    private var cameraFile: File? = null
    private var statusUrl: String? = null
    private var noticeHidden = false
    private var polling = false
    private var backCallback: Any? = null
    private var pendingSave: Triple<File, String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) {
            // Re-created after the app process was killed: the local server is gone, go back to the app.
            finish()
            return
        }
        val url = intent.getStringExtra(EXTRA_URL)
        val origin = url?.let { HlLogic.originOf(it) }
        if (url == null || origin == null) {
            finish()
            return
        }
        statusUrl = "$origin/__status"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.setDecorFitsSystemWindows(false)
        @Suppress("DEPRECATION")
        window.statusBarColor = BG
        @Suppress("DEPRECATION")
        window.navigationBarColor = BG
        if (intent.getBooleanExtra(EXTRA_KEEP_AWAKE, false)) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        transfer = HlTransfer(
            HlFileProvider.outDir(this),
            { Base64.decode(it, Base64.DEFAULT) },
            object : HlTransfer.Listener {
                override fun onFile(file: File, name: String, mime: String, mode: String) = deliver(file, name, mime, mode)
                override fun onFail() = toast("फ़ाइल सेव नहीं हो सकी")
            },
        )
        io.execute { HlFileProvider.cleanupOut(this); HlFileProvider.cleanup(this) }

        banner = TextView(this).apply {
            setTextColor(CREAM)
            setBackgroundColor(BROWN)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            val h = dp(14); val v = dp(8)
            setPadding(h, v, h, v)
            visibility = View.GONE
            setOnClickListener { noticeHidden = true; visibility = View.GONE }
        }
        web = WebView(this)
        configure(web)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BG)
            addView(banner, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            root.setOnApplyWindowInsetsListener { v, ins ->
                val bars = ins.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                val ime = ins.getInsets(WindowInsets.Type.ime())
                val p = HlLogic.padding(bars.left, bars.top, bars.right, bars.bottom, ime.bottom)
                v.setPadding(p[0], p[1], p[2], p[3])
                WindowInsets.CONSUMED
            }
        }
        setContentView(root)

        if (Build.VERSION.SDK_INT >= 33) {
            val cb = OnBackInvokedCallback { goBackOrFinish() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb)
            backCallback = cb
        }
        web.loadUrl(url)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun configure(w: WebView) {
        w.setBackgroundColor(BG)
        w.overScrollMode = View.OVER_SCROLL_NEVER
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) WebView.setWebContentsDebuggingEnabled(true)
        w.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            // The page's own <meta viewport> decides (as in Chrome): width=device-width, pinch-zoom allowed.
            useWideViewPort = true
            loadWithOverviewMode = false
            setSupportZoom(true)
            builtInZoomControls = true
            displayZoomControls = false
            textZoom = 100 // the page's own layout, whatever the phone's font size
            mediaPlaybackRequiresUserGesture = true
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        w.addJavascriptInterface(Bridge(), "GranthHL")
        w.setDownloadListener { url, _, disposition, mime, _ ->
            if (HlLogic.isLocalUrl(url)) {
                val name = HlLogic.safeName(URLUtil.guessFileName(url, disposition, mime), mime ?: "")
                w.post { w.evaluateJavascript(HlLogic.deliverScript(url, name), null) }
            } else {
                toast("फ़ाइल सेव नहीं हो सकी")
            }
        }
        w.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                !HlLogic.isLocalUrl(request.url.toString()) // anything else (none expected) opens nowhere

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) showNotice("पेज नहीं खुल सका — पीछे जाकर Photo Highlighter दोबारा खोलें।", force = true)
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                Log.w(TAG, "render process gone (crash=${detail.didCrash()})")
                finish()
                return true
            }
        }
        w.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(view: WebView, cb: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                chooser?.onReceiveValue(null)
                chooser = cb
                return try {
                    startPicker(params)
                    true
                } catch (e: Exception) {
                    Log.w(TAG, "picker: $e")
                    chooser = null
                    cb.onReceiveValue(null)
                    true
                }
            }

            override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
                if (isFinishing) { result.cancel(); return true }
                AlertDialog.Builder(this@HighlighterActivity).setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setOnCancelListener { result.cancel() }.show()
                return true
            }

            override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
                if (isFinishing) { result.cancel(); return true }
                AlertDialog.Builder(this@HighlighterActivity).setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setNegativeButton("रद्द करें") { _, _ -> result.cancel() }
                    .setOnCancelListener { result.cancel() }.show()
                return true
            }

            override fun onJsPrompt(view: WebView, url: String?, message: String?, defaultValue: String?, result: JsPromptResult): Boolean {
                if (isFinishing) { result.cancel(); return true }
                val input = EditText(this@HighlighterActivity).apply { setText(defaultValue ?: "") }
                AlertDialog.Builder(this@HighlighterActivity).setMessage(message).setView(input)
                    .setPositiveButton("OK") { _, _ -> result.confirm(input.text.toString()) }
                    .setNegativeButton("रद्द करें") { _, _ -> result.cancel() }
                    .setOnCancelListener { result.cancel() }.show()
                return true
            }

            override fun onPermissionRequest(request: PermissionRequest) = request.deny()

            override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                Log.d(TAG, "${m.message()} (${m.sourceId()}:${m.lineNumber()})")
                return true
            }
        }
    }

    // ---- file chooser -------------------------------------------------------------------

    /** Camera for capture inputs, otherwise the system picker (gallery / files, multiple). */
    private fun startPicker(p: WebChromeClient.FileChooserParams) {
        val plan = HlLogic.plan(
            p.acceptTypes?.toList() ?: emptyList(),
            multiple = p.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE,
            capture = p.isCaptureEnabled,
        ) { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }
        if (plan.camera) {
            HlFileProvider.cleanup(this)
            val f = File(HlFileProvider.dir(this), "IMG_${System.currentTimeMillis()}.jpg")
            val uri = HlFileProvider.uriFor(this, f)
            cameraFile = f
            val i = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                .putExtra(MediaStore.EXTRA_OUTPUT, uri)
                .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            i.clipData = ClipData.newRawUri("", uri)
            startActivityForResult(i, REQ_CAMERA)
            return
        }
        val types = plan.types
        val i = Intent(Intent.ACTION_GET_CONTENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType(if (types.size == 1) types[0] else "*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, plan.multiple)
        if (types.size > 1) i.putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
        startActivityForResult(Intent.createChooser(i, null), REQ_PICK)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_PICK && requestCode != REQ_CAMERA) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val cb = chooser ?: return
        chooser = null
        var out: Array<Uri>? = null
        if (resultCode == RESULT_OK) {
            val uris = mutableListOf<Uri>()
            if (requestCode == REQ_PICK) {
                val clip = data?.clipData
                if (clip != null) {
                    for (k in 0 until clip.itemCount) clip.getItemAt(k).uri?.let { uris += it }
                } else {
                    data?.data?.let { uris += it }
                }
            } else {
                cameraFile?.let { if (it.length() > 0) uris += HlFileProvider.uriFor(this, it) }
            }
            out = uris.toTypedArray()
        }
        cameraFile = null
        cb.onReceiveValue(out) // null = cancelled
    }

    // ---- downloads / share from the page --------------------------------------------------

    private inner class Bridge {
        @JavascriptInterface
        fun postMessage(msg: String?) {
            if (msg != null) transfer?.handle(msg)
        }
    }

    private fun toast(text: String) {
        runOnUiThread { Toast.makeText(this, text, Toast.LENGTH_LONG).show() }
    }

    private fun deliver(file: File, name: String, mime: String, mode: String) {
        if (mode == "share") {
            runOnUiThread { share(file, name, mime) }
            return
        }
        io.execute { save(file, name, mime) }
    }

    private fun save(file: File, name: String, mime: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pendingSave = Triple(file, name, mime)
            runOnUiThread { requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQ_STORAGE) }
            return
        }
        try {
            HlSaver.toDownloads(this, file, name, mime)
            file.parentFile?.deleteRecursively()
            toast("Downloads में सेव हुआ: $name")
        } catch (e: Exception) {
            Log.w(TAG, "save: $e")
            runOnUiThread { share(file, name, mime) } // still gets the file out
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != REQ_STORAGE) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
            return
        }
        val p = pendingSave ?: return
        pendingSave = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) io.execute { save(p.first, p.second, p.third) } else share(p.first, p.second, p.third)
    }

    private fun share(file: File, name: String, mime: String) {
        if (isFinishing) return
        try {
            val uri = HlFileProvider.outUri(this, file)
            val send = Intent(Intent.ACTION_SEND).setType(mime)
                .putExtra(Intent.EXTRA_STREAM, uri)
                .putExtra(Intent.EXTRA_TITLE, name)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            send.clipData = ClipData.newRawUri(name, uri)
            startActivity(Intent.createChooser(send, name))
        } catch (e: Exception) {
            Log.w(TAG, "share: $e")
            toast("फ़ाइल सेव नहीं हो सकी")
        }
    }

    // ---- notice banner (from the app's local server) ----------------------------------------

    private fun showNotice(text: String?, force: Boolean = false) {
        if (text.isNullOrEmpty() || (noticeHidden && !force)) {
            banner.visibility = View.GONE
            return
        }
        banner.text = "$text  ✕"
        banner.visibility = View.VISIBLE
    }

    private val poll = object : Runnable {
        override fun run() {
            if (!polling) return
            val u = statusUrl
            if (u != null) statusIo.execute { fetchStatus(u)?.let { t -> runOnUiThread { if (polling) showNotice(t) } } }
            ui.postDelayed(this, 2000)
        }
    }

    private fun fetchStatus(u: String): String? = try {
        val c = URL(u).openConnection() as HttpURLConnection
        c.connectTimeout = 1500
        c.readTimeout = 1500
        try { if (c.responseCode == 200) c.inputStream.bufferedReader(Charsets.UTF_8).readText().trim() else null } finally { c.disconnect() }
    } catch (_: Exception) {
        null
    }

    // ---- back, lifecycle ------------------------------------------------------------------

    private fun goBackOrFinish() {
        if (web.canGoBack()) web.goBack() else finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        goBackOrFinish() // Android 12 and older (13+ uses the back-invoked callback)
    }

    override fun onResume() {
        super.onResume()
        if (::web.isInitialized) web.onResume()
        polling = true
        ui.removeCallbacks(poll)
        ui.post(poll)
    }

    override fun onPause() {
        polling = false
        ui.removeCallbacks(poll)
        if (::web.isInitialized) web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        polling = false
        ui.removeCallbacksAndMessages(null)
        if (Build.VERSION.SDK_INT >= 33) (backCallback as? OnBackInvokedCallback)?.let { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it) }
        transfer?.closeAll()
        chooser?.onReceiveValue(null)
        chooser = null
        if (::web.isInitialized) {
            (web.parent as? ViewGroup)?.removeView(web)
            web.stopLoading()
            web.destroy()
        }
        io.shutdown()
        statusIo.shutdownNow()
        super.onDestroy()
    }
}

package com.wnm.granthprabandhan

import org.json.JSONObject
import java.io.File
import java.io.OutputStream

/**
 * Receives the page's downloads (hl-shim.js: begin / chunk / end / fail, base64 pieces) and
 * writes each into `root/<stamp>-<id>/<name>`. [Listener] gets the finished file.
 * Messages arrive on the WebView's bridge thread, in order.
 */
class HlTransfer(
    private val root: File,
    private val decode: (String) -> ByteArray,
    private val listener: Listener,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    interface Listener {
        fun onFile(file: File, name: String, mime: String, mode: String)
        fun onFail()
    }

    private class Incoming(val dir: File, val file: File, val out: OutputStream, val name: String, val mime: String, val mode: String)

    private val open = HashMap<Int, Incoming>()

    @Synchronized
    fun handle(raw: String) {
        val m = try { JSONObject(raw) } catch (_: Exception) { return }
        val id = m.optInt("id", 0)
        when (m.optString("t")) {
            "begin" -> {
                abandon(id)
                val mime0 = m.optString("mime", "")
                val name = HlLogic.safeName(m.optString("name", "file"), mime0)
                try {
                    val dir = File(root, "${clock()}-$id").apply { mkdirs() }
                    val f = File(dir, name)
                    open[id] = Incoming(dir, f, f.outputStream().buffered(), name, HlLogic.mimeFor(name, mime0), m.optString("mode", "save"))
                } catch (_: Exception) {
                    listener.onFail()
                }
            }
            "chunk" -> {
                val e = open[id] ?: return
                try {
                    e.out.write(decode(m.optString("b64")))
                } catch (_: Exception) {
                    abandon(id)
                    listener.onFail()
                }
            }
            "end" -> {
                val e = open.remove(id) ?: return
                try {
                    e.out.close()
                    listener.onFile(e.file, e.name, e.mime, e.mode)
                } catch (_: Exception) {
                    e.dir.deleteRecursively()
                    listener.onFail()
                }
            }
            "fail" -> {
                abandon(id)
                listener.onFail()
            }
        }
    }

    @Synchronized
    fun closeAll() {
        open.keys.toList().forEach { abandon(it) }
    }

    private fun abandon(id: Int) {
        val e = open.remove(id) ?: return
        try { e.out.close() } catch (_: Exception) {}
        e.dir.deleteRecursively()
    }
}

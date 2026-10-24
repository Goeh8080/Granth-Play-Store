package com.wnm.granthprabandhan

import java.net.URI

/**
 * Pure helpers of the native Photo Highlighter (no Android classes, so JVM unit tests cover
 * them): names, MIME types, what the file chooser should offer, which URLs the page may open,
 * window insets, and the JS that hands a blob download to the app.
 */
object HlLogic {
    private val badName = Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]+")

    /** A file name that is safe in Downloads (same rules the Flutter screen had). */
    fun safeName(name: String, mime: String): String {
        var n = badName.replace(name, " ").trim()
        if (n.isEmpty()) n = "file"
        if (!n.contains('.')) {
            if (mime.contains("pdf")) n = "$n.pdf"
            if (mime.contains("png")) n = "$n.png"
            if (mime.contains("jpeg") || mime.contains("jpg")) n = "$n.jpg"
        }
        return if (n.length > 120) n.substring(n.length - 120) else n
    }

    fun mimeFor(name: String, mime: String): String {
        if (mime.isNotEmpty()) return mime
        val l = name.lowercase()
        return when {
            l.endsWith(".pdf") -> "application/pdf"
            l.endsWith(".png") -> "image/png"
            l.endsWith(".jpg") || l.endsWith(".jpeg") -> "image/jpeg"
            else -> "application/octet-stream"
        }
    }

    /** Only the local page (and its blob: / data: / about: pages) may load in the WebView. */
    fun isLocalUrl(url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        val u = try { URI(url) } catch (_: Exception) { return false }
        val scheme = (u.scheme ?: return false).lowercase()
        if (scheme == "about" || scheme == "data") return true
        if (scheme == "blob") return url.lowercase().startsWith("blob:http://127.0.0.1")
        return scheme == "http" && u.host == "127.0.0.1"
    }

    /** `http://127.0.0.1:47811/anything` → `http://127.0.0.1:47811`. */
    fun originOf(url: String): String? {
        if (!isLocalUrl(url)) return null
        val u = URI(url)
        if (u.scheme != "http") return null
        return "http://${u.host}" + (if (u.port > 0) ":${u.port}" else "")
    }

    class Plan(val types: List<String>, val imagesOnly: Boolean, val multiple: Boolean, val capture: Boolean) {
        /** `capture` on an image input opens the camera straight away. */
        val camera: Boolean get() = capture && imagesOnly
    }

    /** From the page's `<input type=file accept=…>`. [extMime] maps ".png" → "image/png" (or null). */
    fun plan(accept: List<String>, multiple: Boolean, capture: Boolean, extMime: (String) -> String?): Plan {
        val types = LinkedHashSet<String>()
        for (raw in accept) for (part in raw.split(',')) {
            val a = part.trim().lowercase()
            if (a.isEmpty()) continue
            if (a.startsWith(".")) types += (extMime(a.substring(1)) ?: "*/*") else if (a.contains('/')) types += a
        }
        val imagesOnly = types.all { it.startsWith("image/") }
        return Plan(types.toList(), imagesOnly, multiple, capture)
    }

    /** Paddings (left, top, right, bottom) for the page: system bars / cutout, or the keyboard when taller. */
    fun padding(barL: Int, barT: Int, barR: Int, barB: Int, imeB: Int): IntArray = intArrayOf(barL, barT, barR, maxOf(barB, imeB))

    fun jsString(s: String): String {
        val b = StringBuilder("\"")
        for (c in s) when {
            c == '\\' -> b.append("\\\\")
            c == '"' -> b.append("\\\"")
            c == '\n' -> b.append("\\n")
            c == '\r' -> b.append("\\r")
            c == '<' -> b.append("\\u003c")
            c == '\u2028' -> b.append("\\u2028")
            c == '\u2029' -> b.append("\\u2029")
            c < ' ' -> b.append(String.format("\\u%04x", c.code))
            else -> b.append(c)
        }
        return b.append('"').toString()
    }

    /** The page's own bridge script turns a blob into begin/chunk/end messages for the app. */
    fun deliverScript(url: String, name: String): String =
        "(async function(){try{var b=await (await fetch(${jsString(url)})).blob();" +
            "if(window.__granthDeliver)await window.__granthDeliver(b,${jsString(name)},'save');}catch(e){}})();"
}

package com.wnm.granthprabandhan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Base64

/** The page's downloads (hl-shim.js messages) become files. */
class HlTransferTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Rec : HlTransfer.Listener {
        val files = mutableListOf<List<String>>()
        var fails = 0
        var last: File? = null
        override fun onFile(file: File, name: String, mime: String, mode: String) {
            files += listOf(name, mime, mode, file.length().toString())
            last = file
        }
        override fun onFail() { fails++ }
    }

    private fun b64(s: String) = Base64.getEncoder().encodeToString(s.toByteArray())
    private fun make(rec: Rec) = HlTransfer(tmp.newFolder("out"), { Base64.getDecoder().decode(it) }, rec, clock = { 111L })

    @Test
    fun piecesAreJoinedInOrder() {
        val rec = Rec(); val t = make(rec)
        t.handle("""{"t":"begin","id":1,"name":"Album.pdf","mime":"application/pdf","size":10,"mode":"save"}""")
        t.handle("""{"t":"chunk","id":1,"b64":"${b64("hello ")}"}""")
        t.handle("""{"t":"chunk","id":1,"b64":"${b64("pdf!")}"}""")
        t.handle("""{"t":"end","id":1}""")
        assertEquals(listOf(listOf("Album.pdf", "application/pdf", "save", "10")), rec.files)
        assertEquals("hello pdf!", rec.last!!.readText())
        assertEquals("111-1", rec.last!!.parentFile!!.name)
        assertEquals(0, rec.fails)
    }

    @Test
    fun namesAreMadeSafeAndMimeGuessed() {
        val rec = Rec(); val t = make(rec)
        t.handle("""{"t":"begin","id":2,"name":"../../x:y","mime":"image/jpeg","mode":"share"}""")
        t.handle("""{"t":"end","id":2}""")
        assertEquals(listOf(".. .. x y", "image/jpeg", "share", "0"), rec.files.single()) // no separators left
        assertTrue(rec.last!!.canonicalPath.startsWith(tmp.root.canonicalPath))
        val rec2 = Rec(); val t2 = HlTransfer(tmp.newFolder("o2"), { Base64.getDecoder().decode(it) }, rec2)
        t2.handle("""{"t":"begin","id":3,"name":"p.png","mode":"save"}""")
        t2.handle("""{"t":"end","id":3}""")
        assertEquals("image/png", rec2.files.single()[1])
    }

    @Test
    fun failureDropsTheFileAndTellsTheUser() {
        val rec = Rec(); val t = make(rec)
        t.handle("""{"t":"begin","id":4,"name":"a.pdf","mime":"application/pdf","mode":"save"}""")
        t.handle("""{"t":"chunk","id":4,"b64":"${b64("x")}"}""")
        t.handle("""{"t":"fail","id":4,"error":"boom"}""")
        t.handle("""{"t":"end","id":4}""") // late end of a failed one: ignored
        assertEquals(1, rec.fails)
        assertTrue(rec.files.isEmpty())
        assertFalse(File(tmp.root, "out/111-4").exists())
    }

    @Test
    fun badBase64AndGarbageAreHandled() {
        val rec = Rec(); val t = make(rec)
        t.handle("not json")
        t.handle("""{"t":"chunk","id":9,"b64":"AAAA"}""") // no begin: ignored
        t.handle("""{"t":"begin","id":5,"name":"a.pdf","mode":"save"}""")
        t.handle("""{"t":"chunk","id":5,"b64":"***not base64***"}""")
        assertEquals(1, rec.fails)
        t.handle("""{"t":"end","id":5}""")
        assertTrue(rec.files.isEmpty())
    }

    @Test
    fun closeAllRemovesUnfinished() {
        val rec = Rec(); val t = make(rec)
        t.handle("""{"t":"begin","id":6,"name":"a.pdf","mode":"save"}""")
        t.handle("""{"t":"chunk","id":6,"b64":"${b64("x")}"}""")
        t.closeAll()
        assertFalse(File(tmp.root, "out/111-6").exists())
    }
}

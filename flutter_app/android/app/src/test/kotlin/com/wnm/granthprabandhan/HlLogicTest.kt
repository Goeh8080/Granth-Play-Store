package com.wnm.granthprabandhan

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests of the native Photo Highlighter's pure logic. */
class HlLogicTest {
    @Test
    fun namesAreSafeAndTyped() {
        assertEquals("a b c.pdf", HlLogic.safeName("a/b:c", "application/pdf"))
        assertEquals("Album_Export_1.pdf", HlLogic.safeName("Album_Export_1.pdf", ""))
        assertEquals("file.jpg", HlLogic.safeName("  ", "image/jpeg"))
        assertEquals("x.png", HlLogic.safeName("x", "image/png"))
        assertEquals(120, HlLogic.safeName("a".repeat(300) + ".pdf", "").length)
        assertEquals("image/jpeg", HlLogic.mimeFor("x.jpg", ""))
        assertEquals("application/pdf", HlLogic.mimeFor("X.PDF", ""))
        assertEquals("text/plain", HlLogic.mimeFor("x.pdf", "text/plain"))
        assertEquals("application/octet-stream", HlLogic.mimeFor("x.bin", ""))
    }

    @Test
    fun onlyTheLocalPageMayLoad() {
        assertTrue(HlLogic.isLocalUrl("http://127.0.0.1:47811/"))
        assertTrue(HlLogic.isLocalUrl("http://127.0.0.1:47812/lib/pdf.min.js"))
        assertTrue(HlLogic.isLocalUrl("about:blank"))
        assertTrue(HlLogic.isLocalUrl("data:text/plain;base64,AAAA"))
        assertTrue(HlLogic.isLocalUrl("blob:http://127.0.0.1:47811/6f0c-1"))
        assertFalse(HlLogic.isLocalUrl("https://example.com/"))
        assertFalse(HlLogic.isLocalUrl("http://localhost:47811/"))
        assertFalse(HlLogic.isLocalUrl("http://127.0.0.1.evil.com/"))
        assertFalse(HlLogic.isLocalUrl("http://evil.com/#127.0.0.1"))
        assertFalse(HlLogic.isLocalUrl("blob:https://evil.com/x"))
        assertFalse(HlLogic.isLocalUrl("file:///sdcard/x"))
        assertFalse(HlLogic.isLocalUrl("intent://x#Intent;end"))
        assertFalse(HlLogic.isLocalUrl(""))
        assertFalse(HlLogic.isLocalUrl(null))
    }

    @Test
    fun originOfIsTheServerRoot() {
        assertEquals("http://127.0.0.1:47811", HlLogic.originOf("http://127.0.0.1:47811/some/page?x=1"))
        assertNull(HlLogic.originOf("https://example.com/"))
        assertNull(HlLogic.originOf("about:blank"))
        assertNull(HlLogic.originOf("data:text/plain,x"))
    }

    private val ext = { e: String -> mapOf("png" to "image/png", "pdf" to "application/pdf")[e] }

    @Test
    fun chooserPlan() {
        val any = HlLogic.plan(emptyList(), multiple = true, capture = false, extMime = ext)
        assertTrue(any.types.isEmpty()); assertTrue(any.multiple); assertFalse(any.camera)
        val img = HlLogic.plan(listOf("image/*"), multiple = false, capture = true, extMime = ext)
        assertEquals(listOf("image/*"), img.types); assertTrue(img.camera)
        val mixed = HlLogic.plan(listOf("image/png, .pdf", ".png"), multiple = false, capture = true, extMime = ext)
        assertEquals(listOf("image/png", "application/pdf"), mixed.types)
        assertFalse("capture only opens the camera for image inputs", mixed.camera)
        val unknown = HlLogic.plan(listOf(".heic"), multiple = false, capture = true, extMime = ext)
        assertEquals(listOf("*/*"), unknown.types); assertFalse(unknown.camera)
        // An input with no accept list and capture still means "take a photo", like before.
        assertTrue(HlLogic.plan(emptyList(), multiple = false, capture = true, extMime = ext).camera)
    }

    @Test
    fun paddingFollowsBarsAndKeyboard() {
        assertArrayEquals(intArrayOf(0, 80, 0, 126), HlLogic.padding(0, 80, 0, 126, 0))
        assertArrayEquals(intArrayOf(10, 80, 12, 900), HlLogic.padding(10, 80, 12, 126, 900))
    }

    @Test
    fun jsStringsAreEscaped() {
        assertEquals("\"a\\\"b\\\\c\\n\\u003c/script>\"", HlLogic.jsString("a\"b\\c\n</script>"))
        val s = HlLogic.deliverScript("blob:http://127.0.0.1:1/x", "A\"B.pdf")
        assertTrue(s.contains("fetch(\"blob:http://127.0.0.1:1/x\")"))
        assertTrue(s.contains("__granthDeliver(b,\"A\\\"B.pdf\",'save')"))
    }
}

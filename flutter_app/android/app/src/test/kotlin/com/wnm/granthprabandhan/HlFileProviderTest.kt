package com.wnm.granthprabandhan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Only the camera folder and `out/<stamp>/<name>` are reachable through the provider. */
class HlFileProviderTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun r(vararg seg: String): File? {
        val cam = File(tmp.root, "cam").apply { mkdirs() }
        val out = File(tmp.root, "out").apply { mkdirs() }
        return HlFileProvider.resolve(cam, out, seg.toList())
    }

    @Test
    fun allowedPaths() {
        assertEquals("a.jpg", r("camera", "a.jpg")!!.name)
        val f = r("out", "111-1", "Album.pdf")!!
        assertEquals("Album.pdf", f.name)
        assertEquals("111-1", f.parentFile!!.name)
    }

    @Test
    fun everythingElseIsRefused() {
        assertNull(r())
        assertNull(r("camera"))
        assertNull(r("camera", ".."))
        assertNull(r("camera", "..", "x"))
        assertNull(r("out", "111-1"))
        assertNull(r("out", "..", "x"))
        assertNull(r("out", "111-1", ".."))
        assertNull(r("out", "..", "cam"))
        assertNull(r("out", "a", "b", "c"))
        assertNull(r("files", "x"))
        assertNull(r("camera", "x", "y"))
    }
}

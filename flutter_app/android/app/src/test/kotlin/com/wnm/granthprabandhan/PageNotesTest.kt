package com.wnm.granthprabandhan

import org.junit.Assert.assertEquals
import org.junit.Test

/** JVM unit tests for the page-download notification text. */
class PageNotesTest {
    @Test
    fun titleShowsTheLiveCount() {
        assertEquals("पेज सेव हो रहे हैं 412/985", PageNotes.title(412, 985))
    }

    @Test
    fun titleClampsAndHandlesUnknownTotal() {
        assertEquals("पेज सेव हो रहे हैं 985/985", PageNotes.title(1200, 985))
        assertEquals("पेज सेव हो रहे हैं 0/10", PageNotes.title(-3, 10))
        assertEquals("पेज सेव हो रहे हैं", PageNotes.title(5, 0))
    }
}

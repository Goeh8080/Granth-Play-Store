package com.wnm.granthprabandhan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM unit tests for the pure parts of the PDF notification service. */
class PdfNotesTest {
    @Test
    fun percentIsClampedForTheProgressBar() {
        assertEquals(0, PdfNotes.clampPercent(-5))
        assertEquals(45, PdfNotes.clampPercent(45))
        assertEquals(100, PdfNotes.clampPercent(140))
    }

    @Test
    fun doneNotificationsNeverReplaceTheProgressOne() {
        for (id in listOf(0, 1, 0xFFFF, Int.MAX_VALUE, "श्रीमद्भगवत गीता code 17".hashCode() and 0x7fffffff)) {
            assertNotEquals(PdfService.NOTE_ID, PdfNotes.doneId(id))
        }
        // Two different PDFs get two notifications.
        assertNotEquals(PdfNotes.doneId(1), PdfNotes.doneId(2))
    }

    @Test
    fun aStopThatCameBeforeTheStartEndsTheServiceRightAfterStartForeground() {
        assertTrue(PdfNotes.stopRightAway(stopRequested = true, inForeground = true))
        assertFalse(PdfNotes.stopRightAway(stopRequested = false, inForeground = true))
        // startForeground failed: the service already stopped itself.
        assertFalse(PdfNotes.stopRightAway(stopRequested = true, inForeground = false))
    }

    @Test
    fun channelsAreTheNewVisibleOnes() {
        // The first release used IMPORTANCE_LOW channels with these ids; new ids are needed
        // because Android never raises an existing channel's importance.
        assertEquals("pdf_progress_v2", PdfService.CH_PROGRESS)
        assertEquals("pdf_done_v2", PdfService.CH_DONE)
    }
}

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
    fun theSummaryHasItsOwnFixedId() {
        // One id for the whole run's result: replaced, never stacked; never the progress one.
        assertNotEquals(PdfService.NOTE_ID, PdfService.SUMMARY_ID)
        assertNotEquals(PageSyncService.NOTE_ID, PdfService.SUMMARY_ID)
    }

    @Test
    fun summaryTitles() {
        assertEquals("PDF तैयार", PdfNotes.summaryTitle(1, 0))
        assertEquals("50 PDF तैयार", PdfNotes.summaryTitle(50, 0))
        assertEquals("PDF नहीं बनी", PdfNotes.summaryTitle(0, 1))
        assertEquals("3 PDF नहीं बनीं", PdfNotes.summaryTitle(0, 3))
        assertEquals("48 तैयार, 2 नहीं बनीं", PdfNotes.summaryTitle(48, 2))
    }

    @Test
    fun summaryTextShowsAFewNamesNotFifty() {
        val names = (1..5).map { "g$it.pdf" }
        assertEquals("g1.pdf, g2.pdf, g3.pdf +47 और", PdfNotes.summaryText(50, 0, names, ""))
        assertEquals("a.pdf", PdfNotes.summaryText(1, 0, listOf("a.pdf"), ""))
        assertEquals("गीता — इंटरनेट नहीं", PdfNotes.summaryText(0, 1, listOf("गीता"), "इंटरनेट नहीं"))
        assertEquals("ऐप खोलकर देखें", PdfNotes.summaryText(2, 0, emptyList(), ""))
        assertEquals("a.pdf, b.pdf", PdfNotes.summaryText(2, 0, listOf("a.pdf", " ", "b.pdf"), ""))
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

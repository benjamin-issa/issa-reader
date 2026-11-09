package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.sync.PositionGuard
import com.benjaminissa.issareader.core.sync.PositionOrigin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The rules around a reader's place, which is the one thing this app cannot
 * recover once it is wrong. Ported from `PositionWritingTests.swift`.
 */
class PositionWritingTest : AppSuite() {
    private val uuid = "11111111-1111-4111-8111-111111111111"
    private val textGuardKey get() = AppModel.positionGuardKey(uuid, isAudioScaled = false)
    private val audioGuardKey get() = AppModel.positionGuardKey(uuid, isAudioScaled = true)

    private val PositionGuard.Decision.isRefusal: Boolean get() = !isAllowed
    private val PositionGuard.Decision.heldMark: Double? get() = (this as? PositionGuard.Decision.Refuse)?.held

    /** What the audiobook's fifteen-second writer produces: an audio track's href, and a fraction of the audio clock. */
    private fun audioLocator(progress: Double, href: String = "OEBPS/Audio/00000-00085.mp3") = ReadiumLocator(
        href = href, type = "audio/mpeg",
        locations = ReadiumLocator.Locations(progression = progress, totalProgression = progress),
    )

    /** What the reader's own save produces: a chapter document, and a fraction of the text. */
    private fun textLocator(progress: Double, href: String = "OEBPS/ch41.xhtml") = ReadiumLocator(
        href = href, type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = progress, totalProgression = progress),
    )

    /** A guard whose book moved backwards on the server stops refusing. */
    @Test
    fun guardFollowsTheServerBackwards() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.positionGuards[textGuardKey] = PositionGuard(highWater = 0.85, duration = 40.0 * 3600)

        val before = checkNotNull(app.positionGuards[textGuardKey])
        assertTrue(before.decide(0.02, PositionOrigin.DERIVED).isRefusal)

        // The server now says 0.02 — the book was restarted elsewhere.
        app.reseedGuards(listOf(SharedFixtures.book("Dracula", uuid = uuid, progress = 0.02)))

        val after = checkNotNull(app.positionGuards[textGuardKey])
        assertTrue("the guard was not re-seeded from the server", abs(after.highWater - 0.02) < 0.0001)
        assertFalse("reading on must be recordable", after.decide(0.03, PositionOrigin.DERIVED).isRefusal)
        scope.close()
    }

    /** A guard whose book moved forwards on the server is left alone. */
    @Test
    fun forwardMoveDoesNotReseed() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.positionGuards[textGuardKey] = PositionGuard(highWater = 0.85, duration = 40.0 * 3600)

        app.reseedGuards(listOf(SharedFixtures.book("Dracula", uuid = uuid, progress = 0.90)))

        val after = checkNotNull(app.positionGuards[textGuardKey])
        assertTrue("a forward move must not lower the mark", abs(after.highWater - 0.85) < 0.0001)
        scope.close()
    }

    /** A small step back is still allowed, a large one is not. */
    @Test
    fun toleranceBehaviour() {
        val state = PositionGuard(highWater = 0.5, duration = 3600.0)
        assertFalse(state.decide(0.499, PositionOrigin.DERIVED).isRefusal)
        val strict = PositionGuard(highWater = 0.5, duration = 40.0 * 3600)
        assertTrue(strict.decide(0.2, PositionOrigin.DERIVED).isRefusal)
    }

    /** An explicitly chosen position always wins. */
    @Test
    fun chosenAlwaysWins() {
        val state = PositionGuard(highWater = 0.99, duration = 3600.0)
        assertFalse(state.decide(0.01, PositionOrigin.CHOSEN).isRefusal)
        assertFalse("and the mark moved with it", state.decide(0.02, PositionOrigin.DERIVED).isRefusal)
    }

    /** The report: an unresolved start over a reading position holds the audio clock. */
    @Test
    fun anUnresolvedStartOverAReadingPositionHoldsTheAudioClock() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book("A Novel", uuid = uuid, progress = 0.5363, readaloud = true, audiobook = true)
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)

        val held = app.admitPosition(audioLocator(0.0001), PositionOrigin.DERIVED, uuid)
        assertEquals(PositionGuard.Decision.AwaitChoice(0.0001), held)

        // The listener scrubbing is the way out, and the only one.
        assertFalse(app.admitPosition(audioLocator(0.45), PositionOrigin.CHOSEN, uuid).isRefusal)
        assertFalse(
            "listening on from where they steered must be recordable",
            app.admitPosition(audioLocator(0.46), PositionOrigin.DERIVED, uuid).isRefusal,
        )
        assertNull("the reading clock is a different guard and must be untouched", app.positionGuards[textGuardKey])
        scope.close()
    }

    /** An audiobook never opened writes from the start. */
    @Test
    fun anAudiobookNeverOpenedWritesFromTheStart() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book("A Novel", uuid = uuid, audiobook = true, ebook = false)
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)
        assertNull("nothing to hold", app.positionGuards[audioGuardKey])
        assertFalse(app.admitPosition(audioLocator(0.0001), PositionOrigin.DERIVED, uuid).isRefusal)
        scope.close()
    }

    /** A resolved start releases an earlier hold. */
    @Test
    fun aResolvedStartReleasesAnEarlierHold() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book(
            "A Novel", uuid = uuid, progress = 0.30,
            positionHref = "The Outsider.mp3", positionType = "audio/mpeg", audiobook = true,
        )
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)
        assertTrue(app.admitPosition(audioLocator(0.31), PositionOrigin.DERIVED, uuid).isRefusal)

        app.prepareListeningGuard(book, trusted = true)
        assertFalse(app.admitPosition(audioLocator(0.31), PositionOrigin.DERIVED, uuid).isRefusal)
        scope.close()
    }

    /** A resolved start does not lower the mark. */
    @Test
    fun aResolvedStartDoesNotLowerTheMark() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book(
            "A Novel", uuid = uuid, progress = 0.5181,
            positionHref = "The Outsider.mp3", positionType = "audio/mpeg", audiobook = true,
        )
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)
        app.prepareListeningGuard(book, trusted = true)

        val decision = app.admitPosition(audioLocator(0.0004), PositionOrigin.DERIVED, uuid)
        assertTrue(decision.isRefusal)
        assertTrue(
            "the release must keep the mark the stored position gave it, not take the resume's",
            abs((decision.heldMark ?: -1.0) - 0.5181) < 0.0001,
        )
        scope.close()
    }

    /** A server re-seed keeps the hold. */
    @Test
    fun aServerReseedKeepsTheHold() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book(
            "A Novel", uuid = uuid, progress = 0.5181,
            positionHref = "The Outsider.mp3", positionType = "audio/mpeg", audiobook = true,
        )
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)
        app.reseedGuards(
            listOf(
                SharedFixtures.book(
                    "A Novel", uuid = uuid, progress = 0.30,
                    positionHref = "The Outsider.mp3", positionType = "audio/mpeg", audiobook = true,
                ),
            ),
        )

        val after = checkNotNull(app.positionGuards[audioGuardKey])
        assertTrue("the guard was not re-seeded from the server", abs(after.highWater - 0.30) < 0.0001)
        assertEquals(
            "a re-seed is not the listener saying where they are",
            PositionGuard.Decision.AwaitChoice(0.31), app.admitPosition(audioLocator(0.31), PositionOrigin.DERIVED, uuid),
        )
        scope.close()
    }

    /** A drive the listener steered lets the page that follows it be saved. */
    @Test
    fun aSteeredDriveLetsThePageThatFollowsItBeSaved() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book("A Novel", uuid = uuid, progress = 0.60, readaloud = true, audiobook = true)
        app.books = listOf(book)

        assertFalse(app.admitPosition(textLocator(0.60), PositionOrigin.CHOSEN, uuid).isRefusal)
        assertFalse(app.admitPosition(audioLocator(0.55), PositionOrigin.CHOSEN, uuid).isRefusal)
        assertFalse(
            "a whole drive has to be able to land somewhere",
            app.admitPosition(textLocator(0.30), PositionOrigin.DERIVED, uuid).isRefusal,
        )
        scope.close()
    }

    /** A place named on one clock does not release a hold on the other. */
    @Test
    fun aPlaceNamedOnOneClockDoesNotReleaseAHoldOnTheOther() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val book = SharedFixtures.book("A Novel", uuid = uuid, progress = 0.5363, readaloud = true, audiobook = true)
        app.books = listOf(book)

        app.prepareListeningGuard(book, trusted = false)
        assertFalse(app.admitPosition(textLocator(0.54), PositionOrigin.CHOSEN, uuid).isRefusal)

        assertEquals(
            "the app still cannot say where the listener was, so it still must not guess",
            PositionGuard.Decision.AwaitChoice(0.0001), app.admitPosition(audioLocator(0.0001), PositionOrigin.DERIVED, uuid),
        )
        scope.close()
    }
}

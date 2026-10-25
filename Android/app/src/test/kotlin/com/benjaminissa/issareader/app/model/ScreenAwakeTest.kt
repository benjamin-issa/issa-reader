package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.playback.SleepTimer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When the display may be held awake. Ported from the first suite of
 * `ScreenAwakeTests.swift`: the display stays awake for as long as a book is
 * open on the phone, and the sleep timer running out is what lets it go.
 */
class ScreenAwakeTest : AppSuite() {
    private val bothWays = listOf(false, true)

    /** Every row of one policy that holds the display, as `[isPlaying, isReaderVisible, followsText, isForeground, sleepTimerRanOut]`. */
    private fun holdingRows(policy: ScreenAwake.Policy): List<List<Boolean>> {
        val holding = ArrayList<List<Boolean>>()
        for (isPlaying in bothWays) for (isReaderVisible in bothWays) for (followsText in bothWays) {
            for (isForeground in bothWays) for (sleepTimerRanOut in bothWays) {
                if (!ScreenAwake.shouldKeepAwake(policy, isPlaying, isReaderVisible, followsText, isForeground, sleepTimerRanOut)) continue
                holding.add(listOf(isPlaying, isReaderVisible, followsText, isForeground, sleepTimerRanOut))
            }
        }
        return holding
    }

    /** On the phone, a book on screen in the foreground holds the display, whatever is playing. */
    @Test
    fun readerOpenTruthTable() {
        val holding = holdingRows(ScreenAwake.Policy.WHILE_READER_OPEN)
        assertEquals("thirty-two rows, and only four of them may hold the display awake", 4, holding.size)
        for (row in holding) assertTrue("$row holds without a page on screen, in front, before the timer ran out", row[1] && row[3] && !row[4])
    }

    /** On the television, only narration playing for its own page holds the display. */
    @Test
    fun narratingTruthTable() {
        assertEquals(listOf(listOf(true, true, true, true, false)), holdingRows(ScreenAwake.Policy.WHILE_NARRATING))
    }

    /** This platform keeps the display awake for as long as a book is open. */
    @Test
    fun thePhoneUsesTheReaderOpenPolicy() {
        assertEquals(ScreenAwake.Policy.WHILE_READER_OPEN, ScreenAwake.platformPolicy)
    }

    /** A book with no narration holds the display while its page is on screen. */
    @Test
    fun plainReadingHolds() {
        assertTrue(ScreenAwake.shouldKeepAwake(ScreenAwake.Policy.WHILE_READER_OPEN, false, true, false, true, false))
    }

    /** A read-along paused on its page still holds the display. */
    @Test
    fun pausedReadalongHolds() {
        assertTrue(ScreenAwake.shouldKeepAwake(ScreenAwake.Policy.WHILE_READER_OPEN, false, true, true, true, false))
    }

    /** The sleep timer running out lets the screen sleep with the book still open. */
    @Test
    fun anExpiredSleepTimerReleases() {
        for (policy in ScreenAwake.Policy.entries) {
            assertFalse(ScreenAwake.shouldKeepAwake(policy, false, true, true, true, true))
        }
    }

    /** A phone put in a pocket mid-chapter stops holding its display awake. */
    @Test
    fun leavingTheForegroundReleasesTheHold() {
        for (policy in ScreenAwake.Policy.entries) {
            assertFalse(ScreenAwake.shouldKeepAwake(policy, true, true, true, false, false))
        }
    }

    /** Dismissing the reader lets the screen sleep while the book plays on. */
    @Test
    fun dismissingTheReaderReleasesTheHold() {
        for (policy in ScreenAwake.Policy.entries) {
            assertFalse(ScreenAwake.shouldKeepAwake(policy, true, false, true, true, false))
        }
    }

    /** Listening to an audiobook with no page on screen never holds the display. */
    @Test
    fun audioOnlyPlaybackHoldsNothing() {
        for (policy in ScreenAwake.Policy.entries) {
            assertFalse(ScreenAwake.shouldKeepAwake(policy, true, false, false, true, false))
        }
    }

    /** On the television, narration stopping lets the screen sleep. */
    @Test
    fun onTheTelevisionStoppingReleases() {
        assertFalse(ScreenAwake.shouldKeepAwake(ScreenAwake.Policy.WHILE_NARRATING, false, true, true, true, false))
    }
}

/**
 * The one holder of the display assertion. Ported from
 * `ScreenAwakeAssertionTests.swift`; the window flag it drives
 * (`FLAG_KEEP_SCREEN_ON`) is `MainActivity`'s, applied from [ScreenAwakeAssertion.isHeld].
 */
class ScreenAwakeAssertionTest : AppSuite() {
    /** Taking the assertion and giving it back. */
    @Test
    fun theAssertionMoves() {
        val hold = ScreenAwakeAssertion()
        assertFalse("nothing is held until something asks", hold.isHeld)
        hold.apply(true)
        assertTrue(hold.isHeld)
        hold.apply(false)
        assertFalse("a flag left set is the flat battery this is scoped to avoid", hold.isHeld)
    }

    /** Re-applying a decision that has not changed does nothing. */
    @Test
    fun applyingTheSameValueTwiceIsHarmless() {
        val hold = ScreenAwakeAssertion()
        hold.apply(true)
        hold.apply(true)
        assertTrue(hold.isHeld)
        hold.apply(false)
        hold.apply(false)
        assertFalse(hold.isHeld)
    }
}

/**
 * The app model holds the display while a book is open, and each way out lets
 * it go. Ported from `AppModelScreenAwakeTests` in `ScreenAwakeTests.swift`,
 * less its scene table (see PORTING.md).
 */
class AppModelScreenAwakeTest : AppSuite() {
    private val bookUuid = "11111111-1111-4111-8111-111111111111"

    private fun held(app: AppModel) = app.keepsScreenAwake && app.screenAwake.isHeld
    private fun released(app: AppModel) = !app.keepsScreenAwake && !app.screenAwake.isHeld

    /** A reader on screen holds the display, and every way out of it lets go. */
    @Test
    fun aVisibleReaderHoldsTheDisplay() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        assertTrue(released(app))

        app.setReaderVisible(bookUuid, true)
        assertEquals("the reader has to be up for this to mean anything", bookUuid, app.visibleReaderUuid)
        assertTrue("a page on screen is being read, narrated or not", held(app))

        app.setForeground(false)
        assertTrue("a phone put away lets go", released(app))
        app.setForeground(true)
        assertTrue("and picked up again, on the same page, holds again", held(app))

        app.sleepTimerDidExpire()
        assertTrue("the sleep timer running out lets the phone lock with the book open", released(app))
        app.setForeground(false)
        app.setForeground(true)
        assertTrue("the phone picked up again after the timer is back to normal", held(app))

        app.sleepTimerDidExpire()
        app.setReaderVisible(bookUuid, false)
        assertTrue(released(app))
        app.setReaderVisible(bookUuid, true)
        assertTrue("a book opened after the timer ran out holds again", held(app))

        app.setReaderVisible(bookUuid, false)
        assertTrue("closing the book lets go", released(app))
        scope.close()
    }

    /** Signing out with a book on screen lets the display go. */
    @Test
    fun signingOutReleases() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.setReaderVisible(bookUuid, true)
        assertTrue(held(app))

        app.signOut(keepDownloads = true)
        assertNull(app.visibleReaderUuid)
        assertTrue(released(app))
        scope.close()
    }

    /** Removing a local book whose page is on screen lets the display go. */
    @Test
    fun removingAVisibleLocalBookReleases() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("readalong"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val app = testApp(scope)
            app.reader(book, local.library)
            app.setReaderVisible(book.uuid, true)
            assertTrue(held(app))

            app.releaseLocalBook(book.uuid)
            assertNull(app.visibleReaderUuid)
            assertTrue(released(app))
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /** The real sleep timer running out reaches the app model. */
    @Test
    fun theSleepTimerReachesTheAppModel() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val controller = NowPlayingController(scope)
        app.nowPlayingController = controller
        val engine = NowPlayingAttachTest.engine(scope)
        controller.attach(engine, SharedFixtures.book("Dracula", uuid = bookUuid))
        try {
            app.setReaderVisible(bookUuid, true)
            assertTrue(held(app))

            engine.player.play()
            checkNotNull(controller.sleepTimer).start(SleepTimer.Mode.EndOfChapter)
            engine.onChapterChangeObserved?.invoke()

            assertTrue("the timer stopped the book, so the phone may lock", released(app))
            app.setReaderVisible(bookUuid, false)
        } finally {
            controller.attach(null, null)
            scope.close()
        }
    }

    /** The app model is told when the app leaves and returns to the foreground. */
    @Test
    fun foregroundIsReportedAndReleases() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.setReaderVisible(bookUuid, true)

        app.setForeground(false)
        assertFalse(app.keepsScreenAwake)

        app.setForeground(true)
        assertTrue("coming back to the same page holds again", app.keepsScreenAwake)
        app.setReaderVisible(bookUuid, false)
        assertFalse(app.keepsScreenAwake)
        scope.close()
    }
}

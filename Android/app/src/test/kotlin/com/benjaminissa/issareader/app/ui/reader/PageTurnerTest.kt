package com.benjaminissa.issareader.app.ui.reader

import com.benjaminissa.issareader.app.reader.PageSize
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.PageTurnStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode

/**
 * The page turner against a real book and a clock the test holds. Ported from
 * `PageTurnerTests.swift`.
 *
 * What matters most is the order: the model turns first, the page moves
 * after, and only the reader's own turns move at all.
 *
 * Time here is two clocks, as it was on the iPhone: the turner's own (the
 * test's [Clock]), which places the pages, and the dispatcher's, which wakes
 * it — virtual, so a test that waits waits for nothing.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PageTurnerTest {
    class Clock {
        var now = 1000.0
    }

    private class Opened(val model: ReaderModel, val opening: ReaderOpening, val scope: CoroutineScope)

    private suspend fun TestScope.opened(chapters: List<TestEpub.Chapter> = (0 until 3).map(TestEpub::content)): Opened {
        val opening = ReaderOpening(TestEpub.data(chapters))
        val model = opening.model(backgroundScope, StandardTestDispatcher(testScheduler))
        model.open(testPageSize)
        assertEquals(ReaderModel.Phase.Ready, model.phase)
        assertTrue(model.pageCount >= 5)
        // On screen, as a reader the turner is drawing for always is.
        model.setReaderVisible(true)
        return Opened(model, opening, backgroundScope)
    }

    private fun turner(opened: Opened, clock: Clock, style: PageTurnStyle = PageTurnStyle.SLIDE): PageTurner {
        val turner = PageTurner(opened.model, opened.scope) { clock.now }
        turner.width = WIDTH
        turner.adopt(style)
        return turner
    }

    /** Lets the turner's own tasks run until a condition holds, for two virtual seconds at most. */
    private fun TestScope.until(condition: () -> Boolean) {
        repeat(400) {
            runCurrent()
            if (condition()) return
            advanceTimeBy(5)
        }
        runCurrent()
        if (!condition()) fail("timed out waiting")
    }

    /** Asks for a turn and waits for it to have committed. */
    private fun TestScope.turn(turner: PageTurner, forward: Boolean = true) {
        var committed = false
        turner.requestTurn(forward) { committed = true }
        until { committed }
    }

    private fun test(body: suspend TestScope.() -> Unit) = runTest { body() }

    @Test
    fun `a tap turns the page at once, then slides the page it left away`() = test {
        val opened = opened()
        val clock = Clock()
        val turner = turner(opened, clock)
        val duration = turner.timing.duration

        turn(turner)

        assertEquals("the model turned before anything moved", 1, opened.model.pageIndex)
        val scene = turner.scene ?: return@test fail("a turn is sliding")
        assertEquals(PageTurn.Direction.FORWARD, scene.direction)
        assertTrue(scene.liveIsArriving)
        val leaving = scene.other as? PageTurner.Other.Page ?: return@test fail("the page left behind should be drawn as it was")
        assertEquals(0, leaving.snapshot.page.index)
        assertEquals(0.0, turner.progress(clock.now), 0.0)
        assertEquals(0.5, turner.progress(clock.now + duration / 2), 0.001)

        clock.now += duration
        turner.tick()
        assertNull("at rest on the new page", turner.scene)
        opened.opening.tearDown()
    }

    @Test
    fun `a tap while a page is still sliding is a second turn, not a lost one`() = test {
        val opened = opened()
        val clock = Clock()
        val turner = turner(opened, clock)

        turn(turner)
        clock.now += turner.timing.duration / 3
        turn(turner)

        assertEquals(2, opened.model.pageIndex)
        val scene = turner.scene ?: return@test fail("still sliding")
        val leaving = scene.other as? PageTurner.Other.Page ?: return@test fail("the second turn should slide its own page away")
        assertEquals("the first turn finished where it was going", 1, leaving.snapshot.page.index)
        assertEquals("and the second started from the beginning", 0.0, turner.progress(clock.now), 0.0)
        opened.opening.tearDown()
    }

    /** Asked for all at once, as a held key repeats or quick taps land, none waiting for the one before. */
    @Test
    fun `turns asked for in a burst are all made, in order`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())
        var committed = false

        turner.requestTurn(true)
        turner.requestTurn(true)
        turner.requestTurn(true)
        turner.requestTurn(false) { committed = true }
        until { committed }

        assertEquals(2, opened.model.pageIndex)
        opened.opening.tearDown()
    }

    /** A finger going down on a page still sliding — the start of every tap — is not a drag until it moves. */
    @Test
    fun `a finger resting on a sliding page does not stop it`() = test {
        val opened = opened()
        val clock = Clock()
        val turner = turner(opened, clock)
        turn(turner)
        clock.now += turner.timing.duration / 2

        turner.dragChanged(300.0, 0.0)

        assertEquals(0.5, turner.progress(clock.now), 0.001)
        assertEquals(true, turner.scene?.liveIsArriving)
        opened.opening.tearDown()
    }

    /**
     * Narration moving the page writes `pageIndex` itself, as does every jump;
     * none of them is a turn the reader made. The contents entry for the
     * chapter already open reloads it onto the same numbers, which only the
     * layout's revision tells apart.
     */
    @Test
    fun `a page moved by anything else is shown where it is, at once`() {
        for (change in listOf("narration", "contents", "same chapter", "resize")) {
            test {
                val opened = opened()
                val model = opened.model
                val clock = Clock()
                val turner = turner(opened, clock)
                turn(turner)
                turner.modelKeyChanged(model.pageKey)
                assertNotNull("its own turn is still sliding", turner.scene)
                val before = model.pageKey

                when (change) {
                    "narration" -> model.pageIndex = 3
                    "contents" -> model.go(2)
                    "same chapter" -> model.go(model.chapterIndex)
                    else -> model.resize(PageSize(300.0, 500.0))
                }
                assertNotEquals("$change: the change has to be one the view would report", before, model.pageKey)
                turner.modelKeyChanged(model.pageKey)

                assertNull(change, turner.scene)
                assertNull(change, turner.motion)
                opened.opening.tearDown()
            }
        }
    }

    @Test
    fun `with None, a tap turns the page and nothing moves`() = test {
        val opened = opened()
        val turner = turner(opened, Clock(), PageTurnStyle.INSTANT)

        turn(turner)

        assertEquals(1, opened.model.pageIndex)
        assertNull(turner.scene)
        assertNull(turner.motion)
        assertFalse("and a drag does not move the page", turner.dragChanged(300.0, -120.0))
        assertNull(turner.scene)
        assertFalse("and nothing beyond the chapter is kept", opened.model.keepsNeighbours)
        opened.opening.tearDown()
    }

    @Test
    fun `a turner built after the page's style was chosen does not undo it`() = test {
        val opened = opened()
        turner(opened, Clock(), PageTurnStyle.INSTANT)
        assertFalse(opened.model.keepsNeighbours)

        // What a screen can do: build a turner it then discards.
        PageTurner(opened.model, opened.scope)

        assertFalse("None keeps nothing beyond the chapter, whoever is built after", opened.model.keepsNeighbours)
        opened.opening.tearDown()
    }

    @Test
    fun `a clock stepped back during a turn does not strand the page mid-turn`() = test {
        val opened = opened()
        val clock = Clock()
        val turner = turner(opened, clock)

        turn(turner)
        assertNotNull(turner.motion)

        clock.now -= 600
        advanceTimeBy(((turner.timing.duration + 0.15) * 1000).toLong())
        runCurrent()
        assertNotNull("by the stepped clock the turn has not finished", turner.motion)

        clock.now += 2000
        until { turner.motion == null }
        assertNull(turner.scene)
        opened.opening.tearDown()
    }

    @Test
    fun `a dragged page follows the finger, and a throw turns it`() = test {
        val opened = opened()
        val model = opened.model
        val clock = Clock()
        val turner = turner(opened, clock)

        assertFalse("not yet a drag", turner.dragChanged(300.0, -5.0))
        assertTrue("now it is", turner.dragChanged(300.0, -110.0))
        val scene = turner.scene ?: return@test fail("a scene while dragging")
        assertFalse(scene.liveIsArriving)
        val next = scene.other as? PageTurner.Other.Page ?: return@test fail("the next page should be under the finger")
        assertEquals(1, next.snapshot.page.index)
        assertEquals(100 / WIDTH, turner.progress(clock.now), 0.0001)
        assertEquals("nothing is committed while the finger is down", 0, model.pageIndex)

        turner.dragEnded(-500.0)
        until { model.pageIndex == 1 }

        assertEquals(true, turner.scene?.liveIsArriving)
        val spring = turner.motion as? PageTurn.Motion.Spring ?: return@test fail("a released page settles along the spring")
        assertEquals(0.25, spring.from, 0.0001)
        assertEquals(1.0, spring.to, 0.0)
        assertEquals(500 / WIDTH, spring.velocity, 0.0001)
        opened.opening.tearDown()
    }

    @Test
    fun `a page put down short of halfway goes back`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())

        turner.dragChanged(300.0, -110.0)
        turner.dragEnded(0.0)

        assertEquals(0, opened.model.pageIndex)
        val spring = turner.motion as? PageTurn.Motion.Spring ?: return@test fail("settles back along the spring")
        assertEquals(0.0, spring.to, 0.0)
        opened.opening.tearDown()
    }

    /** A tap or a key while a finger holds the page waits for it to lift, and is then made — not lost. */
    @Test
    fun `a turn asked for while a finger holds the page is made once it lifts`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())
        var committed = false

        turner.dragChanged(300.0, -60.0)
        turner.requestTurn(true) { committed = true }
        repeat(10) { runCurrent() }
        assertEquals("not while the finger is down", 0, opened.model.pageIndex)

        turner.dragEnded(0.0)
        until { committed }

        assertEquals(1, opened.model.pageIndex)
        opened.opening.tearDown()
    }

    /** The touch was taken away — no lift — or became a selection. Either way the page goes back and nothing is held up. */
    @Test
    fun `a drag the system takes away puts the page back and holds nothing up`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())

        turner.dragChanged(300.0, -110.0)
        turner.dragCancelled()

        val spring = turner.motion as? PageTurn.Motion.Spring ?: return@test fail("the page should settle back")
        assertEquals(0.0, spring.to, 0.0)
        turn(turner)
        assertEquals("a turn afterwards is made at once", 1, opened.model.pageIndex)
        opened.opening.tearDown()
    }

    @Test
    fun `switching to None with a finger on the page does not hold turns up`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())

        turner.dragChanged(300.0, -110.0)
        turner.style = PageTurnStyle.INSTANT
        turn(turner)

        assertEquals(1, opened.model.pageIndex)
        opened.opening.tearDown()
    }

    /** Narration moved the page between the finger lifting and the turn being committed. */
    @Test
    fun `a released drag whose page moved under it does not turn`() = test {
        val opened = opened()
        val model = opened.model
        val turner = turner(opened, Clock())

        turner.dragChanged(300.0, -220.0)
        turner.dragEnded(-500.0)
        model.pageIndex = 3
        turner.modelKeyChanged(model.pageKey)
        repeat(20) { runCurrent() }

        assertEquals(3, model.pageIndex)
        assertNull(turner.scene)
        opened.opening.tearDown()
    }

    /** A slide caught by a finger halfway: the page the model turned to is now the one under the finger, at the same place. */
    @Test
    fun `a page caught mid-slide is held where it was`() = test {
        val opened = opened()
        val clock = Clock()
        val turner = turner(opened, clock)
        turn(turner)
        clock.now += turner.timing.duration / 2

        turner.dragChanged(300.0, 10.0)

        val scene = turner.scene ?: return@test fail("held mid-turn")
        assertEquals("the page that arrived is now the one leaving, back", PageTurn.Direction.BACKWARD, scene.direction)
        assertFalse(scene.liveIsArriving)
        assertEquals(0.5, turner.progress(clock.now), 0.001)
        assertEquals(1, opened.model.pageIndex)
        opened.opening.tearDown()
    }

    @Test
    fun `dragging at a chapter's edge brings the next chapter's page in, and lets go into it`() = test {
        val opened = opened()
        val model = opened.model
        val turner = turner(opened, Clock())
        model.pageIndex = model.pageCount - 1

        turner.dragChanged(300.0, -60.0)
        assertEquals("a blank page until the chapter is ready", PageTurner.Other.Blank, turner.scene?.other)
        model.neighbourSettled(true)
        turner.dragChanged(300.0, -120.0)
        val next = turner.scene?.other as? PageTurner.Other.Page ?: return@test fail("the next chapter's first page should be under the finger")
        assertEquals(0, next.snapshot.page.index)

        turner.dragEnded(-800.0)
        until { model.chapterIndex == 1 }

        assertEquals(0, model.pageIndex)
        assertSame(next.snapshot.layout, model.layout)
        opened.opening.tearDown()
    }

    /** A swipe toward a chapter that will not open says so: it is not the end of the book. */
    @Test
    fun `a swipe toward a chapter that will not open says which, and goes back`() = test {
        val opened = opened(listOf(TestEpub.content(0), TestEpub.broken(1)))
        val model = opened.model
        val turner = turner(opened, Clock())
        model.pageIndex = model.pageCount - 1
        model.prefetchNeighbours()
        model.neighbourSettled(true)

        turner.dragChanged(300.0, -230.0)
        assertEquals(PageTurner.Other.Blank, turner.scene?.other)
        turner.dragEnded(-500.0)
        until { model.chapterNotice != null }

        assertTrue(model.chapterNotice?.message.orEmpty(), model.chapterNotice?.message?.contains("Chapter 1") == true)
        assertEquals(0, model.chapterIndex)
        val spring = turner.motion as? PageTurn.Motion.Spring ?: return@test fail("the page should settle back")
        assertEquals(0.0, spring.to, 0.0)
        opened.opening.tearDown()
    }

    @Test
    fun `the first page of the book does not move back`() = test {
        val opened = opened()
        val turner = turner(opened, Clock())

        turner.dragChanged(300.0, 150.0)

        assertNull(turner.scene)
        assertEquals(0.0, turner.progress(0.0), 0.0)
        opened.opening.tearDown()
    }

    private companion object {
        const val WIDTH = 400.0
    }
}

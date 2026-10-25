package com.benjaminissa.issareader.app.ask

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.ReadingBoundary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * What a lock screen is allowed to say about an answer. Swift's
 * `AskNotifierTests`, with what the Android notification itself carries.
 *
 * The body used to be the reader's own question. A delivered notification
 * outlives the sheet, and PRIVACY.md promises that questions "exist while the
 * sheet is open and are gone when you close it". The suite exists so the
 * question cannot quietly come back: nothing else checks what goes into it.
 */
@RunWith(RobolectricTestRunner::class)
class AskNotifierTest {
    @Test
    fun `the body names the book and nothing else`() {
        // Never the question, and never the answer — a notification is glanced
        // at across a table and mirrored onto a watch.
        assertEquals("Peter and Wendy", AskNotifier.body("Peter and Wendy"))
    }

    @Test
    fun `an EPUB with no title of its own still gets a readable second line`() {
        assertEquals("Open the book to read it.", AskNotifier.body(null))
        assertEquals("Open the book to read it.", AskNotifier.body("   "))
    }

    @Test
    fun `every book has its own thread, so two answers are two conversations`() {
        assertNotEquals(AskNotifier.thread("alice-uuid"), AskNotifier.thread("wendy-uuid"))
        // And every one of them is under the prefix a purge sweeps, so nothing
        // this feature posts can outlive the account it belongs to.
        assertTrue(AskNotifier.thread("alice-uuid").startsWith("issa.ask."))
    }

    // What is actually posted

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val manager: NotificationManager get() = context.getSystemService(NotificationManager::class.java)

    private fun job(uuid: String = "alice-uuid", question: String = "Who is the Cheshire Cat?") = AskJob(
        bookUuid = uuid,
        question = question,
        boundary = ReadingBoundary(spineIndex = 2, charOffset = 100),
        bookTitle = "Alice's Adventures in Wonderland",
    ).also { it.state = AskJob.State.Working(AskPhase.Thinking) }

    @Test
    fun `the posted notification says the title and the book, never the question`() {
        val notifier = AskNotifier(context, isActive = { false })
        notifier.postAnswerReady(job())

        val posted = shadowOf(manager).allNotifications.single()
        val extras = posted.extras
        assertEquals("Your answer is ready", extras.getCharSequence("android.title").toString())
        assertEquals("Alice's Adventures in Wonderland", extras.getCharSequence("android.text").toString())
        assertFalse(extras.toString().contains("Cheshire"))
        // A secure lock screen shows the title alone.
        val public = posted.publicVersion
        assertEquals("Your answer is ready", public.extras.getCharSequence("android.title").toString())
        assertNull(public.extras.getCharSequence("android.text"))
        // Tapping it opens the book and its answer.
        assertEquals(AskNotifier.link("alice-uuid"), shadowOf(posted.contentIntent).savedIntent.dataString)
    }

    @Test
    fun `nothing is posted while the reader is looking at the app`() {
        val notifier = AskNotifier(context, isActive = { true })
        notifier.postAnswerReady(job())
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test
    fun `a sign-out takes back the account's notifications and keeps the device's own books'`() {
        val notifier = AskNotifier(context, isActive = { false })
        notifier.postAnswerReady(job("server-book"))
        notifier.postReadyToAnswer(job("local-book"))
        assertEquals(2, manager.activeNotifications.size)

        notifier.removeAllDelivered(keeping = setOf("local-book"))
        assertEquals(listOf(AskNotifier.thread("local-book")), manager.activeNotifications.map { it.tag })

        notifier.removeDelivered("local-book")
        assertTrue(manager.activeNotifications.isEmpty())
    }
}

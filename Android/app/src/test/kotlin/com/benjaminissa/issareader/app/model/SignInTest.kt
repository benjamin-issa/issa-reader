package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.auth.AppTokenFailure
import com.benjaminissa.issareader.core.auth.AppTokenOutcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URI
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Starting a browser sign-in once, however often its screen appears. Ported
 * from `BrowserSignInBeginTests.swift`.
 *
 * The flow here is a stand-in the test holds open and releases, so nothing is
 * presented and no network is touched.
 */
class BrowserSignInBeginTest : AppSuite() {
    private val server = URI("http://192.168.1.10:8001")

    /** Stand-in flows: each run counts itself and waits to be told how it ended. Main-thread only. */
    private class HeldFlows {
        var starts = 0
            private set
        private val waiting = ArrayDeque<CompletableDeferred<AppTokenOutcome>>()

        suspend fun run(): AppTokenOutcome {
            val outcome = CompletableDeferred<AppTokenOutcome>()
            starts += 1
            waiting.addLast(outcome)
            return outcome.await()
        }

        /** Ends the oldest attempt still waiting. */
        fun finish(outcome: AppTokenOutcome) {
            val next = waiting.removeFirstOrNull() ?: return fail("no attempt is waiting to be finished")
            next.complete(outcome)
        }

        suspend fun waitForStarts(count: Int) {
            assertTrue("the flow was never started", waitUntil(2.seconds) { starts >= count })
        }
    }

    /** A second begin while the first is in flight starts nothing. */
    @Test
    fun secondBeginWhileRunning() = mainTest {
        val scope = testScope()
        val flows = HeldFlows()
        val model = BrowserSignInModel(server, scope) { flows.run() }

        model.begin()
        flows.waitForStarts(1)
        model.begin() // The screen appearing again as the browser goes.
        delay(200.milliseconds)
        assertEquals("the appearance restarted the sign-in", 1, flows.starts)

        flows.finish(AppTokenOutcome.Granted("token"))
        waitUntil(2.seconds) { model.stage == BrowserSignInModel.Stage.Granted("token") }
        assertEquals("the first attempt's token must not be dropped", BrowserSignInModel.Stage.Granted("token"), model.stage)
        scope.close()
    }

    /** A begin after the attempt has finished starts nothing. */
    @Test
    fun beginAfterFinishing() = mainTest {
        val scope = testScope()
        val flows = HeldFlows()
        val model = BrowserSignInModel(server, scope) { flows.run() }

        model.begin()
        flows.waitForStarts(1)
        flows.finish(AppTokenOutcome.Granted("token"))
        waitUntil(2.seconds) { model.stage == BrowserSignInModel.Stage.Granted("token") }

        model.begin()
        model.cancel() // As the sign-in screen does once the token is handed over.
        model.begin()
        delay(200.milliseconds)
        assertEquals(1, flows.starts)
        assertEquals(BrowserSignInModel.Stage.Granted("token"), model.stage)
        scope.close()
    }

    /** Try again starts a new attempt, and the old one cannot write over it. */
    @Test
    fun restartSupersedes() = mainTest {
        val scope = testScope()
        val flows = HeldFlows()
        val model = BrowserSignInModel(server, scope) { flows.run() }

        model.begin()
        flows.waitForStarts(1)
        flows.finish(AppTokenOutcome.Failed(AppTokenFailure.CouldNotExchange(status = null)))
        waitUntil(2.seconds) { model.stage is BrowserSignInModel.Stage.Failed }

        model.restart()
        flows.waitForStarts(2)
        assertEquals(BrowserSignInModel.Stage.Starting, model.stage)
        flows.finish(AppTokenOutcome.Granted("second"))
        waitUntil(2.seconds) { model.stage == BrowserSignInModel.Stage.Granted("second") }
        assertEquals(BrowserSignInModel.Stage.Granted("second"), model.stage)
        scope.close()
    }

    /**
     * Android's own: a phone whose browser has no Auth Tab is sent to the
     * pairing code, and nothing is opened.
     */
    @Test
    fun noAuthTabOffersTheDeviceCode() = mainTest {
        val scope = testScope()
        val flows = HeldFlows()
        val model = BrowserSignInModel(server, scope, isSupported = { false }) { flows.run() }

        model.begin()
        delay(100.milliseconds)
        assertEquals(BrowserSignInModel.Stage.UseDeviceCode, model.stage)
        assertEquals("a browser that cannot hand back was opened anyway", 0, flows.starts)
        scope.close()
    }
}

/**
 * The launch restore that cancelled itself, and the sentence it produced.
 * Ported from `CancelledSignInTests.swift`: whatever cancels the identity
 * check, it must not be reported as the reader's network.
 */
class CancelledSignInTest : AppSuite() {
    /** A cancelled restore does not blame the reader's network. */
    @Test
    fun cancelledRestoreIsNotANetworkFault() = mainTest {
        StubServer { Answer(200, """{"id":"reader"}""") }.use { stub ->
            val keychain = TestTokens()
            // Seeded directly, because `restore()` returns at once without a
            // stored token. The account key is the server URL.
            keychain.write("stored", stub.url.toString())
            val session = Session(stub.url, keychain, stub.http)

            // ATOMIC, so the body runs although it is cancelled before it
            // starts: the whole of the identity check runs cancelled, which is
            // the shape a Swift task cancelled before its first line has.
            val job = launch(start = CoroutineStart.ATOMIC) { session.restore() }
            job.cancel()
            job.join()

            val state = session.state.value
            if (state is Session.State.Failed) fail("a cancelled check reported a failure to the reader: ${state.reason}")
        }
    }
}

/**
 * The "Not encrypted" line under the server field. Ported from
 * `SignInCleartextTests.swift`: it is worked out from the field, not the
 * stored server.
 */
class SignInCleartextTest : AppSuite() {
    /** An http address is warned about, an https one is not. */
    @Test
    fun followsTheField() {
        assertTrue(SignInForm.isCleartext("http://192.168.1.10:8001"))
        assertFalse(SignInForm.isCleartext("https://books.example.com"))
        assertFalse(SignInForm.isCleartext("  HTTPS://books.example.com/storyteller  "))
    }

    /** A bare address is what normalising makes of it: plain HTTP on Storyteller's port. */
    @Test
    fun bareAddress() {
        assertTrue(SignInForm.isCleartext("192.168.1.10:8001"))
    }

    /** An empty or unreadable field says nothing. */
    @Test
    fun emptyField() {
        assertFalse(SignInForm.isCleartext(""))
        assertFalse(SignInForm.isCleartext("   "))
    }
}

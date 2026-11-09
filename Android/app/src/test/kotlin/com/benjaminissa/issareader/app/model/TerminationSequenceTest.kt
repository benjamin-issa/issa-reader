package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Quitting, as a state machine with nothing platform-shaped in it. Ported from
 * `TerminationSequenceTests.swift`.
 *
 * On Android the sequence guards the background flush rather than an AppKit
 * quit, but the rules are the same: one flush at a time, one reply per flush,
 * and nothing latched once a reply has gone.
 */
class TerminationSequenceTest : AppSuite() {
    private val flush: suspend () -> Unit = {}

    /** A second request while the first is still flushing is cancelled, not granted. */
    @Test
    fun aSecondRequestWhileFlushingIsCancelled() {
        val sequence = TerminationSequence()
        assertEquals(TerminationSequence.Request.LATER, sequence.begin(flush))
        // NOW here would end the process in the middle of the write the first
        // request started; LATER would be a second promise against one reply.
        assertEquals(TerminationSequence.Request.CANCEL, sequence.begin(flush))
        assertEquals(TerminationSequence.Request.CANCEL, sequence.begin(flush))
    }

    /** The deadline and the flush cannot both reply. */
    @Test
    fun theDeadlineAndTheFlushCannotBothReply() {
        val sequence = TerminationSequence()
        assertEquals(TerminationSequence.Request.LATER, sequence.begin(flush))
        var replies = 0
        sequence.replyOnce { replies += 1 }
        sequence.replyOnce { replies += 1 }
        assertEquals("told twice about one termination", 1, replies)
    }

    /** A sequence with no flush closure lets the process go straight out. */
    @Test
    fun withNoFlushClosureTheProcessGoesStraightOut() {
        val sequence = TerminationSequence()
        assertEquals(TerminationSequence.Request.NOW, sequence.begin(null))
        // NOW promises no reply, so nothing was armed: the next request is
        // answered on its own merits rather than cancelled as a duplicate.
        assertEquals(TerminationSequence.Request.LATER, sequence.begin(flush))
    }

    /** A request that was answered leaves a sequence that can answer again. */
    @Test
    fun aRequestThatWasAnsweredCanBeFollowedByAnother() {
        val sequence = TerminationSequence()
        assertEquals(TerminationSequence.Request.LATER, sequence.begin(flush))
        sequence.replyOnce {}
        assertEquals(TerminationSequence.Request.LATER, sequence.begin(flush))
    }

    /** The reply is sent, not merely counted. */
    @Test
    fun theReplyIsActuallySent() {
        val sequence = TerminationSequence()
        sequence.begin(flush)
        var replied = false
        sequence.replyOnce { replied = true }
        assertTrue(replied)
    }
}

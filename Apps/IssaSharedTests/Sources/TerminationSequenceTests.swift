import Testing

@testable import IssaReader_iOS

/// Quitting, as a state machine with nothing platform-shaped in it.
///
/// Every fault this covers was found on a Mac and none of them could be seen
/// there: a quit that exited without saving, a quit that hung, a quit answered
/// twice. AppKit reports none of those — the process is simply gone, or it is
/// not. The arithmetic that decides which is small enough to state exactly, so
/// it is stated here, on the iOS host, where it can actually be run.
///
/// These assert the rules `TerminationWatcher` relies on. It supplies the
/// flush, the three-second ceiling and the AppKit reply; this supplies the
/// answer to "what do we tell the process, and who is allowed to tell it".
@Suite("Deciding whether the process may exit")
@MainActor
struct TerminationSequenceTests {
    /// Stands in for `flushOpenReaders`. Its contents never matter here — only
    /// whether there is one.
    static let flush: () async -> Void = {}

    @Test("a second quit request while the first is still flushing is cancelled, not granted")
    func aSecondQuitRequestWhileFlushingIsCancelled() {
        let sequence = TerminationSequence()
        #expect(sequence.begin(flush: Self.flush) == .later)

        // ⌘Q twice, or ⌘Q and then Quit from the Dock menu — which is as fast
        // as a reader can be, and the save takes up to three seconds.
        //
        // `.now` here would end the process in the middle of the write the
        // first request started, which is worse than never having asked. `.later`
        // would be a second promise against one reply, and the app would sit
        // waiting for a reply nobody owes it.
        #expect(sequence.begin(flush: Self.flush) == .cancel)
        #expect(sequence.begin(flush: Self.flush) == .cancel)
    }

    @Test("the deadline and the flush cannot both reply")
    func theDeadlineAndTheFlushCannotBothReply() {
        let sequence = TerminationSequence()
        #expect(sequence.begin(flush: Self.flush) == .later)

        // The race the watcher runs on purpose: a three-second ceiling so quit
        // is never hostage to a slow server, and a flush that goes on to
        // finish anyway. Either may arrive first.
        var replies = 0
        sequence.replyOnce { replies += 1 }
        sequence.replyOnce { replies += 1 }
        #expect(replies == 1, "AppKit was told twice about one termination")
    }

    @Test("a sequence with no flush closure lets the process go straight out")
    func withNoFlushClosureTheProcessGoesStraightOut() {
        let sequence = TerminationSequence()
        // Nothing installed yet. There is nothing to save, so holding the
        // process — and owing a reply for it — would be a hang bought for
        // nothing.
        #expect(sequence.begin(flush: nil) == .now)
        // And `.now` promises no reply, so nothing was armed: the next request,
        // once there is something to flush, is answered on its own merits
        // rather than cancelled as a duplicate.
        #expect(sequence.begin(flush: Self.flush) == .later)
    }

    @Test("a quit that was answered leaves a sequence that can answer again")
    func aQuitThatWasAnsweredCanBeFollowedByAnother() {
        let sequence = TerminationSequence()
        #expect(sequence.begin(flush: Self.flush) == .later)
        sequence.replyOnce {}

        // Normally the process is gone by now and this is unreachable. Not
        // always: a reply of true is permission, not an exit, and anything
        // ahead of us in the chain — a document that asks, a system prompt —
        // can still stop it. A sequence left latched would answer every quit
        // from then on with `.cancel`, and the app could not be quit at all.
        #expect(sequence.begin(flush: Self.flush) == .later)
    }

    @Test("the reply is sent, not merely counted")
    func theReplyIsActuallySent() {
        let sequence = TerminationSequence()
        _ = sequence.begin(flush: Self.flush)
        var replied = false
        sequence.replyOnce { replied = true }
        // The mirror of the test above it. Guarding against a double reply by
        // never sending the first one would satisfy every count in this file
        // and hang the app forever.
        #expect(replied)
    }
}

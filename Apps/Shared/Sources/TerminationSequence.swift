/// The bookkeeping behind "may this process exit yet?", with no AppKit in it.
///
/// Only macOS asks the question — `applicationShouldTerminate` is where a Mac
/// app gets its last chance to save — and `TerminationWatcher` is the AppKit
/// adapter that asks it. But the part that has actually had bugs in it is not
/// the AppKit part. It is this: two quit requests overlapping, and a deadline
/// and a completion both racing to answer one. Both were wrong at first, and
/// both were invisible, because a mistake here shows up as a process that
/// exited without saving or one that hung — and neither says why.
///
/// So it lives here, in `Apps/Shared/Sources`, which compiles into all three
/// targets and which the shared suite can reach. `TerminationWatcher.swift`
/// cannot follow it: it imports AppKit, and in the iOS-hosted test build it
/// would compile to nothing at all. A rule nothing can run is how the reserve
/// above the Mac reader's first line shipped wrong; this is the same lesson
/// applied to quitting.
///
/// What it does not know about: the flush itself, the clock, and the reply.
/// Those are the adapter's, which is why `begin` takes the flush closure only
/// to ask whether there is one, and `replyOnce` takes the reply as a closure it
/// calls at most once.
@MainActor
final class TerminationSequence {
    /// What the process should be told.
    ///
    /// Three answers rather than a Bool, because the middle one is the whole
    /// point: `later` is a promise that something will reply, and exactly one
    /// reply must follow it.
    enum Request: Equatable {
        /// Nothing to save. Go.
        case now
        /// Wait: a flush is running and `replyOnce` will answer for it.
        case later
        /// Refuse this request. Only ever the *second* one.
        case cancel
    }

    /// Set while a flush is in flight.
    private var isFlushing = false

    /// One reply per `later`. The deadline and the completion can both reach
    /// the reply, and the first version of this let both of them through.
    private var hasReplied = false

    /// Answers one quit request, and arms the reply when the answer is `later`.
    ///
    /// - Parameter flush: what the caller would run before exiting, or nil if
    ///   nothing is installed yet. Only its presence is read here. A process
    ///   with nothing to save must not be held up, and — the case this
    ///   distinction exists for — a launch that has not finished wiring itself
    ///   up has nothing to lose by going straight out.
    ///
    /// A second request arriving while the first is still flushing is
    /// `cancel`, not `now`: the first request is in flight and will end the
    /// process when it is done, and answering `now` killed it mid-save, which
    /// is the one outcome all of this exists to prevent. Not a second `later`
    /// either — that would be a second promise, and AppKit would wait for a
    /// second reply that no-one is going to send.
    func begin(flush: (() async -> Void)?) -> Request {
        guard flush != nil else { return .now }
        guard !isFlushing else { return .cancel }
        isFlushing = true
        hasReplied = false
        return .later
    }

    /// Sends the one reply this sequence owes, and ignores every later attempt.
    ///
    /// Both the deadline and the finished flush call this, on purpose: whichever
    /// arrives first is the answer, and the other is a no-op. Past the deadline
    /// the flush still runs to completion — the save is worth having even when
    /// the process is no longer waiting for it — and without this it replied a
    /// second time to a termination that was no longer pending.
    ///
    /// Replying also clears the in-flight flag, so a quit that was answered and
    /// somehow did not end the process leaves a sequence that can be used again
    /// rather than one that cancels every quit from then on.
    func replyOnce(_ send: () -> Void) {
        guard !hasReplied else { return }
        hasReplied = true
        isFlushing = false
        send()
    }
}

import Foundation

/// Where one window is in opening the book a link named.
///
/// A link for a book may find a reader, or a player sheet, up over the page it
/// would push, and UIKit refuses a presentation made while one is ending. So
/// the covers are asked to close, the reader reports itself gone, a beat is
/// left for the dismissal, and only then is the page pushed:
///
///     idle -> closing(request) -> settling(request) -> route
///
/// This is only the decisions, as a value, so every turn of it can be tested
/// without a window. The view owns what the steps do — closing, timers, the
/// push — and feeds back what it sees: the pending request, the reader on
/// screen, whether this window is the one handling it.
///
/// One request has one owner. A newer request replaces whatever stage an older
/// one had reached, and every timer carries the token it was armed with, so a
/// timer belonging to a request that has gone is ignored rather than acted on.
struct BookLinkFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// The covers have been asked to close; the reader has not yet
        /// reported itself gone. `attempts` counts the closes asked for.
        case closing(AppModel.PendingBook, attempts: Int)
        /// The reader has gone and its dismissal is being waited out.
        case settling(AppModel.PendingBook)
    }

    /// What the view sees at the moment it asks.
    struct Situation: Equatable, Sendable {
        /// The app's pending request.
        var pending: AppModel.PendingBook?
        /// Whether the library has the book yet.
        var libraryHasBook: Bool
        /// The book whose reader is on screen, in any window.
        var visibleReader: String?
        /// Whether this window is the one to handle `pending`.
        var isOwner: Bool
        /// Whether a player sheet may be up: something is playing.
        var mayHaveSheet: Bool
    }

    enum Step: Equatable, Sendable {
        case nothing
        /// Drop the request: it names the book already on screen.
        case discard
        /// Ask every cover to close (for `reader`'s book, or nil for any
        /// sheet) and arm the timeout that carries `token`.
        case closeCovers(reader: String?, token: Int)
        /// Wait out the dismissal, then call `settleElapsed` with `token`.
        case settle(token: Int)
        /// Ask every sheet to close, with no reader to wait for, and wait out
        /// their dismissal as `settle` does.
        case closeSheetsThenSettle(token: Int)
        /// Push the page now.
        case route
        /// The reader would not go after being asked twice. The request is
        /// dropped: a link that could not be honoured is not acted on minutes
        /// later, when the reader is closed for some other reason, and it is
        /// never pushed underneath a reader that is still up.
        case giveUp
    }

    private(set) var phase: Phase = .idle
    /// The latest timer armed. A timer firing with any other token belongs to
    /// something that has since been replaced.
    private(set) var token = 0

    /// How many times the close is asked for before the request is given up.
    static let closeAttempts = 2

    private mutating func arm() -> Int {
        token &+= 1
        return token
    }

    /// Whatever changed — a link, the library, the reader, the owner — and
    /// the answer to what to do now.
    mutating func evaluate(_ now: Situation) -> Step {
        // No request, or not this window's: nothing is held for it, so a
        // request routed or dropped elsewhere leaves nothing behind here.
        guard let pending = now.pending, now.isOwner else {
            phase = .idle
            return .nothing
        }
        switch phase {
        case .idle:
            // Waits for the library before closing anything for a book that
            // may not exist.
            guard now.libraryHasBook else { return .nothing }
            switch AppModel.pendingBookAction(for: pending.uuid, visibleReader: now.visibleReader) {
            case .leave:
                return .discard
            case .closeReaderFirst:
                phase = .closing(pending, attempts: 1)
                return .closeCovers(reader: now.visibleReader, token: arm())
            case .route:
                // A player sheet over the page pushed here would take the
                // reader's own presentation with it, so it is closed first and
                // given the same beat as a reader.
                guard now.mayHaveSheet else { return .route }
                phase = .settling(pending)
                return .closeSheetsThenSettle(token: arm())
            }
        case let .closing(request, _):
            if request == pending {
                // The reader has reported itself gone.
                guard now.visibleReader == nil else { return .nothing }
                phase = .settling(pending)
                return .settle(token: arm())
            }
            return replaced(by: pending, now)
        case let .settling(request):
            if request == pending {
                // Not while one is already being waited out; but a reader that
                // came back is a reader to close.
                guard now.visibleReader != nil else { return .nothing }
                phase = .closing(pending, attempts: 1)
                return .closeCovers(reader: now.visibleReader, token: arm())
            }
            return replaced(by: pending, now)
        }
    }

    /// A newer request while an older one is partway.
    ///
    /// It takes the older one's place at the stage the window is in, never
    /// ahead of it: a close already asked for is not undone — the reader is
    /// going whichever link is next — and a dismissal being waited out is
    /// waited out for the new request too. So the new page is pushed only
    /// once nothing is ending, and a link for the book whose reader was
    /// just asked to close reopens it afterwards instead of being dropped as
    /// "already open".
    private mutating func replaced(by pending: AppModel.PendingBook, _ now: Situation) -> Step {
        guard now.libraryHasBook else {
            phase = .idle
            return .nothing
        }
        if now.visibleReader != nil {
            phase = .closing(pending, attempts: 1)
            return .closeCovers(reader: now.visibleReader, token: arm())
        }
        phase = .settling(pending)
        return .settle(token: arm())
    }

    /// The dismissal has had its beat.
    mutating func settleElapsed(token fired: Int, _ now: Situation) -> Step {
        guard fired == token, case let .settling(request) = phase,
              now.pending == request, now.isOwner
        else { return .nothing }
        // A reader up again is a reader to close, not one to push under.
        if now.visibleReader != nil {
            phase = .closing(request, attempts: 1)
            return .closeCovers(reader: now.visibleReader, token: arm())
        }
        phase = .idle
        return .route
    }

    /// The close has had long enough.
    mutating func closeTimedOut(token fired: Int, _ now: Situation) -> Step {
        guard fired == token, case let .closing(request, attempts) = phase,
              now.pending == request, now.isOwner
        else { return .nothing }
        // It went, and the change that said so was missed or is still coming.
        guard now.visibleReader != nil else {
            phase = .settling(request)
            return .settle(token: arm())
        }
        guard attempts < Self.closeAttempts else {
            phase = .idle
            return .giveUp
        }
        phase = .closing(request, attempts: attempts + 1)
        return .closeCovers(reader: now.visibleReader, token: arm())
    }
}

#if !os(tvOS)
import Foundation
import IssaAsk
import Observation

/// One question about one book, and everything the sheet draws from it.
///
/// It outlives the sheet on purpose. A first question about a long book on a
/// phone can take half a minute, and a reader who closes the sheet to carry on
/// reading — or leaves the app altogether — should come back to an answer
/// rather than to a blank field. So the job belongs to `AskCoordinator`, which
/// lives above the reader, and the sheet is only a view of it.
@Observable
@MainActor
final class AskJob {
    /// Where the job has got to. `working` carries the phase so the sheet can
    /// say "Reading what you've read…" rather than showing a bare spinner for
    /// eight seconds.
    enum State {
        case working(AskPhase)
        case answered(AskAnswer)
        case failed(AskFailure)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isAnswered: Bool {
            if case .answered = self { return true }
            return false
        }
    }

    let bookUUID: String
    let question: String
    /// The boundary the answer was actually bounded by, captured when the
    /// question was asked. The footer names this and not wherever the reader
    /// has turned to since.
    let boundary: ReadingBoundary

    var state: State = .working(.thinking)
    /// The answer so far, already stripped of a half-typed `Sources:` line.
    var partial = ""
    /// Whether the sheet was closed while this was still running, which is the
    /// only case a notification is posted for: a reader watching the sheet does
    /// not need to be told what is on their screen.
    var wasDismissedWhileWorking = false

    /// The pipeline, so `cancel` has something to cancel.
    var task: Task<Void, Never>?

    init(bookUUID: String, question: String, boundary: ReadingBoundary) {
        self.bookUUID = bookUUID
        self.question = question
        self.boundary = boundary
    }

    /// What the status line says while the answer is being worked out.
    ///
    /// Two sentences for four phases, because the reader does not care which
    /// index is being built — they care whether the app is reading or thinking.
    var phaseLine: String? {
        guard case let .working(phase) = state else { return nil }
        switch phase {
        case .preparingIndex, .retrieving: return "Reading what you've read…"
        case .thinking, .answering: return "Thinking…"
        }
    }
}
#endif

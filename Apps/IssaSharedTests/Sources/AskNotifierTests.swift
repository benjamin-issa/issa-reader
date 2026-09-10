import Foundation
import Testing

@testable import IssaReader_iOS

/// What a lock screen is allowed to say about an answer.
///
/// The body used to be the reader's own question, on the argument that the
/// question is theirs already. `UNUserNotificationCenter` persists delivered
/// content to disk, nothing removed it, and PRIVACY.md — added by the same
/// branch — promises that questions "exist while the sheet is open and are gone
/// when you close it". The suite exists so the question cannot quietly come
/// back: nothing else in the app checks what goes into that string.
@Suite("What the answer-ready notification says")
struct AskNotifierTests {
    @Test("the body names the book and nothing else")
    func bodyIsTheBook() {
        // Never the question, and never the answer — a notification is glanced
        // at across a table and mirrored onto a watch.
        #expect(AskNotifier.body(bookTitle: "Peter and Wendy") == "Peter and Wendy")
    }

    @Test("an EPUB with no title of its own still gets a readable second line")
    func bodyFallsBack() {
        #expect(AskNotifier.body(bookTitle: nil) == "Open the book to read it.")
        #expect(AskNotifier.body(bookTitle: "   ") == "Open the book to read it.")
    }

    @Test("every book has its own thread, so two answers are two conversations")
    func threadsArePerBook() {
        #expect(AskNotifier.thread(for: "alice-uuid") != AskNotifier.thread(for: "wendy-uuid"))
        // And every one of them is under the prefix a purge sweeps, so nothing
        // this feature posts can outlive the account it belongs to.
        #expect(AskNotifier.thread(for: "alice-uuid").hasPrefix("issa.ask."))
    }
}

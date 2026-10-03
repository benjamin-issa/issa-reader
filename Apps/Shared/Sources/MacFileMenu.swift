#if !os(tvOS)
import Foundation
import Observation

/// The Mac's File menu: whether it offers Add Book… (⌘O).
///
/// Only once the books from Files have been looked at or some are on the
/// device — never for a server reader who has not. The menu bar's commands
/// used to read the local library themselves, which decided the question at
/// launch, before the library had loaded, as no: an empty New Item group, and
/// on macOS 27, where Close lives in the Window menu, no File menu at all —
/// which nothing brought back once the books were known. Reading the library's
/// whole book list also re-rendered the menu bar on every position the reader
/// saved in a local book.
///
/// So the decision is made here, as the library changes, and published as one
/// flag the commands are rebuilt from only when it flips. Compiled on every
/// platform so the iPhone-hosted tests can ask it; only the Mac uses it.
@MainActor
@Observable
final class MacFileMenu {
    /// Whether File offers Add Book….
    private(set) var offersAddBook = false
    /// How many times the flag has changed, for a test to count.
    @ObservationIgnored private(set) var changes = 0

    static func offersAddBook(wasShown: Bool, hasBooks: Bool) -> Bool {
        wasShown || hasBooks
    }

    /// Follows `local` from now on: the decision is made again whenever what
    /// it reads changes, and the flag written only when the answer does.
    func track(_ local: LocalLibrary) {
        let offers = withObservationTracking {
            Self.offersAddBook(wasShown: local.wasShown, hasBooks: !local.books.isEmpty)
        } onChange: { [weak self, weak local] in
            Task { @MainActor in
                guard let self, let local else { return }
                self.track(local)
            }
        }
        if offers != offersAddBook {
            offersAddBook = offers
            changes += 1
        }
    }
}
#endif

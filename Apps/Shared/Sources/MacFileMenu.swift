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
///
/// **And it is remembered.** Rebuilding the commands was not enough: on
/// macOS 27 a menu the bar was built without is never added to it later. An
/// item appearing inside a menu that exists works — the same `Add Book…`
/// shows up in Read when put there — but File, empty at launch, stayed off
/// the bar for the life of the process however its group changed (checked on
/// the Mac through the Accessibility API, 3 Oct 2026). The library loads
/// after the bar is built, so a decision made fresh at each launch is always
/// "no" when the bar is. Once the answer has been yes it is kept, and the next
/// launch starts with it — the File menu is there from the first frame, and
/// stays: a reader who has looked at their own books once knows the feature.
/// The launch on which the answer first turns yes still has no File menu;
/// the list window's own Add Book… carries ⌘O for that one.
@MainActor
@Observable
final class MacFileMenu {
    /// Whether File offers Add Book….
    private(set) var offersAddBook: Bool
    /// How many times the flag has changed, for a test to count.
    @ObservationIgnored private(set) var changes = 0
    @ObservationIgnored private let defaults: UserDefaults

    /// Where the remembered answer is kept.
    static let rememberedKey = "issa.mac.fileMenuOffersAddBook"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        offersAddBook = defaults.bool(forKey: Self.rememberedKey)
    }

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
        // Never back to no once yes: see the type's comment. A no here is
        // only ever the library not having loaded yet, or every book removed
        // by a reader who already knows where they came from.
        if offers, !offersAddBook {
            offersAddBook = true
            changes += 1
            defaults.set(true, forKey: Self.rememberedKey)
        }
    }
}
#endif

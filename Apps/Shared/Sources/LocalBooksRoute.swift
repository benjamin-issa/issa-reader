#if !os(tvOS)
import Foundation
import Observation

/// Where one window is in the local books' flow, on iPhone and iPad.
///
/// Per window, the way `MacBookSelection` is per window on the Mac: an iPad can
/// have two windows on this app, and opening a book in one must not cover the
/// other. Owned by `RootView`, which presents the reader above its phase switch
/// so a session expiring mid-read cannot take the book away, and handed to the
/// screens below through the environment.
@Observable
@MainActor
public final class LocalBooksRoute {
    /// A book to open, by uuid.
    public struct OpenBook: Identifiable, Hashable, Sendable {
        public let uuid: String
        public var id: String { uuid }
    }

    /// The book whose reader is presented over this window, if any.
    public var openBook: OpenBook?

    /// Whether this window shows the local list in place of the sign-in form
    /// while no server is connected.
    ///
    /// Remembered, so a reader with no server lands on their books on every
    /// launch rather than on a form they have no use for. Cleared by "Connect
    /// to a Storyteller server" and by signing in (`RootView`).
    public var showsListSignedOut: Bool {
        didSet { defaults.set(showsListSignedOut, forKey: Self.showsListKey) }
    }

    static let showsListKey = "issa.local.showsListSignedOut"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsListSignedOut = defaults.bool(forKey: Self.showsListKey)
    }

    public func open(_ uuid: String) { openBook = OpenBook(uuid: uuid) }
}
#endif

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

    /// The library has loaded, at launch.
    ///
    /// The design's rule (5 Spec, §3): "With no server connected and at least
    /// one book here, the list is the app's root" — and 4a: "the app opens on
    /// the list (or sign-in, if the list is empty)". So a launch that finds the
    /// list empty opens on sign-in, whatever was remembered. Within a session
    /// the list stays, empty state and all, once the reader has removed the
    /// last book (2c).
    public func libraryLoaded(hasBooks: Bool) {
        if !hasBooks { showsListSignedOut = false }
    }

    /// The app's phase moved. Signed in, the list is a row in Settings from
    /// then on; signed out, the books are where the app opens if there are any
    /// (4a), and the sign-in form if there are none.
    public func phaseChanged(from old: AppModel.Phase, to new: AppModel.Phase, hasBooks: Bool) {
        switch new {
        case .ready:
            showsListSignedOut = false
        case .chooseServer where old == .ready:
            showsListSignedOut = hasBooks
        default:
            break
        }
    }
}
#endif

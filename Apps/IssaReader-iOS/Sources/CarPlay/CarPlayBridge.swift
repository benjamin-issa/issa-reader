import Foundation
import IssaCore
import IssaPlayback

/// The seam between the CarPlay scene and the app's state.
///
/// CarPlay runs in its own scene with its own lifecycle, and can connect while
/// the phone app has never been foregrounded. Keeping the contact surface this
/// small means the scene delegate never reaches into view state that may not
/// exist yet — and `AppServices` now starts the app from the app delegate, so
/// what it reaches for is actually there.
@MainActor
final class CarPlayBridge {
    static let shared = CarPlayBridge()

    /// What the car may be shown, already filtered to books it can play.
    private(set) var catalogue = CarPlayCatalogue(books: [])

    /// Called when the library changes, so a car connected before the phone
    /// finished loading does not sit on an empty list.
    var onLibraryChange: (() -> Void)?
    /// Starts a book, answering with a message if it could not start.
    ///
    /// The failure has to come back rather than being logged: streaming needs a
    /// signal, a car often has none, and a list row that silently does nothing
    /// is indistinguishable from a crash at the wheel.
    var onPlay: ((String) async -> String?)?
    var onCycleRate: (() -> Void)?
    /// Told to the remote-command centre so bindings resolve against the car's
    /// surface rather than the phone's while connected. Assigned through
    /// `observeSurface(_:)`, which is the only way to take it and not be behind.
    var onSurfaceChange: ((ControlSurface) -> Void)?

    /// Which surface the app is being driven from, remembered rather than only
    /// announced.
    ///
    /// The connect used to be a bare `onSurfaceChange?(.carPlay)`, so the whole
    /// truth lived in one call: a car connecting before anything had taken the
    /// closure would have made the only announcement there was, into nothing.
    /// Today's lifecycle does not allow that — UIKit runs
    /// `didFinishLaunchingWithOptions`, and with it `AppServices.start()`,
    /// before it connects any scene — but an invariant this app depends on to
    /// keep a book on the dashboard should not rest on an ordering decided
    /// somewhere else. Kept here, it can be replayed to whoever arrives late.
    private(set) var surface: ControlSurface = .phone

    /// The chapters of whatever is playing, for the Up Next button.
    var chapters: (() -> [String])?
    var currentChapter: (() -> Int?)?
    var onPlayChapter: ((Int) async -> Void)?
    /// The book playing now, so its row can say so.
    var playingBookUUID: (() -> String?)?
    /// Square cover bytes for a list row.
    var cover: ((String) async -> Data?)?

    private init() {}

    func update(books: [Book], downloaded: Set<String>) {
        catalogue = CarPlayCatalogue(books: books, downloadedUUIDs: downloaded)
        onLibraryChange?()
    }

    /// Takes the surface listener, and tells it straight away what the surface
    /// already is.
    ///
    /// The replay is the point. Assigning alone leaves a listener correct only
    /// from its next change onwards, and for a car that is already connected
    /// the next change is the end of the drive.
    func observeSurface(_ observe: @escaping (ControlSurface) -> Void) {
        onSurfaceChange = observe
        observe(surface)
    }

    /// Recorded as well as announced: the surface is state, not only an event.
    func surfaceDidConnect() {
        surface = .carPlay
        onSurfaceChange?(.carPlay)
    }

    func surfaceDidDisconnect() {
        surface = .phone
        onSurfaceChange?(.phone)
    }

    func entries(for shelf: CarPlayCatalogue.Shelf, limit: Int) -> [CarPlayCatalogue.Entry] {
        catalogue.entries(for: shelf, limit: limit)
    }

    func play(bookID: String) async -> String? {
        await onPlay?(bookID)
    }

    func cycleRate() { onCycleRate?() }
}

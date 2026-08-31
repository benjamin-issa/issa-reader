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
    /// surface rather than the phone's while connected.
    var onSurfaceChange: ((ControlSurface) -> Void)?

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

    func surfaceDidConnect() { onSurfaceChange?(.carPlay) }
    func surfaceDidDisconnect() { onSurfaceChange?(.phone) }

    func entries(for shelf: CarPlayCatalogue.Shelf, limit: Int) -> [CarPlayCatalogue.Entry] {
        catalogue.entries(for: shelf, limit: limit)
    }

    func play(bookID: String) async -> String? {
        await onPlay?(bookID)
    }

    func cycleRate() { onCycleRate?() }
}

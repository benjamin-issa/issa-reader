import Foundation
import IssaCore
import IssaPlayback

/// The seam between the CarPlay scene and the app's state.
///
/// CarPlay runs in its own scene with its own lifecycle, and can connect while
/// the phone app has never been foregrounded. Keeping the contact surface this
/// small means the scene delegate never reaches into view state that may not
/// exist yet.
@MainActor
final class CarPlayBridge {
    static let shared = CarPlayBridge()

    struct Entry {
        let bookID: String
        let title: String
        let subtitle: String
        let progress: Double?
    }

    /// Set by the app once a session exists.
    var books: [Book] = []
    var onPlay: ((String) -> Void)?
    var onCycleRate: (() -> Void)?
    /// Told to the remote-command centre so bindings resolve against the car's
    /// surface rather than the phone's while connected.
    var onSurfaceChange: ((ControlSurface) -> Void)?

    private init() {}

    func surfaceDidConnect() { onSurfaceChange?(.carPlay) }
    func surfaceDidDisconnect() { onSurfaceChange?(.phone) }

    func libraryItems() -> [Entry] {
        books.prefix(50).map(entry)
    }

    func continueItems() -> [Entry] {
        LibraryDerivation(books: books).continueReading.prefix(20).map(entry)
    }

    private func entry(_ book: Book) -> Entry {
        Entry(
            bookID: book.uuid,
            title: book.title,
            subtitle: subtitle(for: book),
            progress: book.progress,
        )
    }

    /// Driving glanceability: author plus time remaining, not a synopsis.
    private func subtitle(for book: Book) -> String {
        var parts = [book.byline]
        if let duration = book.audiobook?.duration ?? book.readaloud?.duration {
            let remaining = duration * (1 - (book.progress ?? 0))
            parts.append(Self.durationText(remaining) + " left")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    func play(bookID: String) { onPlay?(bookID) }
    func cycleRate() { onCycleRate?() }
}

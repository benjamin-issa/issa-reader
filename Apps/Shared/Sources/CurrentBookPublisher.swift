import IssaCore
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The one thing that writes the widget's snapshot.
///
/// There used to be two: the reader wrote one when it saved a position, and the
/// listening loop wrote another every fifteen seconds. Two uncoordinated
/// writers of one file meant the widget flipped between the book being read and
/// the book being played every few seconds, and `widgetURL` deep-linked to
/// whichever wrote last. Worse, the "publish the cover only when the book
/// changes" latch lived in one of them as a private static, so the other could
/// silently invalidate it and leave one book's text over another's artwork.
///
/// Everything that wants the widget updated comes through here instead.
@MainActor
final class CurrentBookPublisher {
    static let shared = CurrentBookPublisher()

    /// Which surface the snapshot currently belongs to.
    enum Owner: Equatable {
        case reading(String)
        case listening(String)

        var bookID: String {
            switch self {
            case let .reading(id), let .listening(id): id
            }
        }
    }

    private var owner: Owner?
    /// Whether the owner was last seen playing, so a reader cannot displace a
    /// book that is audibly still going.
    private var ownerIsPlaying = false
    /// The book whose cover is actually on disk, and in which shape. Instance
    /// state rather than a static, so it cannot be invalidated behind the back
    /// of whoever is relying on it.
    private var coverBookID: String?
    private var coverIsSquare = false
    /// Rejects a cover fetch that was overtaken while it was in flight.
    private var coverGeneration = 0

    private init() {}

    /// Whether `owner` may take the snapshot from whoever holds it.
    ///
    /// The rule is that the widget shows what you are doing. Audio that is
    /// still playing outranks a book you are merely looking at; anything else
    /// is last-touch-wins.
    private func mayPublish(_ candidate: Owner) -> Bool {
        guard let owner, owner != candidate else { return true }
        if case .listening = owner, ownerIsPlaying, case .reading = candidate { return false }
        return true
    }

    func publish(
        book: Book,
        session: Session?,
        progress: Double,
        chapter: String?,
        remaining: TimeInterval?,
        isPlaying: Bool,
        as candidate: Owner,
    ) {
        guard progress.isFinite, mayPublish(candidate) else { return }
        owner = candidate
        ownerIsPlaying = isPlaying

        let wantsSquare = Self.prefersSquareCover(book)
        // A chapter that is only the book title again, or empty, is not a
        // chapter — the widget would print the same string twice.
        let chapter = chapter.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == book.title ? nil : trimmed
        }

        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: book.uuid,
            title: book.title,
            author: book.byline,
            chapter: chapter,
            progress: progress,
            remaining: remaining.flatMap { $0.isFinite ? $0 : nil },
            isPlaying: isPlaying,
            // What is actually on disk, not what we are about to ask for: the
            // fetch below may not have happened yet, or may fail.
            coverIsSquare: coverBookID == book.uuid ? coverIsSquare : false,
        ))
        reload()

        if coverBookID != book.uuid || coverIsSquare != wantsSquare {
            fetchCover(for: book, session: session, square: wantsSquare)
        }
    }

    /// Which art an audio surface should show.
    ///
    /// `servableFormats` rather than a bare `!= nil`: the server creates a
    /// readaloud row when alignment is merely requested, and asking for square
    /// art for a book that has none is a 404 that leaves the previous book's
    /// cover in place.
    static func prefersSquareCover(_ book: Book) -> Bool {
        book.servableFormats.contains(.audiobook)
    }

    private func fetchCover(for book: Book, session: Session?, square: Bool) {
        guard let session else { return }
        coverGeneration += 1
        let generation = coverGeneration
        Task { [weak self] in
            var landed = square
            var data = await CoverCache.shared.coverDataForWidget(
                for: book, session: session, shape: square ? .square : .portrait)
            if data == nil, square {
                // The square endpoint 404s for a book with no audiobook
                // edition, and the service only falls back the other way.
                // Portrait art is better than last book's art.
                landed = false
                data = await CoverCache.shared.coverDataForWidget(
                    for: book, session: session, shape: .portrait)
            }
            guard let self, generation == self.coverGeneration, let data else { return }
            CurrentBookSnapshotStore.writeCover(data)
            // Recorded only once the bytes are on disk, so a failure is retried
            // next time rather than latched for the life of the process.
            self.coverBookID = book.uuid
            self.coverIsSquare = landed
            if var snapshot = CurrentBookSnapshotStore.read(), snapshot.bookID == book.uuid {
                snapshot.coverIsSquare = landed
                CurrentBookSnapshotStore.write(snapshot)
            }
            // The snapshot was published before the art existed, so the widget
            // has to be told again now that it does.
            self.reload()
        }
    }

    /// Forgets everything. Called on sign-out, where the snapshot, the cover
    /// and the latch all have to go together — leaving the latch behind meant
    /// signing back in and reopening the same book skipped the cover fetch and
    /// left the widget with no art at all.
    func clear() {
        owner = nil
        ownerIsPlaying = false
        coverBookID = nil
        coverIsSquare = false
        coverGeneration += 1
        CurrentBookSnapshotStore.clear()
        reload()
    }

    /// Drops ownership without clearing, so the next surface to publish wins.
    func relinquish(_ candidate: Owner) {
        guard owner == candidate else { return }
        owner = nil
        ownerIsPlaying = false
    }

    private func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "CurrentBook")
        #endif
    }
}

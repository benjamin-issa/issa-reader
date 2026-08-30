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
/// whichever wrote last.
///
/// What state there is lives **in the snapshot on disk**, not in this object.
/// An in-memory record of which cover had been fetched did not survive a cold
/// launch, could not be reconciled with a file another launch had written, and
/// gave every question two possible answers.
@MainActor
final class CurrentBookPublisher {
    static let shared = CurrentBookPublisher()

    /// Which surface the snapshot currently belongs to.
    enum Owner: Equatable {
        case reading(String)
        case listening(String)
    }

    private var owner: Owner?
    /// When the owner last said it was playing. Ownership lapses rather than
    /// latching: a stream that stalls stops publishing entirely — the player
    /// leaves `.playing` with no callback — and without a lapse the reader
    /// would be locked out of the widget for the rest of the process.
    private var playingSince: Date?
    /// Rejects a cover fetch that was overtaken while it was in flight.
    private var coverGeneration = 0

    /// How long a silent owner keeps its claim.
    private static let ownershipLapse: TimeInterval = 90

    private init() {}

    /// Whether `candidate` may take the snapshot from whoever holds it.
    ///
    /// The widget shows what you are doing. Audio that is still playing
    /// outranks a book you are merely looking at; anything else is
    /// last-touch-wins.
    private func mayPublish(_ candidate: Owner) -> Bool {
        guard let owner, owner != candidate else { return true }
        guard case .listening = owner, case .reading = candidate else { return true }
        guard let playingSince else { return true }
        return Date.now.timeIntervalSince(playingSince) > Self.ownershipLapse
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
        playingSince = isPlaying ? .now : nil

        let existing = CurrentBookSnapshotStore.read()
        // What is on disk right now, which may be the previous book's.
        let coverMatches = existing?.coverBookID == book.uuid

        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: book.uuid,
            title: book.title,
            author: book.byline,
            chapter: Self.usableChapter(chapter, title: book.title),
            progress: progress,
            remaining: remaining.flatMap { $0.isFinite ? $0 : nil },
            isPlaying: isPlaying,
            coverBookID: coverMatches ? book.uuid : nil,
            coverIsSquare: coverMatches ? (existing?.coverIsSquare ?? false) : false,
        ))
        reload()

        // Keyed on the book alone. Keying on the shape as well never converged:
        // when square art does not exist the fetch falls back to portrait, so
        // "landed != wanted" stayed true and every publish re-ran a doomed
        // request — hundreds an hour, each with its own widget reload.
        if !coverMatches { fetchCover(for: book, session: session) }
    }

    /// A chapter that is only the book's title again, or blank, is not a
    /// chapter. `ReaderModel.chapterTitle` falls back to the title whenever no
    /// navigation entry matches the spine document, which is every plain EPUB.
    static func usableChapter(_ chapter: String?, title: String) -> String? {
        guard let trimmed = chapter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != title
        else { return nil }
        return trimmed
    }

    /// Which art an audio surface should show.
    ///
    /// `servableFormats` rather than a bare `!= nil`: the server creates a
    /// readaloud row when alignment is merely requested, and asking for square
    /// art for a book that has none is a 404.
    static func prefersSquareCover(_ book: Book) -> Bool {
        book.servableFormats.contains(.audiobook)
    }

    private func fetchCover(for book: Book, session: Session?) {
        guard let session else { return }
        coverGeneration += 1
        let generation = coverGeneration
        let square = Self.prefersSquareCover(book)
        Task { [weak self] in
            let fetched = await CoverCache.shared.widgetCover(
                for: book, session: session, preferring: square ? .square : .portrait)
            guard let self, generation == self.coverGeneration, let fetched else { return }
            await CurrentBookSnapshotStore.writeCoverOffMain(fetched.data)
            // Stamped onto whatever snapshot is current, and only if it is
            // still this book's — a snapshot written while the fetch was in
            // flight belongs to something else.
            guard var snapshot = CurrentBookSnapshotStore.read(), snapshot.bookID == book.uuid
            else { return }
            snapshot.coverBookID = book.uuid
            snapshot.coverIsSquare = fetched.isSquare
            CurrentBookSnapshotStore.write(snapshot)
            // The snapshot was published before the art existed, so the widget
            // has to be told again now that it does.
            self.reload()
        }
    }

    /// Forgets everything. Called on sign-out, where the snapshot, the cover
    /// and any fetch in flight all have to go together.
    func clear() {
        owner = nil
        playingSince = nil
        coverGeneration += 1
        CurrentBookSnapshotStore.clear()
        reload()
    }

    private func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: CurrentBookSnapshotStore.widgetKind)
        #endif
    }
}

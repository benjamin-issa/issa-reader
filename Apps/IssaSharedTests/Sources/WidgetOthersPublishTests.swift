import Foundation
import IssaCore
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// When the widget's "also reading" list is written, and when it is not.
///
/// The list follows the catalogue and every position in it, and positions are
/// written every couple of seconds while reading — so what these pin is that a
/// publisher asked again about an unchanged list writes nothing and spends no
/// reload.
@Suite("Publishing the widget's other books", .serialized)
@MainActor
struct WidgetOthersPublishTests {
    private func inDirectory(_ body: () throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CurrentBookSnapshotStore.directoryOverride = directory
        defer {
            CurrentBookSnapshotStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body()
    }

    private static func reading(_ id: String, _ progress: Double, at timestamp: Double) -> Book {
        SharedFixtures.book(
            id, uuid: id, status: "Reading", progress: progress, positionTimestamp: timestamp)
    }

    private static func library(progress: Double = 0.30) -> [Book] {
        [
            reading("current", 0.50, at: 900),
            reading("b", progress, at: 800),
            reading("c", 0.20, at: 700),
            SharedFixtures.book("d", uuid: "d", status: "Read", progress: 1, positionTimestamp: 600),
        ]
    }

    private func seed(_ publisher: CurrentBookPublisher) {
        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: "current", title: "current", author: "", progress: 0.5))
        _ = publisher
    }

    @Test("the list is written beside the current book, never including it or a finished one")
    func writesTheList() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            #expect(publisher.updateLibrary(Self.library(), session: nil))
            let snapshot = CurrentBookSnapshotStore.read()
            #expect(snapshot?.others.map(\.bookID) == ["b", "c"])
            #expect(snapshot?.bookID == "current")
        }
    }

    @Test("the same list, and progress under a fifth of a percent, write nothing")
    func quietWhenNothingMoved() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            #expect(publisher.updateLibrary(Self.library(), session: nil))
            #expect(!publisher.updateLibrary(Self.library(), session: nil))
            #expect(!publisher.updateLibrary(Self.library(progress: 0.3015), session: nil))
            #expect(publisher.updateLibrary(Self.library(progress: 0.3021), session: nil))
            #expect(CurrentBookSnapshotStore.read()?.others.first?.progress == 0.3021)
        }
    }

    @Test("a different order is a write")
    func reorderWrites() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            #expect(publisher.updateLibrary(Self.library(), session: nil))
            let reordered = [
                Self.reading("current", 0.5, at: 900), Self.reading("b", 0.3, at: 100),
                Self.reading("c", 0.2, at: 700),
            ]
            #expect(publisher.updateLibrary(reordered, session: nil))
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["c", "b"])
        }
    }

    @Test("nothing is written with no current book, or while signed out")
    func suspendedAndEmpty() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            // No snapshot: the widget is empty and has nowhere to put them.
            #expect(!publisher.updateLibrary(Self.library(), session: nil))
            #expect(CurrentBookSnapshotStore.read() == nil)

            seed(publisher)
            publisher.clear()          // a sign-out: suspended
            seed(publisher)
            #expect(!publisher.updateLibrary(Self.library(), session: nil))
            #expect(CurrentBookSnapshotStore.read()?.others.isEmpty == true)
            publisher.resume()
            #expect(publisher.updateLibrary(Self.library(), session: nil))
        }
    }

    @Test("a new current book takes its place off the list, and the old one joins it")
    func currentBookChanges() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            publisher.updateLibrary(Self.library(), session: nil)
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["b", "c"])

            // Reading "b" now: it is the current book, so it leaves the list, and
            // "current" (still at 50%) joins it.
            let b = Self.library()[1]
            publisher.publish(
                book: b, session: nil, progress: 0.31, chapter: nil, remaining: nil,
                isPlaying: false, as: .reading("b"))
            let snapshot = CurrentBookSnapshotStore.read()
            #expect(snapshot?.bookID == "b")
            #expect(snapshot?.others.map(\.bookID) == ["current", "c"])

            // A later publish of the same book keeps the list it has.
            publisher.publish(
                book: b, session: nil, progress: 0.40, chapter: nil, remaining: nil,
                isPlaying: false, as: .reading("b"))
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["current", "c"])
        }
    }

    @Test("signing out removes the covers with the snapshot")
    func clearRemovesCovers() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            CurrentBookSnapshotStore.writeOtherCover(Data("x".utf8), bookID: "b")
            publisher.clear()
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))
            #expect(CurrentBookSnapshotStore.read() == nil)
        }
    }

    @Test("a book from the reader's own files is never listed")
    func localBooksAreNotListed() throws {
        try inDirectory {
            let publisher = CurrentBookPublisher()
            seed(publisher)
            var local = Book.local(
                uuid: "local-one", metadata: LocalBookMetadata(title: "From my files"),
                narrationDuration: nil,
                copy: LocalCopy(fileName: "mine.epub", fingerprint: "f", byteCount: 1, importedAt: Date()))
            local.adopt(
                position: ReadiumLocator(
                    href: "a", type: "t", locations: .init(progression: 0.5, totalProgression: 0.5)),
                timestamp: 9_999)
            publisher.updateLibrary([local] + Self.library(), session: nil)
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["b", "c"])
        }
    }
}

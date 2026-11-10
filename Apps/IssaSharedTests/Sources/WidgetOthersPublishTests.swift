import Foundation
import IssaCore
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

extension WidgetStorage {
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

        @Test("a new current book before any library keeps the stored others, less itself")
        func currentBookChangesBeforeTheLibraryIsKnown() throws {
            try inDirectory {
                let publisher = CurrentBookPublisher()
                CurrentBookSnapshotStore.write(CurrentBookSnapshot(
                    bookID: "current", title: "current", author: "", progress: 0.5,
                    others: [
                        OtherBook(bookID: "b", title: "b", progress: 0.3),
                        OtherBook(bookID: "c", title: "c", progress: 0.2),
                    ]))
                // No `updateLibrary` yet: the catalogue is not known.
                publisher.publish(
                    book: Self.reading("b", 0.31, at: 800), session: nil, progress: 0.31, chapter: nil,
                    remaining: nil, isPlaying: false, as: .reading("b"))
                let snapshot = CurrentBookSnapshotStore.read()
                #expect(snapshot?.bookID == "b")
                #expect(snapshot?.others.map(\.bookID) == ["c"])
            }
        }

        // MARK: - Covers, when the list changes mid-fetch

        private static func stubSession() -> Session {
            Session(
                serverURL: URL(string: "https://covers.example")!,
                keychain: LocalTestTokens(), session: URLSession(configuration: .ephemeral))
        }

        private func settle(_ publisher: CurrentBookPublisher) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while publisher.otherFetchesInFlight > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(publisher.otherFetchesInFlight == 0, "the cover fetches never finished")
        }

        @Test("a list that changes while covers are being fetched still gets every cover")
        func listChangeDoesNotStrandCovers() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            let publisher = CurrentBookPublisher()
            publisher.coverFetcher = { book, _, _ in
                try? await Task.sleep(for: .milliseconds(150))
                return (Data(book.uuid.utf8), false)
            }
            seed(publisher)
            let session = Self.stubSession()

            let first = [
                Self.reading("current", 0.5, at: 900), Self.reading("a", 0.4, at: 800),
                Self.reading("b", 0.3, at: 700), Self.reading("c", 0.2, at: 600),
                Self.reading("d", 0.1, at: 500),
            ]
            #expect(publisher.updateLibrary(first, session: session))
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["a", "b", "c", "d"])

            // Straight away, while the first pass is on "a": "a" is finished and
            // "x" has been started, so "x" leads the list and b, c, d stay.
            let second = [
                Self.reading("current", 0.5, at: 900),
                SharedFixtures.book("a", uuid: "a", status: "Read", progress: 1, positionTimestamp: 810),
                Self.reading("x", 0.4, at: 850), Self.reading("b", 0.3, at: 700),
                Self.reading("c", 0.2, at: 600), Self.reading("d", 0.1, at: 500),
            ]
            #expect(publisher.updateLibrary(second, session: session))
            #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["x", "b", "c", "d"])

            try await settle(publisher)
            for id in ["x", "b", "c", "d"] {
                #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: id), "no cover for \(id)")
            }
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "a"))
        }

        // MARK: - Before a catalogue is known

        @Test("a model that has not loaded a catalogue leaves the stored others and their covers alone")
        func launchBeforeTheCatalogueKeepsTheList() throws {
            try inDirectory {
                let app = AppModel(notificationCentre: NotificationCenter())
                app.currentBookPublisher = CurrentBookPublisher()
                CurrentBookSnapshotStore.write(CurrentBookSnapshot(
                    bookID: "current", title: "current", author: "", progress: 0.5,
                    others: [OtherBook(bookID: "b", title: "b", progress: 0.3)]))
                CurrentBookSnapshotStore.writeOtherCover(Data("x".utf8), bookID: "b")

                // What `init` does, and what a failed first refresh leaves.
                app.rebuildDerived()
                #expect(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["b"])
                #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))

                // A catalogue that loaded and is empty is an answer: the list goes.
                app.catalogueApplied = true
                app.rebuildDerived()
                #expect(CurrentBookSnapshotStore.read()?.others.isEmpty == true)
                #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))
            }
        }

        // MARK: - A sign-out that overtakes a cover write

        @Test("a cover write that lands after sign-out does not leave its file behind")
        func signOutDuringACoverWrite() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            let publisher = CurrentBookPublisher()
            publisher.coverFetcher = { book, _, _ in (Data(book.uuid.utf8), false) }
            var release: CheckedContinuation<Void, Never>?
            var writeStarted = false
            publisher.otherCoverWriter = { data, id in
                writeStarted = true
                await withCheckedContinuation { release = $0 }
                CurrentBookSnapshotStore.writeOtherCover(data, bookID: id)
            }
            seed(publisher)
            #expect(publisher.updateLibrary(Self.library(), session: Self.stubSession()))
            let deadline = ContinuousClock.now + .seconds(10)
            while release == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(writeStarted && release != nil, "the write never began")

            publisher.clear()
            release?.resume()
            try await settle(publisher)

            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "c"))
        }

        @Test("a current-book cover write that lands after sign-out does not leave its file behind")
        func signOutDuringTheCurrentCoverWrite() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            let publisher = CurrentBookPublisher()
            publisher.coverFetcher = { book, _, _ in (Data(book.uuid.utf8), false) }
            var release: CheckedContinuation<Void, Never>?
            var landed = false
            publisher.coverWriter = { data in
                await withCheckedContinuation { release = $0 }
                CurrentBookSnapshotStore.writeCover(data)
                landed = true
            }
            let current = Self.library()[0]
            publisher.publish(
                book: current, session: Self.stubSession(), progress: 0.5, chapter: nil, remaining: nil,
                isPlaying: false, as: .reading("current"))
            let deadline = ContinuousClock.now + .seconds(10)
            while release == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(release != nil, "the write never began")

            publisher.clear()
            release?.resume()
            let finished = ContinuousClock.now + .seconds(10)
            while !landed, ContinuousClock.now < finished { try await Task.sleep(for: .milliseconds(10)) }
            try #require(landed, "the write never finished")
            // The task's own clean-up follows the write on the main actor.
            try await Task.sleep(for: .milliseconds(100))

            #expect(CurrentBookSnapshotStore.readCover() == nil)
            #expect(CurrentBookSnapshotStore.read() == nil)
        }

        // MARK: - The window between leaving an account and clearing the widget

        @Test("a position saved while an account is being left lists no others and fetches no covers")
        func positionSavedWhileLeaving() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            let fixture = try await AccountExitTests.signedInAsA()
            defer { fixture.tearDown() }
            let app = fixture.app
            let publisher = CurrentBookPublisher()
            var fetches = 0
            publisher.coverFetcher = { _, _, _ in
                fetches += 1
                return nil
            }
            app.currentBookPublisher = publisher
            seed(publisher)
            app.books = Self.library()
            app.catalogueApplied = true
            app.rebuildDerived()
            try await settle(publisher)
            try #require(CurrentBookSnapshotStore.read()?.others.map(\.bookID) == ["b", "c"])
            fetches = 0

            // What a debounced save does, in the suspension `leaveAccount`
            // makes before it clears the widget.
            var others: [String]?
            app.localBooksLoaded = {
                publisher.publish(
                    book: Self.reading("b", 0.31, at: 950), session: nil, progress: 0.31, chapter: nil,
                    remaining: nil, isPlaying: false, as: .reading("b"))
                others = CurrentBookSnapshotStore.read()?.others.map(\.bookID)
            }
            await app.signOut()

            #expect(others == [], "the departed catalogue was still listed: \(String(describing: others))")
            try await settle(publisher)
            #expect(fetches == 0, "covers were fetched for the departed account")
        }

        // MARK: - Retrying covers on an unchanged list

        @Test("a cover that failed is fetched again, by an unchanged list, once the retry window has passed")
        func unchangedListRetriesMissingCovers() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            let publisher = CurrentBookPublisher()
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            publisher.now = { clock }
            var offline = true
            var asked = 0
            publisher.coverFetcher = { book, _, _ in
                asked += 1
                return offline ? nil : (Data(book.uuid.utf8), false)
            }
            seed(publisher)
            let session = Self.stubSession()

            #expect(publisher.updateLibrary(Self.library(), session: session))
            try await settle(publisher)
            let first = asked
            #expect(first == 2)
            #expect(!CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))

            // Inside the window: the same list asks for nothing.
            clock.addTimeInterval(CurrentBookPublisher.coverRetry - 1)
            #expect(!publisher.updateLibrary(Self.library(), session: session))
            try await settle(publisher)
            #expect(asked == first)

            // Past it, and back online: the same list brings the covers.
            offline = false
            clock.addTimeInterval(2)
            #expect(!publisher.updateLibrary(Self.library(), session: session))
            try await settle(publisher)
            #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "b"))
            #expect(CurrentBookSnapshotStore.hasOtherCover(bookID: "c"))
        }

        // MARK: - Which shape the other books' covers are asked for in

        /// A book in progress that may have either edition, or one of them.
        private static func edition(
            _ id: String, at timestamp: Double, ebook: Bool, audiobook: Bool,
        ) -> Book {
            SharedFixtures.book(
                id, uuid: id, status: "Reading", progress: 0.3, positionTimestamp: timestamp,
                audiobook: audiobook, ebook: ebook)
        }

        private func inScratchDirectory(_ body: () async throws -> Void) async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CurrentBookSnapshotStore.directoryOverride = directory
            defer {
                CurrentBookSnapshotStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: directory)
            }
            try await body()
        }

        @Test("a book with both editions is asked for its portrait cover for the list, and keeps it")
        func bothEditionsPublishPortrait() async throws {
            try await inScratchDirectory {
                let publisher = CurrentBookPublisher()
                var shapes: [String: [LibraryService.CoverShape]] = [:]
                publisher.coverFetcher = { book, _, shape in
                    shapes[book.uuid, default: []].append(shape)
                    return (Data("\(book.uuid)-\(shape)".utf8), shape == .square)
                }
                seed(publisher)
                let library = [
                    Self.reading("current", 0.5, at: 900),
                    Self.edition("both", at: 800, ebook: true, audiobook: true),
                ]
                #expect(publisher.updateLibrary(library, session: Self.stubSession()))
                try await settle(publisher)
                #expect(shapes["both"] == [.portrait])
                #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "both") == Data("both-portrait".utf8))
                #expect(CurrentBookSnapshotStore.read()?.others.first?.coverIsSquare == false)
            }
        }

        @Test("an audiobook-only book falls back to its square cover and is left alone after")
        func audiobookOnlyFallsBackToSquare() async throws {
            try await inScratchDirectory {
                let publisher = CurrentBookPublisher()
                var clock = Date(timeIntervalSince1970: 1_800_000_000)
                publisher.now = { clock }
                var asked = 0
                publisher.coverFetcher = { book, _, _ in
                    asked += 1
                    // The cache tries portrait, finds none, and hands back square.
                    return (Data("\(book.uuid)-square".utf8), true)
                }
                seed(publisher)
                let library = [
                    Self.reading("current", 0.5, at: 900),
                    Self.edition("audio", at: 800, ebook: false, audiobook: true),
                ]
                #expect(publisher.updateLibrary(library, session: Self.stubSession()))
                try await settle(publisher)
                #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "audio") == Data("audio-square".utf8))
                #expect(CurrentBookSnapshotStore.read()?.others.first?.coverIsSquare == true)
                let first = asked
                clock.addTimeInterval(CurrentBookPublisher.coverRetry + 1)
                _ = publisher.updateLibrary(library, session: Self.stubSession())
                try await settle(publisher)
                #expect(asked == first, "a settled square cover is not asked for again")
            }
        }

        @Test("a square cover stored by an earlier build is replaced once by the portrait one")
        func storedSquareIsReplacedOnce() async throws {
            try await inScratchDirectory {
                let publisher = CurrentBookPublisher()
                var clock = Date(timeIntervalSince1970: 1_800_000_000)
                publisher.now = { clock }
                var asked = 0
                publisher.coverFetcher = { book, _, shape in
                    asked += 1
                    return (Data("new-\(shape)".utf8), false)
                }
                // As the previous build left it: a square cover, no record of
                // portrait having been asked for.
                CurrentBookSnapshotStore.write(CurrentBookSnapshot(
                    bookID: "current", title: "current", author: "", progress: 0.5,
                    others: [OtherBook(bookID: "both", title: "both", progress: 0.3, coverIsSquare: true)]))
                CurrentBookSnapshotStore.writeOtherCover(Data("old-square".utf8), bookID: "both")
                let library = [
                    Self.reading("current", 0.5, at: 900),
                    Self.edition("both", at: 800, ebook: true, audiobook: true),
                ]
                _ = publisher.updateLibrary(library, session: Self.stubSession())
                try await settle(publisher)
                #expect(asked == 1)
                #expect(CurrentBookSnapshotStore.readOtherCover(bookID: "both") == Data("new-portrait".utf8))
                #expect(CurrentBookSnapshotStore.read()?.others.first?.coverIsSquare == false)

                clock.addTimeInterval(CurrentBookPublisher.coverRetry + 1)
                _ = publisher.updateLibrary(library, session: Self.stubSession())
                try await settle(publisher)
                #expect(asked == 1, "the portrait cover is not fetched again")
            }
        }

        @Test("when there is no portrait art the stored square one stays, and the ask is not repeated")
        func storedSquareStaysWhenThereIsNoPortrait() async throws {
            try await inScratchDirectory {
                let publisher = CurrentBookPublisher()
                var clock = Date(timeIntervalSince1970: 1_800_000_000)
                publisher.now = { clock }
                var asked = 0
                publisher.coverFetcher = { _, _, _ in
                    asked += 1
                    return (Data("only-square".utf8), true)
                }
                CurrentBookSnapshotStore.write(CurrentBookSnapshot(
                    bookID: "current", title: "current", author: "", progress: 0.5,
                    others: [OtherBook(bookID: "both", title: "both", progress: 0.3, coverIsSquare: true)]))
                CurrentBookSnapshotStore.writeOtherCover(Data("old-square".utf8), bookID: "both")
                let library = [
                    Self.reading("current", 0.5, at: 900),
                    Self.edition("both", at: 800, ebook: true, audiobook: true),
                ]
                _ = publisher.updateLibrary(library, session: Self.stubSession())
                try await settle(publisher)
                #expect(asked == 1)
                let snapshot = CurrentBookSnapshotStore.read()
                #expect(snapshot?.others.first?.coverIsSquare == true)
                #expect(snapshot?.others.first?.portraitChecked == true)
                for _ in 0 ..< 3 {
                    clock.addTimeInterval(CurrentBookPublisher.coverRetry + 1)
                    _ = publisher.updateLibrary(library, session: Self.stubSession())
                    try await settle(publisher)
                }
                #expect(asked == 1, "the attempt is remembered in the snapshot")
            }
        }

        @Test("the current book still takes the square cover where it has audio")
        func currentBookStillPrefersSquare() async throws {
            try await inScratchDirectory {
                let publisher = CurrentBookPublisher()
                var shapes: [LibraryService.CoverShape] = []
                publisher.coverFetcher = { _, _, shape in
                    shapes.append(shape)
                    return (Data("art".utf8), shape == .square)
                }
                let book = Self.edition("both", at: 900, ebook: true, audiobook: true)
                publisher.publish(
                    book: book, session: Self.stubSession(), progress: 0.4, chapter: nil,
                    remaining: nil, isPlaying: true, as: .listening("both"))
                let deadline = ContinuousClock.now + .seconds(5)
                while shapes.isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(shapes == [.square])
            }
        }

        @Test("selection seeds portrait for a book with text, and square for audio alone")
        func selectionSeeds() {
            let books = [
                Self.edition("both", at: 800, ebook: true, audiobook: true),
                Self.edition("audio", at: 700, ebook: false, audiobook: true),
                Self.edition("text", at: 600, ebook: true, audiobook: false),
            ]
            let picked = OtherBook.selection(from: books, excluding: nil)
            #expect(picked.map(\.bookID) == ["both", "audio", "text"])
            #expect(picked.map(\.coverIsSquare) == [false, true, false])
        }
    }
}

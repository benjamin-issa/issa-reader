import Foundation
import IssaAsk
import IssaEPUB
import IssaPlayback
import IssaUI
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What a removal takes with it, and — more importantly — what it must not.
///
/// A download leaves four kinds of derived file behind: the book itself, the
/// narration extracted from a read-along, the question index built from its
/// text, and the publisher face pulled out of the EPUB. Three of those were
/// being forgotten in at least one path, and the fourth — the reader's own
/// imported fonts, and their annotations — must survive every one of them.
///
/// `.serialized`, because these tests write into the app's real download
/// directory. That is deliberate: `refreshDownloadedSet` reads that directory
/// and nothing else, so a test that pointed it somewhere else would be testing
/// a seam rather than the behaviour. Each test uses a uuid of its own and
/// cleans up after itself.
@Suite("Removing a download", .serialized)
@MainActor
struct DownloadRemovalTests {
    private final class BundleMarker {}

    /// A bare uuid, so `BookContentService` names the file rather than hashing
    /// it — a hashed name does not decode back and the set would never contain
    /// the book at all.
    private static func freshUUID() -> String { UUID().uuidString }

    private static func booksDirectory() throws -> URL {
        let directory = BookContentService.defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One test below makes this directory unreadable on purpose, and
        // restores it in a `defer`. A run killed between those two — a stopped
        // test, a crashed process — would otherwise leave the simulator's
        // container locked and every later run failing at launch, on a fault
        // with nothing to do with the code being tested. Repaired here, where
        // every test in the suite passes through.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        return directory
    }

    @discardableResult
    private static func plant(
        _ uuid: String, format: BookContentService.Format, bytes: Int = 32,
    ) throws -> URL {
        let url = BookContentService.localURL(
            in: try booksDirectory(), bookUUID: uuid, format: format)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `AskCoordinator.remove` hands the deletion to the store's actor and the
    /// font sweep is synchronous, so an assertion about the index has to wait
    /// for the hop rather than for the call to return.
    private static func eventually(
        _ condition: @escaping @Sendable () async -> Bool,
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    // MARK: - One edition, not the book

    /// The book screen removes a single edition, and the model refreshes a set
    /// keyed by book uuid — so "does removing the ebook take the read-along
    /// with it" is a question the shape of the state cannot answer on its own.
    @Test("removing one edition leaves the other on the device")
    func removingOneEditionLeavesTheOther() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }

        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        app.removeDownload(book, format: .ebook)

        #expect(!Self.exists(ebook))
        #expect(Self.exists(readaloud), "the reader asked for one edition to go, not the book")
        #expect(app.downloadedUUIDs.contains(uuid), "the book is still downloaded")
    }

    /// Everything a removal has no business touching. The rating is the newest
    /// of these — it only began persisting recently — and the position is what
    /// a reader would notice first.
    @Test("a removal leaves the rating, the position and the annotations alone")
    func removalLeavesTheReadersOwnDataAlone() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let book = SharedFixtures.book(
            "Dracula", uuid: uuid, status: "Reading", progress: 0.42, positionTimestamp: 99)
        app.books = [book]
        app.ratings[uuid] = 4

        // A real annotation in a real store, because "device-local and this is
        // their only copy" is the whole reason it must survive.
        let serverKey = "removal-test-\(UUID().uuidString)"
        let store = try LibraryStore(serverKey: serverKey)
        defer {
            let file = LibraryStore.defaultDirectory()
                .appending(path: "library-\(LibraryStore.filename(for: serverKey)).sqlite")
            try? FileManager.default.removeItem(at: file)
        }
        try await store.save(Annotation(
            bookUUID: uuid, kind: .highlight,
            locator: ReadiumLocator(href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml"),
            excerpt: "Listen to them, the children of the night.",
        ))

        app.removeDownload(book, format: .ebook)

        #expect(!Self.exists(file))
        #expect(app.ratings[uuid] == 4)
        #expect(app.books.first?.position?.timestamp == 99)
        let progression = app.bookByUUID[uuid]?.progress
        #expect(progression != nil && abs(progression! - 0.42) < 0.0001)
        let kept = try await store.annotations(for: uuid)
        #expect(kept.count == 1, "annotations are the reader's, not the download's")
    }

    // MARK: - Nothing may be playing out of a file being deleted

    /// A book with no audio behind it, which is all these need: what is under
    /// test is whether anything asked before deleting, not what came out of the
    /// speaker.
    private static func silentEngine() -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "Dracula"]),
                readingOrder: [.init(href: "track1.mp3", type: "audio/mpeg", duration: 60)]),
            source: .files([:]))
    }

    /// A reader narrating a book, without a real EPUB behind it.
    ///
    /// `narratingBookUUID` is claimed by the rate observer `reader(for:session:)`
    /// installs, so the honest way to set it is to play — and `play()` notifies
    /// its observers whether or not anything loaded, which is the whole reason
    /// this needs no audio.
    private static func narrating(_ app: AppModel, _ book: Book) throws -> ReaderModel {
        let model = app.reader(for: book, session: try session())
        model.attachNarration(
            timeline: SMILTimeline(entries: [
                SMILEntry(
                    fragmentID: "ch01-s0", textHref: "OEBPS/ch01.xhtml",
                    audioHref: "OEBPS/Audio/track1.mp3",
                    start: 0, end: 4, cumulativeEnd: 4),
            ]),
            audioFiles: [:])
        model.readalong?.player.play()
        return model
    }

    private static func session() throws -> Session {
        Session(
            serverURL: URL(string: "https://library.example")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: .ephemeral),
        )
    }

    /// The audiobook engine plays a downloaded read-along straight out of the
    /// extracted narration directory, through a `.files` source — and
    /// `releaseDerivedFiles` deletes that directory. Nothing asked: the current
    /// item played on, and the next `advance()` found the file gone. Mid-drive
    /// the book stopped dead, with a log line and no control anywhere that could
    /// start it again.
    @Test("removing a book that is playing stops it first")
    func removingStopsTheAudiobook() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .readaloud)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()
        let engine = Self.silentEngine()
        app.installListening(engine, book: SharedFixtures.book("Dracula", uuid: uuid))

        app.removeDownload(bookUUID: uuid, format: .readaloud)

        #expect(app.listening == nil, "the engine was reading out of the file that just went")
        #expect(app.listeningBook == nil)
        #expect(engine.player.isPlaying == false)
        #expect(!Self.exists(file))
    }

    /// The other engine, and the other file: the reader narrates out of the
    /// EPUB itself, which `BookContentService.removeDownload` deletes before the
    /// derived files are touched at all.
    @Test("removing a book being narrated stops the narration first")
    func removingStopsTheNarration() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .readaloud)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.books = [book]
        let model = try Self.narrating(app, book)
        #expect(app.reader === model, "the setup has to have claimed narration")

        app.removeDownload(bookUUID: uuid, format: .readaloud)

        #expect(app.reader == nil, "nothing may narrate a book whose text has gone")
        #expect(model.readalong?.player.isPlaying == false)
        #expect(!Self.exists(file))
    }

    /// A removal the app did not make. On an Apple TV every download lives in
    /// Caches, which the system may reclaim under storage pressure, and the
    /// sweep deletes the same narration directory a tap would — so it owes the
    /// listener the same courtesy.
    @Test("the sweep stops a book whose file went behind the app's back")
    func theSweepStopsAPlayingBook() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .readaloud)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))
        let engine = Self.silentEngine()
        app.installListening(engine, book: SharedFixtures.book("Dracula", uuid: uuid))

        // Gone, with no `removeDownload` anywhere near it.
        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(app.listening == nil, "the sweep deletes what this was playing out of")
        #expect(engine.player.isPlaying == false)
    }

    // MARK: - Which engine a removal is entitled to stop

    /// The two lines above keyed on the book uuid alone, while
    /// `releaseDerivedFiles` beside them is format-aware — so a removal stopped
    /// whatever was playing the book whether or not it had anything to do with
    /// the file going away. Deleting the ebook of a book being listened to
    /// killed the drive, having deleted nothing the engine was reading.
    ///
    /// Two editions planted throughout, so the book never loses its last file:
    /// a book that does departs, and the reconciliation sweep would then stop
    /// everything for an entirely different reason and these would pass without
    /// proving a thing.
    @Test("removing the ebook leaves an audiobook playing")
    func removingTheEbookLeavesTheAudiobookPlaying() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        defer { for url in [ebook, audiobook] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let engine = Self.silentEngine()
        engine.player.play()
        app.installListening(
            engine, book: SharedFixtures.book("Dracula", uuid: uuid), reading: .audiobook)

        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(app.listening === engine, "the file that went is not the file it was reading")
        #expect(engine.player.isPlaying, "a drive must not end because a book was tidied up")
        #expect(!Self.exists(ebook))
        #expect(Self.exists(audiobook))
    }

    /// The other engine, and the reason `.ebook` stops nothing at all:
    /// narration is only ever built from the `.readaloud` package —
    /// `ReaderModel.prepareNarration` hands `AudioExtraction` that file and no
    /// other — so a reader opened on an ebook has an empty timeline and no
    /// read-along to make a sound with. The one that *is* narrating is reading
    /// out of a file the removal has not touched.
    @Test("removing the ebook leaves a narration playing")
    func removingTheEbookLeavesTheNarrationPlaying() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.books = [book]
        let model = try Self.narrating(app, book)

        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(app.reader === model, "the read-along it is narrating from is still on the device")
        #expect(model.readalong?.player.isPlaying == true)
        #expect(Self.exists(readaloud))
    }

    /// The case that must still stop: the engine is playing the server's single
    /// upload, straight out of the `.audiobook` download, and that download is
    /// what is being deleted.
    @Test("removing the audiobook stops an engine playing the single upload")
    func removingTheAudiobookStopsTheEngineReadingIt() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        defer { for url in [ebook, audiobook] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let engine = Self.silentEngine()
        engine.player.play()
        app.installListening(
            engine, book: SharedFixtures.book("Dracula", uuid: uuid), reading: .audiobook)

        app.removeDownload(bookUUID: uuid, format: .audiobook)

        #expect(app.listening == nil, "the engine was reading the file that just went")
        #expect(engine.player.isPlaying == false)
        #expect(!Self.exists(audiobook))
    }

    /// And the same removal, with the engine reading somewhere else entirely. A
    /// downloaded read-along is played from its own extracted narration chunks
    /// through a `.files` source, which the `.audiobook` download has nothing to
    /// do with — the two editions of one book are two different files.
    @Test("removing the audiobook leaves an engine playing the read-along's chunks")
    func removingTheAudiobookLeavesTheChunkEngineAlone() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let readaloud = try Self.plant(uuid, format: .readaloud)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        defer { for url in [readaloud, audiobook] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let engine = Self.silentEngine()
        engine.player.play()
        app.installListening(
            engine, book: SharedFixtures.book("Dracula", uuid: uuid), reading: .readaloud)

        app.removeDownload(bookUUID: uuid, format: .audiobook)

        #expect(app.listening === engine, "its chunks come out of the read-along, not this")
        #expect(engine.player.isPlaying)
        #expect(Self.exists(readaloud))
    }

    /// The read-along is the one edition both engines can be reading: the
    /// reader narrates out of the EPUB, and the car plays the narration
    /// extracted from it. So removing it is the one format-named removal that
    /// has to stop both.
    @Test("removing the read-along stops both engines")
    func removingTheReadaloudStopsBoth() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.books = [book]
        // Narration first: `narrationDidStart` calls `stopListening` on its way
        // in, so an engine installed before this would be evicted by the setup
        // rather than by the removal under test.
        let model = try Self.narrating(app, book)
        let engine = Self.silentEngine()
        engine.player.play()
        app.installListening(engine, book: book, reading: .readaloud)

        app.removeDownload(bookUUID: uuid, format: .readaloud)

        #expect(app.listening == nil, "the chunks it was playing are extracted from this file")
        #expect(engine.player.isPlaying == false)
        #expect(app.reader == nil, "and the text it was narrating is this file")
        #expect(model.readalong?.player.isPlaying == false)
    }

    /// A book nobody downloaded. Streaming reads no file on this device, so no
    /// removal can silence it — and stopping a stream because a download was
    /// deleted would be a fresh bug in place of the fixed one, in a car, in a
    /// tunnel.
    ///
    /// Three editions so both named removals can run without the book ever
    /// losing its last file, which is the sweep's business rather than a
    /// removal's.
    @Test("a streamed book survives every removal")
    func aStreamedBookSurvivesEveryRemoval() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 96)
        defer {
            for url in [ebook, audiobook, readaloud] { try? FileManager.default.removeItem(at: url) }
        }
        app.refreshDownloadedSet()
        let engine = Self.silentEngine()
        engine.player.play()
        app.installListening(
            engine, book: SharedFixtures.book("Dracula", uuid: uuid), reading: nil)

        app.removeDownload(bookUUID: uuid, format: .ebook)
        #expect(app.listening === engine, "a stream is not read out of anything on this device")

        app.removeDownload(bookUUID: uuid, format: .audiobook)
        #expect(app.listening === engine, "nor out of the edition it is named after")
        #expect(engine.player.isPlaying)
    }

    /// The sweep asks none of these questions, and must not. It runs for a book
    /// that has lost its last file behind the app's back — an Apple TV
    /// reclaiming Caches, a restore, a failed move — so it cannot tell which
    /// file went, and `releaseDerivedFiles` deletes the extracted narration
    /// along with everything else. Everything playing that book stops, whatever
    /// it believed it was reading.
    @Test("the sweep stops both engines whatever they were reading")
    func theSweepStopsBothEngines() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.books = [book]
        let model = try Self.narrating(app, book)
        let engine = Self.silentEngine()
        engine.player.play()
        // A format no named removal of the file below would have touched, so
        // this can only be the sweep's doing.
        app.installListening(engine, book: book, reading: .audiobook)

        // Gone, with no `removeDownload` anywhere near it.
        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(app.listening == nil, "the sweep cannot say which file went, so none is safe")
        #expect(engine.player.isPlaying == false)
        #expect(app.reader == nil)
        #expect(model.readalong?.player.isPlaying == false)
    }

    // MARK: - A removal that lands before the start has attached

    /// `listeningBook` is first written inside `attachListening`, which is the
    /// far end of a manifest fetch, a chunk extraction and a duration
    /// measurement — seconds on a long book, and every one of them on a cold
    /// launch straight into CarPlay. For that whole stretch a removal looked at
    /// an empty listening slot and did nothing, and the start then woke up and
    /// installed a coordinator over files that had just been deleted.
    ///
    /// The claim is what makes that window visible. It is staged directly here
    /// rather than reached through `startListening`, which needs a signed-in
    /// session and a server holding a manifest — the same terms
    /// `installListening` is internal on.
    @Test("a removal clears a start that has claimed the book but not attached it")
    func aRemovalClearsAnUnattachedStart() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.claimListeningStart(book, reading: .readaloud)

        app.removeDownload(bookUUID: uuid, format: .readaloud)

        #expect(app.startingListeningBook == nil,
                "a start that has not attached still owns the book it is about to play")
        #expect(app.listening == nil, "and nothing may be installed for it afterwards")
        #expect(!Self.exists(readaloud))
    }

    /// The claim narrows as the start works out what it is doing — `.readaloud`
    /// while it extracts chunks, `.audiobook` or nil once the server's manifest
    /// has said whether there is a single file to play. So it answers the same
    /// question the engine does, and a removal of the other edition is none of
    /// its business.
    @Test("a removal of another edition leaves the claim alone")
    func aRemovalOfAnotherEditionLeavesTheClaim() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let audiobook = try Self.plant(uuid, format: .audiobook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [audiobook, readaloud] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()
        let book = SharedFixtures.book("Dracula", uuid: uuid, readaloud: true)
        app.claimListeningStart(book, reading: .readaloud)

        app.removeDownload(bookUUID: uuid, format: .audiobook)

        #expect(app.startingListeningBook == uuid,
                "the chunks it is extracting come out of the read-along, not this")
        #expect(Self.exists(readaloud))
    }

    // MARK: - Reconciliation

    /// The sweep. A download can go without this app deleting it — an Apple TV
    /// keeps them in Caches, which the system may reclaim — and everything
    /// derived from it is then orphaned. The index in particular is the text of
    /// the reader's book, which PRIVACY.md promises is "deleted when you delete
    /// the download or sign out".
    @Test("a file that went behind the model's back takes its question index with it")
    func reconcileDropsTheIndexOfADepartedDownload() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()

        // The download is a real book, copied into the real download directory,
        // so the index below is built from the file that is about to vanish.
        let bundle = Bundle(for: BundleMarker.self)
        let fixture = try #require(bundle.url(forResource: "alice", withExtension: "epub"))
        let file = BookContentService.localURL(
            in: try Self.booksDirectory(), bookUUID: uuid, format: .ebook)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: fixture, to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let indexes = URL.temporaryDirectory.appending(path: "issa-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexes) }
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = AskIndexStore(directory: indexes)
        // Held strongly for the length of the test: `AppModel.ask` is weak, and
        // a coordinator nobody owns is a sweep that quietly does nothing.
        let coordinator = AskCoordinator(
            store: store, model: ScriptedAnswerModel(), notifier: nil, defaults: defaults)
        app.ask = coordinator

        let source = try BookSource(bookUUID: uuid, fileURL: file)
        _ = try await store.prepare(source: source)
        #expect(await store.isPrepared(source: source), "the index has to exist to be dropped")

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // Gone, without a `removeDownload` anywhere near it.
        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(!app.downloadedUUIDs.contains(uuid))
        let dropped = await Self.eventually { await !store.isPrepared(source: source) }
        #expect(dropped, "the index outlived the book it was built from")
    }

    /// `resolvePublisherFont` writes a book's embedded face to
    /// `Fonts/<book-uuid>/` on every open and nothing ever removed it. The
    /// second half matters at least as much: the faces at the root of `Fonts/`
    /// were imported by the reader, this is their only copy, and they are no
    /// more the download's than an annotation is.
    @Test("reconciling removes a book's extracted face and leaves the reader's own")
    func reconcileRemovesExtractedFontsOnly() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .readaloud)
        defer { try? FileManager.default.removeItem(at: file) }

        let fonts = try #require(CustomFonts.importedDirectory)
        let mine = fonts.appending(path: "imported-\(uuid).otf")
        try Data("not really a font".utf8).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data("nor is this".utf8).write(to: extracted.appending(path: "body.otf"))
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        try FileManager.default.removeItem(at: file)
        app.refreshDownloadedSet()

        #expect(!Self.exists(extracted), "the face came out of the book that has gone")
        #expect(Self.exists(mine), "that one is the reader's")
        #expect(Self.exists(fonts), "and so is the folder it lives in")
    }

    /// The ordinary path runs the sweep as well — `removeDownload` refreshes
    /// the set, which is what notices the departure — so the steps have to be
    /// safe to run twice.
    @Test("removing the last edition and reconciling it are the same removal, run twice")
    func removalIsIdempotentWithTheSweep() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data("face".utf8).write(to: extracted.appending(path: "body.otf"))
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        app.removeDownload(SharedFixtures.book("Dracula", uuid: uuid), format: .ebook)

        #expect(!Self.exists(file))
        #expect(!Self.exists(extracted))
        #expect(!app.downloadedUUIDs.contains(uuid))
    }

    /// The half of a two-edition removal that had no owner.
    ///
    /// The publisher face and the question index are derived from the book's
    /// *text*, and either edition carries it — so releasing them because one of
    /// the two went destroyed data belonging to the copy still on the device.
    /// `DownloadsInventory.departed` had already written the rule down — "a book
    /// that lost one of two editions has not departed" — and the deletion path
    /// was the one place not honouring it.
    ///
    /// Nothing on screen changes when this is wrong, which is why it needs a
    /// test: the reader finds out on the next open, when the book is set in the
    /// fallback face and every question it had been indexed for has to be
    /// indexed again.
    @Test("removing one of two editions keeps the face and index of the other")
    func removingOneEditionKeepsTheBooksDerivedFiles() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        // A real book for the ebook, because the index below is built by parsing
        // it — and the point of the test is that the index outlives it.
        let bundle = Bundle(for: BundleMarker.self)
        let fixture = try #require(bundle.url(forResource: "alice", withExtension: "epub"))
        let ebook = BookContentService.localURL(
            in: try Self.booksDirectory(), bookUUID: uuid, format: .ebook)
        try? FileManager.default.removeItem(at: ebook)
        try FileManager.default.copyItem(at: fixture, to: ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let indexes = URL.temporaryDirectory.appending(path: "issa-editions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexes) }
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = AskIndexStore(directory: indexes)
        // Held strongly: `AppModel.ask` is weak, and a coordinator nobody owns
        // is a removal that quietly does nothing and a test that proves nothing.
        let coordinator = AskCoordinator(
            store: store, model: ScriptedAnswerModel(), notifier: nil, defaults: defaults)
        app.ask = coordinator
        let source = try BookSource(bookUUID: uuid, fileURL: ebook)
        _ = try await store.prepare(source: source)
        // The index *file*, not `isPrepared`: that re-reads the fingerprint of
        // the EPUB it was built from, so once the ebook has gone it answers
        // false whether or not the index survived — which is precisely the
        // distinction this test exists to draw.
        let index = store.indexURL(for: uuid)
        #expect(Self.exists(index), "the index has to exist to be kept")

        app.refreshDownloadedSet()
        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(!Self.exists(ebook), "the edition asked for is the one that goes")
        #expect(Self.exists(readaloud))
        #expect(app.downloadedUUIDs.contains(uuid), "the book has not departed")
        #expect(Self.exists(face), "the face belongs to the read-along still on disk")
        // Given a moment to be wrong: the removal hands the index to the store's
        // actor, so asserting straight away would pass whether or not it went.
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.exists(index),
                "the index was built from text that is still on the device")

        // And when the last edition carrying text goes, both do go.
        app.removeDownload(bookUUID: uuid, format: .readaloud)
        #expect(!Self.exists(face))
        let indexPath = index.path
        let dropped = await Self.eventually {
            !FileManager.default.fileExists(atPath: indexPath)
        }
        #expect(dropped)
    }

    /// An audiobook carries no text, so it cannot be what a face or an index was
    /// derived from — a book left with only one has nothing behind either.
    @Test("an audiobook left on the device does not keep a face alive")
    func anAudiobookIsNotTextOnTheDevice() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let audiobook = try Self.plant(uuid, format: .audiobook, bytes: 64)
        defer { for url in [ebook, audiobook] { try? FileManager.default.removeItem(at: url) } }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        app.removeDownload(bookUUID: uuid, format: .ebook)

        #expect(Self.exists(audiobook), "the edition not asked for stays")
        #expect(!Self.exists(face), "nothing left on the device has any text in it")
    }

    /// The sweep's worst case, and the one it is least equipped to notice.
    ///
    /// `downloadedBookUUIDs` coalesced a failed directory read to an empty set,
    /// and every book the app knew about was then in `previous` and in no
    /// `current` — so the sweep concluded that the reader had deleted their
    /// entire library and deleted every book's question index, extracted
    /// narration and publisher font to match. None of that is re-downloadable:
    /// the index is minutes of on-device work, and the narration is hundreds of
    /// megabytes. The files themselves were untouched, which is what made it
    /// invisible until the next time a book was opened.
    ///
    /// An unreadable directory is a fact about this moment — a permissions
    /// fault, a detached volume, a device still unlocking after a restart — and
    /// says nothing about what is on the disk. So: keep the last set, run no
    /// sweep, and try again on the next refresh.
    @Test("a downloads directory that cannot be read is not an empty library")
    func anUnreadableDirectoryIsNotADeparture() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // Unreadable, and emphatically not empty. Restored unconditionally: this
        // is the app's real downloads directory, and leaving it at 0o000 would
        // break every test after it rather than only this one.
        let directory = try Self.booksDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        app.refreshDownloadedSet()

        #expect(app.downloadedUUIDs.contains(uuid),
                "the last set it could read is a better answer than a wrong one")
        #expect(Self.exists(face), "the sweep deleted a face for a book that never left")
    }

    // MARK: - The undo window

    /// The mockup asks for an undo toast and says nothing in the section may
    /// start a download. Both can only be true if the bytes are still there
    /// while the toast is up — so the row goes at once and the file goes when
    /// the window closes.
    @Test("a removal inside its undo window has not touched the disk yet")
    func undoWindowDefersTheDeletion() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))

        #expect(app.pendingRemoval?.bookUUID == uuid)
        #expect(Self.exists(file), "undo must never have to fetch anything back")

        app.undoPendingRemoval()
        #expect(app.pendingRemoval == nil)
        #expect(Self.exists(file))
    }

    @Test("the window closing deletes what it was holding")
    func theWindowCommits() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        app.commitPendingRemoval()

        #expect(app.pendingRemoval == nil)
        #expect(!Self.exists(file))
    }

    /// One at a time, like Mail's undo send: a toast that could mean any of
    /// three rows is not an undo, so a second removal commits the first.
    @Test("a second removal commits the first rather than losing it")
    func aSecondRemovalCommitsTheFirst() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let first = Self.freshUUID()
        let second = Self.freshUUID()
        let firstFile = try Self.plant(first, format: .ebook)
        let secondFile = try Self.plant(second, format: .ebook)
        defer {
            for url in [firstFile, secondFile] { try? FileManager.default.removeItem(at: url) }
        }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: first, format: .ebook, title: "One",
                           undoWindow: .seconds(600))
        app.removeDownload(bookUUID: second, format: .ebook, title: "Two",
                           undoWindow: .seconds(600))

        #expect(!Self.exists(firstFile), "the first window closed when the second opened")
        #expect(Self.exists(secondFile))
        #expect(app.pendingRemoval?.bookUUID == second)
        app.commitPendingRemoval()
    }

    /// The window was visible to the rows of one section and to nothing else.
    ///
    /// `downloadedUUIDs` is what the offline shelf filters on, what CarPlay's
    /// catalogue is built from and what the library's arrangement sorts by, and
    /// for the whole six seconds it went on reporting the edition as present.
    /// So every surface but the one the reader was looking at offered a book
    /// whose file was about to be deleted; in a car, in a tunnel, that is
    /// silence, and `CarPlaySceneDelegate` says so in as many words.
    @Test("an edition inside its undo window is off the device everywhere")
    func theUndoWindowIsVisibleToEverySurface() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))
        #expect(app.isDownloaded(bookUUID: uuid, format: .ebook))

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))

        #expect(!app.downloadedUUIDs.contains(uuid),
                "the car was still being offered a book about to be deleted")
        #expect(!app.isDownloaded(bookUUID: uuid, format: .ebook))
        #expect(Self.exists(file), "and the bytes are still there, which is the point")

        app.undoPendingRemoval()
        #expect(app.downloadedUUIDs.contains(uuid), "undo puts it back with no fetch")
        #expect(app.isDownloaded(bookUUID: uuid, format: .ebook))
    }

    /// Keyed by book, so a book that has lost one of two editions is still on
    /// the device — the same rule `DownloadsInventory.departed` states. Taking
    /// the whole book out of the set here would empty its row from the shelf
    /// while the read-along it still has sat on disk.
    @Test("a book with a second edition stays on the device during the window")
    func aSecondEditionKeepsTheBookOnTheShelf() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        let readaloud = try Self.plant(uuid, format: .readaloud, bytes: 64)
        defer { for url in [ebook, readaloud] { try? FileManager.default.removeItem(at: url) } }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))

        #expect(app.downloadedUUIDs.contains(uuid), "the read-along is still on the device")
        #expect(!app.isDownloaded(bookUUID: uuid, format: .ebook), "but this edition is going")
        #expect(app.isDownloaded(bookUUID: uuid, format: .readaloud))
        app.commitPendingRemoval()
    }

    /// The X on a transfer row says "Cancel" and is drawn on a progress bar,
    /// and it ran a whole book's removal — so cancelling a download started by
    /// mistake released the publisher face and question index of a *different*
    /// edition of that book already on the device. A tap on a cross belonging
    /// to a bar that has not finished is not a decision about anything the
    /// reader already has.
    @Test("cancelling a transfer leaves the book's other edition untouched")
    func cancellingATransferIsNotABookRemoval() throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let ebook = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: ebook) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: uuid)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = extracted.appending(path: "body.otf")
        try Data("face".utf8).write(to: face)
        defer { try? FileManager.default.removeItem(at: extracted) }

        app.refreshDownloadedSet()
        #expect(app.downloadedUUIDs.contains(uuid))

        // The read-along the reader started by accident. No file for it, which
        // is what a transfer still running looks like on disk.
        app.cancelDownload(DownloadManager.Job(bookUUID: uuid, format: .readaloud))

        #expect(Self.exists(ebook), "the edition already on the device is not what was cancelled")
        #expect(Self.exists(face), "the face belongs to the ebook, which nobody asked to remove")
        #expect(app.downloadedUUIDs.contains(uuid))
    }

    /// Restarting a download inside the undo window is the reader changing
    /// their mind, and nothing was telling the window that.
    ///
    /// The timer was armed by the removal and never disarmed, so the file the
    /// new transfer was arriving into was deleted six seconds later by a
    /// decision the reader had already reversed. On screen it looked like a
    /// download that simply stopped: no error, because from the app's point of
    /// view nothing had failed.
    @Test("starting a download takes back a removal still inside its window")
    func startingADownloadCancelsAPendingRemoval() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        #expect(app.pendingRemoval?.bookUUID == uuid)

        // No session, so no transfer actually starts — `download` returns false
        // at the `downloads` guard. The pending removal has to be taken back
        // before that point is even reached, because the tap is the statement.
        await app.resumeDownload(DownloadManager.Job(bookUUID: uuid, format: .ebook))

        #expect(app.pendingRemoval == nil, "the window is still armed over a book being fetched")
        app.commitPendingRemoval()
        #expect(Self.exists(file), "the window closed on a removal the reader had reversed")
    }

    /// Only the same edition. A removal of one book says nothing about a
    /// download of another, and clearing the window on any download at all
    /// would make the toast lie about what it is holding.
    @Test("starting a different download leaves the window alone")
    func adifferentDownloadLeavesTheWindowAlone() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let removed = Self.freshUUID()
        let other = Self.freshUUID()
        let file = try Self.plant(removed, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: removed, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        await app.resumeDownload(DownloadManager.Job(bookUUID: other, format: .ebook))
        #expect(app.pendingRemoval?.bookUUID == removed)

        // And the same book in a different edition is a different job too.
        await app.resumeDownload(DownloadManager.Job(bookUUID: removed, format: .readaloud))
        #expect(app.pendingRemoval?.bookUUID == removed)

        app.commitPendingRemoval()
        #expect(!Self.exists(file))
    }

    /// A timer that fired after the account had gone would delete a file
    /// belonging to whoever signed in next.
    @Test("signing out closes an open undo window first")
    func signingOutCommitsAPendingRemoval() async throws {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let uuid = Self.freshUUID()
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        app.refreshDownloadedSet()

        app.removeDownload(bookUUID: uuid, format: .ebook, title: "Dracula",
                           undoWindow: .seconds(600))
        await app.signOut(keepDownloads: true)

        #expect(app.pendingRemoval == nil)
        #expect(!Self.exists(file))
    }
}

/// A token store that never touches the keychain, so these tests neither read
/// nor write the real one.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}

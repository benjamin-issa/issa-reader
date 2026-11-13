import AVFoundation
import Foundation
import IssaPlayback
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A transport that never reaches a server, as with no signal.
final class UnreachableServer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

extension WidgetStorage {
    /// An audiobook saved with "Save for offline" plays with no server.
    ///
    /// Listen asked the server for the manifest before it looked at the file,
    /// so a downloaded book would not start in a tunnel. `.serialized`: each
    /// test plants files in the app's real download directory.
    @Suite("A downloaded audiobook plays without the server", .serialized)
    @MainActor
    struct OfflineAudiobookTests {
        /// Thirty seconds of silence as an AAC file, which AVFoundation opens by
        /// its contents. A download is named `.epub` whatever it holds, and a
        /// WAV, which it takes from the extension, would not open under that
        /// name.
        private static let silentAAC: URL = {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "issa-offline-audiobook-\(UUID().uuidString).m4a")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try! AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for _ in 0 ..< 30 { try! file.write(from: buffer) }
            return url
        }()

        private static func plantAudiobook(_ uuid: String) throws -> URL {
            let directory = BookContentService.defaultDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = BookContentService.localURL(in: directory, bookUUID: uuid, format: .audiobook)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: silentAAC, to: url)
            return url
        }

        private static func listen(
            _ app: AppModel, to book: Book,
        ) async -> NowPlayingController {
            let suite = "offline-audiobook.\(UUID().uuidString)"
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let nowPlaying = NowPlayingController()
            await app.startListening(
                to: book, nowPlaying: nowPlaying, settings: PlaybackSettings(suiteName: suite))
            return nowPlaying
        }

        /// The manifest was kept when the file was fetched: the server is not
        /// asked at all.
        @Test("a download with its manifest saved starts without asking the server")
        func savedManifestStartsWithoutTheServer() async throws {
            let fixture = try await WidgetStorage.AccountExitTests.signedInAsA()
            defer { fixture.tearDown() }
            let uuid = UUID().uuidString
            let file = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            _ = file
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)
            let content = BookContentService(client: fixture.app.session!.client)
            try content.saveManifest(
                AudiobookManifest(
                    metadata: .init(title: ["und": "Offline"], duration: 30),
                    readingOrder: [.init(href: "book.mp3", title: "Offline", duration: 30)]),
                for: book)
            fixture.app.refreshDownloadedSet()

            let nowPlaying = await Self.listen(fixture.app, to: book)
            defer { fixture.app.stopListening(nowPlaying: nowPlaying) }

            #expect(fixture.app.listeningError == nil)
            #expect(fixture.app.listeningBook?.uuid == uuid)
            #expect(LifecycleServer.requests(to: fixture.server)
                .filter { $0.path == LifecycleServer.manifestPath(uuid) }.isEmpty,
                    "Listen asked the server for a manifest the download already had")
        }

        /// A download made by 1.7.0 has no saved manifest. With the server out
        /// of reach it still plays, over a manifest measured from the file.
        @Test("a download with no saved manifest plays when the server cannot be reached")
        func unsavedDownloadPlaysOffline() async throws {
            let server = URL(string: "https://unreachable-\(UUID().uuidString.prefix(8).lowercased()).test")!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UnreachableServer.self]
            let tokens = LifecycleTokens()
            tokens.write("token-A", account: server.absoluteString)
            let app = AppModel(keychain: tokens, notificationCentre: NotificationCenter())
            app.session = Session(
                serverURL: server, keychain: tokens, session: URLSession(configuration: configuration))
            app.serverAddress = server.absoluteString
            let uuid = UUID().uuidString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)

            let nowPlaying = await Self.listen(app, to: book)
            defer { app.stopListening(nowPlaying: nowPlaying) }

            #expect(app.listeningError == nil, "\(app.listeningError ?? "")")
            #expect(app.listeningBook?.uuid == uuid)
        }

        private static func unreachableApp() -> AppModel {
            let server = URL(string: "https://unreachable-\(UUID().uuidString.prefix(8).lowercased()).test")!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UnreachableServer.self]
            let tokens = LifecycleTokens()
            tokens.write("token-A", account: server.absoluteString)
            let app = AppModel(keychain: tokens, notificationCentre: NotificationCenter())
            app.session = Session(
                serverURL: server, keychain: tokens, session: URLSession(configuration: configuration))
            app.serverAddress = server.absoluteString
            return app
        }

        /// The track a stored position names is the server's name for it. The
        /// file's own name on this device is nobody else's, and a stored
        /// position under another name was read as another manifest's.
        @Test("a stand-in manifest names the track the stored position names")
        func standInNamesTheStoredTrack() async throws {
            let app = Self.unreachableApp()
            let uuid = UUID().uuidString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let book = SharedFixtures.book(
                "Offline", uuid: uuid, progress: 0.5, positionTimestamp: 100,
                positionHref: "/api/books/track-1.mp3", positionType: "audio/mpeg", audiobook: true)

            let nowPlaying = await Self.listen(app, to: book)
            defer { app.stopListening(nowPlaying: nowPlaying) }

            #expect(app.listeningError == nil, "\(app.listeningError ?? "")")
            #expect(app.listening?.manifest.readingOrder.first?.href == "/api/books/track-1.mp3")
            #expect(app.listeningWritesPositions, "listening offline was not saved")
        }

        /// With no stored position there is no name to borrow, and a place
        /// written under the file's own name would be one no other client could
        /// match to a track. It plays; nothing is written until the real
        /// manifest is known.
        @Test("a stand-in with no track name to borrow plays and writes nothing")
        func standInWithoutAnameWritesNothing() async throws {
            let app = Self.unreachableApp()
            let uuid = UUID().uuidString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)

            let nowPlaying = await Self.listen(app, to: book)
            defer { app.stopListening(nowPlaying: nowPlaying) }

            #expect(app.listeningBook?.uuid == uuid)
            #expect(!app.listeningWritesPositions)
        }

        /// One track of several has a fraction of its own that is not the
        /// book's, and the file here is the whole book: a place written under
        /// that track's name with a whole-file offset resumed it at the end of
        /// the track on the next online start, and saved it.
        @Test("a stored place inside one of several tracks is not written under that track")
        func standInOverAPlaceInOneOfSeveralTracksWritesNothing() async throws {
            let app = Self.unreachableApp()
            let uuid = UUID().uuidString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            // Halfway through the second of four equal tracks.
            let book = SharedFixtures.book(
                "Offline", uuid: uuid, progress: 0.375, positionTimestamp: 100,
                positionHref: "/api/books/track-2.mp3", positionType: "audio/mpeg",
                positionProgression: 0.5, audiobook: true)

            let nowPlaying = await Self.listen(app, to: book)
            defer { app.stopListening(nowPlaying: nowPlaying) }

            #expect(app.listeningBook?.uuid == uuid)
            #expect(!app.listeningWritesPositions, "a place was written under one of several tracks")
        }

        /// The server's manifest was kept, and it names several tracks: that
        /// is known, so there is no track for the one file to stand in for,
        /// whatever the stored place looks like.
        @Test("a kept manifest with several tracks lets a stand-in write nothing")
        func standInOverAKeptMultiTrackManifestWritesNothing() async throws {
            let app = Self.unreachableApp()
            let uuid = UUID().uuidString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let book = SharedFixtures.book(
                "Offline", uuid: uuid, progress: 0.5, positionTimestamp: 100,
                positionHref: "/api/books/track-1.mp3", positionType: "audio/mpeg", audiobook: true)
            try BookContentService(client: app.session!.client).saveManifest(
                AudiobookManifest(
                    metadata: .init(title: ["und": "Offline"], duration: 60),
                    readingOrder: [
                        .init(href: "/api/books/track-1.mp3", type: "audio/mpeg", duration: 30),
                        .init(href: "/api/books/track-2.mp3", type: "audio/mpeg", duration: 30),
                    ]),
                for: book)

            let nowPlaying = await Self.listen(app, to: book)
            defer { app.stopListening(nowPlaying: nowPlaying) }

            #expect(app.listeningBook?.uuid == uuid)
            #expect(!app.listeningWritesPositions, "a place was written over a multi-track book")
        }

        /// A multi-track book's manifest is kept too: it is what tells a later
        /// offline start the book is not one track.
        @Test("a refresh keeps the manifest of a downloaded book with several tracks")
        func refreshKeepsAMultiTrackManifest() async throws {
            let server = ScriptedServer.make("manifest-backfill-multi")
            defer { ScriptedServer.forget(server) }
            UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
            let uuid = UUID().uuidString
            ScriptedServer.answer(Endpoint.books, on: server, json: [
                ScriptedServer.book(uuid, title: "Offline"),
            ])
            ScriptedServer.answer(Endpoint.listen(uuid), on: server, json: [
                "metadata": ["title": ["und": "Offline"], "duration": 60],
                "readingOrder": [
                    ["href": "/api/track-1.mp3", "type": "audio/mpeg", "duration": 30],
                    ["href": "/api/track-2.mp3", "type": "audio/mpeg", "duration": 30],
                ],
            ])
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            let session = ScriptedServer.session(on: server, storing: "token-A")
            await session.restore()
            app.session = session
            app.serverAddress = server.absoluteString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let content = BookContentService(client: session.client)
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)

            await app.refreshLibrary()

            #expect(await waitUntil { content.savedManifest(for: book)?.readingOrder.count == 2 },
                    "the multi-track manifest was not kept")
        }

        /// A book the server answers badly about is not a server that cannot
        /// be reached, and the books after it still want their manifests.
        @Test("a book whose manifest the server refuses does not stop the backfill of the next")
        func backfillGoesOnPastABookTheServerRefuses() async throws {
            let server = ScriptedServer.make("manifest-backfill-refused")
            defer { ScriptedServer.forget(server) }
            UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
            let refused = UUID().uuidString
            let wanted = UUID().uuidString
            ScriptedServer.answer(Endpoint.books, on: server, json: [
                ScriptedServer.book(refused, title: "A refused"),
                ScriptedServer.book(wanted, title: "B wanted"),
            ])
            ScriptedServer.answer(Endpoint.listen(refused), on: server, status: 500, json: [:])
            ScriptedServer.answer(Endpoint.listen(wanted), on: server, json: [
                "metadata": ["title": ["und": "B wanted"], "duration": 30],
                "readingOrder": [["href": "/api/track-1.mp3", "type": "audio/mpeg", "duration": 30]],
            ])
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            let session = ScriptedServer.session(on: server, storing: "token-A")
            await session.restore()
            app.session = session
            app.serverAddress = server.absoluteString
            _ = try Self.plantAudiobook(refused)
            _ = try Self.plantAudiobook(wanted)
            defer {
                BookContentService.removeDownload(bookUUID: refused, format: .audiobook)
                BookContentService.removeDownload(bookUUID: wanted, format: .audiobook)
            }
            app.refreshDownloadedSet()
            let content = BookContentService(client: session.client)
            let book = SharedFixtures.book("B wanted", uuid: wanted, audiobook: true)

            await app.refreshLibrary()

            #expect(await waitUntil { content.savedManifest(for: book) != nil },
                    "the refused book ended the pass for the one after it")
        }

        /// A download from before the track list was kept gets it when the
        /// library refresh shows the server is there, not only when Listen is
        /// pressed.
        @Test("a refresh that reaches the server keeps the manifests downloads are missing")
        func refreshBackfillsManifests() async throws {
            let server = ScriptedServer.make("manifest-backfill")
            defer { ScriptedServer.forget(server) }
            UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
            let uuid = UUID().uuidString
            ScriptedServer.answer(Endpoint.books, on: server, json: [
                ScriptedServer.book(uuid, title: "Offline"),
            ])
            ScriptedServer.answer(Endpoint.listen(uuid), on: server, json: [
                "metadata": ["title": ["und": "Offline"], "duration": 30],
                "readingOrder": [["href": "/api/track-1.mp3", "type": "audio/mpeg", "duration": 30]],
            ])
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            let session = ScriptedServer.session(on: server, storing: "token-A")
            await session.restore()
            app.session = session
            app.serverAddress = server.absoluteString
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let content = BookContentService(client: session.client)
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)
            try #require(content.savedManifest(for: book) == nil)

            await app.refreshLibrary()

            #expect(await waitUntil { content.savedManifest(for: book)?.readingOrder.first?.href == "/api/track-1.mp3" },
                    "the refresh did not keep the manifest")
        }

        /// The row has to appear when the button is tapped, not after the
        /// server has answered a request that is only for the track list.
        @Test("a download is queued while the manifest is still being asked for")
        func downloadIsQueuedBeforeTheManifestAnswers() async throws {
            let server = ScriptedServer.make("download-first")
            defer { ScriptedServer.forget(server) }
            let uuid = UUID().uuidString
            let session = ScriptedServer.session(on: server, storing: "token-A")
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            app.session = session
            app.serverAddress = server.absoluteString
            let manager = DownloadManager(
                baseURL: server, tokens: session.tokenProvider,
                identifier: "issa-tests.offline-manifest.\(UUID().uuidString)", fenceStore: nil,
            ) { job in
                FileManager.default.temporaryDirectory.appending(path: "\(job.bookUUID)-\(job.format.rawValue)")
            }
            app.useDownloads(manager)
            app.meteredNetworkOverride = false
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)
            let job = DownloadManager.Job(bookUUID: uuid, format: .audiobook)
            defer { manager.cancel(job) }
            ScriptedServer.hold(Endpoint.listen(uuid), on: server)

            let first = Task { await app.download(book, format: .audiobook) }
            let returned = await waitUntil(within: .seconds(5)) { manager.states[job] != nil }
            #expect(returned, "the download waited for the manifest before it showed")
            let second = Task { await app.download(book, format: .audiobook) }
            await first.value
            await second.value
            #expect(ScriptedServer.held(Endpoint.listen(uuid), on: server) == 1,
                    "a second tap asked for the manifest again")
            ScriptedServer.release(Endpoint.listen(uuid), on: server)
        }

        /// An account that left while the track list was on its way has no
        /// business writing it.
        @Test("a manifest that arrives after the account left is not kept")
        func manifestAfterSignOutIsNotKept() async throws {
            let server = ScriptedServer.make("download-departed")
            defer { ScriptedServer.forget(server) }
            UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
            let uuid = UUID().uuidString
            ScriptedServer.answer(Endpoint.listen(uuid), on: server, json: [
                "metadata": ["title": ["und": "Offline"], "duration": 30],
                "readingOrder": [["href": "/api/track-1.mp3", "type": "audio/mpeg", "duration": 30]],
            ])
            let session = ScriptedServer.session(on: server, storing: "token-A")
            await session.restore()
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            app.session = session
            app.serverAddress = server.absoluteString
            let manager = DownloadManager(
                baseURL: server, tokens: session.tokenProvider,
                identifier: "issa-tests.offline-manifest.\(UUID().uuidString)", fenceStore: nil,
            ) { job in
                FileManager.default.temporaryDirectory.appending(path: "\(job.bookUUID)-\(job.format.rawValue)")
            }
            app.useDownloads(manager)
            app.meteredNetworkOverride = false
            // The file is on the device, so a manifest that was let through
            // would be kept whatever became of the transfer.
            _ = try Self.plantAudiobook(uuid)
            defer { BookContentService.removeDownload(bookUUID: uuid, format: .audiobook) }
            app.refreshDownloadedSet()
            let book = SharedFixtures.book("Offline", uuid: uuid, audiobook: true)
            let job = DownloadManager.Job(bookUUID: uuid, format: .audiobook)
            defer { manager.cancel(job) }
            ScriptedServer.hold(Endpoint.listen(uuid), on: server)
            let content = BookContentService(client: session.client)

            await app.download(book, format: .audiobook)
            try #require(await waitUntil { ScriptedServer.held(Endpoint.listen(uuid), on: server) == 1 })
            await app.adopt(token: "token-B")
            ScriptedServer.release(Endpoint.listen(uuid), on: server)
            try? await Task.sleep(for: .milliseconds(300))

            #expect(content.savedManifest(for: book) == nil, "the departed account's manifest was written")
        }
    }
}

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
    }
}

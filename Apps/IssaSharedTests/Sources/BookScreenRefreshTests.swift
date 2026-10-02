import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The book screen's refresh follows a book restarted on another device.
///
/// `refresh(book:)` runs on every appearance of the book screen, and takes a
/// newer server position even when it is lower — the reader restarted the
/// book somewhere else. It did not re-seed the position guard, which the
/// library refresh does: the guard this process held for that clock kept its
/// old high-water mark, and every derived write from the restarted place —
/// the audiobook's fifteen-second writer, the reader's page turns — was
/// refused and saved nowhere until the reader scrubbed. The library refresh
/// runs only on a pull, a retry or a sign-in, so for days this was the only
/// refresh that saw the restart.
///
/// Through `refresh(book:)` and `writePosition` against `ScriptedServer`, with
/// a real store and queue.
@Suite("The book screen's refresh re-seeds the position guards")
@MainActor
struct BookScreenRefreshTests {
    static let uuid = "33333333-3333-4333-8333-333333333333"

    static func locator(_ progress: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: progress, totalProgression: progress))
    }

    @Test("a lower, newer server position taken by the book screen lets the next derived write through")
    func aRestartElsewhereReseedsTheGuard() async throws {
        let server = ScriptedServer.make("book-screen")
        defer { ScriptedServer.forget(server) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "book-screen-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: server.absoluteString, directory: directory)

        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.useStore(store)
        app.session = ScriptedServer.session(on: server, storing: "token-A")
        let book = SharedFixtures.book(
            "Dracula", uuid: Self.uuid, progress: 0.9, positionTimestamp: 1_000)
        app.books = [book]
        app.rebuildDerived()
        // Read to 0.9 here: the guard for the text clock holds that mark.
        #expect(await app.writePosition(
            Self.locator(0.9), timestamp: 1_000, for: Self.uuid, origin: .chosen))
        let key = AppModel.positionGuardKey(Self.uuid, isAudioScaled: false)
        let before = try #require(app.positionGuards[key]?.highWater)
        try #require(abs(before - 0.9) < 0.0001)

        // Restarted on another device: the server now says 0.02, written later.
        ScriptedServer.answer(Endpoint.book(Self.uuid), on: server, json: ScriptedServer.book(
            Self.uuid, title: "Dracula", progress: 0.02, timestamp: 2_000))
        await app.refresh(book: book)
        let adopted = try #require(app.bookByUUID[Self.uuid]?.progress)
        try #require(abs(adopted - 0.02) < 0.0001, "the refresh has to have taken the restart")

        // Reading on from the restarted place.
        let accepted = await app.writePosition(
            Self.locator(0.03), timestamp: 2_100, for: Self.uuid, origin: .derived)

        #expect(accepted, "the guard still held the old mark and refused the restarted book")
        let progress = app.bookByUUID[Self.uuid]?.progress
        #expect(progress.map { abs($0 - 0.03) < 0.0001 } == true)
        let queued = try await MutationQueue(store: store).pending().filter { $0.kind == .position }
        #expect(queued.isEmpty, "the server takes every write, so an accepted one has been sent")
        #expect(ScriptedServer.requests(to: server).contains {
            $0.method == "POST" && $0.path == Endpoint.positions(Self.uuid)
        })
    }
}

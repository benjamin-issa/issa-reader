import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// A local book's place goes through a guard of the local library's own,
/// with the server writer's rules: a place the reader chose is always taken,
/// a place narration or a layout arrived at is refused when it would walk a
/// good position far backwards.
@Suite("Keeping a local book's place")
@MainActor
struct LocalPositionTests {
    static func locator(_ total: Double, href: String = "OEBPS/ch01.xhtml") -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "application/xhtml+xml",
            locations: .init(progression: total, totalProgression: total))
    }

    static func storedProgress(_ uuid: String, in local: LocalFixtures) async throws -> Double? {
        let store = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: local.storeDirectory)
        return try await store.book(uuid)?.position?.locator.totalProgression
    }

    @Test("a chosen move backwards is taken; a derived one far below the mark is refused")
    func guardRules() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        let library = local.library

        #expect(await library.writePosition(Self.locator(0.8), timestamp: 1, origin: .chosen, for: book.uuid))
        // The reader turning back to the opening is their choice.
        #expect(await library.writePosition(Self.locator(0.3), timestamp: 2, origin: .chosen, for: book.uuid))
        #expect(await library.writePosition(Self.locator(0.9), timestamp: 3, origin: .chosen, for: book.uuid))
        // Narration or a relayout arriving at the front of the book is not.
        #expect(!(await library.writePosition(Self.locator(0.2), timestamp: 4, origin: .derived, for: book.uuid)))

        #expect(library.books.first?.progress == 0.9, "the refused place reached the list")
        #expect(try await Self.storedProgress(book.uuid, in: local) == 0.9, "and the store")
        // A derived move forward is ordinary reading.
        #expect(await library.writePosition(Self.locator(0.92), timestamp: 5, origin: .derived, for: book.uuid))
    }

    /// The mark is seeded from the stored place, so a relaunch is not a window
    /// in which a derived write can walk the reader back.
    @Test("after a relaunch the guard starts from the stored place")
    func seededAfterRelaunch() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        #expect(await local.library.writePosition(Self.locator(0.9), timestamp: 1, origin: .chosen, for: book.uuid))

        let relaunched = local.relaunched()
        await relaunched.load()
        #expect(relaunched.books.first?.progress == 0.9)

        #expect(!(await relaunched.writePosition(Self.locator(0.1), timestamp: 2, origin: .derived, for: book.uuid)))
        #expect(try await Self.storedProgress(book.uuid, in: local) == 0.9)
        #expect(await relaunched.storedPosition(for: book.uuid)?.locator.totalProgression == 0.9)
    }

    @Test("a place older than the one held is not adopted")
    func olderWriteIsNotAdopted() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        #expect(await local.library.writePosition(Self.locator(0.5), timestamp: 20, origin: .chosen, for: book.uuid))
        _ = await local.library.writePosition(Self.locator(0.6), timestamp: 10, origin: .chosen, for: book.uuid)
        #expect(local.library.books.first?.position?.timestamp == 20)
    }
}

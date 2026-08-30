import Foundation
import Testing

@testable import IssaCore

@Suite("Marks a reader makes")
struct AnnotationTests {
    func locator(_ href: String, progression: Double, offset: Int) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "application/xhtml+xml",
            locations: .init(progression: progression, totalProgression: progression, charOffset: offset),
        )
    }

    /// A marks list is read like a table of contents, so it has to be in
    /// reading order rather than the order the marks happened to be made.
    @Test("marks sort into reading order, not creation order")
    func sorting() {
        let late = Annotation(
            bookUUID: "b", kind: .highlight,
            locator: locator("ch09.xhtml", progression: 0.9, offset: 10), excerpt: "later")
        let early = Annotation(
            bookUUID: "b", kind: .bookmark,
            locator: locator("ch01.xhtml", progression: 0.1, offset: 10), excerpt: "earlier")
        let sameChapter = Annotation(
            bookUUID: "b", kind: .highlight,
            locator: locator("ch01.xhtml", progression: 0.1, offset: 400), excerpt: "further in")

        let sorted = [late, sameChapter, early].sorted(by: Annotation.readingOrder)
        #expect(sorted.map(\.excerpt) == ["earlier", "further in", "later"])
    }

    @Test("a mark round-trips through JSON with its locator intact")
    func codable() throws {
        let annotation = Annotation(
            bookUUID: "b", kind: .highlight, tint: .plum,
            locator: locator("ch02.xhtml", progression: 0.5, offset: 120),
            excerpt: "second star to the right", note: "remember this",
            chapterTitle: "Chapter Two")
        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == annotation)
        #expect(decoded.locator.locations?.charOffset == 120)
        #expect(decoded.tint == .plum)
    }

    @Test("stored marks survive a round trip through the database")
    func persistence() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LibraryStore(serverKey: "test", directory: directory)
        let mark = Annotation(
            bookUUID: "book-1", kind: .highlight,
            locator: locator("ch01.xhtml", progression: 0.25, offset: 42), excerpt: "a phrase")
        try await store.save(mark)

        var found = try await store.annotations(for: "book-1")
        #expect(found.count == 1)
        #expect(found.first?.excerpt == "a phrase")
        // Another book's marks must not leak into this one's list.
        #expect(try await store.annotations(for: "book-2").isEmpty)

        // Saving the same id again edits rather than duplicating.
        var edited = mark
        edited.note = "with a note"
        try await store.save(edited)
        found = try await store.annotations(for: "book-1")
        #expect(found.count == 1)
        #expect(found.first?.note == "with a note")

        try await store.deleteAnnotation(id: mark.id)
        #expect(try await store.annotations(for: "book-1").isEmpty)
    }
}

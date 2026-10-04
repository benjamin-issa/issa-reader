import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The line under a Spotlight result.
///
/// The server's blurb is HTML — the 3.x fixture's is
/// `<p>It is a truth <i>universally acknowledged</i>…` — and Spotlight shows a
/// description verbatim, so a result read out its own markup.
@Suite("Spotlight's description of a book")
struct SpotlightDescriptionTests {
    private static func book(description: String?, authors: [String] = ["Jane Austen"]) throws -> Book {
        var json: [String: Any] = [
            "uuid": "pride", "title": "Pride and Prejudice",
            "authors": authors.map { ["uuid": $0, "name": $0] },
            "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        if let description { json["description"] = description }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Book.self, from: data)
    }

    @Test("markup and entities are gone, the words are kept")
    func stripsHTML() throws {
        let book = try Self.book(description:
            "<p>It is a truth <i>universally acknowledged</i> &amp; an <b>unclosed bold tag</p>")
        let text = SpotlightIndex.contentDescription(for: book)
        #expect(!text.contains("<"), "\(text)")
        #expect(!text.contains("&amp;"), "\(text)")
        #expect(text.contains("It is a truth universally acknowledged & an unclosed bold tag"), "\(text)")
        #expect(text.hasPrefix("Jane Austen\n"), "the byline still leads: \(text)")
    }

    @Test("a book with no blurb is described by its byline alone")
    func bylineOnly() throws {
        #expect(SpotlightIndex.contentDescription(for: try Self.book(description: nil)) == "Jane Austen")
        #expect(SpotlightIndex.contentDescription(for: try Self.book(description: "<p> </p>")) == "Jane Austen")
    }
}

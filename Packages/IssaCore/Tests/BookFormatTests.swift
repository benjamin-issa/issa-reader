import Foundation
import Testing

@testable import IssaCore

/// What the app is willing to promise about a book, and which file it opens.
///
/// Both questions used to be answered without consulting `missing`, which is
/// how an audiobook-only book came to offer "Read" — pushing the reader into a
/// spinner and a dead end — and how a book the server had lost still started a
/// download that 404'd.
@Suite("What a book can actually serve")
struct BookFormatTests {
    /// Built by decoding, like everything else here: `Book` has no public
    /// initialiser, and inventing one for tests would be a second definition of
    /// what a book is.
    private func book(
        ebook: (missing: Bool?, Void)? = nil,
        readaloud: (filepath: String?, aligned: Bool, missing: Bool?)? = nil,
        audiobook: (filepath: String?, missing: Bool?)? = nil,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": "u", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
        ]
        if let ebook {
            var edition: [String: Any] = ["uuid": "e", "identifiers": []]
            if let missing = ebook.missing { edition["missing"] = missing }
            json["ebook"] = edition
        }
        if let readaloud {
            var edition: [String: Any] = [
                "uuid": "r", "identifiers": [],
                "status": readaloud.aligned ? "ALIGNED" : "PROCESSING",
            ]
            if let path = readaloud.filepath { edition["filepath"] = path }
            if let missing = readaloud.missing { edition["missing"] = missing }
            json["readaloud"] = edition
        }
        if let audiobook {
            var edition: [String: Any] = ["uuid": "a", "identifiers": []]
            if let path = audiobook.filepath { edition["filepath"] = path }
            if let missing = audiobook.missing { edition["missing"] = missing }
            json["audiobook"] = edition
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    // MARK: - Which file the reader opens

    /// The dead-end bug: the reader offered "Read" on a book with nothing to
    /// read, pushed a screen, and failed there.
    @Test("an audiobook-only book has nothing to read")
    func audiobookOnlyHasNoReadingFormat() {
        let subject = book(audiobook: (filepath: "a.m4b", missing: nil))
        #expect(BookContentService.preferredReadingFormat(for: subject) == nil)
    }

    /// `isReadable` gates whether a "resume reading" request opens the reader or
    /// the detail screen, and the Continue card's VoiceOver hint. It must agree
    /// with "has an ebook or a readaloud that is actually servable".
    @Test("only a book with text is readable")
    func isReadableTracksServableText() {
        #expect(!book(audiobook: (filepath: "a.m4b", missing: nil)).isReadable)
        #expect(book(ebook: (missing: nil, ())).isReadable)
        #expect(book(readaloud: (filepath: "r.epub", aligned: false, missing: nil)).isReadable)
        #expect(!book(ebook: (missing: true, ()),
                      audiobook: (filepath: "a.m4b", missing: nil)).isReadable)
    }

    /// The 404 bug: `missing` was never consulted, so the download started and
    /// the server answered 404 halfway through.
    @Test("an ebook the server has lost is not offered")
    func missingEbookIsNotAReadingFormat() {
        let subject = book(ebook: (missing: true, ()))
        #expect(BookContentService.preferredReadingFormat(for: subject) == nil)
    }

    @Test("a missing readaloud falls back to the healthy ebook")
    func missingReadaloudFallsBackToEbook() {
        let subject = book(
            ebook: (missing: nil, ()),
            readaloud: (filepath: "r.epub", aligned: true, missing: true))
        #expect(BookContentService.preferredReadingFormat(for: subject) == .ebook)
    }

    @Test("an aligned readaloud still wins over a plain ebook")
    func alignedReadaloudIsPreferred() {
        let subject = book(
            ebook: (missing: nil, ()),
            readaloud: (filepath: "r.epub", aligned: true, missing: nil))
        #expect(BookContentService.preferredReadingFormat(for: subject) == .readaloud)
    }

    @Test("an unaligned readaloud is still readable when it is all there is")
    func unalignedReadaloudIsTheLastResort() {
        let subject = book(readaloud: (filepath: "r.epub", aligned: false, missing: nil))
        #expect(BookContentService.preferredReadingFormat(for: subject) == .readaloud)
    }

    /// Every call site compares `== true`, so an absent flag means present.
    @Test("an absent missing flag means the edition is there")
    func absentMissingMeansPresent() {
        let subject = book(ebook: (missing: nil, ()))
        #expect(BookContentService.preferredReadingFormat(for: subject) == .ebook)
    }

    // MARK: - What the library grid promises

    /// The server creates a readaloud row when alignment is *requested*, so
    /// `availableFormats` claims narration for a book with no file behind it.
    @Test("a readaloud with no file is not servable, however aligned it says it is")
    func readaloudWithoutFileIsNotServable() {
        let subject = book(readaloud: (filepath: nil, aligned: true, missing: nil))
        #expect(subject.availableFormats.contains(.readaloud))  // the row exists
        #expect(!subject.servableFormats.contains(.readaloud))  // the file does not
    }

    @Test("an audiobook marked missing is not servable")
    func missingAudiobookIsNotServable() {
        let subject = book(audiobook: (filepath: "a.m4b", missing: true))
        #expect(!subject.servableFormats.contains(.audiobook))
    }

    @Test("a plain ebook is servable")
    func plainEbookIsServable() {
        #expect(book(ebook: (missing: nil, ())).servableFormats == [.ebook])
    }
}

/// Reading the download directory instead of asking about each book in turn.
@Suite("Naming downloaded files")
struct DownloadFilenameTests {
    /// A canonical uuid — which is the only shape the catalogue now admits,
    /// since `LibraryService.refusingUnsafeIdentifiers` drops anything else
    /// before it reaches a shelf. This used to read "abc-123", a convenient
    /// short string no Storyteller server sends.
    private static let uuid = "0198ab12-cd34-4e56-8f90-123456789abc"

    private func service() -> BookContentService {
        let directory = URL(fileURLWithPath: "/tmp/does-not-matter")
        return BookContentService(
            client: APIClient(baseURL: directory, tokens: NoTokens()), cacheDirectory: directory)
    }

    private func book(uuid: String) -> Book {
        let json = Data(#"{"uuid":"\#(uuid)","title":"T","authors":[],"narrators":[],"creators":[],"series":[],"collections":[],"identifiers":[],"tags":[]}"#.utf8)
        return try! JSONDecoder().decode(Book.self, from: json)
    }

    @Test("a filename round-trips to its book for every format")
    func roundTripsEveryFormat() {
        let subject = book(uuid: Self.uuid)
        for format in BookContentService.Format.allCases {
            let name = service().localURL(for: subject, format: format).lastPathComponent
            #expect(BookContentService.bookUUID(fromFilename: name) == Self.uuid)
        }
    }

    /// The trade this makes, stated rather than discovered later.
    ///
    /// A uuid that could escape the directory is hashed instead of used, so its
    /// filename no longer round-trips and the book reads as not-downloaded.
    /// That costs one redundant download in a case the catalogue boundary
    /// already refuses to create — and the alternative was letting the server
    /// choose the path.
    @Test("a uuid that could escape the directory is contained, not round-tripped")
    func hostileIdentifiersAreContained() {
        let hostile = book(uuid: "../../Library/Preferences/x")
        let url = service().localURL(for: hostile, format: .ebook)
        #expect(url.lastPathComponent.hasPrefix("unsafe-"))
        #expect(!url.path.contains(".."), "the written path must stay inside Books")
        #expect(BookContentService.bookUUID(fromFilename: url.lastPathComponent) != "../../Library/Preferences/x")
    }

    @Test("anything that is not one of ours is ignored")
    func rejectsStrays() {
        #expect(BookContentService.bookUUID(fromFilename: "garbage") == nil)
        #expect(BookContentService.bookUUID(fromFilename: "uuid.epub") == nil)
        #expect(BookContentService.bookUUID(fromFilename: "uuid-nonsense.epub") == nil)
        #expect(BookContentService.bookUUID(fromFilename: "-ebook.epub") == nil)
    }

    @Test("one book with several formats on disk counts once")
    func oneEntryPerBookRegardlessOfFormats() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["one-ebook.epub", "one-readaloud.epub", "two-audiobook.epub", "notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }
        #expect(BookContentService.downloadedBookUUIDs(in: directory) == ["one", "two"])
    }
}

private struct NoTokens: TokenProviding {
    func currentToken() async -> String? { nil }
    func invalidate() async {}
}

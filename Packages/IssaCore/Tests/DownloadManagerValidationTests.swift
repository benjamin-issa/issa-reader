import Foundation
import Testing

@testable import IssaCore

private struct ValidationTokens: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}

/// A 200 is not a book.
///
/// A finished transfer was judged by its status code alone, so whatever came
/// back with a 200 — a proxy's sign-in page once its session lapsed, a
/// captive portal — was moved into place as the book. It then counted as
/// downloaded everywhere, opened to "Couldn't open this book" every time, and
/// nothing ever removed it.
@Suite("A finished download that is not the book")
@MainActor
struct DownloadValidationTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "issa-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func manager(books: URL) -> DownloadManager {
        DownloadManager(
            baseURL: unreachableServer,
            tokens: ValidationTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { job in
                BookContentService.localURL(in: books, bookUUID: job.bookUUID, format: job.format)
            },
        )
    }

    /// Runs the finished-download callback for a transfer the server answered
    /// this way, and returns where the book would have landed.
    private func finish(
        _ answer: DownloadStubProtocol.Answer, as format: BookContentService.Format,
        on subject: DownloadManager, root: URL, books: URL,
    ) async throws -> URL {
        let job = DownloadManager.Job(bookUUID: "b", format: format)
        let task = await DownloadStubProtocol.finishedTask(answer)
        task.taskDescription = subject.liveTaskDescription(for: job)
        let arrived = try DownloadStubProtocol.arrivedFile(answer, in: root)
        subject.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: arrived)
        await settle { subject.state(for: job) != nil }
        return BookContentService.localURL(in: books, bookUUID: "b", format: format)
    }

    @Test(
        "a page or an error body answered with 200 is not moved into place as the book",
        arguments: [
            (DownloadStubProtocol.Answer.html, BookContentService.Format.readaloud),
            (.html, .ebook), (.json, .ebook), (.html, .audiobook), (.json, .audiobook),
        ])
    func aPageIsNotTheBook(answer: DownloadStubProtocol.Answer, format: BookContentService.Format) async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = manager(books: books)
        var finished: [DownloadManager.Job] = []
        subject.onFinished = { finished.append($0) }

        let destination = try await finish(answer, as: format, on: subject, root: root, books: books)

        let job = DownloadManager.Job(bookUUID: "b", format: format)
        #expect(subject.state(for: job)?.isFailure == true, "a page was taken for the book")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(finished.isEmpty, "onFinished would have put it on the shelf as downloaded")
        await subject.shutDown()
    }

    /// The plan's own case, straight through the extracted step: a sign-in
    /// page with a 200 and `text/html`, for a read-along.
    @Test("finishing a read-along whose body is a page fails it and moves nothing")
    func finishingWithAPageFails() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = manager(books: books)
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        let arrived = try DownloadStubProtocol.arrivedFile(.html, in: root)
        let response = HTTPURLResponse(
            url: unreachableServer, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"])

        subject.finishDownload(job: job, location: arrived, response: response)
        await settle { subject.state(for: job) != nil }

        #expect(subject.state(for: job)?.isFailure == true)
        #expect(!FileManager.default.fileExists(
            atPath: BookContentService.localURL(in: books, bookUUID: "b", format: .readaloud).path))
        await subject.shutDown()
    }

    /// Unchanged: a status outside 2xx is reported as itself.
    @Test("a refused status is still reported as the status")
    func aRefusedStatusSaysSo() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = manager(books: root.appending(path: "Books", directoryHint: .isDirectory))
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        let arrived = try DownloadStubProtocol.arrivedFile(.epub, in: root)
        let response = HTTPURLResponse(
            url: unreachableServer, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)

        subject.finishDownload(job: job, location: arrived, response: response)
        await settle { subject.state(for: job) != nil }

        #expect(subject.state(for: job) == .failed("The server returned 404."))
        await subject.shutDown()
    }

    /// The other side: a real book still lands, whatever its edition — and an
    /// audiobook is not held to being a zip, because nothing here knows what
    /// container the server keeps its audio in.
    @Test(
        "the book itself still lands",
        arguments: [
            (DownloadStubProtocol.Answer.epub, BookContentService.Format.readaloud),
            (.epub, .ebook), (.audio, .audiobook), (.epub, .audiobook),
        ])
    func theBookStillLands(answer: DownloadStubProtocol.Answer, format: BookContentService.Format) async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = manager(books: books)

        let destination = try await finish(answer, as: format, on: subject, root: root, books: books)

        #expect(subject.state(for: DownloadManager.Job(bookUUID: "b", format: format)) == .finished)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        await subject.shutDown()
    }
}

/// What decides, on its own: only what is true of every server.
@Suite("Telling a book from what came in its place")
struct DownloadedFileValidationTests {
    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issa-validate-\(UUID().uuidString).tmp")
        try bytes.write(to: url)
        return url
    }

    /// An EPUB is a zip, whatever type a server or a proxy labels it with.
    @Test(
        "an EPUB edition is kept only when it begins as a zip",
        arguments: [BookContentService.Format.ebook, .readaloud])
    func epubsAreZips(format: BookContentService.Format) throws {
        let zip = try file(DownloadStubProtocol.zipHead)
        let page = try file(DownloadStubProtocol.page)
        let empty = try file(Data())
        defer { for url in [zip, page, empty] { try? FileManager.default.removeItem(at: url) } }

        for type in ["application/epub+zip", "application/octet-stream", "text/html", nil] as [String?] {
            #expect(BookContentService.validateDownloadedFile(at: zip, format: format, mimeType: type) == nil)
            #expect(BookContentService.validateDownloadedFile(at: page, format: format, mimeType: type) != nil)
        }
        #expect(BookContentService.validateDownloadedFile(at: empty, format: format, mimeType: nil) != nil)
        #expect(BookContentService.validateDownloadedFile(
            at: page.appending(path: "absent"), format: format, mimeType: nil) != nil)
    }

    /// Nothing is assumed about an audiobook's container; only a page or an
    /// API's JSON is never audio.
    @Test("an audiobook is refused only as a page or JSON")
    func audiobooksAreJudgedByTheirType() throws {
        let audio = try file(DownloadStubProtocol.Answer.audio.body)
        defer { try? FileManager.default.removeItem(at: audio) }

        for type in ["audio/mp4", "audio/mpeg", "application/zip", "application/octet-stream", nil] as [String?] {
            #expect(BookContentService.validateDownloadedFile(at: audio, format: .audiobook, mimeType: type) == nil)
        }
        for type in ["text/html", "TEXT/HTML", "application/json"] {
            #expect(BookContentService.validateDownloadedFile(at: audio, format: .audiobook, mimeType: type) != nil)
        }
    }
}

/// The reader's own fetch, for a book opened with no download manager to wait
/// on, takes the same care: it moves the file into place before it can look at
/// it, so a page that arrived there is deleted again rather than kept.
@Suite("Fetching a book to open it")
struct EnsureDownloadedValidationTests {
    private func book() throws -> Book {
        let json: [String: Any] = [
            "uuid": "0198f1c2-6f5a-7000-8000-abcdef012345", "title": "Dracula",
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
            "readaloud": ["uuid": "r", "filepath": "r.epub", "identifiers": []],
        ]
        return try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func content(answering answer: DownloadStubProtocol.Answer, in directory: URL) -> BookContentService {
        let client = APIClient(
            baseURL: DownloadStubProtocol.base(answer), tokens: ValidationTokens(),
            session: DownloadStubProtocol.session())
        return BookContentService(client: client, cacheDirectory: directory)
    }

    @Test("a page answered with 200 is deleted, and the open fails saying why")
    func aPageIsDeletedAndRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-ensure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = try book()
        let content = content(answering: .html, in: directory)

        await #expect(throws: StorytellerError.self) {
            try await content.ensureDownloaded(book, format: .readaloud)
        }
        #expect(!content.isDownloaded(book, format: .readaloud),
                "kept, it is opened and refused again on every launch")
    }

    @Test("the book itself is kept")
    func theBookIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-ensure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = try book()
        let content = content(answering: .epub, in: directory)

        let url = try await content.ensureDownloaded(book, format: .readaloud)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

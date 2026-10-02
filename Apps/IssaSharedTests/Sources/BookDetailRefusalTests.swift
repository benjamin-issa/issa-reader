import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The book screen says why "Save for offline" did nothing.
///
/// The Wi-Fi-only rule refuses a download before any transfer exists, so the
/// status beside the edition never moved and the tap looked ignored. The model
/// now holds the refusal against the job (`DownloadRefusalTests`); this is the
/// book screen reading it back for the edition that was asked for, through the
/// same refused `download` the menu makes, on `DownloadRefusalTests`' fixture.
@Suite("The book screen and a refused download", .serialized)
@MainActor
struct BookDetailRefusalTests {
    @Test("the refused edition shows the reason, and only that edition")
    func refusalIsShownAgainstItsEdition() async throws {
        let fixture = DownloadRefusalTests.fixture()
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[DownloadRefusalTests.uuid])

        #expect(BookDetailView.refusal(for: book, format: .readaloud, in: app.downloadRefusals) == nil)
        let started = await app.download(book, format: .readaloud)
        try #require(!started)

        #expect(BookDetailView.refusal(for: book, format: .readaloud, in: app.downloadRefusals)
            == DownloadRefusalTests.expectedReason)
        #expect(BookDetailView.refusal(for: book, format: .ebook, in: app.downloadRefusals) == nil,
                "another edition was not refused")
    }
}

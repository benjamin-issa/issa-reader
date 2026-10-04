import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The Mac Downloads list's rows: which item a right-click, a double-click or
/// ⌫ is about.
@Suite("The Mac's Downloads rows")
@MainActor
struct DownloadsRowCommandsTests {
    private static func item(_ title: String, _ format: BookContentService.Format = .readaloud)
        -> DownloadsInventory.DownloadedItem {
        DownloadsInventory.DownloadedItem(
            book: SharedFixtures.book(title, uuid: title.lowercased()), format: format, bytes: 1)
    }

    @Test("a row's menu and ⌫ act on the row named, not the first")
    func downloadsRowTarget() {
        let items = [Self.item("Dracula"), Self.item("Emma"), Self.item("Emma", .ebook)]
        #expect(DownloadsRowCommands.target(of: [items[1].id], in: items) == items[1])
        #expect(DownloadsRowCommands.target(of: [items[2].id], in: items) == items[2],
                "two editions of one book are two rows")
        #expect(DownloadsRowCommands.target(of: [], in: items) == nil)
        #expect(DownloadsRowCommands.target(of: [items[0].id, items[1].id], in: items) == nil)
        #expect(DownloadsRowCommands.target(of: ["gone-readaloud"], in: items) == nil,
                "a row removed under the menu is no row")
    }
}

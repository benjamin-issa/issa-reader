import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// What the storage screen scans for, during a removal's undo window.
///
/// `downloadedUUIDs` already leaves out the book being removed, so the rest of
/// the app stops offering it. Its file is still on disk, and the scan files
/// whatever no book claims under "No longer in your library": for six seconds
/// the bar drew the book just swiped away as an alert-red band.
@Suite("The storage screen during an undo window")
@MainActor
struct DownloadsOnDiskTests {
    @Test("the book being removed is still scanned as the library's")
    func pendingBookIsScanned() {
        let pending = AppModel.PendingRemoval(bookUUID: "dracula", format: .ebook, title: "Dracula")
        #expect(DownloadsView.onDisk(["carmilla"], pending: pending) == ["carmilla", "dracula"])
    }

    @Test("with nothing pending the app's own set is scanned unchanged")
    func nothingPending() {
        #expect(DownloadsView.onDisk(["carmilla"], pending: nil) == ["carmilla"])
    }
}

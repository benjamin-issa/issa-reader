import Foundation
import Testing

@testable import IssaReader_iOS

/// Text copied from a book is the reader's to keep; only a secret expires.
@Suite("What a copy tells the pasteboard")
struct ClipboardLifetimeTests {
    #if os(iOS)
    @Test("a copy with no lifetime does not expire, and stays on this device")
    func keptByDefault() {
        let options = Clipboard.pasteboardOptions(lifetime: nil)
        #expect(options[.expirationDate] == nil)
        #expect(options[.localOnly] as? Bool == true)
    }

    @Test("a sensitive copy expires after the sensitive lifetime")
    func sensitiveExpires() throws {
        let now = Date()
        let options = Clipboard.pasteboardOptions(lifetime: Clipboard.sensitiveLifetime, now: now)
        let expires = try #require(options[.expirationDate] as? Date)
        #expect(expires == now.addingTimeInterval(2 * 60))
    }
    #endif
}

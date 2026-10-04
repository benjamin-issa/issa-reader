import Foundation
import Testing

@testable import IssaCore

/// What a status is called on screen and to VoiceOver.
///
/// 3.x puts an admin's wording in `label` and nothing stops it being blank:
/// the admin dialog accepts a label of spaces, and the API accepts `""`. Shown
/// as sent, either one is a status pill with nothing in it, a menu entry with
/// no words, and an accessibility value that reads as silence — for a status
/// whose name is sitting right there.
@Suite("What a status is called")
struct StatusDisplayNameTests {
    /// Decoded, as the server sends it: the label is whatever the admin typed.
    private func status(label: String?) throws -> Status {
        var json: [String: Any] = ["uuid": "s-read", "name": Status.readName]
        if let label { json["label"] = label }
        return try JSONDecoder().decode(
            Status.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("an empty label falls back to the name")
    func emptyLabel() throws {
        #expect(try status(label: "").displayName == Status.readName)
    }

    @Test("a label of nothing but whitespace falls back to the name")
    func whitespaceLabel() throws {
        #expect(try status(label: " ").displayName == Status.readName)
        #expect(try status(label: " \n\t ").displayName == Status.readName)
    }

    /// Only a label with nothing to read is replaced. One with words in it is
    /// the server's, padding and all: tidying it is the admin's call, and a
    /// fallback that trimmed would be a second rule nobody asked for.
    @Test("a label with words in it is kept as sent")
    func paddedLabelIsKept() throws {
        #expect(try status(label: " Finished ").displayName == " Finished ")
        #expect(try status(label: "Finished").displayName == "Finished")
    }

    @Test("no label at all is the name, as on 2.x")
    func noLabel() throws {
        #expect(try status(label: nil).displayName == Status.readName)
    }
}

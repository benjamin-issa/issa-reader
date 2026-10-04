import Foundation
import Testing

@testable import IssaReader_iOS

/// The "Not encrypted" line under the server field.
///
/// It was worked out from the live session or the stored server, never from
/// the field, so while a new address was typed it described the previous one:
/// silent for a fresh `http://` address, red under an `https://` one typed over
/// a stored LAN server. The view now asks this of what is in the field; the
/// stored server's value is beside the point, which is why none is passed.
@Suite("The sign-in form's cleartext warning")
@MainActor
struct SignInCleartextTests {
    @Test("an http address is warned about, an https one is not")
    func followsTheField() {
        #expect(SignInView.isCleartext(typed: "http://192.168.1.10:8001"))
        #expect(!SignInView.isCleartext(typed: "https://books.example.com"))
        #expect(!SignInView.isCleartext(typed: "  HTTPS://books.example.com/storyteller  "))
    }

    @Test("a bare address is what normalising makes of it: plain HTTP on Storyteller's port")
    func bareAddress() {
        #expect(SignInView.isCleartext(typed: "192.168.1.10:8001"))
    }

    @Test("an empty or unreadable field says nothing")
    func emptyField() {
        #expect(!SignInView.isCleartext(typed: ""))
        #expect(!SignInView.isCleartext(typed: "   "))
    }
}

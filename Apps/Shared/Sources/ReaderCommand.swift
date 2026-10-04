import Foundation
import Observation

/// A menu command aimed at whichever reader window is frontmost.
///
/// Posted rather than called: on the Mac several books can be open at once, and
/// a menu item has no idea which one the reader means. Each reader window
/// listens only while it is the active scene, so the frontmost book answers and
/// the others ignore it.
enum ReaderCommand: String, Sendable {
    case find
    case contents
    case marks
    case bookmark
    case nextPage
    case previousPage
    /// Type size, face and theme for this book.
    case typography
    /// The full player — the scrubber, the rate and the sleep timer. The phone
    /// swipes up on the footer strip to reach it; the Mac has no swipe, so the
    /// menu is its route.
    case player
    /// This book's level, one step at a time. Aimed like the rest: only the key
    /// window answers, so ⌘⌥↑ in the Now Playing panel and ⌘⌥↑ in a reader
    /// window both trim the book that window is about.
    case volumeUp
    case volumeDown
    /// A question about the book in front. Aimed for the same reason the level
    /// is: the answer is bounded by one book's reading position, and the menu
    /// has no idea which book the reader means.
    case ask
    /// Playback › Play with no player yet: the narrated book in front starts
    /// its narration, as its page's play button would (`KeyReaderNarration`).
    case playPause

    var notification: Notification.Name { Notification.Name("issa.reader.\(rawValue)") }

    func post() {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// Which reader window is in front with narration to play, for Playback ›
/// Play.
///
/// The menu item acted on `NowPlayingController.coordinator`, which exists only
/// once narration has been started — so in a narrated book's window, before
/// the first press of the page's play button, Play was greyed out (F10). The
/// key reader says here that it can answer, and the menu asks it to.
@MainActor
@Observable
final class KeyReaderNarration {
    static let shared = KeyReaderNarration()

    /// The reader window that is key and narrated, by a token of its own.
    private(set) var owner: UUID?

    var narratedReaderIsKey: Bool { owner != nil }

    /// A reader window's state: whether it is key, and whether its book has
    /// narration. Windows report in any order — the one losing the key can
    /// speak after the one gaining it — so one only ever clears itself.
    func update(token: UUID, isKey: Bool, isNarrated: Bool) {
        if isKey, isNarrated {
            owner = token
        } else if owner == token {
            owner = nil
        }
    }

    /// The window has closed.
    func left(_ token: UUID) {
        if owner == token { owner = nil }
    }

    /// Play is offered with a player to toggle, or a narrated reader in front
    /// to start.
    static func playEnabled(hasCoordinator: Bool, narratedReaderIsKey: Bool) -> Bool {
        hasCoordinator || narratedReaderIsKey
    }
}

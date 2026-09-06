import Foundation

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

    var notification: Notification.Name { Notification.Name("issa.reader.\(rawValue)") }

    func post() {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

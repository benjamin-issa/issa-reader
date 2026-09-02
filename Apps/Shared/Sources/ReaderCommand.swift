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
    /// The full player — the scrubber, the rate and the sleep timer. The phone
    /// swipes up on the footer strip to reach it; the Mac has no swipe, so the
    /// menu is its route.
    case player

    var notification: Notification.Name { Notification.Name("issa.reader.\(rawValue)") }

    func post() {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

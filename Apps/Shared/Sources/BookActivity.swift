import Foundation
import IssaCore
#if canImport(UIKit)
import UIKit
#endif

/// The Handoff activity: reading a book on one device, continuing on another.
///
/// Only the book and the position travel. The devices may hold different
/// downloads and different fonts, and the locator is designed to survive
/// exactly that.
enum BookActivity {
    static let type = "com.benjaminissa.issareader.reading"
    static let bookIDKey = "bookID"
    static let progressKey = "progress"

    static func make(book: Book, progress: Double?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.title = book.title
        activity.userInfo = [
            bookIDKey: book.uuid,
            progressKey: progress ?? book.progress ?? 0,
        ]
        activity.requiredUserInfoKeys = [bookIDKey]
        activity.isEligibleForHandoff = true
        // Not eligible for search or prediction: CoreSpotlight already indexes
        // the library properly, and a duplicate entry per book read is noise.
        activity.isEligibleForSearch = false
        activity.webpageURL = nil
        return activity
    }
}

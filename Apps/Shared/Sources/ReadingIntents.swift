import AppIntents
import Foundation
import IssaCore
import Observation

// iOS only, though this file compiles into all three app targets. On macOS the
// sandbox has no App Group entitlement, so `CurrentBookSnapshotStore.read()`
// is always nil and the intent told a mid-book reader "You haven't started a
// book yet"; tvOS is the same, and neither platform's scene consumes
// `AppIntentInbox` anyway. Advertising a shortcut that can never succeed is
// worse than not having one, so the whole feature is compiled out until those
// platforms can honour it.
#if os(iOS)

/// "Hey Siri, continue my book."
///
/// One intent, doing the thing a listener actually asks for. Resuming needs no
/// parameters and no disambiguation, which is what makes it usable hands-free —
/// the case this exists for.
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription(
        "Opens the book you were last reading, at the place you left off.")
    /// Opens the app: reading is not something that can happen in the
    /// background, and pretending otherwise would just fail silently.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let snapshot = CurrentBookSnapshotStore.read() else {
            throw ContinueReadingError.nothingInProgress
        }
        AppIntentInbox.shared.bookID = snapshot.bookID
        return .result()
    }
}

enum ContinueReadingError: Error, CustomLocalizedStringResourceConvertible {
    case nothingInProgress

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingInProgress: "You haven't started a book yet."
        }
    }
}

/// Where an intent leaves its request for the app to collect.
///
/// An intent runs before — or entirely outside — the SwiftUI scene, so it
/// cannot navigate. It leaves the book here and the root view picks it up the
/// same way it picks up a widget tap.
///
/// Observable, so the library collects a request the moment it is written
/// rather than at the next time the scene becomes active. It used to be
/// collected only there, and a cold launch from Siri reaches `.active` before
/// the library exists — or `perform()` runs after it — so the request sat
/// here until the reader next left the app and came back, when the book
/// opened unasked.
@Observable
@MainActor
final class AppIntentInbox {
    static let shared = AppIntentInbox()
    var bookID: String?
    /// Internal rather than private so a test can have an inbox of its own.
    init() {}

    /// Hands the waiting request to the app, once, and empties the inbox.
    ///
    /// Through `requestBook`, which waits for the catalogue: a request made
    /// before the library has loaded opens the book when it arrives.
    func deliver(to app: AppModel) {
        guard let id = bookID else { return }
        bookID = nil
        // "Continue reading" means exactly that.
        app.requestBook(id, .read)
    }
}

struct IssaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueReadingIntent(),
            phrases: [
                "Continue reading in \(.applicationName)",
                "Continue my book in \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book",
        )
    }
}

#endif

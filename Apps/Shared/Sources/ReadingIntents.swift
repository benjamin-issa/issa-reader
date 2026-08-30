import AppIntents
import Foundation
import IssaCore

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
@MainActor
final class AppIntentInbox {
    static let shared = AppIntentInbox()
    var bookID: String?
    private init() {}
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

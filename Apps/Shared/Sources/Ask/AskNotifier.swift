#if !os(tvOS)
import Foundation
import IssaCore
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Telling a reader their answer is ready, when they are not looking at it.
///
/// The body is the **book**, and neither the question nor the answer. A
/// notification lands on a lock screen that gets handed round, glanced at
/// across a table, or mirrored onto a watch, so the answer was never a
/// candidate: this feature's whole promise is that nothing from further into
/// the book reaches the reader before they do.
///
/// The question used to be the body, on the argument that it is theirs already.
/// That argument was right about who owns it and wrong about where it goes.
/// PRIVACY.md promises "your questions and the answers are never written down:
/// they exist while the sheet is open and are gone when you close it" — and
/// `UNUserNotificationCenter` persists delivered content to disk, where it
/// outlives the sheet, the answer, and the app being killed. Nothing removed
/// it. So the question is out of the body, and `removeDelivered` takes back
/// what has already been delivered when the reader reopens the answer and when
/// the account's data is purged.
///
/// `threadIdentifier` still separates books, so two answers waiting at once
/// still read as two conversations rather than one pile — which is most of what
/// the question was doing there.
struct AskNotifier: Sendable {
    private let centre: @Sendable () -> UNUserNotificationCenter

    init(centre: @escaping @Sendable () -> UNUserNotificationCenter = {
        UNUserNotificationCenter.current()
    }) {
        self.centre = centre
    }

    /// Asks once, if nobody has decided yet.
    ///
    /// `.alert` and `.sound` only: there is no badge to keep in step with
    /// anything, and asking for one is asking for a permission the app would
    /// never use.
    func requestAuthorizationIfNeeded() async {
        let centre = centre()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await centre.requestAuthorization(options: [.alert, .sound])
    }

    /// Posts "your answer is ready", if the reader is not already looking at
    /// the app.
    ///
    /// Checked at the moment of posting rather than when the job started: an
    /// answer that arrives two seconds after the reader comes back should not
    /// buzz in their hand while they watch it appear.
    @MainActor
    func postAnswerReady(job: AskJob) async {
        guard !Self.isActive else {
            // Logged rather than passed over in silence: "I closed the sheet
            // and never heard anything" is the one complaint this feature will
            // attract, and the answer is usually that the app was in front.
            IssaLog.info("ask notification skipped", ["reason": "app active"])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Your answer is ready"
        content.body = Self.body(bookTitle: job.bookTitle)
        content.sound = .default
        content.userInfo = [Self.bookUUIDKey: job.bookUUID]
        // Per book, so two books answered while the app was away read as two
        // conversations rather than one pile.
        content.threadIdentifier = Self.thread(for: job.bookUUID)

        let request = UNNotificationRequest(
            identifier: "\(Self.thread(for: job.bookUUID)).\(UUID().uuidString)",
            content: content,
            // nil, not a one-second trigger: the answer is ready now, and a
            // trigger would only give the app a second in which to be killed.
            trigger: nil,
        )
        do {
            try await centre().add(request)
            IssaLog.info("ask notification posted")
        } catch {
            // Never the question, never the answer.
            IssaLog.error("ask notification failed", ["kind": String(describing: type(of: error))])
        }
    }

    /// Which book the answer is about, and nothing else.
    ///
    /// The book on its own rather than a sentence around it: the title above
    /// has already said what happened, and a lock screen showing "Your answer is
    /// ready / Your answer about Peter and Wendy is ready" says it twice. The
    /// fallback is for an EPUB whose metadata carries no title at all, which is
    /// rare and is not worth an empty second line.
    static func body(bookTitle: String?) -> String {
        let trimmed = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Open the book to read it." : trimmed
    }

    /// Everything this feature posts is under this, so what it takes back is
    /// its own and never somebody else's.
    static func thread(for bookUUID: String) -> String { "issa.ask.\(bookUUID)" }

    /// Takes back what has already been delivered for one book.
    ///
    /// Delivered content sits on disk — and on a paired Watch — until something
    /// removes it, and nothing did: a banner about an answer outlived the
    /// answer, the sheet and the app being killed. Tapping the banner clears
    /// that one banner; this clears the ones the reader walked past on their way
    /// to opening the app themselves.
    func removeDelivered(bookUUID: String) async {
        let centre = centre()
        let thread = Self.thread(for: bookUUID)
        let identifiers = await centre.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == thread }
            .map(\.request.identifier)
        guard !identifiers.isEmpty else { return }
        centre.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Every book's, for sign-out and for deleting the downloads with the
    /// account.
    ///
    /// By identifier rather than `removeAllDeliveredNotifications()`: this app
    /// posts nothing else today, and a later notification that has nothing to do
    /// with asking should not be swept away by a purge of the Ask indexes.
    func removeAllDelivered() async {
        let centre = centre()
        let identifiers = await centre.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier.hasPrefix("issa.ask.") }
            .map(\.request.identifier)
        guard !identifiers.isEmpty else { return }
        centre.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static let bookUUIDKey = "bookUUID"

    @MainActor
    static var isActive: Bool {
        #if os(macOS)
        NSApp?.isActive ?? false
        #elseif canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        false
        #endif
    }
}

// MARK: -

/// What happens when one of those notifications is shown or tapped.
///
/// A class rather than a closure because `UNUserNotificationCenter` wants a
/// delegate object and holds it weakly, so somebody has to own it — on iOS
/// `AppServices`, on the Mac the app struct.
@MainActor
final class AskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let coordinator: AskCoordinator
    private let app: AppModel

    init(coordinator: AskCoordinator, app: AppModel) {
        self.coordinator = coordinator
        self.app = app
    }

    /// Nothing on screen while the app is in front.
    ///
    /// The reader can already see the pill say "Answer ready"; a banner over the
    /// page they are reading would be the app interrupting them to tell them
    /// something they are looking at.
    /// The completion-handler forms, not the `async` ones. Neither
    /// `UNNotification` nor `UNNotificationResponse` is `Sendable`, so an
    /// `async` requirement implemented on a main-actor type cannot be satisfied
    /// at all under strict concurrency — the argument would have to cross an
    /// isolation boundary. These stay `nonisolated`, take what they need as
    /// plain values, and hop with that.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler handler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void,
    ) {
        Task { @MainActor in
            handler(AskNotifier.isActive ? [] : [.banner, .sound])
        }
    }

    /// A tap opens the book and the answer with it.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping @Sendable () -> Void,
    ) {
        let uuid = response.notification.request.content
            .userInfo[AskNotifier.bookUUIDKey] as? String
        Task { @MainActor in
            if let uuid {
                // The sheet first, then the book: the reader is being sent back
                // to an answer, and the reader screen reads this the moment it
                // appears.
                coordinator.reopenRequest = uuid
                app.requestBook(uuid, .read)
            }
            handler()
        }
    }
}
#endif

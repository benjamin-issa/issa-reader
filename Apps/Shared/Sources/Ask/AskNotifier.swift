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
/// The body is the **question**, never the answer. A notification lands on a
/// lock screen that gets handed round, glanced at across a table, or mirrored
/// onto a watch — and this feature's whole promise is that nothing from further
/// into the book reaches the reader before they do. The question is theirs
/// already; the answer might not be.
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
        guard !Self.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your answer is ready"
        content.body = job.question
        content.sound = .default
        content.userInfo = [Self.bookUUIDKey: job.bookUUID]
        // Per book, so two books answered while the app was away read as two
        // conversations rather than one pile.
        content.threadIdentifier = "issa.ask.\(job.bookUUID)"

        let request = UNNotificationRequest(
            identifier: "issa.ask.\(job.bookUUID).\(UUID().uuidString)",
            content: content,
            // nil, not a one-second trigger: the answer is ready now, and a
            // trigger would only give the app a second in which to be killed.
            trigger: nil,
        )
        do {
            try await centre().add(request)
        } catch {
            // Never the question, never the answer.
            IssaLog.error("ask notification failed", ["kind": String(describing: type(of: error))])
        }
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

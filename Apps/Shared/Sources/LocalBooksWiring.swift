#if !os(tvOS)
import Foundation

/// Hands the local library to the objects that keep state per book, for both
/// apps' services.
///
/// An account's exit keeps these books' state (`AppModel.localBookUUIDs`), a
/// book leaving the list lets its reader go at once, and one that is gone for
/// good takes its question index, reader style and level with it. The phone's
/// `AppServices` and the Mac's `MacAppServices` each had a copy of this, kept
/// in step by a comment.
@MainActor
enum LocalBooksWiring {
    /// - Parameter afterLoad: run once the library has loaded, for what needs
    ///   the books on disk to be known first.
    static func connect(
        app: AppModel, local: LocalLibrary, ask: AskCoordinator, settings: PlaybackSettings,
        afterLoad: @escaping @MainActor (LocalLibrary) -> Void = { _ in },
    ) {
        app.localBookUUIDs = { [local] in local.uuids }
        local.onRemove = { [app] uuid in app.releaseLocalBook(uuid) }
        local.onForget = { [ask, settings] uuid in
            ask.remove(bookUUID: uuid)
            settings.forgetBook(uuid)
        }
        Task { [local] in
            await local.load()
            afterLoad(local)
        }
    }
}
#endif

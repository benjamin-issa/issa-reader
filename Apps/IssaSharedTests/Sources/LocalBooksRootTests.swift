import Foundation
import IssaCore
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// Where a reader with no server lands, what ⌘Z does to a removal, and what
/// is saved when the app goes to the background while signed out.
@Suite("The books from Files as the app's root", .serialized)
@MainActor
struct LocalBooksRootTests {
    // MARK: - The root rule

    /// 5 Spec, §3: "With no server connected and at least one book here, the
    /// list is the app's root." 4a: "the app opens on the list (or sign-in, if
    /// the list is empty)".
    @Test("a launch opens on the list while it has books, and on sign-in when it has none")
    func launchRule() {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let route = LocalBooksRoute(defaults: defaults)
        route.showsListSignedOut = true

        route.libraryLoaded(hasBooks: true)
        #expect(route.showsListSignedOut, "a reader with books lands on them")
        #expect(LocalBooksRoute(defaults: defaults).showsListSignedOut, "on every later launch too")

        route.libraryLoaded(hasBooks: false)
        #expect(!route.showsListSignedOut, "an empty list is not the root on a later launch")
    }

    @Test("signing in hands the root back to the library; signing out returns to the books")
    func phaseRule() {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let route = LocalBooksRoute(defaults: defaults)
        route.showsListSignedOut = true

        route.phaseChanged(from: .signingIn, to: .ready, hasBooks: true)
        #expect(!route.showsListSignedOut)
        route.phaseChanged(from: .ready, to: .chooseServer, hasBooks: true)
        #expect(route.showsListSignedOut, "signed out with books here, the app opens on them")
        route.phaseChanged(from: .ready, to: .chooseServer, hasBooks: false)
        #expect(!route.showsListSignedOut, "and on sign-in when there are none")
        // A connect that fails goes from signing in back to the form: not a
        // sign-out, and nothing about the root changes.
        route.showsListSignedOut = true
        route.phaseChanged(from: .signingIn, to: .chooseServer, hasBooks: false)
        #expect(route.showsListSignedOut)
    }

    @Test("a book, a missing file or an import in flight is something on the list")
    func hasAnything() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        #expect(!local.library.hasAnything)
        await local.importAndWait(try local.pick("alice"))
        #expect(local.library.hasAnything)
    }

    // MARK: - ⌘Z

    /// 5 Spec, §7 and 3c: "Edit › Undo ⌘Z also restores it."
    @Test("Undo through the window's undo manager takes a removal back")
    func undoManagerTakesItBack() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        let book = try #require(local.library.books.first)
        let undo = UndoManager()

        local.library.remove([book.uuid], undoManager: undo)
        #expect(local.library.books.isEmpty)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Remove Alice's Adventures in Wonderland")

        undo.undo()
        #expect(local.library.books.map(\.uuid) == [book.uuid])
        #expect(local.library.pendingRemoval == nil)
    }

    /// An undo left on the stack for a removal a later one has carried out
    /// must not take back the later one, or put back a book already deleted.
    @Test("an old undo does not reach a later removal")
    func staleUndoIsHarmless() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("alice"))
        await local.importAndWait(try local.pick("readalong"))
        let first = try #require(local.library.books.first { $0.title.hasPrefix("Alice") })
        let second = try #require(local.library.books.first { !$0.title.hasPrefix("Alice") })
        let undo = UndoManager()

        local.library.remove([first.uuid], undoManager: undo)
        // A second removal carries out the first, and has no undo of its own
        // on this manager — so the only undo there is is the stale one.
        local.library.remove([second.uuid])
        try #require(undo.canUndo)
        undo.undo()
        #expect(!undo.canUndo, "the stale undo was not the one run")

        #expect(local.library.pendingRemoval?.books.map(\.uuid) == [second.uuid],
                "the stale undo took back the wrong removal")
        #expect(local.library.book(first.uuid) == nil, "a removal already carried out came back")
    }

    // MARK: - Saved on the way to the background

    /// Signed out, the root's own scene-phase handler is what saves an open
    /// book from the reader's files: `LibraryTabs`, which flushes when signed
    /// in, does not exist. Hosted for real, with the scene phase moved the way
    /// the system moves it.
    @Test("going to the background while signed out saves the open local book")
    func suspendFlushesSignedOut() async throws {
        let persistence = try RecordingPersistence(accepts: true)
        defer { persistence.tearDown() }
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.phase = .chooseServer
        let model = app.reader(for: persistence.book, persistence: persistence)
        await model.open(pageSize: CGSize(width: 340, height: 560))
        try #require(model.phase == .ready)
        try #require(persistence.positions == 0)

        func root(_ phase: ScenePhase) -> AnyView {
            AnyView(RootView()
                .environment(app)
                .environment(local.library)
                .environment(\.scenePhase, phase))
        }
        let host = UIHostingController(rootView: root(.active))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(persistence.positions == 0, "nothing should be saved while the app is in front")

        host.rootView = root(.background)

        let saved = await LocalImportTests.eventually(within: .seconds(5)) { persistence.positions > 0 }
        #expect(saved, "the open local book was not saved on the way to the background")
    }
}

import Foundation
import IssaCore
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// What an iPhone or iPad window's root shows, and what happens to a book
/// from the reader's files open in its cover.
@Suite("The iPhone and iPad window root", .serialized)
@MainActor
struct RootWindowTests {
    // MARK: - One sign-in screen (R-08, R-09)

    /// "Sign in again" moves the phase from `.expired` through `.signingIn`
    /// to `.chooseServer` while its task runs. One screen across all three is
    /// one `SignInView`, and the browser route that task sets lands in it.
    @Test("every signed-out phase is the one sign-in screen, or the books from Files")
    func signedOutPhasesShareOneScreen() {
        for phase in [AppModel.Phase.expired, .signingIn, .chooseServer] {
            #expect(RootScreen.for(phase: phase, showsListSignedOut: false) == .signIn, "\(phase)")
            // The session-ended notice's own files link included: the flag
            // it sets is read in `.expired` too.
            #expect(RootScreen.for(phase: phase, showsListSignedOut: true) == .localBooks, "\(phase)")
        }
        #expect(RootScreen.for(phase: .ready, showsListSignedOut: true) == .library)
        #expect(RootScreen.for(phase: .launching, showsListSignedOut: true) == .launching)
    }

    // MARK: - Hosting

    /// A window on the host app's scene, showing a real `RootView`.
    @MainActor
    final class Window {
        let host: UIHostingController<AnyView>
        let window: UIWindow

        init(_ view: some View) throws {
            host = UIHostingController(rootView: AnyView(view))
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.isHidden = false
        }

        var isCovered: Bool { host.presentedViewController != nil }

        func close() {
            host.dismiss(animated: false)
            window.isHidden = true
        }
    }

    static func root(_ app: AppModel, _ local: LocalLibrary) -> some View {
        let services = AppServices.shared
        return RootView()
            .environment(app)
            .environment(local)
            .environment(services.settings)
            .environment(services.nowPlaying)
            .environment(services.ask)
    }

    static func loadedLibrary(with resource: String) async throws -> (LocalFixtures, Book) {
        let local = try LocalFixtures()
        await local.library.load()
        await local.importAndWait(try local.pick(resource))
        let book = try #require(local.library.books.first, "\(resource) was not added")
        return (local, book)
    }

    // MARK: - R-42

    /// iPad, two windows: removing a book in one while the other has it open
    /// left that window on a blank full-screen cover nothing could close.
    @Test("a book removed while its reader is open takes the reader with it")
    func removedBookClosesItsCover() async throws {
        let (local, book) = try await Self.loadedLibrary(with: "alice")
        defer { local.tearDown() }
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.phase = .chooseServer
        let window = try Window(Self.root(app, local.library))
        defer { window.close() }

        LocalBookRequests.shared.request(book.uuid)
        let opened = await LocalImportTests.eventually(within: .seconds(10)) { window.isCovered }
        try #require(opened, "the book never opened")

        local.library.remove([book.uuid])

        let closed = await LocalImportTests.eventually(within: .seconds(5)) { !window.isCovered }
        #expect(closed, "the window was left on a cover for a book that is gone")
    }

    // MARK: - R-43

    /// A link to a server book while a local one is open: consumed and pushed
    /// underneath the cover, where nothing could be seen.
    @Test("a server book's link takes down the local reader to be seen")
    func serverLinkClosesTheLocalCover() async throws {
        let (local, book) = try await Self.loadedLibrary(with: "alice")
        defer { local.tearDown() }
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let server = SharedFixtures.book("Dracula", uuid: "server-dracula")
        app.books = [server]
        app.phase = .ready
        let window = try Window(Self.root(app, local.library))
        defer { window.close() }

        LocalBookRequests.shared.request(book.uuid)
        let opened = await LocalImportTests.eventually(within: .seconds(10)) { window.isCovered }
        try #require(opened, "the local book never opened")

        app.requestBook(server.uuid, .details)

        let consumed = await LocalImportTests.eventually(within: .seconds(5)) { app.pendingBook == nil }
        try #require(consumed, "the link was never taken")
        let uncovered = await LocalImportTests.eventually(within: .seconds(5)) { !window.isCovered }
        #expect(uncovered, "the server book was pushed underneath the local reader")
    }

    // MARK: - R-29

    /// Two iPad windows each presented a reader over the one shared model
    /// when the answer's tap was broadcast to both.
    @Test("an answer tapped for a local book opens it in one window, not every window")
    func localTapOpensOneWindow() async throws {
        let (local, book) = try await Self.loadedLibrary(with: "alice")
        defer { local.tearDown() }
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.phase = .chooseServer
        let first = try Window(Self.root(app, local.library))
        defer { first.close() }
        let second = try Window(Self.root(app, local.library))
        defer { second.close() }
        try await Task.sleep(for: .milliseconds(300))

        LocalBookRequests.shared.request(book.uuid)

        let opened = await LocalImportTests.eventually(within: .seconds(10)) { first.isCovered || second.isCovered }
        try #require(opened, "neither window opened the book")
        try await Task.sleep(for: .seconds(1))
        #expect([first.isCovered, second.isCovered].filter { $0 }.count == 1,
                "the book opened in both windows over one shared reader")
        #expect(LocalBookRequests.shared.pending == nil)
    }
}

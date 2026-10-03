import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The Mac's menu-bar and window decisions, asked from the phone's test bundle
/// the way `LibraryModeSwitchTests` asks the toolbar switch's: the Mac code
/// calls these, and no test can drive its menu bar.
@Suite("Mac menus and windows, as decisions", .serialized)
@MainActor
struct MacDecisionsTests {
    // MARK: - MAC-1

    @Test("File offers Add Book… once the books from Files are known, and only then")
    func addBookRule() {
        #expect(!MacFileMenu.offersAddBook(wasShown: false, hasBooks: false))
        #expect(MacFileMenu.offersAddBook(wasShown: true, hasBooks: false))
        #expect(MacFileMenu.offersAddBook(wasShown: false, hasBooks: true))
    }

    /// Decided at launch, before the library had loaded, the answer was no —
    /// and nothing asked again, so a Mac with books had no File menu at all.
    @Test("the File menu is decided again when the library loads, and not on every change")
    func fileMenuFollowsTheLibrary() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let menu = MacFileMenu()
        menu.track(local.library)
        #expect(!menu.offersAddBook)

        await local.library.load()
        await local.importAndWait(try local.pick("alice"))

        let offered = await LocalImportTests.eventually(within: .seconds(5)) { menu.offersAddBook }
        #expect(offered, "books arrived and File still offered no Add Book…")

        // More changes to the books — a second book, a position saved — do
        // not flip the answer, so they do not rebuild the menu bar.
        await local.importAndWait(try local.pick("readalong"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.changes == 1, "the menu's flag was rewritten for a change that did not move it")
    }

    // MARK: - R-45, R-46

    @Test("Show in Library from Settings opens a library window only when none is open")
    func showInLibraryOpensALibraryWhenNeeded() {
        #expect(ShowInLibrary.opensLibraryWindow(libraryWindowsOpen: 0))
        #expect(!ShowInLibrary.opensLibraryWindow(libraryWindowsOpen: 1))
        #expect(!ShowInLibrary.opensLibraryWindow(libraryWindowsOpen: 2))
    }

    @Test("library windows count themselves in and out")
    func libraryWindowCount() {
        let windows = LibraryWindows()
        windows.appeared()
        windows.appeared()
        windows.disappeared()
        #expect(windows.open == 1)
        windows.disappeared()
        windows.disappeared()
        #expect(windows.open == 0)
    }

    // MARK: - Sign-out in progress (side note)

    /// A Settings screen built again during a sign-out — the Mac's window
    /// closed and reopened — had forgotten it and offered a second.
    @Test("a second sign-out is refused while one runs, whichever screen asks")
    func oneSignOutAtATime() async {
        let progress = SignOutProgress()
        var hold: CheckedContinuation<Void, Never>?
        let first = Task {
            await progress.run { await withCheckedContinuation { hold = $0 } }
        }
        let started = await LocalImportTests.eventually(within: .seconds(2)) { progress.isRunning && hold != nil }
        #expect(started)
        let second = await progress.run {}
        #expect(!second, "a second sign-out started behind the first")
        hold?.resume()
        #expect(await first.value)
        #expect(!progress.isRunning)
    }
}

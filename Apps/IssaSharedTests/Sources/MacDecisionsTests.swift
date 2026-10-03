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
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = MacFileMenu(defaults: defaults)
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

    /// A defaults domain of the test's own, so a remembered answer does not
    /// reach the next test or the host app.
    static func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "issa.tests.mac.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// macOS 27 adds no menu to the bar once it is built (F3), so the answer
    /// is kept: a relaunch starts with it, and a library that has not loaded
    /// yet — or has lost its last book — does not take it back.
    @Test("File's Add Book… is remembered, and not taken back")
    func fileMenuRemembers() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!MacFileMenu(defaults: defaults).offersAddBook)
        let menu = MacFileMenu(defaults: defaults)
        menu.track(local.library)
        local.library.noteShown()
        #expect(await LocalImportTests.eventually(within: .seconds(5)) { menu.offersAddBook })

        let relaunched = MacFileMenu(defaults: defaults)
        #expect(relaunched.offersAddBook, "a relaunch started without the File menu")
        // Tracking a library that has not loaded and was never shown is a no
        // here, and must not undo the remembered yes.
        let fresh = try LocalFixtures()
        defer { fresh.tearDown() }
        relaunched.track(fresh.library)
        #expect(relaunched.offersAddBook)
        #expect(relaunched.changes == 0)
    }

    /// The key `MacFileMenu` keeps its answer under, spelled out so this test
    /// says what is stored rather than trusting the type to.
    private static let rememberedKey = "issa.mac.fileMenuOffersAddBook"

    /// macOS 27 adds no menu to the bar after it is built, and the bar is
    /// built before the local library loads. A File menu decided afresh at
    /// each launch was therefore never there: the flag turned yes a moment
    /// after the bar had been built without it. The next launch has to start
    /// from the answer the last one reached.
    @Test("the File menu's Add Book… is offered from the start of the next launch")
    func fileMenuStartsFromTheLastAnswer() async throws {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.rememberedKey) }
        let local = try LocalFixtures()
        defer { local.tearDown() }

        let first = MacFileMenu()
        first.track(local.library)
        #expect(!first.offersAddBook)
        local.library.noteShown()
        let offered = await LocalImportTests.eventually(within: .seconds(5)) { first.offersAddBook }
        #expect(offered)

        // The relaunch: a new menu, before any library has loaded.
        let next = MacFileMenu()
        #expect(next.offersAddBook, "a relaunch started with no File menu, and macOS will not add one later")
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

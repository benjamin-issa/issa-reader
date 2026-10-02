#if ISSA_UITEST_FIXTURE
import Foundation

/// Adds a book to the local library at launch, for the UI tests, without the
/// system picker — which XCUITest cannot drive into Files.
///
/// `-IssaUITestFixtureLocalImport <file name>` names a file the test's script
/// planted in the app's own `tmp/` (`scripts/layout-sweep.sh` copies the
/// read-along fixture there). The book goes through the same `importBooks` the
/// picker's choice does — the copy, the checks, the row — so the flow under
/// test is the shipping one from the moment a URL arrives.
///
/// Debug only, and gated the way `UITestFixture` is: this folder is excluded
/// from Release builds by `project.yml`, and the argument contains the marker
/// `scripts/release.sh` greps the archived binary for, so a leak fails the
/// release.
enum LocalImportFixture {
    static let argument = "-IssaUITestFixtureLocalImport"

    /// The planted file named on the command line, or nil on an ordinary launch.
    static func requestedFile(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
    ) -> URL? {
        guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
        else { return nil }
        let name = (arguments[flag + 1] as NSString).lastPathComponent
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Queues the planted book, once the library has loaded.
    @MainActor
    static func importIfRequested(into library: LocalLibrary) {
        guard let url = requestedFile() else { return }
        // Only once per install: a relaunch would otherwise find it already
        // here and raise the duplicate toast over the screen under test.
        guard !library.books.contains(where: { $0.localCopy?.fileName == url.lastPathComponent })
        else { return }
        library.importBooks([url])
    }
}
#endif

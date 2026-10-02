import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// A local library of a test's own: its `Local/` folder, its device store and
/// the folder its "picked" files come from, all under one temporary directory
/// that `tearDown` removes. Nothing here touches the app's real `Local/` or
/// `Store/`.
@MainActor
struct LocalFixtures {
    let base: URL
    let library: LocalLibrary

    var root: URL { base.appending(path: "Local", directoryHint: .isDirectory) }
    var storeDirectory: URL { base.appending(path: "Store", directoryHint: .isDirectory) }
    /// Where the reader's "Files" are: the picker hands over URLs in here.
    var picked: URL { base.appending(path: "Picked", directoryHint: .isDirectory) }

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-local-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: base.appending(path: "Picked", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        library = LocalLibrary(
            root: base.appending(path: "Local", directoryHint: .isDirectory),
            storeDirectory: base.appending(path: "Store", directoryHint: .isDirectory))
        // Short, so the tests that wait for them are not slow.
        library.addedHold = .milliseconds(10)
    }

    /// A library over the same folders, as a relaunch would build it.
    func relaunched() -> LocalLibrary {
        let next = LocalLibrary(root: root, storeDirectory: storeDirectory)
        next.addedHold = .milliseconds(10)
        return next
    }

    func tearDown() {
        library.cancelAllImports()
        try? FileManager.default.removeItem(at: base)
    }

    /// One of the bundle's books, copied into "Files" under `name`.
    func pick(_ resource: String, as name: String? = nil) throws -> URL {
        let bundle = Bundle(for: BundleMarker.self)
        let source = try #require(
            bundle.url(forResource: resource, withExtension: "epub"),
            "\(resource).epub is not in the test bundle")
        return try pick(Data(contentsOf: source), as: name ?? "\(resource).epub")
    }

    /// Bytes put in "Files" under `name`.
    func pick(_ data: Data, as name: String) throws -> URL {
        let url = picked.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// Imports and waits for the queue to finish, then returns the row.
    @discardableResult
    func importAndWait(_ url: URL, reattaching: String? = nil) async -> LocalImport? {
        library.importBooks([url], reattaching: reattaching)
        await library.importsSettled()
        return library.imports.last { $0.source == url }
    }

    /// The `.incoming/` folder's contents: crash leftovers and copies in flight.
    func incoming() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: LocalBookFiles.incoming(in: root).path)) ?? []
    }

    private final class BundleMarker {}
}

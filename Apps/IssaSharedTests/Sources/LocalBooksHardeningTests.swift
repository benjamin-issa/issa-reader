import Foundation
import IssaCore
import SQLite3
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// What a file from the reader's own folders, or a device store in a bad way,
/// must not be able to do to the list: crash it, empty it, or leave it saying
/// something stale. The 1.4.0 review's local-books findings, one test each.
@Suite("Books from the reader's files, against bad input", .serialized)
@MainActor
struct LocalBooksHardeningTests {
    // MARK: - A book from another volume

    /// What a USB drive or a network share gets: not a clone, a chunked copy.
    /// It read past the end of the file as a failure, so every such book was
    /// refused as "Couldn't copy this book".
    @Test("a book that cannot be cloned is copied to its end and added")
    func chunkedCopyReachesTheEnd() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        local.library.importer.allowsClone = false
        let url = try local.pick("readalong")

        let row = await local.importAndWait(url)

        #expect(row?.stage != .failed(.copyFailed), "the chunked copy failed at the end of the file")
        let book = try #require(local.library.books.first)
        #expect(try Data(contentsOf: local.library.files(for: book.uuid).epub) == Data(contentsOf: url))
        #expect(book.localCopy?.fingerprint == (try LocalBookImporter.sha256(of: url)))
    }

    // MARK: - R-63: the copy says how far it has got, not every megabyte

    @Test("the chunked copy reports whole percents only, and hashes as it copies")
    func copyReportsArePercents() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        var importer = local.library.importer
        importer.allowsClone = false
        importer.chunkSize = 16
        let url = try local.pick("readalong")
        let reports = StageLog()

        let prepared = try await importer.run(url, id: UUID()) { reports.append($0) }
        defer { prepared.discard() }

        let fractions = reports.copying
        #expect(!fractions.isEmpty)
        #expect(fractions.count <= 101, "\(fractions.count) progress reports for one small file")
        let percents = fractions.map { Int(($0 * 100).rounded(.down)) }
        #expect(percents == percents.sorted() && Set(percents).count == percents.count,
                "a report that did not move the whole percent")
        #expect(prepared.fingerprint == (try LocalBookImporter.sha256(of: url)))
    }
}

/// Stages reported from the importer's own queue.
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [LocalImport.Stage] = []

    func append(_ stage: LocalImport.Stage) { lock.withLock { stages.append(stage) } }

    var copying: [Double] {
        lock.withLock { stages.compactMap { if case let .copying(f) = $0 { f } else { nil } } }
    }
}

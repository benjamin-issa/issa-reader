import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// The widget's cover, when it cannot be had.
///
/// A cover that could not be fetched — offline, or a book whose art 404s in
/// both shapes — left nothing on disk to say it had been tried, and the
/// publisher treated a snapshot without its cover as changed. So every publish
/// rewrote the snapshot, reloaded the widget and asked for the cover again:
/// every two seconds while narrating, against a reload budget counted in tens
/// a day. These drive the decision itself, which is everything `publish` does
/// apart from reading and writing the files.
@Suite("Publishing the widget when its cover cannot be fetched")
@MainActor
struct WidgetCoverAttemptTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// What is on disk after the first publish of a book whose cover never
    /// arrived: the book, no cover stamped.
    private static func snapshot(
        progress: Double = 0.40, coverBookID: String? = nil,
    ) -> CurrentBookSnapshot {
        CurrentBookSnapshot(
            bookID: "book", title: "Dracula", author: "Bram Stoker", chapter: "Chapter 3",
            progress: progress, isPlaying: true, coverBookID: coverBookID)
    }

    private static func plan(
        existing: CurrentBookSnapshot?, progress: Double = 0.4001,
        lastAttempt: CurrentBookPublisher.CoverAttempt?, at now: Date = now,
    ) -> CurrentBookPublisher.Plan {
        CurrentBookPublisher.plan(
            existing: existing, bookID: "book", chapter: "Chapter 3",
            progress: progress, isPlaying: true, lastAttempt: lastAttempt, now: now)
    }

    @Test("a repeated publish after a failed cover neither writes, reloads nor asks again")
    func failedCoverDoesNotLoop() {
        let tried = CurrentBookPublisher.CoverAttempt(bookID: "book", at: Self.now.addingTimeInterval(-2))
        let plan = Self.plan(existing: Self.snapshot(), lastAttempt: tried)
        #expect(!plan.write, "nothing the widget draws moved, so the snapshot is not rewritten")
        #expect(!plan.fetchCover, "the cover was asked for two seconds ago")
    }

    @Test("sixty publishes two seconds apart after a failed cover cost one request and one write")
    func aMinuteOfNarrationOffline() {
        // The first publish of the book: written, and the cover asked for.
        var attempt: CurrentBookPublisher.CoverAttempt?
        var writes = 0, fetches = 0
        var onDisk: CurrentBookSnapshot?
        for tick in 0 ..< 60 {
            let now = Self.now.addingTimeInterval(Double(tick) * 2)
            let progress = 0.40 + Double(tick) * 0.0001
            let plan = Self.plan(existing: onDisk, progress: progress, lastAttempt: attempt, at: now)
            if plan.write {
                writes += 1
                onDisk = Self.snapshot(progress: progress)
            }
            if plan.fetchCover {
                fetches += 1
                attempt = .init(bookID: "book", at: now)
            }
        }
        #expect(writes <= 4, "progress moves a fifth of a percent every forty seconds at most")
        #expect(fetches == 1)
    }

    @Test("the cover is asked for again once the retry interval has passed")
    func retriesAfterTheInterval() {
        let tried = CurrentBookPublisher.CoverAttempt(
            bookID: "book", at: Self.now.addingTimeInterval(-CurrentBookPublisher.coverRetry - 1))
        let plan = Self.plan(existing: Self.snapshot(), lastAttempt: tried)
        #expect(plan.fetchCover)
        #expect(!plan.write, "a retry needs no rewrite: a cover that lands stamps and reloads itself")
    }

    @Test("an attempt for another book does not stand for this one")
    func anotherBooksAttemptDoesNotCount() {
        let tried = CurrentBookPublisher.CoverAttempt(bookID: "other", at: Self.now)
        #expect(Self.plan(existing: Self.snapshot(), lastAttempt: tried).fetchCover)
    }

    @Test("a cover already on disk is never asked for")
    func landedCoverIsKept() {
        let plan = Self.plan(existing: Self.snapshot(coverBookID: "book"), lastAttempt: nil)
        #expect(!plan.fetchCover)
        #expect(!plan.write)
    }

    @Test("a new book is written and its cover asked for")
    func newBookIsPublished() {
        let previous = CurrentBookSnapshot(
            bookID: "previous", title: "Carmilla", author: "Le Fanu", progress: 0.4,
            isPlaying: true, coverBookID: "previous")
        let plan = Self.plan(existing: previous, lastAttempt: .init(bookID: "previous", at: Self.now))
        #expect(plan.write)
        #expect(plan.fetchCover)
    }

    @Test("a move worth drawing is still written while the cover is outstanding")
    func progressStillWrites() {
        let tried = CurrentBookPublisher.CoverAttempt(bookID: "book", at: Self.now)
        #expect(Self.plan(existing: Self.snapshot(), progress: 0.45, lastAttempt: tried).write)
    }
}

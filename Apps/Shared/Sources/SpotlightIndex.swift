import Foundation
import IssaCore
import IssaUI
#if !os(tvOS)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Puts the library into system search.
///
/// Indexed with the same deep link the widget uses, so a Spotlight result opens
/// the book rather than the app. Books are indexed once per library change and
/// re-indexed only when the server says something changed, because reindexing a
/// large library on every launch is a real cost for no benefit.
enum SpotlightIndex {
    static let domain = "com.benjaminissa.issareader.books"
    private static let versionKey = "issa.spotlight.libraryVersion"

    /// A cheap stand-in for "the library changed": the count plus the newest
    /// update timestamp. Cheaper than diffing, and wrong only in the case where
    /// one book is added and another deleted in the same instant.
    static func version(of books: [Book]) -> String {
        let newest = books.compactMap { $0.updatedAt?.value.timeIntervalSince1970 }.max() ?? 0
        return "\(books.count)-\(Int(newest))"
    }

    /// The line under a result: the byline, then the blurb as plain text.
    ///
    /// The blurb is the server's HTML — a 3.x description arrives as
    /// `<p>It is a truth <i>universally acknowledged</i>…` — and Spotlight
    /// shows a description verbatim, tags, entities and all. The detail screen
    /// has always put the same string through `HTMLText`; this is the plain
    /// half of that.
    static func contentDescription(for book: Book) -> String {
        let blurb = book.description.map {
            HTMLText.plain($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [book.byline, blurb]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
    }

    /// tvOS ships CoreSpotlight but not its indexing API — the classes are
    /// marked unavailable — so there the whole thing is a no-op rather than a
    /// separate code path at every call site.
    #if os(tvOS)
    static func index(_ books: [Book], force: Bool = false) async {}
    static func clear() async {}
    #else
    static func index(_ books: [Book], force: Bool = false) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let version = version(of: books)
        if !force, UserDefaults.standard.string(forKey: versionKey) == version { return }

        let items = books.map { book -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = book.title
            attributes.contentDescription = contentDescription(for: book)
            attributes.authorNames = book.authors.map(\.name)
            attributes.contentType = UTType.epub.identifier
            // Series and tags make a book findable by what it is as well as
            // what it is called.
            attributes.keywords = book.tags.map(\.name) + book.series.map(\.name)
            if let duration = book.narrationDuration {
                attributes.duration = NSNumber(value: duration)
            }
            attributes.contentURL = CurrentBookSnapshotStore.deepLink(bookID: book.uuid)

            let item = CSSearchableItem(
                uniqueIdentifier: book.uuid, domainIdentifier: domain, attributeSet: attributes)
            // A month: long enough that a book stays findable between launches,
            // short enough that a deleted book eventually falls out even if the
            // delete pass never runs.
            item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)
            return item
        }

        do {
            // Replacing the domain rather than adding: a book deleted on the
            // server must stop appearing in Spotlight too.
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            try await CSSearchableIndex.default().indexSearchableItems(items)
            UserDefaults.standard.set(version, forKey: versionKey)
        } catch {
            IssaLog.failure("spotlight index", error, ["items": String(items.count)])
            // Indexing is a convenience; failing it must never surface as an
            // error the reader has to dismiss.
            UserDefaults.standard.removeObject(forKey: versionKey)
        }
    }

    /// Takes this library out of system search, waiting for that at most
    /// `clearWait`.
    ///
    /// Called in line by an account's departure — sign-out and an account
    /// switch — which awaited the deletion outright. The deletion is answered
    /// by a system daemon, and one that never answers (seen on an iOS 27
    /// simulator under load, for minutes on end) held the hand-over with it:
    /// the arriving account never reached its library. The deletion still
    /// runs to the end when it is slow; only the departure stops waiting.
    static func clear() async {
        UserDefaults.standard.removeObject(forKey: versionKey)
        let finished = await BoundedWait.run(for: clearWait) {
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        }
        if !finished {
            IssaLog.warning("spotlight clear still running; not waiting for it",
                            ["seconds": String(Int(clearWait.components.seconds))])
        }
    }

    static let clearWait: Duration = .seconds(3)
    #endif
}

/// Waits for some work, or for a deadline, whichever comes first.
///
/// For work a caller cannot cancel and must not be held by: the work runs in
/// a task of its own and goes on after the wait ends. A task group cannot do
/// this, because it waits for every child, and a child stuck in a call that
/// ignores cancellation holds the group as surely as awaiting it directly.
enum BoundedWait {
    /// - Returns: whether the work finished before the deadline.
    @discardableResult
    static func run(
        for limit: Duration, _ work: @escaping @Sendable () async -> Void,
    ) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.hold(continuation)
            Task.detached {
                await work()
                once.resume(returning: true)
            }
            Task.detached {
                try? await Task.sleep(for: limit)
                once.resume(returning: false)
            }
        }
    }

    /// Resumes a continuation exactly once, whichever side gets there first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func hold(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(returning value: Bool) {
            let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
    }
}

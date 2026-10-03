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
/// the book rather than the app. Books are indexed once per library change, and
/// again when what an item carries changes (`SpotlightIndexer.schema`) or a
/// week has passed — the items expire after a month, and an unchanged library
/// was otherwise never put back. Not on every launch: reindexing a large
/// library each time is a real cost for no benefit.
@MainActor
enum SpotlightIndex {
    nonisolated static let domain = "com.benjaminissa.issareader.books"

    /// A cheap stand-in for "the library changed": the count plus the newest
    /// update timestamp. Cheaper than diffing, and wrong only in the case where
    /// one book is added and another deleted in the same instant.
    nonisolated static func version(of books: [Book]) -> String {
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
    nonisolated static func contentDescription(for book: Book) -> String {
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
        await SpotlightIndexer.shared.index(books, force: force)
    }

    /// Takes this library out of system search, waiting for that at most
    /// `clearWait`. See `SpotlightIndexer.clear()`.
    static func clear() async {
        await SpotlightIndexer.shared.clear()
    }

    nonisolated static let clearWait: Duration = .seconds(3)
    #endif
}

#if !os(tvOS)
/// What indexing asks of CoreSpotlight: replace the domain, or empty it.
///
/// A seam so a test can hold a deletion the way a slow system daemon does,
/// which is the condition the generation below exists for.
@MainActor
protocol SpotlightBackend: AnyObject, Sendable {
    func deleteDomain(_ domain: String) async throws
    func index(_ items: [CSSearchableItem]) async throws
}

/// The system's own index.
@MainActor
final class CoreSpotlightBackend: SpotlightBackend {
    func deleteDomain(_ domain: String) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    func index(_ items: [CSSearchableItem]) async throws {
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }
}

/// The one owner of the library's place in system search.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer(
        backend: CoreSpotlightBackend(), defaults: .standard,
        isAvailable: { CSSearchableIndex.isIndexingAvailable() })

    static let versionKey = "issa.spotlight.libraryVersion"

    private let backend: any SpotlightBackend
    private let defaults: UserDefaults
    private let isAvailable: () -> Bool
    private let clearWait: Duration

    init(
        backend: any SpotlightBackend, defaults: UserDefaults,
        isAvailable: @escaping () -> Bool = { true },
        clearWait: Duration = SpotlightIndex.clearWait,
    ) {
        self.backend = backend
        self.defaults = defaults
        self.isAvailable = isAvailable
        self.clearWait = clearWait
    }

    /// When the index was last written, so an unchanged library is put back
    /// before its items expire.
    static let indexedAtKey = "issa.spotlight.indexedAt"

    /// What the items carry, bumped whenever that changes so an upgrader's
    /// index is rebuilt even though their catalogue has not moved. 2: the
    /// description became plain text (1.4.0); 1.3.0 stored the bare version.
    static let schema = 2

    /// Items expire a month after they are indexed; an unchanged library is
    /// indexed again once a week, well inside that.
    static let renewal: TimeInterval = 7 * 24 * 3600

    /// Bumped by every pass and by `clear()`, so a pass that has been
    /// overtaken — by a newer one, or by the account leaving — neither adds
    /// its items nor records them as indexed.
    private var generation = 0

    /// What is stored for a library: its version under this schema.
    static func stamp(of books: [Book]) -> String {
        "\(schema)|\(SpotlightIndex.version(of: books))"
    }

    /// Whether the stored index still answers for this library.
    static func isCurrent(stored: String?, indexedAt: Date?, stamp: String, now: Date) -> Bool {
        guard stored == stamp, let indexedAt else { return false }
        return now.timeIntervalSince(indexedAt) < renewal
    }

    func index(_ books: [Book], force: Bool = false, now: Date = .now) async {
        guard isAvailable() else { return }
        let stamp = Self.stamp(of: books)
        let indexedAt = (defaults.object(forKey: Self.indexedAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        if !force, Self.isCurrent(
            stored: defaults.string(forKey: Self.versionKey), indexedAt: indexedAt, stamp: stamp, now: now)
        { return }

        generation &+= 1
        let pass = generation
        // Forgotten before the domain is emptied: a pass that stops after the
        // deletion has left nothing indexed, and a stored version would say
        // otherwise until the catalogue next changed.
        defaults.removeObject(forKey: Self.versionKey)
        let items = books.map { Self.item(for: $0, now: now) }
        do {
            // Replacing the domain rather than adding: a book deleted on the
            // server must stop appearing in Spotlight too.
            try await backend.deleteDomain(SpotlightIndex.domain)
            // The deletion is answered by a daemon that ignores cancellation
            // and can take minutes. An account that left meanwhile has had its
            // books taken out by `clear()`; putting them back now would leave
            // them answering Home Screen search on a signed-out device.
            guard pass == generation, !Task.isCancelled else { return }
            try await backend.index(items)
            guard pass == generation else { return }
            defaults.set(stamp, forKey: Self.versionKey)
            defaults.set(now.timeIntervalSince1970, forKey: Self.indexedAtKey)
        } catch {
            IssaLog.failure("spotlight index", error, ["items": String(items.count)])
            // Indexing is a convenience; failing it must never surface as an
            // error the reader has to dismiss.
            defaults.removeObject(forKey: Self.versionKey)
        }
    }

    /// Called in line by an account's departure — sign-out and an account
    /// switch — which awaited the deletion outright. The deletion is answered
    /// by a system daemon, and one that never answers (seen on an iOS 27
    /// simulator under load, for minutes on end) held the hand-over with it:
    /// the arriving account never reached its library. The deletion still
    /// runs to the end when it is slow; only the departure stops waiting.
    func clear() async {
        generation &+= 1
        defaults.removeObject(forKey: Self.versionKey)
        defaults.removeObject(forKey: Self.indexedAtKey)
        let backend = self.backend
        let finished = await BoundedWait.run(for: clearWait) { @MainActor in
            try? await backend.deleteDomain(SpotlightIndex.domain)
        }
        if !finished {
            IssaLog.warning("spotlight clear still running; not waiting for it",
                            ["seconds": String(Int(clearWait.components.seconds))])
        }
    }

    static func item(for book: Book, now: Date) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
        attributes.title = book.title
        attributes.contentDescription = SpotlightIndex.contentDescription(for: book)
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
            uniqueIdentifier: book.uuid, domainIdentifier: SpotlightIndex.domain, attributeSet: attributes)
        // A month: long enough that a book stays findable between launches,
        // short enough that a deleted book eventually falls out even if the
        // delete pass never runs.
        item.expirationDate = now.addingTimeInterval(30 * 24 * 3600)
        return item
    }
}
#endif

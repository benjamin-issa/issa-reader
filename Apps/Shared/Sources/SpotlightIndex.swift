import Foundation
import IssaCore
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
            attributes.contentDescription = [book.byline, book.description]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
            attributes.authorNames = book.authors.map(\.name)
            attributes.contentType = UTType.epub.identifier
            // Series and tags make a book findable by what it is as well as
            // what it is called.
            attributes.keywords = book.tags.map(\.name) + book.series.map(\.name)
            if let duration = book.audiobook?.duration ?? book.readaloud?.duration {
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
            // Indexing is a convenience; failing it must never surface as an
            // error the reader has to dismiss.
            UserDefaults.standard.removeObject(forKey: versionKey)
        }
    }

    static func clear() async {
        UserDefaults.standard.removeObject(forKey: versionKey)
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }
    #endif
}

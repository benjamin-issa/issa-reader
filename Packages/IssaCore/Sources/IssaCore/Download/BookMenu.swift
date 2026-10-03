import Foundation

/// What a book's hold or right-click menu offers, wherever the book is drawn.
///
/// Every surface that shows a book — a grid cell, a rail cover, the Continue
/// card, a row in the Reading tab or the Downloads list, a television poster —
/// offers the same menu, so the decisions about it are made once, here, where
/// they can be tested, and the views only draw the answer. The same reason
/// `BookPrimaryAction` lives in this package: the view layer has no tests, and
/// a menu that offers Read on an audiobook or "Go to Series" on the series'
/// own page goes wrong without anything failing.
///
/// The items come in groups, drawn with a divider between them:
/// 1. View details · Read or Resume · Listen or Now Playing
/// 2. Mark as ▸ · Rate ▸
/// 3. Go to Series · More by ‹author›
/// 4. The editions: one inline, or several behind "Downloads ▸"
/// 5. A Downloads row's own "Remove download", last
public struct BookMenu: Equatable, Sendable {
    /// Which screen the menu was opened on, so it does not offer the way to
    /// where the reader already is.
    public enum Place: Hashable, Sendable {
        /// A shelf with no subject of its own: the library, the Reading tab,
        /// Browse, Listening, the Downloads list.
        case shelf
        /// A book's own page (its related rails), by uuid.
        case book(String)
        /// A series page, by name.
        case series(String)
        /// An author's page, by name.
        case author(String)
        /// A tag's page, by name.
        case tag(String)
    }

    /// What the platform drawing the menu can do.
    ///
    /// Mark as and Rate are not here: every platform can set a status and a
    /// rating, and on a television the menu is the only place it can.
    public struct Capabilities: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// A screen about the book to go to.
        public static let details = Capabilities(rawValue: 1 << 0)
        /// Open the reader.
        public static let read = Capabilities(rawValue: 1 << 1)
        /// Start the audio, and somewhere to show it playing.
        public static let listen = Capabilities(rawValue: 1 << 2)
        /// Push a series or an author's page.
        public static let navigate = Capabilities(rawValue: 1 << 3)
        /// Save, pause, resume and remove editions.
        public static let downloads = Capabilities(rawValue: 1 << 4)

        /// iPhone, iPad and the Mac's library window.
        public static let all: Capabilities = [.details, .read, .listen, .navigate, .downloads]
        /// The Mac's Settings window: no stack to push a page onto.
        public static let settingsWindow: Capabilities = [.details, .read, .listen, .downloads]
        /// Apple TV. Pressing a poster already opens the book's one screen,
        /// which is the read-along; there is no detail page, no series or
        /// author page, and nowhere to show playback controls but that screen.
        public static let television: Capabilities = [.downloads]
    }

    /// Everything the menu depends on besides the book.
    public struct Inputs: Sendable {
        public var isSignedIn: Bool
        /// The server's statuses. Empty hides Mark as.
        public var statuses: [Status]
        /// This reader's own rating of the book.
        public var rating: Double?
        /// Whether this book's audio is what is playing.
        public var isPlaying: Bool
        /// Editions on this device and staying there (a removal inside its
        /// undo window is not one).
        public var downloadedFormats: Set<BookContentService.Format>
        /// The download state of each edition that has one.
        public var downloadStates: [BookContentService.Format: DownloadManager.State]
        /// Names of the series the library groups — those with two books or
        /// more. A series of one has no page to go to.
        public var groupedSeries: Set<String>
        /// How many books the library holds by the book's first author,
        /// this one included.
        public var firstAuthorBookCount: Int
        public var place: Place
        /// The edition a Downloads row stands for. Its removal is the row's
        /// own, drawn last, and the edition is left out of the Downloads group.
        public var focusEdition: BookContentService.Format?
        public var capabilities: Capabilities

        public init(
            isSignedIn: Bool = true,
            statuses: [Status] = [],
            rating: Double? = nil,
            isPlaying: Bool = false,
            downloadedFormats: Set<BookContentService.Format> = [],
            downloadStates: [BookContentService.Format: DownloadManager.State] = [:],
            groupedSeries: Set<String> = [],
            firstAuthorBookCount: Int = 0,
            place: Place = .shelf,
            focusEdition: BookContentService.Format? = nil,
            capabilities: Capabilities = .all,
        ) {
            self.isSignedIn = isSignedIn
            self.statuses = statuses
            self.rating = rating
            self.isPlaying = isPlaying
            self.downloadedFormats = downloadedFormats
            self.downloadStates = downloadStates
            self.groupedSeries = groupedSeries
            self.firstAuthorBookCount = firstAuthorBookCount
            self.place = place
            self.focusEdition = focusEdition
            self.capabilities = capabilities
        }
    }

    public enum Item: Equatable, Sendable {
        case details
        /// "Read" or "Resume": `BookPrimaryAction.reading(book:)`'s compact
        /// title, so the menu and the book page say the same word.
        case read(title: String)
        case listen
        case nowPlaying
        /// One entry per server status, the book's own marked.
        case markAs([StatusChoice])
        /// The current whole-star rating, nil when unrated. Clear rating is
        /// offered only when there is one to clear.
        case rate(current: Int?)
        case goToSeries(name: String)
        case moreBy(author: String)
        /// The one edition there is, drawn inline.
        case edition(EditionAction)
        /// Several editions, behind a "Downloads" submenu.
        case downloads([EditionAction])
        /// A Downloads row's own removal, destructive and last.
        case removeFocused(BookContentService.Format)
    }

    public struct StatusChoice: Equatable, Sendable, Identifiable {
        public let status: Status
        public let isCurrent: Bool
        public var id: String { status.uuid }
    }

    /// The one thing the menu offers for one edition: the same choice the
    /// book page's edition menu makes, reduced to its first applicable item.
    public struct EditionAction: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case save
            case pause
            case resume
            case retry
            case remove
        }

        public let format: BookContentService.Format
        public let kind: Kind
        public var id: String { format.rawValue }

        public var isDestructive: Bool { kind == .remove }

        /// The item's words. Inline, the menu holds one edition and the verb
        /// is enough; inside "Downloads" it has to say which edition it means.
        public func title(namingEdition: Bool) -> String {
            let edition = format.displayName
            switch (kind, namingEdition) {
            case (.save, false): return "Save for offline"
            case (.save, true): return "Save \(edition) for offline"
            case (.pause, false): return "Pause download"
            case (.pause, true): return "Pause \(edition) download"
            case (.resume, false): return "Resume download"
            case (.resume, true): return "Resume \(edition) download"
            case (.retry, false): return "Try again"
            case (.retry, true): return "Try \(edition) again"
            case (.remove, false): return "Remove download"
            case (.remove, true): return "Remove \(edition) download"
            }
        }

        public var systemImage: String {
            switch kind {
            case .save: "arrow.down.circle"
            case .pause: "pause.circle"
            case .resume: "play.circle"
            case .retry: "arrow.clockwise"
            case .remove: "trash"
            }
        }
    }

    /// The groups, in order, none of them empty.
    public let sections: [[Item]]

    /// Every item, for a caller that only needs to know what is there.
    public var items: [Item] { sections.flatMap { $0 } }

    public var isEmpty: Bool { sections.isEmpty }

    /// The order the book page lists editions in.
    static let editionOrder: [BookContentService.Format] = [.ebook, .audiobook, .readaloud]

    public static func resolve(for book: Book, inputs: Inputs) -> BookMenu {
        let can = inputs.capabilities
        var sections: [[Item]] = []
        func add(_ group: [Item]) { if !group.isEmpty { sections.append(group) } }

        guard inputs.isSignedIn else {
            // Signed out there is no catalogue to act on and no server to
            // tell, but a file on this device is still the reader's to delete
            // — that is why signing out can keep downloads at all.
            if can.contains(.downloads) {
                add(editionItems(editions(
                    downloaded: inputs.downloadedFormats, excluding: inputs.focusEdition
                ).map { EditionAction(format: $0, kind: .remove) }))
            }
            if let focus = inputs.focusEdition { add([.removeFocused(focus)]) }
            return BookMenu(sections: sections)
        }

        // 1. Opening the book.
        var opening: [Item] = []
        if can.contains(.details) { opening.append(.details) }
        if can.contains(.read), let reading = BookPrimaryAction.reading(book: book) {
            opening.append(.read(title: reading.title(compact: true)))
        }
        let formats = book.servableFormats
        if can.contains(.listen), formats.contains(.audiobook) || formats.contains(.readaloud) {
            opening.append(inputs.isPlaying ? .nowPlaying : .listen)
        }
        add(opening)

        // 2. The reader's own say about it.
        var opinion: [Item] = []
        if !inputs.statuses.isEmpty {
            opinion.append(.markAs(inputs.statuses.map {
                StatusChoice(status: $0, isCurrent: $0.uuid == book.status?.uuid)
            }))
        }
        // Through `StarRating`, never `Int(_:)` on the server's number: a
        // rating of 1e300 trapped every time this menu was built.
        opinion.append(.rate(current: inputs.rating.map(StarRating.wholeStars)))
        add(opinion)

        // 3. Where it sits in the library.
        var neighbours: [Item] = []
        if can.contains(.navigate) {
            if let series = book.primarySeries?.name,
               inputs.groupedSeries.contains(series),
               inputs.place != .series(series) {
                neighbours.append(.goToSeries(name: series))
            }
            if let author = book.authors.first?.name,
               inputs.firstAuthorBookCount > 1,
               inputs.place != .author(author) {
                neighbours.append(.moreBy(author: author))
            }
        }
        add(neighbours)

        // 4. Its editions.
        if can.contains(.downloads) {
            let servable = Set(formats.compactMap { BookContentService.Format(rawValue: $0.rawValue) })
            add(editionItems(editions(downloaded: servable, excluding: inputs.focusEdition).map {
                EditionAction(format: $0, kind: kind(
                    state: inputs.downloadStates[$0],
                    onDisk: inputs.downloadedFormats.contains($0)))
            }))
        }

        // 5. The row's own removal.
        if let focus = inputs.focusEdition { add([.removeFocused(focus)]) }
        return BookMenu(sections: sections)
    }

    private static func editions(
        downloaded formats: Set<BookContentService.Format>,
        excluding focus: BookContentService.Format?,
    ) -> [BookContentService.Format] {
        editionOrder.filter { formats.contains($0) && $0 != focus }
    }

    private static func editionItems(_ actions: [EditionAction]) -> [Item] {
        switch actions.count {
        case 0: []
        case 1: [.edition(actions[0])]
        default: [.downloads(actions)]
        }
    }

    /// The book page's edition menu, in its order: a transfer in flight or
    /// paused is the more urgent truth; then a file on disk, which nothing
    /// should offer to fetch again — not even after a failed re-download, for
    /// the reason `BookPrimaryAction` puts the file above `.failed`; then a
    /// failure; and only then the offer to save it.
    static func kind(state: DownloadManager.State?, onDisk: Bool) -> EditionAction.Kind {
        if let state, state.isActive { return .pause }
        if case .paused = state { return .resume }
        if onDisk { return .remove }
        if state?.isFailure == true { return .retry }
        return .save
    }
}

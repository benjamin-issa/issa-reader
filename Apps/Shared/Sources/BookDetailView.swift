import IssaCore
import IssaUI
import SwiftUI

/// Everything the server knows about a book.
///
/// The brief asks for views as data-rich as the server allows, and a single
/// `GET /api/v2/books` already carries all of this — description, both cover
/// editions, creators by role, series position, collections, tags, identifiers,
/// per-user status and position. None of it costs an extra request.
public struct BookDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Which editions are on disk, recomputed on appear and whenever a download
    /// finishes or is deleted anywhere in the app.
    @State private var downloaded: Set<BookContentService.Format> = []
    #if os(iOS)
    @State private var showsReader = false
    #endif
    /// The book as it was when this screen opened. Identity only — everything
    /// drawn comes from `book` below.
    private let initialBook: Book

    /// The live book from the model.
    ///
    /// Navigating here hands over a value, and a value does not change when the
    /// library does: setting a status updated the model and left this screen
    /// showing the old one. Looking it up each time keeps the screen honest
    /// about status, rating and progress, all of which change from here.
    private var book: Book {
        app.books.first { $0.uuid == initialBook.uuid } ?? initialBook
    }

    public init(book: Book) {
        initialBook = book
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing32) {
                // The hero and the action row read as one block, but the row is
                // full width rather than trapped in the ~212pt column beside a
                // 130pt cover, where its labels broke mid-word.
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    hero
                    actionRow
                }
                if let description = book.description, !description.isEmpty {
                    // Server descriptions carry markup. Rendered as a raw
                    // string, <p> and &amp; showed up on screen verbatim.
                    Text(HTMLText.attributed(description))
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
                if !book.tags.isEmpty { tags }
                editions
                facts
                externalRatings
                relatedRails
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .navigationTitle(book.title)
        // Writing a position moves the status server-side, so the shelf shown
        // here is stale after a reading session unless it is re-read.
        .task { await app.refresh(book: book) }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsReader) {
            if let session = app.session {
                ReaderScreen(book: book, session: session)
            }
        }
        #endif
        .onChange(of: app.downloadedUUIDs, initial: true) { refreshDownloaded() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Metrics.spacing16) {
            CoverImage(book: book, session: app.session)
                .frame(width: 130)

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(book.title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                Text(book.byline)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                if !book.narrators.isEmpty {
                    Text("Narrated by " + book.narrators.map(\.name).joined(separator: ", "))
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
                ratingControl
                // Wrapping, not a fixed row: "Readaloud · 5h 4m" beside a
                // status pill overflows a phone column and breaks mid-word.
                FlowRow(spacing: Metrics.spacing8) {
                    statusControl
                    formatBadges
                }
                if let progress = book.progress, progress > 0 {
                    ProgressBar(value: progress).frame(maxWidth: 200)
                    Text("\(ReadingProgress.percent(progress))% complete")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// What the book screen offers, and why it is not a fixed pair of buttons.
    ///
    /// `FlowRow` rather than an `HStack`: it proposes an unspecified width to
    /// each child, so a capsule renders at its natural size and wraps to the
    /// next line when there is no room — which is what has to happen at an
    /// accessibility text size, where a fixed row would simply clip.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            FlowRow(spacing: Metrics.spacing12) {
                primaryControl
                listenButton
            }
            // The reason a download failed existed only in an accessibility
            // label; a sighted reader saw a button that did nothing twice.
            if let detail = primaryAction?.detail {
                Text(detail).font(Typography.caption).foregroundStyle(Palette.alert)
            }
            // Set in AppModel and, until now, rendered by nothing at all — so a
            // Listen tap that failed was completely silent.
            if let error = app.listeningError {
                Text(error).font(Typography.caption).foregroundStyle(Palette.alert)
            }
        }
    }

    /// The one control whose label follows the download state.
    private var primaryAction: BookPrimaryAction? {
        BookPrimaryAction.resolve(
            book: book,
            state: app.downloads.flatMap { $0.state(for: .init(bookUUID: book.uuid, format: preferredFormat ?? .ebook)) },
            isDownloaded: preferredFormat.map { downloaded.contains($0) } ?? false,
        )
    }

    private var preferredFormat: BookContentService.Format? {
        BookContentService.preferredReadingFormat(for: book)
    }

    /// Which editions are on disk.
    ///
    /// Held rather than asked per render: `isDownloaded` is a `fileExists` and
    /// is not observable, so a delete performed on the downloads screen would
    /// otherwise never reach an already-open book screen — and asking inside
    /// the body meant a syscall per edition per frame.
    private func refreshDownloaded() {
        guard let session = app.session else { downloaded = []; return }
        let content = BookContentService(client: session.client)
        downloaded = Set(BookContentService.Format.allCases.filter {
            content.isDownloaded(book, format: $0)
        })
    }

    @ViewBuilder
    private var primaryControl: some View {
        if let action = primaryAction, let session = app.session {
            switch action.intent {
            case .openReader:
                #if os(iOS)
                // Presented, not pushed. Inside the tab's NavigationStack the
                // reader inherits the tab bar and its accessory slot, whose
                // glass capsule draws over the page's own footer — and the
                // navigation stack's edge-swipe pops the book shut mid-page.
                // Outside it, the page owns the whole screen.
                Button {
                    showsReader = true
                } label: {
                    PrimaryCapsule(action: action)
                }
                .buttonStyle(.plain)
                #else
                NavigationLink {
                    ReaderScreen(book: book, session: session)
                } label: {
                    PrimaryCapsule(action: action)
                }
                .buttonStyle(.plain)
                #endif
            case .startDownload, .pauseDownload, .resumeDownload:
                Button {
                    perform(action)
                } label: {
                    PrimaryCapsule(action: action)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func perform(_ action: BookPrimaryAction) {
        let job = DownloadManager.Job(bookUUID: book.uuid, format: action.format)
        switch action.intent {
        case .openReader: break
        case .startDownload: Task { await app.download(book, format: action.format) }
        case .pauseDownload: app.downloads?.pause(job)
        case .resumeDownload: Task { await app.resumeDownload(job) }
        }
    }

    /// Plays the audiobook without opening the reader.
    ///
    /// Offered for readaloud books too: wanting to hear a book while driving or
    /// walking is not the same as wanting the text on screen, and it is the
    /// only mode CarPlay can offer at all.
    @ViewBuilder
    private var listenButton: some View {
        // Readaloud counts: the doc comment above has always claimed it did,
        // but the gate only ever looked at `audiobook`, so a readaloud-only
        // book got no Listen button at all.
        if book.servableFormats.contains(.audiobook) || book.servableFormats.contains(.readaloud) {
            Button {
                Task {
                    await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "headphones").font(.system(size: 14, weight: .semibold))
                    Text(app.listeningBook?.uuid == book.uuid ? "Playing" : "Listen")
                }
                .font(Typography.headline)
                .padding(.horizontal, Metrics.spacing16)
                .padding(.vertical, Metrics.spacing8)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.borderStrong, lineWidth: 1))
                .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
        }
    }

    /// The primary control's face. One definition, used by both the
    /// `NavigationLink` that opens the reader and the `Button` that does
    /// everything else.
    private struct PrimaryCapsule: View {
        let action: BookPrimaryAction
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            HStack(spacing: Metrics.spacing8) {
                if let fraction = action.fraction, action.isDeterminate {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.35), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(.white, style: .init(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                } else if !action.isDeterminate {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                // At an accessibility size "Download · 312 MB" is wider than the
                // screen. Dropping the suffix is honest; shrinking the type of a
                // primary action is not.
                Text(action.title(compact: dynamicTypeSize.isAccessibilitySize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Typography.headline)
            .padding(.horizontal, Metrics.spacing24)
            .padding(.vertical, Metrics.spacing8)
            .background(Palette.tangerine, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel(action.accessibilityLabel)
        }
    }

    /// This user's own rating, tappable. Tapping the current score clears it,
    /// which is the only way to un-rate something without a separate control.
    private var ratingControl: some View {
        let mine = app.ratings[book.uuid]
        return HStack(spacing: Metrics.spacing4) {
            ForEach(1 ... 5, id: \.self) { star in
                Button {
                    Task { await app.setRating(mine == Double(star) ? nil : Double(star), for: book) }
                } label: {
                    Image(systemName: Double(star) <= (mine ?? 0) ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(mine == nil ? Palette.inkQuaternary : Palette.tangerine)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
            }
            if let serverAverage = book.rating, mine == nil {
                Text(String(format: "%.1f average", serverAverage))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    /// The shelf this book sits on, changeable in place.
    private var statusControl: some View {
        Menu {
            ForEach(app.statuses) { status in
                Button {
                    Task { await app.setStatus(status, for: book) }
                } label: {
                    if status.uuid == book.status?.uuid {
                        Label(status.name, systemImage: "checkmark")
                    } else {
                        Text(status.name)
                    }
                }
            }
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: Self.symbol(for: book.status?.name))
                    .font(.system(size: 11))
                Text(book.status?.name ?? "Set status")
                    .font(Typography.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .fixedSize()
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, 4)
            .background(Palette.surfaceRaised, in: Capsule())
            .foregroundStyle(Palette.inkSecondary)
        }
        .disabled(app.statuses.isEmpty)
    }

    static func symbol(for status: String?) -> String {
        switch status {
        case Status.readingName: "book"
        case Status.readName: "checkmark.circle"
        default: "bookmark"
        }
    }

    /// Reads from `servableFormats`, so a badge cannot promise a "Readaloud ·
    /// 5h 4m" two inches above an Editions row saying "Missing on server".
    @ViewBuilder
    private var formatBadges: some View {
        let formats = book.servableFormats
        if formats.contains(.readaloud) {
            badge("Readaloud", duration: book.readaloud?.duration)
        } else if formats.contains(.audiobook) {
            badge("Audiobook", duration: book.audiobook?.duration)
        }
        if formats.contains(.ebook) {
            badge("Ebook", pages: book.ebook?.pageCount)
        }
    }

    private func badge(_ title: String, duration: Double? = nil, pages: Int? = nil) -> some View {
        var text = title
        if let duration { text += " · " + Self.durationText(duration) }
        if let pages { text += " · \(pages) pages" }
        return Text(text)
            .font(Typography.caption)
            .fixedSize()
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, 3)
            .background(Palette.surfaceRaised, in: Capsule())
            .foregroundStyle(Palette.inkSecondary)
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Tags").overlineStyle()
            FlowRow(spacing: Metrics.spacing8) {
                ForEach(book.tags) { tag in
                    Text(tag.name)
                        .font(Typography.caption)
                        .padding(.horizontal, Metrics.spacing8)
                        .padding(.vertical, 4)
                        .background(Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }

    /// Storyteller keeps up to three editions of a book; showing which exist
    /// answers "can I listen to this" without opening it.
    private var editions: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Editions").overlineStyle()
            VStack(spacing: 1) {
                if book.availableFormats.isEmpty {
                    // Was a header over a blank rounded rectangle.
                    editionNote("This book has no editions on the server yet.")
                } else if book.servableFormats.isEmpty {
                    editionNote("Every edition is missing on the server.")
                }
                if let ebook = book.ebook {
                    editionRow("Ebook", format: .ebook,
                               detail: ebook.isEpub2 == true ? "EPUB 2" : "EPUB 3",
                               size: ebook.fileSize, missing: ebook.missing == true)
                }
                if let audiobook = book.audiobook {
                    editionRow("Audiobook", format: .audiobook,
                               detail: Self.durationText(audiobook.duration ?? 0),
                               size: audiobook.fileSize, missing: audiobook.missing == true)
                }
                if let readaloud = book.readaloud {
                    editionRow(
                        "Readaloud", format: .readaloud,
                        detail: readaloud.isAligned
                            ? Self.durationText(readaloud.duration ?? 0)
                            : (readaloud.status ?? "processing").capitalized,
                        size: readaloud.fileSize, missing: readaloud.missing == true,
                    )
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }

    private func editionRow(
        _ title: String, format: BookContentService.Format,
        detail: String, size: Int?, missing: Bool,
    ) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Text(title).font(Typography.callout).foregroundStyle(Palette.ink)
            Spacer()
            if missing {
                // The server tracks files that vanished from disk; saying so
                // beats a download that fails for no visible reason.
                Text("Missing on server")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.alert)
            } else {
                Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                if let size {
                    Text(Self.sizeText(size)).font(Typography.caption).foregroundStyle(Palette.inkQuaternary)
                }
                // State, not a control. The 17pt glyph that used to sit here
                // was the only way to fetch a book and had a tap target under
                // 44pt — which is what testers were describing.
                Text(DownloadStatusText.short(
                    app.downloads?.state(for: .init(bookUUID: book.uuid, format: format)),
                    isDownloaded: downloaded.contains(format)))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                editionMenu(for: format)
            }
        }
        .padding(Metrics.spacing12)
    }

    private func editionNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacing12)
    }

    /// Per-edition control, behind a visible affordance.
    ///
    /// A context menu alone would have been the only route anywhere in the app
    /// to fetch the audiobook edition for offline listening — the downloads
    /// screen only lists and removes — and the primary always acts on the
    /// reading edition. An invisible gesture is not an answer to a complaint
    /// that the control was impossible to find.
    @ViewBuilder
    private func editionMenu(for format: BookContentService.Format) -> some View {
        #if !os(tvOS)
        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        let state = app.downloads?.state(for: job)
        let onDisk = downloaded.contains(format)

        Menu {
            if let state, state.isActive {
                Button("Pause download", systemImage: "pause.circle") { app.downloads?.pause(job) }
            } else if case .paused = state {
                Button("Resume download", systemImage: "play.circle") {
                    Task { await app.resumeDownload(job) }
                }
            } else if !onDisk {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await app.download(book, format: format) }
                }
            }
            if state?.isFailure == true {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await app.download(book, format: format) }
                }
            }
            if onDisk {
                Button("Remove download", systemImage: "trash", role: .destructive) {
                    app.removeDownload(book, format: format)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(Palette.tangerine)
                // The row's own padding sits outside the control, so without
                // this the tap target was the glyph's 17pt bounds.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(format.rawValue.capitalized) options")
        #endif
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Details").overlineStyle()
            VStack(spacing: 1) {
                if let series = book.series.first {
                    factRow("Series", series.position.map { "\(series.name) · \(Self.positionText($0))" } ?? series.name)
                }
                if let published = book.publicationDate?.value {
                    factRow("Published", published.formatted(.dateTime.year()))
                }
                if let language = book.language { factRow("Language", language.uppercased()) }
                if !book.collections.isEmpty {
                    factRow("Collections", book.collections.map(\.name).joined(separator: ", "))
                }
                if let alignedWith = book.alignedWith { factRow("Aligned with", alignedWith) }
                ForEach(namedIdentifiers) { identifier in
                    if let url = identifier.url {
                        // The server configures the URL template per identifier
                        // type, so a link only appears where it actually leads
                        // somewhere.
                        Link(destination: url) {
                            factRow(identifier.label, identifier.value ?? "", showsLink: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        factRow(identifier.label, identifier.value ?? "")
                    }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }

    /// Identifiers the server holds (ISBN, ASIN, Audible), ready for display.
    private var namedIdentifiers: [Identifier] {
        book.identifiers.filter { !($0.value ?? "").isEmpty }
    }

    /// Ratings gathered from elsewhere, shown in the source's own terms.
    ///
    /// A source states its own scale, so nothing is rescaled to five stars: a
    /// reader who knows Hardcover expects Hardcover's number.
    @ViewBuilder
    private var externalRatings: some View {
        let ratings = book.externalData ?? []
        if !ratings.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("ELSEWHERE").font(Typography.overline).foregroundStyle(Palette.inkTertiary)
                HStack(spacing: Metrics.spacing8) {
                    ForEach(ratings) { rating in
                        let chip = HStack(spacing: 5) {
                            Image(systemName: rating.sourceRatingIcon == "star" ? "star.fill" : "circle.fill")
                                .font(.system(size: 10))
                            Text(rating.sourceName ?? "Rating").font(Typography.caption)
                            Text(rating.ratingText).font(Typography.caption.weight(.semibold))
                        }
                        .padding(.horizontal, Metrics.spacing12)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color(hex: rating.sourceColor) ?? Palette.inkSecondary)
                        .background(
                            Capsule().fill((Color(hex: rating.sourceColor) ?? Palette.moss).opacity(0.12)),
                        )

                        if let source = rating.sourceUrl, let url = URL(string: source) {
                            Link(destination: url) { chip }.buttonStyle(.plain)
                        } else {
                            chip
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String, showsLink: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).font(Typography.footnote).foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Metrics.spacing16)
            Text(value)
                .font(Typography.footnote)
                .foregroundStyle(showsLink ? Palette.tangerine : Palette.ink)
                .multilineTextAlignment(.trailing)
            if showsLink {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.tangerine)
            }
        }
        .padding(Metrics.spacing12)
    }

    /// The design's Explore rails, all derived from the one catalogue fetch.
    private var relatedRails: some View {
        let derivation = app.derivation
        return VStack(alignment: .leading, spacing: Metrics.spacing24) {
            if let series = book.series.first,
               let siblings = derivation.bySeries[series.name]?.filter({ $0.uuid != book.uuid }),
               !siblings.isEmpty {
                rail("The \(series.name)", books: siblings)
            }
            if let author = book.authors.first,
               let others = derivation.byAuthor[author.name]?.filter({ $0.uuid != book.uuid }),
               !others.isEmpty {
                rail("More by \(author.name)", books: others)
            }
            if let narrator = book.narrators.first,
               let others = derivation.byNarrator[narrator.name]?.filter({ $0.uuid != book.uuid }),
               !others.isEmpty {
                rail("Narrated by \(narrator.name)", books: others)
            }
        }
    }

    private func rail(_ title: String, books: [Book]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(title).overlineStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    ForEach(books) { sibling in
                        NavigationLink {
                            BookDetailView(book: sibling)
                        } label: {
                            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                                CoverImage(book: sibling, session: app.session).frame(width: 84)
                                Text(sibling.title)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .frame(width: 84, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    static func positionText(_ position: Double) -> String {
        position == position.rounded() ? "Book \(Int(position))" : "Book \(position)"
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Wraps its children onto as many lines as needed. Used for tag chips, where
/// a fixed grid would leave ragged gaps between short and long names.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

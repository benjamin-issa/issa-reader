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
    let book: Book

    public init(book: Book) {
        self.book = book
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing32) {
                hero
                if let description = book.description, !description.isEmpty {
                    Text(description)
                        .font(Typography.body)
                        .foregroundStyle(Palette.inkSecondary)
                }
                if !book.tags.isEmpty { tags }
                editions
                facts
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
                    Text("\(Int(progress * 100))% complete")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
                readButton
            }
            Spacer(minLength: 0)
        }
    }

    private var readButton: some View {
        Group {
            if let session = app.session {
                NavigationLink {
                    ReaderView(book: book, session: session)
                } label: {
                    Text(book.progress ?? 0 > 0 ? "Resume" : "Read")
                        .font(Typography.headline)
                        .padding(.horizontal, Metrics.spacing24)
                        .padding(.vertical, Metrics.spacing8)
                        .background(Palette.tangerine, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, Metrics.spacing4)
            }
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

    @ViewBuilder
    private var formatBadges: some View {
        if book.hasReadalong {
            badge("Readaloud", duration: book.readaloud?.duration)
        } else if book.audiobook != nil {
            badge("Audiobook", duration: book.audiobook?.duration)
        }
        if book.ebook != nil {
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
                    .foregroundStyle(Color(hex: 0x7A2F2A))
            } else {
                Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                if let size {
                    Text(Self.sizeText(size)).font(Typography.caption).foregroundStyle(Palette.inkQuaternary)
                }
                downloadControl(for: format)
            }
        }
        .padding(Metrics.spacing12)
    }

    /// One control that reads as its own state: download, progress, or done.
    @ViewBuilder
    private func downloadControl(for format: BookContentService.Format) -> some View {
        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        let state = app.downloads?.state(for: job)
        let onDisk = app.session.map {
            BookContentService(client: $0.client).isDownloaded(book, format: format)
        } ?? false

        if onDisk, state == nil || state == .finished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Palette.moss)
                .accessibilityLabel("Downloaded")
        } else if let state, state.isActive {
            Button {
                app.downloads?.pause(job)
            } label: {
                ZStack {
                    Circle().stroke(Palette.border, lineWidth: 2).frame(width: 20, height: 20)
                    Circle()
                        .trim(from: 0, to: state.fraction)
                        .stroke(Palette.tangerine, style: .init(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                    Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(Palette.inkTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause download, \(Int(state.fraction * 100)) percent")
        } else if case let .failed(reason) = state {
            Button {
                Task { await app.download(book, format: format) }
            } label: {
                Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0x7A2F2A))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download failed: \(reason). Try again")
        } else {
            Button {
                Task { await app.download(book, format: format) }
            } label: {
                Image(systemName: state == nil ? "arrow.down.circle" : "play.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.tangerine)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(format.rawValue)")
        }
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

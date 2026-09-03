import IssaCore
import IssaUI
import SwiftUI

/// The Library's Browse screen: a vertical scroll of horizontal rails.
///
/// With resuming gone to the Reading tab, the Library's job is looking around
/// — recent arrivals, your series, what has audio, and the tags you use most,
/// each with a "See all" into the flat grid on the matching shelf. Every list
/// is `LibraryRails`, derived in the model; a rail with nothing on it is
/// omitted rather than shown empty. Placed inside `LibraryView`'s scroll view,
/// beneath the header that owns search and the Browse / shelf chips.
struct BrowseView: View {
    @Environment(AppModel.self) private var app

    private var rails: LibraryRails { app.rails }

    private var hasRails: Bool {
        !rails.recentlyAdded.isEmpty || !rails.series.isEmpty
            || !rails.withAudio.isEmpty || !rails.tagRails.isEmpty
    }

    var body: some View {
        if hasRails {
            if !rails.recentlyAdded.isEmpty {
                BookRail(title: "Recently added", books: rails.recentlyAdded, coverWidth: 74) {
                    app.showAllBooks(shelf: .all, sort: .added)
                }
            }
            if !rails.series.isEmpty {
                SeriesRail(series: rails.series)
            }
            if !rails.withAudio.isEmpty {
                BookRail(title: "With audio", books: rails.withAudio, coverWidth: 74) {
                    app.showAllBooks(shelf: .withNarration)
                }
            }
            ForEach(rails.tagRails) { rail in
                BookRail(title: rail.tag, books: rail.books, coverWidth: 74) {
                    app.showAllBooks(shelf: .all, tags: [rail.tag])
                }
            }
        } else if !app.books.isEmpty {
            // A library of undated, untagged, unseriesed, text-only books has
            // nothing to browse by. Say so, and offer the grid — never a
            // blank page under a chip reading "Browse".
            PalettePlaceholder(
                symbol: "square.grid.2x2",
                title: "Nothing to browse by yet",
                message: "Series, tags and audio will appear here as your library grows.",
                actionTitle: "Show all books",
                action: { app.showAllBooks(shelf: .all) },
            )
        }
    }
}

/// Your series as stacked-cover tiles, with a "See all" to the full list.
struct SeriesRail: View {
    let series: [SeriesGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Series").overlineStyle()
                Spacer()
                NavigationLink {
                    SeriesListView()
                } label: {
                    Text("See all")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.tangerinePressed)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all series")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    ForEach(series) { group in
                        SeriesTile(series: group)
                    }
                }
                // The rotated back cover pokes above the tile's frame.
                .padding(.top, Metrics.spacing4)
            }
            // Edge to edge, with the margin put back as a content inset. Inside
            // the screen's padding the rail was clipped 16pt short of the
            // glass, so a shelf that continues off-screen looked like one that
            // had been cut off. The filter chips already do this.
            .scrollClipDisabled()
            .padding(.horizontal, -Metrics.screenMargin)
            .contentMargins(.horizontal, Metrics.screenMargin, for: .scrollContent)
        }
    }
}

/// One series: its first two covers fanned, a count, its name. Opens the
/// series in reading order.
struct SeriesTile: View {
    @Environment(AppModel.self) private var app
    let series: SeriesGroup

    private static let width: CGFloat = 104
    private static let coverWidth: CGFloat = 60

    var body: some View {
        NavigationLink {
            SeriesView(name: series.name)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                covers
                Text(series.name)
                    .font(Typography.serif(13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .frame(width: Self.width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(series.name), \(series.books.count) books")
    }

    /// The second book tilted behind, the first in front, the count on top.
    /// Every group has at least two books — a one-book series is not one.
    private var covers: some View {
        ZStack(alignment: .topLeading) {
            if series.books.count > 1 {
                CoverImage(book: series.books[1], session: app.session)
                    .frame(width: Self.coverWidth)
                    .rotationEffect(.degrees(-4))
                    .offset(y: 6)
            }
            CoverImage(book: series.books[0], session: app.session)
                .frame(width: Self.coverWidth)
                .offset(x: 22)
        }
        .frame(width: Self.width, height: Self.coverWidth / Metrics.coverAspect + 6, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Text("\(series.books.count)")
                .font(Typography.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Metrics.spacing8)
                .padding(.vertical, 2)
                .background(Palette.slate, in: Capsule())
        }
    }
}

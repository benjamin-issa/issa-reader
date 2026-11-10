import IssaCore
import IssaUI
import SwiftUI
import WidgetKit

// The widget's views and the data they draw, apart from the `@main` bundle so
// that `IssaSharedTests` can compile and render them (see WidgetRenderTests).

/// One other book as a family draws it: the record, its cover if the file has
/// landed, and where a tap on it goes.
struct OtherEntry: Hashable {
    let book: OtherBook
    let cover: Data?

    /// Each book's own link, made from its own id. Tested by identity, on
    /// rows other than the first: "every row acts on the first" has shipped.
    var url: URL? { CurrentBookSnapshotStore.deepLink(bookID: book.bookID) }
}

struct CurrentBookEntry: TimelineEntry {
    let date: Date
    let snapshot: CurrentBookSnapshot
    let cover: Data?
    /// What the family draws and no more: medium one, large up to four, the
    /// rest none (the provider decodes nothing a family does not show).
    var others: [OtherEntry] = []
    /// No book in progress: a fresh install, or after a sign-out. The views
    /// draw an empty state instead of reading `snapshot`.
    var isEmpty = false
}

extension CurrentBookEntry {
    /// The snapshot on disk, with the covers the family draws and no others —
    /// nil when there is no snapshot.
    ///
    /// Only the families that draw a cover pay to load it, and only as many of
    /// the others as they show: medium one, large up to four, the lock screen
    /// none. Extensions are held to roughly 30 MB.
    static func current(family: WidgetFamily) -> CurrentBookEntry? {
        guard let snapshot = CurrentBookSnapshotStore.read() else { return nil }
        let others = snapshot.others.prefix(WidgetShelf.coversDrawn(by: family)).map {
            // Each file is its book's by name, so there is no identity to
            // check: a file that is not there yet is the placeholder.
            OtherEntry(book: $0, cover: CurrentBookSnapshotStore.readOtherCover(bookID: $0.bookID))
        }
        return CurrentBookEntry(
            date: snapshot.updatedAt, snapshot: snapshot,
            // Only if it is this book's. The cover is one shared file with no
            // identity of its own, and it is written after the snapshot — so
            // between the two writes it still holds the previous book's
            // jacket, and drawing it would put one book's text over another's
            // artwork. The placeholder is the honest answer for that moment.
            cover: WidgetShelf.drawsCover(family) && snapshot.hasMatchingCover
                ? CurrentBookSnapshotStore.readCover() : nil,
            others: others)
    }
}

/// What each family draws of the other books, apart from the views so that a
/// test can ask it.
enum WidgetShelf {
    /// Medium's one "Also reading" book.
    static func alsoReading(in entry: CurrentBookEntry) -> OtherEntry? { entry.others.first }
    /// Large's row.
    static func alsoInProgress(in entry: CurrentBookEntry) -> [OtherEntry] {
        Array(entry.others.prefix(OtherBook.limit))
    }
    /// How many of the other books a family draws a cover for.
    static func coversDrawn(by family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 1
        case .systemLarge: OtherBook.limit
        default: 0
        }
    }
    /// Whether a family draws the current book's cover.
    static func drawsCover(_ family: WidgetFamily) -> Bool {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge: true
        default: false
        }
    }
}

/// The progress line every family prints: the app's own percent and its own
/// "6h 12m left", joined once.
extension CurrentBookSnapshot {
    var progressLine: String {
        remainingText.map { "\(percent)% · \($0)" } ?? "\(percent)%"
    }

    var accessibilityDescription: String {
        var parts = [title]
        if !author.isEmpty { parts.append("by \(author)") }
        parts.append("\(percent) percent through")
        if let remainingText { parts.append(remainingText) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The view

/// `widgetFamily` and `widgetRenderingMode` are read-only environment values —
/// WidgetKit sets them — so a test, which has no WidgetKit host, says what it
/// wants through these instead. Unset in a real widget.
struct WidgetFamilyOverrideKey: EnvironmentKey { static let defaultValue: WidgetFamily? = nil }
struct WidgetAccentedOverrideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var widgetFamilyOverride: WidgetFamily? {
        get { self[WidgetFamilyOverrideKey.self] }
        set { self[WidgetFamilyOverrideKey.self] = newValue }
    }
    var widgetAccentedOverride: Bool {
        get { self[WidgetAccentedOverrideKey.self] }
        set { self[WidgetAccentedOverrideKey.self] = newValue }
    }
}

struct CurrentBookView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetFamilyOverride) private var override
    let entry: CurrentBookEntry
    private var family: WidgetFamily { override ?? widgetFamily }

    var body: some View {
        if entry.isEmpty {
            EmptyWidgetView(family: family)
        } else {
            switch family {
            case .accessoryInline:
                // One line, no room for anything but the fact.
                Text("\(entry.snapshot.percent)% · \(entry.snapshot.title)")
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Gauge(value: entry.snapshot.progress) {
                        Image(systemName: entry.snapshot.isPlaying ? "headphones" : "book")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                }
            case .accessoryRectangular:
                RectangularWidgetView(snapshot: entry.snapshot)
            case .systemSmall:
                SmallWidgetView(entry: entry)
            case .systemMedium:
                MediumWidgetView(entry: entry)
            case .systemLarge, .systemExtraLarge:
                LargeWidgetView(entry: entry)
            @unknown default:
                SmallWidgetView(entry: entry)
            }
        }
    }
}

// MARK: - Empty

/// What an installed widget says when there is no book in progress — which is
/// the normal state on a fresh install and after a sign-out, not an error
/// worth dressing up.
struct EmptyWidgetView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("No book in progress")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "book.closed")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing in progress").font(.headline).lineLimit(1)
                Text("Open a book to see it here").font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack(alignment: .topTrailing) {
                VStack(spacing: Metrics.spacing8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: family == .systemSmall ? 26 : 32))
                        .foregroundStyle(Palette.inkSecondary)
                    Text("Nothing in progress")
                        .font(Typography.serif(family == .systemSmall ? 15 : 17, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    if family != .systemSmall {
                        Text("Open a book to see it here")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if family != .systemSmall { WidgetLogo().padding(family == .systemLarge ? 14 : 12) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Pieces

/// Where the asset catalog is: the extension's bundle, or the test bundle that
/// compiles these same files.
final class WidgetBundleToken {
    static var bundle: Bundle { Bundle(for: WidgetBundleToken.self) }
}

/// The app's icon, at 22 pt with a continuous corner.
///
/// The catalog holds the square tile (no corner is baked in, per ICON.md), a
/// dark-appearance variant, and a monochrome one for the accented (tinted)
/// Home Screen, where the system recolours it: the full-colour tile there
/// would become a solid blob.
struct WidgetLogo: View {
    @Environment(\.widgetRenderingMode) private var widgetMode
    @Environment(\.widgetAccentedOverride) private var accentedOverride

    var body: some View {
        Group {
            if accentedOverride || widgetMode == .accented {
                Image("WidgetLogoTinted", bundle: WidgetBundleToken.bundle)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
            } else {
                Image("WidgetLogo", bundle: WidgetBundleToken.bundle)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A 4 pt bar. Tangerine on the surface, or on the haze.
struct WidgetBar: View {
    let value: Double
    var fill: Color = Palette.tangerine
    var track: Color = Palette.border
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill)
                    .frame(width: max(height / 2, geo.size.width * (value.asProgression ?? 0)))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
    }
}

/// A tappable book: its own deep link, or nothing but the content if the id
/// cannot make one.
struct BookLink<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: Content

    var body: some View {
        if let url {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

// MARK: - Small

struct SmallWidgetView: View {
    let entry: CurrentBookEntry
    var style: SmallCoverStyle = .current

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Full bleed: the widget's own margins are off
                // (`contentMarginsDisabled`), so this is the whole square.
                CoverArt(
                    data: entry.cover, size: geo.size,
                    fit: style == .fill ? .fill : .fitOverBlur,
                    placeholderTitle: entry.snapshot.title, glyphSize: 22)
                haze
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The cover carries its own title, so none is drawn over it; the title
        // is what VoiceOver reads instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.snapshot.accessibilityDescription)
    }

    /// Black, never tinted: it sits over any jacket, and a neutral one is the
    /// only haze that reads on a light cover and a busy one alike.
    private var haze: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.66), location: 0.5),
                    .init(color: .black.opacity(0.84), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
            progressRow
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .frame(height: 52)
    }

    private var progressRow: some View {
        let bar = WidgetBar(value: entry.snapshot.progress, fill: Palette.tangerine, track: .white.opacity(0.3))
        let text = Text(entry.snapshot.progressLine)
            .font(Typography.overline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
        return ViewThatFits(in: .horizontal) {
            // The usual row: a bar, and the line beside it. With a long
            // remaining time ("12h 40m left") the bar would shrink to a
            // stub, so below a readable length the bar goes above the text.
            HStack(spacing: 8) {
                bar.frame(minWidth: 36)
                text
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                bar
                text
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Medium

struct MediumWidgetView: View {
    let entry: CurrentBookEntry

    private var snapshot: CurrentBookSnapshot { entry.snapshot }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let coverWidth = snapshot.coverIsSquare ? height : height * Metrics.coverAspect
            HStack(spacing: 0) {
                // Flush to the left, top and bottom edges; no corner of its
                // own, because the widget's rounds it.
                // Fit over a blur, not fill: a jacket that is not quite 2:3 (a
                // good many are not) would lose the printed edge of its title.
                CoverArt(
                    data: entry.cover, size: CGSize(width: coverWidth, height: height),
                    fit: .fitOverBlur, glyphSize: 26)
                column(card: WidgetShelf.alsoReading(in: entry), square: snapshot.coverIsSquare)
            }
            .overlay(alignment: .topTrailing) { WidgetLogo().padding(.top, 12).padding(.trailing, 12) }
        }
        .accessibilityElement(children: .contain)
    }

    private func column(card: OtherEntry?, square: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Two lines, or three beside a square jacket, whose column is
            // narrower.
            Text(snapshot.title)
                .font(Typography.bookTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(square ? (card == nil ? 4 : 3) : 2)
                // A square jacket leaves a 108 pt measure for the title, so it
                // may shrink further there than the 0.85 elsewhere.
                .minimumScaleFactor(square ? 0.75 : 0.85)
                // The logo is 22 wide and 12 in; keep 24 clear of it (16 where
                // the column is already narrow).
                .padding(.trailing, 22 + 12 + (square ? 16 : 24) - 14)
            if !snapshot.author.isEmpty {
                Text(snapshot.author)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            if card == nil, let chapter = snapshot.displayChapter {
                // With no card to fill the middle of the column, the chapter
                // does, rather than leaving a hole between the author and the bar.
                Text(chapter)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2)
                    .padding(.top, 6)
            }
            Spacer(minLength: 4)
            progressRow
            if let card {
                BookLink(url: card.url) { AlsoReadingCard(other: card) }
                    .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            WidgetBar(value: snapshot.progress)
            Text(snapshot.progressLine)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// "Also reading": a small card for the next book in progress. The whole card
/// is the tap target — the caller wraps it in a `BookLink`.
struct AlsoReadingCard: View {
    let other: OtherEntry

    var body: some View {
        HStack(spacing: 8) {
            CoverArt(data: other.cover, size: CGSize(width: 24, height: 36), fit: .fitOverBlur, glyphSize: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("ALSO READING")
                    .font(Typography.sans(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(other.book.title)
                    .font(Typography.serif(13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text("\(other.book.percent)%")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Also reading, \(other.book.title), \(other.book.percent) percent")
    }
}

// MARK: - Large

struct LargeWidgetView: View {
    let entry: CurrentBookEntry

    private var snapshot: CurrentBookSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let others = WidgetShelf.alsoInProgress(in: entry)
            if others.isEmpty { Spacer(minLength: 0) }
            top
                .frame(height: others.isEmpty ? 195 : 150, alignment: .top)
            if !others.isEmpty {
                Spacer(minLength: 10)
                Text("ALSO IN PROGRESS")
                    .font(Typography.sans(11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.bottom, 6)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(others, id: \.book.bookID) { other in
                        BookLink(url: other.url) { ShelfBook(other: other) }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            } else {
                // Centred: with no row the block is the whole widget.
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { WidgetLogo().padding(.top, 14).padding(.trailing, 14) }
        .accessibilityElement(children: .contain)
    }

    private var top: some View {
        let square = snapshot.coverIsSquare
        // With nothing else in progress the row is gone, and a 150 pt block
        // would leave two thirds of the widget empty: the book gets the room.
        let roomy = WidgetShelf.alsoInProgress(in: entry).isEmpty
        let scale: CGFloat = roomy ? 1.3 : 1
        let coverSize = square ? CGSize(width: 120 * scale, height: 120 * scale)
            : CGSize(width: 100 * scale, height: 150 * scale)
        return HStack(alignment: .top, spacing: 14) {
            CoverArt(data: entry.cover, size: coverSize, fit: .fitOverBlur, glyphSize: 26)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.title)
                    .font(Typography.bookTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(roomy ? 4 : 3)
                    .minimumScaleFactor(0.85)
                    .padding(.trailing, 22 + 24)
                if !snapshot.author.isEmpty {
                    Text(snapshot.author)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                if let chapter = snapshot.displayChapter {
                    Text(chapter)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    WidgetBar(value: snapshot.progress)
                    Text(snapshot.progressLine)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// One cover in large's row: its jacket with a thin bar along the bottom edge,
/// and its title, two lines, beneath.
struct ShelfBook: View {
    let other: OtherEntry
    static let size = CGSize(width: 70, height: 105)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(data: other.cover, size: Self.size, fit: .fitOverBlur, glyphSize: 18)
                .overlay(alignment: .bottom) {
                    WidgetBar(
                        value: other.book.progress, fill: Palette.tangerine,
                        track: .black.opacity(0.45), height: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(other.book.title)
                .font(Typography.serif(12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(width: Self.size.width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(other.book.title), \(other.book.percent) percent")
    }
}

// MARK: - Lock screen

struct RectangularWidgetView: View {
    let snapshot: CurrentBookSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.title)
                .font(Typography.serif(14, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            // Drawn, not a `ProgressView`: the same bar every family uses,
            // in the lock screen's primary style, thin.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.3))
                    Capsule().fill(.primary)
                        .frame(width: max(1.5, geo.size.width * (snapshot.progress.asProgression ?? 0)))
                        .widgetAccentable()
                }
            }
            .frame(height: 3)
            Text(snapshot.progressLine)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

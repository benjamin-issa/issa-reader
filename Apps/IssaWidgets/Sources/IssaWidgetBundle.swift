import IssaCore
import IssaUI
import SwiftUI
import WidgetKit

@main
struct IssaWidgetBundle: WidgetBundle {
    /// A widget extension is a separate process, so the app registering these
    /// at launch does nothing for it — every `Typography` token was quietly
    /// falling back to the system face, and `Font.custom` fails silently.
    init() { IssaFonts.register() }

    var body: some Widget {
        CurrentBookWidget()
    }
}

/// Reads a small snapshot the app writes to the shared App Group container.
///
/// The widget never opens the library database: extensions are held to roughly
/// 30 MB, and a snapshot read is bounded work. Progress that advances during
/// playback is rendered with a self-updating `ProgressView(timerInterval:)`
/// rather than by reloading the timeline, because WidgetKit enforces a minimum
/// spacing of about five minutes between reloads even while audio is playing.
struct CurrentBookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CurrentBook", provider: CurrentBookProvider()) { entry in
            CurrentBookView(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
                // Tapping the widget opens the book it is showing, not the
                // library — the widget exists because that is the book you are
                // in.
                .widgetURL(CurrentBookSnapshotStore.deepLink(bookID: entry.snapshot.bookID))
        }
        .configurationDisplayName("Currently Reading")
        .description("The book you're in, and how far through you are.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct CurrentBookEntry: TimelineEntry {
    let date: Date
    let snapshot: CurrentBookSnapshot
    let cover: Data?
}

struct CurrentBookProvider: TimelineProvider {
    func placeholder(in context: Context) -> CurrentBookEntry {
        CurrentBookEntry(
            date: .now,
            snapshot: CurrentBookSnapshot(
                bookID: "placeholder", title: "Piranesi", author: "Susanna Clarke",
                chapter: "Part 3 · The Tides", progress: 0.42, remaining: 8_280,
            ),
            cover: nil,
        )
    }

    private func currentEntry(fallback: CurrentBookEntry) -> CurrentBookEntry {
        guard let snapshot = CurrentBookSnapshotStore.read() else { return fallback }
        // Only the families that draw the cover pay to load it.
        return CurrentBookEntry(
            date: snapshot.updatedAt, snapshot: snapshot,
            cover: CurrentBookSnapshotStore.readCover(),
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CurrentBookEntry) -> Void) {
        completion(currentEntry(fallback: placeholder(in: context)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurrentBookEntry>) -> Void) {
        // WidgetKit enforces roughly a five-minute floor between reloads even
        // when an audio session exempts them from the daily budget, so a
        // ticking progress bar cannot come from reloads. Anything that must
        // move second by second uses a self-updating timer view instead.
        let entry = currentEntry(fallback: placeholder(in: context))
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct CurrentBookView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CurrentBookEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            // One line, no room for anything but the fact.
            Text("\(Int(entry.snapshot.progress * 100))% · \(entry.snapshot.title)")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Gauge(value: entry.snapshot.progress) {
                    Image(systemName: entry.snapshot.isPlaying ? "headphones" : "book")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.title).font(.headline).lineLimit(1)
                if let chapter = entry.snapshot.chapter {
                    Text(chapter).font(.caption).lineLimit(1)
                }
                ProgressView(value: entry.snapshot.progress).tint(.primary)
            }
        case .systemSmall:
            small
        case .systemMedium, .systemLarge:
            withCover
        default:
            details
        }
    }

    /// The small widget: cover-led, with a ring rather than a bar.
    ///
    /// It used to fall through to `details`, which draws no cover at all — so
    /// the one family most people actually place was the only one that did not
    /// show the book. `details` is shared with `withCover`, so the ring has to
    /// live in its own layout rather than replacing the bar in place; the bar
    /// still belongs to medium and large.
    private var small: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(alignment: .top, spacing: Metrics.spacing8) {
                CoverThumb(data: entry.cover, isSquare: entry.snapshot.coverIsSquare)
                Spacer(minLength: 0)
                ProgressRingWidget(value: entry.snapshot.progress)
            }
            Spacer(minLength: 0)
            Text(entry.snapshot.title)
                .font(Typography.bookTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                // The cover and the ring are fixed sizes and the type is not,
                // so at an accessibility size the text was squeezed out of a
                // ~110pt box entirely. Shrinking secondary text is honest;
                // clipping it is not.
                .minimumScaleFactor(0.75)
            Text(entry.snapshot.subtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    /// Medium and large have room for the cover beside the text, which is what
    /// makes a shelf of widgets recognisable at a glance.
    private var withCover: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            if let data = entry.cover, let image = Image(widgetCover: data) {
                let width: CGFloat = family == .systemLarge ? 116 : 74
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Height as well as width. Fixing width alone let the row's
                    // height decide the rest, so a square jacket was scaled to
                    // cover it and then clipped — about 40% of the artwork on
                    // medium and 60% on large.
                    .frame(
                        width: width,
                        height: entry.snapshot.coverIsSquare ? width : width / Metrics.coverAspect)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
            }
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(entry.snapshot.title)
                .font(Typography.bookTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Text(entry.snapshot.author)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let chapter = entry.snapshot.chapter {
                Text(chapter)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(family == .systemLarge ? 3 : 1)
            }
            ProgressBarWidget(value: entry.snapshot.progress)
            HStack {
                Text("\(Int(entry.snapshot.progress * 100))%")
                Spacer()
                if let remaining = entry.snapshot.remaining {
                    Text(Self.remainingText(remaining) + " left")
                }
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
        }
    }
}

extension CurrentBookView {
    static func remainingText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

extension Image {
    /// Decodes the shared cover, failing quietly: a widget that traps on a
    /// half-written file is worse than one with no picture.
    init?(widgetCover data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #else
        return nil
        #endif
    }
}

/// The small family's cover, with something to show when there is not one.
///
/// Nil is the normal state on a first render, after a sign-out, and whenever a
/// publish failed — and the layout this replaced simply left a hole with the
/// ring pushed against it.
struct CoverThumb: View {
    let data: Data?
    let isSquare: Bool

    private var size: CGSize {
        isSquare ? CGSize(width: 52, height: 52) : CGSize(width: 40, height: 52)
    }

    var body: some View {
        Group {
            if let data, let image = Image(widgetCover: data) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Palette.surfaceRaised
                    Image(systemName: "book.closed")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.inkQuaternary)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
    }
}

/// A ring around the percentage, for the small family.
struct ProgressRingWidget: View {
    let value: Double

    var body: some View {
        ZStack {
            // Inset by half the stroke: `stroke` straddles the path, so a 4pt
            // line on the frame edge paints 2pt outside it.
            Circle().inset(by: 2).stroke(Palette.border, lineWidth: 4)
            Circle()
                .inset(by: 2)
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(Palette.tangerine, style: .init(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Rounded, matching the reader's own readout. Truncating showed
            // "99%" beside a ring that had visibly closed.
            Text("\(Int((value * 100).rounded()))%")
                .font(Typography.caption.weight(.semibold))
                // inkSecondary, not tangerinePressed: tangerine on this surface
                // is about 3.8:1, under the 4.5:1 floor for text this size.
                .foregroundStyle(Palette.inkSecondary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel("\(Int((value * 100).rounded())) percent through")
    }
}

struct ProgressBarWidget: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.border)
                Capsule().fill(Palette.tangerine)
                    .frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

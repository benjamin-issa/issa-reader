import IssaCore
import IssaUI
import SwiftUI
import WidgetKit

@main
struct IssaWidgetBundle: WidgetBundle {
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
        }
        .configurationDisplayName("Currently Reading")
        .description("The book you're in, and how far through you are.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct CurrentBookEntry: TimelineEntry {
    let date: Date
    let snapshot: CurrentBookSnapshot
}

struct CurrentBookProvider: TimelineProvider {
    func placeholder(in context: Context) -> CurrentBookEntry {
        CurrentBookEntry(date: .now, snapshot: CurrentBookSnapshot(
            bookID: "placeholder", title: "Piranesi", author: "Susanna Clarke",
            chapter: "Part 3 · The Tides", progress: 0.42, remaining: 8_280,
        ))
    }

    private func currentEntry(fallback: CurrentBookEntry) -> CurrentBookEntry {
        guard let snapshot = CurrentBookSnapshotStore.read() else { return fallback }
        return CurrentBookEntry(date: snapshot.updatedAt, snapshot: snapshot)
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
    let entry: CurrentBookEntry

    var body: some View {
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
                    .lineLimit(1)
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

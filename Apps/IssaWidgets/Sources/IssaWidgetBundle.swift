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
    let title: String
    let author: String
    let progress: Double
}

struct CurrentBookProvider: TimelineProvider {
    func placeholder(in context: Context) -> CurrentBookEntry {
        CurrentBookEntry(date: .now, title: "Piranesi", author: "Susanna Clarke", progress: 0.42)
    }

    func getSnapshot(in context: Context, completion: @escaping (CurrentBookEntry) -> Void) {
        completion(CurrentBookSnapshotStore.read() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurrentBookEntry>) -> Void) {
        let entry = CurrentBookSnapshotStore.read() ?? placeholder(in: context)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct CurrentBookView: View {
    let entry: CurrentBookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(entry.title)
                .font(Typography.bookTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Text(entry.author)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ProgressBarWidget(value: entry.progress)
            Text("\(Int(entry.progress * 100))%")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
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

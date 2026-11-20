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
/// 30 MB, and a snapshot read is bounded work. The timeline is one static
/// entry, refreshed a quarter of an hour later; between refreshes the app asks
/// for a reload only when the snapshot has meaningfully moved, because
/// WidgetKit budgets reloads in tens per day and enforces a floor of about five
/// minutes between them even while audio is playing. Progress does not tick on
/// its own — there is no self-updating timer view here.
struct CurrentBookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CurrentBookSnapshotStore.widgetKind, provider: CurrentBookProvider()) { entry in
            CurrentBookView(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
                // Tapping the widget opens the book it is showing, not the
                // library — the widget exists because that is the book you are
                // in. When there is no book, a nil URL just opens the app:
                // a link to a book that does not exist silently did nothing.
                .widgetURL(entry.isEmpty
                    ? nil : CurrentBookSnapshotStore.deepLink(bookID: entry.snapshot.bookID))
        }
        // The cover goes to the edge on small and medium, so each family lays
        // out its own padding (14 pt, per the design) instead of the system's.
        .contentMarginsDisabled()
        .configurationDisplayName("Currently Reading")
        .description("The book you're in, and how far through you are.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct CurrentBookProvider: TimelineProvider {
    /// The gallery sample. Only ever shown where `isPreview` is true — on the
    /// Home Screen this fictional book would masquerade as the user's real
    /// reading state, complete with a deep link to a book that does not exist.
    func placeholder(in context: Context) -> CurrentBookEntry {
        CurrentBookEntry(
            date: .now,
            snapshot: CurrentBookSnapshot(
                bookID: "placeholder", title: "Piranesi", author: "Susanna Clarke",
                chapter: "Part 3 · The Tides", progress: 0.42, remaining: 8_280,
            ),
            cover: nil,
            // Two others, so the gallery shows the whole design.
            others: [
                OtherEntry(book: OtherBook(bookID: "placeholder-1", title: "Jonathan Strange & Mr Norrell", progress: 0.18), cover: nil),
                OtherEntry(book: OtherBook(bookID: "placeholder-2", title: "The Left Hand of Darkness", progress: 0.64), cover: nil),
                OtherEntry(book: OtherBook(bookID: "placeholder-3", title: "Middlemarch", progress: 0.07), cover: nil),
            ],
        )
    }

    /// What an installed widget shows when no snapshot exists on disk.
    private func emptyEntry() -> CurrentBookEntry {
        CurrentBookEntry(
            date: .now,
            snapshot: CurrentBookSnapshot(bookID: "", title: "", author: "", progress: 0),
            cover: nil,
            isEmpty: true,
        )
    }

    private func currentEntry(fallback: CurrentBookEntry, family: WidgetFamily) -> CurrentBookEntry {
        CurrentBookEntry.current(family: family) ?? fallback
    }

    func getSnapshot(in context: Context, completion: @escaping (CurrentBookEntry) -> Void) {
        // The sample book only where this is genuinely a preview — the widget
        // gallery. A transient snapshot for an installed widget gets the same
        // honest empty state the timeline does.
        let fallback = context.isPreview ? placeholder(in: context) : emptyEntry()
        completion(currentEntry(fallback: fallback, family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurrentBookEntry>) -> Void) {
        // One entry, a quarter of an hour apart. WidgetKit enforces roughly a
        // five-minute floor between reloads even when an audio session exempts
        // them from the daily budget, so a ticking progress bar cannot come
        // from reloads, and the app only asks for one when the snapshot moved.
        //
        // The empty entry, never the placeholder: an installed widget with no
        // snapshot — a fresh install, a sign-out — showed the fictional sample
        // book as if it were the user's current one, refreshed forever.
        let entry = currentEntry(fallback: emptyEntry(), family: context.family)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}


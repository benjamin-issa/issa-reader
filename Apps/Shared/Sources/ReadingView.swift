import IssaCore
import IssaUI
import SwiftUI

/// The Reading tab: everything you are actually reading, in one place.
///
/// The Continue card leads, the other books in progress stack beneath it, and
/// the To-read queue is a rail at the bottom. This is where a reader lands to
/// get back to their book; the Library is for looking around. Every list is
/// `ReadingHome`, derived in the model — nothing here decides what is shown.
///
/// Switching tabs is not this view's to do: it is handed `showLibrary`, which
/// the phone answers by selecting the Library tab and the Mac by selecting a
/// sidebar row. A shelf means "the flat grid on that shelf"; `nil` means just
/// go and look.
public struct ReadingView: View {
    @Environment(AppModel.self) private var app
    private let showLibrary: (LibraryArrangement.Shelf?) -> Void

    public init(showLibrary: @escaping (LibraryArrangement.Shelf?) -> Void) {
        self.showLibrary = showLibrary
    }

    private var home: ReadingHome { app.readingHome }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing24) {
                if let hero = home.hero {
                    ContinueCardLink(book: hero, session: app.session)
                }
                if !home.alsoReading.isEmpty {
                    alsoReading
                }
                if !home.upNext.isEmpty {
                    BookRail(title: "Up next · To read", books: home.upNext, coverWidth: 64) {
                        showLibrary(.toRead)
                    }
                }
            }
            .padding(Metrics.screenMargin)
        }
        .background(Palette.paper)
        .refreshable { await app.refreshLibrary() }
        .overlay {
            if app.books.isEmpty, app.isLoadingLibrary {
                ProgressView()
            } else if home.isEmpty {
                PalettePlaceholder(
                    symbol: "bookmark",
                    title: "Nothing in progress",
                    message: "Pick something from your Library and it will be waiting here.",
                    actionTitle: "Go to Library",
                    action: { showLibrary(nil) },
                )
            }
        }
    }

    /// Every other book in progress, compact, one tap to resume. Omitted when
    /// the Continue book is the only one — a heading over nothing is noise.
    private var alsoReading: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Also reading").overlineStyle()
            VStack(spacing: Metrics.spacing8) {
                ForEach(home.alsoReading) { book in
                    ResumeLink(book: book, session: app.session) {
                        ResumeRow(book: book, session: app.session)
                    }
                    .accessibilityLabel(resumeLabel(for: book))
                    .accessibilityHint(book.isReadable ? "Opens the reader where you left off" : "Opens the book")
                }
            }
        }
    }

    private func resumeLabel(for book: Book) -> String {
        guard let progress = book.progress, progress > 0 else { return "Resume \(book.title)" }
        return "Resume \(book.title), \(ReadingProgress.percent(progress))% complete"
    }
}

/// A book in progress as one row: cover, title, how far in.
struct ResumeRow: View {
    let book: Book
    let session: Session?

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            CoverImage(book: book, session: session)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(book.title)
                    .font(Typography.bookTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // Only once there is something to show: a bar at nothing and
                // a "0%" beside it say "not started" louder than a blank does.
                if let progress = book.progress, progress > 0 {
                    ProgressBar(value: progress).frame(maxWidth: 150)
                }
            }
            Spacer(minLength: 0)
            if let progress = book.progress, progress > 0 {
                Text(ReadingProgress.percentText(progress))
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(Palette.border, lineWidth: 1),
        )
        .contentShape(Rectangle())
    }
}

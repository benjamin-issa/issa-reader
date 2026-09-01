import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// The full player for whatever is running, expanded from the mini bar.
///
/// It was a tab. A tab meant the mini bar had to be hidden while it was showing
/// — the same transport twice, one above the other — and hiding the bar meant
/// the tab bar's accessory slot came and went with the selection, which changed
/// the bar's shape on every switch. A sheet is both Music's answer and the one
/// that leaves the bar alone.
///
/// There is no idle state: the only way here is the mini bar, and the mini bar
/// exists only while something is playing.
public struct NowPlayingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var showsReader = false
    #endif

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let book = app.playbackBook {
                    PlayerView(
                        book: book, session: app.session, coordinator: app.playback,
                        chapterTitle: app.playbackChapterTitle,
                    )
                } else {
                    // Only reachable in the instant between playback ending and
                    // the sheet being dismissed for it.
                    Color.clear
                }
            }
            .navigationTitle("Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // Getting back to the words should not mean Library, then the
                // book, then Resume. In the navigation bar rather than beside
                // the transport because the player is a fixed stack that
                // already fills a phone.
                #if os(iOS)
                if let book = app.playbackBook, book.hasText, app.session != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showsReader = true } label: {
                            Label("Read along", systemImage: "book")
                        }
                        .accessibilityLabel("Read along")
                    }
                }
                #endif
            }
        }
        // Hung off the stack, not off the toolbar button it belongs to. A
        // presentation anchored inside a `ToolbarItem` is torn down with the
        // item, and the item disappears the moment `playbackBook` changes.
        #if os(iOS)
        .fullScreenCover(isPresented: $showsReader) {
            if let book = app.playbackBook, let session = app.session {
                ReaderScreen(book: book, session: session)
            }
        }
        #endif
        .presentationBackground(Palette.paper)
    }
}

private extension Book {
    /// Whether there is anything to read along with. A plain audiobook has no
    /// text at all, and offering to open it would be a lie.
    var hasText: Bool {
        servableFormats.contains(.ebook) || servableFormats.contains(.readaloud)
    }
}

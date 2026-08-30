import IssaCore
import IssaUI
import SwiftUI

/// Books with audio: readalongs first, then audiobooks.
public struct ListeningView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    private var readalongs: [Book] { app.derivation.readalongs }
    private var audiobooks: [Book] {
        app.books.filter { $0.audiobook != nil && !$0.hasReadalong }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing32) {
                if !readalongs.isEmpty {
                    section("Read along", books: readalongs)
                }
                if !audiobooks.isEmpty {
                    section("Audiobooks", books: audiobooks)
                }
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .overlay {
            if readalongs.isEmpty, audiobooks.isEmpty {
                // Styled from the palette: on this tab it is the entire screen
                // for a library with no aligned narration, so system greys on
                // warm paper is the whole first impression.
                VStack(spacing: Metrics.spacing12) {
                    Image(systemName: "headphones")
                        .font(.system(size: 44))
                        .foregroundStyle(Palette.inkQuaternary)
                    Text("Nothing to listen to yet")
                        .font(Typography.title)
                        .foregroundStyle(Palette.ink)
                    Text("Books with narration will appear here once your server has aligned them.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Metrics.spacing32)
            }
        }
    }

    private func section(_ title: String, books: [Book]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Text(title).overlineStyle()
            // Square audiobook art, matching the player and the mini player.
            // The grid asked for portrait ebook covers, so one book showed two
            // different artworks six points apart.
            BookGrid(books: books, session: app.session, shape: .square)
        }
    }
}

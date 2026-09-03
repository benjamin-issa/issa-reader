import IssaCore
import IssaUI
import SwiftUI

/// Books with audio: readalongs first, then audiobooks.
public struct ListeningView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    // Both sections read from `servableFormats`, not bare row presence:
    // Storyteller creates an audiobook or readaloud row as soon as work on one
    // is requested, so `audiobook != nil` listed books with nothing behind
    // them — and a readaloud the server has lost stayed under "Read along".
    // Book.swift states the rule this tab was breaking: for anything
    // user-facing prefer `servableFormats`.
    private var readalongs: [Book] {
        app.books.filter { $0.servableFormats.contains(.readaloud) }
    }

    private var audiobooks: [Book] {
        app.books.filter {
            let formats = $0.servableFormats
            return formats.contains(.audiobook) && !formats.contains(.readaloud)
        }
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
            // The television's own overscan-safe gutter, matching the shelf
            // next door; everywhere else the screen margin.
            #if os(tvOS)
            .padding(60)
            #else
            .padding(Metrics.screenMargin)
            #endif
        }
        .background(Palette.paper)
        .overlay {
            if readalongs.isEmpty, audiobooks.isEmpty {
                // Styled from the palette: on this tab it is the entire screen
                // for a library with no aligned narration, so system greys on
                // warm paper is the whole first impression.
                VStack(spacing: Metrics.spacing12) {
                    Image(systemName: "headphones")
                        .font(.system(size: Metrics.scale * 44))
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
            BookGrid(books: books, session: app.session, shape: .square, showsFormatMark: false)
        }
    }
}

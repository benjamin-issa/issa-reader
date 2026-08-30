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
                ContentUnavailableView(
                    "Nothing to listen to yet",
                    systemImage: "headphones",
                    description: Text("Books with narration will appear here once your server has aligned them."),
                )
            }
        }
    }

    private func section(_ title: String, books: [Book]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Text(title).overlineStyle()
            BookGrid(books: books, session: app.session)
        }
    }
}

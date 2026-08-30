import IssaCore
import IssaUI
import SwiftUI

/// Finding a phrase inside the book you are reading.
///
/// Results stream in chapter by chapter, because searching means parsing every
/// spine item and a long book would otherwise stall on the first keystroke.
struct BookSearchView: View {
    let model: ReaderModel
    let onOpen: (ReaderModel.SearchHit) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.searchHits.isEmpty, !query.isEmpty, !model.isSearching {
                Section {
                    Text("No matches.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
                .listRowBackground(Palette.surface)
            }

            ForEach(model.searchHits) { hit in
                Button {
                    onOpen(hit)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.chapterTitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                        excerpt(hit)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.surface)
            }
        }
        .paperListBackground()
        .navigationTitle("Find in book")
        .searchable(text: $query, prompt: "Find in this book")
        .onChange(of: query) { _, value in model.search(value) }
        .onDisappear { model.cancelSearch() }
        .overlay(alignment: .top) {
            if model.isSearching {
                ProgressView()
                    .padding(Metrics.spacing8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Metrics.spacing8)
            }
        }
    }

    /// The match itself in the app's accent, its context in ordinary ink, so a
    /// long excerpt is still scannable.
    ///
    /// Built as one attributed string rather than three concatenated `Text`s,
    /// which 26 deprecates — and which VoiceOver reads as three separate runs.
    private func excerpt(_ hit: ReaderModel.SearchHit) -> Text {
        var attributed = AttributedString(hit.excerpt)
        if let match = attributed.range(of: String(hit.excerpt[hit.excerptMatchRange])) {
            attributed[match].foregroundColor = Palette.tangerine
            attributed[match].font = Typography.footnote.bold()
        }
        return Text(attributed)
    }
}

/// Everything the reader has marked in this book.
struct AnnotationsView: View {
    let model: ReaderModel
    let onOpen: (Annotation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.annotations.isEmpty {
                Section {
                    Text("Nothing marked yet. Hold a sentence to highlight it, or bookmark the page you are on.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
                .listRowBackground(Palette.surface)
            }
            ForEach(model.annotations) { annotation in
                Button {
                    onOpen(annotation)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(annotation.kind == .bookmark
                                ? Palette.inkQuaternary
                                : ReaderPalette.color(for: annotation.tint))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            if let chapter = annotation.chapterTitle {
                                Text(chapter)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                            Text(annotation.excerpt)
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.surface)
                #if !os(tvOS)
                .swipeActions {
                    Button("Delete", role: .destructive) { model.remove(annotation) }
                }
                #endif
            }
        }
        .paperListBackground()
        .navigationTitle("Marks")
    }
}

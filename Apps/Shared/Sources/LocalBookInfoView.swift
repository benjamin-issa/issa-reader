#if !os(tvOS)
import IssaCore
import IssaUI
import SwiftUI

/// Book info for a book from the reader's files.
///
/// The book screen's shape with the server's rows left out — shelves, tags,
/// collections, downloads, Ask and the series link have nothing to say about a
/// file — and an "On this iPhone" group in their place: where it came from, its
/// name, size, format and when it was added. Everything else is what the EPUB
/// says about itself. Remove sits last and behaves like the swipe.
struct LocalBookInfoView: View {
    let book: Book
    let close: () -> Void

    @Environment(LocalLibrary.self) private var library
    @Environment(LocalBooksRoute.self) private var route: LocalBooksRoute?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var reattaching = false

    private var current: Book { library.book(book.uuid) ?? book }
    private var isMissing: Bool { library.missingFiles.contains(book.uuid) }
    private var copy: LocalCopy? { current.localCopy }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing24) {
                    hero
                    if isMissing { missingCard } else { primary }
                    details
                    if !isMissing, let description = Self.aboutText(current.description) {
                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            Text("About this book").overlineStyle()
                            Text(description)
                                .font(Typography.serif(17))
                                .foregroundStyle(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(role: .destructive) {
                        close()
                        library.remove([book.uuid])
                    } label: {
                        Text("Remove from this \(LocalDevice.noun)")
                            .font(Typography.body)
                            .foregroundStyle(Palette.alert)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("localInfo.remove")
                }
                .padding(Metrics.screenMargin)
            }
            .background(Palette.paper)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
        .fileImporter(isPresented: $reattaching, allowedContentTypes: [.epub]) { result in
            if case let .success(url) = result { library.importBooks([url], reattaching: book.uuid) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .presentationBackground(Palette.paper)
        .accessibilityIdentifier("screen.localBookInfo")
    }

    /// "About this book": the package's `dc:description` as text.
    ///
    /// Calibre and most tools write it as escaped HTML, which the XML parser
    /// hands back as literal tags and entities, so it showed `<div><p>…` on
    /// screen (R-19), the bug the server book screen fixed by rendering
    /// through `HTMLText`. Plain rather than attributed, to keep this
    /// sheet's serif.
    static func aboutText(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        let text = HTMLText.plain(description).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: Metrics.spacing16) {
            CoverImage(book: current, session: nil)
                .frame(width: 96)
                .opacity(isMissing ? 0.5 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(current.title)
                    .font(Typography.title)
                    .foregroundStyle(isMissing ? Palette.inkSecondary : Palette.ink)
                if !current.byline.isEmpty {
                    Text(current.byline).font(Typography.body).foregroundStyle(Palette.inkSecondary)
                }
                if isMissing {
                    Text(LocalBooksCopy.notOnDevice).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                } else if current.hasReadalong, let seconds = current.narrationDuration {
                    Label(narratedLine(seconds), systemImage: "waveform")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }

    /// "Narrated by Lucy Simmons · 7 h 4 min", or "Narrated · 7 h 4 min".
    private func narratedLine(_ seconds: Double) -> String {
        let length = LocalBooksCopy.narrated(seconds: seconds)
        let narrators = current.narrators.map(\.name)
        guard !narrators.isEmpty else { return length }
        return length.replacingOccurrences(
            of: "Narrated", with: "Narrated by \(narrators.joined(separator: ", "))")
    }

    private var primary: some View {
        Button {
            close()
            open()
        } label: {
            Text(primaryTitle)
                .font(Typography.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("localInfo.open")
    }

    private var primaryTitle: String {
        guard let progress = current.progress, progress > 0 else { return "Read" }
        return "Continue · \(Int((progress * 100).rounded()))%"
    }

    /// The problem row's shape without the "!": this is not something the
    /// reader did wrong.
    private var missingCard: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("The book file wasn’t restored").font(Typography.headline).foregroundStyle(Palette.ink)
            Text(missingReason)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { reattaching = true } label: {
                Text("Add Again…")
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Palette.border, lineWidth: 1))
    }

    private var missingReason: String {
        let file = copy?.fileName ?? "the file"
        let place = current.progress.map { " from \(Int(($0 * 100).rounded()))%" } ?? ""
        return "Your place and highlights came back from the backup, but the EPUB didn’t. Choose \(file) again to keep reading\(place)."
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("On this \(LocalDevice.noun)").overlineStyle()
            VStack(spacing: 0) {
                if !isMissing { row("Added from", LocalBooksCopy.originalsPlace) }
                row("File", copy?.fileName ?? "—", truncation: .middle)
                if !isMissing {
                    row("Size", copy.map { LocalByteText.text($0.byteCount) } ?? "—")
                    row("Format", format)
                }
                if let added = copy?.importedAt {
                    row("Added", added.formatted(date: .abbreviated, time: .omitted), last: true)
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Palette.border, lineWidth: 1))
            Text("A copy kept by Issa Reader. The original in \(LocalBooksCopy.originalsPlace) stays where it is.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "EPUB 3 · Narration", "EPUB 3 · Fixed layout", "EPUB 2".
    private var format: String {
        let version = (copy?.epubVersion?.first).map { "EPUB \($0)" } ?? "EPUB"
        if current.hasReadalong { return "\(version) · Narration" }
        if copy?.isFixedLayout == true { return "\(version) · Fixed layout" }
        return version
    }

    private func row(
        _ label: String, _ value: String, truncation: Text.TruncationMode = .tail, last: Bool = false,
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(Typography.body).foregroundStyle(Palette.ink)
                Spacer(minLength: Metrics.spacing12)
                Text(value)
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(truncation)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, Metrics.spacing16)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            if !last { Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, Metrics.spacing16) }
        }
    }

    private func open() {
        #if os(macOS)
        openWindow(id: "LocalReader", value: book.uuid)
        #else
        // After the sheet has gone: the reader is a cover over the whole
        // window, and a presentation begun while this one is still leaving is
        // one UIKit drops.
        let route = route
        let uuid = book.uuid
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            route?.open(uuid)
        }
        #endif
    }
}
#endif

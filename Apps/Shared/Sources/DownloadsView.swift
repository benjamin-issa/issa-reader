import IssaCore
import IssaUI
import SwiftUI

/// What is on this device, and how much room it takes.
///
/// Readaloud editions embed their audio, so a single book can be most of a
/// gigabyte. Showing the per-book cost — and letting one be removed without
/// touching the rest — matters more here than in a text-only reader.
public struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [Entry] = []
    @State private var totalBytes: Int64 = 0
    @State private var audioBytes: Int64 = 0

    public init() {}

    struct Entry: Identifiable {
        let book: Book
        let format: BookContentService.Format
        let bytes: Int64
        var id: String { book.uuid + format.rawValue }
    }

    public var body: some View {
        List {
            Section {
                LabeledContent("On this device", value: Self.sizeText(totalBytes))
                LabeledContent("Narration extracted", value: Self.sizeText(audioBytes))
            } footer: {
                Text("Downloaded books play with no network at all. A readaloud edition carries its narration inside the file, so one download covers both the text and the audio.")
            }
            .listRowBackground(Palette.surface)

            if entries.isEmpty {
                Section {
                    Text("Nothing downloaded yet.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
                .listRowBackground(Palette.surface)
            } else {
                Section("Books") {
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.book.title)
                                    .font(Typography.callout)
                                    .foregroundStyle(Palette.ink)
                                Text("\(entry.format.rawValue.capitalized) · \(Self.sizeText(entry.bytes))")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { remove(entry) }
                                .font(Typography.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(hex: 0x7A2F2A))
                        }
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .paperListBackground()
        .navigationTitle("Downloads")
        .task { refresh() }
    }

    private func refresh() {
        guard let session = app.session else { return }
        let service = BookContentService(client: session.client)
        var found: [Entry] = []
        for book in app.books {
            for format in [BookContentService.Format.readaloud, .ebook, .audiobook]
                where service.isDownloaded(book, format: format) {
                let url = service.localURL(for: book, format: format)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                found.append(Entry(book: book, format: format, bytes: Int64(size)))
            }
        }
        entries = found.sorted { $0.bytes > $1.bytes }
        totalBytes = service.cacheSize()
        audioBytes = Self.directorySize(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Audio", directoryHint: .isDirectory),
        )
    }

    private func remove(_ entry: Entry) {
        guard let session = app.session else { return }
        BookContentService(client: session.client).removeDownload(entry.book, format: entry.format)
        // Readaloud audio is extracted alongside the file; leaving it behind
        // would report a smaller total than the disk actually holds.
        if entry.format == .readaloud {
            AudioExtractionCleanup.removeAudio(for: entry.book.uuid)
        }
        refresh()
    }

    /// Recursive, because narration is extracted into a directory per book.
    static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Small shim so the downloads screen does not need to import the playback
/// package purely to clean up extracted audio.
enum AudioExtractionCleanup {
    static func removeAudio(for bookID: String) {
        // Must match AudioExtraction.defaultDirectory: Application Support, not
        // Caches. Pointing at the old path silently freed nothing.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(
            at: support.appending(path: "Audio/\(bookID)", directoryHint: .isDirectory),
        )
    }
}

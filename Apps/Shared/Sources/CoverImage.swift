import IssaCore
import IssaUI
import SwiftUI

/// Loads and caches book covers.
///
/// Covers need the bearer token, so `AsyncImage` cannot fetch them. Images are
/// downsampled with ImageIO on a background task before they ever become a
/// `CGImage`, which is what keeps a grid of hundreds of covers scrolling
/// smoothly — decoding full-size JPEGs on the main thread is the usual cause of
/// jank in a library grid.
@MainActor
@Observable
public final class CoverCache {
    public static let shared = CoverCache()

    private var memory: [String: Image] = [:]
    private var inFlight: [String: Task<Image?, Never>] = [:]
    private let diskDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public func cached(_ uuid: String) -> Image? { memory[uuid] }

    /// Copies a book's cover into the App Group so the widget can draw it.
    ///
    /// The widget cannot reach the app's Caches directory, and a cover fetched
    /// inside the extension would spend its 30 MB budget on a network decode.
    /// One small file, written when the current book changes.
    public func publishCoverToWidget(
        for book: Book, session: Session, shape: LibraryService.CoverShape = .portrait,
    ) async {
        let key = shape == .square ? book.uuid + "-square" : book.uuid
        let fileURL = diskDirectory.appending(path: "\(key).jpg")
        var data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: fileURL)
        }.value
        if data == nil {
            data = try? await LibraryService(client: session.client).coverData(
                for: book.uuid, shape: shape, pixelWidth: 320, version: book.updatedAt?.value)
        }
        guard let data else { return }
        await Task.detached(priority: .utility) {
            CurrentBookSnapshotStore.writeCover(data)
        }.value
    }

    /// Drops everything, for sign-out.
    public func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public func image(
        for book: Book, session: Session,
        shape: LibraryService.CoverShape = .portrait,
        maxPixel: CGFloat = 600,
    ) async -> Image? {
        let key = shape == .square ? book.uuid + "-square" : book.uuid
        if let hit = memory[key] { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Image?, Never> { [diskDirectory] in
            let fileURL = diskDirectory.appending(path: "\(key).jpg")

            // Disk I/O off the main actor: a cold grid otherwise reads dozens of
            // files on the thread that is trying to scroll.
            var data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: fileURL)
            }.value

            if data == nil {
                // Ask the server for the size actually drawn, and key the URL on
                // updatedAt so a replaced cover appears instead of the old one.
                data = try? await LibraryService(client: session.client).coverData(
                    for: book.uuid,
                    shape: shape,
                    pixelWidth: Int(maxPixel),
                    version: book.updatedAt?.value,
                )
                if let data {
                    let payload = data
                    await Task.detached(priority: .utility) {
                        try? payload.write(to: fileURL, options: .atomic)
                    }.value
                }
            }
            guard let data else { return nil }
            guard let image = await Self.downsample(data, maxPixel: maxPixel) else { return nil }
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result }
        return result
    }

    /// Decodes straight to the size we will draw, so a 2000px cover never
    /// occupies memory at full resolution.
    private nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) async -> Image? {
        await Task.detached(priority: .utility) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return Image(decorative: cgImage, scale: 1)
        }.value
    }
}

/// A book cover with the design's placeholder treatment when art is missing:
/// a tinted block carrying the author's initial, never an empty grey rectangle.
public struct CoverImage: View {
    let book: Book
    let session: Session?
    var aspect: CGFloat = Metrics.coverAspect
    var shape: LibraryService.CoverShape = .portrait

    @State private var image: Image?

    public init(
        book: Book, session: Session?,
        aspect: CGFloat = Metrics.coverAspect,
        shape: LibraryService.CoverShape = .portrait,
    ) {
        self.book = book
        self.session = session
        self.aspect = aspect
        self.shape = shape
    }

    public var body: some View {
        // The art is an OVERLAY on a box that sizes itself, not a child of a
        // stack that sizes to its children. `.aspectRatio(contentMode: .fill)`
        // is a request to exceed the proposal, so as a ZStack child a square
        // cover reported a square cell — which bled sideways into its
        // neighbour and inflated the whole grid row. Overlay content is sized
        // to its base and can never grow it, and `.clipShape` alone could not
        // help because it is a drawing mask, not a layout constraint.
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.10), lineWidth: 0.5),
        )
        .task(id: book.uuid) {
            guard let session else { return }
            image = await CoverCache.shared.image(for: book, session: session, shape: shape)
        }
    }

    private var placeholder: some View {
        // Deterministic tint per book so the same title always looks the same.
        let hue = Double(abs(book.uuid.hashValue % 360)) / 360.0
        return ZStack {
            Color(hue: hue, saturation: 0.18, brightness: 0.86)
            Text(initial)
                .font(Typography.serif(34, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.55))
        }
    }

    private var initial: String {
        let source = book.authors.first?.name ?? book.title
        return String(source.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

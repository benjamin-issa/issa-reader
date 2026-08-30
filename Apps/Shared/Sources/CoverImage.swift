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
    /// So the app fetches it; the publisher decides where it goes.
    /// Fetches the bytes without deciding what to do with them.
    ///
    /// Returning the data rather than writing it lets the caller record which
    /// shape actually landed — a square request 404s for a book with no
    /// audiobook edition, and the widget needs to know which aspect it got.
    /// The cover the widget should draw, and which shape it turned out to be.
    ///
    /// Returns the shape as well as the bytes because the caller cannot infer
    /// it: `LibraryService.coverData` has its own fallback from portrait to
    /// square, so asking for one can quietly return the other — and the widget
    /// crops by a third if it frames square art at the portrait aspect.
    public func widgetCover(
        for book: Book, session: Session,
        preferring shape: LibraryService.CoverShape,
    ) async -> (data: Data, isSquare: Bool)? {
        // Its own cache key. The widget asks for 320px and the app asks for
        // 600px through the same directory, so sharing a key let whichever
        // landed first serve the other — an upscaled 320px cover in the library
        // grid for the life of the cache.
        let name = "\(book.uuid)-widget-\(shape == .square ? "square" : "portrait").jpg"
        let fileURL = diskDirectory.appending(path: name)
        if let cached = await Task.detached(priority: .utility, operation: {
            try? Data(contentsOf: fileURL)
        }).value {
            return (cached, shape == .square)
        }

        let service = LibraryService(client: session.client)
        // Try what the book wants, then the other one. A square request 404s
        // for a book with no audiobook edition, and portrait can be missing
        // too — either way the previous book's art must not be left in place.
        for candidate in [shape, shape == .square ? .portrait : .square] {
            guard let data = try? await service.coverData(
                for: book.uuid, shape: candidate, pixelWidth: 320,
                version: book.updatedAt?.value)
            else { continue }
            let url = diskDirectory.appending(
                path: "\(book.uuid)-widget-\(candidate == .square ? "square" : "portrait").jpg")
            await Task.detached(priority: .utility) {
                try? data.write(to: url, options: .atomic)
            }.value
            return (data, candidate == .square)
        }
        return nil
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
        // Drawn from the palette, and stable. `hashValue` is seeded per process,
        // so the "deterministic" tint this comment used to promise actually
        // changed on every launch — the same defect already fixed in
        // LibraryStore.filename.
        let tints: [Color] = [
            Palette.tangerine, Palette.moss, Palette.slate,
            Color(hex: 0xC46A6A), Color(hex: 0x8A6AA8), Palette.borderStrong,
        ]
        let index = book.uuid.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 4_096 } % tints.count
        return ZStack {
            tints[index].opacity(0.28)
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

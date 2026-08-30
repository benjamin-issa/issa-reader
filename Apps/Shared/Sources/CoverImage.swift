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

    public func image(for book: Book, session: Session, maxPixel: CGFloat = 600) async -> Image? {
        if let hit = memory[book.uuid] { return hit }
        if let existing = inFlight[book.uuid] { return await existing.value }

        let task = Task<Image?, Never> { [diskDirectory] in
            let fileURL = diskDirectory.appending(path: "\(book.uuid).jpg")

            var data = try? Data(contentsOf: fileURL)
            if data == nil {
                data = try? await LibraryService(client: session.client).coverData(for: book.uuid)
                if let data { try? data.write(to: fileURL, options: .atomic) }
            }
            guard let data else { return nil }
            guard let image = await Self.downsample(data, maxPixel: maxPixel) else { return nil }
            return image
        }
        inFlight[book.uuid] = task
        let result = await task.value
        inFlight[book.uuid] = nil
        if let result { memory[book.uuid] = result }
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

    @State private var image: Image?

    public init(book: Book, session: Session?, aspect: CGFloat = Metrics.coverAspect) {
        self.book = book
        self.session = session
        self.aspect = aspect
    }

    public var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.10), lineWidth: 0.5),
        )
        .task(id: book.uuid) {
            guard let session else { return }
            image = await CoverCache.shared.image(for: book, session: session)
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

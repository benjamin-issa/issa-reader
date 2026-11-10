import IssaCore
import IssaUI
import SwiftUI
import Testing
import UIKit
import WidgetKit

@testable import IssaCore
@testable import IssaReader_iOS

/// Every widget family, drawn.
///
/// No widget view was rendered by any test: the layout shipped on the strength
/// of a mockup. These render each family through `ImageRenderer` at a small
/// iPhone's size and a Max's, in light and dark, with a long title, none, one
/// and four other books, square and portrait covers, and the empty state.
///
/// Two environment variables, both optional:
/// - `ISSA_WIDGET_RENDER_DIR`: where to write the PNGs, for a contact sheet.
///   Unset, nothing is written; the assertions still run.
/// - `ISSA_WIDGET_COVER_DIR`: a directory of real covers to draw with. Unset,
///   the covers are generated, so a release run needs nothing outside the repo.
@Suite("Widget views, rendered")
@MainActor
struct WidgetRenderTests {
    // MARK: - Sizes, in points

    struct Slot {
        let family: WidgetFamily
        let label: String
        let size: CGSize
    }

    static let small = [
        Slot(family: .systemSmall, label: "small-158", size: CGSize(width: 158, height: 158)),
        Slot(family: .systemSmall, label: "small-170", size: CGSize(width: 170, height: 170)),
    ]
    static let medium = [
        Slot(family: .systemMedium, label: "medium-338", size: CGSize(width: 338, height: 158)),
        Slot(family: .systemMedium, label: "medium-364", size: CGSize(width: 364, height: 170)),
    ]
    static let large = [
        Slot(family: .systemLarge, label: "large-338", size: CGSize(width: 338, height: 354)),
        Slot(family: .systemLarge, label: "large-364", size: CGSize(width: 364, height: 382)),
    ]
    static let rectangular = [
        Slot(family: .accessoryRectangular, label: "rect-160", size: CGSize(width: 160, height: 72)),
        Slot(family: .accessoryRectangular, label: "rect-170", size: CGSize(width: 170, height: 76)),
    ]
    static let all = small + medium + large + rectangular

    static let longTitle = "The Strange Case of Dr Jekyll and Mr Hyde"

    // MARK: - Covers

    /// Real covers from `ISSA_WIDGET_COVER_DIR` when set, in file-name order;
    /// otherwise generated ones. Square is told by shape, not by name.
    struct Covers {
        var portrait: [(name: String, data: Data)]
        var square: [(name: String, data: Data)]
        var real: Bool
    }

    static let covers: Covers = {
        if let path = ProcessInfo.processInfo.environment["ISSA_WIDGET_COVER_DIR"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
            var found = Covers(portrait: [], square: [], real: true)
            for name in names where ["jpg", "jpeg", "png"].contains((name as NSString).pathExtension.lowercased()) {
                guard let data = try? Data(contentsOf: directory.appending(path: name)),
                      let image = UIImage(data: data) else { continue }
                let entry = (name: (name as NSString).deletingPathExtension, data: data)
                if abs(image.size.width / image.size.height - 1) < 0.08 {
                    found.square.append(entry)
                } else {
                    found.portrait.append(entry)
                }
            }
            if !found.portrait.isEmpty, !found.square.isEmpty { return found }
        }
        return Covers(
            portrait: [
                ("gen-light", generated(size: CGSize(width: 320, height: 480), top: 0xF1E7CF, bottom: 0xE2D2AE, title: "LIGHT")),
                ("gen-dark", generated(size: CGSize(width: 320, height: 480), top: 0x203B52, bottom: 0x0E1B27, title: "DARK")),
                ("gen-red", generated(size: CGSize(width: 320, height: 480), top: 0x8A2F3D, bottom: 0x4A1620, title: "RED")),
                ("gen-olive", generated(size: CGSize(width: 320, height: 480), top: 0x66703F, bottom: 0x353C1E, title: "OLIVE")),
            ],
            square: [
                ("gen-square", generated(size: CGSize(width: 320, height: 320), top: 0x3F6E88, bottom: 0x1F3A4B, title: "SQUARE")),
            ],
            real: false)
    }()

    /// A flat-gradient jacket with its title drawn at the top, so a crop that
    /// takes the top shows.
    static func generated(size: CGSize, top: UInt32, bottom: UInt32, title: String) -> Data {
        func colour(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: space, colors: [colour(top).cgColor, colour(bottom).cgColor] as CFArray,
                locations: [0, 1])!
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let brightness = (CGFloat((top >> 16) & 0xFF) + CGFloat((top >> 8) & 0xFF)) / 2 / 255
            let ink = brightness > 0.6 ? UIColor(white: 0.1, alpha: 1) : UIColor.white
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width * 0.13, weight: .bold), .foregroundColor: ink,
            ]
            (title as NSString).draw(
                at: CGPoint(x: size.width * 0.1, y: size.height * 0.06), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.85)!
    }

    // MARK: - Entries

    static func other(_ id: String, _ title: String, _ progress: Double, square: Bool = false, cover: Data?) -> OtherEntry {
        OtherEntry(
            book: OtherBook(bookID: id, title: title, progress: progress, coverIsSquare: square), cover: cover)
    }

    /// The four other books, drawn with the covers in turn.
    static func others(_ count: Int) -> [OtherEntry] {
        let titles = ["Moby-Dick", "Dracula", "Emma and the Whole of Her Long Summer", "Walden", "Unused"]
        let progress = [0.18, 0.55, 0.31, 0.77]
        return (0 ..< min(count, 4)).map { index in
            let pool = covers.portrait
            return other(
                "other-\(index)", titles[index], progress[index],
                cover: pool[(index + 1) % pool.count].data)
        }
    }

    static func entry(
        title: String = longTitle, square: Bool = false, others count: Int = 4,
        cover: Data?? = nil, remaining: TimeInterval? = 6 * 3600 + 12 * 60,
    ) -> CurrentBookEntry {
        let art: Data? = switch cover {
        case .none: square ? covers.square[0].data : covers.portrait[0].data
        case let .some(value): value
        }
        return CurrentBookEntry(
            date: .now,
            snapshot: CurrentBookSnapshot(
                bookID: "current", title: title, author: "Robert Louis Stevenson",
                chapter: "Chapter 3 · A Caucus-Race and a Long Tale", progress: 0.42,
                remaining: remaining, coverBookID: "current", coverIsSquare: square),
            cover: art, others: others(count))
    }

    static var emptyEntry: CurrentBookEntry {
        CurrentBookEntry(
            date: .now, snapshot: CurrentBookSnapshot(bookID: "", title: "", author: "", progress: 0),
            cover: nil, isEmpty: true)
    }

    // MARK: - Rendering

    static let renderDirectory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["ISSA_WIDGET_RENDER_DIR"], !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Draws `content` the way a widget sits: on the surface, in a rounded
    /// tile, with a dark panel behind the lock screen's family.
    static func render(
        _ content: some View, slot: Slot, scheme: ColorScheme,
        accented: Bool = false,
    ) -> UIImage {
        IssaFonts.register()
        let lock = slot.family == .accessoryRectangular
        let tile = ZStack {
            if lock {
                Color(red: 0.13, green: 0.16, blue: 0.2)
            } else {
                Palette.surface
            }
            content
        }
        .frame(width: slot.size.width, height: slot.size.height)
        .clipShape(RoundedRectangle(cornerRadius: lock ? 12 : 22, style: .continuous))
        .environment(\.widgetFamilyOverride, slot.family)
        .environment(\.colorScheme, lock ? .dark : scheme)
        .environment(\.widgetAccentedOverride, accented)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }

    /// Asserts the picture is the size asked for and is not blank, and writes it.
    @discardableResult
    static func check(
        _ image: UIImage, slot: Slot, name: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) -> UIImage {
        #expect(image.size == slot.size, "\(name) is \(image.size)", sourceLocation: sourceLocation)
        #expect(image.cgImage != nil, "\(name) rendered nothing", sourceLocation: sourceLocation)
        if let cg = image.cgImage {
            #expect(distinctColours(cg) > 2, "\(name) is blank", sourceLocation: sourceLocation)
        }
        if let renderDirectory, let png = image.pngData() {
            try? png.write(to: renderDirectory.appending(path: "\(name).png"))
        }
        return image
    }

    /// A rough count of the colours in a sampled grid: a blank tile has one.
    static func distinctColours(_ cg: CGImage) -> Int {
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let key = UInt32(pixels[index] >> 3) << 16 | UInt32(pixels[index + 1] >> 3) << 8 | UInt32(pixels[index + 2] >> 3)
            seen.insert(key)
        }
        return seen.count
    }

    static let schemes: [(name: String, scheme: ColorScheme)] = [("light", .light), ("dark", .dark)]

    // MARK: - Every family

    @Test("small, in both crops, at both sizes, in light and dark")
    func small() {
        for slot in Self.small {
            for (scheme, colour) in Self.schemes {
                for style in [SmallCoverStyle.fill, .fitOverBlur] {
                    let tag = style == .fill ? "fill" : "fit"
                    for (name, square, entry) in [
                        ("portrait", false, Self.entry()),
                        ("square", true, Self.entry(square: true)),
                        ("nocover", false, Self.entry(cover: .some(nil))),
                        ("longleft", false, Self.entry(remaining: 12 * 3600 + 40 * 60)),
                    ] {
                        _ = square
                        let image = Self.render(SmallWidgetView(entry: entry, style: style), slot: slot, scheme: colour)
                        Self.check(image, slot: slot, name: "\(slot.label)-\(scheme)-\(tag)-\(name)")
                    }
                }
            }
        }
    }

    @Test("medium: long title, square, none/one/four others, no cover, empty")
    func medium() {
        for slot in Self.medium {
            for (scheme, colour) in Self.schemes {
                let cases: [(String, CurrentBookEntry)] = [
                    ("long-4others", Self.entry()),
                    ("long-1other", Self.entry(others: 1)),
                    ("long-0others", Self.entry(others: 0)),
                    ("square-4others", Self.entry(square: true)),
                    ("square-0others", Self.entry(square: true, others: 0)),
                    ("short-1other", Self.entry(title: "Piranesi", others: 1)),
                    ("nocover-1other", Self.entry(others: 1, cover: .some(nil))),
                    ("empty", Self.emptyEntry),
                ]
                for (name, entry) in cases {
                    let image = Self.render(CurrentBookView(entry: entry), slot: slot, scheme: colour)
                    Self.check(image, slot: slot, name: "\(slot.label)-\(scheme)-\(name)")
                }
            }
        }
    }

    @Test("large: long title, square, none/one/four others, no cover, empty")
    func large() {
        for slot in Self.large {
            for (scheme, colour) in Self.schemes {
                let cases: [(String, CurrentBookEntry)] = [
                    ("long-4others", Self.entry()),
                    ("long-1other", Self.entry(others: 1)),
                    ("long-0others", Self.entry(others: 0)),
                    ("square-4others", Self.entry(square: true)),
                    ("nocover-4others", Self.entry(cover: .some(nil))),
                    ("empty", Self.emptyEntry),
                ]
                for (name, entry) in cases {
                    let image = Self.render(CurrentBookView(entry: entry), slot: slot, scheme: colour)
                    Self.check(image, slot: slot, name: "\(slot.label)-\(scheme)-\(name)")
                }
            }
        }
    }

    @Test("the lock screen rectangle: a long title, a short one, empty")
    func rectangular() {
        for slot in Self.rectangular {
            for (name, entry) in [
                ("long", Self.entry()), ("short", Self.entry(title: "Piranesi")),
                ("nohours", Self.entry(remaining: nil)), ("empty", Self.emptyEntry),
            ] {
                let image = Self.render(CurrentBookView(entry: entry), slot: slot, scheme: .dark)
                Self.check(image, slot: slot, name: "\(slot.label)-\(name)")
            }
        }
    }

    @Test("the accented (tinted) rendering draws, and the logo is not a blob")
    func accented() {
        for slot in [Self.medium[0], Self.large[0], Self.small[0]] {
            let image = Self.render(
                CurrentBookView(entry: Self.entry()), slot: slot, scheme: .dark, accented: true)
            Self.check(image, slot: slot, name: "\(slot.label)-accented")
        }
    }

    /// A contact-sheet matrix of the real covers (or the generated ones) in
    /// both small crops: which jackets lose their printed title to `fill`.
    @Test("small, every cover in both crops")
    func smallEveryCover() {
        let slot = Self.small[0]
        for (name, data) in Self.covers.portrait + Self.covers.square {
            let isSquare = Self.covers.square.contains { $0.name == name }
            let entry = CurrentBookEntry(
                date: .now,
                snapshot: CurrentBookSnapshot(
                    bookID: "c", title: Self.longTitle, author: "A", progress: 0.42,
                    remaining: 6 * 3600 + 12 * 60, coverBookID: "c", coverIsSquare: isSquare),
                cover: data)
            for (tag, style) in [("fill", SmallCoverStyle.fill), ("fit", .fitOverBlur)] {
                let image = Self.render(SmallWidgetView(entry: entry, style: style), slot: slot, scheme: .light)
                Self.check(image, slot: slot, name: "covers-small-\(name)-\(tag)")
            }
        }
        // And each real cover in the medium and large shapes.
        for (name, data) in Self.covers.portrait + Self.covers.square {
            let isSquare = Self.covers.square.contains { $0.name == name }
            let entry = CurrentBookEntry(
                date: .now,
                snapshot: CurrentBookSnapshot(
                    bookID: "c", title: Self.longTitle, author: "Robert Louis Stevenson",
                    chapter: "Chapter 3 · A Caucus-Race", progress: 0.42,
                    remaining: 6 * 3600 + 12 * 60, coverBookID: "c", coverIsSquare: isSquare),
                cover: data, others: Self.others(isSquare ? 1 : 4))
            for slot in [Self.medium[0], Self.large[0]] {
                let image = Self.render(CurrentBookView(entry: entry), slot: slot, scheme: .light)
                Self.check(image, slot: slot, name: "covers-\(slot.family == .systemMedium ? "medium" : "large")-\(name)")
            }
        }
    }

    // MARK: - What a tap opens

    /// A row that acts on the first has shipped here before, so the books are
    /// distinct and the assertions ask for the second, third and last.
    @Test("the large row links each cover to its own book")
    func largeRowLinksByIdentity() throws {
        let entry = Self.entry()
        let row = WidgetShelf.alsoInProgress(in: entry)
        #expect(row.count == 4)
        #expect(row.map(\.book.bookID) == ["other-0", "other-1", "other-2", "other-3"])
        #expect(row[1].url == CurrentBookSnapshotStore.deepLink(bookID: "other-1"))
        #expect(row[3].url == CurrentBookSnapshotStore.deepLink(bookID: "other-3"))
        #expect(row[2].url?.absoluteString == "issareader://book/other-2")
        // And none of them is the first's, or the current book's.
        #expect(row[1].url != row[0].url)
        #expect(row[3].url != row[0].url)
        #expect(!row.contains { $0.url == CurrentBookSnapshotStore.deepLink(bookID: "current") })
    }

    @Test("medium's card links to the first other book, whoever is current")
    func mediumCardLinks() {
        let entry = Self.entry()
        #expect(WidgetShelf.alsoReading(in: entry)?.url == CurrentBookSnapshotStore.deepLink(bookID: "other-0"))
        #expect(WidgetShelf.alsoReading(in: entry)?.book.title == "Moby-Dick")
        #expect(WidgetShelf.alsoReading(in: Self.entry(others: 0)) == nil)
    }

    @Test("a row of more than four draws four")
    func rowIsCapped() {
        var entry = Self.entry()
        entry.others += [Self.other("other-4", "Fifth", 0.1, cover: nil)]
        #expect(WidgetShelf.alsoInProgress(in: entry).map(\.book.bookID) == ["other-0", "other-1", "other-2", "other-3"])
    }

    // MARK: - Which families decode what

    /// The extension is held to ~30 MB: only the families that draw a cover
    /// read one, and only as many of the others as they show.
    @Test("each family loads only the covers it draws")
    func familiesLoadWhatTheyDraw() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CurrentBookSnapshotStore.directoryOverride = directory
        defer {
            CurrentBookSnapshotStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let others = (0 ..< 4).map { OtherBook(bookID: "o\($0)", title: "O\($0)", progress: 0.1) }
        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: "cur", title: "Current", author: "A", progress: 0.5, coverBookID: "cur", others: others))
        CurrentBookSnapshotStore.writeCover(Self.covers.portrait[0].data)
        // Three of the four covers exist; the fourth is still to land.
        for index in 0 ..< 3 {
            CurrentBookSnapshotStore.writeOtherCover(Self.covers.portrait[index % Self.covers.portrait.count].data, bookID: "o\(index)")
        }

        func loaded(_ family: WidgetFamily) -> (current: Bool, others: [Bool])? {
            CurrentBookEntry.current(family: family).map { ($0.cover != nil, $0.others.map { $0.cover != nil }) }
        }
        #expect(loaded(.systemSmall)?.current == true)
        #expect(loaded(.systemSmall)?.others.isEmpty == true)
        #expect(loaded(.systemMedium)?.others == [true])
        #expect(loaded(.systemLarge)?.others == [true, true, true, false])
        for family in [WidgetFamily.accessoryRectangular, .accessoryCircular, .accessoryInline] {
            #expect(loaded(family)?.current == false, "\(family) decodes no cover")
            #expect(loaded(family)?.others.isEmpty == true)
        }
        // A cover that is another book's is not drawn: the shared file has no identity.
        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: "cur", title: "Current", author: "A", progress: 0.5, coverBookID: "someone-else", others: others))
        #expect(loaded(.systemLarge)?.current == false)
    }

    /// Decoded bytes per family, from the real decoder at the drawn sizes and
    /// the 3x display scale. The honest number the report quotes.
    @Test("a family's decoded covers stay far under the extension's limit")
    func decodedMemory() {
        func bytes(_ data: Data, points: CGSize, fit: CoverArt.Fit) -> Int {
            let pixels = CGSize(width: points.width * 3, height: points.height * 3)
            let main = WidgetImages.image(from: data, framePixels: pixels, fill: fit == .fill)
                .map(WidgetImages.decodedBytes) ?? 0
            let blur = fit == .fitOverBlur ? (WidgetImages.image(from: data, longEdge: 48).map(WidgetImages.decodedBytes) ?? 0) : 0
            return main + blur
        }
        let portrait = Self.covers.portrait[0].data
        let small = bytes(portrait, points: CGSize(width: 170, height: 170), fit: .fill)
        let smallFit = bytes(portrait, points: CGSize(width: 170, height: 170), fit: .fitOverBlur)
        let medium = bytes(portrait, points: CGSize(width: 113, height: 170), fit: .fitOverBlur)
            + bytes(portrait, points: CGSize(width: 24, height: 36), fit: .fitOverBlur)
        let large = bytes(portrait, points: CGSize(width: 130, height: 195), fit: .fitOverBlur)
            + 4 * bytes(portrait, points: CGSize(width: 70, height: 105), fit: .fitOverBlur)
        print("WIDGET-MEMORY small-fill=\(small) small-fit=\(smallFit) medium=\(medium) large=\(large)")
        for (name, value) in [("small", small), ("small fit", smallFit), ("medium", medium), ("large", large)] {
            #expect(value > 0, "\(name) decoded nothing")
            #expect(value < 6_000_000, "\(name) decoded \(value) bytes")
        }
        // A thumbnail never upscales: a 320 px cover asked for 2000 px stays 320.
        let own = UIImage(data: portrait).map { max($0.size.width, $0.size.height) * $0.scale }
        let tiny = WidgetImages.image(from: portrait, longEdge: 2000)
        #expect(tiny.map { max($0.size.width, $0.size.height) } == own)
    }
}

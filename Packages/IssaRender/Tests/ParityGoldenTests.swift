import CryptoKit
import Foundation
import IssaEPUB
import Testing

@testable import IssaRender

/// The rendered string of every chapter of every fixture book, as the reader
/// and the Ask index build it — written down, so the Android client can be
/// held to it.
///
/// A position's `charOffset` is a UTF-16 index into this string, and so is
/// every Ask passage and spoiler boundary. The Android port builds the same
/// string with its own parser (`Android/render`, `ChapterParser`), and a
/// position saved on one device only lands on the same sentence on the other
/// if the two strings are identical, character for character. This suite is
/// the Swift half of that contract: with `ISSA_WRITE_PARITY_GOLDENS=1` it
/// writes `Fixtures/parity/<package>-<book>.json`; otherwise it checks the
/// parser still produces what those files say, so a change on this side that
/// would move every saved position on the other is caught here first.
/// `ParserParityTest` in `Android/render` reads the same files.
///
/// Parsed exactly as `AskIndexStore.parseChapter` parses: a plain
/// `ReaderStyle()` and `ArchiveImageSource`, because each plate contributes an
/// object-replacement character and a newline to the string. Styling is not
/// recorded — it never changes the characters (`IndexOffsetTests`).
///
///     ISSA_WRITE_PARITY_GOLDENS=1 swift test --filter ParityGoldenTests
///
/// Until the files have been written once there is nothing to check, and the
/// suite says so and passes — except on a release run, which must see it
/// check.
@Suite("The rendered string, written down for the Android client")
struct ParityGoldenTests {
    struct Chapter: Codable, Equatable {
        let spineIndex: Int
        let href: String
        /// The chapter could not be parsed at all (a DRM sample, say). The
        /// other client must fail on it too, rather than invent text.
        var failed = false
        var utf16Length: Int?
        /// SHA-256 of the string's UTF-16LE code units: the exact comparison.
        var sha256: String?
        /// The string itself, so a mismatch can be read rather than only
        /// detected.
        var text: String?
        /// Fragment id → `[location, length]` in UTF-16 units.
        var fragmentRanges: [String: [Int]]?
        /// Where each plate's U+FFFC sits.
        var plates: [Int]?
    }

    struct Book: Codable, Equatable {
        /// Repository-relative path of the EPUB.
        let epub: String
        var failed = false
        var chapters: [Chapter] = []
    }

    static let fixtureDirectories = [
        "Packages/IssaEPUB/Tests/Fixtures",
        "Packages/IssaRender/Tests/Fixtures",
        "Packages/IssaPlayback/Tests/Fixtures",
        "Packages/IssaAsk/Tests/Fixtures",
    ]

    static var repoRoot: URL {
        // Packages/IssaRender/Tests/ParityGoldenTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var goldenDirectory: URL {
        repoRoot.appending(path: "Packages/IssaRender/Tests/Fixtures/parity", directoryHint: .isDirectory)
    }

    /// Every fixture book, keyed `<package>-<book>`: `alice.epub` lives in
    /// three packages, and each copy is checked.
    static func books() throws -> [(key: String, path: String)] {
        var books: [(key: String, path: String)] = []
        for directory in fixtureDirectories {
            let url = repoRoot.appending(path: directory, directoryHint: .isDirectory)
            let package = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".epub") }
                .sorted()
            for name in names {
                let stem = String(name.dropLast(".epub".count))
                books.append((key: "\(package)-\(stem)", path: "\(directory)/\(name)"))
            }
        }
        return books
    }

    /// One book, parsed chapter by chapter as the Ask index parses it.
    static func render(path: String) -> Book {
        var book = Book(epub: path)
        guard let package = try? EPUBPackage.open(url: repoRoot.appending(path: path)) else {
            book.failed = true
            return book
        }
        let images = ArchiveImageSource(archive: package.archive)
        for (index, item) in package.spine.enumerated() {
            var chapter = Chapter(spineIndex: index, href: item.href)
            guard let data = try? package.archive.read(item.href),
                  let parsed = try? HTMLContentParser(
                      style: ReaderStyle(), loadImage: { images.image(for: $0) },
                  ).parse(xhtml: data, baseHref: item.href)
            else {
                chapter.failed = true
                book.chapters.append(chapter)
                continue
            }
            let text = parsed.text.string
            let units = Array(text.utf16)
            var bytes = Data(capacity: units.count * 2)
            for unit in units {
                bytes.append(UInt8(unit & 0xFF))
                bytes.append(UInt8(unit >> 8))
            }
            chapter.utf16Length = units.count
            chapter.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            chapter.text = text
            chapter.fragmentRanges = parsed.fragmentRanges.mapValues { [$0.location, $0.length] }
            chapter.plates = units.indices.filter { units[$0] == 0xFFFC }
            book.chapters.append(chapter)
        }
        return book
    }

    @Test("every fixture chapter renders to the string written down for it")
    func chaptersMatch() throws {
        let writing = ProcessInfo.processInfo.environment["ISSA_WRITE_PARITY_GOLDENS"] == "1"
        let releaseRun = ProcessInfo.processInfo.environment["ISSA_RELEASE_RUN"] == "1"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        if writing {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
        }
        var checked = 0
        for (key, path) in try Self.books() {
            let fresh = Self.render(path: path)
            let file = Self.goldenDirectory.appending(path: "\(key).json")
            if writing {
                try encoder.encode(fresh).write(to: file, options: .atomic)
                continue
            }
            guard let data = try? Data(contentsOf: file) else { continue }
            let golden = try JSONDecoder().decode(Book.self, from: data)
            #expect(golden.failed == fresh.failed, "\(key): whether the book opens changed")
            #expect(golden.chapters.count == fresh.chapters.count, "\(key): the spine changed")
            for (old, new) in zip(golden.chapters, fresh.chapters) where old != new {
                Issue.record("\(key) spine \(old.spineIndex) (\(old.href)) no longer renders to its golden string")
            }
            checked += 1
        }
        if !writing, checked == 0 {
            // Nothing written yet. A release run must see the contract checked.
            if releaseRun {
                Issue.record("""
                    No parity goldens in \(Self.goldenDirectory.path). Write them once with \
                    ISSA_WRITE_PARITY_GOLDENS=1 swift test --filter ParityGoldenTests and commit them.
                    """)
            }
        }
    }
}

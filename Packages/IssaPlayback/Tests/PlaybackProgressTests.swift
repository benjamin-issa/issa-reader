import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// What a progress bar stands for, and what dragging it means.
///
/// The same numbers appear on the player, on the mini bar's hairline, on the
/// Lock Screen and in the car. A bar that disagrees with its own times is worse
/// than one that is merely coarse, so all four read this one value — and the
/// drag has to be its exact inverse, or a scrub on a chapter-scoped Lock Screen
/// lands somewhere else entirely in the book.
@Suite("Scoping a progress bar")
struct PlaybackProgressTests {
    /// Peter and Wendy: 5h 04m, a chapter running from 1:00:00 to 1:30:00.
    static let book: TimeInterval = 18_240
    static let chapter = (start: TimeInterval(3600), duration: TimeInterval(1800))

    static func progress(_ scope: ProgressScope, at bookProgress: Double,
                         span: (start: TimeInterval, duration: TimeInterval)? = chapter) -> PlaybackProgress {
        PlaybackProgress(scope: scope, bookProgress: bookProgress,
                         totalDuration: book, chapterSpan: span)
    }

    // MARK: - Whole book, which must not change

    @Test("the whole book is the bar it has always been")
    func bookScope() {
        let p = Self.progress(.book, at: 0.25)
        #expect(p.isChapterScoped == false)
        #expect(p.fraction == 0.25)
        #expect(p.elapsed == Self.book * 0.25)
        #expect(p.remaining == Self.book * 0.75)
    }

    // MARK: - Chapter

    @Test("a chapter bar measures the chapter, not the book")
    func chapterScope() {
        // Ten minutes into a thirty-minute chapter that starts at one hour.
        let p = Self.progress(.chapter, at: 4200 / Self.book)
        #expect(p.isChapterScoped)
        #expect(abs(p.elapsed - 600) < 0.001)
        #expect(abs(p.remaining - 1200) < 0.001)
        #expect(abs(p.fraction - 1.0 / 3.0) < 0.0001)
    }

    @Test("the bar reads zero at the start of a chapter and full at its end")
    func chapterEnds() {
        let atStart = Self.progress(.chapter, at: 3600 / Self.book)
        #expect(atStart.fraction == 0)
        #expect(abs(atStart.remaining - 1800) < 0.001)

        let atEnd = Self.progress(.chapter, at: 5400 / Self.book)
        #expect(abs(atEnd.fraction - 1) < 0.0001)
        #expect(atEnd.remaining < 0.001)
    }

    /// The moment a chapter changes, the position is briefly still in the old
    /// one — or already in the next. Neither may run the bar off its ends.
    @Test("a position outside the chapter clamps rather than overflowing")
    func outsideTheChapter() {
        let before = Self.progress(.chapter, at: 60 / Self.book)
        #expect(before.fraction == 0)
        #expect(before.elapsed == 0)

        let after = Self.progress(.chapter, at: 9000 / Self.book)
        #expect(after.fraction == 1)
        #expect(after.remaining == 0)
    }

    // MARK: - Falling back rather than dividing by zero

    @Test("a book with no chapters falls back to the whole book")
    func noSpan() {
        let p = Self.progress(.chapter, at: 0.25, span: nil)
        #expect(p.isChapterScoped == false)
        #expect(p.fraction == 0.25)
    }

    @Test("a chapter of no length falls back rather than dividing by zero")
    func zeroLengthSpan() {
        let p = Self.progress(.chapter, at: 0.25, span: (start: 3600, duration: 0))
        #expect(p.isChapterScoped == false)
        #expect(p.fraction == 0.25)
    }

    @Test("a duration that has not loaded yet yields a bar at zero, not a crash")
    func noDuration() {
        for total in [TimeInterval(0), .nan, .infinity, -5] {
            let p = PlaybackProgress(scope: .chapter, bookProgress: 0.5,
                                     totalDuration: total, chapterSpan: Self.chapter)
            #expect(p.fraction == 0)
            #expect(p.elapsed == 0)
            #expect(p.bookProgress(forFraction: 0.5) == 0)
        }
    }

    @Test("a non-finite position is treated as the beginning")
    func nonFiniteProgress() {
        for value in [Double.nan, .infinity, -1, 2] {
            let p = Self.progress(.chapter, at: value)
            #expect(p.fraction.isFinite)
            #expect(p.fraction >= 0 && p.fraction <= 1)
        }
    }

    @Test("a chapter claiming to run past the end of the book is trimmed to it")
    func spanBeyondTheBook() {
        let p = Self.progress(.chapter, at: 0.99, span: (start: 18_000, duration: 9999))
        #expect(p.elapsed <= p.spanDuration)
        #expect(p.spanStart + p.spanDuration <= Self.book + 0.001)
    }

    // MARK: - The inverse, which is what makes a drag land where it says

    @Test("dragging to a fraction means the position the bar drew there",
          arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
    func roundTrip(_ fraction: Double) {
        for scope in ProgressScope.allCases {
            let start = Self.progress(scope, at: 0.3)
            let target = start.bookProgress(forFraction: fraction)
            let after = Self.progress(scope, at: target)
            #expect(abs(after.fraction - fraction) < 0.0001,
                    "\(scope) round trip lost \(fraction) → \(after.fraction)")
        }
    }

    @Test("a chapter drag stays inside its chapter")
    func dragStaysInTheChapter() {
        let p = Self.progress(.chapter, at: 4200 / Self.book)
        let atStart = p.bookProgress(forFraction: 0) * Self.book
        let atEnd = p.bookProgress(forFraction: 1) * Self.book
        #expect(abs(atStart - 3600) < 0.001)
        #expect(abs(atEnd - 5400) < 0.001)
    }

    /// The Lock Screen reports a drag in the same units as the duration it was
    /// given, so this has to invert exactly what `publish` sent.
    @Test("a Lock Screen scrub in seconds inverts what was published")
    func secondsInverse() {
        let p = Self.progress(.chapter, at: 4200 / Self.book)
        // iOS was told the bar is `spanDuration` long and `elapsed` in.
        let position = p.bookProgress(forSeconds: p.elapsed) * Self.book
        #expect(abs(position - 4200) < 0.001)
        // Dragging to the middle of the chapter is 15 minutes in.
        let middle = p.bookProgress(forSeconds: 900) * Self.book
        #expect(abs(middle - 4500) < 0.001)
    }

    @Test("a scrub past either end of the bar clamps into the book")
    func scrubOutOfRange() {
        let p = Self.progress(.chapter, at: 4200 / Self.book)
        #expect(p.bookProgress(forFraction: -1) >= 0)
        #expect(p.bookProgress(forFraction: 5) <= 1)
        #expect(p.bookProgress(forSeconds: -100) >= 0)
        #expect(p.bookProgress(forSeconds: 99_999) <= 1)
    }
}

/// The read-along's idea of a chapter: a spine text document.
@Suite("Chapter extents on the narration timeline")
struct DocumentSpanTests {
    static func timeline() throws -> SMILTimeline {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        return SMILParser.timeline(for: try EPUBPackage.open(url: url))
    }

    @Test("a document's span runs from its first sentence to its last")
    func span() throws {
        let timeline = try Self.timeline()
        let href = "OEBPS/ch01.xhtml"
        let entries = timeline.entries(inDocument: href)
        let span = try #require(timeline.span(ofDocument: href))

        let first = try #require(entries.first)
        let last = try #require(entries.last)
        #expect(abs(span.start - (first.cumulativeEnd - first.duration)) < 0.0001)
        #expect(abs(span.start + span.duration - last.cumulativeEnd) < 0.0001)
    }

    @Test("the first document starts at the beginning of the book")
    func firstDocument() throws {
        let timeline = try Self.timeline()
        let href = try #require(timeline.entries.first?.textHref)
        let span = try #require(timeline.span(ofDocument: href))
        #expect(span.start < 0.0001)
    }

    @Test("the last document ends at the end of the book")
    func lastDocument() throws {
        let timeline = try Self.timeline()
        let href = try #require(timeline.entries.last?.textHref)
        let span = try #require(timeline.span(ofDocument: href))
        #expect(abs(span.start + span.duration - timeline.totalDuration) < 0.0001)
    }

    @Test("documents tile the book without gaps or overlaps")
    func documentsTile() throws {
        let timeline = try Self.timeline()
        var seen: [String] = []
        for entry in timeline.entries where seen.last != entry.textHref {
            seen.append(entry.textHref)
        }
        var previousEnd: TimeInterval = 0
        for href in seen {
            let span = try #require(timeline.span(ofDocument: href))
            #expect(abs(span.start - previousEnd) < 0.0001, "\(href) does not follow the one before")
            previousEnd = span.start + span.duration
        }
        #expect(abs(previousEnd - timeline.totalDuration) < 0.0001)
    }

    @Test("a document with no narration has no span")
    func unknownDocument() throws {
        let timeline = try Self.timeline()
        #expect(timeline.span(ofDocument: "OEBPS/not-a-chapter.xhtml") == nil)
    }

    @Test("an empty timeline has no spans at all")
    func emptyTimeline() {
        #expect(SMILTimeline(entries: []).span(ofDocument: "anything") == nil)
    }
}

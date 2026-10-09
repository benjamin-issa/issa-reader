import Foundation

/// Where turning past the end of a chapter lands.
///
/// One rule, used twice. `ReaderModel.move(toChapter:landingOnLastPage:)` walks
/// it when a turn crosses a chapter boundary, and the neighbouring-chapter
/// prefetch walks it ahead of time so that a slide can cross the boundary like
/// any other page. If the two ever disagreed, the page drawn sliding in would
/// not be the page the turn arrived at — so neither has a copy of the rule.
///
/// The rule itself is the one turning pages has always had. Gutenberg EPUBs put
/// wrapper items between chapters, sometimes several together, so a chapter
/// with nothing on it is stepped over; a chapter that will not open is stepped
/// over too, and named, rather than ending the turn. A bound rather than a loop,
/// so a book that is empty from here on cannot spin.
@MainActor
enum ChapterWalk {
    /// What trying one chapter found.
    enum Attempt: Equatable {
        /// Something to stop on: prose, or a plate.
        case content
        /// Opened, and nothing on it.
        case empty
        /// Would not open.
        case unreadable
        /// The walk is no longer wanted — the prefetch it belonged to went
        /// stale. Stops at once and lands nowhere.
        case abandoned
    }

    struct Landing: Equatable {
        /// The chapter the turn lands in: the first with content, or failing
        /// that the last one that opened at all. Nil when none opened.
        var chapter: Int?
        /// The chapters stepped over because they would not open, in the order
        /// they were tried. The first is the one the reader is told about.
        var skipped: [Int] = []
        var abandoned = false
    }

    /// How many chapters in a row a turn may step over before giving up.
    static let limit = 8

    /// - Parameters:
    ///   - start: the first chapter to try.
    ///   - step: +1 forward, −1 back.
    ///   - attempt: opens one chapter and says what it found. Not escaping, so
    ///     a caller can keep what it opened in a local.
    static func walk(
        from start: Int, step: Int, spineCount: Int,
        attempt: (Int) async -> Attempt,
    ) async -> Landing {
        var target = start
        var landing = Landing()
        for _ in 0 ..< limit {
            guard (0 ..< spineCount).contains(target) else { break }
            switch await attempt(target) {
            case .content:
                landing.chapter = target
                return landing
            case .empty:
                // Kept, and walked past: if nothing after it has content
                // either, this is still somewhere the turn can land.
                landing.chapter = target
            case .unreadable:
                landing.skipped.append(target)
            case .abandoned:
                return Landing(chapter: nil, skipped: landing.skipped, abandoned: true)
            }
            target += step
        }
        return landing
    }

    /// A chapter is empty only if it has neither prose nor an illustration.
    /// A full-page image is content worth stopping on.
    static func isEmpty(_ text: String) -> Bool {
        if text.contains("\u{FFFC}") { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4
    }
}

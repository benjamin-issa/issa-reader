import Foundation

/// How far into the book the reader has actually got — the line past which the
/// model is never shown anything.
///
/// A value type captured on the main actor at the moment of asking, then
/// carried through retrieval, ranking, the prompt and the answer's footer. It
/// is deliberately not a live reading of the reader's position: an answer that
/// takes twenty seconds must be bounded by where the reader was when they
/// asked, not by wherever they have turned to since, and the footer that tells
/// them "no further than Chapter I, page 6" has to name the same place the SQL
/// used.
public struct ReadingBoundary: Sendable, Hashable, Codable {
    /// What fixed the boundary here, which is the difference between "the end
    /// of the page you can see" and "the sentence being read to you".
    public enum Kind: String, Sendable, Codable {
        /// The end of the painted range of the page on screen.
        case pageEnd
        /// The end of the sentence narration is currently speaking.
        case narratedSentence
    }

    /// Index into `EPUBPackage.spine`.
    public var spineIndex: Int
    /// UTF-16 offset into the chapter's *rendered* string — the same string the
    /// index stores, which is why `ArchiveImageSource` is not optional.
    public var charOffset: Int
    /// For the answer's footer only. Never sent to the model: a navigation
    /// title such as "Down the Rabbit-Hole" identifies the book outright.
    public var chapterTitle: String
    /// One-based page within the chapter, for the footer. Nil when the caller
    /// has no pagination (a test, or an index built before any layout).
    public var pageNumber: Int?
    public var kind: Kind

    public init(
        spineIndex: Int,
        charOffset: Int,
        chapterTitle: String = "",
        pageNumber: Int? = nil,
        kind: Kind = .pageEnd,
    ) {
        self.spineIndex = spineIndex
        self.charOffset = charOffset
        self.chapterTitle = chapterTitle
        self.pageNumber = pageNumber
        self.kind = kind
    }

    /// What the answer's footer says about where the answer stopped.
    ///
    /// Built here rather than in the view so the sentence is derived from the
    /// boundary that was actually enforced, and cannot drift from it.
    public func footer(deviceNoun: String) -> String {
        var place = chapterTitle.isEmpty ? "what you've read" : chapterTitle
        if let pageNumber, !chapterTitle.isEmpty {
            place += ", page \(pageNumber)"
        }
        return "Answered on this \(deviceNoun) from \(place) — no further. It can still be wrong."
    }
}

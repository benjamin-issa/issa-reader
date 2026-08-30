import Foundation
import IssaEPUB

/// Finding a phrase in a chapter, and saying which chapter it was in.
///
/// Pure text work, kept out of the reader model so it can be tested without a
/// layout, a session or a screen.
public enum BookSearch {
    public struct Hit: Identifiable, Hashable, Sendable {
        public let chapterIndex: Int
        public let chapterTitle: String
        public let charOffset: Int
        /// The match with enough either side to recognise it.
        public let excerpt: String
        /// Where the match sits inside `excerpt`, for emphasising it.
        public let excerptMatchRange: Range<String.Index>

        public var id: String { "\(chapterIndex)-\(charOffset)" }
    }

    /// Every match in one chapter, labelled with the section it falls in.
    ///
    /// Gutenberg's EPUBs pack a whole book into a handful of files and
    /// distinguish chapters only by anchor, so matching navigation entries on
    /// href alone would label every hit in *Peter and Wendy* "Peter and Wendy".
    public static func hits(
        for needle: String,
        in haystack: String,
        chapterIndex: Int,
        chapterTitle: String,
        navigation: [EPUBPackage.NavPoint] = [],
        fragmentRanges: [String: NSRange] = [:],
        limitPerChapter: Int = 40,
    ) -> [Hit] {
        // Anchors sorted once, so labelling each hit is a scan rather than a
        // search through the whole navigation document per match.
        let anchors = navigation
            .compactMap { point -> (location: Int, title: String)? in
                guard let fragment = point.fragment,
                      let range = fragmentRanges[fragment] else { return nil }
                return (range.location, point.title)
            }
            .sorted { $0.location < $1.location }

        let text = haystack as NSString
        var hits: [Hit] = []
        var from = 0
        while from < text.length, hits.count < limitPerChapter {
            let found = text.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: from, length: text.length - from),
            )
            guard found.location != NSNotFound else { break }

            let start = max(0, found.location - 40)
            let end = min(text.length, NSMaxRange(found) + 60)
            let excerpt = text.substring(with: NSRange(location: start, length: end - start))
                .replacingOccurrences(of: "\n", with: " ")
            // Locate the match inside the excerpt rather than assuming an
            // offset: the excerpt may have been clipped at the start of the
            // text, so the match is not always forty characters in.
            let matchRange = excerpt.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                ?? excerpt.startIndex ..< excerpt.startIndex
            // Before the first anchor there is no chapter yet, so the file's own
            // title is the honest answer rather than the first chapter's.
            let label = anchors.last { $0.location <= found.location }?.title ?? chapterTitle
            hits.append(Hit(
                chapterIndex: chapterIndex, chapterTitle: label,
                charOffset: found.location, excerpt: excerpt, excerptMatchRange: matchRange,
            ))
            from = NSMaxRange(found)
        }
        return hits
    }
}

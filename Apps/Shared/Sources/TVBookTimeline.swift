import Foundation
import IssaCore
import IssaEPUB

/// Where the chapters fall along the whole book, and how to say so in words.
///
/// The television draws one strip for the book with a mark on it per chapter,
/// which is the only "where am I" a remote can give: there is no scrubber to
/// drag and no list to scroll while the voice is talking.
///
/// The ticks and the marker must be measured on the **same clock**, or a
/// chapter mark sits on the wrong side of the reader's own position — a book
/// that is 40% read by audio time is rarely 40% read by byte weight, and two
/// clocks on one strip is worse than no strip. So a narrated book measures both
/// in audio time and a plain ebook measures both by spine weight.
///
/// Pure, and in `Apps/Shared` rather than beside `TVReadalongView`, because the
/// tvOS target has no test bundle: this compiles into iOS as well, and
/// `IssaSharedTests` runs there.
enum TVBookTimeline {
    /// One chapter mark: where it falls in the book, and what it is called.
    struct Tick: Equatable, Sendable {
        let title: String
        /// 0...1 along the book, on whichever clock built it.
        let fraction: Double
    }

    /// Two fractions this close together are the same mark.
    ///
    /// Gutenberg packs a whole book into a handful of files, so on the spine
    /// clock every chapter in one file lands on that file's own start — a
    /// seventeen-chapter book would draw seventeen marks in four places, four
    /// of them stacked into a blot.
    private static let sameTick = 0.0005

    // MARK: - Building the marks

    /// One element id in a document, and where it sits in the markup.
    struct Anchor: Equatable, Sendable {
        let id: String
        /// Byte offset of the attribute within the document.
        let offset: Int
    }

    /// The chapter marks for a book, on the clock the book is read by.
    ///
    /// Reads the spine documents a chapter anchor points into, so it is worth
    /// running off the main actor — everything it touches is `Sendable`.
    ///
    /// - Parameter timeline: the media overlay, when the book is narrated.
    ///   `nil` — or empty — falls back to spine weight, which is what a plain
    ///   ebook on the TV shelf gets.
    static func ticks(for package: EPUBPackage, timeline: SMILTimeline?) -> [Tick] {
        let narrated = (timeline?.isEmpty == false) ? timeline : nil
        let points = package.navigation.filter { $0.depth == 0 }
        let raw = points.isEmpty
            ? sections(for: package, timeline: narrated)
            : navigationTicks(points, package: package, timeline: narrated)
        return dedupe(raw)
    }

    /// Marks from the book's own navigation.
    private static func navigationTicks(
        _ points: [EPUBPackage.NavPoint], package: EPUBPackage, timeline: SMILTimeline?,
    ) -> [Tick] {
        let spineIndices = Dictionary(
            package.spine.enumerated().map { ($0.element.href, $0.offset) },
            uniquingKeysWith: { first, _ in first },
        )
        // Read at most once per document, and only for a chapter whose anchor
        // the cheap lookups could not place.
        var documents: [String: (anchors: [Anchor], length: Int)] = [:]
        func document(_ href: String) -> (anchors: [Anchor], length: Int) {
            if let held = documents[href] { return held }
            let data = (try? package.archive.read(href)) ?? Data()
            let read = (anchors(in: data), data.count)
            documents[href] = read
            return read
        }

        return points.compactMap { point in
            guard let index = spineIndices[point.href] else { return nil }
            guard let fraction = fraction(
                ofSpineItem: index, fragment: point.fragment,
                in: package, timeline: timeline, document: document,
            ) else { return nil }
            return Tick(title: point.title, fraction: fraction)
        }
    }

    /// Marks for a book with no navigation at all.
    ///
    /// One per spine document, numbered. "Section 3" rather than a made-up
    /// chapter name: the file is the only boundary such a book actually has,
    /// and calling it a chapter would claim more than is known.
    private static func sections(for package: EPUBPackage, timeline: SMILTimeline?) -> [Tick] {
        package.spine.indices.compactMap { index in
            guard let fraction = fraction(
                ofSpineItem: index, fragment: nil,
                in: package, timeline: timeline, document: { _ in ([], 0) },
            ) else { return nil }
            return Tick(title: "Section \(index + 1)", fraction: fraction)
        }
    }

    /// Where one chapter start falls, on whichever clock is running.
    ///
    /// On the audio clock a document with no narration has no position at all —
    /// there is no time on the tape that is "inside" it — so it is skipped
    /// rather than guessed at. On the spine clock every document has a place.
    private static func fraction(
        ofSpineItem index: Int, fragment: String?,
        in package: EPUBPackage, timeline: SMILTimeline?,
        document: (String) -> (anchors: [Anchor], length: Int),
    ) -> Double? {
        guard package.spine.indices.contains(index) else { return nil }
        let href = package.spine[index].href

        guard let timeline else {
            // No narration: the reader's clock is byte weight, so a chapter's
            // place inside its file is its anchor's place in the markup.
            //
            // A nav entry naming no fragment is the whole file, and the file's
            // own start is a real answer for it.
            guard let fragment else {
                return package.bookProgress(spineIndex: index, within: 0)
            }
            // A named anchor the markup has not got is not a chapter at the top
            // of the file; it is a chapter nobody can place. `?? 0` said the top
            // of the file anyway, which reads as a real position — and since
            // every unplaceable chapter in a file said the same thing, `dedupe`
            // then stacked them all onto one tick. Dropped instead, the way the
            // audio branch below already drops a document with no narration.
            guard let place = within(fragment, of: document(href)) else { return nil }
            return package.bookProgress(spineIndex: index, within: place)
        }

        let total = timeline.totalDuration
        guard total > 0 else { return nil }
        if let fragment, let moment = time(
            of: fragment, inDocument: href, timeline: timeline, document: document,
        ) {
            return (moment / total).asProgression
        }
        guard let span = timeline.span(ofDocument: href) else { return nil }
        return (span.start / total).asProgression
    }

    /// The book time a chapter's anchor stands for.
    ///
    /// The anchor itself is almost never narrated: a media overlay names
    /// sentence spans, and a navigation entry names the heading above them —
    /// Storyteller's aligner writes `chapter-s0`, while Gutenberg's navigation
    /// points at `pgepubid00003`. Looking the anchor up alone therefore failed
    /// for every chapter of a book packed into a handful of files, and all
    /// seventeen marks piled onto their file's start: three marks for a
    /// seventeen-chapter novel, verified on *Peter and Wendy*. So when the
    /// anchor is not itself narrated, the first narrated id *after it in the
    /// markup* stands in — the sentence the voice reaches once the chapter has
    /// begun.
    private static func time(
        of fragment: String, inDocument href: String, timeline: SMILTimeline,
        document: (String) -> (anchors: [Anchor], length: Int),
    ) -> TimeInterval? {
        if let exact = timeline.bookTime(forFragment: fragment, inDocument: href) { return exact }
        guard let narrated = firstNarrated(
            atOrAfter: fragment, in: document(href).anchors,
            isNarrated: { timeline.entry(forFragment: $0, inDocument: href) != nil },
        ) else { return nil }
        return timeline.bookTime(forFragment: narrated, inDocument: href)
    }

    /// How far into its own document an anchor sits, 0...1.
    ///
    /// Measured in bytes of markup, which is the unit `spineWeights` is already
    /// in — so a chapter's place inside its file and the file's place in the
    /// book are weighed the same way.
    private static func within(
        _ fragment: String, of document: (anchors: [Anchor], length: Int),
    ) -> Double? {
        guard document.length > 0,
              let anchor = document.anchors.first(where: { $0.id == fragment })
        else { return nil }
        return (Double(anchor.offset) / Double(document.length)).asProgression
    }

    /// The first narrated id at or after an anchor, in markup order.
    static func firstNarrated(
        atOrAfter fragment: String, in anchors: [Anchor], isNarrated: (String) -> Bool,
    ) -> String? {
        guard let start = anchors.firstIndex(where: { $0.id == fragment }) else { return nil }
        return anchors[start...].first { isNarrated($0.id) }?.id
    }

    /// Every element id in a document, in the order the markup declares them.
    ///
    /// A scan rather than a parse. This runs over a whole novel's markup and
    /// needs only the *order* of the ids — by the time anyone looks at a page
    /// the reader's own parser has already proved the document well formed — so
    /// a second full XML parse would cost hundreds of milliseconds to answer a
    /// question one pass answers.
    ///
    /// The space in front of `id` is what keeps `data-id` and the like out.
    ///
    /// **Either quote, terminating on whichever opened.** One byte used to do
    /// both jobs, so `<h2 id='chapter-3'>` — which is what Sigil and Calibre
    /// write — matched nothing at all: `within` then failed for every chapter in
    /// the file, they all fell back to the file's own start, and `dedupe`
    /// collapsed them into a single tick. That is exactly the "seventeen marks
    /// in three places" defect this whole path exists to prevent. Terminating on
    /// the opener rather than on either quote is what keeps an apostrophe inside
    /// a double-quoted id — `id="it's-here"` — from cutting the id in half.
    ///
    /// Read in place. `[UInt8](data)` copied every spine file whole, which
    /// `navigationTicks` above notes are megabytes on a long novel, and
    /// comparing `Array(bytes[i ..< i + 4]) == pattern` allocated a four-byte
    /// array on every candidate byte in them.
    static func anchors(in data: Data) -> [Anchor] {
        let i = UInt8(ascii: "i")
        let d = UInt8(ascii: "d")
        let equals = UInt8(ascii: "=")
        let double = UInt8(ascii: "\"")
        let single = UInt8(ascii: "'")
        return data.withUnsafeBytes { bytes -> [Anchor] in
            let count = bytes.count
            var found: [Anchor] = []
            var index = 1
            // `id=` and its opening quote are four bytes starting at `index`,
            // with the space that qualifies them at `index - 1`, so the last
            // position worth testing is `count - 4`.
            while index + 4 <= count {
                guard bytes[index] == i, isSpace(bytes[index - 1]),
                      bytes[index + 1] == d, bytes[index + 2] == equals
                else {
                    index += 1
                    continue
                }
                let opener = bytes[index + 3]
                guard opener == double || opener == single else {
                    index += 1
                    continue
                }
                let valueStart = index + 4
                var end = valueStart
                while end < count, bytes[end] != opener { end += 1 }
                // An unterminated attribute is markup nobody can read. Stopping
                // is what keeps the scan inside the buffer.
                guard end < count else { break }
                if end > valueStart,
                   let id = String(bytes: bytes[valueStart ..< end], encoding: .utf8) {
                    found.append(Anchor(id: id, offset: index))
                }
                index = end + 1
            }
            return found
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    /// In book order, with marks that land in the same place collapsed to one.
    ///
    /// Sorted by position rather than trusted in navigation order: a nav
    /// document may list an appendix before the chapter it belongs to, and a
    /// strip drawn in the wrong order would put the "current chapter" highlight
    /// on the wrong mark.
    private static func dedupe(_ ticks: [Tick]) -> [Tick] {
        let sorted = ticks
            .filter { $0.fraction.isFinite }
            .enumerated()
            .sorted { left, right in
                left.element.fraction == right.element.fraction
                    ? left.offset < right.offset
                    : left.element.fraction < right.element.fraction
            }
            .map(\.element)
        var kept: [Tick] = []
        for tick in sorted {
            if let last = kept.last, abs(tick.fraction - last.fraction) < sameTick { continue }
            kept.append(tick)
        }
        return kept
    }

    // MARK: - Reading the marks

    /// Which chapter a position is in.
    ///
    /// The last mark at or before the reader. A position before the first mark
    /// — front matter, a cover, a dedication — belongs to the first chapter
    /// rather than to nothing: "Chapter 0 of 17" is not a thing to show anyone.
    static func currentIndex(in ticks: [Tick], fraction: Double) -> Int? {
        guard !ticks.isEmpty else { return nil }
        let place = fraction.asProgression ?? 0
        var found = 0
        for (index, tick) in ticks.enumerated() where tick.fraction <= place {
            found = index
        }
        return found
    }

    // MARK: - Saying it in words

    /// The footer's one line: "Chapter 12 of 17 · 34% · 1h 11m left".
    ///
    /// Every part is dropped when the book cannot supply it — a book with no
    /// navigation has no chapter ordinal, a plain ebook has nothing left to
    /// play — rather than shown empty or as a zero. The canvas above says the
    /// same thing as a picture and is hidden from VoiceOver, so this line is
    /// the accessible version of the strip as well as the readable one.
    static func progressLine(
        chapter: Int?, count: Int, progress: Double, remaining: TimeInterval?,
    ) -> String {
        var parts: [String] = []
        if let chapter, count > 0, chapter >= 1, chapter <= count {
            parts.append("Chapter \(chapter) of \(count)")
        }
        parts.append(ReadingProgress.percentText(progress))
        if let remaining, remaining.isFinite, remaining > 0 {
            parts.append("\(durationText(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// A rough length, the way a person says it: "1h 11m", or "11m" under
    /// the hour. Never seconds — nobody across a room cares, and a number that
    /// ticks every second draws the eye off the page.
    ///
    /// Rounded to the nearest minute rather than truncated, which is what the
    /// old readout did: fifty-nine seconds of a book left is "1m", not "0m".
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let whole = Int((seconds / 60).rounded())
        let hours = whole / 60
        let minutes = whole % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

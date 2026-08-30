import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import IssaRender
import Observation
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Drives one open book: downloads it, lays out chapters, tracks position.
@Observable
@MainActor
public final class ReaderModel {
    public enum Phase: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading("Opening…")
    public internal(set) var package: EPUBPackage?
    public private(set) var timeline: SMILTimeline?
    public private(set) var layout: ChapterLayout?
    public private(set) var chapterIndex = 0
    public var pageIndex = 0
    /// Fragment currently narrated, when audio is playing.
    public var activeFragmentID: String?
    /// Present only when the book has usable media overlays.
    public private(set) var readalong: ReadalongCoordinator?

    public var hasNarration: Bool { readalong != nil }
    public var isPlaying: Bool { readalong?.player.isPlaying ?? false }

    public var style: ReaderStyle {
        didSet {
            guard style != oldValue else { return }
            // Typography lives in the attributed text, which is immutable once
            // built, so a font or spacing change needs the chapter parsed again
            // — re-flowing alone would keep the old face at the old size. Page
            // size, and only page size, can be handled by re-flowing.
            let needsReparse = style.fontFamily != oldValue.fontFamily
                || style.fontSize != oldValue.fontSize
                || style.lineSpacing != oldValue.lineSpacing
                || style.justified != oldValue.justified
                || style.theme != oldValue.theme
            Task { await needsReparse ? reloadCurrentChapter() : relayoutCurrentChapter() }
        }
    }

    public let book: Book
    private let session: Session

    /// Exposed so the player sheet can load cover art through the same client.
    public var readerSession: Session { session }
    private var pageSize: CGSize = .zero
    private var saveTask: Task<Void, Never>?

    /// Playback rate to start narration at, supplied by the app's preferences.
    public var preferredRate: Double = 1.0
    /// Records a position durably before it is sent. Supplied by the app so the
    /// reader does not need to know about the store.
    /// Persisting annotations is the app's job, not the reader's: this model
    /// knows the geometry, the store knows the disk.
    public var onSaveAnnotation: ((Annotation) -> Void)?
    public var onDeleteAnnotation: ((Annotation) -> Void)?

    public var enqueuePosition: ((ReadiumLocator, Double) async -> Void)?
    private static var lastPublishedCoverBookID: String?

    public init(book: Book, session: Session, style: ReaderStyle = ReaderStyle()) {
        self.book = book
        self.session = session
        self.style = style
    }

    public var chapterTitle: String {
        guard let package, chapterIndex < package.spine.count else { return book.title }
        return title(inSpineItem: chapterIndex, atOffset: currentPage?.characterRange.location ?? 0)
            ?? book.title
    }

    /// The chapter name for a place inside a spine document.
    ///
    /// Gutenberg's EPUBs pack a whole book into a handful of files and
    /// distinguish chapters only by fragment id, so matching on href alone
    /// labels every page of a book "Peter and Wendy". This finds the last
    /// navigation entry whose anchor appears at or before the offset — which is
    /// the chapter the reader is actually in.
    func title(inSpineItem index: Int, atOffset offset: Int) -> String? {
        guard let package, package.spine.indices.contains(index) else { return nil }
        let href = package.spine[index].href
        let entries = package.navigation.filter { $0.href == href }
        guard !entries.isEmpty else { return nil }

        // Only the loaded chapter has ranges to compare against; for any other
        // spine item the first entry is the best available answer.
        guard index == chapterIndex, let layout else { return entries.first?.title }

        var best: (title: String, location: Int)?
        for entry in entries {
            guard let fragment = entry.fragment,
                  let range = layout.fragmentRange(for: fragment) else { continue }
            if range.location <= offset, range.location >= (best?.location ?? -1) {
                best = (entry.title, range.location)
            }
        }
        return best?.title ?? entries.first?.title
    }

    /// How far through the whole book the reader is, for Handoff and the
    /// widget snapshot.
    public var bookProgress: Double {
        guard let package, !package.spine.isEmpty, let layout, let page = currentPage else {
            return book.progress ?? 0
        }
        return (Double(chapterIndex) + layout.progression(of: page)) / Double(package.spine.count)
    }

    /// The words on the current page, for VoiceOver and for copying the page.
    public var currentPageText: String {
        guard let layout, let page = currentPage else { return "" }
        let text = layout.attributedText.string as NSString
        guard NSMaxRange(page.characterRange) <= text.length else { return "" }
        return text.substring(with: page.characterRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var pageCount: Int { layout?.pages.count ?? 0 }
    public var currentPage: RenderedPage? {
        guard let layout, layout.pages.indices.contains(pageIndex) else { return nil }
        return layout.pages[pageIndex]
    }

    public func open(pageSize: CGSize) async {
        self.pageSize = pageSize
        let content = BookContentService(client: session.client)
        guard let format = content.preferredReadingFormat(for: book) else {
            phase = .failed("This book has no readable edition on the server.")
            return
        }

        phase = .loading(content.isDownloaded(book, format: format) ? "Opening…" : "Downloading…")
        do {
            let url = try await content.ensureDownloaded(book, format: format)
            let package = try EPUBPackage.open(url: url)
            self.package = package
            // A book the server calls ALIGNED can still carry no overlays, so
            // narration is offered only when the timeline actually has entries.
            let timeline = SMILParser.timeline(for: package)
            self.timeline = timeline.isEmpty ? nil : timeline

            // Resume where the server says we were, before the first render, so
            // the reader never flashes page one and then jumps.
            let stored = try? await ProgressService(client: session.client).current(for: book.uuid)
            chapterIndex = stored.flatMap { position in
                package.spine.firstIndex { position.locator.matchesHref($0.href) }
            } ?? Self.firstReadableChapter(in: package, style: style)

            await loadChapter(chapterIndex, restoring: stored?.locator)
            await prepareNarration(package: package)
            phase = .ready
        } catch {
            phase = .failed(AppModel.message(for: error))
        }
    }

    /// The first spine item with actual prose.
    ///
    /// Real books routinely open on a cover wrapper that holds a single image
    /// and no text — Gutenberg EPUBs all do. Opening on spine item zero would
    /// therefore show a blank page, and the reader would look broken before it
    /// had rendered a word.
    static func firstReadableChapter(in package: EPUBPackage, style: ReaderStyle = ReaderStyle()) -> Int {
        for (index, item) in package.spine.enumerated() {
            guard let data = try? package.archive.read(item.href),
                  let parsed = try? HTMLContentParser(style: style).parse(xhtml: data, baseHref: item.href)
            else { continue }
            if parsed.text.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                return index
            }
        }
        return 0
    }

    /// Extracts the embedded narration and hooks the audio clock to the page.
    ///
    /// Only runs when the timeline is non-empty, so a book the server reports as
    /// ALIGNED but which carries no overlays simply reads as a plain ebook
    /// rather than showing a player that can never play anything.
    private func prepareNarration(package: EPUBPackage) async {
        guard let timeline, !timeline.isEmpty else { return }
        guard let files = try? AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: book.uuid,
        ), !files.isEmpty else { return }

        let coordinator = ReadalongCoordinator(timeline: timeline, audioFiles: files)
        // The saved rate is otherwise written to preferences and never applied,
        // so every book starts at 1x however the reader left it.
        coordinator.player.rate = Float(preferredRate)
        coordinator.onFragmentChange = { [weak self] fragment in
            guard let self else { return }
            activeFragmentID = fragment
            // Listening moves the position as surely as turning pages does;
            // without this an hour of narration is lost on every other device.
            scheduleSave()
            guard style.followNarration else { return }
            // Keep the narrated sentence on screen. If it is already visible,
            // do not fight the reader by turning the page underneath them.
            if let layout, let page = layout.page(containingFragment: fragment),
               page.index != pageIndex {
                pageIndex = page.index
            }
        }
        coordinator.onChapterChange = { [weak self] href in
            guard let self, let package = self.package else { return }
            guard let index = package.spine.firstIndex(where: { $0.href == href }),
                  index != chapterIndex else { return }
            Task { await self.loadChapter(index) }
        }
        readalong = coordinator
    }

    /// Starts narration at the sentence under a point on the page.
    ///
    /// Returns whether it found one, so the caller can fall back to turning the
    /// page: a tap in the margin, on a heading, or on an illustration has to
    /// keep doing what a tap always did.
    @discardableResult
    public func playSentence(at point: CGPoint) async -> Bool {
        guard let readalong, let layout, let page = currentPage else { return false }
        guard let fragment = layout.fragmentID(at: point, on: page) else { return false }
        // A fragment id the timeline does not know is an ordinary element id —
        // a chapter heading, say — not a narrated sentence.
        guard timeline?.entry(forFragment: fragment) != nil else { return false }
        // seek(toFragment:) starts playback, which is the point: tapping a
        // sentence in a paused book should begin reading it aloud, not merely
        // move the playhead somewhere the reader cannot hear.
        await readalong.seek(toFragment: fragment)
        return true
    }

    /// Plays the narration for whatever is selected.
    public func playSelection() async {
        guard let selection, let layout, let readalong, let timeline else { return }
        let fragment = layout.attributedText
            .attribute(.issaFragmentID, at: selection.location, effectiveRange: nil) as? String
        guard let fragment, timeline.entry(forFragment: fragment) != nil else { return }
        await readalong.seek(toFragment: fragment)
    }

    /// Starts narration from whatever the reader is currently looking at.
    ///
    /// Scans forward for the first narrated fragment on the page rather than
    /// reading only the first character: a page often opens mid-paragraph, or on
    /// a heading that carries no media overlay at all.
    public func startNarration() async {
        guard let readalong else { return }
        if let fragment = firstFragmentOnCurrentPage() {
            await readalong.seek(toFragment: fragment)
        } else if let first = timeline?.entries.first {
            // Nothing narrated on this page; begin at the start of the book.
            await readalong.play(from: first)
        }
    }

    /// The text of one media-overlay fragment.
    ///
    /// Used by the TV presentation, which shows sentences rather than pages: at
    /// ten feet a paginated book page is unreadable, but one large sentence with
    /// its neighbours for context is comfortable.
    public func text(forFragment fragmentID: String) -> String? {
        guard let layout, let range = layout.fragmentRange(for: fragmentID) else { return nil }
        return (layout.attributedText.string as NSString)
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The narrated sentence, plus the one before and after it.
    public func narrationContext() -> (previous: String?, current: String?, next: String?) {
        guard let timeline, let entry = readalong?.activeEntry else { return (nil, nil, nil) }
        return (
            timeline.entry(before: entry).flatMap { text(forFragment: $0.fragmentID) },
            text(forFragment: entry.fragmentID),
            timeline.entry(after: entry).flatMap { text(forFragment: $0.fragmentID) },
        )
    }

    /// The first media-overlay fragment appearing on the current page.
    func firstFragmentOnCurrentPage() -> String? {
        guard let layout, let page = currentPage, let timeline else { return nil }
        var found: String?
        layout.attributedText.enumerateAttribute(
            .issaFragmentID, in: page.characterRange,
        ) { value, _, stop in
            if let id = value as? String, timeline.entry(forFragment: id) != nil {
                found = id
                stop.pointee = true
            }
        }
        return found
    }

    public func togglePlayback() async {
        guard let readalong else { return }
        if readalong.player.isPlaying {
            readalong.player.pause()
        } else if readalong.activeEntry == nil {
            await startNarration()
        } else {
            readalong.player.play()
        }
    }

    /// The fine-grained clock is only worth running while the page is visible.
    public func setReaderVisible(_ visible: Bool) {
        readalong?.player.setHighFrequencyUpdates(visible)
    }

    public func resize(to size: CGSize) async {
        guard size != pageSize, size.width > 0, size.height > 0 else { return }
        pageSize = size
        await relayoutCurrentChapter()
    }

    /// Decodes and caches a chapter's artwork, keyed by archive path.
    ///
    /// A chapter asks once per plate, and the cache lives as long as the chapter
    /// does, so reflowing on a font change costs no re-decoding.
    final class ChapterImageSource {
        private let archive: EPUBArchive
        private var decoded: [String: PlatformImage?] = [:]

        init(archive: EPUBArchive) { self.archive = archive }

        func image(for href: String) -> PlatformImage? {
            if let cached = decoded[href] { return cached }
            var result: PlatformImage?
            if let data = try? archive.read(href) {
                result = PlatformImage(data: data)
            }
            decoded[href] = result
            return result
        }
    }

    /// Re-parses the current chapter under the current style, holding position.
    ///
    /// The anchor is the narrated fragment when there is one, and the character
    /// offset otherwise — a page number would move the reader arbitrarily, since
    /// a larger font means more pages.
    private func reloadCurrentChapter() async {
        let fragment = firstFragmentOnCurrentPage()
        let anchor = currentPage?.characterRange.location ?? 0
        await loadChapter(chapterIndex)
        guard let layout else { return }
        if let fragment, let page = layout.page(containingFragment: fragment) {
            pageIndex = page.index
        } else {
            pageIndex = layout.pages.firstIndex { NSLocationInRange(anchor, $0.characterRange) } ?? 0
        }
    }

    private func relayoutCurrentChapter() async {
        guard let layout, pageSize != .zero else { return }
        // Keep the reader on the same words across a reflow rather than the same
        // page number, which would move the reader arbitrarily.
        let anchor = layout.pages.indices.contains(pageIndex)
            ? layout.pages[pageIndex].characterRange.location
            : 0
        layout.layout(pageSize: pageSize)
        pageIndex = layout.pages.firstIndex { NSLocationInRange(anchor, $0.characterRange) } ?? 0
    }

    private func loadChapter(_ index: Int, restoring locator: ReadiumLocator? = nil) async {
        guard let package, package.spine.indices.contains(index) else { return }
        chapterIndex = index
        let item = package.spine[index]
        do {
            let data = try package.archive.read(item.href)
            let images = ChapterImageSource(archive: package.archive)
            let parsed = try HTMLContentParser(
                style: style,
                maxImageWidth: max(pageSize.width, 1),
                loadImage: { images.image(for: $0) },
            ).parse(xhtml: data, baseHref: item.href)
            let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
            layout.layout(pageSize: pageSize)
            self.layout = layout

            if let locator, let offset = LocatorAnchoring.characterOffset(
                for: locator, in: parsed.text.string, fragmentRanges: parsed.fragmentRanges,
            ), let page = layout.page(containingOffset: offset) {
                pageIndex = page.index
            } else {
                pageIndex = 0
            }
        } catch {
            phase = .failed("Couldn't open this chapter. " + AppModel.message(for: error))
        }
    }

    // MARK: - Navigation

    public func nextPage() async {
        guard let layout else { return }
        if pageIndex + 1 < layout.pages.count {
            pageIndex += 1
        } else if let package, chapterIndex + 1 < package.spine.count {
            await loadChapter(chapterIndex + 1)
            pageIndex = 0
            // A full-page illustration renders as an empty chapter today; step
            // over it rather than stranding the reader on a blank page.
            if isCurrentChapterEmpty, chapterIndex + 1 < package.spine.count {
                await loadChapter(chapterIndex + 1)
            }
        }
        scheduleSave()
    }

    public func previousPage() async {
        guard layout != nil else { return }
        if pageIndex > 0 {
            pageIndex -= 1
        } else if chapterIndex > 0 {
            await loadChapter(chapterIndex - 1)
            pageIndex = max((layout?.pages.count ?? 1) - 1, 0)
        }
        scheduleSave()
    }

    /// A chapter is empty only if it has neither prose nor an illustration.
    /// Now that plates render, a full-page image is content worth stopping on.
    private var isCurrentChapterEmpty: Bool {
        guard let layout else { return true }
        let text = layout.attributedText.string
        if text.contains("\u{FFFC}") { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4
    }

    public func go(toChapter index: Int, fragment: String? = nil) async {
        await loadChapter(index)
        // Books that pack many chapters into one spine file need the fragment to
        // land anywhere useful; without it every entry opens page one.
        if let fragment, let layout, let page = layout.page(containingFragment: fragment) {
            pageIndex = page.index
        }
        scheduleSave()
    }

    /// Element ids appearing on the current page, for marking the contents list.
    public func visibleFragments() -> Set<String> {
        guard let layout, let page = currentPage else { return [] }
        var found: Set<String> = []
        layout.attributedText.enumerateAttribute(.issaFragmentID, in: page.characterRange) { value, _, _ in
            if let id = value as? String { found.insert(id) }
        }
        return found
    }

    // MARK: - Searching inside the book

    public typealias SearchHit = BookSearch.Hit

    public private(set) var searchHits: [SearchHit] = []
    public private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?

    /// Searches the whole book, chapter by chapter, publishing as it goes.
    ///
    /// Every chapter has to be parsed to be searched, which for a long book is
    /// too slow to block on — so results appear progressively and the reader can
    /// act on the first hit before the last chapter is read.
    public func search(_ query: String) {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, let package else {
            searchHits = []
            isSearching = false
            return
        }

        searchHits = []
        isSearching = true
        let style = style
        searchTask = Task { [weak self] in
            for (index, item) in package.spine.enumerated() {
                if Task.isCancelled { break }
                guard let data = try? package.archive.read(item.href),
                      let parsed = try? HTMLContentParser(style: style)
                          .parse(xhtml: data, baseHref: item.href)
                else { continue }

                let hits = BookSearch.hits(
                    for: needle, in: parsed.text.string,
                    chapterIndex: index,
                    chapterTitle: package.navigation.first { $0.href == item.href }?.title
                        ?? "Chapter \(index + 1)",
                    navigation: package.navigation.filter { $0.href == item.href },
                    fragmentRanges: parsed.fragmentRanges,
                )
                if Task.isCancelled { break }
                guard let self else { return }
                searchHits.append(contentsOf: hits)
                // Yield between chapters so typing stays responsive on a book
                // with hundreds of spine items.
                await Task.yield()
            }
            self?.isSearching = false
        }
    }

    public func cancelSearch() {
        searchTask?.cancel()
        searchHits = []
        isSearching = false
    }

    /// Jumps to a hit and leaves the matched text selected, so the reader can
    /// see what was found without hunting for it.
    public func go(to hit: SearchHit, matching query: String) async {
        await loadChapter(hit.chapterIndex)
        guard let layout, let page = layout.page(containingOffset: hit.charOffset) else { return }
        pageIndex = page.index
        selection = NSRange(location: hit.charOffset, length: (query as NSString).length)
        scheduleSave()
    }

    // MARK: - Selection and annotations

    /// The characters the reader has selected on this page, if any.
    public private(set) var selection: NSRange?
    /// Annotations for this book, drawn under the text and listed on demand.
    public private(set) var annotations: [Annotation] = []
    private var selectionAnchor: Int?

    public var selectedText: String? {
        guard let selection, let layout else { return nil }
        let text = layout.attributedText.string as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= text.length else { return nil }
        return text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts a selection at a point, selecting the sentence there.
    ///
    /// A long press that selected one character would be useless, and a word is
    /// usually too little to quote — the aligner has already split this text
    /// into sentences, so that is the unit offered first. Dragging then adjusts
    /// it a character at a time.
    public func beginSelection(at point: CGPoint) {
        guard let layout, let page = currentPage,
              let index = layout.characterIndex(at: point, on: page) else { return }
        let range = layout.sentenceRange(at: index) ?? layout.wordRange(at: index)
        selectionAnchor = index
        selection = range
    }

    public func extendSelection(to point: CGPoint) {
        guard let layout, let page = currentPage, let anchor = selectionAnchor,
              let index = layout.characterIndex(at: point, on: page) else { return }
        let lower = min(anchor, index)
        let upper = max(anchor, index)
        // Snap the ends outward to whole words: a selection that stops
        // mid-word looks like a bug, and quoting half a word is never wanted.
        let start = layout.wordRange(at: lower)?.location ?? lower
        let end = layout.wordRange(at: upper).map { NSMaxRange($0) } ?? upper
        selection = NSRange(location: start, length: max(end - start, 1))
    }

    public func clearSelection() {
        selection = nil
        selectionAnchor = nil
    }

    /// Turns the current selection into a highlight, or drops a bookmark at the
    /// top of the page when nothing is selected.
    @discardableResult
    public func annotate(kind: Annotation.Kind, tint: Annotation.Tint = .tangerine) -> Annotation? {
        guard let layout, let page = currentPage else { return nil }
        let range = kind == .bookmark
            ? NSRange(location: page.characterRange.location, length: min(80, page.characterRange.length))
            : (selection ?? NSRange(location: page.characterRange.location, length: 0))
        guard range.length > 0 else { return nil }

        let text = layout.attributedText.string as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        let excerpt = text.substring(with: range)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let annotation = Annotation(
            bookUUID: book.uuid,
            kind: kind,
            tint: tint,
            locator: locator(forRange: range),
            excerpt: excerpt,
            chapterTitle: chapterTitle,
        )
        annotations.append(annotation)
        annotations.sort(by: Annotation.readingOrder)
        onSaveAnnotation?(annotation)
        clearSelection()
        return annotation
    }

    /// Opens the page an annotation is on.
    public func go(to annotation: Annotation) async {
        guard let package else { return }
        if let index = package.spine.firstIndex(where: { annotation.locator.matchesHref($0.href) }),
           index != chapterIndex {
            await loadChapter(index, restoring: annotation.locator)
        } else if let layout, let offset = annotation.locator.locations?.charOffset,
                  let page = layout.page(containingOffset: offset) {
            pageIndex = page.index
        }
        scheduleSave()
    }

    /// Seeds the marks made in earlier sessions.
    public func loadAnnotations(_ stored: [Annotation]) {
        annotations = stored.sorted(by: Annotation.readingOrder)
    }

    public func remove(_ annotation: Annotation) {
        annotations.removeAll { $0.id == annotation.id }
        onDeleteAnnotation?(annotation)
    }

    /// True when this page already carries a bookmark, so the control can be a
    /// toggle rather than a way to accumulate duplicates.
    public var isPageBookmarked: Bool {
        bookmarkOnCurrentPage != nil
    }

    public var bookmarkOnCurrentPage: Annotation? {
        guard let layout, let page = currentPage else { return nil }
        return annotations.first { annotation in
            guard annotation.kind == .bookmark,
                  annotation.locator.matchesHref(package?.spine[chapterIndex].href ?? ""),
                  let offset = annotation.locator.locations?.charOffset
            else { return false }
            _ = layout
            return NSLocationInRange(offset, page.characterRange)
        }
    }

    public func toggleBookmark() {
        if let existing = bookmarkOnCurrentPage {
            remove(existing)
        } else {
            annotate(kind: .bookmark)
        }
    }

    /// Where an annotation on this chapter lives, in the same terms as a
    /// reading position so the two restore through the same code.
    private func locator(forRange range: NSRange) -> ReadiumLocator {
        let href = package?.spine[chapterIndex].href ?? ""
        let total = max((layout?.attributedText.string as NSString?)?.length ?? 1, 1)
        let chapterProgress = Double(range.location) / Double(total)
        let overall = (package?.spine.count ?? 0) > 0
            ? (Double(chapterIndex) + chapterProgress) / Double(package?.spine.count ?? 1)
            : chapterProgress
        let fragment = layout?.attributedText
            .attribute(.issaFragmentID, at: min(range.location, total - 1), effectiveRange: nil) as? String
        return ReadiumLocator(
            href: href,
            type: "application/xhtml+xml",
            title: chapterTitle,
            locations: .init(
                fragments: fragment.map { [$0] },
                progression: chapterProgress,
                totalProgression: overall,
                charOffset: range.location,
            ),
            text: layout.flatMap {
                LocatorAnchoring.quote(from: $0.attributedText.string, at: range.location,
                                       length: min(range.length, 200))
            },
        )
    }

    /// Rectangles for stored highlights that fall on the current page.
    public func highlightRects(on page: RenderedPage) -> [(rect: CGRect, tint: Annotation.Tint)] {
        guard let layout, let package, package.spine.indices.contains(chapterIndex) else { return [] }
        let href = package.spine[chapterIndex].href
        var result: [(CGRect, Annotation.Tint)] = []
        for annotation in annotations where annotation.kind != .bookmark {
            guard annotation.locator.matchesHref(href) else { continue }
            guard let offset = annotation.locator.locations?.charOffset else { continue }
            let length = (annotation.excerpt as NSString).length
            let range = NSRange(location: offset, length: length)
            for rect in layout.rects(forRange: range, on: page) {
                result.append((rect, annotation.tint))
            }
        }
        return result
    }

    // MARK: - Progress

    /// Position writes are debounced: a reader turning pages quickly should not
    /// generate a request per page, and the server treats rapid equal-timestamp
    /// writes as conflicts.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.saveProgress()
        }
    }

    public func saveProgress() async {
        guard let package, let layout, let page = currentPage else { return }
        let href = package.spine[chapterIndex].href

        // Anchor on the first narrated fragment on this page when there is one:
        // it survives a font or margin change, which a page number does not.
        let fragment = layout.attributedText
            .attribute(.issaFragmentID, at: page.characterRange.location, effectiveRange: nil) as? String

        let chapterProgress = layout.progression(of: page)
        let overall = package.spine.isEmpty
            ? 0
            : (Double(chapterIndex) + chapterProgress) / Double(package.spine.count)

        // Two anchors beyond the fragment: the character offset, and the words
        // that were on screen. Between them a position survives a font change,
        // a different device, and a chapter the publisher has since revised.
        let offset = page.characterRange.location
        let locator = ReadiumLocator(
            href: href,
            type: "application/xhtml+xml",
            title: chapterTitle,
            locations: .init(
                fragments: fragment.map { [$0] },
                progression: chapterProgress,
                totalProgression: overall,
                charOffset: offset,
            ),
            text: LocatorAnchoring.quote(from: layout.attributedText.string, at: offset),
        )
        // Recorded locally first: a chapter read with no signal must not be
        // lost, and the drain collapses a run of page turns to one write.
        let timestamp = ProgressService.now()
        if let enqueuePosition {
            await enqueuePosition(locator, timestamp)
        } else {
            _ = try? await ProgressService(client: session.client)
                .save(locator, for: book.uuid, timestamp: timestamp)
        }
        publishSnapshot(progress: overall)
    }

    /// Publishes the small record the widget reads.
    ///
    /// Written only when progress meaningfully moves, not on every tick: the
    /// widget's own reload budget is the scarce resource, and a snapshot the
    /// widget never reads costs a disk write for nothing.
    private func publishSnapshot(progress: Double) {
        // Only when the book changes, not on every page turn: the cover is the
        // same file each time and rewriting it costs a disk write for nothing.
        if Self.lastPublishedCoverBookID != book.uuid {
            Self.lastPublishedCoverBookID = book.uuid
            Task { [book, session = readerSession] in
                await CoverCache.shared.publishCoverToWidget(for: book, session: session)
            }
        }
        let remaining = (book.readaloud?.duration ?? book.audiobook?.duration)
            .map { $0 * (1 - progress) }
        CurrentBookSnapshotStore.write(CurrentBookSnapshot(
            bookID: book.uuid,
            title: book.title,
            author: book.byline,
            chapter: chapterTitle,
            progress: progress,
            remaining: remaining,
            isPlaying: isPlaying,
        ))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "CurrentBook")
        #endif
    }
}

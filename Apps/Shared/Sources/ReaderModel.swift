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
    public var enqueuePosition: ((ReadiumLocator, Double) async -> Void)?

    public init(book: Book, session: Session, style: ReaderStyle = ReaderStyle()) {
        self.book = book
        self.session = session
        self.style = style
    }

    public var chapterTitle: String {
        guard let package, chapterIndex < package.spine.count else { return book.title }
        let href = package.spine[chapterIndex].href
        return package.navigation.first { $0.href == href }?.title ?? book.title
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

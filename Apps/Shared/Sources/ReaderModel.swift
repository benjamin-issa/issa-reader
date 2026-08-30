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
    public private(set) var package: EPUBPackage?
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
        didSet { if style != oldValue { Task { await relayoutCurrentChapter() } } }
    }

    public let book: Book
    private let session: Session

    /// Exposed so the player sheet can load cover art through the same client.
    public var readerSession: Session { session }
    private var pageSize: CGSize = .zero
    private var saveTask: Task<Void, Never>?

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
            let resumeHref = stored?.locator.href
            chapterIndex = package.spine.firstIndex { $0.href == resumeHref }
                ?? Self.firstReadableChapter(in: package)

            await loadChapter(chapterIndex, restoring: stored?.locator)
            await prepareNarration(package: package)
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// The first spine item with actual prose.
    ///
    /// Real books routinely open on a cover wrapper that holds a single image
    /// and no text — Gutenberg EPUBs all do. Opening on spine item zero would
    /// therefore show a blank page, and the reader would look broken before it
    /// had rendered a word.
    static func firstReadableChapter(in package: EPUBPackage) -> Int {
        let style = ReaderStyle()
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
        coordinator.onFragmentChange = { [weak self] fragment in
            guard let self else { return }
            activeFragmentID = fragment
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
            let parsed = try HTMLContentParser(style: style).parse(xhtml: data, baseHref: item.href)
            let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
            layout.layout(pageSize: pageSize)
            self.layout = layout

            if let fragment = locator?.sentenceID,
               let page = layout.page(containingFragment: fragment) {
                pageIndex = page.index
            } else if let progression = locator?.locations?.progression {
                pageIndex = min(
                    max(Int((Double(layout.pages.count) * progression).rounded(.down)), 0),
                    max(layout.pages.count - 1, 0),
                )
            } else {
                pageIndex = 0
            }
        } catch {
            phase = .failed("Couldn't open chapter: \(error)")
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

    private var isCurrentChapterEmpty: Bool {
        guard let layout else { return true }
        return layout.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).count < 4
    }

    public func go(toChapter index: Int) async {
        await loadChapter(index)
        scheduleSave()
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

        let locator = ReadiumLocator(
            href: href,
            type: "application/xhtml+xml",
            title: chapterTitle,
            locations: .init(
                fragments: fragment.map { [$0] },
                progression: chapterProgress,
                totalProgression: overall,
            ),
        )
        _ = try? await ProgressService(client: session.client).save(locator, for: book.uuid)
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

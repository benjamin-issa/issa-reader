import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import IssaRender
import IssaUI
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
        /// Fetching the book itself, with real bytes to show. Distinct from
        /// `.loading` because this one can take minutes and must be cancellable.
        case downloading(received: Int64, total: Int64)
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

    /// How the current position came about.
    ///
    /// Stored on the model rather than passed per save, so the `.onDisappear`
    /// flush inherits the classification of the move that produced the position
    /// rather than being freshly — and wrongly — labelled at the moment it runs.
    private var positionOrigin: PositionOrigin = .chosen

    /// The narrated sentence the server said we were on.
    ///
    /// `loadChapter(_:restoring:)` uses the locator to work out a character
    /// offset and then drops the id, but the id is the one anchor the audio
    /// clock can use directly — and the only one that still resolves when a
    /// chapter's overlay ids never reached the rendered text.
    private var restoredSentenceID: String?

    /// What this book offers by way of its own face, once opened.
    public internal(set) var publisherFont: EPUBFontResolver.Resolution?

    public var hasNarration: Bool { readalong != nil }
    public var isPlaying: Bool { readalong?.player.isPlaying ?? false }

    public var style: ReaderStyle {
        didSet {
            guard style != oldValue else { return }
            // Typography lives in the attributed text, which is immutable once
            // built, so a font or spacing change needs the chapter parsed again
            // — re-flowing alone would keep the old face at the old size. Page
            // size, and only page size, can be handled by re-flowing.
            let needsReparse = style.typeface != oldValue.typeface
                || style.publisherFamily != oldValue.publisherFamily
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
    /// Whether the reader's own chrome is showing: the top bar, and everything
    /// in the footer including the progress readout.
    ///
    /// The readout used to be exempt, on the theory that it is the one thing
    /// worth keeping. Hiding the controls is a request for a bare page, and a
    /// percentage in the corner is not that.
    public private(set) var chromeVisible = true

    public func toggleChrome() {
        chromeVisible.toggle()
    }

    /// Where the reader gets its downloads from. Set by the view, so the model
    /// does not have to know about AppModel to use the one download engine.
    public weak var downloadHost: AppModel?

    public var onSaveAnnotation: ((Annotation) -> Void)?
    public var onDeleteAnnotation: ((Annotation) -> Void)?

    /// Told once the book turns out to have usable narration.
    ///
    /// The app takes ownership from here: it is what decides that narration and
    /// an audiobook cannot both be audible, what claims the lock screen, and
    /// what keeps this model — and so this book's position writes — alive after
    /// the screen showing it has gone.
    public var onNarrationReady: ((ReadalongCoordinator) -> Void)?

    /// Returns whether the write was accepted: the app's guard may refuse a
    /// derived one, and a refused position must not reach the widget either.
    public var enqueuePosition: ((ReadiumLocator, Double, PositionOrigin) async -> Bool)?
    /// When the oldest unwritten change happened, for the debounce ceiling.
    private var firstUnsavedChangeAt: Date?

    public init(book: Book, session: Session, style: ReaderStyle = ReaderStyle()) {
        self.book = book
        self.session = session
        self.style = style
    }

    /// The href of the spine item currently loaded, when there is one.
    ///
    /// `chapterIndex` and `package` are set independently, so `spine[chapterIndex]`
    /// is not safe to write bare — `saveProgress` says so in as many words and
    /// guards with `spine.indices`, while `bookmarkOnCurrentPage` and
    /// `locator(forRange:)` were still subscripting directly behind a `?? ""`
    /// that only defends against a nil package. One accessor, so the next
    /// reader of the pair cannot get it wrong either.
    private var currentSpineHref: String? {
        guard let package, package.spine.indices.contains(chapterIndex) else { return nil }
        return package.spine[chapterIndex].href
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
        // Weighted by each spine item's size, not by its index: counting them
        // equally made a two-page wrapper worth as much as a forty-page chapter,
        // which is not good enough for a percentage the reader can see.
        return package.bookProgress(
            spineIndex: chapterIndex, within: layout.progression(of: page))
    }

    /// The words actually on the current page.
    ///
    /// Painted range, not `characterRange`: a paragraph taller than the page
    /// stays whole on the page it begins on and the draw pass clips the
    /// overflow, so the two differ — and reading a sighted reader's clipped
    /// text aloud describes a page they are not looking at.
    public var currentPageText: String {
        guard let layout, let page = currentPage else { return "" }
        return layout.spokenText(on: page)
    }

    /// The label VoiceOver reads for the page, never empty: a focusable element
    /// that says nothing is worse than one that admits there is nothing.
    public var spokenPageText: String {
        let text = currentPageText
        if !text.isEmpty { return text }
        switch phase {
        case let .failed(reason): return reason
        case .loading: return "Opening the book"
        case let .downloading(received, total):
            return total > 0
                ? "Downloading, \(Int(Double(received) / Double(total) * 100)) percent"
                : "Downloading"
        case .ready: return "This page has no text on it."
        }
    }

    /// The footer's progress readout, in whichever form the reader chose.
    public var progressText: String {
        switch style.progressDisplay {
        case .book:
            return ReadingProgress.percentText(bookProgress)
        case .chapterPage:
            guard pageCount > 0 else { return "" }
            return "\(pageIndex + 1) / \(pageCount)"
        }
    }

    /// Where the reader is, said the way the footer shows it: the page number
    /// is per chapter, so quoting it alone reads as though the book were twelve
    /// pages long.
    public var spokenPagePosition: String {
        guard pageCount > 0 else { return chapterTitle }
        let place = "Page \(pageIndex + 1) of \(pageCount)"
        let title = chapterTitle
        return title.isEmpty ? place : "\(place) in \(title)"
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

        let alreadyOnDisk = content.isDownloaded(book, format: format)
        phase = alreadyOnDisk ? .loading("Opening…") : .downloading(received: 0, total: 0)
        do {
            let url: URL
            if alreadyOnDisk {
                url = content.localURL(for: book, format: format)
            } else if let app = downloadHost {
                url = try await app.downloadAndWait(book, format: format) { [weak self] written, total in
                    self?.phase = .downloading(received: written, total: total)
                }
            } else {
                url = try await content.ensureDownloaded(book, format: format)
            }
            let package = try EPUBPackage.open(url: url)
            self.package = package
            // A book the server calls ALIGNED can still carry no overlays, so
            // narration is offered only when the timeline actually has entries.
            let timeline = SMILParser.timeline(for: package)
            self.timeline = timeline.isEmpty ? nil : timeline

            // Before the first parse, so a book set in its own face is set in
            // it from the first page rather than re-flowing into it.
            resolvePublisherFont(in: package)

            // Resume where the server says we were, before the first render, so
            // the reader never flashes page one and then jumps.
            //
            // With a local fallback, because `try?` swallows a dropped
            // connection as readily as a real absence, and the consequence was
            // silently landing at the front of the book — over the reader's
            // real position, which the very next page turn then saved. The app
            // already holds this book's last locator in memory and on disk;
            // needing the network to find your own place is not a contract
            // worth keeping.
            //
            // Reconciled by timestamp even when the fetch succeeds, the same
            // way `Book.reconciled(with:)` merges a catalogue refetch: a newer
            // position can still be sitting undrained in the mutation queue —
            // a chapter read offline, force-quit before the queue ran — and
            // the server's answer then predates the one held locally. Adopting
            // the server's copy verbatim landed the reader back there, and the
            // first page turn saved that older place over the real one.
            let stored: StoredPosition?
            do {
                let server = try await ProgressService(client: session.client).current(for: book.uuid)
                if let mine = book.position,
                   server.map({ mine.timestamp > $0.timestamp }) ?? true {
                    stored = mine
                } else {
                    stored = server
                }
            } catch {
                stored = book.position
                IssaLog.failure("stored position fetch", error, [
                    "book": book.title,
                    "fallback": book.position == nil ? "none" : "local",
                ])
            }
            // The catch above is deliberately broad, and a cancelled fetch
            // throws `URLError.cancelled`, which the `CancellationError` catch
            // below would not match anyway. Checked explicitly, here and
            // before narration: a layout pass that replaced this task while
            // the fetch was in flight otherwise saw the open run to the end —
            // a second package, a second layout, a second coordinator with its
            // own player — while the replacement did it all again.
            try Task.checkCancellation()
            restoredSentenceID = stored?.locator.sentenceID
            var resumed = stored.flatMap { position in
                package.spine.firstIndex { position.locator.matchesHref($0.href) }
            }
            // The anchor the chapter load restores from. Usually the stored
            // locator itself; replaced when that locator names no chapter.
            var restoring = stored?.locator
            if let position = stored, resumed == nil {
                // An href no spine entry can match — an audiobook position,
                // whose href is an audio track's path, or a chapter file a
                // revision renamed. The whole-book progression still says
                // where the reader was, so land there: falling back to the
                // front of the book put the first page turn's save over their
                // real position.
                if let progress = position.locator.totalProgression, progress.isFinite,
                   let landing = Self.spinePosition(atTotalProgression: progress, in: package) {
                    resumed = landing.index
                    // A synthetic anchor rather than the stored locator: its
                    // `progression` is within the original resource — for an
                    // audiobook, the track — not within this chapter, and
                    // `LocatorAnchoring` would otherwise anchor on it.
                    restoring = ReadiumLocator(
                        href: package.spine[landing.index].href,
                        type: "application/xhtml+xml",
                        locations: .init(progression: landing.within),
                    )
                    IssaLog.info("stored position resolved by progression", [
                        "book": book.title,
                        "href": position.locator.href,
                        "progress": String(format: "%.4f", progress),
                        "chapter": String(landing.index),
                    ])
                } else {
                    // Nothing left to resolve from: the reader is about to
                    // land at the front of the book, and the first page turn
                    // will save that over their real position.
                    IssaLog.warning("stored position matched no chapter", [
                        "book": book.title,
                        "href": position.locator.href,
                        "spineItems": String(package.spine.count),
                    ])
                }
            }
            chapterIndex = resumed ?? Self.firstReadableChapter(in: package, style: style)

            // A chapter that failed to parse already set `.failed`; overwriting
            // it with `.ready` showed a blank page and no explanation at all.
            var loaded = await loadChapter(chapterIndex, restoring: restoring)

            // A resolved landing chapter can still be unreadable — a resume by
            // progression names the byte-weighted spine item without checking
            // its ZIP entry is intact. If that one chapter is corrupt, opening
            // the book at the front still beats refusing to open it at all, so
            // retry once from `firstReadableChapter` (which `try?`-skips
            // throwing items) rather than drop the reader into `.failed`.
            if !loaded, resumed != nil {
                let fallback = Self.firstReadableChapter(in: package, style: style)
                if fallback != chapterIndex {
                    IssaLog.warning("resume landing chapter unreadable, opening at start", [
                        "book": book.title, "landing": String(chapterIndex),
                    ])
                    chapterIndex = fallback
                    restoring = nil
                    loaded = await loadChapter(chapterIndex, restoring: restoring)
                }
            }

            guard loaded else {
                // The other way out of `loadChapter` is its bounds guard — an
                // empty spine, every itemref naming a missing manifest id —
                // which sets nothing, and used to leave the reader on the
                // opening spinner forever with not a line in the log.
                if case .failed = phase { return }
                IssaLog.warning("book has no loadable chapter", [
                    "book": book.title, "chapter": String(chapterIndex),
                    "spineItems": String(package.spine.count),
                ])
                phase = .failed("This book's file doesn't contain any readable chapters.")
                return
            }
            try Task.checkCancellation()
            try await prepareNarration(package: package)
            phase = .ready
            // Spelled out rather than inline: enough of these and the type
            // checker gives up on the literal.
            var opened: [String: String] = [:]
            opened["book"] = book.title
            opened["chapter"] = String(chapterIndex)
            opened["narration"] = String(!timeline.isEmpty)
            opened["resumed"] = String(stored != nil)
            // The fields that say *why* a resume went wrong, rather than only
            // that it did: whether the stored position named a sentence, and
            // whether this book is aligned everywhere or only in places.
            opened["storedFragment"] = restoredSentenceID ?? "none"
            let storedProgress: Double = stored?.locator.totalProgression ?? -1
            opened["storedProgress"] = String(format: "%.4f", storedProgress)
            opened["entries"] = String(timeline.entries.count)
            let narratedDocuments: Set<String> = Set(timeline.entries.map(\.textHref))
            opened["narratedDocuments"] = String(narratedDocuments.count)
            opened["spineItems"] = String(package.spine.count)
            IssaLog.info("book opened", opened)
            // The widget reads a file that was written only by `saveProgress`,
            // and nothing saves on open — so a reader who opened a book and put
            // the phone down left the widget showing the previous session, or
            // the previous book.
            publishSnapshot(progress: bookProgress)
        } catch is CancellationError {
            // The view task was replaced, not the reader's intent. The transfer
            // is still running in the background session and the next pass
            // picks the wait back up, so leave the phase exactly as it is.
            return
        } catch {
            IssaLog.failure("open book", error,
                            ["book": book.title, "format": String(describing: format)])
            // Distinguish "the file never arrived" from "the server is down".
            // Both used to render as "Couldn't reach your server", which sent
            // people looking at their network for a book that simply had not
            // finished downloading.
            let onDisk = BookContentService(client: session.client)
                .isDownloaded(book, format: format)
            phase = .failed(onDisk
                ? "Couldn't open this book. " + AppModel.message(for: error)
                : "This book hasn't finished downloading. " + AppModel.message(for: error))
        }
    }

    /// Starts the whole open again after a failure.
    public func retryOpen(pageSize: CGSize) async {
        phase = .loading("Opening…")
        await open(pageSize: pageSize)
    }

    /// Stops an in-progress download and closes the book.
    public func cancelDownload() {
        guard let format = BookContentService.preferredReadingFormat(for: book) else { return }
        downloadHost?.downloads?.cancel(.init(bookUUID: book.uuid, format: format))
        phase = .failed("Download cancelled.")
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

    /// The spine location a whole-book progression names — the inverse of
    /// `EPUBPackage.bookProgress(spineIndex:within:)`, sharing its weighting
    /// and its equal-count fallback so the two round-trip.
    static func spinePosition(
        atTotalProgression progression: Double, in package: EPUBPackage,
    ) -> (index: Int, within: Double)? {
        guard !package.spine.isEmpty else { return nil }
        let clamped = min(max(progression, 0), 1)
        let weights = package.spineWeights
        let total = weights.reduce(0, +)
        guard total > 0 else {
            // No sizes available: count items equally, as `bookProgress` does.
            let scaled = clamped * Double(package.spine.count)
            let index = min(Int(scaled), package.spine.count - 1)
            return (index, min(max(scaled - Double(index), 0), 1))
        }
        let target = clamped * total
        var before = 0.0
        for (index, weight) in weights.enumerated() {
            if weight > 0, target < before + weight {
                return (index, (target - before) / weight)
            }
            before += weight
        }
        // A progression of exactly 1 walks past every item; the last one with
        // any size is the end of the book.
        let last = weights.lastIndex { $0 > 0 } ?? package.spine.count - 1
        return (last, 1)
    }

    /// Extracts the embedded narration and hooks the audio clock to the page.
    ///
    /// Only runs when the timeline is non-empty, so a book the server reports as
    /// ALIGNED but which carries no overlays simply reads as a plain ebook
    /// rather than showing a player that can never play anything.
    private func prepareNarration(package: EPUBPackage) async throws {
        guard let timeline, !timeline.isEmpty else {
            IssaLog.info("narration unavailable", [
                "book": book.title, "reason": "emptyTimeline",
            ])
            return
        }
        // Off the main actor: this inflates every audio track in the book and
        // writes it to disk, which for a long readaloud is hundreds of
        // megabytes through the deflater — and it ran on the main actor, so
        // the whole app froze for the duration on every open. Checked for
        // cancellation on the way back, since a layout pass may have replaced
        // this open while the extraction ran.
        let bookID = book.uuid
        let files = await Task.detached(priority: .userInitiated) {
            try? AudioExtraction.extractAudio(from: package, timeline: timeline, bookID: bookID)
        }.value
        try Task.checkCancellation()
        guard let files, !files.isEmpty else {
            // A book whose play button never appears, with no reason given, is
            // indistinguishable from one that was never aligned.
            IssaLog.warning("narration unavailable", [
                "book": book.title, "reason": "audioExtractionFailed",
                "entries": String(timeline.entries.count),
            ])
            return
        }

        let coordinator = ReadalongCoordinator(timeline: timeline, audioFiles: files)
        // The saved rate is otherwise written to preferences and never applied,
        // so every book starts at 1x however the reader left it.
        coordinator.player.rate = Float(preferredRate)
        coordinator.onFragmentChange = { [weak self] fragment in
            guard let self else { return }
            activeFragmentID = fragment
            // Keep the narrated sentence on screen. If it is already visible,
            // do not fight the reader by turning the page underneath them.
            var moved = false
            if style.followNarration, let layout,
               let page = layout.page(containingFragment: fragment),
               page.index != pageIndex {
                pageIndex = page.index
                moved = true
            }
            // Narration arriving somewhere is not the reader choosing to be
            // there, so a write derived from it may not overwrite a good
            // position with a wildly different one.
            //
            // But only when it actually arrived somewhere. This used to be
            // unconditional, so a sentence boundary that merely repainted the
            // highlight — the common case, and every case with "follow
            // narration" off — relabelled the reader's *own* page `.derived`.
            // The debounced save then wrote their page turn under a
            // classification the guard is entitled to refuse.
            //
            // A seek lands here too, and is then relabelled by `onSeek`, which
            // the coordinator fires *after* the move it announces. The save is
            // debounced and reads the label when it runs, so the later word
            // wins. There used to be a one-shot latch armed by `onSeek` and
            // consumed here; a seek that moved nothing left it armed, and it
            // then laundered the next genuine drift into a chosen position.
            if moved {
                positionOrigin = .derived
            }
            // Listening moves the position as surely as turning pages does;
            // without this an hour of narration is lost on every other device.
            scheduleSave()
        }
        coordinator.onChapterChange = { [weak self] href in
            guard let self else { return }
            // `onFragmentChange` fires first, so this is already the sentence
            // that crossed the boundary. Loading without it took `pageIndex = 0`
            // and saved the top of the chapter over the line being spoken — on
            // every chapter boundary, every session.
            let fragment = activeFragmentID
            Task { [weak self] in
                await self?.followNarration(toDocument: href, fragment: fragment)
            }
        }
        coordinator.onSeek = { [weak self] in
            self?.positionOrigin = .chosen
        }
        readalong = coordinator
        // The screen reports visibility as it appears, which is before the
        // book has opened and this coordinator exists; the clock it asked for
        // is applied now that there is a player to run it on.
        coordinator.player.setHighFrequencyUpdates(isReaderVisible)
        onNarrationReady?(coordinator)
    }

    /// Starts narration at the sentence under a point on the page.
    ///
    /// Returns whether it found one, so the caller can fall back to turning the
    /// page: a tap in the margin, on a heading, or on an illustration has to
    /// keep doing what a tap always did.
    @discardableResult
    public func playSentence(at point: CGPoint) async -> Bool {
        positionOrigin = .chosen
        guard let readalong, let layout, let page = currentPage else {
            IssaLog.warning("tap to play refused", ["why": "noReadalongOrPage"])
            return false
        }
        // Ask only for ids the narration actually knows. Element ids are not
        // all sentences — headings, page anchors and a publisher's own
        // paragraph wrappers carry them too, and which of those exist depends
        // entirely on who made the book. Filtering here rather than rejecting
        // afterwards means a wrapper can never shadow the sentence inside it,
        // and a tap in the space a sentence does not own still finds the
        // nearest one on the page.
        guard let fragment = layout.fragmentID(at: point, on: page, matching: { id in
            timeline?.entry(forFragment: id) != nil
        }) else {
            IssaLog.warning("tap to play found nothing", [
                "book": book.title, "chapter": String(chapterIndex), "page": String(pageIndex),
                "x": String(format: "%.1f", point.x), "y": String(format: "%.1f", point.y),
            ])
            return false
        }
        // seek(toFragment:) starts playback, which is the point: tapping a
        // sentence in a paused book should begin reading it aloud, not merely
        // move the playhead somewhere the reader cannot hear.
        await readalong.seek(toFragment: fragment)
        return true
    }

    /// Highlights the whole of the current page.
    ///
    /// A selection is made by holding and dragging, which VoiceOver consumes,
    /// so without this the highlight feature does not exist for anyone using
    /// it. The page is the unit that a reader there can actually refer to.
    @discardableResult
    public func annotatePage(tint: Annotation.Tint) -> Annotation? {
        guard let page = currentPage else { return nil }
        selection = page.characterRange
        defer { clearSelection() }
        return annotate(kind: .highlight, tint: tint)
    }

    /// Starts narration at the first narrated sentence on this page.
    public func playFirstSentenceOnPage() async {
        guard let readalong, let fragment = firstFragmentOnCurrentPage() else { return }
        await readalong.seek(toFragment: fragment)
    }

    /// Plays the narration for whatever is selected.
    public func playSelection() async {
        positionOrigin = .chosen
        guard let selection, let layout, let readalong, let timeline else { return }
        // The bound `selectedText` and `annotate` both carry, and this one did
        // not. `attribute(at:)` raises NSRangeException — an Objective-C
        // exception Swift cannot catch, so the process goes down — and the
        // index is reachable: `annotatePage` assigns `page.characterRange`
        // verbatim, `computePages` can emit a synthetic trailing page at
        // {totalLength, 0}, and narration crossing into a shorter chapter swaps
        // the layout synchronously while `clearSelectionIfStale` only runs on
        // the next view update.
        let text = layout.attributedText
        guard selection.location >= 0, selection.location < text.length else { return }
        let fragment = text
            .attribute(.issaFragmentID, at: selection.location, effectiveRange: nil) as? String
        guard let fragment, timeline.entry(forFragment: fragment) != nil else { return }
        await readalong.seek(toFragment: fragment)
    }

    /// Starts narration from whatever the reader is currently looking at.
    ///
    /// Scans forward for the first narrated fragment on the page rather than
    /// reading only the first character: a page often opens mid-paragraph, or on
    /// a heading that carries no media overlay at all.
    /// How far narration may begin from where the reader actually is.
    ///
    /// The fallback this replaced was the first sentence of the whole
    /// audiobook, which on a part-read novel is most of the book away. Every
    /// legitimate resolution is a page or two out; nothing honest is a tenth of
    /// a book out.
    static let narrationProximityLimit = 0.10

    /// Where a narration entry sits, in the same byte-weighted spine
    /// coordinates as `bookProgress`, so the proximity check compares like
    /// with like. Audio time within the entry's own document stands in for
    /// text position within it — approximate, but well inside a threshold of
    /// a tenth of the book.
    private static func spineProgress(
        of entry: SMILEntry, in package: EPUBPackage, timeline: SMILTimeline,
    ) -> Double? {
        guard let index = package.spine.firstIndex(where: { $0.href == entry.textHref })
        else { return nil }
        var within = 0.0
        if let span = timeline.span(ofDocument: entry.textHref),
           let time = timeline.bookTime(forFragment: entry.fragmentID),
           span.duration > 0 {
            within = min(max((time - span.start) / span.duration, 0), 1)
        }
        return package.bookProgress(spineIndex: index, within: within)
    }

    /// Where narration should begin for a reader who is here.
    ///
    /// Every rung is anchored to the chapter the reader is in, and the last one
    /// still only looks *forward* through the spine. There is deliberately no
    /// rung that can reach the start of the book from the middle of it.
    private func narrationStart() -> (entry: SMILEntry, via: String)? {
        guard let timeline, let package, package.spine.indices.contains(chapterIndex) else { return nil }
        let href = package.spine[chapterIndex].href

        // 1. What the reader can see, or the next narrated sentence after it in
        //    this chapter: a page often opens on a heading or a plate carrying
        //    no overlay of its own while the prose beneath it is narrated.
        if let fragment = firstNarratedFragment(continuingPastPage: true),
           let entry = timeline.entry(forFragment: fragment) {
            return (entry, "page")
        }
        // 2. The sentence the stored position named. An exact audio anchor, and
        //    the only rung that resolves when a chapter's ids never reached
        //    `fragmentRanges` — the case rung 1 structurally cannot see. Held to
        //    this chapter so a stale locator cannot move the reader out of it.
        if let sentence = restoredSentenceID,
           let entry = timeline.entry(forFragment: sentence), entry.textHref == href {
            return (entry, "restored")
        }
        // 3. The nearest narration at or after this chapter. On a fully aligned
        //    book that is the top of this chapter; on a partly aligned one, the
        //    first chapter ahead that has any. Never behind.
        if let entry = timeline.firstEntry(inAnyOf: package.spine[chapterIndex...].map(\.href)) {
            return (entry, entry.textHref == href ? "chapter" : "ahead")
        }
        return nil
    }

    public func startNarration() async {
        guard let readalong, let timeline, let package else { return }
        guard let (entry, via) = narrationStart() else {
            IssaLog.warning("narration has nowhere to start", [
                "book": book.title, "chapter": String(chapterIndex),
                "page": String(pageIndex), "entries": String(timeline.entries.count),
            ])
            return
        }
        // The proximity check, which is the actual fix. Refusing is right:
        // the alternative on the way in was a position, which plays, and which
        // is written to the server within two seconds.
        //
        // Measured in the same coordinates as `bookProgress` — byte-weighted
        // spine progress — not as a fraction of narrated audio time. On a
        // partly aligned book the two denominators disagree by exactly the
        // unaligned part, so a candidate on the reader's own page measured as
        // most of a book away and the play button was permanently dead.
        let at = Self.spineProgress(of: entry, in: package, timeline: timeline)
        let distance = at.map { abs($0 - bookProgress) }
        if let distance, distance > Self.narrationProximityLimit {
            IssaLog.warning("narration would start too far away", [
                "book": book.title, "via": via, "chapter": String(chapterIndex),
                "distance": String(format: "%.4f", distance),
                "reader": String(format: "%.4f", bookProgress),
                "candidate": String(format: "%.4f", at ?? -1),
            ])
            return
        }
        IssaLog.info("narration start", [
            "book": book.title, "via": via, "chapter": String(chapterIndex),
            "page": String(pageIndex), "fragment": entry.fragmentID,
            "distance": String(format: "%.4f", distance ?? -1),
        ])
        // `play(from:)`, not `seek(toFragment:)`: a seek is the reader naming a
        // place, and pressing play is not. Keeping this on the derived side of
        // the line is what leaves the position guard armed.
        await readalong.play(from: entry)
        // The coordinator only notices a document change between two observed
        // fragments, so a start in another chapter never fires `onChapterChange`
        // and the page would never follow.
        await followNarration(toDocument: entry.textHref, fragment: entry.fragmentID)
    }

    /// Turns the book to the page a narrated fragment is on, loading its chapter.
    private func followNarration(toDocument href: String, fragment: String?) async {
        guard let package,
              let index = package.spine.firstIndex(where: { $0.href == href }),
              index != chapterIndex else { return }
        let anchor = fragment.map {
            ReadiumLocator(
                href: href, type: "application/xhtml+xml",
                locations: .init(fragments: [$0]),
            )
        }
        guard await loadChapter(index, restoring: anchor) else { return }
        // A chapter the voice crossed into, not one the reader picked. The
        // fragment change that precedes this cannot classify it — the sentence
        // belongs to the *next* document, so it never resolves in the layout
        // still on screen and the move looked like nobody's.
        positionOrigin = .derived
        IssaLog.info("narration crossed chapter", [
            "book": book.title, "to": String(index),
            "fragment": fragment ?? "none", "page": String(pageIndex),
        ])
    }

    /// Turns the book to the page being spoken, wherever that has got to.
    ///
    /// Called when a reader comes back to a book that carried on playing while
    /// they were somewhere else in the app. Deliberately unconditional, unlike
    /// the page-following in `onFragmentChange`: `followNarration` governs
    /// whether the page turns *under someone who is reading it*, and this is a
    /// fresh open. Landing on the page they left, an hour behind the voice, with
    /// nothing to say why, is the same lost place by a different route.
    public func syncToNarration() async {
        guard let entry = readalong?.activeEntry else { return }
        await followNarration(toDocument: entry.textHref, fragment: entry.fragmentID)
        // `followNarration` returns early when the chapter is already loaded,
        // which is the common case — the page still has to move.
        guard let layout, let page = layout.page(containingFragment: entry.fragmentID),
              page.index != pageIndex
        else { return }
        pageIndex = page.index
        // Catching up with the voice is the textbook derived move, and it was
        // being written under whatever label the reader's last deliberate one
        // left behind — with the guard disarmed. It also has to be saved: an
        // hour of playing while the reader was elsewhere in the app moved the
        // position and told no one.
        positionOrigin = .derived
        scheduleSave()
        IssaLog.info("returned to narration", [
            "book": book.title, "chapter": String(chapterIndex),
            "page": String(pageIndex), "fragment": entry.fragmentID,
        ])
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

    /// One sentence of the read-along window: its text and whether it is the one
    /// being spoken.
    public struct NarratedLine: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let isCurrent: Bool
    }

    /// Several sentences either side of the spoken one, in reading order.
    ///
    /// What `narrationContext()` gives is three lines, which is all a phone has
    /// room for. A television has a whole column, and three sentences floating
    /// in it reads as a teleprompter rather than as a book.
    ///
    /// Lines with no text on the current page are dropped rather than rendered
    /// blank: a fragment can belong to a document the layout has not painted,
    /// and a gap in the column would read as a pause the narrator did not take.
    public func narrationWindow(before: Int = 3, after: Int = 3) -> [NarratedLine] {
        guard let timeline, let entry = readalong?.activeEntry,
              let window = timeline.window(around: entry, before: before, after: after)
        else { return [] }
        return window.entries.enumerated().compactMap { offset, item in
            guard let text = text(forFragment: item.fragmentID), !text.isEmpty else { return nil }
            return NarratedLine(
                id: item.fragmentID, text: text, isCurrent: offset == window.currentIndex)
        }
    }

    /// The first narrated fragment at or after the top of the current page.
    ///
    /// `continuingPastPage: false` is the page-scoped question;`true` carries on
    /// to the end of the chapter, which is what "start reading aloud from here"
    /// wants when the page itself is a heading, a plate or a chapter opening.
    func firstNarratedFragment(continuingPastPage carryOn: Bool) -> String? {
        guard let layout, let page = currentPage, let timeline else { return nil }
        let length = (layout.attributedText.string as NSString).length
        let start = page.characterRange.location
        guard start < length else { return nil }
        let range = carryOn
            ? NSRange(location: start, length: length - start)
            : page.characterRange
        var found: String?
        layout.attributedText.enumerateAttribute(.issaFragmentID, in: range) { value, _, stop in
            if let id = value as? String, timeline.entry(forFragment: id) != nil {
                found = id
                stop.pointee = true
            }
        }
        return found
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
            IssaLog.info("narration paused", [
                "book": book.title, "chapter": String(chapterIndex),
                "fragment": activeFragmentID ?? "none",
            ])
            readalong.player.pause()
        } else if readalong.activeEntry == nil {
            await startNarration()
        } else {
            readalong.player.play()
        }
    }

    /// Notified as the reader view appears (true) and goes away (false), so the
    /// app can tell which book is on screen. Installed by
    /// `AppModel.reader(for:session:)` alongside the other hooks.
    public var onVisibilityChanged: ((Bool) -> Void)?

    /// Whether the reader screen is on screen, as last reported.
    private var isReaderVisible = false

    /// The fine-grained clock is only worth running while the page is visible.
    public func setReaderVisible(_ visible: Bool) {
        isReaderVisible = visible
        readalong?.player.setHighFrequencyUpdates(visible)
        onVisibilityChanged?(visible)
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
        // A style change can land before the book is open — the publisher's
        // face is resolved during `open`, and assigning it fires this. There is
        // no chapter to reload yet, and `open` is about to parse one anyway.
        guard package != nil else { return }
        let fragment = firstFragmentOnCurrentPage()
        let anchor = currentPage?.characterRange.location ?? 0
        guard await loadChapter(chapterIndex), let layout else { return }
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

    /// Loads a chapter, leaving the model untouched if it cannot be read.
    ///
    /// - Returns: whether it loaded.
    ///
    /// Nothing is assigned until the whole chapter has parsed and laid out.
    /// Advancing `chapterIndex` first and then failing left the index pointing
    /// at the new chapter while `layout` still held the old one, and every
    /// caller carried on: the next position write named the new chapter's href
    /// and quoted the old chapter's text, then persisted it. Turning back a page
    /// from that state moved the reader forwards.
    @discardableResult
    private func loadChapter(_ index: Int, restoring locator: ReadiumLocator? = nil) async -> Bool {
        guard let package, package.spine.indices.contains(index) else { return false }
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

            // Everything committed together, once nothing can still throw.
            self.layout = layout
            chapterIndex = index
            if let locator, let offset = LocatorAnchoring.characterOffset(
                for: locator, in: parsed.text.string, fragmentRanges: parsed.fragmentRanges,
            ), let page = layout.page(containingOffset: offset) {
                pageIndex = page.index
            } else {
                pageIndex = 0
            }
            return true
        } catch {
            IssaLog.failure("load chapter", error,
                            ["book": book.title, "chapter": String(index)])
            phase = .failed("Couldn't open this chapter. " + AppModel.message(for: error))
            return false
        }
    }

    // MARK: - Navigation

    // Every deliberate move labels the position only once it has happened.
    // Labelling first and then returning early left the model saying "chosen"
    // about a place the reader never went, and the next unrelated save — the
    // flush on closing the screen, a narration tick — carried that label.
    public func nextPage() async {
        guard let layout else { return }
        positionOrigin = .chosen
        if pageIndex + 1 < layout.pages.count {
            pageIndex += 1
        } else if let package, chapterIndex + 1 < package.spine.count {
            await move(toChapter: chapterIndex + 1, landingOnLastPage: false)
        }
        scheduleSave()
    }

    public func previousPage() async {
        guard layout != nil else { return }
        positionOrigin = .chosen
        if pageIndex > 0 {
            pageIndex -= 1
        } else if chapterIndex > 0 {
            await move(toChapter: chapterIndex - 1, landingOnLastPage: true)
        }
        scheduleSave()
    }

    /// How many empty spine items in a row to step over before giving up.
    ///
    /// Gutenberg EPUBs routinely put wrapper items between chapters, and more
    /// than one can sit together. A bound rather than a loop, so a book that is
    /// empty from here on cannot spin.
    private static let emptyChapterSkipLimit = 8

    /// Moves to a chapter, stepping over ones with nothing on them.
    ///
    /// Both directions skip. Only forward did before, which meant paging back
    /// into a wrapper item stranded the reader on a blank page — and for a
    /// VoiceOver reader, on a silent one.
    private func move(toChapter index: Int, landingOnLastPage: Bool) async {
        guard let package else { return }
        let step = landingOnLastPage ? -1 : 1
        var target = index
        for _ in 0 ..< Self.emptyChapterSkipLimit {
            guard package.spine.indices.contains(target) else { return }
            guard await loadChapter(target) else { return }
            if !isCurrentChapterEmpty { break }
            target += step
        }
        pageIndex = landingOnLastPage ? max((layout?.pages.count ?? 1) - 1, 0) : 0
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
        // On failure `layout` still holds the previous chapter, and every
        // offset below would resolve against it — and then be saved as the
        // reader's own choice, which is the one write the guard may not
        // refuse. Same for the other two jumps below.
        guard await loadChapter(index) else { return }
        positionOrigin = .chosen
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
                // Parsed with the images loaded, though search has no use for
                // the pictures: each plate contributes characters — the object
                // replacement character and its line break — to the rendered
                // text, and a parse without them computes offsets that drift
                // ahead of the laid-out chapter's, far enough on an
                // illustrated book to land `go(to:)` on the wrong page.
                // Decoded per chapter and released with it, as `loadChapter`
                // does.
                let images = ChapterImageSource(archive: package.archive)
                guard let data = try? package.archive.read(item.href),
                      let parsed = try? HTMLContentParser(
                          style: style, loadImage: { images.image(for: $0) },
                      ).parse(xhtml: data, baseHref: item.href)
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
            // Only when this task is still the live one: a superseded search
            // resumes from that yield already cancelled, and the flag by then
            // belongs to the search that replaced it — clearing it here hid
            // the spinner and showed "No matches." for a search still running.
            if !Task.isCancelled { self?.isSearching = false }
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
        guard await loadChapter(hit.chapterIndex),
              let layout, let page = layout.page(containingOffset: hit.charOffset) else { return }
        positionOrigin = .chosen
        pageIndex = page.index
        selection = NSRange(location: hit.charOffset, length: (query as NSString).length)
        selectionChapter = chapterIndex
        scheduleSave()
    }

    // MARK: - Selection and annotations

    /// The characters the reader has selected on this page, if any.
    public private(set) var selection: NSRange?
    /// The chapter the current selection was made in. A selection's offsets are
    /// rebased per chapter, so after a chapter jump the same integers address
    /// unrelated text — this lets the view drop a selection it has navigated
    /// away from instead of drawing a highlight (or, worse, saving a bookmark)
    /// over whatever now sits at those offsets in the new chapter.
    private var selectionChapter: Int?
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
        selectionChapter = chapterIndex
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
        selectionChapter = nil
    }

    /// Drops a selection the reader has navigated away from.
    ///
    /// A selection is kept only while it is still on the visible page of the
    /// chapter it was made in. A same-offset range in a different chapter can
    /// intersect the current page purely by coincidence, so the page-range test
    /// alone would keep a stale highlight after a chapter jump — the chapter
    /// check is what stops a bookmark landing on text the reader never touched.
    /// A search jump re-stamps `selectionChapter`, so its landing highlight,
    /// the one the jump exists to leave, survives.
    public func clearSelectionIfStale() {
        guard let selection else { return }
        if selectionChapter == chapterIndex, let page = currentPage,
           NSIntersectionRange(selection, page.characterRange).length > 0 { return }
        clearSelection()
    }

    /// Turns the current selection into a highlight, or drops a bookmark at the
    /// top of the page when nothing is selected.
    @discardableResult
    public func annotate(kind: Annotation.Kind, tint: Annotation.Tint = .tangerine) -> Annotation? {
        guard let layout, let page = currentPage else { return nil }
        let range = kind == .bookmark
            ? NSRange(location: page.characterRange.location, length: min(80, page.characterRange.length))
            : (selection ?? NSRange(location: page.characterRange.location, length: 0))
        // A bookmark is a place, so it is legal on a page with no text — a
        // full-page plate, or a chapter whose cover image failed to decode.
        // A highlight is a piece of text, and there is none, so it is not.
        guard kind == .bookmark || range.length > 0 else { return nil }

        let text = layout.attributedText.string as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        let excerpt = range.length > 0
            ? text.substring(with: range)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : chapterTitle

        // `highlightRects(on:)` later rebuilds this highlight's rectangle from
        // (charOffset, excerpt.length) — so charOffset has to name the
        // excerpt's own first character. A selection that began at a paragraph
        // break or with leading whitespace trims to a shorter excerpt without
        // this adjustment, and the rebuilt range — same start, shorter length —
        // always begins right and clips its own tail by exactly how much was
        // trimmed off the front. Replacing "\n" with " " above never changes
        // character count, so trimming's boundary is the same whichever side of
        // that replace it is measured on.
        let storedRange: NSRange
        if range.length > 0 {
            let raw = text.substring(with: range)
            let leadingTrimmed = raw.prefix(while: \.isWhitespace).utf16.count
            storedRange = NSRange(
                location: range.location + leadingTrimmed, length: (excerpt as NSString).length)
        } else {
            storedRange = range
        }

        let annotation = Annotation(
            bookUUID: book.uuid,
            kind: kind,
            tint: tint,
            locator: locator(forRange: storedRange),
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
            guard await loadChapter(index, restoring: annotation.locator) else { return }
        } else if let layout, let offset = annotation.locator.locations?.charOffset,
                  let page = layout.page(containingOffset: offset) {
            pageIndex = page.index
        }
        positionOrigin = .chosen
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
                  annotation.locator.matchesHref(currentSpineHref ?? ""),
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
        let href = currentSpineHref ?? ""
        let length = (layout?.attributedText.string as NSString?)?.length ?? 0
        let total = max(length, 1)
        let chapterProgress = Double(range.location) / Double(total)
        let overall = (package?.spine.count ?? 0) > 0
            ? (Double(chapterIndex) + chapterProgress) / Double(package?.spine.count ?? 1)
            : chapterProgress
        // Guarded on the length, not merely clamped: a bookmark is legal on a
        // page with no text at all, and `attribute(at:)` raises on any index
        // into an empty string — clamping to `total - 1` still passed it 0.
        let fragment = length > 0
            ? layout?.attributedText
                .attribute(.issaFragmentID, at: min(range.location, length - 1), effectiveRange: nil) as? String
            : nil
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
    ///
    /// With a ceiling, though. A pure trailing-edge debounce is starved by
    /// anything that keeps resetting it, and narration does exactly that —
    /// dialogue-heavy passages cross a sentence boundary faster than every two
    /// seconds, so an hour of listening would have written nothing at all,
    /// which is the loss the debounce exists to prevent.
    private static let saveDebounce: Duration = .seconds(2)
    private static let saveMaximumWait: TimeInterval = 20

    private func scheduleSave() {
        let now = Date()
        if let first = firstUnsavedChangeAt, now.timeIntervalSince(first) >= Self.saveMaximumWait {
            saveTask?.cancel()
            firstUnsavedChangeAt = nil
            saveTask = Task { [weak self] in await self?.saveProgress() }
            return
        }
        if firstUnsavedChangeAt == nil { firstUnsavedChangeAt = now }

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.firstUnsavedChangeAt = nil
            await self?.saveProgress()
        }
    }

    /// Drops a save that has not run yet.
    ///
    /// Sign-out calls it: the screen holds this model beyond the account, and
    /// a debounced write two seconds out otherwise fired for an account that
    /// had already left.
    public func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        firstUnsavedChangeAt = nil
    }

    public func saveProgress() async {
        // `spine.indices` alongside the rest, like every other reader of this
        // pair: `chapterIndex` and `package` are set independently, and a bare
        // subscript here is the one place that would trap rather than log.
        guard let package, let layout, let page = currentPage,
              package.spine.indices.contains(chapterIndex)
        else {
            IssaLog.info("position not saved", ["book": book.title, "reason": "noPage"])
            return
        }
        let href = package.spine[chapterIndex].href

        // Anchor on the first fragment that begins on this page when there is
        // one: it survives a font or margin change, which a page number does
        // not. Beginning on it, not merely covering its first character — the
        // fragment across the page break began on the page before, and a
        // position anchored there came back a page early on every open.
        // Bounds-checked inside: `.ensuresExtraLineFragment` can append a
        // synthetic zero-length trailing page at the chapter's length.
        let fragment = layout.firstFragment(beginningOn: page)

        let chapterProgress = layout.progression(of: page)
        let overall = package.bookProgress(spineIndex: chapterIndex, within: chapterProgress)

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
        let accepted: Bool
        if let enqueuePosition {
            accepted = await enqueuePosition(locator, timestamp, positionOrigin)
        } else {
            accepted = (try? await ProgressService(client: session.client)
                .save(locator, for: book.uuid, timestamp: timestamp)) != nil
        }
        // Only a position that was actually taken reaches the widget. A
        // refused one — or one with no account left to take it, which is what
        // the flush on closing the screen finds after a sign-out — used to be
        // published regardless, so the Home Screen showed a place the book
        // was never at, or the book of an account that had left.
        if accepted { publishSnapshot(progress: overall) }
    }

    /// Publishes the small record the widget reads.
    ///
    /// The publisher decides whether anything moved enough to be worth the
    /// widget's reload budget; this just hands it the current state.
    private func publishSnapshot(progress: Double) {
        let remaining = book.narrationDuration.map { $0 * (1 - progress) }
        // One publisher for the whole app: the cover latch, the ownership rule
        // and the reload all live there, because two surfaces writing one file
        // is what made the widget flip between books.
        CurrentBookPublisher.shared.publish(
            book: book,
            session: readerSession,
            progress: progress,
            chapter: chapterTitle,
            remaining: remaining,
            isPlaying: isPlaying,
            as: .reading(book.uuid),
        )
    }
}

// MARK: - The publisher's font

extension ReaderModel {
    /// Finds the face this book asks to be set in, and makes it usable.
    ///
    /// Extracted rather than read in place: `CTFontManagerRegisterFontsForURL`
    /// wants a file, and the font is a member of a zip. It lands in the app's
    /// own font directory under the book's uuid, so two books shipping
    /// different files both called "Minion Pro" cannot collide — registration
    /// is process-wide, and the second would otherwise render in the first's
    /// face.
    func resolvePublisherFont(in package: EPUBPackage) {
        let resolution = EPUBFontResolver.resolve(in: package)
        publisherFont = resolution
        guard case let .found(face) = resolution else {
            style.publisherFamily = nil
            if case let .unavailable(reason) = resolution, reason != .noEmbeddedFont {
                IssaLog.info("publisher font unusable", [
                    "book": book.title, "reason": String(describing: reason),
                ])
            }
            return
        }
        guard let directory = CustomFonts.directory(named: "Fonts/\(book.uuid)"),
              let data = try? package.archive.read(face.path)
        else { style.publisherFamily = nil; return }

        let url = directory.appendingPathComponent((face.path as NSString).lastPathComponent)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        let family = CustomFonts.register(url)
        style.publisherFamily = family
        IssaLog.info("publisher font", [
            "book": book.title,
            "declared": face.family,
            "family": family ?? "unavailable",
        ])
    }

    /// What to tell the reader about this book's own face.
    public var publisherFontDescription: String {
        switch publisherFont {
        case let .found(face):
            style.publisherFamily.map { _ in face.family } ?? "This book's font couldn't be read."
        case .unavailable(.noEmbeddedFont), .none:
            "This book doesn't include a font."
        case let .unavailable(.unreadableFormat(format)):
            "This book's font is \(format.uppercased()), which iOS can't display."
        case .unavailable(.obfuscated):
            "This book's font is locked by its publisher."
        }
    }

    /// Whether choosing the publisher's font would actually change anything.
    public var hasPublisherFont: Bool { style.publisherFamily != nil }
}

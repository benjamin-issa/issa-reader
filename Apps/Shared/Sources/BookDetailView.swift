import IssaCore
import IssaUI
import SwiftUI

/// Everything the server knows about a book.
///
/// The brief asks for views as data-rich as the server allows, and a single
/// `GET /api/v2/books` already carries all of this — description, both cover
/// editions, creators by role, series position, collections, tags, identifiers,
/// per-user status and position. None of it costs an extra request.
public struct BookDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Which editions are on disk, recomputed on appear and whenever a download
    /// finishes or is deleted anywhere in the app.
    @State private var downloaded: Set<BookContentService.Format> = []
    /// What this screen's own Listen tap reported, if anything.
    ///
    /// `app.listeningError` is one app-wide string, cleared only inside the
    /// *next* attempt — rendered directly, book A's failure showed under book
    /// B's perfectly working Listen button. Copied here when the attempt this
    /// screen started returns, it can only describe this book.
    @State private var listenError: String?
    #if os(iOS)
    @State private var showsReader = false
    #endif
    /// Whether the expanded player is up, opened by tapping "Now playing" once
    /// this book's audio is already running (item 08). Reuses `NowPlayingSheet`,
    /// the same full player the mini-bar expands into.
    @State private var showsPlayer = false
    /// The book as it was when this screen opened. Identity only — everything
    /// drawn comes from `book` below.
    private let initialBook: Book

    /// The live book from the model.
    ///
    /// Navigating here hands over a value, and a value does not change when the
    /// library does: setting a status updated the model and left this screen
    /// showing the old one. Looking it up each time keeps the screen honest
    /// about status, rating and progress, all of which change from here.
    private var book: Book {
        app.books.first { $0.uuid == initialBook.uuid } ?? initialBook
    }

    public init(book: Book) {
        initialBook = book
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing32) {
                // The hero and the action row read as one block, but the row is
                // full width rather than trapped in the ~212pt column beside a
                // 130pt cover, where its labels broke mid-word.
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    hero
                    actionRow
                }
                if let description = book.description, !description.isEmpty {
                    // Server descriptions carry markup. Rendered as a raw
                    // string, <p> and &amp; showed up on screen verbatim.
                    Text(HTMLText.attributed(description))
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
                if !book.tags.isEmpty { tags }
                facts
                // Editions are a fetch-a-file detail, not a reading choice, so
                // they sit one disclosure down (item 03) rather than competing
                // with Read and Listen above the fold.
                manageDownloads
                externalRatings
                relatedRails
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .navigationTitle(book.title)
        // Writing a position moves the status server-side, so the shelf shown
        // here is stale after a reading session unless it is re-read.
        .task { await app.refresh(book: book) }
        #if os(iOS)
        // A widget tap, a Handoff or a link meant "carry on with this book", so
        // this screen is a waypoint rather than the destination. One-shot, so
        // reaching the same book through the library later does not reopen it.
        .task { if app.consumeReaderRequest(for: book) { showsReader = true } }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showsReader) {
            if let session = app.session {
                ReaderScreen(book: book, session: session)
            }
        }
        #endif
        // The full player, reached by tapping "Now playing" while this book's
        // audio runs (item 08). Reuses `NowPlayingSheet` — the mini-bar's own
        // expansion — so there is one full player, not a second one here.
        .sheet(isPresented: $showsPlayer) { NowPlayingSheet() }
        // Nothing to expand into once playback has stopped.
        .onChange(of: app.playback == nil) { _, stopped in
            if stopped { showsPlayer = false }
        }
        .onChange(of: app.downloadedUUIDs, initial: true) { refreshDownloaded() }
        // `downloadedUUIDs` is keyed by book with the format discarded, so a
        // second edition arriving or leaving while the first is still on disk
        // produces an equal set and the line above stays silent. The
        // per-edition download states do move — a finish writes `.finished`,
        // a removal clears the job — so they are watched as well.
        .onChange(of: editionDownloadStates) { refreshDownloaded() }
        // And re-read on the way back from another screen: removing an edition
        // that was fetched in an earlier session from the downloads list moves
        // neither observed value, because its job has no state to clear.
        .onAppear { refreshDownloaded() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Metrics.spacing16) {
            CoverImage(book: book, session: app.session)
                .frame(width: 130)

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(book.title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                Text(book.byline)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                if !book.narrators.isEmpty {
                    Text("Narrated by " + book.narrators.map(\.name).joined(separator: ", "))
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
                ratingControl
                // Wrapping, not a fixed row: "Readaloud · 5h 4m" beside a
                // status pill overflows a phone column and breaks mid-word.
                FlowRow(spacing: Metrics.spacing8) {
                    statusControl
                    formatBadges
                }
                if let progress = book.progress, progress > 0 {
                    ProgressBar(value: progress).frame(maxWidth: 200)
                    Text("\(ReadingProgress.percent(progress))% complete")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// What the book screen offers, and why it is not a fixed pair of buttons.
    ///
    /// `FlowRow` rather than an `HStack`: it proposes an unspecified width to
    /// each child, so a capsule renders at its natural size and wraps to the
    /// next line when there is no room — which is what has to happen at an
    /// accessibility text size, where a fixed row would simply clip.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            FlowRow(spacing: Metrics.spacing12) {
                primaryControl
                listenButton
            }
            // On an aligned book Read opens the read-along edition, so the
            // reader gets synced narration without choosing a separate file
            // (item 03). Said here so "Read" never has to be guessed at — but
            // only when the read-along is actually ALIGNED: the server hands
            // back a `.readaloud` primary the moment alignment is *requested*,
            // and promising "tap any line to hear it" on a still-processing book
            // is a lie the reader discovers by tapping.
            if primaryAction?.format == .readaloud, book.readaloud?.isAligned == true {
                Label {
                    Text("Narration included — tap any line to hear it")
                } icon: {
                    Image(systemName: "waveform")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            }
            // A failed Listen tap used to be completely silent. The outcome
            // is rendered from this screen's own copy, not `app.listeningError`
            // itself, which is app-wide and would resurface one book's failure
            // under every other book's button.
            if let error = listenError {
                Text(error).font(Typography.caption).foregroundStyle(Palette.alert)
            }
        }
    }

    /// The primary control: always Read / Resume (item 02, Option A).
    ///
    /// It no longer follows the download state — a book that is not on disk
    /// still leads with Read, and the file is fetched inside the reader on open
    /// (`ReaderScreen`'s own `downloadingView`, real bytes + Cancel). Explicit
    /// prefetching lives in Manage downloads below.
    private var primaryAction: BookPrimaryAction? {
        BookPrimaryAction.reading(book: book)
    }

    /// Which editions are on disk.
    ///
    /// Held rather than asked per render: `isDownloaded` is a `fileExists` and
    /// is not observable, so a delete performed on the downloads screen would
    /// otherwise never reach an already-open book screen — and asking inside
    /// the body meant a syscall per edition per frame.
    private func refreshDownloaded() {
        guard let session = app.session else { downloaded = []; return }
        let content = BookContentService(client: session.client)
        downloaded = Set(BookContentService.Format.allCases.filter {
            content.isDownloaded(book, format: $0)
        })
    }

    /// The download states for this book's editions, one slot per format.
    ///
    /// Observed because `app.downloadedUUIDs` cannot carry a second edition of
    /// the same book — see the `onChange` in `body`.
    private var editionDownloadStates: [DownloadManager.State?] {
        BookContentService.Format.allCases.map {
            app.downloads?.state(for: .init(bookUUID: book.uuid, format: $0))
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        // Always opens the reader now (item 02): the control's only intent is
        // `.openReader`, and the reader downloads on open when the file is
        // absent. There is no download branch here any more — Manage downloads
        // owns explicit fetching.
        if let action = primaryAction, let session = app.session {
            #if os(iOS)
            // Presented, not pushed. Inside the tab's NavigationStack the
            // reader inherits the tab bar and its accessory slot, whose
            // glass capsule draws over the page's own footer — and the
            // navigation stack's edge-swipe pops the book shut mid-page.
            // Outside it, the page owns the whole screen.
            Button {
                showsReader = true
            } label: {
                PrimaryCapsule(action: action)
            }
            .buttonStyle(.plain)
            #else
            NavigationLink {
                ReaderScreen(book: book, session: session)
            } label: {
                PrimaryCapsule(action: action)
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    /// Plays the audiobook without opening the reader — or, once it is playing,
    /// opens the player (item 08).
    ///
    /// Offered for readaloud books too: wanting to hear a book while driving or
    /// walking is not the same as wanting the text on screen, and it is the
    /// only mode CarPlay can offer at all.
    @ViewBuilder
    private var listenButton: some View {
        // Readaloud counts: the doc comment above has always claimed it did,
        // but the gate only ever looked at `audiobook`, so a readaloud-only
        // book got no Listen button at all.
        if book.servableFormats.contains(.audiobook) || book.servableFormats.contains(.readaloud) {
            // Whichever kind is playing. Reading it off the audiobook alone
            // offered "Listen" for a book already narrating in the reader.
            let isPlaying = app.playbackBook?.uuid == book.uuid
            Button {
                if isPlaying {
                    // Already this book's audio — expand the player rather than
                    // calling `startListening` again, which is at best a silent
                    // resume and, when it is the reader's narration that is
                    // running, a swap to the audiobook that cuts the current
                    // audio. This just surfaces what is already playing.
                    showsPlayer = true
                } else {
                    Task {
                        await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings)
                        listenError = app.listeningError
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isPlaying ? "waveform" : "headphones")
                        .font(.system(size: 14, weight: .semibold))
                    // "Now playing ▸" reads as a route into the player, not a
                    // status the reader cannot act on.
                    Text(isPlaying ? "Now playing" : "Listen")
                    if isPlaying {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .font(Typography.headline)
                .padding(.horizontal, Metrics.spacing16)
                .padding(.vertical, Metrics.spacing8)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.borderStrong, lineWidth: 1))
                .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            // The label alone reads "Now playing"; the action is to open the
            // player, so say so.
            .accessibilityLabel(isPlaying ? "Now playing. Open the player" : "Listen")
        }
    }

    /// The primary control's face. One definition, used by both the
    /// `NavigationLink` that opens the reader and the `Button` that does
    /// everything else.
    private struct PrimaryCapsule: View {
        let action: BookPrimaryAction
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            HStack(spacing: Metrics.spacing8) {
                if let fraction = action.fraction, action.isDeterminate {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.35), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(.white, style: .init(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                } else if !action.isDeterminate {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                // At an accessibility size "Download · 312 MB" is wider than the
                // screen. Dropping the suffix is honest; shrinking the type of a
                // primary action is not.
                Text(action.title(compact: dynamicTypeSize.isAccessibilitySize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Typography.headline)
            .padding(.horizontal, Metrics.spacing24)
            .padding(.vertical, Metrics.spacing8)
            .background(Palette.tangerine, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel(action.accessibilityLabel)
        }
    }

    /// This user's own rating, tappable. Tapping the current score clears it,
    /// which is the only way to un-rate something without a separate control.
    ///
    /// Unrated, the row wore only five outline stars beside a muted average —
    /// indistinguishable from a static score readout — so it gets a faint
    /// "Rate" chip (item 06) that marks it as an input. A set rating fills in
    /// tangerine, a colour the muted average text never uses, so the reader's
    /// own stars and the community number never read as the same thing.
    private var ratingControl: some View {
        let mine = app.ratings[book.uuid]
        return HStack(spacing: Metrics.spacing8) {
            if mine == nil {
                // Not a control of its own — the stars are — just the cue that
                // makes the outline stars read as "tap to rate" rather than an
                // average already earned. Hidden from VoiceOver, which reads the
                // star buttons and the row's own hint instead.
                Text("Rate")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.horizontal, Metrics.spacing8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Palette.borderStrong, lineWidth: 1))
                    .accessibilityHidden(true)
            }
            HStack(spacing: Metrics.spacing4) {
                ForEach(1 ... 5, id: \.self) { star in
                    Button {
                        Task { await app.setRating(mine == Double(star) ? nil : Double(star), for: book) }
                    } label: {
                        Image(systemName: Double(star) <= (mine ?? 0) ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(mine == nil ? Palette.inkQuaternary : Palette.tangerine)
                    }
                    .buttonStyle(.plain)
                    // A 14pt glyph is a ~15pt target; grow each to the 44pt
                    // floor the rest of this build's controls meet, so a tap
                    // does not land on the neighbouring star.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                    // The fill and the tangerine never reach the accessibility
                    // tree, so VoiceOver read five identical buttons whether or
                    // not the book was rated. The current score carries the trait,
                    // and its hint says what a second tap does — silently deleting
                    // the rating is not discoverable any other way.
                    .accessibilityAddTraits(mine == Double(star) ? .isSelected : [])
                    .accessibilityHint(mine == Double(star) ? "Removes your rating." : "")
                }
            }
            if let serverAverage = book.rating, mine == nil {
                // The community's number, muted and named, so it never reads as
                // the reader's own tangerine stars.
                Text(String(format: "%.1f average", serverAverage))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        // The score goes in the container LABEL, not its value/hint: a
        // `.contain` element is a container VoiceOver steps into rather than a
        // focusable leaf, so a value or hint set on it is never spoken — only
        // the label is, as focus enters the row. Folding the state into the
        // label makes "Your rating, 3 stars" (or "not rated, rate from one to
        // five stars") audible on entry, while the individual star buttons stay
        // separately focusable so the rating can still be changed.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mine.map { "Your rating, \(Int($0)) star\($0 == 1 ? "" : "s")" }
            ?? "Your rating, not rated. Rate this book from one to five stars.")
    }

    /// The shelf this book sits on, changeable in place.
    private var statusControl: some View {
        Menu {
            ForEach(app.statuses) { status in
                Button {
                    Task { await app.setStatus(status, for: book) }
                } label: {
                    if status.uuid == book.status?.uuid {
                        Label(status.name, systemImage: "checkmark")
                    } else {
                        Text(status.name)
                    }
                }
            }
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: Self.symbol(for: book.status?.name))
                    .font(.system(size: 11))
                Text(book.status?.name ?? "Set status")
                    .font(Typography.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .fixedSize()
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, 4)
            .background(Palette.surfaceRaised, in: Capsule())
            .foregroundStyle(Palette.inkSecondary)
        }
        .disabled(app.statuses.isEmpty)
        // The pill's own text is a bare shelf name; VoiceOver needs the verb.
        // The current shelf is the value, so it is not repeated in the label.
        .accessibilityLabel(book.status == nil ? "Set reading status" : "Change reading status")
        .accessibilityValue(book.status?.name ?? "None")
    }

    static func symbol(for status: String?) -> String {
        switch status {
        case Status.readingName: "book"
        case Status.readName: "checkmark.circle"
        default: "bookmark"
        }
    }

    /// Reads from `servableFormats`, so a badge cannot promise a "Readaloud ·
    /// 5h 4m" two inches above an Editions row saying "Missing on server".
    @ViewBuilder
    private var formatBadges: some View {
        let formats = book.servableFormats
        if formats.contains(.readaloud) {
            // "Read-along", never the server's "Readaloud" (item 03).
            badge("Read-along", duration: book.readaloud?.duration)
        } else if formats.contains(.audiobook) {
            badge("Audiobook", duration: book.audiobook?.duration)
        }
        if formats.contains(.ebook) {
            badge("Ebook", pages: book.ebook?.pageCount)
        }
    }

    private func badge(_ title: String, duration: Double? = nil, pages: Int? = nil) -> some View {
        var text = title
        if let duration { text += " · " + DurationText.text(duration) }
        if let pages { text += " · \(pages) pages" }
        return Text(text)
            .font(Typography.caption)
            .fixedSize()
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, 3)
            .background(Palette.surfaceRaised, in: Capsule())
            .foregroundStyle(Palette.inkSecondary)
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Tags").overlineStyle()
            FlowRow(spacing: Metrics.spacing8) {
                ForEach(book.tags) { tag in
                    Text(tag.name)
                        .font(Typography.caption)
                        .padding(.horizontal, Metrics.spacing8)
                        .padding(.vertical, 4)
                        .background(Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }

    /// Editions and their download state, one disclosure down (items 02 & 03).
    ///
    /// Under Option A a book downloads when you open it, so this is no longer a
    /// prerequisite to reading — it is where you *keep* an edition for offline
    /// use, and where the per-edition ⋯ menu (save, pause, resume, remove)
    /// lives. Collapsed by default so raw edition rows never compete with Read
    /// and Listen above the fold.
    private var manageDownloads: some View {
        // tvOS has no `DisclosureGroup` and no route to this screen anyway, so
        // it shows the same content expanded under a plain heading; iOS and the
        // Mac collapse it so raw edition rows never compete above the fold.
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Manage downloads").overlineStyle()
            manageDownloadsContent
        }
        #else
        DisclosureGroup {
            manageDownloadsContent
                .padding(.top, Metrics.spacing8)
        } label: {
            Text("Manage downloads").overlineStyle()
        }
        .tint(Palette.inkSecondary)
        #endif
    }

    private var manageDownloadsContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Books download automatically when you open them. Save an edition here to keep it for offline reading.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            editionsCard
        }
    }

    /// The edition rows. Storyteller keeps up to three editions of a book;
    /// showing which exist answers "can I listen to this" without opening it.
    private var editionsCard: some View {
        VStack(spacing: 1) {
            if book.availableFormats.isEmpty {
                // Was a header over a blank rounded rectangle.
                editionNote("This book has no editions on the server yet.")
            } else if book.servableFormats.isEmpty {
                editionNote("Every edition is missing on the server.")
            }
            if let ebook = book.ebook {
                editionRow(Self.editionName(.ebook), format: .ebook,
                           detail: ebook.isEpub2 == true ? "EPUB 2" : "EPUB 3",
                           size: ebook.fileSize, missing: ebook.missing == true)
            }
            if let audiobook = book.audiobook {
                editionRow(Self.editionName(.audiobook), format: .audiobook,
                           detail: DurationText.text(audiobook.duration ?? 0),
                           size: audiobook.fileSize, missing: audiobook.missing == true)
            }
            if let readaloud = book.readaloud {
                editionRow(
                    Self.editionName(.readaloud), format: .readaloud,
                    detail: readaloud.isAligned
                        ? DurationText.text(readaloud.duration ?? 0)
                        : (readaloud.status ?? "processing").capitalized,
                    size: readaloud.fileSize, missing: readaloud.missing == true,
                )
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
    }

    /// The reader-facing name for an edition. "Read-along", never the server's
    /// "Readaloud" (item 03); the other two already read plainly.
    static func editionName(_ format: BookContentService.Format) -> String {
        switch format {
        case .ebook: "Ebook"
        case .audiobook: "Audiobook"
        case .readaloud: "Read-along"
        }
    }

    private func editionRow(
        _ title: String, format: BookContentService.Format,
        detail: String, size: Int?, missing: Bool,
    ) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Text(title).font(Typography.callout).foregroundStyle(Palette.ink)
            Spacer()
            if missing {
                // The server tracks files that vanished from disk; saying so
                // beats a download that fails for no visible reason.
                Text("Missing on server")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.alert)
            } else {
                Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                if let size {
                    Text(ByteCountText.text(Int64(size))).font(Typography.caption).foregroundStyle(Palette.inkQuaternary)
                }
                // State, not a control. The 17pt glyph that used to sit here
                // was the only way to fetch a book and had a tap target under
                // 44pt — which is what testers were describing.
                Text(DownloadStatusText.short(
                    app.downloads?.state(for: .init(bookUUID: book.uuid, format: format)),
                    isDownloaded: downloaded.contains(format)))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                editionMenu(for: format)
            }
        }
        .padding(Metrics.spacing12)
    }

    private func editionNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacing12)
    }

    /// Per-edition control, behind a visible affordance.
    ///
    /// A context menu alone would have been the only route anywhere in the app
    /// to fetch the audiobook edition for offline listening — the downloads
    /// screen only lists and removes — and the primary always acts on the
    /// reading edition. An invisible gesture is not an answer to a complaint
    /// that the control was impossible to find.
    @ViewBuilder
    private func editionMenu(for format: BookContentService.Format) -> some View {
        #if !os(tvOS)
        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        let state = app.downloads?.state(for: job)
        let onDisk = downloaded.contains(format)

        Menu {
            if let state, state.isActive {
                Button("Pause download", systemImage: "pause.circle") { app.downloads?.pause(job) }
            } else if case .paused = state {
                Button("Resume download", systemImage: "play.circle") {
                    Task { await app.resumeDownload(job) }
                }
            } else if !onDisk {
                // "Save for offline", not "Download": under Option A opening the
                // book already fetches it, so this button is specifically about
                // keeping the edition on the device (item 02).
                Button("Save for offline", systemImage: "arrow.down.circle") {
                    Task { await app.download(book, format: format) }
                }
            }
            if state?.isFailure == true {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await app.download(book, format: format) }
                }
            }
            if onDisk {
                Button("Remove download", systemImage: "trash", role: .destructive) {
                    app.removeDownload(book, format: format)
                    // The model refreshes a set keyed by book UUID, which does
                    // not change while the other edition is still on disk — so
                    // re-read locally rather than waiting on an observer that
                    // cannot fire.
                    refreshDownloaded()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(Palette.tangerine)
                // The row's own padding sits outside the control, so without
                // this the tap target was the glyph's 17pt bounds.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(Self.editionName(format)) options")
        #endif
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text("Details").overlineStyle()
            VStack(spacing: 1) {
                if let series = book.series.first {
                    factRow("Series", series.position.map { "\(series.name) · \(Self.positionText($0))" } ?? series.name)
                }
                if let published = book.publicationDate?.value {
                    factRow("Published", published.formatted(.dateTime.year()))
                }
                if let language = book.language { factRow("Language", language.uppercased()) }
                if !book.collections.isEmpty {
                    factRow("Collections", book.collections.map(\.name).joined(separator: ", "))
                }
                if let alignedWith = book.alignedWith { factRow("Aligned with", alignedWith) }
                ForEach(namedIdentifiers) { identifier in
                    if let url = identifier.url, Self.isWebLink(url) {
                        // The server configures the URL template per identifier
                        // type, so a link only appears where it actually leads
                        // somewhere — and only somewhere on the web.
                        Link(destination: url) {
                            factRow(identifier.label, identifier.value ?? "", showsLink: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        factRow(identifier.label, identifier.value ?? "")
                    }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }

    /// Identifiers the server holds (ISBN, ASIN, Audible), ready for display.
    private var namedIdentifiers: [Identifier] {
        book.identifiers.filter { !($0.value ?? "").isEmpty }
    }

    /// Ratings gathered from elsewhere, shown in the source's own terms.
    ///
    /// A source states its own scale, so nothing is rescaled to five stars: a
    /// reader who knows Hardcover expects Hardcover's number.
    @ViewBuilder
    private var externalRatings: some View {
        let ratings = book.externalData ?? []
        if !ratings.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("ELSEWHERE").font(Typography.overline).foregroundStyle(Palette.inkTertiary)
                HStack(spacing: Metrics.spacing8) {
                    ForEach(ratings) { rating in
                        let chip = HStack(spacing: 5) {
                            Image(systemName: rating.sourceRatingIcon == "star" ? "star.fill" : "circle.fill")
                                .font(.system(size: 10))
                            Text(rating.sourceName ?? "Rating").font(Typography.caption)
                            Text(rating.ratingText).font(Typography.caption.weight(.semibold))
                        }
                        .padding(.horizontal, Metrics.spacing12)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color(hex: rating.sourceColor) ?? Palette.inkSecondary)
                        .background(
                            Capsule().fill((Color(hex: rating.sourceColor) ?? Palette.moss).opacity(0.12)),
                        )

                        if let source = rating.sourceUrl, let url = URL(string: source),
                           Self.isWebLink(url) {
                            Link(destination: url) { chip }.buttonStyle(.plain)
                        } else {
                            chip
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String, showsLink: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).font(Typography.footnote).foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Metrics.spacing16)
            Text(value)
                .font(Typography.footnote)
                .foregroundStyle(showsLink ? Palette.tangerine : Palette.ink)
                .multilineTextAlignment(.trailing)
            if showsLink {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.tangerine)
            }
        }
        .padding(Metrics.spacing12)
    }

    /// The design's Explore rails, all derived from the one catalogue fetch.
    private var relatedRails: some View {
        let derivation = app.derivation
        return VStack(alignment: .leading, spacing: Metrics.spacing24) {
            if let series = book.series.first,
               let siblings = derivation.bySeries[series.name]?.filter({ $0.uuid != book.uuid }),
               !siblings.isEmpty {
                rail("The \(series.name)", books: siblings)
            }
            if let author = book.authors.first,
               let others = derivation.byAuthor[author.name]?.filter({ $0.uuid != book.uuid }),
               !others.isEmpty {
                rail("More by \(author.name)", books: others)
            }
            if let narrator = book.narrators.first,
               let others = derivation.byNarrator[narrator.name]?.filter({ $0.uuid != book.uuid }),
               !others.isEmpty {
                rail("Narrated by \(narrator.name)", books: others)
            }
        }
    }

    private func rail(_ title: String, books: [Book]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(title).overlineStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    ForEach(books) { sibling in
                        NavigationLink {
                            BookDetailView(book: sibling)
                        } label: {
                            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                                CoverImage(book: sibling, session: app.session).frame(width: 84)
                                Text(sibling.title)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .frame(width: 84, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Whether a server-supplied URL is safe to hand to a `Link`.
    ///
    /// The same rule `HTMLText.href` applies to scraped descriptions:
    /// identifiers and external ratings are metadata the server controls, and
    /// `URL(string:)` happily builds `javascript:`, `sms:` or `shortcuts:`
    /// URLs — a tapped `Link` hands those straight to whatever app claims the
    /// scheme. Web links only.
    static func isWebLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    static func positionText(_ position: Double) -> String {
        position == position.rounded() ? "Book \(Int(position))" : "Book \(position)"
    }

}

/// Wraps its children onto as many lines as needed. Used for tag chips, where
/// a fixed grid would leave ragged gaps between short and long names.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

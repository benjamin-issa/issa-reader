import AVFoundation
import Foundation
import IssaCore
import IssaEPUB
import Observation

/// Keeps narration and text in step.
///
/// The audio clock is the source of truth. A periodic observer keeps the model
/// honest at a modest rate, and the view interpolates between observations, so
/// the highlight looks continuous without waking the CPU on every frame while
/// the screen is off.
@Observable
@MainActor
public final class ReadalongCoordinator {
    public private(set) var activeFragmentID: String?
    public private(set) var activeEntry: SMILEntry?
    /// Progress through the whole book, 0...1, on the virtual gapless timeline.
    public private(set) var bookProgress: Double = 0

    /// Called when the highlight moves to a fragment in a different chapter, so
    /// the reader can load and turn to it.
    public var onChapterChange: ((String) -> Void)?
    /// A second, independent chapter-boundary hook.
    ///
    /// The reader owns `onChapterChange` to turn the page; the sleep timer needs
    /// the same signal for "end of chapter" and must not have to fight it.
    public var onChapterChangeObserved: (() -> Void)?
    /// Called whenever the highlighted fragment changes.
    public var onFragmentChange: ((String) -> Void)?
    /// Called when something other than the clock moved the playhead — a tapped
    /// sentence, the scrubber, a skip, a chapter command.
    ///
    /// The reader uses it to tell a position the listener *chose* from one
    /// narration merely wandered into. Notably `play(from:)` does not fire it:
    /// pressing play asks for audio, it does not name a place, and when the app
    /// has to work out where that is the guess must not be allowed to overwrite
    /// a known-good position.
    ///
    /// Fired *after* the move, and only when something moved. Announcing the
    /// seek first meant every early return behind it — the end of the book, a
    /// missing audio file, a skip with no anchor yet — left the reader told of
    /// a choice that never happened.
    public var onSeek: (() -> Void)?

    public let player: AudioPlayer
    private let timeline: SMILTimeline
    /// Archive href to the extracted file on disk.
    private let audioFiles: [String: URL]
    /// How many moves are between the highlight moving and the audio following
    /// it.
    ///
    /// `AudiobookCoordinator`'s `loadsInFlight` and `seeksInFlight`, in the one
    /// counter this engine needs. `AudioPlayer.observeTime` attaches its
    /// periodic observer to the *player*, not to the item, and neither
    /// `player.load` nor `player.seek` stops it firing — so a sample lands in
    /// the middle of every deliberate move, and `advance(to:)` answers it
    /// against a file the move has already changed. The read-along needs no
    /// `fromTick` distinction to go with it: the clock (`advance`) and the steer
    /// (`move`) are already two separate functions here, and `advance` is scoped
    /// to `player.currentAudioHref` so it cannot reach into another file at all.
    ///
    /// Counted rather than flagged, because two moves in a burst overlap and the
    /// second must not reopen the clock while the first is still in flight.
    /// Internal rather than private so a test can see the window it opens.
    var movesInFlight = 0

    public init(timeline: SMILTimeline, audioFiles: [String: URL], player: AudioPlayer = AudioPlayer()) {
        self.timeline = timeline
        self.audioFiles = audioFiles
        self.player = player

        player.onTimeUpdate = { [weak self] time in
            self?.advance(to: time)
        }
        player.onFinishedFile = { [weak self] in
            Task { await self?.advanceToNextFile() }
        }
    }

    public var isEmpty: Bool { timeline.isEmpty }
    public var totalDuration: TimeInterval { timeline.totalDuration }

    /// Where the narration is, in terms the audiobook engine can also act on.
    ///
    /// This is the bridge between the two clocks — see `AudioAnchor`. The media
    /// overlay already names the audio file and the offset within it for every
    /// sentence, so the read-along can hand the audiobook an exact place rather
    /// than a fraction of a different timeline.
    ///
    /// Anchored on the player's own clock rather than on `bookProgress`, for
    /// the reason `skipBook` gives: `bookProgress` is written by the periodic
    /// observer and still reads zero in the first moments after a jump.
    ///
    /// `nil` before anything has played. A book with no anchor yet is exactly
    /// the case the resume order in `AppModel.startListening` exists to handle,
    /// and inventing one here would defeat it.
    public var currentAnchor: AudioAnchor? {
        guard let entry = activeEntry else { return nil }
        // The player's time is already an offset into `entry.audioHref` — clip
        // times restart per file — so it is the anchor's offset directly.
        // Clamped into the entry it belongs to: between clips the clock can sit
        // fractionally past the end.
        let time = player.currentTime
        guard time.isFinite else { return nil }
        return AudioAnchor(
            audioHref: entry.audioHref,
            offset: min(max(entry.start, time), entry.end),
            writtenAt: Date().timeIntervalSince1970,
        )
    }

    // MARK: - Clock

    /// Maps the player's position within the current file onto a fragment.
    ///
    /// Scoped to the current file: clip times restart at zero in each track, so
    /// a book-time search here would land on the wrong sentence.
    /// How far before the active sentence a sample may fall and still be read
    /// as clock jitter rather than as a move. One frame of the player's 1/600 s
    /// timescale is 1.7 ms; twenty is far below the smallest deliberate skip
    /// and far above any rounding.
    static let backwardsClockSlack: TimeInterval = 0.02

    private func advance(to time: TimeInterval) {
        // Mid-move the clock describes neither where the listener was nor where
        // they asked to go — and worse, it is read against a file the move has
        // already swapped, so a clock of zero from a freshly inserted item
        // resolves to the *first* sentence of the new chapter's audio rather
        // than to the one the listener asked for. Answering that dragged the
        // highlight off the destination, and, when the move crossed a document,
        // announced a chapter the listener had deliberately scrubbed into as one
        // that had *ended* — `NowPlayingController` hands that to
        // `SleepTimer.chapterDidEnd()`, and a read-along with a bedtime timer
        // paused itself mid-scrub.
        guard movesInFlight == 0 else { return }
        guard let href = player.currentAudioHref,
              let entry = timeline.entry(inFile: href, at: time)
        else { return }

        // A sample a hair before the sentence the listener is already on
        // resolves to the sentence *before* it — the lookup is half-open — so a
        // clock that lands a fraction early would step the highlight back one,
        // and across a document boundary turn the page back and hand the sleep
        // timer a chapter that had not ended. The seek rounds up so this should
        // not arise; this is the second lock on the same door, because the cost
        // of being wrong is a book that pauses itself at bedtime.
        //
        // Only a hair: a deliberate move backwards is orders of magnitude
        // larger than this, and arrives through `move(to:)` rather than here.
        //
        // And only *before* the active sentence. A clock at or past its start
        // is not early, even when the entry it resolves to began earlier: in a
        // run the CTC aligner left out of order, the clip playing now can start
        // before the one that played last. v2's clips are ascending, where that
        // cannot happen, so for them this half changes nothing; without it,
        // the out-of-order answer was thrown away and the end of the file
        // advanced from the stale entry back into the same file.
        if let active = activeEntry, entry.start < active.start,
           time < active.start, active.start - time < Self.backwardsClockSlack {
            return
        }

        // Two questions, which used to be one: has the *entry* changed, and has
        // the *fragment*? In a v2 book they are the same question. In a v3 book
        // one sentence owns several entries in a row — the audio-only holes
        // before and after it, the continuation of a sentence that runs into
        // the next file — and every one names the sentence's fragment. Asking
        // only about the fragment left `activeEntry` on the sentence while its
        // after-hole played, and everything that asks where the audio is reads
        // `activeEntry`: `currentAnchor` clamped the playhead back into the
        // sentence, `skipBook` measured from it, and a file that ended in the
        // hole advanced from the sentence, onto the hole, and replayed it for
        // ever.
        //
        // The highlight and the page still move on the fragment alone — as
        // the timeline scopes it, to its document. A hole names the sentence
        // it hangs off, which is what v2 lit for those same seconds, having
        // folded them into that sentence's clip; repainting it would change
        // nothing anybody can see, and the reader counts a fragment change as
        // narration arriving somewhere.
        if entry != activeEntry {
            let previousDocument = activeEntry?.textHref
            let fragmentMoved = entry.fragmentID != activeFragmentID
                || entry.textHref != previousDocument
            activeEntry = entry
            if fragmentMoved {
                activeFragmentID = entry.fragmentID
                onFragmentChange?(entry.fragmentID)
            }
            if entry.textHref != previousDocument {
                onChapterChange?(entry.textHref)
                // Only a real boundary, not the first fragment of a session.
                if previousDocument != nil { onChapterChangeObserved?() }
            }
        }
        // Book progress uses the virtual timeline so it advances smoothly across
        // chapter and track boundaries.
        let elapsedWithin = max(0, time - entry.start)
        bookProgress = timeline.progression(
            atBookTime: entry.cumulativeEnd - entry.duration + elapsedWithin,
        )
    }

    private func advanceToNextFile() async {
        // An ending that arrives while a move is in flight is not one to act
        // on: the listener has already gone somewhere else. The ending reaches
        // here through the Task `init` hops it through, so a scrub or a tap
        // whose move starts before that Task runs has already put
        // `activeEntry` on its destination by the time it does. Answering it
        // advanced from *there*, past the rest of a file the listener had only
        // just moved into, and reported the chapter they moved into as ended.
        // Nothing is lost by dropping it: the move owns the playhead, and the
        // file it lands in posts its own ending when it runs out.
        //
        // The hop is the only window. `AudioPlayer.load` removes the replaced
        // item's end observer before it suspends, and a notification that item
        // had already queued for the main queue goes with it — tried: posted
        // from another thread while the main thread was held, it was not
        // delivered once a load had run — so the player needs no guard of its
        // own.
        guard movesInFlight == 0 else { return }
        // The first entry of the next file, whatever it is — not the next
        // sentence. When a file runs out, what plays next is whatever audio
        // the book has next: a hole, the continuation of the sentence just
        // heard, or a whole audio chapter, which `entry(after:)` would step
        // over in silence. Nor the next entry: in a file whose clips the
        // aligner left out of order, the entry playing at its end need not be
        // its last, and the entry after it was more of the same file — the
        // advance seeked back into it and the file ended, and seeked back, for
        // ever. At the end of the book there is nothing, and that is a pause,
        // including when the book ends on a hole.
        //
        // For a file whose clips ascend the two answers are the same, with one
        // exception: a last clip shorter than a tick of the screen-off clock,
        // where `activeEntry` is still the one before it. The next entry
        // replayed that sub-second clip once before moving on; the next file
        // does not, and the clip has already been heard.
        guard let entry = activeEntry, let next = timeline.entry(followingFileOf: entry) else {
            player.pause()
            return
        }
        let endedDocument = entry.textHref
        guard await move(to: next) else { return }
        // A chapter that ran out, which is what the end-of-chapter timer is
        // waiting for. `advance(to:)` cannot see this one: `move(to:)` has
        // already set `activeEntry`, so the clock's next tick finds its own
        // boundary test false. A book with one audio file per chapter
        // therefore never reported an ending at all, and a timer set at bedtime
        // played through the night.
        //
        // Announced from here rather than from inside `move`, which is what
        // keeps `movesInFlight` from swallowing the one ending that is real:
        // the counter is back to zero by the time `move` has returned, and the
        // document that ended was captured before it was called.
        if endedDocument != next.textHref { onChapterChangeObserved?() }
        // Only if the boundary left it playing — read *after* the callback,
        // exactly as `AudiobookCoordinator.advance()` reads it. An
        // end-of-chapter sleep timer pauses inside that callback, and the first
        // version of this guard latched `isPlaying` *before* `move(to:)`, so it
        // then called `play()` and undid the pause in the same turn, after the
        // timer had already reset itself — the book played on into the night,
        // which is the failure the callback above exists to stop.
        //
        // The same late read also covers what the early one was for: anything
        // that paused between `onFinishedFile` and here — the route handler
        // when AirPods come out, an interruption — still reads as not playing.
        // `isPlaying` is the coordinator's intent, not AVPlayer's rate, and
        // `load` preserves it, so a file boundary alone never clears it.
        guard player.isPlaying else { return }
        player.play()
    }

    // MARK: - Seeking

    /// Starts (or continues) playback at a specific narrated fragment.
    ///
    /// - Returns: whether it moved there. False when the entry's audio file is
    ///   missing, in which case nothing plays either.
    @discardableResult
    public func play(from entry: SMILEntry) async -> Bool {
        guard await move(to: entry) else { return false }
        player.play()
        return true
    }

    /// Positions the playhead and the highlight without making a sound.
    ///
    /// `play(from:)` minus the play, and deliberately not `seek(toFragment:)`:
    /// this announces nothing through `onSeek`, because nobody named this
    /// place. It exists for the hand-off back from the car — a driver who
    /// parked and pressed pause wants the page they stopped on, in a quiet
    /// room, and a seek would relabel that page as a position they *chose* and
    /// disarm the guard that protects the real one.
    ///
    /// - Returns: whether it moved there. False when the entry's audio file is
    ///   missing, in which case nothing moved.
    @discardableResult
    public func prepare(at entry: SMILEntry) async -> Bool {
        await move(to: entry)
    }

    /// `play(from:)` for a place the listener named: the seek is announced once
    /// the move has happened, and not at all if it did not.
    private func jump(to entry: SMILEntry) async {
        if await play(from: entry) { onSeek?() }
    }

    /// How far short of an entry's end a move into it may land.
    ///
    /// A scrub to the far end of the bar names the very end of the last entry,
    /// which is the end of its file. A seek that lands exactly on an item's
    /// end may never be told it played to the end, and without that
    /// notification `isPlaying` stays true over a player that has stopped —
    /// the failure `AudioPlayer.load` guards against for an offset of zero.
    /// Landing a hair short lets the file play out and the book end the
    /// ordinary way.
    ///
    /// Two frames of the player's 1/600 s timescale rather than one, because
    /// `AudioPlayer.seek` rounds its target *up* to the next frame: a target
    /// one frame short of an end that sits on a frame boundary comes back up
    /// onto it about one time in fifty.
    static let endOfEntryMargin: TimeInterval = 2.0 / 600

    /// Moves the playhead and the highlight without touching whether audio is
    /// playing. False when the entry's audio file is missing and nothing moved.
    ///
    /// Split out of `play(from:)` because `seek(toBookProgress:)` is a protocol
    /// requirement with a neutral contract — the audiobook implementation moves
    /// the playhead and nothing else — and routing a Lock Screen scrub through
    /// `play(from:)` made a paused book start reading itself aloud in a quiet
    /// room, from the scrubber, the skip buttons and the macOS key commands
    /// alike.
    ///
    /// - Parameter offset: how far into the entry to land, for a scrub or a
    ///   skip, which name a time rather than a sentence. Every other move
    ///   lands at the entry's start. Clamped into the entry, and short of its
    ///   very end by `endOfEntryMargin`.
    @discardableResult
    private func move(to entry: SMILEntry, offset: TimeInterval = 0) async -> Bool {
        // Resolved before a single piece of state moves, exactly as
        // `AudiobookCoordinator.load` resolves its own destination first: a
        // missing audio file is a refusal, not a move, and nothing may be
        // published for one — not the highlight, not the scrubber, not a page
        // turn. Nil means the file is already loaded and only the playhead has
        // to travel.
        let destination: URL?
        if player.currentAudioHref != entry.audioHref {
            guard let url = audioFiles[entry.audioHref] else { return false }
            destination = url
        } else {
            destination = nil
        }
        let within = offset.isFinite
            ? min(max(0, offset), max(0, entry.duration - Self.endOfEntryMargin)) : 0

        // Everything published BEFORE the await, for the reason
        // `AudiobookCoordinator.seek(toBookTime:)` publishes before its own: the
        // player's periodic observer keeps firing across a load and a seek
        // alike, and a sample landing in the middle is answered against whatever
        // this coordinator has already said. Left until afterwards, the file had
        // already been swapped while `activeEntry` still named the old sentence,
        // so `advance(to:)` resolved the new file's clock of zero to its *first*
        // sentence, announced that as a chapter the listener had never reached,
        // and — because the document had changed — reported it as a chapter that
        // *ended*. It also overwrote `activeEntry` before the lines below read
        // `previousDocument` off it, so the real page turn was then skipped.
        let previousDocument = activeEntry?.textHref
        activeFragmentID = entry.fragmentID
        activeEntry = entry
        // Set here rather than left to the time observer: a paused player's
        // clock does not tick, so without this a paused scrub never reached
        // the scrubber or the Lock Screen.
        bookProgress = timeline.progression(atBookTime: entry.cumulativeEnd - entry.duration + within)
        onFragmentChange?(entry.fragmentID)
        // The boundary, announced from the one funnel every seek, skip,
        // sentence, paragraph and chapter command passes through.
        //
        // `advance(to:)` cannot do it for these: this method sets
        // `activeEntry` before returning, so the clock's next tick finds its
        // `entry != activeEntry` test already false, and by
        // the tick after that `previousDocument` is the new document. A seek
        // across a chapter therefore fired `onChapterChange` *never* — not
        // late — so the page did not turn and `SleepTimer.chapterDidEnd()` was
        // never called, and an end-of-chapter timer set at bedtime played all
        // night. `ReaderModel.startNarration` compensated by hand for the play
        // path only.
        // `onChapterChange` only. **Not** `onChapterChangeObserved`: that one
        // means a chapter *ended*, and it drives the end-of-chapter sleep
        // timer. A seek, a skip, or a chapter picked from the list is not a
        // chapter ending — hanging the timer off the general signal is what
        // used to stop the book the moment a chapter was chosen, which
        // `NowPlayingController` documents at the point it wires them up. The
        // natural end-of-file path fires the other one, and only it.
        if let previousDocument, previousDocument != entry.textHref {
            onChapterChange?(entry.textHref)
        }

        // And the clock ignored for the length of the move, exactly as the
        // audiobook engine ignores it for the length of a load or a seek. The
        // lines above answer the sample that arrives holding the new place; this
        // answers the one that arrives holding the old, which resolves against
        // the file already swapped underneath it.
        movesInFlight += 1
        defer { movesInFlight -= 1 }
        if let destination {
            await player.load(url: destination, href: entry.audioHref, startAt: entry.start + within)
        } else {
            await player.seek(to: entry.start + within)
        }
        return true
    }

    public func seek(toFragment fragmentID: String) async {
        guard let entry = timeline.entry(forFragment: fragmentID) else { return }
        await jump(to: entry)
    }

    /// Skips within the BOOK, not within the current audio file.
    ///
    /// `AudioPlayer.skip` moves the playhead inside whichever file is loaded and
    /// clamps at that file's zero, so a fifteen-second rewind five seconds into
    /// a file landed at the start of the file rather than ten seconds earlier in
    /// the book — while the elapsed time published to the lock screen was
    /// book-wide. The audiobook coordinator already worked this way; this is the
    /// same contract for narration.
    public func skipBook(by delta: TimeInterval) async {
        let total = totalDuration
        guard total > 0 else { return }
        // Refuse rather than guess when narration has never played: the
        // coordinator is built eagerly on open and the reader footer draws the
        // skip buttons regardless, so with no anchor a skip resolved to
        // sentence one of the whole book — a third of a novel away from the
        // reader. The same contract as the audiobook's skip from a broken
        // clock.
        guard let entry = activeEntry else { return }
        // Anchored to the active entry and the player's own clock, not to
        // `bookProgress`: that field is written only by the periodic observer,
        // so in the first moments after `play(from:)` it still reads 0.
        let within = min(max(0, player.currentTime - entry.start), entry.duration)
        let current = entry.cumulativeEnd - entry.duration + within
        guard current.isFinite else { return }
        await seek(toBookProgress: max(0, min(current + delta, total)) / total)
    }

    /// Seeks by fraction of the whole book, for a scrubber, and for
    /// `skipBook` — to the time that fraction names, not to the start of the
    /// entry it falls in.
    ///
    /// The entry says which file and which fragment; how far into it the time
    /// falls is the other half of the place, and it used to be thrown away, so
    /// every scrub and skip landed at the start of the containing entry. On a
    /// v2 book that is a sentence, a few seconds early. On a v3 book a hole or
    /// an audio chapter is one entry minutes long: a scrub anywhere inside it
    /// went back to its start, a thirty-second skip forward from its middle
    /// went *backwards* — and every skip after it back to the same place — and
    /// the reader saved that start as a position the listener had chosen.
    public func seek(toBookProgress progress: Double) async {
        // A non-finite progress is not a place in the book. Refusing it is
        // the point: the inline clamp let NaN through, `totalDuration * NaN`
        // is NaN, and the seek that followed set `steeredAt`, so the position
        // writer persisted the result as a listener-*chosen* position — the one
        // origin PositionGuard may not refuse.
        guard let place = progress.asProgression else { return }
        let time = timeline.totalDuration * place
        guard let entry = timeline.entry(atBookTime: time) else { return }
        // Past the entry's end only at the end of the book, where
        // `entry(atBookTime:)` answers the last entry; `move` clamps it back.
        let within = time - (entry.cumulativeEnd - entry.duration)
        // A seek is not a play button: it lands paused when paused, playing
        // when playing, exactly as the audiobook implementation of this same
        // protocol method always has.
        if await move(to: entry, offset: within) { onSeek?() }
    }

    // MARK: - Actions

    /// Applies a mapped control action. This is the single funnel every surface
    /// goes through — screen, lock screen, headphones, CarPlay and the wheel —
    /// so a remapping applies everywhere at once.
    public func perform(_ action: PlaybackAction, using map: CommandMap) async {
        // Navigation names a place; playing, speed and the sleep timer do not.
        // Each navigation route announces its own seek, after it has moved.
        switch action {
        case .playPause:
            player.togglePlayPause()
        case .skipForward:
            await skipBook(by: map.skipForwardInterval)
        case .skipBackward:
            await skipBook(by: -map.skipBackwardInterval)
        case .nextSentence:
            if let entry = activeEntry, let next = timeline.entry(after: entry) { await jump(to: next) }
        case .previousSentence:
            if let entry = activeEntry, let previous = timeline.entry(before: entry) { await jump(to: previous) }
        case .nextParagraph:
            await moveParagraph(forward: true)
        case .previousParagraph:
            await moveParagraph(forward: false)
        case .nextChapter:
            await moveChapter(forward: true)
        case .previousChapter:
            await moveChapter(forward: false)
        case .speedUp:
            player.rate = Float(PlaybackRate.clamped(Double(player.rate) + PlaybackRate.step))
        case .speedDown:
            player.rate = Float(PlaybackRate.clamped(Double(player.rate) - PlaybackRate.step))
        // Discrete on purpose, never a toggle: the system sends these when it
        // has already decided which one it means, and its idea of the state —
        // the published rate — can lag `isPlaying` through a stall.
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .sleepTimer, .none:
            break
        }
    }

    /// A paragraph boundary is approximated by a run of sentences: the aligner
    /// numbers sentences per chapter, so stepping several sentences is the
    /// closest reliable equivalent without re-parsing the source markup.
    private static let sentencesPerParagraph = 3

    private func moveParagraph(forward: Bool) async {
        guard var entry = activeEntry else { return }
        for _ in 0 ..< Self.sentencesPerParagraph {
            guard let next = forward ? timeline.entry(after: entry) : timeline.entry(before: entry) else { break }
            entry = next
        }
        await jump(to: entry)
    }

    private func moveChapter(forward: Bool) async {
        guard let current = activeEntry else { return }
        let documents = timeline.entries.map(\.textHref).reduce(into: [String]()) { list, href in
            if list.last != href { list.append(href) }
        }
        guard let index = documents.firstIndex(of: current.textHref) else { return }
        let target = forward ? index + 1 : index - 1
        guard documents.indices.contains(target),
              let entry = timeline.firstEntry(inDocument: documents[target])
        else { return }
        await jump(to: entry)
    }
}

extension ReadalongCoordinator: PlaybackDriving {
    /// A readaloud's chapter name lives in the book's navigation document, not
    /// in the timeline, so the reader supplies it; the timeline knows only
    /// which text document is playing.
    public var currentChapterTitle: String { activeEntry?.textHref ?? "" }

    /// The current text document's extent on the virtual book timeline.
    ///
    /// The timeline precomputes these, so this is a dictionary lookup rather
    /// than a walk over every entry in the book.
    public var chapterSpan: (start: TimeInterval, duration: TimeInterval)? {
        guard let href = activeEntry?.textHref else { return nil }
        // The run the listener is actually in. A document the spine
        // references twice has two, and the merged range used to span both
        // plus everything between them.
        if let entry = activeEntry { return timeline.span(ofDocumentContaining: entry) }
        return timeline.span(ofDocument: href)
    }
}

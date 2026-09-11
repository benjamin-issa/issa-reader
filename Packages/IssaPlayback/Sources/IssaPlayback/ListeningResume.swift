import Foundation
import IssaCore
import IssaEPUB

/// Where an audiobook should resume, and — just as important — why it could
/// not be worked out.
///
/// Lifted out of `AppModel` so the ladder can be tested against the manifests
/// that actually break it. The one from the car had a single track called after
/// the upload, while everything stored about that book named the EPUB's
/// narration chunks: the anchor matched nothing, the stored position was on the
/// text clock, the overlay was not in memory on a cold launch, and the app
/// resumed at zero and then wrote that zero over a part-read novel.
///
/// Nothing here ever scales a *text* fraction by the audio duration. A fraction
/// of the text and a fraction of the audio are fractions of different
/// timelines — a book has spine items with no narration at all — so the
/// arithmetic produces a plausible number that is simply wrong, which in a car
/// is worse than an obvious one. When no rung answers, this says so.
///
/// An *audio* fraction from a different cut of the same narration is a
/// different matter, and the rung for it is the one thing here that answers
/// approximately. The two track lists are the same hours of speech chopped up
/// differently, so the fraction lands in roughly the right chapter rather than
/// in a different book — and every rung says, in `Reason.isExact`, whether it
/// was exact. Nothing downstream has to guess which kind of answer it got.
public enum ListeningResume {
    /// Which track list the manifest describes: the one the server serves, or
    /// one synthesised from the book's own media overlay. Carried only so the
    /// log can say which, because the two name their files differently and that
    /// difference is the whole of the bug this ladder guards against.
    public enum ManifestKind: String, Sendable {
        case original
        case synthesised
    }

    /// Which rung answered, or which way the ladder ran out.
    public enum Reason: String, Sendable, Equatable {
        /// An audio file and an offset into it, written by whichever engine
        /// last played. Exact, and the only thing that survives switching
        /// between the read-along and the audiobook.
        case anchor
        /// A stored position already on this manifest's clock.
        case audioPosition
        /// A reading position, converted through the media overlay.
        case readingPositionViaOverlay
        /// The anchor, resolvable but written before the position that is
        /// stored now — so somebody read on past it without narration. A real
        /// place in this track list, and not where the reader got to.
        case anchorOlderThanPosition
        /// A stored audio position from a *different* cut of the same
        /// narration, scaled onto this manifest's clock. Roughly the right
        /// place in the book and provably not the exact one.
        case audioPositionFromAnotherManifest
        /// This book has never been opened anywhere.
        case noStoredPosition
        /// There is a stored position, but nothing on the audio clock to place
        /// it with.
        case noAnchorStored
        /// There is an anchor, and it names a file no track in this manifest
        /// answers to. The case from the car.
        case anchorNamesUnknownFile

        /// Whether this rung named the place the listener was, or inferred one.
        ///
        /// The distinction the caller acts on, and the reason it is a `switch`
        /// rather than a list of the exact cases: a rung added later cannot
        /// quietly inherit "exact" by not being mentioned. Approximate is a
        /// real answer — somewhere roughly right beats silence at the front of
        /// a book, in a car — but it is not a place to *write down*, and
        /// `AppModel.prepareListeningGuard` holds the audio clock on exactly
        /// this bit until the listener names somewhere themselves.
        public var isExact: Bool {
            switch self {
            case .anchor, .audioPosition, .readingPositionViaOverlay:
                true
            case .anchorOlderThanPosition, .audioPositionFromAnotherManifest:
                false
            case .noStoredPosition, .noAnchorStored, .anchorNamesUnknownFile:
                false
            }
        }
    }

    /// The answer, with enough of the reasoning attached for a caller to log it
    /// and for a guard to decide whether to trust what plays next.
    public struct Resolution: Sendable, Equatable {
        /// Seconds into this manifest's book clock, or nil when no rung could
        /// answer honestly.
        public let bookTime: TimeInterval?
        public let reason: Reason

        /// Whether playback may start here *and* the position it writes may be
        /// persisted.
        ///
        /// Not the same question as "did a rung answer", which is what the old
        /// `isResolved` asked. A scaled fraction from another track list is an
        /// answer — it starts the car somewhere in the right chapter instead of
        /// at the title page — and it is still not a place the fifteen-second
        /// writer may save over a part-read novel. Both halves have to hold: a
        /// rung that answered, and a rung that was exact.
        public var isTrusted: Bool { bookTime != nil && reason.isExact }

        public init(bookTime: TimeInterval?, reason: Reason) {
            self.bookTime = bookTime
            self.reason = reason
        }
    }

    /// Runs the ladder, most exact rung first.
    /// - Parameter stored: the whole stored position, not just its locator —
    ///   the ladder needs to know *when* it was written, and a `ReadiumLocator`
    ///   cannot say. Taking the wrapper rather than a second `Double` parameter
    ///   is deliberate: no bare number in either epoch crosses this boundary
    ///   for a caller to get the units of wrong. See `StoredPosition.writtenAt`.
    /// - Parameter timeline: the book's media overlay, when it is in memory.
    ///   Absent on a cold launch straight into CarPlay, which is exactly when
    ///   this matters most — hence rung 3 answering nothing rather than
    ///   guessing.
    public static func resolve(
        anchor: AudioAnchor?,
        stored: StoredPosition?,
        timeline: SMILTimeline?,
        manifest: AudiobookManifest,
    ) -> Resolution {
        let locator = stored?.locator
        // Worked out once, because two rungs want it: the exact one at the top
        // and the fallback at rung 4.
        let anchorTime = anchor.flatMap { manifest.bookTime(for: $0) }

        // 1. The anchor, as long as nothing has been stored since it was
        //    written: a file and an offset, in the one language both engines
        //    speak. See `AudioAnchor`.
        //
        //    The age test is the half that was missing. An anchor is written
        //    when narration plays and left alone afterwards, so reading on in
        //    silence moves the stored position and not the anchor — narrate to
        //    0.20, relaunch, read to 0.70, press Listen, and the car resumed at
        //    0.20 and wrote it over the 0.70 fifteen seconds later.
        if let anchor, let anchorTime, anchor.isNewerThan(stored?.writtenAt) {
            return Resolution(bookTime: anchorTime, reason: .anchor)
        }

        // 2. A stored position already on *this* manifest's clock.
        //
        //    The href is what says which clock it is on, and it has to be
        //    checked. A fraction written against the server's single-file
        //    upload is not a fraction of the EPUB's eighty-five narration
        //    chunks, and a fraction of the chunks is not a fraction of the
        //    upload — the two track lists are the same audio cut up
        //    differently, so both numbers look perfectly reasonable and only
        //    one of them is a place in this book.
        var foreignAudioProgress: Double?
        if let locator, locator.isAudioScaled, let progress = locator.totalProgression?.asProgression {
            if manifest.trackIndex(matching: locator.href) != nil {
                return Resolution(bookTime: manifest.totalDuration * progress, reason: .audioPosition)
            }
            // Held for rung 5 rather than acted on here: an exact rung below
            // this one still outranks it.
            foreignAudioProgress = progress
        }

        // 3. A *reading* position, converted through the media overlay — the
        //    bridge Storyteller is built on, and exact when the timeline is in
        //    memory. A file and an offset is all this rung ever meant, and all
        //    it now says.
        if let locator, !locator.isAudioScaled,
           let timeline,
           let fragment = locator.sentenceID,
           let entry = timeline.entry(forFragment: fragment, inDocument: locator.href),
           let time = manifest.bookTime(inFile: entry.audioHref, offset: entry.start) {
            return Resolution(bookTime: time, reason: .readingPositionViaOverlay)
        }

        // 4. The anchor again, having lost rung 1 on age.
        //
        //    Not optional, and not merely tidy. Without it a losing anchor falls
        //    all the way to nothing, the caller plays from `atProgress: 0`, and
        //    a stale-but-real place in the book becomes chapter one — which is
        //    strictly worse than the stale place it was rejected for. It sits
        //    above rung 5 because a stale anchor is a place *in this track
        //    list*, where rung 5 infers a place *across* two of them.
        if let anchorTime {
            return Resolution(bookTime: anchorTime, reason: .anchorOlderThanPosition)
        }

        // 5. The fraction, scaled — and said out loud to be a guess.
        //
        //    The rung this ladder used to refuse outright, on the argument that
        //    two track lists are two clocks and a fraction of one is not a
        //    fraction of the other. True, and still true: the number below is
        //    not where the listener was. But the two lists are the *same
        //    narration* cut differently, so the fraction does name roughly the
        //    same place in the same book — and the alternative was chapter one,
        //    which in a car, with no screen worth reading, is worse than being
        //    a few minutes out. What stops a guess being written over a
        //    part-read novel is not this refusing to answer; it is the caller
        //    holding the audio clock because the answer was not exact. See
        //    `Resolution.isTrusted`.
        if let progress = foreignAudioProgress {
            return Resolution(
                bookTime: manifest.totalDuration * progress,
                reason: .audioPositionFromAnotherManifest)
        }

        // 6. Nothing this manifest can honestly act on, said in terms a log
        //    line can act on too.
        let reason: Reason = stored == nil
            ? .noStoredPosition
            : (anchor == nil ? .noAnchorStored : .anchorNamesUnknownFile)
        return Resolution(bookTime: nil, reason: reason)
    }
}

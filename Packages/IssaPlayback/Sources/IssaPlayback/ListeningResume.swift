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
/// Nothing here ever scales a text fraction by the audio duration. A fraction
/// of the text and a fraction of the audio are fractions of different
/// timelines — a book has spine items with no narration at all — so the
/// arithmetic produces a plausible number that is simply wrong, which in a car
/// is worse than an obvious one. When no rung answers, this says so.
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
        /// This book has never been opened anywhere.
        case noStoredPosition
        /// There is a stored position, but nothing on the audio clock to place
        /// it with.
        case noAnchorStored
        /// There is an anchor, and it names a file no track in this manifest
        /// answers to. The case from the car.
        case anchorNamesUnknownFile
    }

    /// The answer, with enough of the reasoning attached for a caller to log it
    /// and for a guard to decide whether to trust what plays next.
    public struct Resolution: Sendable, Equatable {
        /// Seconds into this manifest's book clock, or nil when no rung could
        /// answer honestly.
        public let bookTime: TimeInterval?
        public let reason: Reason
        /// Whether a stored audio position was passed over because its href
        /// named no track here. Worth saying out loud: it is the difference
        /// between "nothing was stored" and "what was stored belongs to a
        /// different track list", and only the second is a bug worth chasing.
        public let skippedForeignAudioPosition: Bool

        public var isResolved: Bool { bookTime != nil }

        public init(
            bookTime: TimeInterval?, reason: Reason, skippedForeignAudioPosition: Bool = false,
        ) {
            self.bookTime = bookTime
            self.reason = reason
            self.skippedForeignAudioPosition = skippedForeignAudioPosition
        }
    }

    /// Runs the ladder, most exact rung first.
    /// - Parameter timeline: the book's media overlay, when it is in memory.
    ///   Absent on a cold launch straight into CarPlay, which is exactly when
    ///   this matters most — hence rung 3 answering nothing rather than
    ///   guessing.
    public static func resolve(
        anchor: AudioAnchor?,
        stored: ReadiumLocator?,
        timeline: SMILTimeline?,
        manifest: AudiobookManifest,
    ) -> Resolution {
        // 1. The anchor: a file and an offset, in the one language both engines
        //    speak. See `AudioAnchor`.
        if let anchor, let time = manifest.bookTime(for: anchor) {
            return Resolution(bookTime: time, reason: .anchor)
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
        var skippedForeignAudioPosition = false
        if let stored, stored.isAudioScaled {
            let namesATrackHere = manifest.trackIndex(matching: stored.href) != nil
            if namesATrackHere, let progress = stored.totalProgression?.asProgression {
                return Resolution(bookTime: manifest.totalDuration * progress, reason: .audioPosition)
            }
            skippedForeignAudioPosition = !namesATrackHere
        }

        // 3. A *reading* position, converted through the media overlay — the
        //    bridge Storyteller is built on, and exact when the timeline is in
        //    memory.
        if let stored, !stored.isAudioScaled,
           let timeline,
           let fragment = stored.sentenceID,
           let entry = timeline.entry(forFragment: fragment, inDocument: stored.href),
           let time = manifest.bookTime(
               for: AudioAnchor(audioHref: entry.audioHref, offset: entry.start, writtenAt: 0)) {
            return Resolution(bookTime: time, reason: .readingPositionViaOverlay)
        }

        // 4. Nothing this manifest can honestly act on, said in terms a log
        //    line can act on too.
        let reason: Reason = stored == nil
            ? .noStoredPosition
            : (anchor == nil ? .noAnchorStored : .anchorNamesUnknownFile)
        return Resolution(
            bookTime: nil, reason: reason,
            skippedForeignAudioPosition: skippedForeignAudioPosition)
    }
}

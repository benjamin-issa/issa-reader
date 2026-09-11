import Foundation

/// Where playback is, said in the one language both engines speak: an audio
/// file, and how far into it.
///
/// One book has two playback engines here. `ReadalongCoordinator` drives
/// narration against the EPUB's media overlay; `AudiobookCoordinator` drives
/// the server's track list. They keep **different clocks** — the read-along's
/// is a running sum of *clip* durations, the audiobook's a running sum of
/// *file* durations — and `totalProgression` had been carrying whichever of
/// them wrote last, on the assumption that a fraction is a fraction.
///
/// It is not. *The Hero of Ages* has 109 spine items and 85 narrated ones: the
/// title page, the copyright notice, the maps and every "Part One" divider
/// carry text and no audio. So a text fraction always understates the audio
/// fraction, and resuming a 27-hour audiobook from a reading position landed
/// tens of minutes early — "wildly off, too early", from the car.
///
/// A fraction cannot bridge that. A file name and a number of seconds can: the
/// read-along reads them off the media-overlay entry it is speaking
/// (`SMILEntry.audioHref` and `start`), the audiobook off the track it is
/// playing, and either can seek to the other's. That is the whole of this type,
/// and it is why switching format mid-book can be exact rather than
/// approximate.
public struct AudioAnchor: Codable, Sendable, Equatable {
    /// The audio file, as whichever side wrote it names it.
    ///
    /// Kept verbatim rather than normalised on the way in, because the two
    /// sides genuinely have different names for the same file and normalising
    /// would throw away the evidence of which wrote it. Matching normalises
    /// instead — see `AudiobookManifest.trackIndex(matching:)`.
    public let audioHref: String
    /// Seconds into that file.
    public let offset: TimeInterval
    /// Seconds since the epoch. A stale anchor must lose to a fresh one: both
    /// engines write these, and the last one to play is the one that knows
    /// where the listener is.
    public let writtenAt: Double

    public init(audioHref: String, offset: TimeInterval, writtenAt: Double) {
        self.audioHref = audioHref
        // Non-finite offsets have reached seeks in this app before and been
        // persisted as a chosen position; refuse them at the door.
        self.offset = offset.isFinite ? max(0, offset) : 0
        self.writtenAt = writtenAt
    }

    /// Whether this anchor was written after some other moment — the instant a
    /// reading position was stored, in practice.
    ///
    /// Against an instant rather than against another anchor. The anchor-versus-
    /// anchor rule already ships, in SQL, in `LibraryStore.setAudioAnchor`'s
    /// `WHERE excluded.writtenAt > audioAnchor.writtenAt`; a Swift twin of it
    /// would be a second definition of one rule, free to drift from the one
    /// that actually decides what is on disk. The question that had no answer
    /// anywhere was the other one: an anchor is a *place*, a stored position is
    /// a *place*, and until now the resume ladder trusted the anchor however
    /// long ago it was written. Narrate to 0.20, relaunch, read on in silence
    /// to 0.70, press Listen — and the car resumed at 0.20 and then wrote that
    /// over the 0.70.
    ///
    /// `Date` rather than a bare `Double`, because the two numbers being
    /// compared are in different units: this one is epoch seconds and
    /// `StoredPosition.timestamp` is epoch milliseconds. See
    /// `StoredPosition.writtenAt`.
    ///
    /// Strictly newer, and nothing rides on the tie: both writers stamp the
    /// anchor *after* the position it belongs to, so an anchor that is merely
    /// equal has already lost a race it was never in.
    public func isNewerThan(_ instant: Date?) -> Bool {
        guard let instant else { return true }
        return Date(timeIntervalSince1970: writtenAt) > instant
    }
}

public extension AudiobookManifest {
    /// The playable track that names this file, if any.
    ///
    /// The exact href first, and only then the **file name alone**. The name
    /// pass has to stay: the media overlay names an archive path inside the
    /// EPUB (`OEBPS/audio/ch62.mp3`) while the manifest names whatever the
    /// server serves (`ch62.mp3`) — the same file under two names.
    /// `ReadiumLocator.normalizeHref` compares the last *two* components, which
    /// is right for text, where `text/ch01` and `images/ch01` are different
    /// resources, and wrong here for that very reason.
    ///
    /// But a file name is not always a name. A manifest synthesised over a
    /// book's own narration chunks carries full archive paths on purpose, and a
    /// book laid out `Audio/ch01/track.mp3`, `Audio/ch02/track.mp3` — the layout
    /// `AudioExtraction.filename(for:)` exists to flatten — has one file name
    /// for the whole book. On the name alone every chunk collapsed onto track
    /// one: an anchor thirty seconds into chapter twelve resolved to thirty
    /// seconds into the *book*, the resume reported success, and the position
    /// guard let that zero be written over a part-read novel. The exact pass
    /// costs a string compare and cannot be wrong.
    ///
    /// And the exact pass is not enough on its own, because it is only reached
    /// when it misses. `ChunkManifest.make` drops a chunk with no extracted file
    /// and a chunk with no length, and the moment one of those `track.mp3`s is
    /// gone the anchor naming it falls through to the name pass — where the
    /// *other* chapters still answer to `track.mp3`, and the first of them won.
    /// A different chapter entirely, returned as `.anchor`: reported as a
    /// success, and a success is what releases the hold on the audio clock. So a
    /// name that two or more playable tracks answer to is not a name for any of
    /// them, and this returns nil rather than choosing between them.
    ///
    /// Not gated on where the manifest came from. This type does not know its
    /// own provenance — `ManifestKind` is a label the caller attaches, over in
    /// IssaPlayback, and reaching for it from IssaCore would invert a package
    /// dependency — and provenance is in any case only a proxy for the property
    /// that actually decides the answer, which is whether the name is ambiguous.
    ///
    /// One residual risk, documented rather than coded around: if every
    /// `track.mp3` but one is dropped, the survivor's name *is* unique again,
    /// and any anchor from that book resolves onto it. The blast radius is a
    /// manifest with one chunk left in it, where the wrong answer and the right
    /// one are the same track.
    func trackIndex(matching audioHref: String) -> Int? {
        if let exact = playableTracks.firstIndex(where: { $0.href == audioHref }) { return exact }
        let wanted = Self.audioFileName(audioHref)
        guard !wanted.isEmpty else { return nil }
        var match: Int?
        for (index, track) in playableTracks.enumerated()
            where Self.audioFileName(track.href) == wanted {
            guard match == nil else { return nil }
            match = index
        }
        return match
    }

    /// Where a file and an offset into it fall on this manifest's book clock.
    ///
    /// `nil` when no track answers to that file — a book whose audio the server
    /// serves under names the EPUB does not use. Returning `nil` rather than a
    /// guess is the point: a wrong number here is the bug this type exists for.
    ///
    /// Stated over the pair rather than only over an `AudioAnchor`, because a
    /// media-overlay entry is a file and an offset too and has no business
    /// pretending to be an anchor to say so. `ListeningResume`'s overlay rung
    /// used to fabricate one stamped `writtenAt: 0` purely to reach this
    /// arithmetic, which was harmless until an anchor's age started deciding
    /// anything — at which point a synthetic anchor dated 1970 is a landmine.
    func bookTime(inFile audioHref: String, offset: TimeInterval) -> TimeInterval? {
        guard let index = trackIndex(matching: audioHref) else { return nil }
        let track = playableTracks[index]
        // The same door `AudioAnchor.init` shuts: a non-finite offset has
        // reached a seek in this app before, and NaN propagates through the
        // clamp below rather than being stopped by it.
        let sane = offset.isFinite ? max(0, offset) : 0
        // Clamped to the track: an anchor written against a differently
        // transcoded copy can overshoot, and overshooting rolls into the next
        // chapter silently.
        let within = min(sane, track.duration ?? sane)
        return startTime(ofTrackAt: index) + within
    }

    /// Where an anchor falls on this manifest's book clock.
    func bookTime(for anchor: AudioAnchor) -> TimeInterval? {
        bookTime(inFile: anchor.audioHref, offset: anchor.offset)
    }

    /// The last path component, lowercased, with query and fragment removed.
    static func audioFileName(_ href: String) -> String {
        var value = href
        if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex ..< hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[value.startIndex ..< query]) }
        value = value.removingPercentEncoding ?? value
        return value.split(separator: "/").last.map { $0.lowercased() } ?? ""
    }
}

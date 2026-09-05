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

    /// Whether this anchor is newer than one already held.
    public func isNewerThan(_ other: AudioAnchor?) -> Bool {
        guard let other else { return true }
        return writtenAt > other.writtenAt
    }
}

public extension AudiobookManifest {
    /// The playable track that names this file, if any.
    ///
    /// Matched on the **file name alone**, not the path. The media overlay
    /// names an archive path inside the EPUB (`OEBPS/audio/ch62.mp3`) while the
    /// manifest names whatever the server serves (`ch62.mp3`) — the same file
    /// under two names. `ReadiumLocator.normalizeHref` compares the last *two*
    /// components, which is right for text, where `text/ch01` and `images/ch01`
    /// are different resources, and wrong here for that very reason.
    func trackIndex(matching audioHref: String) -> Int? {
        let wanted = Self.audioFileName(audioHref)
        guard !wanted.isEmpty else { return nil }
        return playableTracks.firstIndex { Self.audioFileName($0.href) == wanted }
    }

    /// Where an anchor falls on this manifest's book clock.
    ///
    /// `nil` when no track answers to that file — a book whose audio the server
    /// serves under names the EPUB does not use. Returning `nil` rather than a
    /// guess is the point: a wrong number here is the bug this type exists for.
    func bookTime(for anchor: AudioAnchor) -> TimeInterval? {
        guard let index = trackIndex(matching: anchor.audioHref) else { return nil }
        let track = playableTracks[index]
        // Clamped to the track: an anchor written against a differently
        // transcoded copy can overshoot, and overshooting rolls into the next
        // chapter silently.
        let within = min(max(0, anchor.offset), track.duration ?? anchor.offset)
        return startTime(ofTrackAt: index) + within
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

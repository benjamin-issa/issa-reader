import Foundation

/// The stand-in for a downloaded audiobook whose manifest the server cannot
/// give right now: one track over the whole downloaded file, whose clock is
/// seconds into the file.
///
/// A place on that clock means nothing to the server, which names a track and
/// an offset into it. This maps one to the other through the manifest that was
/// kept beside the download, and only when that manifest describes the same
/// audio as the file. Nothing here guesses: with no kept manifest, or one of
/// another length, there is no place to name, and the caller keeps the place on
/// the device alone.
public enum OfflineStandIn {
    /// How far the kept manifest's total may be from the file's measured length
    /// and still describe the same audio: two seconds, or half a percent of a
    /// long book.
    public static func tolerance(forLength length: TimeInterval) -> TimeInterval {
        max(2, 0.005 * length)
    }

    /// Whether the kept manifest is of the downloaded file.
    public static func matches(_ kept: AudiobookManifest, fileLength: TimeInterval) -> Bool {
        guard fileLength > 0, !kept.playableTracks.isEmpty else { return false }
        return abs(kept.totalDuration - fileLength) <= tolerance(forLength: fileLength)
    }

    /// A place in the server's terms.
    public struct Place: Equatable, Sendable {
        public let trackIndex: Int
        public let track: AudiobookManifest.Track
        /// Seconds into that track.
        public let offset: TimeInterval
        /// The fraction of that track, as a streamed session writes it.
        public let progression: Double
        /// The fraction of the whole book.
        public let totalProgression: Double
    }

    /// The track and offset a point in the file is, by cumulative duration of
    /// the kept manifest's playable tracks in order. Nil when there is no kept
    /// manifest or it does not match the file. A point past the end, within the
    /// tolerance, is the end of the last track.
    public static func place(
        atFileTime time: TimeInterval, kept: AudiobookManifest?, fileLength: TimeInterval,
    ) -> Place? {
        guard let kept, matches(kept, fileLength: fileLength), time.isFinite,
              let located = kept.locate(bookTime: time)
        else { return nil }
        let track = kept.playableTracks[located.index]
        let duration = track.duration ?? 0
        let total = kept.totalDuration
        let within = kept.startTime(ofTrackAt: located.index) + located.offset
        return Place(
            trackIndex: located.index, track: track, offset: located.offset,
            progression: duration > 0 ? min(max(located.offset / duration, 0), 1) : 0,
            totalProgression: total > 0 ? min(max(within / total, 0), 1) : 0)
    }
}

/// Where a stand-in session got to, kept beside the download when no place
/// could be written to the server. Never sent anywhere.
public struct StandInPlace: Codable, Equatable, Sendable {
    /// Seconds into the downloaded file.
    public var fileSeconds: TimeInterval
    /// Epoch milliseconds, the unit stored positions are stamped in.
    public var writtenAt: Double

    public init(fileSeconds: TimeInterval, writtenAt: Double) {
        self.fileSeconds = fileSeconds
        self.writtenAt = writtenAt
    }
}

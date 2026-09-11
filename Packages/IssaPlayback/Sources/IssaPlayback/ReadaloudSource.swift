import Foundation
import IssaCore
import IssaEPUB

/// A downloaded read-along, opened far enough to play it: the package, the
/// media overlay, and the narration on disk.
///
/// The three steps were already written down separately — `EPUBPackage.open`,
/// `SMILParser.timeline`, `AudioExtraction.extractAudio` — and the reader
/// performs them in that order when a book is opened. The car cannot: CarPlay is
/// its own scene and starts a book with no reader anywhere, so `startListening`
/// has to be able to do the same three things from a cold launch. Naming them
/// once keeps the two paths from drifting into two ideas of what a read-along is.
public struct ReadaloudSource: Sendable {
    public let package: EPUBPackage
    public let timeline: SMILTimeline
    /// Archive href to on-disk URL, as `AudioExtraction` returns it.
    public let audioFiles: [String: URL]

    /// - Parameters:
    ///   - package: an already-open package, when the caller has one. A reader
    ///     on screen holds both this and the timeline, and reopening the archive
    ///     to build them a second time is a ZIP inflate and a full overlay parse
    ///     for an answer already in memory.
    ///   - timeline: likewise.
    ///
    /// Blocking, all three steps: inflating a few hundred megabytes of narration
    /// is not something to do on the main actor. Callers run it on a detached
    /// task.
    public static func load(
        epubURL: URL,
        bookID: String,
        package: EPUBPackage? = nil,
        timeline: SMILTimeline? = nil,
        into directory: URL? = nil,
    ) throws -> ReadaloudSource {
        let opened = try package ?? EPUBPackage.open(url: epubURL)
        let overlay = timeline ?? SMILParser.timeline(for: opened)
        let files = try AudioExtraction.extractAudio(
            from: opened, timeline: overlay, bookID: bookID, into: directory)
        return ReadaloudSource(package: opened, timeline: overlay, audioFiles: files)
    }
}

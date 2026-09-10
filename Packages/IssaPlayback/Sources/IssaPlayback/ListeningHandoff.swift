import Foundation
import IssaCore
import IssaEPUB

/// Whether the car's engine should hand the book back to the reader on screen,
/// and — just as important — why it should not.
///
/// Two engines play one book. `AudiobookCoordinator` is what CarPlay, the lock
/// screen and the Listen button start; for a downloaded read-along it plays the
/// EPUB's own narration chunks, so it knows exactly where it is but has no
/// highlight and no page. `ReadalongCoordinator` is what the reader's text
/// follows. They are exclusive — two `AVQueuePlayer`s would put two voices in
/// the room — so coming back to the phone after a drive used to leave the page
/// sitting where it was an hour ago while the car engine narrated on through
/// the speaker.
///
/// Lifted out of `AppModel` for the reason `ListeningResume` was: the decision
/// is a ladder over facts, every rung of it is a case someone hit, and a ladder
/// buried in a method that needs a car, a CarPlay session and a downloaded
/// novel to reach is a ladder nothing tests. The rungs are ordered so the first
/// failure is the most useful thing to say — "the car is still connected" is a
/// different situation from "this reader has no narration yet", and a log line
/// naming the wrong one sends the next person looking in the wrong place.
///
/// `place` is the same mapping `ReaderModel.resolveLanding` does when a book is
/// opened cold after a drive: the anchor names an audio file and an offset, and
/// only the media overlay can say which sentence of which chapter that is. One
/// copy, so the two directions of the same bridge cannot drift apart.
public enum ListeningHandoff {
    /// What woke the decision up. Carried only so the log can say which — the
    /// four arrive in different circumstances and a hand-off that only ever
    /// fires from one of them is a hand-off that is half wired up.
    public enum Trigger: String, Sendable {
        /// A reader appeared, or came back to the front of the stack.
        case readerVisible
        /// The phone was picked up and the app came back to the foreground.
        case foreground
        /// A reader finished extracting its narration, which on a cold open
        /// happens well after the screen appeared.
        case readerReady
        /// The car went away. Until it does the driver is still listening.
        case carDisconnected
    }

    /// Why nothing was handed over. Every one of these is an ordinary state,
    /// not an error — the decision runs on four triggers and most of the time
    /// there is simply nothing to move.
    public enum Skip: String, Sendable, Equatable {
        /// No audiobook engine is playing anything.
        case notListening
        /// No reader on screen to hand it to.
        case noVisibleReader
        /// The reader on screen is a different book from the one playing, which
        /// is a listener browsing while the audiobook runs — not a hand-off.
        case differentBook
        /// The car is still connected. This is the one rung that exists for a
        /// person rather than for the code: the phone in a pocket at 70mph
        /// must not silently take the book off the dashboard.
        case carConnected
        /// The app is not frontmost. Being backgrounded does not dismiss the
        /// reader on iOS, so a visible reader alone would fire this while the
        /// phone was in a pocket.
        case background
        /// The reader has not finished opening the book, or the book has no
        /// narration to hand to. Nothing to aim at yet; `readerReady` brings
        /// the decision back when there is.
        case readerNotReady
        /// The engine has not played anything, so it has no place to hand over.
        case noAnchor
        /// The anchor names an audio file this book's overlay has never heard
        /// of — the server's single upload against the EPUB's own chunks. The
        /// same mismatch `ListeningResume.anchorNamesUnknownFile` describes
        /// from the other side.
        case anchorNamesNoFile
        /// A hand-off is already running. The four triggers overlap — waking
        /// the phone onto an open reader fires three of them — and a second
        /// pass while the first is awaiting its audio load would stop the
        /// engine out from under it.
        case alreadyHandingOff
        /// The read-along refused to move: the sentence's audio file is not on
        /// disk. Decided by the caller after the fact rather than by `decide`,
        /// which cannot know what is extracted.
        case audioFileMissing
    }

    /// Where the reader has to pick the book up.
    ///
    /// `wasPlaying` is the whole difference between the two shapes of this: a
    /// driver who parked mid-sentence expects the phone to carry on, and one
    /// who pressed pause at the door expects a quiet room with the right page
    /// in it.
    public struct Target: Sendable, Equatable {
        /// Which spine item the sentence lives in, so the reader can load it.
        public let spineIndex: Int
        /// The sentence itself, in the terms the read-along engine acts on.
        public let entry: SMILEntry
        /// The anchor it was placed from, kept for the log: it is the only
        /// thing that says how far into the file the car actually was.
        public let anchor: AudioAnchor
        /// Whether the car engine was audible at the moment of the hand-off.
        public let wasPlaying: Bool

        public init(
            spineIndex: Int, entry: SMILEntry, anchor: AudioAnchor, wasPlaying: Bool,
        ) {
            self.spineIndex = spineIndex
            self.entry = entry
            self.anchor = anchor
            self.wasPlaying = wasPlaying
        }
    }

    public enum Decision: Sendable, Equatable {
        case handOff(Target)
        case skip(Skip)
    }

    /// Runs the ladder. First failing rung names the reason.
    ///
    /// Every input is passed in rather than read from a model, so the whole
    /// decision is a function of nine facts and the cases that matter — the
    /// car still connected, the phone still in a pocket, a reader open on a
    /// different book — can be stated in a test instead of staged in a car.
    public static func decide(
        listeningBookUUID: String?,
        visibleBookUUID: String?,
        surface: ControlSurface,
        isForeground: Bool,
        anchor: AudioAnchor?,
        isPlaying: Bool,
        package: EPUBPackage?,
        timeline: SMILTimeline?,
        hasReadalong: Bool,
    ) -> Decision {
        guard let listeningBookUUID else { return .skip(.notListening) }
        guard let visibleBookUUID else { return .skip(.noVisibleReader) }
        guard visibleBookUUID == listeningBookUUID else { return .skip(.differentBook) }
        guard surface != .carPlay else { return .skip(.carConnected) }
        guard isForeground else { return .skip(.background) }
        guard let package, let timeline, hasReadalong else { return .skip(.readerNotReady) }
        guard let anchor else { return .skip(.noAnchor) }
        guard let placed = place(anchor, in: package, timeline: timeline) else {
            return .skip(.anchorNamesNoFile)
        }
        return .handOff(
            Target(
                spineIndex: placed.spineIndex, entry: placed.entry,
                anchor: anchor, wasPlaying: isPlaying))
    }

    /// Turns an audio position into a sentence and the chapter it is in.
    ///
    /// The media overlay is the bridge — the anchor names a file and an offset,
    /// and the timeline says which sentence that is. Falling back to the file's
    /// first entry when the offset lands before its first clip: the file still
    /// names the chapter exactly, and only the sentence within it is
    /// approximate. Landing nowhere at all would be worse, and it is the case a
    /// chunk whose first clip starts a beat in produces every time.
    ///
    /// The spine index goes through `ReadiumLocator.matchesHref` rather than a
    /// string comparison because the overlay and the OPF spell the same
    /// resource differently often enough to matter.
    public static func place(
        _ anchor: AudioAnchor, in package: EPUBPackage, timeline: SMILTimeline,
    ) -> (spineIndex: Int, entry: SMILEntry)? {
        guard let entry = timeline.entry(inFile: anchor.audioHref, at: anchor.offset)
            ?? timeline.firstEntry(inFile: anchor.audioHref)
        else { return nil }
        guard let index = package.spine.firstIndex(where: {
            ReadiumLocator(href: entry.textHref, type: "application/xhtml+xml")
                .matchesHref($0.href)
        }) else { return nil }
        return (index, entry)
    }
}

import AVFoundation
import Foundation
import IssaEPUB
import UniformTypeIdentifiers

/// Whether this device can play a book's narration, asked before the book is
/// added.
///
/// A book from a server was aligned by Storyteller, which writes audio this
/// app plays. A book from the reader's own files can carry anything a media
/// overlay may name — Opus in a `.opus` file is a common one — and narration
/// that is offered and then plays nothing is worse than a book added as text
/// with a note saying why.
public enum AudioPlayability {
    /// Whether AVFoundation says it plays this file.
    ///
    /// By the media type the manifest declares, as AVFoundation is asked about
    /// any stream; where the manifest declares none, by the type the file's
    /// extension stands for. A file nothing can be said about is not playable.
    public static func isPlayable(mediaType: String?, href: String) -> Bool {
        if let mediaType = mediaType?.trimmingCharacters(in: .whitespaces), !mediaType.isEmpty {
            return AVURLAsset.isPlayableExtendedMIMEType(mediaType)
        }
        let ext = (href as NSString).pathExtension
        guard !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType else {
            return false
        }
        return AVURLAsset.isPlayableExtendedMIMEType(mime)
    }

    /// Whether every file of an inspected book's narration is in the archive
    /// and playable here. False for a book with no narration at all.
    public static func canNarrate(_ inspection: EPUBInspection) -> Bool {
        inspection.hasCompleteNarration
            && inspection.audioFiles.allSatisfy { isPlayable(mediaType: $0.mediaType, href: $0.href) }
    }
}

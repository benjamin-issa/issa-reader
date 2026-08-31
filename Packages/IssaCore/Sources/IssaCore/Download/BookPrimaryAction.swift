import Foundation

/// The one control a book screen offers, and what it currently means.
///
/// The screen used to show Resume and Download as two permanent controls, so it
/// offered to resume a book it did not have while hiding the thing that would
/// fetch it. One control that follows the state answers both.
///
/// This lives here rather than in the view because the view layer has no tests
/// at all — every decision below is one that can go quietly wrong, and putting
/// it in a pure value type is the only way any of it gets checked.
public struct BookPrimaryAction: Equatable, Sendable {
    /// The edition the control acts on: the aligned readaloud when the server
    /// has one, otherwise the plain ebook.
    public let format: BookContentService.Format
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        /// Not on the device. `bytes` is nil when the server did not say.
        case download(bytes: Int?)
        /// Asked for, nothing arriving yet.
        case waiting
        case downloading(fraction: Double, bytesWritten: Int64, isDeterminate: Bool)
        case pausedDownload(fraction: Double)
        /// On the device, never opened.
        case read
        /// On the device, with somewhere to return to.
        case resume(progress: Double)
        case retry(reason: String)
    }

    /// What the control should do, so the view's tap handler carries no logic.
    public enum Intent: Equatable, Sendable {
        case openReader
        case startDownload
        case pauseDownload
        case resumeDownload
    }

    /// Resolves the control for a book, or nil when there is nothing to read.
    ///
    /// Nil is the gate: an audiobook-only book, or one whose every readable
    /// edition the server has lost, gets no primary control rather than one
    /// that leads nowhere.
    public static func resolve(
        book: Book,
        state: DownloadManager.State?,
        isDownloaded: Bool,
    ) -> BookPrimaryAction? {
        guard let format = BookContentService.preferredReadingFormat(for: book) else { return nil }
        return BookPrimaryAction(
            format: format,
            kind: kind(book: book, format: format, state: state, isDownloaded: isDownloaded))
    }

    /// Order matters here more than anything else in this type.
    private static func kind(
        book: Book,
        format: BookContentService.Format,
        state: DownloadManager.State?,
        isDownloaded: Bool,
    ) -> Kind {
        switch state {
        case .queued:
            // Not "0%": a fraction of zero is also what a stalled transfer
            // looks like, and the two should not read the same.
            return .waiting
        case let .downloading(fraction, written, total):
            // A transfer in flight is the more urgent truth even when an older
            // copy is already on disk.
            return .downloading(fraction: fraction, bytesWritten: written, isDeterminate: total > 0)
        case let .paused(fraction):
            return .pausedDownload(fraction: fraction)
        default:
            break
        }

        // Deliberately above `.failed`. A non-2xx response never touches the
        // destination file, so a book that downloaded cleanly and later failed a
        // re-download has both a good file and a failed state — and offering
        // "Retry" over a readable book would be wrong.
        if isDownloaded {
            if let progress = book.progress, progress > 0 { return .resume(progress: progress) }
            return .read
        }
        if case let .failed(reason) = state { return .retry(reason: reason) }
        // `.finished` with the file since deleted lands here and reads
        // "Download", which is what it is.
        return .download(bytes: size(of: book, format: format))
    }

    private static func size(of book: Book, format: BookContentService.Format) -> Int? {
        switch format {
        case .ebook: book.ebook?.fileSize
        case .audiobook: book.audiobook?.fileSize
        case .readaloud: book.readaloud?.fileSize
        }
    }

    // MARK: - Presentation

    /// The button's label.
    ///
    /// `compact` drops the trailing size or percentage. At an accessibility
    /// text size "Download · 312 MB" is wider than the screen, and shrinking a
    /// primary action's type is not an honest way to fit it.
    public func title(compact: Bool = false) -> String {
        switch kind {
        case let .download(bytes):
            guard let bytes, !compact else { return "Download" }
            return "Download · \(Self.sizeText(bytes))"
        case .waiting:
            return "Waiting…"
        case let .downloading(fraction, written, isDeterminate):
            if !isDeterminate { return compact ? "Downloading" : "Downloading · \(Self.sizeText(Int(written)))" }
            return "\(Int(fraction * 100))%"
        case let .pausedDownload(fraction):
            // Never "Resume": that is already the reading action in this very
            // button, and the two would be indistinguishable.
            return compact ? "Paused" : "Paused · \(Int(fraction * 100))%"
        case .read:
            return "Read"
        case let .resume(progress):
            let percent = ReadingProgress.percent(progress)
            guard percent >= 1, !compact else { return "Resume" }
            return "Resume · \(percent)%"
        case .retry:
            return "Retry"
        }
    }

    /// The line beneath the button. Only a failure has one — and until now the
    /// reason existed only in an accessibility label, never on screen.
    public var detail: String? {
        if case let .retry(reason) = kind { return reason }
        return nil
    }

    public var fraction: Double? {
        switch kind {
        case let .downloading(fraction, _, _): fraction
        case let .pausedDownload(fraction): fraction
        default: nil
        }
    }

    public var isDeterminate: Bool {
        switch kind {
        case let .downloading(_, _, isDeterminate): isDeterminate
        case .waiting: false
        default: true
        }
    }

    public var intent: Intent {
        switch kind {
        case .read, .resume: .openReader
        case .download, .retry: .startDownload
        case .waiting, .downloading: .pauseDownload
        case .pausedDownload: .resumeDownload
        }
    }

    public var accessibilityLabel: String {
        guard let detail else { return title() }
        return "\(title()). \(detail)"
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// What an edition row says about itself, now that it carries no buttons.
///
/// Shared with the downloads screen so the "size unknown" rule is written once.
public enum DownloadStatusText {
    public static func short(_ state: DownloadManager.State?, isDownloaded: Bool) -> String {
        switch state {
        case .queued: return "Waiting"
        case let .downloading(fraction, written, total):
            return total > 0
                ? "\(Int(fraction * 100))%"
                : BookPrimaryAction.sizeText(Int(written))
        case let .paused(fraction): return "Paused · \(Int(fraction * 100))%"
        case .failed: return "Failed"
        case .finished: return "Downloaded"
        case nil: return isDownloaded ? "Downloaded" : "Not downloaded"
        }
    }
}

import Foundation
import IssaCore
#if os(iOS)
import UIKit
#endif

/// One file the reader chose, on its way into the local library.
///
/// A row of its own from the moment the picker closes, in the order chosen;
/// files are added one at a time. Leaving the screen does not stop them.
public struct LocalImport: Identifiable, Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Queued behind another file.
        case waiting
        /// iCloud Drive or another provider is still fetching it. iCloud gives
        /// no percentage, so neither does this.
        case downloading
        /// Being copied into the app, 0...1.
        case copying(Double)
        /// Being checked: fingerprint, container, lock, chapters, narration.
        case checking
        /// Added, as this book. Held briefly before the row goes.
        case added(bookUUID: String)
        /// Could not be added, and why. Stays until dismissed.
        case failed(LocalImportError)
    }

    public let id: UUID
    /// What the picker handed over: a security-scoped URL on iOS and the Mac.
    public let source: URL
    /// The name the reader knows the file by.
    public let fileName: String
    /// Whose missing file this is meant to put back, for "Add Again…".
    public let reattaching: String?
    public var stage: Stage

    public init(source: URL, reattaching: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.source = source
        fileName = source.lastPathComponent
        self.reattaching = reattaching
        stage = .waiting
    }

    /// Still to finish, and so cancellable.
    public var isUnfinished: Bool {
        switch stage {
        case .waiting, .downloading, .copying, .checking: true
        case .added, .failed: false
        }
    }

    /// What the row says while it works: the copy deck's status line.
    public var statusText: String? {
        switch stage {
        case .waiting: "Waiting"
        case .downloading: "Downloading from iCloud Drive…"
        case let .copying(fraction): "Copying · \(Int((fraction * 100).rounded(.down)))%"
        case .checking: "Checking the book…"
        case .added: "Added"
        case .failed: nil
        }
    }
}

/// Why a file could not be added, with the copy deck's words for it.
///
/// Every problem has one shape: what happened (`title`), which file (the row
/// shows it), why and what to do (`reason`), then at most one action beside
/// Dismiss. Try Again re-runs the same file; Choose Again reopens the picker.
public enum LocalImportError: Error, Equatable, Sendable {
    /// Not an EPUB. `kind` names what it is instead, when that is known: "a PDF".
    case notAnEPUB(kind: String?)
    /// A folder was chosen instead of the .epub — Apple Books' unzipped books
    /// are folders that call themselves .epub.
    case folder
    /// Parts of the file are missing or unreadable.
    case damaged
    /// Locked by a shop's DRM.
    case drmProtected
    /// Larger than the 4 GB limit.
    case tooLarge(bytes: Int64)
    /// Not enough room for the copy and the narration it will extract.
    case notEnoughSpace(needed: Int64, free: Int64)
    /// The provider could not deliver the file: offline, usually.
    case notDownloaded
    /// Security-scoped access was refused.
    case accessDenied
    /// The copy itself failed; nothing was added.
    case copyFailed
    /// "Add Again…" was given a different book than the one whose file is
    /// missing.
    case notTheSameBook(expectedFileName: String)

    public enum Action: Equatable, Sendable {
        case tryAgain
        case chooseAgain
    }

    @MainActor public var title: String {
        switch self {
        case .notAnEPUB: "Not an EPUB"
        case .folder: "This is a folder"
        case .damaged: "This book is damaged"
        case .drmProtected: "This book is copy-protected"
        case .tooLarge: "Too large to add"
        case .notEnoughSpace: "Not enough space on this \(LocalDevice.noun)"
        case .notDownloaded: "Couldn’t download from iCloud Drive"
        case .accessDenied: "Issa Reader wasn’t given access"
        case .copyFailed: "Couldn’t copy this book"
        case .notTheSameBook: "This isn’t the same book"
        }
    }

    @MainActor public var reason: String {
        switch self {
        case let .notAnEPUB(kind):
            (kind.map { "This is \($0)." } ?? "This file isn’t an EPUB.")
                + " Issa Reader can open EPUB books only."
        case .folder:
            "Choose the .epub file itself rather than the folder it’s in."
        case .damaged:
            "Parts of the file are missing or unreadable. A fresh copy from where you got it should open."
        case .drmProtected:
            "It has DRM, a lock some shops add so a book opens only in their own app. Books from Kindle, Kobo, Apple Books or Adobe Digital Editions usually have it, and won’t open here."
        case let .tooLarge(bytes):
            "This book is \(ByteCountText.text(bytes)). Books up to 4 GB can be added."
        case let .notEnoughSpace(needed, free):
            "This book needs \(ByteCountText.text(needed)) and \(ByteCountText.text(free)) is free. Free up some space, then try again."
        case .notDownloaded:
            "This \(LocalDevice.noun) seems to be offline. Connect to the internet, then try again."
        case .accessDenied:
            "The file couldn’t be opened where it’s stored. Choose it again to give access."
        case .copyFailed:
            "Something went wrong while copying, so nothing was added."
        case let .notTheSameBook(expected):
            "This file is a different book. Choose \(expected) again to keep reading."
        }
    }

    /// The one action beside Dismiss, or nil when nothing the reader does
    /// here will help.
    public var action: Action? {
        switch self {
        case .notAnEPUB, .folder, .accessDenied, .notTheSameBook: .chooseAgain
        case .notEnoughSpace, .notDownloaded, .copyFailed: .tryAgain
        case .damaged, .drmProtected, .tooLarge: nil
        }
    }

    /// What an `action` button says.
    public static func label(for action: Action) -> String {
        switch action {
        case .tryAgain: "Try Again"
        case .chooseAgain: "Choose Again"
        }
    }

    /// What a file's extension says it is, for "This is a PDF."
    static func kind(ofExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "pdf": "a PDF"
        case "mobi", "azw", "azw3", "kfx": "a Kindle book"
        case "doc", "docx": "a Word document"
        case "txt": "a text file"
        case "rtf": "a rich-text document"
        case "zip": "a ZIP archive"
        case "cbz", "cbr": "a comic archive"
        case "m4b", "mp3", "m4a": "an audiobook file"
        default: nil
        }
    }
}

/// The copy deck's words for the list's notices and toasts, in one place.
@MainActor
public enum LocalBooksCopy {
    /// "Files" on iPhone and iPad, "Finder" on the Mac: where the original stays.
    public static var originalsPlace: String {
        #if os(macOS)
        "Finder"
        #else
        "Files"
        #endif
    }

    /// The list's title: "On this iPhone", "On this iPad", "Books on This Mac".
    public static var listTitle: String {
        #if os(macOS)
        "Books on This Mac"
        #else
        "On this \(LocalDevice.noun)"
        #endif
    }

    public static var privacyLine: String {
        "Kept only on this \(LocalDevice.noun). Nothing is sent to a server."
    }

    public static func notice(_ notice: LocalNotice) -> String {
        switch notice {
        case .narrationUnplayable:
            "Added without narration. Its audio is in a format this \(LocalDevice.noun) can’t play, so the book reads as text only."
        case .fixedLayout:
            "This book was designed as fixed pages. It’s shown as flowing text, so pictures and layout may look different."
        }
    }

    public static var restoredNotice: String {
        "Add it again from \(originalsPlace) to keep reading — your place and highlights are kept."
    }

    public static var notOnDevice: String { "Not on \(LocalDevice.noun)" }

    public static func alreadyHere(_ title: String) -> String {
        "\(title) is already on this \(LocalDevice.noun)."
    }

    /// The undo toast: "Removed Dracula. Original kept in Files."
    public static func removed(_ titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return "Removed \(title). Original kept in \(originalsPlace)."
        }
        return "Removed \(titles.count) books. Originals kept in \(originalsPlace)."
    }

    /// What VoiceOver says for the toast.
    public static func removedSpoken(_ titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return "Removed \(title). The original in \(originalsPlace) is kept. Undo available."
        }
        return "Removed \(titles.count) books. The originals in \(originalsPlace) are kept. Undo available."
    }

    /// "Narrated · 7 h 4 min", or "Narrated" alone for a length no clock can
    /// show.
    ///
    /// Through `wholeSeconds`, as `DurationText` is: the length is the book's
    /// own claim, and 1e21 seconds is finite, passes every check the parser
    /// makes, and trapped in `Int(_:)` on every draw of the row and Book info.
    public static func narrated(seconds: Double) -> String {
        guard seconds > 0, let total = seconds.wholeSeconds else { return "Narrated" }
        let minutes = Int((Double(total) / 60).rounded())
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(minutes, 1)) min"
        return "Narrated · \(length)"
    }
}

/// "iPhone", "iPad" or "Mac": the machine whose list this is, named as the
/// Ask copy names it (`AskDevice`, which is not built for the television).
@MainActor
enum LocalDevice {
    static var noun: String {
        #if os(macOS)
        "Mac"
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Apple TV"
        #endif
    }

    /// The device's own glyph, for the Settings row.
    static var symbol: String {
        switch noun {
        case "iPad": "ipad"
        case "Mac": "laptopcomputer"
        default: "iphone"
        }
    }
}

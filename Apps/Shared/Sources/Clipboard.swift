import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copying text, spelled once rather than at every call site.
///
/// tvOS has no pasteboard at all, which is the reason this is not simply
/// `UIPasteboard.general` inline.
enum Clipboard {
    /// How long a sensitive value stays on the pasteboard.
    ///
    /// For what is short-lived by nature: a device sign-in code, which is a live
    /// credential, and the diagnostics log, which carries the server's hostname
    /// and the title of every book opened in the last six hours. Neither needs
    /// to outlive the paste, and each passes this explicitly.
    static let sensitiveLifetime: TimeInterval = 2 * 60

    #if os(iOS) || os(visionOS)
    /// What the pasteboard is told about a copy: kept on this device, and
    /// expiring only when a lifetime was asked for.
    static func pasteboardOptions(lifetime: TimeInterval?, now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let lifetime { options[.expirationDate] = now.addingTimeInterval(lifetime) }
        return options
    }
    #endif

    /// - Parameter lifetime: how long the value stays, `nil` for one the reader
    ///   means to keep, which is the default. A passage from a book or an answer
    ///   about one is theirs — copied to paste into their own notes, perhaps an
    ///   hour later — and expiring it would make Copy a button that sometimes
    ///   works. Only a secret asks for `sensitiveLifetime`.
    static func copy(_ text: String, lifetime: TimeInterval? = nil) {
        #if os(iOS) || os(visionOS)
        // `setItems(_:options:)`, not `.string =`. The plain setter puts the
        // value on the *general* pasteboard with no expiry and no local-only
        // flag, so with Handoff on it is pushed to the reader's other devices
        // and is readable by any app they foreground until the next copy.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]], options: pasteboardOptions(lifetime: lifetime))
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // AppKit has no expiry, but it does have the marker the pasteboard
        // managers respect: `org.nspasteboard.ConcealedType` asks history tools
        // not to record the value at all. Only for the values that expire —
        // concealing something the reader copied on purpose would keep it out
        // of their own clipboard history, which is where they went looking.
        if lifetime != nil {
            NSPasteboard.general.setString(
                text, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        #endif
    }
}

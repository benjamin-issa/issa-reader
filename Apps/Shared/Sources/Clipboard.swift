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
    /// How long a copied value stays on the pasteboard by default.
    ///
    /// Most of what this copies is sensitive and short-lived by nature: a
    /// device sign-in code, which is a live credential, and the diagnostics
    /// log, which carries the server's hostname and the title of every book
    /// opened in the last six hours. Neither needs to outlive the paste.
    static let defaultLifetime: TimeInterval = 2 * 60

    /// - Parameter lifetime: `nil` for a value the reader means to keep. An
    ///   answer about a book is theirs — copied to paste into their own notes,
    ///   perhaps an hour later — and expiring it would make Copy a button that
    ///   sometimes works. Everything else keeps the short default.
    static func copy(_ text: String, lifetime: TimeInterval? = defaultLifetime) {
        #if os(iOS) || os(visionOS)
        // `setItems(_:options:)`, not `.string =`. The plain setter puts the
        // value on the *general* pasteboard with no expiry and no local-only
        // flag, so with Handoff on it is pushed to the reader's other devices
        // and is readable by any app they foreground until the next copy.
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let lifetime { options[.expirationDate] = Date().addingTimeInterval(lifetime) }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
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

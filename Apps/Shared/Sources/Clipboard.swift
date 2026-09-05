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
    /// How long a copied value stays on the pasteboard.
    ///
    /// Both things this copies are sensitive and short-lived by nature: a
    /// device sign-in code, which is a live credential, and the diagnostics
    /// log, which carries the server's hostname and the title of every book
    /// opened in the last six hours. Neither needs to outlive the paste.
    private static let lifetime: TimeInterval = 2 * 60

    static func copy(_ text: String) {
        #if os(iOS) || os(visionOS)
        // `setItems(_:options:)`, not `.string =`. The plain setter puts the
        // value on the *general* pasteboard with no expiry and no local-only
        // flag, so with Handoff on it is pushed to the reader's other devices
        // and is readable by any app they foreground until the next copy.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime),
            ])
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        // AppKit has no expiry, but it does have the marker the pasteboard
        // managers respect: `org.nspasteboard.ConcealedType` asks history tools
        // not to record the value at all.
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setString(
            text, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        #endif
    }
}

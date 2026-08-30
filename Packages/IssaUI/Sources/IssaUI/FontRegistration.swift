import CoreText
import Foundation

/// Registers the bundled reading faces.
///
/// Fonts shipped in a Swift package resource bundle are not picked up the way
/// an app's `UIAppFonts` entry would be, so they must be handed to CoreText
/// explicitly. Doing it here keeps the app targets from each needing their own
/// copy of the files and their own plist entry.
///
/// Newsreader and Public Sans are both under the SIL Open Font License 1.1;
/// see Resources/Fonts/OFL.txt.
public enum IssaFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    /// Idempotent, and safe to call from anywhere. Call once at launch, before
    /// the first view renders, or type falls back to the system face.
    public static func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true

        let names = ["Newsreader", "Newsreader-Italic", "PublicSans", "PublicSans-Italic"]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            // .process scope: the faces are visible to this process only, which
            // is what a bundled app font should be.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is not a failure worth surfacing; anything
                // else means type will silently fall back, so it is logged.
                if let cfError = error?.takeRetainedValue(),
                   CFErrorGetCode(cfError) != CTFontManagerError.alreadyRegistered.rawValue {
                    print("[IssaUI] font registration failed for \(name): \(cfError)")
                }
            }
        }
    }
}

import Foundation

/// 64-bit FNV-1a.
///
/// Not a security property — it is here to be *stable* — so a non-cryptographic
/// hash with no dependency is the right size of tool.
///
/// One spelling, because there are two callers who must never disagree with
/// themselves across releases. `String.safePathComponent` names files that
/// already exist on devices, and the Ask engine's sampler seed decides whether
/// asking the same question twice gives the same answer. A second copy of this
/// loop is a second answer to both.
public enum FNV1a {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x100_0000_01b3

    public static func hash(_ text: String) -> UInt64 {
        var hash = offsetBasis
        for byte in Data(text.utf8) {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return hash
    }

    /// The hash in hexadecimal, as `String(_:radix:)` writes it.
    ///
    /// Deliberately *not* zero-padded. `String(_:radix:)` drops a leading zero,
    /// so `".."` is fifteen digits and not sixteen — and that is the spelling
    /// already on devices. Padding it would rename every `unsafe-` file the app
    /// has ever written.
    public static func hexadecimal(_ text: String) -> String {
        String(hash(text), radix: 16)
    }
}

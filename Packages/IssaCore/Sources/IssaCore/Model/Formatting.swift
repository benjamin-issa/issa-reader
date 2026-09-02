import Foundation

/// A length of audio as a reader sees it: "2h 18m", "45m".
///
/// One copy. There were three — the detail screen's, the widget snapshot's
/// and CarPlay's — and only CarPlay's guarded against a non-finite value, so a
/// server-supplied duration of NaN trapped in `Int(seconds.rounded())` on the
/// book screen while the car showed "0m".
public enum DurationText {
    public static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// A byte count as a reader sees it: "146.2 MB".
public enum ByteCountText {
    public static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

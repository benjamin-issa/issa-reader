import Foundation

/// A real audio file with nothing in it, for suites that drive a real
/// `AudioPlayer` and need its loads to succeed, but are about the clock, not
/// the sound. `/dev/null` is not one: AVFoundation cannot open it, and a load
/// of it reports `.failed` — the suites that used it only worked while a file
/// that would not open was reported as loaded.
///
/// Thirty minutes, because the offsets these suites seek to run up to a
/// track's full length — 1,599 seconds into a 1,600-second track — and a seek
/// past the end of the file would end it: AVFoundation posts the end of an
/// item that a seek lands on or past, and the coordinators move on from that.
/// Mono, eight-bit, 2 kHz: 3.6 MB, written once per machine and reused.
enum SilentAudio {
    static let duration: TimeInterval = 1_800
    static let sampleRate = 2_000

    static let url: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-playback-tests-silence-v1.wav")
        let bytes = wav()
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        if existing != bytes.count {
            // Atomic, because another test process may be reading it.
            try? bytes.write(to: url, options: .atomic)
        }
        return url
    }()

    /// A canonical 44-byte RIFF header and unsigned eight-bit silence.
    private static func wav() -> Data {
        let samples = Int(duration) * sampleRate
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16) // chunk size
        le16(1) // PCM
        le16(1) // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate)) // bytes per second
        le16(1) // block align
        le16(8) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples))
        data.append(Data(repeating: 0x80, count: samples))
        return data
    }
}

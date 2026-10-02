import Foundation

/// A real audio file with nothing in it, for suites that drive a real player
/// and need its loads to succeed, but are about the clock, not the sound.
///
/// The app tests' own copy of `IssaPlaybackTests`' helper of the same name —
/// a package test target is not something this bundle can import. `/dev/null`
/// is not one: AVFoundation cannot open it, and a load of it reports a
/// failure, so a suite that used it was exercising a load that failed while
/// saying it tested something else.
enum SilentAudio {
    static let sampleRate = 2_000

    /// Thirty minutes of silence on disk, written once per machine and reused:
    /// long enough that no offset these suites seek to runs past the end of
    /// the file, which AVFoundation would answer by ending the item.
    static let url: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-shared-tests-silence-v1.wav")
        let bytes = wav(seconds: 1_800)
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        if existing != bytes.count {
            // Atomic, because another test process may be reading it.
            try? bytes.write(to: url, options: .atomic)
        }
        return url
    }()

    /// A canonical 44-byte RIFF header and unsigned eight-bit mono silence.
    static func wav(seconds: Int) -> Data {
        let samples = seconds * sampleRate
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

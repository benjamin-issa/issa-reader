import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// What an audio file is, when its name does not say.
///
/// A download is saved as `<id>-audiobook.epub` whatever it holds, because the
/// downloads directory names every edition the same way. AVFoundation judges an
/// asset by its extension first and does not open an MP3 or an M4B called
/// `.epub`, so such a file is played with the type it really has, read from the
/// first bytes, handed to the asset as an override.
public enum AudioFileKind {
    /// The MIME type to tell AVFoundation the file at `url` is, or nil when its
    /// extension already names audio (it needs no help) or the first bytes are
    /// not one this knows.
    public static func overrideMIMEType(forFileAt url: URL) -> String? {
        let ext = url.pathExtension
        if !ext.isEmpty, UTType(filenameExtension: ext)?.conforms(to: .audio) == true { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16) else { return nil }
        return mimeType(forHeader: header)
    }

    /// The type the first bytes of a file say it is.
    public static func mimeType(forHeader header: Data) -> String? {
        let bytes = [UInt8](header)
        func starts(_ text: String, at offset: Int = 0) -> Bool {
            let wanted = Array(text.utf8)
            return bytes.count >= offset + wanted.count
                && Array(bytes[offset ..< offset + wanted.count]) == wanted
        }
        if starts("ID3") { return "audio/mpeg" }
        if starts("ftyp", at: 4) { return "audio/mp4" }
        if starts("RIFF"), starts("WAVE", at: 8) { return "audio/wav" }
        if starts("fLaC") { return "audio/flac" }
        if starts("OggS") { return "audio/ogg" }
        if starts("ADIF") { return "audio/aac" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            // A frame sync. The layer bits tell ADTS AAC (00) from MPEG audio.
            return bytes[1] & 0x06 == 0 ? "audio/aac" : "audio/mpeg"
        }
        return nil
    }

    /// `AVURLAsset` options for a file on disk: the override, when it needs one.
    static func assetOptions(forFileAt url: URL) -> [String: Any]? {
        overrideMIMEType(forFileAt: url).map { [AVURLAssetOverrideMIMETypeKey: $0] }
    }
}

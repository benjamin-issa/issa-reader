import AVFoundation
import Foundation
import Testing

@testable import IssaPlayback

/// The arithmetic, on its own, with no audio machinery in the way.
@Suite("The gain kernel")
struct GainKernelTests {
    @Test("above unity a sample near full scale is clipped, not wrapped")
    func clipsRatherThanWrapping() {
        var samples: [Float] = [0.9, -0.9, 0.5, -0.5, 0]
        samples.withUnsafeMutableBufferPointer { GainTap.apply(gain: 1.5, to: $0) }
        #expect(samples[0] == 1.0, "0.9 × 1.5 is 1.35, which has to land on the ceiling")
        #expect(samples[1] == -1.0)
        #expect(abs(samples[2] - 0.75) < 1e-6)
        #expect(abs(samples[3] + 0.75) < 1e-6)
        #expect(samples[4] == 0)
    }

    @Test("below unity every sample scales and nothing meets the ceiling")
    func scalesDown() {
        var samples: [Float] = [1.0, -1.0, 0.5, 0]
        samples.withUnsafeMutableBufferPointer { GainTap.apply(gain: 0.5, to: $0) }
        #expect(abs(samples[0] - 0.5) < 1e-6)
        #expect(abs(samples[1] + 0.5) < 1e-6)
        #expect(abs(samples[2] - 0.25) < 1e-6)
        #expect(samples[3] == 0)
    }

    /// The common case by a wide margin — most books are never trimmed — and it
    /// runs on the real-time thread, so it has to cost nothing. Including the
    /// clip: an out-of-range sample the recording already contained is left
    /// exactly as it was, because at unity this code is not in the path.
    @Test("at unity not a byte moves")
    func unityIsFree() {
        let original: [Float] = [0.9, -0.9, 0.123_456, 2.0, -2.0]
        var samples = original
        samples.withUnsafeMutableBufferPointer { GainTap.apply(gain: 1, to: $0) }
        #expect(samples == original)
    }

    @Test("an empty buffer, and a null one, are both no-ops")
    func emptyBuffer() {
        var samples: [Float] = []
        samples.withUnsafeMutableBufferPointer { GainTap.apply(gain: 1.5, to: $0) }
        #expect(samples.isEmpty)
        // What an `AudioBufferList` can genuinely hold: a buffer with no data
        // pointer at all.
        GainTap.apply(gain: 1.5, to: UnsafeMutableBufferPointer<Float>(start: nil, count: 0))
    }
}

// MARK: - End to end

/// The tap wired into a real decode, because the kernel being right says
/// nothing about whether the mix was ever consulted. A mix that is silently
/// ignored looks exactly like a mix that is applied and happens to do nothing.
@Suite("A book decoded through the gain tap")
struct GainTapDecodeTests {
    @Test("a recording read through the mix comes out louder, and clipped at the top")
    func louder() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let tap = GainTap()
        tap.gain.store(1.5, ordering: .relaxed)
        let peak = try await Fixture.peak(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0,
                "the mix was never consulted, so the peak below means nothing")
        #expect(abs(peak - 0.75) < 0.02, "0.5 × 1.5 should be 0.75, got \(peak)")
    }

    @Test("and quieter the other way")
    func quieter() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let tap = GainTap()
        tap.gain.store(0.5, ordering: .relaxed)
        let peak = try await Fixture.peak(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(abs(peak - 0.25) < 0.02, "0.5 × 0.5 should be 0.25, got \(peak)")
    }

    /// A book already mastered close to full scale is the one that most tempts
    /// a listener to turn it up, and it is the one where an unclipped multiply
    /// would wrap into a buzz.
    @Test("a recording already near full scale never leaves the range")
    func loudRecordingStaysInRange() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.9, in: directory)

        let tap = GainTap()
        tap.gain.store(1.5, ordering: .relaxed)
        let peak = try await Fixture.peak(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(peak <= 1.0, "0.9 × 1.5 is 1.35 and must be limited, got \(peak)")
        #expect(peak > 0.99, "and it should be reaching the ceiling, not sitting under it")
    }

    @Test("no audio tracks, no mix — the caller has to be able to tell")
    func noTracks() {
        #expect(GainTap().makeAudioMix(for: []) == nil)
    }
}

// MARK: - AudioPlayer

/// How the two levels combine, and which of them carries the trim.
@Suite("A player carrying a book's level")
@MainActor
struct AudioPlayerGainTests {
    @Test("a gain outside the range is clamped on the way in")
    func clampsGain() {
        let player = AudioPlayer()
        player.gain = 2
        #expect(player.gain == 1.5)
        player.gain = 0.1
        #expect(player.gain == 0.5)
        player.gain = .nan
        #expect(player.gain == 1)
    }

    @Test("a file with real tracks gets the tap, and the fade keeps the player's volume")
    func localFileCarriesTheTap() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let player = AudioPlayer()
        #expect(await player.load(url: url, href: "sine.wav"))
        #expect(player.tapCarriesGain, "a local float WAV has a track to attach to")

        // The gain is in the samples, so the player's own volume is left to the
        // sleep timer alone — at 1 until it fades.
        player.gain = 1.5
        #expect(player.underlyingVolume == 1)
        player.volume = 0.5
        #expect(player.underlyingVolume == 0.5, "the fade must not be multiplied by the trim twice")
    }

    /// The HLS case, and the reason `applyPlayerVolume` is not simply
    /// `player.volume = volume`: with no track there is no tap, and the only
    /// level left is the player's own. It can go down and it cannot go up.
    @Test("with no loadable tracks the quieter half still arrives")
    func fallbackWithoutTracks() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-not-audio-\(UUID().uuidString).wav")
        let player = AudioPlayer()
        _ = await player.load(url: missing, href: "missing.wav")
        #expect(player.tapCarriesGain == false)

        player.gain = 0.5
        #expect(player.underlyingVolume == 0.5, "quieter is expressible without a tap")
        player.gain = 1.5
        #expect(player.underlyingVolume == 1, "louder is not, and must not be faked by clipping")
    }
}

// MARK: - Fixtures

private enum Fixture {
    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-gain-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One second of 440 Hz at a known amplitude, as 32-bit float mono.
    ///
    /// Synthesised rather than taken from the book fixture because the assertion
    /// is about a peak: a known sine has one, and speech does not.
    static func sine(amplitude: Float, in directory: URL) throws -> URL {
        let sampleRate = 44_100.0
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false,
        ))
        let url = directory.appending(path: "sine-\(Int(amplitude * 100)).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData)[0]
        for frame in 0 ..< Int(frames) {
            channel[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// The loudest sample in the file, decoded through the tap's mix.
    static func peak(of url: URL, through tap: GainTap) async throws -> Float {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let mix = try #require(tap.makeAudioMix(for: tracks))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        reader.add(output)
        reader.startReading()

        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            var list = AudioBufferList()
            var block: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample,
                bufferListSizeNeededOut: nil,
                bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &block,
            )
            guard status == noErr else { continue }
            for buffer in UnsafeMutableAudioBufferListPointer(&list) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self), count: count)
                for value in floats { peak = max(peak, abs(value)) }
            }
        }
        return peak
    }
}

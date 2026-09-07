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

// MARK: - Two taps, one owner

/// A chapter change, staged.
///
/// One `GainTap` lives for the life of an `AudioPlayer` while `makeAudioMix`
/// builds a **new** `MTAudioProcessingTap` per `load`, and on a change of
/// chapter `player.removeAllItems()` hands the old item's teardown to
/// AVFoundation's own queues. So the two taps' lifecycles interleave, and while
/// the format flag lived on the shared owner, `tapUnprepare(tap1)` arriving
/// after `tapPrepare(tap2)` cleared the *new* tap's flag: `tapProcess` bailed
/// at the guard, the chapter played as recorded, and `tapCarriesGain` stayed
/// true so `applyPlayerVolume` did not compensate through `player.volume`
/// either. A book set to +50% played one chapter flat with nothing to show why.
///
/// Driven through the real callbacks rather than a stand-in. No end-to-end
/// decode can stage this: starting a read prepares the tap again, which sets
/// the flag back and hides it.
@Suite("Two taps made by one gain tap")
struct GainTapPerTapStateTests {
    /// The format the kernel is written for, and the one `tapPrepare` accepts.
    static var float32: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0,
        )
    }

    static func taps(from owner: GainTap, tracks: [AVAssetTrack]) throws
        -> (MTAudioProcessingTap, MTAudioProcessingTap) {
        func tap(_ mix: AVAudioMix?) throws -> MTAudioProcessingTap {
            let parameters = try #require(mix?.inputParameters.first)
            return try #require(parameters.audioTapProcessor)
        }
        return (
            try tap(owner.makeAudioMix(for: tracks)),
            try tap(owner.makeAudioMix(for: tracks))
        )
    }

    @Test("tearing the first one down leaves the second one scaling")
    func unprepareDoesNotClearTheOtherTap() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)

        let owner = GainTap()
        let (first, second) = try Self.taps(from: owner, tracks: tracks)
        #expect(first !== second, "each load builds its own tap")

        var format = Self.float32
        withUnsafePointer(to: &format) { tapPrepare(tap: first, maxFrames: 1024, processingFormat: $0) }
        withUnsafePointer(to: &format) { tapPrepare(tap: second, maxFrames: 1024, processingFormat: $0) }
        #expect(Self.carriesGain(first))
        #expect(Self.carriesGain(second))

        // The old chapter's tap is torn down after the new one is ready.
        tapUnprepare(tap: first)
        let oldTap = Self.carriesGain(first)
        let newTap = Self.carriesGain(second)
        #expect(oldTap == false)
        #expect(newTap, "the new chapter's tap would pass every sample through untouched")

        // And the setting the two are meant to share is still shared.
        owner.gain.store(1.5, ordering: .relaxed)
        #expect(state(of: first).owner === owner)
        #expect(state(of: second).owner === owner)
        #expect(state(of: second).owner.gain.load(ordering: .relaxed) == 1.5)
    }

    /// Reads the format flag out of one tap's own storage. Hoisted out of the
    /// `#expect`s because `Atomic` is non-copyable and the macro cannot take an
    /// expression apart around one.
    static func carriesGain(_ tap: MTAudioProcessingTap) -> Bool {
        state(of: tap).isFloat32.load(ordering: .relaxed)
    }

    /// The flag is per tap; the owner is not, and the manual retain that keeps
    /// it alive is now taken once per tap and given back once per tap. Three
    /// mixes is enough to catch it in either direction: a `TapState` that
    /// failed to consume `makeAudioMix`'s `+1` leaves the object alive after
    /// every tap has gone, and one that consumed it twice would have released
    /// the object out from under the taps still using it long before here.
    @Test("every tap keeps the owner alive, and hands it back exactly once")
    func retainBalance() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)

        weak var weakOwner: GainTap?
        var mixes: [AVAudioMix] = []
        do {
            let owner = GainTap()
            weakOwner = owner
            for _ in 0 ..< 3 {
                mixes.append(try #require(owner.makeAudioMix(for: tracks)))
            }
        }
        #expect(weakOwner != nil, "the taps hold the owner while the mixes are alive")
        autoreleasepool { mixes.removeAll() }
        // AVFoundation finalises a tap on its own schedule, so this waits for
        // it rather than assuming it has already happened.
        for _ in 0 ..< 100 where weakOwner != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weakOwner == nil, "the retains taken per tap were not all given back")
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

    /// The reason `applyPlayerVolume` is not simply `player.volume = volume`:
    /// with no track there is no tap, and the only level left is the player's
    /// own. It can go down and it cannot go up.
    ///
    /// This is the asset that will not load *at all* — the file is not there.
    /// Its doc used to say "the HLS case", which it is not: an unreachable file
    /// fails both loads, and the branch it names is the one below.
    @Test("an asset that will not load leaves the quieter half working")
    func fallbackWhenNothingLoads() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-not-audio-\(UUID().uuidString).wav")
        let player = AudioPlayer()
        _ = await player.load(url: missing, href: "missing.wav")
        #expect(player.tapCarriesGain == false)
        #expect(player.duration == 0, "there is no honest length to report")

        player.gain = 0.5
        #expect(player.underlyingVolume == 0.5, "quieter is expressible without a tap")
        player.gain = 1.5
        #expect(player.underlyingVolume == 1, "louder is not, and must not be faked by clipping")
    }

    /// The no-audio-tracks branch, which is what the test above claimed to
    /// cover and did not: the tracks resolve and hold nothing to hang a tap on,
    /// while the duration resolves perfectly well — and the scrubber, the
    /// "…m left" caption and the end-of-track arithmetic all depend on it.
    ///
    /// The remaining case, tracks that *fail* while the duration succeeds, is
    /// what `load` now catches one at a time rather than as one all-or-nothing
    /// tuple. It needs a live HLS server to produce: no local asset separates
    /// the two — a file corrupt enough to lose its tracks loses its duration
    /// with them, and a valid one keeps both. So the shape of the code is the
    /// guard there, and this is the neighbouring case that can be pinned.
    @Test("an asset with a real duration and no audio keeps its length")
    func durationSurvivesMissingTracks() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixture.silentMovie(in: directory)

        let player = AudioPlayer()
        _ = await player.load(url: url, href: "silent.mp4")
        #expect(player.tapCarriesGain == false, "no audio track to attach a tap to")
        #expect(player.duration > 0.5, "the duration loaded and must not be thrown away, was \(player.duration)")

        player.gain = 0.5
        #expect(player.underlyingVolume == 0.5)
        player.gain = 1.5
        #expect(player.underlyingVolume == 1)
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

    /// One second of video and not a sample of audio.
    ///
    /// The asset a book streamed as HLS looks like from `AudioPlayer.load`'s
    /// point of view — tracks that resolve and hold nothing to attach a gain
    /// tap to — while the duration resolves normally. Synthesised rather than
    /// bundled because the whole point is that it is *valid*: a file that is
    /// merely absent fails both loads and tests the branch above instead.
    static func silentMovie(in directory: URL) async throws -> URL {
        let url = directory.appending(path: "silent.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            ],
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixels)
        let buffer = try #require(pixels)
        for frame in 0 ..< 10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            #expect(adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        await writer.finishWriting()
        #expect(writer.status == .completed, "the fixture did not write: \(String(describing: writer.error))")
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

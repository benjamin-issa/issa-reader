import AVFoundation
import Foundation
import Testing

@testable import IssaPlayback

/// The arithmetic, on its own, with no audio machinery in the way.
@Suite("The gain kernel")
struct GainKernelTests {
    /// Runs the kernel over a copy, with scratch of the given size — the
    /// default being room for the whole block, which is what a prepared tap
    /// hands it.
    static func applied(gain: Float, to input: [Float], scratch size: Int? = nil) -> [Float] {
        var samples = input
        var scratch = [Float](repeating: .nan, count: size ?? max(input.count, 1))
        samples.withUnsafeMutableBufferPointer { block in
            scratch.withUnsafeMutableBufferPointer { room in
                GainTap.apply(gain: gain, to: block, scratch: room)
            }
        }
        return samples
    }

    static let threshold = GainTap.threshold
    static let ceiling = GainTap.ceiling

    @Test("above unity a sample far past the knee lands exactly on the ceiling")
    func clipsRatherThanWrapping() {
        let samples = Self.applied(gain: 1.5, to: [0.9, -0.9, 0.5, -0.5, 0])
        #expect(samples[0] == 1.0, "0.9 × 1.5 is 1.35, past 2 − T, so it is exactly 1")
        #expect(samples[1] == -1.0)
        #expect(samples[2] == 0.75, "0.75 is under the knee and must not be touched at all")
        #expect(samples[3] == -0.75)
        #expect(samples[4] == 0)
    }

    @Test("below unity every sample scales and nothing meets the ceiling")
    func scalesDown() {
        let samples = Self.applied(gain: 0.5, to: [1.0, -1.0, 0.5, 0])
        #expect(samples[0] == 0.5)
        #expect(samples[1] == -0.5)
        #expect(samples[2] == 0.25)
        #expect(samples[3] == 0)
    }

    /// The common case by a wide margin — most books are never trimmed — and it
    /// runs on the real-time thread, so it has to cost nothing. Including the
    /// clip: an out-of-range sample the recording already contained is left
    /// exactly as it was, because at unity this code is not in the path.
    @Test("at unity not a byte moves")
    func unityIsFree() {
        let original: [Float] = [0.9, -0.9, 0.123_456, 2.0, -2.0]
        #expect(Self.applied(gain: 1, to: original) == original)
    }

    /// The promise `tanh` and a cubic both broke, and the reason neither was
    /// chosen. They shape every sample, so they colour a book at gains that
    /// cannot possibly clip: `tanh` costs 0.16 dB and 1.59% THD+N at gain 1.0.
    /// Under unity this kernel multiplies and stops.
    ///
    /// The gains are unity and every rung of the quiet half of the slider,
    /// 0 dB down to −8 dB.
    @Test("at and below unity every sample is exactly the multiply", arguments: [
        Float(1.0), 0.891_251, 0.794_328, 0.707_946, 0.630_957, 0.562_341, 0.501_187,
        0.446_684, 0.398_107,
    ])
    func exactBelowUnity(gain: Float) {
        // Loud samples included, and they are the point: at 0.99 × 0.891 the
        // product is 0.882, well past the knee, and the knee must not see it.
        var input: [Float] = [0, 0.5, -0.5, 0.99, -0.99, 1.0, -1.0, 0.123_456_7]
        for index in 0 ..< 2000 { input.append(-1 + 2 * Float(index) / 1999) }
        let expected = input.map { $0 * gain }
        #expect(Self.applied(gain: gain, to: input) == expected)
    }

    /// The other half of the same promise, and the harder half: at a gain that
    /// *does* engage the knee, a sample under the threshold still comes out of
    /// the multiply untouched — even sitting next to one that is being limited,
    /// which is the case a whole-block early-out would flatter.
    @Test("under the knee the answer is the multiply, bit for bit")
    func transparentBelowTheKnee() {
        let gain: Float = 2.512
        var input: [Float] = []
        // Everything here scales to at most 0.8 × 0.999.
        for index in 0 ..< 4000 {
            input.append(-0.318 + 0.636 * Float(index) / 3999)
        }
        let quiet = Self.applied(gain: gain, to: input)
        #expect(quiet == input.map { $0 * gain })

        // And again with one sample loud enough to force the long path.
        let mixed = Self.applied(gain: gain, to: input + [0.9])
        #expect(Array(mixed.dropLast()) == input.map { $0 * gain },
                "the early-out was doing the work, not the arithmetic")
        #expect(mixed.last == 1.0)
    }

    /// The three pieces of the curve, checked where they join. `f(2 − T)` has to
    /// be exactly 1 or the limiter has a step in it at the loudest moment of the
    /// loudest passage.
    @Test("the curve is odd, monotone, and meets the ceiling exactly")
    func shape() {
        let gain: Float = 2.0
        // Straight onto the join, and either side of it. A hair either side
        // will not do: the curve arrives at the ceiling with a slope of zero,
        // which is the whole point of it, so a step of 1e-4 lands 1.25e-8 under
        // 1 — closer than a `Float` can hold at that magnitude, and the
        // assertion would fail for being right.
        let joins: [Float] = [Self.ceiling / gain, (Self.ceiling - 0.05) / gain,
                              (Self.ceiling + 0.05) / gain]
        let landed = Self.applied(gain: gain, to: joins)
        #expect(landed[0] == 1.0, "f(2 − T) is not exactly 1, got \(landed[0])")
        #expect(landed[1] < 1.0, "the curve is on the ceiling before it reaches it, \(landed[1])")
        #expect(landed[2] == 1.0)

        var rising: [Float] = []
        for index in 0 ... 4000 { rising.append(Float(index) / 4000) }
        let positive = Self.applied(gain: gain, to: rising)
        let negative = Self.applied(gain: gain, to: rising.map { -$0 })
        #expect(zip(positive, negative).allSatisfy { $0 == -$1 }, "f(−x) ≠ −f(x)")
        #expect(zip(positive, positive.dropFirst()).allSatisfy { $0 <= $1 }, "the curve goes back on itself")
        #expect(positive.allSatisfy { $0 <= 1.0 })
        #expect(positive.last == 1.0)
    }

    /// What makes it a knee rather than a corner. A hard clip's slope falls from
    /// 1 to 0 in one sample and that discontinuity is the crackle; here it
    /// arrives at the threshold still at 1 and leaves the ceiling at 0.
    @Test("the curve leaves the knee at the slope it arrived with")
    func unitySlopeAtTheKnee() {
        let gain: Float = 2.0
        let step: Float = 1e-4
        let around = Self.applied(gain: gain, to: [
            (Self.threshold - step) / gain, (Self.threshold + step) / gain,
        ])
        let slope = (around[1] - around[0]) / (2 * step)
        #expect(abs(slope - 1) < 0.01, "the knee has a corner in it, slope \(slope)")
    }

    /// A decoder can hand back anything. The rule is that poison is passed on
    /// rather than turned into full-scale noise: a NaN stays a NaN — which is
    /// what it did before the limiter arrived — and an infinity, which *is*
    /// representable as a level, lands on the ceiling like any other loud
    /// sample.
    @Test("non-finite samples survive the limiter")
    func nonFinite() {
        let poisoned = Self.applied(gain: 2.0, to: [.nan, .infinity, -.infinity, 0.25])
        #expect(poisoned[0].isNaN, "a NaN was read as a level")
        #expect(poisoned[1] == 1.0)
        #expect(poisoned[2] == -1.0)
        #expect(poisoned[3] == 0.5)

        // Alone, so the block's peak is the NaN itself. `vDSP_maxv` hands back
        // NaN, `NaN <= threshold` is false, and the block therefore does *not*
        // take the quiet early-out — which is the ordering this depends on.
        #expect(Self.applied(gain: 2.0, to: [.nan])[0].isNaN)
    }

    /// The test that catches a scratch buffer leaking state across calls, or an
    /// early-out that depends on where the block boundaries happen to fall.
    /// AVFoundation picks the block size and it changes with the route, the
    /// sample rate and whatever else the system is doing.
    @Test("the answer does not depend on how the samples were split up")
    func blockSizeInvariance() {
        var ramp: [Float] = []
        for index in 0 ..< 4096 { ramp.append(-1 + 2 * Float(index) / 4095) }
        let whole = Self.applied(gain: 2.512, to: ramp)

        for size in [1024, 37, 1, 4095, 4096] {
            var chunked = ramp
            var scratch = [Float](repeating: .nan, count: size)
            chunked.withUnsafeMutableBufferPointer { block in
                scratch.withUnsafeMutableBufferPointer { room in
                    var offset = 0
                    while offset < block.count {
                        let frames = min(size, block.count - offset)
                        GainTap.apply(
                            gain: 2.512,
                            to: UnsafeMutableBufferPointer(
                                start: block.baseAddress! + offset, count: frames),
                            scratch: room,
                        )
                        offset += frames
                    }
                }
            }
            #expect(chunked == whole, "blocks of \(size) do not agree with one block")
        }
    }

    /// A tap prepared for 512 frames handed 4096. It should not happen, and the
    /// kernel walks the block in chunks of whatever room it has rather than
    /// running off the end of the scratch if it does.
    @Test("a block larger than the scratch is walked, not overrun", arguments: [1, 7, 512, 4095])
    func scratchSmallerThanTheBlock(size: Int) {
        var ramp: [Float] = []
        for index in 0 ..< 4096 { ramp.append(-1 + 2 * Float(index) / 4095) }
        #expect(Self.applied(gain: 2.512, to: ramp, scratch: size)
            == Self.applied(gain: 2.512, to: ramp))
    }

    @Test("an empty buffer, and a null one, are both no-ops")
    func emptyBuffer() {
        var samples: [Float] = []
        var scratch: [Float] = []
        samples.withUnsafeMutableBufferPointer { block in
            scratch.withUnsafeMutableBufferPointer { room in
                GainTap.apply(gain: 1.5, to: block, scratch: room)
            }
        }
        #expect(samples.isEmpty)
        // What an `AudioBufferList` can genuinely hold: a buffer with no data
        // pointer at all.
        GainTap.apply(
            gain: 1.5,
            to: UnsafeMutableBufferPointer<Float>(start: nil, count: 0),
            scratch: UnsafeMutableBufferPointer<Float>(start: nil, count: 0),
        )
    }

    /// The only path that can reach the kernel without working room is a tap
    /// that reported no frames to prepare, which `tapPrepare` already refuses.
    /// If it ever happens anyway, the reader gets the level they asked for,
    /// hard-limited — never a chapter that silently plays flat, which is the
    /// failure this file's `TapState` was built to end.
    @Test("with no scratch at all the gain still arrives, hard-limited")
    func noScratch() {
        let samples = Self.applied(gain: 2.0, to: [0.1, 0.9, -0.9], scratch: 0)
        #expect(samples[0] == 0.2)
        #expect(samples[1] == 1.0)
        #expect(samples[2] == -1.0)
    }
}

// MARK: - End to end

/// The tap wired into a real decode, because the kernel being right says
/// nothing about whether the mix was ever consulted. A mix that is silently
/// ignored looks exactly like a mix that is applied and happens to do nothing.
///
/// Serialised, and it has to be. Every test here stands up an `AVAssetReader`
/// with an audio mix on it, and those share one `AQProcessingTapManager` for
/// the whole process. Three at once is fine; the eight this suite grew to
/// wedged the lot of them — every reader parked in `copyNextSampleBuffer`
/// waiting on a CoreMedia semaphore, with nothing of ours on any stack and no
/// timeout to end it. One decode at a time costs about a fifth of a second each
/// and cannot do that.
@Suite("A book decoded through the gain tap", .serialized)
struct GainTapDecodeTests {
    @Test("a recording read through the mix comes out louder, and clipped at the top")
    func louder() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let tap = GainTap()
        tap.gain.store(1.5, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0,
                "the mix was never consulted, so the peak below means nothing")
        #expect(abs(measured.peak - 0.75) < 0.02, "0.5 × 1.5 should be 0.75, got \(measured.peak)")
    }

    @Test("and quieter the other way")
    func quieter() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let tap = GainTap()
        tap.gain.store(0.5, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(abs(measured.peak - 0.25) < 0.02, "0.5 × 0.5 should be 0.25, got \(measured.peak)")
    }

    /// A book already mastered close to full scale is the one that most tempts
    /// a listener to turn it up, and it is the one where an unlimited multiply
    /// would wrap into a buzz.
    @Test("a recording already near full scale never leaves the range")
    func loudRecordingStaysInRange() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.9, in: directory)

        let tap = GainTap()
        tap.gain.store(1.5, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(measured.peak <= 1.0, "0.9 × 1.5 is 1.35 and must be limited, got \(measured.peak)")
        #expect(measured.peak > 0.99, "and it should be reaching the ceiling, not sitting under it")
    }

    /// The assertion the reader's complaint actually turns on.
    ///
    /// "I can hear a difference from −50% to +50%, and that's pretty much it"
    /// is a statement about *loudness*, and a peak cannot answer it — a limiter
    /// pinned to the ceiling and a gain stage doing its job both report 1.0. So
    /// this measures the RMS through a real `MTAudioProcessingTap` and asks for
    /// the level the slider promises, to a tenth of a decibel. The fixture is
    /// quiet enough that the knee never engages, which is what makes the
    /// arithmetic checkable at all.
    @Test("the level delivered is the level the rung promises", arguments: [
        (Float(0.398_107_2), Float(-8)), (1.0, 0), (2.511_886_4, 8),
    ])
    func deliveredLevel(gain: Float, decibels: Float) async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.2, in: directory)

        let reference = try await Fixture.measure(of: url, through: GainTap())
        let tap = GainTap()
        tap.gain.store(gain, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        let delivered = 20 * log10(measured.rms / reference.rms)
        #expect(abs(delivered - decibels) < 0.1,
                "\(decibels) dB was asked for and \(delivered) dB arrived")
    }

    /// The top of the new slider on a book that is quiet enough to want it —
    /// which is the book the control exists for. Nothing may touch the ceiling:
    /// if the limiter is reaching for a quietly mastered file at +8 dB, the
    /// threshold is in the wrong place.
    @Test("a quiet book at the top of the slider is loud and never limited")
    func quietBookAtTheTop() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.2, in: directory)

        let tap = GainTap()
        tap.gain.store(2.511_886_4, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(abs(measured.peak - 0.502) < 0.02,
                "0.2 × 2.512 should be 0.502, got \(measured.peak)")
        #expect(measured.clipped == 0, "a quiet book was limited at +8 dB")
    }

    /// And the same rung on a book that was mastered hot, which is where +8 dB
    /// is 2.26 times more than there is room for. The knee is what stops that
    /// being a crackle.
    @Test("a hot book at the top of the slider sits exactly on the ceiling")
    func hotBookAtTheTop() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.9, in: directory)

        let tap = GainTap()
        tap.gain.store(2.511_886_4, ordering: .relaxed)
        let measured = try await Fixture.measure(of: url, through: tap)

        #expect(tap.processedFrames.load(ordering: .relaxed) > 0)
        #expect(measured.peak <= 1.0, "0.9 × 2.512 is 2.26 and must be limited, got \(measured.peak)")
        #expect(measured.peak > 0.99, "and it should be reaching the ceiling, not sitting under it")
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

    /// The limiter needs working room, and the obvious place to hang it is the
    /// shared `GainTap` — which is exactly the bug this whole file was
    /// rearranged to close. Two chapters are alive at once across a change, one
    /// buffer between them means one writing over the other's samples mid-block,
    /// and the audible result would be a burst of somebody else's audio.
    ///
    /// Two prepared taps, two addresses. Nothing short of comparing them says
    /// so: a shared buffer produces perfectly plausible output right up until
    /// two chapters overlap.
    @Test("each tap gets its own working room, and gives it back")
    func scratchIsPerTap() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)

        let owner = GainTap()
        let (first, second) = try Self.taps(from: owner, tracks: tracks)
        var format = Self.float32
        withUnsafePointer(to: &format) { tapPrepare(tap: first, maxFrames: 1024, processingFormat: $0) }
        withUnsafePointer(to: &format) { tapPrepare(tap: second, maxFrames: 1024, processingFormat: $0) }

        let firstRoom = try #require(state(of: first).scratch)
        let secondRoom = try #require(state(of: second).scratch)
        #expect(firstRoom.count == 1024, "one mono buffer of maxFrames, got \(firstRoom.count)")
        #expect(secondRoom.count == 1024)
        #expect(firstRoom.baseAddress != secondRoom.baseAddress,
                "the two chapters are sharing one scratch buffer")

        // Preparing again is what a route change does, and it must not leak the
        // buffer it replaces or keep a stale size.
        var stereo = Self.float32
        stereo.mChannelsPerFrame = 2
        withUnsafePointer(to: &stereo) { tapPrepare(tap: first, maxFrames: 512, processingFormat: $0) }
        #expect(state(of: first).scratch?.count == 1024, "512 frames of 2 channels is 1024 floats")
        #expect(state(of: second).scratch?.baseAddress == secondRoom.baseAddress,
                "re-preparing one tap moved the other one's room")

        // And a format the kernel cannot read leaves no room behind at all.
        var integer = Self.float32
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger
        integer.mBitsPerChannel = 16
        withUnsafePointer(to: &integer) { tapPrepare(tap: first, maxFrames: 1024, processingFormat: $0) }
        #expect(Self.carriesGain(first) == false)
        #expect(state(of: first).scratch?.baseAddress == nil, "the unusable format left a buffer behind")
    }

    /// Two tracks in **one** mix, which is the same defect one level up.
    ///
    /// `makeAudioMix` used to create a single tap and hang it on every track's
    /// `AVMutableAudioMixInputParameters`. One tap is one `TapState` is one
    /// scratch buffer, so the second track's `tapPrepare` called
    /// `allocateScratch`, which frees what it replaces — 1024 floats here —
    /// while the first track's `tapProcess` was still writing the limiter's
    /// working set through it. A use-after-free on the real-time audio thread,
    /// where the symptom is somebody else's audio in the block rather than a
    /// crash anybody can read.
    ///
    /// Unreachable from any book on the shelf today, because the audiobooks
    /// here are single-track — which is precisely why the invariant has to be
    /// in the shape of the code and this test has to build the multi-track case
    /// by hand. An `AVMutableComposition` with the fixture's audio inserted
    /// twice is two real `AVAssetTrack`s and needs no second file.
    ///
    /// Two prepares, two addresses. Nothing short of comparing them says so.
    @Test("two tracks of one mix cannot be handed the same working room")
    func scratchIsPerTrackOfOneMix() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)
        let asset = AVURLAsset(url: url)
        let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let span = try await CMTimeRange(start: .zero, duration: asset.load(.duration))

        let composition = AVMutableComposition()
        for _ in 0 ..< 2 {
            let track = try #require(composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(span, of: source, at: .zero)
        }
        let tracks = composition.tracks(withMediaType: .audio)
        #expect(tracks.count == 2, "the fixture did not produce two tracks to share a buffer")

        let owner = GainTap()
        let mix = try #require(owner.makeAudioMix(for: tracks))
        #expect(mix.inputParameters.count == 2, "a track was dropped from the mix")
        let taps = try mix.inputParameters.map { try #require($0.audioTapProcessor) }
        #expect(taps[0] !== taps[1], "both tracks are driving one tap, and one scratch buffer")

        var format = Self.float32
        withUnsafePointer(to: &format) { tapPrepare(tap: taps[0], maxFrames: 1024, processingFormat: $0) }
        withUnsafePointer(to: &format) { tapPrepare(tap: taps[1], maxFrames: 1024, processingFormat: $0) }

        let first = try #require(state(of: taps[0]).scratch)
        let second = try #require(state(of: taps[1]).scratch)
        #expect(first.count == 1024)
        #expect(second.count == 1024)
        #expect(first.baseAddress != second.baseAddress,
                "the second track's prepare freed the buffer the first is processing through")

        // And the level itself is still shared, which is the whole reason one
        // `GainTap` makes all of them.
        owner.gain.store(1.5, ordering: .relaxed)
        #expect(state(of: taps[0]).owner === owner)
        #expect(state(of: taps[1]).owner === owner)
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
        player.gain = 4
        #expect(player.gain == VolumeTrim.gainRange.upperBound)
        player.gain = 0.1
        #expect(player.gain == VolumeTrim.gainRange.lowerBound)
        // In range, and it has to stay: 2× is +6 dB, two rungs below the top,
        // and the old ±50% bound would have taken it back to 1.5.
        player.gain = 2
        #expect(player.gain == 2)
        player.gain = .nan
        #expect(player.gain == 1)
    }

    /// "Not loaded yet" and "cannot be made louder" are different answers, and
    /// the screen that captions the second must not caption the first: a row
    /// that read a bare `false` would tell every reader their book can only be
    /// made quieter for the moment between the sheet opening and the first
    /// track resolving.
    ///
    /// The fallback arithmetic is the same either way, because there is no tap
    /// either way.
    @Test("a player with nothing loaded has no answer yet, and still trims downwards")
    func nothingLoadedYet() {
        let player = AudioPlayer()
        #expect(player.tapCarriesGain == nil)
        player.gain = VolumeTrim.gain(-6)
        #expect(abs(player.underlyingVolume - VolumeTrim.gain(-6)) < 1e-6,
                "the quieter half has to arrive through the player's own volume")
        player.gain = VolumeTrim.gain(8)
        #expect(player.underlyingVolume == 1, "and the louder half has nowhere to go")
    }

    @Test("a file with real tracks gets the tap, and the fade keeps the player's volume")
    func localFileCarriesTheTap() async throws {
        let directory = try Fixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Fixture.sine(amplitude: 0.5, in: directory)

        let player = AudioPlayer()
        #expect(await player.load(url: url, href: "sine.wav"))
        #expect(player.tapCarriesGain == true, "a local float WAV has a track to attach to")

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
        player.gain = VolumeTrim.gainRange.upperBound
        #expect(player.underlyingVolume == 1,
                "+8 dB is not expressible without a tap, and must not be faked by clipping")
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
        player.gain = VolumeTrim.gainRange.upperBound
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

    /// What came out of the tap's mix, measured three ways.
    ///
    /// The peak alone cannot tell "the level moved" from "the level was
    /// clamped": a hard clip and a working gain stage both report 1.0. The RMS
    /// is what says how loud the book actually got, and the clipped fraction is
    /// what says at what cost — which is the whole argument between a soft knee
    /// and the `vDSP_vclip` it replaced.
    ///
    /// `clipped` counts samples at or past full scale, not blocks: the loop
    /// below visits every sample anyway, and per-sample is the stricter reading.
    static func measure(of url: URL, through tap: GainTap) async throws
        -> (peak: Float, rms: Float, clipped: Double) {
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
        var sumOfSquares = 0.0
        var clipped = 0
        var total = 0
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
                for value in floats {
                    let magnitude = abs(value)
                    peak = max(peak, magnitude)
                    sumOfSquares += Double(value) * Double(value)
                    if magnitude >= 1 { clipped += 1 }
                    total += 1
                }
            }
        }
        return (
            peak,
            total > 0 ? Float((sumOfSquares / Double(total)).squareRoot()) : 0,
            total > 0 ? Double(clipped) / Double(total) : 0
        )
    }
}

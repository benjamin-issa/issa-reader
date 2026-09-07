import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import Synchronization

/// A gain stage in front of `AVPlayer`'s own output.
///
/// `AVPlayer.volume` is documented 0…1 and does not go above unity, so it can
/// make a book quieter and never louder — and it is already spoken for by the
/// sleep timer's fade. `AVMutableAudioMixInputParameters.setVolume(_:at:)` is
/// no better: same documented range, unspecified behaviour above it. That
/// leaves an `MTAudioProcessingTap`, which hands us the samples themselves.
///
/// One instance lives for the life of an `AudioPlayer` and is attached to every
/// item it loads, so a chapter change does not drop the level. What it does
/// *not* share across those items is the per-tap format flag or the limiter's
/// scratch buffer — see `TapState`.
/// The gain is read on the real-time audio thread, which may not block: no
/// lock, no actor hop, no allocation and no ARC traffic beyond the unretained
/// reference to the tap's own state, which holds this object. `Atomic` rather
/// than `OSAllocatedUnfairLock` for exactly that reason — a lock held by the
/// main thread while the audio thread wants it is a priority inversion, and the
/// symptom is a dropout, not a hang anyone can see.
final class GainTap: Sendable {
    /// The multiplier every sample is scaled by. 1 means "as recorded", and the
    /// process callback then does no work at all.
    ///
    /// Shared across every tap this object makes, deliberately: it is the
    /// player-wide setting, and sharing it is exactly what stops a chapter
    /// change dropping the book's level.
    let gain = Atomic<Float>(1)
    /// Frames the tap has actually seen. Nothing in the app reads this — it is
    /// how a test tells "the mix was attached and ran" from "the mix was
    /// attached and silently ignored", which is otherwise indistinguishable
    /// from correct output.
    let processedFrames = Atomic<Int>(0)

    /// Builds the mix that carries this tap, or nil when there is nothing to
    /// attach it to.
    ///
    /// Nil is a real answer, not a failure: a streamed asset whose tracks
    /// cannot be loaded — an HLS playlist — has no `AVAssetTrack` to hang input
    /// parameters on, and the caller falls back to the player's own volume for
    /// the half of the range that can be expressed there.
    func makeAudioMix(for tracks: [AVAssetTrack]) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }
        // +1 for the tap to hold. `tapInit` takes it into the `TapState` it
        // allocates, and `tapFinalize` releasing that box is what gives it
        // back. Balanced by hand below if the tap is never created, because
        // `tapInit` is then never called and nothing else would.
        let clientInfo = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess,
        )
        var tap: MTAudioProcessingTap?
        // PostEffects, so the samples arrive after `audioTimePitchAlgorithm`
        // has done its work: pre-effects gain would be re-scaled by the
        // time-stretcher, and the level would then depend on the playback rate.
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap,
        )
        guard status == noErr, let tap else {
            // Nothing will ever call `tapFinalize`, so the retain above has to
            // be given back here or this object outlives the process.
            Unmanaged<GainTap>.fromOpaque(clientInfo).release()
            return nil
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            return parameters
        }
        return mix
    }

    // MARK: - The kernel

    /// Where the knee starts, in linear amplitude. Everything quieter than this
    /// is passed through bit-exact, which is the whole reason a knee was chosen
    /// over the shapes that curve the entire signal.
    static let threshold: Float = 0.8
    /// Where the knee reaches the ceiling. Above it every sample is exactly 1.
    ///
    /// `2 − T` and not a number of its own: it is what makes the curve meet the
    /// ceiling with a slope of zero, so the limiter has no corner at either end.
    static let ceiling: Float = 2 - threshold
    /// The quadratic's coefficient, `1 / 4(1 − T)`. Chosen so the curve leaves
    /// the threshold at slope 1 and arrives at `ceiling` at slope 0 and height 1.
    static let curvature: Float = 1 / (4 * (1 - threshold))

    /// Scales a block of samples, softly limiting anything the scale pushed
    /// past the knee.
    ///
    /// The shape, for a scaled sample `y` and a threshold `T` of 0.8:
    ///
    /// - `|y| ≤ T` — untouched, bit for bit.
    /// - `T < |y| < 2 − T` — `|y| − (|y| − T)² / 4(1 − T)`, signed like `y`.
    /// - `|y| ≥ 2 − T` — exactly 1.
    ///
    /// A knee rather than a curve over the whole signal, and that is the point
    /// of it. Measured on an ACX-mastered book at 2.5×, this delivers 7.90 dB of
    /// the 7.96 asked for, at 2.41% THD+N, with 1.8% of blocks touching the
    /// ceiling; the hard clip it replaces put 17.4% of blocks on the ceiling and
    /// its error above 8 kHz was 4 dB worse. `tanh` and a cubic were both tried
    /// and both rejected for the same reason: they shape *every* sample, so at
    /// gain 1.0 `tanh` costs 0.16 dB and 1.59% THD+N — a volume control that
    /// audibly changes a book set to "As recorded" is not shippable. Look-ahead
    /// limiting was rejected too: 3 ms of latency, a delay line nothing flushes
    /// on a seek, and it throws the boost away — 4.65 dB of the 7.96 asked for
    /// on a hot master, which is the wrong trade for a reader whose complaint is
    /// that they cannot hear a difference.
    ///
    /// Below unity the knee is not engaged at all. A gain under 1 cannot push an
    /// in-range recording out of range, and a sample the recording already
    /// carried out of range is left exactly as it was — the same promise
    /// `gain == 1` has always kept by short-circuiting.
    ///
    /// Real-time safe: no allocation, no lock, no transcendental and no
    /// per-sample branch. Nine vDSP passes plus a reduction and one vForce
    /// sign copy, over one caller-supplied scratch buffer.
    ///
    /// Layout-agnostic — mono, interleaved stereo and one channel of a
    /// deinterleaved pair are all just a run of floats.
    ///
    /// - Parameter scratch: working room the kernel writes over. Any size:
    ///   `samples` is walked in chunks of it, which is exact because the shape
    ///   is memoryless — no sample's output depends on its neighbours. An empty
    ///   one is answered with the hard clip this replaced rather than with
    ///   silence-or-nothing, so a tap that somehow reached the audio thread
    ///   without scratch still delivers the level the reader asked for.
    static func apply(
        gain: Float,
        to samples: UnsafeMutableBufferPointer<Float>,
        scratch: UnsafeMutableBufferPointer<Float>,
    ) {
        guard gain != 1, let base = samples.baseAddress, !samples.isEmpty else { return }
        var scale = gain
        let count = vDSP_Length(samples.count)
        vDSP_vsmul(base, 1, &scale, base, 1, count)
        guard gain > 1 else { return }

        guard let temp = scratch.baseAddress, !scratch.isEmpty else {
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(base, 1, &low, &high, base, 1, count)
            return
        }
        var offset = 0
        while offset < samples.count {
            limit(base + offset, temp, Swift.min(scratch.count, samples.count - offset))
            offset += scratch.count
        }
    }

    /// The knee itself, over one run of samples that fits the scratch.
    private static func limit(
        _ samples: UnsafeMutablePointer<Float>,
        _ temp: UnsafeMutablePointer<Float>,
        _ frames: Int,
    ) {
        let count = vDSP_Length(frames)
        vDSP_vabs(samples, 1, temp, 1, count)
        var peak: Float = 0
        vDSP_maxv(temp, 1, &peak, count)
        // Written inverted, and it matters: a NaN anywhere in the block makes
        // `vDSP_maxv` hand back NaN, `NaN <= threshold` is false, and the block
        // therefore takes the long path — where the poison stays a NaN instead
        // of being read as "quiet" and skipped. Most blocks of most books never
        // reach the knee at all, and this is what makes them cost three passes.
        guard !(peak <= threshold) else { return }

        // Everything past the point where the curve has already reached 1,
        // ±infinity included, folded onto the one value the arithmetic below
        // turns into exactly 1.
        var low = -ceiling
        var high = ceiling
        vDSP_vclip(samples, 1, &low, &high, samples, 1, count)
        // How far each sample is past the knee, floored at zero so every sample
        // under it is reduced by exactly nothing.
        vDSP_vabs(samples, 1, temp, 1, count)
        var offset = -threshold
        vDSP_vsadd(temp, 1, &offset, temp, 1, count)
        var zero: Float = 0
        vDSP_vthr(temp, 1, &zero, temp, 1, count)
        // (excess)² / 4(1 − T), signed like the sample it comes off.
        vDSP_vsq(temp, 1, temp, 1, count)
        var scale = curvature
        vDSP_vsmul(temp, 1, &scale, temp, 1, count)
        var signedCount = Int32(frames)
        vvcopysignf(temp, temp, samples, &signedCount)
        // C = B − A, so this is `samples −= temp`.
        vDSP_vsub(temp, 1, samples, 1, samples, 1, count)
    }
}

// MARK: - Per-tap state

/// What one `MTAudioProcessingTap` carries, as against what the `GainTap` that
/// made it carries.
///
/// `isFloat32` lives here, and this type exists, because the two lifetimes are
/// not the same. One `GainTap` lives for the life of an `AudioPlayer`, while
/// `makeAudioMix` builds a **new tap per `load`** — one per chapter. Held on
/// the shared owner, the flag was one variable for every tap alive at once,
/// and on a chapter change
/// `player.removeAllItems()` hands item 1's teardown to AVFoundation's own
/// queues: `tapUnprepare(tap1)` could store `false` after `tapPrepare(tap2)`
/// had stored `true`. `tapProcess` then bailed at the format guard and passed
/// every sample through untouched — a book set to +50% played that chapter as
/// recorded — while `tapCarriesGain` stayed true, so `applyPlayerVolume` did
/// not compensate through `player.volume` either.
///
/// The limiter's scratch is here for exactly the same reason, and hanging it on
/// the shared owner instead would be that bug a second time: two chapters alive
/// at once would share one buffer, and each would be prepared for its own frame
/// count and format.
///
/// Allocated by `tapInit`, which is where the tap's own storage is for, and
/// freed by `tapFinalize`. Holding `owner` strongly is what consumes the +1
/// `makeAudioMix` took: this box's own release is the only balance needed.
final class TapState: Sendable {
    let owner: GainTap
    /// Whether the format the tap was prepared with is the 32-bit float PCM
    /// the kernel assumes. Set in `prepare`, cleared in `unprepare`; anything
    /// else is passed through untouched rather than reinterpreted.
    let isFloat32 = Atomic<Bool>(false)

    /// The limiter's working room, as an address rather than as a pointer.
    ///
    /// `Atomic` is `Sendable` only where its value is, and a pointer is not, so
    /// a checked-`Sendable` class cannot hold `Atomic<UnsafeMutablePointer<Float>?>`.
    /// The address travels as the `UInt` it already is, which keeps the
    /// compiler's check over every other member of this type. Zero means none.
    private let scratchAddress = Atomic<UInt>(0)
    /// How many floats `scratchAddress` points at. Written before the address
    /// and cleared after it, so a reader that sees an address sees a length.
    private let scratchCount = Atomic<Int>(0)

    init(owner: GainTap) { self.owner = owner }

    /// The limiter's working room, or nil where there is none.
    ///
    /// Read on the real-time thread: two relaxed-free atomic loads and no ARC,
    /// which is the whole reason the buffer is held as a bare address.
    var scratch: UnsafeMutableBufferPointer<Float>? {
        guard let base = UnsafeMutablePointer<Float>(
            bitPattern: scratchAddress.load(ordering: .acquiring)) else { return nil }
        let count = scratchCount.load(ordering: .acquiring)
        guard count > 0 else { return nil }
        return UnsafeMutableBufferPointer(start: base, count: count)
    }

    /// Gives this tap room for `count` floats, replacing whatever it had.
    ///
    /// Called from `prepare`, which may run more than once over one tap's life
    /// — with a different frame count or a different channel layout each time —
    /// so the old buffer is handed back rather than leaked. Safe to free here
    /// because `prepare` and `process` are never in flight together for the same
    /// tap; it is two *different* taps whose callbacks interleave, and they no
    /// longer share anything.
    func allocateScratch(count: Int) {
        releaseScratch()
        guard count > 0 else { return }
        let base = UnsafeMutablePointer<Float>.allocate(capacity: count)
        base.initialize(repeating: 0, count: count)
        scratchCount.store(count, ordering: .releasing)
        scratchAddress.store(UInt(bitPattern: base), ordering: .releasing)
    }

    /// Hands the working room back. Idempotent, because `prepare` calls it
    /// before every allocation and `finalize` calls it once at the end.
    func releaseScratch() {
        let address = scratchAddress.exchange(0, ordering: .acquiringAndReleasing)
        let count = scratchCount.exchange(0, ordering: .acquiringAndReleasing)
        guard let base = UnsafeMutablePointer<Float>(bitPattern: address) else { return }
        base.deinitialize(count: count)
        base.deallocate()
    }
}

// MARK: - Callbacks

/// Free functions, not methods: `MTAudioProcessingTapCallbacks` holds C
/// function pointers, and a Swift method — even a static one — cannot be one.
/// The state they work on arrives through the tap's storage instead.
///
/// Internal rather than private so a test can prepare two taps made by one
/// `GainTap` and watch the first one's teardown leave the second alone. No
/// end-to-end decode can stage that: starting a read prepares the tap again,
/// which sets the flag back and hides the bug.
func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
) {
    guard let clientInfo else { return }
    // `takeRetainedValue`, so the +1 `makeAudioMix` took becomes this box's
    // strong reference rather than a second thing to balance by hand.
    let state = TapState(owner: Unmanaged<GainTap>.fromOpaque(clientInfo).takeRetainedValue())
    tapStorageOut.pointee = Unmanaged.passRetained(state).toOpaque()
}

func tapFinalize(tap: MTAudioProcessingTap) {
    let state = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
    // Before the release, so the buffer is handed back even if this is the last
    // reference and the box goes with it. `unprepare` deliberately does not do
    // this: prepare and unprepare pair up several times over one tap's life,
    // and the room is worth keeping between them.
    state.takeUnretainedValue().releaseScratch()
    state.release()
}

func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>,
) {
    let format = processingFormat.pointee
    // Every check matters. `kAudioFormatLinearPCM` alone still admits 16-bit
    // integer samples, and reading those as floats would not be quiet or loud
    // — it would be noise at full scale.
    //
    // The frame count is part of the same question, not a separate one: the
    // limiter needs working room, and a tap that reports no room to prepare is
    // a tap that cannot limit. Folding it in here is what lets `tapProcess`
    // treat "the format is right" and "there is scratch" as one fact.
    let frames = Int(maxFrames) * Int(format.mChannelsPerFrame)
    let usable = format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && format.mBitsPerChannel == 32
        && frames > 0
    let state = state(of: tap)
    // Sized for the widest buffer this tap can be handed: `maxFrames` frames of
    // `mChannelsPerFrame` channels is exactly one interleaved buffer, and more
    // than one channel of a deinterleaved pair. `tapProcess` chunks anything
    // bigger rather than trusting the promise.
    //
    // A format the kernel cannot read gets none, which keeps the invariant to
    // one sentence: there is working room exactly when there is a gain to
    // apply. Re-preparing releases what came before either way, so a route
    // change does not leave a buffer behind.
    state.allocateScratch(count: usable ? frames : 0)
    state.isFloat32.store(usable, ordering: .relaxed)
}

func tapUnprepare(tap: MTAudioProcessingTap) {
    // Prepare and unprepare are paired but may run several times over one
    // tap's life, and the format is only promised inside a pair. This tap's
    // pair: another tap's is none of its business.
    state(of: tap).isFloat32.store(false, ordering: .relaxed)
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>,
) {
    // Always pull, even when there is nothing to do: the buffer list handed to
    // us is empty until this fills it, so returning early without it would
    // deliver silence rather than the untouched recording.
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut,
    )
    guard status == noErr else { return }
    let state = state(of: tap)
    guard state.isFloat32.load(ordering: .relaxed) else { return }
    state.owner.processedFrames.wrappingAdd(Int(numberFramesOut.pointee), ordering: .relaxed)

    let gain = state.owner.gain.load(ordering: .relaxed)
    guard gain != 1 else { return }
    // This tap's own working room, never the owner's: two chapters are alive at
    // once across a change, and one buffer between them is the bug `TapState`
    // exists to close.
    let scratch = state.scratch ?? UnsafeMutableBufferPointer<Float>(start: nil, count: 0)
    for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { continue }
        GainTap.apply(
            gain: gain,
            to: UnsafeMutableBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: count),
            scratch: scratch,
        )
    }
}

/// This tap's own state, unretained. `MTAudioProcessingTapGetStorage` hands
/// back exactly what `tapInit` wrote, and `tapFinalize` is what releases it, so
/// it is good for the life of the tap and reading it costs no ARC traffic on
/// the audio thread.
func state(of tap: MTAudioProcessingTap) -> TapState {
    Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

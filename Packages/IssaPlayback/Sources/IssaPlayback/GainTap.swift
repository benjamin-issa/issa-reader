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
/// item it loads, so a chapter change does not drop the level. The gain is read
/// on the real-time audio thread, which may not block: no lock, no actor hop,
/// no allocation and no ARC traffic beyond the one unretained reference to this
/// object. `Atomic` rather than `OSAllocatedUnfairLock` for exactly that
/// reason — a lock held by the main thread while the audio thread wants it is a
/// priority inversion, and the symptom is a dropout, not a hang anyone can see.
final class GainTap: Sendable {
    /// The multiplier every sample is scaled by. 1 means "as recorded", and the
    /// process callback then does no work at all.
    let gain = Atomic<Float>(1)
    /// Whether the format the tap was prepared with is the deinterleaved 32-bit
    /// float PCM the kernel assumes. Set in `prepare`, cleared in `unprepare`;
    /// anything else is passed through untouched rather than reinterpreted.
    let isFloat32 = Atomic<Bool>(false)
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
        // +1 for the tap to hold; `tapFinalize` balances it. Balanced by hand
        // below if the tap is never created, because nothing else would.
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

    /// Scales a block of samples and clips it back into range.
    ///
    /// Clipped rather than left to overflow: above unity a recording already
    /// mastered close to full scale would wrap into a hard buzz, and hard
    /// limiting is the least bad of the answers that cost nothing per sample.
    /// Layout-agnostic — mono, interleaved stereo and one channel of a
    /// deinterleaved pair are all just a run of floats.
    static func apply(gain: Float, to samples: UnsafeMutableBufferPointer<Float>) {
        guard gain != 1, let base = samples.baseAddress, !samples.isEmpty else { return }
        var scale = gain
        var low: Float = -1
        var high: Float = 1
        let count = vDSP_Length(samples.count)
        vDSP_vsmul(base, 1, &scale, base, 1, count)
        vDSP_vclip(base, 1, &low, &high, base, 1, count)
    }
}

// MARK: - Callbacks

/// Free functions, not methods: `MTAudioProcessingTapCallbacks` holds C
/// function pointers, and a Swift method — even a static one — cannot be one.
/// The object they belong to arrives through the tap's storage instead.
private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
) {
    // The retain taken in `makeAudioMix` is what keeps this pointer good for
    // the life of the tap.
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<GainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>,
) {
    let format = processingFormat.pointee
    // Every check matters. `kAudioFormatLinearPCM` alone still admits 16-bit
    // integer samples, and reading those as floats would not be quiet or loud
    // — it would be noise at full scale.
    let usable = format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && format.mBitsPerChannel == 32
    owner(of: tap).isFloat32.store(usable, ordering: .relaxed)
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    // Prepare and unprepare are paired but may run several times over one
    // tap's life, and the format is only promised inside a pair.
    owner(of: tap).isFloat32.store(false, ordering: .relaxed)
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
    let tap = owner(of: tap)
    guard tap.isFloat32.load(ordering: .relaxed) else { return }
    tap.processedFrames.wrappingAdd(Int(numberFramesOut.pointee), ordering: .relaxed)

    let gain = tap.gain.load(ordering: .relaxed)
    guard gain != 1 else { return }
    for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { continue }
        GainTap.apply(
            gain: gain,
            to: UnsafeMutableBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: count),
        )
    }
}

/// The tap's owner, unretained. `MTAudioProcessingTapGetStorage` hands back
/// exactly what `tapInit` wrote, which is the pointer `makeAudioMix` retained.
private func owner(of tap: MTAudioProcessingTap) -> GainTap {
    Unmanaged<GainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

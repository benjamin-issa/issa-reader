import Foundation
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// The half of the volume slider that cannot be delivered, and used to say so
/// to nobody.
///
/// `AVPlayer.volume` is documented 0…1, so with no `MTAudioProcessingTap` on
/// the item `AudioPlayer.applyPlayerVolume` computes `volume * min(gain, 1)`:
/// the quieter half arrives and everything right of "as recorded" plays at the
/// recorded level. The arithmetic is right — there is nowhere else for the
/// level to come from — but it was silent, so a reader dragging to the top
/// heard nothing change and had no way to tell that from a broken control. On
/// the percentage scale this replaced the silent loss was 3.5 dB; with the
/// +8 dB top rung it is 8 dB.
///
/// Three states and not two, which is the part worth pinning: nil is "nothing
/// loaded yet", and captioning that would put the warning under every book for
/// the moment before its tracks resolve.
@Suite("Telling a reader their book cannot be made louder")
struct VolumeTrimReachTests {
    @Test("only a player that has answered no says no", arguments: [
        (nil as Bool?, true), (true as Bool?, true), (false as Bool?, false),
    ])
    func canBeLouder(carriesGain: Bool?, expected: Bool) {
        #expect(VolumeTrimReach.canBeLouder(carriesGain: carriesGain) == expected)
    }

    @Test("the caption appears for that one state and no other")
    func captionOnlyWhereItIsTrue() {
        #expect(VolumeTrimReach.caption(carriesGain: nil) == nil)
        #expect(VolumeTrimReach.caption(carriesGain: true) == nil)
        let caption = VolumeTrimReach.caption(carriesGain: false)
        #expect(caption != nil)
        #expect(caption?.contains("quieter") == true)
    }

    /// VoiceOver has no caption to fall back on — the line under the slider is
    /// hidden from it — so the value carries the warning, and only where the
    /// level is actually asking for more than can be delivered.
    @Test("the spoken value warns above as-recorded and stays quiet at or below it")
    func spokenValue() {
        #expect(VolumeTrimReach.spoken(3, carriesGain: true) == "3 decibels louder")
        #expect(VolumeTrimReach.spoken(3, carriesGain: nil) == "3 decibels louder")
        #expect(VolumeTrimReach.spoken(3, carriesGain: false)
            == "3 decibels louder, but this book can only be made quieter")
        #expect(VolumeTrimReach.spoken(1, carriesGain: false)
            == "1 decibel louder, but this book can only be made quieter")
        // Nothing is being lost at or below the recorded level, and a warning
        // there would be noise on every step of the working half.
        #expect(VolumeTrimReach.spoken(0, carriesGain: false) == "as recorded")
        #expect(VolumeTrimReach.spoken(-6, carriesGain: false) == "6 decibels quieter")
        // Through the clamp, so a stored level off the end is judged by the
        // rung it will actually play at.
        #expect(VolumeTrimReach.spoken(Int.max, carriesGain: false)
            == "8 decibels louder, but this book can only be made quieter")
        #expect(VolumeTrimReach.spoken(Int.min, carriesGain: false) == "8 decibels quieter")
    }

    /// Every rung, so the warning cannot be attached to the wrong half of the
    /// ladder by a stray comparison.
    @Test("the warning is on exactly the rungs that cannot be heard")
    func everyRung() {
        for level in VolumeTrim.ladder {
            let spoken = VolumeTrimReach.spoken(level, carriesGain: false)
            let warns = spoken.contains("can only be made quieter")
            #expect(warns == (level > 0), "\(level) dB spoke as \(spoken)")
            #expect(VolumeTrimReach.spoken(level, carriesGain: true) == VolumeTrim.spoken(level))
        }
    }
}

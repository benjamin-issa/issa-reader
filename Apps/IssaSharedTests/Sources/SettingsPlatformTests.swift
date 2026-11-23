import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// What each platform's Settings says and offers, asked of from the phone's
/// bundle, the way `MacPanesAndPlaybackTests` asks of the Mac's panes.
///
/// The phone's words are pinned exactly: the television and the Mac lost the
/// sentences about the car, the Lock Screen and CarPlay, and the phone must
/// not have lost a word of them.
@Suite("Settings, by platform")
struct SettingsPlatformTests {
    private static let elsewhere = ["Lock Screen", "CarPlay", "the car", "in the car"]

    private func mentionsElsewhere(_ text: String?) -> Bool {
        guard let text else { return false }
        return Self.elsewhere.contains { text.contains($0) }
    }

    @Test("the phone's Settings say what they said, word for word")
    func phoneIsUnchanged() {
        let phone = SettingsPlatform.phone
        #expect(phone.offersControls)
        #expect(phone.choosesSurface)
        #expect(phone.progressNote(for: .chapter)
            == "The player, the Lock Screen and CarPlay all show the chapter you are in.")
        #expect(phone.progressNote(for: .book)
            == "The player, the Lock Screen and CarPlay all show the whole book.")
        #expect(phone.buttonsNote(surface: .phone, wheelIsBound: true)
            == "The Lock Screen shows next and previous track while the wheel is assigned.")
        #expect(phone.buttonsNote(surface: .headphones, wheelIsBound: false)
            == "Leave the wheel unassigned and the Lock Screen shows the skip buttons instead.")
        #expect(phone.buttonsNote(surface: .carPlay, wheelIsBound: true) == nil)
        #expect(phone.skipNote
            == "Used by the skip buttons wherever narration is playing — the player, the Lock Screen, CarPlay — and by the jump buttons next to the chapter name on the reading page.")
        #expect(phone.resetTitle(for: .phone) == "Reset Phone to defaults")
        #expect(phone.resetTitle(for: .carPlay) == "Reset CarPlay to defaults")
    }

    /// The Mac only ever uses the phone's bindings, so it shows one set and
    /// says nothing of surfaces it does not have.
    @Test("the Mac has one set of buttons and no car, Lock Screen or CarPlay")
    func macHasOneSurface() {
        let mac = SettingsPlatform.mac
        #expect(mac.offersControls)
        #expect(!mac.choosesSurface, "the Mac offers a choice of surface it never reads")
        for scope in ProgressScope.allCases {
            let note = mac.progressNote(for: scope)
            #expect(note != nil, "the Mac's Progress bar has nothing under it")
            #expect(!mentionsElsewhere(note), "\(note ?? "")")
        }
        for surface in ControlSurface.allCases {
            for bound in [true, false] {
                let note = mac.buttonsNote(surface: surface, wheelIsBound: bound)
                #expect(!mentionsElsewhere(note), "\(note ?? "")")
            }
        }
        #expect(!mentionsElsewhere(mac.skipNote), "\(mac.skipNote)")
        for surface in ControlSurface.allCases {
            let title = mac.resetTitle(for: surface)
            #expect(!title.contains(surface.title), "the Mac's reset names a surface: \(title)")
        }
    }

    @Test("the television has no Controls & remapping and no Lock Screen sentence")
    func televisionHasNoControls() {
        let television = SettingsPlatform.television
        #expect(!television.offersControls)
        for scope in ProgressScope.allCases {
            #expect(television.progressNote(for: scope) == nil)
        }
    }

    @Test("this bundle's own platform is the phone")
    func currentIsThePhone() {
        #expect(SettingsPlatform.current == .phone)
    }
}

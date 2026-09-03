import SwiftUI
import Testing
@testable import IssaUI

/// The ramp is sized for a phone and doubled for a television. These are the
/// guarantees that keeps: the phone and Mac do not move at all, and nothing on
/// tvOS lands under the size that platform calls its minimum.
@Suite("The type ramp across platforms")
struct TypographyTests {
    @Test("doubling with a floor is what the tvOS scale does")
    func scaledArithmetic() {
        #expect(Typography.scaled(15, by: 2, floor: 23) == 30)
        // Caption would be 22, which tvOS does not allow.
        #expect(Typography.scaled(11, by: 2, floor: 23) == 23)
        #expect(Typography.scaled(34, by: 2, floor: 23) == 68)
    }

    @Test("no size on a television lands under 23")
    func televisionMeetsTheFloor() {
        for entry in Typography.rampSizes {
            let size = Typography.scaled(entry.size, by: 2, floor: 23)
            #expect(size >= 23, "\(entry.name) would be \(size)pt on a television")
        }
    }

    #if !os(tvOS)
    /// The promise to the phone and the Mac: the named constants are the same
    /// fonts they were before the scale existed.
    @Test("off tvOS every named size is untouched")
    func phoneAndMacAreUnchanged() {
        #expect(Typography.rampScale == 1)
        #expect(Typography.displayLarge == Typography.serif(34, weight: .medium))
        #expect(Typography.display == Typography.serif(28, weight: .medium))
        #expect(Typography.title == Typography.serif(22, weight: .medium))
        #expect(Typography.bookTitle == Typography.serif(17, weight: .medium))
        #expect(Typography.headline == Typography.sans(17, weight: .semibold))
        #expect(Typography.body == Typography.sans(15))
        #expect(Typography.callout == Typography.sans(14))
        #expect(Typography.subhead == Typography.sans(13))
        #expect(Typography.footnote == Typography.sans(12))
        #expect(Typography.caption == Typography.sans(11))
        #expect(Typography.overline == Typography.sans(11, weight: .semibold))
    }

    @Test("off tvOS the spacing scale is the identity")
    func spacingIsUnchanged() {
        #expect(Metrics.spacing4 == 4)
        #expect(Metrics.spacing16 == 16)
        #expect(Metrics.spacing32 == 32)
        #expect(Metrics.spacing48 == 48)
        #expect(Metrics.radiusLarge == 14)
        #expect(Metrics.screenMargin == 16)
        #expect(Metrics.overlineTracking == 1.6)
    }
    #endif
}

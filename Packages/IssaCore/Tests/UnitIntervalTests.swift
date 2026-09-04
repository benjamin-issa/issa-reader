import Foundation
import Testing

@testable import IssaCore

@Suite("A progression is finite or it is not a progression")
struct UnitIntervalTests {
    /// The hazard, before the guard. This is why twenty inline clamps were not
    /// clamps: `max(_:_:)` is `y >= x ? y : x`, every comparison against NaN is
    /// false, so the answer depends on which operand was written first.
    @Test("Swift's own clamp does not filter NaN, and the argument order decides")
    func theHazardIsReal() {
        #expect(min(max(Double.nan, 0), 1).isNaN, "the spelling used at fourteen sites")
        #expect(min(max(0, Double.nan), 1) == 0, "the other order, which happens to be safe")
    }

    @Test("a non-finite value has no honest progression", arguments: [
        Double.nan, .infinity, -.infinity,
    ])
    func refusesNonFinite(_ value: Double) {
        #expect(value.asProgression == nil, "0 would be a claim about where the reader is")
        #expect(value.clampedToUnitInterval() == 0)
    }

    @Test("everything else clamps", arguments: [
        (-1.0, 0.0), (0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (2.0, 1.0), (-0.0001, 0.0),
    ])
    func clampsTheRest(_ value: Double, _ expected: Double) {
        #expect(value.asProgression == expected)
    }

    /// The specific consequence at the sites this replaced: a NaN reaching
    /// `spinePosition` becomes `Int(nan)`, which traps rather than throws.
    @Test("a refused progression never reaches an Int conversion")
    func doesNotReachIntConversion() {
        let poisoned = Double.nan
        let safe = poisoned.asProgression
        #expect(safe == nil)
        // Int(nan) traps; Int(0) does not. The guard is what keeps the second
        // line reachable.
        #expect(Int((safe ?? 0) * 100) == 0)
    }
}

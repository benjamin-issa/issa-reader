#if ISSA_UITEST_FIXTURE
import IssaUI
import SwiftUI

/// Publishes the numbers the layout sweep measures against.
///
/// The alternative is a test that writes `XCTAssertEqual(minX, 16)`, which is a
/// second copy of `Metrics.screenMargin` living in a different file. The class
/// of bug this sweep exists to catch is "a margin drifted from the token", so a
/// duplicated literal is exactly how it happens again, one layer down. The test
/// reads the token out of the running app instead.
///
/// An invisible element rather than a modifier on real content: it must not
/// change anything it measures.
struct LayoutProbe: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(Self.identifier)
            .accessibilityLabel("layout probe")
            .accessibilityValue(Self.value)
            .allowsHitTesting(false)
    }

    static let identifier = "probe.layout"

    private static var value: String {
        let safe = ReaderInsets.current()
        return "margin=\(Metrics.screenMargin);left=\(safe.leading);right=\(safe.trailing)"
    }
}
#endif

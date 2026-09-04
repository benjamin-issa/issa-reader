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
///
/// The value is `@State` refreshed from `.task` and on rotation, not a computed
/// property read inline. This struct has no stored properties, so SwiftUI
/// compares two instances as equal and is free to evaluate `body` exactly once
/// — which latched whatever `ReaderInsets.current()` returned at that moment.
/// At launch that is `EdgeInsets()`, because there is no key window yet, so the
/// sweep could measure a landscape iPad against a safe area of zero and pass.
/// It has not bitten only because every row of `ALL_DEVICES` is portrait.
struct LayoutProbe: View {
    @State private var value = ""

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(Self.identifier)
            .accessibilityLabel("layout probe")
            .accessibilityValue(value)
            .allowsHitTesting(false)
            .task { value = Self.reading() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)
            ) { _ in
                value = Self.reading()
            }
    }

    static let identifier = "probe.layout"

    private static func reading() -> String {
        let safe = ReaderInsets.current()
        return "margin=\(Metrics.screenMargin);left=\(safe.leading);right=\(safe.trailing)"
    }
}
#endif

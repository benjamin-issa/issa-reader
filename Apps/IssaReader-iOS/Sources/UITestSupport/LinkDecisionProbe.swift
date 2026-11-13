#if ISSA_UITEST_FIXTURE
import Observation
import SwiftUI

/// What the app last decided about a book link, for the link tests.
///
/// A test that sends a link and then looks for nothing to have happened (the
/// reader of the same book staying up) passes just as well when the link never
/// arrived. This is the positive half: the app says it saw the link and what
/// it did, and the test reads that out of `probe.link`.
@MainActor
@Observable
final class LinkDecisions {
    static let shared = LinkDecisions()

    /// `<count>:<decision>:<book uuid>`, or `none` before any link. The count
    /// tells a decision made for a later link from one made for an earlier.
    private(set) var last = "none"
    private var count = 0

    func record(_ decision: String, book: String) {
        count += 1
        last = "\(count):\(decision):\(book)"
    }
}

/// The last decision as an invisible element, as `LayoutProbe` publishes its
/// numbers.
struct LinkDecisionProbe: View {
    static let identifier = "probe.link"

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(Self.identifier)
            .accessibilityLabel("link probe")
            .accessibilityValue(LinkDecisions.shared.last)
            .allowsHitTesting(false)
    }
}
#endif

import XCTest

/// Tests for the tests.
///
/// The sweep's whole value is that it fails when a screen is wrong, and the
/// only honest way to know it does is to hand it a screen that is. Driving the
/// real app into the exact failure is unreliable — the app has since grown the
/// `containerRelativeFrame` that makes that particular overflow impossible, and
/// an injected over-wide subview did not reproduce it — so the invariants are
/// fed hand-built trees instead, shaped exactly like the four bugs that
/// prompted them.
///
/// These need no simulator app: `XCUIElementSnapshot` is a protocol.
@MainActor
final class LayoutInvariantsTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func reference(margin: CGFloat = 16) -> LayoutReference {
        LayoutReference(window: window, safe: window, screenMargin: margin)
    }

    /// An expectation that only the intended failure satisfies.
    ///
    /// Every `XCTExpectFailure` here used to take a bare description, which is
    /// the non-strict form: it is satisfied by *any* recorded failure. That is
    /// not a detail. `assertContentStartsAtTheMargin` has a second, unrelated
    /// failure path — "too few measurable elements" — so breaking the walk badly
    /// enough to discard the whole tree made these tests pass, which is exactly
    /// the regression they exist to catch.
    private func expectingFailure(
        containing fragment: String,
        _ block: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains(fragment) }
        XCTExpectFailure(fragment, options: options, failingBlock: block)
    }

    // MARK: - The four shipped bugs, as trees

    /// Build 22: 430 points of content in a 402-point screen. A vertical scroll
    /// view centres cross-axis overflow, so both margins collapsed from 16 to 2.
    func testCollapsedMarginsFail() {
        let root = Fake.screen([
            Fake.text(x: 2, width: 398),
            Fake.text(x: 2, width: 200),
            Fake.text(x: 2, width: 150),
        ])
        expectingFailure(containing: "content starts 2.0pt from the safe edge") {
            assertContentStartsAtTheMargin(root, reference(), screen: "collapsed")
        }
    }

    /// A frame at `x = -10, width = 422` in a 402-point window.
    func testContentOutsideTheWindowFails() {
        let root = Fake.screen([Fake.text(x: -10, width: 422)])
        expectingFailure(containing: "the safe area starts at") {
            assertHorizontallyContained(root, reference(), screen: "overflowing")
        }
    }

    /// The mechanism: a child refusing the scroll view's proposed width.
    func testOverWideScrollChildFails() {
        let root = Fake.node(type: .scrollView, x: 0, width: 402, children: [
            Fake.node(type: .other, x: -14, width: 430, children: []),
        ])
        expectingFailure(containing: "pt scroll view") {
            assertScrollContentFits(root, reference())
        }
    }

    /// A rail put back inside the screen's padding, clipping 16 points short.
    func testRailShortOfTheEdgeFails() {
        let root = Fake.screen([
            Fake.node(type: .scrollView, x: 16, width: 370, identifier: "rail.up-next", children: []),
        ])
        // The identifier, not one of the two sentences: a rail inset on both
        // sides records a failure for each edge, and a matcher that accepts
        // only the leading one leaves the trailing one unexpected.
        expectingFailure(containing: "rail.up-next") {
            assertRailsReachTheEdge(root, reference())
        }
    }

    // MARK: - And the cases that must not fail

    func testAHealthyScreenPasses() {
        let root = Fake.screen([
            Fake.text(x: 16, width: 370),
            // A card's inner column, which is what defeated the earlier
            // "commonest leading edge" form of this check: five things at 140
            // against one at 16 made the mode measure the card.
            Fake.text(x: 140, width: 246),
            Fake.text(x: 140, width: 246),
            Fake.text(x: 140, width: 200),
            Fake.text(x: 140, width: 180),
            Fake.node(type: .scrollView, x: 0, width: 402, identifier: "rail.up-next", children: []),
        ])
        assertContentStartsAtTheMargin(root, reference(), screen: "healthy")
        assertHorizontallyContained(root, reference(), screen: "healthy")
        assertRailsReachTheEdge(root, reference())
    }

    /// A deliberate bleed is not a violation, and neither is anything inside it.
    func testDeliberateBleedIsNotAViolation() {
        // Three at the margin, because everything inside the rail is excluded
        // and the check refuses to name a margin from fewer than three samples.
        let root = Fake.screen([
            Fake.text(x: 16, width: 370),
            Fake.text(x: 16, width: 200),
            Fake.text(x: 16, width: 150),
            Fake.node(type: .scrollView, x: 0, width: 402, identifier: "rail.series", children: [
                Fake.text(x: -8, width: 120),
            ]),
        ])
        assertContentStartsAtTheMargin(root, reference(), screen: "bleed")
        assertHorizontallyContained(root, reference(), screen: "bleed")
    }

    /// The system's own chrome sits outside the window on purpose.
    ///
    /// The overlay is an `.image`, not an `.other`. As an `.other` this test
    /// proved nothing: that type is not in `measured`, so the assertion returned
    /// before `isSystemChrome` was ever consulted, and the test passed just as
    /// happily with that function deleted.
    func testSystemChromeIsIgnored() {
        let root = Fake.screen([
            Fake.text(x: 16, width: 370),
            Fake.node(type: .image, x: -120, width: 642,
                      identifier: "AdditionalDimmingOverlay", children: []),
        ])
        assertHorizontallyContained(root, reference(), screen: "chrome")
    }

    /// …and a node under one, which is the ancestry half of the same rule.
    func testContentInsideSystemChromeIsIgnored() {
        let root = Fake.screen([
            Fake.text(x: 16, width: 370),
            Fake.node(type: .other, x: 0, width: 402,
                      identifier: "UITransitionView", children: [
                          Fake.node(type: .image, x: -120, width: 642, children: []),
                      ]),
        ])
        assertHorizontallyContained(root, reference(), screen: "under-chrome")
    }

    /// iOS 26 hosts a `TabView`'s pages inside the tab bar's element, so
    /// skipping system subtrees on type alone discarded every signed-in screen.
    func testTabBarHostingContentIsWalked() {
        let root = Fake.node(type: .tabBar, x: 0, width: 402, children: [
            Fake.node(type: .other, x: 0, width: 402, identifier: "screen.library", children: [
                Fake.text(x: 2, width: 398),
                Fake.text(x: 2, width: 200),
                Fake.text(x: 2, width: 150),
            ]),
        ])
        expectingFailure(containing: "content starts 2.0pt from the safe edge") {
            assertContentStartsAtTheMargin(root, reference(), screen: "under-the-bar")
        }
    }

    /// Descending into the bar is not the same as measuring the bar.
    ///
    /// This is the hole that made the headline invariant fail open on every
    /// signed-in screen. Apple's tab-bar buttons are `.button`, carry no system
    /// identifier and have no `rail.` ancestor, so once the walk was inside the
    /// bar they went into the margin histogram beside this app's content — and
    /// a screen whose every element had drifted to 140 still passed, because one
    /// of Apple's buttons happened to sit at the margin.
    func testTabBarSystemButtonsAreNotMeasuredAsOurs() {
        let root = Fake.node(type: .tabBar, x: 0, width: 402, children: [
            // Apple's, at a healthy-looking edge.
            Fake.node(type: .button, x: 16, width: 60, children: []),
            Fake.node(type: .button, x: 96, width: 60, children: []),
            Fake.node(type: .button, x: 176, width: 60, children: []),
            // Ours, every one of them drifted.
            Fake.node(type: .other, x: 0, width: 402, identifier: "screen.library", children: [
                Fake.text(x: 140, width: 246),
                Fake.text(x: 140, width: 200),
                Fake.text(x: 140, width: 180),
            ]),
        ])
        expectingFailure(containing: "content starts 140.0pt from the safe edge") {
            assertContentStartsAtTheMargin(root, reference(), screen: "bar-buttons")
        }
    }

    /// …and the same shape, laid out correctly, still passes — so the fix above
    /// is a narrowing rather than a refusal to measure hosted screens at all.
    func testTabBarHostedContentAtTheMarginPasses() {
        let root = Fake.node(type: .tabBar, x: 0, width: 402, children: [
            Fake.node(type: .button, x: 300, width: 60, children: []),
            Fake.node(type: .other, x: 0, width: 402, identifier: "screen.library", children: [
                Fake.text(x: 16, width: 370),
                Fake.text(x: 16, width: 200),
                Fake.text(x: 16, width: 150),
            ]),
        ])
        assertContentStartsAtTheMargin(root, reference(), screen: "bar-healthy")
        assertHorizontallyContained(root, reference(), screen: "bar-healthy")
    }
}

/// A hand-built accessibility tree.
///
/// `@MainActor` throughout, like the invariants it feeds: `XCUIElementSnapshot`
/// is main-actor isolated in this SDK, and pretending otherwise only moves the
/// argument.
@MainActor
private enum Fake {
    static func screen(_ children: [XCUIElementSnapshot]) -> XCUIElementSnapshot {
        node(type: .other, x: 0, width: 402, identifier: "screen.test", children: children)
    }

    static func text(x: CGFloat, width: CGFloat) -> XCUIElementSnapshot {
        node(type: .staticText, x: x, width: width, children: [])
    }

    static func node(
        type: XCUIElement.ElementType,
        x: CGFloat,
        width: CGFloat,
        identifier: String = "",
        children: [XCUIElementSnapshot]
    ) -> XCUIElementSnapshot {
        Snapshot(
            elementType: type,
            identifier: identifier,
            frame: CGRect(x: x, y: 100, width: width, height: 20),
            children: children)
    }

    // `XCUIElementSnapshot` is not Sendable and this project builds with strict
    // concurrency, so the initialiser has to promise what the type already is:
    // three `let`s and an array of the same, built and read on one actor.
    private final class Snapshot: NSObject, XCUIElementSnapshot, @unchecked Sendable {
        let elementType: XCUIElement.ElementType
        let identifier: String
        let frame: CGRect
        let children: [any XCUIElementSnapshot]

        init(
            elementType: XCUIElement.ElementType, identifier: String,
            frame: CGRect, children: [any XCUIElementSnapshot]
        ) {
            self.elementType = elementType
            self.identifier = identifier
            self.frame = frame
            self.children = children
        }

        var propertyValues: [XCUIProtectedResource: Any] { [:] }
        var isSelected: Bool { false }
        var hasFocus: Bool { false }
        var isEnabled: Bool { true }
        var horizontalSizeClass: XCUIElement.SizeClass { .unspecified }
        var verticalSizeClass: XCUIElement.SizeClass { .unspecified }
        var value: Any? { nil }
        var placeholderValue: String? { nil }
        var label: String { "" }
        var title: String { "" }
        var parent: XCUIElementSnapshot? { nil }
        var dictionaryRepresentation: [XCUIElement.AttributeName: Any] { [:] }
        func suggestedHitpoints() -> [NSValue] { [] }
    }
}

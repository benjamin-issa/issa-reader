import XCTest

/// The rules a screen has to obey at every width, and the vocabulary for saying
/// which parts of a screen they apply to.
///
/// Four of this app's recent bugs were one bug: a subview with a rigid minimum
/// width larger than its container, or a margin that drifted from the token.
/// Every one was found by eye, on one simulator, after shipping. These are the
/// same checks, made automatic.
@MainActor
enum LayoutInvariants {
    /// Element classes an invariant applies to.
    ///
    /// A whitelist, deliberately. A `.scrollView` is entitled to be the full
    /// width of the window; the warm paper behind every screen is drawn with
    /// `.ignoresSafeArea()` and is *meant* to bleed; the system's own bars set
    /// their own margins and are not this app's to police.
    static let measured: Set<XCUIElement.ElementType> = [
        .staticText, .button, .image, .textField, .secureTextField, .searchField,
        .textView, .link, .slider, .switch, .stepper, .progressIndicator,
    ]

    /// Subtrees the app does not lay out, skipped whole rather than per element.
    /// A navigation bar's back chevron sits at 8 points on a phone and 20 on an
    /// iPad, and neither number is this app's to have an opinion about.
    static let system: Set<XCUIElement.ElementType> = [
        .navigationBar, .tabBar, .toolbar, .statusBar, .keyboard, .alert, .sheet,
    ]

    /// A container that hangs outside its parent on purpose, and says so.
    ///
    /// `BookRail`, `SeriesRail` and the shelf chips all remove the screen's
    /// padding and put it back as a content inset, precisely so a shelf that
    /// continues off screen reads as continuing rather than as cut off. That is
    /// why these identifiers are load-bearing rather than cosmetic: the sweep
    /// cannot infer the difference between that and a bug.
    static func isDeliberateBleed(_ identifier: String) -> Bool {
        identifier.hasPrefix("rail.")
            || identifier.hasPrefix("chips.")
            || identifier.hasSuffix(".fullBleed")
    }

    /// Chrome the system draws outside the window on purpose.
    ///
    /// `AdditionalDimmingOverlay` is 642 points wide in a 402-point window and
    /// starts at x = −120; it is UIKit's, not this app's, and reporting it as a
    /// layout failure teaches people to ignore the sweep.
    static let systemIdentifiers: Set<String> = [
        "AdditionalDimmingOverlay", "DimmingView", "PopoverDimmingView",
        "UITransitionView", "PlatterView",
    ]

    static func isSystemChrome(_ node: XCUIElementSnapshot, ancestry: [String]) -> Bool {
        systemIdentifiers.contains(node.identifier)
            || ancestry.contains(where: systemIdentifiers.contains)
    }

    /// Identifiers this app puts on its own screens and content columns.
    static func isOurs(_ identifier: String) -> Bool {
        identifier.hasPrefix("screen.") || identifier.hasPrefix("content.")
            || identifier.hasPrefix("grid.") || identifier.hasPrefix("cell.")
            || identifier.hasPrefix("rail.") || identifier.hasPrefix("chips.")
            || identifier.hasPrefix("field.") || identifier.hasPrefix("action.")
    }

    /// Whether anything this app labelled lives under this node.
    static func containsOurContent(_ node: XCUIElementSnapshot) -> Bool {
        if isOurs(node.identifier) { return true }
        return node.children.contains(where: containsOurContent)
    }

    /// Every node, depth first, carrying its ancestors' identifiers.
    ///
    /// A system subtree is skipped whole — a navigation bar's back chevron sits
    /// at 8 points on a phone and 20 on an iPad, and neither is this app's to
    /// have an opinion about — but only when it holds none of this app's own
    /// content. iOS 26 hosts a `TabView`'s pages *inside* the bar's element,
    /// so skipping on type alone discarded every signed-in screen and left the
    /// margin check with nothing to measure.
    static func walk(
        _ node: XCUIElementSnapshot,
        ancestry: [String] = [],
        visit: (XCUIElementSnapshot, [String]) -> Void
    ) {
        if system.contains(node.elementType), !containsOurContent(node) { return }
        visit(node, ancestry)
        let path = node.identifier.isEmpty ? ancestry : ancestry + [node.identifier]
        for child in node.children {
            walk(child, ancestry: path, visit: visit)
        }
    }

    static func describe(_ node: XCUIElementSnapshot) -> String {
        let id = node.identifier.isEmpty ? "" : " #\(node.identifier)"
        let label = node.label.isEmpty ? "" : " “\(node.label.prefix(40))”"
        return "\(node.elementType.rawValue)\(id)\(label)"
    }

    /// Whether this node is on screen at all vertically.
    ///
    /// Vertical only. A lazy container prepares cells beyond the viewport, and
    /// those cannot be wrong on a screen they are not on — but *horizontal*
    /// overflow is the thing under test, so it is never filtered.
    static func isOnScreen(_ frame: CGRect, in window: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.maxY > window.minY && frame.minY < window.maxY
    }

    static func first(
        in root: XCUIElementSnapshot, identifier: String
    ) -> XCUIElementSnapshot? {
        var found: XCUIElementSnapshot?
        walk(root) { node, _ in
            if found == nil, node.identifier == identifier { found = node }
        }
        return found
    }
}

@MainActor
extension XCTestCase {
    /// I1 and I2 — nothing wider than the window, nothing outside the safe area.
    ///
    /// This is the one that catches `x = -10, width = 422` in a 402-point
    /// window, and it reports both halves rather than leaving the reader of the
    /// failure to work out which it was.
    ///
    /// Collects every violation and fails once: one `XCTFail` per element turns
    /// a single regression into forty identical failures and buries the one
    /// that matters.
    func assertHorizontallyContained(
        _ root: XCUIElementSnapshot,
        _ reference: LayoutReference,
        screen: String,
        tolerance: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var failures: [String] = []
        LayoutInvariants.walk(root) { node, ancestry in
            guard LayoutInvariants.measured.contains(node.elementType) else { return }
            guard !ancestry.contains(where: LayoutInvariants.isDeliberateBleed) else { return }
            guard !LayoutInvariants.isSystemChrome(node, ancestry: ancestry) else { return }
            let frame = node.frame
            guard LayoutInvariants.isOnScreen(frame, in: reference.window) else { return }

            if frame.width > reference.window.width + tolerance {
                failures.append("""
                    \(LayoutInvariants.describe(node)) is \(frame.width)pt wide \
                    in a \(reference.window.width)pt window
                    """)
            }
            if frame.minX < reference.safe.minX - tolerance {
                failures.append("""
                    \(LayoutInvariants.describe(node)) starts at x=\(frame.minX); \
                    the safe area starts at \(reference.safe.minX)
                    """)
            }
            if frame.maxX > reference.safe.maxX + tolerance {
                failures.append("""
                    \(LayoutInvariants.describe(node)) ends at x=\(frame.maxX); \
                    the safe area ends at \(reference.safe.maxX)
                    """)
            }
        }
        if !failures.isEmpty {
            XCTFail(failures.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// I3 — the screen's content starts exactly one margin in.
    ///
    /// Two rules in one number, and the number is the *leftmost* content edge,
    /// not the commonest:
    ///
    /// - nothing starts left of the margin, which is the 430-in-402 bug (its
    ///   content sat at 2) and the `x = -10` one;
    /// - something starts *at* it, which catches a whole screen shifted right.
    ///
    /// The commonest edge was the first attempt and it is wrong on any screen
    /// built from cards: the Reading tab's Continue card has five left-aligned
    /// things inside it at 140 points, against one at the screen's own 16, so
    /// the mode measured the card and called a healthy screen broken. The
    /// histogram is still printed on failure, because it is what makes the
    /// answer obvious.
    func assertContentStartsAtTheMargin(
        _ root: XCUIElementSnapshot,
        _ reference: LayoutReference,
        screen: String,
        minimumSamples: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var edges: [CGFloat: Int] = [:]
        LayoutInvariants.walk(root) { node, ancestry in
            guard LayoutInvariants.measured.contains(node.elementType) else { return }
            guard !ancestry.contains(where: LayoutInvariants.isDeliberateBleed) else { return }
            guard !LayoutInvariants.isSystemChrome(node, ancestry: ancestry) else { return }
            let frame = node.frame
            guard LayoutInvariants.isOnScreen(frame, in: reference.window) else { return }
            edges[(frame.minX - reference.safe.minX).rounded(), default: 0] += 1
        }

        guard edges.values.reduce(0, +) >= minimumSamples, let leftmost = edges.keys.min()
        else {
            return XCTFail(
                "\(screen): too few measurable elements to establish a margin",
                file: file, line: line)
        }
        let histogram = edges.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        XCTAssertEqual(
            leftmost, reference.screenMargin, accuracy: 0.5,
            """
            \(screen): content starts \(leftmost)pt from the safe edge, not \
            Metrics.screenMargin (\(reference.screenMargin)pt). \
            Leading edges seen, with counts: \(histogram)
            """,
            file: file, line: line)
    }

    /// I3b — the declared content container's margins, both of them.
    ///
    /// Currently unused, and kept for the record rather than deleted. An
    /// accessibility container's frame is the *union of its children*, not a
    /// layout rect: a screen holding a rail that reaches the screen edge on
    /// purpose, or one showing an empty state that fills the window, reports
    /// the safe edges and this reads it as a collapsed margin. `content.*`
    /// identifiers earn their keep as a way to find a screen's primary column;
    /// they do not earn it as something to measure.
    ///
    /// Both sides deliberately. The 430-in-402 bug produced −14 on each; the
    /// leading edge alone would have caught it, but asserting both is what says
    /// at a glance that the content was *centred* rather than shifted.
    func assertContentMargins(
        _ root: XCUIElementSnapshot,
        identifier: String,
        _ reference: LayoutReference,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let content = LayoutInvariants.first(in: root, identifier: identifier) else {
            return XCTFail(
                "no \(identifier) — the screen has not declared its primary content",
                file: file, line: line)
        }
        // An accessibility container's frame is the union of its children, so a
        // screen holding a rail — which reaches the screen edge on purpose —
        // reports the safe edges rather than its own margin. Nothing is wrong
        // there; the question simply cannot be asked this way, and the mode of
        // leading edges answers it instead.
        var bleeds = false
        LayoutInvariants.walk(content) { node, _ in
            if LayoutInvariants.isDeliberateBleed(node.identifier) { bleeds = true }
        }
        guard !bleeds else { return }
        // x only: a scroll view's content runs off the top and bottom of the
        // window by design, and its height says nothing.
        XCTAssertEqual(
            content.frame.minX - reference.safe.minX, reference.screenMargin,
            accuracy: 0.5, "\(identifier) leading margin", file: file, line: line)
        XCTAssertEqual(
            reference.safe.maxX - content.frame.maxX, reference.screenMargin,
            accuracy: 0.5, "\(identifier) trailing margin", file: file, line: line)
    }

    /// I4 — no scroll child wider than its container.
    ///
    /// The direct check for the mechanism behind the worst of the four: a
    /// vertical scroll view proposes its own width to its content, and a child
    /// that refuses the proposal is *centred* — so a symmetric overflow shows
    /// up as symmetrically wrong margins rather than as clipping, which is why
    /// it took a photograph to notice.
    func assertScrollContentFits(
        _ root: XCUIElementSnapshot,
        tolerance: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var failures: [String] = []
        LayoutInvariants.walk(root) { node, _ in
            guard node.elementType == .scrollView || node.elementType == .collectionView else { return }
            // A horizontal rail is meant to overflow its own width, and a
            // snapshot carries no axis — which is why the identifier convention
            // has to carry it instead.
            guard !LayoutInvariants.isDeliberateBleed(node.identifier) else { return }
            let box = node.frame
            guard box.width > 1 else { return }
            for child in node.children where !LayoutInvariants.isDeliberateBleed(child.identifier) {
                let frame = child.frame
                guard frame.width > box.width + tolerance else { continue }
                failures.append("""
                    \(LayoutInvariants.describe(child)) is \(frame.width)pt inside a \
                    \(box.width)pt scroll view — overhanging \(box.minX - frame.minX)pt leading \
                    and \(frame.maxX - box.maxX)pt trailing. A vertical scroll view centres \
                    cross-axis overflow, so this is a collapsed margin on every screen it \
                    appears on.
                    """)
            }
        }
        if !failures.isEmpty {
            XCTFail(failures.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// I5 — the inverse: what is meant to reach the edge does.
    ///
    /// The third shipped bug, stated as a rule. A rail put back inside the
    /// screen's padding clips 16 points short of the glass, and a shelf that
    /// continues off screen then looks like one that was cut off.
    func assertRailsReachTheEdge(
        _ root: XCUIElementSnapshot,
        _ reference: LayoutReference,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        LayoutInvariants.walk(root) { node, _ in
            guard node.identifier.hasPrefix("rail.") || node.identifier.hasPrefix("chips.") else { return }
            guard LayoutInvariants.isOnScreen(node.frame, in: reference.window) else { return }
            XCTAssertEqual(
                node.frame.minX, reference.safe.minX, accuracy: 0.5,
                "\(node.identifier) starts \(node.frame.minX - reference.safe.minX)pt in from the edge",
                file: file, line: line)
            XCTAssertEqual(
                node.frame.maxX, reference.safe.maxX, accuracy: 0.5,
                "\(node.identifier) stops \(reference.safe.maxX - node.frame.maxX)pt short of the edge",
                file: file, line: line)
        }
    }
}

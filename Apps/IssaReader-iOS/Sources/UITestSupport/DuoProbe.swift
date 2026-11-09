#if ISSA_UITEST_FIXTURE
import IssaUI
import SwiftUI

/// What the system says about the window, for the iPhone Duo tests: the size
/// classes, which edge the bars run down, the window's safe area and the
/// reserved regions (the fold and the sensor bar), all in window coordinates.
///
/// Read out of the running app for the reason `LayoutProbe` is: a test that
/// wrote the Duo's 466 or its fold at 475 into its own source would be a second
/// copy of what the system decides, and it is the system's answer the layout
/// has to follow.
///
/// Invisible and one point square, so it changes nothing it measures; the
/// geometry is read by a window-sized reader behind it.
struct DuoProbe: View {
    let identifier: String
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("duo probe")
                .accessibilityValue(reading(proxy))
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func reading(_ proxy: GeometryProxy) -> String {
        var parts = [
            "h=\(name(horizontal))", "v=\(name(vertical))",
            "size=\(Int(proxy.size.width))x\(Int(proxy.size.height))",
        ]
        let safe = ReaderInsets.current()
        parts.append("safe=\(Int(safe.top)),\(Int(safe.leading)),\(Int(safe.bottom)),\(Int(safe.trailing))")
        if #available(iOS 27.1, *) {
            parts.append(Self.regions(proxy))
        }
        return parts.joined(separator: ";")
    }

    @available(iOS 27.1, *)
    private static func regions(_ proxy: GeometryProxy) -> String {
        func list(_ kind: ReservedRegion.Kind) -> String {
            proxy.reservedRegions(kind: kind, options: [.includeInactive])
                .map { region in
                    let f = region.frame
                    return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)),"
                        + (region.isActive ? "on" : "off")
                }
                .joined(separator: "|")
        }
        return "div=\(list(.division));occ=\(list(.occlusion))"
    }

    private func name(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "none"
        }
    }
}

/// Both probes, named for where they stand: `probe.duo.<scope>` and
/// `probe.bars.<scope>`.
struct DuoProbes: View {
    let scope: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            DuoProbe(identifier: "probe.duo.\(scope)")
            if #available(iOS 27.1, *) {
                DuoBarsProbe(identifier: "probe.bars.\(scope)")
            }
        }
    }
}

/// The edge the system runs the bars down, where it can say. A view of its own
/// because the environment value exists only from iOS 27.1.
@available(iOS 27.1, *)
struct DuoBarsProbe: View {
    let identifier: String
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("duo bars probe")
            .accessibilityValue(edge.map { $0 == .leading ? "leading" : "trailing" } ?? "top")
            .allowsHitTesting(false)
    }
}
#endif

import XCTest

/// The rectangles every invariant measures against, read out of the app.
///
/// Never `XCUIScreen`: it has no `bounds`, its screenshot size is in pixels,
/// and on an iPad the app's window is not necessarily the screen. Element
/// frames are reported in points in the same space as the window's frame, so
/// the window is the only reference that is always right.
@MainActor
struct LayoutReference {
    /// The app's window, in points.
    let window: CGRect
    /// The window inset by the device's own unsafe edges. Zero on a phone in
    /// portrait; 59 points a side on a notched phone in landscape.
    let safe: CGRect
    /// `Metrics.screenMargin`, as the app itself computed it.
    ///
    /// Read from the running app rather than written here. A test with its own
    /// copy of the token is a second place for the token to live, and "a margin
    /// drifted from the token" is the exact class of bug this sweep exists to
    /// catch — so a duplicated literal is how it happens again, one layer down.
    let screenMargin: CGFloat

    static func read(from app: XCUIApplication, timeout: TimeInterval = 30) throws -> LayoutReference {
        let window = app.windows.element(boundBy: 0)
        guard window.waitForExistence(timeout: timeout) else {
            throw LayoutError.noWindow
        }
        let probe = app.otherElements["probe.layout"]
        guard probe.waitForExistence(timeout: timeout), let raw = probe.value as? String else {
            throw LayoutError.noProbe
        }

        // "margin=16.0;left=0.0;right=0.0"
        //
        // Every field is required, and a malformed one throws. The parse used
        // to `continue` past anything it could not read and then fall back to
        // `?? 16` and `?? 0`, which degraded silently into the worst possible
        // state: a reference claiming the safe area is the whole window, and a
        // margin token hardcoded in the very file whose doc comment above
        // argues against a second copy of it. Every invariant then passed
        // while measuring nothing — a green sweep that had checked the app
        // against numbers the app no longer used.
        var fields: [String: CGFloat] = [:]
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let value = Double(parts[1]) else {
                throw LayoutError.unreadableProbe(raw)
            }
            fields[String(parts[0])] = CGFloat(value)
        }
        guard let margin = fields["margin"],
              let left = fields["left"],
              let right = fields["right"]
        else { throw LayoutError.unreadableProbe(raw) }

        let box = window.frame
        let safe = CGRect(
            x: box.minX + left,
            y: box.minY,
            width: box.width - left - right,
            height: box.height)
        return LayoutReference(window: box, safe: safe, screenMargin: margin)
    }
}

enum LayoutError: Error, CustomStringConvertible {
    case noWindow
    case noProbe
    case unreadableProbe(String)

    var description: String {
        switch self {
        case .noWindow: "The app never showed a window."
        case .noProbe:
            """
            The app published no probe.layout. Either -IssaUITestFixture was not \
            passed, or this build has ISSA_UITEST_FIXTURE compiled out.
            """
        case let .unreadableProbe(raw):
            """
            probe.layout published "\(raw)", which is not margin=…;left=…;right=… \
            with all three present. Failing rather than assuming a default: a \
            guessed margin makes every invariant pass against a number the app \
            does not use.
            """
        }
    }
}

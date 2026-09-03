import Foundation

/// Somewhere to show the server's own approval page.
///
/// Deliberately has no success case. The server has never heard of this app and
/// will not redirect back to it, so the only thing a browser can report is that
/// it closed. Whether the sign-in worked is the poll's business.
public protocol ApprovalBrowsing: Sendable {
    func present(_ url: URL) async -> BrowserDismissal
}

public enum BrowserDismissal: Sendable, Equatable {
    /// The reader closed it, or declined the "share your Safari login" alert.
    /// Those arrive as the same error code and cannot be told apart.
    case byUser
    /// The app closed it, because the poll had already won.
    case byApp
    case couldNotOpen(String)
}

public enum BrowserApprovalOutcome: Sendable, Equatable {
    case granted(String)
    case denied
    case expired
    /// The window closed without an answer.
    case dismissed
    case failed(String)
}

/// Sign-in through the server's own login page, in the system browser.
///
/// The device grant does the work; the browser is only a place for the reader to
/// prove who they are. That is what makes this route carry every identity
/// provider the server admin configured without this client implementing an
/// OIDC client — the page is the server's, and the app never sees it.
///
/// The browser lives behind `ApprovalBrowsing` so the hard part, which is the
/// race between the poll and the window, is testable without
/// AuthenticationServices and without a clock.
public struct BrowserSignInFlow: Sendable {
    public enum Progress: Sendable, Equatable {
        case awaitingApproval
        case finishing
    }

    private let transport: any DeviceGrantTransport
    private let browser: any ApprovalBrowsing
    private let pollsAfterDismissal: Int

    public init(
        transport: any DeviceGrantTransport,
        browser: any ApprovalBrowsing,
        pollsAfterDismissal: Int = 3
    ) {
        self.transport = transport
        self.browser = browser
        self.pollsAfterDismissal = pollsAfterDismissal
    }

    public func run(reporting report: @escaping @Sendable (Progress) -> Void) async -> BrowserApprovalOutcome {
        let authorization: DeviceAuthorization
        do {
            authorization = try await transport.start()
        } catch {
            IssaLog.failure("browser sign-in start", error)
            return .failed(AppFacingError.text(for: error))
        }

        // Server-supplied and therefore untrusted: `URL(string:)` will build
        // `javascript:` or `shortcuts:` just as happily as `https:`.
        guard let url = authorization.approvalURL, url.isWebLink else {
            return .failed("""
                Your server didn't give the app a web address to open. \
                Try a pairing code instead.
                """)
        }

        let flow = DeviceGrantFlow(transport: transport)
        report(.awaitingApproval)

        enum Leg: Sendable {
            case poll(DeviceGrantOutcome)
            case browser(BrowserDismissal)
        }

        let first: Leg = await withTaskGroup(of: Leg.self) { group in
            group.addTask { .poll(await flow.awaitApproval(for: authorization)) }
            group.addTask { .browser(await browser.present(url)) }
            guard let first = await group.next() else { return .browser(.byUser) }
            // Whoever lost is told to stop. For the browser leg that is the only
            // way a Safari sheet comes off the screen from code; the group then
            // waits for it, so the sheet is provably gone before a token is
            // handed up and the library appears underneath it.
            group.cancelAll()
            return first
        }

        switch first {
        case let .poll(outcome):
            return Self.map(outcome)
        case let .browser(.couldNotOpen(reason)):
            return .failed(reason)
        case .browser(.byApp):
            // Unreachable: only this flow sends `byApp`, and only after the poll
            // has already returned.
            return .dismissed
        case .browser(.byUser):
            report(.finishing)
            return await collectAfterDismissal(authorization)
        }
    }

    /// A few more polls after the window closes.
    ///
    /// The reader who taps Approve and *then* closes the window has already been
    /// granted a token — the server records the approval whether the browser is
    /// still open or not — and dropping it there would be the most annoying
    /// possible failure. Spelled out here rather than reusing `awaitApproval`,
    /// because the semantics differ: this loop is not waiting for a person, it is
    /// collecting an answer that probably already exists, and it must stop in
    /// seconds rather than at the server's fifteen-minute deadline.
    ///
    /// Counted in polls rather than wall-clock, for the reason `DeviceGrantFlow`
    /// gives: it keeps the loop deterministic under a scripted transport. The
    /// wait before each attempt is not optional — this server answers
    /// `slow_down` to any poll arriving inside `interval`.
    private func collectAfterDismissal(_ authorization: DeviceAuthorization) async -> BrowserApprovalOutcome {
        let interval = Double(max(authorization.interval, 1))
        for _ in 0 ..< pollsAfterDismissal {
            await transport.wait(seconds: interval)
            if Task.isCancelled { return .dismissed }
            switch await transport.poll(deviceCode: authorization.deviceCode) {
            case let .token(token): return .granted(token)
            case .error(.accessDenied): return .denied
            case .error(.expiredToken): return .expired
            case .error, .transportFailure: continue
            }
        }
        return .dismissed
    }

    static func map(_ outcome: DeviceGrantOutcome) -> BrowserApprovalOutcome {
        switch outcome {
        case let .granted(token): .granted(token)
        case .denied: .denied
        case .expired: .expired
        // What `awaitApproval` returns when the task group cancels it, which
        // happens only when the browser leg won the race.
        case .cancelled: .dismissed
        case let .failed(reason): .failed(reason)
        }
    }
}

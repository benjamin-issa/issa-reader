import IssaCore
import Observation
import SwiftUI

/// Runs the device authorization grant and exposes it to SwiftUI.
@Observable
@MainActor
public final class DeviceSignInModel {
    public enum Stage: Equatable {
        case starting
        case awaitingApproval(DeviceAuthorization)
        case granted(String)
        case failed(String)
    }

    public private(set) var stage: Stage = .starting
    /// When the code on screen was issued, so the view can count down to the
    /// moment it lapses.
    public private(set) var issuedAt: Date?
    /// True while a lapsed code is being replaced, which the view says out loud
    /// rather than leaving a stale code under a spinner.
    public private(set) var isRenewing = false

    private let serverURL: URL
    private var pollTask: Task<Void, Never>?
    private var renewals = 0

    /// A code lives 15 minutes on a default server, so this is about two hours
    /// of an abandoned sign-in screen. Past that, stop asking the server.
    private static let maxRenewals = 8

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// The moment the code on screen stops being accepted.
    public var expiresAt: Date? {
        guard case let .awaitingApproval(auth) = stage, let issuedAt else { return nil }
        return issuedAt.addingTimeInterval(TimeInterval(auth.expiresIn))
    }

    public func begin() async {
        // A renewal replaces an in-flight poll; leaving the old one running
        // would have two loops polling two codes at once.
        pollTask?.cancel()
        pollTask = nil

        let transport = HTTPDeviceGrantTransport(baseURL: serverURL)
        let flow = DeviceGrantFlow(transport: transport)
        do {
            let authorization = try await flow.begin()
            stage = .awaitingApproval(authorization)
            issuedAt = .now
            isRenewing = false
            pollTask = Task { [weak self] in
                let outcome = await flow.awaitApproval(for: authorization)
                guard let self else { return }
                await self.finish(outcome)
            }
        } catch {
            IssaLog.failure("device sign-in", error, ["server": serverURL.absoluteString])
            isRenewing = false
            stage = .failed(AppModel.message(for: error))
        }
    }

    /// What the poll loop's answer means for the screen.
    ///
    /// Expiry is the interesting one. The lifetime is the server's — the start
    /// call takes no parameters, so a client cannot ask for longer — and
    /// stranding someone on "Couldn't sign in / Back" for the crime of walking
    /// away for a quarter of an hour is the wrong answer to that. Instead the
    /// code is replaced where it stands and polling carries on, so a lapsed
    /// code becomes a number changing on screen rather than a failure.
    private func finish(_ outcome: DeviceGrantOutcome) async {
        switch outcome {
        case let .granted(token): stage = .granted(token)
        case .denied: stage = .failed("Sign-in was denied.")
        case .cancelled: break
        case .expired:
            guard renewals < Self.maxRenewals else {
                stage = .failed("The code expired. Try again.")
                return
            }
            renewals += 1
            isRenewing = true
            IssaLog.info("device code renewed", ["attempt": String(renewals)])
            await begin()
        case let .failed(reason): stage = .failed(reason)
        }
    }

    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }
}

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
    private let serverURL: URL
    private var pollTask: Task<Void, Never>?

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    public func begin() async {
        let transport = HTTPDeviceGrantTransport(baseURL: serverURL)
        let flow = DeviceGrantFlow(transport: transport)
        do {
            let authorization = try await flow.begin()
            stage = .awaitingApproval(authorization)
            pollTask = Task { [weak self] in
                let outcome = await flow.awaitApproval(for: authorization)
                await MainActor.run {
                    guard let self else { return }
                    switch outcome {
                    case let .granted(token): self.stage = .granted(token)
                    case .denied: self.stage = .failed("Sign-in was denied.")
                    case .expired: self.stage = .failed("The code expired. Try again.")
                    case let .failed(reason): self.stage = .failed(reason)
                    }
                }
            }
        } catch {
            stage = .failed(AppModel.message(for: error))
        }
    }

    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The URL a person opens to approve. Prefer the pre-identified one.
    public var approvalURL: URL? {
        guard case let .awaitingApproval(auth) = stage else { return nil }
        return URL(string: auth.verificationURIComplete ?? auth.verificationURI)
    }
}

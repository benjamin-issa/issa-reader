#if !os(tvOS)
import AuthenticationServices
import Foundation
import IssaAsk
import IssaCore
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Runs OpenAI's Sign in with ChatGPT OAuth 2.0 + PKCE flow in the system
/// browser (`ASWebAuthenticationSession`) backed by an ephemeral loopback
/// listener on `127.0.0.1:<port>/auth/callback`.
///
/// OpenAI's `dynamic_agent_client` requires an explicit `http://127.0.0.1`
/// loopback `redirect_uri`. Once OpenAI redirects there, the listener captures
/// the authorization `code`, `state` and issued `client_id` (`oaiapp_…`) and
/// replies with `302 Found` to `issareader://openai-auth/done`, which causes
/// `ASWebAuthenticationSession` to dismiss itself cleanly on both iOS and macOS.
@MainActor
final class OpenAIBrowserAuth {
    private static let completionScheme = "issareader"
    private static let completionRedirect = "issareader://openai-auth/done"

    func signIn(hostID: String, existingClientID: String?) async throws(OpenAIOAuth.Failure) -> OpenAIOAuthSession {
        let server: LoopbackCallbackServer
        let port: UInt16
        do {
            server = LoopbackCallbackServer(
                expectedPath: OpenAIOAuth.callbackPath,
                completionRedirect: Self.completionRedirect,
            )
            port = try await server.start()
        } catch {
            IssaLog.error("openai oauth loopback listener failed", [
                "reason": String(describing: error),
            ])
            throw .couldNotStartListener
        }
        defer { Task { await server.stop() } }

        let request = OpenAIOAuth.AuthorizationRequest.make(
            port: port,
            hostID: hostID,
            existingClientID: existingClientID,
        )

        let sessionController = AuthSessionController(callbackScheme: Self.completionScheme)
        let authURL = request.url
        let callbackURL: URL
        do {
            callbackURL = try await Self.awaitCallback(
                authURL: authURL,
                server: server,
                controller: sessionController,
            )
        } catch let failure as OpenAIOAuth.Failure {
            sessionController.close()
            throw failure
        } catch {
            sessionController.close()
            throw .cancelled
        }

        let callback = try OpenAIOAuth.parseCallback(
            url: callbackURL,
            expectedState: request.state,
            existingClientID: existingClientID,
        )
        return try await OpenAIOAuth.exchangeCode(callback, request: request)
    }

    private nonisolated static func awaitCallback(
        authURL: URL,
        server: LoopbackCallbackServer,
        controller: AuthSessionController,
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                try await server.waitForCallback()
            }
            group.addTask {
                let dismissal = await controller.present(authURL)
                switch dismissal {
                case .completed, .byApp:
                    return nil
                case .byUser:
                    throw OpenAIOAuth.Failure.cancelled
                case let .couldNotOpen(reason):
                    throw OpenAIOAuth.Failure.couldNotOpenBrowser(reason)
                }
            }

            var received: URL?
            while let next = try await group.next() {
                if let url = next {
                    received = url
                    await controller.closeSoon()
                    group.cancelAll()
                    break
                }
            }
            guard let received else {
                throw OpenAIOAuth.Failure.cancelled
            }
            return received
        }
    }
}

// MARK: - ASWebAuthenticationSession controller

@MainActor
private final class AuthSessionController: NSObject {
    enum Dismissal: Sendable {
        case completed
        case byUser
        case byApp
        case couldNotOpen(String)
    }

    private let callbackScheme: String
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<Dismissal, Never>?
    private var closedByApp = false

    init(callbackScheme: String) {
        self.callbackScheme = callbackScheme
    }

    func present(_ url: URL) async -> Dismissal {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme),
                ) { @Sendable [weak self] callback, error in
                    // Keep the completion handler `@Sendable` and nonisolated
                    // (see `BrowserSignIn.swift`): on macOS this callback lands
                    // on an XPC reply queue, not the main actor.
                    let dismissal = Self.mapOutcome(callback: callback, error: error)
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(dismissal ?? (self.closedByApp ? .byApp : .byUser))
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session

                guard Self.hasPresentableWindow else {
                    finish(.couldNotOpen("There is no window to show ChatGPT's sign-in page in."))
                    return
                }
                guard session.start() else {
                    finish(.couldNotOpen("Couldn't open ChatGPT's sign-in page. Try again."))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    nonisolated private static func mapOutcome(callback: URL?, error: (any Error)?) -> Dismissal? {
        if callback != nil { return .completed }
        guard let error else { return nil }
        let ns = error as NSError
        guard ns.domain == ASWebAuthenticationSessionErrorDomain,
              let code = ASWebAuthenticationSessionError.Code(rawValue: ns.code)
        else {
            return .couldNotOpen("Couldn't open ChatGPT's sign-in page. Try again.")
        }
        switch code {
        case .presentationContextNotProvided, .presentationContextInvalid:
            return .couldNotOpen("This window couldn't open ChatGPT's sign-in page.")
        default:
            return nil
        }
    }

    func closeSoon() async {
        try? await Task.sleep(for: .milliseconds(250))
        close()
    }

    func close() {
        closedByApp = true
        session?.cancel()
        session = nil
        finish(.byApp)
    }

    private func finish(_ dismissal: Dismissal) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: dismissal)
    }

    private static var hasPresentableWindow: Bool {
        #if os(macOS)
        return NSApplication.shared.keyWindow != nil || !NSApplication.shared.windows.isEmpty
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            .map { $0.keyWindow != nil || !$0.windows.isEmpty } ?? false
        #endif
    }
}

extension AuthSessionController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        if let window = scene?.keyWindow ?? scene?.windows.first { return window }
        if let scene { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Ephemeral 127.0.0.1 loopback callback server

/// Tiny single-shot HTTP server bound strictly to `127.0.0.1:<ephemeral-port>`.
/// Never opens a LAN socket and tears itself down as soon as the OAuth callback
/// arrives or sign-in is cancelled.
private actor LoopbackCallbackServer {
    enum ServerError: Error {
        case failedToStart
        case cancelled
    }

    private let expectedPath: String
    private let completionRedirect: String
    private let queue = DispatchQueue(label: "issa.ask.openai.loopback")
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var capturedURL: URL?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?

    init(expectedPath: String, completionRedirect: String) {
        self.expectedPath = expectedPath
        self.completionRedirect = completionRedirect
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = OnceContinuation(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let raw = listener.port?.rawValue, raw != 0 {
                        box.resume(returning: raw)
                    } else {
                        box.resume(throwing: ServerError.failedToStart)
                    }
                case let .failed(error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: ServerError.cancelled)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: queue)
        }
        boundPort = port
        return port
    }

    func waitForCallback() async throws -> URL {
        if let capturedURL { return capturedURL }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let capturedURL {
                    continuation.resume(returning: capturedURL)
                } else {
                    callbackContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(throwing: ServerError.cancelled)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let target = data.flatMap(Self.parseRequestTarget)
            Task {
                await self.respond(target: target, on: connection)
            }
        }
    }

    private func respond(target: String?, on connection: NWConnection) {
        guard let target,
              let fullURL = URL(string: "http://127.0.0.1:\(boundPort)\(target)"),
              fullURL.path == expectedPath
        else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let body = "<!doctype html><meta charset=utf-8><title>Signed in</title><p>Signed in. Returning to Issa Reader…</p>"
        let response =
            "HTTP/1.1 302 Found\r\n"
            + "Location: \(completionRedirect)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
            + body

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        capturedURL = fullURL
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(returning: fullURL)
        }
    }

    private nonisolated static func parseRequestTarget(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first
                ?? text.split(separator: "\n", maxSplits: 1).first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }
}

private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let taken = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            let current = continuation
            continuation = nil
            return current
        }
        taken?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let taken = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            let current = continuation
            continuation = nil
            return current
        }
        taken?.resume(throwing: error)
    }
}
#endif

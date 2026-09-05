import AuthenticationServices
import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What the browser sign-in makes of the SDK's completion handler.
///
/// This exists because of a crash, and it is worth being exact about what it
/// does and does not prove. Build 28 died on the Mac the instant anyone pressed
/// **Continue in browser**: the completion closure was written inside a
/// `@MainActor` class and so inherited that isolation, Swift 6 verifies the
/// assumption at the closure's *entry*, and macOS delivers the outcome on the
/// Safari launch agent's XPC reply queue. `EXC_BREAKPOINT`, before a line of
/// the body ran — and on the path where the sign-in had *succeeded* and the
/// callback was being handed back, not on any failure.
///
/// **The mapping below is not what crashed, and these cases cannot catch that
/// crash.** A surviving isolation trap aborts the whole test runner rather than
/// failing a case. What they pin is the part that had to move to make the fix
/// possible — the decision, lifted out of the closure and off the actor — and
/// one behaviour that was wrong on its own account: an error from outside the
/// session's own domain used to be reported as the reader closing the window.
@Suite("Reading the browser sign-in's outcome")
struct BrowserOutcomeTests {
    private static func asError(_ code: ASWebAuthenticationSessionError.Code) -> NSError {
        NSError(domain: ASWebAuthenticationSessionErrorDomain, code: code.rawValue)
    }

    @Test("a callback is the callback, whatever else arrived with it")
    func callbackWins() {
        let url = URL(string: "storyteller://settings?token=abc")!
        #expect(BrowserApprovalController.outcome(callback: url, error: nil) == .completed(url))
        // The SDK does not hand back both, but if it ever did the token is the
        // thing that matters.
        #expect(
            BrowserApprovalController.outcome(
                callback: url, error: Self.asError(.canceledLogin)) == .completed(url))
    }

    /// `nil` is deliberate and load-bearing: closing the window is the one
    /// answer this function cannot give, because `closedByApp` is main-actor
    /// state. Returning `.byUser` here would report the app's own `cancel()` —
    /// which arrives as this very code — as the reader walking away.
    @Test("a cancelled login is left for the caller to attribute")
    func cancelledLoginIsUnattributed() {
        #expect(BrowserApprovalController.outcome(
            callback: nil, error: Self.asError(.canceledLogin)) == nil)
    }

    @Test(
        "a context the SDK will not present says so, and offers the way out",
        arguments: [
            ASWebAuthenticationSessionError.Code.presentationContextNotProvided,
            ASWebAuthenticationSessionError.Code.presentationContextInvalid,
        ])
    func presentationFailuresExplainThemselves(_ code: ASWebAuthenticationSessionError.Code) throws {
        let outcome = BrowserApprovalController.outcome(callback: nil, error: Self.asError(code))
        guard case let .couldNotOpen(reason) = try #require(outcome) else {
            Issue.record("a presentation failure is not the reader's doing")
            return
        }
        #expect(reason.contains("code"), "and names the other way in: \(reason)")
    }

    /// The behavioural regression, separate from the crash. Anything that was
    /// not the session's own error fell into the same `default:` as
    /// `canceledLogin` and came back as "the reader closed the window" — which
    /// then showed them a note asking whether they had declined a Safari alert
    /// they were never shown. On the Mac that is the *likely* path, since the
    /// dry run refuses through some other domain entirely.
    @Test("an error from anywhere else is not the reader closing a window")
    func foreignErrorIsNotADismissal() throws {
        let outcome = BrowserApprovalController.outcome(
            callback: nil, error: URLError(.notConnectedToInternet))
        guard case .couldNotOpen = try #require(outcome, "must not be reported as a dismissal")
        else {
            Issue.record("a foreign error was attributed to the reader")
            return
        }
    }

    /// Structural, and the reason any of this moved. `outcome` is
    /// `nonisolated static`: put the isolation back and this stops compiling,
    /// which is the red we want — the closure that calls it must be able to run
    /// on whatever queue AuthenticationServices happens to use.
    @Test("the decision is reachable from off the main actor")
    func decidableOffTheMainActor() async {
        let url = URL(string: "storyteller://settings?token=abc")!
        let outcome = await Task.detached {
            BrowserApprovalController.outcome(callback: url, error: nil)
        }.value
        #expect(outcome == .completed(url))
    }
}

import IssaCore

/// What one iPhone or iPad window shows for the app's phase, decided in one
/// place a test can ask.
///
/// The three signed-out phases are one screen. "Sign in again" on the
/// session-ended notice moves the phase from `.expired` through `.signingIn`
/// to `.chooseServer` while its own task is still running; when `.expired`
/// had a branch of its own, SwiftUI built a fresh `SignInView` at the first
/// step and the browser route the tap went on to set was written into the
/// state of a view that no longer existed. 1.3.0 grouped all three, and so
/// does this.
///
/// And the books from Files are that screen's alternative in every one of
/// those phases, the session-ended notice included — its "Read a book from
/// your files" sets the same flag the form's does, which the `.expired`
/// branch never read, so the link did nothing there and the flag then took
/// over the next sign-in instead.
enum RootScreen: Equatable {
    case launching
    case signIn
    case localBooks
    case library

    static func `for`(phase: AppModel.Phase, showsListSignedOut: Bool) -> RootScreen {
        switch phase {
        case .launching: .launching
        case .chooseServer, .signingIn, .expired: showsListSignedOut ? .localBooks : .signIn
        case .ready: .library
        }
    }
}

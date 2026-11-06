import XCTest

extension XCUIApplication {
    /// Back one page: the navigation bar's back button, or where the system
    /// runs its bars down a side (iPhone Duo) and the button is not in a
    /// navigation bar to find, the edge swipe that pops the same page.
    @MainActor
    func goBack() {
        let barBack = navigationBars.buttons.firstMatch
        if barBack.exists {
            barBack.tap()
        } else {
            coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
    }
}

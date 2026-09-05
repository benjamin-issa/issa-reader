import Foundation
import Testing

@testable import IssaReader_iOS

/// Proof that this bundle reaches Apps/Shared, which is the reason it exists.
@Suite("AppModel is reachable from a test", .serialized)
@MainActor
struct AppModelReachabilityTests {
    @Test("the app model can be built and reports its launch phase")
    func buildsAnAppModel() {
        let app = AppModel()
        #expect(app.phase == .launching, "a fresh model has not connected to anything yet")
        #expect(app.books.isEmpty)
    }
}

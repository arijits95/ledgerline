@testable import Ledgerline
import Testing

@MainActor
struct LedgerlineTests {
    @Test func contentViewBuilds() {
        _ = ContentView().body
    }
}

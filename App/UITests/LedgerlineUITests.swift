import XCTest

final class LedgerlineUITests: XCTestCase {
    @MainActor
    func testLaunchShowsEmptyState() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Ledgerline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No groups yet"].exists)
    }
}

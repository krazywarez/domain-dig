import XCTest

@MainActor
final class RecentSearchesTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Run one recent search, clear the results, then pick a different one.
    /// The second pick must run the domain that was tapped, not the one run
    /// before it.
    func testTappingARecentSearchRunsThatDomain() {
        let app = AccessibilityAuditHarness.launch(recentSearches: true)
        app.selectRootTab("Inspect")

        let field = app.textFields["e.g. cleberg.net"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        app.buttons["Look up healthy.example"].tap()
        XCTAssertEqual(field.value as? String, "healthy.example")

        let clear = app.buttons["Cancel lookup"].exists ? app.buttons["Cancel lookup"] : app.buttons["Clear results"]
        clear.tap()

        let next = app.buttons["Look up broken.example"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()

        XCTAssertEqual(field.value as? String, "broken.example")
    }
}

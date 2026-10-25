import XCTest

/// Captures the Phase-6 visual-pass evidence as result-bundle attachments:
/// the seeded dense screens in Light and Dark, and again at an accessibility
/// text size. Driven from XCUITest (not `simctl`) for two reasons proven during
/// this pass: the seed fixtures only populate under the test harness's launch,
/// and `xcrun simctl ui appearance` does not propagate to a headless-booted
/// simulator — so appearance is switched through the app's own Settings →
/// Display picker, exercising the real code path.
///
/// **This is a capture utility, not a pass/fail test.** Every step is
/// best-effort and never asserts: a control it cannot reach on a given runtime
/// simply yields no screenshot, so adding it to the audit suite can never gate
/// CI. Run with an explicit `-resultBundlePath` and export the attachments.
@MainActor
final class AccessibilityScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// Dashboard, Watchlist, and batch results in Light then Dark.
    func testLightAndDarkScreens() {
        let app = AccessibilityAuditHarness.launch(seeded: true)

        for appearance in ["Light", "Dark"] {
            guard setAppearance(app, to: appearance) else { continue }
            captureSeededScreens(app, suffix: appearance.lowercased())
        }
    }

    /// The same seeded screens at the largest accessibility text size, where
    /// reflow and clipping surface. Launched fresh with the content-size arg.
    func testAccessibilityTextSizeScreens() {
        let app = AccessibilityAuditHarness.launch(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL",
            seeded: true
        )
        captureSeededScreens(app, suffix: "axxxl")
    }

    // MARK: Capture (best-effort)

    private func captureSeededScreens(_ app: XCUIApplication, suffix: String) {
        app.selectRootTab("Dashboard")
        _ = app.buttons["Refresh all tracked domains"].waitForExistence(timeout: 5)
        attach(app, name: "dashboard-\(suffix)")

        let watchlist = app.buttons["Watchlist"]
        if watchlist.waitForExistence(timeout: 5) {
            watchlist.tap()
            _ = element(app, labelled: "healthy.example").waitForExistence(timeout: 5)
            attach(app, name: "watchlist-\(suffix)")
            // Pop the push, so a later pass's Dashboard capture is the
            // Dashboard rather than this view again.
            app.selectRootTab("Dashboard")
        }

        app.selectRootTab("Inspect")
        _ = element(app, labelled: "broken.example").waitForExistence(timeout: 5)
        attach(app, name: "batch-\(suffix)")
    }

    private func element(_ app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Appearance (best-effort; returns whether it switched)

    /// Drives Settings → Display → Appearance to the given option. The `Picker`
    /// renders as an inline `.menu` whose trigger is labelled
    /// "Appearance, <current value>". Returns `false` (rather than failing) if
    /// any step is unreachable on this runtime.
    private func setAppearance(_ app: XCUIApplication, to option: String) -> Bool {
        // A prior step may have left the Settings tab on a pushed view.
        // Re-selecting the active tab pops it back to root.
        app.selectRootTab("Settings")
        let display = app.buttons["Display"]
        if !display.waitForExistence(timeout: 2) {
            app.selectRootTab("Settings")
        }
        guard display.waitForExistence(timeout: 5) else { return false }
        display.tap()

        let trigger = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance"))
            .firstMatch
        guard trigger.waitForExistence(timeout: 5) else { return false }
        trigger.tap()

        // The popped menu exposes System / Light / Dark as buttons (or menu
        // items on some runtimes).
        let asButton = app.buttons[option]
        let choice = asButton.waitForExistence(timeout: 3) ? asButton : app.menuItems[option]
        guard choice.waitForExistence(timeout: 3) else { return false }
        choice.tap()
        return true
    }
}

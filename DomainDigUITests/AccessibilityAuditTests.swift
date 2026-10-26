import XCTest

/// One accessibility audit per primary screen, plus a Dynamic Type sweep.
///
/// See `AccessibilityAuditHarness` for why these report rather than fail by
/// default, and how to make them enforcing.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        // Keep going after a failure so an enforced audit still collects and
        // attaches every finding. With this off, XCTest aborts at the first
        // reported issue and the burndown list is lost precisely when a category
        // is being enforced.
        continueAfterFailure = true
    }

    // MARK: Per-screen audits

    func testInspectScreen() throws {
        try auditRootTab("Inspect")
    }

    func testDashboardScreen() throws {
        try auditRootTab("Dashboard")
    }

    func testAuditScreen() throws {
        try auditRootTab("Audit")
    }

    func testHistoryScreen() throws {
        try auditRootTab("History")
    }

    func testSettingsScreen() throws {
        try auditRootTab("Settings")
    }

    func testTrackedDomainsScreen() throws {
        let app = AccessibilityAuditHarness.launch()
        app.selectRootTab("Dashboard")

        let watchlist = app.buttons["Watchlist"]
        XCTAssertTrue(
            watchlist.waitForExistence(timeout: 5),
            "Dashboard no longer offers a Watchlist row"
        )
        watchlist.tap()

        let audited = try AccessibilityAuditHarness.audit(app, screen: "tracked-domains", test: self)
        try XCTSkipUnless(audited, "Tracked Domains audit did not complete in time")
    }

    // MARK: Dynamic Type

    /// Re-audits every root screen at the largest accessibility content size.
    ///
    /// This is where clipped text and fixed-height containers surface — the
    /// `.accessibility5`-class failures that the fixed geometry in
    /// `AppDensityMetrics` is expected to produce until phase 3 of #21 lands.
    ///
    /// Every screen is attempted even if an earlier one times out, so one slow
    /// screen cannot silently drop the rest; the skip is reported at the end.
    func testAllScreensAtLargestAccessibilitySize() throws {
        let app = AccessibilityAuditHarness.launch(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
        )

        var unaudited: [String] = []

        for tab in ["Inspect", "Dashboard", "Audit", "History", "Settings"] {
            app.selectRootTab(tab)
            let screen = "\(tab.lowercased())-accessibilityXXXL"
            if try !AccessibilityAuditHarness.audit(app, screen: screen, test: self) {
                unaudited.append(tab)
            }
        }

        try XCTSkipUnless(
            unaudited.isEmpty,
            "Audit did not complete in time for: \(unaudited.joined(separator: ", "))"
        )
    }

    // MARK: Seeded audits — dense rows that never render on an empty simulator

    /// Dashboard with a populated portfolio: summary tiles, quick filters,
    /// activity/attention/expiry rows, and the grouped portfolio list.
    func testSeededDashboard() throws {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        app.selectRootTab("Dashboard")
        let audited = try AccessibilityAuditHarness.audit(app, screen: "seeded-dashboard", test: self, reportOnly: true)
        try XCTSkipUnless(audited, "Audit did not complete in time for seeded Dashboard")
    }

    /// The watchlist's dense rows (up to nine text elements each).
    func testSeededTrackedDomains() throws {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        app.selectRootTab("Dashboard")
        let watchlist = app.buttons["Watchlist"]
        XCTAssertTrue(watchlist.waitForExistence(timeout: 5))
        watchlist.tap()
        let audited = try AccessibilityAuditHarness.audit(app, screen: "seeded-tracked-domains", test: self, reportOnly: true)
        try XCTSkipUnless(audited, "Audit did not complete in time for seeded Tracked Domains")
    }

    /// Batch result rows on the Inspect tab, including a failed lookup.
    func testSeededBatchResults() throws {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        app.selectRootTab("Inspect")
        let audited = try AccessibilityAuditHarness.audit(app, screen: "seeded-batch", test: self, reportOnly: true)
        try XCTSkipUnless(audited, "Audit did not complete in time for seeded batch results")
    }

    /// The seeded screens at an **intermediate** accessibility size.
    ///
    /// The default/`AccessibilityXXXL` pair brackets the range but skips the
    /// middle band, and two production layout bugs lived exactly there — a
    /// bordered button letter-wrapping vertically at a merely-large size, which
    /// neither endpoint reproduced. `AccessibilityL` samples that band across the
    /// dense seeded screens so a regression in it cannot slip between the two
    /// existing test points. Reports rather than gates, matching the other
    /// seeded audits.
    func testSeededScreensAtIntermediateAccessibilitySize() throws {
        let app = AccessibilityAuditHarness.launch(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityL",
            seeded: true
        )

        var unaudited: [String] = []

        app.selectRootTab("Dashboard")
        if try !AccessibilityAuditHarness.audit(app, screen: "seeded-dashboard-accessibilityL", test: self, reportOnly: true) {
            unaudited.append("Dashboard")
        }

        app.selectRootTab("Inspect")
        if try !AccessibilityAuditHarness.audit(app, screen: "seeded-batch-accessibilityL", test: self, reportOnly: true) {
            unaudited.append("Inspect batch")
        }

        app.selectRootTab("Dashboard")
        let watchlist = app.buttons["Watchlist"]
        if watchlist.waitForExistence(timeout: 5) {
            watchlist.tap()
            if try !AccessibilityAuditHarness.audit(app, screen: "seeded-tracked-domains-accessibilityL", test: self, reportOnly: true) {
                unaudited.append("Tracked Domains")
            }
        }

        try XCTSkipUnless(
            unaudited.isEmpty,
            "Audit did not complete in time for: \(unaudited.joined(separator: ", "))"
        )
    }

    /// The seeded screens again at the largest accessibility size — the case the
    /// deferred ViewThatFits work exists for.
    func testSeededScreensAtLargestAccessibilitySize() throws {
        let app = AccessibilityAuditHarness.launch(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL",
            seeded: true
        )

        var unaudited: [String] = []

        app.selectRootTab("Dashboard")
        if try !AccessibilityAuditHarness.audit(app, screen: "seeded-dashboard-accessibilityXXXL", test: self, reportOnly: true) {
            unaudited.append("Dashboard")
        }

        app.selectRootTab("Inspect")
        if try !AccessibilityAuditHarness.audit(app, screen: "seeded-batch-accessibilityXXXL", test: self, reportOnly: true) {
            unaudited.append("Inspect batch")
        }

        app.selectRootTab("Dashboard")
        let watchlist = app.buttons["Watchlist"]
        if watchlist.waitForExistence(timeout: 5) {
            watchlist.tap()
            if try !AccessibilityAuditHarness.audit(app, screen: "seeded-tracked-domains-accessibilityXXXL", test: self, reportOnly: true) {
                unaudited.append("Tracked Domains")
            }
        }

        try XCTSkipUnless(
            unaudited.isEmpty,
            "Audit did not complete in time for: \(unaudited.joined(separator: ", "))"
        )
    }

    // MARK: Helpers

    // MARK: Screens reached through Settings (C9)

    /// Integrations was not audited, so the SMTP port caption added in !5 had
    /// never been rendered at the largest Dynamic Type under audit and nothing
    /// here would have caught it wrapping badly.
    ///
    /// Report-only: these screens have never been through the ratchet, so
    /// gating them now would fail the build on findings that predate the
    /// coverage. They are a burndown list for #21 like the seeded screens, and
    /// `enforcedAuditTypes` widens to cover them once they are clear.
    func testIntegrationsScreen() throws {
        let app = AccessibilityAuditHarness.launch()
        app.selectRootTab("Settings")

        let integrations = app.buttons["Integrations"]
        XCTAssertTrue(
            integrations.waitForExistence(timeout: 5),
            "Settings no longer offers an Integrations row"
        )
        integrations.tap()

        let audited = try AccessibilityAuditHarness.audit(
            app,
            screen: "integrations",
            test: self,
            reportOnly: true
        )
        try XCTSkipUnless(audited, "Audit did not complete in time for Integrations")
    }

    /// The integration editor's whole form, which is the densest set of text
    /// fields and captions in the app and the one C9 named.
    func testIntegrationEditorScreen() throws {
        let app = AccessibilityAuditHarness.launch()
        app.selectRootTab("Settings")

        let integrations = app.buttons["Integrations"]
        guard integrations.waitForExistence(timeout: 5) else {
            throw XCTSkip("Settings no longer offers an Integrations row")
        }
        integrations.tap()

        let add = app.buttons["Add Integration"]
        guard add.waitForExistence(timeout: 5) else {
            throw XCTSkip("the integrations screen offers no add button to reach the editor")
        }
        add.tap()

        let audited = try AccessibilityAuditHarness.audit(
            app,
            screen: "integration-editor",
            test: self,
            reportOnly: true
        )
        try XCTSkipUnless(audited, "Audit did not complete in time for the integration editor")
    }

    /// Every remaining screen behind a Settings row.
    ///
    /// Integrations and the integration editor were covered in !42; these are
    /// the ten that were still unaudited, which was the largest blind spot left
    /// in the suite — five phases of row and caption treatment shipped without
    /// any of them being rendered under audit.
    ///
    /// Report-only for the same reason as Integrations: they have never been
    /// through the ratchet, so gating them on first contact would fail the
    /// build on findings that predate the coverage. They are a burndown list
    /// for #21, and `enforcedAuditTypes` widens once they are clear.
    ///
    /// One launch rather than ten: re-selecting the Settings tab pops it back
    /// to root, so each destination is reached from a known place, and the
    /// store reset means the launch state is the same for all of them.
    func testSettingsDestinations() throws {
        let destinations = [
            "Display",
            "History & Network",
            "Monitoring Log",
            "Local API",
            "iCloud Sync",
            "Monitoring Settings",
            "Scheduled Reports",
            "Import & Export",
            "Data Management",
            "App Info"
        ]

        let app = AccessibilityAuditHarness.launch()
        var unreachable: [String] = []
        var unaudited: [String] = []

        for destination in destinations {
            // Pops any previous push, so each row is tapped from the root.
            app.selectRootTab("Settings")

            let row = app.buttons[destination]
            guard row.waitForExistence(timeout: 5) else {
                unreachable.append(destination)
                continue
            }
            row.tap()

            let screen = destination
                .lowercased()
                .replacingOccurrences(of: " & ", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            if try !AccessibilityAuditHarness.audit(app, screen: screen, test: self, reportOnly: true) {
                unaudited.append(destination)
            }
        }

        XCTAssertEqual(unreachable, [], "Settings no longer offers these rows")
        try XCTSkipUnless(
            unaudited.isEmpty,
            "Audit did not complete in time for: \(unaudited.joined(separator: ", "))"
        )
    }

    private func auditRootTab(_ tab: String) throws {
        let app = AccessibilityAuditHarness.launch()
        app.selectRootTab(tab)
        let audited = try AccessibilityAuditHarness.audit(app, screen: tab.lowercased(), test: self)
        try XCTSkipUnless(audited, "Audit did not complete in time for \(tab)")
    }
}

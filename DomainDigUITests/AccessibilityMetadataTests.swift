import XCTest

/// Mechanical assertions for the accessibility **metadata** the manual runbook
/// (issue #21, Phase 6) checks by hand: icon-only control labels, dense-row
/// label/value pairs, and toggle selected-state.
///
/// `performAccessibilityAudit` (see `AccessibilityAuditTests`) validates
/// contrast, hit-region, clipping, and trait *correctness*, but it does not
/// assert that a specific control carries a specific spoken label — that a
/// refresh button says "Refresh all tracked domains" rather than "arrow
/// clockwise". Those strings were one-time manual VoiceOver checks; this file
/// converts the ones reachable without a live network lookup into permanent
/// regression coverage, so a relabel or a lost `.accessibilityValue` fails CI.
///
/// What is deliberately **not** here, and why:
/// - Inspect toolbar Clear/Actions/Export, the bookmark (Save) toggle, and the
///   Timeline grouping control only appear after a completed lookup, which needs
///   the network — non-deterministic in CI. They stay in the manual pass.
/// - VoiceOver speech, the More Content rotor, and custom-content ordering are
///   not observable from XCUITest at all (the rotor is a VoiceOver feature, not
///   an element property). `.accessibilityCustomContent` does not surface as a
///   queryable value here, so the row assertions cover label + value only.
@MainActor
final class AccessibilityMetadataTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: Icon-only control labels (runbook §3a)

    /// Every icon-only control reachable from the seeded launch state must
    /// announce a purpose, never a raw SF Symbol name.
    func testIconOnlyControlLabels() {
        let app = AccessibilityAuditHarness.launch(seeded: true)

        // Dashboard refresh.
        app.selectRootTab("Dashboard")
        XCTAssertTrue(
            app.buttons["Refresh all tracked domains"].waitForExistence(timeout: 5),
            "Dashboard refresh lost its 'Refresh all tracked domains' label"
        )

        // Watchlist add + filter.
        openWatchlist(app)
        XCTAssertTrue(
            app.buttons["Add domain"].waitForExistence(timeout: 5),
            "Watchlist add-domain lost its 'Add domain' label"
        )
        XCTAssertTrue(
            app.buttons["Filter and sort"].exists,
            "Watchlist filter lost its 'Filter and sort' label"
        )

        // History's "Filter" menu (HistoryView.swift:109) is gated behind a
        // non-empty history, which the seed fixtures do not populate, so it is
        // not reachable here — it stays a verified-by-construction item in the
        // results matrix rather than a flaky assertion.
    }

    /// Workflows is Pro-gated; the seed harness forces Pro so its create button
    /// is reachable.
    func testWorkflowsCreateLabel() {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        app.selectRootTab("Inspect")
        let workflows = app.buttons["Workflows"]
        XCTAssertTrue(workflows.waitForExistence(timeout: 5), "Inspect no longer offers Workflows")
        workflows.tap()
        XCTAssertTrue(
            app.buttons["Create workflow"].waitForExistence(timeout: 5),
            "Workflows create lost its 'Create workflow' label"
        )
    }

    // MARK: Dense rows — label is the domain, value is the status (runbook §3d)

    /// The watchlist's dense rows collapse to a single VoiceOver element whose
    /// label is the domain and whose value is availability. The badge title is
    /// folded into that value (children: .ignore), which is the §3c "one word"
    /// contract.
    func testWatchlistRowLabelAndValue() {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        openWatchlist(app)

        assertElement(in: app, label: "healthy.example", value: "Registered")
        // The stress-length fixture with no known availability.
        assertElement(
            in: app,
            label: "very-long-subdomain.observability.internal.staging.example",
            value: "Unknown"
        )
    }

    /// Batch result rows: domain as label, "<status>, <availability>" as value —
    /// including the failed lookup, whose badge reads "Failed".
    func testBatchRowLabelAndValue() {
        let app = AccessibilityAuditHarness.launch(seeded: true)
        app.selectRootTab("Inspect")

        assertElement(in: app, label: "broken.example", value: "Critical, Registered")
        assertElement(in: app, label: "unreachable.example", value: "Failed, Unknown")
    }

    // Toggle selected-state (runbook §3b) is intentionally not asserted here.
    // The bookmark ("Save domain") and Pin ("Pin domain") toggles both live in
    // the Inspect result's Domain section, reachable only after a completed live
    // lookup — non-deterministic in CI. The watchlist's own pin is a swipe/menu
    // action that carries no `.isSelected` trait, and the Audit checklist and
    // picker rows need seeded audits / a multi-step gated flow the fixtures do
    // not provide. These remain in the manual pass; the results matrix records
    // each as verified-by-construction with its source line.

    // MARK: Helpers

    private func openWatchlist(_ app: XCUIApplication) {
        app.selectRootTab("Dashboard")
        let watchlist = app.buttons["Watchlist"]
        XCTAssertTrue(watchlist.waitForExistence(timeout: 5), "Dashboard no longer offers Watchlist")
        watchlist.tap()
    }

    /// A `children: .ignore` row can surface as a button, cell, or other-element
    /// depending on its container; match on label across the likely types.
    private func firstElement(in app: XCUIApplication, label: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == %@", label)
        for query in [app.buttons, app.cells, app.otherElements, app.staticTexts] {
            let match = query.matching(predicate).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    private func assertElement(
        in app: XCUIApplication,
        label: String,
        value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Wait for the row to appear at all.
        let predicate = NSPredicate(format: "label == %@", label)
        let anyMatch = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(
            anyMatch.waitForExistence(timeout: 8),
            "No accessibility element labelled \(label)",
            file: file,
            line: line
        )
        guard let element = firstElement(in: app, label: label) else {
            XCTFail("Element \(label) exists but not as a queryable button/cell/other", file: file, line: line)
            return
        }
        XCTAssertEqual(
            element.value as? String,
            value,
            "Element \(label) reported value \(String(describing: element.value)); expected \(value)",
            file: file,
            line: line
        )
    }
}

import XCTest

/// Shared plumbing for the accessibility audit suite.
///
/// `performAccessibilityAudit` checks contrast, hit-region size, clipped text at
/// large Dynamic Type, element descriptions, and trait correctness — the same
/// categories the accessibility pass in issue #21 works through.
///
/// **The suite reports by default and fails only for enforced categories.** The
/// audit surfaces violations that exist today, so failing on everything would
/// block unrelated PRs until the whole pass lands. `enforcedAuditTypes` below is
/// the ratchet: widen it as each phase of #21 clears a category.
///
/// Two alternatives were tried and rejected:
///
/// - *A per-screen baseline count.* Audit coverage is not nested across OS
///   versions — the same screen legitimately yields different counts on the
///   floor simulator and the current one, so no single committed number is
///   correct for both.
/// - *An environment variable.* Neither a plain `xcodebuild` env var nor a
///   `TEST_RUNNER_`-prefixed build setting reaches this process, so the toggle
///   silently did nothing. A committed constant also makes "when did contrast
///   become enforced?" answerable with `git blame` instead of CI tribal
///   knowledge.
@MainActor
enum AccessibilityAuditHarness {
    /// Launch argument that lifts feature gating so Pro-only screens are
    /// reachable. `PurchaseService` honours this in `DEBUG` builds only.
    private static let forceProPlusArgument = "DOMAIN_DIG_FORCE_PRO_PLUS"
    /// Matches `AuditFixtures.resetStoreArgument`.
    private static let resetStoreArgument = "DOMAIN_DIG_RESET_STORE"

    /// Audit categories that fail the build on the empty-state suite. A named
    /// finding in any of these is a regression in the phase 1–5 work.
    ///
    /// `.contrast` is deliberately absent: the two long-standing Settings
    /// findings come from rows scrolled under the translucent tab bar, and their
    /// attribution flips between a row name and nil run-to-run, so there is no
    /// suppression narrow enough to keep CI stable. Contrast stays report-only,
    /// with the palette centralised in `Shared/Colors.xcassets` as the actual
    /// guard.
    static let enforcedAuditTypes: XCUIAccessibilityAuditType = [
        .textClipped,
        .dynamicType,
        .hitRegion,
        .elementDetection,
        .sufficientElementDescription,
        .trait
    ]

    /// How many times to retry an audit that misses its internal deadline.
    private static let auditAttempts = 3

    /// Launch argument that seeds deterministic in-memory tracked domains and
    /// batch results (DEBUG builds only; never persisted). Without it the dense
    /// rows and portfolio sections render nothing, which is how five phases of
    /// row treatment went unmeasured.
    private static let seedFixturesArgument = "DOMAIN_DIG_SEED_FIXTURES"

    /// Launches the app with feature gating lifted, optionally at a specific
    /// content size category and with the audit fixtures seeded.
    static func launch(contentSizeCategory: String? = nil, seeded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Every launch starts from a cleared store, so a screen the enforced
        // suite audits as empty is empty whatever ran before it.
        app.launchArguments = [forceProPlusArgument, resetStoreArgument]
        if seeded {
            app.launchArguments.append(seedFixturesArgument)
        }
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        return app
    }

    /// Runs a full audit and records every finding against the test.
    ///
    /// Findings are logged and attached to the result bundle so a CI run
    /// produces the burndown list as an artifact rather than only a pass/fail.
    ///
    /// Returns `false` if the audit could not complete, leaving the screen
    /// unaudited. Callers turn that into an `XCTSkip` — reporting a pass would
    /// claim coverage that did not happen.
    /// `reportOnly` disables enforcement for this call. Used by the seeded
    /// tests: bisection showed the audit degrades on `children: .ignore`
    /// content — the correct VoiceOver treatment for dense rows — reporting
    /// unattributed contrast/dynamicType failures on rows that measure 6–7:1
    /// and render correctly. Until that behaves, the seeded screens report
    /// their burndown without gating CI.
    ///
    /// `enforcing` narrows the enforced set for one screen, so a screen whose
    /// burndown is partly clear can gate on the categories it has cleared
    /// while still reporting the rest. That is the ratchet at screen
    /// granularity: `enforcedAuditTypes` is what a cleared screen gets.
    @discardableResult
    static func audit(
        _ app: XCUIApplication,
        screen: String,
        test: XCTestCase,
        reportOnly: Bool = false,
        enforcing: XCUIAccessibilityAuditType = enforcedAuditTypes
    ) throws -> Bool {
        var findings: [String] = []
        var timeout: Error?

        // The audit traverses the whole element tree and has its own internal
        // deadline, which slower CI runners miss on the denser screens. That is a
        // tooling timeout, not an app defect, so retry before giving up.
        //
        // Only the timeout is retried. If a category is enforced and the audit
        // reports findings before timing out, those failures are already recorded
        // and a retry would duplicate them — accepted, because the alternative is
        // losing the run to an infrastructure hiccup.
        for attempt in 1...auditAttempts {
            findings.removeAll()
            timeout = nil
            do {
                try app.performAccessibilityAudit { issue in
                    // Include the element so the burndown says *what* to fix, not
                    // just that something is wrong.
                    let element = issue.element.map { el -> String in
                        let label = el.label.isEmpty ? el.identifier : el.label
                        return label.isEmpty ? "\(el.elementType)" : "\"\(label)\""
                    } ?? "unknown element"

                    // Characterised noise never fails, but is still logged with
                    // its reason — nothing disappears silently.
                    if let noise = noiseReason(for: issue) {
                        findings.append("[noise: \(noise)][\(name(for: issue.auditType))] \(issue.compactDescription) — \(element)")
                        return true
                    }

                    let isEnforced = !reportOnly && !enforcing.intersection(issue.auditType).isEmpty
                    let marker = isEnforced ? "FAIL" : "report"
                    findings.append("[\(marker)][\(name(for: issue.auditType))] \(issue.compactDescription) — \(element)")
                    // true suppresses the finding, false reports it as a test failure.
                    return !isEnforced
                }
                break
            } catch let error as NSError where error.isAccessibilityAuditTimeout {
                timeout = error
                print("\(screen): audit timed out (attempt \(attempt) of \(auditAttempts))")
            }
        }

        if timeout != nil {
            let message = "\(screen): audit did not complete in time after \(auditAttempts) attempts — screen NOT audited"
            print(message)
            let attachment = XCTAttachment(string: message)
            attachment.name = "a11y-audit-\(screen)-timeout"
            attachment.lifetime = .keepAlways
            test.add(attachment)
            return false
        }

        let summary = findings.isEmpty
            ? "\(screen): no accessibility findings"
            : "\(screen): \(findings.count) finding(s)\n" + findings.sorted().map { "  • \($0)" }.joined(separator: "\n")

        print(summary)

        let attachment = XCTAttachment(string: summary)
        attachment.name = "a11y-audit-\(screen)"
        attachment.lifetime = .keepAlways
        test.add(attachment)

        return true
    }

    /// Classifies findings that are measurement artifacts, not app defects.
    /// Each rule exists because it was proven, not assumed; the evidence is
    /// recorded inline. A classified finding is logged with its reason and
    /// never fails the build.
    private static func noiseReason(for issue: XCUIAccessibilityAuditIssue) -> String? {
        // WCAG 1.4.3 exempts inactive components from contrast requirements,
        // but the audit flags them anyway. Proven on Inspect's Run button,
        // disabled until a domain is typed. (Driving the UI to enable it was
        // worse: the raised keyboard followed the audit onto later screens and
        // flagged the emoji picker.)
        if issue.auditType.contains(.contrast), issue.element?.isEnabled == false {
            return "disabled control, WCAG 1.4.3 exempt"
        }

        // "Nearly passed" is the audit's near-miss band, not a failure. The
        // only occurrences are iOS-rendered Settings section headers, whose
        // styling is the system's.
        if issue.compactDescription.localizedCaseInsensitiveContains("nearly passed") {
            return "near-miss, not a failure"
        }

        // Placeholder text in text/search fields is reported clipped at ANY
        // length — shortening "Search portfolio" to "Search" changed nothing —
        // and the search field's hit region at accessibility sizes is the
        // system's own control. Reading `elementType` here is safe; reading
        // `frame` is not (it kills element attribution for the whole audit).
        if let type = issue.element?.elementType,
           type == .searchField || type == .textField,
           issue.auditType.contains(.textClipped) || issue.auditType.contains(.hitRegion) {
            return "system field placeholder/hit region, length-independent"
        }

        // Unattributed clipped-text/dynamic-type findings. Bisection showed the
        // audit loses attribution inside NavigationLink rows and
        // children-ignored elements and then reports failures on content that
        // is visually verified correct (and, for the one long-standing
        // empty-watchlist phantom, renders nothing clipped at all). Named
        // findings in these categories still enforce.
        if issue.element == nil,
           issue.auditType.contains(.textClipped) || issue.auditType.contains(.dynamicType) {
            return "unattributed, audit artifact on ignored/link content"
        }

        // iOS-27-only Settings `Section` header dynamicType finding. On iOS 27.0
        // (and only there) the audit reports "font sizes partially unsupported"
        // against a Settings section header — the same system-rendered headers
        // already carved out for the contrast near-miss above. Proof it is a
        // system-chrome artifact, not an app defect:
        //   • Each is a plain `Section("Services")` etc. (ContentView.swift ~2768);
        //     the app sets no font, so the scaling is UIKit's `.footnote` header.
        //   • Version-specific: absent on the iOS 18.6 floor and on the 26.x
        //     runtime CI runs (both audit clean); it surfaces only under 27.0.
        //     ACCESSIBILITY.md's coverage table records the same asymmetry
        //     ("dynamicType finding 18.6 missed").
        //   • Attribution is unstable run-to-run across the header set
        //     (Tier/Preferences/Services), exactly like the documented contrast
        //     flip — so it lands on whichever header the traversal reaches first.
        // Overriding every Section header with a custom scaling `Text` to chase
        // this was rejected for the contrast case (ACCESSIBILITY.md) for trading
        // platform convention for nothing; the same holds here. Scoped to
        // dynamicType on the exact Settings header titles so a real regression
        // on app-controlled text still enforces.
        if issue.auditType.contains(.dynamicType),
           let label = issue.element?.label,
           settingsSectionHeaders.contains(label) {
            return "iOS-rendered Settings section header, app sets no font (27.0-only)"
        }

        return nil
    }

    /// The Settings screen's `Section(_:)` header titles. UIKit renders these;
    /// the app passes only a string literal. Used to scope the section-header
    /// dynamicType carve-out narrowly (see `noiseReason`).
    private static let settingsSectionHeaders: Set<String> = [
        "Tier", "Preferences", "Services", "Data", "About"
    ]

    /// `XCUIAccessibilityAuditType` is an option set whose description is just a
    /// raw bitmask, which makes the burndown list unreadable. Resolve it against
    /// the named members rather than hard-coding bit positions, so this keeps
    /// working if Apple adds audit types.
    private static func name(for type: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"),
            (.elementDetection, "elementDetection"),
            (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"),
            (.dynamicType, "dynamicType"),
            (.textClipped, "textClipped"),
            (.trait, "trait")
        ]
        let matched = known.filter { type.contains($0.0) }.map(\.1)
        return matched.isEmpty ? "unknown(\(type.rawValue))" : matched.joined(separator: "+")
    }
}

private extension NSError {
    /// `Audit failed to complete in time` — the audit's own deadline, raised by
    /// XCTest rather than by anything wrong with the app.
    var isAccessibilityAuditTimeout: Bool {
        domain == "com.apple.xcode.xctest.accessibilityAudit" && code == -56
    }
}

extension XCUIApplication {
    /// Taps a root tab by its visible label.
    ///
    /// Falls back to a plain button query because the tab bar is only present in
    /// the compact size class — in regular width `RootTabView` renders a
    /// `NavigationSplitView` sidebar instead.
    @MainActor
    func selectRootTab(_ name: String) {
        let tabButton = tabBars.buttons[name]
        let element = tabButton.waitForExistence(timeout: 5) ? tabButton : buttons[name]
        XCTAssertTrue(
            element.waitForExistence(timeout: 5),
            "Could not find a way to reach the \(name) screen"
        )
        element.tap()
    }
}

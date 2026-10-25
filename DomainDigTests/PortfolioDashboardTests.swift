import XCTest
@testable import DomainDig

/// Filtering the dashboard used to be five computed properties on the view
/// model, each re-reading `portfolioDashboardData` and re-deriving the visible
/// set — so the whole dashboard was rebuilt more than twenty times per render
/// (A4), and none of it was covered.
///
/// It is a function of the data now, which makes it testable, and these are
/// what that bought.
final class PortfolioDashboardTests: XCTestCase {

    private func state(
        domain: String,
        apex: String? = nil,
        health: DomainHealth = .healthy,
        lastChangeDate: Date? = nil,
        certificateExpiry: CertificateWarningLevel = .none,
        certificateDaysRemaining: Int? = nil,
        isUnreachable: Bool = false
    ) -> PortfolioDomainStatus {
        PortfolioDomainStatus(
            trackedDomain: TrackedDomain(domain: domain, createdAt: Date(), updatedAt: Date()),
            latestEntry: nil,
            report: SnapshotFixture.report(domain: domain),
            apexDomain: apex ?? domain,
            health: health,
            lastChangeDate: lastChangeDate,
            lastMonitoringFailure: nil,
            instabilityScore: 0,
            certificateExpiryState: certificateExpiry,
            certificateDaysRemaining: certificateDaysRemaining,
            isUnreachable: isUnreachable,
            recentDNSChange: false,
            recentCriticalChange: false,
            recentFailureCount: 0
        )
    }

    private func dashboard(_ states: [PortfolioDomainStatus]) -> PortfolioDashboardData {
        PortfolioDashboardData(
            snapshot: PortfolioSnapshot(
                totalDomains: states.count,
                healthyCount: states.filter { $0.health == .healthy }.count,
                warningCount: states.filter { $0.health == .warning }.count,
                criticalCount: states.filter { $0.health == .critical }.count,
                changedLast24h: 0,
                expiringSoonCount: states.filter { $0.certificateExpiryState != .none }.count,
                unreachableCount: states.filter(\.isUnreachable).count
            ),
            domainStates: states,
            recentActivity: states.map {
                PortfolioActivityItem(
                    id: "activity-\($0.trackedDomain.domain)",
                    trackedDomainID: $0.trackedDomain.id,
                    domain: $0.trackedDomain.domain,
                    message: "changed",
                    timestamp: Date(),
                    health: $0.health,
                    systemImage: "circle"
                )
            },
            attentionRequired: states.map {
                PortfolioAttentionItem(
                    id: "attention-\($0.trackedDomain.domain)",
                    trackedDomainID: $0.trackedDomain.id,
                    domain: $0.trackedDomain.domain,
                    reason: "needs attention",
                    timestamp: Date(),
                    health: $0.health
                )
            },
            expiringSoon: states.filter { $0.certificateExpiryState != .none },
            groups: PortfolioDashboardData.groups(from: states)
        )
    }

    // MARK: Filters

    func testTheAllFilterKeepsEveryDomain() {
        let data = dashboard([
            state(domain: "a.example", health: .healthy),
            state(domain: "b.example", health: .critical)
        ])

        let visible = data.filtered(by: .all, searchText: "")

        XCTAssertEqual(visible.domainStates.map(\.trackedDomain.domain), ["a.example", "b.example"])
    }

    func testEachHealthFilterKeepsOnlyThatHealth() {
        let data = dashboard([
            state(domain: "healthy.example", health: .healthy),
            state(domain: "warning.example", health: .warning),
            state(domain: "critical.example", health: .critical)
        ])

        XCTAssertEqual(
            data.filtered(by: .healthy, searchText: "").domainStates.map(\.trackedDomain.domain),
            ["healthy.example"]
        )
        XCTAssertEqual(
            data.filtered(by: .warning, searchText: "").domainStates.map(\.trackedDomain.domain),
            ["warning.example"]
        )
        XCTAssertEqual(
            data.filtered(by: .critical, searchText: "").domainStates.map(\.trackedDomain.domain),
            ["critical.example"]
        )
    }

    func testTheUnreachableFilterKeepsOnlyUnreachableDomains() {
        let data = dashboard([
            state(domain: "up.example"),
            state(domain: "down.example", isUnreachable: true)
        ])

        XCTAssertEqual(
            data.filtered(by: .unreachable, searchText: "").domainStates.map(\.trackedDomain.domain),
            ["down.example"]
        )
    }

    func testTheExpiringFilterKeepsAnyNonNoneWarningLevel() {
        let data = dashboard([
            state(domain: "fine.example", certificateExpiry: .none),
            state(domain: "soon.example", certificateExpiry: .warning),
            state(domain: "urgent.example", certificateExpiry: .critical)
        ])

        XCTAssertEqual(
            Set(data.filtered(by: .expiring, searchText: "").domainStates.map(\.trackedDomain.domain)),
            ["soon.example", "urgent.example"]
        )
    }

    /// The 24-hour window is relative to now, so a change from last week is not
    /// "changed" and one from a minute ago is.
    func testTheChangedFilterUsesATwentyFourHourWindow() {
        let data = dashboard([
            state(domain: "recent.example", lastChangeDate: Date().addingTimeInterval(-60)),
            state(domain: "old.example", lastChangeDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)),
            state(domain: "never.example", lastChangeDate: nil)
        ])

        XCTAssertEqual(
            data.filtered(by: .changed, searchText: "").domainStates.map(\.trackedDomain.domain),
            ["recent.example"]
        )
    }

    // MARK: Search

    func testSearchMatchesTheDomainAndTheApexCaseInsensitively() {
        let data = dashboard([
            state(domain: "shop.example.com", apex: "example.com"),
            state(domain: "other.test", apex: "other.test")
        ])

        XCTAssertEqual(
            data.filtered(by: .all, searchText: "SHOP").domainStates.map(\.trackedDomain.domain),
            ["shop.example.com"]
        )
        XCTAssertEqual(
            data.filtered(by: .all, searchText: "example.com").domainStates.map(\.trackedDomain.domain),
            ["shop.example.com"]
        )
    }

    func testSearchIgnoresSurroundingWhitespace() {
        let data = dashboard([state(domain: "a.example"), state(domain: "b.example")])

        XCTAssertEqual(
            data.filtered(by: .all, searchText: "   ").domainStates.count, 2,
            "a whitespace-only query should not filter anything out"
        )
        XCTAssertEqual(
            data.filtered(by: .all, searchText: "  a.  ").domainStates.map(\.trackedDomain.domain),
            ["a.example"],
            "the query is trimmed at the ends, so this matches as 'a.'"
        )
    }

    func testTheFilterAndTheSearchBothApply() {
        let data = dashboard([
            state(domain: "bad.example", health: .critical),
            state(domain: "bad.other", health: .healthy),
            state(domain: "good.example", health: .critical)
        ])

        XCTAssertEqual(
            data.filtered(by: .critical, searchText: "bad").domainStates.map(\.trackedDomain.domain),
            ["bad.example"]
        )
    }

    // MARK: The dependent lists follow the visible set

    /// Each list used to be filtered by its own computed property against a
    /// separately rebuilt dashboard. They have to agree.
    func testEveryListIsNarrowedToTheVisibleDomains() {
        let data = dashboard([
            state(domain: "keep.example", health: .critical, certificateExpiry: .warning),
            state(domain: "drop.example", health: .healthy, certificateExpiry: .warning)
        ])

        let visible = data.filtered(by: .critical, searchText: "")

        XCTAssertEqual(visible.domainStates.map(\.trackedDomain.domain), ["keep.example"])
        XCTAssertEqual(visible.recentActivity.map(\.domain), ["keep.example"])
        XCTAssertEqual(visible.attentionRequired.map(\.domain), ["keep.example"])
        XCTAssertEqual(visible.expiringSoon.map(\.trackedDomain.domain), ["keep.example"])
        XCTAssertEqual(visible.groups.flatMap { $0.domains.map(\.trackedDomain.domain) }, ["keep.example"])
    }

    /// The snapshot counts describe the whole portfolio, not the filtered view —
    /// the summary cards are what the filter is selected *from*, so filtering
    /// must not change them.
    func testFilteringDoesNotChangeTheSummaryCounts() {
        let data = dashboard([
            state(domain: "a.example", health: .healthy),
            state(domain: "b.example", health: .critical)
        ])

        let visible = data.filtered(by: .critical, searchText: "")

        XCTAssertEqual(visible.snapshot.totalDomains, 2)
        XCTAssertEqual(visible.snapshot.healthyCount, 1)
        XCTAssertEqual(visible.snapshot.criticalCount, 1)
    }

    // MARK: Grouping

    func testGroupsPutTheWorstHealthFirst() {
        let groups = PortfolioDashboardData.groups(from: [
            state(domain: "a.calm", apex: "calm", health: .healthy),
            state(domain: "b.bad", apex: "bad", health: .critical),
            state(domain: "c.mid", apex: "mid", health: .warning)
        ])

        XCTAssertEqual(groups.map(\.apexDomain), ["bad", "mid", "calm"])
    }

    func testDomainsWithinAGroupAreWorstFirstThenAlphabetical() {
        let groups = PortfolioDashboardData.groups(from: [
            state(domain: "z.example", apex: "example", health: .healthy),
            state(domain: "a.example", apex: "example", health: .healthy),
            state(domain: "m.example", apex: "example", health: .critical)
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].domains.map(\.trackedDomain.domain),
            ["m.example", "a.example", "z.example"]
        )
    }

    func testHealthSeverityRankOrdersWorstHighest() {
        XCTAssertLessThan(DomainHealth.healthy.severityRank, DomainHealth.warning.severityRank)
        XCTAssertLessThan(DomainHealth.warning.severityRank, DomainHealth.critical.severityRank)
    }
}

import XCTest
@testable import DomainDig

/// Monitoring decides when it runs, and a mistake there is silent in both
/// directions: an interval that grows without bound stops monitoring with no
/// error, and one that never backs off hammers every tracked domain on every
/// background wake. None of it had coverage.
final class MonitoringSchedulingTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: Backing off when nothing changes

    /// The interval multiplies upward from the base, never from below it: the
    /// clamp is `max(base, min(max, current * multiplier))`, so a current value
    /// under the base is raised to the base rather than multiplied.
    func testAStableCheckMultipliesTheIntervalAndCountsUp() {
        let settings = settings(adaptive: true, sensitivity: .medium)
        let base = settings.config.sanitizedBaseInterval
        let start = MonitoringState(consecutiveStableChecks: 2, currentInterval: base)

        let (state, isNewChange) = DomainMonitoringScheduler.adapted(
            start, changeHash: nil, settings: settings, now: now
        )

        XCTAssertFalse(isNewChange)
        XCTAssertEqual(state.consecutiveStableChecks, 3)
        XCTAssertEqual(state.currentInterval, base * settings.sensitivity.intervalMultiplier)
        XCTAssertGreaterThan(settings.sensitivity.intervalMultiplier, 1)
    }

    func testTheBackoffIsCappedAtTheMaximum() {
        let settings = settings(adaptive: true, sensitivity: .medium)
        let start = MonitoringState(currentInterval: settings.config.maxInterval)

        let (state, _) = DomainMonitoringScheduler.adapted(
            start, changeHash: nil, settings: settings, now: now
        )

        XCTAssertEqual(state.currentInterval, settings.config.maxInterval)
    }

    func testTheBackoffNeverDropsBelowTheBaseInterval() {
        let settings = settings(adaptive: true, sensitivity: .medium)
        let start = MonitoringState(currentInterval: 1)

        let (state, _) = DomainMonitoringScheduler.adapted(
            start, changeHash: nil, settings: settings, now: now
        )

        XCTAssertEqual(state.currentInterval, settings.config.sanitizedBaseInterval)
    }

    func testWithoutAdaptiveModeAStableCheckReturnsToBase() {
        let settings = settings(adaptive: false, sensitivity: .medium)
        let start = MonitoringState(currentInterval: 99_999)

        let (state, _) = DomainMonitoringScheduler.adapted(
            start, changeHash: nil, settings: settings, now: now
        )

        XCTAssertEqual(state.currentInterval, settings.config.sanitizedBaseInterval)
    }

    // MARK: Reacting to a change

    func testANewChangeResetsToTheSensitivityMinimum() {
        let settings = settings(adaptive: true, sensitivity: .medium)
        let start = MonitoringState(lastChangeHash: "old", consecutiveStableChecks: 7, currentInterval: 50_000)

        let (state, isNewChange) = DomainMonitoringScheduler.adapted(
            start, changeHash: "new", settings: settings, now: now
        )

        XCTAssertTrue(isNewChange)
        XCTAssertEqual(state.currentInterval, settings.sensitivity.minimumInterval)
        XCTAssertEqual(state.consecutiveStableChecks, 0)
        XCTAssertEqual(state.lastChangeHash, "new")
        XCTAssertEqual(state.lastChangeDate, now)
    }

    func testANewChangeWithoutAdaptiveModeResetsToBase() {
        let settings = settings(adaptive: false, sensitivity: .medium)
        let start = MonitoringState(lastChangeHash: "old", currentInterval: 50_000)

        let (state, isNewChange) = DomainMonitoringScheduler.adapted(
            start, changeHash: "new", settings: settings, now: now
        )

        XCTAssertTrue(isNewChange)
        XCTAssertEqual(state.currentInterval, settings.config.sanitizedBaseInterval)
    }

    /// The subtle case, deliberate and easy to "tidy" away: a condition that is
    /// still alerting but has not changed moves neither the interval nor the
    /// counter, so a persistent alert does not keep resetting the backoff.
    func testAnUnchangedAlertMovesNothing() {
        let settings = settings(adaptive: true, sensitivity: .medium)
        let start = MonitoringState(lastChangeHash: "same", consecutiveStableChecks: 4, currentInterval: 7200)

        let (state, isNewChange) = DomainMonitoringScheduler.adapted(
            start, changeHash: "same", settings: settings, now: now
        )

        XCTAssertFalse(isNewChange)
        XCTAssertEqual(state.currentInterval, 7200)
        XCTAssertEqual(state.consecutiveStableChecks, 4)
    }

    // MARK: Whether a domain is due

    func testADomainNeverCheckedIsDue() {
        let domain = trackedDomain(lastCheck: nil, interval: 3600)

        XCTAssertTrue(DomainMonitoringScheduler.isDue(
            trackedDomain: domain, settings: settings(), now: now
        ))
    }

    func testADomainCheckedWithinItsIntervalIsNotDue() {
        let domain = trackedDomain(lastCheck: now.addingTimeInterval(-1800), interval: 3600)

        XCTAssertFalse(DomainMonitoringScheduler.isDue(
            trackedDomain: domain, settings: settings(), now: now
        ))
    }

    func testADomainPastItsIntervalIsDue() {
        let domain = trackedDomain(lastCheck: now.addingTimeInterval(-3601), interval: 3600)

        XCTAssertTrue(DomainMonitoringScheduler.isDue(
            trackedDomain: domain, settings: settings(), now: now
        ))
    }

    /// A zero interval means "never configured", and must not read as "due
    /// never" or "due always" — it falls back to the base interval.
    func testAZeroIntervalFallsBackToTheBaseInterval() {
        let settings = settings()
        let domain = trackedDomain(lastCheck: now.addingTimeInterval(-60), interval: 0)

        XCTAssertFalse(DomainMonitoringScheduler.isDue(trackedDomain: domain, settings: settings, now: now))
        XCTAssertEqual(
            DomainMonitoringScheduler.normalizedMonitoringState(for: domain, settings: settings).currentInterval,
            settings.config.sanitizedBaseInterval
        )
    }

    // MARK: When to ask the system for the next wake

    func testWithNothingMonitoredTheNextWakeIsTheBaseInterval() {
        let settings = settings()

        XCTAssertEqual(
            DomainMonitoringScheduler.nextScheduleInterval(settings: settings, trackedDomains: [], now: now),
            settings.config.sanitizedBaseInterval
        )
    }

    func testTheSoonestDueDomainSetsTheNextWake() {
        let soon = trackedDomain(lastCheck: now.addingTimeInterval(-3000), interval: 3600)
        let later = trackedDomain(lastCheck: now.addingTimeInterval(-100), interval: 3600)

        let interval = DomainMonitoringScheduler.nextScheduleInterval(
            settings: settings(), trackedDomains: [later, soon], now: now
        )

        XCTAssertEqual(interval, 600, accuracy: 1)
    }

    func testAnOverdueDomainAsksForAnImmediateWake() {
        let overdue = trackedDomain(lastCheck: now.addingTimeInterval(-99_999), interval: 3600)

        XCTAssertEqual(
            DomainMonitoringScheduler.nextScheduleInterval(
                settings: settings(), trackedDomains: [overdue], now: now
            ),
            0
        )
    }

    // MARK: Which domains are monitored

    func testAllTrackedScopeStillRespectsThePerDomainToggle() {
        let on = trackedDomain(monitoringEnabled: true)
        let off = trackedDomain(monitoringEnabled: false)

        let monitored = MonitoringStorage.monitoredDomains(
            settings: settings(scope: .allTracked), trackedDomains: [on, off]
        )

        XCTAssertEqual(monitored.map(\.id), [on.id])
    }

    func testSelectedScopeNeedsBothSelectionAndToggle() {
        let selectedOn = trackedDomain(monitoringEnabled: true)
        let selectedOff = trackedDomain(monitoringEnabled: false)
        let unselectedOn = trackedDomain(monitoringEnabled: true)
        var settings = settings(scope: .selectedOnly)
        settings.selectedDomainIDs = [selectedOn.id, selectedOff.id]

        let monitored = MonitoringStorage.monitoredDomains(
            settings: settings, trackedDomains: [selectedOn, selectedOff, unselectedOn]
        )

        XCTAssertEqual(monitored.map(\.id), [selectedOn.id])
    }

    /// A selection that outlives the domain it named must not keep it alive.
    func testSanitizingDropsSelectionsForDomainsThatNoLongerExist() {
        let surviving = trackedDomain()
        var settings = settings(scope: .selectedOnly)
        settings.selectedDomainIDs = [surviving.id, UUID()]

        let sanitized = MonitoringStorage.sanitizeSettings(settings, trackedDomains: [surviving])

        XCTAssertEqual(sanitized.selectedDomainIDs, [surviving.id])
    }

    // MARK: Helpers

    private func settings(
        adaptive: Bool = true,
        sensitivity: MonitoringSensitivity = .medium,
        scope: MonitoringScope = .allTracked
    ) -> MonitoringSettings {
        MonitoringSettings(
            config: MonitoringConfig(isEnabled: true, adaptiveEnabled: adaptive, sensitivity: sensitivity),
            scope: scope
        )
    }

    private func trackedDomain(
        lastCheck: Date? = nil,
        interval: TimeInterval = 3600,
        monitoringEnabled: Bool = true
    ) -> TrackedDomain {
        TrackedDomain(
            domain: "example.com",
            createdAt: now,
            updatedAt: now,
            monitoringEnabled: monitoringEnabled,
            monitoringState: MonitoringState(lastCheck: lastCheck, currentInterval: interval)
        )
    }
}

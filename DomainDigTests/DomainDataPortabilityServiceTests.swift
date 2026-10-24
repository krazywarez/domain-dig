import XCTest
@testable import DomainDig

/// Characterization tests for the portability layer's deterministic core: the
/// CSV round-trip and the merge/dedup semantics that `load*/save*` apply. Storage
/// is exercised through an ephemeral `UserDefaults` suite so nothing touches the
/// real app domain.
final class DomainDataPortabilityServiceTests: XCTestCase {
    private let suiteName = "DomainDigTests.portability"
    private var defaults: UserDefaults!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - CSV round-trip

    func testTrackedDomainCSVRoundTripPreservesFields() throws {
        let original = TrackedDomain(
            domain: "csv.example",
            createdAt: base,
            updatedAt: base.addingTimeInterval(3_600),
            note: "keep an eye on this",
            isPinned: true,
            monitoringEnabled: false,
            lastKnownAvailability: .registered,
            certificateWarningLevel: .warning,
            certificateDaysRemaining: 12
        )

        let csv = DataPortabilityCSV.trackedDomains([original])
        let parsed = try DataPortabilityCSV.parseTrackedDomains(from: csv)

        XCTAssertEqual(parsed.count, 1)
        let restored = try XCTUnwrap(parsed.first)
        XCTAssertEqual(restored.domain, "csv.example")
        XCTAssertEqual(restored.note, "keep an eye on this")
        XCTAssertTrue(restored.isPinned)
        XCTAssertFalse(restored.monitoringEnabled)
        XCTAssertEqual(restored.lastKnownAvailability, .registered)
        XCTAssertEqual(restored.certificateWarningLevel, .warning)
        XCTAssertEqual(restored.certificateDaysRemaining, 12)
    }

    func testTrackedDomainCSVParseSkipsRowsWithoutDomain() throws {
        let csv = """
        domain,isPinned,monitoringEnabled
        ,true,true
        valid.example,false,true
        """

        let parsed = try DataPortabilityCSV.parseTrackedDomains(from: csv)

        XCTAssertEqual(parsed.map(\.domain), ["valid.example"])
    }

    // MARK: - Merge / dedup

    /// `CloudSyncService` decides whether a row has been pushed by comparing a
    /// recorded date against the row's own `updatedAt` after it has been written
    /// to the store and read back. If that comparison were lossy, every row
    /// would read as unpushed forever and local would always win every merge.
    func testUpdatedAtSurvivesAStoreRoundTripExactly() {
        let updatedAt = Date()
        let trackedDomain = TrackedDomain(
            domain: "example.com",
            createdAt: updatedAt.addingTimeInterval(-3600),
            updatedAt: updatedAt
        )

        DomainDataPortabilityService.saveTrackedDomains([trackedDomain], defaults: defaults)
        let loaded = DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.updatedAt, updatedAt)
    }

    func testSaveLoadDeduplicatesSameDomainCaseInsensitively() {
        let older = TrackedDomain(
            domain: "example.com",
            createdAt: base.addingTimeInterval(-100),
            updatedAt: base.addingTimeInterval(-50),
            isPinned: false,
            monitoringEnabled: false
        )
        let newer = TrackedDomain(
            domain: "EXAMPLE.com",
            createdAt: base.addingTimeInterval(-80),
            updatedAt: base.addingTimeInterval(-10),
            isPinned: true,
            monitoringEnabled: false
        )

        DomainDataPortabilityService.saveTrackedDomains([older, newer], defaults: defaults)
        let loaded = DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)

        XCTAssertEqual(loaded.count, 1, "same domain differing only in case must collapse to one entry")
        let merged = loaded[0]
        XCTAssertEqual(merged.domain, "example.com")
        XCTAssertTrue(merged.isPinned, "pinned state is OR-merged")
        XCTAssertFalse(merged.monitoringEnabled)
        XCTAssertEqual(merged.createdAt, base.addingTimeInterval(-100), "createdAt takes the earliest")
        XCTAssertEqual(merged.updatedAt, base.addingTimeInterval(-10), "updatedAt takes the latest")
    }

    func testSaveLoadKeepsDistinctDomainsSortedByRecency() {
        let domains = [
            TrackedDomain(domain: "old.example", updatedAt: base.addingTimeInterval(-300)),
            TrackedDomain(domain: "new.example", updatedAt: base.addingTimeInterval(-10)),
            TrackedDomain(domain: "mid.example", updatedAt: base.addingTimeInterval(-100))
        ]

        DomainDataPortabilityService.saveTrackedDomains(domains, defaults: defaults)
        let loaded = DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)

        XCTAssertEqual(loaded.map(\.domain), ["new.example", "mid.example", "old.example"])
    }

    func testLoadTrackedDomainsEmptyWhenUnset() {
        XCTAssertTrue(DomainDataPortabilityService.loadTrackedDomains(defaults: defaults).isEmpty)
    }

    // MARK: - Recent searches

    func testRecentSearchesRoundTripAndTruncateToTwenty() {
        let values = (0..<30).map { "domain\($0).example" }

        DomainDataPortabilityService.saveRecentSearches(values, defaults: defaults)
        let loaded = DomainDataPortabilityService.loadRecentSearches(defaults: defaults)

        XCTAssertEqual(loaded.count, 20, "recent searches are capped at 20")
        XCTAssertEqual(loaded, Array(values.prefix(20)), "order is preserved")
    }
}

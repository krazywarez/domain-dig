import XCTest
@testable import DomainDig

/// Characterization tests for the versioned store-migration runner. They drive
/// `migrateIfNeeded` against legacy on-disk fixtures in an ephemeral
/// `UserDefaults` suite and pin the policy: forward-only, idempotent, and
/// non-destructive to a store written by a newer build.
///
/// The raw storage-key strings ("trackedDomains", "watchedDomains", the legacy
/// marker) are duplicated here on purpose — they are the on-disk contract, and
/// hard-coding them means an accidental rename shows up as a failing migration.
final class DataMigrationServiceTests: XCTestCase {
    private let suiteName = "DomainDigTests.migration"
    private var defaults: UserDefaults!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// v2 moves history into a directory, so an ephemeral `UserDefaults` suite
    /// is no longer enough to keep these off the real store.
    private var historyLocation = HistoryFileStore.Location.default

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        historyLocation = HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigMigrationTest-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        HistoryFileStore.removeAll(at: historyLocation)
        super.tearDown()
    }

    func testFreshStoreIsStampedAtCurrentVersion() {
        XCTAssertEqual(DataMigrationService.storeSchemaVersion(defaults: defaults), 0)

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)

        XCTAssertEqual(
            DataMigrationService.storeSchemaVersion(defaults: defaults),
            DataMigrationService.currentStoreSchemaVersion
        )
    }

    func testLegacyWatchedDomainsAreMigratedAndTheOldKeyIsDropped() throws {
        let legacy = [WatchedDomain(domain: "legacy.example", createdAt: base, lastKnownAvailability: .registered)]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "watchedDomains")

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)

        let tracked = DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)
        XCTAssertEqual(tracked.map(\.domain), ["legacy.example"])
        XCTAssertNil(defaults.data(forKey: "watchedDomains"), "legacy key is dropped after migration")
        XCTAssertNotNil(defaults.data(forKey: "trackedDomains"), "data is rewritten under the current key")
        XCTAssertEqual(
            DataMigrationService.storeSchemaVersion(defaults: defaults),
            DataMigrationService.currentStoreSchemaVersion,
            "the runner stops short of this build's version"
        )
    }

    func testMigrationDeduplicatesTheStoredBlobInPlace() throws {
        let dupes = [
            TrackedDomain(domain: "dupe.example", updatedAt: base.addingTimeInterval(-10)),
            TrackedDomain(domain: "DUPE.example", updatedAt: base)
        ]
        defaults.set(try JSONEncoder().encode(dupes), forKey: "trackedDomains")

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)

        let data = try XCTUnwrap(defaults.data(forKey: "trackedDomains"))
        let stored = try JSONDecoder().decode([TrackedDomain].self, from: data)
        XCTAssertEqual(stored.count, 1, "the persisted blob is deduplicated, not just the load result")
    }

    func testMigrationIsIdempotent() throws {
        defaults.set(
            try JSONEncoder().encode([TrackedDomain(domain: "a.example", updatedAt: base)]),
            forKey: "trackedDomains"
        )

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        let afterFirst = defaults.data(forKey: "trackedDomains")

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        let afterSecond = defaults.data(forKey: "trackedDomains")

        XCTAssertEqual(afterFirst, afterSecond, "a second run makes no further changes")
        XCTAssertEqual(
            DataMigrationService.storeSchemaVersion(defaults: defaults),
            DataMigrationService.currentStoreSchemaVersion
        )
    }

    func testLegacyBooleanMarkerCountsAsVersionOne() {
        defaults.set(true, forKey: "data.migrations.v3_4_0")

        XCTAssertEqual(DataMigrationService.storeSchemaVersion(defaults: defaults), 1)

        // Already at v1, so the v1 step must not re-run: a leftover legacy blob
        // is left exactly as found.
        defaults.set(Data("x".utf8), forKey: "watchedDomains")
        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        XCTAssertNotNil(defaults.data(forKey: "watchedDomains"), "v1 is treated as already applied; no re-run")
    }

    func testNewerStoreVersionIsNeverDowngradedOrRewritten() throws {
        let future = DataMigrationService.currentStoreSchemaVersion + 1
        defaults.set(future, forKey: DataMigrationService.storeSchemaVersionKey)
        let blob = try JSONEncoder().encode([TrackedDomain(domain: "keep.example", updatedAt: base)])
        defaults.set(blob, forKey: "trackedDomains")

        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)

        XCTAssertEqual(DataMigrationService.storeSchemaVersion(defaults: defaults), future, "must never downgrade")
        XCTAssertEqual(defaults.data(forKey: "trackedDomains"), blob, "future-version data is left byte-for-byte")
    }
}

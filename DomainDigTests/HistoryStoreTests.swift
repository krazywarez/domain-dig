import XCTest
@testable import DomainDig

/// Review Focus #2: a history store at its tier cap must not drop or duplicate
/// rows across a save, an auto-prune or a backup import, and a restore must
/// round-trip every field the UI reads. Pro+ at 2000 snapshots is the worst
/// case, not the 250 the store caps at today.
///
/// These run against the store as it is. W5 moves the substrate underneath
/// `DomainDataPortabilityService`'s API, and this is the gate that says the
/// move lost nothing — so it comes before the switch, not after.
final class HistoryStoreTests: XCTestCase {

    /// The Pro+ retention tier D1 settled on, and the size every assertion here
    /// is about.
    private static let proPlusCap = 2000

    private var suiteName = ""
    private var scratch = UserDefaults.standard

    /// History lives in files now, so a scratch `UserDefaults` is no longer
    /// enough to keep a test out of the real store — it needs its own
    /// directory too.
    private var historyLocation = HistoryFileStore.Location.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        historyLocation = Self.scratchLocation()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        HistoryFileStore.removeAll(at: historyLocation)
        super.tearDown()
    }

    private static func scratchLocation() -> HistoryFileStore.Location {
        HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigTestHistory-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func entries(_ count: Int) -> [HistoryEntry] {
        (0..<count).map { SnapshotFixture.historyEntry(index: $0) }
    }

    // MARK: Round trip at the cap

    func testTwoThousandEntriesSurviveASaveAndLoad() {
        let saved = entries(Self.proPlusCap)

        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)
        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(loaded.count, Self.proPlusCap, "the store dropped or added rows")
        XCTAssertEqual(Set(loaded.map(\.id)), Set(saved.map(\.id)), "the store changed which rows exist")
    }

    /// The store sorts on load, newest first. Every reader downstream — the
    /// history list, the dashboard's recent activity, the diff view's
    /// "previous snapshot" — takes that for granted.
    func testTheStoreReturnsRowsNewestFirst() {
        DomainDataPortabilityService.saveHistoryEntries(entries(Self.proPlusCap), defaults: scratch, historyLocation: historyLocation)

        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(loaded.map(\.timestamp), loaded.map(\.timestamp).sorted(by: >))
        XCTAssertEqual(loaded.first?.snapshotIndex, Self.proPlusCap - 1)
        XCTAssertEqual(loaded.last?.snapshotIndex, 0)
    }

    func testNoRowIsDuplicatedAcrossRepeatedSaves() {
        let saved = entries(Self.proPlusCap)

        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)
        let once = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        DomainDataPortabilityService.saveHistoryEntries(once, defaults: scratch, historyLocation: historyLocation)
        let twice = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(twice.count, Self.proPlusCap)
        XCTAssertEqual(Set(twice.map(\.id)).count, Self.proPlusCap, "a row was duplicated")
        XCTAssertEqual(twice.map(\.id), once.map(\.id), "a second save reordered the store")
    }

    /// Every field the UI reads, on an entry that has all of them set. A
    /// substrate change that silently lost one section would still pass a
    /// count assertion.
    func testEveryPopulatedFieldSurvivesTheRoundTrip() throws {
        let original = SnapshotFixture.historyEntry(index: 7)

        DomainDataPortabilityService.saveHistoryEntries([original], defaults: scratch, historyLocation: historyLocation)
        let restored = try XCTUnwrap(
            DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation).first
        )

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.domain, original.domain)
        XCTAssertEqual(restored.timestamp, original.timestamp)
        XCTAssertEqual(restored.trackedDomainID, original.trackedDomainID)
        XCTAssertEqual(restored.note, original.note)

        XCTAssertEqual(restored.dnsSections.count, original.dnsSections.count)
        XCTAssertEqual(restored.dnsSections.map(\.recordType), original.dnsSections.map(\.recordType))
        XCTAssertEqual(
            restored.dnsSections.flatMap { $0.records.map(\.value) },
            original.dnsSections.flatMap { $0.records.map(\.value) }
        )

        XCTAssertEqual(restored.sslInfo?.commonName, original.sslInfo?.commonName)
        XCTAssertEqual(restored.sslInfo?.issuer, original.sslInfo?.issuer)
        XCTAssertEqual(restored.sslInfo?.daysUntilExpiry, original.sslInfo?.daysUntilExpiry)
        XCTAssertEqual(restored.sslInfo?.subjectAltNames, original.sslInfo?.subjectAltNames)

        XCTAssertEqual(restored.httpHeaders.map(\.name), original.httpHeaders.map(\.name))
        XCTAssertEqual(restored.httpHeaders.map(\.value), original.httpHeaders.map(\.value))
        XCTAssertEqual(restored.reachabilityResults.map(\.port), original.reachabilityResults.map(\.port))
        XCTAssertEqual(restored.reachabilityResults.map(\.latencyMs), original.reachabilityResults.map(\.latencyMs))

        XCTAssertEqual(restored.ipGeolocation?.ip, original.ipGeolocation?.ip)
        XCTAssertEqual(restored.ipGeolocation?.countryName, original.ipGeolocation?.countryName)
        XCTAssertEqual(restored.ipGeolocation?.org, original.ipGeolocation?.org)

        XCTAssertEqual(restored.ptrRecord, original.ptrRecord)
        XCTAssertEqual(restored.redirectChain.map(\.url), original.redirectChain.map(\.url))
        XCTAssertEqual(restored.redirectChain.map(\.isFinal), original.redirectChain.map(\.isFinal))
        XCTAssertEqual(restored.subdomains.map(\.hostname), original.subdomains.map(\.hostname))
        XCTAssertEqual(restored.hstsPreloaded, original.hstsPreloaded)

        XCTAssertEqual(restored.priorProviders, original.priorProviders)
        XCTAssertEqual(restored.riskSignals.map(\.id), original.riskSignals.map(\.id))
        XCTAssertEqual(restored.riskSignals.map(\.severity), original.riskSignals.map(\.severity))

        XCTAssertEqual(restored.dataSources, original.dataSources)
        XCTAssertEqual(restored.resolverDisplayName, original.resolverDisplayName)
        XCTAssertEqual(restored.resolverURLString, original.resolverURLString)
        XCTAssertEqual(restored.totalLookupDurationMs, original.totalLookupDurationMs)

        XCTAssertEqual(restored.primaryIP, original.primaryIP)
        XCTAssertEqual(restored.finalRedirectURL, original.finalRedirectURL)
        XCTAssertEqual(restored.tlsStatusSummary, original.tlsStatusSummary)
        XCTAssertEqual(restored.snapshotIndex, original.snapshotIndex)
        XCTAssertEqual(restored.changeCount, original.changeCount)
    }

    // MARK: Backup and restore at the cap

    func testABackupAtTheCapRestoresEveryRow() throws {
        let saved = entries(Self.proPlusCap)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch, historyLocation: historyLocation)

        let restoreName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: restoreName) }
        let restoreStore = try XCTUnwrap(UserDefaults(suiteName: restoreName))
        let restoreLocation = Self.scratchLocation()
        defer { HistoryFileStore.removeAll(at: restoreLocation) }

        let preview = try DomainDataPortabilityService.prepareImport(
            data: backup,
            fileName: "backup.json",
            mode: .replace,
            defaults: restoreStore,
            historyLocation: restoreLocation
        )
        _ = try DomainDataPortabilityService.applyImport(
            preview,
            mode: .replace,
            defaults: restoreStore,
            historyLocation: restoreLocation
        )

        let restored = DomainDataPortabilityService.loadHistoryEntries(
            defaults: restoreStore,
            historyLocation: restoreLocation
        )
        XCTAssertEqual(restored.count, Self.proPlusCap, "the backup round trip changed the row count")
        XCTAssertEqual(Set(restored.map(\.id)), Set(saved.map(\.id)), "the backup round trip changed which rows exist")
    }

    /// A merge import of a backup of the same store must not double every row.
    func testMergingABackupOfTheSameStoreDoesNotDuplicateRows() throws {
        let saved = entries(500)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch, historyLocation: historyLocation)
        let preview = try DomainDataPortabilityService.prepareImport(
            data: backup,
            fileName: "backup.json",
            mode: .merge,
            defaults: scratch,
            historyLocation: historyLocation
        )
        _ = try DomainDataPortabilityService.applyImport(preview, mode: .merge, defaults: scratch, historyLocation: historyLocation)

        let merged = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(merged.count, 500, "merging a backup of the same store duplicated rows")
        XCTAssertEqual(Set(merged.map(\.id)).count, 500)
    }

    // MARK: The v2 migration off UserDefaults

    /// An install that predates the file store has its history in one
    /// `UserDefaults` blob. The migration must move every row and then clear
    /// the key, not before.
    func testTheMigrationMovesHistoryOutOfUserDefaults() throws {
        let saved = entries(250)
        let blob = try JSONEncoder().encode(saved)
        scratch.set(blob, forKey: DomainDataPortabilityService.legacyHistoryBlobKey)
        scratch.set(1, forKey: DataMigrationService.storeSchemaVersionKey)

        DataMigrationService.migrateIfNeeded(defaults: scratch, historyLocation: historyLocation)

        XCTAssertNil(
            scratch.data(forKey: DomainDataPortabilityService.legacyHistoryBlobKey),
            "the legacy blob survived the migration"
        )
        let moved = DomainDataPortabilityService.loadHistoryEntries(
            defaults: scratch,
            historyLocation: historyLocation
        )
        XCTAssertEqual(Set(moved.map(\.id)), Set(saved.map(\.id)))
    }

    func testTheMigrationIsSafeOnAnEmptyStore() {
        scratch.set(1, forKey: DataMigrationService.storeSchemaVersionKey)

        DataMigrationService.migrateIfNeeded(defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(DataMigrationService.storeSchemaVersion(defaults: scratch), DataMigrationService.currentStoreSchemaVersion)
    }

    /// Running it twice must not resurrect or duplicate anything.
    func testTheMigrationIsIdempotent() throws {
        let saved = entries(50)
        scratch.set(try JSONEncoder().encode(saved), forKey: DomainDataPortabilityService.legacyHistoryBlobKey)
        scratch.set(1, forKey: DataMigrationService.storeSchemaVersionKey)

        DataMigrationService.migrateIfNeeded(defaults: scratch, historyLocation: historyLocation)
        DataMigrationService.migrateIfNeeded(defaults: scratch, historyLocation: historyLocation)

        let moved = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(moved.count, 50)
    }

    // MARK: Per-entry writes

    /// The reason for the directory: appending one snapshot must not rewrite
    /// the rest. Measured at the Pro+ cap, 23 ms against 656 ms.
    func testAppendingOneSnapshotLeavesTheOthersAlone() {
        let existing = entries(100)
        DomainDataPortabilityService.saveHistoryEntries(existing, defaults: scratch, historyLocation: historyLocation)

        let fresh = SnapshotFixture.historyEntry(index: 5000)
        DomainDataPortabilityService.appendHistoryEntry(
            fresh,
            cap: 250,
            defaults: scratch,
            historyLocation: historyLocation
        )

        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(loaded.count, 101)
        XCTAssertTrue(loaded.contains { $0.id == fresh.id })
        XCTAssertEqual(Set(existing.map(\.id)).subtracting(loaded.map(\.id)), [])
    }

    func testUpdatingOneSnapshotChangesOnlyThatRow() throws {
        var saved = entries(20)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        saved[3].note = "edited"
        DomainDataPortabilityService.updateHistoryEntry(saved[3], defaults: scratch, historyLocation: historyLocation)

        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(loaded.count, 20)
        let edited = try XCTUnwrap(loaded.first { $0.id == saved[3].id })
        XCTAssertEqual(edited.note, "edited")
        XCTAssertEqual(loaded.filter { $0.note == "edited" }.count, 1)
    }

    func testRemovingSnapshotsDropsOnlyThoseRows() {
        let saved = entries(30)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        let doomed = Set(saved.prefix(5).map(\.id))
        DomainDataPortabilityService.removeHistoryEntries(ids: doomed, defaults: scratch, historyLocation: historyLocation)

        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(loaded.count, 25)
        XCTAssertTrue(Set(loaded.map(\.id)).isDisjoint(with: doomed))
    }

    /// The index is what a list view reads, and it must agree with the files.
    func testTheIndexMatchesTheStoredEntries() {
        let saved = entries(120)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        let index = DomainDataPortabilityService.loadHistoryIndex(defaults: scratch, historyLocation: historyLocation)
        let full = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(index.map(\.id), full.map(\.id))
        XCTAssertEqual(index.map(\.domain), full.map(\.domain))
        XCTAssertEqual(index.map(\.timestamp), full.map(\.timestamp))
    }

    /// Append is the only writer that prunes: it adds the row that pushes the
    /// oldest one past the limit, so it is the only one that can delete it.
    func testAppendingPastTheCapDropsTheOldestRow() {
        let saved = entries(250)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)
        let oldest = DomainDataPortabilityService.loadHistoryIndex(
            defaults: scratch,
            historyLocation: historyLocation
        ).last

        DomainDataPortabilityService.appendHistoryEntry(
            SnapshotFixture.historyEntry(index: 7000),
            cap: 250,
            defaults: scratch,
            historyLocation: historyLocation
        )

        let loaded = DomainDataPortabilityService.loadHistoryIndex(defaults: scratch, historyLocation: historyLocation)
        XCTAssertEqual(loaded.count, 250)
        XCTAssertFalse(loaded.contains { $0.id == oldest?.id }, "the oldest row survived the cap")
    }

    /// A full rewrite stores what it is given. The old `UserDefaults` store
    /// had no cap here either, and a backup import that quietly truncated a
    /// user's history to 250 rows would be data loss.
    func testAFullRewriteDoesNotImposeACap() {
        DomainDataPortabilityService.saveHistoryEntries(
            entries(Self.proPlusCap),
            defaults: scratch,
            historyLocation: historyLocation
        )

        XCTAssertEqual(
            DomainDataPortabilityService.loadHistoryIndex(
                defaults: scratch,
                historyLocation: historyLocation
            ).count,
            Self.proPlusCap
        )
    }

    // MARK: Validation at the cap

    func testValidationAcceptsAStoreAtTheCap() throws {
        let saved = entries(Self.proPlusCap)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch, historyLocation: historyLocation)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch, historyLocation: historyLocation)
        let report = try DomainDataPortabilityService.validateBackup(data: backup)

        XCTAssertTrue(report.errors.isEmpty, "a store at the Pro+ cap failed validation: \(report.errors)")
    }
}

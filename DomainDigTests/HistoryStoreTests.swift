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

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func entries(_ count: Int) -> [HistoryEntry] {
        (0..<count).map { SnapshotFixture.historyEntry(index: $0) }
    }

    // MARK: Round trip at the cap

    func testTwoThousandEntriesSurviveASaveAndLoad() {
        let saved = entries(Self.proPlusCap)

        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch)
        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch)

        XCTAssertEqual(loaded.count, Self.proPlusCap, "the store dropped or added rows")
        XCTAssertEqual(Set(loaded.map(\.id)), Set(saved.map(\.id)), "the store changed which rows exist")
    }

    /// The store sorts on load, newest first. Every reader downstream — the
    /// history list, the dashboard's recent activity, the diff view's
    /// "previous snapshot" — takes that for granted.
    func testTheStoreReturnsRowsNewestFirst() {
        DomainDataPortabilityService.saveHistoryEntries(entries(Self.proPlusCap), defaults: scratch)

        let loaded = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch)

        XCTAssertEqual(loaded.map(\.timestamp), loaded.map(\.timestamp).sorted(by: >))
        XCTAssertEqual(loaded.first?.snapshotIndex, Self.proPlusCap - 1)
        XCTAssertEqual(loaded.last?.snapshotIndex, 0)
    }

    func testNoRowIsDuplicatedAcrossRepeatedSaves() {
        let saved = entries(Self.proPlusCap)

        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch)
        let once = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch)
        DomainDataPortabilityService.saveHistoryEntries(once, defaults: scratch)
        let twice = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch)

        XCTAssertEqual(twice.count, Self.proPlusCap)
        XCTAssertEqual(Set(twice.map(\.id)).count, Self.proPlusCap, "a row was duplicated")
        XCTAssertEqual(twice.map(\.id), once.map(\.id), "a second save reordered the store")
    }

    /// Every field the UI reads, on an entry that has all of them set. A
    /// substrate change that silently lost one section would still pass a
    /// count assertion.
    func testEveryPopulatedFieldSurvivesTheRoundTrip() throws {
        let original = SnapshotFixture.historyEntry(index: 7)

        DomainDataPortabilityService.saveHistoryEntries([original], defaults: scratch)
        let restored = try XCTUnwrap(
            DomainDataPortabilityService.loadHistoryEntries(defaults: scratch).first
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
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch)

        let restoreName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: restoreName) }
        let restoreStore = try XCTUnwrap(UserDefaults(suiteName: restoreName))

        let preview = try DomainDataPortabilityService.prepareImport(
            data: backup,
            fileName: "backup.json",
            mode: .replace,
            defaults: restoreStore
        )
        _ = try DomainDataPortabilityService.applyImport(preview, mode: .replace, defaults: restoreStore)

        let restored = DomainDataPortabilityService.loadHistoryEntries(defaults: restoreStore)
        XCTAssertEqual(restored.count, Self.proPlusCap, "the backup round trip changed the row count")
        XCTAssertEqual(Set(restored.map(\.id)), Set(saved.map(\.id)), "the backup round trip changed which rows exist")
    }

    /// A merge import of a backup of the same store must not double every row.
    func testMergingABackupOfTheSameStoreDoesNotDuplicateRows() throws {
        let saved = entries(500)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch)
        let preview = try DomainDataPortabilityService.prepareImport(
            data: backup,
            fileName: "backup.json",
            mode: .merge,
            defaults: scratch
        )
        _ = try DomainDataPortabilityService.applyImport(preview, mode: .merge, defaults: scratch)

        let merged = DomainDataPortabilityService.loadHistoryEntries(defaults: scratch)
        XCTAssertEqual(merged.count, 500, "merging a backup of the same store duplicated rows")
        XCTAssertEqual(Set(merged.map(\.id)).count, 500)
    }

    // MARK: Validation at the cap

    func testValidationAcceptsAStoreAtTheCap() throws {
        let saved = entries(Self.proPlusCap)
        DomainDataPortabilityService.saveHistoryEntries(saved, defaults: scratch)

        let backup = try DomainDataPortabilityService.backupData(defaults: scratch)
        let report = try DomainDataPortabilityService.validateBackup(data: backup)

        XCTAssertTrue(report.errors.isEmpty, "a store at the Pro+ cap failed validation: \(report.errors)")
    }
}

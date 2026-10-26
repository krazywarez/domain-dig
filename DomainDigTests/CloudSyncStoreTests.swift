import XCTest
@testable import DomainDig

/// C7's first remaining gap: the merge *decisions* were covered (!7), but the
/// service that stores them was not, because a private initialiser meant the
/// only instance was `shared` on `UserDefaults.standard` and covering a
/// deletion would have polluted the simulator the suite runs on.
///
/// What these assert is that a deletion is recorded, is recorded correctly, and
/// is recorded *in the injected store* — losing or resurrecting a user's
/// tracked domains is the failure mode C7 called out, and the second half of
/// that is a tombstone written somewhere nothing reads back.
@MainActor
final class CloudSyncStoreTests: XCTestCase {

    private var suiteName = ""
    private var scratch = UserDefaults.standard

    /// Releasing a main-actor-isolated object aborts the runner on iOS 18.6
    /// (E1), and `Scripts/test.sh` runs that tier. `CloudSyncService` also
    /// cancels a network path monitor in `deinit`, so it is never released.
    private static var retained: [CloudSyncService] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.sync.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService() -> CloudSyncService {
        let service = CloudSyncService(defaults: scratch)
        Self.retained.append(service)
        return service
    }

    private func trackedDomain(_ domain: String) -> TrackedDomain {
        TrackedDomain(domain: domain, createdAt: Date(), updatedAt: Date())
    }

    // MARK: Tracked domains

    func testDeletingATrackedDomainRecordsATombstone() {
        let service = makeService()
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

        service.recordTrackedDomainDeletion(trackedDomain("example.com"), deletedAt: deletedAt)

        let tombstones = service.loadTombstones()
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(tombstones.first?.entityType, .trackedDomain)
        XCTAssertEqual(tombstones.first?.identifier, "example.com")
        XCTAssertEqual(tombstones.first?.deletedAt, deletedAt)
    }

    /// The identifier is the normalized domain, because that is the key the
    /// merge matches rows on. A tombstone under the typed spelling would not
    /// suppress the row it is meant to.
    func testTheTombstoneIdentifierIsNormalized() {
        let service = makeService()

        service.recordTrackedDomainDeletion(trackedDomain("  WWW.Example.COM  "))

        XCTAssertEqual(
            service.loadTombstones().first?.identifier,
            CloudSyncMerge.normalizeDomain("  WWW.Example.COM  ")
        )
    }

    func testADomainThatNormalizesToNothingRecordsNoTombstone() {
        let service = makeService()

        service.recordTrackedDomainDeletion(trackedDomain("   "))

        XCTAssertTrue(service.loadTombstones().isEmpty)
    }

    // MARK: Workflows

    func testDeletingAWorkflowRecordsATombstoneUnderItsID() {
        let service = makeService()
        let workflow = DomainWorkflow(name: "Nightly", domains: ["example.com"])

        service.recordWorkflowDeletion(workflow)

        let tombstones = service.loadTombstones()
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(tombstones.first?.entityType, .workflow)
        XCTAssertEqual(tombstones.first?.identifier, workflow.id.uuidString)
    }

    /// A domain and a workflow can share an identifier without colliding,
    /// because the entity type is part of the key.
    func testADomainAndAWorkflowTombstoneCoexist() {
        let service = makeService()
        let workflow = DomainWorkflow(name: "Nightly", domains: [])

        service.recordTrackedDomainDeletion(trackedDomain("example.com"))
        service.recordWorkflowDeletion(workflow)

        XCTAssertEqual(Set(service.loadTombstones().map(\.entityType)), [.trackedDomain, .workflow])
    }

    // MARK: Re-recording

    /// Deleting the same domain twice leaves one tombstone, with the later
    /// date — `latestTombstones` dedupes by identifier and this is the write
    /// path feeding it.
    func testDeletingTheSameDomainTwiceKeepsTheNewerTombstone() {
        let service = makeService()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)

        service.recordTrackedDomainDeletion(trackedDomain("example.com"), deletedAt: older)
        service.recordTrackedDomainDeletion(trackedDomain("example.com"), deletedAt: newer)

        let tombstones = service.loadTombstones()
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(tombstones.first?.deletedAt, newer)
    }

    // MARK: The injected store

    /// The assertion C7 is actually about. Every tombstone write goes through
    /// the injected store, so a test can exercise deletions without writing to
    /// the simulator's shared defaults.
    func testNothingIsWrittenToTheStandardStore() throws {
        let key = "cloudSync.tombstones"
        let before = UserDefaults.standard.data(forKey: key)
        let service = makeService()

        service.recordTrackedDomainDeletion(trackedDomain("scratch-only.example"))

        XCTAssertFalse(service.loadTombstones().isEmpty, "the scratch store has it")
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: key),
            before,
            "the standard store must be untouched"
        )
    }

    /// A second service on the same store reads what the first wrote, which is
    /// what makes the tombstone survive a launch.
    func testTombstonesSurviveAFreshServiceOnTheSameStore() {
        let first = makeService()
        first.recordTrackedDomainDeletion(trackedDomain("example.com"))

        let second = makeService()

        XCTAssertEqual(second.loadTombstones().map(\.identifier), ["example.com"])
    }

    /// And a service on a different store sees none of it.
    func testAnotherStoreSeesNoTombstones() throws {
        let first = makeService()
        first.recordTrackedDomainDeletion(trackedDomain("example.com"))

        let otherName = "net.cleberg.DomainDig.tests.sync.other.\(UUID().uuidString)"
        let other = try XCTUnwrap(UserDefaults(suiteName: otherName))
        defer { UserDefaults.standard.removePersistentDomain(forName: otherName) }
        let isolated = CloudSyncService(defaults: other)
        Self.retained.append(isolated)

        XCTAssertTrue(isolated.loadTombstones().isEmpty)
    }

    // MARK: Reset

    func testResettingTrackedDomainsRecordsOneTombstoneEach() {
        let service = makeService()

        service.recordTrackedDomainReset([
            trackedDomain("a.example"),
            trackedDomain("b.example")
        ])

        XCTAssertEqual(
            Set(service.loadTombstones().map(\.identifier)),
            ["a.example", "b.example"]
        )
    }
}

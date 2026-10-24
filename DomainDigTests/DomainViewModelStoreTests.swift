import XCTest
@testable import DomainDig

/// Every persisted property on the view model used to read from and write to
/// `UserDefaults.standard`, so no test could drive its lifecycle without
/// writing into the store the app on the same simulator is using. The store is
/// injected now. These cover the seam itself and the lifecycle rules that sit
/// on top of it: history pruning, recent-search truncation, tracking, and the
/// lookup generation that keeps a stale section result off a new snapshot.
@MainActor
final class DomainViewModelStoreTests: XCTestCase {

    private var suiteName = ""
    private var scratch = UserDefaults.standard

    /// History lives in a directory now, so the scratch store has two halves.
    private var historyLocation = HistoryFileStore.Location.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        historyLocation = HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigVMTest-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        HistoryFileStore.removeAll(at: historyLocation)
        super.tearDown()
    }

    /// Releasing a main-actor-isolated object aborts the test runner on iOS
    /// 18.6 — finding E1, a Swift runtime bug in `MarkerItem::create` fixed by
    /// iOS 26.5. `Scripts/test.sh` runs the floor tier, so a view model that
    /// went out of scope would kill the whole run there. Holding every instance
    /// for the life of the process avoids the release and needs no app change.
    private static var retained: [DomainViewModel] = []

    private func makeViewModel() -> DomainViewModel {
        let viewModel = DomainViewModel(defaults: scratch, historyLocation: historyLocation)
        Self.retained.append(viewModel)
        return viewModel
    }

    private func makeEntry(domain: String, at timestamp: Date) -> HistoryEntry {
        HistoryEntry(
            identity: .init(domain: domain, timestamp: timestamp),
            inspection: .init(
                dnsSections: [],
                sslInfo: nil,
                httpHeaders: [],
                reachabilityResults: [],
                ipGeolocation: nil
            ),
            provenance: .init(resolverDisplayName: "Test Resolver", resolverURLString: "")
        )
    }

    private func makeEntries(_ count: Int) -> [HistoryEntry] {
        (0..<count).map {
            makeEntry(
                domain: "domain\($0).example",
                at: Date(timeIntervalSince1970: 1_700_000_000 - Double($0))
            )
        }
    }

    // MARK: The seam

    func testTheViewModelReadsTheStoreItWasGiven() {
        DomainDataPortabilityService.saveRecentSearches(["a.example", "b.example"], defaults: scratch)
        DomainDataPortabilityService.saveTrackedDomains(
            [TrackedDomain(domain: "tracked.example", createdAt: Date(), updatedAt: Date())],
            defaults: scratch
        )
        DomainDataPortabilityService.saveHistoryEntries(makeEntries(3), defaults: scratch, historyLocation: historyLocation)

        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.recentSearches, ["a.example", "b.example"])
        XCTAssertEqual(viewModel.trackedDomains.map(\.domain), ["tracked.example"])
        XCTAssertEqual(viewModel.history.count, 3)
    }

    /// The point of the seam: a test may drive the whole lifecycle without the
    /// app's own store on the same simulator changing underneath it.
    func testWritesLandInTheInjectedStoreAndNotTheDefaultOne() {
        let marker = "seam-\(UUID().uuidString).example"
        let viewModel = makeViewModel()

        viewModel.addRecentSearch(marker)

        XCTAssertEqual(DomainDataPortabilityService.loadRecentSearches(defaults: scratch).first, marker)
        XCTAssertFalse(
            DomainDataPortabilityService.loadRecentSearches(defaults: .standard).contains(marker),
            "a view model write reached UserDefaults.standard"
        )
    }

    func testTwoViewModelsOnSeparateStoresDoNotSeeEachOther() throws {
        let otherName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: otherName) }
        let other = try XCTUnwrap(UserDefaults(suiteName: otherName))

        let first = makeViewModel()
        let second = DomainViewModel(defaults: other, historyLocation: historyLocation)
        Self.retained.append(second)

        first.addRecentSearch("first.example")
        second.addRecentSearch("second.example")

        XCTAssertEqual(DomainDataPortabilityService.loadRecentSearches(defaults: scratch), ["first.example"])
        XCTAssertEqual(DomainDataPortabilityService.loadRecentSearches(defaults: other), ["second.example"])
    }

    // MARK: Recent searches

    func testRecentSearchesTruncateAtTheCap() {
        let viewModel = makeViewModel()

        for index in 0..<40 {
            viewModel.addRecentSearch("domain\(index).example")
        }

        XCTAssertEqual(viewModel.recentSearches.count, 20)
        XCTAssertEqual(viewModel.recentSearches.first, "domain39.example")
        XCTAssertEqual(viewModel.recentSearches.last, "domain20.example")
        XCTAssertEqual(DomainDataPortabilityService.loadRecentSearches(defaults: scratch).count, 20)
    }

    func testARepeatedSearchMovesToTheFrontWithoutDuplicating() {
        let viewModel = makeViewModel()

        viewModel.addRecentSearch("one.example")
        viewModel.addRecentSearch("two.example")
        viewModel.addRecentSearch("ONE.EXAMPLE")

        XCTAssertEqual(viewModel.recentSearches, ["ONE.EXAMPLE", "two.example"])
    }

    // MARK: History pruning

    func testTheAutoPruneOptionTrimsHistoryAndPersistsTheResult() {
        let viewModel = makeViewModel()
        viewModel.history = makeEntries(120)

        viewModel.setHistoryAutoPruneOption(.keep50)

        XCTAssertEqual(viewModel.history.count, 50)
        XCTAssertEqual(DomainDataPortabilityService.loadHistoryEntries(defaults: scratch, historyLocation: historyLocation).count, 50)
    }

    /// Pruning trims from the front, so the rows kept must be the newest ones.
    /// A trim that dropped the head would silently discard the only snapshots
    /// the dashboard and the diff view read.
    func testPruningKeepsTheNewestRows() {
        let viewModel = makeViewModel()
        let seeded = makeEntries(120)
        viewModel.history = seeded

        viewModel.setHistoryAutoPruneOption(.keep50)

        XCTAssertEqual(viewModel.history.map(\.id), seeded.prefix(50).map(\.id))
    }

    /// "Unlimited" is unlimited only up to the store's own hard cap. The
    /// setting has no bearing on that ceiling.
    func testTheHardCapAppliesEvenWhenPruningIsUnlimited() {
        let viewModel = makeViewModel()
        viewModel.history = makeEntries(300)

        viewModel.setHistoryAutoPruneOption(.unlimited)

        XCTAssertEqual(viewModel.history.count, 250)
    }

    /// A store already over the cap must still be readable. Pruning happens on
    /// a write, not on a read, so loading must not drop rows.
    func testAStoreAlreadyOverTheCapLoadsEveryRow() {
        DomainDataPortabilityService.saveHistoryEntries(makeEntries(300), defaults: scratch, historyLocation: historyLocation)

        XCTAssertEqual(makeViewModel().history.count, 300)
    }

    // MARK: Tracking

    func testTrackingADomainPersistsToTheInjectedStore() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.trackDomain(domain: "tracked.example", availabilityStatus: nil))

        XCTAssertEqual(
            DomainDataPortabilityService.loadTrackedDomains(defaults: scratch).map(\.domain),
            ["tracked.example"]
        )
    }

    /// The store key is the normalized domain, so a differently-cased repeat is
    /// the same row. Returning true without inserting is what keeps the Track
    /// button idempotent.
    func testTrackingTheSameDomainInADifferentCaseDoesNotAddASecondRow() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.trackDomain(domain: "tracked.example", availabilityStatus: nil))
        XCTAssertTrue(viewModel.trackDomain(domain: "TRACKED.EXAMPLE", availabilityStatus: nil))

        XCTAssertEqual(viewModel.trackedDomains.count, 1)
        XCTAssertEqual(DomainDataPortabilityService.loadTrackedDomains(defaults: scratch).count, 1)
    }

    /// The gate is the live entitlement's ceiling rather than a pinned number:
    /// the tier comes from `PurchaseService.shared`, which a cached purchase on
    /// the simulator can change.
    func testTrackingRefusesPastTheCeilingAndRaisesTheUpgradePrompt() {
        let limit = FeatureAccessService.entitlements.trackedDomainLimit
        let viewModel = makeViewModel()
        viewModel.trackedDomains = (0..<limit).map {
            TrackedDomain(domain: "filler\($0).example", createdAt: Date(), updatedAt: Date())
        }

        XCTAssertFalse(viewModel.trackDomain(domain: "overflow.example", availabilityStatus: nil))

        XCTAssertNotNil(viewModel.upgradePrompt)
        XCTAssertEqual(viewModel.trackedDomains.count, limit)
    }

    /// A lapsed subscriber holds more than the new ceiling. The limit gates
    /// adding, not holding, so the rows above it must still load and read back.
    func testAStoreOverTheCeilingStillLoadsEveryTrackedDomain() {
        let over = FeatureAccessService.entitlements.trackedDomainLimit + 3
        DomainDataPortabilityService.saveTrackedDomains(
            (0..<over).map { TrackedDomain(domain: "held\($0).example", createdAt: Date(), updatedAt: Date()) },
            defaults: scratch
        )

        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.trackedDomains.count, over)
        XCTAssertFalse(viewModel.canTrackCurrentDomain)
    }

    // MARK: Batch cancellation

    /// Cancelling must resolve every row it started. A pending row left pending
    /// reads as still running in the batch view, and the sweep summary counts
    /// it as outstanding forever.
    ///
    /// Start and cancel both run on the main actor with no suspension between
    /// them, so the batch task cannot begin before the cancel lands — the
    /// transition under test is the synchronous one.
    func testCancellingABatchResolvesEveryPendingRow() {
        let viewModel = makeViewModel()

        viewModel.startBatchLookup(domains: ["one.example", "two.example"], source: .manual)
        XCTAssertTrue(viewModel.batchLookupRunning)
        XCTAssertEqual(viewModel.batchResults.map(\.status), [.pending, .pending])

        viewModel.cancelBatchLookup()

        XCTAssertFalse(viewModel.batchLookupRunning)
        XCTAssertNil(viewModel.batchCurrentDomain)
        XCTAssertTrue(viewModel.batchResults.allSatisfy { $0.quickStatus == "Cancelled" })
        XCTAssertFalse(viewModel.batchResults.contains { $0.status == .pending || $0.status == .running })
    }

    /// `batchLookupRunning` and the one-second throttle both refuse the second
    /// start. Either way the running batch must not be replaced out from under
    /// the results view.
    func testASecondBatchStartDoesNotReplaceTheRunningOne() {
        let viewModel = makeViewModel()

        viewModel.startBatchLookup(domains: ["one.example"], source: .manual)
        viewModel.startBatchLookup(domains: ["a.example", "b.example", "c.example"], source: .manual)

        XCTAssertEqual(viewModel.batchTotalCount, 1)
        XCTAssertEqual(viewModel.batchResults.count, 1)
    }

    // MARK: Lookup generation (Review Focus #4)

    /// A second Run while the first lookup's sections are still in flight. Each
    /// section applier checks `isCurrentLookup` before writing, so the first
    /// lookup's generation must stop being current the moment the second
    /// begins — otherwise a late DNS or TLS result lands on the new snapshot.
    func testASecondLookupInvalidatesTheFirstOnesGeneration() {
        let viewModel = makeViewModel()

        let first = viewModel.beginLookup(for: "first.example")
        XCTAssertTrue(viewModel.isCurrentLookup(first))

        let second = viewModel.beginLookup(for: "second.example")

        XCTAssertFalse(
            viewModel.isCurrentLookup(first),
            "a section result from the first lookup would still be applied"
        )
        XCTAssertTrue(viewModel.isCurrentLookup(second))
        XCTAssertEqual(viewModel.searchedDomain, "second.example")
    }

    /// Two lookups of the same domain are still separate generations. Keying
    /// the guard on the domain rather than the run would let a stale result
    /// through on a re-run.
    func testRerunningTheSameDomainStillStartsANewGeneration() {
        let viewModel = makeViewModel()

        let first = viewModel.beginLookup(for: "same.example")
        let second = viewModel.beginLookup(for: "same.example")

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(viewModel.isCurrentLookup(first))
    }

    /// Starting a lookup clears the previous run's snapshot identity, so the
    /// history row the UI is pointing at cannot be mistaken for the new one.
    func testBeginningALookupClearsThePreviousSnapshotIdentity() {
        let viewModel = makeViewModel()
        viewModel.history = makeEntries(1)

        _ = viewModel.beginLookup(for: "fresh.example")

        XCTAssertNil(viewModel.currentHistoryEntryID)
        XCTAssertTrue(viewModel.hasRun)
    }
}


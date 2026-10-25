import XCTest
@testable import DomainDig

/// What each result section ends up showing after an inspection lands.
///
/// `applySnapshot` is the one place section state is written, and until now
/// nothing covered it — which is why A2's collapse of the 20 `*Loading` flags
/// and 19 `*Error` strings into `SectionState` could not be attempted safely.
/// These assert on the section slices the views actually consume rather than
/// on the raw properties behind them, so they survive that collapse and are
/// the thing it must not change.
@MainActor
final class SectionStateTests: XCTestCase {

    private var suiteName = ""
    private var scratch = UserDefaults.standard
    private var historyLocation = HistoryFileStore.Location.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        historyLocation = HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigSectionTest-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        HistoryFileStore.removeAll(at: historyLocation)
        super.tearDown()
    }

    /// Releasing a main-actor-isolated object aborts the runner on iOS 18.6
    /// (E1), and `Scripts/test.sh` runs that tier.
    private static var retained: [DomainViewModel] = []

    private func makeViewModel() -> DomainViewModel {
        let viewModel = DomainViewModel(defaults: scratch, historyLocation: historyLocation)
        Self.retained.append(viewModel)
        return viewModel
    }

    // MARK: Loading

    /// Starting a lookup puts every section in flight; applying a snapshot
    /// takes them all out of it. Nothing may be left loading, or the section
    /// spins forever.
    // MARK: Provenance (A12)

    /// Provenance used to be recovered from the saved history entry, so it was
    /// empty until the snapshot had been written. It now comes from the
    /// snapshot itself, which is visible here because nothing is saved.
    func testProvenanceIsAvailableBeforeTheSnapshotIsSaved() {
        let viewModel = makeViewModel()
        let provenance = SnapshotFixture.provenance(source: "DNS-over-HTTPS query", provider: "Selected DoH resolver")

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(provenanceBySection: [.dns: provenance])
        )

        XCTAssertNil(viewModel.currentHistoryEntryID, "nothing should have been saved")
        XCTAssertEqual(viewModel.currentSnapshot.provenanceBySection[.dns], provenance)
    }

    /// The case the finding called out: a lookup that ends with a status
    /// message returns before saving, so this was the state in which every
    /// section showed no source at all.
    func testProvenanceSurvivesASnapshotThatWouldNotBeSaved() {
        let viewModel = makeViewModel()
        let provenance = SnapshotFixture.provenance(source: "RDAP domain lookup", provider: "rdap.org")

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(provenanceBySection: [.ownership: provenance])
        )

        XCTAssertEqual(viewModel.currentSnapshot.provenanceBySection[.ownership], provenance)
        XCTAssertEqual(viewModel.currentSnapshot.provenanceBySection.count, 1)
    }

    /// Reset drops it, so a cleared screen does not keep claiming a source.
    func testResetClearsTheInspectionMetadata() {
        let viewModel = makeViewModel()
        viewModel.applySnapshot(
            SnapshotFixture.snapshot(provenanceBySection: [.dns: SnapshotFixture.provenance()])
        )
        XCTAssertFalse(viewModel.currentSnapshot.provenanceBySection.isEmpty)

        viewModel.reset()

        XCTAssertTrue(viewModel.currentSnapshot.provenanceBySection.isEmpty)
    }

    func testApplyingASnapshotSettlesEverySection() {
        let viewModel = makeViewModel()
        _ = viewModel.beginLookup(for: "example.com")

        XCTAssertFalse(viewModel.resultsLoaded, "sections should be in flight after a lookup starts")

        viewModel.applySnapshot(SnapshotFixture.snapshot())

        XCTAssertTrue(viewModel.resultsLoaded, "a section was left loading")
        XCTAssertFalse(viewModel.webSectionData.tls.isLoading)
        XCTAssertFalse(viewModel.webSectionData.http.isLoading)
        XCTAssertFalse(viewModel.webSectionData.redirect.isLoading)
        XCTAssertFalse(viewModel.networkSectionData.reachability.isLoading)
        XCTAssertFalse(viewModel.networkSectionData.location.isLoading)
        XCTAssertFalse(viewModel.networkSectionData.portScan.isLoading)
        XCTAssertFalse(viewModel.networkSectionData.customPortScan.isLoading)
    }

    /// `resultsLoaded` gates the whole results area, so it must not read true
    /// before a lookup has ever run.
    func testResultsAreNotLoadedBeforeAnyLookup() {
        XCTAssertFalse(makeViewModel().resultsLoaded)
    }

    // MARK: Values

    func testASuccessfulSnapshotPopulatesTheWebSection() throws {
        let viewModel = makeViewModel()
        let certificate = SnapshotFixture.certificate(commonName: "example.com", issuer: "Test CA")

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(
                sslInfo: certificate,
                httpHeaders: [HTTPHeader(name: "server", value: "test")]
            )
        )

        let web = viewModel.webSectionData
        XCTAssertNil(web.tls.error)
        XCTAssertEqual(web.sslInfo?.commonName, "example.com")
        XCTAssertEqual(web.sslInfo?.issuer, "Test CA")
        XCTAssertNil(web.http.error)
        XCTAssertEqual(web.headers.map(\.name), ["server"])
    }

    func testASuccessfulSnapshotPopulatesTheNetworkSection() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(SnapshotFixture.snapshot(dnsSections: [
            SnapshotFixture.dnsSection(type: .A, values: ["203.0.113.1"])
        ]))

        let network = viewModel.networkSectionData
        XCTAssertNil(network.reachability.error)
        XCTAssertNil(network.location.error)
        XCTAssertNil(network.portScan.error)
    }

    func testTheDNSSectionTakesItsRecordsFromTheSnapshot() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(SnapshotFixture.snapshot(dnsSections: [
            SnapshotFixture.dnsSection(type: .A, values: ["203.0.113.1", "203.0.113.2"]),
            SnapshotFixture.dnsSection(type: .MX, values: ["10 mail.example.com"])
        ]))

        XCTAssertEqual(viewModel.dnsSections.map(\.recordType), [.A, .MX])
        XCTAssertEqual(
            viewModel.dnsSections.flatMap { $0.records.map(\.value) },
            ["203.0.113.1", "203.0.113.2", "10 mail.example.com"]
        )
        XCTAssertNil(viewModel.dnsError)
    }

    // MARK: Failures

    func testAFailedSectionCarriesItsMessage() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(
                failures: .init(sslError: "handshake failed", httpHeadersError: "timed out")
            )
        )

        XCTAssertEqual(viewModel.webSectionData.tls.error, "handshake failed")
        XCTAssertEqual(viewModel.webSectionData.http.error, "timed out")
    }

    /// One section failing must not mark the others failed. Partial snapshots
    /// are the normal case, not the exception.
    func testOneFailedSectionLeavesTheOthersAlone() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(SnapshotFixture.snapshot(failures: .init(sslError: "handshake failed")))

        XCTAssertEqual(viewModel.webSectionData.tls.error, "handshake failed")
        XCTAssertNil(viewModel.webSectionData.http.error)
        XCTAssertNil(viewModel.webSectionData.redirect.error)
        XCTAssertNil(viewModel.networkSectionData.reachability.error)
        XCTAssertNil(viewModel.networkSectionData.location.error)
        XCTAssertNil(viewModel.networkSectionData.portScan.error)
    }

    func testEachNetworkCardCarriesItsOwnFailure() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(
                failures: .init(
                    reachabilityError: "no route",
                    ipGeolocationError: "no geolocation",
                    portScanError: "scan refused"
                )
            )
        )

        let network = viewModel.networkSectionData
        XCTAssertEqual(network.reachability.error, "no route")
        XCTAssertEqual(network.location.error, "no geolocation")
        XCTAssertEqual(network.portScan.error, "scan refused")
    }

    /// A snapshot can carry a value *and* an error for one section, and every
    /// section view renders `loading → error → rows`: the error wins and the
    /// value is not shown. Collapsing the triples must keep that order, and
    /// must keep the value reachable where a card reads it alongside the error
    /// — the TLS badge takes both.
    func testAnErrorAndAValueTogetherKeepBothReachable() {
        let viewModel = makeViewModel()

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(
                sslInfo: SnapshotFixture.certificate(commonName: "stale.example"),
                failures: .init(sslError: "handshake failed")
            )
        )

        let web = viewModel.webSectionData
        XCTAssertEqual(web.tls.error, "handshake failed", "the error must still be what the card shows")
        XCTAssertEqual(
            web.sslInfo?.commonName, "stale.example",
            "the TLS badge reads sslInfo alongside the error, so it must survive"
        )
    }

    // MARK: Provenance

    /// Provenance now comes from the snapshot that was just applied, which is
    /// A12 closed. It used to be recovered from the saved history entry, so
    /// between applying and saving — and on a lookup that ends with a status
    /// message and is therefore never saved — the cards showed none at all.
    ///
    /// This asserts through the section slice the view consumes, which is what
    /// the earlier version of this test pinned in the opposite direction.
    func testTheAppliedSnapshotCarriesProvenanceToTheSection() {
        let viewModel = makeViewModel()
        let provenance = SnapshotFixture.provenance(source: "Direct TLS handshake", provider: "Target host")

        viewModel.applySnapshot(
            SnapshotFixture.snapshot(provenanceBySection: [.ssl: provenance])
        )

        XCTAssertEqual(viewModel.webSectionData.tls.provenance, provenance)
    }

    // MARK: A second lookup clears the first one's results

    /// Starting a new lookup must not leave the previous domain's sections on
    /// screen as though they belonged to the new one.
    func testANewLookupClearsThePreviousSectionResults() {
        let viewModel = makeViewModel()
        viewModel.applySnapshot(
            SnapshotFixture.snapshot(
                domain: "first.example",
                dnsSections: [SnapshotFixture.dnsSection(type: .A, values: ["203.0.113.1"])],
                failures: .init(sslError: "handshake failed")
            )
        )
        XCTAssertFalse(viewModel.dnsSections.isEmpty)

        _ = viewModel.beginLookup(for: "second.example")

        XCTAssertTrue(viewModel.dnsSections.isEmpty, "the previous domain's records survived a new lookup")
        XCTAssertNil(viewModel.webSectionData.tls.error, "the previous domain's failure survived a new lookup")
    }
}

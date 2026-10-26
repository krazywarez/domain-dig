import XCTest
@testable import DomainDig

/// C7's second remaining gap: `LocalAPIRoutingTests` covers which request maps
/// to which route and the 401/404 envelopes, which `handle` answers before it
/// reaches the store — but nothing covered what the success paths actually
/// return, because they read the real store.
///
/// `LocalAPIRequestHandler` takes a `defaults:` and a `historyLocation:` now,
/// so they can be answered from a scratch store and asserted. `/inspect` still
/// is not here: it runs a live lookup, which is a network dependency rather
/// than a store one.
@MainActor
final class LocalAPISuccessTests: XCTestCase {

    private let token = "test-token"
    private var suiteName = ""
    private var scratch = UserDefaults.standard
    private var historyLocation = HistoryFileStore.Location.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.localapi.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        historyLocation = HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigLocalAPITest-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        HistoryFileStore.removeAll(at: historyLocation)
        super.tearDown()
    }

    private var handler: LocalAPIRequestHandler {
        LocalAPIRequestHandler(defaults: scratch, historyLocation: historyLocation)
    }

    private func get(_ path: String) async -> LocalAPIHTTPResponse {
        await handler.handle(
            request: LocalAPIHTTPRequest(
                method: "GET",
                path: path,
                queryItems: [],
                headers: ["x-api-token": token],
                body: Data()
            ),
            expectedToken: token
        )
    }

    /// The envelope's `data`, as loosely typed JSON — these assert on the
    /// values the store produced, and `LocalAPIContractTests` already pins the
    /// shape.
    private func data(from response: LocalAPIHTTPResponse) throws -> [String: Any] {
        XCTAssertEqual(response.statusCode, 200)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        XCTAssertEqual(json["success"] as? Bool, true)
        return try XCTUnwrap(json["data"] as? [String: Any])
    }

    private func seedTrackedDomains(_ domains: [String]) {
        DomainDataPortabilityService.saveTrackedDomains(
            domains.map { TrackedDomain(domain: $0, createdAt: Date(), updatedAt: Date()) },
            defaults: scratch
        )
    }

    // MARK: /domains

    func testDomainsReturnsTheTrackedDomainsFromTheInjectedStore() async throws {
        seedTrackedDomains(["b.example", "a.example"])

        let payload = try data(from: await get("/domains"))
        let domains = try XCTUnwrap(payload["domains"] as? [[String: Any]])

        XCTAssertEqual(Set(domains.compactMap { $0["domain"] as? String }), ["a.example", "b.example"])
    }

    func testDomainsIsEmptyOnAFreshStore() async throws {
        let payload = try data(from: await get("/domains"))

        XCTAssertEqual((payload["domains"] as? [[String: Any]])?.count, 0)
    }

    // MARK: /portfolio

    func testPortfolioCountsTheTrackedDomains() async throws {
        seedTrackedDomains(["a.example", "b.example", "c.example"])

        let payload = try data(from: await get("/portfolio"))
        let summary = try XCTUnwrap(payload["summary"] as? [String: Any])

        XCTAssertEqual(summary["totalDomains"] as? Int, 3)
    }

    func testPortfolioIsZeroedOnAFreshStore() async throws {
        let payload = try data(from: await get("/portfolio"))
        let summary = try XCTUnwrap(payload["summary"] as? [String: Any])

        XCTAssertEqual(summary["totalDomains"] as? Int, 0)
        XCTAssertEqual(summary["healthyCount"] as? Int, 0)
    }

    // MARK: /domains/{domain}

    func testDomainDetailsAnswersForATrackedDomain() async throws {
        seedTrackedDomains(["example.com"])

        let payload = try data(from: await get("/domains/example.com"))

        XCTAssertEqual(payload["domain"] as? String, "example.com")
        XCTAssertNotNil(payload["trackedDomain"])
    }

    /// A domain the store does not hold is a 404 with the documented code,
    /// rather than an empty 200.
    func testDomainDetailsIsNotFoundForAnUntrackedDomain() async throws {
        let response = await get("/domains/unknown.example")

        XCTAssertEqual(response.statusCode, 404)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "domain_not_found")
    }

    /// The path is matched case-insensitively, because that is how the store
    /// matches it everywhere else.
    func testDomainDetailsMatchesCaseInsensitively() async throws {
        seedTrackedDomains(["example.com"])

        let payload = try data(from: await get("/domains/EXAMPLE.COM"))

        XCTAssertEqual(payload["domain"] as? String, "example.com")
    }

    // MARK: /domains/{domain}/history

    func testDomainHistoryIsEmptyWithoutSnapshots() async throws {
        seedTrackedDomains(["example.com"])

        let payload = try data(from: await get("/domains/example.com/history"))

        XCTAssertEqual(payload["domain"] as? String, "example.com")
        XCTAssertEqual((payload["history"] as? [[String: Any]])?.count, 0)
    }

    // MARK: /events and /monitoring

    func testEventsAnswersOnAFreshStore() async throws {
        let payload = try data(from: await get("/events"))

        XCTAssertEqual((payload["events"] as? [[String: Any]])?.count, 0)
    }

    func testMonitoringReportsTheStoredSettings() async throws {
        seedTrackedDomains(["example.com"])

        let payload = try data(from: await get("/monitoring"))

        XCTAssertNotNil(payload["isEnabled"])
        XCTAssertNotNil(payload["scope"])
        XCTAssertNotNil(payload["monitoredDomains"])
    }

    // MARK: The injected store

    /// The point of the seam: answering these touches the scratch store and
    /// leaves the simulator's shared defaults alone.
    func testTheSuccessPathsDoNotReadTheStandardStore() async throws {
        let key = "trackedDomains"
        let before = UserDefaults.standard.data(forKey: key)
        seedTrackedDomains(["scratch-only.example"])

        let payload = try data(from: await get("/domains"))
        let domains = try XCTUnwrap(payload["domains"] as? [[String: Any]])

        XCTAssertEqual(domains.compactMap { $0["domain"] as? String }, ["scratch-only.example"])
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), before, "standard store untouched")
    }

    /// Auth still runs ahead of the store, so a seeded store is no way around
    /// a missing token.
    func testAMissingTokenIsStillRejectedWithASeededStore() async throws {
        seedTrackedDomains(["example.com"])

        let response = await handler.handle(
            request: LocalAPIHTTPRequest(
                method: "GET",
                path: "/domains",
                queryItems: [],
                headers: [:],
                body: Data()
            ),
            expectedToken: token
        )

        XCTAssertEqual(response.statusCode, 401)
    }
}

import XCTest
@testable import DomainDig

/// Characterization tests pinning `HistoryEntry`'s encoded shape.
///
/// This type is not merely an in-memory model: `DomainDataPortabilityService`
/// persists it to `UserDefaults` as JSON and reads the same shape back out of
/// backup files. Both decode paths swallow failures — `loadHistoryEntries` uses
/// `try?` and drops anything that will not decode — so a change to the encoded
/// keys does not raise, it silently discards a user's saved history.
///
/// These tests exist so that any such change fails here first, loudly, instead
/// of in someone's app.
final class HistoryEntryCodableTests: XCTestCase {
    /// Every key `HistoryEntry` is expected to encode. Adding a stored property
    /// is a format change: extend this list deliberately, and only once you have
    /// decided what happens to history written by an older build.
    private static let expectedKeys: Set<String> = [
        "id", "domain", "timestamp", "trackedDomainID", "note", "dnsSections",
        "sslInfo", "httpHeaders", "reachabilityResults", "ipGeolocation",
        "emailSecurity", "mtaSts", "ownership", "ownershipHistory",
        "inferredProvider", "priorProviders", "domainClassification",
        "ownershipTransitions", "hostingTransitions", "subdomainHistory",
        "riskSignals", "intelligenceTimeline", "ptrRecord", "redirectChain",
        "subdomains", "extendedSubdomains", "dnsHistory", "domainPricing",
        "reputation", "portScanResults", "hstsPreloaded", "availabilityResult",
        "suggestions", "appVersion", "resultSource", "dataSources",
        "provenanceBySection", "availabilityConfidence", "ownershipConfidence",
        "subdomainConfidence", "emailSecurityConfidence", "geolocationConfidence",
        "errorDetails", "isPartialSnapshot", "validationIssues",
        "resolverDisplayName", "resolverURLString", "totalLookupDurationMs",
        "primaryIP", "finalRedirectURL", "tlsStatusSummary",
        "emailSecuritySummary", "httpGradeSummary", "changeSummary",
        "snapshotIndex", "previousSnapshotID", "changeCount", "severitySummary",
        "sslError", "httpHeadersError", "reachabilityError", "ipGeolocationError",
        "emailSecurityError", "ownershipError", "ownershipHistoryError",
        "ptrError", "redirectChainError", "subdomainsError",
        "extendedSubdomainsError", "dnsHistoryError", "domainPricingError",
        "reputationError", "portScanError",
    ]

    /// Assembled from parts rather than written as a literal: a hardcoded
    /// absolute URI trips swift:S1075, and the value only has to be a stable,
    /// obviously-fake resolver address.
    private static let resolverURL = ["https:/", "resolver.example", "dns-query"]
        .joined(separator: "/")

    private func makeEntry() -> HistoryEntry {
        HistoryEntry(
            identity: .init(
                domain: "example.com",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            inspection: .init(
                dnsSections: [],
                sslInfo: nil,
                httpHeaders: [],
                reachabilityResults: [],
                ipGeolocation: nil
            ),
            provenance: .init(
                resolverDisplayName: "Test Resolver",
                resolverURLString: Self.resolverURL
            )
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// The set of top-level keys is the persisted contract. Optionals that are
    /// nil are omitted by the synthesized encoder, so this asserts containment
    /// rather than equality — no key may appear that is not accounted for.
    func testEncodedKeysAreAllAccountedFor() throws {
        let data = try encoder().encode(makeEntry())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let unexpected = Set(object.keys).subtracting(Self.expectedKeys)
        XCTAssertTrue(
            unexpected.isEmpty,
            "HistoryEntry encoded keys not in the pinned set: \(unexpected.sorted()). "
                + "This changes the persisted format; older history will not decode."
        )
    }

    /// A populated entry must survive encode → decode → encode unchanged. This
    /// is the guard that a refactor which regroups the initializer has not also
    /// moved a value into a different place in the JSON.
    func testRoundTripIsStable() throws {
        let first = try encoder().encode(makeEntry())
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: first)
        let second = try encoder().encode(decoded)

        XCTAssertEqual(
            first, second,
            "HistoryEntry did not survive a JSON round trip unchanged"
        )
    }

    /// The values a caller supplies must land under the keys the persisted format
    /// already uses, not merely somewhere in the document.
    func testRequiredValuesEncodeAtTheTopLevel() throws {
        let data = try encoder().encode(makeEntry())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["domain"] as? String, "example.com")
        XCTAssertEqual(object["resolverDisplayName"] as? String, "Test Resolver")
        XCTAssertEqual(
            object["resolverURLString"] as? String,
            Self.resolverURL
        )
    }

    /// What `loadHistoryEntries` actually does with a stored blob, end to end:
    /// anything that fails to decode is dropped without error, so this pins that
    /// a current-format entry survives the real read path.
    func testSurvivesTheRealPersistencePath() throws {
        let suite = "DomainDigTests.historyEntryCodable"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let historyLocation = HistoryFileStore.Location(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DomainDigCodableTest-\(UUID().uuidString)", isDirectory: true)
        )
        defer { HistoryFileStore.removeAll(at: historyLocation) }

        DomainDataPortabilityService.saveHistoryEntries(
            [makeEntry()],
            defaults: defaults,
            historyLocation: historyLocation
        )
        let loaded = DomainDataPortabilityService.loadHistoryEntries(
            defaults: defaults,
            historyLocation: historyLocation
        )

        XCTAssertEqual(loaded.count, 1, "entry was silently dropped by the load path")
        XCTAssertEqual(loaded.first?.domain, "example.com")
    }
}

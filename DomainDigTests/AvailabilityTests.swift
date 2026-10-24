import XCTest
@testable import DomainDig

/// Availability has two sources that disagree about what silence means: a
/// registry 404 means the name is free, while a DNS lookup with no records
/// means nothing, because the DoH layer drops the response code. These pin the
/// mapping for each path through `DomainAvailabilityService.check`.
final class DomainAvailabilityTests: XCTestCase {

    /// A resolving name under a TLD with no RDAP server: the 404 comes from the
    /// bootstrap redirector, which says nothing about registration, so DNS
    /// decides.
    func testBootstrapNotFoundWithDNSRecordsIsRegistered() async {
        let transport = StubRDAPTransport { _ in
            (Data(), stubHTTPResponse(status: 404, host: "rdap.org", domain: "example.quux"))
        }
        let dns = StubDNSLookup(records: [.A: [DNSRecord(value: "203.0.113.10", ttl: 300)]])

        let result = await DomainAvailabilityService.check(
            domain: "example.quux",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .registered)
    }

    func testRegistryNotFoundIsAvailable() async {
        let transport = StubRDAPTransport { _ in
            (Data(), stubHTTPResponse(status: 404, host: "rdap.verisign.com", domain: "example.com"))
        }
        let dns = StubDNSLookup(records: [:])

        let result = await DomainAvailabilityService.check(
            domain: "example.com",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(dns.lookupCount, 0)
    }

    func testDomainRecordIsRegistered() async {
        let transport = StubRDAPTransport { _ in
            (domainRecordBody, stubHTTPResponse(status: 200, host: "rdap.verisign.com", domain: "example.com"))
        }
        let dns = StubDNSLookup(records: [:])

        let result = await DomainAvailabilityService.check(
            domain: "example.com",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .registered)
        XCTAssertEqual(dns.lookupCount, 0)
    }

    func testNonDomainRecordFallsBackToDNS() async {
        let transport = StubRDAPTransport { _ in
            (nonDomainRecordBody, stubHTTPResponse(status: 200, host: "rdap.verisign.com", domain: "example.com"))
        }
        let dns = StubDNSLookup(records: [.NS: [DNSRecord(value: "ns1.example.net", ttl: 300)]])

        let result = await DomainAvailabilityService.check(
            domain: "example.com",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .registered)
        XCTAssertEqual(dns.lookupCount, 2)
    }

    func testTransportErrorWithDNSRecordsIsRegistered() async {
        let transport = StubRDAPTransport { _ in throw URLError(.timedOut) }
        let dns = StubDNSLookup(records: [.A: [DNSRecord(value: "203.0.113.10", ttl: 300)]])

        let result = await DomainAvailabilityService.check(
            domain: "example.com",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .registered)
    }

    /// No RDAP answer and no DNS records is undecided, not available: a
    /// resolver failure and NXDOMAIN arrive here identically.
    func testTransportErrorWithoutDNSRecordsIsUnknown() async {
        let transport = StubRDAPTransport { _ in throw URLError(.timedOut) }
        let dns = StubDNSLookup(records: [:])

        let result = await DomainAvailabilityService.check(
            domain: "example.com",
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(result.status, .unknown)
    }

    func testBlankInputIsUnknownWithoutALookup() async {
        let transport = StubRDAPTransport { _ in
            XCTFail("blank input should not reach the network")
            return (Data(), stubHTTPResponse(status: 200, host: "rdap.org", domain: ""))
        }
        let dns = StubDNSLookup(records: [:])

        for input in ["", "   \n"] {
            let result = await DomainAvailabilityService.check(
                domain: input,
                rdapTransport: transport,
                dns: dns
            )
            XCTAssertEqual(result.status, .unknown)
        }

        XCTAssertEqual(transport.requestedDomains, [])
        XCTAssertEqual(dns.lookupCount, 0)
    }

    func testSuggestionsMapEachCandidateStatus() async {
        let transport = StubRDAPTransport { request in
            let domain = request.url?.lastPathComponent ?? ""
            if domain == "example.net" {
                return (Data(), stubHTTPResponse(status: 404, host: "rdap.nic.net", domain: domain))
            }
            return (domainRecordBody, stubHTTPResponse(status: 200, host: "rdap.nic.io", domain: domain))
        }
        let dns = StubDNSLookup(records: [:])

        let results = await DomainAvailabilityService.suggestions(
            for: "example.com",
            limit: 2,
            rdapTransport: transport,
            dns: dns
        )

        XCTAssertEqual(results.map(\.domain), ["example.net", "example.io"])
        XCTAssertEqual(results.map(\.status), [.available, .registered])
    }
}

private final class StubRDAPTransport: RDAPTransport {
    private let respond: (URLRequest) throws -> (Data, URLResponse)
    private(set) var requestedDomains: [String] = []

    init(respond: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.respond = respond
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let domain = request.url?.lastPathComponent {
            requestedDomains.append(domain)
        }
        return try respond(request)
    }
}

private final class StubDNSLookup: DNSLookup {
    private let records: [DNSRecordType: [DNSRecord]]
    private(set) var lookupCount = 0

    init(records: [DNSRecordType: [DNSRecord]]) {
        self.records = records
    }

    func lookup(domain: String, recordType: DNSRecordType) async throws -> [DNSRecord] {
        lookupCount += 1
        return records[recordType] ?? []
    }
}

private let domainRecordBody = Data(#"{"objectClassName":"domain","ldhName":"example.com"}"#.utf8)

private let nonDomainRecordBody = Data(#"{"objectClassName":"help"}"#.utf8)

/// The response URL matters as much as the status code: it is how a registry's
/// 404 is told apart from the bootstrap redirector's.
private func stubHTTPResponse(status: Int, host: String, domain: String) -> URLResponse {
    let url = URL(string: "https://\(host)/domain/\(domain)")!
    return HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

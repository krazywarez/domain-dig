import Foundation
@testable import DomainDig

/// Deterministic builders for the deep `LookupSnapshot` / `DomainReport` models
/// so the core unit tests can construct inputs without wiring up every one of the
/// ~75 snapshot fields at each call site.
///
/// `snapshot(...)` exposes only the fields the tests actually vary; everything
/// else defaults to an empty/absent value. `report(...)` runs a snapshot through
/// the real `DomainReportBuilder`, which is both the natural constructor for the
/// otherwise-unconstructable `DomainReport` and, for the builder tests, the unit
/// under test.
enum SnapshotFixture {
    /// Fixed instant so timestamp-derived output (diff ranges, export headers) is
    /// stable across runs.
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    static let defaultResolverURL = "https://resolver.example/dns-query"

    static func snapshot(
        domain: String = "example.com",
        timestamp: Date = referenceDate,
        resolverURLString: String = defaultResolverURL,
        resultSource: LookupResultSource = .live,
        availability: DomainAvailabilityStatus? = nil,
        ownership: DomainOwnership? = nil,
        dnsSections: [DNSSection] = [],
        ptrRecord: String? = nil,
        sslInfo: SSLCertificateInfo? = nil,
        httpHeaders: [HTTPHeader] = [],
        httpStatusCode: Int? = nil,
        httpSecurityGrade: String? = nil,
        subdomains: [DiscoveredSubdomain] = [],
        extendedSubdomains: [DiscoveredSubdomain] = [],
        isPartialSnapshot: Bool = false,
        validationIssues: [String] = [],
        changeSummary: DomainChangeSummary? = nil
    ) -> LookupSnapshot {
        LookupSnapshot(
            historyEntryID: nil,
            domain: domain,
            timestamp: timestamp,
            trackedDomainID: nil,
            note: nil,
            appVersion: "test",
            resolverDisplayName: "Test Resolver",
            resolverURLString: resolverURLString,
            dataSources: [],
            provenanceBySection: [:],
            availabilityConfidence: nil,
            ownershipConfidence: nil,
            subdomainConfidence: nil,
            emailSecurityConfidence: nil,
            geolocationConfidence: nil,
            errorDetails: [:],
            isPartialSnapshot: isPartialSnapshot,
            validationIssues: validationIssues,
            totalLookupDurationMs: nil,
            snapshotIndex: nil,
            previousSnapshotID: nil,
            changeCount: 0,
            severitySummary: nil,
            dnsSections: dnsSections,
            dnsError: nil,
            availabilityResult: availability.map { DomainAvailabilityResult(domain: domain, status: $0) },
            suggestions: [],
            sslInfo: sslInfo,
            sslError: nil,
            hstsPreloaded: nil,
            httpHeaders: httpHeaders,
            httpSecurityGrade: httpSecurityGrade,
            httpStatusCode: httpStatusCode,
            httpResponseTimeMs: nil,
            httpProtocol: nil,
            http3Advertised: false,
            httpHeadersError: nil,
            reachabilityResults: [],
            reachabilityError: nil,
            ipGeolocation: nil,
            ipGeolocationError: nil,
            emailSecurity: nil,
            emailSecurityError: nil,
            ownership: ownership,
            ownershipError: nil,
            ownershipHistory: [],
            ownershipHistoryError: nil,
            inferredProvider: nil,
            priorProviders: [],
            domainClassification: nil,
            ownershipTransitions: [],
            hostingTransitions: [],
            subdomainHistory: [],
            riskSignals: [],
            intelligenceTimeline: [],
            ptrRecord: ptrRecord,
            ptrError: nil,
            redirectChain: [],
            redirectChainError: nil,
            subdomains: subdomains,
            subdomainsError: nil,
            extendedSubdomains: extendedSubdomains,
            extendedSubdomainsError: nil,
            dnsHistory: [],
            dnsHistoryError: nil,
            domainPricing: nil,
            domainPricingError: nil,
            reputation: nil,
            reputationError: nil,
            portScanResults: [],
            portScanError: nil,
            changeSummary: changeSummary,
            resultSource: resultSource,
            cachedSections: [],
            statusMessage: nil
        )
    }

    static func report(
        domain: String = "example.com",
        timestamp: Date = referenceDate,
        resolverURLString: String = defaultResolverURL,
        resultSource: LookupResultSource = .live,
        availability: DomainAvailabilityStatus? = nil,
        ownership: DomainOwnership? = nil,
        dnsSections: [DNSSection] = [],
        ptrRecord: String? = nil,
        sslInfo: SSLCertificateInfo? = nil,
        httpHeaders: [HTTPHeader] = [],
        httpStatusCode: Int? = nil,
        httpSecurityGrade: String? = nil,
        subdomains: [DiscoveredSubdomain] = [],
        extendedSubdomains: [DiscoveredSubdomain] = [],
        isPartialSnapshot: Bool = false,
        validationIssues: [String] = []
    ) -> DomainReport {
        DomainReportBuilder().build(
            from: snapshot(
                domain: domain,
                timestamp: timestamp,
                resolverURLString: resolverURLString,
                resultSource: resultSource,
                availability: availability,
                ownership: ownership,
                dnsSections: dnsSections,
                ptrRecord: ptrRecord,
                sslInfo: sslInfo,
                httpHeaders: httpHeaders,
                httpStatusCode: httpStatusCode,
                httpSecurityGrade: httpSecurityGrade,
                subdomains: subdomains,
                extendedSubdomains: extendedSubdomains,
                isPartialSnapshot: isPartialSnapshot,
                validationIssues: validationIssues
            ),
            deriveChangeSummary: false
        )
    }

    // MARK: - Nested model conveniences

    static func dnsSection(
        type: DNSRecordType,
        values: [String],
        ttl: Int = 300,
        dnssecSigned: Bool? = nil,
        wildcards: [String] = []
    ) -> DNSSection {
        DNSSection(
            recordType: type,
            records: values.map { DNSRecord(value: $0, ttl: ttl) },
            wildcardRecords: wildcards.map { DNSRecord(value: $0, ttl: ttl) },
            dnssecSigned: dnssecSigned
        )
    }

    /// A `HistoryEntry` with every section populated, for the tests that care
    /// about the persisted store rather than about one field. The store holds
    /// up to 2000 of these at the Pro+ cap, so `index` varies the content: an
    /// entry repeated verbatim would not measure a realistic encode.
    static func historyEntry(index: Int = 0, domain: String? = nil) -> HistoryEntry {
        let host = domain ?? "domain\(index).example"
        return HistoryEntry(
            identity: .init(
                domain: host,
                timestamp: referenceDate.addingTimeInterval(Double(index)),
                trackedDomainID: UUID(),
                note: "note for \(host)"
            ),
            inspection: .init(
                dnsSections: [
                    dnsSection(type: .A, values: ["203.0.113.\(index % 256)", "198.51.100.\(index % 256)"]),
                    dnsSection(type: .MX, values: ["10 mail.\(host)"]),
                    dnsSection(type: .TXT, values: ["v=spf1 include:_spf.\(host) -all"])
                ],
                sslInfo: certificate(commonName: host, daysUntilExpiry: 30 + index % 300),
                httpHeaders: [
                    HTTPHeader(name: "strict-transport-security", value: "max-age=31536000"),
                    HTTPHeader(name: "content-security-policy", value: "default-src 'self'"),
                    HTTPHeader(name: "server", value: "test/\(index)")
                ],
                reachabilityResults: [
                    PortReachability(port: 80, reachable: true, latencyMs: 12 + index % 50),
                    PortReachability(port: 443, reachable: true, latencyMs: 15 + index % 50)
                ],
                ipGeolocation: IPGeolocation(
                    ip: "203.0.113.\(index % 256)",
                    city: "Testville",
                    region: "Test Region",
                    countryName: "Testland",
                    org: "Test Org \(index)",
                    latitude: 45.0,
                    longitude: -93.0
                ),
                ptrRecord: "host\(index).\(host)",
                redirectChain: [
                    RedirectHop(stepNumber: 1, statusCode: 301, url: "http://\(host)", isFinal: false),
                    RedirectHop(stepNumber: 2, statusCode: 200, url: "https://\(host)", isFinal: true)
                ],
                subdomains: (0..<5).map { DiscoveredSubdomain(hostname: "sub\($0).\(host)", source: "crt.sh") },
                hstsPreloaded: index.isMultiple(of: 2)
            ),
            registration: .init(priorProviders: ["Provider \(index)", "Provider \(index + 1)"]),
            intelligence: .init(
                riskSignals: [
                    IntelligenceRiskSignal(
                        id: "signal-\(index)",
                        title: "Signal \(index)",
                        detail: "A detail string long enough to be representative of a real finding.",
                        severity: .medium,
                        firstObserved: referenceDate,
                        lastObserved: referenceDate.addingTimeInterval(Double(index))
                    )
                ]
            ),
            provenance: .init(
                dataSources: ["dns", "tls", "http", "crt.sh"],
                validationIssues: [],
                resolverDisplayName: "Test Resolver",
                resolverURLString: defaultResolverURL,
                totalLookupDurationMs: 1200 + index
            ),
            summary: .init(
                primaryIP: "203.0.113.\(index % 256)",
                finalRedirectURL: "https://\(host)",
                tlsStatusSummary: "Valid",
                snapshotIndex: index,
                changeCount: index % 4
            )
        )
    }

    static func certificate(
        commonName: String = "example.com",
        issuer: String = "Test CA",
        daysUntilExpiry: Int = 90
    ) -> SSLCertificateInfo {
        SSLCertificateInfo(
            commonName: commonName,
            subjectAltNames: [commonName],
            issuer: issuer,
            validFrom: referenceDate,
            validUntil: referenceDate.addingTimeInterval(Double(daysUntilExpiry) * 86_400),
            daysUntilExpiry: daysUntilExpiry,
            chainDepth: 1
        )
    }
}

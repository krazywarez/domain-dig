import Foundation

struct DomainInspectionService {
    private let reportBuilder = DomainReportBuilder()
    private let runtime: LookupRuntime

    init(runtime: LookupRuntime = .shared) {
        self.runtime = runtime
    }

    func inspect(domain: String, previousSnapshot: LookupSnapshot? = nil) async -> DomainReport {
        let snapshot = await inspectSnapshot(domain: domain, previousSnapshot: previousSnapshot)
        return reportBuilder.build(from: snapshot)
    }

    func inspectSnapshot(domain: String, previousSnapshot: LookupSnapshot? = nil) async -> LookupSnapshot {
        let normalizedDomain = normalize(domain)
        let inspectionStartedAt = DomainDebugLog.signpostStart("Inspection.inspectSnapshot", domain: normalizedDomain)
        let startedAt = Date()
        let resolverDisplayName = DNSLookupService.currentResolverDisplayName()
        let resolverURLString = DNSLookupService.currentResolverURLString()
        var ledger = InspectionLedger(resolverDisplayName: resolverDisplayName)

        async let dnsFetch = runtime.dns(domain: normalizedDomain)
        async let availabilityFetch = runtime.availability(domain: normalizedDomain)
        async let sslFetch = runtime.ssl(domain: normalizedDomain)
        async let hstsFetch = runtime.hsts(domain: normalizedDomain)
        async let httpFetch = runtime.http(domain: normalizedDomain)
        async let ownershipFetch = runtime.ownership(domain: normalizedDomain)
        async let redirectFetch = runtime.redirectChain(domain: normalizedDomain)
        async let subdomainFetch = runtime.subdomains(domain: normalizedDomain)

        let resolvedDNS = await dnsFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=dns source=\(resolvedDNS.source.rawValue)")
        let dnsResult = normalizeErrors(in: resolvedDNS.value)
        ledger.track(.dns, source: resolvedDNS.source)
        ledger.captureFailure(for: .dns, result: dnsResult)

        let availability = await availabilityFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=availability source=\(availability.source.rawValue)")
        ledger.track(.availability, source: availability.source)

        let resolvedSSL = await sslFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=ssl source=\(resolvedSSL.source.rawValue)")
        let sslResult = normalizeErrors(in: resolvedSSL.value)
        ledger.track(.ssl, source: resolvedSSL.source)
        ledger.captureFailure(for: .ssl, result: sslResult)

        let hsts = await hstsFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=hsts source=\(hsts.source.rawValue)")
        ledger.track(.hsts, source: hsts.source)

        let http = await httpFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=http source=\(http.source.rawValue)")
        let httpResult = normalizeErrors(in: http.value)
        ledger.track(.httpHeaders, source: http.source)
        ledger.captureFailure(for: .httpHeaders, result: httpResult)

        let resolvedOwnership = await ownershipFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=ownership source=\(resolvedOwnership.source.rawValue)")
        let ownershipResult = normalizeErrors(in: resolvedOwnership.value)
        ledger.track(.ownership, source: resolvedOwnership.source)
        ledger.captureFailure(for: .ownership, result: ownershipResult)

        let redirects = await redirectFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=redirect source=\(redirects.source.rawValue)")
        let redirectResult = normalizeErrors(in: redirects.value)
        ledger.track(.redirectChain, source: redirects.source)
        ledger.captureFailure(for: .redirectChain, result: redirectResult)

        let resolvedSubdomains = await subdomainFetch
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=subdomains source=\(resolvedSubdomains.source.rawValue)")
        let subdomainResult = normalizeErrors(in: resolvedSubdomains.value)
        ledger.track(.subdomains, source: resolvedSubdomains.source)
        ledger.captureFailure(for: .subdomains, result: subdomainResult)

        let dnsSections = mapServiceResult(dnsResult, emptyValue: [])
        let sslInfo = mapOptionalValueServiceResult(sslResult)
        let httpHeadersResult = mapHTTPResult(httpResult)
        let redirectChain = mapServiceResult(redirectResult, emptyValue: [])
        let ownership = mapOptionalValueServiceResult(ownershipResult)
        let subdomains = mapServiceResult(subdomainResult, emptyValue: [])

        let txtRecords = dnsSections.value.first(where: { $0.recordType == .TXT })?.records ?? []
        let primaryIP = dnsSections.value.first(where: { $0.recordType == .A })?.records.first?.value
        let hasNetworkTarget = dnsSections.value.contains { section in
            (section.recordType == .A || section.recordType == .AAAA)
                && (!section.records.isEmpty || !section.wildcardRecords.isEmpty)
        }
        let canReuseDNSDependents = canReuseDependentSections(from: previousSnapshot, dnsSections: dnsSections.value)
        let canReuseIPDependents = canReuseIPBasedSections(from: previousSnapshot, primaryIP: primaryIP)

        let reachabilityOutcome = await whenRoutable(hasNetworkTarget) {
            await runtime.reachability(domain: normalizedDomain)
        }
        let reachabilityResult = normalizeErrors(in: reachabilityOutcome.value)
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=reachability hasNetworkTarget=\(hasNetworkTarget) source=\(reachabilityOutcome.source.rawValue)")
        ledger.track(.reachability, source: reachabilityOutcome.source)
        if hasNetworkTarget {
            ledger.captureFailure(for: .reachability, result: reachabilityResult)
        }
        let reachabilityResultValue = mapServiceResult(reachabilityResult, emptyValue: [])

        let portScanOutcome = await whenRoutable(hasNetworkTarget) {
            await runtime.portScan(domain: normalizedDomain)
        }
        let portScanResult = normalizeErrors(in: portScanOutcome.value)
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=portScan hasNetworkTarget=\(hasNetworkTarget) source=\(portScanOutcome.source.rawValue)")
        ledger.track(.portScan, source: portScanOutcome.source)
        if hasNetworkTarget {
            ledger.captureFailure(for: .portScan, result: portScanResult)
        }
        let portScanResults = hasNetworkTarget
            ? await mapPortScanResult(portScanResult, domain: normalizedDomain)
            : (value: [], message: nil)

        let emailOutcome = await reusingPrevious(
            previousSnapshot?.emailSecurity,
            error: previousSnapshot?.emailSecurityError,
            when: canReuseDNSDependents
        ) {
            await runtime.email(domain: normalizedDomain, txtRecords: txtRecords)
        }
        let normalizedEmailResult = normalizeErrors(in: emailOutcome.value)
        DomainDebugLog.debug("Inspection.sectionComplete domain=\(normalizedDomain) section=email source=\(emailOutcome.source.rawValue)")
        ledger.track(.emailSecurity, source: emailOutcome.source)
        ledger.captureFailure(for: .emailSecurity, result: normalizedEmailResult)

        let suggestionsOutcome: CachedLookupResult<[DomainSuggestionResult]>
        if availability.value.status == .registered {
            suggestionsOutcome = await runtime.suggestions(domain: normalizedDomain)
            ledger.track(.suggestions, source: suggestionsOutcome.source)
        } else {
            suggestionsOutcome = CachedLookupResult(value: [], source: .live)
        }

        let ptrOutcome: CachedLookupResult<ServiceResult<String>>?
        let geoOutcome: CachedLookupResult<ServiceResult<IPGeolocation>>?
        if let primaryIP {
            let ptr = await reusingPrevious(
                previousSnapshot?.ptrRecord,
                error: previousSnapshot?.ptrError,
                when: canReuseIPDependents
            ) {
                await runtime.ptr(ip: primaryIP, resolverURLString: resolverURLString)
            }
            let geo = await reusingPrevious(
                previousSnapshot?.ipGeolocation,
                error: previousSnapshot?.ipGeolocationError,
                when: canReuseIPDependents
            ) {
                await runtime.ipGeolocation(ip: primaryIP)
            }
            ledger.track(.ptr, source: ptr.source)
            ledger.captureFailure(for: .ptr, result: normalizeErrors(in: ptr.value))
            ledger.track(.ipGeolocation, source: geo.source)
            ledger.captureFailure(for: .ipGeolocation, result: normalizeErrors(in: geo.value))
            ptrOutcome = ptr
            geoOutcome = geo
        } else {
            ptrOutcome = nil
            geoOutcome = nil
        }

        let emailSecurity = mapOptionalValueServiceResult(normalizedEmailResult)
        let ptrRecord = mapOptionalServiceResult(ptrOutcome.map { normalizeErrors(in: $0.value) }, missingMessage: "No A record available")
        let geolocation = mapOptionalServiceResult(geoOutcome.map { normalizeErrors(in: $0.value) }, missingMessage: "No A record available")
        let availabilityConfidence = confidenceForAvailability(result: availability.value, provenance: ledger.provenanceBySection[.availability])
        let ownershipConfidence = confidenceForOwnership(result: ownership.value)
        let subdomainConfidence = confidenceForSubdomains(results: subdomains.value)
        let emailConfidence = confidenceForEmail(result: emailSecurity.value)
        let geolocationConfidence = confidenceForGeolocation(result: geolocation.value)
        let validationIssues = validationIssues(for: normalizedDomain, snapshotTimestamp: startedAt, availability: availability.value, dnsSections: dnsSections.value, provenanceBySection: ledger.provenanceBySection)

        let snapshot = LookupSnapshot(
            historyEntryID: nil,
            domain: availability.value.domain,
            timestamp: Date(),
            trackedDomainID: previousSnapshot?.trackedDomainID,
            note: previousSnapshot?.note,
            appVersion: AppVersion.current,
            resolverDisplayName: resolverDisplayName,
            resolverURLString: resolverURLString,
            dataSources: Array(ledger.dataSources).sorted(),
            provenanceBySection: ledger.provenanceBySection,
            availabilityConfidence: availabilityConfidence,
            ownershipConfidence: ownershipConfidence,
            subdomainConfidence: subdomainConfidence,
            emailSecurityConfidence: emailConfidence,
            geolocationConfidence: geolocationConfidence,
            errorDetails: ledger.errorDetails,
            isPartialSnapshot: !validationIssues.isEmpty,
            validationIssues: validationIssues,
            totalLookupDurationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            snapshotIndex: nil,
            previousSnapshotID: previousSnapshot?.historyEntryID,
            changeCount: 0,
            severitySummary: nil,
            dnsSections: dnsSections.value,
            dnsError: dnsSections.message,
            availabilityResult: availability.value,
            suggestions: suggestionsOutcome.value,
            sslInfo: sslInfo.value,
            sslError: sslInfo.message,
            hstsPreloaded: hsts.value,
            httpHeaders: httpHeadersResult.headers,
            httpSecurityGrade: httpHeadersResult.securityGrade,
            httpStatusCode: httpHeadersResult.statusCode,
            httpResponseTimeMs: httpHeadersResult.responseTimeMs,
            httpProtocol: httpHeadersResult.httpProtocol,
            http3Advertised: httpHeadersResult.http3Advertised,
            httpHeadersError: httpHeadersResult.error,
            reachabilityResults: reachabilityResultValue.value,
            reachabilityError: reachabilityResultValue.message,
            ipGeolocation: geolocation.value,
            ipGeolocationError: geolocation.message,
            emailSecurity: emailSecurity.value,
            emailSecurityError: emailSecurity.message,
            ownership: ownership.value,
            ownershipError: ownership.message,
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
            ptrRecord: ptrRecord.value,
            ptrError: ptrRecord.message,
            redirectChain: redirectChain.value,
            redirectChainError: redirectChain.message,
            subdomains: subdomains.value,
            subdomainsError: subdomains.message,
            extendedSubdomains: [],
            extendedSubdomainsError: nil,
            dnsHistory: [],
            dnsHistoryError: nil,
            domainPricing: nil,
            domainPricingError: nil,
            reputation: nil,
            reputationError: nil,
            portScanResults: portScanResults.value,
            portScanError: portScanResults.message,
            changeSummary: nil,
            resultSource: aggregateSource(ledger.sectionSources),
            cachedSections: Array(ledger.cachedSections).sorted { $0.rawValue < $1.rawValue },
            statusMessage: nil
        )
        DomainDebugLog.signpostEnd(
            "Inspection.inspectSnapshot",
            start: inspectionStartedAt,
            domain: normalizedDomain,
            extra: "resultSource=\(snapshot.resultSource.rawValue) cachedSections=\(snapshot.cachedSections.count) partial=\(snapshot.isPartialSnapshot)"
        )
        return snapshot
    }

    private func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first?
            .lowercased() ?? domain.lowercased()
    }

    /// A lookup that needs an address to reach, or an empty result when the
    /// domain has none.
    private func whenRoutable<Value>(
        _ hasNetworkTarget: Bool,
        fetch: () async -> CachedLookupResult<ServiceResult<Value>>
    ) async -> CachedLookupResult<ServiceResult<Value>> {
        guard hasNetworkTarget else {
            return CachedLookupResult(value: .empty("No routable address available"), source: .live)
        }
        return await fetch()
    }

    /// The previous snapshot's value, or its error, when its section can be
    /// reused; otherwise a fresh lookup.
    private func reusingPrevious<Value>(
        _ value: Value?,
        error: String?,
        when reusable: Bool,
        otherwise fetch: () async -> CachedLookupResult<ServiceResult<Value>>
    ) async -> CachedLookupResult<ServiceResult<Value>> {
        if reusable, let value {
            return CachedLookupResult(value: .success(value), source: .cached)
        }
        if reusable, let error {
            return CachedLookupResult(value: .error(error), source: .cached)
        }
        return await fetch()
    }

    fileprivate static func provenance(
        for section: LookupSectionKind,
        source: LookupResultSource,
        collectedAt: Date,
        resolverDisplayName: String
    ) -> SectionProvenance {
        switch section {
        case .dns, .ptr:
            return SectionProvenance(
                source: "DNS-over-HTTPS query",
                collectedAt: collectedAt,
                provider: "Selected DoH resolver",
                resolver: resolverDisplayName,
                resultSource: source
            )
        case .availability:
            return SectionProvenance(
                source: "RDAP lookup with DNS fallback",
                collectedAt: collectedAt,
                provider: "rdap.org / selected resolver",
                resolver: resolverDisplayName,
                resultSource: source
            )
        case .ssl:
            return SectionProvenance(source: "Direct TLS handshake", collectedAt: collectedAt, provider: "Target host", resolver: nil, resultSource: source)
        case .hsts, .httpHeaders, .redirectChain:
            return SectionProvenance(source: "HTTP request", collectedAt: collectedAt, provider: "Target host", resolver: nil, resultSource: source)
        case .reachability:
            return SectionProvenance(source: "TCP reachability probe", collectedAt: collectedAt, provider: "Target host", resolver: nil, resultSource: source)
        case .ipGeolocation:
            return SectionProvenance(source: "IP geolocation lookup", collectedAt: collectedAt, provider: "ipapi.co", resolver: nil, resultSource: source)
        case .emailSecurity:
            return SectionProvenance(source: "DNS TXT inspection", collectedAt: collectedAt, provider: "Selected DoH resolver", resolver: resolverDisplayName, resultSource: source)
        case .ownership:
            return SectionProvenance(source: "RDAP domain lookup", collectedAt: collectedAt, provider: "rdap.org", resolver: nil, resultSource: source)
        case .subdomains:
            return SectionProvenance(source: "Certificate transparency search", collectedAt: collectedAt, provider: "crt.sh", resolver: nil, resultSource: source)
        case .portScan:
            return SectionProvenance(source: "TCP port scan", collectedAt: collectedAt, provider: "Target host", resolver: nil, resultSource: source)
        case .suggestions:
            return SectionProvenance(source: "Availability suggestions", collectedAt: collectedAt, provider: "DomainDig heuristic", resolver: resolverDisplayName, resultSource: source)
        }
    }

    private func aggregateSource(_ sectionSources: [LookupResultSource]) -> LookupResultSource {
        let normalizedSources = sectionSources.map { source -> LookupResultSource in
            source == .mixed ? .cached : source
        }

        let hasLive = normalizedSources.contains(.live)
        let hasCached = normalizedSources.contains(.cached)

        switch (hasLive, hasCached) {
        case (true, true):
            return .mixed
        case (false, true):
            return .cached
        default:
            return .live
        }
    }

    private func canReuseDependentSections(from previousSnapshot: LookupSnapshot?, dnsSections: [DNSSection]) -> Bool {
        guard let previousSnapshot else { return false }
        return dnsSignature(for: previousSnapshot.dnsSections) == dnsSignature(for: dnsSections)
    }

    private func canReuseIPBasedSections(from previousSnapshot: LookupSnapshot?, primaryIP: String?) -> Bool {
        guard let previousSnapshot else { return false }
        let previousIP = previousSnapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
        return primaryIP == previousIP
    }

    private func dnsSignature(for sections: [DNSSection]) -> String {
        sections
            .sorted { $0.recordType.rawValue < $1.recordType.rawValue }
            .map { section in
                let records = section.records
                    .sorted { $0.value < $1.value }
                    .map { "\($0.value)|\($0.ttl)" }
                    .joined(separator: ",")
                let wildcardRecords = section.wildcardRecords
                    .sorted { $0.value < $1.value }
                    .map { "\($0.value)|\($0.ttl)" }
                    .joined(separator: ",")
                return [
                    section.recordType.rawValue,
                    records,
                    wildcardRecords,
                    section.dnssecSigned.map { $0 ? "signed" : "unsigned" } ?? "unknown",
                    section.error ?? ""
                ].joined(separator: "#")
            }
            .joined(separator: "||")
    }

    private func normalizeErrors<Value>(in result: ServiceResult<Value>) -> ServiceResult<Value> {
        switch result {
        case let .success(value):
            return .success(value)
        case let .empty(message):
            return .empty(Self.classifyFailure(from: message, defaultKind: .unavailable).message)
        case let .error(message):
            return .error(Self.classifyFailure(from: message).message)
        }
    }

    fileprivate static func classifyFailure(from message: String, defaultKind: InspectionErrorKind = .unknown) -> InspectionFailure {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedMessage = normalizedMessage.lowercased()
        if lowercasedMessage.contains("timed out") {
            return InspectionFailure(kind: .timeout, message: "Timed out", details: normalizedMessage)
        }
        if lowercasedMessage.contains("429")
            || lowercasedMessage.contains("too many requests")
            || lowercasedMessage.contains("rate limit") {
            return InspectionFailure(kind: .rateLimited, message: "Rate limited", details: normalizedMessage)
        }
        if lowercasedMessage.contains("cannot parse")
            || lowercasedMessage.contains("decoding")
            || lowercasedMessage.contains("json") {
            return InspectionFailure(kind: .parsing, message: "Could not parse response", details: normalizedMessage)
        }
        if lowercasedMessage.contains("offline")
            || lowercasedMessage.contains("internet connection")
            || lowercasedMessage.contains("not connected")
            || lowercasedMessage.contains("network connection") {
            return InspectionFailure(kind: .network, message: "Network unavailable", details: normalizedMessage)
        }
        if lowercasedMessage.contains("unsupported") {
            return InspectionFailure(kind: .unsupported, message: "Unsupported for this target", details: normalizedMessage)
        }
        if lowercasedMessage == "unavailable" || lowercasedMessage.contains("no a record available") {
            return InspectionFailure(kind: .unavailable, message: normalizedMessage, details: nil)
        }
        if defaultKind == .unavailable {
            return InspectionFailure(kind: .unavailable, message: normalizedMessage, details: nil)
        }
        return InspectionFailure(kind: .unknown, message: normalizedMessage.isEmpty ? defaultKind.title : normalizedMessage, details: normalizedMessage)
    }

    private func confidenceForAvailability(result: DomainAvailabilityResult, provenance: SectionProvenance?) -> ConfidenceLevel {
        guard result.status != .unknown else { return .low }
        if provenance?.provider?.localizedCaseInsensitiveContains("rdap.org") == true, result.status == .registered {
            return .high
        }
        if result.status == .registered {
            return .medium
        }
        return .low
    }

    private func confidenceForOwnership(result: DomainOwnership?) -> ConfidenceLevel {
        guard let result else { return .low }
        let hasDirectRegistrationData = result.registrar != nil || result.createdDate != nil || result.expirationDate != nil
        return hasDirectRegistrationData ? .high : .medium
    }

    private func confidenceForSubdomains(results: [DiscoveredSubdomain]) -> ConfidenceLevel {
        if !results.isEmpty {
            return .medium
        }
        return .low
    }

    private func confidenceForEmail(result: EmailSecurityResult?) -> ConfidenceLevel {
        guard let result else { return .low }
        let foundCount = [result.spf.found, result.dmarc.found, result.dkim.found, result.bimi.found, result.mtaSts?.txtFound == true]
            .filter { $0 }
            .count
        if foundCount >= 3 {
            return .high
        }
        if foundCount >= 1 {
            return .medium
        }
        return .low
    }

    private func confidenceForGeolocation(result: IPGeolocation?) -> ConfidenceLevel {
        guard let result else { return .low }
        if result.city != nil && result.countryName != nil && result.latitude != nil && result.longitude != nil {
            return .high
        }
        if result.countryName != nil || result.org != nil {
            return .medium
        }
        return .low
    }

    private func validationIssues(
        for domain: String,
        snapshotTimestamp: Date,
        availability: DomainAvailabilityResult,
        dnsSections: [DNSSection],
        provenanceBySection: [LookupSectionKind: SectionProvenance]
    ) -> [String] {
        var issues: [String] = []
        if domain.isEmpty {
            issues.append("Missing normalized domain")
        }
        if availability.domain.isEmpty {
            issues.append("Missing normalized availability domain")
        }
        if dnsSections.isEmpty && provenanceBySection[.dns] == nil {
            issues.append("Missing DNS provenance")
        }
        if snapshotTimestamp > Date().addingTimeInterval(5) {
            issues.append("Snapshot timestamp is in the future")
        }
        return issues
    }

    private func mapServiceResult<Value>(_ result: ServiceResult<Value>, emptyValue: Value) -> (value: Value, message: String?) {
        switch result {
        case let .success(value):
            return (value, nil)
        case let .empty(message), let .error(message):
            return (emptyValue, message)
        }
    }

    private func mapOptionalValueServiceResult<Value>(_ result: ServiceResult<Value>) -> (value: Value?, message: String?) {
        switch result {
        case let .success(value):
            return (value, nil)
        case let .empty(message), let .error(message):
            return (nil, message)
        }
    }

    private func mapOptionalServiceResult<Value>(
        _ result: ServiceResult<Value>?,
        missingMessage: String
    ) -> (value: Value?, message: String?) {
        guard let result else {
            return (nil, missingMessage)
        }

        switch result {
        case let .success(value):
            return (value, nil)
        case let .empty(message), let .error(message):
            return (nil, message)
        }
    }

    private func mapPortScanResult(_ result: ServiceResult<[PortScanResult]>, domain: String) async -> (value: [PortScanResult], message: String?) {
        switch result {
        case let .success(results):
            return (await PortScanService.withBanners(results, host: domain), nil)
        case let .empty(message), let .error(message):
            return ([], message)
        }
    }

    private func mapHTTPResult(_ result: ServiceResult<HTTPHeadersResult>) -> (
        headers: [HTTPHeader],
        securityGrade: String?,
        statusCode: Int?,
        responseTimeMs: Int?,
        httpProtocol: String?,
        http3Advertised: Bool,
        error: String?
    ) {
        switch result {
        case let .success(value):
            return (
                headers: value.headers,
                securityGrade: HTTPSecurityGrade.grade(for: value.headers).rawValue,
                statusCode: value.statusCode,
                responseTimeMs: value.responseTimeMs,
                httpProtocol: value.httpProtocol,
                http3Advertised: value.http3Advertised,
                error: nil
            )
        case let .empty(message), let .error(message):
            return (
                headers: [],
                securityGrade: nil,
                statusCode: nil,
                responseTimeMs: nil,
                httpProtocol: nil,
                http3Advertised: false,
                error: message
            )
        }
    }
}

/// What an inspection has learned about its sections so far: where each came
/// from, which were served from cache, and which failed.
private struct InspectionLedger {
    let resolverDisplayName: String
    var cachedSections = Set<LookupSectionKind>()
    var sectionSources: [LookupResultSource] = []
    var provenanceBySection: [LookupSectionKind: SectionProvenance] = [:]
    var dataSources = Set<String>()
    var errorDetails: [LookupSectionKind: InspectionFailure] = [:]

    mutating func track(_ section: LookupSectionKind, source: LookupResultSource) {
        let provenance = DomainInspectionService.provenance(
            for: section,
            source: source,
            collectedAt: Date(),
            resolverDisplayName: resolverDisplayName
        )
        sectionSources.append(source)
        provenanceBySection[section] = provenance
        dataSources.insert(provenance.provider ?? provenance.source)
        if source != .live {
            cachedSections.insert(section)
        }
    }

    mutating func captureFailure<Value>(for section: LookupSectionKind, result: ServiceResult<Value>) {
        switch result {
        case .success:
            return
        case let .empty(message):
            errorDetails[section] = DomainInspectionService.classifyFailure(from: message, defaultKind: .unavailable)
        case let .error(message):
            errorDetails[section] = DomainInspectionService.classifyFailure(from: message)
        }
    }
}

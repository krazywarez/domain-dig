import Foundation

struct LookupSnapshot {
    let historyEntryID: UUID?
    let domain: String
    let timestamp: Date
    let trackedDomainID: UUID?
    let note: String?
    let appVersion: String
    let resolverDisplayName: String
    let resolverURLString: String
    let dataSources: [String]
    let provenanceBySection: [LookupSectionKind: SectionProvenance]
    let availabilityConfidence: ConfidenceLevel?
    let ownershipConfidence: ConfidenceLevel?
    let subdomainConfidence: ConfidenceLevel?
    let emailSecurityConfidence: ConfidenceLevel?
    let geolocationConfidence: ConfidenceLevel?
    let errorDetails: [LookupSectionKind: InspectionFailure]
    let isPartialSnapshot: Bool
    let validationIssues: [String]
    let totalLookupDurationMs: Int?
    let snapshotIndex: Int?
    let previousSnapshotID: UUID?
    let changeCount: Int
    let severitySummary: ChangeSeverity?
    let dnsSections: [DNSSection]
    let dnsError: String?
    let availabilityResult: DomainAvailabilityResult?
    let suggestions: [DomainSuggestionResult]
    let sslInfo: SSLCertificateInfo?
    let sslError: String?
    let hstsPreloaded: Bool?
    let httpHeaders: [HTTPHeader]
    let httpSecurityGrade: String?
    let httpStatusCode: Int?
    let httpResponseTimeMs: Int?
    let httpProtocol: String?
    let http3Advertised: Bool
    let httpHeadersError: String?
    let reachabilityResults: [PortReachability]
    let reachabilityError: String?
    let ipGeolocation: IPGeolocation?
    let ipGeolocationError: String?
    let emailSecurity: EmailSecurityResult?
    let emailSecurityError: String?
    let ownership: DomainOwnership?
    let ownershipError: String?
    let ownershipHistory: [DomainOwnershipHistoryEvent]
    let ownershipHistoryError: String?
    let inferredProvider: InferredProviderFingerprint?
    let priorProviders: [String]
    let domainClassification: DomainClassificationSummary?
    let ownershipTransitions: [OwnershipTransitionEvent]
    let hostingTransitions: [HostingTransitionEvent]
    let subdomainHistory: [SubdomainHistoryEntry]
    let riskSignals: [IntelligenceRiskSignal]
    let intelligenceTimeline: [IntelligenceTimelineEvent]
    let ptrRecord: String?
    let ptrError: String?
    let redirectChain: [RedirectHop]
    let redirectChainError: String?
    let subdomains: [DiscoveredSubdomain]
    let subdomainsError: String?
    let extendedSubdomains: [DiscoveredSubdomain]
    let extendedSubdomainsError: String?
    let dnsHistory: [DNSHistoryEvent]
    let dnsHistoryError: String?
    let domainPricing: DomainPricingInsight?
    let domainPricingError: String?
    let reputation: DomainReputationResult?
    let reputationError: String?
    let portScanResults: [PortScanResult]
    let portScanError: String?
    let changeSummary: DomainChangeSummary?
    let resultSource: LookupResultSource
    let cachedSections: [LookupSectionKind]
    let statusMessage: String?

    var isLive: Bool {
        resultSource == .live
    }
}

extension HistoryEntry {
    var snapshot: LookupSnapshot {
        LookupSnapshot(
            historyEntryID: id,
            domain: domain,
            timestamp: timestamp,
            trackedDomainID: trackedDomainID,
            note: note,
            appVersion: appVersion,
            resolverDisplayName: resolverDisplayName,
            resolverURLString: resolverURLString,
            dataSources: dataSources,
            provenanceBySection: provenanceBySection,
            availabilityConfidence: availabilityConfidence,
            ownershipConfidence: ownershipConfidence,
            subdomainConfidence: subdomainConfidence,
            emailSecurityConfidence: emailSecurityConfidence,
            geolocationConfidence: geolocationConfidence,
            errorDetails: errorDetails,
            isPartialSnapshot: isPartialSnapshot,
            validationIssues: validationIssues,
            totalLookupDurationMs: totalLookupDurationMs,
            snapshotIndex: snapshotIndex,
            previousSnapshotID: previousSnapshotID,
            changeCount: changeCount,
            severitySummary: severitySummary,
            dnsSections: dnsSections,
            dnsError: nil,
            availabilityResult: availabilityResult,
            suggestions: suggestions,
            sslInfo: sslInfo,
            sslError: sslError,
            hstsPreloaded: hstsPreloaded,
            httpHeaders: httpHeaders,
            httpSecurityGrade: HTTPSecurityGrade.grade(for: httpHeaders).rawValue,
            httpStatusCode: nil,
            httpResponseTimeMs: nil,
            httpProtocol: nil,
            http3Advertised: false,
            httpHeadersError: httpHeadersError,
            reachabilityResults: reachabilityResults,
            reachabilityError: reachabilityError,
            ipGeolocation: ipGeolocation,
            ipGeolocationError: ipGeolocationError,
            emailSecurity: emailSecurity,
            emailSecurityError: emailSecurityError,
            ownership: ownership,
            ownershipError: ownershipError,
            ownershipHistory: ownershipHistory,
            ownershipHistoryError: ownershipHistoryError,
            inferredProvider: inferredProvider,
            priorProviders: priorProviders,
            domainClassification: domainClassification,
            ownershipTransitions: ownershipTransitions,
            hostingTransitions: hostingTransitions,
            subdomainHistory: subdomainHistory,
            riskSignals: riskSignals,
            intelligenceTimeline: intelligenceTimeline,
            ptrRecord: ptrRecord,
            ptrError: ptrError,
            redirectChain: redirectChain,
            redirectChainError: redirectChainError,
            subdomains: subdomains,
            subdomainsError: subdomainsError,
            extendedSubdomains: extendedSubdomains,
            extendedSubdomainsError: extendedSubdomainsError,
            dnsHistory: dnsHistory,
            dnsHistoryError: dnsHistoryError,
            domainPricing: domainPricing,
            domainPricingError: domainPricingError,
            reputation: reputation,
            reputationError: reputationError,
            portScanResults: portScanResults,
            portScanError: portScanError,
            changeSummary: changeSummary,
            resultSource: resultSource,
            cachedSections: [],
            statusMessage: nil
        )
    }
}

extension LookupSnapshot {
    /// Whether every section that failed did so for want of a connection (a
    /// network error, a timeout, a rate limit) and nothing worth showing came
    /// back, so the last snapshot should stand in for this one.
    var needsFallback: Bool {
        let candidateMessages = [
            dnsError,
            httpHeadersError,
            sslError,
            ownershipError,
            subdomainsError,
            redirectChainError,
            ipGeolocationError
        ]
        .compactMap { $0?.lowercased() }

        guard !candidateMessages.isEmpty else { return false }
        let connectivityFailure = candidateMessages.allSatisfy { message in
            message.hasPrefix("network error:")
                || message.hasPrefix("timeout:")
                || message.hasPrefix("rate limit:")
        }

        let hasMaterialData = !dnsSections.isEmpty
            || !httpHeaders.isEmpty
            || sslInfo != nil
            || ownership != nil
            || !subdomains.isEmpty

        return connectivityFailure && !hasMaterialData
    }

    /// `previous`, marked as the last known result, when this lookup
    /// ``needsFallback``; otherwise this lookup.
    func resolvedAfterFallback(to previous: LookupSnapshot?) -> LookupSnapshot {
        guard needsFallback, let previous else {
            return self
        }

        return LookupSnapshot(
            historyEntryID: previous.historyEntryID,
            domain: previous.domain,
            timestamp: previous.timestamp,
            trackedDomainID: previous.trackedDomainID,
            note: previous.note,
            appVersion: previous.appVersion,
            resolverDisplayName: previous.resolverDisplayName,
            resolverURLString: previous.resolverURLString,
            dataSources: previous.dataSources,
            provenanceBySection: previous.provenanceBySection,
            availabilityConfidence: previous.availabilityConfidence,
            ownershipConfidence: previous.ownershipConfidence,
            subdomainConfidence: previous.subdomainConfidence,
            emailSecurityConfidence: previous.emailSecurityConfidence,
            geolocationConfidence: previous.geolocationConfidence,
            errorDetails: previous.errorDetails,
            isPartialSnapshot: previous.isPartialSnapshot,
            validationIssues: previous.validationIssues,
            totalLookupDurationMs: previous.totalLookupDurationMs,
            snapshotIndex: previous.snapshotIndex,
            previousSnapshotID: previous.previousSnapshotID,
            changeCount: previous.changeCount,
            severitySummary: previous.severitySummary,
            dnsSections: previous.dnsSections,
            dnsError: previous.dnsError,
            availabilityResult: previous.availabilityResult,
            suggestions: previous.suggestions,
            sslInfo: previous.sslInfo,
            sslError: previous.sslError,
            hstsPreloaded: previous.hstsPreloaded,
            httpHeaders: previous.httpHeaders,
            httpSecurityGrade: previous.httpSecurityGrade,
            httpStatusCode: previous.httpStatusCode,
            httpResponseTimeMs: previous.httpResponseTimeMs,
            httpProtocol: previous.httpProtocol,
            http3Advertised: previous.http3Advertised,
            httpHeadersError: previous.httpHeadersError,
            reachabilityResults: previous.reachabilityResults,
            reachabilityError: previous.reachabilityError,
            ipGeolocation: previous.ipGeolocation,
            ipGeolocationError: previous.ipGeolocationError,
            emailSecurity: previous.emailSecurity,
            emailSecurityError: previous.emailSecurityError,
            ownership: previous.ownership,
            ownershipError: previous.ownershipError,
            ownershipHistory: previous.ownershipHistory,
            ownershipHistoryError: previous.ownershipHistoryError,
            inferredProvider: previous.inferredProvider,
            priorProviders: previous.priorProviders,
            domainClassification: previous.domainClassification,
            ownershipTransitions: previous.ownershipTransitions,
            hostingTransitions: previous.hostingTransitions,
            subdomainHistory: previous.subdomainHistory,
            riskSignals: previous.riskSignals,
            intelligenceTimeline: previous.intelligenceTimeline,
            ptrRecord: previous.ptrRecord,
            ptrError: previous.ptrError,
            redirectChain: previous.redirectChain,
            redirectChainError: previous.redirectChainError,
            subdomains: previous.subdomains,
            subdomainsError: previous.subdomainsError,
            extendedSubdomains: previous.extendedSubdomains,
            extendedSubdomainsError: previous.extendedSubdomainsError,
            dnsHistory: previous.dnsHistory,
            dnsHistoryError: previous.dnsHistoryError,
            domainPricing: previous.domainPricing,
            domainPricingError: previous.domainPricingError,
            reputation: previous.reputation,
            reputationError: previous.reputationError,
            portScanResults: previous.portScanResults,
            portScanError: previous.portScanError,
            changeSummary: previous.changeSummary,
            resultSource: .snapshot,
            cachedSections: [],
            statusMessage: "Last known result • \(previous.timestamp.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

/// The metadata one inspection produced: where each section came from, how
/// confident it is, what failed, and whether the result is partial.
///
/// `DomainViewModel.currentSnapshot` used to recover all of this from the
/// *saved history entry*, so it was empty until the snapshot had been written
/// and `currentHistoryEntryID` pointed at it. Two consequences, both fixed by
/// carrying it from the lookup instead: the cards rendered without provenance
/// between applying a snapshot and saving it, and a lookup that returns before
/// saving — any partial or failed one — showed no provenance for any section,
/// which is the case where knowing the source matters most (A12).
struct InspectionMetadata: Equatable {
    var dataSources: [String]
    var provenanceBySection: [LookupSectionKind: SectionProvenance]
    var availabilityConfidence: ConfidenceLevel?
    var ownershipConfidence: ConfidenceLevel?
    var subdomainConfidence: ConfidenceLevel?
    var emailSecurityConfidence: ConfidenceLevel?
    var geolocationConfidence: ConfidenceLevel?
    var errorDetails: [LookupSectionKind: InspectionFailure]
    var isPartialSnapshot: Bool
    var validationIssues: [String]
    var snapshotIndex: Int?
    var previousSnapshotID: UUID?

    init(snapshot: LookupSnapshot) {
        dataSources = snapshot.dataSources
        provenanceBySection = snapshot.provenanceBySection
        availabilityConfidence = snapshot.availabilityConfidence
        ownershipConfidence = snapshot.ownershipConfidence
        subdomainConfidence = snapshot.subdomainConfidence
        emailSecurityConfidence = snapshot.emailSecurityConfidence
        geolocationConfidence = snapshot.geolocationConfidence
        errorDetails = snapshot.errorDetails
        isPartialSnapshot = snapshot.isPartialSnapshot
        validationIssues = snapshot.validationIssues
        snapshotIndex = snapshot.snapshotIndex
        previousSnapshotID = snapshot.previousSnapshotID
    }
}

/// Bulk input split into what will run and what will not.
struct ParsedBulkInput: Equatable {
    /// Valid domains, deduplicated, in the order they were written.
    var domains: [String]
    /// Entries that failed validation, as the user typed them.
    var skipped: [String]

    /// How many entries to name before falling back to a count. Naming them is
    /// the point — "two were skipped" does not tell anyone which to fix — but a
    /// pasted list of fifty typos should not become a wall of text.
    private static let namedLimit = 5

    /// What to tell the user, or `nil` when nothing was skipped.
    var skippedMessage: String? {
        guard !skipped.isEmpty else { return nil }

        let named = skipped.prefix(Self.namedLimit).joined(separator: ", ")
        let remainder = skipped.count - min(skipped.count, Self.namedLimit)
        let list = remainder > 0 ? "\(named) and \(remainder) more" : named

        if domains.isEmpty {
            return skipped.count == 1
                ? "\(list) is not a valid domain, so there is nothing to run."
                : "None of these is a valid domain, so there is nothing to run: \(list)."
        }
        return skipped.count == 1
            ? "Skipped \(list): not a valid domain."
            : "Skipped \(skipped.count) entries that are not valid domains: \(list)."
    }
}

import Foundation

struct DomainReport: Codable {
    let domain: String
    let timestamp: Date
    let provenance: DomainReportProvenance
    let appVersion: String
    let resolverDisplayName: String
    let resolverURLString: String
    let dataSources: [String]
    let resultSource: LookupResultSource
    let sectionProvenance: [LookupSectionKind: SectionProvenance]
    let errorDetails: [LookupSectionKind: InspectionFailure]
    let isPartialSnapshot: Bool
    let validationIssues: [String]
    let auditNote: String?
    let availability: DomainAvailabilityStatus
    let availabilityConfidence: ConfidenceLevel?
    let ownershipConfidence: ConfidenceLevel?
    let subdomainConfidence: ConfidenceLevel?
    let emailConfidence: ConfidenceLevel?
    let geolocationConfidence: ConfidenceLevel?
    let ownership: DomainOwnership?
    let ownershipHistory: [DomainOwnershipHistoryEvent]
    let inferredProvider: InferredProviderFingerprint?
    let priorProviders: [String]
    let domainClassification: DomainClassificationSummary?
    let ownershipTransitions: [OwnershipTransitionEvent]
    let hostingTransitions: [HostingTransitionEvent]
    let subdomainHistory: [SubdomainHistoryEntry]
    let riskSignals: [IntelligenceRiskSignal]
    let intelligenceTimeline: [IntelligenceTimelineEvent]
    let dns: DNSResultSummary
    let web: WebResultSummary
    let email: EmailSecuritySummary
    let network: NetworkSummary
    let subdomains: [String]
    let extendedSubdomains: [String]
    let dnsHistory: [DNSHistoryEvent]
    let domainPricing: DomainPricingInsight?
    let reputation: DomainReputationResult?
    let subdomainGroups: [SubdomainGroup]
    let riskAssessment: DomainRiskAssessment
    let insights: [String]
    let changeSummary: DomainChangeSummary?
    let lastChangeDate: Date?
    let health: DomainHealth
    let lastMonitoringFailure: Date?
    let instabilityScore: Int
    let certificateExpiryState: CertificateWarningLevel
    let workflowContext: DomainWorkflowContext?
    let metadata: DomainReportMetadata
}

struct DomainReportProvenance: Codable {
    let collectedAt: Date
    let source: LookupResultSource
    let sections: [LookupSectionKind: SectionProvenance]
    let dataSources: [String]
}

struct DomainWorkflowContext: Codable {
    let workflowID: UUID?
    let workflowName: String?
    let source: String
}

struct DomainReportMetadata: Codable {
    let schemaVersion: String
    let resolverDisplayName: String
    let resolverURLString: String
    let appVersion: String
    let cachedSections: [LookupSectionKind]
    let auditNote: String?
    let validationIssues: [String]
    let isPartialSnapshot: Bool
    let errorDetails: [LookupSectionKind: InspectionFailure]
    let statusMessage: String?
    let snapshotIndex: Int?
    let previousSnapshotID: UUID?
    let changeCount: Int
    let severitySummary: ChangeSeverity?
}

struct DNSResultSummary: Codable {
    let resolverDisplayName: String
    let resolverURLString: String
    let lookupDurationMs: Int?
    let recordSections: [DNSSection]
    let primaryIP: String?
    let ptrRecord: String?
    let dnssecSigned: Bool?
    let patternSummary: DNSPatternSummary
    let error: String?
    let ptrError: String?
}

struct WebResultSummary: Codable {
    let tls: SSLCertificateInfo?
    let tlsStatus: String
    let tlsGrade: TLSGrade
    let tlsHighlights: [String]
    let certificateWarningLevel: CertificateWarningLevel
    let hstsPreloaded: Bool?
    let headers: [HTTPHeader]
    let headerCount: Int
    let securityGrade: String?
    let statusCode: Int?
    let responseTimeMs: Int?
    let httpProtocol: String?
    let http3Advertised: Bool
    let redirectChain: [RedirectHop]
    let finalURL: String?
    let tlsError: String?
    let headersError: String?
    let redirectError: String?
}

struct EmailSecuritySummary: Codable {
    let records: EmailSecurityResult?
    let grade: EmailSecurityGrade?
    let reasons: [String]
    let summary: String
    let error: String?
}

struct NetworkSummary: Codable {
    let primaryIP: String?
    let reachability: [PortReachability]
    let reachabilitySummary: String
    let reachabilityError: String?
    let geolocation: IPGeolocation?
    let geolocationSummary: String
    let geolocationError: String?
    let portScan: [PortScanResult]
    let openPorts: [UInt16]
    let portScanError: String?
}

struct DomainReportBuilder {
    func build(
        from snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot? = nil,
        workflowContext: DomainWorkflowContext? = nil,
        historyEntries: [HistoryEntry] = [],
        deriveChangeSummary: Bool = true
    ) -> DomainReport {
        let buildStartedAt = DomainDebugLog.signpostStart("DomainReportBuilder.build", domain: snapshot.domain)
        let primaryIP = primaryIPAddress(from: snapshot)
        let analysis = DomainInsightEngine.analyze(snapshot: snapshot, previousSnapshot: previousSnapshot)
        let changeSummary: DomainChangeSummary?
        if let existingChangeSummary = snapshot.changeSummary, existingChangeSummary.riskAssessment != nil {
            changeSummary = existingChangeSummary
        } else if deriveChangeSummary, let previousSnapshot {
            let previousReport = build(
                from: previousSnapshot,
                workflowContext: workflowContext,
                historyEntries: historyEntries,
                deriveChangeSummary: false
            )
            let currentReport = buildBaseReport(
                from: snapshot,
                previousSnapshot: previousSnapshot,
                workflowContext: workflowContext,
                historyEntries: historyEntries,
                analysis: analysis,
                primaryIP: primaryIP,
                changeSummary: nil as DomainChangeSummary?
            )
            let diff = DiffService.compare(from: previousReport, to: currentReport)
            let changedItems = diff.sections.flatMap { $0.items }.filter { $0.hasChanges }
            let highlights = diff.changedSectionTitles
            let severity = changedItems.map { $0.severity }.max() ?? .low
            let message = DiffService.summaryMessage(from: highlights, changeCount: changedItems.count)
            let observedFacts = changedItems.prefix(4).map { item in
                "\(item.label): \(item.oldValue ?? "none") -> \(item.newValue ?? "none")"
            }
            let previousRiskScore = previousReport.riskAssessment.score
            let riskScoreDelta = analysis.riskAssessment.score - previousRiskScore
            let impactClassification = DomainInsightEngine.impactClassification(
                severity: severity,
                riskDelta: riskScoreDelta,
                changedSections: highlights
            )

            changeSummary = DomainChangeSummary(
                hasChanges: !changedItems.isEmpty,
                changedSections: highlights,
                message: message,
                severity: severity,
                impactClassification: impactClassification,
                generatedAt: snapshot.timestamp,
                observedFacts: observedFacts,
                inferredConclusions: highlights.isEmpty ? [] : [message],
                contextNote: diff.contextNote,
                riskAssessment: analysis.riskAssessment,
                insights: analysis.insights,
                riskScoreDelta: riskScoreDelta
            )
        } else {
            changeSummary = nil
        }

        let report = buildBaseReport(
            from: snapshot,
            previousSnapshot: previousSnapshot,
            workflowContext: workflowContext,
            historyEntries: historyEntries,
            analysis: analysis,
            primaryIP: primaryIP,
            changeSummary: changeSummary
        )
        DomainDebugLog.signpostEnd(
            "DomainReportBuilder.build",
            start: buildStartedAt,
            domain: snapshot.domain,
            extra: "risk=\(report.riskAssessment.score) insights=\(report.insights.count)"
        )
        return report
    }

    func build(
        from entry: HistoryEntry,
        previousSnapshot: LookupSnapshot? = nil,
        workflowContext: DomainWorkflowContext? = nil,
        historyEntries: [HistoryEntry] = [],
        deriveChangeSummary: Bool = true
    ) -> DomainReport {
        build(
            from: entry.snapshot,
            previousSnapshot: previousSnapshot,
            workflowContext: workflowContext,
            historyEntries: historyEntries,
            deriveChangeSummary: deriveChangeSummary
        )
    }

    private func buildBaseReport(
        from snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot?,
        workflowContext: DomainWorkflowContext?,
        historyEntries: [HistoryEntry],
        analysis: DomainAnalysisBundle,
        primaryIP: String?,
        changeSummary: DomainChangeSummary?
    ) -> DomainReport {
        let intelligence = DomainIntelligenceService.derive(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            historyEntries: historyEntries
        )
        let certificateExpiryState = DomainDiffService.certificateWarningLevel(for: snapshot)
        let recentChangeCount = changeSummary?.hasChanges == true ? 1 : 0
        let instabilityScore = DomainHealth.instabilityScore(
            recentChangeCount: recentChangeCount,
            recentFailureCount: 0,
            pendingAlertCount: 0,
            hasRecentDNSChange: changeSummary?.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("dns") }) == true
        )
        let hasInvalidTLS = snapshot.sslInfo == nil && snapshot.sslError != nil
        let isReachable = !snapshot.reachabilityResults.isEmpty
            ? snapshot.reachabilityResults.contains(where: \.reachable)
            : snapshot.reachabilityError == nil
        let health = DomainHealth.classify(
            certificateExpiryState: certificateExpiryState,
            isReachable: isReachable,
            recentMonitoringFailureCount: 0,
            hasRecentDNSChange: changeSummary?.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("dns") }) == true,
            instabilityScore: instabilityScore,
            hasRecentCriticalChange: changeSummary?.impactClassification == .critical,
            hasInvalidTLS: hasInvalidTLS
        )

        return DomainReport(
            domain: snapshot.domain,
            timestamp: snapshot.timestamp,
            provenance: DomainReportProvenance(
                collectedAt: snapshot.timestamp,
                source: snapshot.resultSource,
                sections: snapshot.provenanceBySection,
                dataSources: snapshot.dataSources
            ),
            appVersion: snapshot.appVersion,
            resolverDisplayName: snapshot.resolverDisplayName,
            resolverURLString: snapshot.resolverURLString,
            dataSources: snapshot.dataSources,
            resultSource: snapshot.resultSource,
            sectionProvenance: snapshot.provenanceBySection,
            errorDetails: snapshot.errorDetails,
            isPartialSnapshot: snapshot.isPartialSnapshot,
            validationIssues: snapshot.validationIssues,
            auditNote: snapshot.note,
            availability: snapshot.availabilityResult?.status ?? .unknown,
            availabilityConfidence: snapshot.availabilityConfidence,
            ownershipConfidence: snapshot.ownershipConfidence,
            subdomainConfidence: snapshot.subdomainConfidence,
            emailConfidence: snapshot.emailSecurityConfidence,
            geolocationConfidence: snapshot.geolocationConfidence,
            ownership: snapshot.ownership,
            ownershipHistory: snapshot.ownershipHistory,
            inferredProvider: intelligence.inferredProvider,
            priorProviders: intelligence.priorProviders,
            domainClassification: intelligence.domainClassification,
            ownershipTransitions: intelligence.ownershipTransitions,
            hostingTransitions: intelligence.hostingTransitions,
            subdomainHistory: intelligence.subdomainHistory,
            riskSignals: intelligence.riskSignals,
            intelligenceTimeline: intelligence.timelineEvents,
            dns: DNSResultSummary(
                resolverDisplayName: snapshot.resolverDisplayName,
                resolverURLString: snapshot.resolverURLString,
                lookupDurationMs: snapshot.totalLookupDurationMs,
                recordSections: snapshot.dnsSections,
                primaryIP: primaryIP,
                ptrRecord: snapshot.ptrRecord,
                dnssecSigned: dnssecSigned(from: snapshot),
                patternSummary: analysis.dnsPatterns,
                error: snapshot.dnsError,
                ptrError: snapshot.ptrError
            ),
            web: WebResultSummary(
                tls: snapshot.sslInfo,
                tlsStatus: tlsStatus(from: snapshot),
                tlsGrade: analysis.tlsAssessment.grade,
                tlsHighlights: analysis.tlsAssessment.highlights,
                certificateWarningLevel: DomainDiffService.certificateWarningLevel(for: snapshot),
                hstsPreloaded: snapshot.hstsPreloaded,
                headers: snapshot.httpHeaders,
                headerCount: snapshot.httpHeaders.count,
                securityGrade: snapshot.httpSecurityGrade,
                statusCode: snapshot.httpStatusCode,
                responseTimeMs: snapshot.httpResponseTimeMs,
                httpProtocol: snapshot.httpProtocol,
                http3Advertised: snapshot.http3Advertised,
                redirectChain: snapshot.redirectChain,
                finalURL: snapshot.redirectChain.last?.url,
                tlsError: snapshot.sslError,
                headersError: snapshot.httpHeadersError,
                redirectError: snapshot.redirectChainError
            ),
            email: EmailSecuritySummary(
                records: snapshot.emailSecurity,
                grade: analysis.emailAssessment?.grade,
                reasons: analysis.emailAssessment?.reasons ?? [],
                summary: emailSummary(from: snapshot, assessment: analysis.emailAssessment),
                error: snapshot.emailSecurityError
            ),
            network: NetworkSummary(
                primaryIP: primaryIP,
                reachability: snapshot.reachabilityResults,
                reachabilitySummary: reachabilitySummary(from: snapshot),
                reachabilityError: snapshot.reachabilityError,
                geolocation: snapshot.ipGeolocation,
                geolocationSummary: geolocationSummary(from: snapshot),
                geolocationError: snapshot.ipGeolocationError,
                portScan: snapshot.portScanResults,
                openPorts: snapshot.portScanResults.filter(\.open).map(\.port),
                portScanError: snapshot.portScanError
            ),
            subdomains: snapshot.subdomains.map(\.hostname),
            extendedSubdomains: snapshot.extendedSubdomains.map(\.hostname),
            dnsHistory: snapshot.dnsHistory,
            domainPricing: snapshot.domainPricing,
            reputation: snapshot.reputation,
            subdomainGroups: analysis.subdomainGroups,
            riskAssessment: analysis.riskAssessment,
            insights: analysis.insights,
            changeSummary: changeSummary,
            lastChangeDate: changeSummary?.hasChanges == true ? snapshot.timestamp : nil,
            health: health,
            lastMonitoringFailure: nil,
            instabilityScore: instabilityScore,
            certificateExpiryState: certificateExpiryState,
            workflowContext: workflowContext,
            metadata: DomainReportMetadata(
                schemaVersion: "4.3.0",
                resolverDisplayName: snapshot.resolverDisplayName,
                resolverURLString: snapshot.resolverURLString,
                appVersion: snapshot.appVersion,
                cachedSections: snapshot.cachedSections,
                auditNote: snapshot.note,
                validationIssues: snapshot.validationIssues,
                isPartialSnapshot: snapshot.isPartialSnapshot,
                errorDetails: snapshot.errorDetails,
                statusMessage: snapshot.statusMessage,
                snapshotIndex: snapshot.snapshotIndex,
                previousSnapshotID: snapshot.previousSnapshotID ?? previousSnapshot?.historyEntryID,
                changeCount: snapshot.changeCount == 0 ? (changeSummary?.changedSections.count ?? 0) : snapshot.changeCount,
                severitySummary: snapshot.severitySummary ?? changeSummary?.severity
            )
        )
    }

    private func primaryIPAddress(from snapshot: LookupSnapshot) -> String? {
        snapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    private func dnssecSigned(from snapshot: LookupSnapshot) -> Bool? {
        snapshot.dnsSections.compactMap(\.dnssecSigned).first
    }

    private func tlsStatus(from snapshot: LookupSnapshot) -> String {
        if snapshot.sslInfo != nil {
            return "valid"
        }
        if let sslError = snapshot.sslError {
            return sslError.localizedCaseInsensitiveContains("certificate") ? "invalid" : "failed"
        }
        return "unavailable"
    }

    private func emailSummary(from snapshot: LookupSnapshot, assessment: EmailSecurityAssessment?) -> String {
        guard let emailSecurity = snapshot.emailSecurity else {
            return snapshot.emailSecurityError ?? "Unavailable"
        }

        return [
            "Grade \(assessment?.grade.rawValue ?? "?")",
            "SPF \(emailSecurity.spf.found ? "Yes" : "No")",
            "DMARC \(emailSecurity.dmarc.found ? "Yes" : "No")",
            "DKIM \(emailSecurity.dkim.found ? "Yes" : "No")",
            "BIMI \(emailSecurity.bimi.found ? "Yes" : "No")",
            "MTA-STS \(emailSecurity.mtaSts?.txtFound == true ? "Yes" : "No")"
        ].joined(separator: " / ")
    }

    private func reachabilitySummary(from snapshot: LookupSnapshot) -> String {
        guard !snapshot.reachabilityResults.isEmpty else {
            return snapshot.reachabilityError ?? "Unavailable"
        }

        return snapshot.reachabilityResults
            .sorted { $0.port < $1.port }
            .map { "\($0.port):\($0.reachable ? "open" : "closed")" }
            .joined(separator: ", ")
    }

    private func geolocationSummary(from snapshot: LookupSnapshot) -> String {
        guard let geolocation = snapshot.ipGeolocation else {
            return snapshot.ipGeolocationError ?? "Unavailable"
        }

        let parts = [geolocation.city, geolocation.region, geolocation.countryName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        return geolocation.ip
    }
}

struct DerivedDomainIntelligence {
    let inferredProvider: InferredProviderFingerprint?
    let priorProviders: [String]
    let domainClassification: DomainClassificationSummary?
    let ownershipTransitions: [OwnershipTransitionEvent]
    let hostingTransitions: [HostingTransitionEvent]
    let subdomainHistory: [SubdomainHistoryEntry]
    let riskSignals: [IntelligenceRiskSignal]
    let timelineEvents: [IntelligenceTimelineEvent]
}

enum DomainIntelligenceService {
    static func derive(
        snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot? = nil,
        historyEntries: [HistoryEntry]
    ) -> DerivedDomainIntelligence {
        let orderedHistory = historyEntries
            .filter { $0.domain.caseInsensitiveCompare(snapshot.domain) == .orderedSame }
            .sorted { $0.timestamp < $1.timestamp }
        let observationSnapshots = mergeObservations(historyEntries: orderedHistory, currentSnapshot: snapshot)
        let providerObservations = observationSnapshots.compactMap { observation -> (Date, InferredProviderFingerprint)? in
            inferProvider(from: observation).map { (observation.timestamp, $0) }
        }
        let currentProvider = inferProvider(from: snapshot)
        let priorProviders = Array(Set(providerObservations.dropLast().map { $0.1.name })).sorted()
        let ownershipTransitions = ownershipTransitions(from: observationSnapshots)
        let hostingTransitions = hostingTransitions(from: providerObservations)
        let currentClassification = classify(snapshot: snapshot)
        let subdomainHistory = buildSubdomainHistory(from: observationSnapshots)
        let riskSignals = buildRiskSignals(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            ownershipTransitions: ownershipTransitions,
            hostingTransitions: hostingTransitions,
            subdomainHistory: subdomainHistory
        )
        let timelineEvents = buildTimelineEvents(
            snapshot: snapshot,
            observations: observationSnapshots,
            providerObservations: providerObservations,
            ownershipTransitions: ownershipTransitions,
            hostingTransitions: hostingTransitions,
            riskSignals: riskSignals
        )
        return DerivedDomainIntelligence(
            inferredProvider: currentProvider,
            priorProviders: priorProviders,
            domainClassification: currentClassification,
            ownershipTransitions: ownershipTransitions,
            hostingTransitions: hostingTransitions,
            subdomainHistory: subdomainHistory,
            riskSignals: riskSignals,
            timelineEvents: timelineEvents
        )
    }

    private static func mergeObservations(historyEntries: [HistoryEntry], currentSnapshot: LookupSnapshot) -> [LookupSnapshot] {
        var snapshots = historyEntries.map(\.snapshot)
        let alreadyIncluded = snapshots.contains {
            $0.timestamp == currentSnapshot.timestamp && $0.domain.caseInsensitiveCompare(currentSnapshot.domain) == .orderedSame
        }
        if !alreadyIncluded {
            snapshots.append(currentSnapshot)
        }
        return snapshots.sorted { $0.timestamp < $1.timestamp }
    }

    private static func inferProvider(from snapshot: LookupSnapshot) -> InferredProviderFingerprint? {
        // A stored or imported snapshot can repeat a header name in another case.
        let headerMap = Dictionary(snapshot.httpHeaders.map { ($0.name.lowercased(), $0.value.lowercased()) }) { first, _ in first }
        let dnsProviders = dnsValues(for: .NS, in: snapshot.dnsSections) + dnsValues(for: .CNAME, in: snapshot.dnsSections)
        let issuer = snapshot.sslInfo?.issuer.lowercased() ?? ""
        let org = snapshot.ipGeolocation?.org?.lowercased() ?? ""

        if headerMap["cf-ray"] != nil || containsAny(in: dnsProviders, matching: ["cloudflare"]) || issuer.contains("cloudflare") {
            return provider("Cloudflare", confidence: .high, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["cf-ray", "cloudflare"]))
        }
        if headerMap["x-vercel-id"] != nil || containsAny(in: dnsProviders, matching: ["vercel"]) {
            return provider("Vercel", confidence: .high, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["x-vercel-id", "vercel"]))
        }
        if containsHeaderValue(headerMap, value: "netlify") || containsAny(in: dnsProviders, matching: ["netlify"]) {
            return provider("Netlify", confidence: .medium, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["netlify"]))
        }
        if containsHeaderValue(headerMap, value: "fastly") || headerMap["x-served-by"]?.contains("cache") == true {
            return provider("Fastly", confidence: .medium, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["fastly", "x-served-by"]))
        }
        if headerMap["x-amz-cf-id"] != nil || containsHeaderValue(headerMap, value: "cloudfront") || containsAny(in: dnsProviders, matching: ["cloudfront.net"]) {
            return provider("CloudFront", confidence: .high, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["x-amz-cf-id", "cloudfront"]))
        }
        if containsAny(in: dnsProviders, matching: ["awsdns", "amazonaws.com"]) || org.contains("amazon") {
            return provider("AWS", confidence: .medium, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["awsdns", "amazon"]))
        }
        if containsAny(in: dnsProviders, matching: ["github.io"]) || containsHeaderValue(headerMap, value: "github") {
            return provider("GitHub Pages", confidence: .medium, evidence: providerEvidence(headerMap: headerMap, dnsProviders: dnsProviders, matches: ["github"]))
        }
        return nil
    }

    private static func classify(snapshot: LookupSnapshot) -> DomainClassificationSummary? {
        let host = snapshot.domain.lowercased()
        let headerValues = snapshot.httpHeaders.map { "\($0.name.lowercased()):\($0.value.lowercased())" }
        let finalURL = snapshot.redirectChain.last?.url.lowercased() ?? ""

        if host.hasPrefix("api.") || host.contains(".api.") {
            return .init(kind: .api, confidence: .high, reasons: ["Hostname pattern"])
        }
        if containsAny(in: [host, finalURL], matching: ["auth", "login", "sso", "oauth"]) {
            return .init(kind: .auth, confidence: .high, reasons: ["Auth-oriented host or redirect"])
        }
        if containsAny(in: [host, finalURL], matching: ["docs", "developer", "developers", "help"]) {
            return .init(kind: .docs, confidence: .high, reasons: ["Docs-oriented host or redirect"])
        }
        if containsAny(in: [host, finalURL], matching: ["status", "statuspage", "health"]) {
            return .init(kind: .status, confidence: .medium, reasons: ["Status-oriented host or redirect"])
        }
        if containsAny(in: [host], matching: ["cdn.", "static.", "assets.", "img."]) {
            return .init(kind: .staticSite, confidence: .medium, reasons: ["Static asset hostname"])
        }
        if containsAny(in: [host], matching: ["app.", "portal.", "admin.", "dashboard."]) {
            return .init(kind: .app, confidence: .medium, reasons: ["Application hostname"])
        }
        if containsAny(in: [host], matching: ["vpn.", "internal.", "infra."]) || headerValues.contains(where: { $0.contains("x-envoy") }) {
            return .init(kind: .infrastructure, confidence: .medium, reasons: ["Infrastructure-oriented hostname or headers"])
        }
        if host == apexDomain(for: host) || host.hasPrefix("www.") {
            return .init(kind: .marketing, confidence: .low, reasons: ["Apex or www host"])
        }
        return nil
    }

    private static func ownershipTransitions(from snapshots: [LookupSnapshot]) -> [OwnershipTransitionEvent] {
        zip(snapshots, snapshots.dropFirst()).compactMap { previous, current in
            guard let previousOwnership = previous.ownership, let currentOwnership = current.ownership else {
                return nil
            }
            var changeParts: [String] = []
            if previousOwnership.registrar != currentOwnership.registrar {
                changeParts.append("registrar")
            }
            if previousOwnership.registrant != currentOwnership.registrant {
                changeParts.append("ownership")
            }
            if normalized(previousOwnership.nameservers) != normalized(currentOwnership.nameservers) {
                changeParts.append("nameservers")
            }
            guard !changeParts.isEmpty else { return nil }
            return OwnershipTransitionEvent(
                date: current.timestamp,
                summary: "Changed \(changeParts.joined(separator: ", "))",
                previousRegistrar: previousOwnership.registrar,
                currentRegistrar: currentOwnership.registrar,
                previousRegistrant: previousOwnership.registrant,
                currentRegistrant: currentOwnership.registrant,
                previousNameservers: previousOwnership.nameservers,
                currentNameservers: currentOwnership.nameservers
            )
        }
        .sorted { $0.date > $1.date }
    }

    private static func hostingTransitions(from observations: [(Date, InferredProviderFingerprint)]) -> [HostingTransitionEvent] {
        zip(observations, observations.dropFirst()).compactMap { previous, current in
            guard previous.1.name != current.1.name else { return nil }
            return HostingTransitionEvent(
                date: current.0,
                fromProvider: previous.1.name,
                toProvider: current.1.name,
                summary: "Hosting moved from \(previous.1.name) to \(current.1.name)"
            )
        }
        .sorted { $0.date > $1.date }
    }

    private static func buildSubdomainHistory(from snapshots: [LookupSnapshot]) -> [SubdomainHistoryEntry] {
        var states: [String: SubdomainPresence] = [:]
        for snapshot in snapshots {
            let currentHosts = Set((snapshot.subdomains + snapshot.extendedSubdomains).map { $0.hostname.lowercased() })
            let knownHosts = Set(states.keys).union(currentHosts)
            for host in knownHosts {
                let isPresent = currentHosts.contains(host)
                if states[host] != nil {
                    states[host]?.observe(isPresent: isPresent, at: snapshot.timestamp)
                } else if isPresent {
                    states[host] = SubdomainPresence(firstSeen: snapshot.timestamp)
                }
            }
        }

        return states.map { host, state in state.entry(hostname: host) }
            .sorted { lhs, rhs in
                if lhs.isEphemeral != rhs.isEphemeral {
                    return lhs.isEphemeral && !rhs.isEphemeral
                }
                return lhs.hostname < rhs.hostname
            }
    }

    /// One subdomain's presence across a run of snapshots, from the first that saw it.
    private struct SubdomainPresence {
        var firstSeen: Date
        var lastSeen: Date
        var recurrenceCount = 1
        var statusChangeCount = 0
        var lastSeenInPreviousSnapshot = true

        init(firstSeen: Date) {
            self.firstSeen = firstSeen
            lastSeen = firstSeen
        }

        mutating func observe(isPresent: Bool, at timestamp: Date) {
            if isPresent {
                lastSeen = timestamp
                recurrenceCount += 1
            }
            if lastSeenInPreviousSnapshot != isPresent {
                statusChangeCount += 1
            }
            lastSeenInPreviousSnapshot = isPresent
        }

        func entry(hostname: String) -> SubdomainHistoryEntry {
            SubdomainHistoryEntry(
                hostname: hostname,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                recurrenceCount: recurrenceCount,
                statusChangeCount: statusChangeCount,
                lastKnownStatus: lastSeenInPreviousSnapshot ? "Active" : "Inactive",
                isEphemeral: recurrenceCount <= 2 || statusChangeCount >= 2
            )
        }
    }

    private static func buildRiskSignals(
        snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot?,
        ownershipTransitions: [OwnershipTransitionEvent],
        hostingTransitions: [HostingTransitionEvent],
        subdomainHistory: [SubdomainHistoryEntry]
    ) -> [IntelligenceRiskSignal] {
        var signals: [IntelligenceRiskSignal] = []
        let dnsInstabilityCount = snapshot.dnsHistory.filter { !$0.changedRecordTypes.isEmpty }.count
        let ephemeralSubdomains = subdomainHistory.filter(\.isEphemeral)

        if ownershipTransitions.count >= 2 {
            signals.append(.init(
                id: "ownership-churn",
                title: "Ownership churn",
                detail: "Observed \(ownershipTransitions.count) ownership transitions in local history.",
                severity: .high,
                firstObserved: ownershipTransitions.last?.date,
                lastObserved: ownershipTransitions.first?.date
            ))
        }
        if dnsInstabilityCount >= 3 {
            signals.append(.init(
                id: "unstable-dns",
                title: "Unstable DNS",
                detail: "DNS history shows \(dnsInstabilityCount) recorded change events.",
                severity: .medium,
                firstObserved: snapshot.dnsHistory.last?.date,
                lastObserved: snapshot.dnsHistory.first?.date
            ))
        }
        if hostingTransitions.count >= 2 {
            signals.append(.init(
                id: "repeated-hosting-moves",
                title: "Repeated hosting moves",
                detail: "Infrastructure provider changed \(hostingTransitions.count) times across observations.",
                severity: .medium,
                firstObserved: hostingTransitions.last?.date,
                lastObserved: hostingTransitions.first?.date
            ))
        }
        if !ephemeralSubdomains.isEmpty {
            signals.append(.init(
                id: "ephemeral-subdomains",
                title: "Ephemeral subdomains",
                detail: "\(ephemeralSubdomains.count) subdomains appear short-lived or unstable.",
                severity: ephemeralSubdomains.count >= 3 ? .medium : .low,
                firstObserved: ephemeralSubdomains.map(\.firstSeen).min(),
                lastObserved: ephemeralSubdomains.map(\.lastSeen).max()
            ))
        }
        if let createdDate = snapshot.ownership?.createdDate {
            let ageDays = Calendar.current.dateComponents([.day], from: createdDate, to: snapshot.timestamp).day ?? 0
            if ageDays <= 180 {
                signals.append(.init(
                    id: "young-registration",
                    title: "Short registration age",
                    detail: "Domain registration is \(ageDays) days old.",
                    severity: ageDays <= 90 ? .high : .medium,
                    firstObserved: createdDate,
                    lastObserved: snapshot.timestamp
                ))
            }
        }
        if let previousSnapshot,
           let previousProvider = inferProvider(from: previousSnapshot)?.name,
           let currentProvider = inferProvider(from: snapshot)?.name,
           previousProvider != currentProvider {
            signals.append(.init(
                id: "recent-hosting-move",
                title: "Recent hosting move",
                detail: "Latest snapshot moved from \(previousProvider) to \(currentProvider).",
                severity: .medium,
                firstObserved: snapshot.timestamp,
                lastObserved: snapshot.timestamp
            ))
        }
        return signals.sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) }
    }

    private static func buildTimelineEvents(
        snapshot: LookupSnapshot,
        observations: [LookupSnapshot],
        providerObservations: [(Date, InferredProviderFingerprint)],
        ownershipTransitions: [OwnershipTransitionEvent],
        hostingTransitions: [HostingTransitionEvent],
        riskSignals: [IntelligenceRiskSignal]
    ) -> [IntelligenceTimelineEvent] {
        var events: [IntelligenceTimelineEvent] = []

        events += ownershipTransitions.map {
            .init(date: $0.date, category: .ownership, title: "Ownership transition", detail: $0.summary, severity: .high)
        }
        events += snapshot.dnsHistory.map {
            .init(date: $0.date, category: .dns, title: "DNS change", detail: $0.summary, severity: $0.changedRecordTypes.contains(.A) || $0.changedRecordTypes.contains(.NS) ? .high : .medium)
        }
        events += hostingTransitions.map {
            .init(date: $0.date, category: .hosting, title: "Hosting transition", detail: $0.summary, severity: .medium)
        }
        events += buildClassificationEvents(from: observations)
        events += buildSubdomainDiscoveryEvents(from: observations)
        events += riskSignals.compactMap {
            guard let date = $0.lastObserved ?? $0.firstObserved else { return nil }
            return IntelligenceTimelineEvent(date: date, category: .risk, title: $0.title, detail: $0.detail, severity: $0.severity)
        }
        if let latestProvider = providerObservations.last?.1 {
            events.append(.init(
                date: snapshot.timestamp,
                category: .hosting,
                title: "Current infrastructure",
                detail: "Likely running on \(latestProvider.name)",
                severity: .low
            ))
        }
        return events.sorted { $0.date > $1.date }
    }

    private static func buildClassificationEvents(from observations: [LookupSnapshot]) -> [IntelligenceTimelineEvent] {
        let classifications = observations.compactMap { snapshot -> (Date, DomainClassificationSummary)? in
            classify(snapshot: snapshot).map { (snapshot.timestamp, $0) }
        }
        return zip(classifications, classifications.dropFirst()).compactMap { previous, current in
            guard previous.1.kind != current.1.kind else { return nil }
            return .init(
                date: current.0,
                category: .classification,
                title: "Classification changed",
                detail: "\(previous.1.kind.title) -> \(current.1.kind.title)",
                severity: .medium
            )
        }
    }

    private static func buildSubdomainDiscoveryEvents(from observations: [LookupSnapshot]) -> [IntelligenceTimelineEvent] {
        var seen = Set<String>()
        var events: [IntelligenceTimelineEvent] = []
        for snapshot in observations {
            let hosts = Set((snapshot.subdomains + snapshot.extendedSubdomains).map { $0.hostname.lowercased() })
            for host in hosts where seen.insert(host).inserted {
                events.append(.init(
                    date: snapshot.timestamp,
                    category: .subdomain,
                    title: "Subdomain observed",
                    detail: host,
                    severity: .low
                ))
            }
        }
        return events
    }

    private static func provider(_ name: String, confidence: ConfidenceLevel, evidence: [String]) -> InferredProviderFingerprint {
        .init(name: name, confidence: confidence, evidence: evidence)
    }

    private static func providerEvidence(headerMap: [String: String], dnsProviders: [String], matches: [String]) -> [String] {
        var evidence: [String] = []
        for match in matches {
            if headerMap.keys.contains(match) || headerMap.values.contains(where: { $0.contains(match) }) {
                evidence.append("HTTP \(match)")
            }
            if dnsProviders.contains(where: { $0.lowercased().contains(match) }) {
                evidence.append("DNS \(match)")
            }
        }
        return Array(Set(evidence)).sorted()
    }

    private static func dnsValues(for type: DNSRecordType, in sections: [DNSSection]) -> [String] {
        sections
            .first(where: { $0.recordType == type })?
            .records
            .map(\.value) ?? []
    }

    private static func normalized(_ values: [String]) -> [String] {
        values.map { $0.lowercased() }.sorted()
    }

    private static func containsAny(in values: [String], matching patterns: [String]) -> Bool {
        values.contains { value in
            let normalized = value.lowercased()
            return patterns.contains { normalized.contains($0) }
        }
    }

    private static func containsHeaderValue(_ headerMap: [String: String], value: String) -> Bool {
        headerMap.values.contains(where: { $0.contains(value) })
    }

    private static func apexDomain(for host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }
}

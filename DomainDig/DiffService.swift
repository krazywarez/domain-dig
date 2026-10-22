import Foundation

enum DiffChangeType: String, Codable {
    case added
    case removed
    case changed
    case unchanged

    var marker: String {
        switch self {
        case .added:
            return "+"
        case .removed:
            return "-"
        case .changed:
            return "~"
        case .unchanged:
            return "="
        }
    }

    var title: String {
        switch self {
        case .added:
            return "Added"
        case .removed:
            return "Removed"
        case .changed:
            return "Changed"
        case .unchanged:
            return "Unchanged"
        }
    }
}

struct DiffItem: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    let changeType: DiffChangeType
    let oldValue: String?
    let newValue: String?
    let severity: ChangeSeverity

    init(
        id: String,
        label: String,
        changeType: DiffChangeType,
        oldValue: String?,
        newValue: String?,
        severity: ChangeSeverity
    ) {
        self.id = id
        self.label = label
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.severity = severity
    }

    var hasChanges: Bool {
        changeType != .unchanged
    }
}

struct DiffSection: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let items: [DiffItem]

    var hasChanges: Bool {
        items.contains(where: \.hasChanges)
    }

    var severity: ChangeSeverity {
        items.map(\.severity).max() ?? .low
    }

    var changeCount: Int {
        items.filter(\.hasChanges).count
    }
}

struct DomainDiff: Identifiable, Equatable, Codable {
    let domain: String
    let fromTimestamp: Date
    let toTimestamp: Date
    let sections: [DiffSection]
    let changedSectionIDs: [String]
    let changedSectionTitles: [String]
    let contextNote: String?

    var id: String {
        "\(domain)-\(fromTimestamp.timeIntervalSince1970)-\(toTimestamp.timeIntervalSince1970)"
    }

    var changeCount: Int {
        sections.reduce(0) { $0 + $1.changeCount }
    }

    var severity: ChangeSeverity {
        sections.map(\.severity).max() ?? .low
    }
}

typealias DomainDiffItem = DiffItem
typealias DomainDiffSection = DiffSection

/// Result of comparing two distinct domains' latest reports side by side, as
/// opposed to `DomainDiff`, which compares the same domain across time.
struct DomainComparisonResult: Identifiable, Equatable {
    let domainA: String
    let domainB: String
    let generatedAt: Date
    let sections: [DiffSection]
    let contextNote: String?

    var id: String {
        "\(domainA)-\(domainB)-\(generatedAt.timeIntervalSince1970)"
    }

    var changedSections: [DiffSection] {
        sections.filter(\.hasChanges)
    }

    var changeCount: Int {
        sections.reduce(0) { $0 + $1.changeCount }
    }

    var severity: ChangeSeverity {
        sections.map(\.severity).max() ?? .low
    }
}

enum DiffService {
    static func compare(from oldReport: DomainReport, to newReport: DomainReport) -> DomainDiff {
        let sections = [
            availabilitySection(from: oldReport, to: newReport),
            ownershipSection(from: oldReport, to: newReport),
            dnsSection(from: oldReport, to: newReport),
            webSection(from: oldReport, to: newReport),
            emailSection(from: oldReport, to: newReport),
            networkSection(from: oldReport, to: newReport),
            subdomainsSection(from: oldReport, to: newReport),
            intelligenceSection(from: oldReport, to: newReport),
            riskSection(from: oldReport, to: newReport)
        ]

        let changedSections = sections.filter(\.hasChanges)
        return DomainDiff(
            domain: newReport.domain,
            fromTimestamp: oldReport.timestamp,
            toTimestamp: newReport.timestamp,
            sections: sections,
            changedSectionIDs: changedSections.map(\.id),
            changedSectionTitles: changedSections.map(\.title),
            contextNote: comparisonContextNote(from: oldReport, to: newReport)
        )
    }

    static func compare(from oldSnapshot: LookupSnapshot, to newSnapshot: LookupSnapshot) -> DomainDiff {
        let builder = DomainReportBuilder()
        let oldReport = builder.build(from: oldSnapshot, deriveChangeSummary: false)
        let newReport = builder.build(from: newSnapshot, previousSnapshot: oldSnapshot, deriveChangeSummary: false)
        return compare(from: oldReport, to: newReport)
    }

    static func summary(
        from oldSnapshot: LookupSnapshot,
        to newSnapshot: LookupSnapshot,
        generatedAt: Date = Date(),
        riskAssessment: DomainRiskAssessment? = nil,
        insights: [String]? = nil
    ) -> DomainChangeSummary {
        let diff = compare(from: oldSnapshot, to: newSnapshot)
        let changedItems = diff.sections.flatMap(\.items).filter(\.hasChanges)
        let highlights = diff.changedSectionTitles
        let severity = changedItems.map(\.severity).max() ?? .low
        let message = summaryMessage(from: highlights, changeCount: changedItems.count)
        let observedFacts = changedItems.prefix(4).map { item in
            "\(item.label): \(item.oldValue ?? "none") -> \(item.newValue ?? "none")"
        }

        let analysis = DomainInsightEngine.analyze(snapshot: newSnapshot, previousSnapshot: oldSnapshot)
        let currentRiskAssessment = riskAssessment ?? analysis.riskAssessment
        let currentInsights = insights ?? analysis.insights
        let previousRiskScore = DomainInsightEngine.analyze(snapshot: oldSnapshot).riskAssessment.score
        let riskScoreDelta = currentRiskAssessment.score - previousRiskScore
        let impactClassification = DomainInsightEngine.impactClassification(
            severity: severity,
            riskDelta: riskScoreDelta,
            changedSections: highlights
        )

        return DomainChangeSummary(
            hasChanges: !changedItems.isEmpty,
            changedSections: highlights,
            message: message,
            severity: severity,
            impactClassification: impactClassification,
            generatedAt: generatedAt,
            observedFacts: observedFacts,
            inferredConclusions: highlights.isEmpty ? [] : [message],
            contextNote: diff.contextNote,
            riskAssessment: currentRiskAssessment,
            insights: currentInsights,
            riskScoreDelta: riskScoreDelta
        )
    }

    /// Compares two distinct domains' reports section by section. Reuses the same
    /// field-level diff logic as time-based comparison; the two reports are simply
    /// unrelated domains rather than the same domain at different times.
    static func compare(domainA: DomainReport, domainB: DomainReport) -> DomainComparisonResult {
        let sections = [
            availabilitySection(from: domainA, to: domainB),
            ownershipSection(from: domainA, to: domainB),
            dnsSection(from: domainA, to: domainB),
            webSection(from: domainA, to: domainB),
            emailSection(from: domainA, to: domainB),
            networkSection(from: domainA, to: domainB),
            subdomainsSection(from: domainA, to: domainB),
            intelligenceSection(from: domainA, to: domainB),
            riskSection(from: domainA, to: domainB)
        ]

        return DomainComparisonResult(
            domainA: domainA.domain,
            domainB: domainB.domain,
            generatedAt: Date(),
            sections: sections,
            contextNote: comparisonContextNote(from: domainA, to: domainB)
        )
    }

    static func comparisonContextNote(from oldReport: DomainReport, to newReport: DomainReport) -> String? {
        var notes: [String] = []
        if oldReport.resolverURLString != newReport.resolverURLString {
            notes.append("Compared snapshots used different DNS resolvers.")
        }
        if oldReport.resultSource != newReport.resultSource {
            notes.append("Compared snapshots came from different collection modes.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    static func comparisonContextNote(from oldSnapshot: LookupSnapshot, to newSnapshot: LookupSnapshot) -> String? {
        comparisonContextNote(
            from: DomainReportBuilder().build(from: oldSnapshot, deriveChangeSummary: false),
            to: DomainReportBuilder().build(from: newSnapshot, previousSnapshot: oldSnapshot, deriveChangeSummary: false)
        )
    }

    static func certificateWarningLevel(for snapshot: LookupSnapshot) -> CertificateWarningLevel {
        guard let days = snapshot.sslInfo?.daysUntilExpiry else {
            return .none
        }
        if days < 14 {
            return .critical
        }
        if days < 30 {
            return .warning
        }
        return .none
    }

    private static func availabilitySection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "availability",
            title: "Domain / Availability",
            items: [
                compare(id: "domain", label: "Domain", oldValue: oldReport.domain, newValue: newReport.domain, severity: .low),
                compare(
                    id: "availability",
                    label: "Availability",
                    oldValue: availabilityLabel(oldReport.availability),
                    newValue: availabilityLabel(newReport.availability),
                    severity: .high
                ),
                compare(id: "primary-ip", label: "Primary IP", oldValue: oldReport.dns.primaryIP, newValue: newReport.dns.primaryIP, severity: .high),
                compare(
                    id: "tls-status",
                    label: "TLS Status",
                    oldValue: oldReport.web.tlsStatus,
                    newValue: newReport.web.tlsStatus,
                    severity: .medium
                )
            ].compactMap { $0 }
        )
    }

    private static func ownershipSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "ownership",
            title: "Ownership",
            items: [
                compare(id: "registrar", label: "Registrar", oldValue: oldReport.ownership?.registrar, newValue: newReport.ownership?.registrar, severity: .high),
                compare(id: "registrant", label: "Registrant", oldValue: oldReport.ownership?.registrant, newValue: newReport.ownership?.registrant, severity: .medium),
                compare(
                    id: "ownership-created",
                    label: "Registration Date",
                    oldValue: ownershipDateLabel(oldReport.ownership?.createdDate),
                    newValue: ownershipDateLabel(newReport.ownership?.createdDate),
                    severity: .low
                ),
                compare(
                    id: "ownership-expires",
                    label: "Expiration Date",
                    oldValue: ownershipDateLabel(oldReport.ownership?.expirationDate),
                    newValue: ownershipDateLabel(newReport.ownership?.expirationDate),
                    severity: .medium
                ),
                compare(
                    id: "ownership-status",
                    label: "Status",
                    oldValue: joined(oldReport.ownership?.status),
                    newValue: joined(newReport.ownership?.status),
                    severity: .low
                ),
                compare(
                    id: "ownership-nameservers",
                    label: "Nameservers",
                    oldValue: joined(oldReport.ownership?.nameservers),
                    newValue: joined(newReport.ownership?.nameservers),
                    severity: .medium
                ),
                compare(id: "ownership-abuse", label: "Abuse Contact", oldValue: oldReport.ownership?.abuseEmail, newValue: newReport.ownership?.abuseEmail, severity: .low)
            ].compactMap { $0 }
        )
    }

    private static func dnsSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        // Imported reports are not guaranteed one section per record type.
        let oldSections = Dictionary(oldReport.dns.recordSections.map { ($0.recordType, $0) }) { first, _ in first }
        let newSections = Dictionary(newReport.dns.recordSections.map { ($0.recordType, $0) }) { first, _ in first }
        let recordTypes = Set(oldSections.keys).union(newSections.keys).sorted { $0.rawValue < $1.rawValue }

        var items: [DiffItem] = [
            compare(id: "dnssec", label: "DNSSEC", oldValue: dnssecLabel(oldReport.dns.dnssecSigned), newValue: dnssecLabel(newReport.dns.dnssecSigned), severity: .medium),
            compare(id: "ptr", label: "PTR", oldValue: oldReport.dns.ptrRecord, newValue: newReport.dns.ptrRecord, severity: .low)
        ].compactMap { $0 }

        for type in recordTypes {
            items.append(
                compare(
                    id: "dns-\(type.rawValue.lowercased())-records",
                    label: "\(type.rawValue) Records",
                    oldValue: normalizedRecordValues(for: oldSections[type]),
                    newValue: normalizedRecordValues(for: newSections[type]),
                    severity: type == .A || type == .NS ? .high : .medium
                ) ?? DiffItem(id: "", label: "", changeType: .unchanged, oldValue: nil, newValue: nil, severity: .low)
            )
            if let ttlChange = compare(
                id: "dns-\(type.rawValue.lowercased())-ttl",
                label: "\(type.rawValue) TTL",
                oldValue: normalizedTTLValues(for: oldSections[type]),
                newValue: normalizedTTLValues(for: newSections[type]),
                severity: .low
            ) {
                items.append(ttlChange)
            }
        }

        return DiffSection(
            id: "dns",
            title: "DNS",
            items: items.filter { !$0.id.isEmpty }
        )
    }

    private static func webSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "web",
            title: "Web",
            items: [
                compare(id: "web-status", label: "HTTP Status", oldValue: oldReport.web.statusCode.map(String.init), newValue: newReport.web.statusCode.map(String.init), severity: .medium),
                compare(id: "web-grade", label: "Security Grade", oldValue: oldReport.web.securityGrade, newValue: newReport.web.securityGrade, severity: .medium),
                compare(id: "web-final-url", label: "Final URL", oldValue: oldReport.web.finalURL, newValue: newReport.web.finalURL, severity: .high),
                compare(id: "web-tls-issuer", label: "TLS Issuer", oldValue: oldReport.web.tls?.issuer, newValue: newReport.web.tls?.issuer, severity: .medium),
                compare(id: "web-tls-expiry", label: "TLS Expiration", oldValue: expirationLabel(oldReport.web.tls), newValue: expirationLabel(newReport.web.tls), severity: .medium),
                compare(id: "web-headers", label: "Headers", oldValue: normalizedHeaders(oldReport.web.headers), newValue: normalizedHeaders(newReport.web.headers), severity: .low),
                compare(id: "web-redirects", label: "Redirect Chain", oldValue: redirectChainSummary(oldReport.web.redirectChain), newValue: redirectChainSummary(newReport.web.redirectChain), severity: .medium)
            ].compactMap { $0 }
        )
    }

    private static func emailSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "email",
            title: "Email Security",
            items: [
                compare(id: "email-summary", label: "Summary", oldValue: oldReport.email.summary, newValue: newReport.email.summary, severity: .medium),
                compare(id: "email-grade", label: "Grade", oldValue: oldReport.email.grade?.rawValue, newValue: newReport.email.grade?.rawValue, severity: .medium),
                compare(id: "email-spf", label: "SPF", oldValue: recordLabel(oldReport.email.records?.spf), newValue: recordLabel(newReport.email.records?.spf), severity: .medium),
                compare(id: "email-dmarc", label: "DMARC", oldValue: recordLabel(oldReport.email.records?.dmarc), newValue: recordLabel(newReport.email.records?.dmarc), severity: .high),
                compare(id: "email-dkim", label: "DKIM", oldValue: recordLabel(oldReport.email.records?.dkim), newValue: recordLabel(newReport.email.records?.dkim), severity: .medium),
                compare(id: "email-bimi", label: "BIMI", oldValue: recordLabel(oldReport.email.records?.bimi), newValue: recordLabel(newReport.email.records?.bimi), severity: .low),
                compare(id: "email-mta-sts", label: "MTA-STS", oldValue: mtaStsLabel(oldReport.email.records?.mtaSts), newValue: mtaStsLabel(newReport.email.records?.mtaSts), severity: .medium)
            ].compactMap { $0 }
        )
    }

    private static func networkSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "network",
            title: "Network",
            items: [
                compare(id: "network-reachability", label: "Reachability", oldValue: oldReport.network.reachabilitySummary, newValue: newReport.network.reachabilitySummary, severity: .medium),
                compare(id: "network-geolocation", label: "Geolocation", oldValue: oldReport.network.geolocationSummary, newValue: newReport.network.geolocationSummary, severity: .medium),
                compare(id: "network-open-ports", label: "Open Ports", oldValue: joined(oldReport.network.openPorts.map(String.init)), newValue: joined(newReport.network.openPorts.map(String.init)), severity: .high),
                compare(id: "network-port-scan", label: "Port Scan", oldValue: portScanSummary(oldReport.network.portScan), newValue: portScanSummary(newReport.network.portScan), severity: .medium)
            ].compactMap { $0 }
        )
    }

    private static func subdomainsSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "subdomains",
            title: "Subdomains",
            items: [
                compare(id: "subdomains-primary", label: "Primary Subdomains", oldValue: joined(oldReport.subdomains), newValue: joined(newReport.subdomains), severity: .low),
                compare(id: "subdomains-extended", label: "Extended Subdomains", oldValue: joined(oldReport.extendedSubdomains), newValue: joined(newReport.extendedSubdomains), severity: .low),
                compare(id: "subdomains-groups", label: "Groups", oldValue: groupSummary(oldReport.subdomainGroups), newValue: groupSummary(newReport.subdomainGroups), severity: .low)
            ].compactMap { $0 }
        )
    }

    private static func riskSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "risk",
            title: "Risk / Insights",
            items: [
                compare(id: "risk-score", label: "Risk Score", oldValue: "\(oldReport.riskAssessment.score)", newValue: "\(newReport.riskAssessment.score)", severity: .high),
                compare(id: "risk-level", label: "Risk Level", oldValue: oldReport.riskAssessment.level.title, newValue: newReport.riskAssessment.level.title, severity: .high),
                compare(id: "risk-factors", label: "Risk Factors", oldValue: joined(oldReport.riskAssessment.factors.map(\.description)), newValue: joined(newReport.riskAssessment.factors.map(\.description)), severity: .medium),
                compare(id: "risk-insights", label: "Insights", oldValue: joined(oldReport.insights), newValue: joined(newReport.insights), severity: .medium)
            ].compactMap { $0 }
        )
    }

    private static func intelligenceSection(from oldReport: DomainReport, to newReport: DomainReport) -> DiffSection {
        DiffSection(
            id: "intelligence",
            title: "Data+ Intelligence",
            items: [
                compare(id: "intel-provider", label: "Provider", oldValue: oldReport.inferredProvider?.name, newValue: newReport.inferredProvider?.name, severity: .medium),
                compare(id: "intel-classification", label: "Classification", oldValue: oldReport.domainClassification?.kind.title, newValue: newReport.domainClassification?.kind.title, severity: .medium),
                compare(id: "intel-hosting-history", label: "Hosting Transitions", oldValue: joined(oldReport.hostingTransitions.map(\.summary)), newValue: joined(newReport.hostingTransitions.map(\.summary)), severity: .medium),
                compare(id: "intel-ownership-history", label: "Ownership Transitions", oldValue: joined(oldReport.ownershipTransitions.map(\.summary)), newValue: joined(newReport.ownershipTransitions.map(\.summary)), severity: .high),
                compare(id: "intel-risk-signals", label: "Risk Signals", oldValue: joined(oldReport.riskSignals.map(\.title)), newValue: joined(newReport.riskSignals.map(\.title)), severity: .medium)
            ].compactMap { $0 }
        )
    }

    private static func compare(
        id: String,
        label: String,
        oldValue: String?,
        newValue: String?,
        severity: ChangeSeverity
    ) -> DiffItem? {
        let oldValue = normalized(oldValue)
        let newValue = normalized(newValue)

        guard oldValue != nil || newValue != nil else {
            return nil
        }

        let changeType: DiffChangeType
        switch (oldValue?.lowercased(), newValue?.lowercased()) {
        case let (old?, new?) where old == new:
            changeType = .unchanged
        case (nil, _?):
            changeType = .added
        case (_?, nil):
            changeType = .removed
        default:
            changeType = .changed
        }

        return DiffItem(
            id: id,
            label: label,
            changeType: changeType,
            oldValue: oldValue,
            newValue: newValue,
            severity: severity
        )
    }

    static func summaryMessage(from sectionTitles: [String], changeCount: Int) -> String {
        guard !sectionTitles.isEmpty else {
            return "No meaningful changes"
        }
        if sectionTitles.count == 1 {
            return "\(sectionTitles[0]) changed"
        }
        return "\(sectionTitles[0]) and \(sectionTitles[1].lowercased()) changed (\(changeCount) items)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func availabilityLabel(_ status: DomainAvailabilityStatus) -> String {
        switch status {
        case .available:
            return "Available"
        case .registered:
            return "Registered"
        case .unknown:
            return "Unknown"
        }
    }

    private static func ownershipDateLabel(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .omitted)
    }

    private static func expirationLabel(_ certificate: SSLCertificateInfo?) -> String? {
        guard let certificate else { return nil }
        return "\(certificate.validUntil.formatted(date: .abbreviated, time: .omitted)) (\(certificate.daysUntilExpiry)d)"
    }

    private static func joined(_ values: [String]?) -> String? {
        guard let values else { return nil }
        let normalizedValues = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return normalizedValues.isEmpty ? nil : normalizedValues.joined(separator: ", ")
    }

    private static func normalizedRecordValues(for section: DNSSection?) -> String? {
        guard let section else { return nil }
        let values = (section.records + section.wildcardRecords)
            .map(\.value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .sorted()
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func normalizedTTLValues(for section: DNSSection?) -> String? {
        guard let section else { return nil }
        let values = (section.records + section.wildcardRecords)
            .map { "\($0.value.lowercased()):\($0.ttl)" }
            .sorted()
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func normalizedHeaders(_ headers: [HTTPHeader]) -> String? {
        let values = headers
            .map { "\($0.name.lowercased()): \($0.value.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .sorted()
        return values.isEmpty ? nil : values.joined(separator: " | ")
    }

    private static func redirectChainSummary(_ redirects: [RedirectHop]) -> String? {
        let values = redirects.map { "\($0.statusCode) \($0.url)" }
        return values.isEmpty ? nil : values.joined(separator: " -> ")
    }

    private static func portScanSummary(_ results: [PortScanResult]) -> String? {
        let values = results
            .sorted { $0.port < $1.port }
            .map { "\($0.port):\($0.open ? "open" : "closed")" }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func groupSummary(_ groups: [SubdomainGroup]) -> String? {
        joined(groups.map { "\($0.label): \($0.subdomains.count)" })
    }

    private static func recordLabel(_ record: EmailSecurityRecord?) -> String? {
        guard let record else { return nil }
        if record.found {
            return record.value ?? "Present"
        }
        return "Missing"
    }

    private static func mtaStsLabel(_ result: MTASTSResult?) -> String? {
        guard let result else { return nil }
        guard result.txtFound else { return "Missing" }
        return result.policyMode ?? "Present"
    }

    private static func dnssecLabel(_ value: Bool?) -> String? {
        switch value {
        case true:
            return "Signed"
        case false:
            return "Unsigned"
        case nil:
            return nil
        }
    }
}

enum DomainDiffService {
    static func diff(from oldSnapshot: LookupSnapshot, to newSnapshot: LookupSnapshot) -> [DomainDiffSection] {
        DiffService.compare(from: oldSnapshot, to: newSnapshot).sections
    }

    static func summary(
        from oldSnapshot: LookupSnapshot,
        to newSnapshot: LookupSnapshot,
        generatedAt: Date = Date(),
        riskAssessment: DomainRiskAssessment? = nil,
        insights: [String]? = nil
    ) -> DomainChangeSummary {
        DiffService.summary(
            from: oldSnapshot,
            to: newSnapshot,
            generatedAt: generatedAt,
            riskAssessment: riskAssessment,
            insights: insights
        )
    }

    static func comparisonContextNote(from oldSnapshot: LookupSnapshot, to newSnapshot: LookupSnapshot) -> String? {
        DiffService.comparisonContextNote(from: oldSnapshot, to: newSnapshot)
    }

    static func certificateWarningLevel(for snapshot: LookupSnapshot) -> CertificateWarningLevel {
        DiffService.certificateWarningLevel(for: snapshot)
    }
}

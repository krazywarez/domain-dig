import Foundation

enum RiskLevel: String, Codable {
    case low
    case medium
    case high

    var title: String { rawValue.capitalized }
}

enum RiskImpact: String, Codable {
    case positive
    case neutral
    case negative
}

struct RiskFactor: Codable, Equatable {
    let description: String
    let impact: RiskImpact
}

struct DomainRiskAssessment: Codable, Equatable {
    let score: Int
    let level: RiskLevel
    let factors: [RiskFactor]
}

enum ChangeImpactClassification: String, Codable {
    case informational
    case warning
    case critical

    var title: String { rawValue.capitalized }
}

enum EmailSecurityGrade: String, Codable {
    case a = "A"
    case b = "B"
    case c = "C"
    case f = "F"
}

struct EmailSecurityAssessment: Codable, Equatable {
    let grade: EmailSecurityGrade
    let reasons: [String]
}

enum TLSGrade: String, Codable {
    case a = "A"
    case b = "B"
    case c = "C"
    case f = "F"
}

struct TLSSummaryAssessment: Codable, Equatable {
    let grade: TLSGrade
    let highlights: [String]
}

struct DNSPatternSummary: Codable, Equatable {
    let providers: [String]
    let wildcardDetected: Bool
    let patterns: [String]
}

struct SubdomainGroup: Codable, Equatable, Identifiable {
    let label: String
    let subdomains: [String]

    var id: String { label }
}

struct WorkflowInsight: Codable, Equatable, Identifiable {
    let description: String
    let domainsInvolved: [String]

    var id: String {
        ([description] + domainsInvolved.sorted()).joined(separator: "|")
    }
}

struct DomainAnalysisBundle {
    let riskAssessment: DomainRiskAssessment
    let insights: [String]
    let dnsPatterns: DNSPatternSummary
    let emailAssessment: EmailSecurityAssessment?
    let tlsAssessment: TLSSummaryAssessment
    let subdomainGroups: [SubdomainGroup]
}

enum DomainInsightEngine {
    static func analyze(snapshot: LookupSnapshot, previousSnapshot: LookupSnapshot? = nil) -> DomainAnalysisBundle {
        let dnsPatterns = dnsPatterns(for: snapshot)
        let emailAssessment = emailAssessment(for: snapshot.emailSecurity)
        let tlsAssessment = tlsAssessment(for: snapshot)
        let subdomainGroups = groupedSubdomains(from: snapshot.subdomains.map(\.hostname))
        let riskAssessment = riskAssessment(
            for: snapshot,
            previousSnapshot: previousSnapshot,
            dnsPatterns: dnsPatterns,
            emailAssessment: emailAssessment,
            tlsAssessment: tlsAssessment,
            subdomainGroups: subdomainGroups
        )
        let insights = insights(
            for: snapshot,
            previousSnapshot: previousSnapshot,
            dnsPatterns: dnsPatterns,
            emailAssessment: emailAssessment,
            tlsAssessment: tlsAssessment,
            subdomainGroups: subdomainGroups
        )

        return DomainAnalysisBundle(
            riskAssessment: riskAssessment,
            insights: insights,
            dnsPatterns: dnsPatterns,
            emailAssessment: emailAssessment,
            tlsAssessment: tlsAssessment,
            subdomainGroups: subdomainGroups
        )
    }

    static func workflowInsights(for reports: [DomainReport]) -> [WorkflowInsight] {
        var insights: [WorkflowInsight] = []

        appendSharedInsights(
            title: "Shared IP address observed",
            groups: groupedDomains(for: reports, keyPath: \.dns.primaryIP),
            into: &insights
        )
        appendSharedInsights(
            title: "Shared nameserver set detected",
            groups: groupedDomains(for: reports) {
                let value = $0.ownership?.nameservers.sorted().joined(separator: "|")
                return value?.nilIfBlank
            },
            into: &insights
        )
        appendSharedInsights(
            title: "Shared registrar detected",
            groups: groupedDomains(for: reports) { $0.ownership?.registrar?.nilIfBlank },
            into: &insights
        )
        appendSharedInsights(
            title: "Shared TLS issuer detected",
            groups: groupedDomains(for: reports) { $0.web.tls?.issuer.nilIfBlank },
            into: &insights
        )

        return insights
    }

    static func impactClassification(
        severity: ChangeSeverity,
        riskDelta: Int,
        changedSections: [String]
    ) -> ChangeImpactClassification {
        if severity == .high || riskDelta >= 20 || changedSections.contains(where: {
            $0.localizedCaseInsensitiveContains("availability")
                || $0.localizedCaseInsensitiveContains("certificate expires")
        }) {
            return .critical
        }
        if severity == .medium || riskDelta >= 8 || !changedSections.isEmpty {
            return .warning
        }
        return .informational
    }

    private static func riskAssessment(
        for snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot?,
        dnsPatterns: DNSPatternSummary,
        emailAssessment: EmailSecurityAssessment?,
        tlsAssessment: TLSSummaryAssessment,
        subdomainGroups: [SubdomainGroup]
    ) -> DomainRiskAssessment {
        var tally = RiskTally()
        scoreAvailability(snapshot, into: &tally)
        scoreDNS(snapshot, patterns: dnsPatterns, into: &tally)
        scoreTLS(snapshot, assessment: tlsAssessment, into: &tally)
        scoreRedirects(snapshot, into: &tally)
        scoreEmail(snapshot, assessment: emailAssessment, into: &tally)
        scorePorts(snapshot, into: &tally)
        scoreSubdomains(snapshot, groups: subdomainGroups, into: &tally)
        scoreGeolocation(snapshot, into: &tally)
        // Compares against the score so far, so it runs after the snapshot's own factors.
        if let previousSnapshot {
            let delta = tally.score - analyze(snapshot: previousSnapshot).riskAssessment.score
            if delta >= 15 {
                tally.add(4, "Observed risk has increased materially since the previous snapshot", .negative)
            }
        }

        let clampedScore = min(max(tally.score, 0), 100)
        let level: RiskLevel
        switch clampedScore {
        case 0..<35:
            level = .low
        case 35..<65:
            level = .medium
        default:
            level = .high
        }

        return DomainRiskAssessment(score: clampedScore, level: level, factors: tally.factors)
    }

    /// A risk score in progress, from a baseline of 18, and the factors behind it.
    private struct RiskTally {
        var score = 18
        var factors: [RiskFactor] = []

        mutating func add(_ points: Int, _ description: String, _ impact: RiskImpact) {
            score += points
            factors.append(RiskFactor(description: description, impact: impact))
        }
    }

    private static func scoreAvailability(_ snapshot: LookupSnapshot, into tally: inout RiskTally) {
        switch snapshot.availabilityResult?.status ?? .unknown {
        case .available:
            tally.add(-12, "Domain appears available rather than actively deployed", .positive)
        case .unknown:
            tally.add(8, "Ownership and availability could not be confirmed", .negative)
        case .registered:
            if !snapshot.dnsSections.isEmpty || snapshot.sslInfo != nil || !snapshot.redirectChain.isEmpty {
                tally.add(6, "Registered domain exposes active infrastructure", .negative)
            } else {
                tally.add(0, "Registered domain with limited active surface detected", .neutral)
            }
        }
    }

    private static func scoreDNS(_ snapshot: LookupSnapshot, patterns: DNSPatternSummary, into tally: inout RiskTally) {
        let recordTypes = snapshot.dnsSections.filter { !$0.records.isEmpty || !$0.wildcardRecords.isEmpty }.count
        if recordTypes >= 5 {
            tally.add(8, "DNS configuration is broad across multiple record types", .negative)
        }
        if patterns.wildcardDetected {
            tally.add(12, "Wildcard DNS is enabled", .negative)
        }
        if let firstPattern = patterns.patterns.first {
            tally.add(0, firstPattern, .neutral)
        }
    }

    private static func scoreTLS(_ snapshot: LookupSnapshot, assessment: TLSSummaryAssessment, into tally: inout RiskTally) {
        switch assessment.grade {
        case .a:
            tally.add(-8, "TLS configuration looks current and stable", .positive)
        case .b:
            tally.add(-3, "TLS is valid with minor concerns", .positive)
        case .c:
            tally.add(10, "TLS configuration has visible weaknesses", .negative)
        case .f:
            tally.add(22, "TLS is missing, invalid, or near failure", .negative)
        }
        if let daysUntilExpiry = snapshot.sslInfo?.daysUntilExpiry, daysUntilExpiry <= 14 {
            tally.add(10, "Certificate expires within 14 days", .negative)
        }
    }

    private static func scoreRedirects(_ snapshot: LookupSnapshot, into tally: inout RiskTally) {
        if snapshot.redirectChain.count >= 3 {
            tally.add(8, "Redirect chain is longer than expected", .negative)
        }
        if redirectLooksSensitive(snapshot.redirectChain.last?.url) {
            tally.add(6, "Redirect target looks like an auth or account gateway", .negative)
        }
    }

    private static func scoreEmail(
        _ snapshot: LookupSnapshot,
        assessment: EmailSecurityAssessment?,
        into tally: inout RiskTally
    ) {
        guard let assessment else {
            if hasMXRecords(snapshot) {
                tally.add(14, "Mail is configured without enough email security evidence", .negative)
            }
            return
        }
        switch assessment.grade {
        case .a:
            tally.add(-10, "Email protections are strong and aligned", .positive)
        case .b:
            tally.add(-4, "Email protections are present with minor gaps", .positive)
        case .c:
            tally.add(8, "Email protections are partial", .negative)
        case .f:
            tally.add(18, "Email security protections are weak or absent", .negative)
        }
    }

    private static func scorePorts(_ snapshot: LookupSnapshot, into tally: inout RiskTally) {
        let openPorts = snapshot.portScanResults.filter(\.open).map(\.port)
        let sensitivePorts: Set<UInt16> = [21, 22, 23, 25, 3389, 5900]
        let exposedSensitivePorts = openPorts.filter { sensitivePorts.contains($0) }
        if !exposedSensitivePorts.isEmpty {
            tally.add(min(18, exposedSensitivePorts.count * 6), "Sensitive management or mail ports are exposed", .negative)
        } else if Set(openPorts) == Set([80, 443]) {
            tally.add(0, "Exposure is limited to standard web ports", .positive)
        } else if openPorts.count >= 3 {
            tally.add(8, "Multiple open services expand the attack surface", .negative)
        }
    }

    private static func scoreSubdomains(_ snapshot: LookupSnapshot, groups: [SubdomainGroup], into tally: inout RiskTally) {
        guard !groups.isEmpty else { return }
        let labels = Set(groups.map(\.label))
        if labels.contains("dev") || labels.contains("staging") {
            tally.add(8, "Development or staging subdomains are discoverable", .negative)
        }
        if labels.contains("admin") {
            tally.add(10, "Administrative subdomains are discoverable", .negative)
        }
        if snapshot.subdomains.count >= 8 {
            tally.add(6, "Large passive subdomain footprint detected", .negative)
        }
    }

    private static func scoreGeolocation(_ snapshot: LookupSnapshot, into tally: inout RiskTally) {
        if snapshot.ipGeolocation == nil,
           snapshot.availabilityResult?.status == .registered,
           snapshot.dnsSections.contains(where: { $0.recordType == .A && !$0.records.isEmpty }) {
            tally.add(4, "Active host could not be geolocated", .neutral)
        }
    }

    private static func insights(
        for snapshot: LookupSnapshot,
        previousSnapshot: LookupSnapshot?,
        dnsPatterns: DNSPatternSummary,
        emailAssessment: EmailSecurityAssessment?,
        tlsAssessment: TLSSummaryAssessment,
        subdomainGroups: [SubdomainGroup]
    ) -> [String] {
        var items: [String] = []

        if let group = subdomainGroups.first(where: { $0.label == "staging" || $0.label == "dev" }) {
            items.append("Multiple \(group.label) subdomains suggest non-production environments are exposed")
        }
        if subdomainGroups.contains(where: { $0.label == "admin" }) {
            items.append("Administrative subdomains are publicly discoverable")
        }
        if let emailAssessment, emailAssessment.grade == .f {
            items.append("Domain lacks email security protections")
        } else if let emailAssessment, emailAssessment.grade == .c {
            items.append("Email security is only partially enforced")
        }
        if let daysUntilExpiry = snapshot.sslInfo?.daysUntilExpiry, daysUntilExpiry <= 30 {
            items.append("Certificate expires soon")
        }
        if redirectLooksSensitive(snapshot.redirectChain.last?.url) {
            items.append("Redirect chain may indicate login gateway")
        }
        items.append(contentsOf: dnsPatterns.patterns)

        if let tlsVersion = snapshot.sslInfo?.tlsVersion, tlsVersion == "TLS 1.0" || tlsVersion == "TLS 1.1" {
            items.append("TLS protocol version is outdated")
        }
        if tlsAssessment.grade == .f, snapshot.sslInfo == nil, snapshot.availabilityResult?.status == .registered {
            items.append("HTTPS endpoint could not be validated")
        }
        if let previousSnapshot,
           let previousURL = previousSnapshot.redirectChain.last?.url,
           let currentURL = snapshot.redirectChain.last?.url,
           previousURL != currentURL {
            items.append("Redirect target changed since the previous snapshot")
        }

        var deduplicated: [String] = []
        for item in items where !deduplicated.contains(item) {
            deduplicated.append(item)
        }
        return deduplicated
    }

    private static func dnsPatterns(for snapshot: LookupSnapshot) -> DNSPatternSummary {
        let nameservers = snapshot.ownership?.nameservers.map { $0.lowercased() } ?? []
        let headerNames = Set(snapshot.httpHeaders.map { $0.name.lowercased() })
        let headerValues = snapshot.httpHeaders.map { $0.value.lowercased() }
        let allValues = snapshot.dnsSections.flatMap { section in
            (section.records + section.wildcardRecords).map { $0.value.lowercased() }
        }

        var providers: [String] = []
        if nameservers.contains(where: { $0.contains("cloudflare") }) || headerNames.contains("cf-ray") || headerNames.contains("cf-cache-status") {
            providers.append("Cloudflare")
        }
        if nameservers.contains(where: { $0.contains("awsdns") }) || allValues.contains(where: { $0.contains("cloudfront.net") || $0.contains("elb.amazonaws.com") || $0.contains("amazonaws.com") }) {
            providers.append("AWS")
        }
        if allValues.contains(where: { $0.contains("fastly.net") }) || headerValues.contains(where: { $0.contains("fastly") || $0.contains("cache-") }) {
            providers.append("Fastly")
        }

        var patterns: [String] = []
        let wildcardDetected = snapshot.dnsSections.contains { !$0.wildcardRecords.isEmpty }
        if !providers.isEmpty {
            patterns.append("CDN or edge network detected: \(providers.joined(separator: ", "))")
        }
        if wildcardDetected {
            patterns.append("Wildcard DNS responses are present")
        }
        if hasMXRecords(snapshot), snapshot.emailSecurity == nil {
            patterns.append("MX records exist without corresponding email security records")
        }
        if snapshot.sslInfo != nil, snapshot.dnsSections.first(where: { $0.recordType == .CAA })?.records.isEmpty != false {
            patterns.append("TLS is active but no CAA record was found")
        }

        return DNSPatternSummary(providers: providers, wildcardDetected: wildcardDetected, patterns: patterns)
    }

    private static func emailAssessment(for result: EmailSecurityResult?) -> EmailSecurityAssessment? {
        guard let result else { return nil }

        let spfFound = result.spf.found
        let dkimFound = result.dkim.found
        let dmarcFound = result.dmarc.found
        let dmarcStrict = isStrictDMARC(result.dmarc.value)

        let dmarcReason: String
        if !dmarcFound {
            dmarcReason = "DMARC missing"
        } else {
            dmarcReason = dmarcStrict ? "DMARC policy is strict" : "DMARC policy is not strict"
        }

        let reasons = [
            spfFound ? "SPF present" : "SPF missing",
            dmarcReason,
            dkimFound ? "DKIM present" : "DKIM not detected"
        ]

        let grade: EmailSecurityGrade
        if spfFound && dkimFound && dmarcStrict {
            grade = .a
        } else if spfFound && dmarcFound && (dkimFound || dmarcStrict) {
            grade = .b
        } else if spfFound || dmarcFound || dkimFound {
            grade = .c
        } else {
            grade = .f
        }

        return EmailSecurityAssessment(grade: grade, reasons: reasons)
    }

    private static func tlsAssessment(for snapshot: LookupSnapshot) -> TLSSummaryAssessment {
        guard let sslInfo = snapshot.sslInfo else {
            return TLSSummaryAssessment(grade: .f, highlights: ["TLS handshake failed or no certificate was returned"])
        }

        var issues: [String] = []
        if sslInfo.daysUntilExpiry <= 14 {
            issues.append("Certificate expires within 14 days")
        } else if sslInfo.daysUntilExpiry <= 30 {
            issues.append("Certificate expires within 30 days")
        }
        if let tlsVersion = sslInfo.tlsVersion, tlsVersion == "TLS 1.0" || tlsVersion == "TLS 1.1" {
            issues.append("Uses \(tlsVersion)")
        }
        if let cipherSuite = sslInfo.cipherSuite?.lowercased(),
           cipherSuite.contains("_cbc_") || cipherSuite.contains("3des") || cipherSuite.contains("rc4") {
            issues.append("Negotiated cipher suite looks weak")
        }

        let grade: TLSGrade
        if snapshot.sslError != nil {
            grade = .f
        } else if issues.contains(where: { $0.contains("14 days") || $0.contains("weak") || $0.contains("TLS 1.0") || $0.contains("TLS 1.1") }) {
            grade = .c
        } else if !issues.isEmpty {
            grade = .b
        } else {
            grade = .a
        }

        return TLSSummaryAssessment(
            grade: grade,
            highlights: issues.isEmpty ? ["Certificate is valid and no weak TLS indicators were detected"] : issues
        )
    }

    private static func groupedSubdomains(from subdomains: [String]) -> [SubdomainGroup] {
        let labels = ["api", "dev", "staging", "admin"]
        let normalized = Array(Set(subdomains.map { $0.lowercased() })).sorted()

        return labels.compactMap { label in
            let matches = normalized.filter {
                guard let firstLabel = $0.split(separator: ".").first?.lowercased() else { return false }
                return firstLabel == label
            }
            guard !matches.isEmpty else { return nil }
            return SubdomainGroup(label: label, subdomains: matches)
        }
    }

    private static func isStrictDMARC(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.contains("p=reject") || value.contains("p=quarantine")
    }

    private static func hasMXRecords(_ snapshot: LookupSnapshot) -> Bool {
        snapshot.dnsSections.contains { $0.recordType == .MX && !$0.records.isEmpty }
    }

    private static func redirectLooksSensitive(_ urlString: String?) -> Bool {
        guard let urlString = urlString?.lowercased() else { return false }
        return urlString.contains("/login")
            || urlString.contains("/signin")
            || urlString.contains("/auth")
            || urlString.contains("/account")
            || urlString.contains("sso")
    }

    private static func appendSharedInsights(
        title: String,
        groups: [String: [String]],
        into insights: inout [WorkflowInsight]
    ) {
        for domains in groups.values where domains.count >= 2 {
            insights.append(
                WorkflowInsight(
                    description: "\(title) across \(domains.count) domains",
                    domainsInvolved: domains.sorted()
                )
            )
        }
    }

    private static func groupedDomains(
        for reports: [DomainReport],
        keyPath: KeyPath<DomainReport, String?>
    ) -> [String: [String]] {
        groupedDomains(for: reports) { $0[keyPath: keyPath]?.nilIfBlank }
    }

    private static func groupedDomains(
        for reports: [DomainReport],
        transform: (DomainReport) -> String?
    ) -> [String: [String]] {
        var grouped: [String: [String]] = [:]
        for report in reports {
            guard let value = transform(report) else { continue }
            grouped[value, default: []].append(report.domain)
        }
        return grouped
    }
}

private extension String {
}

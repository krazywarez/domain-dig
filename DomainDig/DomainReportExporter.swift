import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DomainExportFormat: String, CaseIterable, Identifiable, Codable {
    case text = "txt"
    case csv = "csv"
    case json = "json"
    case markdown = "md"
    case pdf = "pdf"

    var fileExtension: String { rawValue }
    var id: String { fileExtension }

    var title: String {
        switch self {
        case .text: return "TXT"
        case .csv: return "CSV"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        }
    }

    /// Sent as `Content-Type` when a report is uploaded, so a bucket serves it
    /// back as the right thing rather than as a download.
    var mimeType: String {
        switch self {
        case .text: return "text/plain; charset=utf-8"
        case .csv: return "text/csv; charset=utf-8"
        case .json: return "application/json"
        case .markdown: return "text/markdown; charset=utf-8"
        case .pdf: return "application/pdf"
        }
    }
}

enum DomainReportExporter {
    static func data(for report: DomainReport, format: DomainExportFormat) throws -> Data {
        switch format {
        case .text:
            return Data(text(for: report).utf8)
        case .csv:
            return Data(csv(for: [report]).utf8)
        case .json:
            return try jsonEncoder.encode(report)
        case .markdown:
            return Data(markdown(for: report).utf8)
        case .pdf:
            return pdfData(fromMarkdown: markdown(for: report))
        }
    }

    static func data(for reports: [DomainReport], format: DomainExportFormat, title: String) throws -> Data {
        switch format {
        case .text:
            return Data(batchText(for: reports, title: title).utf8)
        case .csv:
            return Data(csv(for: reports).utf8)
        case .json:
            return try jsonEncoder.encode(reports)
        case .markdown:
            return Data(batchMarkdown(for: reports, title: title).utf8)
        case .pdf:
            return pdfData(fromMarkdown: batchMarkdown(for: reports, title: title))
        }
    }

    /// Renders `text(for:)`'s content as Markdown: the leading title becomes an
    /// H1, `appendSection`'s "Title\n----" underlines become H2 headers, and
    /// other non-empty lines that aren't already list items become bullets.
    /// This reuses the exact same section content as the text export rather
    /// than re-deriving it, so the two formats never drift.
    static func markdown(for report: DomainReport) -> String {
        markdown(fromPlainText: text(for: report), title: "DomainDig Report")
    }

    static func batchMarkdown(for reports: [DomainReport], title: String) -> String {
        markdown(fromPlainText: batchText(for: reports, title: title), title: title)
    }

    private static func markdown(fromPlainText text: String, title: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = ["# \(title)", ""]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index == 0, line == title {
                index += 1
                if index < lines.count, isUnderline(lines[index], for: line) {
                    index += 1
                }
                continue
            }
            if index + 1 < lines.count, !line.isEmpty, isUnderline(lines[index + 1], for: line) {
                output.append("")
                output.append("## \(line)")
                index += 2
                continue
            }
            if isRule(line) {
                output.append("")
                output.append("---")
                index += 1
                continue
            }
            if line.isEmpty || line.hasPrefix("-") || line.hasPrefix("  ") {
                output.append(line)
            } else {
                output.append("- \(line)")
            }
            index += 1
        }
        return output.joined(separator: "\n")
    }

    /// True when `line` is a run of `-` or `=` exactly as long as the heading it
    /// underlines. `batchText` uses `=` for the document title, `appendSection`
    /// uses `-` for section headers.
    private static func isUnderline(_ line: String, for heading: String) -> Bool {
        guard !heading.isEmpty else { return false }
        return line == String(repeating: "-", count: heading.count)
            || line == String(repeating: "=", count: heading.count)
    }

    /// True for a standalone divider not attached to a heading — `batchText`
    /// emits a fixed 48-character `=` run between reports.
    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && (line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" })
    }

    /// Renders Markdown as a simple monospaced multi-page PDF. Foundation-only
    /// consumers (no UIKit available) get the Markdown bytes back instead.
    static func pdfData(fromMarkdown markdown: String) -> Data {
        #if canImport(UIKit)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            let lines = markdown.components(separatedBy: .newlines)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .paragraphStyle: paragraphStyle
            ]

            var yOffset: CGFloat = 36
            context.beginPage()

            for line in lines {
                if yOffset > 744 {
                    context.beginPage()
                    yOffset = 36
                }

                let renderedLine = NSString(string: line.isEmpty ? " " : line)
                renderedLine.draw(
                    in: CGRect(x: 36, y: yOffset, width: 540, height: 22),
                    withAttributes: attributes
                )
                yOffset += 16
            }
        }
        #else
        return Data(markdown.utf8)
        #endif
    }

    static func text(for report: DomainReport) -> String {
        var lines = headerLines(report)
        appendSection("Summary", to: &lines) { summarySection(report) }
        appendSection("Risk", to: &lines) { riskSection(report) }
        appendSection("Insights", to: &lines) { insightsSection(report) }
        appendSection("Ownership", to: &lines) { ownershipSection(report) }
        appendSection("Ownership History", to: &lines) { ownershipHistorySection(report) }
        appendSection("DNS", to: &lines) { dnsSection(report) }
        appendSection("DNS History", to: &lines) { dnsHistorySection(report) }
        appendSection("Web", to: &lines) { webSection(report) }
        appendSection("Email", to: &lines) { emailSection(report) }
        appendSection("Network", to: &lines) { networkSection(report) }
        appendSection("Subdomains", to: &lines) { subdomainsSection(report) }
        appendSection("Pricing", to: &lines) { pricingSection(report) }
        appendSection("Changes", to: &lines) { changesSection(report) }
        return lines.joined(separator: "\n")
    }

    /// The report's title block: what was looked up, when, how, and with what caveats.
    private static func headerLines(_ report: DomainReport) -> [String] {
        var lines = [
            "DomainDig Report",
            "Domain: \(report.domain)",
            "Timestamp: \(textDateFormatter.string(from: report.timestamp))",
            "App Version: \(report.metadata.appVersion)",
            "Resolver: \(report.metadata.resolverDisplayName)",
            "Resolver URL: \(report.metadata.resolverURLString)",
            "Source: \(report.provenance.source.label)",
            "Availability: \(availabilityLabel(report.availability))",
            "Availability Confidence: \(report.availabilityConfidence?.title ?? "N/A")"
        ]

        if report.metadata.isPartialSnapshot {
            lines.append("Snapshot Integrity: Partial snapshot")
        }
        if let auditNote = report.metadata.auditNote, !auditNote.isEmpty {
            lines.append("Audit Note: \(auditNote)")
        }
        if !report.provenance.dataSources.isEmpty {
            lines.append("Data Sources: \(report.provenance.dataSources.joined(separator: ", "))")
        }
        if !report.metadata.validationIssues.isEmpty {
            lines.append("Validation: \(report.metadata.validationIssues.joined(separator: " | "))")
        }
        if let workflowContext = report.workflowContext {
            lines.append("Workflow Context: \(workflowContext.workflowName ?? workflowContext.source)")
        }
        return lines
    }

    private static func summarySection(_ report: DomainReport) -> [String] {
        [
            "Primary IP: \(report.dns.primaryIP ?? "Unavailable")",
            "Risk Score: \(report.riskAssessment.score) (\(report.riskAssessment.level.title))",
            "TLS Status: \(report.web.tlsStatus)",
            "HTTP: \(httpSummary(for: report))",
            "Email: \(report.email.summary)",
            "Subdomains: \(report.subdomains.count)",
            "Extended Subdomains: \(report.extendedSubdomains.count)",
            "External Price: \(report.domainPricing?.estimatedPrice ?? "Unavailable")",
            "Reputation: \(report.reputation?.status.title ?? "Unavailable")"
        ]
    }

    private static func riskSection(_ report: DomainReport) -> [String] {
        var values = [
            "Score: \(report.riskAssessment.score)",
            "Level: \(report.riskAssessment.level.title)"
        ]
        if report.riskAssessment.factors.isEmpty {
            values.append("Factors: None")
        } else {
            values.append("Factors:")
            for factor in report.riskAssessment.factors {
                values.append("  [\(factor.impact.rawValue)] \(factor.description)")
            }
        }
        return values
    }

    private static func insightsSection(_ report: DomainReport) -> [String] {
        report.insights.isEmpty ? ["No deterministic insights triggered"] : report.insights.map { "- \($0)" }
    }

    private static func ownershipSection(_ report: DomainReport) -> [String] {
        var ownershipLines = [
            "Registrar: \(report.ownership?.registrar ?? "Unavailable")",
            "Confidence: \(report.ownershipConfidence?.title ?? "N/A")",
            "Created: \(ownershipDateLabel(report.ownership?.createdDate))",
            "Expires: \(ownershipDateLabel(report.ownership?.expirationDate))",
            "Registrant: \(report.ownership?.registrant ?? "Unavailable")",
            "Nameservers: \(joined(report.ownership?.nameservers) ?? "Unavailable")",
            "Status: \(joined(report.ownership?.status) ?? "Unavailable")",
            "Abuse Contact: \(report.ownership?.abuseEmail ?? "Unavailable")"
        ]
        if let provenance = report.sectionProvenance[.ownership] {
            ownershipLines.append("Provenance: \(provenanceLabel(provenance))")
        }
        if let error = report.dns.error, report.ownership == nil {
            ownershipLines.append("Error: \(error)")
        }
        return ownershipLines
    }

    private static func ownershipHistorySection(_ report: DomainReport) -> [String] {
        guard !report.ownershipHistory.isEmpty else {
            return ["No ownership history available"]
        }

        return report.ownershipHistory.map { event in
            [
                textDateFormatter.string(from: event.date),
                event.summary,
                "source=\(event.source)"
            ].joined(separator: " | ")
        }
    }

    private static func dnsSection(_ report: DomainReport) -> [String] {
        var dnsLines = [
            "Lookup Duration: \(durationLabel(report.dns.lookupDurationMs))",
            "Primary IP: \(report.dns.primaryIP ?? "Unavailable")",
            "PTR: \(report.dns.ptrRecord ?? report.dns.ptrError ?? "Unavailable")",
            "DNSSEC: \(dnssecLabel(report.dns.dnssecSigned))",
            "Patterns: \(report.dns.patternSummary.patterns.joined(separator: " | ").nilIfEmpty ?? "None")"
        ]
        if let provenance = report.sectionProvenance[.dns] {
            dnsLines.append("Provenance: \(provenanceLabel(provenance))")
        }
        if let error = report.dns.error {
            dnsLines.append("Error: \(error)")
        }
        if report.dns.recordSections.isEmpty {
            dnsLines.append("Records: None")
        } else {
            dnsLines.append("Records:")
            for section in report.dns.recordSections {
                var seen: Set<String> = []
                let values = (section.records + section.wildcardRecords)
                    .map(\.value)
                    .filter { seen.insert($0).inserted }
                let renderedValues = values.isEmpty ? "None" : values.joined(separator: " | ")
                dnsLines.append("  \(section.recordType.rawValue): \(renderedValues)")
            }
        }
        return dnsLines
    }

    private static func dnsHistorySection(_ report: DomainReport) -> [String] {
        guard !report.dnsHistory.isEmpty else {
            return ["No DNS history available"]
        }

        return report.dnsHistory.map { event in
            [
                textDateFormatter.string(from: event.date),
                event.summary,
                "A=\(event.aRecords.joined(separator: " | ").nilIfEmpty ?? "-")",
                "NS=\(event.nameservers.joined(separator: " | ").nilIfEmpty ?? "-")",
                "source=\(event.source)"
            ].joined(separator: " | ")
        }
    }

    private static func webSection(_ report: DomainReport) -> [String] {
        var webLines = [
            "TLS Status: \(report.web.tlsStatus)",
            "TLS Grade: \(report.web.tlsGrade.rawValue)",
            "TLS Highlights: \(report.web.tlsHighlights.joined(separator: " | "))",
            "Certificate Warning: \(report.web.certificateWarningLevel.title)",
            "Security Grade: \(report.web.securityGrade ?? "Unavailable")",
            "HTTP Status: \(report.web.statusCode.map(String.init) ?? "Unavailable")",
            "Protocol: \(report.web.httpProtocol ?? "Unavailable")",
            "HTTP/3 Advertised: \(report.web.http3Advertised ? "Yes" : "No")",
            "Final URL: \(report.web.finalURL ?? "Unavailable")",
            "HSTS Preloaded: \(booleanLabel(report.web.hstsPreloaded))",
            "Header Count: \(report.web.headerCount)"
        ]
        if let provenance = report.sectionProvenance[.ssl] {
            webLines.append("TLS Provenance: \(provenanceLabel(provenance))")
        }
        if let provenance = report.sectionProvenance[.httpHeaders] {
            webLines.append("HTTP Provenance: \(provenanceLabel(provenance))")
        }
        if let provenance = report.sectionProvenance[.redirectChain] {
            webLines.append("Redirect Provenance: \(provenanceLabel(provenance))")
        }
        if let tlsError = report.web.tlsError {
            webLines.append("TLS Error: \(tlsError)")
        }
        if let headersError = report.web.headersError {
            webLines.append("Headers Error: \(headersError)")
        }
        if let redirectError = report.web.redirectError {
            webLines.append("Redirect Error: \(redirectError)")
        }
        if !report.web.headers.isEmpty {
            webLines.append("Headers:")
            for header in report.web.headers {
                webLines.append("  \(header.name): \(header.value)")
            }
        }
        if !report.web.redirectChain.isEmpty {
            webLines.append("Redirect Chain:")
            for hop in report.web.redirectChain {
                webLines.append("  \(hop.stepNumber). \(hop.statusCode) \(hop.url)\(hop.isFinal ? " (final)" : "")")
            }
        }
        return webLines
    }

    private static func emailSection(_ report: DomainReport) -> [String] {
        var emailLines = [report.email.summary]
        if let grade = report.email.grade {
            emailLines.append("Grade: \(grade.rawValue)")
        }
        if !report.email.reasons.isEmpty {
            emailLines.append("Why: \(report.email.reasons.joined(separator: " | "))")
        }
        emailLines.append("Confidence: \(report.emailConfidence?.title ?? "N/A")")
        if let provenance = report.sectionProvenance[.emailSecurity] {
            emailLines.append("Provenance: \(provenanceLabel(provenance))")
        }
        if let records = report.email.records {
            emailLines.append("SPF: \(recordLabel(records.spf))")
            emailLines.append("DMARC: \(recordLabel(records.dmarc))")
            emailLines.append("DKIM: \(recordLabel(records.dkim))")
            emailLines.append("BIMI: \(recordLabel(records.bimi))")
            emailLines.append("MTA-STS: \(records.mtaSts?.txtFound == true ? records.mtaSts?.policyMode ?? "found" : "Unavailable")")
        }
        if let error = report.email.error {
            emailLines.append("Error: \(error)")
        }
        return emailLines
    }

    private static func networkSection(_ report: DomainReport) -> [String] {
        var networkLines = [
            "Reachability: \(report.network.reachabilitySummary)",
            "Geolocation: \(report.network.geolocationSummary)",
            "Geolocation Confidence: \(report.geolocationConfidence?.title ?? "N/A")",
            "Open Ports: \(report.network.openPorts.map(String.init).joined(separator: ", ").nilIfEmpty ?? "None")"
        ]
        if let provenance = report.sectionProvenance[.ipGeolocation] {
            networkLines.append("Geolocation Provenance: \(provenanceLabel(provenance))")
        }
        if let error = report.network.reachabilityError {
            networkLines.append("Reachability Error: \(error)")
        }
        if let error = report.network.geolocationError {
            networkLines.append("Geolocation Error: \(error)")
        }
        if let error = report.network.portScanError {
            networkLines.append("Port Scan Error: \(error)")
        }
        if !report.network.portScan.isEmpty {
            networkLines.append("Port Scan:")
            for result in report.network.portScan {
                networkLines.append(
                    "  \(result.port) \(result.service): \(result.open ? "open" : "closed")\(result.banner.map { " banner=\($0)" } ?? "")"
                )
            }
        }
        return networkLines
    }

    private static func subdomainsSection(_ report: DomainReport) -> [String] {
        var values = ["Confidence: \(report.subdomainConfidence?.title ?? "N/A")"]
        if let provenance = report.sectionProvenance[.subdomains] {
            values.append("Provenance: \(provenanceLabel(provenance))")
        }
        if report.subdomains.isEmpty {
            values.append("None")
            return values
        }
        if !report.subdomainGroups.isEmpty {
            values.append("Groups: \(report.subdomainGroups.map { "\($0.label): \($0.subdomains.count)" }.joined(separator: " | "))")
        }
        values.append(contentsOf: report.subdomains.map { "- \($0)" })
        if !report.extendedSubdomains.isEmpty {
            values.append("Extended:")
            values.append(contentsOf: report.extendedSubdomains.map { "- \($0)" })
        }
        return values
    }

    private static func pricingSection(_ report: DomainReport) -> [String] {
        guard let pricing = report.domainPricing else {
            return ["External pricing unavailable"]
        }

        return [
            "Estimated Price: \(pricing.estimatedPrice ?? "Unavailable")",
            "Premium: \(pricing.premiumIndicator == true ? "Yes" : "No")",
            "Resale: \(pricing.resaleSignal ?? "Unavailable")",
            "Auction: \(pricing.auctionSignal ?? "Unavailable")",
            "Source: \(pricing.source)",
            "Collected: \(textDateFormatter.string(from: pricing.collectedAt))"
        ]
    }

    private static func changesSection(_ report: DomainReport) -> [String] {
        guard let changeSummary = report.changeSummary else {
            return ["No comparison available"]
        }

        var values = [
            "Has Changes: \(changeSummary.hasChanges ? "Yes" : "No")",
            "Severity: \(changeSummary.severity.title)",
            "Impact: \(changeSummary.impactClassification.title)",
            "Inferred Summary: \(changeSummary.message)",
            "Changed Sections: \(changeSummary.changedSections.isEmpty ? "None" : changeSummary.changedSections.joined(separator: ", "))"
        ]
        if let riskScoreDelta = changeSummary.riskScoreDelta {
            values.append("Risk Delta: \(riskScoreDelta >= 0 ? "+" : "")\(riskScoreDelta)")
        }
        if !changeSummary.insights.isEmpty {
            values.append("Insights: \(changeSummary.insights.joined(separator: " | "))")
        }
        if !changeSummary.observedFacts.isEmpty {
            values.append("Observed: \(changeSummary.observedFacts.joined(separator: " | "))")
        }
        if let contextNote = changeSummary.contextNote {
            values.append("Context: \(contextNote)")
        }
        return values
    }

    static func batchText(for reports: [DomainReport], title: String) -> String {
        guard !reports.isEmpty else {
            return "\(title)\nNo results available."
        }

        var lines = [title, String(repeating: "=", count: title.count), ""]
        for (index, report) in reports.enumerated() {
            if index > 0 {
                lines.append("")
                lines.append(String(repeating: "=", count: 48))
                lines.append("")
            }
            lines.append(text(for: report))
        }
        return lines.joined(separator: "\n")
    }

    static func csv(for reports: [DomainReport]) -> String {
        csv(for: reports, workflowInsights: [])
    }

    static func csv(for reports: [DomainReport], workflowInsights: [WorkflowInsight]) -> String {
        let workflowInsightSummary = workflowInsights.map(\.description).joined(separator: " | ")
        let headers = [
            "domain",
            "timestamp",
            "app_version",
            "result_source",
            "resolver",
            "availability",
            "risk_score",
            "risk_level",
            "risk_factors",
            "insights",
            "availability_confidence",
            "registrar",
            "ownership_confidence",
            "ownership_expires",
            "nameservers",
            "primary_ip",
            "ptr_record",
            "dnssec_signed",
            "dns_patterns",
            "tls_status",
            "tls_grade",
            "tls_highlights",
            "certificate_warning_level",
            "hsts_preloaded",
            "http_status",
            "http_security_grade",
            "final_url",
            "email_summary",
            "email_grade",
            "email_confidence",
            "subdomain_count",
            "extended_subdomain_count",
            "subdomain_groups",
            "subdomain_confidence",
            "subdomains",
            "extended_subdomains",
            "ownership_history",
            "dns_history",
            "pricing_estimated",
            "pricing_premium",
            "pricing_resale_signal",
            "pricing_auction_signal",
            "pricing_source",
            "reputation_status",
            "reputation_listed_sources",
            "open_ports",
            "reachability_summary",
            "geolocation_summary",
            "geolocation_confidence",
            "data_sources",
            "audit_note",
            "partial_snapshot",
            "workflow_name",
            "workflow_source",
            "cached_sections",
            "change_summary",
            "change_impact",
            "workflow_insights"
        ]

        let rows = reports.map { report in
            let expirationDate = report.ownership?.expirationDate.map(csvDateFormatter.string(from:)) ?? ""
            let nameservers = joined(report.ownership?.nameservers) ?? ""
            let dnssecSigned = report.dns.dnssecSigned.map { $0 ? "true" : "false" } ?? ""
            let hstsPreloaded = report.web.hstsPreloaded.map { $0 ? "true" : "false" } ?? ""
            let httpStatus = report.web.statusCode.map(String.init) ?? ""
            let subdomainCount = String(report.subdomains.count)
            let subdomains = report.subdomains.joined(separator: " | ")
            let extendedSubdomains = report.extendedSubdomains.joined(separator: " | ")
            let openPorts = report.network.openPorts.map(String.init).joined(separator: " | ")
            let riskFactors = report.riskAssessment.factors.map(\.description).joined(separator: " | ")
            let insights = report.insights.joined(separator: " | ")
            let dnsPatterns = report.dns.patternSummary.patterns.joined(separator: " | ")
            let tlsHighlights = report.web.tlsHighlights.joined(separator: " | ")
            let subdomainGroups = report.subdomainGroups.map { "\($0.label):\($0.subdomains.count)" }.joined(separator: " | ")
            let ownershipHistory = report.ownershipHistory.map { "\($0.date.ISO8601Format()) \($0.summary)" }.joined(separator: " | ")
            let dnsHistory = report.dnsHistory.map { "\($0.date.ISO8601Format()) \($0.summary)" }.joined(separator: " | ")
            let reputationStatus = report.reputation?.status.rawValue ?? ""
            let reputationListedSources = report.reputation?.listedSources.joined(separator: " | ") ?? ""

            return [
                report.domain,
                csvDateFormatter.string(from: report.timestamp),
                report.appVersion,
                report.resultSource.rawValue,
                report.resolverDisplayName,
                availabilityLabel(report.availability),
                "\(report.riskAssessment.score)",
                report.riskAssessment.level.rawValue,
                riskFactors,
                insights,
                report.availabilityConfidence?.rawValue ?? "",
                report.ownership?.registrar ?? "",
                report.ownershipConfidence?.rawValue ?? "",
                expirationDate,
                nameservers,
                report.dns.primaryIP ?? "",
                report.dns.ptrRecord ?? "",
                dnssecSigned,
                dnsPatterns,
                report.web.tlsStatus,
                report.web.tlsGrade.rawValue,
                tlsHighlights,
                report.web.certificateWarningLevel.rawValue,
                hstsPreloaded,
                httpStatus,
                report.web.securityGrade ?? "",
                report.web.finalURL ?? "",
                report.email.summary,
                report.email.grade?.rawValue ?? "",
                report.emailConfidence?.rawValue ?? "",
                subdomainCount,
                String(report.extendedSubdomains.count),
                subdomainGroups,
                report.subdomainConfidence?.rawValue ?? "",
                subdomains,
                extendedSubdomains,
                ownershipHistory,
                dnsHistory,
                report.domainPricing?.estimatedPrice ?? "",
                report.domainPricing?.premiumIndicator == true ? "true" : "false",
                report.domainPricing?.resaleSignal ?? "",
                report.domainPricing?.auctionSignal ?? "",
                report.domainPricing?.source ?? "",
                reputationStatus,
                reputationListedSources,
                openPorts,
                report.network.reachabilitySummary,
                report.network.geolocationSummary,
                report.geolocationConfidence?.rawValue ?? "",
                report.provenance.dataSources.joined(separator: " | "),
                report.metadata.auditNote ?? "",
                report.metadata.isPartialSnapshot ? "true" : "false",
                report.workflowContext?.workflowName ?? "",
                report.workflowContext?.source ?? "",
                report.metadata.cachedSections.map(\.rawValue).joined(separator: " | "),
                report.changeSummary?.message ?? "",
                report.changeSummary?.impactClassification.rawValue ?? "",
                workflowInsightSummary
            ]
        }

        return ([headers] + rows)
            .map { row in row.map(csvEscaped).joined(separator: ",") }
            .joined(separator: "\n")
    }

    static func timelineText(for reports: [DomainReport], domain: String, includeDiffSummary: Bool) -> String {
        guard !reports.isEmpty else {
            return "Timeline Export\nNo snapshots available for \(domain)."
        }

        var lines = [
            "DomainDig Timeline Export",
            "Domain: \(domain)",
            "Snapshots: \(reports.count)"
        ]

        for report in reports.sorted(by: { $0.timestamp > $1.timestamp }) {
            lines.append("")
            lines.append("\(textDateFormatter.string(from: report.timestamp))")
            lines.append("Summary: \(report.changeSummary?.message ?? "No change summary")")
            lines.append("Severity: \(report.changeSummary?.severity.title ?? "N/A")")
            if includeDiffSummary, let changeSummary = report.changeSummary {
                lines.append("Changed Sections: \(changeSummary.changedSections.joined(separator: ", ").nilIfEmpty ?? "None")")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func timelineData(for reports: [DomainReport], domain: String, includeDiffSummary: Bool) throws -> Data {
        struct TimelineExportEntry: Codable {
            let timestamp: Date
            let summary: String?
            let severity: String?
            let changedSections: [String]?
        }

        struct TimelineExportPayload: Codable {
            let domain: String
            let exportedAt: Date
            let snapshots: [TimelineExportEntry]
        }

        let payload = TimelineExportPayload(
            domain: domain,
            exportedAt: Date(),
            snapshots: reports
                .sorted(by: { $0.timestamp > $1.timestamp })
                .map { report in
                    TimelineExportEntry(
                        timestamp: report.timestamp,
                        summary: report.changeSummary?.message,
                        severity: report.changeSummary?.severity.title,
                        changedSections: includeDiffSummary ? report.changeSummary?.changedSections : nil
                    )
                }
        )

        return try jsonEncoder.encode(payload)
    }

    private static func appendSection(_ title: String, to lines: inout [String], body: () -> [String]) {
        lines.append("")
        lines.append(title)
        lines.append(String(repeating: "-", count: title.count))
        lines.append(contentsOf: body())
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

    private static func joined(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: " | ")
    }

    private static func dnssecLabel(_ value: Bool?) -> String {
        switch value {
        case true:
            return "Signed"
        case false:
            return "Unsigned"
        case nil:
            return "Unavailable"
        }
    }

    private static func ownershipDateLabel(_ date: Date?) -> String {
        guard let date else { return "Unavailable" }
        return textDateFormatter.string(from: date)
    }

    private static func durationLabel(_ durationMs: Int?) -> String {
        durationMs.map { "\($0) ms" } ?? "Unavailable"
    }

    private static func httpSummary(for report: DomainReport) -> String {
        let parts = [report.web.statusCode.map(String.init), report.web.securityGrade].compactMap { $0 }
        return parts.isEmpty ? report.web.headersError ?? "Unavailable" : parts.joined(separator: " / ")
    }

    private static func booleanLabel(_ value: Bool?) -> String {
        guard let value else { return "Unavailable" }
        return value ? "Yes" : "No"
    }

    private static func recordLabel(_ record: EmailSecurityRecord) -> String {
        if record.found {
            return record.value ?? "Present"
        }
        return "Unavailable"
    }

    private static func provenanceLabel(_ provenance: SectionProvenance) -> String {
        [
            provenance.source,
            provenance.provider,
            provenance.resolver.map { "resolver=\($0)" },
            provenance.resultSource.label.lowercased(),
            textDateFormatter.string(from: provenance.collectedAt)
        ]
        .compactMap { $0 }
        .joined(separator: " | ")
    }

    private static let textDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

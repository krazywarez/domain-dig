import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum AuditExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case json
    case markdown

    var id: String { rawValue }

    var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
}

enum AuditExporter {
    static func data(for session: AuditSession, format: AuditExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(session)
        case .markdown:
            return Data(markdown(for: session).utf8)
        case .pdf:
            return try pdfData(for: session)
        }
    }

    static func markdown(for session: AuditSession) -> String {
        var lines: [String] = [
            "# DomainDig Audit",
            "",
            "- Domain: \(session.domain)",
            "- Review Date: \(session.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "- Reviewer: \(session.reviewer)",
            "- Status: \(session.status.title)",
            "- Evidence Captured: \(session.evidence.capturedAt.formatted(date: .abbreviated, time: .shortened))",
            "- Checklist Progress: \(session.completedChecklistCount)/\(session.checklist.count)",
            ""
        ]

        if !session.notes.isEmpty {
            lines.append("## Summary Notes")
            lines.append(session.notes)
            lines.append("")
        }

        lines += findingsSummaryLines(session)
        lines += keyRiskLines(session)
        lines.append("## Checklist")
        for item in session.checklist {
            lines.append("- [\(item.isComplete ? "x" : " ")] \(item.title): \(item.detail)")
        }
        lines.append("")
        lines += findingLines(session)
        lines += evidenceLines(session.evidence)

        return lines.joined(separator: "\n")
    }

    private static func findingsSummaryLines(_ session: AuditSession) -> [String] {
        var lines = ["## Findings Summary"]
        if session.findings.isEmpty {
            lines.append("No findings recorded.")
        } else {
            for finding in session.findings {
                lines.append("- [\(finding.severity.title)] \(finding.title) (\(finding.status.title))")
            }
        }
        lines.append("")
        return lines
    }

    private static func keyRiskLines(_ session: AuditSession) -> [String] {
        var lines = ["## Key Risks"]
        if session.keyRisks.isEmpty {
            lines.append("No medium or high-severity risks recorded.")
        } else {
            for finding in session.keyRisks {
                lines.append("- \(finding.title): \(finding.summary)")
            }
        }
        lines.append("")
        return lines
    }

    private static func findingLines(_ session: AuditSession) -> [String] {
        var lines = ["## Findings"]
        if session.findings.isEmpty {
            lines.append("No findings recorded.")
        }
        for finding in session.findings {
            lines.append("### \(finding.title)")
            lines.append("- Severity: \(finding.severity.title)")
            lines.append("- Status: \(finding.status.title)")
            if !finding.checklistAreas.isEmpty {
                lines.append("- Checklist Areas: \(finding.checklistAreas.map(\.title).joined(separator: ", "))")
            }
            lines.append("- Summary: \(finding.summary)")
            if !finding.evidenceReferences.isEmpty {
                lines.append("- Evidence: \(finding.evidenceReferences.joined(separator: " | "))")
            }
            if !finding.notes.isEmpty {
                lines.append("- Notes: \(finding.notes)")
            }
            lines.append("")
        }
        return lines
    }

    private static func evidenceLines(_ evidence: AuditEvidenceSnapshot) -> [String] {
        let report = evidence.report
        return [
            "## Evidence Snapshot",
            "- Availability: \(availabilityTitle(report.availability))",
            "- Risk Score: \(report.riskAssessment.score) (\(report.riskAssessment.level.title))",
            "- TLS Status: \(report.web.tlsStatus)",
            "- Final URL: \(report.web.finalURL ?? "Unavailable")",
            "- Primary IP: \(report.dns.primaryIP ?? "Unavailable")",
            "- Reachability: \(report.network.reachabilitySummary)",
            "- Ownership: \(report.ownership?.registrar ?? "Unavailable")",
            "- Historical Context Snapshots: \(evidence.historicalContext.count)",
        ]
    }

    private static func availabilityTitle(_ status: DomainAvailabilityStatus) -> String {
        switch status {
        case .available:
            return "Available"
        case .registered:
            return "Registered"
        case .unknown:
            return "Unknown"
        }
    }

    private static func pdfData(for session: AuditSession) throws -> Data {
        DomainReportExporter.pdfData(fromMarkdown: markdown(for: session))
    }
}

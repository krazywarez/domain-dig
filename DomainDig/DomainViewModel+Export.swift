import Foundation

/// Export and data-portability surface of `DomainViewModel`: rendering the
/// current report, batch results, tracked domains, timelines, and workflow runs
/// into the shareable formats, plus the full-backup / portable-slice exporters
/// and the import + app-settings persistence entry points.
///
/// These are thin adapters over `DomainReportExporter` and
/// `DomainDataPortabilityService`. The report-projection helpers they call
/// (`currentBatchReports`, `reports(for:)`, `timelineReports`, `workflowReports`)
/// remain on the main type — they belong to the report layer shared with
/// inspection, not to export.
extension DomainViewModel {
    func exportJSONData() -> Data? {
        guard let currentReport else { return nil }
        return try? DomainReportExporter.data(for: currentReport, format: .json)
    }

    func exportJSONString() -> String? {
        guard let data = exportJSONData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportSingleReportData(format: DomainExportFormat) -> Data? {
        guard let currentReport else { return nil }
        return try? DomainReportExporter.data(for: currentReport, format: format)
    }

    func exportBatchReportData(format: DomainExportFormat) -> Data? {
        try? DomainReportExporter.data(
            for: currentBatchReports(),
            format: format,
            title: batchLookupSource == .watchlistRefresh ? "Tracked Domains Export" : "Batch Results Export"
        )
    }

    func exportTrackedDomainsData(domains: [TrackedDomain], format: DomainExportFormat) -> Data? {
        try? DomainReportExporter.data(
            for: reports(for: domains),
            format: format,
            title: "Tracked Domains Export"
        )
    }

    func exportTimelineText(domain: String, includeDiffSummary: Bool) -> String {
        DomainReportExporter.timelineText(
            for: timelineReports(for: domain),
            domain: domain,
            includeDiffSummary: includeDiffSummary
        )
    }

    func exportTimelineJSONData(domain: String, includeDiffSummary: Bool) -> Data? {
        try? DomainReportExporter.timelineData(
            for: timelineReports(for: domain),
            domain: domain,
            includeDiffSummary: includeDiffSummary
        )
    }

    func exportFullBackupData() -> Data? {
        try? DomainDataPortabilityService.backupData(defaults: defaults, historyLocation: historyLocation)
    }

    func exportPortableTrackedDomainsJSONData() -> Data? {
        try? DomainDataPortabilityService.trackedDomainsExportData(defaults: defaults)
    }

    func exportPortableTrackedDomainsCSV() -> String {
        DomainDataPortabilityService.trackedDomainsCSV(defaults: defaults)
    }

    func exportPortableWorkflowsJSONData() -> Data? {
        try? DomainDataPortabilityService.workflowsExportData(defaults: defaults)
    }

    func exportPortableWorkflowsCSV() -> String {
        DomainDataPortabilityService.workflowsCSV(defaults: defaults)
    }

    func exportPortableHistoryJSONData() -> Data? {
        try? DomainDataPortabilityService.historyExportData(defaults: defaults, historyLocation: historyLocation)
    }

    func prepareDataImport(
        data: Data,
        fileName: String,
        mode: DataPortabilityImportMode
    ) throws -> DataImportPreview {
        try DomainDataPortabilityService.prepareImport(
            data: data,
            fileName: fileName,
            mode: mode,
            defaults: defaults,
            historyLocation: historyLocation
        )
    }

    func applyDataImport(_ preview: DataImportPreview, mode: DataPortabilityImportMode) throws -> DataImportResult {
        let result = try DomainDataPortabilityService.applyImport(
            preview,
            mode: mode,
            defaults: defaults,
            historyLocation: historyLocation
        )
        refreshPersistedData()
        portabilityStatusMessage = result.summary
        CloudSyncService.shared.markAppSettingsChanged()
        CloudSyncService.shared.markMonitoringSettingsChanged(localActivationConfirmed: monitoringSettings.isEnabled)
        CloudSyncService.shared.scheduleSyncIfNeeded(trigger: .imported)
        return result
    }

    func persistCurrentAppSettings(resolverURLString: String, appDensityRawValue: String) {
        DomainDataPortabilityService.saveAppSettings(
            AppSettingsSnapshot(
                recentSearches: recentSearches,
                resolverURLString: resolverURLString,
                appDensityRawValue: appDensityRawValue
            ),
            defaults: defaults
        )
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    func exportWorkflowText(summary: WorkflowRunSummary, changedOnly: Bool) -> String {
        let reports = workflowReports(from: summary, changedOnly: changedOnly)
        let base = DomainReportExporter.batchText(
            for: reports,
            title: "\(summary.workflowName) Workflow Export"
        )
        guard !summary.workflowInsights.isEmpty else { return base }
        let insightLines = summary.workflowInsights.map {
            "- \($0.description): \($0.domainsInvolved.joined(separator: ", "))"
        }
        return ([ "\(summary.workflowName) Workflow Insights", String(repeating: "-", count: 32) ] + insightLines + ["", base]).joined(separator: "\n")
    }

    func exportWorkflowCSV(summary: WorkflowRunSummary, changedOnly: Bool) -> String {
        DomainReportExporter.csv(
            for: workflowReports(from: summary, changedOnly: changedOnly),
            workflowInsights: summary.workflowInsights
        )
    }

    func exportWorkflowJSONData(summary: WorkflowRunSummary, changedOnly: Bool) -> Data? {
        let payload = WorkflowExportPayload(
            workflowName: summary.workflowName,
            generatedAt: summary.generatedAt,
            workflowInsights: summary.workflowInsights,
            reports: workflowReports(from: summary, changedOnly: changedOnly)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    func exportWorkflowMarkdown(summary: WorkflowRunSummary, changedOnly: Bool) -> String {
        let reports = workflowReports(from: summary, changedOnly: changedOnly)
        let base = DomainReportExporter.batchMarkdown(for: reports, title: "\(summary.workflowName) Workflow Export")
        guard !summary.workflowInsights.isEmpty else { return base }
        let insightLines = summary.workflowInsights.map {
            "- \($0.description): \($0.domainsInvolved.joined(separator: ", "))"
        }
        return (["## \(summary.workflowName) Workflow Insights"] + insightLines + ["", base]).joined(separator: "\n")
    }

    func exportWorkflowData(summary: WorkflowRunSummary, changedOnly: Bool, format: DomainExportFormat) -> Data? {
        switch format {
        case .text:
            return Data(exportWorkflowText(summary: summary, changedOnly: changedOnly).utf8)
        case .csv:
            return Data(exportWorkflowCSV(summary: summary, changedOnly: changedOnly).utf8)
        case .json:
            return exportWorkflowJSONData(summary: summary, changedOnly: changedOnly)
        case .markdown:
            return Data(exportWorkflowMarkdown(summary: summary, changedOnly: changedOnly).utf8)
        case .pdf:
            return DomainReportExporter.pdfData(fromMarkdown: exportWorkflowMarkdown(summary: summary, changedOnly: changedOnly))
        }
    }
}

private struct WorkflowExportPayload: Codable {
    let workflowName: String
    let generatedAt: Date
    let workflowInsights: [WorkflowInsight]
    let reports: [DomainReport]
}

// MARK: - Export line builders

// Moved out of DomainViewModel.swift (A13): these are static functions
// over a snapshot or report, so they hold no view-model state and the
// core file was carrying a quarter of its length in them.

extension DomainViewModel {
    static func formatBatchExportText(
        title: String,
        entries: [(snapshot: LookupSnapshot, trackedDomain: TrackedDomain?, changeSummary: DomainChangeSummary?, diffSections: [DomainDiffSection])]
    ) -> String {
        guard !entries.isEmpty else {
            return "\(title)\nNo results available."
        }

        var lines = [title, String(repeating: "=", count: title.count), ""]
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                lines.append("")
                lines.append(String(repeating: "=", count: 48))
                lines.append("")
            }

            lines.append(
                formatExportText(
                    from: entry.snapshot,
                    trackedDomain: entry.trackedDomain,
                    changeSummary: entry.changeSummary,
                    diffSections: entry.diffSections
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    static func formatCSV(from snapshots: [LookupSnapshot]) -> String {
        let headers = [
            "domain",
            "availability",
            "primary_ip",
            "redirect_target",
            "tls_status",
            "http_status_grade",
            "email_security_summary",
            "registrar",
            "ownership_expires",
            "ownership_status",
            "ownership_nameservers",
            "subdomain_count",
            "subdomains",
            "last_updated"
        ]

        let rows = snapshots.map { snapshot in
            [
                snapshot.domain,
                availabilityLabel(snapshot.availabilityResult?.status),
                primaryIPAddress(from: snapshot) ?? "",
                finalRedirectTarget(from: snapshot) ?? "",
                httpsSummary(from: snapshot),
                httpStatusGradeSummary(from: snapshot),
                emailSummary(from: snapshot),
                snapshot.ownership?.registrar ?? "",
                snapshot.ownership?.expirationDate.map(csvDateFormatter.string(from:)) ?? "",
                snapshot.ownership?.status.joined(separator: " | ") ?? "",
                snapshot.ownership?.nameservers.joined(separator: " | ") ?? "",
                "\(snapshot.subdomains.count)",
                snapshot.subdomains.map(\.hostname).joined(separator: " | "),
                csvDateFormatter.string(from: snapshot.timestamp)
            ]
        }

        return ([headers] + rows)
            .map { row in row.map(csvEscaped).joined(separator: ",") }
            .joined(separator: "\n")
    }

    static func formatExportText(
        from snapshot: LookupSnapshot,
        trackedDomain: TrackedDomain?,
        changeSummary: DomainChangeSummary?,
        diffSections: [DomainDiffSection]
    ) -> String {
        let exportDateFormatter = DateFormatter()
        exportDateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            "DomainDig Export",
            "Domain: \(snapshot.domain)",
            "Date: \(exportDateFormatter.string(from: snapshot.timestamp))",
            "Mode: \(snapshot.statusMessage ?? snapshot.resultSource.label)",
            "Resolver: \(snapshot.resolverDisplayName)",
            "Lookup Duration: \(durationLabel(snapshot.totalLookupDurationMs))",
            "Tracked: \(trackedDomain == nil ? "No" : "Yes")"
        ]

        if let note = trackedDomain?.note?.nilIfEmpty {
            lines.append("Tracking Note: \(note)")
        }

        func appendSection(_ title: String, _ body: [String]) {
            lines.append("")
            lines.append(title)
            lines.append(String(repeating: "-", count: title.count))
            lines += body
        }

        appendSection("Summary", exportSummaryLines(snapshot, changeSummary: changeSummary, exportDateFormatter: exportDateFormatter))
        appendSection("Tracking", exportTrackingLines(trackedDomain, exportDateFormatter: exportDateFormatter))
        appendSection("Diff Summary", exportDiffSummaryLines(diffSections))
        appendSection("Domain", exportDomainLines(snapshot))
        appendSection("Ownership", exportOwnershipLines(snapshot))
        appendSection("Subdomains", exportSubdomainsLines(snapshot))
        appendSection("DNS", exportDnsLines(snapshot))
        appendSection("Web", exportWebLines(snapshot))
        appendSection("Email", exportEmailLines(snapshot))
        appendSection("Network", exportNetworkLines(snapshot))

        return lines.joined(separator: "\n")
    }

    private static func exportSummaryLines(
        _ snapshot: LookupSnapshot,
        changeSummary: DomainChangeSummary?,
        exportDateFormatter: DateFormatter
    ) -> [String] {
        var lines: [String] = []
        for item in summaryFields(from: snapshot) {
            lines.append("  \(item.label): \(item.value)")
        }
        if let changeSummary {
            lines.append("  Change Summary: \(changeSummary.message)")
            lines.append("  Severity: \(changeSummary.severity.title)")
            lines.append("  Changed Sections: \(changeSummary.changedSections.isEmpty ? "None" : changeSummary.changedSections.joined(separator: ", "))")
            lines.append("  Compared At: \(exportDateFormatter.string(from: changeSummary.generatedAt))")
        }
        return lines
    }

    private static func exportTrackingLines(_ trackedDomain: TrackedDomain?, exportDateFormatter: DateFormatter) -> [String] {
        var lines: [String] = []
        if let trackedDomain {
            lines.append("  Pinned: \(trackedDomain.isPinned ? "Yes" : "No")")
            lines.append("  Last Refresh: \(exportDateFormatter.string(from: trackedDomain.updatedAt))")
            lines.append("  Last Known Availability: \(availabilityLabel(trackedDomain.lastKnownAvailability))")
            if let note = trackedDomain.note?.nilIfEmpty {
                lines.append("  Note: \(note)")
            }
        } else {
            lines.append("  This domain is not currently tracked.")
        }
        return lines
    }

    private static func exportDiffSummaryLines(_ diffSections: [DomainDiffSection]) -> [String] {
        var lines: [String] = []
        if diffSections.isEmpty {
            lines.append("  No comparison available")
        } else {
            for section in diffSections where section.items.contains(where: { $0.changeType != .unchanged }) {
                lines.append("  \(section.title)")
                for item in section.items where item.changeType != .unchanged {
                    lines.append("    [\(item.changeType.rawValue.capitalized)] \(item.label): \(item.oldValue ?? "None") -> \(item.newValue ?? "None")")
                }
            }
        }
        return lines
    }

    private static func exportDomainLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        for row in domainRows(from: snapshot) {
            lines.append("  \(row.label): \(row.value)")
        }
        if snapshot.suggestions.isEmpty {
            lines.append("  Suggestions: None")
        } else {
            lines.append("  Suggestions:")
            for suggestion in snapshot.suggestions {
                lines.append("    \(suggestion.domain): \(availabilityLabel(suggestion.status))")
            }
        }
        return lines
    }

    private static func exportOwnershipLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        for row in ownershipRows(from: snapshot) {
            lines.append("  \(row.label): \(row.value)")
        }
        if let ownershipError = snapshot.ownershipError, snapshot.ownership == nil {
            lines.append("  Source: \(ownershipError)")
        }
        return lines
    }

    private static func exportSubdomainsLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        lines.append("  Count: \(snapshot.subdomains.count)")
        if snapshot.subdomains.isEmpty {
            lines.append("  \(snapshot.subdomainsError ?? "No passive subdomains found")")
        } else {
            for subdomain in subdomainRows(from: snapshot) {
                let marker = subdomain.isInteresting ? " [interesting]" : ""
                lines.append("  \(subdomain.hostname)\(marker)")
            }
        }
        if !FeatureAccessService.hasAccess(to: .extendedSubdomains) {
            lines.append("  Extended subdomain discovery (Pro)")
        }
        return lines
    }

    private static func exportDnsLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        if let dnsError = snapshot.dnsError {
            lines.append("  Error: \(dnsError)")
        }
        if let dnssecLabel = dnssecLabel(from: snapshot) {
            lines.append("  \(dnssecLabel)")
        }
        for section in dnsRows(from: snapshot) {
            lines += exportDNSSectionLines(section)
        }
        if let ptrRecord = snapshot.ptrRecord {
            lines.append("  PTR: \(ptrRecord)")
        } else if let ptrError = snapshot.ptrError {
            lines.append("  PTR Error: \(ptrError)")
        }
        return lines
    }

    private static func exportDNSSectionLines(_ section: DNSRecordSectionViewData) -> [String] {
        var lines = ["  \(section.title)"]
        if let message = section.message {
            lines.append("    \(message.isError ? "Error" : "Info"): \(message.text)")
        }
        for row in section.rows {
            lines.append("    \(row.value) (\(row.label))")
        }
        if let wildcardTitle = section.wildcardTitle {
            lines.append("    \(wildcardTitle)")
            for row in section.wildcardRows {
                lines.append("      \(row.value) (\(row.label))")
            }
        }
        return lines
    }

    private static func exportResponseLines(_ snapshot: LookupSnapshot) -> [String] {
        if let httpHeadersError = snapshot.httpHeadersError {
            return ["  Headers Error: \(httpHeadersError)"]
        }
        var lines = webResponseRows(from: snapshot).map { "  \($0.label): \($0.value)" }
        if snapshot.httpHeaders.isEmpty {
            lines.append("  Headers: No headers returned")
        } else {
            lines.append("  Headers:")
            for header in snapshot.httpHeaders {
                lines.append("    \(header.name): \(header.value)")
            }
        }
        return lines
    }

    private static func exportWebLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        if let sslError = snapshot.sslError {
            lines.append("  TLS Error: \(sslError)")
        } else {
            for row in webCertificateRows(from: snapshot) {
                lines.append("  \(row.label): \(row.value)")
            }
        }
        lines += exportResponseLines(snapshot)

        if let redirectChainError = snapshot.redirectChainError {
            lines.append("  Redirect Error: \(redirectChainError)")
        } else if snapshot.redirectChain.isEmpty {
            lines.append("  Redirects: No redirect data available")
        } else {
            lines.append("  Redirects:")
            for hop in redirectRows(from: snapshot) {
                lines.append("    \(hop.stepLabel). \(hop.statusCode) \(hop.url)\(hop.isFinal ? " (final)" : "")")
            }
        }
        return lines
    }

    private static func exportEmailLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        if let emailSecurityError = snapshot.emailSecurityError {
            lines.append("  Error: \(emailSecurityError)")
        } else if emailRows(from: snapshot).isEmpty {
            lines.append("  No email security records found")
        } else {
            for row in emailRows(from: snapshot) {
                lines.append("  \(row.label): \(row.status)")
                lines.append("    \(row.detail)")
                if let auxiliaryDetail = row.auxiliaryDetail {
                    lines.append("    \(auxiliaryDetail)")
                }
            }
        }
        return lines
    }

    private static func exportPortLines(_ rows: [PortScanRowViewData]) -> [String] {
        guard !rows.isEmpty else { return ["    No results"] }
        var lines: [String] = []
        for row in rows {
            lines.append("    \(row.portLabel) \(row.service): \(row.statusLabel)\(row.durationLabel.map { " \($0)" } ?? "")")
            if let banner = row.banner {
                lines.append("      Banner: \(banner)")
            }
        }
        return lines
    }

    private static func exportNetworkLines(_ snapshot: LookupSnapshot) -> [String] {
        var lines: [String] = []
        if let reachabilityError = snapshot.reachabilityError {
            lines.append("  Reachability Error: \(reachabilityError)")
        } else if reachabilityRows(from: snapshot).isEmpty {
            lines.append("  Reachability: No results")
        } else {
            lines.append("  Reachability:")
            for row in reachabilityRows(from: snapshot) {
                lines.append("    \(row.portLabel): \(row.statusLabel) \(row.latencyLabel)")
            }
        }

        if let ipGeolocationError = snapshot.ipGeolocationError, snapshot.ipGeolocation == nil {
            lines.append("  Location Error: \(ipGeolocationError)")
        } else if locationRows(from: snapshot).isEmpty {
            lines.append("  Location: No data")
        } else {
            lines.append("  Location:")
            for row in locationRows(from: snapshot) {
                lines.append("    \(row.label): \(row.value)")
            }
        }

        if let portScanError = snapshot.portScanError, snapshot.portScanResults.isEmpty {
            lines.append("  Port Scan Error: \(portScanError)")
        }

        lines.append("  Standard Ports:")
        lines += exportPortLines(portRows(from: snapshot, kind: .standard))
        lines.append("  Custom Ports:")
        lines += exportPortLines(portRows(from: snapshot, kind: .custom))
        return lines
    }

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func httpStatusGradeSummary(from snapshot: LookupSnapshot) -> String {
        let parts = [snapshot.httpStatusCode.map(String.init), snapshot.httpSecurityGrade].compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: " / ")
        }
        return snapshot.httpHeadersError ?? "Unavailable"
    }
}


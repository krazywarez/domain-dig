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
        try? DomainDataPortabilityService.backupData()
    }

    func exportPortableTrackedDomainsJSONData() -> Data? {
        try? DomainDataPortabilityService.trackedDomainsExportData()
    }

    func exportPortableTrackedDomainsCSV() -> String {
        DomainDataPortabilityService.trackedDomainsCSV()
    }

    func exportPortableWorkflowsJSONData() -> Data? {
        try? DomainDataPortabilityService.workflowsExportData()
    }

    func exportPortableWorkflowsCSV() -> String {
        DomainDataPortabilityService.workflowsCSV()
    }

    func exportPortableHistoryJSONData() -> Data? {
        try? DomainDataPortabilityService.historyExportData()
    }

    func prepareDataImport(
        data: Data,
        fileName: String,
        mode: DataPortabilityImportMode
    ) throws -> DataImportPreview {
        try DomainDataPortabilityService.prepareImport(data: data, fileName: fileName, mode: mode)
    }

    func applyDataImport(_ preview: DataImportPreview, mode: DataPortabilityImportMode) throws -> DataImportResult {
        let result = try DomainDataPortabilityService.applyImport(preview, mode: mode)
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
            )
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

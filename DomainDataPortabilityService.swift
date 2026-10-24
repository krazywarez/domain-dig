import Foundation
import UniformTypeIdentifiers

struct DomainDigBackup: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let trackedDomains: [TrackedDomain]
    let historyEntries: [HistoryEntry]
    let auditSessions: [AuditSession]?
    let workflows: [DomainWorkflow]
    let monitoringSettings: MonitoringSettings?
    let monitoringLogs: [MonitoringLog]
    let appSettings: AppSettingsSnapshot
    let featureMetadata: FeatureMetadataSnapshot?
}

struct AppSettingsSnapshot: Codable {
    let recentSearches: [String]
    let savedDomains: [String]
    let resolverURLString: String
    let appDensityRawValue: String
}

struct FeatureMetadataSnapshot: Codable {
    let cachedEntitlement: PurchaseService.CachedEntitlement?
}

struct TrackedDomainsExport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let trackedDomains: [TrackedDomain]
}

struct WorkflowsExport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let workflows: [DomainWorkflow]
}

struct HistoryExport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let historyEntries: [HistoryEntry]
}

enum DataPortabilityImportMode: String, CaseIterable, Identifiable {
    case merge
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge:
            return "Merge"
        case .replace:
            return "Replace"
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            return "Keep local data and merge imported items."
        case .replace:
            return "Replace local data with the imported file."
        }
    }
}

enum DataPortabilityImportKind: String {
    case backup
    case trackedDomains
    case workflows
}

struct DataLifecycleSummary: Equatable {
    let trackedDomains: Int
    let historySnapshots: Int
    let auditSessions: Int
    let workflows: Int
    let cachedItems: Int
    let monitoringLogs: Int
}

struct DataValidationMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct DataValidationReport {
    let messages: [DataValidationMessage]

    var warnings: [String] {
        messages.filter { !$0.isError }.map(\.text)
    }

    var errors: [String] {
        messages.filter(\.isError).map(\.text)
    }
}

struct DataImportPreview {
    let fileName: String
    let kind: DataPortabilityImportKind
    let mode: DataPortabilityImportMode
    let summaryLines: [String]
    let warnings: [String]
    let currentCounts: DataLifecycleSummary
    let projectedCounts: DataLifecycleSummary
    fileprivate let payload: ImportPayload
}

struct DataImportResult {
    let kind: DataPortabilityImportKind
    let mode: DataPortabilityImportMode
    let summary: String
    let warnings: [String]
}

enum DataPortabilityError: LocalizedError {
    case unsupportedFormat
    case unsupportedSchema(Int)
    case invalidCSV(String)
    case unreadableFile
    case validationFailed([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The selected file is not a supported DomainDig import."
        case .unsupportedSchema(let version):
            return "Backup schema v\(version) is not supported by this version of DomainDig."
        case .invalidCSV(let message):
            return message
        case .unreadableFile:
            return "The selected file could not be read."
        case .validationFailed(let messages):
            return messages.joined(separator: "\n")
        }
    }
}

enum DataPortabilityCSV {
    static func trackedDomains(_ domains: [TrackedDomain]) -> String {
        let header = [
            "id",
            "domain",
            "createdAt",
            "updatedAt",
            "note",
            "isPinned",
            "monitoringEnabled",
            "lastKnownAvailability",
            "certificateWarningLevel",
            "certificateDaysRemaining",
            "lastMonitoredAt",
            "lastAlertAt"
        ]

        let rows = domains.map { domain in
            [
                domain.id.uuidString,
                domain.domain,
                DomainDataPortabilityService.formatISODate(domain.createdAt),
                DomainDataPortabilityService.formatISODate(domain.updatedAt),
                domain.note ?? "",
                String(domain.isPinned),
                String(domain.monitoringEnabled),
                domain.lastKnownAvailability?.rawValue ?? "",
                domain.certificateWarningLevel.rawValue,
                domain.certificateDaysRemaining.map(String.init) ?? "",
                domain.lastMonitoredAt.map(DomainDataPortabilityService.formatISODate) ?? "",
                domain.lastAlertAt.map(DomainDataPortabilityService.formatISODate) ?? ""
            ]
        }

        return ([header] + rows).map(Self.csvLine).joined(separator: "\n")
    }

    static func workflows(_ workflows: [DomainWorkflow]) -> String {
        let header = ["id", "name", "domains", "createdAt", "updatedAt", "notes"]
        let rows = workflows.map { workflow in
            [
                workflow.id.uuidString,
                workflow.name,
                workflow.domains.joined(separator: "|"),
                DomainDataPortabilityService.formatISODate(workflow.createdAt),
                DomainDataPortabilityService.formatISODate(workflow.updatedAt),
                workflow.notes ?? ""
            ]
        }

        return ([header] + rows).map(Self.csvLine).joined(separator: "\n")
    }

    static func parseTrackedDomains(from string: String) throws -> [TrackedDomain] {
        let rows = try parseRows(from: string)
        guard let header = rows.first else { return [] }
        let mappedRows = rows.dropFirst().map { dictionary(for: Array($0), header: header) }

        return mappedRows.compactMap { row in
            let domain = Self.normalizedDomain(row["domain"])
            guard !domain.isEmpty else { return nil }

            let createdAt = parseDate(row["createdAt"]) ?? Date()
            let updatedAt = parseDate(row["updatedAt"]) ?? createdAt
            let availability = row["lastKnownAvailability"].flatMap(DomainAvailabilityStatus.init(rawValue:))
            let certificateLevel = row["certificateWarningLevel"].flatMap(CertificateWarningLevel.init(rawValue:)) ?? .none

            return TrackedDomain(
                id: UUID(uuidString: row["id"] ?? "") ?? UUID(),
                domain: domain,
                createdAt: createdAt,
                updatedAt: updatedAt,
                note: row["note"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                isPinned: Self.parseBool(row["isPinned"]),
                monitoringEnabled: row["monitoringEnabled"].map(Self.parseBool) ?? true,
                lastKnownAvailability: availability,
                certificateWarningLevel: certificateLevel,
                certificateDaysRemaining: Int(row["certificateDaysRemaining"] ?? ""),
                lastMonitoredAt: parseDate(row["lastMonitoredAt"]),
                lastAlertAt: parseDate(row["lastAlertAt"]),
                monitoringState: MonitoringState(),
                pendingMonitoringAlerts: []
            )
        }
    }

    static func parseWorkflows(from string: String) throws -> [DomainWorkflow] {
        let rows = try parseRows(from: string)
        guard let header = rows.first else { return [] }
        let mappedRows = rows.dropFirst().map { dictionary(for: Array($0), header: header) }

        return mappedRows.compactMap { row in
            let name = row["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let domains = (row["domains"] ?? "")
                .split(separator: "|")
                .map { Self.normalizedDomain(String($0)) }
                .filter { !$0.isEmpty }

            guard !name.isEmpty, !domains.isEmpty else { return nil }

            let createdAt = parseDate(row["createdAt"]) ?? Date()
            let updatedAt = parseDate(row["updatedAt"]) ?? createdAt
            return DomainWorkflow(
                id: UUID(uuidString: row["id"] ?? "") ?? UUID(),
                name: name,
                domains: Self.deduplicated(domains),
                createdAt: createdAt,
                updatedAt: updatedAt,
                notes: row["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }
    }

    private nonisolated static func parseRows(from string: String) throws -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        for character in string {
            switch character {
            case "\"":
                insideQuotes.toggle()
            case "," where !insideQuotes:
                currentRow.append(currentField)
                currentField = ""
            case "\n" where !insideQuotes:
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
            case "\r":
                continue
            default:
                currentField.append(character)
            }
        }

        if insideQuotes {
            throw DataPortabilityError.invalidCSV("The CSV file is malformed.")
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    private nonisolated static func dictionary(for row: [String], header: [String]) -> [String: String] {
        // A repeated column keeps its first value rather than failing the import.
        Dictionary(zip(header, row).map { ($0.0, $0.1) }) { first, _ in first }
    }

    private nonisolated static func csvLine(_ values: [String]) -> String {
        values.map { value in
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        .joined(separator: ",")
    }

    private nonisolated static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return DomainDataPortabilityService.parseISODate(value)
    }

    private nonisolated static func parseBool(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private nonisolated static func normalizedDomain(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }

    private nonisolated static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Versioned migration runner for the on-device persisted store.
///
/// The store is a set of independent JSON blobs in `UserDefaults` (tracked
/// domains, history, audits, workflows, monitoring settings/logs, app settings).
/// Most model evolution is handled additively by the models' own lenient
/// decoders (`decodeIfPresent` with defaults), which need no migration at all.
/// This runner exists only for changes lenient decoding can't express: dropping
/// a renamed storage key, re-normalizing existing rows, or reshaping a blob.
///
/// `currentStoreSchemaVersion` is bumped whenever such a step is added. Each step
/// runs exactly once, in ascending order, and must be safe to run on any prior
/// state — including an empty store. A store written by a newer build (a higher
/// version than this build knows) is left untouched; migrations never downgrade.
/// The policy is documented in `Docs/data-migration.md`.
enum DataMigrationService {
    /// The schema version this build expects the on-device store to be at.
    static let currentStoreSchemaVersion = 1

    /// UserDefaults key holding the store's current schema version.
    static let storeSchemaVersionKey = "data.storeSchemaVersion"

    /// Pre-versioning installs recorded that the one-shot v1 normalization had
    /// run using this boolean marker; `true` means the store is already at v1.
    private static let legacyNormalizationMarkerKey = "data.migrations.v3_4_0"

    /// The store's current schema version. Absent on pre-versioning installs: a
    /// set legacy marker means v1 already ran, otherwise the store is fresh or
    /// never-migrated at v0.
    static func storeSchemaVersion(defaults: UserDefaults = .standard) -> Int {
        if let version = defaults.object(forKey: storeSchemaVersionKey) as? Int {
            return version
        }
        return defaults.bool(forKey: legacyNormalizationMarkerKey) ? 1 : 0
    }

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        // At or ahead of this build's version: nothing to do, and never rewrite
        // a store a newer build may have reshaped (forward compatibility).
        guard storeSchemaVersion(defaults: defaults) < currentStoreSchemaVersion else { return }

        var version = storeSchemaVersion(defaults: defaults)
        while version < currentStoreSchemaVersion {
            let target = version + 1
            runMigration(to: target, defaults: defaults)
            defaults.set(target, forKey: storeSchemaVersionKey)
            version = target
        }
    }

    private static func runMigration(to version: Int, defaults: UserDefaults) {
        switch version {
        case 1:
            normalizeAllStores(defaults: defaults)
        default:
            break
        }
    }

    /// v1: load every store through its deduplicating loader and write it back.
    /// This consolidates duplicate rows, drops the legacy `watchedDomains` key
    /// (via `saveTrackedDomains`), and sanitizes monitoring settings against the
    /// surviving tracked domains. Safe on an empty store (every step is a no-op).
    private static func normalizeAllStores(defaults: UserDefaults) {
        let trackedDomains = DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)
        DomainDataPortabilityService.saveTrackedDomains(trackedDomains, defaults: defaults)

        let historyEntries = DomainDataPortabilityService.loadHistoryEntries(defaults: defaults)
        DomainDataPortabilityService.saveHistoryEntries(historyEntries, defaults: defaults)

        let auditSessions = DomainDataPortabilityService.loadAuditSessions(defaults: defaults)
        DomainDataPortabilityService.saveAuditSessions(auditSessions, defaults: defaults)

        let workflows = DomainDataPortabilityService.loadWorkflows(defaults: defaults)
        DomainDataPortabilityService.saveWorkflows(workflows, defaults: defaults)

        let monitoringSettings = DomainDataPortabilityService.loadMonitoringSettings(defaults: defaults)
        let sanitizedMonitoringSettings = MonitoringStorage.sanitizeSettings(monitoringSettings, trackedDomains: trackedDomains)
        DomainDataPortabilityService.saveMonitoringSettings(sanitizedMonitoringSettings, defaults: defaults)

        let monitoringLogs = DomainDataPortabilityService.loadMonitoringLogs(defaults: defaults)
        DomainDataPortabilityService.saveMonitoringLogs(monitoringLogs, defaults: defaults)
    }
}

enum DataValidationService {
    static func validate(backup: DomainDigBackup) -> DataValidationReport {
        var messages: [DataValidationMessage] = []

        if backup.schemaVersion > DomainDigBackup.currentSchemaVersion {
            messages.append(.init(text: "This backup was created by a newer DomainDig version.", isError: true))
        } else if backup.schemaVersion < DomainDigBackup.currentSchemaVersion {
            messages.append(.init(text: "Older backup schema detected. DomainDig will import using compatibility rules.", isError: false))
        }

        messages.append(contentsOf: validateTrackedDomains(backup.trackedDomains))
        messages.append(contentsOf: validateHistoryEntries(backup.historyEntries))
        messages.append(contentsOf: validateAuditSessions(backup.auditSessions ?? []))
        messages.append(contentsOf: validateWorkflows(backup.workflows))

        if backup.appSettings.resolverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.init(text: "Backup is missing a resolver URL. The default resolver will be used.", isError: false))
        }

        return DataValidationReport(messages: messages)
    }

    static func validate(trackedDomains: [TrackedDomain]) -> DataValidationReport {
        DataValidationReport(messages: validateTrackedDomains(trackedDomains))
    }

    static func validate(workflows: [DomainWorkflow]) -> DataValidationReport {
        DataValidationReport(messages: validateWorkflows(workflows))
    }

    private static func validateTrackedDomains(_ trackedDomains: [TrackedDomain]) -> [DataValidationMessage] {
        var messages: [DataValidationMessage] = []
        var seen = Set<String>()

        for trackedDomain in trackedDomains {
            let normalized = normalizeDomain(trackedDomain.domain)
            if normalized.isEmpty {
                messages.append(.init(text: "A tracked domain entry is missing its domain name.", isError: true))
                continue
            }

            if !seen.insert(normalized).inserted {
                messages.append(.init(text: "Duplicate tracked domain found for \(normalized). Merge rules will consolidate it.", isError: false))
            }
        }

        return messages
    }

    private static func validateHistoryEntries(_ historyEntries: [HistoryEntry]) -> [DataValidationMessage] {
        var messages: [DataValidationMessage] = []
        for entry in historyEntries {
            if normalizeDomain(entry.domain).isEmpty {
                messages.append(.init(text: "A history snapshot is missing its domain name.", isError: true))
            }
            if entry.timestamp == .distantPast {
                messages.append(.init(text: "A history snapshot is missing its timestamp.", isError: false))
            }
            for issue in entry.validationIssues {
                messages.append(.init(text: "History warning for \(entry.domain): \(issue)", isError: false))
            }
        }
        return messages
    }

    private static func validateAuditSessions(_ auditSessions: [AuditSession]) -> [DataValidationMessage] {
        var messages: [DataValidationMessage] = []
        var seen = Set<UUID>()

        for session in auditSessions {
            if normalizeDomain(session.domain).isEmpty {
                messages.append(.init(text: "An audit session is missing its domain name.", isError: true))
            }

            if !seen.insert(session.id).inserted {
                messages.append(.init(text: "Duplicate audit session found for \(session.domain). Merge rules will consolidate it.", isError: false))
            }
        }

        return messages
    }

    private static func validateWorkflows(_ workflows: [DomainWorkflow]) -> [DataValidationMessage] {
        var messages: [DataValidationMessage] = []
        for workflow in workflows {
            if workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(.init(text: "A workflow is missing its name.", isError: true))
            }
            if workflow.domains.isEmpty {
                messages.append(.init(text: "Workflow \(workflow.name) has no domains.", isError: false))
            }
            if Set(workflow.domains.map(Self.normalizeDomain)).count != workflow.domains.count {
                messages.append(.init(text: "Workflow \(workflow.name) contains duplicate domains. Import will deduplicate them.", isError: false))
            }
        }
        return messages
    }

    private nonisolated static func normalizeDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }
}

enum DomainDataPortabilityService {
    static let backupUTType = UTType.json
    static let csvUTType = UTType.commaSeparatedText

    fileprivate nonisolated static func formatISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    fileprivate nonisolated static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private enum StorageKey {
        static let recentSearches = "recentSearches"
        static let savedDomains = "savedDomains"
        static let trackedDomains = "trackedDomains"
        static let legacyWatchedDomains = "watchedDomains"
        static let history = "lookupHistory"
        static let audits = "domainAudits"
        static let workflows = "domainWorkflows"
        static let monitoringSettings = "monitoring.settings"
        static let monitoringLogs = "monitoring.logs"
        static let appDensity = AppDensity.userDefaultsKey
        static let resolverURL = DNSResolverOption.userDefaultsKey
        static let purchaseCache = "purchase.cachedEntitlement"
    }

    static func loadRecentSearches(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: StorageKey.recentSearches) ?? []
    }

    static func saveRecentSearches(_ values: [String], defaults: UserDefaults = .standard) {
        defaults.set(Array(values.prefix(20)), forKey: StorageKey.recentSearches)
    }

    static func loadSavedDomains(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: StorageKey.savedDomains) ?? []
    }

    static func saveSavedDomains(_ values: [String], defaults: UserDefaults = .standard) {
        defaults.set(values, forKey: StorageKey.savedDomains)
    }

    static func loadTrackedDomains(defaults: UserDefaults = .standard) -> [TrackedDomain] {
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: StorageKey.trackedDomains),
           let domains = try? decoder.decode([TrackedDomain].self, from: data) {
            return deduplicatedTrackedDomains(domains)
        }

        if let data = defaults.data(forKey: StorageKey.legacyWatchedDomains),
           let legacy = try? decoder.decode([WatchedDomain].self, from: data) {
            return deduplicatedTrackedDomains(
                legacy.map {
                    TrackedDomain(
                        id: $0.id,
                        domain: normalizeDomain($0.domain),
                        createdAt: $0.createdAt,
                        updatedAt: $0.createdAt,
                        lastKnownAvailability: $0.lastKnownAvailability
                    )
                }
            )
        }

        return []
    }

    static func saveTrackedDomains(_ trackedDomains: [TrackedDomain], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(deduplicatedTrackedDomains(trackedDomains)) {
            defaults.set(data, forKey: StorageKey.trackedDomains)
        }
        defaults.removeObject(forKey: StorageKey.legacyWatchedDomains)
    }

    static func loadHistoryEntries(defaults: UserDefaults = .standard) -> [HistoryEntry] {
        guard let data = defaults.data(forKey: StorageKey.history) else { return [] }

        if let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            return deduplicatedHistoryEntries(entries)
        }

        guard let rawArray = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }

        let decoder = JSONDecoder()
        let entries = rawArray.compactMap { item -> HistoryEntry? in
            guard JSONSerialization.isValidJSONObject(item),
                  let entryData = try? JSONSerialization.data(withJSONObject: item) else {
                return nil
            }
            return try? decoder.decode(HistoryEntry.self, from: entryData)
        }
        return deduplicatedHistoryEntries(entries)
    }

    static func saveHistoryEntries(_ historyEntries: [HistoryEntry], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(deduplicatedHistoryEntries(historyEntries)) {
            defaults.set(data, forKey: StorageKey.history)
        }
    }

    static func loadAuditSessions(defaults: UserDefaults = .standard) -> [AuditSession] {
        guard let data = defaults.data(forKey: StorageKey.audits),
              let sessions = try? JSONDecoder().decode([AuditSession].self, from: data) else {
            return []
        }
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    static func saveAuditSessions(_ auditSessions: [AuditSession], defaults: UserDefaults = .standard) {
        let sessions = auditSessions.sorted { $0.createdAt > $1.createdAt }
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: StorageKey.audits)
        }
    }

    static func loadWorkflows(defaults: UserDefaults = .standard) -> [DomainWorkflow] {
        guard let data = defaults.data(forKey: StorageKey.workflows),
              let workflows = try? JSONDecoder().decode([DomainWorkflow].self, from: data) else {
            return []
        }

        return deduplicatedWorkflows(workflows).sorted(by: workflowSort)
    }

    static func saveWorkflows(_ workflows: [DomainWorkflow], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(deduplicatedWorkflows(workflows)) {
            defaults.set(data, forKey: StorageKey.workflows)
        }
    }

    static func loadMonitoringSettings(defaults: UserDefaults = .standard) -> MonitoringSettings {
        guard let data = defaults.data(forKey: StorageKey.monitoringSettings),
              let settings = try? JSONDecoder().decode(MonitoringSettings.self, from: data) else {
            return MonitoringSettings()
        }
        return settings
    }

    static func saveMonitoringSettings(_ settings: MonitoringSettings, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: StorageKey.monitoringSettings)
        }
    }

    static func loadMonitoringLogs(defaults: UserDefaults = .standard) -> [MonitoringLog] {
        guard let data = defaults.data(forKey: StorageKey.monitoringLogs),
              let logs = try? JSONDecoder().decode([MonitoringLog].self, from: data) else {
            return []
        }
        return Array(logs.prefix(MonitoringStorage.maxLogs))
    }

    static func saveMonitoringLogs(_ logs: [MonitoringLog], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(Array(logs.prefix(MonitoringStorage.maxLogs))) {
            defaults.set(data, forKey: StorageKey.monitoringLogs)
        }
    }

    static func loadAppSettings(defaults: UserDefaults = .standard) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            recentSearches: loadRecentSearches(defaults: defaults),
            savedDomains: loadSavedDomains(defaults: defaults),
            resolverURLString: defaults.string(forKey: StorageKey.resolverURL) ?? DNSResolverOption.defaultURLString,
            appDensityRawValue: defaults.string(forKey: StorageKey.appDensity) ?? AppDensity.compact.rawValue
        )
    }

    static func saveAppSettings(_ settings: AppSettingsSnapshot, defaults: UserDefaults = .standard) {
        saveRecentSearches(settings.recentSearches, defaults: defaults)
        saveSavedDomains(settings.savedDomains, defaults: defaults)
        defaults.set(settings.resolverURLString, forKey: StorageKey.resolverURL)
        defaults.set(settings.appDensityRawValue, forKey: StorageKey.appDensity)
    }

    static func loadFeatureMetadata(defaults: UserDefaults = .standard) -> FeatureMetadataSnapshot {
        let cachedEntitlement: PurchaseService.CachedEntitlement?
        if let data = defaults.data(forKey: StorageKey.purchaseCache) {
            cachedEntitlement = try? JSONDecoder().decode(PurchaseService.CachedEntitlement.self, from: data)
        } else {
            cachedEntitlement = nil
        }

        return FeatureMetadataSnapshot(cachedEntitlement: cachedEntitlement)
    }

    static func saveFeatureMetadata(_ featureMetadata: FeatureMetadataSnapshot?, defaults: UserDefaults = .standard) {
        if let cachedEntitlement = featureMetadata?.cachedEntitlement,
           let data = try? JSONEncoder().encode(cachedEntitlement) {
            defaults.set(data, forKey: StorageKey.purchaseCache)
        }
    }

    static func currentBackup(defaults: UserDefaults = .standard) -> DomainDigBackup {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        return DomainDigBackup(
            schemaVersion: DomainDigBackup.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: AppVersion.current,
            trackedDomains: loadTrackedDomains(defaults: defaults),
            historyEntries: loadHistoryEntries(defaults: defaults),
            auditSessions: loadAuditSessions(defaults: defaults),
            workflows: loadWorkflows(defaults: defaults),
            monitoringSettings: loadMonitoringSettings(defaults: defaults),
            monitoringLogs: loadMonitoringLogs(defaults: defaults),
            appSettings: loadAppSettings(defaults: defaults),
            featureMetadata: loadFeatureMetadata(defaults: defaults)
        )
    }

    static func backupData(defaults: UserDefaults = .standard) throws -> Data {
        try makeEncoder().encode(currentBackup(defaults: defaults))
    }

    static func trackedDomainsExportData(defaults: UserDefaults = .standard) throws -> Data {
        try makeEncoder().encode(
            TrackedDomainsExport(
                schemaVersion: DomainDigBackup.currentSchemaVersion,
                exportedAt: Date(),
                appVersion: AppVersion.current,
                trackedDomains: loadTrackedDomains(defaults: defaults)
            )
        )
    }

    static func workflowsExportData(defaults: UserDefaults = .standard) throws -> Data {
        try makeEncoder().encode(
            WorkflowsExport(
                schemaVersion: DomainDigBackup.currentSchemaVersion,
                exportedAt: Date(),
                appVersion: AppVersion.current,
                workflows: loadWorkflows(defaults: defaults)
            )
        )
    }

    static func historyExportData(defaults: UserDefaults = .standard) throws -> Data {
        try makeEncoder().encode(
            HistoryExport(
                schemaVersion: DomainDigBackup.currentSchemaVersion,
                exportedAt: Date(),
                appVersion: AppVersion.current,
                historyEntries: loadHistoryEntries(defaults: defaults)
            )
        )
    }

    static func trackedDomainsCSV(defaults: UserDefaults = .standard) -> String {
        DataPortabilityCSV.trackedDomains(loadTrackedDomains(defaults: defaults))
    }

    static func workflowsCSV(defaults: UserDefaults = .standard) -> String {
        DataPortabilityCSV.workflows(loadWorkflows(defaults: defaults))
    }

    static func prepareImport(
        data: Data,
        fileName: String,
        mode: DataPortabilityImportMode,
        defaults: UserDefaults = .standard
    ) throws -> DataImportPreview {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        let currentCounts = lifecycleSummary(defaults: defaults)

        let payload = try decodeImportPayload(from: data, fileName: fileName)
        let projectedCounts = projectCounts(for: payload, mode: mode, defaults: defaults)

        return DataImportPreview(
            fileName: fileName,
            kind: payload.kind,
            mode: mode,
            summaryLines: payload.summaryLines(mode: mode),
            warnings: payload.validationReport.warnings,
            currentCounts: currentCounts,
            projectedCounts: projectedCounts,
            payload: payload
        )
    }

    static func applyImport(
        _ preview: DataImportPreview,
        mode: DataPortabilityImportMode,
        defaults: UserDefaults = .standard
    ) throws -> DataImportResult {
        switch preview.payload {
        case .backup(let backup, let report):
            try applyBackup(backup, mode: mode, defaults: defaults)
            return DataImportResult(
                kind: .backup,
                mode: mode,
                summary: "Imported backup with \(backup.trackedDomains.count) tracked domains, \(backup.historyEntries.count) history snapshots, \(backup.auditSessions?.count ?? 0) audit sessions, and \(backup.workflows.count) workflows.",
                warnings: report.warnings
            )
        case .trackedDomains(let trackedDomains, let report):
            applyTrackedDomainsImport(trackedDomains, mode: mode, defaults: defaults)
            return DataImportResult(
                kind: .trackedDomains,
                mode: mode,
                summary: "Imported \(trackedDomains.count) tracked domains.",
                warnings: report.warnings
            )
        case .workflows(let workflows, let report):
            applyWorkflowsImport(workflows, mode: mode, defaults: defaults)
            return DataImportResult(
                kind: .workflows,
                mode: mode,
                summary: "Imported \(workflows.count) workflows.",
                warnings: report.warnings
            )
        }
    }

    static func validateBackup(data: Data, fileName: String = "backup.json") throws -> DataValidationReport {
        switch try decodeImportPayload(from: data, fileName: fileName) {
        case .backup(_, let report):
            return report
        case .trackedDomains(_, let report):
            return report
        case .workflows(_, let report):
            return report
        }
    }

    static func lifecycleSummary(defaults: UserDefaults = .standard) -> DataLifecycleSummary {
        let appSettings = loadAppSettings(defaults: defaults)
        let featureMetadata = loadFeatureMetadata(defaults: defaults)
        let cachedItems = appSettings.recentSearches.count
            + appSettings.savedDomains.count
            + (featureMetadata.cachedEntitlement == nil ? 0 : 1)

        return DataLifecycleSummary(
            trackedDomains: loadTrackedDomains(defaults: defaults).count,
            historySnapshots: loadHistoryEntries(defaults: defaults).count,
            auditSessions: loadAuditSessions(defaults: defaults).count,
            workflows: loadWorkflows(defaults: defaults).count,
            cachedItems: cachedItems,
            monitoringLogs: loadMonitoringLogs(defaults: defaults).count
        )
    }

    private static func decodeImportPayload(from data: Data, fileName: String) throws -> ImportPayload {
        let decoder = JSONDecoder()

        if let backup = try? decoder.decode(DomainDigBackup.self, from: data) {
            if backup.schemaVersion > DomainDigBackup.currentSchemaVersion {
                throw DataPortabilityError.unsupportedSchema(backup.schemaVersion)
            }
            return .backup(backup, try passing(DataValidationService.validate(backup: backup)))
        }
        if let backup = try? decodeLegacyBackup(from: data) {
            return .backup(backup, try passing(DataValidationService.validate(backup: backup)))
        }
        if let export = try? decoder.decode(TrackedDomainsExport.self, from: data) {
            return try trackedDomainsPayload(export.trackedDomains)
        }
        if let export = try? decoder.decode(WorkflowsExport.self, from: data) {
            return try workflowsPayload(export.workflows)
        }
        if let trackedDomains = try? decoder.decode([TrackedDomain].self, from: data) {
            return try trackedDomainsPayload(trackedDomains)
        }
        if let workflows = try? decoder.decode([DomainWorkflow].self, from: data) {
            return try workflowsPayload(workflows)
        }
        if fileName.lowercased().hasSuffix(".csv") {
            return try decodeCSVPayload(from: data, fileName: fileName)
        }
        throw DataPortabilityError.unsupportedFormat
    }

    /// A CSV holds workflows when its name says so, and tracked domains otherwise.
    private static func decodeCSVPayload(from data: Data, fileName: String) throws -> ImportPayload {
        guard let string = String(data: data, encoding: .utf8) else {
            throw DataPortabilityError.unreadableFile
        }
        if fileName.lowercased().contains("workflow") {
            return try workflowsPayload(DataPortabilityCSV.parseWorkflows(from: string))
        }
        return try trackedDomainsPayload(DataPortabilityCSV.parseTrackedDomains(from: string))
    }

    private static func trackedDomainsPayload(_ trackedDomains: [TrackedDomain]) throws -> ImportPayload {
        .trackedDomains(trackedDomains, try passing(DataValidationService.validate(trackedDomains: trackedDomains)))
    }

    private static func workflowsPayload(_ workflows: [DomainWorkflow]) throws -> ImportPayload {
        .workflows(workflows, try passing(DataValidationService.validate(workflows: workflows)))
    }

    /// `report`, unless it found errors, which fail the import.
    private static func passing(_ report: DataValidationReport) throws -> DataValidationReport {
        guard report.errors.isEmpty else {
            throw DataPortabilityError.validationFailed(report.errors)
        }
        return report
    }

    private static func decodeLegacyBackup(from data: Data) throws -> DomainDigBackup {
        struct LegacyBackup: Decodable {
            let trackedDomains: [TrackedDomain]?
            let historyEntries: [HistoryEntry]?
            let workflows: [DomainWorkflow]?
            let monitoringSettings: MonitoringSettings?
            let monitoringLogs: [MonitoringLog]?
            let recentSearches: [String]?
            let savedDomains: [String]?
        }

        let legacy = try JSONDecoder().decode(LegacyBackup.self, from: data)
        return DomainDigBackup(
            schemaVersion: 0,
            exportedAt: Date(),
            appVersion: AppVersion.current,
            trackedDomains: legacy.trackedDomains ?? [],
            historyEntries: legacy.historyEntries ?? [],
            auditSessions: nil,
            workflows: legacy.workflows ?? [],
            monitoringSettings: legacy.monitoringSettings,
            monitoringLogs: legacy.monitoringLogs ?? [],
            appSettings: AppSettingsSnapshot(
                recentSearches: legacy.recentSearches ?? [],
                savedDomains: legacy.savedDomains ?? [],
                resolverURLString: DNSResolverOption.defaultURLString,
                appDensityRawValue: AppDensity.compact.rawValue
            ),
            featureMetadata: nil
        )
    }

    private static func applyBackup(
        _ backup: DomainDigBackup,
        mode: DataPortabilityImportMode,
        defaults: UserDefaults
    ) throws {
        if mode == .replace {
            saveTrackedDomains(deduplicatedTrackedDomains(backup.trackedDomains), defaults: defaults)
            saveHistoryEntries(deduplicatedHistoryEntries(backup.historyEntries), defaults: defaults)
            saveAuditSessions(backup.auditSessions ?? [], defaults: defaults)
            saveWorkflows(deduplicatedWorkflows(backup.workflows), defaults: defaults)
            saveMonitoringSettings(
                MonitoringStorage.sanitizeSettings(
                    backup.monitoringSettings ?? MonitoringSettings(),
                    trackedDomains: deduplicatedTrackedDomains(backup.trackedDomains)
                ),
                defaults: defaults
            )
            saveMonitoringLogs(backup.monitoringLogs, defaults: defaults)
            saveAppSettings(backup.appSettings, defaults: defaults)
            saveFeatureMetadata(backup.featureMetadata, defaults: defaults)
            return
        }

        let existingTrackedDomains = loadTrackedDomains(defaults: defaults)
        let mergedTrackedDomains = mergeTrackedDomains(existing: existingTrackedDomains, incoming: backup.trackedDomains)
        saveTrackedDomains(mergedTrackedDomains.domains, defaults: defaults)

        let existingHistoryEntries = loadHistoryEntries(defaults: defaults)
        let remappedIncomingHistory = backup.historyEntries.map { remapHistoryEntry($0, using: mergedTrackedDomains.idMap) }
        saveHistoryEntries(
            mergeHistoryEntries(existing: existingHistoryEntries, incoming: remappedIncomingHistory),
            defaults: defaults
        )

        let existingAuditSessions = loadAuditSessions(defaults: defaults)
        let mergedAuditSessions = mergeAuditSessions(existing: existingAuditSessions, incoming: backup.auditSessions ?? [])
        saveAuditSessions(mergedAuditSessions, defaults: defaults)

        let existingWorkflows = loadWorkflows(defaults: defaults)
        saveWorkflows(mergeWorkflows(existing: existingWorkflows, incoming: backup.workflows), defaults: defaults)

        let existingMonitoringLogs = loadMonitoringLogs(defaults: defaults)
        saveMonitoringLogs(mergeMonitoringLogs(existing: existingMonitoringLogs, incoming: backup.monitoringLogs), defaults: defaults)

        let remappedMonitoringSettings = remapMonitoringSettings(
            backup.monitoringSettings ?? MonitoringSettings(),
            using: mergedTrackedDomains.idMap
        )
        saveMonitoringSettings(
            MonitoringStorage.sanitizeSettings(remappedMonitoringSettings, trackedDomains: mergedTrackedDomains.domains),
            defaults: defaults
        )

        let mergedSettings = mergeAppSettings(existing: loadAppSettings(defaults: defaults), incoming: backup.appSettings)
        saveAppSettings(mergedSettings, defaults: defaults)

        let mergedFeatureMetadata = mergeFeatureMetadata(existing: loadFeatureMetadata(defaults: defaults), incoming: backup.featureMetadata)
        saveFeatureMetadata(mergedFeatureMetadata, defaults: defaults)
    }

    private static func applyTrackedDomainsImport(
        _ trackedDomains: [TrackedDomain],
        mode: DataPortabilityImportMode,
        defaults: UserDefaults
    ) {
        let importedDomains = deduplicatedTrackedDomains(trackedDomains)
        let finalDomains: [TrackedDomain]
        switch mode {
        case .merge:
            finalDomains = mergeTrackedDomains(existing: loadTrackedDomains(defaults: defaults), incoming: importedDomains).domains
        case .replace:
            finalDomains = importedDomains
        }

        saveTrackedDomains(finalDomains, defaults: defaults)
        let sanitizedSettings = MonitoringStorage.sanitizeSettings(loadMonitoringSettings(defaults: defaults), trackedDomains: finalDomains)
        saveMonitoringSettings(sanitizedSettings, defaults: defaults)
    }

    private static func applyWorkflowsImport(
        _ workflows: [DomainWorkflow],
        mode: DataPortabilityImportMode,
        defaults: UserDefaults
    ) {
        let importedWorkflows = deduplicatedWorkflows(workflows)
        let finalWorkflows: [DomainWorkflow]
        switch mode {
        case .merge:
            finalWorkflows = mergeWorkflows(existing: loadWorkflows(defaults: defaults), incoming: importedWorkflows)
        case .replace:
            finalWorkflows = importedWorkflows
        }
        saveWorkflows(finalWorkflows, defaults: defaults)
    }

    private static func projectCounts(
        for payload: ImportPayload,
        mode: DataPortabilityImportMode,
        defaults: UserDefaults
    ) -> DataLifecycleSummary {
        let current = lifecycleSummary(defaults: defaults)
        switch payload {
        case .backup(let backup, _):
            if mode == .replace {
                return DataLifecycleSummary(
                    trackedDomains: backup.trackedDomains.count,
                    historySnapshots: backup.historyEntries.count,
                    auditSessions: backup.auditSessions?.count ?? 0,
                    workflows: backup.workflows.count,
                    cachedItems: backup.appSettings.recentSearches.count + backup.appSettings.savedDomains.count + (backup.featureMetadata?.cachedEntitlement == nil ? 0 : 1),
                    monitoringLogs: backup.monitoringLogs.count
                )
            }

            return DataLifecycleSummary(
                trackedDomains: mergeTrackedDomains(existing: loadTrackedDomains(defaults: defaults), incoming: backup.trackedDomains).domains.count,
                historySnapshots: mergeHistoryEntries(existing: loadHistoryEntries(defaults: defaults), incoming: backup.historyEntries).count,
                auditSessions: mergeAuditSessions(existing: loadAuditSessions(defaults: defaults), incoming: backup.auditSessions ?? []).count,
                workflows: mergeWorkflows(existing: loadWorkflows(defaults: defaults), incoming: backup.workflows).count,
                cachedItems: max(current.cachedItems, backup.appSettings.recentSearches.count + backup.appSettings.savedDomains.count),
                monitoringLogs: mergeMonitoringLogs(existing: loadMonitoringLogs(defaults: defaults), incoming: backup.monitoringLogs).count
            )
        case .trackedDomains(let trackedDomains, _):
            let total = mode == .replace
                ? trackedDomains.count
                : mergeTrackedDomains(existing: loadTrackedDomains(defaults: defaults), incoming: trackedDomains).domains.count
            return DataLifecycleSummary(
                trackedDomains: total,
                historySnapshots: current.historySnapshots,
                auditSessions: current.auditSessions,
                workflows: current.workflows,
                cachedItems: current.cachedItems,
                monitoringLogs: current.monitoringLogs
            )
        case .workflows(let workflows, _):
            let total = mode == .replace
                ? workflows.count
                : mergeWorkflows(existing: loadWorkflows(defaults: defaults), incoming: workflows).count
            return DataLifecycleSummary(
                trackedDomains: current.trackedDomains,
                historySnapshots: current.historySnapshots,
                auditSessions: current.auditSessions,
                workflows: total,
                cachedItems: current.cachedItems,
                monitoringLogs: current.monitoringLogs
            )
        }
    }

    private static func mergeTrackedDomains(existing: [TrackedDomain], incoming: [TrackedDomain]) -> MergedTrackedDomains {
        var mergedByDomain = Dictionary(uniqueKeysWithValues: existing.map { (normalizeDomain($0.domain), $0) })
        var idMap: [UUID: UUID] = [:]

        for trackedDomain in incoming {
            let key = normalizeDomain(trackedDomain.domain)
            guard !key.isEmpty else { continue }

            if let existingDomain = mergedByDomain[key] {
                let chosen = trackedDomain.updatedAt >= existingDomain.updatedAt
                    ? mergeTrackedDomain(existing: existingDomain, incoming: trackedDomain)
                    : mergeTrackedDomain(existing: trackedDomain, incoming: existingDomain)
                mergedByDomain[key] = chosen
                idMap[trackedDomain.id] = chosen.id
            } else {
                let normalized = normalizedTrackedDomain(trackedDomain)
                mergedByDomain[key] = normalized
                idMap[trackedDomain.id] = normalized.id
            }
        }

        for trackedDomain in existing {
            idMap[trackedDomain.id] = mergedByDomain[normalizeDomain(trackedDomain.domain)]?.id ?? trackedDomain.id
        }

        return MergedTrackedDomains(
            domains: mergedByDomain.values.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
            },
            idMap: idMap
        )
    }

    private static func mergeTrackedDomain(existing: TrackedDomain, incoming: TrackedDomain) -> TrackedDomain {
        let normalizedDomain = normalizeDomain(existing.domain.isEmpty ? incoming.domain : existing.domain)
        let winner = existing.updatedAt >= incoming.updatedAt ? existing : incoming
        let note = winner.note ?? existing.note ?? incoming.note

        return TrackedDomain(
            id: existing.id,
            domain: normalizedDomain,
            createdAt: min(existing.createdAt, incoming.createdAt),
            updatedAt: max(existing.updatedAt, incoming.updatedAt),
            note: note,
            isPinned: existing.isPinned || incoming.isPinned,
            monitoringEnabled: existing.monitoringEnabled || incoming.monitoringEnabled,
            lastKnownAvailability: winner.lastKnownAvailability ?? existing.lastKnownAvailability ?? incoming.lastKnownAvailability,
            lastSnapshotID: winner.lastSnapshotID ?? existing.lastSnapshotID ?? incoming.lastSnapshotID,
            lastChangeSummary: winner.lastChangeSummary ?? existing.lastChangeSummary ?? incoming.lastChangeSummary,
            lastChangeSeverity: winner.lastChangeSeverity ?? existing.lastChangeSeverity ?? incoming.lastChangeSeverity,
            certificateWarningLevel: higherCertificateWarningLevel(existing.certificateWarningLevel, incoming.certificateWarningLevel),
            certificateDaysRemaining: winner.certificateDaysRemaining ?? existing.certificateDaysRemaining ?? incoming.certificateDaysRemaining,
            lastMonitoredAt: [existing.lastMonitoredAt, incoming.lastMonitoredAt].compactMap { $0 }.max(),
            lastAlertAt: [existing.lastAlertAt, incoming.lastAlertAt].compactMap { $0 }.max(),
            monitoringState: preferredMonitoringState(existing.monitoringState, incoming.monitoringState),
            pendingMonitoringAlerts: deduplicatedPendingAlerts(existing.pendingMonitoringAlerts + incoming.pendingMonitoringAlerts)
        )
    }

    private static func mergeHistoryEntries(existing: [HistoryEntry], incoming: [HistoryEntry]) -> [HistoryEntry] {
        var mergedByKey: [String: HistoryEntry] = [:]

        for entry in existing + incoming {
            let key = historyKey(for: entry)
            if let existingEntry = mergedByKey[key] {
                mergedByKey[key] = chooseBetterHistoryEntry(existingEntry, entry)
            } else {
                mergedByKey[key] = entry
            }
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
        }
    }

    private static func mergeAuditSessions(existing: [AuditSession], incoming: [AuditSession]) -> [AuditSession] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for session in incoming {
            if let existingSession = merged[session.id] {
                let winner = existingSession.findings.count >= session.findings.count ? existingSession : session
                let candidateNotes = [existingSession.notes, session.notes]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let notes = candidateNotes.reduce(into: [String]()) { result, note in
                    if !result.contains(note) {
                        result.append(note)
                    }
                }.joined(separator: "\n\n")
                merged[session.id] = AuditSession(
                    id: existingSession.id,
                    domain: existingSession.domain,
                    createdAt: min(existingSession.createdAt, session.createdAt),
                    reviewer: winner.reviewer,
                    status: winner.status,
                    evidence: winner.evidence,
                    findings: winner.findings,
                    notes: notes,
                    checklist: winner.checklist
                )
            } else {
                merged[session.id] = session
            }
        }

        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    private static func mergeWorkflows(existing: [DomainWorkflow], incoming: [DomainWorkflow]) -> [DomainWorkflow] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, normalizedWorkflow($0)) })

        for workflow in incoming {
            let normalized = normalizedWorkflow(workflow)
            if let existingWorkflow = merged[workflow.id] {
                let winner = existingWorkflow.updatedAt >= normalized.updatedAt ? existingWorkflow : normalized
                merged[workflow.id] = DomainWorkflow(
                    id: existingWorkflow.id,
                    name: winner.name,
                    domains: deduplicated(existingWorkflow.domains + normalized.domains),
                    createdAt: min(existingWorkflow.createdAt, normalized.createdAt),
                    updatedAt: max(existingWorkflow.updatedAt, normalized.updatedAt),
                    notes: winner.notes ?? existingWorkflow.notes ?? normalized.notes
                )
            } else {
                merged[workflow.id] = normalized
            }
        }

        return merged.values.sorted(by: workflowSort)
    }

    private static func mergeMonitoringLogs(existing: [MonitoringLog], incoming: [MonitoringLog]) -> [MonitoringLog] {
        var merged: [UUID: MonitoringLog] = [:]
        for log in existing + incoming {
            if let current = merged[log.id] {
                merged[log.id] = log.timestamp >= current.timestamp ? log : current
            } else {
                merged[log.id] = log
            }
        }
        return merged.values.sorted { $0.timestamp > $1.timestamp }.prefix(MonitoringStorage.maxLogs).map { $0 }
    }

    private static func mergeAppSettings(existing: AppSettingsSnapshot, incoming: AppSettingsSnapshot) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            recentSearches: deduplicated(incoming.recentSearches + existing.recentSearches).prefix(20).map { $0 },
            savedDomains: deduplicated(incoming.savedDomains + existing.savedDomains),
            resolverURLString: incoming.resolverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.resolverURLString : incoming.resolverURLString,
            appDensityRawValue: incoming.appDensityRawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.appDensityRawValue : incoming.appDensityRawValue
        )
    }

    private static func mergeFeatureMetadata(existing: FeatureMetadataSnapshot, incoming: FeatureMetadataSnapshot?) -> FeatureMetadataSnapshot {
        guard let incoming else { return existing }

        return FeatureMetadataSnapshot(
            cachedEntitlement: incoming.cachedEntitlement ?? existing.cachedEntitlement
        )
    }

    private static func remapMonitoringSettings(
        _ settings: MonitoringSettings,
        using idMap: [UUID: UUID]
    ) -> MonitoringSettings {
        var remapped = settings
        remapped.selectedDomainIDs = deduplicatedUUIDs(settings.selectedDomainIDs.compactMap { idMap[$0] ?? $0 })
        return remapped
    }

    private static func remapHistoryEntry(_ entry: HistoryEntry, using idMap: [UUID: UUID]) -> HistoryEntry {
        var remapped = entry
        if let trackedDomainID = entry.trackedDomainID {
            remapped.trackedDomainID = idMap[trackedDomainID] ?? trackedDomainID
        }
        return remapped
    }

    private static func chooseBetterHistoryEntry(_ lhs: HistoryEntry, _ rhs: HistoryEntry) -> HistoryEntry {
        if historyQualityScore(lhs) == historyQualityScore(rhs) {
            return lhs.timestamp >= rhs.timestamp ? lhs : rhs
        }
        return historyQualityScore(lhs) >= historyQualityScore(rhs) ? lhs : rhs
    }

    private static func historyQualityScore(_ entry: HistoryEntry) -> Int {
        var score = 0
        score += entry.dnsSections.count
        score += entry.httpHeaders.count
        score += entry.reachabilityResults.count
        score += entry.redirectChain.count
        score += entry.subdomains.count
        score += entry.portScanResults.count
        score += entry.validationIssues.isEmpty ? 2 : 0
        score += entry.sslInfo == nil ? 0 : 4
        score += entry.ownership == nil ? 0 : 4
        score += entry.emailSecurity == nil ? 0 : 3
        score += entry.ipGeolocation == nil ? 0 : 2
        return score
    }

    private static func historyKey(for entry: HistoryEntry) -> String {
        if entry.id != UUID() {
            return "id:\(entry.id.uuidString)"
        }
        return "domain:\(normalizeDomain(entry.domain))|timestamp:\(entry.timestamp.timeIntervalSince1970)"
    }

    private nonisolated static func normalizeDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }

    private static func normalizedTrackedDomain(_ trackedDomain: TrackedDomain) -> TrackedDomain {
        TrackedDomain(
            id: trackedDomain.id,
            domain: normalizeDomain(trackedDomain.domain),
            createdAt: trackedDomain.createdAt,
            updatedAt: trackedDomain.updatedAt,
            note: trackedDomain.note,
            isPinned: trackedDomain.isPinned,
            monitoringEnabled: trackedDomain.monitoringEnabled,
            lastKnownAvailability: trackedDomain.lastKnownAvailability,
            lastSnapshotID: trackedDomain.lastSnapshotID,
            lastChangeSummary: trackedDomain.lastChangeSummary,
            lastChangeSeverity: trackedDomain.lastChangeSeverity,
            certificateWarningLevel: trackedDomain.certificateWarningLevel,
            certificateDaysRemaining: trackedDomain.certificateDaysRemaining,
            lastMonitoredAt: trackedDomain.lastMonitoredAt,
            lastAlertAt: trackedDomain.lastAlertAt,
            monitoringState: trackedDomain.monitoringState,
            pendingMonitoringAlerts: trackedDomain.pendingMonitoringAlerts
        )
    }

    private static func preferredMonitoringState(_ lhs: MonitoringState, _ rhs: MonitoringState) -> MonitoringState {
        let lhsDate = [lhs.lastCheck, lhs.lastAlertDate, lhs.lastChangeDate].compactMap { $0 }.max() ?? .distantPast
        let rhsDate = [rhs.lastCheck, rhs.lastAlertDate, rhs.lastChangeDate].compactMap { $0 }.max() ?? .distantPast
        return lhsDate >= rhsDate ? lhs : rhs
    }

    private static func deduplicatedPendingAlerts(_ alerts: [MonitoringPendingAlert]) -> [MonitoringPendingAlert] {
        var uniqueByHash: [String: MonitoringPendingAlert] = [:]
        for alert in alerts {
            if let existing = uniqueByHash[alert.changeHash] {
                uniqueByHash[alert.changeHash] = existing.detectedAt >= alert.detectedAt ? existing : alert
            } else {
                uniqueByHash[alert.changeHash] = alert
            }
        }
        return uniqueByHash.values.sorted { $0.detectedAt < $1.detectedAt }
    }

    private static func normalizedWorkflow(_ workflow: DomainWorkflow) -> DomainWorkflow {
        DomainWorkflow(
            id: workflow.id,
            name: workflow.name.trimmingCharacters(in: .whitespacesAndNewlines),
            domains: deduplicated(workflow.domains.map(Self.normalizeDomain).filter { !$0.isEmpty }),
            createdAt: workflow.createdAt,
            updatedAt: workflow.updatedAt,
            notes: workflow.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static func deduplicatedTrackedDomains(_ trackedDomains: [TrackedDomain]) -> [TrackedDomain] {
        mergeTrackedDomains(existing: [], incoming: trackedDomains).domains
    }

    private static func deduplicatedHistoryEntries(_ historyEntries: [HistoryEntry]) -> [HistoryEntry] {
        mergeHistoryEntries(existing: [], incoming: historyEntries)
    }

    private static func deduplicatedWorkflows(_ workflows: [DomainWorkflow]) -> [DomainWorkflow] {
        mergeWorkflows(existing: [], incoming: workflows)
    }

    private nonisolated static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated static func deduplicatedUUIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated static func workflowSort(lhs: DomainWorkflow, rhs: DomainWorkflow) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private nonisolated static func higherCertificateWarningLevel(
        _ lhs: CertificateWarningLevel,
        _ rhs: CertificateWarningLevel
    ) -> CertificateWarningLevel {
        let rank: [CertificateWarningLevel: Int] = [
            .none: 0,
            .warning: 1,
            .critical: 2
        ]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private struct MergedTrackedDomains {
    let domains: [TrackedDomain]
    let idMap: [UUID: UUID]
}

private enum ImportPayload {
    case backup(DomainDigBackup, DataValidationReport)
    case trackedDomains([TrackedDomain], DataValidationReport)
    case workflows([DomainWorkflow], DataValidationReport)

    var kind: DataPortabilityImportKind {
        switch self {
        case .backup:
            return .backup
        case .trackedDomains:
            return .trackedDomains
        case .workflows:
            return .workflows
        }
    }

    var validationReport: DataValidationReport {
        switch self {
        case .backup(_, let report), .trackedDomains(_, let report), .workflows(_, let report):
            return report
        }
    }

    func summaryLines(mode: DataPortabilityImportMode) -> [String] {
        switch self {
        case .backup(let backup, _):
            return [
                "Full backup import",
                "\(backup.trackedDomains.count) tracked domains",
                "\(backup.historyEntries.count) history snapshots",
                "\(backup.auditSessions?.count ?? 0) audit sessions",
                "\(backup.workflows.count) workflows",
                "\(backup.monitoringLogs.count) monitoring logs",
                mode == .replace ? "Replace mode will overwrite local backupable data." : "Merge mode will keep local data and consolidate duplicates."
            ]
        case .trackedDomains(let trackedDomains, _):
            return [
                "Tracked domains import",
                "\(trackedDomains.count) tracked domains",
                mode == .replace ? "Replace mode will overwrite the watchlist." : "Merge mode will consolidate duplicates by normalized domain."
            ]
        case .workflows(let workflows, _):
            return [
                "Workflow import",
                "\(workflows.count) workflows",
                mode == .replace ? "Replace mode will overwrite saved workflows." : "Merge mode will merge matching workflow IDs and deduplicate domains."
            ]
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

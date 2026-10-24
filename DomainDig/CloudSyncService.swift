import CloudKit
import Foundation
import Network
import Observation

extension Notification.Name {
    static let cloudSyncDidApplyChanges = Notification.Name("CloudSyncService.didApplyChanges")
}

enum CloudSyncStatus: String, Codable {
    case disabled
    case synced
    case syncing
    case offline
    case iCloudUnavailable
    case conflictResolved
    case error

    var title: String {
        switch self {
        case .disabled:
            return "Off"
        case .synced:
            return "Synced"
        case .syncing:
            return "Syncing"
        case .offline:
            return "Offline"
        case .iCloudUnavailable:
            return "iCloud unavailable"
        case .conflictResolved:
            return "Conflict resolved"
        case .error:
            return "Error"
        }
    }
}

enum CloudSyncTrigger: String {
    case launch
    case automatic
    case manual
    case imported = "import"
}

enum ShareableEntity: Identifiable, Hashable {
    case trackedDomain(String)
    case workflow(UUID)

    var id: String {
        switch self {
        case .trackedDomain(let domain):
            return "tracked:\(domain)"
        case .workflow(let identifier):
            return "workflow:\(identifier.uuidString)"
        }
    }
}

private enum CloudZone {
    static let name = "DomainDigZone"
}

private enum CloudRecordType {
    static let trackedDomain = "TrackedDomain"
    static let workflow = "DomainWorkflow"
    static let appSettings = "AppSettingsSnapshot"
    static let monitoringSettings = "MonitoringSettings"
    static let domainNote = "DomainNote"
    static let historyMetadata = "HistoryMetadata"
    static let tombstone = "SyncTombstone"
}

private enum CloudRecordKey {
    static let payload = "payload"
    static let updatedAt = "updatedAt"
    static let domain = "domain"
    static let identifier = "identifier"
    static let entityType = "entityType"
    static let deletedAt = "deletedAt"
}

private enum SyncEntityType: String, Codable {
    case trackedDomain
    case workflow
}

private struct SyncedAppSettings: Codable {
    var snapshot: AppSettingsSnapshot
    var updatedAt: Date
}

private struct SyncedMonitoringSettings: Codable {
    var settings: MonitoringSettings
    var updatedAt: Date
}

private struct SyncedDomainNote: Codable, Equatable {
    var domain: String
    var text: String
    var updatedAt: Date
}

private struct SyncedHistoryMetadata: Codable, Equatable {
    var domain: String
    var lastKnownAvailabilityRawValue: String?
    var lastChangeMessage: String?
    var lastChangeSeverityRawValue: Int?
    var certificateWarningLevelRawValue: String
    var certificateDaysRemaining: Int?
    var lastObservedAt: Date?
    var updatedAt: Date
}

private struct SyncTombstone: Codable, Equatable {
    var entityType: SyncEntityType
    var identifier: String
    var deletedAt: Date
}

private struct SyncPayload {
    var trackedDomains: [TrackedDomain]
    var workflows: [DomainWorkflow]
    var appSettings: SyncedAppSettings
    var monitoringSettings: SyncedMonitoringSettings
    var notesByDomain: [String: SyncedDomainNote]
    var historyMetadataByDomain: [String: SyncedHistoryMetadata]
    var tombstones: [SyncTombstone]
}

private enum SyncDatabaseScope {
    case privateDatabase
    case sharedDatabase
}

private struct MergedSyncPayload {
    var payload: SyncPayload
    var hadConflict: Bool
    var changedLocalData: Bool
}

@MainActor
@Observable
final class CloudSyncService {
    static let shared = CloudSyncService()

    var isEnabled: Bool
    var status: CloudSyncStatus
    var lastSyncDate: Date?
    var lastErrorMessage: String?
    var detailMessage: String

    private var container: CKContainer?
    private var privateDatabase: CKDatabase?
    private var sharedDatabase: CKDatabase?
    private var didEnsureZone = false
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "DomainDig.CloudSync.PathMonitor")

    private var isNetworkAvailable = true
    private var scheduledSyncTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private enum StorageKey {
        static let isEnabled = "cloudSync.enabled"
        static let status = "cloudSync.status"
        static let lastSyncDate = "cloudSync.lastSyncDate"
        static let lastErrorMessage = "cloudSync.lastErrorMessage"
        static let detailMessage = "cloudSync.detailMessage"
        static let appSettingsUpdatedAt = "cloudSync.appSettingsUpdatedAt"
        static let monitoringSettingsUpdatedAt = "cloudSync.monitoringSettingsUpdatedAt"
        static let noteUpdatedAtByDomain = "cloudSync.noteUpdatedAtByDomain"
        static let tombstones = "cloudSync.tombstones"
        static let monitoringLocalActivationConfirmed = "cloudSync.monitoringLocalActivationConfirmed"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.container = nil
        self.privateDatabase = nil
        self.sharedDatabase = nil
        let syncEnabled = defaults.bool(forKey: StorageKey.isEnabled)
        self.isEnabled = syncEnabled
        self.status = CloudSyncStatus(rawValue: defaults.string(forKey: StorageKey.status) ?? "") ?? (syncEnabled ? .synced : .disabled)
        self.lastSyncDate = defaults.object(forKey: StorageKey.lastSyncDate) as? Date
        self.lastErrorMessage = defaults.string(forKey: StorageKey.lastErrorMessage)
        self.detailMessage = defaults.string(forKey: StorageKey.detailMessage) ?? "DomainDig stores synced data in your private iCloud account."

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isNetworkAvailable = path.status == .satisfied
                if !self.isNetworkAvailable, self.isEnabled, self.status == .syncing {
                    self.setStatus(.offline, detail: "Waiting for a network connection.", error: nil)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func setSyncEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: StorageKey.isEnabled)

        guard enabled else {
            scheduledSyncTask?.cancel()
            syncTask?.cancel()
            setStatus(.disabled, detail: "Sync is optional. Local data stays on this device.", error: nil)
            return
        }

        Task {
            await refreshAvailability()
            await syncNow(trigger: .manual)
        }
    }

    func refreshAvailability() async {
        guard isEnabled else {
            setStatus(.disabled, detail: "Sync is optional. Local data stays on this device.", error: nil)
            return
        }

        guard isNetworkAvailable else {
            setStatus(.offline, detail: "Waiting for a network connection.", error: nil)
            return
        }

        switch await accountStatus() {
        case .available:
            if status == .iCloudUnavailable || status == .offline || status == .disabled {
                setStatus(.synced, detail: syncSummaryDetail(), error: nil)
            }
        case .noAccount:
            setStatus(.iCloudUnavailable, detail: "Sign in to iCloud to sync DomainDig.", error: nil)
        case .restricted:
            setStatus(.iCloudUnavailable, detail: "iCloud access is restricted on this device.", error: nil)
        case .temporarilyUnavailable:
            setStatus(.iCloudUnavailable, detail: "iCloud is temporarily unavailable.", error: nil)
        case .unknown:
            setStatus(.iCloudUnavailable, detail: "DomainDig could not confirm iCloud availability.", error: nil)
        case .missingEntitlement:
            setStatus(.iCloudUnavailable, detail: missingEntitlementMessage, error: nil)
        }
    }

    func scheduleSyncIfNeeded(trigger: CloudSyncTrigger = .automatic) {
        guard isEnabled else { return }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow(trigger: trigger)
        }
    }

    func markAppSettingsChanged() {
        defaults.set(Date(), forKey: StorageKey.appSettingsUpdatedAt)
        scheduleSyncIfNeeded()
    }

    func markMonitoringSettingsChanged(localActivationConfirmed: Bool = false) {
        defaults.set(Date(), forKey: StorageKey.monitoringSettingsUpdatedAt)
        if localActivationConfirmed {
            defaults.set(true, forKey: StorageKey.monitoringLocalActivationConfirmed)
        }
        scheduleSyncIfNeeded()
    }

    func markNoteChanged(for domain: String, updatedAt: Date = Date()) {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return }

        var noteDates = loadNoteUpdatedAtByDomain()
        noteDates[normalized] = updatedAt
        saveNoteUpdatedAtByDomain(noteDates)
        scheduleSyncIfNeeded()
    }

    func recordTrackedDomainDeletion(_ trackedDomain: TrackedDomain, deletedAt: Date = Date()) {
        let normalized = Self.normalizeDomain(trackedDomain.domain)
        guard !normalized.isEmpty else { return }
        saveTombstone(.init(entityType: .trackedDomain, identifier: normalized, deletedAt: deletedAt))

        var noteDates = loadNoteUpdatedAtByDomain()
        noteDates.removeValue(forKey: normalized)
        saveNoteUpdatedAtByDomain(noteDates)

        scheduleSyncIfNeeded()
    }

    func recordWorkflowDeletion(_ workflow: DomainWorkflow, deletedAt: Date = Date()) {
        saveTombstone(.init(entityType: .workflow, identifier: workflow.id.uuidString, deletedAt: deletedAt))
        scheduleSyncIfNeeded()
    }

    func recordTrackedDomainReset(_ trackedDomains: [TrackedDomain], deletedAt: Date = Date()) {
        for trackedDomain in trackedDomains {
            recordTrackedDomainDeletion(trackedDomain, deletedAt: deletedAt)
        }
    }

    func recordWorkflowReset(_ workflows: [DomainWorkflow], deletedAt: Date = Date()) {
        for workflow in workflows {
            recordWorkflowDeletion(workflow, deletedAt: deletedAt)
        }
    }

    func resetLocalStateAfterWipe() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        syncTask?.cancel()
        syncTask = nil

        let syncEnabled = defaults.bool(forKey: StorageKey.isEnabled)
        isEnabled = syncEnabled
        status = CloudSyncStatus(rawValue: defaults.string(forKey: StorageKey.status) ?? "") ?? (syncEnabled ? .synced : .disabled)
        lastSyncDate = defaults.object(forKey: StorageKey.lastSyncDate) as? Date
        lastErrorMessage = defaults.string(forKey: StorageKey.lastErrorMessage)
        detailMessage = defaults.string(forKey: StorageKey.detailMessage) ?? "DomainDig stores synced data in your private iCloud account."
    }

    func acceptShare(metadata: CKShare.Metadata) async throws {
        let container = cloudKitContainer()

        if metadata.participantStatus == .pending {
            _ = try await container.accept(metadata)
        }

        await syncNow(trigger: .manual)
    }

    func existingShare(for entity: ShareableEntity) async throws -> CKShare? {
        let shareRecordName = try await shareRecordName(for: entity)
        guard let shareRecordName else { return nil }
        if let privateShare = try await fetchShare(recordName: shareRecordName, in: .privateDatabase) {
            return privateShare
        }
        return try await fetchShare(recordName: shareRecordName, in: .sharedDatabase)
    }

    func createShare(for entity: ShareableEntity) async throws -> CKShare {
        guard let database = cloudKitDatabase(in: .privateDatabase) else {
            throw CloudSyncRuntimeError.missingEntitlement
        }

        try await ensureCustomZone(in: database)

        switch entity {
        case .trackedDomain(let domain):
            let normalized = Self.normalizeDomain(domain)
            let trackedDomain = DomainDataPortabilityService.loadTrackedDomains()
                .first(where: { Self.normalizeDomain($0.domain) == normalized })
            guard let trackedDomain else {
                throw CloudSyncRuntimeError.missingLocalItem
            }

            let rootRecord = makeTrackedDomainRecord(trackedDomain)
            let share = CKShare(rootRecord: rootRecord)
            share[CKShare.SystemFieldKey.title] = normalized as CKRecordValue
            share.publicPermission = .none
            _ = try await database.modifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            await syncNow(trigger: .manual)
            return share

        case .workflow(let identifier):
            let workflow = DomainDataPortabilityService.loadWorkflows()
                .first(where: { $0.id == identifier })
            guard let workflow else {
                throw CloudSyncRuntimeError.missingLocalItem
            }

            let rootRecord = makeWorkflowRecord(workflow)
            let share = CKShare(rootRecord: rootRecord)
            share[CKShare.SystemFieldKey.title] = workflow.name as CKRecordValue
            share.publicPermission = .none
            _ = try await database.modifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            await syncNow(trigger: .manual)
            return share
        }
    }

    func syncNow(trigger: CloudSyncTrigger = .manual) async {
        guard isEnabled else {
            setStatus(.disabled, detail: "Sync is optional. Local data stays on this device.", error: nil)
            return
        }

        if syncTask != nil {
            return
        }

        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.performSync(trigger: trigger)
            await MainActor.run {
                self.syncTask = nil
            }
        }

        await syncTask?.value
    }

    private func performSync(trigger: CloudSyncTrigger) async {
        guard cloudKitDatabase(in: .privateDatabase) != nil else {
            setStatus(.iCloudUnavailable, detail: missingEntitlementMessage, error: nil)
            return
        }

        guard isNetworkAvailable else {
            setStatus(.offline, detail: "Waiting for a network connection.", error: nil)
            return
        }

        switch await accountStatus() {
        case .available:
            break
        case .noAccount:
            setStatus(.iCloudUnavailable, detail: "Sign in to iCloud to sync DomainDig.", error: nil)
            return
        case .restricted:
            setStatus(.iCloudUnavailable, detail: "iCloud access is restricted on this device.", error: nil)
            return
        case .temporarilyUnavailable:
            setStatus(.iCloudUnavailable, detail: "iCloud is temporarily unavailable.", error: nil)
            return
        case .unknown:
            setStatus(.iCloudUnavailable, detail: "DomainDig could not confirm iCloud availability.", error: nil)
            return
        case .missingEntitlement:
            setStatus(.iCloudUnavailable, detail: missingEntitlementMessage, error: nil)
            return
        }

        setStatus(.syncing, detail: trigger == .manual ? "Syncing now…" : "Syncing changes…", error: nil)

        do {
            let local = loadLocalPayload()
            let remote = try await fetchRemotePayload()
            let merged = merge(local: local, remote: remote)
            applyMergedPayload(merged.payload)
            try await pushMergedPayload(merged.payload)

            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: StorageKey.lastSyncDate)

            if merged.changedLocalData {
                NotificationCenter.default.post(name: .cloudSyncDidApplyChanges, object: nil)
            }

            let detail = syncSummaryDetail()
            if merged.hadConflict {
                setStatus(.conflictResolved, detail: detail, error: nil)
            } else {
                setStatus(.synced, detail: detail, error: nil)
            }
        } catch {
            let mapped = mapSyncError(error)
            setStatus(mapped.status, detail: mapped.message, error: mapped.errorDetail)
        }
    }

    private func loadLocalPayload() -> SyncPayload {
        let trackedDomains = DomainDataPortabilityService.loadTrackedDomains()
        let workflows = DomainDataPortabilityService.loadWorkflows()
        let appSettings = SyncedAppSettings(
            snapshot: DomainDataPortabilityService.loadAppSettings(),
            updatedAt: defaults.object(forKey: StorageKey.appSettingsUpdatedAt) as? Date ?? .distantPast
        )
        let monitoringSettings = SyncedMonitoringSettings(
            settings: DomainDataPortabilityService.loadMonitoringSettings(),
            updatedAt: defaults.object(forKey: StorageKey.monitoringSettingsUpdatedAt) as? Date ?? .distantPast
        )

        let noteDates = loadNoteUpdatedAtByDomain()
        let notesByDomain = Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { trackedDomain -> (String, SyncedDomainNote)? in
            guard trackedDomain.collaboration?.scope != .sharedDatabase else { return nil }
            let normalized = Self.normalizeDomain(trackedDomain.domain)
            guard !normalized.isEmpty else { return nil }
            let noteText = trackedDomain.note ?? ""
            let updatedAt = noteDates[normalized] ?? trackedDomain.updatedAt
            return (
                normalized,
                SyncedDomainNote(
                    domain: normalized,
                    text: noteText,
                    updatedAt: updatedAt
                )
            )
        })

        let historyMetadataByDomain = Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { trackedDomain -> (String, SyncedHistoryMetadata)? in
            guard trackedDomain.collaboration?.scope != .sharedDatabase else { return nil }
            let normalized = Self.normalizeDomain(trackedDomain.domain)
            guard !normalized.isEmpty else { return nil }
            return (
                normalized,
                SyncedHistoryMetadata(
                    domain: normalized,
                    lastKnownAvailabilityRawValue: trackedDomain.lastKnownAvailability?.rawValue,
                    lastChangeMessage: trackedDomain.lastChangeSummary?.message,
                    lastChangeSeverityRawValue: trackedDomain.lastChangeSeverity?.rawValue ?? trackedDomain.lastChangeSummary?.severity.rawValue,
                    certificateWarningLevelRawValue: trackedDomain.certificateWarningLevel.rawValue,
                    certificateDaysRemaining: trackedDomain.certificateDaysRemaining,
                    lastObservedAt: trackedDomain.updatedAt,
                    updatedAt: trackedDomain.updatedAt
                )
            )
        })

        return SyncPayload(
            trackedDomains: trackedDomains,
            workflows: workflows,
            appSettings: appSettings,
            monitoringSettings: monitoringSettings,
            notesByDomain: notesByDomain,
            historyMetadataByDomain: historyMetadataByDomain,
            tombstones: loadTombstones()
        )
    }

    private func fetchRemotePayload() async throws -> SyncPayload {
        let privateRecords = try await fetchZoneRecords(in: .privateDatabase)
        let sharedRecords = try await fetchZoneRecords(in: .sharedDatabase)

        let privateTrackedDomains = try await trackedDomains(from: privateRecords, in: .privateDatabase)
        let sharedTrackedDomains = try await trackedDomains(from: sharedRecords, in: .sharedDatabase)
        let privateWorkflows = try await workflows(from: privateRecords, in: .privateDatabase)
        let sharedWorkflows = try await workflows(from: sharedRecords, in: .sharedDatabase)

        let appSettingsRecords: [SyncedAppSettings] = decodeRecords(privateRecords, ofType: CloudRecordType.appSettings)
        let monitoringSettingsRecords: [SyncedMonitoringSettings] = decodeRecords(privateRecords, ofType: CloudRecordType.monitoringSettings)
        let domainNotes: [SyncedDomainNote] = decodeRecords(privateRecords, ofType: CloudRecordType.domainNote)
        let historyMetadata: [SyncedHistoryMetadata] = decodeRecords(privateRecords, ofType: CloudRecordType.historyMetadata)
        let tombstones: [SyncTombstone] = decodeRecords(privateRecords, ofType: CloudRecordType.tombstone)

        let appSettings = appSettingsRecords.max(by: { $0.updatedAt < $1.updatedAt })
            ?? SyncedAppSettings(snapshot: DomainDataPortabilityService.loadAppSettings(), updatedAt: .distantPast)
        let monitoringSettings = monitoringSettingsRecords.max(by: { $0.updatedAt < $1.updatedAt })
            ?? SyncedMonitoringSettings(settings: DomainDataPortabilityService.loadMonitoringSettings(), updatedAt: .distantPast)

        return SyncPayload(
            trackedDomains: privateTrackedDomains + sharedTrackedDomains,
            workflows: privateWorkflows + sharedWorkflows,
            appSettings: appSettings,
            monitoringSettings: monitoringSettings,
            notesByDomain: Dictionary(uniqueKeysWithValues: domainNotes.map { (Self.normalizeDomain($0.domain), $0) }),
            historyMetadataByDomain: Dictionary(uniqueKeysWithValues: historyMetadata.map { (Self.normalizeDomain($0.domain), $0) }),
            tombstones: tombstones
        )
    }

    private func pushMergedPayload(_ payload: SyncPayload) async throws {
        guard let privateDatabase = cloudKitDatabase(in: .privateDatabase) else {
            throw CloudSyncRuntimeError.missingEntitlement
        }

        try await ensureCustomZone(in: privateDatabase)

        var privateRecordsToSave: [CKRecord] = []
        var sharedRecordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for trackedDomain in payload.trackedDomains {
            switch trackedDomain.collaboration?.scope ?? .privateDatabase {
            case .privateDatabase:
                privateRecordsToSave.append(makeTrackedDomainRecord(trackedDomain))
            case .sharedDatabase:
                if trackedDomain.collaboration?.canEdit == true {
                    sharedRecordsToSave.append(makeTrackedDomainRecord(trackedDomain))
                }
            }
        }

        for workflow in payload.workflows {
            switch workflow.collaboration?.scope ?? .privateDatabase {
            case .privateDatabase:
                privateRecordsToSave.append(makeWorkflowRecord(workflow))
            case .sharedDatabase:
                if workflow.collaboration?.canEdit == true {
                    sharedRecordsToSave.append(makeWorkflowRecord(workflow))
                }
            }
        }

        privateRecordsToSave.append(makeAppSettingsRecord(payload.appSettings))
        privateRecordsToSave.append(makeMonitoringSettingsRecord(payload.monitoringSettings))
        privateRecordsToSave.append(contentsOf: payload.notesByDomain.values.map(makeDomainNoteRecord))
        privateRecordsToSave.append(contentsOf: payload.historyMetadataByDomain.values.map(makeHistoryMetadataRecord))
        privateRecordsToSave.append(contentsOf: payload.tombstones.map(makeTombstoneRecord))

        for tombstone in payload.tombstones {
            switch tombstone.entityType {
            case .trackedDomain:
                let identifier = tombstone.identifier
                recordIDsToDelete.append(CKRecord.ID(recordName: trackedDomainRecordName(for: identifier), zoneID: customZoneID))
                recordIDsToDelete.append(CKRecord.ID(recordName: domainNoteRecordName(for: identifier), zoneID: customZoneID))
                recordIDsToDelete.append(CKRecord.ID(recordName: historyMetadataRecordName(for: identifier), zoneID: customZoneID))
            case .workflow:
                recordIDsToDelete.append(CKRecord.ID(recordName: workflowRecordName(for: tombstone.identifier), zoneID: customZoneID))
            }
        }

        _ = try await privateDatabase.modifyRecords(
            saving: privateRecordsToSave,
            deleting: Array(Set(recordIDsToDelete)),
            savePolicy: .changedKeys,
            atomically: false
        )

        if !sharedRecordsToSave.isEmpty, let sharedDatabase = cloudKitDatabase(in: .sharedDatabase) {
            _ = try await sharedDatabase.modifyRecords(
                saving: sharedRecordsToSave,
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
        }
    }

    private func applyMergedPayload(_ payload: SyncPayload) {
        DomainDataPortabilityService.saveTrackedDomains(payload.trackedDomains)
        DomainDataPortabilityService.saveWorkflows(payload.workflows)
        DomainDataPortabilityService.saveAppSettings(payload.appSettings.snapshot)
        DomainDataPortabilityService.saveMonitoringSettings(payload.monitoringSettings.settings)

        defaults.set(payload.appSettings.updatedAt, forKey: StorageKey.appSettingsUpdatedAt)
        defaults.set(payload.monitoringSettings.updatedAt, forKey: StorageKey.monitoringSettingsUpdatedAt)
        saveNoteUpdatedAtByDomain(Dictionary(uniqueKeysWithValues: payload.notesByDomain.map { ($0.key, $0.value.updatedAt) }))
        saveTombstones(payload.tombstones)
    }

    private func merge(local: SyncPayload, remote: SyncPayload) -> MergedSyncPayload {
        var hadConflict = false

        let tombstones = latestTombstones(local.tombstones + remote.tombstones)

        let trackedDomainsResult = mergeTrackedDomains(local.trackedDomains, remote.trackedDomains)
        hadConflict = hadConflict || trackedDomainsResult.hadConflict
        var trackedDomains = applyTrackedDomainTombstones(trackedDomainsResult.domains, tombstones: tombstones)

        let workflowsResult = mergeWorkflows(local.workflows, remote.workflows)
        hadConflict = hadConflict || workflowsResult.hadConflict
        let workflows = applyWorkflowTombstones(workflowsResult.workflows, tombstones: tombstones)

        let notesResult = mergeNotes(local.notesByDomain, remote.notesByDomain)
        hadConflict = hadConflict || notesResult.hadConflict
        trackedDomains = applyNotes(notesResult.notesByDomain, to: trackedDomains, tombstones: tombstones)

        let historyResult = mergeHistoryMetadata(local.historyMetadataByDomain, remote.historyMetadataByDomain)
        hadConflict = hadConflict || historyResult.hadConflict
        trackedDomains = applyHistoryMetadata(historyResult.historyMetadataByDomain, to: trackedDomains, tombstones: tombstones)

        let appSettingsResult = mergeAppSettings(local.appSettings, remote.appSettings)
        hadConflict = hadConflict || appSettingsResult.hadConflict

        let monitoringResult = mergeMonitoringSettings(local.monitoringSettings, remote.monitoringSettings)
        hadConflict = hadConflict || monitoringResult.hadConflict

        let mergedPayload = SyncPayload(
            trackedDomains: trackedDomains,
            workflows: workflows,
            appSettings: appSettingsResult.settings,
            monitoringSettings: monitoringResult.settings,
            notesByDomain: Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { trackedDomain -> (String, SyncedDomainNote)? in
                guard trackedDomain.collaboration?.scope != .sharedDatabase else { return nil }
                let normalized = Self.normalizeDomain(trackedDomain.domain)
                guard let note = notesResult.notesByDomain[normalized] else { return nil }
                return (normalized, note)
            }),
            historyMetadataByDomain: Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { trackedDomain -> (String, SyncedHistoryMetadata)? in
                guard trackedDomain.collaboration?.scope != .sharedDatabase else { return nil }
                let normalized = Self.normalizeDomain(trackedDomain.domain)
                guard let metadata = historyResult.historyMetadataByDomain[normalized] else { return nil }
                return (normalized, metadata)
            }),
            tombstones: tombstones
        )

        let changedLocalData =
            mergedPayload.trackedDomains != local.trackedDomains
            || mergedPayload.workflows != local.workflows
            || !sameAppSettings(mergedPayload.appSettings.snapshot, local.appSettings.snapshot)
            || mergedPayload.monitoringSettings.settings != local.monitoringSettings.settings

        return MergedSyncPayload(
            payload: mergedPayload,
            hadConflict: hadConflict,
            changedLocalData: changedLocalData
        )
    }

    private func mergeTrackedDomains(_ lhs: [TrackedDomain], _ rhs: [TrackedDomain]) -> (domains: [TrackedDomain], hadConflict: Bool) {
        var mergedByDomain = Dictionary(uniqueKeysWithValues: lhs.map { (Self.normalizeDomain($0.domain), Self.payloadTrackedDomain($0)) })
        var hadConflict = false

        for trackedDomain in rhs.map(Self.payloadTrackedDomain) {
            let key = Self.normalizeDomain(trackedDomain.domain)
            guard !key.isEmpty else { continue }

            if let existing = mergedByDomain[key] {
                if existing != trackedDomain {
                    hadConflict = true
                }
                mergedByDomain[key] = mergedTrackedDomain(existing, trackedDomain)
            } else {
                mergedByDomain[key] = trackedDomain
            }
        }

        let domains = mergedByDomain.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }

        return (domains, hadConflict)
    }

    private func mergeWorkflows(_ lhs: [DomainWorkflow], _ rhs: [DomainWorkflow]) -> (workflows: [DomainWorkflow], hadConflict: Bool) {
        var merged = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, normalizedWorkflow($0)) })
        var hadConflict = false

        for workflow in rhs.map(normalizedWorkflow) {
            if let existing = merged[workflow.id] {
                if existing != workflow {
                    hadConflict = true
                }
                let winner = preferredWorkflow(existing, workflow)
                merged[workflow.id] = DomainWorkflow(
                    id: existing.id,
                    name: winner.name,
                    domains: deduplicated(existing.domains + workflow.domains),
                    createdAt: min(existing.createdAt, workflow.createdAt),
                    updatedAt: max(existing.updatedAt, workflow.updatedAt),
                    notes: winner.notes ?? existing.notes ?? workflow.notes,
                    collaboration: preferredCollaboration(existing.collaboration, workflow.collaboration)
                )
            } else {
                merged[workflow.id] = workflow
            }
        }

        return (
            merged.values.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            hadConflict
        )
    }

    private func mergeNotes(
        _ lhs: [String: SyncedDomainNote],
        _ rhs: [String: SyncedDomainNote]
    ) -> (notesByDomain: [String: SyncedDomainNote], hadConflict: Bool) {
        let result = mergeLatest(lhs, rhs, updatedAt: \.updatedAt)
        return (result.merged, result.hadConflict)
    }

    private func mergeHistoryMetadata(
        _ lhs: [String: SyncedHistoryMetadata],
        _ rhs: [String: SyncedHistoryMetadata]
    ) -> (historyMetadataByDomain: [String: SyncedHistoryMetadata], hadConflict: Bool) {
        let result = mergeLatest(lhs, rhs, updatedAt: \.updatedAt)
        return (result.merged, result.hadConflict)
    }

    /// `rhs` merged over `lhs` by domain; where both differ, the newer wins
    /// (the local one on a tie) and the merge reports a conflict.
    private func mergeLatest<Value: Equatable>(
        _ lhs: [String: Value],
        _ rhs: [String: Value],
        updatedAt: KeyPath<Value, Date>
    ) -> (merged: [String: Value], hadConflict: Bool) {
        var merged = lhs
        var hadConflict = false

        for (domain, remote) in rhs {
            if let local = merged[domain], local != remote {
                hadConflict = true
                merged[domain] = local[keyPath: updatedAt] >= remote[keyPath: updatedAt] ? local : remote
            } else {
                merged[domain] = remote
            }
        }

        return (merged, hadConflict)
    }

    private func mergeAppSettings(_ lhs: SyncedAppSettings, _ rhs: SyncedAppSettings) -> (settings: SyncedAppSettings, hadConflict: Bool) {
        let winner = lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        let loser = winner.updatedAt == lhs.updatedAt ? rhs : lhs

        let merged = SyncedAppSettings(
            snapshot: AppSettingsSnapshot(
                recentSearches: deduplicated(winner.snapshot.recentSearches + loser.snapshot.recentSearches).prefix(20).map { $0 },
                savedDomains: deduplicated(winner.snapshot.savedDomains + loser.snapshot.savedDomains),
                resolverURLString: winner.snapshot.resolverURLString,
                appDensityRawValue: winner.snapshot.appDensityRawValue
            ),
            updatedAt: max(lhs.updatedAt, rhs.updatedAt)
        )

        return (merged, !sameAppSettings(lhs.snapshot, rhs.snapshot) || lhs.updatedAt != rhs.updatedAt)
    }

    private func mergeMonitoringSettings(
        _ lhs: SyncedMonitoringSettings,
        _ rhs: SyncedMonitoringSettings
    ) -> (settings: SyncedMonitoringSettings, hadConflict: Bool) {
        let winner = lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        var merged = winner

        if merged.settings.isEnabled && !defaults.bool(forKey: StorageKey.monitoringLocalActivationConfirmed) {
            merged.settings.isEnabled = false
        }

        if merged.settings.alertsEnabled {
            merged.settings.alertsEnabled = false
        }

        merged.updatedAt = max(lhs.updatedAt, rhs.updatedAt)
        return (merged, lhs.settings != rhs.settings || lhs.updatedAt != rhs.updatedAt)
    }

    private func applyTrackedDomainTombstones(_ trackedDomains: [TrackedDomain], tombstones: [SyncTombstone]) -> [TrackedDomain] {
        let tombstonesByDomain = Dictionary(uniqueKeysWithValues: tombstones.compactMap { tombstone -> (String, SyncTombstone)? in
            guard tombstone.entityType == .trackedDomain else { return nil }
            return (tombstone.identifier, tombstone)
        })

        return trackedDomains.filter { trackedDomain in
            let key = Self.normalizeDomain(trackedDomain.domain)
            guard let tombstone = tombstonesByDomain[key] else { return true }
            return trackedDomain.updatedAt > tombstone.deletedAt
        }
    }

    private func applyWorkflowTombstones(_ workflows: [DomainWorkflow], tombstones: [SyncTombstone]) -> [DomainWorkflow] {
        let tombstonesByIdentifier = Dictionary(uniqueKeysWithValues: tombstones.compactMap { tombstone -> (String, SyncTombstone)? in
            guard tombstone.entityType == .workflow else { return nil }
            return (tombstone.identifier, tombstone)
        })

        return workflows.filter { workflow in
            guard let tombstone = tombstonesByIdentifier[workflow.id.uuidString] else { return true }
            return workflow.updatedAt > tombstone.deletedAt
        }
    }

    private func applyNotes(
        _ notesByDomain: [String: SyncedDomainNote],
        to trackedDomains: [TrackedDomain],
        tombstones: [SyncTombstone]
    ) -> [TrackedDomain] {
        let tombstonesByDomain = Dictionary(uniqueKeysWithValues: tombstones.compactMap { tombstone -> (String, SyncTombstone)? in
            guard tombstone.entityType == .trackedDomain else { return nil }
            return (tombstone.identifier, tombstone)
        })

        return trackedDomains.map { trackedDomain in
            guard trackedDomain.collaboration?.scope != .sharedDatabase else { return trackedDomain }
            let normalized = Self.normalizeDomain(trackedDomain.domain)
            guard let note = notesByDomain[normalized] else { return trackedDomain }
            if let tombstone = tombstonesByDomain[normalized], tombstone.deletedAt >= note.updatedAt {
                return trackedDomain
            }

            var updated = trackedDomain
            updated.note = emptyToNil(note.text)
            return updated
        }
    }

    private func applyHistoryMetadata(
        _ historyMetadataByDomain: [String: SyncedHistoryMetadata],
        to trackedDomains: [TrackedDomain],
        tombstones: [SyncTombstone]
    ) -> [TrackedDomain] {
        let tombstonesByDomain = Dictionary(uniqueKeysWithValues: tombstones.compactMap { tombstone -> (String, SyncTombstone)? in
            guard tombstone.entityType == .trackedDomain else { return nil }
            return (tombstone.identifier, tombstone)
        })

        return trackedDomains.map { trackedDomain in
            guard trackedDomain.collaboration?.scope != .sharedDatabase else { return trackedDomain }
            let normalized = Self.normalizeDomain(trackedDomain.domain)
            guard let metadata = historyMetadataByDomain[normalized] else { return trackedDomain }
            if let tombstone = tombstonesByDomain[normalized], tombstone.deletedAt >= metadata.updatedAt {
                return trackedDomain
            }

            var updated = trackedDomain
            updated.lastKnownAvailability = metadata.lastKnownAvailabilityRawValue.flatMap(DomainAvailabilityStatus.init(rawValue:))
            updated.lastChangeSeverity = metadata.lastChangeSeverityRawValue.flatMap(ChangeSeverity.init(rawValue:))
            updated.certificateWarningLevel = CertificateWarningLevel(rawValue: metadata.certificateWarningLevelRawValue) ?? .none
            updated.certificateDaysRemaining = metadata.certificateDaysRemaining

            if let message = metadata.lastChangeMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                updated.lastChangeSummary = DomainChangeSummary(
                    hasChanges: true,
                    changedSections: [],
                    message: message,
                    severity: updated.lastChangeSeverity ?? .medium,
                    impactClassification: .warning,
                    generatedAt: metadata.lastObservedAt ?? metadata.updatedAt
                )
            }

            return updated
        }
    }

    private func latestTombstones(_ tombstones: [SyncTombstone]) -> [SyncTombstone] {
        var latest: [String: SyncTombstone] = [:]

        for tombstone in tombstones {
            let key = "\(tombstone.entityType.rawValue):\(tombstone.identifier)"
            if let existing = latest[key] {
                latest[key] = existing.deletedAt >= tombstone.deletedAt ? existing : tombstone
            } else {
                latest[key] = tombstone
            }
        }

        return latest.values.sorted { $0.deletedAt > $1.deletedAt }
    }

    private func saveTombstone(_ tombstone: SyncTombstone) {
        var tombstones = loadTombstones()
        tombstones.append(tombstone)
        saveTombstones(latestTombstones(tombstones))
    }

    private func loadTombstones() -> [SyncTombstone] {
        guard let data = defaults.data(forKey: StorageKey.tombstones),
              let tombstones = try? decoder.decode([SyncTombstone].self, from: data) else {
            return []
        }
        return tombstones
    }

    private func saveTombstones(_ tombstones: [SyncTombstone]) {
        if let data = try? encoder.encode(Array(tombstones.prefix(200))) {
            defaults.set(data, forKey: StorageKey.tombstones)
        }
    }

    private func loadNoteUpdatedAtByDomain() -> [String: Date] {
        guard let data = defaults.data(forKey: StorageKey.noteUpdatedAtByDomain),
              let values = try? decoder.decode([String: Date].self, from: data) else {
            return [:]
        }
        return values
    }

    private func saveNoteUpdatedAtByDomain(_ values: [String: Date]) {
        if let data = try? encoder.encode(values) {
            defaults.set(data, forKey: StorageKey.noteUpdatedAtByDomain)
        }
    }

    private func setStatus(_ status: CloudSyncStatus, detail: String, error: String?) {
        self.status = status
        self.detailMessage = detail
        self.lastErrorMessage = error

        defaults.set(status.rawValue, forKey: StorageKey.status)
        defaults.set(detail, forKey: StorageKey.detailMessage)
        if let error {
            defaults.set(error, forKey: StorageKey.lastErrorMessage)
        } else {
            defaults.removeObject(forKey: StorageKey.lastErrorMessage)
        }
    }

    private func syncSummaryDetail() -> String {
        let dateLabel = lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet synced"
        return "Data stays in your private iCloud account. Last sync: \(dateLabel)."
    }

    private func accountStatus() async -> AvailabilityState {
        let container = cloudKitContainer()

        return await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    switch (error as? CKError)?.code {
                    case .notAuthenticated:
                        continuation.resume(returning: AvailabilityState.noAccount)
                    case .missingEntitlement, .badContainer, .permissionFailure:
                        continuation.resume(returning: AvailabilityState.missingEntitlement)
                    default:
                        continuation.resume(returning: AvailabilityState.unknown)
                    }
                    return
                }

                switch status {
                case .available:
                    continuation.resume(returning: AvailabilityState.available)
                case .noAccount:
                    continuation.resume(returning: AvailabilityState.noAccount)
                case .restricted:
                    continuation.resume(returning: AvailabilityState.restricted)
                case .temporarilyUnavailable:
                    continuation.resume(returning: AvailabilityState.temporarilyUnavailable)
                case .couldNotDetermine:
                    continuation.resume(returning: AvailabilityState.unknown)
                @unknown default:
                    continuation.resume(returning: AvailabilityState.unknown)
                }
            }
        }
    }

    /// Fetches every record in `scope` via `CKFetchRecordZoneChangesOperation`,
    /// which — unlike a `CKQuery` — needs no queryable schema indexes and works
    /// on a brand-new zone. The private database holds the user's own records in
    /// a single custom zone; the shared database exposes one zone per accepted
    /// share, so every shared zone is fetched.
    private func fetchZoneRecords(in scope: SyncDatabaseScope) async throws -> [CKRecord] {
        guard let database = cloudKitDatabase(in: scope) else {
            if scope == .sharedDatabase {
                return []
            }
            throw CloudSyncRuntimeError.missingEntitlement
        }

        let zoneIDs: [CKRecordZone.ID]
        switch scope {
        case .privateDatabase:
            try await ensureCustomZone(in: database)
            zoneIDs = [customZoneID]
        case .sharedDatabase:
            zoneIDs = try await database.allRecordZones().map(\.zoneID)
        }

        guard !zoneIDs.isEmpty else { return [] }
        return try await fetchZoneChanges(in: database, zoneIDs: zoneIDs)
    }

    private func fetchZoneChanges(in database: CKDatabase, zoneIDs: [CKRecordZone.ID]) async throws -> [CKRecord] {
        // A nil change token requests every record in the zone. The server may
        // truncate a large response and set `moreComing`, so keep re-fetching
        // the still-truncated zones with their latest tokens until all drain.
        var tokensByZone: [CKRecordZone.ID: CKServerChangeToken?] = [:]
        for zoneID in zoneIDs {
            tokensByZone[zoneID] = .some(nil)
        }

        var records: [CKRecord] = []
        while !tokensByZone.isEmpty {
            tokensByZone = try await withCheckedThrowingContinuation { continuation in
                var moreByZone: [CKRecordZone.ID: CKServerChangeToken?] = [:]
                let configurations = tokensByZone.mapValues { token -> CKFetchRecordZoneChangesOperation.ZoneConfiguration in
                    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                    configuration.previousServerChangeToken = token ?? nil
                    return configuration
                }

                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: Array(tokensByZone.keys),
                    configurationsByRecordZoneID: configurations
                )
                operation.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }
                operation.recordZoneFetchResultBlock = { zoneID, result in
                    if case .success(let value) = result, value.moreComing {
                        moreByZone[zoneID] = .some(value.serverChangeToken)
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: moreByZone)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        }

        return records
    }

    private func decodeRecords<T: Decodable>(_ records: [CKRecord], ofType recordType: String) -> [T] {
        var results: [T] = []
        for record in records where record.recordType == recordType {
            guard let payload = record[CloudRecordKey.payload] as? Data else { continue }
            if let decoded = try? decoder.decode(T.self, from: payload) {
                results.append(decoded)
            } else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
            }
        }
        return results
    }

    private func trackedDomains(from records: [CKRecord], in scope: SyncDatabaseScope) async throws -> [TrackedDomain] {
        let matching = records.filter { $0.recordType == CloudRecordType.trackedDomain }
        let shares = try await sharesByRecordID(for: matching, in: scope)

        return matching.compactMap { record in
            guard let payload = record[CloudRecordKey.payload] as? Data,
                  let decoded = try? decoder.decode(TrackedDomain.self, from: payload) else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
                return nil
            }
            var trackedDomain = Self.payloadTrackedDomain(decoded)
            trackedDomain.collaboration = collaborationMetadata(for: record, share: shares[record.recordID], scope: scope)
            return trackedDomain
        }
    }

    private func workflows(from records: [CKRecord], in scope: SyncDatabaseScope) async throws -> [DomainWorkflow] {
        let matching = records.filter { $0.recordType == CloudRecordType.workflow }
        let shares = try await sharesByRecordID(for: matching, in: scope)

        return matching.compactMap { record in
            guard let payload = record[CloudRecordKey.payload] as? Data,
                  let decoded = try? decoder.decode(DomainWorkflow.self, from: payload) else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
                return nil
            }
            var workflow = normalizedWorkflow(decoded)
            workflow.collaboration = collaborationMetadata(for: record, share: shares[record.recordID], scope: scope)
            return workflow
        }
    }

    private func sharesByRecordID(
        for records: [CKRecord],
        in scope: SyncDatabaseScope
    ) async throws -> [CKRecord.ID: CKShare] {
        guard let database = cloudKitDatabase(in: scope) else { return [:] }

        let shareReferences = records.reduce(into: [CKRecord.ID: CKRecord.Reference]()) { partialResult, record in
            if let reference = record.share {
                partialResult[record.recordID] = reference
            }
        }
        guard !shareReferences.isEmpty else { return [:] }

        let fetched = try await database.records(for: Array(Set(shareReferences.values.map(\.recordID))))
        var sharesByRootRecordID: [CKRecord.ID: CKShare] = [:]

        for (rootRecordID, shareReference) in shareReferences {
            guard case .success(let shareRecord) = fetched[shareReference.recordID],
                  let share = shareRecord as? CKShare else {
                continue
            }
            sharesByRootRecordID[rootRecordID] = share
        }

        return sharesByRootRecordID
    }

    private func collaborationMetadata(
        for _: CKRecord,
        share: CKShare?,
        scope: SyncDatabaseScope
    ) -> CollaborationMetadata {
        let ownership: CollaborationOwnership
        let permission: CollaborationPermission

        if let participant = share?.currentUserParticipant {
            ownership = participant.role == .owner ? .owner : .participant
            permission = participant.permission == .readOnly ? .readOnly : .editable
        } else {
            ownership = scope == .sharedDatabase ? .participant : .owner
            permission = scope == .sharedDatabase ? .readOnly : .editable
        }

        return CollaborationMetadata(
            scope: scope == .privateDatabase ? .privateDatabase : .sharedDatabase,
            ownership: ownership,
            permission: permission,
            shareRecordName: share?.recordID.recordName
        )
    }

    private func fetchShare(recordName: String, in scope: SyncDatabaseScope) async throws -> CKShare? {
        guard let database = cloudKitDatabase(in: scope) else { return nil }
        let results = try await database.records(for: [CKRecord.ID(recordName: recordName)])
        guard case .success(let shareRecord) = results[CKRecord.ID(recordName: recordName)] else {
            return nil
        }
        return shareRecord as? CKShare
    }

    private func shareRecordName(for entity: ShareableEntity) async throws -> String? {
        switch entity {
        case .trackedDomain(let domain):
            let normalized = Self.normalizeDomain(domain)
            return DomainDataPortabilityService.loadTrackedDomains()
                .first(where: { Self.normalizeDomain($0.domain) == normalized })?
                .collaboration?.shareRecordName
        case .workflow(let identifier):
            return DomainDataPortabilityService.loadWorkflows()
                .first(where: { $0.id == identifier })?
                .collaboration?.shareRecordName
        }
    }

    private func makeTrackedDomainRecord(_ trackedDomain: TrackedDomain) -> CKRecord {
        let normalized = Self.normalizeDomain(trackedDomain.domain)
        let sanitized = Self.payloadTrackedDomain(trackedDomain)
        return makeRecord(
            type: CloudRecordType.trackedDomain,
            recordName: trackedDomainRecordName(for: normalized),
            payload: sanitized,
            extraFields: [
                CloudRecordKey.domain: normalized as CKRecordValue,
                CloudRecordKey.updatedAt: sanitized.updatedAt as CKRecordValue
            ]
        )
    }

    private func makeWorkflowRecord(_ workflow: DomainWorkflow) -> CKRecord {
        let normalized = normalizedWorkflow(workflow)
        return makeRecord(
            type: CloudRecordType.workflow,
            recordName: workflowRecordName(for: normalized.id.uuidString),
            payload: normalized,
            extraFields: [
                CloudRecordKey.identifier: normalized.id.uuidString as CKRecordValue,
                CloudRecordKey.updatedAt: normalized.updatedAt as CKRecordValue
            ]
        )
    }

    private func makeAppSettingsRecord(_ settings: SyncedAppSettings) -> CKRecord {
        makeRecord(
            type: CloudRecordType.appSettings,
            recordName: "app-settings",
            payload: settings,
            extraFields: [CloudRecordKey.updatedAt: settings.updatedAt as CKRecordValue]
        )
    }

    private func makeMonitoringSettingsRecord(_ settings: SyncedMonitoringSettings) -> CKRecord {
        makeRecord(
            type: CloudRecordType.monitoringSettings,
            recordName: "monitoring-settings",
            payload: settings,
            extraFields: [CloudRecordKey.updatedAt: settings.updatedAt as CKRecordValue]
        )
    }

    private func makeDomainNoteRecord(_ note: SyncedDomainNote) -> CKRecord {
        makeRecord(
            type: CloudRecordType.domainNote,
            recordName: domainNoteRecordName(for: note.domain),
            payload: note,
            extraFields: [
                CloudRecordKey.domain: note.domain as CKRecordValue,
                CloudRecordKey.updatedAt: note.updatedAt as CKRecordValue
            ]
        )
    }

    private func makeHistoryMetadataRecord(_ metadata: SyncedHistoryMetadata) -> CKRecord {
        makeRecord(
            type: CloudRecordType.historyMetadata,
            recordName: historyMetadataRecordName(for: metadata.domain),
            payload: metadata,
            extraFields: [
                CloudRecordKey.domain: metadata.domain as CKRecordValue,
                CloudRecordKey.updatedAt: metadata.updatedAt as CKRecordValue
            ]
        )
    }

    private func makeTombstoneRecord(_ tombstone: SyncTombstone) -> CKRecord {
        makeRecord(
            type: CloudRecordType.tombstone,
            recordName: tombstoneRecordName(for: tombstone.entityType, identifier: tombstone.identifier),
            payload: tombstone,
            extraFields: [
                CloudRecordKey.entityType: tombstone.entityType.rawValue as CKRecordValue,
                CloudRecordKey.identifier: tombstone.identifier as CKRecordValue,
                CloudRecordKey.deletedAt: tombstone.deletedAt as CKRecordValue
            ]
        )
    }

    private func makeRecord<T: Encodable>(
        type: String,
        recordName: String,
        payload: T,
        extraFields: [String: CKRecordValue]
    ) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: recordName, zoneID: customZoneID))
        record[CloudRecordKey.payload] = (try? encoder.encode(payload)) as CKRecordValue?
        for (key, value) in extraFields {
            record[key] = value
        }
        return record
    }

    private func mapSyncError(_ error: Error) -> (status: CloudSyncStatus, message: String, errorDetail: String?) {
        if let runtimeError = error as? CloudSyncRuntimeError, runtimeError == .missingEntitlement {
            return (
                .iCloudUnavailable,
                missingEntitlementMessage,
                nil
            )
        }

        if let runtimeError = error as? CloudSyncRuntimeError, runtimeError == .missingLocalItem {
            return (.error, "The shared item is no longer available locally.", nil)
        }

        guard let ckError = error as? CKError else {
            return (.error, "Sync failed, but local data is still available.", error.localizedDescription)
        }

        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable:
            return (.offline, "Sync is waiting for a stable network connection.", ckError.localizedDescription)
        case .notAuthenticated:
            return (.iCloudUnavailable, "Sign in to iCloud to sync DomainDig.", ckError.localizedDescription)
        case .quotaExceeded:
            return (.error, "iCloud storage is full. DomainDig kept working locally.", ckError.localizedDescription)
        case .permissionFailure, .badContainer, .missingEntitlement:
            return (.iCloudUnavailable, "CloudKit access is unavailable for this build.", ckError.localizedDescription)
        case .partialFailure:
            return (.error, "Some iCloud records could not sync. Local data remains available.", ckError.localizedDescription)
        default:
            return (.error, "Sync failed, but local data is still available.", ckError.localizedDescription)
        }
    }

    private enum AvailabilityState {
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown
        case missingEntitlement
    }

    private enum CloudSyncRuntimeError: Error, Equatable {
        case missingEntitlement
        case missingLocalItem
    }

    private static func normalizeDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }

    private func cloudKitContainer() -> CKContainer {
        if let container {
            return container
        }

        let container = CKContainer.default()
        self.container = container
        return container
    }

    /// The user's own records live in a single custom zone. A custom zone (as
    /// opposed to the default zone) is what lets the sync read every record with
    /// `CKFetchRecordZoneChangesOperation`, which needs no queryable schema
    /// indexes, and is also a prerequisite for CloudKit sharing.
    private var customZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: CloudZone.name, ownerName: CKCurrentUserDefaultName)
    }

    /// Creates the custom zone if it does not exist yet. Saving an existing zone
    /// is a no-op, so this is safe to call before every push and fetch.
    private func ensureCustomZone(in database: CKDatabase) async throws {
        if didEnsureZone { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: customZoneID)], deleting: [])
        didEnsureZone = true
    }

    private func cloudKitDatabase(in scope: SyncDatabaseScope) -> CKDatabase? {
        switch scope {
        case .privateDatabase:
            if let privateDatabase {
                return privateDatabase
            }
        case .sharedDatabase:
            if let sharedDatabase {
                return sharedDatabase
            }
        }

        let container = cloudKitContainer()

        switch scope {
        case .privateDatabase:
            let database = container.privateCloudDatabase
            self.privateDatabase = database
            return database
        case .sharedDatabase:
            let database = container.sharedCloudDatabase
            self.sharedDatabase = database
            return database
        }
    }

    private var missingEntitlementMessage: String {
        "This build does not have the CloudKit entitlement required for iCloud sync."
    }

    private static func payloadTrackedDomain(_ trackedDomain: TrackedDomain) -> TrackedDomain {
        TrackedDomain(
            id: trackedDomain.id,
            domain: normalizeDomain(trackedDomain.domain),
            createdAt: trackedDomain.createdAt,
            updatedAt: trackedDomain.updatedAt,
            note: trackedDomain.note,
            isPinned: trackedDomain.isPinned,
            monitoringEnabled: trackedDomain.monitoringEnabled,
            lastKnownAvailability: trackedDomain.lastKnownAvailability,
            lastSnapshotID: nil,
            lastChangeSummary: nil,
            lastChangeSeverity: trackedDomain.lastChangeSeverity,
            certificateWarningLevel: trackedDomain.certificateWarningLevel,
            certificateDaysRemaining: trackedDomain.certificateDaysRemaining,
            lastMonitoredAt: trackedDomain.lastMonitoredAt,
            lastAlertAt: trackedDomain.lastAlertAt,
            monitoringState: trackedDomain.monitoringState,
            pendingMonitoringAlerts: trackedDomain.pendingMonitoringAlerts,
            collaboration: trackedDomain.collaboration
        )
    }

    private func mergedTrackedDomain(_ lhs: TrackedDomain, _ rhs: TrackedDomain) -> TrackedDomain {
        let winner = preferredTrackedDomain(lhs, rhs)

        return TrackedDomain(
            id: lhs.id,
            domain: Self.normalizeDomain(lhs.domain.isEmpty ? rhs.domain : lhs.domain),
            createdAt: min(lhs.createdAt, rhs.createdAt),
            updatedAt: max(lhs.updatedAt, rhs.updatedAt),
            note: winner.note ?? lhs.note ?? rhs.note,
            isPinned: winner.isPinned,
            monitoringEnabled: winner.monitoringEnabled,
            lastKnownAvailability: winner.lastKnownAvailability ?? lhs.lastKnownAvailability ?? rhs.lastKnownAvailability,
            lastSnapshotID: nil,
            lastChangeSummary: nil,
            lastChangeSeverity: winner.lastChangeSeverity ?? lhs.lastChangeSeverity ?? rhs.lastChangeSeverity,
            certificateWarningLevel: higherCertificateWarningLevel(lhs.certificateWarningLevel, rhs.certificateWarningLevel),
            certificateDaysRemaining: winner.certificateDaysRemaining ?? lhs.certificateDaysRemaining ?? rhs.certificateDaysRemaining,
            lastMonitoredAt: [lhs.lastMonitoredAt, rhs.lastMonitoredAt].compactMap { $0 }.max(),
            lastAlertAt: [lhs.lastAlertAt, rhs.lastAlertAt].compactMap { $0 }.max(),
            monitoringState: preferredMonitoringState(lhs.monitoringState, rhs.monitoringState),
            pendingMonitoringAlerts: deduplicatedPendingAlerts(lhs.pendingMonitoringAlerts + rhs.pendingMonitoringAlerts),
            collaboration: preferredCollaboration(lhs.collaboration, rhs.collaboration)
        )
    }

    private func normalizedWorkflow(_ workflow: DomainWorkflow) -> DomainWorkflow {
        DomainWorkflow(
            id: workflow.id,
            name: workflow.name.trimmingCharacters(in: .whitespacesAndNewlines),
            domains: deduplicated(workflow.domains.map(Self.normalizeDomain).filter { !$0.isEmpty }),
            createdAt: workflow.createdAt,
            updatedAt: workflow.updatedAt,
            notes: emptyToNil(workflow.notes ?? ""),
            collaboration: workflow.collaboration
        )
    }

    private func preferredTrackedDomain(_ lhs: TrackedDomain, _ rhs: TrackedDomain) -> TrackedDomain {
        let lhsRank = collaborationRank(lhs.collaboration)
        let rhsRank = collaborationRank(rhs.collaboration)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank ? lhs : rhs
        }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private func preferredMonitoringState(_ lhs: MonitoringState, _ rhs: MonitoringState) -> MonitoringState {
        let lhsDate = [lhs.lastCheck, lhs.lastAlertDate, lhs.lastChangeDate].compactMap { $0 }.max() ?? .distantPast
        let rhsDate = [rhs.lastCheck, rhs.lastAlertDate, rhs.lastChangeDate].compactMap { $0 }.max() ?? .distantPast
        return lhsDate >= rhsDate ? lhs : rhs
    }

    private func deduplicatedPendingAlerts(_ alerts: [MonitoringPendingAlert]) -> [MonitoringPendingAlert] {
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

    private func preferredWorkflow(_ lhs: DomainWorkflow, _ rhs: DomainWorkflow) -> DomainWorkflow {
        let lhsRank = collaborationRank(lhs.collaboration)
        let rhsRank = collaborationRank(rhs.collaboration)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank ? lhs : rhs
        }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private func preferredCollaboration(
        _ lhs: CollaborationMetadata?,
        _ rhs: CollaborationMetadata?
    ) -> CollaborationMetadata? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let lhsRank = collaborationRank(lhs)
        let rhsRank = collaborationRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank ? lhs : rhs
        }
        if lhs.shareRecordName != nil {
            return lhs
        }
        return rhs
    }

    private func collaborationRank(_ collaboration: CollaborationMetadata?) -> Int {
        guard let collaboration else { return 0 }
        switch collaboration.ownership {
        case .owner:
            return collaboration.isShared ? 3 : 2
        case .participant:
            return collaboration.permission == .editable ? 1 : 0
        }
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sameAppSettings(_ lhs: AppSettingsSnapshot, _ rhs: AppSettingsSnapshot) -> Bool {
        lhs.recentSearches == rhs.recentSearches
            && lhs.savedDomains == rhs.savedDomains
            && lhs.resolverURLString == rhs.resolverURLString
            && lhs.appDensityRawValue == rhs.appDensityRawValue
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func higherCertificateWarningLevel(
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

    private func trackedDomainRecordName(for normalizedDomain: String) -> String {
        "tracked-domain:\(normalizedDomain)"
    }

    private func workflowRecordName(for identifier: String) -> String {
        "workflow:\(identifier)"
    }

    private func domainNoteRecordName(for normalizedDomain: String) -> String {
        "domain-note:\(normalizedDomain)"
    }

    private func historyMetadataRecordName(for normalizedDomain: String) -> String {
        "history-metadata:\(normalizedDomain)"
    }

    private func tombstoneRecordName(for entityType: SyncEntityType, identifier: String) -> String {
        "tombstone:\(entityType.rawValue):\(identifier)"
    }
}

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

private struct SyncPayload {
    var trackedDomains: [SyncRow<TrackedDomain>]
    var workflows: [SyncRow<DomainWorkflow>]
    var appSettings: SyncRow<SyncedAppSettings>
    var monitoringSettings: SyncRow<SyncedMonitoringSettings>
    var notesByDomain: [String: SyncRow<SyncedDomainNote>]
    var historyMetadataByDomain: [String: SyncRow<SyncedHistoryMetadata>]
    var tombstones: [SyncRow<SyncTombstone>]
}

/// What a remote fetch produced: the payload, and the change token each zone
/// may resume from once the payload has been merged and pushed.
private struct RemoteSyncState {
    var payload: SyncPayload
    var changeTokens: [String: CKServerChangeToken]
}

/// One pass of `CKFetchRecordZoneChangesOperation`: the zones that still have
/// more coming, the token each zone reached, and the zones whose stored token
/// the server has aged out.
private struct ZoneChangesStep {
    var pendingByZone: [CKRecordZone.ID: CKServerChangeToken?]
    var tokensByZone: [CKRecordZone.ID: CKServerChangeToken]
    var expiredZones: [CKRecordZone.ID]
}

/// The server date this device last saw for a record, with the payload date the
/// row carried at that moment. A row whose payload date has moved since has a
/// local change the server has not seen.
private struct StoredRowAuthority: Codable {
    var serverDate: Date
    var deviceDate: Date
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
        static let rowAuthority = "cloudSync.rowAuthority"
        static let changeTokenPrefix = "cloudSync.changeToken."
    }

    /// Injectable so the tombstone paths can be exercised against a scratch
    /// store. Every write below goes through `defaults`, and C7's remaining gap
    /// was that nothing could prove it: with a private init the only instance
    /// was `shared`, on `.standard`, and covering a deletion meant polluting
    /// the simulator the suite runs on. The app still uses `shared`.
    init(defaults: UserDefaults = .standard) {
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
        let normalized = CloudSyncMerge.normalizeDomain(domain)
        guard !normalized.isEmpty else { return }

        var noteDates = loadNoteUpdatedAtByDomain()
        noteDates[normalized] = updatedAt
        saveNoteUpdatedAtByDomain(noteDates)
        scheduleSyncIfNeeded()
    }

    func recordTrackedDomainDeletion(_ trackedDomain: TrackedDomain, deletedAt: Date = Date()) {
        let normalized = CloudSyncMerge.normalizeDomain(trackedDomain.domain)
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
            let normalized = CloudSyncMerge.normalizeDomain(domain)
            let trackedDomain = DomainDataPortabilityService.loadTrackedDomains()
                .first(where: { CloudSyncMerge.normalizeDomain($0.domain) == normalized })
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
            let merged = merge(local: local, remote: remote.payload)
            applyMergedPayload(merged.payload)
            let pushedServerDates = try await pushMergedPayload(merged.payload)

            // Recorded from a reload rather than from the merged payload: the
            // local stores round-trip dates through ISO-8601 and through
            // `JSONEncoder`, and the next sync compares against what they read
            // back, not against the in-memory values.
            recordRowAuthority(in: loadLocalPayload(), remote: remote.payload, pushedServerDates: pushedServerDates)

            // Only once the fetched changes are on disk and the push went
            // through: a token committed earlier would skip those changes
            // forever if either step failed.
            commitChangeTokens(remote.changeTokens)

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
        let authority = loadRowAuthority()
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
        var notesByDomain: [String: SyncRow<SyncedDomainNote>] = [:]
        var historyMetadataByDomain: [String: SyncRow<SyncedHistoryMetadata>] = [:]

        for trackedDomain in trackedDomains {
            guard trackedDomain.collaboration?.scope != .sharedDatabase else { continue }
            let normalized = CloudSyncMerge.normalizeDomain(trackedDomain.domain)
            guard !normalized.isEmpty else { continue }

            let note = SyncedDomainNote(
                domain: normalized,
                text: trackedDomain.note ?? "",
                updatedAt: noteDates[normalized] ?? trackedDomain.updatedAt
            )
            notesByDomain[normalized] = SyncRow(
                value: note,
                orderKey: localOrderKey(authority, recordName: domainNoteRecordName(for: normalized), deviceDate: note.updatedAt)
            )

            let metadata = SyncedHistoryMetadata(
                domain: normalized,
                lastKnownAvailabilityRawValue: trackedDomain.lastKnownAvailability?.rawValue,
                lastChangeMessage: trackedDomain.lastChangeSummary?.message,
                lastChangeSeverityRawValue: trackedDomain.lastChangeSeverity?.rawValue ?? trackedDomain.lastChangeSummary?.severity.rawValue,
                certificateWarningLevelRawValue: trackedDomain.certificateWarningLevel.rawValue,
                certificateDaysRemaining: trackedDomain.certificateDaysRemaining,
                lastObservedAt: trackedDomain.updatedAt,
                updatedAt: trackedDomain.updatedAt
            )
            historyMetadataByDomain[normalized] = SyncRow(
                value: metadata,
                orderKey: localOrderKey(authority, recordName: historyMetadataRecordName(for: normalized), deviceDate: metadata.updatedAt)
            )
        }

        return SyncPayload(
            trackedDomains: trackedDomains.map { trackedDomain in
                SyncRow(
                    value: trackedDomain,
                    orderKey: localOrderKey(
                        authority,
                        recordName: trackedDomainRecordName(for: CloudSyncMerge.normalizeDomain(trackedDomain.domain)),
                        deviceDate: trackedDomain.updatedAt
                    )
                )
            },
            workflows: workflows.map { workflow in
                SyncRow(
                    value: workflow,
                    orderKey: localOrderKey(
                        authority,
                        recordName: workflowRecordName(for: workflow.id.uuidString),
                        deviceDate: workflow.updatedAt
                    )
                )
            },
            appSettings: SyncRow(
                value: appSettings,
                orderKey: localOrderKey(authority, recordName: appSettingsRecordName, deviceDate: appSettings.updatedAt)
            ),
            monitoringSettings: SyncRow(
                value: monitoringSettings,
                orderKey: localOrderKey(authority, recordName: monitoringSettingsRecordName, deviceDate: monitoringSettings.updatedAt)
            ),
            notesByDomain: notesByDomain,
            historyMetadataByDomain: historyMetadataByDomain,
            tombstones: loadTombstones().map { tombstone in
                SyncRow(
                    value: tombstone,
                    orderKey: localOrderKey(
                        authority,
                        recordName: tombstoneRecordName(for: tombstone.entityType, identifier: tombstone.identifier),
                        deviceDate: tombstone.deletedAt
                    )
                )
            }
        )
    }

    private func fetchRemotePayload() async throws -> RemoteSyncState {
        let privateFetch = try await fetchZoneRecords(in: .privateDatabase)
        let sharedFetch = try await fetchZoneRecords(in: .sharedDatabase)
        let privateRecords = privateFetch.records
        let sharedRecords = sharedFetch.records

        let privateTrackedDomains = try await trackedDomains(from: privateRecords, in: .privateDatabase)
        let sharedTrackedDomains = try await trackedDomains(from: sharedRecords, in: .sharedDatabase)
        let privateWorkflows = try await workflows(from: privateRecords, in: .privateDatabase)
        let sharedWorkflows = try await workflows(from: sharedRecords, in: .sharedDatabase)

        let appSettingsRecords: [SyncRow<SyncedAppSettings>] = decodeRecords(
            privateRecords,
            ofType: CloudRecordType.appSettings,
            deviceDate: \.updatedAt
        )
        let monitoringSettingsRecords: [SyncRow<SyncedMonitoringSettings>] = decodeRecords(
            privateRecords,
            ofType: CloudRecordType.monitoringSettings,
            deviceDate: \.updatedAt
        )
        let domainNotes: [SyncRow<SyncedDomainNote>] = decodeRecords(
            privateRecords,
            ofType: CloudRecordType.domainNote,
            deviceDate: \.updatedAt
        )
        let historyMetadata: [SyncRow<SyncedHistoryMetadata>] = decodeRecords(
            privateRecords,
            ofType: CloudRecordType.historyMetadata,
            deviceDate: \.updatedAt
        )
        let tombstones: [SyncRow<SyncTombstone>] = decodeRecords(
            privateRecords,
            ofType: CloudRecordType.tombstone,
            deviceDate: \.deletedAt
        )

        let appSettings = appSettingsRecords.max(by: { SyncOrderKey.isNewer($1.orderKey, $0.orderKey) })
            ?? SyncRow(
                value: SyncedAppSettings(snapshot: DomainDataPortabilityService.loadAppSettings(), updatedAt: .distantPast),
                orderKey: Self.absentRemoteOrderKey
            )
        let monitoringSettings = monitoringSettingsRecords.max(by: { SyncOrderKey.isNewer($1.orderKey, $0.orderKey) })
            ?? SyncRow(
                value: SyncedMonitoringSettings(settings: DomainDataPortabilityService.loadMonitoringSettings(), updatedAt: .distantPast),
                orderKey: Self.absentRemoteOrderKey
            )

        let payload = SyncPayload(
            trackedDomains: privateTrackedDomains + sharedTrackedDomains,
            workflows: privateWorkflows + sharedWorkflows,
            appSettings: appSettings,
            monitoringSettings: monitoringSettings,
            notesByDomain: Dictionary(
                domainNotes.map { (CloudSyncMerge.normalizeDomain($0.value.domain), $0) },
                uniquingKeysWith: { SyncOrderKey.isAtLeastAsRecent($0.orderKey, $1.orderKey) ? $0 : $1 }
            ),
            historyMetadataByDomain: Dictionary(
                historyMetadata.map { (CloudSyncMerge.normalizeDomain($0.value.domain), $0) },
                uniquingKeysWith: { SyncOrderKey.isAtLeastAsRecent($0.orderKey, $1.orderKey) ? $0 : $1 }
            ),
            tombstones: tombstones
        )

        return RemoteSyncState(
            payload: payload,
            changeTokens: privateFetch.changeTokens.merging(sharedFetch.changeTokens) { _, shared in shared }
        )
    }

    /// Stands in for a singleton record the zone does not hold yet. It has to
    /// lose to anything real, so it carries the oldest possible server date
    /// rather than none — no server date means an unpushed local change, which
    /// wins.
    private static let absentRemoteOrderKey = SyncOrderKey(serverDate: .distantPast, deviceDate: .distantPast)

    /// Returns the server-assigned modification date of every record the push
    /// saved, keyed by record name. Those dates are what the next sync orders
    /// its conflicts by.
    private func pushMergedPayload(_ payload: SyncPayload) async throws -> [String: Date] {
        guard let privateDatabase = cloudKitDatabase(in: .privateDatabase) else {
            throw CloudSyncRuntimeError.missingEntitlement
        }

        try await ensureCustomZone(in: privateDatabase)

        var privateRecordsToSave: [CKRecord] = []
        var sharedRecordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for trackedDomain in payload.trackedDomains.map(\.value) {
            switch trackedDomain.collaboration?.scope ?? .privateDatabase {
            case .privateDatabase:
                privateRecordsToSave.append(makeTrackedDomainRecord(trackedDomain))
            case .sharedDatabase:
                if trackedDomain.collaboration?.canEdit == true {
                    sharedRecordsToSave.append(makeTrackedDomainRecord(trackedDomain))
                }
            }
        }

        for workflow in payload.workflows.map(\.value) {
            switch workflow.collaboration?.scope ?? .privateDatabase {
            case .privateDatabase:
                privateRecordsToSave.append(makeWorkflowRecord(workflow))
            case .sharedDatabase:
                if workflow.collaboration?.canEdit == true {
                    sharedRecordsToSave.append(makeWorkflowRecord(workflow))
                }
            }
        }

        privateRecordsToSave.append(makeAppSettingsRecord(payload.appSettings.value))
        privateRecordsToSave.append(makeMonitoringSettingsRecord(payload.monitoringSettings.value))
        privateRecordsToSave.append(contentsOf: payload.notesByDomain.values.map { makeDomainNoteRecord($0.value) })
        privateRecordsToSave.append(contentsOf: payload.historyMetadataByDomain.values.map { makeHistoryMetadataRecord($0.value) })
        privateRecordsToSave.append(contentsOf: payload.tombstones.map { makeTombstoneRecord($0.value) })

        for tombstone in payload.tombstones.map(\.value) {
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

        let privateResults = try await privateDatabase.modifyRecords(
            saving: privateRecordsToSave,
            deleting: Array(Set(recordIDsToDelete)),
            savePolicy: .changedKeys,
            atomically: false
        )
        var serverDates = Self.serverDates(from: privateResults.saveResults)

        if !sharedRecordsToSave.isEmpty, let sharedDatabase = cloudKitDatabase(in: .sharedDatabase) {
            let sharedResults = try await sharedDatabase.modifyRecords(
                saving: sharedRecordsToSave,
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            serverDates.merge(Self.serverDates(from: sharedResults.saveResults)) { _, shared in shared }
        }

        return serverDates
    }

    private static func serverDates(from results: [CKRecord.ID: Result<CKRecord, Error>]) -> [String: Date] {
        results.reduce(into: [String: Date]()) { partialResult, entry in
            guard case .success(let record) = entry.value, let modificationDate = record.modificationDate else { return }
            partialResult[entry.key.recordName] = modificationDate
        }
    }

    private func applyMergedPayload(_ payload: SyncPayload) {
        DomainDataPortabilityService.saveTrackedDomains(payload.trackedDomains.map(\.value))
        DomainDataPortabilityService.saveWorkflows(payload.workflows.map(\.value))
        DomainDataPortabilityService.saveAppSettings(payload.appSettings.value.snapshot)
        DomainDataPortabilityService.saveMonitoringSettings(payload.monitoringSettings.value.settings)

        defaults.set(payload.appSettings.value.updatedAt, forKey: StorageKey.appSettingsUpdatedAt)
        defaults.set(payload.monitoringSettings.value.updatedAt, forKey: StorageKey.monitoringSettingsUpdatedAt)
        saveNoteUpdatedAtByDomain(Dictionary(uniqueKeysWithValues: payload.notesByDomain.map { ($0.key, $0.value.value.updatedAt) }))
        saveTombstones(payload.tombstones)
    }

    private func merge(local: SyncPayload, remote: SyncPayload) -> MergedSyncPayload {
        var hadConflict = false

        let tombstones = CloudSyncMerge.latestTombstones(local.tombstones + remote.tombstones)

        let trackedDomainsResult = CloudSyncMerge.mergeTrackedDomains(local.trackedDomains, remote.trackedDomains)
        hadConflict = hadConflict || trackedDomainsResult.hadConflict
        var trackedDomains = CloudSyncMerge.applyTrackedDomainTombstones(trackedDomainsResult.domains, tombstones: tombstones)

        let workflowsResult = CloudSyncMerge.mergeWorkflows(local.workflows, remote.workflows)
        hadConflict = hadConflict || workflowsResult.hadConflict
        let workflows = CloudSyncMerge.applyWorkflowTombstones(workflowsResult.workflows, tombstones: tombstones)

        let notesResult = CloudSyncMerge.mergeNotes(local.notesByDomain, remote.notesByDomain)
        hadConflict = hadConflict || notesResult.hadConflict
        trackedDomains = CloudSyncMerge.applyNotes(notesResult.notesByDomain, to: trackedDomains, tombstones: tombstones)

        let historyResult = CloudSyncMerge.mergeHistoryMetadata(local.historyMetadataByDomain, remote.historyMetadataByDomain)
        hadConflict = hadConflict || historyResult.hadConflict
        trackedDomains = CloudSyncMerge.applyHistoryMetadata(historyResult.historyMetadataByDomain, to: trackedDomains, tombstones: tombstones)

        let appSettingsResult = CloudSyncMerge.mergeAppSettings(local.appSettings, remote.appSettings)
        hadConflict = hadConflict || appSettingsResult.hadConflict

        let monitoringResult = CloudSyncMerge.mergeMonitoringSettings(
            local.monitoringSettings,
            remote.monitoringSettings,
            localActivationConfirmed: defaults.bool(forKey: StorageKey.monitoringLocalActivationConfirmed)
        )
        hadConflict = hadConflict || monitoringResult.hadConflict

        let mergedPayload = SyncPayload(
            trackedDomains: trackedDomains,
            workflows: workflows,
            appSettings: SyncRow(
                value: appSettingsResult.settings,
                orderKey: CloudSyncMerge.mergedOrderKey(local.appSettings.orderKey, remote.appSettings.orderKey)
            ),
            monitoringSettings: SyncRow(
                value: monitoringResult.settings,
                orderKey: CloudSyncMerge.mergedOrderKey(local.monitoringSettings.orderKey, remote.monitoringSettings.orderKey)
            ),
            notesByDomain: Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { row -> (String, SyncRow<SyncedDomainNote>)? in
                guard row.value.collaboration?.scope != .sharedDatabase else { return nil }
                let normalized = CloudSyncMerge.normalizeDomain(row.value.domain)
                guard let note = notesResult.notesByDomain[normalized] else { return nil }
                return (normalized, note)
            }),
            historyMetadataByDomain: Dictionary(uniqueKeysWithValues: trackedDomains.compactMap { row -> (String, SyncRow<SyncedHistoryMetadata>)? in
                guard row.value.collaboration?.scope != .sharedDatabase else { return nil }
                let normalized = CloudSyncMerge.normalizeDomain(row.value.domain)
                guard let metadata = historyResult.historyMetadataByDomain[normalized] else { return nil }
                return (normalized, metadata)
            }),
            tombstones: tombstones
        )

        let changedLocalData =
            mergedPayload.trackedDomains.map(\.value) != local.trackedDomains.map(\.value)
            || mergedPayload.workflows.map(\.value) != local.workflows.map(\.value)
            || !CloudSyncMerge.sameAppSettings(mergedPayload.appSettings.value.snapshot, local.appSettings.value.snapshot)
            || mergedPayload.monitoringSettings.value.settings != local.monitoringSettings.value.settings

        return MergedSyncPayload(
            payload: mergedPayload,
            hadConflict: hadConflict,
            changedLocalData: changedLocalData
        )
    }

    private func saveTombstone(_ tombstone: SyncTombstone) {
        let authority = loadRowAuthority()
        var tombstones = loadTombstones().map { stored in
            SyncRow(
                value: stored,
                orderKey: localOrderKey(
                    authority,
                    recordName: tombstoneRecordName(for: stored.entityType, identifier: stored.identifier),
                    deviceDate: stored.deletedAt
                )
            )
        }
        // A deletion recorded right now has not been pushed, so it carries no
        // server date and outranks whatever the server already holds.
        tombstones.append(SyncRow(value: tombstone, orderKey: SyncOrderKey(serverDate: nil, deviceDate: tombstone.deletedAt)))
        saveTombstones(tombstones)
    }

    /// Internal so a test can read back what a deletion recorded.
    func loadTombstones() -> [SyncTombstone] {
        guard let data = defaults.data(forKey: StorageKey.tombstones),
              let tombstones = try? decoder.decode([SyncTombstone].self, from: data) else {
            return []
        }
        return tombstones
    }

    private func saveTombstones(_ tombstones: [SyncRow<SyncTombstone>]) {
        if let data = try? encoder.encode(CloudSyncMerge.newestTombstones(tombstones).map(\.value)) {
            defaults.set(data, forKey: StorageKey.tombstones)
        }
    }

    private func loadRowAuthority() -> [String: StoredRowAuthority] {
        guard let data = defaults.data(forKey: StorageKey.rowAuthority),
              let values = try? decoder.decode([String: StoredRowAuthority].self, from: data) else {
            return [:]
        }
        return values
    }

    /// The order key for a row read out of the local store.
    ///
    /// A row keeps the server date this device last saw for it, but only while
    /// its payload date still matches the one recorded then. Any later local
    /// edit moves that date, which marks the row as a change the server has
    /// never seen. Both dates in that comparison were minted by this one
    /// device, so no other device's clock enters into it.
    private func localOrderKey(
        _ authority: [String: StoredRowAuthority],
        recordName: String,
        deviceDate: Date
    ) -> SyncOrderKey {
        guard let stored = authority[recordName], stored.deviceDate == deviceDate else {
            return SyncOrderKey(serverDate: nil, deviceDate: deviceDate)
        }
        return SyncOrderKey(serverDate: stored.serverDate, deviceDate: deviceDate)
    }

    /// Remembers the server date behind every row the sync just settled. Rows
    /// that are no longer in the payload are dropped, so the map stays the size
    /// of the data rather than of everything ever seen.
    ///
    /// The first sync after this bookkeeping arrives has no recorded dates at
    /// all, so every local row counts as unpushed and wins that one merge.
    private func recordRowAuthority(in payload: SyncPayload, remote: SyncPayload, pushedServerDates: [String: Date]) {
        let remoteServerDates = Dictionary(
            rowDates(in: remote).compactMap { entry in entry.serverDate.map { (entry.recordName, $0) } },
            uniquingKeysWith: { max($0, $1) }
        )

        let previous = loadRowAuthority()
        var authority: [String: StoredRowAuthority] = [:]
        for entry in rowDates(in: payload) {
            if let serverDate = pushedServerDates[entry.recordName] ?? remoteServerDates[entry.recordName] {
                authority[entry.recordName] = StoredRowAuthority(serverDate: serverDate, deviceDate: entry.deviceDate)
            } else if let carried = previous[entry.recordName], carried.deviceDate == entry.deviceDate {
                // A fetch that resumed from a change token only returns what
                // changed, and a read-only shared row is never pushed, so a row
                // can appear in neither list. Keeping the date already recorded
                // for it is what stops it from looking like a local change this
                // device never pushed.
                authority[entry.recordName] = carried
            }
        }

        if let data = try? encoder.encode(authority) {
            defaults.set(data, forKey: StorageKey.rowAuthority)
        }
    }

    private func rowDates(in payload: SyncPayload) -> [(recordName: String, deviceDate: Date, serverDate: Date?)] {
        var entries: [(recordName: String, deviceDate: Date, serverDate: Date?)] = [
            (appSettingsRecordName, payload.appSettings.value.updatedAt, payload.appSettings.orderKey.serverDate),
            (monitoringSettingsRecordName, payload.monitoringSettings.value.updatedAt, payload.monitoringSettings.orderKey.serverDate)
        ]

        for row in payload.trackedDomains {
            entries.append((
                trackedDomainRecordName(for: CloudSyncMerge.normalizeDomain(row.value.domain)),
                row.value.updatedAt,
                row.orderKey.serverDate
            ))
        }
        for row in payload.workflows {
            entries.append((workflowRecordName(for: row.value.id.uuidString), row.value.updatedAt, row.orderKey.serverDate))
        }
        for row in payload.notesByDomain.values {
            entries.append((domainNoteRecordName(for: row.value.domain), row.value.updatedAt, row.orderKey.serverDate))
        }
        for row in payload.historyMetadataByDomain.values {
            entries.append((historyMetadataRecordName(for: row.value.domain), row.value.updatedAt, row.orderKey.serverDate))
        }
        for row in payload.tombstones {
            entries.append((
                tombstoneRecordName(for: row.value.entityType, identifier: row.value.identifier),
                row.value.deletedAt,
                row.orderKey.serverDate
            ))
        }

        return entries
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
    private func fetchZoneRecords(
        in scope: SyncDatabaseScope
    ) async throws -> (records: [CKRecord], changeTokens: [String: CKServerChangeToken]) {
        guard let database = cloudKitDatabase(in: scope) else {
            if scope == .sharedDatabase {
                return ([], [:])
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

        guard !zoneIDs.isEmpty else { return ([], [:]) }
        return try await fetchZoneChanges(in: database, scope: scope, zoneIDs: zoneIDs)
    }

    /// Fetches what changed in each zone since the token stored for it, and
    /// returns the tokens the caller should store once the changes are safely
    /// applied. A zone with no stored token is fetched in full.
    ///
    /// The server may truncate a large response and set `moreComing`, so keep
    /// re-fetching the still-truncated zones with their latest tokens until all
    /// drain. A token the server has aged out comes back as
    /// `.changeTokenExpired`, and the only recovery is to drop it and refetch
    /// that zone in full; that is done at most once per zone per sync, so a
    /// token that keeps expiring cannot spin here.
    private func fetchZoneChanges(
        in database: CKDatabase,
        scope: SyncDatabaseScope,
        zoneIDs: [CKRecordZone.ID]
    ) async throws -> (records: [CKRecord], changeTokens: [String: CKServerChangeToken]) {
        var pendingByZone: [CKRecordZone.ID: CKServerChangeToken?] = [:]
        for zoneID in zoneIDs {
            pendingByZone[zoneID] = .some(loadChangeToken(forKey: changeTokenStorageKey(scope: scope, zoneID: zoneID)))
        }

        var records: [CKRecord] = []
        var tokensByZone: [CKRecordZone.ID: CKServerChangeToken] = [:]
        var refetchedAfterExpiry: Set<CKRecordZone.ID> = []

        while !pendingByZone.isEmpty {
            let step: ZoneChangesStep = try await withCheckedThrowingContinuation { continuation in
                var moreByZone: [CKRecordZone.ID: CKServerChangeToken?] = [:]
                var fetchedByZone: [CKRecordZone.ID: CKServerChangeToken] = [:]
                var expiredZones: [CKRecordZone.ID] = []

                let configurations = pendingByZone.mapValues { token -> CKFetchRecordZoneChangesOperation.ZoneConfiguration in
                    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                    configuration.previousServerChangeToken = token ?? nil
                    return configuration
                }

                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: Array(pendingByZone.keys),
                    configurationsByRecordZoneID: configurations
                )
                operation.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }
                operation.recordZoneFetchResultBlock = { zoneID, result in
                    switch result {
                    case .success(let value):
                        fetchedByZone[zoneID] = value.serverChangeToken
                        if value.moreComing {
                            moreByZone[zoneID] = .some(value.serverChangeToken)
                        }
                    case .failure(let error):
                        if (error as? CKError)?.code == .changeTokenExpired {
                            expiredZones.append(zoneID)
                        }
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(
                            returning: ZoneChangesStep(pendingByZone: moreByZone, tokensByZone: fetchedByZone, expiredZones: expiredZones)
                        )
                    case .failure(let error):
                        // An expired token is reported per zone and also fails
                        // the operation as a whole. That is the one failure the
                        // loop can recover from, and only when a zone actually
                        // reported it — anything else still throws.
                        let code = (error as? CKError)?.code
                        if !expiredZones.isEmpty, code == .partialFailure || code == .changeTokenExpired {
                            continuation.resume(
                                returning: ZoneChangesStep(pendingByZone: moreByZone, tokensByZone: fetchedByZone, expiredZones: expiredZones)
                            )
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                database.add(operation)
            }

            tokensByZone.merge(step.tokensByZone) { _, fetched in fetched }
            pendingByZone = step.pendingByZone

            for zoneID in step.expiredZones where !refetchedAfterExpiry.contains(zoneID) {
                refetchedAfterExpiry.insert(zoneID)
                tokensByZone.removeValue(forKey: zoneID)
                pendingByZone[zoneID] = .some(nil)
            }
        }

        let changeTokens = tokensByZone.reduce(into: [String: CKServerChangeToken]()) { partialResult, entry in
            partialResult[changeTokenStorageKey(scope: scope, zoneID: entry.key)] = entry.value
        }
        return (records, changeTokens)
    }

    private func changeTokenStorageKey(scope: SyncDatabaseScope, zoneID: CKRecordZone.ID) -> String {
        let scopeName = scope == .privateDatabase ? "private" : "shared"
        return "\(StorageKey.changeTokenPrefix)\(scopeName).\(zoneID.ownerName).\(zoneID.zoneName)"
    }

    private func loadChangeToken(forKey key: String) -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func commitChangeTokens(_ changeTokens: [String: CKServerChangeToken]) {
        for (key, token) in changeTokens {
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { continue }
            defaults.set(data, forKey: key)
        }
    }

    /// Decodes the payload blob and pairs it with the record's server-assigned
    /// modification date, which is what the merge orders conflicts by. The
    /// `deviceDate` key path names the payload's own date, kept as display
    /// metadata.
    private func decodeRecords<T: Decodable>(
        _ records: [CKRecord],
        ofType recordType: String,
        deviceDate: KeyPath<T, Date>
    ) -> [SyncRow<T>] {
        var results: [SyncRow<T>] = []
        for record in records where record.recordType == recordType {
            guard let payload = record[CloudRecordKey.payload] as? Data else { continue }
            if let decoded = try? decoder.decode(T.self, from: payload) {
                results.append(SyncRow(value: decoded, orderKey: Self.orderKey(for: record, deviceDate: decoded[keyPath: deviceDate])))
            } else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
            }
        }
        return results
    }

    /// `modificationDate` is nil only on a `CKRecord` the server has never
    /// stored, which a fetched record never is. A nil would read as an unpushed
    /// local change, so a record arriving without one is left to win, matching
    /// how the rest of the merge treats an unknown server date.
    private static func orderKey(for record: CKRecord, deviceDate: Date) -> SyncOrderKey {
        SyncOrderKey(serverDate: record.modificationDate, deviceDate: deviceDate)
    }

    private func trackedDomains(from records: [CKRecord], in scope: SyncDatabaseScope) async throws -> [SyncRow<TrackedDomain>] {
        let matching = records.filter { $0.recordType == CloudRecordType.trackedDomain }
        let shares = try await sharesByRecordID(for: matching, in: scope)

        return matching.compactMap { record in
            guard let payload = record[CloudRecordKey.payload] as? Data,
                  let decoded = try? decoder.decode(TrackedDomain.self, from: payload) else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
                return nil
            }
            var trackedDomain = CloudSyncMerge.payloadTrackedDomain(decoded)
            trackedDomain.collaboration = collaborationMetadata(for: record, share: shares[record.recordID], scope: scope)
            return SyncRow(value: trackedDomain, orderKey: Self.orderKey(for: record, deviceDate: trackedDomain.updatedAt))
        }
    }

    private func workflows(from records: [CKRecord], in scope: SyncDatabaseScope) async throws -> [SyncRow<DomainWorkflow>] {
        let matching = records.filter { $0.recordType == CloudRecordType.workflow }
        let shares = try await sharesByRecordID(for: matching, in: scope)

        return matching.compactMap { record in
            guard let payload = record[CloudRecordKey.payload] as? Data,
                  let decoded = try? decoder.decode(DomainWorkflow.self, from: payload) else {
                lastErrorMessage = "Some iCloud records were skipped because they could not be decoded."
                return nil
            }
            var workflow = CloudSyncMerge.normalizedWorkflow(decoded)
            workflow.collaboration = collaborationMetadata(for: record, share: shares[record.recordID], scope: scope)
            return SyncRow(value: workflow, orderKey: Self.orderKey(for: record, deviceDate: workflow.updatedAt))
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
            let normalized = CloudSyncMerge.normalizeDomain(domain)
            return DomainDataPortabilityService.loadTrackedDomains()
                .first(where: { CloudSyncMerge.normalizeDomain($0.domain) == normalized })?
                .collaboration?.shareRecordName
        case .workflow(let identifier):
            return DomainDataPortabilityService.loadWorkflows()
                .first(where: { $0.id == identifier })?
                .collaboration?.shareRecordName
        }
    }

    private func makeTrackedDomainRecord(_ trackedDomain: TrackedDomain) -> CKRecord {
        let normalized = CloudSyncMerge.normalizeDomain(trackedDomain.domain)
        let sanitized = CloudSyncMerge.payloadTrackedDomain(trackedDomain)
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
        let normalized = CloudSyncMerge.normalizedWorkflow(workflow)
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
            recordName: appSettingsRecordName,
            payload: settings,
            extraFields: [CloudRecordKey.updatedAt: settings.updatedAt as CKRecordValue]
        )
    }

    private func makeMonitoringSettingsRecord(_ settings: SyncedMonitoringSettings) -> CKRecord {
        makeRecord(
            type: CloudRecordType.monitoringSettings,
            recordName: monitoringSettingsRecordName,
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

    private var appSettingsRecordName: String {
        "app-settings"
    }

    private var monitoringSettingsRecordName: String {
        "monitoring-settings"
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

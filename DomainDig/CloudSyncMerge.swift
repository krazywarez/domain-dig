import Foundation

/// What a merge decision is ordered by.
///
/// Every date inside a synced payload — `updatedAt`, `deletedAt` — is minted by
/// `Date()` on whichever device wrote it. Ordering a conflict by those dates
/// means trusting both devices' clocks, so a device whose clock is skewed, or
/// one coming back from a long offline gap, won or lost arbitrarily. CloudKit
/// stamps every saved record with a server-assigned `CKRecord.modificationDate`,
/// the one date in a record no device can move, so that is the authority here.
/// The payload dates stay as display metadata.
struct SyncOrderKey: Equatable {
    /// `CKRecord.modificationDate` for a row the server has stored. Nil for a
    /// row this device has changed since its last push, which the server has
    /// therefore never seen.
    var serverDate: Date?

    /// The payload's own `updatedAt`/`deletedAt`. Only ever compared against
    /// another date from this same device.
    var deviceDate: Date

    /// True when `lhs` is strictly more recent than `rhs`.
    ///
    /// Both sides stored on the server: the server dates order them. One side
    /// unpushed: it is a change the server has never seen, so it counts as more
    /// recent than anything the server already holds — otherwise an edit made
    /// offline would be discarded by the first sync that noticed it. Neither
    /// side pushed: both dates came from this one device's clock, which is at
    /// least self-consistent, so the payload dates order them.
    static func isNewer(_ lhs: SyncOrderKey, _ rhs: SyncOrderKey) -> Bool {
        switch (lhs.serverDate, rhs.serverDate) {
        case (let lhsDate?, let rhsDate?):
            return lhsDate > rhsDate
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (nil, nil):
            return lhs.deviceDate > rhs.deviceDate
        }
    }

    /// True when `lhs` is at least as recent as `rhs`. A tie goes to `lhs`.
    static func isAtLeastAsRecent(_ lhs: SyncOrderKey, _ rhs: SyncOrderKey) -> Bool {
        !isNewer(rhs, lhs)
    }
}

/// A synced value together with the key its conflicts are decided by.
struct SyncRow<Value> {
    var value: Value
    var orderKey: SyncOrderKey
}

extension SyncRow: Equatable where Value: Equatable {}

enum SyncEntityType: String, Codable {
    case trackedDomain
    case workflow
}

struct SyncedAppSettings: Codable {
    var snapshot: AppSettingsSnapshot
    var updatedAt: Date
}

struct SyncedMonitoringSettings: Codable {
    var settings: MonitoringSettings
    var updatedAt: Date
}

struct SyncedDomainNote: Codable, Equatable {
    var domain: String
    var text: String
    var updatedAt: Date
}

struct SyncedHistoryMetadata: Codable, Equatable {
    var domain: String
    var lastKnownAvailabilityRawValue: String?
    var lastChangeMessage: String?
    var lastChangeSeverityRawValue: Int?
    var certificateWarningLevelRawValue: String
    var certificateDaysRemaining: Int?
    var lastObservedAt: Date?
    var updatedAt: Date
}

struct SyncTombstone: Codable, Equatable {
    var entityType: SyncEntityType
    var identifier: String
    var deletedAt: Date
}

/// Every conflict decision the sync makes, as functions over plain values.
///
/// `CloudSyncService` is a `@MainActor` singleton wired to `CKContainer`, so
/// nothing that lives on it can be exercised in a unit test. The decisions live
/// here instead and the service calls them.
enum CloudSyncMerge {

    /// How many tombstones the local ledger keeps.
    static let tombstoneLedgerLimit = 200

    // MARK: Rows

    static func mergeTrackedDomains(
        _ lhs: [SyncRow<TrackedDomain>],
        _ rhs: [SyncRow<TrackedDomain>]
    ) -> (domains: [SyncRow<TrackedDomain>], hadConflict: Bool) {
        var mergedByDomain: [String: SyncRow<TrackedDomain>] = [:]
        var hadConflict = false

        for row in lhs.map(sanitizedTrackedDomain) {
            let key = normalizeDomain(row.value.domain)
            guard !key.isEmpty else { continue }
            mergedByDomain[key] = row
        }

        for row in rhs.map(sanitizedTrackedDomain) {
            let key = normalizeDomain(row.value.domain)
            guard !key.isEmpty else { continue }

            if let existing = mergedByDomain[key] {
                if existing.value != row.value {
                    hadConflict = true
                }
                mergedByDomain[key] = mergedTrackedDomain(existing, row)
            } else {
                mergedByDomain[key] = row
            }
        }

        // Display order, not a merge decision: the list is newest first by the
        // date the user sees.
        let domains = mergedByDomain.values.sorted {
            if $0.value.updatedAt != $1.value.updatedAt {
                return $0.value.updatedAt > $1.value.updatedAt
            }
            return $0.value.domain.localizedCaseInsensitiveCompare($1.value.domain) == .orderedAscending
        }

        return (domains, hadConflict)
    }

    static func mergeWorkflows(
        _ lhs: [SyncRow<DomainWorkflow>],
        _ rhs: [SyncRow<DomainWorkflow>]
    ) -> (workflows: [SyncRow<DomainWorkflow>], hadConflict: Bool) {
        var merged: [UUID: SyncRow<DomainWorkflow>] = [:]
        var hadConflict = false

        for row in lhs.map(sanitizedWorkflow) {
            merged[row.value.id] = row
        }

        for row in rhs.map(sanitizedWorkflow) {
            guard let existing = merged[row.value.id] else {
                merged[row.value.id] = row
                continue
            }

            if existing.value != row.value {
                hadConflict = true
            }

            let winner = preferredWorkflow(existing, row)
            merged[row.value.id] = SyncRow(
                value: DomainWorkflow(
                    id: existing.value.id,
                    name: winner.value.name,
                    domains: deduplicated(existing.value.domains + row.value.domains),
                    createdAt: min(existing.value.createdAt, row.value.createdAt),
                    updatedAt: max(existing.value.updatedAt, row.value.updatedAt),
                    notes: winner.value.notes ?? existing.value.notes ?? row.value.notes,
                    collaboration: preferredCollaboration(existing.value.collaboration, row.value.collaboration)
                ),
                orderKey: mergedOrderKey(existing.orderKey, row.orderKey)
            )
        }

        return (
            merged.values.sorted {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt > $1.value.updatedAt
                }
                return $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending
            },
            hadConflict
        )
    }

    static func mergeNotes(
        _ lhs: [String: SyncRow<SyncedDomainNote>],
        _ rhs: [String: SyncRow<SyncedDomainNote>]
    ) -> (notesByDomain: [String: SyncRow<SyncedDomainNote>], hadConflict: Bool) {
        let result = mergeLatest(lhs, rhs)
        return (result.merged, result.hadConflict)
    }

    static func mergeHistoryMetadata(
        _ lhs: [String: SyncRow<SyncedHistoryMetadata>],
        _ rhs: [String: SyncRow<SyncedHistoryMetadata>]
    ) -> (historyMetadataByDomain: [String: SyncRow<SyncedHistoryMetadata>], hadConflict: Bool) {
        let result = mergeLatest(lhs, rhs)
        return (result.merged, result.hadConflict)
    }

    /// `rhs` merged over `lhs` by domain; where both differ, the more recent
    /// one wins (`lhs` on a tie) and the merge reports a conflict.
    static func mergeLatest<Value: Equatable>(
        _ lhs: [String: SyncRow<Value>],
        _ rhs: [String: SyncRow<Value>]
    ) -> (merged: [String: SyncRow<Value>], hadConflict: Bool) {
        var merged = lhs
        var hadConflict = false

        for (domain, remote) in rhs {
            if let local = merged[domain], local.value != remote.value {
                hadConflict = true
                merged[domain] = SyncOrderKey.isAtLeastAsRecent(local.orderKey, remote.orderKey) ? local : remote
            } else {
                merged[domain] = remote
            }
        }

        return (merged, hadConflict)
    }

    // MARK: Settings

    static func mergeAppSettings(
        _ lhs: SyncRow<SyncedAppSettings>,
        _ rhs: SyncRow<SyncedAppSettings>
    ) -> (settings: SyncedAppSettings, hadConflict: Bool) {
        let lhsWins = SyncOrderKey.isAtLeastAsRecent(lhs.orderKey, rhs.orderKey)
        let winner = lhsWins ? lhs.value : rhs.value
        let loser = lhsWins ? rhs.value : lhs.value

        let merged = SyncedAppSettings(
            snapshot: AppSettingsSnapshot(
                recentSearches: deduplicated(winner.snapshot.recentSearches + loser.snapshot.recentSearches).prefix(20).map { $0 },
                savedDomains: deduplicated(winner.snapshot.savedDomains + loser.snapshot.savedDomains),
                resolverURLString: winner.snapshot.resolverURLString,
                appDensityRawValue: winner.snapshot.appDensityRawValue
            ),
            updatedAt: max(lhs.value.updatedAt, rhs.value.updatedAt)
        )

        return (merged, !sameAppSettings(lhs.value.snapshot, rhs.value.snapshot) || lhs.value.updatedAt != rhs.value.updatedAt)
    }

    static func mergeMonitoringSettings(
        _ lhs: SyncRow<SyncedMonitoringSettings>,
        _ rhs: SyncRow<SyncedMonitoringSettings>,
        localActivationConfirmed: Bool
    ) -> (settings: SyncedMonitoringSettings, hadConflict: Bool) {
        var merged = SyncOrderKey.isAtLeastAsRecent(lhs.orderKey, rhs.orderKey) ? lhs.value : rhs.value

        if merged.settings.isEnabled && !localActivationConfirmed {
            merged.settings.isEnabled = false
        }

        if merged.settings.alertsEnabled {
            merged.settings.alertsEnabled = false
        }

        merged.updatedAt = max(lhs.value.updatedAt, rhs.value.updatedAt)
        return (merged, lhs.value.settings != rhs.value.settings || lhs.value.updatedAt != rhs.value.updatedAt)
    }

    // MARK: Tombstones

    /// One tombstone per entity, the most recent kept, most recent first.
    static func latestTombstones(_ tombstones: [SyncRow<SyncTombstone>]) -> [SyncRow<SyncTombstone>] {
        var latest: [String: SyncRow<SyncTombstone>] = [:]

        for row in tombstones {
            let key = "\(row.value.entityType.rawValue):\(row.value.identifier)"
            if let existing = latest[key] {
                latest[key] = SyncOrderKey.isAtLeastAsRecent(existing.orderKey, row.orderKey) ? existing : row
            } else {
                latest[key] = row
            }
        }

        return latest.values.sorted { SyncOrderKey.isNewer($0.orderKey, $1.orderKey) }
    }

    /// The ledger is capped so it cannot grow without bound. Deduplicating and
    /// sorting first means the cap drops the oldest deletions rather than
    /// whichever ones happened to be encountered last.
    static func newestTombstones(
        _ tombstones: [SyncRow<SyncTombstone>],
        limit: Int = tombstoneLedgerLimit
    ) -> [SyncRow<SyncTombstone>] {
        Array(latestTombstones(tombstones).prefix(limit))
    }

    /// Drops a row whose deletion is at least as recent as the row itself.
    ///
    /// Equal authority dates keep the row deleted. The two can only tie when
    /// the server stamped both in the same instant, and of the two possible
    /// mistakes, resurrecting a row the user deleted is the worse one.
    static func applyTrackedDomainTombstones(
        _ rows: [SyncRow<TrackedDomain>],
        tombstones: [SyncRow<SyncTombstone>]
    ) -> [SyncRow<TrackedDomain>] {
        let tombstonesByDomain = tombstonesByIdentifier(tombstones, entityType: .trackedDomain)

        return rows.filter { row in
            guard let tombstone = tombstonesByDomain[normalizeDomain(row.value.domain)] else { return true }
            return SyncOrderKey.isNewer(row.orderKey, tombstone.orderKey)
        }
    }

    static func applyWorkflowTombstones(
        _ rows: [SyncRow<DomainWorkflow>],
        tombstones: [SyncRow<SyncTombstone>]
    ) -> [SyncRow<DomainWorkflow>] {
        let tombstonesByIdentifier = tombstonesByIdentifier(tombstones, entityType: .workflow)

        return rows.filter { row in
            guard let tombstone = tombstonesByIdentifier[row.value.id.uuidString] else { return true }
            return SyncOrderKey.isNewer(row.orderKey, tombstone.orderKey)
        }
    }

    static func applyNotes(
        _ notesByDomain: [String: SyncRow<SyncedDomainNote>],
        to rows: [SyncRow<TrackedDomain>],
        tombstones: [SyncRow<SyncTombstone>]
    ) -> [SyncRow<TrackedDomain>] {
        let tombstonesByDomain = tombstonesByIdentifier(tombstones, entityType: .trackedDomain)

        return rows.map { row in
            guard row.value.collaboration?.scope != .sharedDatabase else { return row }
            let normalized = normalizeDomain(row.value.domain)
            guard let note = notesByDomain[normalized] else { return row }
            if let tombstone = tombstonesByDomain[normalized],
               SyncOrderKey.isAtLeastAsRecent(tombstone.orderKey, note.orderKey) {
                return row
            }

            var updated = row
            updated.value.note = emptyToNil(note.value.text)
            return updated
        }
    }

    static func applyHistoryMetadata(
        _ historyMetadataByDomain: [String: SyncRow<SyncedHistoryMetadata>],
        to rows: [SyncRow<TrackedDomain>],
        tombstones: [SyncRow<SyncTombstone>]
    ) -> [SyncRow<TrackedDomain>] {
        let tombstonesByDomain = tombstonesByIdentifier(tombstones, entityType: .trackedDomain)

        return rows.map { row in
            guard row.value.collaboration?.scope != .sharedDatabase else { return row }
            let normalized = normalizeDomain(row.value.domain)
            guard let metadataRow = historyMetadataByDomain[normalized] else { return row }
            if let tombstone = tombstonesByDomain[normalized],
               SyncOrderKey.isAtLeastAsRecent(tombstone.orderKey, metadataRow.orderKey) {
                return row
            }

            let metadata = metadataRow.value
            var updated = row
            updated.value.lastKnownAvailability = metadata.lastKnownAvailabilityRawValue.flatMap(DomainAvailabilityStatus.init(rawValue:))
            updated.value.lastChangeSeverity = metadata.lastChangeSeverityRawValue.flatMap(ChangeSeverity.init(rawValue:))
            updated.value.certificateWarningLevel = CertificateWarningLevel(rawValue: metadata.certificateWarningLevelRawValue) ?? .none
            updated.value.certificateDaysRemaining = metadata.certificateDaysRemaining

            if let message = metadata.lastChangeMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                updated.value.lastChangeSummary = DomainChangeSummary(
                    hasChanges: true,
                    changedSections: [],
                    message: message,
                    severity: updated.value.lastChangeSeverity ?? .medium,
                    impactClassification: .warning,
                    generatedAt: metadata.lastObservedAt ?? metadata.updatedAt
                )
            }

            return updated
        }
    }

    // MARK: Normalizing

    static func normalizeDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }

    static func payloadTrackedDomain(_ trackedDomain: TrackedDomain) -> TrackedDomain {
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
            collaboration: trackedDomain.collaboration,
            tags: trackedDomain.tags
        )
    }

    static func normalizedWorkflow(_ workflow: DomainWorkflow) -> DomainWorkflow {
        DomainWorkflow(
            id: workflow.id,
            name: workflow.name.trimmingCharacters(in: .whitespacesAndNewlines),
            domains: deduplicated(workflow.domains.map(normalizeDomain).filter { !$0.isEmpty }),
            createdAt: workflow.createdAt,
            updatedAt: workflow.updatedAt,
            notes: emptyToNil(workflow.notes ?? ""),
            collaboration: workflow.collaboration
        )
    }

    static func sameAppSettings(_ lhs: AppSettingsSnapshot, _ rhs: AppSettingsSnapshot) -> Bool {
        lhs.recentSearches == rhs.recentSearches
            && lhs.savedDomains == rhs.savedDomains
            && lhs.resolverURLString == rhs.resolverURLString
            && lhs.appDensityRawValue == rhs.appDensityRawValue
    }

    // MARK: Field-level merges

    private static func sanitizedTrackedDomain(_ row: SyncRow<TrackedDomain>) -> SyncRow<TrackedDomain> {
        SyncRow(value: payloadTrackedDomain(row.value), orderKey: row.orderKey)
    }

    private static func sanitizedWorkflow(_ row: SyncRow<DomainWorkflow>) -> SyncRow<DomainWorkflow> {
        SyncRow(value: normalizedWorkflow(row.value), orderKey: row.orderKey)
    }

    private static func mergedTrackedDomain(
        _ lhs: SyncRow<TrackedDomain>,
        _ rhs: SyncRow<TrackedDomain>
    ) -> SyncRow<TrackedDomain> {
        let winner = preferredTrackedDomain(lhs, rhs).value

        return SyncRow(
            value: TrackedDomain(
                id: lhs.value.id,
                domain: normalizeDomain(lhs.value.domain.isEmpty ? rhs.value.domain : lhs.value.domain),
                createdAt: min(lhs.value.createdAt, rhs.value.createdAt),
                updatedAt: max(lhs.value.updatedAt, rhs.value.updatedAt),
                note: winner.note ?? lhs.value.note ?? rhs.value.note,
                isPinned: winner.isPinned,
                monitoringEnabled: winner.monitoringEnabled,
                lastKnownAvailability: winner.lastKnownAvailability ?? lhs.value.lastKnownAvailability ?? rhs.value.lastKnownAvailability,
                lastSnapshotID: nil,
                lastChangeSummary: nil,
                lastChangeSeverity: winner.lastChangeSeverity ?? lhs.value.lastChangeSeverity ?? rhs.value.lastChangeSeverity,
                certificateWarningLevel: higherCertificateWarningLevel(lhs.value.certificateWarningLevel, rhs.value.certificateWarningLevel),
                certificateDaysRemaining: winner.certificateDaysRemaining ?? lhs.value.certificateDaysRemaining ?? rhs.value.certificateDaysRemaining,
                lastMonitoredAt: [lhs.value.lastMonitoredAt, rhs.value.lastMonitoredAt].compactMap { $0 }.max(),
                lastAlertAt: [lhs.value.lastAlertAt, rhs.value.lastAlertAt].compactMap { $0 }.max(),
                monitoringState: preferredMonitoringState(lhs.value.monitoringState, rhs.value.monitoringState),
                pendingMonitoringAlerts: deduplicatedPendingAlerts(lhs.value.pendingMonitoringAlerts + rhs.value.pendingMonitoringAlerts),
                collaboration: preferredCollaboration(lhs.value.collaboration, rhs.value.collaboration),
                tags: firstNonEmpty(winner.tags, lhs.value.tags, rhs.value.tags)
            ),
            orderKey: mergedOrderKey(lhs.orderKey, rhs.orderKey)
        )
    }

    /// A merged row holds both sides' changes, so it carries the more recent of
    /// the two keys — including when a collaboration rank, not a date, decided
    /// which side's scalar fields won.
    static func mergedOrderKey(_ lhs: SyncOrderKey, _ rhs: SyncOrderKey) -> SyncOrderKey {
        SyncOrderKey.isAtLeastAsRecent(lhs, rhs) ? lhs : rhs
    }

    /// Records written before tags were carried decode with none at all, so an
    /// empty list means "this side has nothing to say" rather than "cleared".
    /// Without the fallback the first sync after the fix would still drop them.
    private static func firstNonEmpty(_ candidates: [String]...) -> [String] {
        candidates.first { !$0.isEmpty } ?? []
    }

    private static func preferredTrackedDomain(
        _ lhs: SyncRow<TrackedDomain>,
        _ rhs: SyncRow<TrackedDomain>
    ) -> SyncRow<TrackedDomain> {
        let lhsRank = collaborationRank(lhs.value.collaboration)
        let rhsRank = collaborationRank(rhs.value.collaboration)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank ? lhs : rhs
        }
        return SyncOrderKey.isAtLeastAsRecent(lhs.orderKey, rhs.orderKey) ? lhs : rhs
    }

    private static func preferredWorkflow(
        _ lhs: SyncRow<DomainWorkflow>,
        _ rhs: SyncRow<DomainWorkflow>
    ) -> SyncRow<DomainWorkflow> {
        let lhsRank = collaborationRank(lhs.value.collaboration)
        let rhsRank = collaborationRank(rhs.value.collaboration)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank ? lhs : rhs
        }
        return SyncOrderKey.isAtLeastAsRecent(lhs.orderKey, rhs.orderKey) ? lhs : rhs
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

    private static func preferredCollaboration(
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

    private static func collaborationRank(_ collaboration: CollaborationMetadata?) -> Int {
        guard let collaboration else { return 0 }
        switch collaboration.ownership {
        case .owner:
            return collaboration.isShared ? 3 : 2
        case .participant:
            return collaboration.permission == .editable ? 1 : 0
        }
    }

    private static func tombstonesByIdentifier(
        _ tombstones: [SyncRow<SyncTombstone>],
        entityType: SyncEntityType
    ) -> [String: SyncRow<SyncTombstone>] {
        var result: [String: SyncRow<SyncTombstone>] = [:]
        for row in tombstones where row.value.entityType == entityType {
            result[row.value.identifier] = row
        }
        return result
    }

    private static func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func higherCertificateWarningLevel(
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
}

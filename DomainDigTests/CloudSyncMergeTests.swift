import XCTest
@testable import DomainDig

/// Sync conflicts used to be decided by `updatedAt` and `deletedAt`, both minted
/// by `Date()` on the writing device, so the winner depended on whose clock was
/// right. These pin the replacement: CloudKit's server-assigned
/// `CKRecord.modificationDate` decides, and the payload dates are only display
/// metadata. `CloudSyncService` itself cannot be built in a test — it is a
/// `@MainActor` singleton wired to `CKContainer.default()` — so the decisions
/// are tested where they live, in `CloudSyncMerge`.
final class CloudSyncMergeTests: XCTestCase {

    // MARK: Row versus row

    func testNewerServerDateWinsTheScalarFields() {
        let local = trackedDomainRow("example.com", isPinned: false, serverDate: at(100), deviceDate: at(100))
        let remote = trackedDomainRow("example.com", isPinned: true, serverDate: at(200), deviceDate: at(200))

        let merged = CloudSyncMerge.mergeTrackedDomains([local], [remote])

        XCTAssertEqual(merged.domains.count, 1)
        XCTAssertEqual(merged.domains.first?.value.isPinned, true)
        XCTAssertTrue(merged.hadConflict)
    }

    func testNewerServerDateWinsInTheOtherArgumentOrder() {
        let older = trackedDomainRow("example.com", isPinned: false, serverDate: at(100), deviceDate: at(100))
        let newer = trackedDomainRow("example.com", isPinned: true, serverDate: at(200), deviceDate: at(200))

        let merged = CloudSyncMerge.mergeTrackedDomains([newer], [older])

        XCTAssertEqual(merged.domains.first?.value.isPinned, true)
    }

    /// The regression this whole change exists for: a device whose clock runs
    /// days fast stamps `updatedAt` in the future, and under the old rule that
    /// made it win every conflict it took part in. The server date it was
    /// actually saved at is older, so it loses.
    func testRemoteRowWithASkewedClockLosesToAnOlderDeviceDateWithANewerServerDate() {
        let local = trackedDomainRow("example.com", isPinned: false, serverDate: at(200), deviceDate: at(100))
        let skewedRemote = trackedDomainRow("example.com", isPinned: true, serverDate: at(100), deviceDate: at(99_999))

        let merged = CloudSyncMerge.mergeTrackedDomains([local], [skewedRemote])

        XCTAssertEqual(merged.domains.first?.value.isPinned, false)
    }

    /// A row this device has edited since its last push has no server date at
    /// all. Treating that as older would throw away every edit made offline, so
    /// it counts as the more recent of the two.
    func testUnpushedLocalRowBeatsARowTheServerHasStored() {
        let unpushedLocal = trackedDomainRow("example.com", isPinned: true, serverDate: nil, deviceDate: at(100))
        let remote = trackedDomainRow("example.com", isPinned: false, serverDate: at(99_999), deviceDate: at(99_999))

        let merged = CloudSyncMerge.mergeTrackedDomains([unpushedLocal], [remote])

        XCTAssertEqual(merged.domains.first?.value.isPinned, true)
    }

    // MARK: Deletes

    func testARowReAddedAfterItsDeletionSurvives() {
        let readded = trackedDomainRow("example.com", serverDate: at(200), deviceDate: at(200))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(100), deviceDate: at(100))

        let surviving = CloudSyncMerge.applyTrackedDomainTombstones([readded], tombstones: [tombstone])

        XCTAssertEqual(surviving.map(\.value.domain), ["example.com"])
    }

    func testARowDeletedAfterItWasReAddedStaysDeleted() {
        let readded = trackedDomainRow("example.com", serverDate: at(100), deviceDate: at(100))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(200), deviceDate: at(200))

        let surviving = CloudSyncMerge.applyTrackedDomainTombstones([readded], tombstones: [tombstone])

        XCTAssertTrue(surviving.isEmpty)
    }

    /// Both sides stamped in the same server instant. The tie goes to the
    /// tombstone: of the two mistakes available, resurrecting a row the user
    /// deleted is worse than dropping a re-add they can make again.
    func testATombstoneWinsATieWithTheRow() {
        let row = trackedDomainRow("example.com", serverDate: at(100), deviceDate: at(100))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(100), deviceDate: at(100))

        XCTAssertTrue(CloudSyncMerge.applyTrackedDomainTombstones([row], tombstones: [tombstone]).isEmpty)
    }

    /// A deletion recorded on this device and not yet pushed has no server
    /// date, so it outranks the copy of the row the server still holds —
    /// otherwise every sync would hand the deleted row straight back.
    func testAnUnpushedDeletionBeatsARowTheServerStillHolds() {
        let row = trackedDomainRow("example.com", serverDate: at(99_999), deviceDate: at(99_999))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: nil, deviceDate: at(100))

        XCTAssertTrue(CloudSyncMerge.applyTrackedDomainTombstones([row], tombstones: [tombstone]).isEmpty)
    }

    func testWorkflowDeletesFollowTheSameRule() {
        let identifier = UUID()
        let workflow = workflowRow(identifier, serverDate: at(200), deviceDate: at(200))
        let staleTombstone = tombstoneRow(.workflow, identifier.uuidString, serverDate: at(100), deviceDate: at(100))
        let freshTombstone = tombstoneRow(.workflow, identifier.uuidString, serverDate: at(300), deviceDate: at(300))

        XCTAssertEqual(CloudSyncMerge.applyWorkflowTombstones([workflow], tombstones: [staleTombstone]).count, 1)
        XCTAssertTrue(CloudSyncMerge.applyWorkflowTombstones([workflow], tombstones: [freshTombstone]).isEmpty)
    }

    // MARK: The tombstone ledger

    func testLatestTombstonesKeepsTheNewestPerIdentifier() {
        let older = tombstoneRow(.trackedDomain, "example.com", serverDate: at(100), deviceDate: at(100))
        let newer = tombstoneRow(.trackedDomain, "example.com", serverDate: at(200), deviceDate: at(200))

        let latest = CloudSyncMerge.latestTombstones([newer, older])

        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest.first?.value.deletedAt, at(200))
    }

    func testLatestTombstonesKeepsOneEntryPerEntityType() {
        let domain = tombstoneRow(.trackedDomain, "shared-identifier", serverDate: at(100), deviceDate: at(100))
        let workflow = tombstoneRow(.workflow, "shared-identifier", serverDate: at(100), deviceDate: at(100))

        XCTAssertEqual(CloudSyncMerge.latestTombstones([domain, workflow]).count, 2)
    }

    /// The cap drops the oldest deletions. Taking the first 200 encountered
    /// instead would let a long ledger push out the deletions that still
    /// matter and resurrect those rows.
    func testTheLedgerCapKeepsTheNewestTombstones() {
        let tombstones = (0..<250).map { index in
            tombstoneRow(
                .trackedDomain,
                "domain-\(index).com",
                serverDate: at(Double(index)),
                deviceDate: at(Double(index))
            )
        }

        let kept = CloudSyncMerge.newestTombstones(tombstones)

        XCTAssertEqual(kept.count, CloudSyncMerge.tombstoneLedgerLimit)
        XCTAssertEqual(kept.first?.value.identifier, "domain-249.com")
        XCTAssertEqual(kept.last?.value.identifier, "domain-50.com")
        XCTAssertFalse(kept.contains { $0.value.identifier == "domain-0.com" })
    }

    // MARK: Notes and history metadata

    func testNotesFollowTheServerDate() {
        let local = noteRow("example.com", text: "local", serverDate: at(200), deviceDate: at(100))
        let skewedRemote = noteRow("example.com", text: "remote", serverDate: at(100), deviceDate: at(99_999))

        let merged = CloudSyncMerge.mergeNotes(["example.com": local], ["example.com": skewedRemote])

        XCTAssertEqual(merged.notesByDomain["example.com"]?.value.text, "local")
        XCTAssertTrue(merged.hadConflict)
    }

    func testANoteOlderThanTheDeletionIsNotWrittenBackOntoTheRow() {
        let row = trackedDomainRow("example.com", note: nil, serverDate: at(300), deviceDate: at(300))
        let note = noteRow("example.com", text: "stale", serverDate: at(100), deviceDate: at(100))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(200), deviceDate: at(200))

        let updated = CloudSyncMerge.applyNotes(["example.com": note], to: [row], tombstones: [tombstone])

        XCTAssertNil(updated.first?.value.note)
    }

    func testANoteNewerThanTheDeletionIsWrittenBackOntoTheRow() {
        let row = trackedDomainRow("example.com", note: nil, serverDate: at(300), deviceDate: at(300))
        let note = noteRow("example.com", text: "kept", serverDate: at(300), deviceDate: at(100))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(200), deviceDate: at(200))

        let updated = CloudSyncMerge.applyNotes(["example.com": note], to: [row], tombstones: [tombstone])

        XCTAssertEqual(updated.first?.value.note, "kept")
    }

    func testHistoryMetadataFollowsTheServerDate() {
        let local = historyMetadataRow("example.com", availability: .registered, serverDate: at(200), deviceDate: at(100))
        let skewedRemote = historyMetadataRow("example.com", availability: .available, serverDate: at(100), deviceDate: at(99_999))

        let merged = CloudSyncMerge.mergeHistoryMetadata(["example.com": local], ["example.com": skewedRemote])

        XCTAssertEqual(merged.historyMetadataByDomain["example.com"]?.value.lastKnownAvailabilityRawValue, DomainAvailabilityStatus.registered.rawValue)
    }

    func testHistoryMetadataOlderThanTheDeletionIsNotApplied() {
        let row = trackedDomainRow("example.com", serverDate: at(300), deviceDate: at(300))
        let metadata = historyMetadataRow("example.com", availability: .available, serverDate: at(100), deviceDate: at(100))
        let tombstone = tombstoneRow(.trackedDomain, "example.com", serverDate: at(200), deviceDate: at(200))

        let updated = CloudSyncMerge.applyHistoryMetadata(["example.com": metadata], to: [row], tombstones: [tombstone])

        XCTAssertNil(updated.first?.value.lastKnownAvailability)
    }

    // MARK: Tombstone retention

    /// The window is what stops the zone growing without bound. A tombstone
    /// older than it is deleted from the zone; everything newer stays, because
    /// forgetting a deletion resurrects the row.
    func testATombstoneOlderThanTheWindowExpires() {
        let now = at(0)
        let old = tombstoneRow(.trackedDomain, "old.example", serverDate: now.addingTimeInterval(-400 * 86_400), deviceDate: now.addingTimeInterval(-400 * 86_400))
        let recent = tombstoneRow(.trackedDomain, "recent.example", serverDate: now.addingTimeInterval(-10 * 86_400), deviceDate: now.addingTimeInterval(-10 * 86_400))

        let partitioned = CloudSyncMerge.partitionedTombstones([old, recent], now: now)

        XCTAssertEqual(partitioned.kept.map(\.value.identifier), ["recent.example"])
        XCTAssertEqual(partitioned.expired.map(\.value.identifier), ["old.example"])
    }

    /// A tombstone exactly on the boundary is kept. Of the two mistakes
    /// available, resurrecting a row the user deleted is the worse one — the
    /// same tie-break `applyTrackedDomainTombstones` makes.
    func testATombstoneExactlyOnTheBoundaryIsKept() {
        let now = at(0)
        let boundary = tombstoneRow(
            .trackedDomain,
            "boundary.example",
            serverDate: now.addingTimeInterval(-CloudSyncMerge.tombstoneRetention),
            deviceDate: now.addingTimeInterval(-CloudSyncMerge.tombstoneRetention)
        )

        let partitioned = CloudSyncMerge.partitionedTombstones([boundary], now: now)

        XCTAssertEqual(partitioned.kept.map(\.value.identifier), ["boundary.example"])
        XCTAssertTrue(partitioned.expired.isEmpty)
    }

    /// Workflows carry tombstones too, and the window applies to the record
    /// regardless of what it refers to.
    func testTheWindowAppliesToWorkflowTombstones() {
        let now = at(0)
        let old = tombstoneRow(.workflow, "flow-1", serverDate: now.addingTimeInterval(-400 * 86_400), deviceDate: now.addingTimeInterval(-400 * 86_400))

        XCTAssertEqual(
            CloudSyncMerge.partitionedTombstones([old], now: now).expired.map(\.value.identifier),
            ["flow-1"]
        )
    }

    /// Nothing is dropped on a device that has only ever deleted rows
    /// recently, which is the common case and must stay free of churn.
    func testRecentDeletionsAreAllKept() {
        let now = at(0)
        let rows = (1...5).map { index in
            tombstoneRow(
                .trackedDomain,
                "row-\(index).example",
                serverDate: now.addingTimeInterval(-Double(index) * 86_400),
                deviceDate: now.addingTimeInterval(-Double(index) * 86_400)
            )
        }

        let partitioned = CloudSyncMerge.partitionedTombstones(rows, now: now)

        XCTAssertEqual(partitioned.kept.count, 5)
        XCTAssertTrue(partitioned.expired.isEmpty)
    }

    /// The deletion is still only on this device, so ageing it out would throw
    /// away the deletion rather than a record of one — and the row would come
    /// back from another device on the next sync.
    func testADeletionTheServerHasNeverSeenNeverExpires() {
        let now = at(0)
        let unpushed = tombstoneRow(
            .trackedDomain,
            "offline.example",
            serverDate: nil,
            deviceDate: now.addingTimeInterval(-4_000 * 86_400)
        )

        let partitioned = CloudSyncMerge.partitionedTombstones([unpushed], now: now)

        XCTAssertEqual(partitioned.kept.map(\.value.identifier), ["offline.example"])
        XCTAssertTrue(partitioned.expired.isEmpty)
    }

    /// A year, stated as a test so a change to the constant is a deliberate
    /// one rather than a silent shortening of everyone's safe offline window.
    func testTheRetentionWindowIsAYear() {
        XCTAssertEqual(CloudSyncMerge.tombstoneRetention, 365 * 24 * 60 * 60)
    }

    // MARK: Fixtures

    private func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    // MARK: Tags

    /// `payloadTrackedDomain` rebuilds the row field by field, and every field
    /// it forgets is written back to the local store by `applyMergedPayload`.
    /// It used to forget `tags`, so one sync emptied every tracked domain's
    /// tags and the watchlist's tag filter with them.
    func testTagsSurviveThePayloadSanitizer() {
        let trackedDomain = TrackedDomain(
            domain: "example.com",
            createdAt: at(0),
            updatedAt: at(100),
            tags: ["client-a", "production"]
        )

        let sanitized = CloudSyncMerge.payloadTrackedDomain(trackedDomain)

        XCTAssertEqual(sanitized.tags, ["client-a", "production"])
    }

    func testTagsSurviveAMerge() {
        let local = trackedDomainRow("example.com", tags: ["client-a"], serverDate: at(100), deviceDate: at(100))
        let remote = trackedDomainRow("example.com", tags: ["client-b"], serverDate: at(200), deviceDate: at(200))

        let merged = CloudSyncMerge.mergeTrackedDomains([local], [remote])

        XCTAssertEqual(merged.domains.first?.value.tags, ["client-b"])
    }

    /// Records written before tags were carried decode with none at all, so an
    /// empty list means "this side has nothing to say", not "cleared".
    /// Otherwise the first sync after the fix would still drop them.
    func testTagsFallBackWhenTheWinningSideHasNone() {
        let local = trackedDomainRow("example.com", tags: ["client-a"], serverDate: at(100), deviceDate: at(100))
        let legacyRemote = trackedDomainRow("example.com", tags: [], serverDate: at(200), deviceDate: at(200))

        let merged = CloudSyncMerge.mergeTrackedDomains([local], [legacyRemote])

        XCTAssertEqual(merged.domains.first?.value.tags, ["client-a"])
    }

    private func trackedDomainRow(
        _ domain: String,
        note: String? = nil,
        isPinned: Bool = false,
        tags: [String] = [],
        serverDate: Date?,
        deviceDate: Date
    ) -> SyncRow<TrackedDomain> {
        SyncRow(
            value: TrackedDomain(
                domain: domain,
                createdAt: at(0),
                updatedAt: deviceDate,
                note: note,
                isPinned: isPinned,
                tags: tags
            ),
            orderKey: SyncOrderKey(serverDate: serverDate, deviceDate: deviceDate)
        )
    }

    private func workflowRow(_ identifier: UUID, serverDate: Date?, deviceDate: Date) -> SyncRow<DomainWorkflow> {
        SyncRow(
            value: DomainWorkflow(
                id: identifier,
                name: "Workflow",
                domains: ["example.com"],
                createdAt: at(0),
                updatedAt: deviceDate
            ),
            orderKey: SyncOrderKey(serverDate: serverDate, deviceDate: deviceDate)
        )
    }

    private func tombstoneRow(
        _ entityType: SyncEntityType,
        _ identifier: String,
        serverDate: Date?,
        deviceDate: Date
    ) -> SyncRow<SyncTombstone> {
        SyncRow(
            value: SyncTombstone(entityType: entityType, identifier: identifier, deletedAt: deviceDate),
            orderKey: SyncOrderKey(serverDate: serverDate, deviceDate: deviceDate)
        )
    }

    private func noteRow(_ domain: String, text: String, serverDate: Date?, deviceDate: Date) -> SyncRow<SyncedDomainNote> {
        SyncRow(
            value: SyncedDomainNote(domain: domain, text: text, updatedAt: deviceDate),
            orderKey: SyncOrderKey(serverDate: serverDate, deviceDate: deviceDate)
        )
    }

    private func historyMetadataRow(
        _ domain: String,
        availability: DomainAvailabilityStatus,
        serverDate: Date?,
        deviceDate: Date
    ) -> SyncRow<SyncedHistoryMetadata> {
        SyncRow(
            value: SyncedHistoryMetadata(
                domain: domain,
                lastKnownAvailabilityRawValue: availability.rawValue,
                lastChangeMessage: nil,
                lastChangeSeverityRawValue: nil,
                certificateWarningLevelRawValue: CertificateWarningLevel.none.rawValue,
                certificateDaysRemaining: nil,
                lastObservedAt: deviceDate,
                updatedAt: deviceDate
            ),
            orderKey: SyncOrderKey(serverDate: serverDate, deviceDate: deviceDate)
        )
    }
}

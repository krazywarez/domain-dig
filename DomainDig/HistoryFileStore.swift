import Foundation

/// One row of the history index: the fields the list, the filters and the
/// sorts read, without the snapshot behind them.
///
/// `filteredHistory` searches on `domain`, filters on `timestamp` and
/// `changeSummary`, and sorts on those plus `changeCount` — so a reader that
/// only lists history never needs the DNS sections, headers, subdomain lists
/// or timelines that make up almost all of an entry's bytes.
struct HistoryIndexRow: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let domain: String
    let timestamp: Date
    var trackedDomainID: UUID?
    var note: String?
    var snapshotIndex: Int?
    var changeCount: Int
    var severitySummary: ChangeSeverity?
    var hasChanges: Bool
    var availabilityStatus: DomainAvailabilityStatus?
    var resultSource: LookupResultSource

    nonisolated init(entry: HistoryEntry) {
        id = entry.id
        domain = entry.domain
        timestamp = entry.timestamp
        trackedDomainID = entry.trackedDomainID
        note = entry.note
        snapshotIndex = entry.snapshotIndex
        changeCount = entry.changeCount
        severitySummary = entry.severitySummary
        hasChanges = entry.changeSummary?.hasChanges ?? false
        availabilityStatus = entry.availabilityResult?.status
        resultSource = entry.resultSource
    }
}

/// History on disk: one JSON file per snapshot plus an index, under D3's
/// "files plus an index, keep a cap, no dependency" decision.
///
/// The substrate it replaces kept every snapshot in one `UserDefaults` key and
/// rewrote the whole blob on every save. Measured at the Pro+ cap of 2000 rows
/// that was 6,564 KiB, 214 ms to save and 209 ms to load, with the save on the
/// main actor after every lookup (A1). Per-entry files make a single-snapshot
/// write independent of how many snapshots exist, and the index makes listing
/// independent of their contents.
///
/// `UserDefaults` is still the home for the small stores — tracked domains,
/// workflows, settings. Only history is large enough to be worth a directory.
enum HistoryFileStore {

    /// Injected so tests get a scratch directory instead of the real one, the
    /// same way `defaults:` threads the store through the view model.
    nonisolated struct Location: Sendable {
        let root: URL

        static let `default` = Location(
            root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("History", isDirectory: true)
        )

        var indexFile: URL { root.appendingPathComponent("index.json", isDirectory: false) }
        var entriesDirectory: URL { root.appendingPathComponent("entries", isDirectory: true) }

        func entryFile(id: UUID) -> URL {
            entriesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
        }
    }

    // MARK: Reading

    /// The index alone. This is what a list view wants.
    static func loadIndex(at location: Location = .default) -> [HistoryIndexRow] {
        guard let data = try? Data(contentsOf: location.indexFile),
              let rows = try? decoder().decode([HistoryIndexRow].self, from: data)
        else { return [] }
        return sorted(rows)
    }

    static func loadEntry(id: UUID, at location: Location = .default) -> HistoryEntry? {
        guard let data = try? Data(contentsOf: location.entryFile(id: id)) else { return nil }
        return try? decoder().decode(HistoryEntry.self, from: data)
    }

    /// Every snapshot in full. Backup, export and the migration need this; the
    /// UI does not, and asking for it at the Pro+ cap reads 2000 files.
    static func loadAllEntries(at location: Location = .default) -> [HistoryEntry] {
        let rows = loadIndex(at: location)
        guard !rows.isEmpty else { return [] }
        return rows.compactMap { loadEntry(id: $0.id, at: location) }
    }

    // MARK: Writing

    /// Appends one snapshot: one file written, one index rewritten. The cost
    /// does not depend on how many snapshots are already stored, which is the
    /// whole reason for the directory. A `replaceAll` of the same array costs
    /// an encode of every row instead.
    static func append(_ entry: HistoryEntry, cap: Int, at location: Location = .default) {
        guard ensureDirectories(at: location), write(entry, at: location) else { return }

        var rows = loadIndex(at: location).filter { $0.id != entry.id }
        rows.append(HistoryIndexRow(entry: entry))
        rows = sorted(rows)

        let kept = Array(rows.prefix(cap))
        for dropped in rows.dropFirst(cap) {
            try? FileManager.default.removeItem(at: location.entryFile(id: dropped.id))
        }
        writeIndex(kept, at: location)
    }

    /// Replaces one snapshot in place, for a note edit or a re-linked tracked
    /// domain. Same cost as an append.
    static func update(_ entry: HistoryEntry, at location: Location = .default) {
        guard ensureDirectories(at: location), write(entry, at: location) else { return }

        let rows = loadIndex(at: location).map { $0.id == entry.id ? HistoryIndexRow(entry: entry) : $0 }
        writeIndex(sorted(rows), at: location)
    }

    static func remove(ids: Set<UUID>, at location: Location = .default) {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? FileManager.default.removeItem(at: location.entryFile(id: id))
        }
        writeIndex(loadIndex(at: location).filter { !ids.contains($0.id) }, at: location)
    }

    /// Writes the store from scratch. For the migration off `UserDefaults`, a
    /// backup import and a prune — the cases that really do change every row.
    /// Everything else should use `append` or `update`.
    static func replaceAll(with entries: [HistoryEntry], cap: Int, at location: Location = .default) {
        guard ensureDirectories(at: location) else { return }

        let rows = Array(sorted(entries.map(HistoryIndexRow.init(entry:))).prefix(cap))
        let keptIDs = Set(rows.map(\.id))
        var byID: [UUID: HistoryEntry] = [:]
        for entry in entries where keptIDs.contains(entry.id) {
            byID[entry.id] = entry
        }

        for id in keptIDs {
            guard let entry = byID[id] else { continue }
            _ = write(entry, at: location)
        }
        for stale in onDiskEntryIDs(at: location).subtracting(keptIDs) {
            try? FileManager.default.removeItem(at: location.entryFile(id: stale))
        }
        writeIndex(rows, at: location)
    }

    /// `nonisolated` because the data reset's wipe runs off the main actor and
    /// removing a directory touches no `Codable` conformance. The rest of this
    /// type cannot follow: `HistoryEntry`'s conformance is MainActor-isolated
    /// by the project's default isolation.
    nonisolated static func removeAll(at location: Location = .default) {
        try? FileManager.default.removeItem(at: location.root)
    }

    // MARK: Internals

    /// Newest first, matching what the `UserDefaults` store's merge returned
    /// and what every reader downstream assumes.
    private static func sorted(_ rows: [HistoryIndexRow]) -> [HistoryIndexRow] {
        var seen: Set<UUID> = []
        return rows
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            }
    }

    /// Writes unconditionally. The previous version read the existing file
    /// back to compare first, which made appending one snapshot to a full
    /// store cost 2000 reads — measured at 890 ms against the blob's 216 ms.
    private static func write(_ entry: HistoryEntry, at location: Location) -> Bool {
        guard let data = try? encoder().encode(entry) else { return false }
        return (try? data.write(to: location.entryFile(id: entry.id), options: .atomic)) != nil
    }

    private static func writeIndex(_ rows: [HistoryIndexRow], at location: Location) {
        guard let data = try? encoder().encode(rows) else { return }
        try? data.write(to: location.indexFile, options: .atomic)
    }

    private static func onDiskEntryIDs(at location: Location) -> Set<UUID> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: location.entriesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
    }

    private static func ensureDirectories(at location: Location) -> Bool {
        (try? FileManager.default.createDirectory(
            at: location.entriesDirectory,
            withIntermediateDirectories: true
        )) != nil
    }

    private static func encoder() -> JSONEncoder { JSONEncoder() }
    private static func decoder() -> JSONDecoder { JSONDecoder() }
}

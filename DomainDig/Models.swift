import Foundation

enum ServiceResult<Value> {
    case success(Value)
    case empty(String)
    case error(String)
}

enum ConfidenceLevel: String, Codable {
    case high
    case medium
    case low

    var title: String {
        rawValue.capitalized
    }
}

enum InspectionErrorKind: String, Codable {
    case network
    case timeout
    case rateLimited
    case parsing
    case unsupported
    case unavailable
    case unknown

    var title: String {
        switch self {
        case .network:
            return "Network"
        case .timeout:
            return "Timeout"
        case .rateLimited:
            return "Rate limited"
        case .parsing:
            return "Parsing"
        case .unsupported:
            return "Unsupported"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }
}

struct InspectionFailure: Codable, Equatable {
    let kind: InspectionErrorKind
    let message: String
    let details: String?
}

struct SectionProvenance: Codable, Equatable {
    let source: String
    let collectedAt: Date
    let provider: String?
    let resolver: String?
    let resultSource: LookupResultSource
}

enum LookupResultSource: String, Codable {
    case live
    case cached
    case mixed
    case snapshot

    var label: String {
        switch self {
        case .live:
            return "Live"
        case .cached:
            return "Cached"
        case .mixed:
            return "Mixed"
        case .snapshot:
            return "Snapshot"
        }
    }
}

enum LookupSectionKind: String, Codable, CaseIterable {
    case dns
    case availability
    case ssl
    case hsts
    case httpHeaders
    case reachability
    case ipGeolocation
    case emailSecurity
    case ownership
    case ptr
    case redirectChain
    case subdomains
    case portScan
    case suggestions
}

enum DomainAvailabilityStatus: String, Codable {
    case available
    case registered
    case unknown
}

struct DomainAvailabilityResult: Codable {
    let domain: String
    let status: DomainAvailabilityStatus
}

struct DomainSuggestionResult: Identifiable, Codable {
    let id: UUID
    let domain: String
    let status: DomainAvailabilityStatus

    init(id: UUID = UUID(), domain: String, status: DomainAvailabilityStatus) {
        self.id = id
        self.domain = domain
        self.status = status
    }
}

struct WatchedDomain: Codable, Identifiable {
    let id: UUID
    let domain: String
    let createdAt: Date
    var lastKnownAvailability: DomainAvailabilityStatus?

    init(
        id: UUID = UUID(),
        domain: String,
        createdAt: Date = Date(),
        lastKnownAvailability: DomainAvailabilityStatus? = nil
    ) {
        self.id = id
        self.domain = domain
        self.createdAt = createdAt
        self.lastKnownAvailability = lastKnownAvailability
    }
}

enum ChangeSeverity: Int, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high

    static func < (lhs: ChangeSeverity, rhs: ChangeSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

enum CertificateWarningLevel: String, Codable {
    case none
    case warning
    case critical

    var title: String {
        switch self {
        case .none:
            return "Healthy"
        case .warning:
            return "Warning"
        case .critical:
            return "Critical"
        }
    }
}

enum DomainHealth: String, Codable, Sendable, CaseIterable {
    case healthy
    case warning
    case critical

    var title: String {
        rawValue.capitalized
    }
}

struct PortfolioSnapshot: Codable, Sendable {
    var totalDomains: Int
    var healthyCount: Int
    var warningCount: Int
    var criticalCount: Int
    var changedLast24h: Int
    var expiringSoonCount: Int
    var unreachableCount: Int
}

struct DomainChangeSummary: Codable, Equatable {
    let hasChanges: Bool
    let changedSections: [String]
    let message: String
    let severity: ChangeSeverity
    let impactClassification: ChangeImpactClassification
    let generatedAt: Date
    let observedFacts: [String]
    let inferredConclusions: [String]
    let contextNote: String?
    let riskAssessment: DomainRiskAssessment?
    let insights: [String]
    let riskScoreDelta: Int?

    init(
        hasChanges: Bool,
        changedSections: [String],
        message: String,
        severity: ChangeSeverity,
        impactClassification: ChangeImpactClassification,
        generatedAt: Date,
        observedFacts: [String] = [],
        inferredConclusions: [String] = [],
        contextNote: String? = nil,
        riskAssessment: DomainRiskAssessment? = nil,
        insights: [String] = [],
        riskScoreDelta: Int? = nil
    ) {
        self.hasChanges = hasChanges
        self.changedSections = changedSections
        self.message = message
        self.severity = severity
        self.impactClassification = impactClassification
        self.generatedAt = generatedAt
        self.observedFacts = observedFacts
        self.inferredConclusions = inferredConclusions
        self.contextNote = contextNote
        self.riskAssessment = riskAssessment
        self.insights = insights
        self.riskScoreDelta = riskScoreDelta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasChanges = try container.decodeIfPresent(Bool.self, forKey: .hasChanges) ?? false
        changedSections = try container.decodeIfPresent([String].self, forKey: .changedSections) ?? []
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        severity = try container.decodeIfPresent(ChangeSeverity.self, forKey: .severity) ?? (hasChanges ? .medium : .low)
        let defaultImpact: ChangeImpactClassification
        if severity == .high {
            defaultImpact = .critical
        } else {
            defaultImpact = hasChanges ? .warning : .informational
        }
        impactClassification = try container.decodeIfPresent(ChangeImpactClassification.self, forKey: .impactClassification)
            ?? defaultImpact
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? (changedSections.isEmpty ? "No meaningful changes" : changedSections.joined(separator: " • "))
        observedFacts = try container.decodeIfPresent([String].self, forKey: .observedFacts) ?? []
        inferredConclusions = try container.decodeIfPresent([String].self, forKey: .inferredConclusions) ?? []
        contextNote = try container.decodeIfPresent(String.self, forKey: .contextNote)
        riskAssessment = try container.decodeIfPresent(DomainRiskAssessment.self, forKey: .riskAssessment)
        insights = try container.decodeIfPresent([String].self, forKey: .insights) ?? []
        riskScoreDelta = try container.decodeIfPresent(Int.self, forKey: .riskScoreDelta)
    }
}

enum BatchLookupSource: String, Codable {
    case manual
    case watchlistRefresh
    case workflow
}

enum BatchLookupStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

struct BatchLookupResult: Identifiable, Codable, Equatable {
    let id: UUID
    let domain: String
    let historyEntryID: UUID?
    let resultSource: LookupResultSource
    let availability: DomainAvailabilityStatus?
    let primaryIP: String?
    let quickStatus: String
    let summaryMessage: String?
    let changeSeverity: ChangeSeverity?
    let changeClassification: ChangeImpactClassification?
    let certificateWarningLevel: CertificateWarningLevel
    let riskScore: Int?
    let riskLevel: RiskLevel?
    let timestamp: Date
    let status: BatchLookupStatus
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        domain: String,
        historyEntryID: UUID?,
        resultSource: LookupResultSource = .live,
        availability: DomainAvailabilityStatus?,
        primaryIP: String?,
        quickStatus: String,
        summaryMessage: String? = nil,
        changeSeverity: ChangeSeverity? = nil,
        changeClassification: ChangeImpactClassification? = nil,
        certificateWarningLevel: CertificateWarningLevel = .none,
        riskScore: Int? = nil,
        riskLevel: RiskLevel? = nil,
        timestamp: Date,
        status: BatchLookupStatus,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.domain = domain
        self.historyEntryID = historyEntryID
        self.resultSource = resultSource
        self.availability = availability
        self.primaryIP = primaryIP
        self.quickStatus = quickStatus
        self.summaryMessage = summaryMessage
        self.changeSeverity = changeSeverity
        self.changeClassification = changeClassification
        self.certificateWarningLevel = certificateWarningLevel
        self.riskScore = riskScore
        self.riskLevel = riskLevel
        self.timestamp = timestamp
        self.status = status
        self.errorMessage = errorMessage
    }

    var hasMeaningfulChange: Bool {
        quickStatus == "Changed"
            || quickStatus == "High"
            || quickStatus == "Critical"
            || certificateWarningLevel != .none
            || riskLevel == .high
            || status == .failed
    }
}

struct BatchSweepSummary: Identifiable, Equatable {
    let id = UUID()
    let source: BatchLookupSource
    let totalDomains: Int
    let changedDomains: Int
    let unchangedDomains: Int
    let warningDomains: Int
    let results: [BatchLookupResult]
    let generatedAt: Date
}

struct DomainWorkflow: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var domains: [String]
    var createdAt: Date
    var updatedAt: Date
    var notes: String?
    var collaboration: CollaborationMetadata?

    init(
        id: UUID = UUID(),
        name: String,
        domains: [String],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        notes: String? = nil,
        collaboration: CollaborationMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.domains = domains
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
        self.collaboration = collaboration
    }
}

struct WorkflowRunSummary: Identifiable, Equatable {
    let id = UUID()
    let workflowID: UUID
    let workflowName: String
    let totalDomains: Int
    let changedDomains: Int
    let unchangedDomains: Int
    let warningDomains: Int
    let results: [BatchLookupResult]
    let workflowInsights: [WorkflowInsight]
    let generatedAt: Date
}

/// Data that a tier gates. Ownership and DNS history derive from the user's own
/// stored snapshots and are not gated at all; pricing and reputation were
/// removed, having no local derivation and no configured provider.
enum DataCapability: String, Codable {
    case extendedSubdomains
}

struct DomainOwnershipHistoryEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let summary: String
    let registrar: String?
    let registrant: String?
    let nameservers: [String]
    let source: String
    let isExternal: Bool

    nonisolated init(
        id: UUID = UUID(),
        date: Date,
        summary: String,
        registrar: String? = nil,
        registrant: String? = nil,
        nameservers: [String] = [],
        source: String,
        isExternal: Bool
    ) {
        self.id = id
        self.date = date
        self.summary = summary
        self.registrar = registrar
        self.registrant = registrant
        self.nameservers = nameservers
        self.source = source
        self.isExternal = isExternal
    }
}

struct DNSHistoryEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let summary: String
    let aRecords: [String]
    let nameservers: [String]
    let recordSnapshots: [DNSHistoryRecordSnapshot]
    let changedRecordTypes: [DNSRecordType]
    let source: String
    let isExternal: Bool

    nonisolated init(
        id: UUID = UUID(),
        date: Date,
        summary: String,
        aRecords: [String] = [],
        nameservers: [String] = [],
        recordSnapshots: [DNSHistoryRecordSnapshot] = [],
        changedRecordTypes: [DNSRecordType] = [],
        source: String,
        isExternal: Bool
    ) {
        self.id = id
        self.date = date
        self.summary = summary
        self.aRecords = aRecords
        self.nameservers = nameservers
        self.recordSnapshots = recordSnapshots
        self.changedRecordTypes = changedRecordTypes
        self.source = source
        self.isExternal = isExternal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? "DNS change observed"
        aRecords = try container.decodeIfPresent([String].self, forKey: .aRecords) ?? []
        nameservers = try container.decodeIfPresent([String].self, forKey: .nameservers) ?? []
        let decodedRecordSnapshots = try container.decodeIfPresent([DNSHistoryRecordSnapshot].self, forKey: .recordSnapshots) ?? []
        if decodedRecordSnapshots.isEmpty {
            var synthesizedSnapshots: [DNSHistoryRecordSnapshot] = []
            if !aRecords.isEmpty {
                synthesizedSnapshots.append(DNSHistoryRecordSnapshot(recordType: .A, values: aRecords))
            }
            if !nameservers.isEmpty {
                synthesizedSnapshots.append(DNSHistoryRecordSnapshot(recordType: .NS, values: nameservers))
            }
            recordSnapshots = synthesizedSnapshots
        } else {
            recordSnapshots = decodedRecordSnapshots
        }
        changedRecordTypes = try container.decodeIfPresent([DNSRecordType].self, forKey: .changedRecordTypes)
            ?? recordSnapshots.map(\.recordType)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "Unknown"
        isExternal = try container.decodeIfPresent(Bool.self, forKey: .isExternal) ?? false
    }
}

struct DNSHistoryRecordSnapshot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let recordType: DNSRecordType
    let values: [String]

    nonisolated init(id: UUID = UUID(), recordType: DNSRecordType, values: [String]) {
        self.id = id
        self.recordType = recordType
        self.values = values
    }

    static func == (lhs: DNSHistoryRecordSnapshot, rhs: DNSHistoryRecordSnapshot) -> Bool {
        lhs.recordType == rhs.recordType && lhs.values == rhs.values
    }
}

struct InferredProviderFingerprint: Codable, Equatable, Sendable {
    let name: String
    let confidence: ConfidenceLevel
    let evidence: [String]
}

enum DomainClassificationKind: String, Codable, CaseIterable, Sendable {
    case marketing
    case app
    case api
    case auth
    case docs
    case staticSite = "static"
    case infrastructure
    case status
    case unknown

    var title: String {
        if self == .staticSite {
            return "Static"
        }
        return rawValue.capitalized
    }
}

struct DomainClassificationSummary: Codable, Equatable, Sendable {
    let kind: DomainClassificationKind
    let confidence: ConfidenceLevel
    let reasons: [String]
}

struct OwnershipTransitionEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let summary: String
    let previousRegistrar: String?
    let currentRegistrar: String?
    let previousRegistrant: String?
    let currentRegistrant: String?
    let previousNameservers: [String]
    let currentNameservers: [String]

    nonisolated init(
        id: UUID = UUID(),
        date: Date,
        summary: String,
        previousRegistrar: String? = nil,
        currentRegistrar: String? = nil,
        previousRegistrant: String? = nil,
        currentRegistrant: String? = nil,
        previousNameservers: [String] = [],
        currentNameservers: [String] = []
    ) {
        self.id = id
        self.date = date
        self.summary = summary
        self.previousRegistrar = previousRegistrar
        self.currentRegistrar = currentRegistrar
        self.previousRegistrant = previousRegistrant
        self.currentRegistrant = currentRegistrant
        self.previousNameservers = previousNameservers
        self.currentNameservers = currentNameservers
    }
}

struct HostingTransitionEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let fromProvider: String
    let toProvider: String
    let summary: String

    nonisolated init(id: UUID = UUID(), date: Date, fromProvider: String, toProvider: String, summary: String) {
        self.id = id
        self.date = date
        self.fromProvider = fromProvider
        self.toProvider = toProvider
        self.summary = summary
    }
}

struct SubdomainHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let hostname: String
    let firstSeen: Date
    let lastSeen: Date
    let recurrenceCount: Int
    let statusChangeCount: Int
    let lastKnownStatus: String
    let isEphemeral: Bool

    nonisolated init(
        hostname: String,
        firstSeen: Date,
        lastSeen: Date,
        recurrenceCount: Int,
        statusChangeCount: Int,
        lastKnownStatus: String,
        isEphemeral: Bool
    ) {
        id = hostname.lowercased()
        self.hostname = hostname
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.recurrenceCount = recurrenceCount
        self.statusChangeCount = statusChangeCount
        self.lastKnownStatus = lastKnownStatus
        self.isEphemeral = isEphemeral
    }
}

struct IntelligenceRiskSignal: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: ChangeSeverity
    let firstObserved: Date?
    let lastObserved: Date?

    nonisolated init(
        id: String,
        title: String,
        detail: String,
        severity: ChangeSeverity,
        firstObserved: Date? = nil,
        lastObserved: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.firstObserved = firstObserved
        self.lastObserved = lastObserved
    }
}

enum IntelligenceTimelineEventCategory: String, Codable, Sendable {
    case ownership
    case dns
    case hosting
    case subdomain
    case classification
    case risk
}

struct IntelligenceTimelineEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let category: IntelligenceTimelineEventCategory
    let title: String
    let detail: String
    let severity: ChangeSeverity

    nonisolated init(
        id: UUID = UUID(),
        date: Date,
        category: IntelligenceTimelineEventCategory,
        title: String,
        detail: String,
        severity: ChangeSeverity
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

struct DomainPricingInsight: Codable, Equatable, Sendable {
    let estimatedPrice: String?
    let premiumIndicator: Bool?
    let resaleSignal: String?
    let auctionSignal: String?
    let source: String
    let collectedAt: Date
}

enum DomainReputationStatus: String, Codable, Sendable {
    case clean
    case listed
    case unknown

    var title: String {
        switch self {
        case .clean:
            return "Clean"
        case .listed:
            return "Listed"
        case .unknown:
            return "Unknown"
        }
    }
}

struct DomainReputationResult: Codable, Equatable, Sendable {
    let status: DomainReputationStatus
    let listedSources: [String]
    let checkedAt: Date
}

enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .last7Days:
            return "Last 7 Days"
        case .all:
            return "All"
        }
    }
}

enum ChangeFilterOption: String, CaseIterable, Identifiable {
    case all
    case changed
    case unchanged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .changed:
            return "Changed"
        case .unchanged:
            return "Unchanged"
        }
    }
}

enum HistorySortOption: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case domain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest:
            return "Newest"
        case .oldest:
            return "Oldest"
        case .domain:
            return "Domain A-Z"
        }
    }
}

enum TimelineGroupingOption: String, CaseIterable, Identifiable {
    case none
    case relativeDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "Ungrouped"
        case .relativeDay:
            return "Today / Yesterday / Older"
        }
    }
}

enum HistoryAutoPruneOption: String, CaseIterable, Codable, Identifiable {
    case keep50
    case keep100
    case unlimited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep50:
            return "Keep Last 50"
        case .keep100:
            return "Keep Last 100"
        case .unlimited:
            return "Unlimited"
        }
    }

    var keepCount: Int? {
        switch self {
        case .keep50:
            return 50
        case .keep100:
            return 100
        case .unlimited:
            return nil
        }
    }
}

struct SnapshotSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let domain: String
    let timestamp: Date
    let trackedDomainID: UUID?
    let snapshotIndex: Int?
    let previousSnapshotID: UUID?
    let changeCount: Int
    let severitySummary: ChangeSeverity?
    let changeSummaryMessage: String?
    let availability: DomainAvailabilityStatus?
    let primaryIP: String?
    let tlsStatus: String?
    let riskScore: Int?
    let historyEntryID: UUID

    var hasChanges: Bool {
        changeCount > 0
    }
}

struct FullSnapshot: Codable {
    let historyEntry: HistoryEntry
}

struct TimelineSection: Identifiable, Equatable {
    let id: String
    let title: String
    let entries: [SnapshotSummary]
}

enum WatchlistFilterOption: String, CaseIterable, Identifiable, Codable {
    case all
    case pinnedOnly
    case changedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .pinnedOnly:
            return "Pinned Only"
        case .changedOnly:
            return "Changed Only"
        }
    }
}

enum WatchlistSortOption: String, CaseIterable, Identifiable, Codable {
    case pinned
    case recentlyUpdated
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned:
            return "Pinned"
        case .recentlyUpdated:
            return "Recently Updated"
        case .alphabetical:
            return "Alphabetical"
        }
    }
}

/// A named watchlist filter preset (tag, filter, sort) the user can save and
/// reapply. Stored locally in UserDefaults; not included in backup/restore.
struct WatchlistSavedView: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var tag: String?
    var filter: WatchlistFilterOption
    var sort: WatchlistSortOption

    init(
        id: UUID = UUID(),
        name: String,
        tag: String?,
        filter: WatchlistFilterOption,
        sort: WatchlistSortOption
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.filter = filter
        self.sort = sort
    }
}

enum PortfolioFilterOption: String, CaseIterable, Identifiable {
    case all
    case healthy
    case warning
    case critical
    case changed
    case expiring
    case unreachable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .healthy:
            return "Healthy"
        case .warning:
            return "Warning"
        case .critical:
            return "Critical"
        case .changed:
            return "Changed"
        case .expiring:
            return "Expiring"
        case .unreachable:
            return "Unreachable"
        }
    }
}

extension DomainHealth {
    static func classify(
        certificateExpiryState: CertificateWarningLevel,
        isReachable: Bool,
        recentMonitoringFailureCount: Int,
        hasRecentDNSChange: Bool,
        instabilityScore: Int,
        hasRecentCriticalChange: Bool,
        hasInvalidTLS: Bool
    ) -> DomainHealth {
        if !isReachable
            || hasInvalidTLS
            || certificateExpiryState == .critical
            || recentMonitoringFailureCount >= 2
            || instabilityScore >= 70
            || hasRecentCriticalChange {
            return .critical
        }

        if certificateExpiryState == .warning
            || recentMonitoringFailureCount == 1
            || hasRecentDNSChange
            || instabilityScore >= 35 {
            return .warning
        }

        return .healthy
    }

    static func instabilityScore(
        recentChangeCount: Int,
        recentFailureCount: Int,
        pendingAlertCount: Int,
        hasRecentDNSChange: Bool
    ) -> Int {
        let rawScore = (recentChangeCount * 12)
            + (recentFailureCount * 24)
            + (pendingAlertCount * 8)
            + (hasRecentDNSChange ? 14 : 0)
        return min(rawScore, 100)
    }
}

enum PremiumCapability: String, Codable {
    case unlimitedTrackedDomains
    case automatedMonitoring
    case pushAlerts
    case batchTracking
    case advancedExports
}

enum CollaborationPermission: String, Codable, Equatable {
    case readOnly
    case editable

    var title: String {
        switch self {
        case .readOnly:
            return "Read only"
        case .editable:
            return "Editable"
        }
    }
}

enum CollaborationOwnership: String, Codable, Equatable {
    case owner
    case participant

    var title: String {
        switch self {
        case .owner:
            return "Owned by you"
        case .participant:
            return "Shared with you"
        }
    }
}

enum CollaborationScope: String, Codable, Equatable {
    case privateDatabase
    case sharedDatabase
}

struct CollaborationMetadata: Codable, Equatable {
    var scope: CollaborationScope
    var ownership: CollaborationOwnership
    var permission: CollaborationPermission
    var shareRecordName: String?

    init(
        scope: CollaborationScope,
        ownership: CollaborationOwnership,
        permission: CollaborationPermission,
        shareRecordName: String? = nil
    ) {
        self.scope = scope
        self.ownership = ownership
        self.permission = permission
        self.shareRecordName = shareRecordName
    }

    var isShared: Bool {
        shareRecordName != nil || scope == .sharedDatabase
    }

    var canEdit: Bool {
        permission == .editable
    }

    var isOwner: Bool {
        ownership == .owner
    }
}

enum MonitoringSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var minimumInterval: TimeInterval {
        switch self {
        case .low:
            return 30 * 60
        case .medium:
            return 15 * 60
        case .high:
            return 5 * 60
        }
    }

    var intervalMultiplier: Double {
        switch self {
        case .low:
            return 1.5
        case .medium:
            return 1.25
        case .high:
            return 1.1
        }
    }
}

struct QuietHours: Codable, Equatable, Sendable {
    var startHour: Int
    var endHour: Int

    init(startHour: Int, endHour: Int) {
        self.startHour = max(0, min(23, startHour))
        self.endHour = max(0, min(23, endHour))
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }
}

enum MonitoringBaseInterval: String, Codable, CaseIterable, Identifiable {
    case thirtyMinutes
    case hourly
    case sixHours
    case twelveHours
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes:
            return "Every 30 Minutes"
        case .hourly:
            return "Hourly"
        case .sixHours:
            return "Every 6 Hours"
        case .twelveHours:
            return "Every 12 Hours"
        case .daily:
            return "Daily"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .thirtyMinutes:
            return 30 * 60
        case .hourly:
            return 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .daily:
            return 24 * 60 * 60
        }
    }

    static func nearest(to interval: TimeInterval) -> MonitoringBaseInterval {
        allCases.min { abs($0.interval - interval) < abs($1.interval - interval) } ?? .twelveHours
    }
}

struct MonitoringConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var baseInterval: TimeInterval
    var adaptiveEnabled: Bool
    var sensitivity: MonitoringSensitivity
    var quietHours: QuietHours?

    init(
        isEnabled: Bool = false,
        baseInterval: TimeInterval = MonitoringBaseInterval.twelveHours.interval,
        adaptiveEnabled: Bool = true,
        sensitivity: MonitoringSensitivity = .medium,
        quietHours: QuietHours? = nil
    ) {
        self.isEnabled = isEnabled
        self.baseInterval = baseInterval
        self.adaptiveEnabled = adaptiveEnabled
        self.sensitivity = sensitivity
        self.quietHours = quietHours
    }

    var maxInterval: TimeInterval {
        24 * 60 * 60
    }

    var sanitizedBaseInterval: TimeInterval {
        max(5 * 60, min(baseInterval, maxInterval))
    }
}

struct MonitoringState: Codable, Equatable, Sendable {
    var lastCheck: Date?
    var lastChangeHash: String?
    var lastAlertDate: Date?
    var consecutiveStableChecks: Int
    var currentInterval: TimeInterval
    var lastChangeDate: Date?

    init(
        lastCheck: Date? = nil,
        lastChangeHash: String? = nil,
        lastAlertDate: Date? = nil,
        consecutiveStableChecks: Int = 0,
        currentInterval: TimeInterval = 0,
        lastChangeDate: Date? = nil
    ) {
        self.lastCheck = lastCheck
        self.lastChangeHash = lastChangeHash
        self.lastAlertDate = lastAlertDate
        self.consecutiveStableChecks = consecutiveStableChecks
        self.currentInterval = currentInterval
        self.lastChangeDate = lastChangeDate
    }
}

struct MonitoringPendingAlert: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var detectedAt: Date
    var message: String
    var severity: MonitoringAlertSeverity
    var changeHash: String
}


// Declared in an extension so the struct keeps its synthesized memberwise
// initializer: adding one inside the body would suppress it.
extension HistoryEntry.Inspection {
    /// Every field here is copied straight off the snapshot, and both call
    /// sites did exactly that. Naming it once keeps them from drifting.
    init(snapshot: LookupSnapshot) {
        self.init(
            dnsSections: snapshot.dnsSections,
            sslInfo: snapshot.sslInfo,
            httpHeaders: snapshot.httpHeaders,
            reachabilityResults: snapshot.reachabilityResults,
            ipGeolocation: snapshot.ipGeolocation,
            emailSecurity: snapshot.emailSecurity,
            mtaSts: snapshot.emailSecurity?.mtaSts,
            ptrRecord: snapshot.ptrRecord,
            redirectChain: snapshot.redirectChain,
            subdomains: snapshot.subdomains,
            extendedSubdomains: snapshot.extendedSubdomains,
            dnsHistory: snapshot.dnsHistory,
            portScanResults: snapshot.portScanResults,
            hstsPreloaded: snapshot.hstsPreloaded,
            availabilityResult: snapshot.availabilityResult,
            suggestions: snapshot.suggestions
        )
    }
}

// Declared in an extension so the struct keeps its synthesized memberwise
// initializer: adding one inside the body would suppress it.
extension HistoryEntry.Provenance {
    /// Every field here is copied straight off the snapshot, and both call
    /// sites did exactly that. Naming it once keeps them from drifting.
    init(snapshot: LookupSnapshot) {
        self.init(
            appVersion: snapshot.appVersion,
            resultSource: snapshot.resultSource,
            dataSources: snapshot.dataSources,
            provenanceBySection: snapshot.provenanceBySection,
            availabilityConfidence: snapshot.availabilityConfidence,
            ownershipConfidence: snapshot.ownershipConfidence,
            subdomainConfidence: snapshot.subdomainConfidence,
            emailSecurityConfidence: snapshot.emailSecurityConfidence,
            geolocationConfidence: snapshot.geolocationConfidence,
            isPartialSnapshot: snapshot.isPartialSnapshot,
            validationIssues: snapshot.validationIssues,
            resolverDisplayName: snapshot.resolverDisplayName,
            resolverURLString: snapshot.resolverURLString,
            totalLookupDurationMs: snapshot.totalLookupDurationMs
        )
    }
}

// Declared in an extension so the struct keeps its synthesized memberwise
// initializer: adding one inside the body would suppress it.
extension HistoryEntry.Failures {
    /// Every field here is copied straight off the snapshot, and both call
    /// sites did exactly that. Naming it once keeps them from drifting.
    init(snapshot: LookupSnapshot) {
        self.init(
            errorDetails: snapshot.errorDetails,
            sslError: snapshot.sslError,
            httpHeadersError: snapshot.httpHeadersError,
            reachabilityError: snapshot.reachabilityError,
            ipGeolocationError: snapshot.ipGeolocationError,
            emailSecurityError: snapshot.emailSecurityError,
            ownershipError: snapshot.ownershipError,
            ownershipHistoryError: snapshot.ownershipHistoryError,
            ptrError: snapshot.ptrError,
            redirectChainError: snapshot.redirectChainError,
            subdomainsError: snapshot.subdomainsError,
            extendedSubdomainsError: snapshot.extendedSubdomainsError,
            dnsHistoryError: snapshot.dnsHistoryError,
            domainPricingError: snapshot.domainPricingError,
            reputationError: snapshot.reputationError,
            portScanError: snapshot.portScanError
        )
    }
}

struct TrackedDomain: Codable, Identifiable, Equatable {
    let id: UUID
    var domain: String
    var createdAt: Date
    var updatedAt: Date
    var note: String?
    var isPinned: Bool
    var monitoringEnabled: Bool
    var lastKnownAvailability: DomainAvailabilityStatus?
    var lastSnapshotID: UUID?
    var lastChangeSummary: DomainChangeSummary?
    var lastChangeSeverity: ChangeSeverity?
    var certificateWarningLevel: CertificateWarningLevel
    var certificateDaysRemaining: Int?
    var lastMonitoredAt: Date?
    var lastAlertAt: Date?
    var monitoringState: MonitoringState
    var pendingMonitoringAlerts: [MonitoringPendingAlert]
    var collaboration: CollaborationMetadata?
    var tags: [String]

    init(
        id: UUID = UUID(),
        domain: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        note: String? = nil,
        isPinned: Bool = false,
        monitoringEnabled: Bool = true,
        lastKnownAvailability: DomainAvailabilityStatus? = nil,
        lastSnapshotID: UUID? = nil,
        lastChangeSummary: DomainChangeSummary? = nil,
        lastChangeSeverity: ChangeSeverity? = nil,
        certificateWarningLevel: CertificateWarningLevel = .none,
        certificateDaysRemaining: Int? = nil,
        lastMonitoredAt: Date? = nil,
        lastAlertAt: Date? = nil,
        monitoringState: MonitoringState = MonitoringState(),
        pendingMonitoringAlerts: [MonitoringPendingAlert] = [],
        collaboration: CollaborationMetadata? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.domain = domain
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.note = note
        self.isPinned = isPinned
        self.monitoringEnabled = monitoringEnabled
        self.lastKnownAvailability = lastKnownAvailability
        self.lastSnapshotID = lastSnapshotID
        self.lastChangeSummary = lastChangeSummary
        self.lastChangeSeverity = lastChangeSeverity
        self.certificateWarningLevel = certificateWarningLevel
        self.certificateDaysRemaining = certificateDaysRemaining
        self.lastMonitoredAt = lastMonitoredAt
        self.lastAlertAt = lastAlertAt
        self.monitoringState = monitoringState
        self.pendingMonitoringAlerts = pendingMonitoringAlerts
        self.collaboration = collaboration
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = try container.decode(String.self, forKey: .domain)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        note = try container.decodeIfPresent(String.self, forKey: .note)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
        lastKnownAvailability = try container.decodeIfPresent(DomainAvailabilityStatus.self, forKey: .lastKnownAvailability)
        lastSnapshotID = try container.decodeIfPresent(UUID.self, forKey: .lastSnapshotID)
        lastChangeSummary = try container.decodeIfPresent(DomainChangeSummary.self, forKey: .lastChangeSummary)
        lastChangeSeverity = try container.decodeIfPresent(ChangeSeverity.self, forKey: .lastChangeSeverity) ?? lastChangeSummary?.severity
        certificateWarningLevel = try container.decodeIfPresent(CertificateWarningLevel.self, forKey: .certificateWarningLevel) ?? .none
        certificateDaysRemaining = try container.decodeIfPresent(Int.self, forKey: .certificateDaysRemaining)
        lastMonitoredAt = try container.decodeIfPresent(Date.self, forKey: .lastMonitoredAt)
        lastAlertAt = try container.decodeIfPresent(Date.self, forKey: .lastAlertAt)
        monitoringState = try container.decodeIfPresent(MonitoringState.self, forKey: .monitoringState) ?? MonitoringState()
        pendingMonitoringAlerts = try container.decodeIfPresent([MonitoringPendingAlert].self, forKey: .pendingMonitoringAlerts) ?? []
        collaboration = try container.decodeIfPresent(CollaborationMetadata.self, forKey: .collaboration)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

enum MonitoringScope: String, Codable, CaseIterable, Identifiable {
    case allTracked
    case selectedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTracked:
            return "All Tracked"
        case .selectedOnly:
            return "Selected Only"
        }
    }
}

enum MonitoringAlertSeverity: Int, Codable, CaseIterable, Comparable {
    case info
    case warning
    case critical

    static func < (lhs: MonitoringAlertSeverity, rhs: MonitoringAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .info:
            return "Info"
        case .warning:
            return "Warning"
        case .critical:
            return "Critical"
        }
    }
}

enum MonitoringAlertFilter: String, Codable, CaseIterable, Identifiable {
    case criticalOnly
    case criticalAndWarnings
    case allChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .criticalOnly:
            return "Critical Only"
        case .criticalAndWarnings:
            return "Critical + Warnings"
        case .allChanges:
            return "All Changes"
        }
    }

    var minimumSeverity: MonitoringAlertSeverity {
        switch self {
        case .criticalOnly:
            return .critical
        case .criticalAndWarnings:
            return .warning
        case .allChanges:
            return .info
        }
    }
}

enum MonitoringRunTrigger: String, Codable {
    case manual
    case background
    case cli

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .background:
            return "Background"
        case .cli:
            return "CLI"
        }
    }
}

struct MonitoringSettings: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case config
        case isEnabled
        case frequency
        case scope
        case selectedDomainIDs
        case alertFilter
        case alertsEnabled
    }

    var config: MonitoringConfig
    var scope: MonitoringScope
    var selectedDomainIDs: [UUID]
    var alertFilter: MonitoringAlertFilter
    var alertsEnabled: Bool

    init(
        config: MonitoringConfig = MonitoringConfig(),
        scope: MonitoringScope = .allTracked,
        selectedDomainIDs: [UUID] = [],
        alertFilter: MonitoringAlertFilter = .criticalAndWarnings,
        alertsEnabled: Bool = false
    ) {
        self.config = config
        self.scope = scope
        self.selectedDomainIDs = selectedDomainIDs
        self.alertFilter = alertFilter
        self.alertsEnabled = alertsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let legacyFrequencyRaw = try container.decodeIfPresent(String.self, forKey: .frequency)

        if let decodedConfig = try container.decodeIfPresent(MonitoringConfig.self, forKey: .config) {
            config = decodedConfig
        } else {
            let mappedInterval: TimeInterval
            switch legacyFrequencyRaw {
            case "daily":
                mappedInterval = MonitoringBaseInterval.daily.interval
            case "twiceDaily":
                mappedInterval = MonitoringBaseInterval.twelveHours.interval
            default:
                mappedInterval = MonitoringBaseInterval.twelveHours.interval
            }

            config = MonitoringConfig(
                isEnabled: legacyEnabled,
                baseInterval: mappedInterval,
                adaptiveEnabled: true,
                sensitivity: .medium,
                quietHours: nil
            )
        }

        scope = try container.decodeIfPresent(MonitoringScope.self, forKey: .scope) ?? .allTracked
        selectedDomainIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedDomainIDs) ?? []
        alertFilter = try container.decodeIfPresent(MonitoringAlertFilter.self, forKey: .alertFilter) ?? .criticalAndWarnings
        alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(config, forKey: .config)
        try container.encode(scope, forKey: .scope)
        try container.encode(selectedDomainIDs, forKey: .selectedDomainIDs)
        try container.encode(alertFilter, forKey: .alertFilter)
        try container.encode(alertsEnabled, forKey: .alertsEnabled)
    }

    var isEnabled: Bool {
        get { config.isEnabled }
        set { config.isEnabled = newValue }
    }

    var baseInterval: TimeInterval {
        get { config.baseInterval }
        set { config.baseInterval = newValue }
    }

    var adaptiveEnabled: Bool {
        get { config.adaptiveEnabled }
        set { config.adaptiveEnabled = newValue }
    }

    var sensitivity: MonitoringSensitivity {
        get { config.sensitivity }
        set { config.sensitivity = newValue }
    }

    var quietHours: QuietHours? {
        get { config.quietHours }
        set { config.quietHours = newValue }
    }
}

struct MonitoringDomainResult: Codable, Identifiable, Equatable {
    let id: UUID
    let domain: String
    let historyEntryID: UUID?
    let checkedAt: Date
    let didChange: Bool
    let summaryMessage: String
    let alertSeverity: MonitoringAlertSeverity?
    let certificateWarningLevel: CertificateWarningLevel
    let resultSource: LookupResultSource
    let errorMessage: String?
    /// Non-nil when the lookup failed and the previous snapshot was reused, so
    /// this run compared the old data against itself and cannot claim the
    /// domain is unchanged. Optional so already-persisted logs still decode.
    let unreachableReason: String?

    init(
        id: UUID = UUID(),
        domain: String,
        historyEntryID: UUID?,
        checkedAt: Date,
        didChange: Bool,
        summaryMessage: String,
        alertSeverity: MonitoringAlertSeverity?,
        certificateWarningLevel: CertificateWarningLevel,
        resultSource: LookupResultSource,
        errorMessage: String? = nil,
        unreachableReason: String? = nil
    ) {
        self.id = id
        self.domain = domain
        self.historyEntryID = historyEntryID
        self.checkedAt = checkedAt
        self.didChange = didChange
        self.summaryMessage = summaryMessage
        self.alertSeverity = alertSeverity
        self.certificateWarningLevel = certificateWarningLevel
        self.resultSource = resultSource
        self.errorMessage = errorMessage
        self.unreachableReason = unreachableReason
    }
}

struct MonitoringLog: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let trigger: MonitoringRunTrigger
    let domainsChecked: Int
    let changesFound: Int
    let alertsTriggered: Int
    let checkedDomains: [MonitoringDomainResult]
    let errors: [String]

    init(
        id: UUID = UUID(),
        timestamp: Date,
        trigger: MonitoringRunTrigger,
        domainsChecked: Int,
        changesFound: Int,
        alertsTriggered: Int,
        checkedDomains: [MonitoringDomainResult],
        errors: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.trigger = trigger
        self.domainsChecked = domainsChecked
        self.changesFound = changesFound
        self.alertsTriggered = alertsTriggered
        self.checkedDomains = checkedDomains
        self.errors = errors
    }

    var summary: String {
        if errors.isEmpty {
            return "\(changesFound) changes across \(domainsChecked) domains"
        }
        return "\(changesFound) changes, \(errors.count) errors"
    }
}

enum EventSeverity: String, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case info
    case warning
    case critical

    var id: String { rawValue }

    static func < (lhs: EventSeverity, rhs: EventSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var title: String {
        rawValue.capitalized
    }

    private var rank: Int {
        switch self {
        case .info:
            return 0
        case .warning:
            return 1
        case .critical:
            return 2
        }
    }

    init(monitoringSeverity: MonitoringAlertSeverity) {
        switch monitoringSeverity {
        case .info:
            self = .info
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }
}

enum MonitoringEventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case dnsChanged
    case certificateUpdated
    case certificateExpiring
    case redirectChanged
    case headersChanged
    case endpointUnreachable
    case monitoringFailure
    case changeDetected
    case test

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dnsChanged:
            return "DNS Changed"
        case .certificateUpdated:
            return "Certificate Updated"
        case .certificateExpiring:
            return "Certificate Expiring"
        case .redirectChanged:
            return "Redirect Changed"
        case .headersChanged:
            return "Headers Changed"
        case .endpointUnreachable:
            return "Endpoint Unreachable"
        case .monitoringFailure:
            return "Monitoring Failure"
        case .changeDetected:
            return "Change Detected"
        case .test:
            return "Test Event"
        }
    }
}

struct MonitoringEvent: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var type: MonitoringEventType
    var severity: EventSeverity
    var domain: String
    var timestamp: Date
    var summary: String
    var details: [String: String]

    init(
        id: UUID = UUID(),
        type: MonitoringEventType,
        severity: EventSeverity,
        domain: String,
        timestamp: Date = Date(),
        summary: String,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.severity = severity
        self.domain = domain
        self.timestamp = timestamp
        self.summary = summary
        self.details = details
    }
}

enum IntegrationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case webhook
    case slack
    case email

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum SMTPSecurityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain
    case directTLS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain:
            return "None (no TLS)"
        case .directTLS:
            return "Direct TLS"
        }
    }
}

struct WebhookIntegrationConfiguration: Codable, Equatable, Sendable {
    var endpointDisplayHost: String
    var timeoutSeconds: Double
    var additionalHeaders: [String: String]
    var credentialReference: String?

    init(
        endpointDisplayHost: String = "",
        timeoutSeconds: Double = 15,
        additionalHeaders: [String: String] = [:],
        credentialReference: String? = nil
    ) {
        self.endpointDisplayHost = endpointDisplayHost
        self.timeoutSeconds = timeoutSeconds
        self.additionalHeaders = additionalHeaders
        self.credentialReference = credentialReference
    }
}

struct SlackIntegrationConfiguration: Codable, Equatable, Sendable {
    var destinationLabel: String
    var credentialReference: String?

    init(
        destinationLabel: String = "Slack",
        credentialReference: String? = nil
    ) {
        self.destinationLabel = destinationLabel
        self.credentialReference = credentialReference
    }
}

struct EmailIntegrationConfiguration: Codable, Equatable, Sendable {
    var smtpHost: String
    var port: Int
    var username: String
    var senderAddress: String
    var recipientAddresses: [String]
    var securityMode: SMTPSecurityMode
    var credentialReference: String?

    init(
        smtpHost: String = "",
        port: Int = 465,
        username: String = "",
        senderAddress: String = "",
        recipientAddresses: [String] = [],
        securityMode: SMTPSecurityMode = .directTLS,
        credentialReference: String? = nil
    ) {
        self.smtpHost = smtpHost
        self.port = port
        self.username = username
        self.senderAddress = senderAddress
        self.recipientAddresses = recipientAddresses
        self.securityMode = securityMode
        self.credentialReference = credentialReference
    }
}

enum IntegrationConfiguration: Codable, Equatable, Sendable {
    case webhook(WebhookIntegrationConfiguration)
    case slack(SlackIntegrationConfiguration)
    case email(EmailIntegrationConfiguration)

    private enum CodingKeys: String, CodingKey {
        case type
        case webhook
        case slack
        case email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(IntegrationType.self, forKey: .type)
        switch type {
        case .webhook:
            self = .webhook(try container.decode(WebhookIntegrationConfiguration.self, forKey: .webhook))
        case .slack:
            self = .slack(try container.decode(SlackIntegrationConfiguration.self, forKey: .slack))
        case .email:
            self = .email(try container.decode(EmailIntegrationConfiguration.self, forKey: .email))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .webhook(let configuration):
            try container.encode(IntegrationType.webhook, forKey: .type)
            try container.encode(configuration, forKey: .webhook)
        case .slack(let configuration):
            try container.encode(IntegrationType.slack, forKey: .type)
            try container.encode(configuration, forKey: .slack)
        case .email(let configuration):
            try container.encode(IntegrationType.email, forKey: .type)
            try container.encode(configuration, forKey: .email)
        }
    }

    var type: IntegrationType {
        switch self {
        case .webhook:
            return .webhook
        case .slack:
            return .slack
        case .email:
            return .email
        }
    }
}

struct IntegrationFilterSet: Codable, Equatable, Sendable {
    var minimumSeverity: EventSeverity
    var eventTypes: Set<MonitoringEventType>
    var domains: [String]

    init(
        minimumSeverity: EventSeverity = .warning,
        eventTypes: Set<MonitoringEventType> = Set(MonitoringEventType.allCases.filter { $0 != .test }),
        domains: [String] = []
    ) {
        self.minimumSeverity = minimumSeverity
        self.eventTypes = eventTypes
        self.domains = domains
    }

    func matches(_ event: MonitoringEvent) -> Bool {
        guard event.severity >= minimumSeverity else {
            return false
        }
        guard eventTypes.isEmpty || eventTypes.contains(event.type) else {
            return false
        }
        guard domains.isEmpty || domains.map({ $0.lowercased() }).contains(event.domain.lowercased()) else {
            return false
        }
        return true
    }
}

struct IntegrationTarget: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var type: IntegrationType
    var name: String
    var isEnabled: Bool
    var configuration: IntegrationConfiguration
    var filters: IntegrationFilterSet

    init(
        id: UUID = UUID(),
        type: IntegrationType,
        name: String,
        isEnabled: Bool = true,
        configuration: IntegrationConfiguration,
        filters: IntegrationFilterSet = IntegrationFilterSet()
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.isEnabled = isEnabled
        self.configuration = configuration
        self.filters = filters
    }
}

enum DeliveryStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case retrying
    case delivered
    case failed
    case expired
    case skipped

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct DeliveryRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var integrationID: UUID
    var eventID: UUID
    var timestamp: Date
    var status: DeliveryStatus
    var destination: String
    var summary: String
    var failureReason: String?
    var attemptCount: Int

    init(
        id: UUID = UUID(),
        integrationID: UUID,
        eventID: UUID,
        timestamp: Date = Date(),
        status: DeliveryStatus,
        destination: String,
        summary: String,
        failureReason: String? = nil,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.integrationID = integrationID
        self.eventID = eventID
        self.timestamp = timestamp
        self.status = status
        self.destination = destination
        self.summary = summary
        self.failureReason = failureReason
        self.attemptCount = attemptCount
    }
}

struct QueuedDelivery: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var integrationID: UUID
    var event: MonitoringEvent
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?
    var expiresAt: Date

    init(
        id: UUID = UUID(),
        integrationID: UUID,
        event: MonitoringEvent,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        nextAttemptAt: Date = Date(),
        lastError: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(3 * 24 * 60 * 60)
    ) {
        self.id = id
        self.integrationID = integrationID
        self.event = event
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.expiresAt = expiresAt
    }
}

// MARK: - DNS Models

enum DNSRecordType: String, CaseIterable, Codable {
    case A
    case AAAA
    case MX
    case NS
    case TXT
    case CNAME
    case SOA
    case SRV
    case CAA
    case DS
    case PTR

    var queryType: Int {
        switch self {
        case .A: return 1
        case .AAAA: return 28
        case .MX: return 15
        case .NS: return 2
        case .TXT: return 16
        case .CNAME: return 5
        case .SOA: return 6
        case .SRV: return 33
        case .CAA: return 257
        case .DS: return 43
        case .PTR: return 12
        }
    }

    var usesRawDataValue: Bool {
        switch self {
        case .TXT, .SOA, .DS:
            return true
        default:
            return false
        }
    }
}

struct DNSRecord: Identifiable, Codable {
    var id = UUID()
    let value: String
    let ttl: Int
}

struct DNSSection: Identifiable, Codable {
    var id = UUID()
    let recordType: DNSRecordType
    var records: [DNSRecord]
    var wildcardRecords: [DNSRecord] = []
    var dnssecSigned: Bool?
    var error: String?
}

// MARK: - SSL Models

struct SSLCertificateInfo: Codable {
    struct CertChainEntry: Codable {
        let subject: String
        let issuer: String
    }

    let commonName: String
    let subjectAltNames: [String]
    let issuer: String
    let validFrom: Date
    let validUntil: Date
    let daysUntilExpiry: Int
    let chainDepth: Int
    let tlsVersion: String?
    let cipherSuite: String?
    let chain: [CertChainEntry]

    init(
        commonName: String,
        subjectAltNames: [String],
        issuer: String,
        validFrom: Date,
        validUntil: Date,
        daysUntilExpiry: Int,
        chainDepth: Int,
        tlsVersion: String? = nil,
        cipherSuite: String? = nil,
        chain: [CertChainEntry] = []
    ) {
        self.commonName = commonName
        self.subjectAltNames = subjectAltNames
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.daysUntilExpiry = daysUntilExpiry
        self.chainDepth = chainDepth
        self.tlsVersion = tlsVersion
        self.cipherSuite = cipherSuite
        self.chain = chain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commonName = try container.decode(String.self, forKey: .commonName)
        subjectAltNames = try container.decode([String].self, forKey: .subjectAltNames)
        issuer = try container.decode(String.self, forKey: .issuer)
        validFrom = try container.decode(Date.self, forKey: .validFrom)
        validUntil = try container.decode(Date.self, forKey: .validUntil)
        daysUntilExpiry = try container.decode(Int.self, forKey: .daysUntilExpiry)
        chainDepth = try container.decode(Int.self, forKey: .chainDepth)
        tlsVersion = try container.decodeIfPresent(String.self, forKey: .tlsVersion)
        cipherSuite = try container.decodeIfPresent(String.self, forKey: .cipherSuite)
        chain = try container.decodeIfPresent([CertChainEntry].self, forKey: .chain) ?? []
    }
}

// MARK: - HTTP Headers Models

struct HTTPHeader: Identifiable, Codable {
    var id = UUID()
    let name: String
    let value: String

    static let securityHeaders: Set<String> = [
        "strict-transport-security",
        "x-frame-options",
        "x-content-type-options",
        "content-security-policy",
        "referrer-policy"
    ]

    var isSecurityHeader: Bool {
        Self.securityHeaders.contains(name.lowercased())
    }
}

// MARK: - Reachability Models

struct PortReachability: Identifiable, Codable {
    var id = UUID()
    let port: UInt16
    let reachable: Bool
    let latencyMs: Int?
}

// MARK: - IP Geolocation Models

struct IPGeolocation: Codable {
    let ip: String
    let city: String?
    let region: String?
    let countryName: String?
    let org: String?
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case ip, city, region
        case countryName = "country_name"
        case org, latitude, longitude
    }
}

// MARK: - Ownership Models

struct DomainOwnership: Codable, Equatable {
    let registrar: String?
    let registrant: String?
    let createdDate: Date?
    let expirationDate: Date?
    let status: [String]
    let nameservers: [String]
    let abuseEmail: String?

    init(
        registrar: String? = nil,
        registrant: String? = nil,
        createdDate: Date? = nil,
        expirationDate: Date? = nil,
        status: [String] = [],
        nameservers: [String] = [],
        abuseEmail: String? = nil
    ) {
        self.registrar = registrar
        self.registrant = registrant
        self.createdDate = createdDate
        self.expirationDate = expirationDate
        self.status = status
        self.nameservers = nameservers
        self.abuseEmail = abuseEmail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registrar = try container.decodeIfPresent(String.self, forKey: .registrar)
        registrant = try container.decodeIfPresent(String.self, forKey: .registrant)
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate)
        expirationDate = try container.decodeIfPresent(Date.self, forKey: .expirationDate)
        status = try container.decodeIfPresent([String].self, forKey: .status) ?? []
        nameservers = try container.decodeIfPresent([String].self, forKey: .nameservers) ?? []
        abuseEmail = try container.decodeIfPresent(String.self, forKey: .abuseEmail)
    }
}

struct DiscoveredSubdomain: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { hostname }
    let hostname: String
    let source: String?
    let isExtended: Bool

    nonisolated init(hostname: String, source: String? = nil, isExtended: Bool = false) {
        self.hostname = hostname
        self.source = source
        self.isExtended = isExtended
    }
}

// MARK: - Email Security Models

struct EmailSecurityResult: Codable {
    let spf: EmailSecurityRecord
    let dmarc: EmailSecurityRecord
    let dkim: EmailSecurityRecord
    let bimi: EmailSecurityRecord
    let mtaSts: MTASTSResult?

    init(
        spf: EmailSecurityRecord,
        dmarc: EmailSecurityRecord,
        dkim: EmailSecurityRecord,
        bimi: EmailSecurityRecord = EmailSecurityRecord(found: false, value: nil),
        mtaSts: MTASTSResult? = nil
    ) {
        self.spf = spf
        self.dmarc = dmarc
        self.dkim = dkim
        self.bimi = bimi
        self.mtaSts = mtaSts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spf = try container.decode(EmailSecurityRecord.self, forKey: .spf)
        dmarc = try container.decode(EmailSecurityRecord.self, forKey: .dmarc)
        dkim = try container.decode(EmailSecurityRecord.self, forKey: .dkim)
        bimi = try container.decodeIfPresent(EmailSecurityRecord.self, forKey: .bimi)
            ?? EmailSecurityRecord(found: false, value: nil)
        mtaSts = try container.decodeIfPresent(MTASTSResult.self, forKey: .mtaSts)
    }
}

struct EmailSecurityRecord: Codable {
    let found: Bool
    let value: String?
    let matchedSelector: String?

    init(found: Bool, value: String?, matchedSelector: String? = nil) {
        self.found = found
        self.value = value
        self.matchedSelector = matchedSelector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = try container.decode(Bool.self, forKey: .found)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        matchedSelector = try container.decodeIfPresent(String.self, forKey: .matchedSelector)
    }
}

struct MTASTSResult: Codable {
    let txtFound: Bool
    let policyMode: String?
}

// MARK: - Redirect Chain Models

struct RedirectHop: Identifiable, Codable {
    var id = UUID()
    let stepNumber: Int
    let statusCode: Int
    let url: String
    let isFinal: Bool
}

// MARK: - Port Scan Models

enum PortScanKind: String, Codable {
    case standard
    case custom
}

struct PortScanResult: Identifiable, Codable {
    var id = UUID()
    let port: UInt16
    let service: String
    let open: Bool
    var banner: String?
    let kind: PortScanKind
    let durationMs: Int?

    nonisolated init(
        port: UInt16,
        service: String,
        open: Bool,
        banner: String? = nil,
        kind: PortScanKind = .standard,
        durationMs: Int? = nil
    ) {
        self.port = port
        self.service = service
        self.open = open
        self.banner = banner
        self.kind = kind
        self.durationMs = durationMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        port = try container.decode(UInt16.self, forKey: .port)
        service = try container.decode(String.self, forKey: .service)
        open = try container.decode(Bool.self, forKey: .open)
        banner = try container.decodeIfPresent(String.self, forKey: .banner)
        kind = try container.decodeIfPresent(PortScanKind.self, forKey: .kind) ?? .standard
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
    }
}

// MARK: - History Models

struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    let domain: String
    let timestamp: Date
    var trackedDomainID: UUID?
    var note: String?
    let dnsSections: [DNSSection]
    let sslInfo: SSLCertificateInfo?
    let httpHeaders: [HTTPHeader]
    let reachabilityResults: [PortReachability]
    let ipGeolocation: IPGeolocation?
    var emailSecurity: EmailSecurityResult?
    var mtaSts: MTASTSResult?
    var ownership: DomainOwnership?
    var ownershipHistory: [DomainOwnershipHistoryEvent]
    var inferredProvider: InferredProviderFingerprint?
    var priorProviders: [String]
    var domainClassification: DomainClassificationSummary?
    var ownershipTransitions: [OwnershipTransitionEvent]
    var hostingTransitions: [HostingTransitionEvent]
    var subdomainHistory: [SubdomainHistoryEntry]
    var riskSignals: [IntelligenceRiskSignal]
    var intelligenceTimeline: [IntelligenceTimelineEvent]
    var ptrRecord: String?
    var redirectChain: [RedirectHop]
    var subdomains: [DiscoveredSubdomain]
    var extendedSubdomains: [DiscoveredSubdomain]
    var dnsHistory: [DNSHistoryEvent]
    var domainPricing: DomainPricingInsight?
    var reputation: DomainReputationResult?
    var portScanResults: [PortScanResult]
    var hstsPreloaded: Bool?
    var availabilityResult: DomainAvailabilityResult?
    var suggestions: [DomainSuggestionResult]
    var appVersion: String
    var resultSource: LookupResultSource
    var dataSources: [String]
    var provenanceBySection: [LookupSectionKind: SectionProvenance]
    var availabilityConfidence: ConfidenceLevel?
    var ownershipConfidence: ConfidenceLevel?
    var subdomainConfidence: ConfidenceLevel?
    var emailSecurityConfidence: ConfidenceLevel?
    var geolocationConfidence: ConfidenceLevel?
    var errorDetails: [LookupSectionKind: InspectionFailure]
    var isPartialSnapshot: Bool
    var validationIssues: [String]
    var resolverDisplayName: String
    var resolverURLString: String
    var totalLookupDurationMs: Int?
    var primaryIP: String?
    var finalRedirectURL: String?
    var tlsStatusSummary: String?
    var emailSecuritySummary: String?
    var httpGradeSummary: String?
    var changeSummary: DomainChangeSummary?
    var snapshotIndex: Int?
    var previousSnapshotID: UUID?
    var changeCount: Int
    var severitySummary: ChangeSeverity?
    var sslError: String?
    var httpHeadersError: String?
    var reachabilityError: String?
    var ipGeolocationError: String?
    var emailSecurityError: String?
    var ownershipError: String?
    var ownershipHistoryError: String?
    var ptrError: String?
    var redirectChainError: String?
    var subdomainsError: String?
    var extendedSubdomainsError: String?
    var dnsHistoryError: String?
    var domainPricingError: String?
    var reputationError: String?
    var portScanError: String?

    // A full inspection produces 73 stored properties, and passing them as one
    // flat argument list made a 72-parameter initializer no call site could read
    // (SonarCloud swift:S107). They are grouped below by what they describe.
    //
    // The stored properties stay flat, deliberately. This type is persisted to
    // UserDefaults and read back out of backup files, and both decode paths drop
    // entries that will not parse rather than raising — so nesting a value would
    // change the encoded shape and silently discard history written by an older
    // build. These groups exist at the call boundary only; the JSON is unchanged,
    // which HistoryEntryCodableTests pins.

    /// What was inspected, and when.
    struct Identity {
        var domain: String
        var timestamp: Date
        var trackedDomainID: UUID? = nil
        var note: String? = nil
    }

    /// The live probe results for this snapshot.
    struct Inspection {
        var dnsSections: [DNSSection]
        var sslInfo: SSLCertificateInfo?
        var httpHeaders: [HTTPHeader]
        var reachabilityResults: [PortReachability]
        var ipGeolocation: IPGeolocation?
        var emailSecurity: EmailSecurityResult? = nil
        var mtaSts: MTASTSResult? = nil
        var ptrRecord: String? = nil
        var redirectChain: [RedirectHop] = []
        var subdomains: [DiscoveredSubdomain] = []
        var extendedSubdomains: [DiscoveredSubdomain] = []
        var dnsHistory: [DNSHistoryEvent] = []
        var portScanResults: [PortScanResult] = []
        var hstsPreloaded: Bool? = nil
        var availabilityResult: DomainAvailabilityResult? = nil
        var suggestions: [DomainSuggestionResult] = []

    }

    /// Who owns the domain and where it is hosted.
    struct Registration {
        var ownership: DomainOwnership? = nil
        var ownershipHistory: [DomainOwnershipHistoryEvent] = []
        var inferredProvider: InferredProviderFingerprint? = nil
        var priorProviders: [String] = []
        var domainClassification: DomainClassificationSummary? = nil
        var ownershipTransitions: [OwnershipTransitionEvent] = []
        var hostingTransitions: [HostingTransitionEvent] = []
        var domainPricing: DomainPricingInsight? = nil
    }

    /// Derived signals rather than direct observations.
    struct Intelligence {
        var subdomainHistory: [SubdomainHistoryEntry] = []
        var riskSignals: [IntelligenceRiskSignal] = []
        var intelligenceTimeline: [IntelligenceTimelineEvent] = []
        var reputation: DomainReputationResult? = nil
    }

    /// Where the data came from, and how much to trust it.
    struct Provenance {
        var appVersion: String = "2.7.0"
        var resultSource: LookupResultSource = .snapshot
        var dataSources: [String] = []
        var provenanceBySection: [LookupSectionKind: SectionProvenance] = [:]
        var availabilityConfidence: ConfidenceLevel? = nil
        var ownershipConfidence: ConfidenceLevel? = nil
        var subdomainConfidence: ConfidenceLevel? = nil
        var emailSecurityConfidence: ConfidenceLevel? = nil
        var geolocationConfidence: ConfidenceLevel? = nil
        var isPartialSnapshot: Bool = false
        var validationIssues: [String] = []
        var resolverDisplayName: String
        var resolverURLString: String
        var totalLookupDurationMs: Int? = nil

    }

    /// Precomputed display values and change tracking.
    struct Summary {
        var primaryIP: String? = nil
        var finalRedirectURL: String? = nil
        var tlsStatusSummary: String? = nil
        var emailSecuritySummary: String? = nil
        var httpGradeSummary: String? = nil
        var changeSummary: DomainChangeSummary? = nil
        var snapshotIndex: Int? = nil
        var previousSnapshotID: UUID? = nil
        var changeCount: Int = 0
        var severitySummary: ChangeSeverity? = nil
    }

    /// Per-section failures: a snapshot records what it could not collect.
    struct Failures {
        var errorDetails: [LookupSectionKind: InspectionFailure] = [:]
        var sslError: String? = nil
        var httpHeadersError: String? = nil
        var reachabilityError: String? = nil
        var ipGeolocationError: String? = nil
        var emailSecurityError: String? = nil
        var ownershipError: String? = nil
        var ownershipHistoryError: String? = nil
        var ptrError: String? = nil
        var redirectChainError: String? = nil
        var subdomainsError: String? = nil
        var extendedSubdomainsError: String? = nil
        var dnsHistoryError: String? = nil
        var domainPricingError: String? = nil
        var reputationError: String? = nil
        var portScanError: String? = nil

    }

    init(identity: Identity,
         inspection: Inspection,
         registration: Registration = Registration(),
         intelligence: Intelligence = Intelligence(),
         provenance: Provenance,
         summary: Summary = Summary(),
         failures: Failures = Failures()) {
        self.domain = identity.domain
        self.timestamp = identity.timestamp
        self.trackedDomainID = identity.trackedDomainID
        self.note = identity.note
        self.dnsSections = inspection.dnsSections
        self.sslInfo = inspection.sslInfo
        self.httpHeaders = inspection.httpHeaders
        self.reachabilityResults = inspection.reachabilityResults
        self.ipGeolocation = inspection.ipGeolocation
        self.emailSecurity = inspection.emailSecurity
        self.mtaSts = inspection.mtaSts ?? inspection.emailSecurity?.mtaSts
        self.ptrRecord = inspection.ptrRecord
        self.redirectChain = inspection.redirectChain
        self.subdomains = inspection.subdomains
        self.extendedSubdomains = inspection.extendedSubdomains
        self.dnsHistory = inspection.dnsHistory
        self.portScanResults = inspection.portScanResults
        self.hstsPreloaded = inspection.hstsPreloaded
        self.availabilityResult = inspection.availabilityResult
        self.suggestions = inspection.suggestions
        self.ownership = registration.ownership
        self.ownershipHistory = registration.ownershipHistory
        self.inferredProvider = registration.inferredProvider
        self.priorProviders = registration.priorProviders
        self.domainClassification = registration.domainClassification
        self.ownershipTransitions = registration.ownershipTransitions
        self.hostingTransitions = registration.hostingTransitions
        self.domainPricing = registration.domainPricing
        self.subdomainHistory = intelligence.subdomainHistory
        self.riskSignals = intelligence.riskSignals
        self.intelligenceTimeline = intelligence.intelligenceTimeline
        self.reputation = intelligence.reputation
        self.appVersion = provenance.appVersion
        self.resultSource = provenance.resultSource
        self.dataSources = provenance.dataSources
        self.provenanceBySection = provenance.provenanceBySection
        self.availabilityConfidence = provenance.availabilityConfidence
        self.ownershipConfidence = provenance.ownershipConfidence
        self.subdomainConfidence = provenance.subdomainConfidence
        self.emailSecurityConfidence = provenance.emailSecurityConfidence
        self.geolocationConfidence = provenance.geolocationConfidence
        self.isPartialSnapshot = provenance.isPartialSnapshot
        self.validationIssues = provenance.validationIssues
        self.resolverDisplayName = provenance.resolverDisplayName
        self.resolverURLString = provenance.resolverURLString
        self.totalLookupDurationMs = provenance.totalLookupDurationMs
        self.primaryIP = summary.primaryIP
        self.finalRedirectURL = summary.finalRedirectURL
        self.tlsStatusSummary = summary.tlsStatusSummary
        self.emailSecuritySummary = summary.emailSecuritySummary
        self.httpGradeSummary = summary.httpGradeSummary
        self.changeSummary = summary.changeSummary
        self.snapshotIndex = summary.snapshotIndex
        self.previousSnapshotID = summary.previousSnapshotID
        self.changeCount = summary.changeCount
        self.severitySummary = summary.severitySummary
        self.errorDetails = failures.errorDetails
        self.sslError = failures.sslError
        self.httpHeadersError = failures.httpHeadersError
        self.reachabilityError = failures.reachabilityError
        self.ipGeolocationError = failures.ipGeolocationError
        self.emailSecurityError = failures.emailSecurityError
        self.ownershipError = failures.ownershipError
        self.ownershipHistoryError = failures.ownershipHistoryError
        self.ptrError = failures.ptrError
        self.redirectChainError = failures.redirectChainError
        self.subdomainsError = failures.subdomainsError
        self.extendedSubdomainsError = failures.extendedSubdomainsError
        self.dnsHistoryError = failures.dnsHistoryError
        self.domainPricingError = failures.domainPricingError
        self.reputationError = failures.reputationError
        self.portScanError = failures.portScanError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? "unknown-domain"
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? .distantPast
        trackedDomainID = try container.decodeIfPresent(UUID.self, forKey: .trackedDomainID)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        dnsSections = try container.decodeIfPresent([DNSSection].self, forKey: .dnsSections) ?? []
        sslInfo = try container.decodeIfPresent(SSLCertificateInfo.self, forKey: .sslInfo)
        httpHeaders = try container.decodeIfPresent([HTTPHeader].self, forKey: .httpHeaders) ?? []
        reachabilityResults = try container.decodeIfPresent([PortReachability].self, forKey: .reachabilityResults) ?? []
        ipGeolocation = try container.decodeIfPresent(IPGeolocation.self, forKey: .ipGeolocation)
        emailSecurity = try container.decodeIfPresent(EmailSecurityResult.self, forKey: .emailSecurity)
        mtaSts = try container.decodeIfPresent(MTASTSResult.self, forKey: .mtaSts) ?? emailSecurity?.mtaSts
        ownership = try container.decodeIfPresent(DomainOwnership.self, forKey: .ownership)
        ownershipHistory = try container.decodeIfPresent([DomainOwnershipHistoryEvent].self, forKey: .ownershipHistory) ?? []
        inferredProvider = try container.decodeIfPresent(InferredProviderFingerprint.self, forKey: .inferredProvider)
        priorProviders = try container.decodeIfPresent([String].self, forKey: .priorProviders) ?? []
        domainClassification = try container.decodeIfPresent(DomainClassificationSummary.self, forKey: .domainClassification)
        ownershipTransitions = try container.decodeIfPresent([OwnershipTransitionEvent].self, forKey: .ownershipTransitions) ?? []
        hostingTransitions = try container.decodeIfPresent([HostingTransitionEvent].self, forKey: .hostingTransitions) ?? []
        subdomainHistory = try container.decodeIfPresent([SubdomainHistoryEntry].self, forKey: .subdomainHistory) ?? []
        riskSignals = try container.decodeIfPresent([IntelligenceRiskSignal].self, forKey: .riskSignals) ?? []
        intelligenceTimeline = try container.decodeIfPresent([IntelligenceTimelineEvent].self, forKey: .intelligenceTimeline) ?? []
        ptrRecord = try container.decodeIfPresent(String.self, forKey: .ptrRecord)
        redirectChain = try container.decodeIfPresent([RedirectHop].self, forKey: .redirectChain) ?? []
        subdomains = try container.decodeIfPresent([DiscoveredSubdomain].self, forKey: .subdomains) ?? []
        extendedSubdomains = try container.decodeIfPresent([DiscoveredSubdomain].self, forKey: .extendedSubdomains) ?? []
        dnsHistory = try container.decodeIfPresent([DNSHistoryEvent].self, forKey: .dnsHistory) ?? []
        domainPricing = try container.decodeIfPresent(DomainPricingInsight.self, forKey: .domainPricing)
        reputation = try container.decodeIfPresent(DomainReputationResult.self, forKey: .reputation)
        portScanResults = try container.decodeIfPresent([PortScanResult].self, forKey: .portScanResults) ?? []
        hstsPreloaded = try container.decodeIfPresent(Bool.self, forKey: .hstsPreloaded)
        availabilityResult = try container.decodeIfPresent(DomainAvailabilityResult.self, forKey: .availabilityResult)
        suggestions = try container.decodeIfPresent([DomainSuggestionResult].self, forKey: .suggestions) ?? []
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? "2.6.0"
        resultSource = try container.decodeIfPresent(LookupResultSource.self, forKey: .resultSource) ?? .snapshot
        dataSources = try container.decodeIfPresent([String].self, forKey: .dataSources) ?? []
        provenanceBySection = try container.decodeIfPresent([LookupSectionKind: SectionProvenance].self, forKey: .provenanceBySection) ?? [:]
        availabilityConfidence = try container.decodeIfPresent(ConfidenceLevel.self, forKey: .availabilityConfidence)
        ownershipConfidence = try container.decodeIfPresent(ConfidenceLevel.self, forKey: .ownershipConfidence)
        subdomainConfidence = try container.decodeIfPresent(ConfidenceLevel.self, forKey: .subdomainConfidence)
        emailSecurityConfidence = try container.decodeIfPresent(ConfidenceLevel.self, forKey: .emailSecurityConfidence)
        geolocationConfidence = try container.decodeIfPresent(ConfidenceLevel.self, forKey: .geolocationConfidence)
        errorDetails = try container.decodeIfPresent([LookupSectionKind: InspectionFailure].self, forKey: .errorDetails) ?? [:]
        validationIssues = try container.decodeIfPresent([String].self, forKey: .validationIssues) ?? HistoryEntry.defaultValidationIssues(domain: domain, timestamp: timestamp)
        isPartialSnapshot = try container.decodeIfPresent(Bool.self, forKey: .isPartialSnapshot) ?? !validationIssues.isEmpty
        resolverDisplayName = try container.decodeIfPresent(String.self, forKey: .resolverDisplayName) ?? "Cloudflare"
        resolverURLString = try container.decodeIfPresent(String.self, forKey: .resolverURLString) ?? DNSResolverOption.defaultURLString
        totalLookupDurationMs = try container.decodeIfPresent(Int.self, forKey: .totalLookupDurationMs)
        primaryIP = try container.decodeIfPresent(String.self, forKey: .primaryIP)
        finalRedirectURL = try container.decodeIfPresent(String.self, forKey: .finalRedirectURL)
        tlsStatusSummary = try container.decodeIfPresent(String.self, forKey: .tlsStatusSummary)
        emailSecuritySummary = try container.decodeIfPresent(String.self, forKey: .emailSecuritySummary)
        httpGradeSummary = try container.decodeIfPresent(String.self, forKey: .httpGradeSummary)
        changeSummary = try container.decodeIfPresent(DomainChangeSummary.self, forKey: .changeSummary)
        snapshotIndex = try container.decodeIfPresent(Int.self, forKey: .snapshotIndex)
        previousSnapshotID = try container.decodeIfPresent(UUID.self, forKey: .previousSnapshotID)
        changeCount = try container.decodeIfPresent(Int.self, forKey: .changeCount)
            ?? changeSummary?.changedSections.count
            ?? 0
        severitySummary = try container.decodeIfPresent(ChangeSeverity.self, forKey: .severitySummary)
            ?? changeSummary?.severity
        sslError = try container.decodeIfPresent(String.self, forKey: .sslError)
        httpHeadersError = try container.decodeIfPresent(String.self, forKey: .httpHeadersError)
        reachabilityError = try container.decodeIfPresent(String.self, forKey: .reachabilityError)
        ipGeolocationError = try container.decodeIfPresent(String.self, forKey: .ipGeolocationError)
        emailSecurityError = try container.decodeIfPresent(String.self, forKey: .emailSecurityError)
        ownershipError = try container.decodeIfPresent(String.self, forKey: .ownershipError)
        ownershipHistoryError = try container.decodeIfPresent(String.self, forKey: .ownershipHistoryError)
        ptrError = try container.decodeIfPresent(String.self, forKey: .ptrError)
        redirectChainError = try container.decodeIfPresent(String.self, forKey: .redirectChainError)
        subdomainsError = try container.decodeIfPresent(String.self, forKey: .subdomainsError)
        extendedSubdomainsError = try container.decodeIfPresent(String.self, forKey: .extendedSubdomainsError)
        dnsHistoryError = try container.decodeIfPresent(String.self, forKey: .dnsHistoryError)
        domainPricingError = try container.decodeIfPresent(String.self, forKey: .domainPricingError)
        reputationError = try container.decodeIfPresent(String.self, forKey: .reputationError)
        portScanError = try container.decodeIfPresent(String.self, forKey: .portScanError)
    }

    private static func defaultValidationIssues(domain: String, timestamp: Date) -> [String] {
        var issues: [String] = []
        if domain == "unknown-domain" {
            issues.append("Missing domain in stored snapshot")
        }
        if timestamp == .distantPast {
            issues.append("Missing collection timestamp in stored snapshot")
        }
        return issues
    }

    var snapshotSummary: SnapshotSummary {
        SnapshotSummary(
            id: id,
            domain: domain,
            timestamp: timestamp,
            trackedDomainID: trackedDomainID,
            snapshotIndex: snapshotIndex,
            previousSnapshotID: previousSnapshotID,
            changeCount: changeCount,
            severitySummary: severitySummary ?? changeSummary?.severity,
            changeSummaryMessage: changeSummary?.message,
            availability: availabilityResult?.status,
            primaryIP: primaryIP,
            tlsStatus: tlsStatusSummary,
            riskScore: changeSummary?.riskAssessment?.score,
            historyEntryID: id
        )
    }
}

// MARK: - Cloudflare DNS-over-HTTPS Response

struct CloudflareDNSResponse: Decodable {
    let status: Int
    let authenticatedData: Bool?
    let answer: [CloudflareDNSAnswer]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case authenticatedData = "AD"
        case answer = "Answer"
    }

    struct CloudflareDNSAnswer: Decodable {
        let name: String
        let type: Int
        let ttl: Int
        let data: String

        enum CodingKeys: String, CodingKey {
            case name, type
            case ttl = "TTL"
            case data
        }
    }
}

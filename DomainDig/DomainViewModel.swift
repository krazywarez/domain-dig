import Foundation
import SwiftUI
import UserNotifications

enum ResultTone {
    case primary
    case secondary
    case success
    case warning
    case failure
}

struct SummaryFieldViewData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let tone: ResultTone
}

/// How VoiceOver should pronounce a row's value.
///
/// DNS records, cipher suites, and the like are read as prose by default, which
/// mangles load-bearing punctuation (`;`, `~`, `_`) and technical tokens. See
/// `Docs/ACCESSIBILITY.md`.
enum RowSpeechStyle {
    /// Normal prose.
    case plain
    /// Record values and identifiers: include punctuation, use code heuristics.
    case technical
}

struct InfoRowViewData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let tone: ResultTone
    var speechStyle: RowSpeechStyle = .plain
}

struct SectionMessageViewData {
    let text: String
    let isError: Bool
}

struct DNSRecordSectionViewData: Identifiable {
    let id = UUID()
    let title: String
    let rows: [InfoRowViewData]
    let wildcardRows: [InfoRowViewData]
    let wildcardTitle: String?
    let message: SectionMessageViewData?
}

struct EmailRowViewData: Identifiable {
    let id = UUID()
    let label: String
    let status: String
    let statusTone: ResultTone
    let detail: String
    let auxiliaryDetail: String?
}

struct RedirectHopViewData: Identifiable {
    let id = UUID()
    let stepLabel: String
    let statusCode: String
    let url: String
    let isFinal: Bool
}

struct ReachabilityRowViewData: Identifiable {
    let id = UUID()
    let portLabel: String
    let latencyLabel: String
    let statusLabel: String
    let statusTone: ResultTone
}

struct PortScanRowViewData: Identifiable {
    let id = UUID()
    let portLabel: String
    let service: String
    let statusLabel: String
    let statusTone: ResultTone
    let banner: String?
    let durationLabel: String?
}

struct SubdomainRowViewData: Identifiable {
    let id: String
    let hostname: String
    let isInteresting: Bool

    init(hostname: String, isInteresting: Bool) {
        self.id = hostname
        self.hostname = hostname
        self.isInteresting = isInteresting
    }
}

struct DomainSuggestionViewData: Identifiable {
    let id: UUID
    let domain: String
    let availabilityStatus: DomainAvailabilityStatus
    let status: String
    let tone: ResultTone
}

private struct BatchLookupPayload {
    let snapshot: LookupSnapshot
}

struct PortfolioDomainStatus: Identifiable {
    let trackedDomain: TrackedDomain
    let latestEntry: HistoryEntry?
    let report: DomainReport
    let apexDomain: String
    let health: DomainHealth
    let lastChangeDate: Date?
    let lastMonitoringFailure: Date?
    let instabilityScore: Int
    let certificateExpiryState: CertificateWarningLevel
    let certificateDaysRemaining: Int?
    let isUnreachable: Bool
    let recentDNSChange: Bool
    let recentCriticalChange: Bool
    let recentFailureCount: Int

    var id: UUID { trackedDomain.id }
}

struct PortfolioActivityItem: Identifiable {
    let id: String
    let trackedDomainID: UUID
    let domain: String
    let message: String
    let timestamp: Date
    let health: DomainHealth
    let systemImage: String
}

struct PortfolioAttentionItem: Identifiable {
    let id: String
    let trackedDomainID: UUID
    let domain: String
    let reason: String
    let timestamp: Date
    let health: DomainHealth
}

struct PortfolioGroup: Identifiable {
    let apexDomain: String
    let domains: [PortfolioDomainStatus]

    var id: String { apexDomain }
}

struct PortfolioDashboardData {
    let snapshot: PortfolioSnapshot
    let domainStates: [PortfolioDomainStatus]
    let recentActivity: [PortfolioActivityItem]
    let attentionRequired: [PortfolioAttentionItem]
    let expiringSoon: [PortfolioDomainStatus]
    let groups: [PortfolioGroup]
}

private struct PortfolioDashboardStamp: Equatable {
    let trackedDomainSignature: [String]
    let historySignature: [String]
    let monitoringSignature: [String]
}

@MainActor
@Observable
final class DomainViewModel {
    var domain: String = ""
    var bulkInput: String = ""

    var dnsSections: [DNSSection] = []
    var dnsLoading = false
    var dnsError: String?
    var availabilityResult: DomainAvailabilityResult?
    var availabilityLoading = false
    var suggestions: [DomainSuggestionResult] = []
    var suggestionsLoading = false

    var sslInfo: SSLCertificateInfo?
    var sslLoading = false
    var sslError: String?
    var hstsPreloaded: Bool?
    var hstsLoading = false

    var httpHeaders: [HTTPHeader] = []
    var httpSecurityGrade: String?
    var httpStatusCode: Int?
    var httpResponseTimeMs: Int?
    var httpProtocol: String?
    var http3Advertised = false
    var httpHeadersLoading = false
    var httpHeadersError: String?

    var reachabilityResults: [PortReachability] = []
    var reachabilityLoading = false
    var reachabilityError: String?

    var ipGeolocation: IPGeolocation?
    var ipGeolocationLoading = false
    var ipGeolocationError: String?

    var emailSecurity: EmailSecurityResult?
    var emailSecurityLoading = false
    var emailSecurityError: String?

    var ownershipResult: DomainOwnership?
    var ownershipLoading = false
    var ownershipError: String?
    var ownershipHistory: [DomainOwnershipHistoryEvent] = []
    var ownershipHistoryLoading = false
    var ownershipHistoryError: String?

    var ptrRecord: String?
    var ptrLoading = false
    var ptrError: String?

    var redirectChain: [RedirectHop] = []
    var redirectChainLoading = false
    var redirectChainError: String?

    var subdomains: [DiscoveredSubdomain] = []
    var subdomainsLoading = false
    var subdomainsError: String?
    var extendedSubdomains: [DiscoveredSubdomain] = []
    var extendedSubdomainsLoading = false
    var extendedSubdomainsError: String?
    var dnsHistory: [DNSHistoryEvent] = []
    var dnsHistoryLoading = false
    var dnsHistoryError: String?
    var domainPricing: DomainPricingInsight?
    var domainPricingLoading = false
    var domainPricingError: String?
    var reputation: DomainReputationResult?
    var reputationLoading = false
    var reputationError: String?
    var usageCredits: [UsageCreditFeature: UsageCreditStatus] = DomainViewModel.defaultUsageCredits()

    var portScanResults: [PortScanResult] = []
    var portScanLoading = false
    var portScanError: String?
    var customPortResults: [PortScanResult] = []
    var customPortScanLoading = false
    var customPortScanError: String?

    var hasRun = false
    private(set) var searchedDomain: String = ""
    private(set) var lastLookupDurationMs: Int?
    private(set) var currentDiffSections: [DomainDiffSection] = []
    private(set) var currentChangeSummary: DomainChangeSummary?
    private(set) var ownershipDiff: [DomainDiffItem] = []
    private(set) var refreshingTrackedDomainID: UUID?
    private(set) var rerunNavigationToken = UUID()
    private(set) var batchResults: [BatchLookupResult] = []
    private(set) var batchLookupSource: BatchLookupSource = .manual
    private(set) var batchCurrentDomain: String?
    private(set) var batchCompletedCount = 0
    private(set) var batchTotalCount = 0
    private(set) var batchLookupRunning = false
    var latestBatchSweepSummary: BatchSweepSummary?
    var latestWorkflowRunSummary: WorkflowRunSummary?
    private(set) var notificationsAuthorized = false

    private var lookupTask: Task<Void, Never>?
    private var customPortScanTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var activeLookupID = UUID()
    private var lookupStartedAt: Date?
    private var activeBatchDomains: [String] = []
    private var lastBatchStartedAt: Date?
    var activeWorkflowRunID: UUID?
    var activeWorkflowRunName: String?
    private var historyPersistenceSuspended = false
    private var trackedDomainsPersistenceSuspended = false
    private var historyPersistenceDirty = false
    private var trackedDomainsPersistenceDirty = false
    private let reportBuilder = DomainReportBuilder()
    private let inspectionService = DomainInspectionService()
    private var cachedPortfolioDashboardData: PortfolioDashboardData?
    private var cachedPortfolioDashboardStamp: PortfolioDashboardStamp?
    private(set) var currentResultSource: LookupResultSource = .live
    private(set) var currentCachedSections: [LookupSectionKind] = []
    private(set) var currentStatusMessage: String?
    private(set) var currentSnapshotTimestamp = Date()
    private(set) var currentHistoryEntryID: UUID?
    private(set) var currentReport: DomainReport?

    private static let recentSearchesKey = "recentSearches"
    private static let maxRecent = 20
    var recentSearches: [String] = DomainDataPortabilityService.loadRecentSearches()

    private static let savedDomainsKey = "savedDomains"
    var savedDomains: [String] = DomainDataPortabilityService.loadSavedDomains()

    private static let trackedDomainsKey = "trackedDomains"
    private static let legacyWatchedDomainsKey = "watchedDomains"
    var trackedDomains: [TrackedDomain] = DomainViewModel.loadTrackedDomains()

    private static let historyKey = "lookupHistory"
    private static let maxHistory = 250
    var history: [HistoryEntry] = DomainViewModel.loadHistoryEntries()
    var auditSessions: [AuditSession] = DomainDataPortabilityService.loadAuditSessions()
    private static let workflowsKey = "domainWorkflows"
    var workflows: [DomainWorkflow] = DomainViewModel.loadWorkflows()
    var historySearchText = ""
    var historyDateFilter: HistoryDateFilter = .all
    var historyChangeFilter: ChangeFilterOption = .all
    var historySortOption: HistorySortOption = .newest
    var timelineGrouping: TimelineGroupingOption = .relativeDay
    var timelineDomainFilter = ""
    var watchlistSearchText = ""
    var watchlistFilter: WatchlistFilterOption = .all
    var watchlistSortOption: WatchlistSortOption = .pinned
    var watchlistTagFilter: String?
    var watchlistSavedViews: [WatchlistSavedView] = DomainViewModel.loadWatchlistSavedViews()
    var dashboardSearchText = ""
    var dashboardFilter: PortfolioFilterOption = .all
    var monitoringSettings: MonitoringSettings = MonitoringStorage.loadSettings()
    var monitoringLogs: [MonitoringLog] = MonitoringStorage.loadLogs()
    var monitoringRunInProgress = false
    var monitoringStatusMessage: String?
    var monitoringNotificationStatus: UNAuthorizationStatus = .notDetermined
    var dataLifecycleSummary = DomainDataPortabilityService.lifecycleSummary()
    var portabilityStatusMessage: String?
    var upgradePrompt: UpgradePromptContext?
    var isPaywallPresented = false
    var selectedSnapshotIDs = Set<UUID>()
    var activeDomainDiff: DomainDiff?
    var activeDiffChangeIndex = 0

    private static let historyAutoPruneKey = "historyAutoPrune"
    var historyAutoPruneOption: HistoryAutoPruneOption = DomainViewModel.loadHistoryAutoPruneOption()

    var trimmedDomain: String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first ?? ""
    }

    var resultsLoaded: Bool {
        hasRun &&
            !dnsLoading &&
            !availabilityLoading &&
            !suggestionsLoading &&
            !sslLoading &&
            !hstsLoading &&
            !httpHeadersLoading &&
            !reachabilityLoading &&
            !ipGeolocationLoading &&
            !emailSecurityLoading &&
            !ownershipLoading &&
            !ptrLoading &&
            !redirectChainLoading &&
            !subdomainsLoading &&
            !portScanLoading &&
            !customPortScanLoading
    }

    var activeLoadingLabels: [String] {
        var labels: [String] = []
        if availabilityLoading { labels.append("Availability") }
        if dnsLoading { labels.append("DNS") }
        if sslLoading || hstsLoading { labels.append("TLS") }
        if httpHeadersLoading { labels.append("HTTP") }
        if ownershipLoading { labels.append("Ownership") }
        if ownershipHistoryLoading { labels.append("Ownership History") }
        if emailSecurityLoading { labels.append("Email") }
        if subdomainsLoading { labels.append("Subdomains") }
        if extendedSubdomainsLoading { labels.append("Extended Subdomains") }
        if dnsHistoryLoading { labels.append("DNS History") }
        if domainPricingLoading { labels.append("Pricing") }
        if redirectChainLoading { labels.append("Redirects") }
        if reachabilityLoading { labels.append("Reachability") }
        if ipGeolocationLoading { labels.append("Geolocation") }
        if ptrLoading { labels.append("PTR") }
        if portScanLoading { labels.append("Port Scan") }
        if customPortScanLoading { labels.append("Custom Ports") }
        return labels
    }

    var isCloudflareProxied: Bool {
        httpHeaders.contains { $0.name.lowercased() == "cf-ray" }
    }

    var isCurrentDomainSaved: Bool {
        !searchedDomain.isEmpty && savedDomains.contains(where: { $0.lowercased() == searchedDomain.lowercased() })
    }

    var sortedTrackedDomains: [TrackedDomain] {
        sortedTrackedDomains(from: trackedDomains, using: .pinned)
    }

    var filteredHistory: [HistoryEntry] {
        let calendar = Calendar.current
        let now = Date()
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return history
            .lazy
            .filter { entry in
                query.isEmpty || entry.domain.localizedCaseInsensitiveContains(query)
            }
            .filter { entry in
                switch self.historyDateFilter {
                case .today:
                    return calendar.isDate(entry.timestamp, inSameDayAs: now)
                case .last7Days:
                    guard let startDate = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
                    return entry.timestamp >= startDate
                case .all:
                    return true
                }
            }
            .filter { entry in
                switch self.historyChangeFilter {
                case .all:
                    return true
                case .changed:
                    return entry.changeSummary?.hasChanges == true
                case .unchanged:
                    return entry.changeSummary?.hasChanges != true
                }
            }
            .sorted(by: historySortPredicate)
    }

    var filteredTrackedDomains: [TrackedDomain] {
        let query = watchlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trackedDomains.filter { trackedDomain in
            if !query.isEmpty, !trackedDomain.domain.localizedCaseInsensitiveContains(query) {
                return false
            }

            if let watchlistTagFilter, !trackedDomain.tags.contains(watchlistTagFilter) {
                return false
            }

            switch watchlistFilter {
            case .all:
                return true
            case .pinnedOnly:
                return trackedDomain.isPinned
            case .changedOnly:
                return trackedDomain.lastChangeSummary?.hasChanges == true
            }
        }

        return sortedTrackedDomains(from: filtered, using: watchlistSortOption)
    }

    var portfolioDashboardData: PortfolioDashboardData {
        let stamp = portfolioDashboardStamp()
        if let cachedPortfolioDashboardData, cachedPortfolioDashboardStamp == stamp {
            return cachedPortfolioDashboardData
        }

        let domainStates = buildPortfolioDomainStates()
        let recentActivity = buildPortfolioActivity(from: domainStates)
        let attentionRequired = buildAttentionQueue(from: domainStates)
        let expiringSoon = domainStates
            .filter { $0.certificateExpiryState != .none }
            .sorted {
                ($0.certificateDaysRemaining ?? .max, $0.trackedDomain.domain)
                    < ($1.certificateDaysRemaining ?? .max, $1.trackedDomain.domain)
            }
        let groups = buildPortfolioGroups(from: domainStates)
        let snapshot = PortfolioSnapshot(
            totalDomains: domainStates.count,
            healthyCount: domainStates.filter { $0.health == .healthy }.count,
            warningCount: domainStates.filter { $0.health == .warning }.count,
            criticalCount: domainStates.filter { $0.health == .critical }.count,
            changedLast24h: domainStates.filter {
                guard let lastChangeDate = $0.lastChangeDate else { return false }
                return Date().timeIntervalSince(lastChangeDate) <= 24 * 60 * 60
            }.count,
            expiringSoonCount: expiringSoon.count,
            unreachableCount: domainStates.filter(\.isUnreachable).count
        )
        let data = PortfolioDashboardData(
            snapshot: snapshot,
            domainStates: domainStates,
            recentActivity: recentActivity,
            attentionRequired: attentionRequired,
            expiringSoon: expiringSoon,
            groups: groups
        )
        cachedPortfolioDashboardStamp = stamp
        cachedPortfolioDashboardData = data
        return data
    }

    var filteredPortfolioDomainStates: [PortfolioDomainStatus] {
        let query = dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return portfolioDashboardData.domainStates.filter { state in
            matchesPortfolioFilter(state) && matchesDashboardSearch(state, query: query)
        }
    }

    var filteredPortfolioGroups: [PortfolioGroup] {
        buildPortfolioGroups(from: filteredPortfolioDomainStates)
    }

    var filteredPortfolioRecentActivity: [PortfolioActivityItem] {
        let visibleDomainIDs = Set(filteredPortfolioDomainStates.map(\.trackedDomain.id))
        return portfolioDashboardData.recentActivity.filter { visibleDomainIDs.contains($0.trackedDomainID) }
    }

    var filteredPortfolioAttentionRequired: [PortfolioAttentionItem] {
        let visibleDomainIDs = Set(filteredPortfolioDomainStates.map(\.trackedDomain.id))
        return portfolioDashboardData.attentionRequired.filter { visibleDomainIDs.contains($0.trackedDomainID) }
    }

    var filteredPortfolioExpiringSoon: [PortfolioDomainStatus] {
        let visibleDomainIDs = Set(filteredPortfolioDomainStates.map(\.trackedDomain.id))
        return portfolioDashboardData.expiringSoon.filter { visibleDomainIDs.contains($0.trackedDomain.id) }
    }

    var timelineDomains: [String] {
        let query = timelineDomainFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let domains = history.map(\.domain)
        let filtered = query.isEmpty
            ? domains
            : domains.filter { $0.localizedCaseInsensitiveContains(query) }
        return Array(Set(filtered)).sorted()
    }

    var batchProgressLabel: String {
        guard batchTotalCount > 0 else { return "No active batch" }
        if !batchLookupRunning, batchCompletedCount >= batchTotalCount {
            return "\(batchCompletedCount)/\(batchTotalCount) • Complete"
        }
        let domainLabel = activeBatchDomains.first ?? batchCurrentDomain ?? "Preparing"
        return "\(batchCompletedCount)/\(batchTotalCount) • \(domainLabel)"
    }

    var currentBatchResultEntries: [HistoryEntry] {
        batchResults.compactMap { result in
            guard let historyEntryID = result.historyEntryID else { return nil }
            return history.first(where: { $0.id == historyEntryID })
        }
    }

    var currentTrackedDomain: TrackedDomain? {
        guard !searchedDomain.isEmpty else { return nil }
        return trackedDomain(for: searchedDomain)
    }

    var currentDomainWorkflows: [DomainWorkflow] {
        guard !searchedDomain.isEmpty else { return [] }
        return workflowsContaining(domain: searchedDomain)
    }

    var isCurrentDomainTracked: Bool {
        currentTrackedDomain != nil
    }

    var trackingLimitMessage: String? {
        FeatureAccessService.trackedDomainLimitMessage(currentCount: trackedDomains.count)
    }

    var canTrackCurrentDomain: Bool {
        FeatureAccessService.canAddTrackedDomain(currentCount: trackedDomains.count)
    }

    var resolverDisplayName: String {
        DNSLookupService.currentResolverDisplayName()
    }

    var resolverURLString: String {
        DNSLookupService.currentResolverURLString()
    }

    var allPortScanResults: [PortScanResult] {
        (portScanResults + customPortResults).sorted {
            if $0.kind == $1.kind {
                return $0.port < $1.port
            }
            return $0.kind == .standard
        }
    }

    var currentSnapshot: LookupSnapshot {
        LookupSnapshot(
            historyEntryID: currentHistoryEntryID,
            domain: searchedDomain,
            timestamp: currentSnapshotTimestamp,
            trackedDomainID: currentTrackedDomain?.id,
            note: currentHistoryEntry?.note ?? currentTrackedDomain?.note,
            appVersion: AppVersion.current,
            resolverDisplayName: resolverDisplayName,
            resolverURLString: resolverURLString,
            dataSources: currentHistoryEntry?.dataSources ?? [],
            provenanceBySection: currentHistoryEntry?.provenanceBySection ?? [:],
            availabilityConfidence: currentHistoryEntry?.availabilityConfidence,
            ownershipConfidence: currentHistoryEntry?.ownershipConfidence,
            subdomainConfidence: currentHistoryEntry?.subdomainConfidence,
            emailSecurityConfidence: currentHistoryEntry?.emailSecurityConfidence,
            geolocationConfidence: currentHistoryEntry?.geolocationConfidence,
            errorDetails: currentHistoryEntry?.errorDetails ?? [:],
            isPartialSnapshot: currentHistoryEntry?.isPartialSnapshot ?? false,
            validationIssues: currentHistoryEntry?.validationIssues ?? [],
            totalLookupDurationMs: lastLookupDurationMs,
            snapshotIndex: currentHistoryEntry?.snapshotIndex,
            previousSnapshotID: currentHistoryEntry?.previousSnapshotID,
            changeCount: currentHistoryEntry?.changeCount ?? currentChangeSummary?.changedSections.count ?? 0,
            severitySummary: currentHistoryEntry?.severitySummary ?? currentChangeSummary?.severity,
            dnsSections: dnsSections,
            dnsError: dnsError,
            availabilityResult: availabilityResult,
            suggestions: suggestions,
            sslInfo: sslInfo,
            sslError: sslError,
            hstsPreloaded: hstsPreloaded,
            httpHeaders: httpHeaders,
            httpSecurityGrade: httpSecurityGrade,
            httpStatusCode: httpStatusCode,
            httpResponseTimeMs: httpResponseTimeMs,
            httpProtocol: httpProtocol,
            http3Advertised: http3Advertised,
            httpHeadersError: httpHeadersError,
            reachabilityResults: reachabilityResults,
            reachabilityError: reachabilityError,
            ipGeolocation: ipGeolocation,
            ipGeolocationError: ipGeolocationError,
            emailSecurity: emailSecurity,
            emailSecurityError: emailSecurityError,
            ownership: ownershipResult,
            ownershipError: ownershipError,
            ownershipHistory: ownershipHistory,
            ownershipHistoryError: ownershipHistoryError,
            inferredProvider: currentHistoryEntry?.inferredProvider ?? currentReport?.inferredProvider,
            priorProviders: currentHistoryEntry?.priorProviders ?? currentReport?.priorProviders ?? [],
            domainClassification: currentHistoryEntry?.domainClassification ?? currentReport?.domainClassification,
            ownershipTransitions: currentHistoryEntry?.ownershipTransitions ?? currentReport?.ownershipTransitions ?? [],
            hostingTransitions: currentHistoryEntry?.hostingTransitions ?? currentReport?.hostingTransitions ?? [],
            subdomainHistory: currentHistoryEntry?.subdomainHistory ?? currentReport?.subdomainHistory ?? [],
            riskSignals: currentHistoryEntry?.riskSignals ?? currentReport?.riskSignals ?? [],
            intelligenceTimeline: currentHistoryEntry?.intelligenceTimeline ?? currentReport?.intelligenceTimeline ?? [],
            ptrRecord: ptrRecord,
            ptrError: ptrError,
            redirectChain: redirectChain,
            redirectChainError: redirectChainError,
            subdomains: subdomains,
            subdomainsError: subdomainsError,
            extendedSubdomains: extendedSubdomains,
            extendedSubdomainsError: extendedSubdomainsError,
            dnsHistory: dnsHistory,
            dnsHistoryError: dnsHistoryError,
            domainPricing: domainPricing,
            domainPricingError: domainPricingError,
            reputation: reputation,
            reputationError: reputationError,
            portScanResults: allPortScanResults,
            portScanError: combinedPortScanError,
            changeSummary: currentChangeSummary,
            resultSource: currentResultSource,
            cachedSections: currentCachedSections,
            statusMessage: currentStatusMessage
        )
    }

    private var currentHistoryEntry: HistoryEntry? {
        guard let currentHistoryEntryID else { return nil }
        return history.first(where: { $0.id == currentHistoryEntryID })
    }

    var currentRiskAssessment: DomainRiskAssessment? {
        currentReport?.riskAssessment
    }

    var currentInsights: [String] {
        currentReport?.insights ?? []
    }

    var currentSubdomainGroups: [SubdomainGroup] {
        currentReport?.subdomainGroups ?? []
    }

    var currentDNSPatterns: DNSPatternSummary? {
        currentReport?.dns.patternSummary
    }

    var currentEmailAssessment: EmailSecuritySummary? {
        currentReport?.email
    }

    var currentTLSSummary: WebResultSummary? {
        currentReport?.web
    }

    var ownershipHistoryCreditStatus: UsageCreditStatus {
        usageCredits[.ownershipHistory] ?? Self.fallbackCreditStatus(for: .ownershipHistory)
    }

    var dnsHistoryCreditStatus: UsageCreditStatus {
        usageCredits[.dnsHistory] ?? Self.fallbackCreditStatus(for: .dnsHistory)
    }

    var extendedSubdomainsCreditStatus: UsageCreditStatus {
        usageCredits[.extendedSubdomains] ?? Self.fallbackCreditStatus(for: .extendedSubdomains)
    }

    var combinedSubdomains: [DiscoveredSubdomain] {
        let existingHosts = Set(subdomains.map { $0.hostname.lowercased() })
        return subdomains + extendedSubdomains.filter { !existingHosts.contains($0.hostname.lowercased()) }
    }

    var summaryFields: [SummaryFieldViewData] {
        Self.summaryFields(from: currentSnapshot)
    }

    var domainRows: [InfoRowViewData] {
        Self.domainRows(from: currentSnapshot)
    }

    var dnsRows: [DNSRecordSectionViewData] {
        Self.dnsRows(from: currentSnapshot)
    }

    var suggestionRows: [DomainSuggestionViewData] {
        Self.suggestionRows(from: currentSnapshot)
    }

    var dnssecLabel: String? {
        Self.dnssecLabel(from: currentSnapshot)
    }

    var ptrMessage: SectionMessageViewData? {
        Self.ptrMessage(from: currentSnapshot)
    }

    var webCertificateRows: [InfoRowViewData] {
        Self.webCertificateRows(from: currentSnapshot)
    }

    var webResponseRows: [InfoRowViewData] {
        Self.webResponseRows(from: currentSnapshot)
    }

    var redirectRows: [RedirectHopViewData] {
        Self.redirectRows(from: currentSnapshot)
    }

    var emailRows: [EmailRowViewData] {
        Self.emailRows(from: currentSnapshot)
    }

    var ownershipRows: [InfoRowViewData] {
        Self.ownershipRows(from: currentSnapshot)
    }

    var subdomainRows: [SubdomainRowViewData] {
        Self.subdomainRows(from: combinedSubdomains)
    }

    var reachabilityRows: [ReachabilityRowViewData] {
        Self.reachabilityRows(from: currentSnapshot)
    }

    var locationRows: [InfoRowViewData] {
        Self.locationRows(from: currentSnapshot)
    }

    var standardPortRows: [PortScanRowViewData] {
        Self.portRows(from: currentSnapshot, kind: .standard)
    }

    var customPortRows: [PortScanRowViewData] {
        Self.portRows(from: currentSnapshot, kind: .custom)
    }

    var combinedPortScanError: String? {
        [portScanError, customPortScanError].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
    }

    func toggleSavedDomain() {
        if isCurrentDomainSaved {
            savedDomains.removeAll { $0.lowercased() == searchedDomain.lowercased() }
        } else {
            savedDomains.append(searchedDomain)
        }
        DomainDataPortabilityService.saveSavedDomains(savedDomains)
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    func removeSavedDomains(at offsets: IndexSet) {
        savedDomains.remove(atOffsets: offsets)
        DomainDataPortabilityService.saveSavedDomains(savedDomains)
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    @discardableResult
    func trackCurrentDomain() -> Bool {
        guard !searchedDomain.isEmpty else { return false }
        return trackDomain(domain: searchedDomain, availabilityStatus: availabilityResult?.status)
    }

    @discardableResult
    func trackDomain(domain: String, availabilityStatus: DomainAvailabilityStatus?) -> Bool {
        let normalizedDomain = normalizedDomain(domain)
        guard !normalizedDomain.isEmpty else { return false }

        if trackedDomain(for: normalizedDomain) != nil {
            return true
        }

        guard PremiumAccessService.canAddTrackedDomain(currentCount: trackedDomains.count) else {
            upgradePrompt = FeatureAccessService.upgradePromptForTrackedDomains(currentCount: trackedDomains.count)
            return false
        }

        trackedDomains.insert(
            TrackedDomain(
                domain: normalizedDomain,
                createdAt: Date(),
                updatedAt: Date(),
                lastKnownAvailability: availabilityStatus,
                collaboration: CollaborationMetadata(
                    scope: .privateDatabase,
                    ownership: .owner,
                    permission: .editable
                )
            ),
            at: 0
        )
        persistTrackedDomains()
        sanitizeMonitoringSelection()
        linkTrackedDomainHistory(for: normalizedDomain)
        return true
    }

    func refreshTrackedDomain(_ trackedDomain: TrackedDomain) {
        refreshingTrackedDomainID = trackedDomain.id
        domain = trackedDomain.domain
        Task { [weak self] in
            guard let self else { return }
            self.notificationsAuthorized = await LocalNotificationService.shared.requestAuthorizationIfNeeded()
        }
        run()
    }

    func rerunInspection(for trackedDomain: TrackedDomain) {
        rerunInspection(for: trackedDomain, useSnapshotResolver: false)
    }

    func deleteTrackedDomains(at offsets: IndexSet) {
        let removedDomains = offsets.map { sortedTrackedDomains[$0] }
        let ids = removedDomains.map(\.id)
        CloudSyncService.shared.recordTrackedDomainReset(removedDomains)
        trackedDomains.removeAll { ids.contains($0.id) }
        history.indices.forEach { index in
            if let trackedDomainID = history[index].trackedDomainID, ids.contains(trackedDomainID) {
                history[index].trackedDomainID = nil
            }
        }
        persistTrackedDomains()
        persistHistory()
        sanitizeMonitoringSelection()
    }

    func deleteTrackedDomain(_ trackedDomain: TrackedDomain) {
        guard canDelete(trackedDomain) else { return }
        CloudSyncService.shared.recordTrackedDomainDeletion(trackedDomain)
        trackedDomains.removeAll { $0.id == trackedDomain.id }
        history.indices.forEach { index in
            if history[index].trackedDomainID == trackedDomain.id {
                history[index].trackedDomainID = nil
            }
        }
        persistTrackedDomains()
        persistHistory()
        sanitizeMonitoringSelection()
    }

    func togglePinned(for trackedDomain: TrackedDomain) {
        guard canEdit(trackedDomain) else { return }
        guard let index = trackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) else { return }
        trackedDomains[index].isPinned.toggle()
        trackedDomains[index].updatedAt = Date()
        persistTrackedDomains()
    }

    func updateNote(_ note: String, for trackedDomain: TrackedDomain) {
        guard canEdit(trackedDomain) else { return }
        guard let index = trackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) else { return }
        trackedDomains[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        trackedDomains[index].updatedAt = Date()
        CloudSyncService.shared.markNoteChanged(for: trackedDomains[index].domain, updatedAt: trackedDomains[index].updatedAt)
        persistTrackedDomains()
    }

    func updateTags(_ tags: [String], for trackedDomain: TrackedDomain) {
        guard canEdit(trackedDomain) else { return }
        guard let index = trackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) else { return }
        let normalized = Self.normalizedTags(tags)
        trackedDomains[index].tags = normalized
        trackedDomains[index].updatedAt = Date()
        persistTrackedDomains()
    }

    /// All tags currently in use across the watchlist, sorted for stable display.
    var allWatchlistTags: [String] {
        Array(Set(trackedDomains.flatMap(\.tags))).sorted()
    }

    func saveCurrentWatchlistView(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let view = WatchlistSavedView(
            name: trimmedName,
            tag: watchlistTagFilter,
            filter: watchlistFilter,
            sort: watchlistSortOption
        )
        watchlistSavedViews.append(view)
        persistWatchlistSavedViews()
    }

    func applyWatchlistSavedView(_ view: WatchlistSavedView) {
        watchlistTagFilter = view.tag
        watchlistFilter = view.filter
        watchlistSortOption = view.sort
    }

    func deleteWatchlistSavedViews(at offsets: IndexSet) {
        watchlistSavedViews.remove(atOffsets: offsets)
        persistWatchlistSavedViews()
    }

    private static let watchlistSavedViewsKey = "watchlistSavedViews"

    private static func loadWatchlistSavedViews() -> [WatchlistSavedView] {
        guard let data = UserDefaults.standard.data(forKey: watchlistSavedViewsKey),
              let views = try? JSONDecoder().decode([WatchlistSavedView].self, from: data)
        else { return [] }
        return views
    }

    private func persistWatchlistSavedViews() {
        guard let data = try? JSONEncoder().encode(watchlistSavedViews) else { return }
        UserDefaults.standard.set(data, forKey: Self.watchlistSavedViewsKey)
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized.sorted()
    }

    func removeHistoryEntries(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func removeHistoryEntries(withIDs ids: [UUID]) {
        history.removeAll { ids.contains($0.id) }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
        clearMonitoringLogs()
        refreshDataLifecycleSummary()
    }

    func clearLookupCache() {
        Task {
            await LookupRuntime.shared.clearCache()
        }
    }

    func clearWorkflows() {
        CloudSyncService.shared.recordWorkflowReset(workflows)
        workflows.removeAll()
        latestWorkflowRunSummary = nil
        persistWorkflows()
        refreshDataLifecycleSummary()
    }

    func clearTrackedDomains() {
        CloudSyncService.shared.recordTrackedDomainReset(trackedDomains)
        trackedDomains.removeAll()
        refreshingTrackedDomainID = nil
        persistTrackedDomains()
        sanitizeMonitoringSelection()
        clearMonitoringLogs()
        refreshDataLifecycleSummary()
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        DomainDataPortabilityService.saveRecentSearches([])
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    func refreshMonitoringState() {
        #if DEBUG
        // Runs right after fixture seeding in the app task (and again on every
        // scene activation); the disk reload below would wipe the fixtures.
        if auditFixturesActive { return }
        #endif
        DataMigrationService.migrateIfNeeded()
        trackedDomains = Self.loadTrackedDomains()
        history = Self.loadHistoryEntries()
        monitoringSettings = MonitoringStorage.sanitizeSettings(
            MonitoringStorage.loadSettings(),
            trackedDomains: trackedDomains
        )
        monitoringLogs = MonitoringStorage.loadLogs()
        persistMonitoringSettings()
        refreshDataLifecycleSummary()
    }

    func refreshDataLifecycleSummary() {
        dataLifecycleSummary = DomainDataPortabilityService.lifecycleSummary()
    }

    func refreshPersistedData() {
        #if DEBUG
        // A reload from disk would silently replace the in-memory fixtures.
        if auditFixturesActive { return }
        #endif
        recentSearches = DomainDataPortabilityService.loadRecentSearches()
        savedDomains = DomainDataPortabilityService.loadSavedDomains()
        trackedDomains = Self.loadTrackedDomains()
        history = Self.loadHistoryEntries()
        auditSessions = DomainDataPortabilityService.loadAuditSessions()
        workflows = Self.loadWorkflows()
        monitoringSettings = MonitoringStorage.sanitizeSettings(
            MonitoringStorage.loadSettings(),
            trackedDomains: trackedDomains
        )
        monitoringLogs = MonitoringStorage.loadLogs()
        refreshDataLifecycleSummary()
    }

    func applyLocalDataReset() async {
        domain = ""
        bulkInput = ""
        reset()

        recentSearches = []
        savedDomains = []
        trackedDomains = []
        history = []
        auditSessions = []
        workflows = []
        historySearchText = ""
        historyDateFilter = .all
        historyChangeFilter = .all
        historySortOption = .newest
        timelineGrouping = .relativeDay
        timelineDomainFilter = ""
        watchlistSearchText = ""
        watchlistFilter = .all
        watchlistSortOption = .pinned
        dashboardSearchText = ""
        dashboardFilter = .all
        monitoringSettings = MonitoringSettings()
        monitoringLogs = []
        notificationsAuthorized = false
        monitoringRunInProgress = false
        monitoringStatusMessage = nil
        portabilityStatusMessage = "All local data removed."
        upgradePrompt = nil
        isPaywallPresented = false
        selectedSnapshotIDs.removeAll()
        activeDomainDiff = nil
        activeDiffChangeIndex = 0
        latestBatchSweepSummary = nil
        latestWorkflowRunSummary = nil
        historyAutoPruneOption = Self.loadHistoryAutoPruneOption()
        refreshDataLifecycleSummary()
        await refreshUsageCredits()
        await refreshMonitoringAuthorizationStatus()
    }

    func rerunLookup(from entry: HistoryEntry, useSnapshotResolver: Bool) {
        if useSnapshotResolver {
            UserDefaults.standard.set(entry.resolverURLString, forKey: DNSResolverOption.userDefaultsKey)
        }
        domain = entry.domain
        run()
        rerunNavigationToken = UUID()
    }

    func rerunInspection(for trackedDomain: TrackedDomain, useSnapshotResolver: Bool) {
        if useSnapshotResolver, let snapshot = latestSnapshot(for: trackedDomain) {
            UserDefaults.standard.set(snapshot.resolverURLString, forKey: DNSResolverOption.userDefaultsKey)
        }
        domain = trackedDomain.domain
        run()
        rerunNavigationToken = UUID()
    }

    func openInspection(for domain: String) {
        self.domain = normalizedDomain(domain)
        run()
        rerunNavigationToken = UUID()
    }

    func reset() {
        lookupTask?.cancel()
        customPortScanTask?.cancel()
        batchTask?.cancel()
        hasRun = false
        searchedDomain = ""
        lastLookupDurationMs = nil
        currentDiffSections = []
        currentChangeSummary = nil
        ownershipDiff = []
        currentReport = nil
        refreshingTrackedDomainID = nil
        clearBatchState()
        clearLookupState()
    }

    func clearPresentedResults() {
        reset()
    }

    func run() {
        let target = trimmedDomain
        guard !target.isEmpty else { return }
        clearBatchState()
        let lookupID = beginLookup(for: target)

        lookupTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.performLookup(domain: target, lookupID: lookupID)
        }
    }

    func runBulkLookup() {
        let domains = parsedDomains(from: bulkInput)
        guard !domains.isEmpty else { return }
        guard FeatureAccessService.canRunBatch(domainCount: domains.count) else {
            upgradePrompt = FeatureAccessService.upgradePromptForBatch(domainCount: domains.count)
            return
        }
        startBatchLookup(domains: domains, source: .manual)
    }

    func refreshAllTrackedDomains() {
        guard FeatureAccessService.canRunBatch(domainCount: sortedTrackedDomains.count) else {
            upgradePrompt = FeatureAccessService.upgradePromptForBatch(domainCount: sortedTrackedDomains.count)
            return
        }
        startBatchLookup(domains: sortedTrackedDomains.map(\.domain), source: .watchlistRefresh)
    }

    func cancelBatchLookup() {
        batchTask?.cancel()
        batchLookupRunning = false
        batchCurrentDomain = nil
        activeBatchDomains = []
        refreshingTrackedDomainID = nil

        for index in batchResults.indices where batchResults[index].status == .pending || batchResults[index].status == .running {
            batchResults[index] = BatchLookupResult(
                id: batchResults[index].id,
                domain: batchResults[index].domain,
                historyEntryID: batchResults[index].historyEntryID,
                availability: batchResults[index].availability,
                primaryIP: batchResults[index].primaryIP,
                quickStatus: "Cancelled",
                summaryMessage: batchResults[index].summaryMessage,
                changeSeverity: batchResults[index].changeSeverity,
                changeClassification: batchResults[index].changeClassification,
                certificateWarningLevel: batchResults[index].certificateWarningLevel,
                riskScore: batchResults[index].riskScore,
                riskLevel: batchResults[index].riskLevel,
                timestamp: Date(),
                status: .failed,
                errorMessage: "Lookup cancelled"
            )
        }
    }

    func canEdit(_ trackedDomain: TrackedDomain) -> Bool {
        trackedDomain.collaboration?.canEdit ?? true
    }

    func canDelete(_ trackedDomain: TrackedDomain) -> Bool {
        trackedDomain.collaboration?.isOwner ?? true
    }

    func collaborationLabel(for trackedDomain: TrackedDomain) -> String? {
        guard let collaboration = trackedDomain.collaboration, collaboration.isShared else { return nil }
        return "\(collaboration.ownership.title) • \(collaboration.permission.title)"
    }

    func runCustomPortScan(ports: [UInt16]) async {
        guard !searchedDomain.isEmpty else {
            customPortScanError = "Run a domain lookup first"
            return
        }

        guard !ports.isEmpty else {
            customPortScanError = "Enter at least one valid port"
            customPortResults = []
            return
        }

        customPortScanTask?.cancel()
        let domain = searchedDomain
        let lookupID = activeLookupID

        customPortScanLoading = true
        customPortScanError = nil
        customPortResults = []

        customPortScanTask = Task { [weak self] in
            guard let self else { return }
            let result = await PortScanService.scanPorts(domain: domain, ports: ports, timeout: 3.0)
            guard !Task.isCancelled, self.isCurrentLookup(lookupID) else { return }
            self.applyCustomPortResult(result)
        }
    }

    @discardableResult
    func startAudit(for domain: String, reviewer: String? = nil) async -> AuditSession? {
        let normalizedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first?
            .lowercased() ?? domain.lowercased()
        guard !normalizedDomain.isEmpty else { return nil }

        let previous = historyEntries(for: normalizedDomain).first?.snapshot
        let snapshot = await inspectionService.inspectSnapshot(domain: normalizedDomain, previousSnapshot: previous)
        guard let entry = saveHistoryEntry(
            from: snapshot,
            replaceLatest: false,
            updateCurrentState: searchedDomain.caseInsensitiveCompare(normalizedDomain) == .orderedSame
        ) else {
            return nil
        }

        let report = report(for: entry)
        let historicalContext = Array(historyEntries(for: normalizedDomain).dropFirst().prefix(6)).map(\.snapshotSummary)
        let screenshots = snapshotEvidenceAssets(from: report)
        let session = AuditSession(
            domain: normalizedDomain,
            createdAt: entry.timestamp,
            reviewer: (reviewer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) ?? Self.defaultAuditReviewer,
            status: .draft,
            evidence: AuditEvidenceSnapshot(
                capturedAt: entry.timestamp,
                lookup: entry,
                report: report,
                historicalContext: historicalContext,
                screenshots: screenshots
            ),
            findings: [],
            notes: "",
            checklist: AuditChecklistArea.defaultItems
        )

        auditSessions.insert(session, at: 0)
        persistAuditSessions()
        return session
    }

    func loadOwnershipHistory() async {
        await loadLookup(.ownershipHistory, into: \.ownershipHistory, loading: \.ownershipHistoryLoading, error: \.ownershipHistoryError,
                         fallback: "Ownership history unavailable") {
            await ExternalDataService.shared.ownershipHistory(
                domain: searchedDomain,
                currentOwnership: ownershipResult,
                historyEntries: history
            ).value
        }
    }

    func loadDNSHistory() async {
        await loadLookup(.dnsHistory, into: \.dnsHistory, loading: \.dnsHistoryLoading, error: \.dnsHistoryError,
                         fallback: "DNS history unavailable") {
            await ExternalDataService.shared.dnsHistory(
                domain: searchedDomain,
                dnsSections: dnsSections,
                historyEntries: history
            ).value
        }
    }

    func loadExtendedSubdomains() async {
        await loadLookup(.extendedSubdomains, into: \.extendedSubdomains, loading: \.extendedSubdomainsLoading, error: \.extendedSubdomainsError,
                         fallback: "Extended subdomains unavailable") {
            await ExternalDataService.shared.extendedSubdomains(
                domain: searchedDomain,
                existing: subdomains
            ).value
        }
    }

    /// Loads `capability`'s lookup for the searched domain into `items`, unless it is loaded
    /// already, or shows the upgrade prompt when the plan doesn't include it.
    private func loadLookup<Item>(
        _ capability: DataCapability,
        into items: ReferenceWritableKeyPath<DomainViewModel, [Item]>,
        loading: ReferenceWritableKeyPath<DomainViewModel, Bool>,
        error: ReferenceWritableKeyPath<DomainViewModel, String?>,
        fallback: String,
        fetch: () async -> ServiceResult<[Item]>
    ) async {
        guard !searchedDomain.isEmpty else { return }
        guard DataAccessService.hasAccess(to: capability) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: capability.feature)
            return
        }
        guard self[keyPath: items].isEmpty else { return }

        self[keyPath: loading] = true
        self[keyPath: error] = nil

        (self[keyPath: items], self[keyPath: error]) = found(await fetch(), fallback: fallback)

        self[keyPath: loading] = false
        _ = saveHistoryEntry(replaceLatest: true)
    }

    /// What a lookup found, and the message to show when it found nothing or failed.
    private func found<Item>(_ result: ServiceResult<[Item]>, fallback: String) -> ([Item], String?) {
        switch result {
        case let .success(items):
            return (items, nil)
        case let .empty(message):
            return ([], message)
        case let .error(message):
            return ([], conciseExternalMessage(message, fallback: fallback))
        }
    }

    func refreshUsageCredits() async {
        let statuses = await UsageCreditService.shared.allStatuses()
        usageCredits = Dictionary(uniqueKeysWithValues: statuses.map { ($0.feature, $0) })
    }

    private func performLookup(domain: String, lookupID: UUID) async -> HistoryEntry? {
        let lookupStartedAt = DomainDebugLog.signpostStart("DomainViewModel.performLookup", domain: domain)
        let previous = previousSnapshot(
            for: domain,
            trackedDomainID: currentTrackedDomain?.id,
            replacingLatest: false
        )
        let inspectedSnapshot = await inspectionService.inspectSnapshot(domain: domain, previousSnapshot: previous)
        DomainDebugLog.debug("DomainViewModel.performLookup inspectionReturned domain=\(domain)")
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return nil }

        let snapshot = inspectedSnapshot.resolvedAfterFallback(to: previous)
        let applyStartedAt = DomainDebugLog.signpostStart("DomainViewModel.applySnapshot", domain: domain)
        applySnapshot(snapshot)
        DomainDebugLog.signpostEnd("DomainViewModel.applySnapshot", start: applyStartedAt, domain: domain)
        lastLookupDurationMs = snapshot.totalLookupDurationMs
        refreshingTrackedDomainID = nil

        if DataAccessService.hasAccess(to: .domainPricing), domainPricing == nil {
            DomainDebugLog.debug("DomainViewModel.performLookup loadingPricing domain=\(domain)")
            await refreshDomainPricing(for: snapshot.domain, persistAfterFetch: false)
        }

        if DataAccessService.hasAccess(to: .reputation), reputation == nil {
            DomainDebugLog.debug("DomainViewModel.performLookup loadingReputation domain=\(domain)")
            await refreshReputation(for: snapshot.domain, persistAfterFetch: false)
        }

        guard snapshot.statusMessage == nil else {
            return history.first(where: { $0.id == snapshot.historyEntryID })
        }

        let saveStartedAt = DomainDebugLog.signpostStart("DomainViewModel.saveHistoryEntry", domain: domain)
        let entry = saveHistoryEntry(replaceLatest: false, reuseCurrentAnalysis: true)
        DomainDebugLog.signpostEnd("DomainViewModel.saveHistoryEntry", start: saveStartedAt, domain: domain)
        DomainDebugLog.signpostEnd("DomainViewModel.performLookup", start: lookupStartedAt, domain: domain)
        return entry
    }

    private func applySnapshot(_ snapshot: LookupSnapshot) {
        currentHistoryEntryID = snapshot.historyEntryID
        currentSnapshotTimestamp = snapshot.timestamp
        currentResultSource = snapshot.resultSource
        currentCachedSections = snapshot.cachedSections
        currentStatusMessage = snapshot.statusMessage
        currentDiffSections = []
        ownershipDiff = []
        let reportStartedAt = DomainDebugLog.signpostStart("DomainViewModel.reportBuilder.build", domain: snapshot.domain)
        currentReport = reportBuilder.build(
            from: snapshot,
            previousSnapshot: previousSnapshot(
                for: snapshot.domain,
                trackedDomainID: snapshot.trackedDomainID ?? trackedDomain(for: snapshot.domain)?.id,
                replacingLatest: false
            ),
            historyEntries: historyEntries(for: snapshot.domain)
        )
        DomainDebugLog.signpostEnd("DomainViewModel.reportBuilder.build", start: reportStartedAt, domain: snapshot.domain)
        currentChangeSummary = currentReport?.changeSummary ?? snapshot.changeSummary

        dnsSections = snapshot.dnsSections
        dnsError = snapshot.dnsError
        availabilityResult = snapshot.availabilityResult
        suggestions = snapshot.suggestions
        sslInfo = snapshot.sslInfo
        sslError = snapshot.sslError
        hstsPreloaded = snapshot.hstsPreloaded
        httpHeaders = snapshot.httpHeaders
        httpSecurityGrade = snapshot.httpSecurityGrade
        httpStatusCode = snapshot.httpStatusCode
        httpResponseTimeMs = snapshot.httpResponseTimeMs
        httpProtocol = snapshot.httpProtocol
        http3Advertised = snapshot.http3Advertised
        httpHeadersError = snapshot.httpHeadersError
        reachabilityResults = snapshot.reachabilityResults
        reachabilityError = snapshot.reachabilityError
        ipGeolocation = snapshot.ipGeolocation
        ipGeolocationError = snapshot.ipGeolocationError
        emailSecurity = snapshot.emailSecurity
        emailSecurityError = snapshot.emailSecurityError
        ownershipResult = snapshot.ownership
        ownershipError = snapshot.ownershipError
        ownershipHistory = snapshot.ownershipHistory
        ownershipHistoryError = snapshot.ownershipHistoryError
        ptrRecord = snapshot.ptrRecord
        ptrError = snapshot.ptrError
        redirectChain = snapshot.redirectChain
        redirectChainError = snapshot.redirectChainError
        subdomains = snapshot.subdomains
        subdomainsError = snapshot.subdomainsError
        extendedSubdomains = snapshot.extendedSubdomains
        extendedSubdomainsError = snapshot.extendedSubdomainsError
        dnsHistory = snapshot.dnsHistory
        dnsHistoryError = snapshot.dnsHistoryError
        domainPricing = snapshot.domainPricing
        domainPricingError = snapshot.domainPricingError
        portScanResults = snapshot.portScanResults.filter { $0.kind == .standard }
        customPortResults = snapshot.portScanResults.filter { $0.kind == .custom }
        portScanError = snapshot.portScanError
        customPortScanError = nil

        dnsLoading = false
        availabilityLoading = false
        suggestionsLoading = false
        sslLoading = false
        hstsLoading = false
        httpHeadersLoading = false
        reachabilityLoading = false
        ipGeolocationLoading = false
        emailSecurityLoading = false
        ownershipLoading = false
        ownershipHistoryLoading = false
        ptrLoading = false
        redirectChainLoading = false
        subdomainsLoading = false
        extendedSubdomainsLoading = false
        dnsHistoryLoading = false
        domainPricingLoading = false
        portScanLoading = false
        customPortScanLoading = false
    }

    private func runDNS(domain: String, lookupID: UUID) async {
        let result = await DNSLookupService.lookupAll(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(sections):
            dnsSections = sections
            dnsError = nil
        case let .empty(message), let .error(message):
            dnsSections = []
            dnsError = message
        }
        dnsLoading = false
    }

    private func runAvailability(domain: String, lookupID: UUID) async {
        let result = await DomainAvailabilityService.check(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        availabilityResult = result
        availabilityLoading = false
        updateTrackedDomainAvailability(for: result.domain, status: result.status)
    }

    private func runSSL(domain: String, lookupID: UUID) async {
        let result = await SSLCheckService.check(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(info):
            sslInfo = info
            sslError = nil
        case let .empty(message), let .error(message):
            sslInfo = nil
            sslError = message
        }
        sslLoading = false
    }

    private func runHSTSPreload(domain: String, lookupID: UUID) async {
        let result = await SSLCheckService.checkHSTSPreload(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        hstsPreloaded = result
        hstsLoading = false
    }

    private func runHTTPHeaders(domain: String, lookupID: UUID) async {
        let result = await HTTPHeadersService.fetch(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(headersResult):
            httpHeaders = headersResult.headers
            httpSecurityGrade = HTTPSecurityGrade.grade(for: headersResult.headers).rawValue
            httpStatusCode = headersResult.statusCode
            httpResponseTimeMs = headersResult.responseTimeMs
            httpProtocol = headersResult.httpProtocol
            http3Advertised = headersResult.http3Advertised
            httpHeadersError = nil
        case let .empty(message), let .error(message):
            httpHeaders = []
            httpSecurityGrade = nil
            httpStatusCode = nil
            httpResponseTimeMs = nil
            httpProtocol = nil
            http3Advertised = false
            httpHeadersError = message
        }
        httpHeadersLoading = false
    }

    private func runReachability(domain: String, lookupID: UUID) async {
        let result = await ReachabilityService.checkAll(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(results):
            reachabilityResults = results
            reachabilityError = nil
        case let .empty(message), let .error(message):
            reachabilityResults = []
            reachabilityError = message
        }
        reachabilityLoading = false
    }

    private func runEmailSecurity(domain: String, txtRecords: [DNSRecord], lookupID: UUID) async {
        let result = await EmailSecurityService.analyze(domain: domain, txtRecords: txtRecords)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(emailResult):
            emailSecurity = emailResult
            emailSecurityError = nil
        case let .empty(message), let .error(message):
            emailSecurity = nil
            emailSecurityError = message
        }
        emailSecurityLoading = false
    }

    private func runOwnership(domain: String, lookupID: UUID) async {
        let result = await DomainOwnershipService.lookup(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(ownership):
            ownershipResult = ownership
            ownershipError = nil
        case let .empty(message), let .error(message):
            ownershipResult = nil
            ownershipError = message
        }
        ownershipLoading = false
    }

    private func runReverseDNS(ip: String, lookupID: UUID) async {
        let result = await ReverseDNSService.lookup(ip: ip, resolverURLString: resolverURLString)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(record):
            ptrRecord = record
            ptrError = nil
        case let .empty(message), let .error(message):
            ptrRecord = nil
            ptrError = message
        }
        ptrLoading = false
    }

    private func runRedirectChain(domain: String, lookupID: UUID) async {
        let result = await RedirectChainService.trace(domain: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(hops):
            redirectChain = hops
            redirectChainError = nil
        case let .empty(message), let .error(message):
            redirectChain = []
            redirectChainError = message
        }
        redirectChainLoading = false
    }

    private func runSubdomains(domain: String, lookupID: UUID) async {
        let result = await SubdomainDiscoveryService.discover(for: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(results):
            subdomains = results
            subdomainsError = nil
        case let .empty(message), let .error(message):
            subdomains = []
            subdomainsError = message
        }
        subdomainsLoading = false
    }

    private func runPortScan(domain: String, lookupID: UUID) async {
        let result = await PortScanService.scanAll(domain: domain)
        switch result {
        case let .success(results):
            let enrichedResults = await PortScanService.withBanners(results, host: domain)
            guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
            portScanResults = enrichedResults
            portScanError = nil
        case let .empty(message), let .error(message):
            guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
            portScanResults = []
            portScanError = message
        }
        portScanLoading = false
    }

    private func runIPGeolocation(ip: String, lookupID: UUID) async {
        let result = await IPGeolocationService.lookup(ip: ip)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        switch result {
        case let .success(geolocation):
            ipGeolocation = geolocation
            ipGeolocationError = nil
        case let .empty(message), let .error(message):
            ipGeolocation = nil
            ipGeolocationError = message
        }
        ipGeolocationLoading = false
    }

    private func finishDependentWithoutPrimaryIP(lookupID: UUID) async {
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        ptrLoading = false
        ptrError = "No A record available"
        ipGeolocationLoading = false
        ipGeolocationError = "No A record available"
    }

    private func runSuggestions(domain: String, lookupID: UUID) async {
        let results = await DomainAvailabilityService.suggestions(for: domain)
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return }
        suggestions = results
        suggestionsLoading = false
    }

    private func applyCustomPortResult(_ result: ServiceResult<[PortScanResult]>) {
        switch result {
        case let .success(results):
            customPortResults = results
            customPortScanError = nil
            _ = saveHistoryEntry(replaceLatest: true)
        case let .empty(message), let .error(message):
            customPortResults = []
            customPortScanError = message
        }
        customPortScanLoading = false
    }

    private static func performBatchLookup(domain: String, previousSnapshot: LookupSnapshot?) async -> BatchLookupPayload? {
        guard !Task.isCancelled else { return nil }
        let inspectionService = DomainInspectionService()
        let snapshot = await inspectionService.inspectSnapshot(domain: domain, previousSnapshot: previousSnapshot)
        guard !Task.isCancelled else { return nil }
        return BatchLookupPayload(snapshot: snapshot.resolvedAfterFallback(to: previousSnapshot))
    }

    @discardableResult
    private func saveHistoryEntry(replaceLatest: Bool, reuseCurrentAnalysis: Bool = false) -> HistoryEntry? {
        guard !searchedDomain.isEmpty else { return nil }
        return saveHistoryEntry(
            from: currentSnapshot,
            replaceLatest: replaceLatest,
            updateCurrentState: true,
            reuseCurrentAnalysis: reuseCurrentAnalysis
        )
    }

    @discardableResult
    private func saveHistoryEntry(
        from snapshot: LookupSnapshot,
        replaceLatest: Bool,
        updateCurrentState: Bool,
        reuseCurrentAnalysis: Bool = false
    ) -> HistoryEntry? {
        let trackedDomainID = snapshot.trackedDomainID ?? trackedDomain(for: snapshot.domain)?.id
        let previousSnapshot = previousSnapshot(for: snapshot.domain, trackedDomainID: trackedDomainID, replacingLatest: replaceLatest)
        let domainHistoryEntries = history.filter {
            $0.domain.caseInsensitiveCompare(snapshot.domain) == .orderedSame
        }
        let analysis = reuseCurrentAnalysis ? nil : DomainInsightEngine.analyze(snapshot: snapshot, previousSnapshot: previousSnapshot)
        let intelligence = DomainIntelligenceService.derive(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            historyEntries: domainHistoryEntries
        )
        let changeSummary = reuseCurrentAnalysis
            ? currentChangeSummary ?? snapshot.changeSummary
            : previousSnapshot.map {
                DiffService.summary(
                    from: $0,
                    to: snapshot,
                    generatedAt: snapshot.timestamp,
                    riskAssessment: analysis?.riskAssessment,
                    insights: analysis?.insights
                )
            }
        let domainDiff = reuseCurrentAnalysis
            ? previousSnapshot.map {
                DomainDiff(
                    domain: snapshot.domain,
                    fromTimestamp: $0.timestamp,
                    toTimestamp: snapshot.timestamp,
                    sections: currentDiffSections,
                    changedSectionIDs: currentDiffSections.filter(\.hasChanges).map(\.id),
                    changedSectionTitles: currentDiffSections.filter(\.hasChanges).map(\.title),
                    contextNote: currentChangeSummary?.contextNote
                )
            }
            : previousSnapshot.map { DiffService.compare(from: $0, to: snapshot) }
        let diffSections = domainDiff?.sections ?? currentDiffSections
        let previousSnapshotID = previousSnapshot?.historyEntryID
        let nextSnapshotIndex = nextSnapshotIndex(for: snapshot.domain, trackedDomainID: trackedDomainID)

        if updateCurrentState {
            currentChangeSummary = changeSummary
            currentDiffSections = diffSections
            ownershipDiff = diffSections.first(where: { $0.title == "Ownership" })?.items.filter(\.hasChanges) ?? []
            if !reuseCurrentAnalysis {
                currentReport = reportBuilder.build(
                    from: snapshot,
                    previousSnapshot: previousSnapshot,
                    historyEntries: domainHistoryEntries
                )
            }
        }

        let entry = HistoryEntry(
            identity: HistoryEntry.Identity(
                domain: snapshot.domain,
                timestamp: snapshot.timestamp,
                trackedDomainID: trackedDomainID,
                note: currentHistoryEntry?.note
            ),
            inspection: .init(snapshot: snapshot),
            registration: HistoryEntry.Registration(
                ownership: snapshot.ownership,
                ownershipHistory: snapshot.ownershipHistory,
                inferredProvider: intelligence.inferredProvider,
                priorProviders: intelligence.priorProviders,
                domainClassification: intelligence.domainClassification,
                ownershipTransitions: intelligence.ownershipTransitions,
                hostingTransitions: intelligence.hostingTransitions,
                domainPricing: snapshot.domainPricing
            ),
            intelligence: HistoryEntry.Intelligence(
                subdomainHistory: intelligence.subdomainHistory,
                riskSignals: intelligence.riskSignals,
                intelligenceTimeline: intelligence.timelineEvents,
                reputation: snapshot.reputation
            ),
            provenance: .init(snapshot: snapshot),
            summary: HistoryEntry.Summary(
                primaryIP: Self.primaryIPAddress(from: snapshot),
                finalRedirectURL: Self.finalRedirectTarget(from: snapshot),
                tlsStatusSummary: Self.httpsSummary(from: snapshot),
                emailSecuritySummary: Self.emailSummary(from: snapshot),
                httpGradeSummary: snapshot.httpSecurityGrade ?? snapshot.httpHeadersError,
                changeSummary: changeSummary,
                snapshotIndex: nextSnapshotIndex,
                previousSnapshotID: previousSnapshotID,
                changeCount: domainDiff?.changeCount ?? changeSummary?.changedSections.count ?? 0,
                severitySummary: changeSummary?.severity
            ),
            failures: .init(snapshot: snapshot)
        )

        if updateCurrentState {
            currentHistoryEntryID = entry.id
        }

        if replaceLatest, !history.isEmpty, history[0].domain.caseInsensitiveCompare(snapshot.domain) == .orderedSame {
            history[0] = entry
        } else {
            history.insert(entry, at: 0)
            trimHistoryToLimit()
        }

        updateTrackedDomainSnapshotMetadata(
            domain: snapshot.domain,
            snapshotID: entry.id,
            availabilityStatus: snapshot.availabilityResult?.status,
            updatedAt: snapshot.timestamp,
            changeSummary: changeSummary,
            changeSeverity: changeSummary?.severity,
            certificateWarningLevel: DomainDiffService.certificateWarningLevel(for: snapshot),
            certificateDaysRemaining: snapshot.sslInfo?.daysUntilExpiry
        )
        persistHistory()
        notifyIfNeeded(for: entry, snapshot: snapshot, previousSnapshot: previousSnapshot)
        return entry
    }

    private func persistHistory() {
        if historyPersistenceSuspended {
            historyPersistenceDirty = true
            return
        }
        let persistStartedAt = DomainDebugLog.signpostStart("DomainViewModel.persistHistory")
        DomainDataPortabilityService.saveHistoryEntries(history)
        refreshDataLifecycleSummary()
        DomainDebugLog.signpostEnd("DomainViewModel.persistHistory", start: persistStartedAt, extra: "count=\(history.count)")
    }

    func persistAuditSessions() {
        DomainDataPortabilityService.saveAuditSessions(auditSessions)
        refreshDataLifecycleSummary()
    }

    func setHistoryAutoPruneOption(_ option: HistoryAutoPruneOption) {
        historyAutoPruneOption = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.historyAutoPruneKey)
        trimHistoryToLimit()
        persistHistory()
    }

    func updateHistoryNote(_ note: String, for entry: HistoryEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persistHistory()
    }

    #if DEBUG
    /// True when this session was launched with `DOMAIN_DIG_SEED_FIXTURES`.
    /// Blocks tracked-domain persistence, widget-store writes, and persisted-data
    /// reloads so fixture data stays strictly in-memory — the audit suite relies
    /// on every launch starting from the same state.
    private(set) var auditFixturesActive = false

    func seedAuditFixturesIfRequested() {
        guard AuditFixtures.requested, !auditFixturesActive else { return }
        auditFixturesActive = true
        trackedDomains = AuditFixtures.trackedDomains
        batchResults = AuditFixtures.batchResults
    }
    #endif

    private func persistTrackedDomains() {
        #if DEBUG
        if auditFixturesActive { return }
        #endif
        if trackedDomainsPersistenceSuspended {
            trackedDomainsPersistenceDirty = true
            return
        }
        DomainDataPortabilityService.saveTrackedDomains(trackedDomains)
        CloudSyncService.shared.scheduleSyncIfNeeded()
        refreshDataLifecycleSummary()
        refreshWidgetData()
    }

    private func beginBulkPersistenceDeferral() {
        historyPersistenceSuspended = true
        trackedDomainsPersistenceSuspended = true
        historyPersistenceDirty = false
        trackedDomainsPersistenceDirty = false
    }

    private func endBulkPersistenceDeferral() {
        historyPersistenceSuspended = false
        trackedDomainsPersistenceSuspended = false

        if trackedDomainsPersistenceDirty {
            trackedDomainsPersistenceDirty = false
            DomainDataPortabilityService.saveTrackedDomains(trackedDomains)
            CloudSyncService.shared.scheduleSyncIfNeeded()
        }

        if historyPersistenceDirty {
            historyPersistenceDirty = false
            DomainDataPortabilityService.saveHistoryEntries(history)
        }

        refreshDataLifecycleSummary()
    }

    private func trimHistoryToLimit() {
        let hardLimit = historyAutoPruneOption.keepCount ?? Self.maxHistory
        history = Array(history.prefix(min(hardLimit, Self.maxHistory)))
    }

    private func nextSnapshotIndex(for domain: String, trackedDomainID: UUID?) -> Int {
        let siblings = history.filter { entry in
            if let trackedDomainID {
                return entry.trackedDomainID == trackedDomainID
            }
            return entry.domain.caseInsensitiveCompare(domain) == .orderedSame
        }
        let existingMax = siblings.compactMap(\.snapshotIndex).max() ?? siblings.count
        return existingMax + 1
    }

    func persistMonitoringSettings(localActivationConfirmed: Bool = false) {
        monitoringSettings = MonitoringStorage.sanitizeSettings(monitoringSettings, trackedDomains: trackedDomains)
        MonitoringStorage.saveSettings(monitoringSettings)
        CloudSyncService.shared.markMonitoringSettingsChanged(localActivationConfirmed: localActivationConfirmed)
    }

    func sanitizeMonitoringSelection() {
        monitoringSettings = MonitoringStorage.sanitizeSettings(monitoringSettings, trackedDomains: trackedDomains)
        MonitoringStorage.saveSettings(monitoringSettings)
        CloudSyncService.shared.markMonitoringSettingsChanged(localActivationConfirmed: false)
    }

    private func clearMonitoringLogs() {
        monitoringLogs.removeAll()
        monitoringStatusMessage = nil
        MonitoringStorage.saveLogs([])
    }

    private func updateTrackedDomainAvailability(for domain: String, status: DomainAvailabilityStatus) {
        guard let index = trackedDomains.firstIndex(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }) else {
            return
        }
        trackedDomains[index].lastKnownAvailability = status
        persistTrackedDomains()
    }

    private func updateTrackedDomainSnapshotMetadata(
        domain: String,
        snapshotID: UUID,
        availabilityStatus: DomainAvailabilityStatus?,
        updatedAt: Date,
        changeSummary: DomainChangeSummary?,
        changeSeverity: ChangeSeverity?,
        certificateWarningLevel: CertificateWarningLevel,
        certificateDaysRemaining: Int?
    ) {
        guard let index = trackedDomains.firstIndex(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }) else {
            return
        }
        trackedDomains[index].lastSnapshotID = snapshotID
        trackedDomains[index].lastKnownAvailability = availabilityStatus
        trackedDomains[index].updatedAt = updatedAt
        trackedDomains[index].lastChangeSummary = changeSummary
        trackedDomains[index].lastChangeSeverity = changeSeverity
        trackedDomains[index].certificateWarningLevel = certificateWarningLevel
        trackedDomains[index].certificateDaysRemaining = certificateDaysRemaining
        persistTrackedDomains()
    }

    private func notifyIfNeeded(for entry: HistoryEntry, snapshot: LookupSnapshot, previousSnapshot: LookupSnapshot?) {
        guard notificationsAuthorized, entry.trackedDomainID != nil else { return }

        Task {
            if let summary = entry.changeSummary, summary.hasChanges {
                await LocalNotificationService.shared.notifyDomainEvent(
                    domain: entry.domain,
                    message: summary.message,
                    severity: summary.severity
                )
            }

            let certificateWarningLevel = DomainDiffService.certificateWarningLevel(for: snapshot)
            if certificateWarningLevel == .critical, let daysRemaining = snapshot.sslInfo?.daysUntilExpiry {
                await LocalNotificationService.shared.notifyCertificateWarning(
                    domain: entry.domain,
                    daysRemaining: daysRemaining
                )
            }

            if let previousStatus = previousSnapshot?.availabilityResult?.status,
               let newStatus = snapshot.availabilityResult?.status,
               previousStatus != newStatus {
                await LocalNotificationService.shared.notifyDomainEvent(
                    domain: entry.domain,
                    message: "Availability changed",
                    severity: .high
                )
            }
        }
    }

    private func previousSnapshot(for domain: String, trackedDomainID: UUID?, replacingLatest: Bool) -> LookupSnapshot? {
        let matchingEntries = history.filter { entry in
            if let trackedDomainID {
                return entry.trackedDomainID == trackedDomainID
            }
            return entry.domain.caseInsensitiveCompare(domain) == .orderedSame
        }

        if replacingLatest {
            return matchingEntries.dropFirst().first?.snapshot
        }
        return matchingEntries.first?.snapshot
    }

    private func trackedDomain(for domain: String) -> TrackedDomain? {
        trackedDomains.first { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }
    }

    func normalizedDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }

    private func linkTrackedDomainHistory(for domain: String) {
        guard let trackedDomain = trackedDomain(for: domain) else { return }
        var didChange = false

        for index in history.indices where history[index].domain.caseInsensitiveCompare(domain) == .orderedSame {
            if history[index].trackedDomainID != trackedDomain.id {
                history[index].trackedDomainID = trackedDomain.id
                didChange = true
            }
        }

        if didChange {
            persistHistory()
        }

        if let latestEntry = history.first(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }),
           let trackedIndex = trackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) {
            trackedDomains[trackedIndex].lastSnapshotID = latestEntry.id
            trackedDomains[trackedIndex].lastChangeSummary = latestEntry.changeSummary
            trackedDomains[trackedIndex].lastChangeSeverity = latestEntry.changeSummary?.severity
            trackedDomains[trackedIndex].lastKnownAvailability = latestEntry.availabilityResult?.status
            trackedDomains[trackedIndex].certificateWarningLevel = DomainDiffService.certificateWarningLevel(for: latestEntry.snapshot)
            trackedDomains[trackedIndex].certificateDaysRemaining = latestEntry.sslInfo?.daysUntilExpiry
            trackedDomains[trackedIndex].updatedAt = latestEntry.timestamp
            persistTrackedDomains()
        }
    }

    private func addRecentSearch(_ domain: String) {
        recentSearches.removeAll { $0.lowercased() == domain.lowercased() }
        recentSearches.insert(domain, at: 0)
        if recentSearches.count > Self.maxRecent {
            recentSearches = Array(recentSearches.prefix(Self.maxRecent))
        }
        DomainDataPortabilityService.saveRecentSearches(recentSearches)
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    private func beginLookup(for target: String, cancelExistingTask: Bool = true) -> UUID {
        if cancelExistingTask {
            lookupTask?.cancel()
        }
        customPortScanTask?.cancel()

        let lookupID = UUID()
        activeLookupID = lookupID
        lookupStartedAt = Date()
        lastLookupDurationMs = nil
        addRecentSearch(target)
        searchedDomain = target
        hasRun = true
        currentHistoryEntryID = nil
        currentSnapshotTimestamp = Date()
        currentResultSource = .live
        currentCachedSections = []
        currentStatusMessage = nil
        currentDiffSections = []
        currentChangeSummary = nil
        currentReport = nil
        ownershipDiff = []
        clearLookupState()
        setAllLoadingStates(true)
        customPortScanLoading = false
        return lookupID
    }

    func startBatchLookup(domains: [String], source: BatchLookupSource, workflow: DomainWorkflow? = nil) {
        guard !domains.isEmpty else { return }
        guard !batchLookupRunning else { return }

        let now = Date()
        if let lastBatchStartedAt, now.timeIntervalSince(lastBatchStartedAt) < 1 {
            return
        }

        lastBatchStartedAt = now
        clearBatchState()
        batchLookupSource = source
        activeWorkflowRunID = workflow?.id
        activeWorkflowRunName = workflow?.name
        batchTotalCount = domains.count
        batchLookupRunning = true
        batchResults = domains.map {
            BatchLookupResult(
                domain: $0,
                historyEntryID: nil,
                availability: nil,
                primaryIP: nil,
                quickStatus: "Pending",
                timestamp: Date(),
                status: .pending
            )
        }

        lookupTask?.cancel()
        customPortScanTask?.cancel()
        batchTask?.cancel()

        SweepActivityController.shared.begin(
            title: source == .watchlistRefresh ? "Watchlist Sweep" : "Batch Lookup",
            total: domains.count
        )

        batchTask = Task { [weak self] in
            guard let self else { return }
            self.notificationsAuthorized = await LocalNotificationService.shared.requestAuthorizationIfNeeded()
            await self.runBatchLookup(domains: domains, source: source)
        }
    }

    private func clearBatchState() {
        batchResults = []
        batchLookupSource = .manual
        batchCurrentDomain = nil
        batchCompletedCount = 0
        batchTotalCount = 0
        batchLookupRunning = false
        latestBatchSweepSummary = nil
        latestWorkflowRunSummary = nil
        activeBatchDomains = []
        activeWorkflowRunID = nil
        activeWorkflowRunName = nil
        batchTask = nil
    }

    private func parsedDomains(from input: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        var seen = Set<String>()

        return input
            .components(separatedBy: separators)
            .map(normalizedDomain)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func runBatchLookup(domains: [String], source: BatchLookupSource) async {
        let concurrencyLimit = min(source == .watchlistRefresh ? 4 : 3, max(domains.count, 1))
        var nextIndex = 0
        beginBulkPersistenceDeferral()

        await withTaskGroup(of: (String, BatchLookupPayload?).self) { group in
            for _ in 0..<concurrencyLimit {
                guard nextIndex < domains.count else { break }
                let domain = domains[nextIndex]
                nextIndex += 1
                enqueueBatchLookup(domain: domain, source: source, group: &group)
            }

            while let (domain, payload) = await group.next() {
                completeBatchLookup(domain: domain, payload: payload)

                if nextIndex < domains.count, !Task.isCancelled {
                    let nextDomain = domains[nextIndex]
                    nextIndex += 1
                    enqueueBatchLookup(domain: nextDomain, source: source, group: &group)
                }
            }
        }

        endBulkPersistenceDeferral()
        finishBatchLookup(source: source)
    }

    private func enqueueBatchLookup(
        domain: String,
        source: BatchLookupSource,
        group: inout TaskGroup<(String, BatchLookupPayload?)>
    ) {
        activeBatchDomains.append(domain)
        batchCurrentDomain = activeBatchDomains.first
        if source == .watchlistRefresh {
            refreshingTrackedDomainID = trackedDomain(for: domain)?.id
        }
        updateBatchResult(domain: domain, status: .running, quickStatus: "Running", entry: nil, errorMessage: nil)
        let previousSnapshot = previousSnapshot(for: domain, trackedDomainID: trackedDomain(for: domain)?.id, replacingLatest: false)

        group.addTask { [domain, previousSnapshot] in
            let payload = await Self.performBatchLookup(domain: domain, previousSnapshot: previousSnapshot)
            return (domain, payload)
        }
    }

    private func completeBatchLookup(domain: String, payload: BatchLookupPayload?) {
        activeBatchDomains.removeAll { $0.caseInsensitiveCompare(domain) == .orderedSame }
        batchCurrentDomain = activeBatchDomains.first

        guard let payload else {
            updateBatchResult(
                domain: domain,
                status: .failed,
                quickStatus: "Failed",
                entry: nil,
                resultSource: .live,
                errorMessage: "Lookup cancelled"
            )
            batchCompletedCount += 1
            SweepActivityController.shared.update(
                completed: batchCompletedCount,
                total: batchTotalCount,
                currentDomain: batchCurrentDomain
            )
            return
        }

        let entry = payload.snapshot.historyEntryID.flatMap { id in
            history.first(where: { $0.id == id })
        } ?? saveHistoryEntry(from: payload.snapshot, replaceLatest: false, updateCurrentState: false)
        let certificateWarningLevel = DomainDiffService.certificateWarningLevel(for: payload.snapshot)
        let riskAssessment = entry?.changeSummary?.riskAssessment ?? DomainInsightEngine.analyze(snapshot: payload.snapshot).riskAssessment
        let quickStatus: String
        if entry?.changeSummary?.hasChanges == true {
            if entry?.changeSummary?.impactClassification == .critical {
                quickStatus = "Critical"
            } else {
                quickStatus = entry?.changeSummary?.severity == .high ? "High" : "Changed"
            }
        } else if certificateWarningLevel != .none {
            quickStatus = certificateWarningLevel == .critical ? "Critical" : "Warning"
        } else if riskAssessment.level == .high {
            quickStatus = "High"
        } else {
            quickStatus = "Unchanged"
        }

        updateBatchResult(
            domain: domain,
            status: .completed,
            quickStatus: quickStatus,
            entry: entry,
            resultSource: payload.snapshot.resultSource,
            errorMessage: payload.snapshot.statusMessage
        )
        batchCompletedCount += 1
        SweepActivityController.shared.update(
            completed: batchCompletedCount,
            total: batchTotalCount,
            currentDomain: batchCurrentDomain
        )
    }

    private func finishBatchLookup(source: BatchLookupSource) {
        batchLookupRunning = false
        batchCurrentDomain = nil
        activeBatchDomains = []
        refreshingTrackedDomainID = nil
        batchTask = nil

        let changedCount = batchResults.filter { $0.quickStatus == "Changed" || $0.quickStatus == "High" || $0.quickStatus == "Critical" }.count
        let unchangedCount = batchResults.filter { $0.quickStatus == "Unchanged" && $0.status == .completed }.count
        let warningCount = batchResults.filter {
            $0.certificateWarningLevel != .none
                || $0.changeClassification == .warning
                || $0.changeClassification == .critical
                || $0.riskLevel == .high
        }.count

        let summary = BatchSweepSummary(
            source: source,
            totalDomains: batchResults.count,
            changedDomains: changedCount,
            unchangedDomains: unchangedCount,
            warningDomains: warningCount,
            results: batchResults.sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status.rawValue < rhs.status.rawValue
                }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            },
            generatedAt: Date()
        )
        latestBatchSweepSummary = summary
        SweepActivityController.shared.end(changed: changedCount, warnings: warningCount)
        AppAccessibility.announce(
            "Sweep complete. \(summary.results.count) domains, \(changedCount) changed, \(warningCount) warnings."
        )

        if source == .workflow, let activeWorkflowRunID, let activeWorkflowRunName {
            let workflowReports: [DomainReport] = summary.results.compactMap { result in
                guard let entry = historyEntry(for: result) else { return nil }
                return report(for: entry)
            }
            latestWorkflowRunSummary = WorkflowRunSummary(
                workflowID: activeWorkflowRunID,
                workflowName: activeWorkflowRunName,
                totalDomains: batchResults.count,
                changedDomains: changedCount,
                unchangedDomains: unchangedCount,
                warningDomains: warningCount,
                results: summary.results,
                workflowInsights: DomainInsightEngine.workflowInsights(for: workflowReports),
                generatedAt: summary.generatedAt
            )
        }

        if notificationsAuthorized, source != .workflow {
            Task {
                await LocalNotificationService.shared.notifySweepComplete(summary: summary)
            }
        }
    }

    private func updateBatchResult(
        domain: String,
        status: BatchLookupStatus,
        quickStatus: String,
        entry: HistoryEntry?,
        resultSource: LookupResultSource = .live,
        errorMessage: String?
    ) {
        guard let index = batchResults.firstIndex(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }) else {
            return
        }

        batchResults[index] = BatchLookupResult(
            id: batchResults[index].id,
            domain: domain,
            historyEntryID: entry?.id,
            resultSource: resultSource,
            availability: entry?.availabilityResult?.status,
            primaryIP: entry?.primaryIP,
            quickStatus: quickStatus,
            summaryMessage: entry?.changeSummary?.message,
            changeSeverity: entry?.changeSummary?.severity,
            changeClassification: entry?.changeSummary?.impactClassification,
            certificateWarningLevel: entry.map { DomainDiffService.certificateWarningLevel(for: $0.snapshot) } ?? batchResults[index].certificateWarningLevel,
            riskScore: entry.map { $0.changeSummary?.riskAssessment?.score ?? report(for: $0).riskAssessment.score },
            riskLevel: entry.map { $0.changeSummary?.riskAssessment?.level ?? report(for: $0).riskAssessment.level },
            timestamp: entry?.timestamp ?? Date(),
            status: status,
            errorMessage: errorMessage
        )
    }

    private func clearLookupState() {
        dnsSections = []
        dnsError = nil
        dnsLoading = false
        availabilityResult = nil
        availabilityLoading = false
        suggestions = []
        suggestionsLoading = false
        sslInfo = nil
        sslError = nil
        sslLoading = false
        hstsPreloaded = nil
        hstsLoading = false
        httpHeaders = []
        httpSecurityGrade = nil
        httpStatusCode = nil
        httpResponseTimeMs = nil
        httpProtocol = nil
        http3Advertised = false
        httpHeadersError = nil
        httpHeadersLoading = false
        reachabilityResults = []
        reachabilityError = nil
        reachabilityLoading = false
        ipGeolocation = nil
        ipGeolocationError = nil
        ipGeolocationLoading = false
        emailSecurity = nil
        emailSecurityError = nil
        emailSecurityLoading = false
        ownershipResult = nil
        ownershipError = nil
        ownershipLoading = false
        ownershipHistory = []
        ownershipHistoryError = nil
        ownershipHistoryLoading = false
        ptrRecord = nil
        ptrError = nil
        ptrLoading = false
        redirectChain = []
        redirectChainError = nil
        redirectChainLoading = false
        subdomains = []
        subdomainsError = nil
        subdomainsLoading = false
        extendedSubdomains = []
        extendedSubdomainsError = nil
        extendedSubdomainsLoading = false
        dnsHistory = []
        dnsHistoryError = nil
        dnsHistoryLoading = false
        domainPricing = nil
        domainPricingError = nil
        domainPricingLoading = false
        portScanResults = []
        portScanError = nil
        portScanLoading = false
        customPortResults = []
        customPortScanError = nil
        customPortScanLoading = false
        currentHistoryEntryID = nil
        currentSnapshotTimestamp = Date()
        currentResultSource = .live
        currentCachedSections = []
        currentStatusMessage = nil
        currentReport = nil
    }

    private func setAllLoadingStates(_ loading: Bool) {
        dnsLoading = loading
        availabilityLoading = loading
        suggestionsLoading = loading
        sslLoading = loading
        hstsLoading = loading
        httpHeadersLoading = loading
        reachabilityLoading = loading
        ipGeolocationLoading = loading
        emailSecurityLoading = loading
        ownershipLoading = loading
        ownershipHistoryLoading = false
        ptrLoading = loading
        redirectChainLoading = loading
        subdomainsLoading = loading
        extendedSubdomainsLoading = false
        dnsHistoryLoading = false
        domainPricingLoading = false
        portScanLoading = loading
    }

    private func primaryIPAddress(from sections: [DNSSection]) -> String? {
        sections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    private func isCurrentLookup(_ lookupID: UUID) -> Bool {
        activeLookupID == lookupID
    }

    func recentSnapshots(for trackedDomain: TrackedDomain, limit: Int = 6) -> [HistoryEntry] {
        history
            .filter { $0.trackedDomainID == trackedDomain.id || $0.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    func latestSnapshots(for domains: [TrackedDomain]) -> [HistoryEntry] {
        domains.compactMap { trackedDomain in
            recentSnapshots(for: trackedDomain, limit: 1).first
        }
    }

    func diffSectionsForLatestSnapshots(of trackedDomain: TrackedDomain) -> [DomainDiffSection] {
        let snapshots = recentSnapshots(for: trackedDomain, limit: 2)
        guard snapshots.count == 2 else { return [] }
        return DomainDiffService.diff(from: snapshots[1].snapshot, to: snapshots[0].snapshot)
    }

    func latestChangeSummary(for trackedDomain: TrackedDomain) -> DomainChangeSummary? {
        trackedDomain.lastChangeSummary ?? recentSnapshots(for: trackedDomain, limit: 1).first?.changeSummary
    }

    func latestSnapshot(for trackedDomain: TrackedDomain) -> LookupSnapshot? {
        recentSnapshots(for: trackedDomain, limit: 1).first?.snapshot
    }

    func trackedDomain(withID id: UUID) -> TrackedDomain? {
        trackedDomains.first(where: { $0.id == id })
    }

    private func portfolioDashboardStamp() -> PortfolioDashboardStamp {
        PortfolioDashboardStamp(
            trackedDomainSignature: trackedDomains
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map {
                    [
                        $0.id.uuidString,
                        $0.updatedAt.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(3))),
                        String($0.pendingMonitoringAlerts.count),
                        $0.lastMonitoredAt?.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(3))) ?? "0",
                        $0.lastAlertAt?.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(3))) ?? "0"
                    ].joined(separator: "|")
                },
            historySignature: history
                .prefix(250)
                .map {
                    [
                        $0.id.uuidString,
                        $0.timestamp.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(3))),
                        String($0.changeCount),
                        $0.severitySummary?.rawValue.description ?? "-"
                    ].joined(separator: "|")
                },
            monitoringSignature: monitoringLogs
                .prefix(100)
                .map {
                    [
                        $0.id.uuidString,
                        $0.timestamp.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(3))),
                        String($0.alertsTriggered),
                        String($0.changesFound)
                    ].joined(separator: "|")
                }
        )
    }

    private func buildPortfolioDomainStates() -> [PortfolioDomainStatus] {
        let now = Date()
        return sortedTrackedDomains(from: trackedDomains, using: .pinned).map { trackedDomain in
            let recentEntries = recentSnapshots(for: trackedDomain, limit: 8)
            let latestEntry = recentEntries.first
            let report = latestEntry.map { self.report(for: $0) } ?? reportBuilder.build(from: placeholderSnapshot(for: trackedDomain))
            let recentMonitoringResults = monitoringLogs
                .flatMap(\.checkedDomains)
                .filter { $0.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame }
                .sorted { $0.checkedAt > $1.checkedAt }
            let recentFailureResults = recentMonitoringResults.filter {
                let isFailure = $0.errorMessage != nil || ($0.alertSeverity ?? .info) >= .warning
                return isFailure && now.timeIntervalSince($0.checkedAt) <= 7 * 24 * 60 * 60
            }
            let recentChangeCount = recentEntries.filter {
                guard let changeSummary = $0.changeSummary, changeSummary.hasChanges else { return false }
                return now.timeIntervalSince($0.timestamp) <= 7 * 24 * 60 * 60
            }.count
            let recentDNSChange = recentEntries.contains {
                guard let changeSummary = $0.changeSummary else { return false }
                return changeSummary.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("dns") })
                    && now.timeIntervalSince($0.timestamp) <= 7 * 24 * 60 * 60
            }
            let recentCriticalChange = recentEntries.contains {
                guard let changeSummary = $0.changeSummary else { return false }
                return changeSummary.impactClassification == .critical
                    && now.timeIntervalSince($0.timestamp) <= 7 * 24 * 60 * 60
            }
            let certificateExpiryState = trackedDomain.certificateWarningLevel == .none
                ? report.certificateExpiryState
                : trackedDomain.certificateWarningLevel
            let isUnreachable: Bool = {
                if let latestEntry {
                    if !latestEntry.reachabilityResults.isEmpty {
                        return !latestEntry.reachabilityResults.contains(where: \.reachable)
                    }
                    if latestEntry.reachabilityError != nil {
                        return true
                    }
                }
                return recentFailureResults.contains { ($0.alertSeverity ?? .info) == .critical && $0.errorMessage != nil }
            }()
            let hasInvalidTLS = latestEntry?.sslInfo == nil && latestEntry?.sslError != nil
            let instabilityScore = DomainHealth.instabilityScore(
                recentChangeCount: recentChangeCount,
                recentFailureCount: recentFailureResults.count,
                pendingAlertCount: trackedDomain.pendingMonitoringAlerts.count,
                hasRecentDNSChange: recentDNSChange
            )
            let health = DomainHealth.classify(
                certificateExpiryState: certificateExpiryState,
                isReachable: !isUnreachable,
                recentMonitoringFailureCount: recentFailureResults.count,
                hasRecentDNSChange: recentDNSChange,
                instabilityScore: instabilityScore,
                hasRecentCriticalChange: recentCriticalChange,
                hasInvalidTLS: hasInvalidTLS
            )

            return PortfolioDomainStatus(
                trackedDomain: trackedDomain,
                latestEntry: latestEntry,
                report: report,
                apexDomain: apexDomain(for: trackedDomain.domain),
                health: health,
                lastChangeDate: latestEntry?.changeSummary?.hasChanges == true
                    ? latestEntry?.timestamp
                    : trackedDomain.monitoringState.lastChangeDate ?? report.lastChangeDate,
                lastMonitoringFailure: recentFailureResults.first?.checkedAt,
                instabilityScore: instabilityScore,
                certificateExpiryState: certificateExpiryState,
                certificateDaysRemaining: trackedDomain.certificateDaysRemaining ?? latestEntry?.sslInfo?.daysUntilExpiry,
                isUnreachable: isUnreachable,
                recentDNSChange: recentDNSChange,
                recentCriticalChange: recentCriticalChange,
                recentFailureCount: recentFailureResults.count
            )
        }
    }

    private func buildPortfolioActivity(from domainStates: [PortfolioDomainStatus]) -> [PortfolioActivityItem] {
        var items: [PortfolioActivityItem] = []
        let healthByDomainID = Dictionary(uniqueKeysWithValues: domainStates.map { ($0.trackedDomain.id, $0.health) })

        for state in domainStates {
            if let latestEntry = state.latestEntry,
               let changeSummary = latestEntry.changeSummary,
               changeSummary.hasChanges {
                items.append(
                    PortfolioActivityItem(
                        id: "history|\(latestEntry.id.uuidString)",
                        trackedDomainID: state.trackedDomain.id,
                        domain: state.trackedDomain.domain,
                        message: portfolioHistoryMessage(for: latestEntry),
                        timestamp: latestEntry.timestamp,
                        health: state.health,
                        systemImage: portfolioHistoryIcon(for: latestEntry)
                    )
                )
            }
        }

        for log in monitoringLogs.prefix(25) {
            for result in log.checkedDomains where result.didChange || result.errorMessage != nil || result.certificateWarningLevel != .none {
                guard let trackedDomain = trackedDomain(for: result.domain) else { continue }
                items.append(
                    PortfolioActivityItem(
                        id: "monitoring|\(log.id.uuidString)|\(result.id.uuidString)",
                        trackedDomainID: trackedDomain.id,
                        domain: trackedDomain.domain,
                        message: portfolioMonitoringMessage(for: result),
                        timestamp: result.checkedAt,
                        health: healthByDomainID[trackedDomain.id] ?? (result.alertSeverity == .critical ? .critical : .warning),
                        systemImage: portfolioMonitoringIcon(for: result)
                    )
                )
            }
        }

        var seen = Set<String>()
        return items
            .sorted { $0.timestamp > $1.timestamp }
            .filter { item in
                let key = "\(item.domain.lowercased())|\(item.message.lowercased())"
                return seen.insert(key).inserted
            }
    }

    private func buildAttentionQueue(from domainStates: [PortfolioDomainStatus]) -> [PortfolioAttentionItem] {
        domainStates.compactMap { state in
            guard state.health != .healthy else { return nil }
            let (reason, timestamp) = Self.attentionReason(for: state)
            return PortfolioAttentionItem(
                id: "\(state.trackedDomain.id.uuidString)|\(reason)",
                trackedDomainID: state.trackedDomain.id,
                domain: state.trackedDomain.domain,
                reason: reason,
                timestamp: timestamp,
                health: state.health
            )
        }
        .sorted { lhs, rhs in
            if lhs.health != rhs.health {
                return healthRank(lhs.health) > healthRank(rhs.health)
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    /// Why an unhealthy domain needs attention, most urgent cause first, and
    /// when that cause was last seen.
    private static func attentionReason(for state: PortfolioDomainStatus) -> (reason: String, timestamp: Date) {
        let changedAt = state.lastChangeDate ?? state.trackedDomain.updatedAt
        let failedAt = state.lastMonitoringFailure ?? state.trackedDomain.updatedAt
        if state.isUnreachable {
            return ("Endpoint is unreachable", failedAt)
        }
        if state.certificateExpiryState == .critical {
            return ("Certificate is expiring in under 14 days", changedAt)
        }
        if state.certificateExpiryState == .warning {
            return ("Certificate expires within 30 days", changedAt)
        }
        if state.recentFailureCount >= 2 || state.instabilityScore >= 70 {
            return ("Repeated instability detected", failedAt)
        }
        if state.recentDNSChange {
            return ("DNS changed recently", changedAt)
        }
        if state.recentCriticalChange {
            return ("Recent critical change detected", changedAt)
        }
        return ("Needs attention", state.trackedDomain.updatedAt)
    }

    private func buildPortfolioGroups(from domainStates: [PortfolioDomainStatus]) -> [PortfolioGroup] {
        Dictionary(grouping: domainStates, by: \.apexDomain)
            .map { apexDomain, domains in
                PortfolioGroup(
                    apexDomain: apexDomain,
                    domains: domains.sorted { lhs, rhs in
                        if lhs.health != rhs.health {
                            return healthRank(lhs.health) > healthRank(rhs.health)
                        }
                        return lhs.trackedDomain.domain.localizedCaseInsensitiveCompare(rhs.trackedDomain.domain) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                if let lhsMostSevere = lhs.domains.map(\.health).map(healthRank).max(),
                   let rhsMostSevere = rhs.domains.map(\.health).map(healthRank).max(),
                   lhsMostSevere != rhsMostSevere {
                    return lhsMostSevere > rhsMostSevere
                }
                return lhs.apexDomain.localizedCaseInsensitiveCompare(rhs.apexDomain) == .orderedAscending
            }
    }

    private func matchesPortfolioFilter(_ state: PortfolioDomainStatus) -> Bool {
        switch dashboardFilter {
        case .all:
            return true
        case .healthy:
            return state.health == .healthy
        case .warning:
            return state.health == .warning
        case .critical:
            return state.health == .critical
        case .changed:
            guard let lastChangeDate = state.lastChangeDate else { return false }
            return Date().timeIntervalSince(lastChangeDate) <= 24 * 60 * 60
        case .expiring:
            return state.certificateExpiryState != .none
        case .unreachable:
            return state.isUnreachable
        }
    }

    private func matchesDashboardSearch(_ state: PortfolioDomainStatus, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedQuery = query.lowercased()
        return state.trackedDomain.domain.lowercased().contains(normalizedQuery)
            || state.apexDomain.lowercased().contains(normalizedQuery)
    }

    private func portfolioHistoryMessage(for entry: HistoryEntry) -> String {
        guard let summary = entry.changeSummary else {
            return "Configuration changed for \(entry.domain)"
        }
        if summary.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("dns") }) {
            return "DNS changed for \(entry.domain)"
        }
        if summary.changedSections.contains(where: {
            $0.localizedCaseInsensitiveContains("certificate")
                || $0.localizedCaseInsensitiveContains("tls")
        }) {
            return "Certificate updated for \(entry.domain)"
        }
        if summary.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("redirect") }) {
            return "Redirect chain changed for \(entry.domain)"
        }
        return summary.message
    }

    private func portfolioHistoryIcon(for entry: HistoryEntry) -> String {
        guard let summary = entry.changeSummary else { return "clock.arrow.trianglehead.counterclockwise.rotate.90" }
        if summary.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("dns") }) {
            return "point.3.connected.trianglepath.dotted"
        }
        if summary.changedSections.contains(where: {
            $0.localizedCaseInsensitiveContains("certificate")
                || $0.localizedCaseInsensitiveContains("tls")
        }) {
            return "lock.rotation"
        }
        if summary.changedSections.contains(where: { $0.localizedCaseInsensitiveContains("redirect") }) {
            return "arrow.triangle.branch"
        }
        return "clock.arrow.trianglehead.counterclockwise.rotate.90"
    }

    private func portfolioMonitoringMessage(for result: MonitoringDomainResult) -> String {
        if result.errorMessage != nil {
            return "Monitoring failed for \(result.domain)"
        }
        if result.certificateWarningLevel != .none {
            return "Certificate needs attention for \(result.domain)"
        }
        if result.didChange {
            return result.summaryMessage.isEmpty ? "Monitoring detected a change for \(result.domain)" : result.summaryMessage
        }
        return "Monitoring updated \(result.domain)"
    }

    private func portfolioMonitoringIcon(for result: MonitoringDomainResult) -> String {
        if result.errorMessage != nil {
            return "xmark.octagon.fill"
        }
        if result.certificateWarningLevel != .none {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.path.ecg"
    }

    private func apexDomain(for domain: String) -> String {
        let parts = domain
            .lowercased()
            .split(separator: ".")
            .map(String.init)
        guard parts.count > 2 else { return domain.lowercased() }
        return parts.suffix(2).joined(separator: ".")
    }

    private func healthRank(_ health: DomainHealth) -> Int {
        switch health {
        case .healthy:
            return 0
        case .warning:
            return 1
        case .critical:
            return 2
        }
    }

    private func exportSnapshots(for domains: [TrackedDomain]) -> [LookupSnapshot] {
        let latestEntries = latestSnapshots(for: domains)

        return domains.map { trackedDomain in
            if let entry = latestEntries.first(where: { $0.trackedDomainID == trackedDomain.id || $0.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame }) {
                return entry.snapshot
            }
            return placeholderSnapshot(for: trackedDomain)
        }
    }

    func currentBatchReports() -> [DomainReport] {
        currentBatchResultEntries.map { entry in
            report(for: entry, workflowContext: activeWorkflowContext)
        }
    }

    func workflowReports(from summary: WorkflowRunSummary, changedOnly: Bool) -> [DomainReport] {
        let filteredResults = changedOnly ? summary.results.filter(\.hasMeaningfulChange) : summary.results
        return filteredResults.compactMap { result in
            guard let entry = historyEntry(for: result) else { return nil }
            return report(
                for: entry,
                workflowContext: DomainWorkflowContext(
                    workflowID: summary.workflowID,
                    workflowName: summary.workflowName,
                    source: "workflow"
                )
            )
        }
    }

    func reports(for domains: [TrackedDomain]) -> [DomainReport] {
        let latestEntries = latestSnapshots(for: domains)

        return domains.map { trackedDomain in
            if let entry = latestEntries.first(where: {
                $0.trackedDomainID == trackedDomain.id ||
                $0.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame
            }) {
                return report(for: entry)
            }

            return reportBuilder.build(from: placeholderSnapshot(for: trackedDomain))
        }
    }

    func timelineReports(for domain: String) -> [DomainReport] {
        historyEntries(for: domain).map { report(for: $0) }
    }

    private func report(for entry: HistoryEntry, workflowContext: DomainWorkflowContext? = nil) -> DomainReport {
        reportBuilder.build(
            from: entry,
            previousSnapshot: comparisonSnapshot(for: entry),
            workflowContext: workflowContext,
            historyEntries: historyEntries(for: entry.domain)
        )
    }

    private var activeWorkflowContext: DomainWorkflowContext? {
        guard batchLookupSource == .workflow, let activeWorkflowRunID, let activeWorkflowRunName else {
            return nil
        }
        return DomainWorkflowContext(
            workflowID: activeWorkflowRunID,
            workflowName: activeWorkflowRunName,
            source: "workflow"
        )
    }

    private static var defaultAuditReviewer: String {
        let reviewer = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return reviewer.isEmpty ? "Local Reviewer" : reviewer
    }

    private func snapshotEvidenceAssets(from report: DomainReport) -> [AuditEvidenceAsset] {
        var assets: [AuditEvidenceAsset] = []
        if let finalURL = report.web.finalURL {
            assets.append(AuditEvidenceAsset(title: "Final URL", kind: .document, reference: finalURL))
        }
        if let registrar = report.ownership?.registrar {
            assets.append(AuditEvidenceAsset(title: "Registrar", kind: .document, reference: registrar))
        }
        if let primaryIP = report.dns.primaryIP {
            assets.append(AuditEvidenceAsset(title: "Primary IP", kind: .document, reference: primaryIP))
        }
        if !report.web.redirectChain.isEmpty {
            assets.append(
                AuditEvidenceAsset(
                    title: "Redirect Chain",
                    kind: .document,
                    reference: report.web.redirectChain.map { "\($0.statusCode) \($0.url)" }.joined(separator: " | ")
                )
            )
        }
        if !report.web.headers.isEmpty {
            assets.append(
                AuditEvidenceAsset(
                    title: "Observed Headers",
                    kind: .document,
                    reference: report.web.headers.prefix(6).map { "\($0.name): \($0.value)" }.joined(separator: " | ")
                )
            )
        }
        return assets
    }

    private func placeholderSnapshot(for trackedDomain: TrackedDomain) -> LookupSnapshot {
        LookupSnapshot(
            historyEntryID: trackedDomain.lastSnapshotID,
            domain: trackedDomain.domain,
            timestamp: trackedDomain.updatedAt,
            trackedDomainID: trackedDomain.id,
            note: trackedDomain.note,
            appVersion: AppVersion.current,
            resolverDisplayName: resolverDisplayName,
            resolverURLString: resolverURLString,
            dataSources: [],
            provenanceBySection: [:],
            availabilityConfidence: nil,
            ownershipConfidence: nil,
            subdomainConfidence: nil,
            emailSecurityConfidence: nil,
            geolocationConfidence: nil,
            errorDetails: [:],
            isPartialSnapshot: true,
            validationIssues: ["No stored snapshot data available"],
            totalLookupDurationMs: nil,
            snapshotIndex: nil,
            previousSnapshotID: nil,
            changeCount: 0,
            severitySummary: trackedDomain.lastChangeSeverity,
            dnsSections: [],
            dnsError: nil,
            availabilityResult: DomainAvailabilityResult(domain: trackedDomain.domain, status: trackedDomain.lastKnownAvailability ?? .unknown),
            suggestions: [],
            sslInfo: nil,
            sslError: nil,
            hstsPreloaded: nil,
            httpHeaders: [],
            httpSecurityGrade: nil,
            httpStatusCode: nil,
            httpResponseTimeMs: nil,
            httpProtocol: nil,
            http3Advertised: false,
            httpHeadersError: nil,
            reachabilityResults: [],
            reachabilityError: nil,
            ipGeolocation: nil,
            ipGeolocationError: nil,
            emailSecurity: nil,
            emailSecurityError: nil,
            ownership: nil,
            ownershipError: nil,
            ownershipHistory: [],
            ownershipHistoryError: nil,
            inferredProvider: nil,
            priorProviders: [],
            domainClassification: nil,
            ownershipTransitions: [],
            hostingTransitions: [],
            subdomainHistory: [],
            riskSignals: [],
            intelligenceTimeline: [],
            ptrRecord: nil,
            ptrError: nil,
            redirectChain: [],
            redirectChainError: nil,
            subdomains: [],
            subdomainsError: nil,
            extendedSubdomains: [],
            extendedSubdomainsError: nil,
            dnsHistory: [],
            dnsHistoryError: nil,
            domainPricing: nil,
            domainPricingError: nil,
            reputation: nil,
            reputationError: nil,
            portScanResults: [],
            portScanError: nil,
            changeSummary: trackedDomain.lastChangeSummary,
            resultSource: .snapshot,
            cachedSections: [],
            statusMessage: nil
        )
    }

    private static func loadHistoryEntries() -> [HistoryEntry] {
        DataMigrationService.migrateIfNeeded()
        return DomainDataPortabilityService.loadHistoryEntries()
    }

    private static func loadHistoryAutoPruneOption() -> HistoryAutoPruneOption {
        guard let rawValue = UserDefaults.standard.string(forKey: historyAutoPruneKey),
              let option = HistoryAutoPruneOption(rawValue: rawValue) else {
            return .unlimited
        }
        return option
    }

    private static func loadTrackedDomains() -> [TrackedDomain] {
        DataMigrationService.migrateIfNeeded()
        return DomainDataPortabilityService.loadTrackedDomains()
    }

    func persistWorkflows() {
        DomainDataPortabilityService.saveWorkflows(workflows)
        CloudSyncService.shared.scheduleSyncIfNeeded()
        refreshDataLifecycleSummary()
    }

    static func loadWorkflows() -> [DomainWorkflow] {
        DataMigrationService.migrateIfNeeded()
        return DomainDataPortabilityService.loadWorkflows()
    }

    private static func deduplicatedTrackedDomains(_ domains: [TrackedDomain]) -> [TrackedDomain] {
        var seen = Set<String>()
        return domains.filter { domain in
            let key = domain.domain.lowercased()
            return seen.insert(key).inserted
        }
    }

    func normalizedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains
            .map(normalizedDomain)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func historySortPredicate(lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        switch historySortOption {
        case .newest:
            return lhs.timestamp > rhs.timestamp
        case .oldest:
            return lhs.timestamp < rhs.timestamp
        case .domain:
            let domainOrder = lhs.domain.localizedCaseInsensitiveCompare(rhs.domain)
            if domainOrder != .orderedSame {
                return domainOrder == .orderedAscending
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func sortedTrackedDomains(from domains: [TrackedDomain], using sortOption: WatchlistSortOption) -> [TrackedDomain] {
        domains.sorted { lhs, rhs in
            switch sortOption {
            case .pinned:
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            case .recentlyUpdated:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            case .alphabetical:
                let domainOrder = lhs.domain.localizedCaseInsensitiveCompare(rhs.domain)
                if domainOrder != .orderedSame {
                    return domainOrder == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    static func summaryFields(from snapshot: LookupSnapshot) -> [SummaryFieldViewData] {
        [
            SummaryFieldViewData(label: "Domain", value: snapshot.domain.nilIfEmpty ?? "Unavailable", tone: .primary),
            SummaryFieldViewData(label: "Observed IP", value: primaryIPAddress(from: snapshot) ?? "Unavailable", tone: .primary),
            SummaryFieldViewData(label: "Observed Redirect", value: finalRedirectTarget(from: snapshot) ?? "Unavailable", tone: .secondary),
            SummaryFieldViewData(label: "Inference", value: availabilityInference(from: snapshot), tone: availabilityTone(snapshot.availabilityResult?.status)),
            SummaryFieldViewData(label: "Observed TLS", value: httpsSummary(from: snapshot), tone: httpsSummaryTone(from: snapshot)),
            SummaryFieldViewData(label: "Certificate", value: certificateStatusLabel(from: snapshot), tone: certificateStatusTone(from: snapshot)),
            SummaryFieldViewData(label: "Source", value: snapshot.statusMessage ?? snapshot.resultSource.label, tone: sourceTone(for: snapshot))
        ]
    }

    static func domainRows(from snapshot: LookupSnapshot) -> [InfoRowViewData] {
        var rows = [
            InfoRowViewData(label: "Domain", value: snapshot.domain, tone: .primary),
            InfoRowViewData(label: "Resolver", value: snapshot.resolverDisplayName, tone: .secondary),
            InfoRowViewData(label: "Collected", value: snapshot.timestamp.formatted(date: .abbreviated, time: .shortened), tone: .secondary),
            InfoRowViewData(label: snapshot.statusMessage == nil ? "Result" : "Snapshot", value: snapshot.statusMessage ?? snapshot.resultSource.label, tone: sourceTone(for: snapshot)),
            InfoRowViewData(label: "Lookup Duration", value: durationLabel(snapshot.totalLookupDurationMs), tone: .secondary)
        ]
        rows.insert(
            InfoRowViewData(
                label: "Observed Availability",
                value: snapshot.availabilityResult?.status == .unknown ? "No direct registration proof" : "Status collected",
                tone: .secondary
            ),
            at: 1
        )
        rows.insert(
            InfoRowViewData(
                label: "Inference",
                value: availabilityInference(from: snapshot),
                tone: availabilityTone(snapshot.availabilityResult?.status)
            ),
            at: 2
        )
        if let confidence = snapshot.availabilityConfidence {
            rows.insert(
                InfoRowViewData(label: "Confidence", value: confidence.title, tone: .secondary),
                at: 3
            )
        }
        if let pricing = snapshot.domainPricing {
            rows += pricingRows(pricing)
        }
        if let reputation = snapshot.reputation {
            rows.append(reputationRow(reputation))
        }
        if let certificateStatus = certificateBadgeLabel(from: snapshot) {
            rows.insert(
                InfoRowViewData(
                    label: "Certificate",
                    value: certificateStatus,
                    tone: certificateStatusTone(from: snapshot)
                ),
                at: 2
            )
        }
        return rows
    }

    private static func pricingRows(_ pricing: DomainPricingInsight) -> [InfoRowViewData] {
        var rows = [InfoRowViewData(label: "External Price", value: pricing.estimatedPrice ?? "Unavailable", tone: .secondary)]
        if let premiumIndicator = pricing.premiumIndicator {
            rows.append(
                InfoRowViewData(
                    label: "Premium",
                    value: premiumIndicator ? "Yes" : "No",
                    tone: premiumIndicator ? .warning : .secondary
                )
            )
        }
        if let resaleSignal = pricing.resaleSignal {
            rows.append(InfoRowViewData(label: "Resale", value: resaleSignal, tone: .secondary))
        }
        if let auctionSignal = pricing.auctionSignal {
            rows.append(InfoRowViewData(label: "Auction", value: auctionSignal, tone: .secondary))
        }
        return rows
    }

    private static func reputationRow(_ reputation: DomainReputationResult) -> InfoRowViewData {
        let tone: ResultTone
        switch reputation.status {
        case .clean: tone = .success
        case .listed: tone = .failure
        case .unknown: tone = .secondary
        }
        let value = reputation.status == .listed && !reputation.listedSources.isEmpty
            ? "\(reputation.status.title) (\(reputation.listedSources.joined(separator: ", ")))"
            : reputation.status.title
        return InfoRowViewData(label: "Reputation", value: value, tone: tone)
    }

    static func suggestionRows(from snapshot: LookupSnapshot) -> [DomainSuggestionViewData] {
        snapshot.suggestions.map {
            DomainSuggestionViewData(
                id: $0.id,
                domain: $0.domain,
                availabilityStatus: $0.status,
                status: availabilityLabel($0.status),
                tone: availabilityTone($0.status)
            )
        }
    }

    static func subdomainRows(from subdomains: [DiscoveredSubdomain]) -> [SubdomainRowViewData] {
        subdomains.map { subdomain in
            SubdomainRowViewData(
                hostname: subdomain.hostname,
                isInteresting: subdomain.isExtended || isInterestingSubdomain(subdomain.hostname)
            )
        }
    }

    static func dnsRows(from snapshot: LookupSnapshot) -> [DNSRecordSectionViewData] {
        snapshot.dnsSections.map { section in
            DNSRecordSectionViewData(
                title: section.recordType.rawValue,
                rows: section.records.map { InfoRowViewData(label: "TTL \($0.ttl)", value: $0.value, tone: .primary, speechStyle: .technical) },
                wildcardRows: section.wildcardRecords.map { InfoRowViewData(label: "TTL \($0.ttl)", value: $0.value, tone: .primary, speechStyle: .technical) },
                wildcardTitle: section.wildcardRecords.isEmpty ? nil : "*.\(snapshot.domain)",
                message: section.error.map { SectionMessageViewData(text: $0, isError: true) } ??
                    ((section.records.isEmpty && section.wildcardRecords.isEmpty) ? SectionMessageViewData(text: "No records found", isError: false) : nil)
            )
        }
    }

    static func dnssecLabel(from snapshot: LookupSnapshot) -> String? {
        guard let signed = snapshot.dnsSections.compactMap(\.dnssecSigned).first else { return nil }
        return "Resolver-reported DNSSEC (not full validation): \(signed ? "Yes" : "No")"
    }

    static func ptrMessage(from snapshot: LookupSnapshot) -> SectionMessageViewData? {
        if let ptrRecord = snapshot.ptrRecord {
            return SectionMessageViewData(text: ptrRecord, isError: false)
        }
        if let ptrError = snapshot.ptrError {
            return SectionMessageViewData(text: ptrError, isError: ptrError != "No A record available" && ptrError != "No PTR record found")
        }
        return nil
    }

    static func webCertificateRows(from snapshot: LookupSnapshot) -> [InfoRowViewData] {
        guard let sslInfo = snapshot.sslInfo else { return [] }
        var rows = [
            InfoRowViewData(label: "Common Name", value: sslInfo.commonName, tone: .primary),
            InfoRowViewData(label: "Issuer", value: sslInfo.issuer, tone: .primary),
            InfoRowViewData(label: "Valid From", value: certificateDateFormatter.string(from: sslInfo.validFrom), tone: .secondary),
            InfoRowViewData(label: "Valid Until", value: certificateDateFormatter.string(from: sslInfo.validUntil), tone: .secondary),
            InfoRowViewData(label: "Days Until Expiry", value: "\(sslInfo.daysUntilExpiry)", tone: certificateTone(daysRemaining: sslInfo.daysUntilExpiry)),
            InfoRowViewData(label: "Chain Depth", value: "\(sslInfo.chainDepth)", tone: .secondary)
        ]
        if let tlsVersion = sslInfo.tlsVersion {
            rows.append(InfoRowViewData(label: "TLS Version", value: tlsVersion, tone: .secondary))
        }
        if let cipherSuite = sslInfo.cipherSuite {
            rows.append(InfoRowViewData(label: "Cipher Suite", value: cipherSuite, tone: .secondary, speechStyle: .technical))
        }
        if let hstsPreloaded = snapshot.hstsPreloaded {
            rows.append(InfoRowViewData(label: "HSTS Preload", value: hstsPreloaded ? "Preloaded" : "Not preloaded", tone: hstsPreloaded ? .success : .secondary))
        }
        return rows
    }

    static func webResponseRows(from snapshot: LookupSnapshot) -> [InfoRowViewData] {
        var rows: [InfoRowViewData] = []
        if let httpStatusCode = snapshot.httpStatusCode {
            rows.append(InfoRowViewData(label: "Status", value: "\(httpStatusCode)", tone: .primary))
        }
        if let httpResponseTimeMs = snapshot.httpResponseTimeMs {
            rows.append(InfoRowViewData(label: "Response Time", value: "\(httpResponseTimeMs) ms", tone: .secondary))
        }
        if let httpProtocol = snapshot.httpProtocol {
            rows.append(InfoRowViewData(label: "Protocol", value: httpProtocol, tone: .secondary))
        }
        if let httpSecurityGrade = snapshot.httpSecurityGrade {
            rows.append(InfoRowViewData(label: "Security Grade", value: httpSecurityGrade, tone: securityGradeTone(httpSecurityGrade)))
        }
        if snapshot.http3Advertised {
            rows.append(InfoRowViewData(label: "HTTP/3", value: "Advertised", tone: .secondary))
        }
        return rows
    }

    static func redirectRows(from snapshot: LookupSnapshot) -> [RedirectHopViewData] {
        snapshot.redirectChain.map {
            RedirectHopViewData(
                stepLabel: "\($0.stepNumber)",
                statusCode: "\($0.statusCode)",
                url: $0.url,
                isFinal: $0.isFinal
            )
        }
    }

    static func emailRows(from snapshot: LookupSnapshot) -> [EmailRowViewData] {
        guard let emailSecurity = snapshot.emailSecurity else { return [] }
        return [
            EmailRowViewData(label: "SPF", status: emailSecurity.spf.found ? "Present" : "Missing", statusTone: emailSecurity.spf.found ? .success : .warning, detail: emailSecurity.spf.value ?? "No record found", auxiliaryDetail: nil),
            EmailRowViewData(label: "DMARC", status: emailSecurity.dmarc.found ? "Present" : "Missing", statusTone: emailSecurity.dmarc.found ? .success : .warning, detail: emailSecurity.dmarc.value ?? "No record found", auxiliaryDetail: nil),
            EmailRowViewData(label: "DKIM", status: emailSecurity.dkim.found ? "Present" : "Missing", statusTone: emailSecurity.dkim.found ? .success : .warning, detail: emailSecurity.dkim.value ?? "No record found", auxiliaryDetail: emailSecurity.dkim.matchedSelector.map { "Selector: \($0)" }),
            EmailRowViewData(label: "MTA-STS", status: emailSecurity.mtaSts?.txtFound == true ? "Present" : "Missing", statusTone: emailSecurity.mtaSts?.txtFound == true ? .success : .warning, detail: emailSecurity.mtaSts?.policyMode ?? (emailSecurity.mtaSts?.txtFound == true ? "Policy unavailable" : "No record found"), auxiliaryDetail: nil),
            EmailRowViewData(label: "BIMI", status: emailSecurity.bimi.found ? "Present" : "Missing", statusTone: emailSecurity.bimi.found ? .success : .warning, detail: emailSecurity.bimi.value ?? "No record found", auxiliaryDetail: nil)
        ]
    }

    static func ownershipRows(from snapshot: LookupSnapshot) -> [InfoRowViewData] {
        let ownership = snapshot.ownership

        return [
            InfoRowViewData(label: "Registrar", value: ownership?.registrar ?? "Unavailable", tone: ownership?.registrar == nil ? .secondary : .primary),
            InfoRowViewData(label: "Registered", value: ownership?.createdDate.map(ownershipDateFormatter.string(from:)) ?? "Unavailable", tone: ownership?.createdDate == nil ? .secondary : .primary),
            InfoRowViewData(label: "Expires", value: ownership?.expirationDate.map(ownershipDateFormatter.string(from:)) ?? "Unavailable", tone: ownership?.expirationDate == nil ? .secondary : .primary),
            InfoRowViewData(label: "Status", value: ownership?.status.nilIfEmpty?.joined(separator: ", ") ?? "Unavailable", tone: ownership?.status.isEmpty == false ? .primary : .secondary),
            InfoRowViewData(label: "Nameservers", value: ownership?.nameservers.nilIfEmpty?.joined(separator: ", ") ?? "Unavailable", tone: ownership?.nameservers.isEmpty == false ? .primary : .secondary),
            InfoRowViewData(label: "Abuse Contact", value: ownership?.abuseEmail ?? "Unavailable", tone: ownership?.abuseEmail == nil ? .secondary : .primary)
        ]
    }

    static func subdomainRows(from snapshot: LookupSnapshot) -> [SubdomainRowViewData] {
        snapshot.subdomains.map { subdomain in
            SubdomainRowViewData(
                hostname: subdomain.hostname,
                isInteresting: isInterestingSubdomain(subdomain.hostname)
            )
        }
    }

    static func reachabilityRows(from snapshot: LookupSnapshot) -> [ReachabilityRowViewData] {
        snapshot.reachabilityResults.map {
            ReachabilityRowViewData(
                portLabel: "Port \($0.port)",
                latencyLabel: $0.latencyMs.map { "\($0) ms" } ?? "—",
                statusLabel: $0.reachable ? "Reachable" : "Unreachable",
                statusTone: $0.reachable ? .success : .failure
            )
        }
    }

    static func locationRows(from snapshot: LookupSnapshot) -> [InfoRowViewData] {
        guard let ipGeolocation = snapshot.ipGeolocation else { return [] }
        var rows = [InfoRowViewData(label: "IP", value: ipGeolocation.ip, tone: .primary)]
        if let org = ipGeolocation.org {
            rows.append(InfoRowViewData(label: "Org / ISP", value: org, tone: .secondary))
        }
        let location = [ipGeolocation.city, ipGeolocation.region, ipGeolocation.countryName].compactMap { $0 }.joined(separator: ", ")
        if !location.isEmpty {
            rows.append(InfoRowViewData(label: "Location", value: location, tone: .secondary))
        }
        if let latitude = ipGeolocation.latitude, let longitude = ipGeolocation.longitude {
            rows.append(InfoRowViewData(label: "Coordinates", value: "\(latitude), \(longitude)", tone: .secondary))
        }
        return rows
    }

    static func portRows(from snapshot: LookupSnapshot, kind: PortScanKind) -> [PortScanRowViewData] {
        snapshot.portScanResults
            .filter { $0.kind == kind }
            .map {
                PortScanRowViewData(
                    portLabel: "\($0.port)",
                    service: $0.service,
                    statusLabel: $0.open ? "Open" : "Closed",
                    statusTone: $0.open ? .success : .secondary,
                    banner: $0.banner,
                    durationLabel: $0.durationMs.map { "\($0) ms" }
                )
            }
    }

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
        if !DataAccessService.hasAccess(to: .ownershipHistory) {
            lines.append("  Ownership history (coming soon)")
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
        if !DataAccessService.hasAccess(to: .extendedSubdomains) {
            lines.append("  Extended subdomain discovery (Pro+)")
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

    private static func primaryIPAddress(from snapshot: LookupSnapshot) -> String? {
        snapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    private static func finalRedirectTarget(from snapshot: LookupSnapshot) -> String? {
        snapshot.redirectChain.last?.url
    }

    private static func httpStatusGradeSummary(from snapshot: LookupSnapshot) -> String {
        let parts = [snapshot.httpStatusCode.map(String.init), snapshot.httpSecurityGrade].compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: " / ")
        }
        return snapshot.httpHeadersError ?? "Unavailable"
    }

    private static func httpsSummary(from snapshot: LookupSnapshot) -> String {
        if snapshot.sslInfo != nil {
            return "Valid"
        }
        if let sslError = snapshot.sslError {
            return sslError.localizedCaseInsensitiveContains("certificate") ? "Invalid" : "Failed"
        }
        return "Unavailable"
    }

    private static func httpsSummaryTone(from snapshot: LookupSnapshot) -> ResultTone {
        if snapshot.sslInfo != nil {
            return .success
        }
        return snapshot.sslError == nil ? .secondary : .failure
    }

    private static func emailSummary(from snapshot: LookupSnapshot) -> String {
        guard let emailSecurity = snapshot.emailSecurity else {
            return snapshot.emailSecurityError ?? "Unavailable"
        }
        return "SPF \(emailSecurity.spf.found ? "Yes" : "No") / DMARC \(emailSecurity.dmarc.found ? "Yes" : "No")"
    }

    private static func certificateStatusLabel(from snapshot: LookupSnapshot) -> String {
        guard let sslInfo = snapshot.sslInfo else {
            return snapshot.sslError ?? "Unavailable"
        }

        switch DomainDiffService.certificateWarningLevel(for: snapshot) {
        case .critical:
            return "Critical (\(sslInfo.daysUntilExpiry)d)"
        case .warning:
            return "Warning (\(sslInfo.daysUntilExpiry)d)"
        case .none:
            return "Healthy (\(sslInfo.daysUntilExpiry)d)"
        }
    }

    private static func certificateBadgeLabel(from snapshot: LookupSnapshot) -> String? {
        guard snapshot.sslInfo != nil else { return nil }
        return certificateStatusLabel(from: snapshot)
    }

    private static func certificateStatusTone(from snapshot: LookupSnapshot) -> ResultTone {
        guard let daysRemaining = snapshot.sslInfo?.daysUntilExpiry else {
            return snapshot.sslError == nil ? .secondary : .failure
        }
        return certificateTone(daysRemaining: daysRemaining)
    }

    private static func certificateTone(daysRemaining: Int) -> ResultTone {
        if daysRemaining < 14 {
            return .failure
        }
        if daysRemaining < 30 {
            return .warning
        }
        return .success
    }

    private static func availabilityLabel(_ status: DomainAvailabilityStatus?) -> String {
        switch status {
        case .available:
            return "Available"
        case .registered:
            return "Registered"
        case .unknown, .none:
            return "Unknown"
        }
    }

    private static func availabilityInference(from snapshot: LookupSnapshot) -> String {
        switch snapshot.availabilityResult?.status {
        case .registered:
            return "Likely registered"
        case .available:
            return "Possibly available"
        case .unknown, .none:
            return "Unclear"
        }
    }

    private static func availabilityTone(_ status: DomainAvailabilityStatus?) -> ResultTone {
        switch status {
        case .available:
            return .success
        case .registered:
            return .warning
        case .unknown, .none:
            return .secondary
        }
    }

    private static func sourceTone(for snapshot: LookupSnapshot) -> ResultTone {
        if snapshot.statusMessage != nil {
            return .warning
        }

        switch snapshot.resultSource {
        case .live:
            return .success
        case .cached:
            return .secondary
        case .mixed:
            return .warning
        case .snapshot:
            return .warning
        }
    }

    private static func securityGradeTone(_ grade: String) -> ResultTone {
        switch grade {
        case "A", "B":
            return .success
        case "C":
            return .warning
        case "D", "F":
            return .failure
        default:
            return .secondary
        }
    }

    private static func durationLabel(_ durationMs: Int?) -> String {
        durationMs.map { "\($0) ms" } ?? "Unavailable"
    }

    private static let certificateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let ownershipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func refreshDomainPricing(for domain: String, persistAfterFetch: Bool) async {
        domainPricingLoading = true
        let outcome = await ExternalDataService.shared.pricing(domain: domain)

        switch outcome.value {
        case let .success(pricing):
            domainPricing = pricing
            domainPricingError = nil
        case let .empty(message), let .error(message):
            domainPricing = nil
            domainPricingError = conciseExternalMessage(message, fallback: "External pricing unavailable")
        }

        domainPricingLoading = false

        if persistAfterFetch {
            _ = saveHistoryEntry(replaceLatest: true)
        }
    }

    private func refreshReputation(for domain: String, persistAfterFetch: Bool) async {
        reputationLoading = true
        let outcome = await ExternalDataService.shared.reputation(domain: domain)

        switch outcome.value {
        case let .success(result):
            reputation = result
            reputationError = nil
        case let .empty(message), let .error(message):
            reputation = nil
            reputationError = conciseExternalMessage(message, fallback: "Reputation check unavailable")
        }

        reputationLoading = false

        if persistAfterFetch {
            _ = saveHistoryEntry(replaceLatest: true)
        }
    }

    private func conciseExternalMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.localizedCaseInsensitiveContains("rate") {
            return "Rate limited. Try again later."
        }
        if trimmed.localizedCaseInsensitiveContains("invalid") {
            return "External data was invalid."
        }
        if trimmed.localizedCaseInsensitiveContains("network") {
            return "External data is offline."
        }
        return trimmed
    }

    private static func defaultUsageCredits() -> [UsageCreditFeature: UsageCreditStatus] {
        Dictionary(uniqueKeysWithValues: UsageCreditFeature.allCases.map { feature in
            (feature, fallbackCreditStatus(for: feature))
        })
    }

    private static func fallbackCreditStatus(for feature: UsageCreditFeature) -> UsageCreditStatus {
        UsageCreditStatus(
            feature: feature,
            remaining: feature.defaultAllowance,
            total: feature.defaultAllowance,
            resetContext: "Resets with app version \(AppVersion.current)"
        )
    }

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func isInterestingSubdomain(_ hostname: String) -> Bool {
        let keywords = ["admin", "api", "dev", "staging", "test", "internal"]
        let labels = hostname.lowercased().split(separator: ".").map(String.init)
        return labels.contains { label in
            keywords.contains(where: { label.contains($0) })
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element == String {
    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}

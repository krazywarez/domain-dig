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

@MainActor
@Observable
final class DomainViewModel {
    var domain: String = ""
    var bulkInput: String = ""
    var domainInputError: String?

    // MARK: Section state

    /// Each section's value, phase and error as one stored property, so the
    /// three are written together or not at all. There were 20 `*Loading`
    /// flags and 19 `*Error` strings before, independently assignable (A2).
    ///
    /// The accessors below keep the names every reader already uses. They are
    /// a staging layer: the next step is views reading the state directly, as
    /// the Web and Network slices already do.
    var dnsState = SectionState<[DNSSection]>()
    var availabilityState = SectionState<DomainAvailabilityResult>()
    var suggestionsState = SectionState<[DomainSuggestionResult]>()
    var sslState = SectionState<SSLCertificateInfo>()
    var hstsState = SectionState<Bool>()
    var httpHeadersState = SectionState<[HTTPHeader]>()
    var reachabilityState = SectionState<[PortReachability]>()
    var ipGeolocationState = SectionState<IPGeolocation>()
    var emailSecurityState = SectionState<EmailSecurityResult>()
    var ownershipState = SectionState<DomainOwnership>()
    var ownershipHistoryState = SectionState<[DomainOwnershipHistoryEvent]>()
    var ptrState = SectionState<String>()
    var redirectChainState = SectionState<[RedirectHop]>()
    var subdomainsState = SectionState<[DiscoveredSubdomain]>()
    var extendedSubdomainsState = SectionState<[DiscoveredSubdomain]>()
    var dnsHistoryState = SectionState<[DNSHistoryEvent]>()
    var domainPricingState = SectionState<DomainPricingInsight>()
    var reputationState = SectionState<DomainReputationResult>()
    var portScanState = SectionState<[PortScanResult]>()
    var customPortScanState = SectionState<[PortScanResult]>()

    var dnsSections: [DNSSection] { dnsState.items }
    var dnsLoading: Bool { dnsState.isLoading }
    var dnsError: String? { dnsState.error }

    var availabilityResult: DomainAvailabilityResult? { availabilityState.value }
    var availabilityLoading: Bool { availabilityState.isLoading }

    var suggestions: [DomainSuggestionResult] { suggestionsState.items }
    var suggestionsLoading: Bool { suggestionsState.isLoading }

    var sslInfo: SSLCertificateInfo? { sslState.value }
    var sslLoading: Bool { sslState.isLoading }
    var sslError: String? { sslState.error }

    var hstsPreloaded: Bool? { hstsState.value }
    var hstsLoading: Bool { hstsState.isLoading }

    var httpHeaders: [HTTPHeader] { httpHeadersState.items }
    var httpHeadersLoading: Bool { httpHeadersState.isLoading }
    var httpHeadersError: String? { httpHeadersState.error }

    var reachabilityResults: [PortReachability] { reachabilityState.items }
    var reachabilityLoading: Bool { reachabilityState.isLoading }
    var reachabilityError: String? { reachabilityState.error }

    var ipGeolocation: IPGeolocation? { ipGeolocationState.value }
    var ipGeolocationLoading: Bool { ipGeolocationState.isLoading }
    var ipGeolocationError: String? { ipGeolocationState.error }

    var emailSecurity: EmailSecurityResult? { emailSecurityState.value }
    var emailSecurityLoading: Bool { emailSecurityState.isLoading }
    var emailSecurityError: String? { emailSecurityState.error }

    var ownershipResult: DomainOwnership? { ownershipState.value }
    var ownershipLoading: Bool { ownershipState.isLoading }
    var ownershipError: String? { ownershipState.error }

    var ownershipHistory: [DomainOwnershipHistoryEvent] { ownershipHistoryState.items }
    var ownershipHistoryLoading: Bool { ownershipHistoryState.isLoading }
    var ownershipHistoryError: String? { ownershipHistoryState.error }

    var ptrRecord: String? { ptrState.value }
    var ptrLoading: Bool { ptrState.isLoading }
    var ptrError: String? { ptrState.error }

    var redirectChain: [RedirectHop] { redirectChainState.items }
    var redirectChainLoading: Bool { redirectChainState.isLoading }
    var redirectChainError: String? { redirectChainState.error }

    var subdomains: [DiscoveredSubdomain] { subdomainsState.items }
    var subdomainsLoading: Bool { subdomainsState.isLoading }
    var subdomainsError: String? { subdomainsState.error }

    var extendedSubdomains: [DiscoveredSubdomain] { extendedSubdomainsState.items }
    var extendedSubdomainsLoading: Bool { extendedSubdomainsState.isLoading }
    var extendedSubdomainsError: String? { extendedSubdomainsState.error }

    var dnsHistory: [DNSHistoryEvent] { dnsHistoryState.items }
    var dnsHistoryLoading: Bool { dnsHistoryState.isLoading }
    var dnsHistoryError: String? { dnsHistoryState.error }

    var domainPricing: DomainPricingInsight? { domainPricingState.value }
    var domainPricingLoading: Bool { domainPricingState.isLoading }
    var domainPricingError: String? { domainPricingState.error }

    var reputation: DomainReputationResult? { reputationState.value }
    var reputationLoading: Bool { reputationState.isLoading }
    var reputationError: String? { reputationState.error }

    var portScanResults: [PortScanResult] { portScanState.items }
    var portScanLoading: Bool { portScanState.isLoading }
    var portScanError: String? { portScanState.error }

    var customPortResults: [PortScanResult] { customPortScanState.items }
    var customPortScanLoading: Bool { customPortScanState.isLoading }
    var customPortScanError: String? { customPortScanState.error }

    var httpSecurityGrade: String?
    var httpStatusCode: Int?
    var httpResponseTimeMs: Int?
    var httpProtocol: String?
    var http3Advertised = false

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
    private(set) var currentResultSource: LookupResultSource = .live
    private(set) var currentCachedSections: [LookupSectionKind] = []
    private(set) var currentStatusMessage: String?
    private(set) var currentSnapshotTimestamp = Date()
    private(set) var currentHistoryEntryID: UUID?
    /// The metadata the current lookup produced, in preference to whatever the
    /// saved entry holds. Nil outside a lookup, when the saved entry is the
    /// only source there is.
    private(set) var currentInspectionMetadata: InspectionMetadata?
    private(set) var currentReport: DomainReport?

    private static let recentSearchesKey = "recentSearches"
    private static let maxRecent = 20
    var recentSearches: [String]


    private static let trackedDomainsKey = "trackedDomains"
    private static let legacyWatchedDomainsKey = "watchedDomains"
    var trackedDomains: [TrackedDomain]

    private static let historyKey = "lookupHistory"
    var history: [HistoryEntry]
    var auditSessions: [AuditSession]
    private static let workflowsKey = "domainWorkflows"
    var workflows: [DomainWorkflow]
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
    var watchlistSavedViews: [WatchlistSavedView]
    var dashboardSearchText = ""
    var dashboardFilter: PortfolioFilterOption = .all
    var monitoringSettings: MonitoringSettings
    var monitoringLogs: [MonitoringLog]
    var monitoringRunInProgress = false
    var monitoringStatusMessage: String?
    var monitoringNotificationStatus: UNAuthorizationStatus = .notDetermined
    var dataLifecycleSummary: DataLifecycleSummary
    var portabilityStatusMessage: String?
    var upgradePrompt: UpgradePromptContext?
    var isPaywallPresented = false
    var selectedSnapshotIDs = Set<UUID>()
    var activeDomainDiff: DomainDiff?
    var activeDiffChangeIndex = 0

    private static let historyAutoPruneKey = "historyAutoPrune"
    var historyAutoPruneOption: HistoryAutoPruneOption

    /// The store every persisted property is read from and written back to.
    /// Injected so a test can drive the whole lifecycle — history pruning,
    /// tracking limits, batch state — against a scratch store instead of the
    /// one the app is using.
    let defaults: UserDefaults

    /// History lives in files rather than in `defaults`, so the directory is
    /// injected alongside the store it used to be part of.
    let historyLocation: HistoryFileStore.Location

    init(
        defaults: UserDefaults = .standard,
        historyLocation: HistoryFileStore.Location = .default
    ) {
        self.defaults = defaults
        self.historyLocation = historyLocation
        recentSearches = DomainDataPortabilityService.loadRecentSearches(defaults: defaults)
        trackedDomains = DomainViewModel.loadTrackedDomains(defaults: defaults, historyLocation: historyLocation)
        history = DomainViewModel.loadHistoryEntries(defaults: defaults, historyLocation: historyLocation)
        auditSessions = DomainDataPortabilityService.loadAuditSessions(defaults: defaults)
        workflows = DomainViewModel.loadWorkflows(defaults: defaults, historyLocation: historyLocation)
        watchlistSavedViews = DomainViewModel.loadWatchlistSavedViews(defaults: defaults)
        monitoringSettings = MonitoringStorage.loadSettings(defaults: defaults)
        monitoringLogs = MonitoringStorage.loadLogs(defaults: defaults)
        dataLifecycleSummary = DomainDataPortabilityService.lifecycleSummary(defaults: defaults, historyLocation: historyLocation)
        historyAutoPruneOption = DomainViewModel.loadHistoryAutoPruneOption(defaults: defaults)
    }

    var trimmedDomain: String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first ?? ""
    }

    var resultsLoaded: Bool {
        guard hasRun else { return false }
        return [
            dnsState.isSettled,
            availabilityState.isSettled,
            suggestionsState.isSettled,
            sslState.isSettled,
            hstsState.isSettled,
            httpHeadersState.isSettled,
            reachabilityState.isSettled,
            ipGeolocationState.isSettled,
            emailSecurityState.isSettled,
            ownershipState.isSettled,
            ptrState.isSettled,
            redirectChainState.isSettled,
            subdomainsState.isSettled,
            portScanState.isSettled,
            !customPortScanState.isLoading
        ].allSatisfy { $0 }
    }

    /// A single lookup is in flight. `hasRun` is set when one starts and the
    /// sections settle as they land, so this is the window in which cancelling
    /// means something — the counterpart to `batchLookupRunning`.
    var singleLookupRunning: Bool {
        hasRun && !resultsLoaded
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

    /// Builds the dashboard. Uncached, deliberately: the cache this replaces
    /// was keyed on a signature of every tracked domain, the last 250 history
    /// rows and the last 100 monitoring logs, built with
    /// `.formatted(.number.precision(.fractionLength(3)))` — roughly 350
    /// interpolations per access, and the dashboard reads this more than twenty
    /// times per render, so checking the cache cost far more than the build it
    /// was avoiding (A4).
    ///
    /// Callers that need it more than once should read it once and filter with
    /// `filtered(by:searchText:)`, which is what `DashboardView` does.
    var portfolioDashboardData: PortfolioDashboardData {
        let domainStates = buildPortfolioDomainStates()
        let recentActivity = buildPortfolioActivity(from: domainStates)
        let attentionRequired = buildAttentionQueue(from: domainStates)
        let expiringSoon = domainStates
            .filter { $0.certificateExpiryState != .none }
            .sorted {
                ($0.certificateDaysRemaining ?? .max, $0.trackedDomain.domain)
                    < ($1.certificateDaysRemaining ?? .max, $1.trackedDomain.domain)
            }
        let groups = PortfolioDashboardData.groups(from: domainStates)
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
        return PortfolioDashboardData(
            snapshot: snapshot,
            domainStates: domainStates,
            recentActivity: recentActivity,
            attentionRequired: attentionRequired,
            expiringSoon: expiringSoon,
            groups: groups
        )
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
            dataSources: currentInspectionMetadata?.dataSources ?? currentHistoryEntry?.dataSources ?? [],
            provenanceBySection: currentInspectionMetadata?.provenanceBySection ?? currentHistoryEntry?.provenanceBySection ?? [:],
            availabilityConfidence: currentInspectionMetadata?.availabilityConfidence ?? currentHistoryEntry?.availabilityConfidence,
            ownershipConfidence: currentInspectionMetadata?.ownershipConfidence ?? currentHistoryEntry?.ownershipConfidence,
            subdomainConfidence: currentInspectionMetadata?.subdomainConfidence ?? currentHistoryEntry?.subdomainConfidence,
            emailSecurityConfidence: currentInspectionMetadata?.emailSecurityConfidence ?? currentHistoryEntry?.emailSecurityConfidence,
            geolocationConfidence: currentInspectionMetadata?.geolocationConfidence ?? currentHistoryEntry?.geolocationConfidence,
            errorDetails: currentInspectionMetadata?.errorDetails ?? currentHistoryEntry?.errorDetails ?? [:],
            isPartialSnapshot: currentInspectionMetadata?.isPartialSnapshot ?? currentHistoryEntry?.isPartialSnapshot ?? false,
            validationIssues: currentInspectionMetadata?.validationIssues ?? currentHistoryEntry?.validationIssues ?? [],
            totalLookupDurationMs: lastLookupDurationMs,
            snapshotIndex: currentInspectionMetadata?.snapshotIndex ?? currentHistoryEntry?.snapshotIndex,
            previousSnapshotID: currentInspectionMetadata?.previousSnapshotID ?? currentHistoryEntry?.previousSnapshotID,
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

    /// The same two slices built from a stored snapshot, for the history
    /// detail view. Nothing is in flight there, so every panel is settled.
    static func webSectionData(from snapshot: LookupSnapshot, report: DomainReport) -> WebSectionViewData {
        WebSectionViewData(
            tls: SectionPanelViewData(
                error: snapshot.sslError,
                provenance: snapshot.provenanceBySection[.ssl]
            ),
            certificateRows: webCertificateRows(from: snapshot),
            sslInfo: snapshot.sslInfo,
            tlsSummary: report.web,
            http: SectionPanelViewData(
                error: snapshot.httpHeadersError,
                provenance: snapshot.provenanceBySection[.httpHeaders]
            ),
            responseRows: webResponseRows(from: snapshot),
            headers: snapshot.httpHeaders,
            redirect: SectionPanelViewData(
                error: snapshot.redirectChainError,
                provenance: snapshot.provenanceBySection[.redirectChain]
            ),
            redirectRows: redirectRows(from: snapshot),
            finalURL: snapshot.redirectChain.last?.url
        )
    }

    static func networkSectionData(from snapshot: LookupSnapshot) -> NetworkSectionViewData {
        NetworkSectionViewData(
            reachability: SectionPanelViewData(
                error: snapshot.reachabilityError,
                provenance: snapshot.provenanceBySection[.reachability]
            ),
            reachabilityRows: reachabilityRows(from: snapshot),
            location: SectionPanelViewData(
                error: snapshot.ipGeolocationError,
                provenance: snapshot.provenanceBySection[.ipGeolocation],
                confidence: snapshot.geolocationConfidence
            ),
            locationRows: locationRows(from: snapshot),
            geolocation: snapshot.ipGeolocation,
            portScan: SectionPanelViewData(
                error: snapshot.portScanError,
                provenance: snapshot.provenanceBySection[.portScan]
            ),
            standardPortRows: portRows(from: snapshot, kind: .standard),
            customPortRows: portRows(from: snapshot, kind: .custom),
            isCloudflareProxied: snapshot.httpHeaders.contains { $0.name.lowercased() == "cf-ray" }
        )
    }

    /// Everything the Web section draws, assembled in one place. The call
    /// site used to name seventeen arguments and had to keep their order
    /// straight; this groups them by the card they belong to (A10).
    var webSectionData: WebSectionViewData {
        WebSectionViewData(
            tls: SectionPanelViewData(
                isLoading: sslLoading || hstsLoading,
                error: sslError,
                provenance: currentSnapshot.provenanceBySection[.ssl]
            ),
            certificateRows: webCertificateRows,
            sslInfo: sslInfo,
            tlsSummary: currentTLSSummary,
            http: SectionPanelViewData(
                isLoading: httpHeadersLoading,
                error: httpHeadersError,
                provenance: currentSnapshot.provenanceBySection[.httpHeaders]
            ),
            responseRows: webResponseRows,
            headers: httpHeaders,
            redirect: SectionPanelViewData(
                isLoading: redirectChainLoading,
                error: redirectChainError,
                provenance: currentSnapshot.provenanceBySection[.redirectChain]
            ),
            redirectRows: redirectRows,
            finalURL: currentSnapshot.redirectChain.last?.url
        )
    }

    /// Everything the Network section draws. Twenty-two arguments before.
    var networkSectionData: NetworkSectionViewData {
        NetworkSectionViewData(
            reachability: SectionPanelViewData(
                isLoading: reachabilityLoading,
                error: reachabilityError,
                provenance: currentSnapshot.provenanceBySection[.reachability]
            ),
            reachabilityRows: reachabilityRows,
            location: SectionPanelViewData(
                isLoading: ipGeolocationLoading,
                error: ipGeolocationError,
                provenance: currentSnapshot.provenanceBySection[.ipGeolocation],
                confidence: currentSnapshot.geolocationConfidence
            ),
            locationRows: locationRows,
            geolocation: ipGeolocation,
            portScan: SectionPanelViewData(
                isLoading: portScanLoading,
                error: portScanError,
                provenance: currentSnapshot.provenanceBySection[.portScan]
            ),
            standardPortRows: standardPortRows,
            customPortRows: customPortRows,
            customPortScan: SectionPanelViewData(
                isLoading: customPortScanLoading,
                error: customPortScanError
            ),
            isCloudflareProxied: isCloudflareProxied
        )
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

        guard FeatureAccessService.canAddTrackedDomain(currentCount: trackedDomains.count) else {
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
        var relinked: [HistoryEntry] = []
        history.indices.forEach { index in
            if let trackedDomainID = history[index].trackedDomainID, ids.contains(trackedDomainID) {
                history[index].trackedDomainID = nil
                relinked.append(history[index])
            }
        }
        persistTrackedDomains()
        relinked.forEach { updateStoredHistory($0) }
        sanitizeMonitoringSelection()
    }

    func deleteTrackedDomain(_ trackedDomain: TrackedDomain) {
        guard canDelete(trackedDomain) else { return }
        CloudSyncService.shared.recordTrackedDomainDeletion(trackedDomain)
        trackedDomains.removeAll { $0.id == trackedDomain.id }
        var relinked: [HistoryEntry] = []
        history.indices.forEach { index in
            if history[index].trackedDomainID == trackedDomain.id {
                history[index].trackedDomainID = nil
                relinked.append(history[index])
            }
        }
        persistTrackedDomains()
        relinked.forEach { updateStoredHistory($0) }
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

    private static func loadWatchlistSavedViews(defaults: UserDefaults) -> [WatchlistSavedView] {
        guard let data = defaults.data(forKey: watchlistSavedViewsKey),
              let views = try? JSONDecoder().decode([WatchlistSavedView].self, from: data)
        else { return [] }
        return views
    }

    private func persistWatchlistSavedViews() {
        guard let data = try? JSONEncoder().encode(watchlistSavedViews) else { return }
        defaults.set(data, forKey: Self.watchlistSavedViewsKey)
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
        let removed = Set(offsets.map { history[$0].id })
        history.remove(atOffsets: offsets)
        removeStoredHistory(ids: removed)
    }

    func removeHistoryEntries(withIDs ids: [UUID]) {
        history.removeAll { ids.contains($0.id) }
        removeStoredHistory(ids: Set(ids))
    }

    func clearHistory() {
        history.removeAll()
        DomainDataPortabilityService.removeAllHistoryEntries(
            defaults: defaults,
            historyLocation: historyLocation
        )
        refreshDataLifecycleSummary()
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
        DomainDataPortabilityService.saveRecentSearches([], defaults: defaults)
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    func refreshMonitoringState() {
        #if DEBUG
        // Runs right after fixture seeding in the app task (and again on every
        // scene activation); the disk reload below would wipe the fixtures.
        if auditFixturesActive { return }
        #endif
        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        trackedDomains = Self.loadTrackedDomains(defaults: defaults, historyLocation: historyLocation)
        history = Self.loadHistoryEntries(defaults: defaults, historyLocation: historyLocation)
        monitoringSettings = MonitoringStorage.sanitizeSettings(
            MonitoringStorage.loadSettings(defaults: defaults),
            trackedDomains: trackedDomains
        )
        monitoringLogs = MonitoringStorage.loadLogs(defaults: defaults)
        persistMonitoringSettings()
        refreshDataLifecycleSummary()
    }

    func refreshDataLifecycleSummary() {
        dataLifecycleSummary = DomainDataPortabilityService.lifecycleSummary(defaults: defaults, historyLocation: historyLocation)
    }

    func refreshPersistedData() {
        #if DEBUG
        // A reload from disk would silently replace the in-memory fixtures.
        if auditFixturesActive { return }
        #endif
        recentSearches = DomainDataPortabilityService.loadRecentSearches(defaults: defaults)
        trackedDomains = Self.loadTrackedDomains(defaults: defaults, historyLocation: historyLocation)
        history = Self.loadHistoryEntries(defaults: defaults, historyLocation: historyLocation)
        auditSessions = DomainDataPortabilityService.loadAuditSessions(defaults: defaults)
        workflows = Self.loadWorkflows(defaults: defaults, historyLocation: historyLocation)
        monitoringSettings = MonitoringStorage.sanitizeSettings(
            MonitoringStorage.loadSettings(defaults: defaults),
            trackedDomains: trackedDomains
        )
        monitoringLogs = MonitoringStorage.loadLogs(defaults: defaults)
        refreshDataLifecycleSummary()
    }

    func applyLocalDataReset() async {
        domain = ""
        bulkInput = ""
        reset()

        recentSearches = []
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
        historyAutoPruneOption = Self.loadHistoryAutoPruneOption(defaults: defaults)
        refreshDataLifecycleSummary()
        await refreshMonitoringAuthorizationStatus()
    }

    func rerunLookup(from entry: HistoryEntry, useSnapshotResolver: Bool) {
        if useSnapshotResolver {
            defaults.set(entry.resolverURLString, forKey: DNSResolverOption.userDefaultsKey)
        }
        domain = entry.domain
        run()
        rerunNavigationToken = UUID()
    }

    func rerunInspection(for trackedDomain: TrackedDomain, useSnapshotResolver: Bool) {
        if useSnapshotResolver, let snapshot = latestSnapshot(for: trackedDomain) {
            defaults.set(snapshot.resolverURLString, forKey: DNSResolverOption.userDefaultsKey)
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
        let target: String
        switch DomainName.validate(trimmedDomain) {
        case .success(let host):
            target = host
            domainInputError = nil
        case .failure(let error):
            domainInputError = error.localizedDescription
            return
        }

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
            customPortScanState = .settled(value: [], error: "Run a domain lookup first")
            return
        }

        guard !ports.isEmpty else {
            customPortScanState = .settled(value: [], error: "Enter at least one valid port")
            return
        }

        customPortScanTask?.cancel()
        let domain = searchedDomain
        let lookupID = activeLookupID

        customPortScanState = .loading

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

        // Free keeps one audit open at a time so the feature stays discoverable;
        // finishing one frees the slot. Existing sessions are never closed off.
        if let limit = FeatureAccessService.entitlements.activeAuditSessionLimit,
           auditSessions.filter({ $0.status != .complete }).count >= limit {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .auditDepth)
            return nil
        }

        let previous = historyEntries(for: normalizedDomain).first?.snapshot
        let snapshot = await inspectionService.inspectSnapshot(
            domain: normalizedDomain,
            previousSnapshot: previous,
            scope: InspectionScope.current(defaults: defaults)
        )
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
        await loadLookup(into: \.ownershipHistoryState, fallback: "Ownership history unavailable") {
            await ExternalDataService.shared.ownershipHistory(
                domain: searchedDomain,
                currentOwnership: ownershipResult,
                historyEntries: history
            ).value
        }
    }

    func loadDNSHistory() async {
        await loadLookup(into: \.dnsHistoryState, fallback: "DNS history unavailable") {
            await ExternalDataService.shared.dnsHistory(
                domain: searchedDomain,
                dnsSections: dnsSections,
                historyEntries: history
            ).value
        }
    }

    func loadExtendedSubdomains() async {
        await loadLookup(
            .extendedSubdomains,
            into: \.extendedSubdomainsState,
            fallback: "Extended subdomains unavailable"
        ) {
            await ExternalDataService.shared.extendedSubdomains(
                domain: searchedDomain,
                existing: subdomains
            ).value
        }
    }

    /// Loads a lookup for the searched domain into `items`, unless it is loaded
    /// already. With a `capability`, shows the upgrade prompt when the plan
    /// doesn't include it; without one the lookup is open to every tier.
    private func loadLookup<Item>(
        _ capability: FeatureCapability? = nil,
        into state: ReferenceWritableKeyPath<DomainViewModel, SectionState<[Item]>>,
        fallback: String,
        fetch: () async -> ServiceResult<[Item]>
    ) async {
        guard !searchedDomain.isEmpty else { return }
        if let capability, !FeatureAccessService.hasAccess(to: capability) {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: capability)
            return
        }
        guard self[keyPath: state].items.isEmpty else { return }

        self[keyPath: state] = .loading
        let (items, message) = found(await fetch(), fallback: fallback)
        self[keyPath: state] = .settled(value: items, error: message)
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

    private func performLookup(domain: String, lookupID: UUID) async -> HistoryEntry? {
        let lookupStartedAt = DomainDebugLog.signpostStart("DomainViewModel.performLookup", domain: domain)
        let previous = previousSnapshot(
            for: domain,
            trackedDomainID: currentTrackedDomain?.id,
            replacingLatest: false
        )
        let inspectedSnapshot = await inspectionService.inspectSnapshot(
            domain: domain,
            previousSnapshot: previous,
            scope: InspectionScope.current(defaults: defaults)
        )
        DomainDebugLog.debug("DomainViewModel.performLookup inspectionReturned domain=\(domain)")
        guard !Task.isCancelled, isCurrentLookup(lookupID) else { return nil }

        let snapshot = inspectedSnapshot.resolvedAfterFallback(to: previous)
        let applyStartedAt = DomainDebugLog.signpostStart("DomainViewModel.applySnapshot", domain: domain)
        applySnapshot(snapshot)
        DomainDebugLog.signpostEnd("DomainViewModel.applySnapshot", start: applyStartedAt, domain: domain)
        lastLookupDurationMs = snapshot.totalLookupDurationMs
        refreshingTrackedDomainID = nil

        guard snapshot.statusMessage == nil else {
            return history.first(where: { $0.id == snapshot.historyEntryID })
        }

        let saveStartedAt = DomainDebugLog.signpostStart("DomainViewModel.saveHistoryEntry", domain: domain)
        let entry = saveHistoryEntry(replaceLatest: false, reuseCurrentAnalysis: true)
        DomainDebugLog.signpostEnd("DomainViewModel.saveHistoryEntry", start: saveStartedAt, domain: domain)
        // Opt-in, and off by default: this fires on every Run, so a target
        // that enabled it ships an object per tap.
        IntegrationService.shared.enqueueExports(domains: [domain], trigger: .interactiveRun)
        DomainDebugLog.signpostEnd("DomainViewModel.performLookup", start: lookupStartedAt, domain: domain)
        return entry
    }

    /// The single place section state is written from an inspection result.
    /// Internal so the tests that pin what each section ends up showing can
    /// reach it without a live lookup.
    func applySnapshot(_ snapshot: LookupSnapshot) {
        currentInspectionMetadata = InspectionMetadata(snapshot: snapshot)
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

        dnsState = .settled(value: snapshot.dnsSections, error: snapshot.dnsError)
        availabilityState = .settled(value: snapshot.availabilityResult)
        suggestionsState = .settled(value: snapshot.suggestions)
        sslState = .settled(value: snapshot.sslInfo, error: snapshot.sslError)
        hstsState = .settled(value: snapshot.hstsPreloaded)
        httpHeadersState = .settled(value: snapshot.httpHeaders, error: snapshot.httpHeadersError)
        httpSecurityGrade = snapshot.httpSecurityGrade
        httpStatusCode = snapshot.httpStatusCode
        httpResponseTimeMs = snapshot.httpResponseTimeMs
        httpProtocol = snapshot.httpProtocol
        http3Advertised = snapshot.http3Advertised
        reachabilityState = .settled(value: snapshot.reachabilityResults, error: snapshot.reachabilityError)
        ipGeolocationState = .settled(value: snapshot.ipGeolocation, error: snapshot.ipGeolocationError)
        emailSecurityState = .settled(value: snapshot.emailSecurity, error: snapshot.emailSecurityError)
        ownershipState = .settled(value: snapshot.ownership, error: snapshot.ownershipError)
        ownershipHistoryState = .settled(value: snapshot.ownershipHistory, error: snapshot.ownershipHistoryError)
        ptrState = .settled(value: snapshot.ptrRecord, error: snapshot.ptrError)
        redirectChainState = .settled(value: snapshot.redirectChain, error: snapshot.redirectChainError)
        subdomainsState = .settled(value: snapshot.subdomains, error: snapshot.subdomainsError)
        extendedSubdomainsState = .settled(value: snapshot.extendedSubdomains, error: snapshot.extendedSubdomainsError)
        dnsHistoryState = .settled(value: snapshot.dnsHistory, error: snapshot.dnsHistoryError)
        domainPricingState = .settled(value: snapshot.domainPricing, error: snapshot.domainPricingError)
        reputationState = .settled(value: snapshot.reputation, error: snapshot.reputationError)
        portScanState = .settled(
            value: snapshot.portScanResults.filter { $0.kind == .standard },
            error: snapshot.portScanError
        )
        customPortScanState = .settled(value: snapshot.portScanResults.filter { $0.kind == .custom })
    }

    private func applyCustomPortResult(_ result: ServiceResult<[PortScanResult]>) {
        switch result {
        case let .success(results):
            customPortScanState = .settled(value: results)
            _ = saveHistoryEntry(replaceLatest: true)
        case let .empty(message), let .error(message):
            customPortScanState = .settled(value: [], error: message)
        }
    }

    private static func performBatchLookup(
        domain: String,
        previousSnapshot: LookupSnapshot?,
        scope: InspectionScope
    ) async -> BatchLookupPayload? {
        guard !Task.isCancelled else { return nil }
        let inspectionService = DomainInspectionService()
        let snapshot = await inspectionService.inspectSnapshot(domain: domain, previousSnapshot: previousSnapshot, scope: scope)
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

        // Before the insert: afterwards `history.count` includes this entry
        // and `growthHistoryLimit` would never prune anything.
        let storedLimit = growthHistoryLimit
        let replacedLatest = replaceLatest
            && !history.isEmpty
            && history[0].domain.caseInsensitiveCompare(snapshot.domain) == .orderedSame
        if replacedLatest {
            history[0] = entry
        } else {
            history.insert(entry, at: 0)
            history = Array(history.prefix(storedLimit))
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
        if replacedLatest {
            updateStoredHistory(entry)
        } else {
            appendStoredHistory(entry, cap: storedLimit)
        }
        notifyIfNeeded(for: entry, snapshot: snapshot, previousSnapshot: previousSnapshot)
        return entry
    }

    /// A single snapshot written on its own. `persistHistory` rewrites every
    /// row because it cannot tell what changed; these callers can, and at the
    /// Pro+ cap that is the difference between 23 ms and 656 ms.
    /// Replaces one stored snapshot. No cap: an update changes a row that is
    /// already there and cannot push the store past its limit.
    private func updateStoredHistory(_ entry: HistoryEntry) {
        if historyPersistenceSuspended {
            historyPersistenceDirty = true
            return
        }
        DomainDataPortabilityService.updateHistoryEntry(
            entry,
            defaults: defaults,
            historyLocation: historyLocation
        )
        refreshDataLifecycleSummary()
    }

    /// Stores a new snapshot under `cap`, which the caller reads before its
    /// own insert so the row being added does not raise its own ceiling.
    private func appendStoredHistory(_ entry: HistoryEntry, cap: Int) {
        if historyPersistenceSuspended {
            historyPersistenceDirty = true
            return
        }
        DomainDataPortabilityService.appendHistoryEntry(
            entry,
            cap: cap,
            defaults: defaults,
            historyLocation: historyLocation
        )
        refreshDataLifecycleSummary()
    }

    private func removeStoredHistory(ids: Set<UUID>) {
        if historyPersistenceSuspended {
            historyPersistenceDirty = true
            return
        }
        DomainDataPortabilityService.removeHistoryEntries(
            ids: ids,
            defaults: defaults,
            historyLocation: historyLocation
        )
        refreshDataLifecycleSummary()
    }

    /// Rewrites the whole store. Only the auto-prune setting needs this — it
    /// drops rows from the middle and cannot say which. Every other writer
    /// goes through `appendStoredHistory`, `updateStoredHistory` or
    /// `removeStoredHistory`.
    private func persistHistory() {
        if historyPersistenceSuspended {
            historyPersistenceDirty = true
            return
        }
        let persistStartedAt = DomainDebugLog.signpostStart("DomainViewModel.persistHistory")
        DomainDataPortabilityService.saveHistoryEntries(history, defaults: defaults, historyLocation: historyLocation)
        refreshDataLifecycleSummary()
        DomainDebugLog.signpostEnd("DomainViewModel.persistHistory", start: persistStartedAt, extra: "count=\(history.count)")
    }

    func persistAuditSessions() {
        DomainDataPortabilityService.saveAuditSessions(auditSessions, defaults: defaults)
        refreshDataLifecycleSummary()
    }

    func setHistoryAutoPruneOption(_ option: HistoryAutoPruneOption) {
        historyAutoPruneOption = option
        defaults.set(option.rawValue, forKey: Self.historyAutoPruneKey)
        history = Array(history.prefix(requestedHistoryLimit))
        persistHistory()
    }

    func updateHistoryNote(_ note: String, for entry: HistoryEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updateStoredHistory(history[index])
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
        DomainDataPortabilityService.saveTrackedDomains(trackedDomains, defaults: defaults)
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
            DomainDataPortabilityService.saveTrackedDomains(trackedDomains, defaults: defaults)
            CloudSyncService.shared.scheduleSyncIfNeeded()
        }

        if historyPersistenceDirty {
            historyPersistenceDirty = false
            DomainDataPortabilityService.saveHistoryEntries(history, defaults: defaults, historyLocation: historyLocation)
        }

        refreshDataLifecycleSummary()
    }

    /// What Settings says under the auto-prune picker. The old copy claimed
    /// auto-prune "defaults to unlimited", which was never true — there has
    /// always been a hard ceiling, and under D1 it is the tier's.
    var historyRetentionCaption: String {
        let limit = tierHistoryLimit
        let base = "History stays on this device. Your plan keeps up to \(limit) snapshots"
        guard history.count > limit else {
            return base + "; auto-prune trims to fewer if you want."
        }
        return base
            + ", and you have \(history.count). Nothing already saved is removed —"
            + " new snapshots replace the oldest instead."
    }

    /// Snapshots this tier keeps: 50 free, 250 Pro, 2000 Pro+ under D1.
    private var tierHistoryLimit: Int {
        FeatureAccessService.historyRetentionLimit
    }

    /// The ceiling a newly stored snapshot is kept under, computed before the
    /// insert. Never below what is already held: a lapsed Pro+ subscriber with
    /// 2000 snapshots keeps all 2000 (Review Focus #6), and the store holds
    /// there rather than draining to the lower tier a row at a time. For
    /// anyone at or under their tier's limit this is just that limit.
    var growthHistoryLimit: Int {
        max(tierHistoryLimit, history.count)
    }

    /// What the user's own auto-prune choice asks for, which may be less than
    /// the tier allows but never more. This one is permitted to delete,
    /// because the user chose it.
    var requestedHistoryLimit: Int {
        min(historyAutoPruneOption.keepCount ?? tierHistoryLimit, tierHistoryLimit)
    }

    /// Caps growth without pruning what is already stored.
    private func trimHistoryToLimit() {
        history = Array(history.prefix(growthHistoryLimit))
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
        MonitoringStorage.saveSettings(monitoringSettings, defaults: defaults)
        CloudSyncService.shared.markMonitoringSettingsChanged(localActivationConfirmed: localActivationConfirmed)
    }

    func sanitizeMonitoringSelection() {
        monitoringSettings = MonitoringStorage.sanitizeSettings(monitoringSettings, trackedDomains: trackedDomains)
        MonitoringStorage.saveSettings(monitoringSettings, defaults: defaults)
        CloudSyncService.shared.markMonitoringSettingsChanged(localActivationConfirmed: false)
    }

    private func clearMonitoringLogs() {
        monitoringLogs.removeAll()
        monitoringStatusMessage = nil
        MonitoringStorage.saveLogs([], defaults: defaults)
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

        var relinked: [HistoryEntry] = []
        for index in history.indices where history[index].domain.caseInsensitiveCompare(domain) == .orderedSame {
            if history[index].trackedDomainID != trackedDomain.id {
                history[index].trackedDomainID = trackedDomain.id
                relinked.append(history[index])
            }
        }

        relinked.forEach { updateStoredHistory($0) }

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

    func addRecentSearch(_ domain: String) {
        recentSearches.removeAll { $0.lowercased() == domain.lowercased() }
        recentSearches.insert(domain, at: 0)
        if recentSearches.count > Self.maxRecent {
            recentSearches = Array(recentSearches.prefix(Self.maxRecent))
        }
        DomainDataPortabilityService.saveRecentSearches(recentSearches, defaults: defaults)
        CloudSyncService.shared.markAppSettingsChanged()
        refreshDataLifecycleSummary()
    }

    func beginLookup(for target: String, cancelExistingTask: Bool = true) -> UUID {
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
        currentInspectionMetadata = nil
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
        let separators = CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)
        var seen = Set<String>()

        return input
            .components(separatedBy: separators)
            .compactMap { try? DomainName.validate($0).get() }
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

        group.addTask { [domain, previousSnapshot, scope = InspectionScope.current(defaults: defaults)] in
            let payload = await Self.performBatchLookup(domain: domain, previousSnapshot: previousSnapshot, scope: scope)
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
        // Only the domains that actually completed: a failed lookup has no
        // report to upload.
        IntegrationService.shared.enqueueExports(
            domains: batchResults.filter { $0.status == .completed }.map(\.domain),
            trigger: .batch
        )
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

    /// Resets every section before a new lookup, so the previous domain's
    /// results cannot be mistaken for this one's. One assignment per section
    /// now; it used to be three.
    private func clearLookupState() {
        currentInspectionMetadata = nil
        dnsState = .idle
        availabilityState = .idle
        suggestionsState = .idle
        sslState = .idle
        hstsState = .idle
        httpHeadersState = .idle
        httpSecurityGrade = nil
        httpStatusCode = nil
        httpResponseTimeMs = nil
        httpProtocol = nil
        http3Advertised = false
        reachabilityState = .idle
        ipGeolocationState = .idle
        emailSecurityState = .idle
        ownershipState = .idle
        ownershipHistoryState = .idle
        ptrState = .idle
        redirectChainState = .idle
        subdomainsState = .idle
        extendedSubdomainsState = .idle
        dnsHistoryState = .idle
        domainPricingState = .idle
        reputationState = .idle
        portScanState = .idle
        customPortScanState = .idle
    }

    /// Puts the sections a lookup drives into flight, and resets the
    /// on-demand ones — ownership history, extended subdomains, DNS history
    /// and pricing are fetched when the user opens them, not by the lookup, so
    /// they were never part of this either.
    private func setAllLoadingStates(_ loading: Bool) {
        let phase: SectionPhase = loading ? .loading : .idle
        dnsState.phase = phase
        availabilityState.phase = phase
        suggestionsState.phase = phase
        sslState.phase = phase
        hstsState.phase = phase
        httpHeadersState.phase = phase
        reachabilityState.phase = phase
        ipGeolocationState.phase = phase
        emailSecurityState.phase = phase
        ownershipState.phase = phase
        ptrState.phase = phase
        redirectChainState.phase = phase
        subdomainsState.phase = phase
        portScanState.phase = phase

        ownershipHistoryState.phase = .idle
        extendedSubdomainsState.phase = .idle
        dnsHistoryState.phase = .idle
        domainPricingState.phase = .idle
    }

    private func primaryIPAddress(from sections: [DNSSection]) -> String? {
        sections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    func isCurrentLookup(_ lookupID: UUID) -> Bool {
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
                return lhs.health.severityRank > rhs.health.severityRank
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

    private static func loadHistoryEntries(
        defaults: UserDefaults,
        historyLocation: HistoryFileStore.Location
    ) -> [HistoryEntry] {
        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        return DomainDataPortabilityService.loadHistoryEntries(
            defaults: defaults,
            historyLocation: historyLocation
        )
    }

    private static func loadHistoryAutoPruneOption(defaults: UserDefaults) -> HistoryAutoPruneOption {
        guard let rawValue = defaults.string(forKey: historyAutoPruneKey),
              let option = HistoryAutoPruneOption(rawValue: rawValue) else {
            return .unlimited
        }
        return option
    }

    private static func loadTrackedDomains(
        defaults: UserDefaults,
        historyLocation: HistoryFileStore.Location
    ) -> [TrackedDomain] {
        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        return DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)
    }

    func persistWorkflows() {
        DomainDataPortabilityService.saveWorkflows(workflows, defaults: defaults)
        CloudSyncService.shared.scheduleSyncIfNeeded()
        refreshDataLifecycleSummary()
    }

    static func loadWorkflows(
        defaults: UserDefaults,
        historyLocation: HistoryFileStore.Location
    ) -> [DomainWorkflow] {
        DataMigrationService.migrateIfNeeded(defaults: defaults, historyLocation: historyLocation)
        return DomainDataPortabilityService.loadWorkflows(defaults: defaults)
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

    static func primaryIPAddress(from snapshot: LookupSnapshot) -> String? {
        snapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    static func finalRedirectTarget(from snapshot: LookupSnapshot) -> String? {
        snapshot.redirectChain.last?.url
    }

    static func httpsSummary(from snapshot: LookupSnapshot) -> String {
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

    static func emailSummary(from snapshot: LookupSnapshot) -> String {
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

    static func availabilityLabel(_ status: DomainAvailabilityStatus?) -> String {
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

    static func durationLabel(_ durationMs: Int?) -> String {
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

    private static func isInterestingSubdomain(_ hostname: String) -> Bool {
        let keywords = ["admin", "api", "dev", "staging", "test", "internal"]
        let labels = hostname.lowercased().split(separator: ".").map(String.init)
        return labels.contains { label in
            keywords.contains(where: { label.contains($0) })
        }
    }
}


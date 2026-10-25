import Foundation

// The portfolio dashboard's value types and the filtering that derives a
// visible subset from them. Split out of DomainViewModel.swift (A13), where
// they sat above the class; the filtering arrived there with A4 and belongs
// with the data rather than with the view model.

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

    /// The same dashboard narrowed to the domains matching the filter and the
    /// search text, with every list kept consistent with that set.
    ///
    /// This used to be five computed properties on the view model, each of
    /// which re-read `portfolioDashboardData` and re-derived the visible set.
    /// A4: the view reads each of them twice, so the dashboard was rebuilt
    /// more than twenty times per render. Filtering is a function of the data
    /// now, so a view can do it once.
    func filtered(by filter: PortfolioFilterOption, searchText: String) -> PortfolioDashboardData {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleStates = domainStates.filter {
            $0.matches(filter) && $0.matches(searchQuery: query)
        }
        let visibleIDs = Set(visibleStates.map(\.trackedDomain.id))

        return PortfolioDashboardData(
            snapshot: snapshot,
            domainStates: visibleStates,
            recentActivity: recentActivity.filter { visibleIDs.contains($0.trackedDomainID) },
            attentionRequired: attentionRequired.filter { visibleIDs.contains($0.trackedDomainID) },
            expiringSoon: expiringSoon.filter { visibleIDs.contains($0.trackedDomain.id) },
            groups: PortfolioDashboardData.groups(from: visibleStates)
        )
    }

    /// Worst health first, then alphabetical, within a group and between them.
    static func groups(from domainStates: [PortfolioDomainStatus]) -> [PortfolioGroup] {
        Dictionary(grouping: domainStates, by: \.apexDomain)
            .map { apexDomain, domains in
                PortfolioGroup(
                    apexDomain: apexDomain,
                    domains: domains.sorted { lhs, rhs in
                        if lhs.health != rhs.health {
                            return lhs.health.severityRank > rhs.health.severityRank
                        }
                        return lhs.trackedDomain.domain
                            .localizedCaseInsensitiveCompare(rhs.trackedDomain.domain) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                if let lhsMostSevere = lhs.domains.map(\.health.severityRank).max(),
                   let rhsMostSevere = rhs.domains.map(\.health.severityRank).max(),
                   lhsMostSevere != rhsMostSevere {
                    return lhsMostSevere > rhsMostSevere
                }
                return lhs.apexDomain.localizedCaseInsensitiveCompare(rhs.apexDomain) == .orderedAscending
            }
    }
}

extension DomainHealth {
    /// Sort order for "worst first" listings. Was a private `healthRank` on the
    /// view model, which is the wrong owner for a property of the health value.
    var severityRank: Int {
        switch self {
        case .healthy: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}

extension PortfolioDomainStatus {
    func matches(_ filter: PortfolioFilterOption) -> Bool {
        switch filter {
        case .all:
            return true
        case .healthy:
            return health == .healthy
        case .warning:
            return health == .warning
        case .critical:
            return health == .critical
        case .changed:
            guard let lastChangeDate else { return false }
            return Date().timeIntervalSince(lastChangeDate) <= 24 * 60 * 60
        case .expiring:
            return certificateExpiryState != .none
        case .unreachable:
            return isUnreachable
        }
    }

    func matches(searchQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let normalized = query.lowercased()
        return trackedDomain.domain.lowercased().contains(normalized)
            || apexDomain.lowercased().contains(normalized)
    }
}

import SwiftUI

struct DashboardView: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Bindable var viewModel: DomainViewModel
    @State private var collapsedGroups = Set<String>()

    private let summaryColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        // Once per body evaluation. Each of these reads used to rebuild the
        // whole dashboard, and there were more than twenty of them (A4).
        let dashboard = viewModel.portfolioDashboardData
        let visible = dashboard.filtered(
            by: viewModel.dashboardFilter,
            searchText: viewModel.dashboardSearchText
        )

        List {
            if viewModel.trackedDomains.isEmpty {
                Section {
                    EmptyStateCardView(
                        title: "No Portfolio Yet",
                        message: "Track domains to get portfolio health, recent changes, expiry visibility, and an attention queue in one place.",
                        suggestion: "Inspect a domain and use the Track action, or add one directly from Tracked Domains in Settings.",
                        systemImage: "square.stack.3d.up.fill",
                        showsCardBackground: false
                    )
                }
                .listRowBackground(Color(.appSurface))
            } else {
                Section {
                    LazyVGrid(columns: summaryColumns, spacing: 10) {
                        summaryCard(title: "Total Domains", value: dashboard.snapshot.totalDomains, filter: .all, tint: Color(.statusInfo))
                        summaryCard(title: "Healthy", value: dashboard.snapshot.healthyCount, filter: .healthy, tint: Color(.statusPositive))
                        summaryCard(title: "Warning", value: dashboard.snapshot.warningCount, filter: .warning, tint: Color(.statusWarning))
                        summaryCard(title: "Critical", value: dashboard.snapshot.criticalCount, filter: .critical, tint: Color(.statusCritical))
                        summaryCard(title: "Changes (24h)", value: dashboard.snapshot.changedLast24h, filter: .changed, tint: Color(.statusWarning))
                        summaryCard(title: "Unreachable", value: dashboard.snapshot.unreachableCount, filter: .unreachable, tint: Color(.statusCritical))
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color(.appSurface))

                Section("Quick Filters") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PortfolioFilterOption.allCases) { filter in
                                Button {
                                    viewModel.dashboardFilter = filter
                                } label: {
                                    let isSelected = viewModel.dashboardFilter == filter
                                    HStack(spacing: 4) {
                                        // Selection is a fill-colour change; under
                                        // Differentiate Without Color add a
                                        // checkmark + border so it does not depend
                                        // on hue alone.
                                        if isSelected, differentiateWithoutColor {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                        }
                                        Text(filter.title)
                                            .font(appDensity.font(.caption, weight: .semibold))
                                    }
                                    .foregroundStyle(isSelected ? Color(.appOnAccent) : Color.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color(.statusInfo) : Color(.appSurfaceElevated))
                                    .overlay(
                                        Capsule().strokeBorder(
                                            Color.primary,
                                            lineWidth: isSelected && differentiateWithoutColor ? 1.5 : 0
                                        )
                                    )
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(viewModel.dashboardFilter == filter ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Color(.appSurface))

                Section("Recent Activity") {
                    if visible.recentActivity.isEmpty {
                        dashboardEmptyRow("No recent portfolio changes")
                    } else {
                        ForEach(visible.recentActivity.prefix(8)) { item in
                            trackedDomainLink(item.trackedDomainID) {
                                PortfolioActivityRow(item: item)
                            }
                        }
                    }
                }
                .listRowBackground(Color(.appSurface))

                Section("Attention Required") {
                    if visible.attentionRequired.isEmpty {
                        dashboardEmptyRow("Nothing urgent right now")
                    } else {
                        ForEach(visible.attentionRequired.prefix(8)) { item in
                            trackedDomainLink(item.trackedDomainID) {
                                PortfolioAttentionRow(item: item)
                            }
                        }
                    }
                }
                .listRowBackground(Color(.appSurface))

                Section("Expiring Soon") {
                    if visible.expiringSoon.isEmpty {
                        dashboardEmptyRow("No certificates expiring within 30 days")
                    } else {
                        ForEach(visible.expiringSoon.prefix(8)) { state in
                            NavigationLink {
                                TrackedDomainDetailView(viewModel: viewModel, trackedDomain: state.trackedDomain)
                            } label: {
                                PortfolioExpiryRow(state: state)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(Color(.appSurface))

                Section("Portfolio List") {
                    if visible.groups.isEmpty {
                        dashboardEmptyRow("No domains match the current filter")
                    } else {
                        ForEach(visible.groups) { group in
                            DisclosureGroup(
                                isExpanded: disclosureBinding(for: group.apexDomain),
                                content: {
                                    ForEach(group.domains) { state in
                                        NavigationLink {
                                            TrackedDomainDetailView(viewModel: viewModel, trackedDomain: state.trackedDomain)
                                        } label: {
                                            WatchlistRowView(
                                                trackedDomain: state.trackedDomain,
                                                isRefreshing: viewModel.refreshingTrackedDomainID == state.trackedDomain.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                },
                                label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.apexDomain)
                                                .font(appDensity.font(.headline, design: .default, weight: .semibold))
                                            Text("\(group.domains.count) domain\(group.domains.count == 1 ? "" : "s")")
                                                .font(appDensity.font(.caption))
                                                .foregroundStyle(Color(.appTextSecondary))
                                        }
                                        Spacer()
                                        groupBadge(for: group.domains)
                                    }
                                    .padding(.vertical, 4)
                                }
                            )
                        }
                    }
                }
                .listRowBackground(Color(.appSurface))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle("Dashboard")
        .searchable(text: $viewModel.dashboardSearchText, prompt: "Search portfolio")
        .toolbar {
            if !viewModel.trackedDomains.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.refresh()
                        viewModel.refreshAllTrackedDomains()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh all tracked domains")
                    .disabled(viewModel.batchLookupRunning)
                }
            }
        }
    }

    private func disclosureBinding(for apexDomain: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(apexDomain) },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(apexDomain)
                } else {
                    collapsedGroups.insert(apexDomain)
                }
            }
        )
    }

    private func summaryCard(title: String, value: Int, filter: PortfolioFilterOption, tint: Color) -> some View {
        Button {
            viewModel.dashboardFilter = filter
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(appDensity.font(.caption, design: .default, weight: .semibold))
                    .foregroundStyle(Color(.appTextSecondary))
                Text("\(value)")
                    // Was a fixed 28pt, which ignored Dynamic Type entirely.
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    // A symbol under Differentiate Without Color (where a bare
                    // colour dot conveys nothing), a plain dot otherwise.
                    if differentiateWithoutColor {
                        Image(systemName: symbol(for: filter))
                            .font(.caption2)
                            .foregroundStyle(tint)
                    } else {
                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                    }
                    Text(filter.title)
                        .font(appDensity.font(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(appDensity.metrics.cardPadding)
            .background(cardBackground(for: filter))
            .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func symbol(for filter: PortfolioFilterOption) -> String {
        switch filter {
        case .all: return "square.grid.2x2.fill"
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .changed: return "arrow.triangle.2.circlepath"
        case .expiring: return "clock.badge.exclamationmark.fill"
        case .unreachable: return "wifi.slash"
        }
    }

    private func cardBackground(for filter: PortfolioFilterOption) -> some ShapeStyle {
        if viewModel.dashboardFilter == filter {
            // Uses the authored info surface rather than a translucent wash of
            // the accent. `statusInfo` at 28% over a light background renders
            // lavender, not blue — an artefact of carrying a dark-only opacity
            // trick into light mode.
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(.statusInfoSurface), Color(.appSurface)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color(.appSurfaceElevated))
    }

    /// `label`, opening the tracked domain's detail; nothing for a domain no longer tracked.
    @ViewBuilder
    private func trackedDomainLink<Label: View>(_ id: UUID, @ViewBuilder label: () -> Label) -> some View {
        if let trackedDomain = viewModel.trackedDomain(withID: id) {
            NavigationLink {
                TrackedDomainDetailView(viewModel: viewModel, trackedDomain: trackedDomain)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        }
    }

    private func dashboardEmptyRow(_ message: String) -> some View {
        Text(message)
            .font(appDensity.font(.caption))
            .foregroundStyle(Color(.appTextSecondary))
            .padding(.vertical, 4)
    }

    private func groupBadge(for states: [PortfolioDomainStatus]) -> some View {
        let criticalCount = states.filter { $0.health == .critical }.count
        let warningCount = states.filter { $0.health == .warning }.count
        let title: String
        let tone: AppStatusTone
        let systemImage: String

        if criticalCount > 0 {
            title = "\(criticalCount) critical"
            tone = .critical
            systemImage = "exclamationmark.octagon.fill"
        } else if warningCount > 0 {
            title = "\(warningCount) warning"
            tone = .warning
            systemImage = "exclamationmark.triangle.fill"
        } else {
            title = "Healthy"
            tone = .positive
            systemImage = "checkmark.circle.fill"
        }

        return AppStatusBadgeView(
            model: .init(
                title: title,
                systemImage: systemImage,
                foregroundColor: tone.foreground,
                backgroundColor: tone.surface
            )
        )
    }
}

private struct PortfolioActivityRow: View {
    @Environment(\.appDensity) private var appDensity
    let item: PortfolioActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background(iconColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.message)
                    .font(appDensity.font(.callout, design: .default))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(item.domain)
                    Text(relativeTimestamp(item.timestamp))
                }
                .font(appDensity.font(.caption2))
                .foregroundStyle(Color(.appTextSecondary))
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch item.health {
        case .healthy:
            return Color(.statusInfo)
        case .warning:
            return Color(.statusWarning)
        case .critical:
            return Color(.statusCritical)
        }
    }
}

private struct PortfolioAttentionRow: View {
    @Environment(\.appDensity) private var appDensity
    let item: PortfolioAttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppStatusBadgeView(model: badgeModel)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.domain)
                    .font(appDensity.font(.callout))
                    .foregroundStyle(.primary)
                Text(item.reason)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))
                Text(relativeTimestamp(item.timestamp))
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeModel: AppStatusBadgeModel {
        switch item.health {
        case .healthy:
            return .init(title: "Healthy", systemImage: "checkmark.circle.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        case .warning:
            return .init(title: "Warning", systemImage: "exclamationmark.triangle.fill", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .critical:
            return .init(title: "Critical", systemImage: "exclamationmark.octagon.fill", foregroundColor: Color(.statusCritical), backgroundColor: Color(.statusCriticalSurface))
        }
    }
}

private struct PortfolioExpiryRow: View {
    @Environment(\.appDensity) private var appDensity
    let state: PortfolioDomainStatus

    var body: some View {
        // Wide while it fits; stacked at accessibility sizes so the badge does
        // not letter-wrap beside a long domain.
        ViewThatFits(in: .horizontal) {
            HStack {
                expiryText
                Spacer()
                AppStatusBadgeView(model: badgeModel)
            }
            VStack(alignment: .leading, spacing: 6) {
                expiryText
                AppStatusBadgeView(model: badgeModel)
            }
        }
        .padding(.vertical, 4)
    }

    private var expiryText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.trackedDomain.domain)
                .font(appDensity.font(.callout))
                .foregroundStyle(.primary)
            Text(expirySubtitle)
                .font(appDensity.font(.caption))
                .foregroundStyle(Color(.appTextSecondary))
        }
    }

    private var expirySubtitle: String {
        if let days = state.certificateDaysRemaining {
            return "Expires in \(days) day\(days == 1 ? "" : "s")"
        }
        return "Certificate needs review"
    }

    private var badgeModel: AppStatusBadgeModel {
        switch state.certificateExpiryState {
        case .none:
            return .init(title: "Healthy", systemImage: "lock.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        case .warning:
            return .init(title: "Warning", systemImage: "exclamationmark.triangle.fill", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .critical:
            return .init(title: "Critical", systemImage: "xmark.octagon.fill", foregroundColor: Color(.statusCritical), backgroundColor: Color(.statusCriticalSurface))
        }
    }
}

private func relativeTimestamp(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

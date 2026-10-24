import SwiftUI

private enum RootTab: Hashable, CaseIterable {
    case dashboard
    case audit
    case history
    case inspect
    case settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .audit: return "Audit"
        case .history: return "History"
        case .inspect: return "Inspect"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .audit: return "checklist"
        case .history: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .inspect: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct RootTabView: View {
    @Bindable var viewModel: DomainViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var purchaseService = PurchaseService.shared
    @State private var intentRouter = DomainDigIntentRouter.shared
    @State private var detailDomain: TrackedDomain?
    @State private var selectedTab: RootTab = FeatureAccessService.currentTier == .free ? .inspect : .dashboard

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                tabLayout
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isPaywallPresented },
            set: { viewModel.isPaywallPresented = $0 }
        )) {
            PaywallView()
        }
        .alert(item: Binding(
            get: { viewModel.upgradePrompt },
            set: { viewModel.upgradePrompt = $0 }
        )) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text("Open Paywall")) {
                    viewModel.upgradePrompt = nil
                    viewModel.isPaywallPresented = true
                },
                secondaryButton: .cancel(Text("Continue")) {
                    viewModel.upgradePrompt = nil
                }
            )
        }
        .sheet(item: $detailDomain) { trackedDomain in
            NavigationStack {
                TrackedDomainDetailView(viewModel: viewModel, trackedDomain: trackedDomain)
            }
        }
        .onChange(of: purchaseService.currentTier) { _, newValue in
            if newValue != .free, selectedTab == .inspect, viewModel.trackedDomains.isEmpty == false {
                selectedTab = .dashboard
            }
        }
        .onOpenURL { url in
            guard let action = DomainDigDeepLink.action(from: url) else { return }
            perform(action)
        }
        .onChange(of: intentRouter.pendingAction) { _, action in
            consume(action)
        }
        .task {
            consume(intentRouter.pendingAction)
        }
    }

    // MARK: Layouts

    /// Compact (iPhone, iPad slide-over): the classic tab bar.
    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                section(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
    }

    /// Regular width (iPad, large iPhone landscape): two-column split view.
    private var splitLayout: some View {
        NavigationSplitView {
            List(RootTab.allCases, id: \.self, selection: sidebarSelection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("DomainDig")
        } detail: {
            section(for: selectedTab)
        }
    }

    private var sidebarSelection: Binding<RootTab?> {
        Binding(
            get: { selectedTab },
            set: { selectedTab = $0 ?? selectedTab }
        )
    }

    @ViewBuilder
    private func section(for tab: RootTab) -> some View {
        switch tab {
        case .dashboard:
            NavigationStack {
                DashboardView(viewModel: viewModel)
            }
        case .audit:
            NavigationStack {
                AuditListView(viewModel: viewModel)
            }
        case .history:
            NavigationStack {
                HistoryView(viewModel: viewModel)
            }
        case .inspect:
            ContentView(viewModel: viewModel)
        case .settings:
            NavigationStack {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    // MARK: Intent / deep-link routing

    private func consume(_ action: DomainDigDeepLink.Action?) {
        guard let action else { return }
        intentRouter.pendingAction = nil
        perform(action)
    }

    private func perform(_ action: DomainDigDeepLink.Action) {
        switch action {
        case let .inspect(domain):
            viewModel.domain = domain
            selectedTab = .inspect
            viewModel.run()
        case let .watch(domain):
            // On success show the dashboard (where tracked domains live); on
            // failure stay put so the upgrade/paywall alert surfaces in place.
            if viewModel.trackDomain(domain: domain, availabilityStatus: nil) {
                selectedTab = .dashboard
            }
        case let .detail(domain):
            // Open the tracked domain's detail (e.g. from a widget tap). If it is
            // no longer tracked, fall back to inspecting it.
            if let tracked = viewModel.trackedDomains.first(
                where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }
            ) {
                detailDomain = tracked
            } else {
                perform(.inspect(domain))
            }
        case .sweep:
            selectedTab = .dashboard
            viewModel.refreshAllTrackedDomains()
        }
    }
}

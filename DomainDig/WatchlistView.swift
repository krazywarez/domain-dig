import SwiftUI

struct WatchlistView: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: DomainViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var purchaseService = PurchaseService.shared
    @State private var showWorkflowAddSheet = false
    @State private var showAddDomainSheet = false
    @State private var newTrackedDomain = ""
    @State private var addDomainError: String?
    @FocusState private var isAddDomainFieldFocused: Bool
    @State private var showSavedViewsSheet = false
    @State private var showSaveViewPrompt = false
    @State private var newSavedViewName = ""

    private var pinnedDomains: [TrackedDomain] {
        viewModel.filteredTrackedDomains.filter(\.isPinned)
    }

    private var otherDomains: [TrackedDomain] {
        viewModel.filteredTrackedDomains.filter { !$0.isPinned }
    }

    var body: some View {
        let _ = purchaseService.currentTier

        List {
            if !viewModel.allWatchlistTags.isEmpty {
                Section {
                    TagFilterChipRowView(tags: viewModel.allWatchlistTags, selection: $viewModel.watchlistTagFilter)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if viewModel.batchLookupSource == .watchlistRefresh, (!viewModel.batchResults.isEmpty || viewModel.batchLookupRunning) {
                Section("Refresh Progress") {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(viewModel.batchCompletedCount), total: Double(max(viewModel.batchTotalCount, 1)))
                            .tint(Color(.statusInfo))
                        HStack {
                            Text(viewModel.batchProgressLabel)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))
                            Spacer()
                            if viewModel.batchLookupRunning {
                                Button("Cancel") {
                                    viewModel.cancelBatchLookup()
                                }
                                .buttonStyle(.bordered)
                                .font(appDensity.font(.caption2))
                            }
                        }

                        ForEach(viewModel.batchResults.prefix(5)) { result in
                            BatchResultRowView(result: result)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color(.appSurface))
            }

            if viewModel.filteredTrackedDomains.isEmpty {
                Section {
                    EmptyStateCardView(
                        title: "No Tracked Domains",
                        message: "Track important domains locally so you can refresh them quickly and see status changes at a glance.",
                        suggestion: "Run an inspection and use the Track action on a domain you care about.",
                        systemImage: "eye",
                        showsCardBackground: false
                    )
                }
                .listRowBackground(Color(.appSurface))
            } else {
                if let limitMessage = FeatureAccessService.trackedDomainLimitMessage(currentCount: viewModel.trackedDomains.count) {
                    Section {
                        Text(limitMessage)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                    .listRowBackground(Color(.appSurface))
                }

                if !pinnedDomains.isEmpty {
                    trackedSection(title: "Pinned", domains: pinnedDomains)
                }

                if !otherDomains.isEmpty {
                    trackedSection(title: pinnedDomains.isEmpty ? "Tracked Domains" : "Others", domains: otherDomains)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.filteredTrackedDomains.map(\.id))
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle("Watchlist")
        .searchable(text: $viewModel.watchlistSearchText, prompt: "Search tracked domains")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    addDomainError = nil
                    newTrackedDomain = ""
                    showAddDomainSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add domain")

                if !viewModel.filteredTrackedDomains.isEmpty {
                    Menu {
                        Picker("Filter", selection: $viewModel.watchlistFilter) {
                            ForEach(WatchlistFilterOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }

                        Picker("Sort", selection: $viewModel.watchlistSortOption) {
                            ForEach(WatchlistSortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }

                        Button("Save Current View…") {
                            newSavedViewName = ""
                            showSaveViewPrompt = true
                        }

                        if !viewModel.watchlistSavedViews.isEmpty {
                            Button("Saved Views") {
                                showSavedViewsSheet = true
                            }
                        }

                        Button(viewModel.batchLookupRunning ? "Check All Running" : "Check All") {
                            AppHaptics.refresh()
                            viewModel.refreshAllTrackedDomains()
                        }
                        .disabled(viewModel.batchLookupRunning)

                        Button("Add to Workflow") {
                            showWorkflowAddSheet = true
                        }

                        if viewModel.trackedDomains.count >= 2 {
                            NavigationLink("Compare Domains") {
                                DomainCompareView(viewModel: viewModel)
                            }
                        }

                        ExportFormatButtons(share: shareTrackedDomains)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter and sort")

                    EditButton()
                }
            }
        }
        .onChange(of: viewModel.rerunNavigationToken) { _, _ in
            dismiss()
        }
        .sheet(item: batchSummaryBinding) { summary in
            BatchSweepSummaryView(viewModel: viewModel, summary: summary)
        }
        .sheet(isPresented: $showAddDomainSheet) {
            NavigationStack {
                Form {
                    Section("Domain") {
                        TextField("example.com", text: $newTrackedDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .focused($isAddDomainFieldFocused)
                            .onSubmit(addTrackedDomain)
                    }

                    Section {
                        Text("Adds the domain directly to your watchlist so monitoring can run without a prior inspection.")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))
                    }

                    if let addDomainError {
                        Section {
                            Text(addDomainError)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.statusCritical))
                        }
                    }
                }
                .navigationTitle("Add Domain")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showAddDomainSheet = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", action: addTrackedDomain)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isAddDomainFieldFocused = true
                    }
                }
            }
        }
        .sheet(isPresented: $showWorkflowAddSheet) {
            WorkflowBulkAddSheet(
                viewModel: viewModel,
                title: "Add Watchlist Domains",
                availableDomains: viewModel.filteredTrackedDomains.map(\.domain)
            )
        }
        .alert("Save Current View", isPresented: $showSaveViewPrompt) {
            TextField("View name", text: $newSavedViewName)
            Button("Save") {
                viewModel.saveCurrentWatchlistView(name: newSavedViewName)
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("Saves the current tag, filter, and sort as a reusable preset.")
        }
        .sheet(isPresented: $showSavedViewsSheet) {
            NavigationStack {
                List {
                    ForEach(viewModel.watchlistSavedViews) { view in
                        Button {
                            viewModel.applyWatchlistSavedView(view)
                            showSavedViewsSheet = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(view.name)
                                    .foregroundStyle(.primary)
                                Text([view.tag, view.filter.title, view.sort.title].compactMap { $0 }.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(Color(.appTextSecondary))
                            }
                        }
                    }
                    .onDelete { offsets in
                        viewModel.deleteWatchlistSavedViews(at: offsets)
                    }
                }
                .navigationTitle("Saved Views")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showSavedViewsSheet = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackedSection(title: String, domains: [TrackedDomain]) -> some View {
        Section(title) {
            ForEach(domains) { trackedDomain in
                trackedDomainRow(trackedDomain)
            }
        }
    }

    private func trackedDomainRow(_ trackedDomain: TrackedDomain) -> some View {
        NavigationLink {
            TrackedDomainDetailView(viewModel: viewModel, trackedDomain: trackedDomain)
        } label: {
            WatchlistRowView(
                trackedDomain: trackedDomain,
                isRefreshing: viewModel.refreshingTrackedDomainID == trackedDomain.id
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            refreshButton(trackedDomain)
                .tint(Color(.statusInfo))
            pinButton(trackedDomain)
                .tint(Color(.statusWarning))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            refreshButton(trackedDomain)
                .tint(Color(.statusInfo))
            deleteButton(trackedDomain)
        }
        .contextMenu {
            rowMenu(trackedDomain)
        }
        .listRowBackground(Color(.appSurface))
    }

    @ViewBuilder
    private func rowMenu(_ trackedDomain: TrackedDomain) -> some View {
        refreshButton(trackedDomain)

        Button {
            dismiss()
            viewModel.rerunInspection(for: trackedDomain)
        } label: {
            Label("Open Inspection", systemImage: "magnifyingglass")
        }

        pinButton(trackedDomain)
            .disabled(!viewModel.canEdit(trackedDomain))

        Button {
            // The system sharing UI manages participants and permissions.
        } label: {
            Label(trackedDomain.collaboration?.isShared == true ? "Shared" : "Private", systemImage: "person.2")
        }
        .disabled(true)

        deleteButton(trackedDomain)
    }

    private func refreshButton(_ trackedDomain: TrackedDomain) -> some View {
        Button {
            AppHaptics.refresh()
            viewModel.refreshTrackedDomain(trackedDomain)
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private func pinButton(_ trackedDomain: TrackedDomain) -> some View {
        Button {
            viewModel.togglePinned(for: trackedDomain)
        } label: {
            Label(trackedDomain.isPinned ? "Unpin" : "Pin", systemImage: trackedDomain.isPinned ? "pin.slash" : "pin")
        }
    }

    @ViewBuilder
    private func deleteButton(_ trackedDomain: TrackedDomain) -> some View {
        if viewModel.canDelete(trackedDomain) {
            Button(role: .destructive) {
                viewModel.deleteTrackedDomain(trackedDomain)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var batchSummaryBinding: Binding<BatchSweepSummary?> {
        Binding(
            get: { viewModel.latestBatchSweepSummary },
            set: { viewModel.latestBatchSweepSummary = $0 }
        )
    }

    private func deleteFilteredTrackedDomains(at offsets: IndexSet) {
        let domains = offsets.map { viewModel.filteredTrackedDomains[$0] }
        domains.forEach(viewModel.deleteTrackedDomain)
    }

    private func shareTrackedDomains(format: DomainExportFormat) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)_domaindig_watchlist.\(format.fileExtension)"
        guard let data = viewModel.exportTrackedDomainsData(domains: viewModel.filteredTrackedDomains, format: format) else {
            return
        }

        ExportPresenter.share(filename: filename, data: data)
    }

    private func addTrackedDomain() {
        let draft = newTrackedDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            addDomainError = "Enter a domain to add."
            return
        }

        if viewModel.trackDomain(domain: draft, availabilityStatus: nil) {
            AppHaptics.track()
            isAddDomainFieldFocused = false
            addDomainError = nil
            newTrackedDomain = ""
            showAddDomainSheet = false
        } else if viewModel.upgradePrompt == nil {
            addDomainError = "Enter a valid domain like example.com."
        }
    }
}

struct WatchlistRowView: View {
    @Environment(\.appDensity) private var appDensity
    let trackedDomain: TrackedDomain
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 1) {
            // Side-by-side while it fits; at accessibility sizes the badge drops
            // below the domain instead of squeezing it into "hea lt…" while the
            // badge letter-wraps down the screen. ViewThatFits picks the wide
            // layout whenever it genuinely fits, so default sizes keep density.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    domainTitle
                    Spacer(minLength: 8)
                    statusBadge
                }
                VStack(alignment: .leading, spacing: 6) {
                    domainTitle
                    statusBadge
                }
            }

            Text("Updated \(trackedDomain.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(appDensity.font(.caption2))
                .foregroundStyle(Color(.appTextSecondary))

            if let collaboration = trackedDomain.collaboration, collaboration.isShared {
                Text("\(collaboration.ownership.title) • \(collaboration.permission.title)")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { monitoringMetadata }
                VStack(alignment: .leading, spacing: 2) { monitoringMetadata }
            }
            .font(appDensity.font(.caption2))
            .foregroundStyle(Color(.appTextSecondary))

            indicatorRow

            if let note = trackedDomain.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(Color(.appTextSecondary))
                    .lineLimit(2)
            } else if let summary = trackedDomain.lastChangeSummary {
                Text(summary.message)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(Color(.appTextSecondary))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .modifier(WatchlistRowAccessibility(trackedDomain: trackedDomain, isRefreshing: isRefreshing))
    }

    @ViewBuilder
    private var monitoringMetadata: some View {
        Text(trackedDomain.monitoringEnabled ? "Monitoring on" : "Monitoring off")
        if let lastMonitoredAt = trackedDomain.lastMonitoredAt {
            Text("Checked \(lastMonitoredAt.formatted(date: .omitted, time: .shortened))")
        }
        if let lastAlertAt = trackedDomain.lastAlertAt {
            Text("Alert \(lastAlertAt.formatted(date: .omitted, time: .shortened))")
        }
    }

    private var domainTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if trackedDomain.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(.statusWarning))
            }
            Text(trackedDomain.domain)
                .font(appDensity.font(.callout))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func availabilityLabel(_ status: DomainAvailabilityStatus?) -> String {
        switch status {
        case .available:
            return "Available"
        case .registered:
            return "Registered"
        case .unknown, .none:
            return "Unknown"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isRefreshing {
            AppStatusBadgeView(model: .init(title: "Refreshing", systemImage: "arrow.clockwise", foregroundColor: Color(.appTextSecondary), backgroundColor: Color(.appSurfaceElevated)))
        } else {
            AppStatusBadgeView(model: AppStatusFactory.availability(trackedDomain.lastKnownAvailability))
        }
    }

    @ViewBuilder
    private var indicatorRow: some View {
        HStack(spacing: 8) {
            if trackedDomain.collaboration?.isShared == true {
                AppStatusBadgeView(
                    model: .init(
                        title: "Shared",
                        systemImage: "person.2.fill",
                        foregroundColor: Color(.statusInfo),
                        backgroundColor: Color(.statusInfoSurface)
                    )
                )
            }

            AppStatusBadgeView(model: AppStatusFactory.change(trackedDomain.lastChangeSummary))

            if trackedDomain.certificateWarningLevel != .none {
                AppStatusBadgeView(model: certificateBadge)
            }
        }
    }

    private var certificateBadge: AppStatusBadgeModel {
        let days = trackedDomain.certificateDaysRemaining.map { "\($0)d" } ?? "Soon"
        switch trackedDomain.certificateWarningLevel {
        case .critical:
            return .init(title: "Invalid \(days)", systemImage: "xmark.octagon.fill", foregroundColor: Color(.statusCritical), backgroundColor: Color(.statusCriticalSurface))
        case .warning:
            return .init(title: "Expiring \(days)", systemImage: "exclamationmark.triangle.fill", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .none:
            return .init(title: "Valid", systemImage: "lock.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        }
    }
}

/// Row-level VoiceOver treatment for a tracked domain: domain as label,
/// availability as value, the rest on the More Content rotor. Same rationale as
/// the batch row — up to nine text elements would be one unnavigable utterance.
private struct WatchlistRowAccessibility: ViewModifier {
    let trackedDomain: TrackedDomain
    let isRefreshing: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trackedDomain.domain)
            .accessibilityValue(isRefreshing ? "Refreshing" : AppStatusFactory.availability(trackedDomain.lastKnownAvailability).title)
            .accessibilityCustomContent("Certificate", certificateContent, importance: .high)
            .accessibilityCustomContent("Monitoring", trackedDomain.monitoringEnabled ? "on" : "off")
            .accessibilityCustomContent("Updated", trackedDomain.updatedAt.formatted(date: .abbreviated, time: .shortened))
            .accessibilityCustomContent("Pinned", trackedDomain.isPinned ? "yes" : "no")
    }

    private var certificateContent: String {
        let days = trackedDomain.certificateDaysRemaining.map { "\($0) days" } ?? "unknown"
        switch trackedDomain.certificateWarningLevel {
        case .critical: return "invalid, \(days)"
        case .warning: return "expiring, \(days)"
        case .none: return "valid"
        }
    }
}

struct TrackedDomainDetailView: View {
    @Bindable var viewModel: DomainViewModel
    let trackedDomain: TrackedDomain
    @Environment(\.dismiss) private var dismiss

    @State private var noteDraft = ""
    @State private var isEditingNote = false
    @State private var tagsDraft = ""
    @State private var isEditingTags = false
    @State private var showRerunOptions = false
    @State private var shareEntity: ShareableEntity?
    @State private var showingAuditTimeline = false
    @State private var auditStartInFlight = false

    private var liveTrackedDomain: TrackedDomain {
        viewModel.trackedDomains.first(where: { $0.id == trackedDomain.id }) ?? trackedDomain
    }

    private var latestSnapshots: [HistoryEntry] {
        viewModel.recentSnapshots(for: liveTrackedDomain)
    }

    private var latestDiffSections: [DomainDiffSection] {
        viewModel.diffSectionsForLatestSnapshots(of: liveTrackedDomain)
    }

    var body: some View {
        List {
            Section {
                WatchlistRowView(
                    trackedDomain: liveTrackedDomain,
                    isRefreshing: viewModel.refreshingTrackedDomainID == liveTrackedDomain.id
                )
            }
            .listRowBackground(Color(.appSurface))

            Section {
                Button {
                    viewModel.refreshTrackedDomain(liveTrackedDomain)
                } label: {
                    Label("Manual Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    showRerunOptions = true
                } label: {
                    Label("Re-run Inspection", systemImage: "magnifyingglass")
                }

                Button {
                    Task {
                        auditStartInFlight = true
                        if await viewModel.startAudit(for: liveTrackedDomain.domain) != nil {
                            showingAuditTimeline = true
                        }
                        auditStartInFlight = false
                    }
                } label: {
                    Label(auditStartInFlight ? "Starting Audit…" : "Start Audit", systemImage: "checklist")
                }
                .disabled(auditStartInFlight)

                if !viewModel.audits(for: liveTrackedDomain.domain).isEmpty {
                    Button {
                        showingAuditTimeline = true
                    } label: {
                        Label("View Audits", systemImage: "clock.badge.checkmark")
                    }
                }

                Button {
                    viewModel.togglePinned(for: liveTrackedDomain)
                } label: {
                    Label(liveTrackedDomain.isPinned ? "Unpin Domain" : "Pin Domain", systemImage: liveTrackedDomain.isPinned ? "pin.slash" : "pin")
                }
                .disabled(!viewModel.canEdit(liveTrackedDomain))

                Button {
                    viewModel.toggleMonitoring(for: liveTrackedDomain)
                } label: {
                    Label(
                        liveTrackedDomain.monitoringEnabled ? "Disable Monitoring" : "Enable Monitoring",
                        systemImage: liveTrackedDomain.monitoringEnabled ? "bell.slash" : "bell"
                    )
                }
                .disabled(!viewModel.canEdit(liveTrackedDomain))

                Button {
                    noteDraft = liveTrackedDomain.note ?? ""
                    isEditingNote = true
                } label: {
                    Label(liveTrackedDomain.note == nil ? "Add Note" : "Edit Note", systemImage: "note.text")
                }
                .disabled(!viewModel.canEdit(liveTrackedDomain))

                Button {
                    tagsDraft = liveTrackedDomain.tags.joined(separator: ", ")
                    isEditingTags = true
                } label: {
                    Label(liveTrackedDomain.tags.isEmpty ? "Add Tags" : "Edit Tags", systemImage: "tag")
                }
                .disabled(!viewModel.canEdit(liveTrackedDomain))

                Button {
                    shareEntity = .trackedDomain(liveTrackedDomain.domain)
                } label: {
                    Label(liveTrackedDomain.collaboration?.isShared == true ? "Manage Share" : "Share Domain", systemImage: "person.2")
                }
            }
            .listRowBackground(Color(.appSurface))

            if !liveTrackedDomain.tags.isEmpty {
                Section("Tags") {
                    TagChipRowView(tags: liveTrackedDomain.tags)
                }
                .listRowBackground(Color(.appSurface))
            }

            Section("Monitoring Status") {
                LabeledContent("State", value: viewModel.monitoringStatusLabel(for: liveTrackedDomain))
                LabeledContent("Current Interval", value: viewModel.monitoringIntervalLabel(for: liveTrackedDomain))
                LabeledContent(
                    "Last Change",
                    value: liveTrackedDomain.monitoringState.lastChangeDate?.formatted(date: .abbreviated, time: .shortened) ?? "None"
                )
                if !liveTrackedDomain.pendingMonitoringAlerts.isEmpty {
                    LabeledContent("Queued Alerts", value: "\(liveTrackedDomain.pendingMonitoringAlerts.count)")
                }
            }
            .listRowBackground(Color(.appSurface))

            if let summary = viewModel.latestChangeSummary(for: liveTrackedDomain) {
                Section("Latest Change Summary") {
                    DomainChangeSummaryView(summary: summary)
                }
                .listRowBackground(Color.clear)
            }

            if !latestDiffSections.isEmpty {
                Section("Latest Diff") {
                    DomainDiffView(
                        title: "Latest Snapshot vs Previous",
                        sections: latestDiffSections,
                        contextNote: latestSnapshots.count >= 2
                            ? DomainDiffService.comparisonContextNote(from: latestSnapshots[1].snapshot, to: latestSnapshots[0].snapshot)
                            : nil,
                        showsUnchanged: false,
                        highlightedSectionID: nil
                    )
                }
                .listRowBackground(Color.clear)
            }

            Section("Recent Snapshots") {
                if latestSnapshots.isEmpty {
                    Text("No snapshots yet")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(latestSnapshots) { entry in
                        NavigationLink {
                            HistoryDetailView(viewModel: viewModel, entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(entry.changeSummary?.hasChanges == true ? "Changed" : "Snapshot")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Color(.appTextSecondary))
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color(.appSurface))
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle(liveTrackedDomain.domain)
        .onChange(of: viewModel.rerunNavigationToken) { _, _ in
            dismiss()
        }
        .confirmationDialog("Re-run inspection", isPresented: $showRerunOptions) {
            Button("Run with Current Settings") {
                viewModel.rerunInspection(for: liveTrackedDomain, useSnapshotResolver: false)
            }
            if latestSnapshots.first != nil {
                Button("Run with Snapshot Resolver") {
                    viewModel.rerunInspection(for: liveTrackedDomain, useSnapshotResolver: true)
                }
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text(viewModel.resolverMismatchNote(for: liveTrackedDomain) ?? "Choose how to reproduce the most recent snapshot.")
        }
        .sheet(isPresented: $isEditingNote) {
            NavigationStack {
                Form {
                    Section("Tracking Note") {
                        TextField("Optional note", text: $noteDraft, axis: .vertical)
                            .lineLimit(3...6)
                    }
                }
                .navigationTitle("Edit Note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditingNote = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.updateNote(noteDraft, for: liveTrackedDomain)
                            isEditingNote = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isEditingTags) {
            NavigationStack {
                Form {
                    Section("Tags") {
                        TextField("comma, separated, tags", text: $tagsDraft)
                            .textInputAutocapitalization(.never)
                    }
                }
                .navigationTitle("Edit Tags")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditingTags = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let tags = tagsDraft.components(separatedBy: ",")
                            viewModel.updateTags(tags, for: liveTrackedDomain)
                            isEditingTags = false
                        }
                    }
                }
            }
        }
        .sheet(item: $shareEntity) { entity in
            CloudSharingSheet(entity: entity, title: liveTrackedDomain.domain)
        }
        .sheet(isPresented: $showingAuditTimeline) {
            NavigationStack {
                AuditDomainTimelineView(viewModel: viewModel, domain: liveTrackedDomain.domain)
            }
        }
    }
}

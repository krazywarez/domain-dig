import SwiftUI

struct HistoryView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showClearAllConfirmation = false
    @State private var showWorkflowAddSheet = false

    private var domainSummaries: [(domain: String, latest: SnapshotSummary, count: Int)] {
        viewModel.timelineDomains.compactMap { domain in
            let entries = viewModel.timelineEntries(for: domain)
            guard let latest = entries.first else { return nil }
            return (domain, latest, entries.count)
        }
    }

    var body: some View {
        List {
            if viewModel.filteredHistory.isEmpty {
                EmptyStateCardView(
                    title: "No History Yet",
                    message: "History stores local snapshots of previous inspections so you can revisit and compare them later.",
                    suggestion: "Run a lookup to create your first saved snapshot.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    showsCardBackground: false
                )
                    .listRowBackground(Color(.appSurface))
            } else {
                Section("Domains") {
                    ForEach(domainSummaries, id: \.domain) { item in
                        NavigationLink {
                            TimelineView(viewModel: viewModel, domain: item.domain)
                        } label: {
                            VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 1) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(item.domain)
                                        .font(appDensity.font(.callout))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(item.count) snapshots")
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }

                                Text(item.latest.changeSummaryMessage ?? "No change summary")
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(Color(.appTextSecondary))
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    AppStatusBadgeView(model: AppStatusFactory.availability(item.latest.availability))
                                    if let severity = item.latest.severitySummary {
                                        AppStatusBadgeView(
                                            model: .init(
                                                title: severity.title,
                                                systemImage: "arrow.triangle.2.circlepath",
                                                foregroundColor: severity == .high ? Color(.statusCritical) : Color(.statusWarning),
                                                backgroundColor: (severity == .high ? AppStatusTone.critical : .warning).surface
                                            )
                                        )
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color(.appSurface))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle("History")
        .searchable(text: $viewModel.timelineDomainFilter, prompt: "Search domains")
        .toolbar {
            if !viewModel.history.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Date Range", selection: $viewModel.historyDateFilter) {
                            ForEach(HistoryDateFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }

                        Picker("Change Filter", selection: $viewModel.historyChangeFilter) {
                            ForEach(ChangeFilterOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }

                        Picker("Sort", selection: $viewModel.historySortOption) {
                            ForEach(HistorySortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }

                        Button("Clear All", role: .destructive) {
                            showClearAllConfirmation = true
                        }

                        if !viewModel.filteredHistory.isEmpty {
                            Button("Add to Workflow") {
                                showWorkflowAddSheet = true
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter")

                    EditButton()
                }
            }
        }
        .alert("Clear history?", isPresented: $showClearAllConfirmation) {
            Button("Clear All", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("This will delete all saved history entries. This cannot be undone.")
        }
        .sheet(isPresented: $showWorkflowAddSheet) {
            WorkflowBulkAddSheet(
                viewModel: viewModel,
                title: "Add History Domains",
                availableDomains: Array(Set(viewModel.filteredHistory.map(\.domain))).sorted()
            )
        }
        .onChange(of: viewModel.rerunNavigationToken) { _, _ in
            dismiss()
        }
    }

    private func deleteFilteredHistoryEntries(at offsets: IndexSet) {
        let ids = offsets.map { viewModel.filteredHistory[$0].id }
        viewModel.removeHistoryEntries(withIDs: ids)
    }
}

struct HistoryDetailView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let entry: HistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var noteDraft = ""
    @State private var isEditingNote = false
    @State private var showRerunOptions = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var snapshot: LookupSnapshot {
        entry.snapshot
    }

    private var report: DomainReport {
        DomainReportBuilder().build(
            from: entry,
            previousSnapshot: viewModel.comparisonSnapshot(for: entry),
            historyEntries: viewModel.historyEntries(for: entry.domain)
        )
    }

    private var trackedDomain: TrackedDomain? {
        viewModel.trackedDomains.first { $0.domain.caseInsensitiveCompare(entry.domain) == .orderedSame }
    }

    var body: some View {
        List {
                Section {
                    snapshotBanner
                }
                Section {
                    SummaryView(fields: DomainViewModel.summaryFields(from: snapshot))
                }
                Section {
                    RiskSummaryCardView(report: report)
                }
                Section {
                    InsightsSummaryCardView(insights: report.insights)
                }
                Section {
                    IntelligenceSectionView(
                        isCollapsed: .constant(false),
                        report: report,
                        showsPlaceholder: !FeatureAccessService.hasAccess(to: .intelligenceDetail)
                    )
                }
                Section {
                    DomainSectionView(
                        isCollapsed: .constant(false),
                        rows: DomainViewModel.domainRows(from: snapshot),
                        suggestions: DomainViewModel.suggestionRows(from: snapshot),
                        showSuggestions: entry.availabilityResult?.status == .registered && !entry.suggestions.isEmpty,
                        availabilityLoading: false,
                        suggestionsLoading: false,
                        provenance: snapshot.provenanceBySection[.availability],
                        confidence: snapshot.availabilityConfidence,
                        snapshotNote: entry.note,
                        trackedDomain: trackedDomain,
                        workflows: viewModel.workflowsContaining(domain: entry.domain),
                        trackingLimitMessage: nil,
                        onTrack: {
                            _ = viewModel.trackDomain(domain: entry.domain, availabilityStatus: entry.availabilityResult?.status)
                        },
                        onTogglePinned: {
                            guard let trackedDomain else { return }
                            viewModel.togglePinned(for: trackedDomain)
                        },
                        onEditNote: nil,
                        onAddToWorkflow: nil,
                        onOpenWorkflow: nil,
                        onRunWorkflow: nil
                    )
                }
                Section {
                    OwnershipSectionView(
                        isCollapsed: .constant(false),
                        rows: DomainViewModel.ownershipRows(from: snapshot),
                        loading: false,
                        error: snapshot.ownershipError,
                        provenance: snapshot.provenanceBySection[.ownership],
                        confidence: snapshot.ownershipConfidence
                    )
                }
                Section {
                    SubdomainsSectionView(
                        isCollapsed: .constant(false),
                        rows: DomainViewModel.subdomainRows(from: snapshot),
                        groups: report.subdomainGroups,
                        loading: false,
                        error: snapshot.subdomainsError,
                        provenance: snapshot.provenanceBySection[.subdomains],
                        confidence: snapshot.subdomainConfidence,
                        showsExtendedPlaceholder: !FeatureAccessService.hasAccess(to: .extendedSubdomains)
                    )
                }
                if let comparisonSnapshot = viewModel.comparisonSnapshot(for: entry) {
                    if let changeSummary = entry.changeSummary {
                        Section {
                            DomainChangeSummaryView(summary: changeSummary)
                        }
                    }
                    Section {
                        DomainDiffView(
                            title: "Compared With Previous Snapshot",
                            sections: DomainDiffService.diff(from: comparisonSnapshot, to: snapshot),
                            contextNote: DomainDiffService.comparisonContextNote(from: comparisonSnapshot, to: snapshot),
                            showsUnchanged: false,
                            highlightedSectionID: nil
                        )
                    }
                }
                Section {
                    DNSSectionView(
                        isCollapsed: .constant(false),
                        dnssecLabel: DomainViewModel.dnssecLabel(from: snapshot),
                        patternSummary: report.dns.patternSummary,
                        sections: DomainViewModel.dnsRows(from: snapshot),
                        ptrMessage: DomainViewModel.ptrMessage(from: snapshot),
                        loading: false,
                        dnsProvenance: snapshot.provenanceBySection[.dns],
                        ptrProvenance: snapshot.provenanceBySection[.ptr],
                        sectionError: snapshot.dnsError
                    )
                }
                Section {
                    WebSectionView(
                        isCollapsed: .constant(false),
                        data: DomainViewModel.webSectionData(from: snapshot, report: report)
                    )
                }
                Section {
                    EmailSectionView(
                        isCollapsed: .constant(false),
                        rows: DomainViewModel.emailRows(from: snapshot),
                        assessment: report.email,
                        loading: false,
                        provenance: snapshot.provenanceBySection[.emailSecurity],
                        confidence: snapshot.emailSecurityConfidence,
                        error: snapshot.emailSecurityError
                    )
                }
                Section {
                    NetworkSectionView(
                        isCollapsed: .constant(false),
                        customPortsExpanded: .constant(false),
                        customPortInput: .constant(""),
                        data: DomainViewModel.networkSectionData(from: snapshot),
                        onScanCustomPorts: { /* Historical snapshot; re-scanning is not offered here. */ }
                    )
                }
        }
        .listRowBackground(Color(.appSurface))
        .environment(\.cardProvidesSurface, false)
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle(entry.domain)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Note") {
                    noteDraft = entry.note ?? ""
                    isEditingNote = true
                }
                Button("Re-run") {
                    showRerunOptions = true
                }
            }
        }
        .onChange(of: viewModel.rerunNavigationToken) { _, _ in
            dismiss()
        }
        .confirmationDialog("Re-run lookup", isPresented: $showRerunOptions) {
            Button("Run with Current Settings") {
                viewModel.rerunLookup(from: entry, useSnapshotResolver: false)
            }
            Button("Run with Snapshot Resolver") {
                viewModel.rerunLookup(from: entry, useSnapshotResolver: true)
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text(viewModel.resolverMismatchNote(for: entry) ?? "Choose how to reproduce this snapshot.")
        }
        .sheet(isPresented: $isEditingNote) {
            NavigationStack {
                Form {
                    Section("Audit Note") {
                        TextField("Optional note", text: $noteDraft, axis: .vertical)
                            .lineLimit(3...6)
                    }
                }
                .navigationTitle(entry.domain)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditingNote = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.updateHistoryNote(noteDraft, for: entry)
                            isEditingNote = false
                        }
                    }
                }
            }
        }
    }

    private var snapshotBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.caption)
                Text("Snapshot from \(dateFormatter.string(from: entry.timestamp))")
                    .font(appDensity.font(.caption))
                Spacer()
                Text("Live re-run available")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }
            if let mismatchNote = viewModel.resolverMismatchNote(for: entry) {
                Text(mismatchNote)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.statusWarning))
            }
            if entry.isPartialSnapshot {
                Text("Partial snapshot: \(entry.validationIssues.joined(separator: " | "))")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.statusWarning))
            }
            if let note = entry.note, !note.isEmpty {
                Text(note)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }
        }
        .foregroundStyle(Color(.appTextSecondary))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.appSurface))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
        .padding(.vertical, 12)
    }
}

private struct HistoryGroup: Identifiable {
    let title: String
    let entries: [HistoryEntry]

    var id: String { title }

    static func groups(for entries: [HistoryEntry]) -> [HistoryGroup] {
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let grouped = Dictionary(grouping: entries) { entry -> String in
            if calendar.isDate(entry.timestamp, inSameDayAs: today) {
                return "Today"
            }
            if calendar.isDate(entry.timestamp, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            return "Older"
        }

        return ["Today", "Yesterday", "Older"].compactMap { title in
            guard let entries = grouped[title], !entries.isEmpty else { return nil }
            return HistoryGroup(title: title, entries: entries)
        }
    }
}

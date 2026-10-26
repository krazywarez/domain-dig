import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum LookupInputMode: String, CaseIterable, Identifiable {
    case single
    case bulk

    var id: String { rawValue }
}

enum ResultSection: String, Hashable {
    case domain
    case intelligence
    case ownership
    case dns
    case web
    case email
    case network
    case subdomains
}

private enum LookupInputField: Hashable {
    case singleDomain
    case bulkDomains
}

private struct WorkflowNavigationTarget: Hashable {
    let workflowID: UUID
}

struct ContentView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @State private var navigationPath = NavigationPath()
    @FocusState private var focusedInputField: LookupInputField?
    @State private var customPortInput = ""
    @State private var customPortsExpanded = false
    @State private var trackingNoteDraft = ""
    @State private var editingTrackedDomain: TrackedDomain?
    @State private var inputMode: LookupInputMode = .single
    @State private var collapsedSections: Set<ResultSection> = [.network]
    @State private var showingCurrentDomainWorkflowSheet = false
    @State private var showingBatchWorkflowSheet = false
    @State private var showingTimeline = false
    @State private var showingAuditTimeline = false
    @State private var auditStartInFlight = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section { inputSection }
                if !viewModel.batchResults.isEmpty || viewModel.batchLookupRunning {
                    Section { batchSection }
                }
                if viewModel.hasRun {
                    Section { actionButtons }
                    if !viewModel.resultsLoaded {
                        Section { LookupProgressOverviewView(steps: viewModel.activeLoadingLabels) }
                    } else if let statusMessage = resultStatusMessage {
                        Section {
                            LookupStatusBannerView(message: statusMessage, resultSource: viewModel.currentResultSource)
                        }
                    }
                    if viewModel.resultsLoaded {
                        Section { SummaryView(fields: viewModel.summaryFields) }
                        if let report = viewModel.currentReport {
                            Section { RiskSummaryCardView(report: report) }
                            Section { InsightsSummaryCardView(insights: report.insights) }
                        }
                        if let changeSummary = viewModel.currentChangeSummary {
                            Section { DomainChangeSummaryView(summary: changeSummary) }
                        }
                    }
                    if let report = viewModel.currentReport {
                        Section { intelligenceSection(report: report) }
                    }
                    Section { domainOverviewSection }
                    Section { ownershipSection }
                    Section { subdomainsSection }
                    if !viewModel.currentDiffSections.isEmpty {
                        Section {
                            DomainDiffView(
                                title: "Latest Changes",
                                sections: viewModel.currentDiffSections,
                                contextNote: viewModel.currentChangeSummary?.contextNote,
                                showsUnchanged: false,
                                highlightedSectionID: nil
                            )
                        }
                    }
                    Section { dnsSection }
                    Section {
                        WebSectionView(
                            isCollapsed: sectionCollapsedBinding(.web),
                            data: viewModel.webSectionData
                        )
                    }
                    Section {
                        EmailSectionView(
                            isCollapsed: sectionCollapsedBinding(.email),
                            rows: viewModel.emailRows,
                            assessment: viewModel.currentEmailAssessment,
                            loading: viewModel.emailSecurityLoading,
                            provenance: viewModel.currentSnapshot.provenanceBySection[.emailSecurity],
                            confidence: viewModel.currentSnapshot.emailSecurityConfidence,
                            error: viewModel.emailSecurityError
                        )
                    }
                    Section {
                        NetworkSectionView(
                            isCollapsed: sectionCollapsedBinding(.network),
                            customPortsExpanded: $customPortsExpanded,
                            customPortInput: $customPortInput,
                            data: viewModel.networkSectionData,
                            onScanCustomPorts: runCustomPortScan
                        )
                    }
                } else if !viewModel.recentSearches.isEmpty {
                    Section { recentSearchesSection }
                }
            }
            .themedListRowBackground(.surface)
            .environment(\.cardProvidesSurface, false)
            .scrollContentBackground(.hidden)
            .background(ThemeToken.background)
            .navigationTitle("DomainDig")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // While a lookup is in flight the same action is a cancel,
                    // so it says so rather than leaving an unlabelled glyph to
                    // stand for both.
                    if viewModel.singleLookupRunning {
                        Button("Cancel") {
                            viewModel.reset()
                        }
                        .accessibilityLabel("Cancel lookup")
                    } else if viewModel.hasRun {
                        Button {
                            viewModel.reset()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(ThemeToken.textSecondary)
                        }
                        .accessibilityLabel("Clear results")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WorkflowsView(viewModel: viewModel)
                    } label: {
                        Label("Workflows", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityLabel("Workflows")
                }
            }
            .navigationDestination(for: WorkflowNavigationTarget.self) { target in
                WorkflowDetailView(viewModel: viewModel, workflowID: target.workflowID)
            }
        }
        .task {
        }
        .onChange(of: viewModel.searchedDomain) { _, _ in
            collapsedSections = defaultCollapsedSections
        }
        .onChange(of: viewModel.resultsLoaded) { wasLoaded, isLoaded in
            // Single-lookup completion has no single view-model moment
            // (`resultsLoaded` is derived from many loading flags), so the
            // announcement is posted from the view where the transition is
            // observable. The batch path announces from the view model directly.
            guard !wasLoaded, isLoaded, viewModel.hasRun else { return }
            let summary = AppStatusFactory.availability(viewModel.availabilityResult?.status).title
            AppAccessibility.announce("Lookup complete for \(viewModel.searchedDomain). \(summary).")
        }
        .onChange(of: viewModel.rerunNavigationToken) { _, _ in
            navigationPath = NavigationPath()
            focusedInputField = nil
        }
        .onChange(of: inputMode) { _, newValue in
            viewModel.clearPresentedResults()
            focusedInputField = newValue == .single ? .singleDomain : .bulkDomains
        }
        .onChange(of: viewModel.domain) { _, newValue in
            viewModel.domainInputError = nil
            guard inputMode == .single else { return }
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != viewModel.searchedDomain else { return }
            guard viewModel.hasRun || !viewModel.batchResults.isEmpty else { return }
            viewModel.clearPresentedResults()
        }
        .onChange(of: viewModel.bulkInput) { _, newValue in
            viewModel.bulkInputError = nil
            guard inputMode == .bulk else { return }
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty || viewModel.hasRun || !viewModel.batchResults.isEmpty else { return }
            viewModel.clearPresentedResults()
        }
        .sheet(item: $editingTrackedDomain) { trackedDomain in
            NavigationStack {
                Form {
                    Section("Tracking Note") {
                        TextField("Optional note", text: $trackingNoteDraft, axis: .vertical)
                            .lineLimit(3...6)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle(trackedDomain.domain)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            editingTrackedDomain = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.updateNote(trackingNoteDraft, for: trackedDomain)
                            editingTrackedDomain = nil
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingCurrentDomainWorkflowSheet) {
            WorkflowBulkAddSheet(
                viewModel: viewModel,
                title: "Add Domain to Workflow",
                availableDomains: [viewModel.searchedDomain]
            )
        }
        .sheet(isPresented: $showingBatchWorkflowSheet) {
            WorkflowBulkAddSheet(
                viewModel: viewModel,
                title: "Add Batch Domains",
                availableDomains: viewModel.batchResults.map(\.domain)
            )
        }
        .sheet(item: manualBatchSummaryBinding) { summary in
            BatchSweepSummaryView(viewModel: viewModel, summary: summary)
        }
        .sheet(isPresented: $showingTimeline) {
            NavigationStack {
                TimelineView(viewModel: viewModel, domain: viewModel.searchedDomain)
            }
        }
        .sheet(isPresented: $showingAuditTimeline) {
            NavigationStack {
                AuditDomainTimelineView(viewModel: viewModel, domain: viewModel.searchedDomain)
            }
        }
    }

    private var manualBatchSummaryBinding: Binding<BatchSweepSummary?> {
        Binding(
            get: {
                guard let summary = viewModel.latestBatchSweepSummary,
                      summary.source == .manual else {
                    return nil
                }
                return summary
            },
            set: { viewModel.latestBatchSweepSummary = $0 }
        )
    }

    private var inputSection: some View {
        VStack(spacing: appDensity.metrics.cardSpacing + 2) {
            Picker("Mode", selection: $inputMode) {
                Text("Single").tag(LookupInputMode.single)
                Text("Bulk").tag(LookupInputMode.bulk)
            }
            .pickerStyle(.segmented)

            if inputMode == .single {
                TextField("e.g. cleberg.net", text: $viewModel.domain)
                    .font(appDensity.font(.title3, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.horizontal, 12)
                    .padding(.vertical, appDensity.metrics.controlVerticalPadding)
                    .background(ThemeToken.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                    .focused($focusedInputField, equals: .singleDomain)
                    .onSubmit {
                        focusedInputField = nil
                        viewModel.run()
                    }

                if let domainInputError = viewModel.domainInputError {
                    Text(domainInputError)
                        .font(appDensity.font(.caption))
                        .foregroundStyle(ThemeToken.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    focusedInputField = nil
                    viewModel.run()
                } label: {
                    Text("Run")
                        .font(appDensity.font(.headline, design: .default, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: appDensity.metrics.controlMinHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeToken.accent)
                .disabled(viewModel.trimmedDomain.isEmpty)
            } else {
                if FeatureAccessService.hasAccess(to: .batchOperations) {
                    VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
                        Text("Paste domains separated by new lines or commas.")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ThemeToken.textSecondary)

                        if let batchAllowanceSummary = FeatureAccessService.batchAllowanceSummary() {
                            Text(batchAllowanceSummary)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(ThemeToken.textSecondary)
                        }

                        TextField(
                            "example.com\napple.com, openai.com",
                            text: $viewModel.bulkInput,
                            axis: .vertical
                        )
                        .font(appDensity.font(.body))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(4...10)
                        .padding(.horizontal, 12)
                        .padding(.vertical, appDensity.metrics.controlVerticalPadding)
                        .background(ThemeToken.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                        .focused($focusedInputField, equals: .bulkDomains)

                        if let bulkInputError = viewModel.bulkInputError {
                            Text(bulkInputError)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(ThemeToken.critical)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            focusedInputField = nil
                            viewModel.runBulkLookup()
                        } label: {
                            Text(viewModel.batchLookupRunning ? "Running Batch…" : "Run Batch")
                                .font(appDensity.font(.headline, design: .default, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: appDensity.metrics.controlMinHeight)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ThemeToken.accent)
                        .disabled(viewModel.bulkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.batchLookupRunning)
                    }
                } else {
                    lockedFeatureCard(
                        title: "Batch Operations",
                        message: FeatureAccessService.upgradeMessage(for: .batchOperations)
                    )
                }
            }
        }
        .padding(.vertical, appDensity.metrics.sectionSpacing)
    }

    private var domainOverviewSection: some View {
        let trackedDomain = viewModel.currentTrackedDomain
        let workflows = viewModel.currentDomainWorkflows

        return DomainSectionView(
            isCollapsed: sectionCollapsedBinding(.domain),
            rows: viewModel.domainRows,
            suggestions: viewModel.suggestionRows,
            showSuggestions: viewModel.availabilityResult?.status == .registered || viewModel.suggestionsLoading,
            availabilityLoading: viewModel.availabilityLoading,
            suggestionsLoading: viewModel.suggestionsLoading,
            provenance: viewModel.currentSnapshot.provenanceBySection[.availability],
            confidence: viewModel.currentSnapshot.availabilityConfidence,
            snapshotNote: viewModel.currentSnapshot.note,
            trackedDomain: trackedDomain,
            workflows: workflows,
            trackingLimitMessage: viewModel.trackingLimitMessage,

            onTrack: {
                _ = viewModel.trackCurrentDomain()
            },
            onTogglePinned: {
                guard let trackedDomain else { return }
                viewModel.togglePinned(for: trackedDomain)
            },
            onEditNote: {
                guard let trackedDomain else { return }
                trackingNoteDraft = trackedDomain.note ?? ""
                editingTrackedDomain = trackedDomain
            },
            onAddToWorkflow: {
                showingCurrentDomainWorkflowSheet = true
            },
            onOpenWorkflow: { workflow in
                navigationPath.append(WorkflowNavigationTarget(workflowID: workflow.id))
            },
            onRunWorkflow: { workflow in
                viewModel.rerunCurrentDomain(in: workflow)
            }
        )
    }

    private func intelligenceSection(report: DomainReport) -> some View {
        IntelligenceSectionView(
            isCollapsed: sectionCollapsedBinding(.intelligence),
            report: report,
            showsPlaceholder: !FeatureAccessService.hasAccess(to: .intelligenceDetail)
        )
    }

    private var ownershipSection: some View {
        OwnershipSectionView(
            isCollapsed: sectionCollapsedBinding(.ownership),
            rows: viewModel.ownershipRows,
            loading: viewModel.ownershipLoading,
            error: viewModel.ownershipError,
            provenance: viewModel.currentSnapshot.provenanceBySection[.ownership],
            confidence: viewModel.currentSnapshot.ownershipConfidence,
            history: viewModel.ownershipHistory,
            historyLoading: viewModel.ownershipHistoryLoading,
            historyError: viewModel.ownershipHistoryError,
            onLoadHistory: {
                Task {
                    await viewModel.loadOwnershipHistory()
                }
            }
        )
    }

    private var subdomainsSection: some View {
        SubdomainsSectionView(
            isCollapsed: sectionCollapsedBinding(.subdomains),
            rows: viewModel.subdomainRows,
            groups: viewModel.currentSubdomainGroups,
            loading: viewModel.subdomainsLoading,
            error: viewModel.subdomainsError,
            provenance: viewModel.currentSnapshot.provenanceBySection[.subdomains],
            confidence: viewModel.currentSnapshot.subdomainConfidence,
            showsExtendedPlaceholder: !FeatureAccessService.hasAccess(to: .extendedSubdomains),
            extendedCount: viewModel.extendedSubdomains.count,
            extendedLoading: viewModel.extendedSubdomainsLoading,
            extendedError: viewModel.extendedSubdomainsError,
            onLoadExtended: {
                Task {
                    await viewModel.loadExtendedSubdomains()
                }
            }
        )
    }

    private var dnsSection: some View {
        DNSSectionView(
            isCollapsed: sectionCollapsedBinding(.dns),
            dnssecLabel: viewModel.dnssecLabel,
            patternSummary: viewModel.currentDNSPatterns,
            sections: viewModel.dnsRows,
            ptrMessage: viewModel.ptrMessage,
            loading: viewModel.dnsLoading || viewModel.ptrLoading,
            dnsProvenance: viewModel.currentSnapshot.provenanceBySection[.dns],
            ptrProvenance: viewModel.currentSnapshot.provenanceBySection[.ptr],
            sectionError: viewModel.dnsError,
            history: viewModel.dnsHistory,
            historyLoading: viewModel.dnsHistoryLoading,
            historyError: viewModel.dnsHistoryError,
            onLoadHistory: {
                Task {
                    await viewModel.loadDNSHistory()
                }
            }
        )
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            if viewModel.resultsLoaded {
                Menu {
                    if !viewModel.isCurrentDomainTracked {
                        Button("Track this domain") {
                            _ = viewModel.trackCurrentDomain()
                        }
                    }
                    Button("Add to workflow") {
                        showingCurrentDomainWorkflowSheet = true
                    }
                    Button(auditStartInFlight ? "Starting audit…" : "Start audit") {
                        Task {
                            auditStartInFlight = true
                            if await viewModel.startAudit(for: viewModel.searchedDomain) != nil {
                                showingAuditTimeline = true
                            }
                            auditStartInFlight = false
                        }
                    }
                    .disabled(auditStartInFlight)
                    if !viewModel.audits(for: viewModel.searchedDomain).isEmpty {
                        Button("View audits") {
                            showingAuditTimeline = true
                        }
                    }
                    if !viewModel.historyEntries(for: viewModel.searchedDomain).isEmpty {
                        Button("Open timeline") {
                            showingTimeline = true
                        }
                    }
                    if FeatureAccessService.hasAccess(to: .advancedExports) {
                        Button("Copy report JSON") {
                            guard let json = viewModel.exportJSONString() else { return }
                            AppClipboard.copy(json)
                            AppHaptics.copy()
                        }
                    } else {
                        Button("Copy report JSON") {
                            viewModel.upgradePrompt = FeatureAccessService.upgradePrompt(for: .advancedExports)
                        }
                    }
                    Button("Export report") {
                        shareSingleResults(format: .text)
                    }
                } label: {
                    Image(systemName: "bolt.circle")
                        .font(appDensity.font(.body, design: .default))
                        .foregroundStyle(ThemeToken.textSecondary)
                }
                .accessibilityLabel("Actions")
                Menu {
                    ExportFormatButtons(share: shareSingleResults)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(appDensity.font(.body, design: .default))
                        .foregroundStyle(ThemeToken.textSecondary)
                }
                .accessibilityLabel("Export")
            }
        }
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            HStack {
                Spacer()
                if viewModel.batchLookupRunning {
                    Button("Cancel") {
                        viewModel.cancelBatchLookup()
                    }
                    .buttonStyle(.bordered)
                    .font(appDensity.font(.caption))
                }
                if !viewModel.currentBatchResultEntries.isEmpty {
                    Menu {
                        Button("Add to Workflow") {
                            showingBatchWorkflowSheet = true
                        }
                        Divider()
                        ExportFormatButtons(share: shareBatchResults, batch: true)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(appDensity.font(.caption))
                    }
                    .buttonStyle(.bordered)
                }
            }

            BatchResultsView(
                viewModel: viewModel,
                title: viewModel.batchLookupSource == .watchlistRefresh ? "Tracked Domain Refresh" : "Batch Results"
            )
        }
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            HStack {
                Text("RECENT")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(ThemeToken.textSecondary)
                Spacer()
                Button("Clear") {
                    viewModel.clearRecentSearches()
                }
                .font(appDensity.font(.caption2))
                .foregroundStyle(ThemeToken.textSecondary)
            }

            ForEach(viewModel.recentSearches, id: \.self) { domain in
                Button {
                    viewModel.domain = domain
                    focusedInputField = nil
                    viewModel.run()
                } label: {
                    Text(domain)
                        .font(appDensity.font(.callout))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(ThemeToken.surface)
                        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                }
            }
        }
        .padding(.top, appDensity.metrics.cardSpacing)
    }

    private func runCustomPortScan() {
        let ports = parsedCustomPorts(from: customPortInput)
        Task {
            await viewModel.runCustomPortScan(ports: ports)
        }
    }

    private func lockedFeatureCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            Text(title)
                .font(appDensity.font(.headline, design: .default, weight: .semibold))
            Text(message)
                .font(appDensity.font(.callout, design: .default))
                .foregroundStyle(ThemeToken.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(appDensity.metrics.cardPadding)
        .background(ThemeToken.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }

    private func parsedCustomPorts(from input: String) -> [UInt16] {
        let parts = input.split(separator: ",", omittingEmptySubsequences: true)
        var seen = Set<UInt16>()
        var ports: [UInt16] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = UInt16(trimmed), seen.insert(value).inserted else {
                continue
            }
            ports.append(value)
            if ports.count == 20 {
                break
            }
        }

        return ports
    }

    private func shareSingleResults(format: DomainExportFormat) {
        guard let data = viewModel.exportSingleReportData(format: format) else { return }
        ExportPresenter.share(filename: exportFilename(prefix: "domaindig_single", format: format), data: data)
    }

    private func shareBatchResults(format: DomainExportFormat) {
        guard let data = viewModel.exportBatchReportData(format: format) else { return }
        ExportPresenter.share(filename: exportFilename(prefix: "domaindig_batch", format: format), data: data)
    }

    private func exportFilename(prefix: String, format: DomainExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(timestamp)_\(prefix).\(format.fileExtension)"
    }

    private var defaultCollapsedSections: Set<ResultSection> {
        []
    }

    private var currentPrimaryIP: String? {
        viewModel.currentSnapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    private var resultStatusMessage: String? {
        if let currentStatusMessage = viewModel.currentStatusMessage {
            return currentStatusMessage
        }

        if viewModel.currentResultSource != .live {
            return viewModel.currentResultSource.label
        }

        return nil
    }

    private func sectionCollapsedBinding(_ section: ResultSection) -> Binding<Bool> {
        Binding(
            get: { collapsedSections.contains(section) },
            set: { isCollapsed in
                if isCollapsed {
                    collapsedSections.insert(section)
                } else {
                    collapsedSections.remove(section)
                }
            }
        )
    }
}

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
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    inputSection
                    if !viewModel.batchResults.isEmpty || viewModel.batchLookupRunning {
                        batchSection
                            .padding(.top, appDensity.metrics.cardSpacing)
                    }
                    if viewModel.hasRun {
                        actionButtons
                        if !viewModel.resultsLoaded {
                            LookupProgressOverviewView(steps: viewModel.activeLoadingLabels)
                                .padding(.top, appDensity.metrics.cardSpacing)
                        } else if let statusMessage = resultStatusMessage {
                            LookupStatusBannerView(message: statusMessage, resultSource: viewModel.currentResultSource)
                                .padding(.top, appDensity.metrics.cardSpacing)
                        }
                        if viewModel.resultsLoaded {
                            SummaryView(fields: viewModel.summaryFields)
                                .padding(.top, appDensity.metrics.cardSpacing)
                            if let report = viewModel.currentReport {
                                RiskSummaryCardView(report: report)
                                    .padding(.top, appDensity.metrics.cardSpacing)
                                InsightsSummaryCardView(insights: report.insights)
                                    .padding(.top, appDensity.metrics.cardSpacing)
                            }
                            if let changeSummary = viewModel.currentChangeSummary {
                                DomainChangeSummaryView(summary: changeSummary)
                                    .padding(.top, appDensity.metrics.cardSpacing)
                            }
                        }
                        if let report = viewModel.currentReport {
                            intelligenceSection(report: report)
                                .padding(.top, appDensity.metrics.sectionSpacing)
                        }
                        domainOverviewSection
                            .padding(.top, appDensity.metrics.sectionSpacing)
                        ownershipSection
                        .padding(.top, appDensity.metrics.sectionSpacing)
                        subdomainsSection
                        .padding(.top, appDensity.metrics.sectionSpacing)
                        if !viewModel.currentDiffSections.isEmpty {
                            DomainDiffView(
                                title: "Latest Changes",
                                sections: viewModel.currentDiffSections,
                                contextNote: viewModel.currentChangeSummary?.contextNote,
                                showsUnchanged: false,
                                highlightedSectionID: nil
                            )
                            .padding(.top, appDensity.metrics.sectionSpacing)
                        }
                        dnsSection
                        .padding(.top, appDensity.metrics.sectionSpacing)
                        WebSectionView(
                            isCollapsed: sectionCollapsedBinding(.web),
                            certificateRows: viewModel.webCertificateRows,
                            sslInfo: viewModel.sslInfo,
                            tlsSummary: viewModel.currentTLSSummary,
                            sslLoading: viewModel.sslLoading || viewModel.hstsLoading,
                            sslError: viewModel.sslError,
                            tlsProvenance: viewModel.currentSnapshot.provenanceBySection[.ssl],
                            responseRows: viewModel.webResponseRows,
                            headers: viewModel.httpHeaders,
                            headersLoading: viewModel.httpHeadersLoading,
                            headersError: viewModel.httpHeadersError,
                            httpProvenance: viewModel.currentSnapshot.provenanceBySection[.httpHeaders],
                            redirects: viewModel.redirectRows,
                            redirectLoading: viewModel.redirectChainLoading,
                            redirectError: viewModel.redirectChainError,
                            redirectProvenance: viewModel.currentSnapshot.provenanceBySection[.redirectChain],
                            finalURL: viewModel.currentSnapshot.redirectChain.last?.url
                        )
                        .padding(.top, appDensity.metrics.sectionSpacing)
                        EmailSectionView(
                            isCollapsed: sectionCollapsedBinding(.email),
                            rows: viewModel.emailRows,
                            assessment: viewModel.currentEmailAssessment,
                            loading: viewModel.emailSecurityLoading,
                            provenance: viewModel.currentSnapshot.provenanceBySection[.emailSecurity],
                            confidence: viewModel.currentSnapshot.emailSecurityConfidence,
                            error: viewModel.emailSecurityError
                        )
                        .padding(.top, appDensity.metrics.sectionSpacing)
                        NetworkSectionView(
                            isCollapsed: sectionCollapsedBinding(.network),
                            reachabilityRows: viewModel.reachabilityRows,
                            reachabilityLoading: viewModel.reachabilityLoading,
                            reachabilityError: viewModel.reachabilityError,
                            reachabilityProvenance: viewModel.currentSnapshot.provenanceBySection[.reachability],
                            locationRows: viewModel.locationRows,
                            geolocation: viewModel.ipGeolocation,
                            geolocationLoading: viewModel.ipGeolocationLoading,
                            geolocationError: viewModel.ipGeolocationError,
                            geolocationProvenance: viewModel.currentSnapshot.provenanceBySection[.ipGeolocation],
                            geolocationConfidence: viewModel.currentSnapshot.geolocationConfidence,
                            standardPortRows: viewModel.standardPortRows,
                            customPortRows: viewModel.customPortRows,
                            portScanLoading: viewModel.portScanLoading,
                            portScanError: viewModel.portScanError,
                            portScanProvenance: viewModel.currentSnapshot.provenanceBySection[.portScan],
                            customPortScanLoading: viewModel.customPortScanLoading,
                            customPortScanError: viewModel.customPortScanError,
                            isCloudflareProxied: viewModel.isCloudflareProxied,
                            customPortsExpanded: $customPortsExpanded,
                            customPortInput: $customPortInput,
                            onScanCustomPorts: runCustomPortScan
                        )
                        .padding(.top, appDensity.metrics.sectionSpacing)
                    } else if !viewModel.recentSearches.isEmpty {
                        recentSearchesSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(
                LinearGradient(
                    colors: [Color(.appBackground), Color(.appSurface)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .navigationTitle("DomainDig")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.hasRun {
                        Button {
                            viewModel.reset()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                        .accessibilityLabel("Clear results")
                    }
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
                    .background(Color(.appSurfaceElevated))
                    .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                    .focused($focusedInputField, equals: .singleDomain)
                    .onSubmit {
                        focusedInputField = nil
                        viewModel.run()
                    }

                if let domainInputError = viewModel.domainInputError {
                    Text(domainInputError)
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.statusCritical))
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
                .tint(Color(.accentFill))
                .disabled(viewModel.trimmedDomain.isEmpty)
            } else {
                if FeatureAccessService.hasAccess(to: .batchOperations) {
                    VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
                        Text("Paste domains separated by new lines or commas.")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))

                        if let batchAllowanceSummary = FeatureAccessService.batchAllowanceSummary() {
                            Text(batchAllowanceSummary)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.appTextSecondary))
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
                        .background(Color(.appSurfaceElevated))
                        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                        .focused($focusedInputField, equals: .bulkDomains)

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
                        .tint(Color(.accentFill))
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
                        .foregroundStyle(Color(.appTextSecondary))
                }
                .accessibilityLabel("Actions")
                Menu {
                    ExportFormatButtons(share: shareSingleResults)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(appDensity.font(.body, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
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
                    .foregroundStyle(Color(.appTextSecondary))
                Spacer()
                Button("Clear") {
                    viewModel.clearRecentSearches()
                }
                .font(appDensity.font(.caption2))
                .foregroundStyle(Color(.appTextSecondary))
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
                        .background(Color(.appSurface))
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
                .foregroundStyle(Color(.appTextSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(appDensity.metrics.cardPadding)
        .background(Color(.appSurfaceElevated))
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

struct SummaryView: View {
    @Environment(\.appDensity) private var appDensity
    let fields: [SummaryFieldViewData]

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Summary")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: appDensity.metrics.cardSpacing) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing) {
                        Text(field.label)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        Text(field.value)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ResultColors.color(for: field.tone))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: appDensity.metrics.rowMinHeight + 12, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(appDensity.metrics.cardPadding)
                    .background(Color(.appSurface))
                    .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                }
            }
        }
    }
}

struct RiskSummaryCardView: View {
    @Environment(\.appDensity) private var appDensity
    let report: DomainReport

    private var topFactors: [RiskFactor] {
        Array(report.riskAssessment.factors.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Risk")
            CardView(allowsHorizontalScroll: false) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.riskAssessment.score)")
                            .font(appDensity.font(.largeTitle, weight: .bold))
                            .foregroundStyle(levelColor)
                        Text(report.riskAssessment.level.title)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(levelColor)
                    }
                    Spacer()
                    Text("Deterministic")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                }

                if topFactors.isEmpty {
                    Text("No major risk factors identified")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(Array(topFactors.enumerated()), id: \.offset) { _, factor in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(factorColor(factor.impact))
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            Text(factor.description)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    private var levelColor: Color {
        switch report.riskAssessment.level {
        case .low:
            return Color(.statusPositive)
        case .medium:
            return Color(.statusWarning)
        case .high:
            return Color(.statusCritical)
        }
    }

    private func factorColor(_ impact: RiskImpact) -> Color {
        switch impact {
        case .positive:
            return Color(.statusPositive)
        case .neutral:
            return .secondary
        case .negative:
            return Color(.statusCritical)
        }
    }
}

struct InsightsSummaryCardView: View {
    @Environment(\.appDensity) private var appDensity
    let insights: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Insights")
            CardView(allowsHorizontalScroll: false) {
                if insights.isEmpty {
                    Text("No deterministic insights triggered")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.statusInfo))
                                .padding(.top, 2)
                            Text(insight)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }
}

struct StickyLookupSummaryView: View {
    @Environment(\.appDensity) private var appDensity

    let domain: String
    let availability: DomainAvailabilityStatus?
    let primaryIP: String?
    let sslInfo: SSLCertificateInfo?
    let sslError: String?
    let emailSecurity: EmailSecurityResult?
    let emailError: String?
    let changeSummary: DomainChangeSummary?

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
                HStack(alignment: .center, spacing: 10) {
                    Text(domain)
                        .font(appDensity.font(.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    AppCopyButton(value: domain, label: "Copy domain")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        AppStatusBadgeView(model: AppStatusFactory.availability(availability))
                        AppStatusBadgeView(model: AppStatusFactory.tls(sslInfo: sslInfo, error: sslError))
                        AppStatusBadgeView(model: AppStatusFactory.email(emailSecurity, error: emailError))
                        AppStatusBadgeView(model: AppStatusFactory.change(changeSummary))
                    }
                }

                if let primaryIP {
                    HStack(spacing: 8) {
                        Label(primaryIP, systemImage: "network")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))
                        Spacer(minLength: 6)
                        AppCopyButton(value: primaryIP, label: "Copy IP")
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

struct LookupProgressOverviewView: View {
    @Environment(\.appDensity) private var appDensity
    let steps: [String]

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running lookup…")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(.primary)
                    Text(steps.isEmpty ? "Preparing requests" : steps.joined(separator: " • "))
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                }
                Spacer()
            }
        }
    }
}

struct LookupStatusBannerView: View {
    @Environment(\.appDensity) private var appDensity
    let message: String
    let resultSource: LookupResultSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
            Text(message)
                .font(appDensity.font(.caption))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(appDensity.metrics.cardPadding - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }

    private var color: Color {
        switch resultSource {
        case .live:
            return Color(.statusPositive)
        case .cached:
            return .secondary
        case .mixed:
            return Color(.statusWarning)
        case .snapshot:
            return Color(.statusWarning)
        }
    }

    private var iconName: String {
        switch resultSource {
        case .live:
            return "bolt.horizontal"
        case .cached:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .mixed:
            return "arrow.triangle.branch"
        case .snapshot:
            return "archivebox"
        }
    }
}

struct DomainChangeSummaryView: View {
    @Environment(\.appDensity) private var appDensity
    let summary: DomainChangeSummary
    @State private var showsDetails = false

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            HStack {
                Label(summary.hasChanges ? "Changed" : "Stable", systemImage: summary.hasChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(appDensity.font(.caption))
                    .foregroundStyle(summary.hasChanges ? severityTone(summary.severity).foreground : Color(.statusPositive))
                Spacer()
                Text(summary.severity.title.uppercased())
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(summary.hasChanges ? severityTone(summary.severity).foreground : Color(.appTextSecondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((summary.hasChanges ? severityTone(summary.severity) : AppStatusTone.neutral).surface)
                    .clipShape(Capsule())
                Text(summary.impactClassification.title.uppercased())
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(summary.impactClassification.tone.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(summary.impactClassification.tone.surface)
                    .clipShape(Capsule())
                Text(summary.generatedAt, style: .time)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Inference")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
                Text(summary.message)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if !summary.observedFacts.isEmpty || summary.contextNote != nil {
                DisclosureGroup(showsDetails ? "Hide Details" : "Show Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !summary.observedFacts.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Observed")
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(Color(.appTextSecondary))
                                ForEach(Array(summary.observedFacts.enumerated()), id: \.offset) { _, fact in
                                    Text(fact)
                                        .font(appDensity.font(.caption))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }

                        if let riskScoreDelta = summary.riskScoreDelta {
                            Text("Risk delta: \(riskScoreDelta >= 0 ? "+" : "")\(riskScoreDelta)")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(riskScoreDelta > 0 ? Color(.statusWarning) : .secondary)
                        }

                        if let contextNote = summary.contextNote {
                            Text(contextNote)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.statusWarning))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(appDensity.font(.caption))
                .tint(.secondary)
            }
        }
    }

    private func severityTone(_ severity: ChangeSeverity) -> AppStatusTone {
        switch severity {
        case .low:
            return .neutral
        case .medium:
            return .warning
        case .high:
            return .critical
        }
    }

}

struct DomainDiffView: View {
    let title: String
    let sections: [DomainDiffSection]
    let contextNote: String?
    let showsUnchanged: Bool
    let highlightedSectionID: String?

    @State private var collapsedSections = Set<String>()
    @State private var showsLowSeverity = false

    private var filteredSections: [DomainDiffSection] {
        sections
            .map { section in
                let items = section.items.filter { item in
                    if !showsUnchanged, !item.hasChanges {
                        return false
                    }
                    if showsLowSeverity {
                        return true
                    }
                    return item.severity >= .medium || (showsUnchanged && item.changeType == .unchanged)
                }
                return DomainDiffSection(id: section.id, title: section.title, items: items)
            }
            .filter { !$0.items.isEmpty }
    }

    private var hasLowSeverityChanges: Bool {
        sections.flatMap(\.items).contains { $0.hasChanges && $0.severity == .low }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitleView(title: title)
                Spacer()
                if hasLowSeverityChanges {
                    Button(showsLowSeverity ? "Hide Low" : "Show Low") {
                        showsLowSeverity.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(.caption, design: .monospaced))
                }
            }
            if let contextNote {
                MessageCardView(text: contextNote, isError: false)
            }
            if filteredSections.isEmpty {
                MessageCardView(text: "No comparison data available", isError: false)
            } else {
                ForEach(filteredSections) { section in
                    CardView(allowsHorizontalScroll: false) {
                        DisclosureGroup(isExpanded: binding(for: section)) {
                            let visibleItems = showsUnchanged ? section.items : section.items.filter(\.hasChanges)

                            ForEach(visibleItems) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.label)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(Color(.appTextSecondary))
                                        Spacer()
                                        Text("\(item.changeType.marker) \(item.severity.title) • \(changeLabel(for: item.changeType))")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(changeTone(for: item).foreground)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(changeTone(for: item).surface)
                                            .clipShape(Capsule())
                                    }

                                    if let oldValue = item.oldValue {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Old")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                            Text(oldValue)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                                .textSelection(.enabled)
                                        }
                                    }

                                    if let newValue = item.newValue {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("New")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                            Text(newValue)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(item.hasChanges ? .primary : .secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(item.hasChanges ? changeTone(for: item).surface : Color(.appSurface))
                                .cornerRadius(8)
                            }
                        } label: {
                            HStack {
                                Text(section.title)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(sectionColor(section))
                                Spacer()
                                Text(section.severity.title)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(sectionColor(section))
                            }
                        }
                    }
                    .id(section.id)
                    .overlay {
                        if highlightedSectionID == section.id {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.statusInfo).opacity(0.55), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .onAppear {
            collapsedSections = Set(sections.filter { !showsUnchanged && !$0.hasChanges }.map(\.id))
        }
    }

    private func changeLabel(for changeType: DiffChangeType) -> String {
        switch changeType {
        case .added:
            return "Added"
        case .removed:
            return "Removed"
        case .changed:
            return "Changed"
        case .unchanged:
            return "Unchanged"
        }
    }

    private func changeTone(for item: DomainDiffItem) -> AppStatusTone {
        if item.changeType == .unchanged {
            return .neutral
        }

        switch item.severity {
        case .low:
            return .info
        case .medium:
            return .warning
        case .high:
            return .critical
        }
    }

    private func sectionColor(_ section: DomainDiffSection) -> Color {
        switch section.severity {
        case .low:
            return .blue
        case .medium:
            return Color(.statusWarning)
        case .high:
            return Color(.statusCritical)
        }
    }

    private func binding(for section: DomainDiffSection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(section.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSections.remove(section.id)
                } else {
                    collapsedSections.insert(section.id)
                }
            }
        )
    }
}

struct TrackedDomainDetailHeaderView: View {
    let trackedDomain: TrackedDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = trackedDomain.note?.nilIfEmpty {
                LabeledValueRow(row: InfoRowViewData(label: "Tracking Note", value: note, tone: .secondary))
            }
            HStack(spacing: 8) {
                if trackedDomain.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                }
                Text("Last refresh \(trackedDomain.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(Color(.appTextSecondary))
        }
    }
}

struct SectionTitleView: View {
    @Environment(\.appDensity) private var appDensity
    let title: String

    var body: some View {
        Text(title)
            .font(appDensity.font(.headline, design: .default, weight: .semibold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A card that wraps its content by default.
///
/// `allowsHorizontalScroll` used to default to `true`, so nine call sites put
/// their content behind a horizontal gesture instead of letting it wrap — a
/// WCAG 1.4.10 (Reflow) failure, and the mechanism behind clipped rows at large
/// text sizes. It also forced VoiceOver and Switch Control users onto a nested
/// scroll axis to reach data.
///
/// The default is now `false`. Where horizontal scrolling genuinely suits wide
/// tabular content, it is still opt-in — but it is suppressed at accessibility
/// text sizes, where wrapping always beats a hidden axis.
struct CardView<Content: View>: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let allowsHorizontalScroll: Bool
    let content: Content

    init(allowsHorizontalScroll: Bool = false, @ViewBuilder content: () -> Content) {
        self.allowsHorizontalScroll = allowsHorizontalScroll
        self.content = content()
    }

    var body: some View {
        Group {
            if allowsHorizontalScroll, !dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    cardContent
                        .scrollTargetLayout()
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                cardContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(appDensity.metrics.cardPadding)
        .background(Color(.appSurface))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            content
        }
    }
}

struct LoadingCardView: View {
    let text: String

    var body: some View {
        CardView {
            ProgressView(text)
                .appLoadingStyle()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct MessageCardView: View {
    let text: String
    let isError: Bool

    var body: some View {
        CardView {
            MessageRowView(text: text, isError: isError)
        }
    }
}

struct MessageRowView: View {
    @Environment(\.appDensity) private var appDensity
    let text: String
    let isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(appDensity.font(.caption))
            .foregroundStyle(isError ? Color(.statusCritical) : .secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionTrustMetadataView: View {
    @Environment(\.appDensity) private var appDensity
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let note: String?

    init(provenance: SectionProvenance?, confidence: ConfidenceLevel?, note: String? = nil) {
        self.provenance = provenance
        self.confidence = confidence
        self.note = note
    }

    var body: some View {
        if provenance != nil || confidence != nil || note != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let confidence {
                        Text("Confidence \(confidence.title)")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                    if let provenance {
                        Text(provenance.provider ?? provenance.source)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        Text(provenance.resultSource.label)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let provenance {
                            LabeledValueRow(row: .init(label: "Method", value: provenance.source, tone: .secondary))
                            if let provider = provenance.provider {
                                LabeledValueRow(row: .init(label: "Provider", value: provider, tone: .secondary))
                            }
                            if let resolver = provenance.resolver {
                                LabeledValueRow(row: .init(label: "Resolver", value: resolver, tone: .secondary))
                            }
                            LabeledValueRow(row: .init(label: "Collected", value: provenance.collectedAt.formatted(date: .abbreviated, time: .shortened), tone: .secondary))
                            LabeledValueRow(row: .init(label: "Mode", value: provenance.resultSource.label, tone: .secondary))
                        }
                        if let note {
                            LabeledValueRow(row: .init(label: "Note", value: note, tone: .secondary))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(appDensity.font(.caption))
                .tint(.secondary)
            }
        }
    }
}

struct LabeledValueRow: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let row: InfoRowViewData

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing - 1) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing - 1) {
                    Text(row.label)
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if differentiateWithoutColor, let symbol = toneSymbol {
                            Image(systemName: symbol)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(ResultColors.color(for: row.tone))
                                .accessibilityHidden(true)
                        }
                        valueText
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 6)
                if !row.value.isEmpty, row.value != "Unavailable" {
                    AppCopyButton(value: row.value, label: "Copy \(row.label)")
                }
            }
        }
        .frame(minHeight: appDensity.metrics.rowMinHeight, alignment: .topLeading)
    }

    /// A leading symbol for warning/failure tones, shown only under Differentiate
    /// Without Color so tone is not conveyed by text colour alone. Hidden from
    /// VoiceOver — the value text already carries the meaning.
    private var toneSymbol: String? {
        switch row.tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        default: return nil
        }
    }

    @ViewBuilder
    private var valueText: some View {
        let base = Text(row.value)
            .font(appDensity.font(.caption))
            .foregroundStyle(ResultColors.color(for: row.tone))

        switch row.speechStyle {
        case .plain:
            base
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .technical:
            // Record values and identifiers: keep punctuation audible (SPF/DMARC
            // separators are semantically load-bearing) and let VoiceOver use its
            // code-reading heuristics.
            base
                .speechAlwaysIncludesPunctuation()
                .accessibilityTextContentType(.sourceCode)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Maps a row's semantic tone onto the app palette.
///
/// See `Docs/ACCESSIBILITY.md` for the measured contrast ratios behind these
/// colours. Never reach for a literal (`Color(.statusCritical)`, `Color(.statusWarning)`, …) — the system
/// palette fails WCAG AA badly in light mode (systemYellow is 1.28:1 on white).
enum ResultColors {
    static func color(for tone: ResultTone) -> Color {
        switch tone {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .success:
            return Color(.statusPositive)
        case .warning:
            return Color(.statusWarning)
        case .failure:
            return Color(.statusCritical)
        }
    }
}

extension DateFormatter {
    static let certDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension View {
    func appLoadingStyle() -> some View {
        font(.system(.caption, design: .monospaced))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension ChangeImpactClassification {
    var tone: AppStatusTone {
        switch self {
        case .informational: return .neutral
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

extension TLSGrade {
    var tone: ResultTone {
        switch self {
        case .a: return .success
        case .f: return .failure
        default: return .warning
        }
    }
}

extension EmailSecurityGrade {
    var tone: ResultTone {
        switch self {
        case .a: return .success
        case .f: return .failure
        default: return .warning
        }
    }
}

#Preview {
    ContentView(viewModel: DomainViewModel())
}

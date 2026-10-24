import SwiftUI

private enum WorkflowDestinationMode: String, CaseIterable, Identifiable {
    case existing
    case new

    var id: String { rawValue }
}

struct WorkflowsView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @State private var purchaseService = PurchaseService.shared

    @State private var showingCreateWorkflow = false

    var body: some View {
        let _ = purchaseService.currentTier

        List {
            if let limitMessage = FeatureAccessService.workflowAllowanceSummary(currentCount: viewModel.workflows.count) {
                Section {
                    Text(limitMessage)
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                }
                .listRowBackground(Color(.appSurface))
            }

            workflowContent
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .refreshable {
            await viewModel.refreshWorkflowList()
        }
        .navigationTitle("Workflows")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingCreateWorkflow = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Create workflow")

                if !viewModel.workflows.isEmpty {
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showingCreateWorkflow) {
            WorkflowComposerView(viewModel: viewModel)
        }
        .sheet(item: workflowSummaryBinding) { summary in
            WorkflowRunSummaryView(viewModel: viewModel, summary: summary)
        }
    }

    private var workflowSummaryBinding: Binding<WorkflowRunSummary?> {
        Binding(
            get: { viewModel.latestWorkflowRunSummary },
            set: { viewModel.latestWorkflowRunSummary = $0 }
        )
    }

    @ViewBuilder
    private var workflowContent: some View {
        if viewModel.batchLookupSource == .workflow, (!viewModel.batchResults.isEmpty || viewModel.batchLookupRunning) {
            Section("Workflow Run") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(
                        value: Double(viewModel.batchCompletedCount),
                        total: Double(max(viewModel.batchTotalCount, 1))
                    )
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
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color(.appSurface))
        }

        if viewModel.workflows.isEmpty {
            Section {
                EmptyStateCardView(
                    title: "No Workflows Yet",
                    message: "Workflows save a reusable set of domains so repeat inspections take one tap instead of rebuilding the same batch each time.",
                    suggestion: "Create a workflow for a weekly audit set, customer domains, or a monitoring group.",
                    systemImage: "square.stack.3d.down.right",
                    showsCardBackground: false
                )
            }
            .listRowBackground(Color(.appSurface))
        } else {
            ForEach(viewModel.workflows) { workflow in
                NavigationLink {
                    WorkflowDetailView(viewModel: viewModel, workflowID: workflow.id)
                } label: {
                    WorkflowRowView(workflow: workflow)
                }
                .listRowBackground(Color(.appSurface))
            }
            .onDelete { offsets in
                let workflows = offsets.map { viewModel.workflows[$0] }
                workflows.forEach(viewModel.deleteWorkflow)
            }
        }
    }
}

private struct WorkflowRowView: View {
    @Environment(\.appDensity) private var appDensity

    let workflow: DomainWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if workflow.collaboration?.isShared == true {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(.statusInfo))
                        .accessibilityLabel("Shared")
                }
                Text(workflow.name)
                    .font(appDensity.font(.callout, design: .default, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(workflow.domains.count) domains")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            Text("Updated \(workflow.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(appDensity.font(.caption2))
                .foregroundStyle(Color(.appTextSecondary))

            if let collaboration = workflow.collaboration, collaboration.isShared {
                Text("\(collaboration.ownership.title) • \(collaboration.permission.title)")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            if let notes = workflow.notes, !notes.isEmpty {
                Text(notes)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(Color(.appTextSecondary))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct WorkflowDetailView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let workflowID: UUID

    @State private var showingEditor = false
    @State private var draftDomain = ""
    @State private var includeAllExports = false
    @State private var shareEntity: ShareableEntity?

    private var workflow: DomainWorkflow? {
        viewModel.workflow(withID: workflowID)
    }

    private var latestSummary: WorkflowRunSummary? {
        guard viewModel.latestWorkflowRunSummary?.workflowID == workflowID else { return nil }
        return viewModel.latestWorkflowRunSummary
    }

    var body: some View {
        Group {
            if let workflow {
                List {
                    Section("Overview") {
                        statRow(label: "Domains", value: "\(workflow.domains.count)")
                        statRow(label: "Created", value: workflow.createdAt.formatted(date: .abbreviated, time: .shortened))
                        statRow(label: "Updated", value: workflow.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        if let notes = workflow.notes, !notes.isEmpty {
                            Text(notes)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                        if let collaboration = workflow.collaboration, collaboration.isShared {
                            Text("\(collaboration.ownership.title) • \(collaboration.permission.title)")
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                    }

                    Section("Actions") {
                        Button {
                            viewModel.runWorkflow(workflow)
                        } label: {
                            Label("Run Workflow", systemImage: "play.fill")
                        }
                        .disabled(workflow.domains.isEmpty || viewModel.batchLookupRunning)

                        if viewModel.batchLookupRunning, viewModel.batchLookupSource == .workflow {
                            Button("Cancel Workflow Run", role: .destructive) {
                                viewModel.cancelBatchLookup()
                            }
                        }

                        Button {
                            showingEditor = true
                        } label: {
                            Label("Edit Workflow", systemImage: "pencil")
                        }
                        .disabled(!viewModel.canEdit(workflow))

                        Button {
                            guard workflow.collaboration?.isShared == true
                                || FeatureAccessService.hasAccess(to: .sharedPortfolios) else {
                                viewModel.upgradePrompt = FeatureAccessService.upgradePrompt(for: .sharedPortfolios)
                                return
                            }
                            shareEntity = .workflow(workflow.id)
                        } label: {
                            Label(workflow.collaboration?.isShared == true ? "Manage Share" : "Share Workflow", systemImage: "person.2")
                        }

                        if latestSummary != nil {
                            Toggle("Export all domains", isOn: $includeAllExports)
                            Menu {
                                ExportFormatButtons(share: shareWorkflowResults)
                            } label: {
                                Label("Export Results", systemImage: "square.and.arrow.up")
                            }
                        }
                    }

                    if let latestSummary {
                        Section("Latest Run") {
                            statRow(label: "Processed", value: "\(latestSummary.totalDomains)")
                            statRow(label: "Changed", value: "\(latestSummary.changedDomains)")
                            statRow(label: "Warnings", value: "\(latestSummary.warningDomains)")
                            statRow(label: "Unchanged", value: "\(latestSummary.unchangedDomains)")
                            if !latestSummary.workflowInsights.isEmpty {
                                Text(latestSummary.workflowInsights[0].description)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(Color(.appTextSecondary))
                            }

                            Button {
                                viewModel.latestWorkflowRunSummary = latestSummary
                            } label: {
                                Label("View Run Summary", systemImage: "list.bullet.rectangle")
                            }
                        }
                    }

                    Section("Add Domain") {
                        HStack {
                            TextField("example.com", text: $draftDomain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Add") {
                                guard !draftDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                viewModel.addDomains([draftDomain], to: workflow)
                                draftDomain = ""
                            }
                            .disabled(!viewModel.canEdit(workflow))
                        }
                    }

                    Section("Domains") {
                        if workflow.domains.isEmpty {
                            Text("No domains in this workflow")
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))
                        } else {
                            ForEach(workflow.domains, id: \.self) { domain in
                                Button {
                                    viewModel.openInspection(for: domain)
                                } label: {
                                    HStack {
                                        Text(domain)
                                            .font(appDensity.font(.callout))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.right.circle")
                                            .foregroundStyle(Color(.appTextSecondary))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                guard viewModel.canEdit(workflow) else { return }
                                viewModel.removeWorkflowDomains(at: offsets, from: workflow)
                            }
                            .onMove { offsets, destination in
                                guard viewModel.canEdit(workflow) else { return }
                                viewModel.moveWorkflowDomains(from: offsets, to: destination, in: workflow)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(.appBackground))
                .navigationTitle(workflow.name)
                .toolbar {
                    if !workflow.domains.isEmpty {
                        EditButton()
                            .disabled(!viewModel.canEdit(workflow))
                    }
                }
                .sheet(isPresented: $showingEditor) {
                    WorkflowComposerView(viewModel: viewModel, workflow: workflow)
                }
                .sheet(item: workflowSummaryBinding) { summary in
                    WorkflowRunSummaryView(viewModel: viewModel, summary: summary)
                }
                .sheet(item: $shareEntity) { entity in
                    CloudSharingSheet(entity: entity, title: workflow.name)
                }
            } else {
                Text("Workflow not found")
                    .font(appDensity.font(.callout))
                    .foregroundStyle(Color(.appTextSecondary))
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(appDensity.font(.caption))
                .foregroundStyle(Color(.appTextSecondary))
            Spacer()
            Text(value)
                .font(appDensity.font(.callout))
                .foregroundStyle(.primary)
        }
    }

    private var workflowSummaryBinding: Binding<WorkflowRunSummary?> {
        Binding(
            get: {
                guard viewModel.latestWorkflowRunSummary?.workflowID == workflowID else { return nil }
                return viewModel.latestWorkflowRunSummary
            },
            set: { _ in
                viewModel.latestWorkflowRunSummary = nil
            }
        )
    }

    private func shareWorkflowResults(format: DomainExportFormat) {
        guard let latestSummary else { return }

        let changedOnly = !includeAllExports
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)_workflow_\(latestSummary.workflowName.replacingOccurrences(of: " ", with: "_").lowercased()).\(format.fileExtension)"
        guard let data = viewModel.exportWorkflowData(summary: latestSummary, changedOnly: changedOnly, format: format) else {
            return
        }

        ExportPresenter.share(filename: filename, data: data)
    }
}

struct WorkflowComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: DomainViewModel
    let workflow: DomainWorkflow?

    @State private var name = ""
    @State private var domainsText = ""
    @State private var notes = ""

    init(viewModel: DomainViewModel, workflow: DomainWorkflow? = nil) {
        self.viewModel = viewModel
        self.workflow = workflow
        _name = State(initialValue: workflow?.name ?? "")
        _domainsText = State(initialValue: workflow?.domains.joined(separator: "\n") ?? "")
        _notes = State(initialValue: workflow?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workflow") {
                    TextField("Name", text: $name)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Domains") {
                    TextField("example.com\napple.com", text: $domainsText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(6...14)
                }
            }
            .navigationTitle(workflow == nil ? "New Workflow" : "Edit Workflow")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWorkflow()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedDomains.isEmpty)
                }
            }
        }
    }

    private var parsedDomains: [String] {
        domainsText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveWorkflow() {
        if let workflow {
            viewModel.updateWorkflow(workflow, name: name, domains: parsedDomains, notes: notes)
            dismiss()
            return
        }

        if viewModel.createWorkflow(name: name, domains: parsedDomains, notes: notes) != nil {
            dismiss()
        }
    }
}

struct WorkflowRunSummaryView: View {
    @Bindable var viewModel: DomainViewModel
    let summary: WorkflowRunSummary

    @State private var showAllResults = false

    private var visibleResults: [BatchLookupResult] {
        showAllResults ? summary.results : summary.results.filter(\.hasMeaningfulChange)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Overview") {
                    statRow(label: "Workflow", value: summary.workflowName)
                    statRow(label: "Processed", value: "\(summary.totalDomains)")
                    statRow(label: "Changed", value: "\(summary.changedDomains)")
                    statRow(label: "Warnings", value: "\(summary.warningDomains)")
                    statRow(label: "Unchanged", value: "\(summary.unchangedDomains)")
                    statRow(label: "Finished", value: summary.generatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    Toggle("Show unchanged domains", isOn: $showAllResults)
                }

                if !summary.workflowInsights.isEmpty {
                    Section("Workflow Insights") {
                        ForEach(summary.workflowInsights) { insight in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(insight.description)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(insight.domainsInvolved.joined(separator: ", "))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color(.appTextSecondary))
                            }
                        }
                    }
                }

                BatchResultsSection(
                    viewModel: viewModel,
                    results: visibleResults,
                    emptyTitle: "Meaningful Changes",
                    emptyText: "No domains with meaningful changes or warnings"
                )
            }
            .navigationTitle("Workflow Summary")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        ExportFormatButtons(share: share)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export summary")

                    if let workflow = viewModel.workflow(withID: summary.workflowID) {
                        Button {
                            viewModel.runWorkflow(workflow)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Re-run workflow")
                        .disabled(viewModel.batchLookupRunning)
                    }
                }
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(.appTextSecondary))
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func share(format: DomainExportFormat) {
        let changedOnly = !showAllResults
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)_workflow_summary.\(format.fileExtension)"
        guard let data = viewModel.exportWorkflowData(summary: summary, changedOnly: changedOnly, format: format) else {
            return
        }

        ExportPresenter.share(filename: filename, data: data)
    }
}

struct WorkflowBulkAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: DomainViewModel
    let title: String
    let availableDomains: [String]

    @State private var mode: WorkflowDestinationMode = .existing
    @State private var selectedDomains: Set<String>
    @State private var selectedWorkflowID: UUID?
    @State private var newWorkflowName = ""
    @State private var newWorkflowNotes = ""

    init(viewModel: DomainViewModel, title: String, availableDomains: [String]) {
        self.viewModel = viewModel
        self.title = title
        self.availableDomains = Array(Set(availableDomains)).sorted()
        _selectedDomains = State(initialValue: Set(availableDomains))
        _selectedWorkflowID = State(initialValue: viewModel.workflows.first?.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Selection") {
                    ForEach(availableDomains, id: \.self) { domain in
                        Button {
                            toggle(domain)
                        } label: {
                            HStack {
                                Text(domain)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedDomains.contains(domain) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedDomains.contains(domain) ? Color(.statusInfo) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedDomains.contains(domain) ? .isSelected : [])
                    }
                }

                Section("Destination") {
                    Picker("Destination", selection: $mode) {
                        Text("Existing").tag(WorkflowDestinationMode.existing)
                        Text("New").tag(WorkflowDestinationMode.new)
                    }
                    .pickerStyle(.segmented)

                    if mode == .existing, !viewModel.workflows.isEmpty {
                        Picker("Workflow", selection: $selectedWorkflowID) {
                            ForEach(viewModel.workflows) { workflow in
                                Text(workflow.name).tag(Optional(workflow.id))
                            }
                        }
                    } else {
                        TextField("Workflow name", text: $newWorkflowName)
                        TextField("Notes", text: $newWorkflowNotes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if viewModel.workflows.isEmpty {
                    mode = .new
                }
            }
        }
    }

    private var selectedDomainList: [String] {
        availableDomains.filter { selectedDomains.contains($0) }
    }

    private var canSave: Bool {
        guard !selectedDomainList.isEmpty else { return false }
        switch mode {
        case .existing:
            return selectedWorkflowID != nil
        case .new:
            return !newWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func toggle(_ domain: String) {
        if selectedDomains.contains(domain) {
            selectedDomains.remove(domain)
        } else {
            selectedDomains.insert(domain)
        }
    }

    private func save() {
        switch mode {
        case .existing:
            guard let selectedWorkflowID, let workflow = viewModel.workflow(withID: selectedWorkflowID) else { return }
            viewModel.addDomains(selectedDomainList, to: workflow)
            dismiss()
        case .new:
            guard viewModel.createWorkflow(name: newWorkflowName, domains: selectedDomainList, notes: newWorkflowNotes) != nil else {
                return
            }
            dismiss()
        }
    }
}

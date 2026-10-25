import SwiftUI

struct AuditListView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @State private var auditStartInFlight = false

    private var groupedSessions: [(domain: String, sessions: [AuditSession])] {
        Dictionary(grouping: viewModel.auditSessions) { $0.domain.lowercased() }
            .values
            .map { sessions in
                let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
                return (domain: sorted.first?.domain ?? "unknown", sessions: sorted)
            }
            .sorted { $0.domain < $1.domain }
    }

    var body: some View {
        List {
            if groupedSessions.isEmpty {
                Section {
                    EmptyStateCardView(
                        title: "No Audits Yet",
                        message: "Audit Mode captures evidence, findings, checklist progress, and point-in-time review output for each domain assessment.",
                        suggestion: "Open Inspect for a domain and start an audit to create your first review session.",
                        systemImage: "checklist.unchecked",
                        showsCardBackground: false
                    )
                }
                .listRowBackground(Color(.appSurface))
            } else {
                Section("Audit Domains") {
                    ForEach(groupedSessions, id: \.domain) { group in
                        NavigationLink {
                            AuditDomainTimelineView(viewModel: viewModel, domain: group.domain)
                        } label: {
                            VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 2) {
                                HStack {
                                    Text(group.domain)
                                        .font(appDensity.font(.callout, design: .default, weight: .semibold))
                                    Spacer()
                                    Text("\(group.sessions.count) audit\(group.sessions.count == 1 ? "" : "s")")
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }

                                if let latest = group.sessions.first {
                                    Text(latest.findings.isEmpty ? "No findings recorded yet" : latest.findings.map(\.title).prefix(2).joined(separator: " • "))
                                        .font(appDensity.font(.caption))
                                        .foregroundStyle(Color(.appTextSecondary))
                                        .lineLimit(2)

                                    HStack(spacing: 8) {
                                        auditStatusBadge(latest.status)
                                        if let severity = latest.highestSeverity {
                                            findingSeverityBadge(severity)
                                        }
                                        Text("Checklist \(latest.completedChecklistCount)/\(latest.checklist.count)")
                                            .font(appDensity.font(.caption2))
                                            .foregroundStyle(Color(.appTextSecondary))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listRowBackground(Color(.appSurface))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle("Audit Mode")
        .toolbar {
            if !viewModel.searchedDomain.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(auditStartInFlight ? "Auditing…" : "Start Audit") {
                        Task {
                            auditStartInFlight = true
                            _ = await viewModel.startAudit(for: viewModel.searchedDomain)
                            auditStartInFlight = false
                        }
                    }
                    .disabled(auditStartInFlight)
                }
            }
        }
    }
}

struct AuditDomainTimelineView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let domain: String
    @State private var auditStartInFlight = false

    private var sessions: [AuditSession] {
        viewModel.audits(for: domain)
    }

    var body: some View {
        List {
            Section("Sessions") {
                ForEach(sessions) { session in
                    NavigationLink {
                        AuditSessionDetailView(viewModel: viewModel, sessionID: session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 2) {
                            HStack {
                                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(appDensity.font(.callout))
                                Spacer()
                                auditStatusBadge(session.status)
                            }

                            Text("Reviewer: \(session.reviewer)")
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))

                            HStack(spacing: 8) {
                                Text("\(session.findings.count) findings")
                                Text("Checklist \(session.completedChecklistCount)/\(session.checklist.count)")
                                if let severity = session.highestSeverity {
                                    Text("Top \(severity.title)")
                                }
                            }
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listRowBackground(Color(.appSurface))

            Section("Trend") {
                ForEach(viewModel.auditTimeline(for: domain)) { point in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(appDensity.font(.caption, weight: .semibold))
                            Spacer()
                            Text("\(point.findingCount) findings")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                        Text("Open high severity: \(point.openHighSeverityCount) • Repeated issues: \(point.repeatedIssueCount)")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listRowBackground(Color(.appSurface))
        }
        .scrollContentBackground(.hidden)
        .background(Color(.appBackground))
        .navigationTitle(domain)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(auditStartInFlight ? "Auditing…" : "New Audit") {
                    Task {
                        auditStartInFlight = true
                        _ = await viewModel.startAudit(for: domain)
                        auditStartInFlight = false
                    }
                }
                .disabled(auditStartInFlight)
            }
        }
    }
}

struct AuditSessionDetailView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let sessionID: UUID

    @State private var notesDraft = ""
    @State private var showingFindingEditor = false
    @State private var editingFinding: AuditFinding?

    private var session: AuditSession? {
        viewModel.auditSession(withID: sessionID)
    }

    var body: some View {
        Group {
            if let session {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.domain)
                                        .font(appDensity.font(.headline, design: .default, weight: .semibold))
                                    Text("Reviewer: \(session.reviewer)")
                                        .font(appDensity.font(.caption))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }
                                Spacer()
                                auditStatusBadge(session.status)
                            }

                            Picker("Status", selection: Binding(
                                get: { session.status },
                                set: { viewModel.updateAuditStatus($0, sessionID: session.id) }
                            )) {
                                ForEach(AuditStatus.allCases) { status in
                                    Text(status.title).tag(status)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text("Captured \(session.evidence.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                    }
                    .listRowBackground(Color(.appSurface))

                    Section("Audit Summary") {
                        LabeledContent("Findings", value: "\(session.findings.count)")
                        LabeledContent("Checklist", value: "\(session.completedChecklistCount)/\(session.checklist.count)")
                        LabeledContent("Risk Score", value: "\(session.evidence.report.riskAssessment.score)")
                        if let severity = session.highestSeverity {
                            LabeledContent("Highest Severity", value: severity.title)
                        }
                    }
                    .listRowBackground(Color(.appSurface))

                    Section("Reviewer Notes") {
                        TextEditor(text: $notesDraft)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)

                        Button("Save Notes") {
                            viewModel.updateAuditNotes(notesDraft, sessionID: session.id)
                        }
                    }
                    .listRowBackground(Color(.appSurface))

                    Section("Checklist") {
                        ForEach(session.checklist) { item in
                            Button {
                                viewModel.toggleAuditChecklistItem(sessionID: session.id, itemID: item.id)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.isComplete ? Color(.statusPositive) : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(appDensity.font(.callout))
                                            .foregroundStyle(.primary)
                                        Text(item.detail)
                                            .font(appDensity.font(.caption))
                                            .foregroundStyle(Color(.appTextSecondary))
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(item.isComplete ? .isSelected : [])
                            .accessibilityHint(item.isComplete ? "Marks incomplete" : "Marks complete")
                        }
                    }
                    .listRowBackground(Color(.appSurface))

                    Section("Findings") {
                        if session.findings.isEmpty {
                            Text("No findings recorded.")
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.appTextSecondary))
                        } else {
                            ForEach(session.findings) { finding in
                                Button {
                                    editingFinding = finding
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(finding.title)
                                                .font(appDensity.font(.callout, design: .default, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            findingSeverityBadge(finding.severity)
                                        }
                                        Text(finding.summary)
                                            .font(appDensity.font(.caption))
                                            .foregroundStyle(Color(.appTextSecondary))
                                            .lineLimit(2)
                                        Text("\(finding.status.title) • \(finding.evidenceReferences.count) evidence refs")
                                            .font(appDensity.font(.caption2))
                                            .foregroundStyle(Color(.appTextSecondary))
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                viewModel.removeAuditFindings(at: offsets, sessionID: session.id)
                            }
                        }
                    }
                    .listRowBackground(Color(.appSurface))

                    Section("Evidence Snapshot") {
                        LabeledContent("Availability", value: availabilityTitle(session.evidence.report.availability))
                        LabeledContent("Primary IP", value: session.evidence.report.dns.primaryIP ?? "Unavailable")
                        LabeledContent("TLS", value: session.evidence.report.web.tlsStatus)
                        LabeledContent("Final URL", value: session.evidence.report.web.finalURL ?? "Unavailable")
                        LabeledContent("Reachability", value: session.evidence.report.network.reachabilitySummary)
                        LabeledContent("Registrar", value: session.evidence.report.ownership?.registrar ?? "Unavailable")
                    }
                    .listRowBackground(Color(.appSurface))

                    if !session.evidence.historicalContext.isEmpty {
                        Section("Historical Context") {
                            ForEach(session.evidence.historicalContext) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(appDensity.font(.caption, weight: .semibold))
                                    Text(entry.changeSummaryMessage ?? "No change summary")
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }
                            }
                        }
                        .listRowBackground(Color(.appSurface))
                    }

                    Section("Audit Timeline") {
                        ForEach(viewModel.auditTimeline(for: session.domain)) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(appDensity.font(.caption, weight: .semibold))
                                    Spacer()
                                    Text(point.status.title)
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }
                                Text("Findings \(point.findingCount) • Open high \(point.openHighSeverityCount) • Repeated \(point.repeatedIssueCount)")
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(Color(.appTextSecondary))
                            }
                        }
                    }
                    .listRowBackground(Color(.appSurface))
                }
                .scrollContentBackground(.hidden)
                .background(Color(.appBackground))
                .navigationTitle("Audit Session")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Add Finding") {
                            editingFinding = nil
                            showingFindingEditor = true
                        }
                        Menu("Export") {
                            ForEach(AuditExportFormat.allCases) { format in
                                Button("Export \(format.fileExtension.uppercased())") {
                                    guard let data = viewModel.exportAuditData(sessionID: session.id, format: format) else { return }
                                    ExportPresenter.share(
                                        filename: "\(session.domain)-audit-\(session.createdAt.ISO8601Format()).\(format.fileExtension)",
                                        data: data
                                    )
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    notesDraft = session.notes
                }
                .onChange(of: session.notes) { _, newValue in
                    notesDraft = newValue
                }
                .sheet(isPresented: $showingFindingEditor) {
                    AuditFindingEditorView(
                        existingFinding: nil,
                        session: session
                    ) { draft in
                        viewModel.addAuditFinding(
                            sessionID: session.id,
                            title: draft.title,
                            severity: draft.severity,
                            summary: draft.summary,
                            evidenceReferences: draft.evidenceReferences,
                            notes: draft.notes,
                            checklistAreas: draft.checklistAreas
                        )
                    }
                }
                .sheet(item: $editingFinding) { finding in
                    AuditFindingEditorView(existingFinding: finding, session: session) { updated in
                        viewModel.updateAuditFinding(updated, sessionID: session.id)
                    }
                }
            } else {
                ContentUnavailableView("Audit Session Missing", systemImage: "exclamationmark.triangle")
                    .background(Color(.appBackground))
            }
        }
    }
}

private struct AuditFindingEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingFinding: AuditFinding?
    let session: AuditSession
    let onSave: (AuditFinding) -> Void

    @State private var title: String
    @State private var severity: AuditFindingSeverity
    @State private var summary: String
    @State private var evidenceReferencesText: String
    @State private var notes: String
    @State private var status: AuditFindingStatus
    @State private var selectedAreas: Set<AuditChecklistArea>

    init(existingFinding: AuditFinding?, session: AuditSession, onSave: @escaping (AuditFinding) -> Void) {
        self.existingFinding = existingFinding
        self.session = session
        self.onSave = onSave
        _title = State(initialValue: existingFinding?.title ?? "")
        _severity = State(initialValue: existingFinding?.severity ?? .medium)
        _summary = State(initialValue: existingFinding?.summary ?? "")
        _evidenceReferencesText = State(initialValue: existingFinding?.evidenceReferences.joined(separator: "\n") ?? "")
        _notes = State(initialValue: existingFinding?.notes ?? "")
        _status = State(initialValue: existingFinding?.status ?? .open)
        _selectedAreas = State(initialValue: Set(existingFinding?.checklistAreas ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Finding") {
                    TextField("Title", text: $title)
                    Picker("Severity", selection: $severity) {
                        ForEach(AuditFindingSeverity.allCases) { severity in
                            Text(severity.title).tag(severity)
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(AuditFindingStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    TextField("Summary", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Evidence References") {
                    TextField("One reference per line", text: $evidenceReferencesText, axis: .vertical)
                        .lineLimit(4...8)
                    if !session.evidence.screenshots.isEmpty {
                        ForEach(session.evidence.screenshots) { asset in
                            Text("\(asset.title): \(asset.reference)")
                                .font(.caption)
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                    }
                }

                Section("Checklist Areas") {
                    ForEach(AuditChecklistArea.allCases) { area in
                        Button {
                            if selectedAreas.contains(area) {
                                selectedAreas.remove(area)
                            } else {
                                selectedAreas.insert(area)
                            }
                        } label: {
                            HStack {
                                Text(area.title)
                                Spacer()
                                Image(systemName: selectedAreas.contains(area) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedAreas.contains(area) ? Color(.statusPositive) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedAreas.contains(area) ? .isSelected : [])
                    }
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(4...8)
                }
            }
            .navigationTitle(existingFinding == nil ? "New Finding" : "Edit Finding")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            AuditFinding(
                                id: existingFinding?.id ?? UUID(),
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                severity: severity,
                                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                evidenceReferences: evidenceReferencesText
                                    .split(separator: "\n")
                                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty },
                                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                                status: status,
                                checklistAreas: Array(selectedAreas).sorted { $0.title < $1.title },
                                createdAt: existingFinding?.createdAt ?? Date(),
                                updatedAt: Date()
                            )
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private func auditStatusBadge(_ status: AuditStatus) -> some View {
    let model: AppStatusBadgeModel
    switch status {
    case .draft:
        model = .init(title: "Draft", systemImage: "square.and.pencil", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
    case .inReview:
        model = .init(title: "In Review", systemImage: "doc.text.magnifyingglass", foregroundColor: Color(.statusInfo), backgroundColor: Color(.statusInfoSurface))
    case .complete:
        model = .init(title: "Complete", systemImage: "checkmark.seal.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
    }
    return AppStatusBadgeView(model: model)
}

private func findingSeverityBadge(_ severity: AuditFindingSeverity) -> some View {
    let tone: AppStatusTone
    switch severity {
    case .informational:
        tone = .neutral
    case .low:
        tone = .positive
    case .medium:
        tone = .warning
    case .high:
        tone = .critical
    }
    return AppStatusBadgeView(
        model: .init(
            title: severity.title,
            systemImage: "exclamationmark.circle.fill",
            foregroundColor: tone.foreground,
            backgroundColor: tone.surface
        )
    )
}

private func availabilityTitle(_ status: DomainAvailabilityStatus) -> String {
    switch status {
    case .available:
        return "Available"
    case .registered:
        return "Registered"
    case .unknown:
        return "Unknown"
    }
}

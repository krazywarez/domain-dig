import SwiftUI

struct ScheduledReportsView: View {
    @Environment(\.appDensity) private var appDensity
    @State private var settings = ScheduledReportStorage.loadSettings()
    @State private var logs = ScheduledReportStorage.loadLogs()
    @State private var isGenerating = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section("Overview") {
                if !FeatureAccessService.hasAccess(to: .automatedMonitoring) {
                    Text("Scheduled reports require Pro.")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(ThemeToken.textSecondary)
                }

                Toggle("Scheduled Reports", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { newValue in
                        settings.isEnabled = newValue
                        saveSettings()
                    }
                ))
                .disabled(!FeatureAccessService.hasAccess(to: .automatedMonitoring))

                Picker("Cadence", selection: Binding(
                    get: { settings.cadence },
                    set: { newValue in
                        settings.cadence = newValue
                        saveSettings()
                    }
                )) {
                    ForEach(ScheduledReportCadence.allCases) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .disabled(!FeatureAccessService.hasAccess(to: .automatedMonitoring))

                Picker("Format", selection: Binding(
                    get: { settings.format },
                    set: { newValue in
                        settings.format = newValue
                        saveSettings()
                    }
                )) {
                    ForEach([DomainExportFormat.markdown, .pdf, .json]) { format in
                        Text(format.title).tag(format)
                    }
                }
                .disabled(!FeatureAccessService.hasAccess(to: .automatedMonitoring))

                LabeledContent(
                    "Last Generated",
                    value: settings.lastGeneratedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
                )

                if let statusMessage {
                    Text(statusMessage)
                        .font(appDensity.font(.caption))
                        .foregroundStyle(ThemeToken.textSecondary)
                }

                Button(isGenerating ? "Generating…" : "Generate Now") {
                    Task { await generateNow() }
                }
                .disabled(isGenerating || !FeatureAccessService.hasAccess(to: .automatedMonitoring))
            }
            .themedListRowBackground(.surface)

            if logs.isEmpty {
                Section {
                    EmptyStateCardView(
                        title: "No Reports Yet",
                        message: "Generated reports for your watchlist appear here after a manual or scheduled run.",
                        suggestion: "Tap Generate Now, or enable Scheduled Reports above.",
                        systemImage: "doc.text",
                        showsCardBackground: false
                    )
                }
                .themedListRowBackground(.surface)
            } else {
                Section("Recent Reports") {
                    ForEach(logs) { log in
                        Button {
                            share(log)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(log.domainCount) domains • \(log.format.title)")
                                    .foregroundStyle(.primary)
                                Text(log.generatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(ThemeToken.textSecondary)
                            }
                        }
                    }
                }
                .themedListRowBackground(.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeToken.background)
        .navigationTitle("Scheduled Reports")
    }

    private func saveSettings() {
        ScheduledReportStorage.saveSettings(settings)
        ScheduledReportScheduler.shared.syncSchedule()
    }

    private func generateNow() async {
        isGenerating = true
        let outcome = await ScheduledReportService.shared.generateReport(trigger: .manual, requireEnabledSetting: false)
        statusMessage = outcome.message
        settings = ScheduledReportStorage.loadSettings()
        logs = ScheduledReportStorage.loadLogs()
        isGenerating = false
    }

    private func share(_ log: ScheduledReportLog) {
        let url = ScheduledReportStorage.reportsDirectory.appendingPathComponent(log.fileName)
        guard let data = try? Data(contentsOf: url) else {
            statusMessage = "That report is no longer available on disk."
            return
        }
        ExportPresenter.share(filename: log.fileName, data: data)
    }
}

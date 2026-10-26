import SwiftUI

struct MonitoringView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel

    private var monitoredDomainsCount: Int {
        MonitoringStorage.monitoredDomains(
            settings: viewModel.monitoringSettings,
            trackedDomains: viewModel.trackedDomains
        ).count
    }

    var body: some View {
        List {
            Section("Overview") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Status", value: viewModel.monitoringSettings.isEnabled ? "Scheduled" : "Manual only")
                    LabeledContent("Domains", value: "\(monitoredDomainsCount)")
                    LabeledContent("Base Interval", value: MonitoringBaseInterval.nearest(to: viewModel.monitoringSettings.baseInterval).title)
                    LabeledContent("Adaptive", value: viewModel.monitoringSettings.adaptiveEnabled ? viewModel.monitoringSettings.sensitivity.title : "Off")
                    LabeledContent(
                        "Quiet Hours",
                        value: viewModel.monitoringSettings.quietHours.map {
                            "\(Self.hourLabel($0.startHour)) to \(Self.hourLabel($0.endHour))"
                        } ?? "Off"
                    )
                    LabeledContent("Alerts", value: viewModel.monitoringSettings.alertsEnabled ? viewModel.monitoringSettings.alertFilter.title : "Off")

                    if let monitoringStatusMessage = viewModel.monitoringStatusMessage,
                       !monitoringStatusMessage.isEmpty {
                        Text(monitoringStatusMessage)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ThemeToken.textSecondary)
                    }

                    Button(viewModel.monitoringRunInProgress ? "Monitoring…" : "Run Now") {
                        viewModel.runMonitoringNow()
                    }
                    .disabled(viewModel.monitoringRunInProgress)
                }
                .padding(.vertical, 4)
            }
            .themedListRowBackground(.surface)

            if viewModel.monitoringLogs.isEmpty {
                Section {
                    EmptyStateCardView(
                        title: "No Monitoring Runs Yet",
                        message: "Monitoring history appears here after manual or background runs finish.",
                        suggestion: "Enable monitoring in Settings or run a manual monitoring sweep.",
                        systemImage: "waveform.path.ecg",
                        showsCardBackground: false
                    )
                }
                .themedListRowBackground(.surface)
            } else {
                Section("Recent Runs") {
                    ForEach(viewModel.monitoringLogs) { log in
                        NavigationLink {
                            MonitoringLogDetailView(viewModel: viewModel, log: log)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(log.trigger.title)
                                        .font(appDensity.font(.callout))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(ThemeToken.textSecondary)
                                }

                                Text(log.summary)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(ThemeToken.textSecondary)

                                HStack(spacing: 8) {
                                    metricBadge(title: "\(log.domainsChecked) checked")
                                    if log.changesFound > 0 {
                                        metricBadge(title: "\(log.changesFound) changed", tone: .warning)
                                    }
                                    if log.alertsTriggered > 0 {
                                        metricBadge(title: "\(log.alertsTriggered) alerts", tone: .critical)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .themedListRowBackground(.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeToken.background)
        .navigationTitle("Monitoring")
        .onAppear {
            viewModel.refreshMonitoringState()
        }
    }

    private func metricBadge(title: String, tone: AppStatusTone = .info) -> some View {
        Text(title)
            .font(appDensity.font(.caption2))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.surface)
            .clipShape(Capsule())
    }

    private static func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let components = DateComponents(calendar: .current, hour: hour)
        return components.date.map(formatter.string(from:)) ?? "\(hour):00"
    }
}

struct MonitoringLogDetailView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let log: MonitoringLog

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Trigger", value: log.trigger.title)
                LabeledContent("Checked", value: "\(log.domainsChecked)")
                LabeledContent("Changes", value: "\(log.changesFound)")
                LabeledContent("Alerts", value: "\(log.alertsTriggered)")
                LabeledContent("Timestamp", value: log.timestamp.formatted(date: .abbreviated, time: .shortened))
            }
            .themedListRowBackground(.surface)

            Section("Domains") {
                ForEach(log.checkedDomains) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(result.domain)
                                .font(appDensity.font(.callout))
                                .foregroundStyle(.primary)
                            Spacer()
                            if let alertSeverity = result.alertSeverity {
                                Text(alertSeverity.title.uppercased())
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(color(for: alertSeverity))
                            }
                        }

                        Text(result.summaryMessage)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ThemeToken.textSecondary)

                        HStack(spacing: 10) {
                            Text(result.resultSource.label)
                            Text(result.didChange ? "Changed" : "No change")
                            if result.certificateWarningLevel != .none {
                                Text(result.certificateWarningLevel.title)
                            }
                        }
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(ThemeToken.textSecondary)

                        if let errorMessage = result.errorMessage {
                            Text(errorMessage)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(ThemeToken.warning)
                        }

                        if let historyEntryID = result.historyEntryID,
                           let entry = viewModel.history.first(where: { $0.id == historyEntryID }) {
                            NavigationLink("Open Snapshot") {
                                HistoryDetailView(viewModel: viewModel, entry: entry)
                            }
                            .font(appDensity.font(.caption))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .themedListRowBackground(.surface)

            if !log.errors.isEmpty {
                Section("Errors") {
                    ForEach(log.errors, id: \.self) { error in
                        Text(error)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
                .themedListRowBackground(.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeToken.background)
        .navigationTitle("Run Details")
    }

    private func color(for severity: MonitoringAlertSeverity) -> AnyShapeStyle {
        switch severity {
        case .info:
            return AnyShapeStyle(.secondary)
        case .warning:
            return AnyShapeStyle(ThemeToken.warning)
        case .critical:
            return AnyShapeStyle(ThemeToken.critical)
        }
    }
}

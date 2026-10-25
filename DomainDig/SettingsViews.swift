import SwiftUI
import UniformTypeIdentifiers

// Settings screens extracted from ContentView.swift. `SettingsView` is the
// Settings tab root (presented from RootTabView); the per-section screens are
// file-private, reached only through its navigation links.

struct SettingsView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @State private var purchaseService = PurchaseService.shared

    var body: some View {

        List {
            Section("Tier") {
                LabeledContent("Status", value: purchaseService.currentTier.title)

                if purchaseService.currentTier == .free {
                    Button("Upgrade") {
                        viewModel.isPaywallPresented = true
                    }
                } else {
                    Button("Manage Subscription") {
                        Task {
                            await purchaseService.manageSubscription()
                        }
                    }
                }

                Button(purchaseService.isRestoring ? "Restoring…" : "Restore Purchases") {
                    Task {
                        await purchaseService.restorePurchases()
                    }
                }
                .disabled(purchaseService.isRestoring || purchaseService.isPurchasing)

                if let statusMessage = purchaseService.statusMessage {
                    Text(statusMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                }

                if let errorMessage = purchaseService.errorMessage {
                    Text(errorMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.statusCritical))
                }
            }

            Section("Preferences") {
                NavigationLink("Display") {
                    DisplaySettingsView()
                }

                NavigationLink("History & Network") {
                    HistoryNetworkSettingsView(viewModel: viewModel)
                }
            }

            Section("Services") {
                NavigationLink("Monitoring Log") {
                    MonitoringView(viewModel: viewModel)
                }

                NavigationLink("Integrations") {
                    IntegrationsSettingsView()
                }

                NavigationLink("Local API") {
                    LocalAPISettingsView()
                }

                NavigationLink("iCloud Sync") {
                    CloudSyncSettingsView()
                }

                NavigationLink("Monitoring Settings") {
                    MonitoringSettingsView(viewModel: viewModel)
                }

                NavigationLink("Scheduled Reports") {
                    ScheduledReportsView()
                }
            }

            Section("Data") {
                NavigationLink("Import & Export") {
                    DataPortabilitySettingsView(viewModel: viewModel)
                }

                NavigationLink("Data Management") {
                    DataManagementSettingsView(viewModel: viewModel)
                }
            }

            Section("About") {
                NavigationLink("App Info") {
                    AppInfoView()
                }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct DisplaySettingsView: View {
    @AppStorage(AppDensity.userDefaultsKey) private var storedDensity = AppDensity.compact.rawValue
    @AppStorage(AppAppearance.userDefaultsKey) private var storedAppearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("Display") {
                Picker("Appearance", selection: $storedAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }

                Picker("Density", selection: $storedDensity) {
                    ForEach(AppDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Display")
    }
}

private struct HistoryNetworkSettingsView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    @AppStorage(DNSResolverOption.userDefaultsKey) private var storedResolverURL = DNSResolverOption.defaultURLString
    @AppStorage(AppDensity.userDefaultsKey) private var storedDensity = AppDensity.compact.rawValue
    @AppStorage(InspectionScope.profileDefaultsKey) private var storedProfile = InspectionProfile.full.rawValue
    @AppStorage(InspectionScope.enrichmentDefaultsKey) private var allowsThirdPartyEnrichment = true

    @State private var resolverOption: DNSResolverOption = .cloudflare
    @State private var customResolverURL = DNSResolverOption.defaultURLString

    private static let enrichmentCaption = """
        On, DomainDig asks rdap.org for registration and ownership, crt.sh for subdomain discovery, \
        and ipapi.co for IP location. Off, it contacts none of them: ownership, subdomain discovery, \
        IP location and name suggestions become unavailable, and registration is decided from DNS \
        alone, so a domain that resolves reads as registered and anything else as unknown.
        """

    private var selectedProfile: InspectionProfile {
        InspectionProfile(rawValue: storedProfile) ?? .full
    }

    private var customResolverError: String? {
        guard resolverOption == .custom else { return nil }
        return DNSResolverOption.isValidCustomURL(customResolverURL) ? nil : "Resolver URL must start with https://"
    }

    var body: some View {
        Form {
            Section("History") {
                Picker(
                    "Auto-prune",
                    selection: Binding(
                        get: { viewModel.historyAutoPruneOption },
                        set: { viewModel.setHistoryAutoPruneOption($0) }
                    )
                ) {
                    ForEach(HistoryAutoPruneOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Text(viewModel.historyRetentionCaption)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            Section("Network") {
                Picker("Resolver", selection: $resolverOption) {
                    ForEach(DNSResolverOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                if resolverOption == .custom {
                    TextField("https://resolver.example/dns-query", text: $customResolverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if let customResolverError {
                        Text(customResolverError)
                            .font(appDensity.font(.caption, design: .default))
                            .foregroundStyle(Color(.statusCritical))
                    }
                }

                Picker("Lookup profile", selection: $storedProfile) {
                    ForEach(InspectionProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }

                Text(selectedProfile.detail)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))

                Toggle("Allow third-party enrichment", isOn: $allowsThirdPartyEnrichment)

                Text(Self.enrichmentCaption)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))
            }
        }
        .navigationTitle("History & Network")
        .onAppear {
            let currentResolverURL = storedResolverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            resolverOption = DNSResolverOption.option(for: currentResolverURL)
            customResolverURL = resolverOption == .custom ? currentResolverURL : DNSResolverOption.defaultURLString
        }
        .onChange(of: resolverOption) { _, newValue in
            guard let presetURL = newValue.urlString else {
                storedResolverURL = customResolverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.persistCurrentAppSettings(
                    resolverURLString: storedResolverURL,
                    appDensityRawValue: storedDensity
                )
                return
            }
            storedResolverURL = presetURL
            viewModel.persistCurrentAppSettings(
                resolverURLString: storedResolverURL,
                appDensityRawValue: storedDensity
            )
        }
        .onChange(of: customResolverURL) { _, newValue in
            guard resolverOption == .custom else { return }
            storedResolverURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.persistCurrentAppSettings(
                resolverURLString: storedResolverURL,
                appDensityRawValue: storedDensity
            )
        }
        .onChange(of: storedDensity) { _, newValue in
            viewModel.persistCurrentAppSettings(
                resolverURLString: storedResolverURL,
                appDensityRawValue: newValue
            )
        }
    }
}

private struct CloudSyncSettingsView: View {
    @Environment(\.appDensity) private var appDensity
    @State private var cloudSyncService = CloudSyncService.shared

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle(
                    "Enable iCloud Sync",
                    isOn: Binding(
                        get: { cloudSyncService.isEnabled },
                        set: { cloudSyncService.setSyncEnabled($0) }
                    )
                )

                LabeledContent("Status", value: cloudSyncService.status.title)
                LabeledContent(
                    "Last Sync",
                    value: cloudSyncService.lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet synced"
                )

                Button(cloudSyncService.status == .syncing ? "Syncing…" : "Sync Now") {
                    Task {
                        await cloudSyncService.syncNow(trigger: .manual)
                    }
                }
                .disabled(!cloudSyncService.isEnabled || cloudSyncService.status == .syncing)

                Text("iCloud Sync stores DomainDig data in your private iCloud account. DomainDig does not operate a sync server. Disabling sync keeps local data on this device.")
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))

                Text(cloudSyncService.detailMessage)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))

                if let lastErrorMessage = cloudSyncService.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.statusCritical))
                }
            }
        }
        .navigationTitle("iCloud Sync")
        .task {
            await cloudSyncService.refreshAvailability()
        }
    }
}

private struct LocalAPISettingsView: View {
    @Environment(\.appDensity) private var appDensity
    @State private var localAPIService = LocalAPIService.shared
    @State private var portText = ""

    private var statusText: String {
        if localAPIService.isRunning { return "Running" }
        return localAPIService.config.isEnabled ? "Stopped" : "Disabled"
    }

    var body: some View {
        Form {
            Section("Local API") {
                Toggle(
                    "Enable Local API",
                    isOn: Binding(
                        get: { localAPIService.config.isEnabled },
                        set: { localAPIService.setEnabled($0) }
                    )
                )

                TextField(
                    "Port",
                    text: Binding(
                        get: { portText },
                        set: { newValue in
                            portText = newValue
                            if let port = Int(newValue) {
                                localAPIService.setPort(port)
                            }
                        }
                    )
                )
                .keyboardType(.numberPad)

                LabeledContent("Address", value: localAPIService.address)
                LabeledContent("Status", value: statusText)
                LabeledContent("Token", value: localAPIService.maskedToken)

                if let statusMessage = localAPIService.statusMessage {
                    Text(statusMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                }
            }

            Section("Authentication") {
                Button("Copy Token") {
                    localAPIService.copyToken()
                }

                Button("Copy cURL Command") {
                    localAPIService.copyCurlCommand()
                }

                Button("Rotate Token") {
                    localAPIService.rotateToken()
                }

                Text("Every request requires either `Authorization: Bearer <token>` or `X-API-Token`. DomainDig stores the token in Keychain and only binds the server to localhost.")
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            Section("Request Logging") {
                Toggle(
                    "Log Requests",
                    isOn: Binding(
                        get: { localAPIService.config.requestLoggingEnabled },
                        set: { localAPIService.setRequestLoggingEnabled($0) }
                    )
                )

                if localAPIService.requestLogs.isEmpty {
                    Text("No local API requests logged yet.")
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(localAPIService.requestLogs.prefix(25)) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(log.method) \(log.path)")
                                    .font(appDensity.font(.callout, design: .monospaced))
                                Spacer()
                                Text("\(log.statusCode)")
                                    .font(appDensity.font(.caption, design: .default))
                                    .foregroundStyle(log.statusCode >= 400 ? Color(.statusCritical) : .secondary)
                            }

                            Text(log.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(appDensity.font(.caption2, design: .default))
                                .foregroundStyle(Color(.appTextSecondary))

                            Text("\(Int(log.duration * 1000)) ms")
                                .font(appDensity.font(.caption2, design: .default))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                    }
                }

                Button("Clear Logs", role: .destructive) {
                    localAPIService.clearRequestLogs()
                }
            }

            Section("Control") {
                Button("Restart Server") {
                    localAPIService.setEnabled(false)
                    localAPIService.setEnabled(true)
                }
                .disabled(!localAPIService.config.isEnabled)

                Button("Stop Server") {
                    localAPIService.stopServer()
                }
                .disabled(!localAPIService.isRunning)
            }
        }
        .navigationTitle("Local API")
        .onAppear {
            portText = String(localAPIService.config.port)
            localAPIService.refresh()
        }
    }
}

private struct MonitoringSettingsView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel

    private var notificationAuthorizationLabel: String {
        switch viewModel.monitoringNotificationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Requested"
        @unknown default:
            return "Unknown"
        }
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle(
                    "Enable Background Monitoring",
                    isOn: Binding(
                        get: { viewModel.monitoringSettings.isEnabled },
                        set: { viewModel.setMonitoringEnabled($0) }
                    )
                )

                Picker(
                    "Base Interval",
                    selection: Binding(
                        get: { MonitoringBaseInterval.nearest(to: viewModel.monitoringSettings.baseInterval) },
                        set: { viewModel.setMonitoringBaseInterval($0) }
                    )
                ) {
                    ForEach(MonitoringBaseInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }

                Toggle(
                    "Adaptive Monitoring",
                    isOn: Binding(
                        get: { viewModel.monitoringSettings.adaptiveEnabled },
                        set: { viewModel.setMonitoringAdaptiveEnabled($0) }
                    )
                )

                Picker(
                    "Sensitivity",
                    selection: Binding(
                        get: { viewModel.monitoringSettings.sensitivity },
                        set: { viewModel.setMonitoringSensitivity($0) }
                    )
                ) {
                    ForEach(MonitoringSensitivity.allCases) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }

                let quietHoursStart = viewModel.monitoringSettings.quietHours?.startHour ?? 22
                let quietHoursEnd = viewModel.monitoringSettings.quietHours?.endHour ?? 7
                Toggle(
                    "Quiet Hours",
                    isOn: Binding(
                        get: { viewModel.monitoringSettings.quietHours != nil },
                        set: { isEnabled in
                            viewModel.setMonitoringQuietHours(
                                startHour: quietHoursStart,
                                endHour: quietHoursEnd,
                                isEnabled: isEnabled
                            )
                        }
                    )
                )

                if viewModel.monitoringSettings.quietHours != nil {
                    hourPicker("Quiet Starts", selection: Binding(
                        get: { quietHoursStart },
                        set: { viewModel.setMonitoringQuietHours(startHour: $0, endHour: quietHoursEnd, isEnabled: true) }
                    ))
                    hourPicker("Quiet Ends", selection: Binding(
                        get: { quietHoursEnd },
                        set: { viewModel.setMonitoringQuietHours(startHour: quietHoursStart, endHour: $0, isEnabled: true) }
                    ))
                }

                Picker(
                    "Domains",
                    selection: Binding(
                        get: { viewModel.monitoringSettings.scope },
                        set: { viewModel.setMonitoringScope($0) }
                    )
                ) {
                    ForEach(MonitoringScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }

                if viewModel.monitoringSettings.scope == .selectedOnly {
                    ForEach(viewModel.trackedDomains) { trackedDomain in
                        Toggle(
                            trackedDomain.domain,
                            isOn: Binding(
                                get: { viewModel.monitoringSettings.selectedDomainIDs.contains(trackedDomain.id) },
                                set: { viewModel.setMonitoringSelection(for: trackedDomain, isSelected: $0) }
                            )
                        )
                    }
                }

                Toggle(
                    "Local Alerts",
                    isOn: Binding(
                        get: { viewModel.monitoringSettings.alertsEnabled },
                        set: { isEnabled in
                            if isEnabled {
                                Task {
                                    await viewModel.requestMonitoringNotificationAuthorization()
                                }
                            } else {
                                viewModel.setMonitoringAlertsEnabled(false)
                            }
                        }
                    )
                )

                Picker(
                    "Notify For",
                    selection: Binding(
                        get: { viewModel.monitoringSettings.alertFilter },
                        set: { viewModel.setMonitoringAlertFilter($0) }
                    )
                ) {
                    ForEach(MonitoringAlertFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }

                LabeledContent("Background Refresh", value: DomainMonitoringScheduler.shared.backgroundRefreshStatusDescription())
                LabeledContent("Notification Access", value: notificationAuthorizationLabel)

                if let monitoringStatusMessage = viewModel.monitoringStatusMessage {
                    Text(monitoringStatusMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                }

                if !FeatureAccessService.hasAccess(to: .automatedMonitoring) {
                    Text("Background monitoring and alerts are available in Pro.")
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                }
            }
        }
        .navigationTitle("Monitoring")
        .onAppear {
            viewModel.refreshMonitoringState()
            Task {
                await viewModel.refreshMonitoringAuthorizationStatus()
            }
        }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.monitoringHourLabel(for: hour)).tag(hour)
            }
        }
    }

    private static func monitoringHourLabel(for hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let components = DateComponents(calendar: .current, hour: hour)
        return components.date.map(formatter.string(from:)) ?? "\(hour):00"
    }
}

private struct DataPortabilitySettingsView: View {
    private enum ImportTarget {
        case backup
        case trackedDomains
        case workflows

        var expectedKind: DataPortabilityImportKind {
            switch self {
            case .backup:
                return .backup
            case .trackedDomains:
                return .trackedDomains
            case .workflows:
                return .workflows
            }
        }

        var allowedContentTypes: [UTType] {
            switch self {
            case .backup:
                return [UTType.json]
            case .trackedDomains, .workflows:
                return [UTType.json, UTType.commaSeparatedText]
            }
        }
    }

    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel

    @State private var importMode: DataPortabilityImportMode = .merge
    @State private var activeImportTarget: ImportTarget?
    @State private var pendingImportTarget: ImportTarget?
    @State private var importDebugStatus: String?
    @State private var pendingImportPreview: DataImportPreview?
    @State private var pendingImportError: String?
    @State private var showReplaceImportConfirmation = false

    var body: some View {
        Form {
            Section("Import & Export") {
                Picker("Import Mode", selection: $importMode) {
                    ForEach(DataPortabilityImportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text(importMode.explanation)
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))

                Button("Export Full Backup") {
                    exportFullBackup()
                }

                Button("Import Backup") {
                    recordImportDebugStatus("Tapped Import Backup")
                    pendingImportTarget = .backup
                    activeImportTarget = .backup
                }

                Menu("Export Tracked Domains") {
                    Button("JSON") {
                        exportPortableTrackedDomainsJSON()
                    }
                    Button("CSV") {
                        exportPortableTrackedDomainsCSV()
                    }
                }

                Button("Import Tracked Domains") {
                    recordImportDebugStatus("Tapped Import Tracked Domains")
                    pendingImportTarget = .trackedDomains
                    activeImportTarget = .trackedDomains
                }

                Menu("Export Workflows") {
                    Button("JSON") {
                        exportPortableWorkflowsJSON()
                    }
                    Button("CSV") {
                        exportPortableWorkflowsCSV()
                    }
                }

                Button("Import Workflows") {
                    recordImportDebugStatus("Tapped Import Workflows")
                    pendingImportTarget = .workflows
                    activeImportTarget = .workflows
                }

                Button("Export History") {
                    exportPortableHistoryJSON()
                }
            }

            Section("Local Data") {
                LabeledContent("Tracked Domains", value: "\(viewModel.dataLifecycleSummary.trackedDomains)")
                LabeledContent("History Snapshots", value: "\(viewModel.dataLifecycleSummary.historySnapshots)")
                LabeledContent("Audit Sessions", value: "\(viewModel.dataLifecycleSummary.auditSessions)")
                LabeledContent("Workflows", value: "\(viewModel.dataLifecycleSummary.workflows)")
                LabeledContent("Cached Items", value: "\(viewModel.dataLifecycleSummary.cachedItems)")
                LabeledContent("Monitoring Logs", value: "\(viewModel.dataLifecycleSummary.monitoringLogs)")

                Text("Data stays on this device unless you export it. Backup files can include domain history, monitoring settings, and notes. Imported files are processed on-device.")
                    .font(appDensity.font(.caption, design: .default))
                    .foregroundStyle(Color(.appTextSecondary))

                if let portabilityStatusMessage = viewModel.portabilityStatusMessage {
                    Text(portabilityStatusMessage)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                }
            }

            #if DEBUG
            if let importDebugStatus {
                Section("Import Debug") {
                    Text(importDebugStatus)
                        .font(appDensity.font(.caption, design: .default))
                        .foregroundStyle(Color(.appTextSecondary))
                        .textSelection(.enabled)
                }
            }
            #endif
        }
        .navigationTitle("Import & Export")
        .alert("Replace local data?", isPresented: $showReplaceImportConfirmation) {
            Button("Replace", role: .destructive) {
                applyPendingImport()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("Replace mode overwrites local data covered by the imported file and may remove items that are only on this device.")
        }
        .alert("Import Error", isPresented: Binding(
            get: { pendingImportError != nil },
            set: { if !$0 { pendingImportError = nil } }
        )) {
            Button("OK", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text(pendingImportError ?? "The import could not be completed.")
        }
        .sheet(isPresented: Binding(
            get: { pendingImportPreview != nil },
            set: { if !$0 { pendingImportPreview = nil } }
        )) {
            if let pendingImportPreview {
                DataImportPreviewSheet(
                    preview: pendingImportPreview,
                    mode: importMode,
                    onCancel: {
                        self.pendingImportPreview = nil
                    },
                    onApply: {
                        if importMode == .replace {
                            showReplaceImportConfirmation = true
                        } else {
                            applyPendingImport()
                        }
                    }
                )
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeImportTarget != nil },
                set: { if !$0 { activeImportTarget = nil } }
            ),
            allowedContentTypes: activeImportTarget?.allowedContentTypes ?? [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            guard let pendingImportTarget else {
                recordImportDebugStatus("fileImporter returned with no active target")
                return
            }
            recordImportDebugStatus("fileImporter returned for \(pendingImportTarget.expectedKind.rawValue)")
            handleImportResult(result, expectedKind: pendingImportTarget.expectedKind)
            self.pendingImportTarget = nil
            self.activeImportTarget = nil
        }
        .onAppear {
            viewModel.refreshDataLifecycleSummary()
        }
    }

    private func exportFullBackup() {
        guard let data = viewModel.exportFullBackupData() else { return }
        ExportPresenter.share(filename: portabilityFilename(suffix: "backup", fileExtension: "json"), data: data)
    }

    private func exportPortableTrackedDomainsJSON() {
        guard let data = viewModel.exportPortableTrackedDomainsJSONData() else { return }
        ExportPresenter.share(filename: portabilityFilename(suffix: "tracked_domains", fileExtension: "json"), data: data)
    }

    private func exportPortableTrackedDomainsCSV() {
        ExportPresenter.share(
            filename: portabilityFilename(suffix: "tracked_domains", fileExtension: "csv"),
            contents: viewModel.exportPortableTrackedDomainsCSV()
        )
    }

    private func exportPortableWorkflowsJSON() {
        guard let data = viewModel.exportPortableWorkflowsJSONData() else { return }
        ExportPresenter.share(filename: portabilityFilename(suffix: "workflows", fileExtension: "json"), data: data)
    }

    private func exportPortableWorkflowsCSV() {
        ExportPresenter.share(
            filename: portabilityFilename(suffix: "workflows", fileExtension: "csv"),
            contents: viewModel.exportPortableWorkflowsCSV()
        )
    }

    private func exportPortableHistoryJSON() {
        guard let data = viewModel.exportPortableHistoryJSONData() else { return }
        ExportPresenter.share(filename: portabilityFilename(suffix: "history", fileExtension: "json"), data: data)
    }

    private func handleImportResult(
        _ result: Result<[URL], Error>,
        expectedKind: DataPortabilityImportKind
    ) {
        DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult expectedKind=\(expectedKind.rawValue)")
        recordImportDebugStatus("handleImportResult started for \(expectedKind.rawValue)")
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult noURLReturned")
                recordImportDebugStatus("No URL returned from picker")
                return
            }
            DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult selectedURL=\(url.absoluteString)")
            recordImportDebugStatus("Selected \(url.lastPathComponent)")
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult securityScopeGranted=\(shouldStopAccessing)")
            recordImportDebugStatus("Security scope granted: \(shouldStopAccessing)")
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                    DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult securityScopeReleased")
                }
            }

            let data = try Data(contentsOf: url)
            DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult dataRead bytes=\(data.count) fileName=\(url.lastPathComponent)")
            recordImportDebugStatus("Read \(data.count) bytes from \(url.lastPathComponent)")
            let preview = try viewModel.prepareDataImport(
                data: data,
                fileName: url.lastPathComponent,
                mode: importMode
            )
            DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult previewReady previewKind=\(preview.kind.rawValue) expectedKind=\(expectedKind.rawValue)")
            recordImportDebugStatus("Preview ready: \(preview.kind.rawValue)")

            guard preview.kind == expectedKind else {
                let message = preview.kind == .backup
                    ? "That file is a full backup. Use Import Backup."
                    : "That file type does not match this import action."
                DomainDebugLog.error("DataPortabilitySettingsView.handleImportResult kindMismatch message=\(message)")
                recordImportDebugStatus("Kind mismatch: \(message)")
                presentImportError(message)
                return
            }

            DomainDebugLog.debug("DataPortabilitySettingsView.handleImportResult presentingPreview kind=\(preview.kind.rawValue)")
            recordImportDebugStatus("Presenting preview for \(preview.kind.rawValue)")
            presentImportPreview(preview)
        } catch {
            DomainDebugLog.error("DataPortabilitySettingsView.handleImportResult failed error=\(error.localizedDescription)")
            recordImportDebugStatus("Import failed: \(error.localizedDescription)")
            presentImportError(error.localizedDescription)
        }
    }

    private func applyPendingImport() {
        guard let pendingImportPreview else { return }
        do {
            _ = try viewModel.applyDataImport(pendingImportPreview, mode: importMode)
            self.pendingImportPreview = nil
        } catch {
            pendingImportError = error.localizedDescription
        }
    }

    private func portabilityFilename(suffix: String, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: Date()))_domaindig_\(suffix).\(fileExtension)"
    }

    private func presentImportPreview(_ preview: DataImportPreview) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            DomainDebugLog.debug("DataPortabilitySettingsView.presentImportPreview kind=\(preview.kind.rawValue) fileName=\(preview.fileName)")
            recordImportDebugStatus("Preview presented for \(preview.fileName)")
            pendingImportPreview = preview
        }
    }

    private func presentImportError(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            DomainDebugLog.error("DataPortabilitySettingsView.presentImportError message=\(message)")
            recordImportDebugStatus("Error presented: \(message)")
            pendingImportError = message
        }
    }

    private func recordImportDebugStatus(_ message: String) {
        #if DEBUG
        let status = "[Import Debug] \(message)"
        importDebugStatus = status
        print(status)
        #endif
    }
}

private struct DataManagementSettingsView: View {
    @Bindable var viewModel: DomainViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var showClearHistoryConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var showClearWorkflowsConfirmation = false
    @State private var showClearTrackedDomainsConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var deleteAllErrorMessage: String?
    @State private var deleteAllSuccessMessage: String?
    @State private var isDeletingAllData = false

    var body: some View {
        Form {
            Section("Data") {
                Button("Clear History", role: .destructive) {
                    showClearHistoryConfirmation = true
                }

                Button("Clear Cache", role: .destructive) {
                    showClearCacheConfirmation = true
                }

                Button("Clear Workflows", role: .destructive) {
                    showClearWorkflowsConfirmation = true
                }

                Button("Clear Tracked Domains", role: .destructive) {
                    showClearTrackedDomainsConfirmation = true
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    HStack {
                        Text("Delete All Data")
                        Spacer()
                        if isDeletingAllData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isDeletingAllData)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Permanently removes all local DomainDig data from this device.")
            }
        }
        .disabled(isDeletingAllData)
        .navigationTitle("Data Management")
        .alert("Clear history?", isPresented: $showClearHistoryConfirmation) {
            Button("Clear", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("This removes saved lookup snapshots and clears monitoring run history on this device.")
        }
        .alert("Clear cache?", isPresented: $showClearCacheConfirmation) {
            Button("Clear", role: .destructive) {
                viewModel.clearLookupCache()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("This clears the in-memory lookup cache and cancels any cached in-flight work.")
        }
        .alert("Clear workflows?", isPresented: $showClearWorkflowsConfirmation) {
            Button("Clear", role: .destructive) {
                viewModel.clearWorkflows()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("This removes saved workflows only. History, tracked domains, and saved reports stay intact.")
        }
        .alert("Clear tracked domains?", isPresented: $showClearTrackedDomainsConfirmation) {
            Button("Clear", role: .destructive) {
                viewModel.clearTrackedDomains()
            }
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text("This removes the watchlist and clears monitoring run history. History and workflows stay intact.")
        }
        .alert("Delete All Data?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
            Button("Delete All Data", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will permanently remove all saved DomainDig data from this device. This includes tracked domains, monitoring history, snapshots, exports, cached reports, and local settings. This action cannot be undone.")
        }
        .alert("Delete Failed", isPresented: Binding(
            get: { deleteAllErrorMessage != nil },
            set: { if !$0 { deleteAllErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { /* Dismiss only; SwiftUI closes the alert. */ }
        } message: {
            Text(deleteAllErrorMessage ?? "The local data reset could not be completed.")
        }
        .safeAreaInset(edge: .bottom) {
            if let deleteAllSuccessMessage {
                Text(deleteAllSuccessMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(.appTextSecondary))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // Reduce Transparency swaps the blur for an opaque surface.
                    // On iOS 26+ the system also composites its own translucency
                    // that the app cannot declare — verify there too (Phase 6).
                    .background(
                        Capsule().fill(reduceTransparency ? AnyShapeStyle(Color(.appSurfaceElevated)) : AnyShapeStyle(.thinMaterial))
                    )
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func deleteAllData() {
        guard !isDeletingAllData else { return }

        isDeletingAllData = true
        deleteAllErrorMessage = nil
        deleteAllSuccessMessage = nil

        Task {
            do {
                try await DataResetService.wipeAllLocalData(viewModel: viewModel)
                deleteAllSuccessMessage = "All local data removed."
                try? await Task.sleep(for: .seconds(2))
                if deleteAllSuccessMessage == "All local data removed." {
                    deleteAllSuccessMessage = nil
                }
            } catch {
                deleteAllErrorMessage = error.localizedDescription
            }

            isDeletingAllData = false
        }
    }
}

private struct DataImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preview: DataImportPreview
    let mode: DataPortabilityImportMode
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    ForEach(preview.summaryLines, id: \.self) { line in
                        Text(line)
                    }
                }

                Section("Projected Counts") {
                    LabeledContent("Tracked Domains", value: "\(preview.projectedCounts.trackedDomains)")
                    LabeledContent("History Snapshots", value: "\(preview.projectedCounts.historySnapshots)")
                    LabeledContent("Audit Sessions", value: "\(preview.projectedCounts.auditSessions)")
                    LabeledContent("Workflows", value: "\(preview.projectedCounts.workflows)")
                    LabeledContent("Cached Items", value: "\(preview.projectedCounts.cachedItems)")
                    LabeledContent("Monitoring Logs", value: "\(preview.projectedCounts.monitoringLogs)")
                }

                if !preview.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Text(warning)
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                    }
                }
            }
            .navigationTitle("Import Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .replace ? "Replace" : "Import") {
                        onApply()
                        if mode == .merge {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

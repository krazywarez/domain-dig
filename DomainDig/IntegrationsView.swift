import SwiftUI

struct IntegrationsSettingsView: View {
    @State private var integrationService = IntegrationService.shared
    @State private var editingTarget: IntegrationTarget?
    @State private var showingCreateSheet = false

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Integrations", value: "\(integrationService.targets.count)")
                LabeledContent("Queued Deliveries", value: "\(integrationService.queue.count)")
                LabeledContent("Recent Log Entries", value: "\(integrationService.deliveryRecords.count)")

                if let statusMessage = integrationService.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)
                }

                Button("Process Queue Now") {
                    integrationService.processQueueNow()
                }
            }

            Section("Targets") {
                if integrationService.targets.isEmpty {
                    Text("No integrations configured.")
                        .foregroundStyle(ThemeToken.textSecondary)
                } else {
                    ForEach(integrationService.targets) { target in
                        NavigationLink {
                            IntegrationDetailView(
                                integrationID: target.id,
                                onEdit: {
                                    editingTarget = target
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(target.name)
                                    Spacer()
                                    Text(target.type.title)
                                        .foregroundStyle(ThemeToken.textSecondary)
                                }

                                Text(summary(for: target))
                                    .font(.caption)
                                    .foregroundStyle(ThemeToken.textSecondary)

                                if !target.isEnabled {
                                    Text("Disabled")
                                        .font(.caption2)
                                        .foregroundStyle(ThemeToken.warning)
                                }
                            }
                        }
                    }
                }

                Button("Add Integration") {
                    showingCreateSheet = true
                }
            }
        }
        .navigationTitle("Integrations")
        .sheet(isPresented: $showingCreateSheet) {
            NavigationStack {
                IntegrationEditorView(existingTarget: nil)
            }
        }
        .sheet(item: $editingTarget) { target in
            NavigationStack {
                IntegrationEditorView(existingTarget: target)
            }
        }
        .onAppear {
            integrationService.refresh()
        }
    }

    private func summary(for target: IntegrationTarget) -> String {
        switch target.configuration {
        case .webhook(let configuration):
            return configuration.endpointDisplayHost.isEmpty ? "Webhook" : configuration.endpointDisplayHost
        case .slack(let configuration):
            return configuration.destinationLabel
        case .email(let configuration):
            return configuration.recipientAddresses.joined(separator: ", ")
        case .s3(let configuration):
            return configuration.bucket.isEmpty ? "S3 bucket" : configuration.bucket
        }
    }
}

private struct IntegrationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var integrationService = IntegrationService.shared

    let integrationID: UUID
    let onEdit: () -> Void

    private var target: IntegrationTarget? {
        integrationService.targets.first(where: { $0.id == integrationID })
    }

    var body: some View {
        List {
            if let target {
                Section("Configuration") {
                    LabeledContent("Type", value: target.type.title)
                    LabeledContent("Status", value: target.isEnabled ? "Enabled" : "Disabled")
                    LabeledContent("Destination", value: destination(for: target))
                    LabeledContent("Minimum Severity", value: target.filters.minimumSeverity.title)
                    if !target.filters.domains.isEmpty {
                        LabeledContent("Domains", value: target.filters.domains.joined(separator: ", "))
                    }
                }

                Section("Actions") {
                    Button("Edit Integration") {
                        onEdit()
                    }

                    Button("Send Test Event") {
                        integrationService.sendTest(for: target.id)
                    }

                    Button(target.isEnabled ? "Disable" : "Enable") {
                        integrationService.setEnabled(!target.isEnabled, for: target.id)
                    }

                    Button("Delete Integration", role: .destructive) {
                        integrationService.delete(targetID: target.id)
                        dismiss()
                    }
                }

                Section("Delivery Log") {
                    if integrationService.deliveryRecords(for: target.id).isEmpty {
                        Text("No deliveries yet.")
                            .foregroundStyle(ThemeToken.textSecondary)
                    } else {
                        ForEach(integrationService.deliveryRecords(for: target.id), id: \.id) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(record.status.title)
                                    Spacer()
                                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(ThemeToken.textSecondary)
                                }

                                Text(record.summary)
                                    .font(.subheadline)

                                Text(record.destination)
                                    .font(.caption)
                                    .foregroundStyle(ThemeToken.textSecondary)

                                if let failureReason = record.failureReason {
                                    let failureStyle = record.status == .skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(ThemeToken.critical)
                                    Text(failureReason)
                                        .font(.caption)
                                        .foregroundStyle(failureStyle)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Integration not found.")
                    .foregroundStyle(ThemeToken.textSecondary)
            }
        }
        .navigationTitle(target?.name ?? "Integration")
    }

    private func destination(for target: IntegrationTarget) -> String {
        switch target.configuration {
        case .webhook(let configuration):
            return configuration.endpointDisplayHost
        case .slack(let configuration):
            return configuration.destinationLabel
        case .email(let configuration):
            return configuration.recipientAddresses.joined(separator: ", ")
        case .s3(let configuration):
            return configuration.bucket
        }
    }
}

private struct IntegrationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var integrationService = IntegrationService.shared

    let existingTarget: IntegrationTarget?

    @State private var type: IntegrationType = .webhook
    @State private var name: String = ""
    @State private var isEnabled = true
    @State private var minimumSeverity: EventSeverity = .warning
    @State private var selectedEventTypes: Set<MonitoringEventType> = Set(MonitoringEventType.filterable)
    @State private var s3Endpoint = ""
    @State private var s3Region = "us-east-1"
    @State private var s3Bucket = ""
    @State private var s3KeyPrefix = "domaindig"
    @State private var s3UsesPathStyle = false
    @State private var s3AccessKeyID = ""
    @State private var s3SecretAccessKey = ""
    @State private var s3Triggers: Set<S3ExportTrigger> = S3ExportTrigger.defaults
    @State private var s3ExtraFormats: Set<DomainExportFormat> = []
    @State private var domainsText = ""

    @State private var webhookURL = ""
    @State private var slackWebhookURL = ""
    @State private var emailHost = ""
    @State private var emailPort = "465"
    @State private var emailUsername = ""
    @State private var emailPassword = ""
    @State private var senderAddress = ""
    @State private var recipientAddresses = ""
    @State private var smtpSecurity: SMTPSecurityMode = .directTLS

    @State private var validationMessage: String?

    var body: some View {
        Form {
            Section("Integration") {
                AdaptivePicker("Type", selection: $type) {
                    ForEach(selectableTypes) { integrationType in
                        Text(integrationType.title).tag(integrationType)
                    }
                }
                .disabled(existingTarget != nil)

                if !FeatureAccessService.hasAccess(to: .bucketExport) {
                    Text("Export to your own bucket is \(FeatureAccessService.upgradeMessage(for: .bucketExport)).")
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)
                }

                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section("Routing Rules") {
                AdaptivePicker("Minimum Severity", selection: $minimumSeverity) {
                    ForEach(EventSeverity.allCases) { severity in
                        Text(severity.title).tag(severity)
                    }
                }

                TextField("Domains (comma-separated)", text: $domainsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                ForEach(MonitoringEventType.filterable, id: \.self) { eventType in
                    Toggle(
                        eventType.title,
                        isOn: Binding(
                            get: { selectedEventTypes.contains(eventType) },
                            set: { isSelected in
                                if isSelected {
                                    selectedEventTypes.insert(eventType)
                                } else {
                                    selectedEventTypes.remove(eventType)
                                }
                            }
                        )
                    )
                }
            }

            switch type {
            case .webhook:
                Section("Webhook") {
                    TextField("https://example.com/webhook", text: $webhookURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if existingTarget != nil {
                        Text("Saved webhook URL remains in Keychain unless you replace it.")
                            .font(.caption)
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
            case .slack:
                Section("Slack") {
                    TextField("https://hooks.slack.com/services/...", text: $slackWebhookURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if existingTarget != nil {
                        Text("Saved Slack webhook remains in Keychain unless you replace it.")
                            .font(.caption)
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
            case .email:
                Section("SMTP") {
                    TextField("SMTP Host", text: $emailHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $emailPort)
                        .keyboardType(.numberPad)

                    Text("Port 465 with Direct TLS is supported. Port 587 (STARTTLS) is not.")
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)

                    TextField("Username", text: $emailUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField(existingTarget == nil ? "Password" : "Replace Password", text: $emailPassword)

                    TextField("Sender Address", text: $senderAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    TextField("Recipients (comma-separated)", text: $recipientAddresses)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    AdaptivePicker("Security", selection: $smtpSecurity) {
                        ForEach(SMTPSecurityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if existingTarget != nil {
                        Text("Saved SMTP password remains in Keychain unless you replace it.")
                            .font(.caption)
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
            case .s3:
                Section("Bucket") {
                    TextField("https://s3.eu-central-1.amazonaws.com", text: $s3Endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Must be https. Signing puts your access key ID on the wire, and the signature with it.")
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)

                    TextField("Bucket", text: $s3Bucket)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Region", text: $s3Region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Key prefix", text: $s3KeyPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Path-style addressing", isOn: $s3UsesPathStyle)

                    Text("Addresses the bucket as endpoint/bucket/key. MinIO needs this, and so do R2 custom domains.")
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)
                }

                Section("Credentials") {
                    TextField("Access key ID", text: $s3AccessKeyID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField(
                        existingTarget == nil ? "Secret access key" : "Replace secret access key",
                        text: $s3SecretAccessKey
                    )

                    if existingTarget != nil {
                        Text("Saved secret access key remains in Keychain unless you replace it.")
                            .font(.caption)
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }

                Section("Upload when") {
                    ForEach(S3ExportTrigger.allCases) { trigger in
                        Toggle(
                            isOn: Binding(
                                get: { s3Triggers.contains(trigger) },
                                set: { isOn in
                                    if isOn {
                                        s3Triggers.insert(trigger)
                                    } else {
                                        s3Triggers.remove(trigger)
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trigger.title)
                                if let detail = trigger.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(ThemeToken.textSecondary)
                                }
                            }
                        }
                    }
                }

                Section("Formats") {
                    Text("JSON always uploads. The others are renderings of it.")
                        .font(.caption)
                        .foregroundStyle(ThemeToken.textSecondary)

                    ForEach([DomainExportFormat.pdf, .csv]) { format in
                        Toggle(
                            format.title,
                            isOn: Binding(
                                get: { s3ExtraFormats.contains(format) },
                                set: { isOn in
                                    if isOn {
                                        s3ExtraFormats.insert(format)
                                    } else {
                                        s3ExtraFormats.remove(format)
                                    }
                                }
                            )
                        )
                    }
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(ThemeToken.critical)
                }
            }
        }
        .navigationTitle(existingTarget == nil ? "Add Integration" : "Edit Integration")
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
            }
        }
        .onAppear {
            populateFromExisting()
        }
    }

    private func populateFromExisting() {
        guard let existingTarget else { return }
        type = existingTarget.type
        name = existingTarget.name
        isEnabled = existingTarget.isEnabled
        minimumSeverity = existingTarget.filters.minimumSeverity
        selectedEventTypes = existingTarget.filters.eventTypes
        domainsText = existingTarget.filters.domains.joined(separator: ", ")

        switch existingTarget.configuration {
        case .webhook:
            break
        case .slack:
            break
        case .email(let configuration):
            emailHost = configuration.smtpHost
            emailPort = String(configuration.port)
            emailUsername = configuration.username
            senderAddress = configuration.senderAddress
            recipientAddresses = configuration.recipientAddresses.joined(separator: ", ")
            smtpSecurity = configuration.securityMode
        case .s3(let configuration):
            s3Endpoint = configuration.endpoint
            s3Region = configuration.region
            s3Bucket = configuration.bucket
            s3KeyPrefix = configuration.keyPrefix
            s3UsesPathStyle = configuration.usesPathStyle
            s3AccessKeyID = configuration.accessKeyID
            s3Triggers = configuration.triggers
            s3ExtraFormats = configuration.extraFormats
        }
    }

    private func save() {
        validationMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Name is required."
            return
        }

        let filters = IntegrationFilterSet(
            minimumSeverity: minimumSeverity,
            eventTypes: selectedEventTypes,
            domains: domainsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        let targetID = existingTarget?.id ?? UUID()

        do {
            switch type {
            case .webhook:
                let existingReference: String? = {
                    guard case .webhook(let configuration) = existingTarget?.configuration else { return nil }
                    return configuration.credentialReference
                }()
                if webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existingReference == nil {
                    validationMessage = "Webhook URL is required."
                    return
                }

                let target = IntegrationTarget(
                    id: targetID,
                    type: .webhook,
                    name: trimmedName,
                    isEnabled: isEnabled,
                    configuration: .webhook(
                        WebhookIntegrationConfiguration(
                            endpointDisplayHost: existingWebhookDisplayHost(),
                            timeoutSeconds: 15,
                            additionalHeaders: [:],
                            credentialReference: existingReference
                        )
                    ),
                    filters: filters
                )
                try integrationService.upsert(
                    target: target,
                    webhookURL: webhookURL.nilIfBlank
                )
            case .slack:
                let existingReference: String? = {
                    guard case .slack(let configuration) = existingTarget?.configuration else { return nil }
                    return configuration.credentialReference
                }()
                if slackWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existingReference == nil {
                    validationMessage = "Slack webhook URL is required."
                    return
                }

                let target = IntegrationTarget(
                    id: targetID,
                    type: .slack,
                    name: trimmedName,
                    isEnabled: isEnabled,
                    configuration: .slack(
                        SlackIntegrationConfiguration(
                            destinationLabel: existingSlackDestination(),
                            credentialReference: existingReference
                        )
                    ),
                    filters: filters
                )
                try integrationService.upsert(
                    target: target,
                    slackWebhookURL: slackWebhookURL.nilIfBlank
                )
            case .email:
                guard let port = Int(emailPort) else {
                    validationMessage = "SMTP port must be a number."
                    return
                }

                let recipients = recipientAddresses
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let existingReference: String? = {
                    guard case .email(let configuration) = existingTarget?.configuration else { return nil }
                    return configuration.credentialReference
                }()
                if emailPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existingReference == nil {
                    validationMessage = "SMTP password is required."
                    return
                }
                if smtpSecurity != .directTLS, !emailUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    validationMessage = "A username needs Direct TLS, usually on port 465. Without it the password would be sent in cleartext."
                    return
                }

                let target = IntegrationTarget(
                    id: targetID,
                    type: .email,
                    name: trimmedName,
                    isEnabled: isEnabled,
                    configuration: .email(
                        EmailIntegrationConfiguration(
                            smtpHost: emailHost.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: port,
                            username: emailUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                            senderAddress: senderAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                            recipientAddresses: recipients,
                            securityMode: smtpSecurity,
                            credentialReference: existingReference
                        )
                    ),
                    filters: filters
                )
                try integrationService.upsert(
                    target: target,
                    emailPassword: emailPassword.nilIfBlank
                )
            case .s3:
                guard FeatureAccessService.hasAccess(to: .bucketExport) else {
                    validationMessage = "Export to your own bucket is \(FeatureAccessService.upgradeMessage(for: .bucketExport))."
                    return
                }

                let existingReference: String? = {
                    guard case .s3(let configuration) = existingTarget?.configuration else { return nil }
                    return configuration.credentialReference
                }()

                let trimmedBucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedBucket.isEmpty else {
                    validationMessage = "Bucket is required."
                    return
                }
                let trimmedAccessKeyID = s3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAccessKeyID.isEmpty else {
                    validationMessage = "Access key ID is required."
                    return
                }
                if s3SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existingReference == nil {
                    validationMessage = "Secret access key is required."
                    return
                }

                let target = IntegrationTarget(
                    id: targetID,
                    type: .s3,
                    name: trimmedName,
                    isEnabled: isEnabled,
                    configuration: .s3(
                        S3IntegrationConfiguration(
                            endpoint: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                            region: s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
                            bucket: trimmedBucket,
                            keyPrefix: s3KeyPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                            usesPathStyle: s3UsesPathStyle,
                            accessKeyID: trimmedAccessKeyID,
                            credentialReference: existingReference,
                            triggers: s3Triggers,
                            extraFormats: s3ExtraFormats
                        )
                    ),
                    filters: filters
                )
                try integrationService.upsert(
                    target: target,
                    s3SecretAccessKey: s3SecretAccessKey.nilIfBlank
                )
            }

            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    /// Bucket export is Pro+ (D1), so a tier without it does not get the
    /// option. An existing target keeps its type listed, so a downgrade leaves
    /// the editor readable rather than blank.
    private var selectableTypes: [IntegrationType] {
        IntegrationType.allCases.filter { integrationType in
            if integrationType == existingTarget?.type { return true }
            guard integrationType == .s3 else { return true }
            return FeatureAccessService.hasAccess(to: .bucketExport)
        }
    }

    private func existingWebhookDisplayHost() -> String {
        guard case .webhook(let configuration) = existingTarget?.configuration else {
            return ""
        }
        return configuration.endpointDisplayHost
    }

    private func existingSlackDestination() -> String {
        guard case .slack(let configuration) = existingTarget?.configuration else {
            return "Slack"
        }
        return configuration.destinationLabel
    }
}

private extension String {
}

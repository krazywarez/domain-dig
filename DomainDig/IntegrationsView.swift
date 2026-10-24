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
                        .foregroundStyle(Color(.appTextSecondary))
                }

                Button("Process Queue Now") {
                    integrationService.processQueueNow()
                }
            }

            Section("Targets") {
                if integrationService.targets.isEmpty {
                    Text("No integrations configured.")
                        .foregroundStyle(Color(.appTextSecondary))
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
                                        .foregroundStyle(Color(.appTextSecondary))
                                }

                                Text(summary(for: target))
                                    .font(.caption)
                                    .foregroundStyle(Color(.appTextSecondary))

                                if !target.isEnabled {
                                    Text("Disabled")
                                        .font(.caption2)
                                        .foregroundStyle(Color(.statusWarning))
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
                            .foregroundStyle(Color(.appTextSecondary))
                    } else {
                        ForEach(integrationService.deliveryRecords(for: target.id), id: \.id) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(record.status.title)
                                    Spacer()
                                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Color(.appTextSecondary))
                                }

                                Text(record.summary)
                                    .font(.subheadline)

                                Text(record.destination)
                                    .font(.caption)
                                    .foregroundStyle(Color(.appTextSecondary))

                                if let failureReason = record.failureReason {
                                    let failureColor: Color = record.status == .skipped ? .secondary : Color(.statusCritical)
                                    Text(failureReason)
                                        .font(.caption)
                                        .foregroundStyle(failureColor)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Integration not found.")
                    .foregroundStyle(Color(.appTextSecondary))
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
    @State private var selectedEventTypes: Set<MonitoringEventType> = Set(MonitoringEventType.allCases.filter { $0 != .test })
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
                Picker("Type", selection: $type) {
                    ForEach(IntegrationType.allCases) { integrationType in
                        Text(integrationType.title).tag(integrationType)
                    }
                }
                .disabled(existingTarget != nil)

                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section("Routing Rules") {
                Picker("Minimum Severity", selection: $minimumSeverity) {
                    ForEach(EventSeverity.allCases) { severity in
                        Text(severity.title).tag(severity)
                    }
                }

                TextField("Domains (comma-separated)", text: $domainsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                ForEach(MonitoringEventType.allCases.filter { $0 != .test }, id: \.self) { eventType in
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
                            .foregroundStyle(Color(.appTextSecondary))
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
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
            case .email:
                Section("SMTP") {
                    TextField("SMTP Host", text: $emailHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $emailPort)
                        .keyboardType(.numberPad)

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

                    Picker("Security", selection: $smtpSecurity) {
                        ForEach(SMTPSecurityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if existingTarget != nil {
                        Text("Saved SMTP password remains in Keychain unless you replace it.")
                            .font(.caption)
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(Color(.statusCritical))
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
            }

            dismiss()
        } catch {
            validationMessage = error.localizedDescription
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
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

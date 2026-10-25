import Foundation
import Network
import os
import Observation
import Security

@MainActor
@Observable
final class IntegrationService {
    static let shared = IntegrationService()

    var targets: [IntegrationTarget]
    var deliveryRecords: [DeliveryRecord]
    var queue: [QueuedDelivery]
    var statusMessage: String?

    private let defaults: UserDefaults
    private var processingTask: Task<Void, Never>?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targets = Self.loadTargets(defaults: defaults)
        self.deliveryRecords = Self.loadRecords(defaults: defaults)
        self.queue = Self.loadQueue(defaults: defaults)
    }

    func refresh() {
        targets = Self.loadTargets(defaults: defaults)
        deliveryRecords = Self.loadRecords(defaults: defaults)
        queue = Self.loadQueue(defaults: defaults)
    }

    func upsert(
        target: IntegrationTarget,
        webhookURL: String? = nil,
        slackWebhookURL: String? = nil,
        emailPassword: String? = nil,
        s3SecretAccessKey: String? = nil
    ) throws {
        var updatedTarget = target

        switch updatedTarget.configuration {
        case .webhook(var configuration):
            if let webhookURL {
                try Self.validateHTTPS(webhookURL)
                let reference = configuration.credentialReference ?? Self.secretReference(for: updatedTarget.id, suffix: "webhook")
                try IntegrationSecretStore.save(secret: webhookURL, reference: reference)
                configuration.credentialReference = reference
                configuration.endpointDisplayHost = Self.hostLabel(from: webhookURL)
                updatedTarget.configuration = .webhook(configuration)
            }
        case .slack(var configuration):
            if let slackWebhookURL {
                try Self.validateHTTPS(slackWebhookURL)
                let reference = configuration.credentialReference ?? Self.secretReference(for: updatedTarget.id, suffix: "slack")
                try IntegrationSecretStore.save(secret: slackWebhookURL, reference: reference)
                configuration.credentialReference = reference
                configuration.destinationLabel = Self.hostLabel(from: slackWebhookURL)
                updatedTarget.configuration = .slack(configuration)
            }
        case .email(var configuration):
            if let emailPassword {
                let reference = configuration.credentialReference ?? Self.secretReference(for: updatedTarget.id, suffix: "smtp")
                try IntegrationSecretStore.save(secret: emailPassword, reference: reference)
                configuration.credentialReference = reference
                updatedTarget.configuration = .email(configuration)
            }
        case .s3(var configuration):
            // Validated on every save, not only when a new key is supplied:
            // the endpoint is editable on its own, and an http endpoint would
            // put the access key ID and the signature on the wire in the
            // clear. F3's NSAllowsArbitraryLoads means nothing else stops it.
            try Self.validateHTTPS(configuration.endpoint)
            if let s3SecretAccessKey {
                let reference = configuration.credentialReference ?? Self.secretReference(for: updatedTarget.id, suffix: "s3")
                try IntegrationSecretStore.save(secret: s3SecretAccessKey, reference: reference)
                configuration.credentialReference = reference
            }
            updatedTarget.configuration = .s3(configuration)
        }

        if let index = targets.firstIndex(where: { $0.id == updatedTarget.id }) {
            targets[index] = updatedTarget
        } else {
            targets.append(updatedTarget)
        }
        targets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistTargets()
        statusMessage = "Saved integration settings."
    }

    func delete(targetID: UUID) {
        guard let target = targets.first(where: { $0.id == targetID }) else { return }
        deleteSecrets(for: target)
        targets.removeAll { $0.id == targetID }
        queue.removeAll { $0.integrationID == targetID }
        deliveryRecords.removeAll { $0.integrationID == targetID }
        persistTargets()
        persistQueue()
        persistRecords()
    }

    func setEnabled(_ isEnabled: Bool, for targetID: UUID) {
        guard let index = targets.firstIndex(where: { $0.id == targetID }) else { return }
        targets[index].isEnabled = isEnabled
        persistTargets()
    }

    func deliveryRecords(for targetID: UUID) -> [DeliveryRecord] {
        deliveryRecords
            .filter { $0.integrationID == targetID }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Queues an upload of each domain's latest report to every S3 target set
    /// to fire on `trigger`, one entry per configured format.
    ///
    /// Deliberately not routed through `enqueue(events:)`. That fans one event
    /// out to every target and applies each target's severity and event-type
    /// filters, which exist for alerts. Whether a completed run exports is a
    /// per-target setting, and a finished run is not an alert, so the filters
    /// must not decide it.
    ///
    /// One entry per format rather than one per report, so a PDF that fails to
    /// upload retries without re-sending the JSON that already landed.
    func enqueueExports(domains: [String], trigger: S3ExportTrigger) {
        guard FeatureAccessService.hasAccess(to: .bucketExport) else { return }

        var seen = Set<String>()
        let normalizedDomains = domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !normalizedDomains.isEmpty else { return }

        var queuedAny = false
        for target in targets {
            guard target.isEnabled, case .s3(let configuration) = target.configuration else { continue }
            guard configuration.uploads(on: trigger) else { continue }

            for domain in normalizedDomains {
                for format in configuration.formats {
                    queue.append(
                        QueuedDelivery(
                            integrationID: target.id,
                            event: MonitoringEvent(
                                type: .reportExported,
                                severity: .info,
                                domain: domain,
                                summary: "\(trigger.title): \(domain) as \(format.title)"
                            ),
                            export: ExportDelivery(format: format, trigger: trigger)
                        )
                    )
                    queuedAny = true
                }
            }
        }

        guard queuedAny else { return }
        persistQueue()
        scheduleProcessing()
    }

    func enqueue(events: [MonitoringEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            for target in targets {
                guard target.isEnabled else {
                    appendRecord(
                        DeliveryRecord(
                            integrationID: target.id,
                            eventID: event.id,
                            status: .skipped,
                            destination: destinationLabel(for: target),
                            summary: event.summary,
                            failureReason: Self.disabledTargetReason
                        )
                    )
                    continue
                }

                if let reason = filterMismatchReason(for: event, target: target) {
                    appendRecord(
                        DeliveryRecord(
                            integrationID: target.id,
                            eventID: event.id,
                            status: .skipped,
                            destination: destinationLabel(for: target),
                            summary: event.summary,
                            failureReason: reason
                        )
                    )
                    continue
                }

                queue.append(QueuedDelivery(integrationID: target.id, event: event))
                appendRecord(
                    DeliveryRecord(
                        integrationID: target.id,
                        eventID: event.id,
                        status: .pending,
                        destination: destinationLabel(for: target),
                        summary: event.summary
                    )
                )
            }
        }
        persistQueue()
        scheduleProcessing()
    }

    func recordNoOutboundEvents(for runSummary: String) {
        let eligibleTargets = targets.filter(\.isEnabled)
        for target in eligibleTargets {
            appendRecord(
                DeliveryRecord(
                    integrationID: target.id,
                    eventID: UUID(),
                    status: .skipped,
                    destination: destinationLabel(for: target),
                    summary: runSummary,
                    failureReason: "Monitoring run produced no outbound events."
                )
            )
        }
    }

    func sendTest(for targetID: UUID) {
        guard let target = targets.first(where: { $0.id == targetID }) else { return }
        let event = MonitoringEvent(
            type: .test,
            severity: .info,
            domain: "example.com",
            summary: "DomainDig integration test",
            details: [
                "source": "manual test",
                "environment": "local-first"
            ]
        )

        // Real events skip a disabled target, so a test event must too —
        // otherwise a test succeeds against a target that silently drops
        // everything monitoring sends it.
        guard target.isEnabled else {
            appendRecord(
                DeliveryRecord(
                    integrationID: target.id,
                    eventID: event.id,
                    status: .skipped,
                    destination: destinationLabel(for: target),
                    summary: event.summary,
                    failureReason: Self.disabledTargetReason
                )
            )
            return
        }

        queue.append(QueuedDelivery(integrationID: target.id, event: event))
        appendRecord(
            DeliveryRecord(
                integrationID: target.id,
                eventID: event.id,
                status: .pending,
                destination: destinationLabel(for: target),
                summary: event.summary
            )
        )
        persistQueue()
        scheduleProcessing()
    }

    /// Restarting the processing task alone leaves any item still in retry
    /// backoff undue, so the loop would skip it and sleep again. Pulling every
    /// queued item forward is what makes this button mean "now".
    func processQueueNow() {
        guard !queue.isEmpty else {
            statusMessage = "No deliveries are waiting."
            return
        }

        let now = Date()
        for index in queue.indices {
            queue[index].nextAttemptAt = now
        }
        persistQueue()
        scheduleProcessing(force: true)
    }

    func localSecretReferences() -> [String] {
        targets.compactMap { target in
            switch target.configuration {
            case .webhook(let configuration):
                configuration.credentialReference
            case .slack(let configuration):
                configuration.credentialReference
            case .email(let configuration):
                configuration.credentialReference
            case .s3(let configuration):
                configuration.credentialReference
            }
        }
    }

    func resetAfterLocalWipe() {
        processingTask?.cancel()
        processingTask = nil
        targets = []
        deliveryRecords = []
        queue = []
        statusMessage = nil
    }

    private func scheduleProcessing(force: Bool = false) {
        if force {
            processingTask?.cancel()
            processingTask = nil
        }
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processQueueLoop()
        }
    }

    private func processQueueLoop() async {
        defer { processingTask = nil }

        while true {
            let dueItems = queue
                .enumerated()
                .filter { $0.element.nextAttemptAt <= Date() }

            if dueItems.isEmpty {
                guard let nextAttemptAt = queue.map(\.nextAttemptAt).min() else {
                    break
                }

                let delay = max(0.25, nextAttemptAt.timeIntervalSinceNow)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } catch {
                    break
                }
            }

            for entry in dueItems.reversed() {
                guard entry.offset < queue.count else { continue }
                let item = queue[entry.offset]
                await process(item: item, at: entry.offset)
            }
        }
    }

    private func process(item: QueuedDelivery, at index: Int) async {
        guard let target = targets.first(where: { $0.id == item.integrationID }) else {
            queue.remove(at: index)
            persistQueue()
            return
        }

        guard item.expiresAt > Date() else {
            queue.remove(at: index)
            persistQueue()
            appendRecord(
                DeliveryRecord(
                    integrationID: target.id,
                    eventID: item.event.id,
                    status: .expired,
                    destination: destinationLabel(for: target),
                    summary: item.event.summary,
                    failureReason: "Delivery expired before succeeding.",
                    attemptCount: item.attemptCount
                )
            )
            return
        }

        do {
            try await deliver(item, to: target)
            queue.remove(at: index)
            persistQueue()
            appendRecord(
                DeliveryRecord(
                    integrationID: target.id,
                    eventID: item.event.id,
                    status: .delivered,
                    destination: destinationLabel(for: target),
                    summary: item.event.summary,
                    attemptCount: item.attemptCount + 1
                )
            )
            statusMessage = "Delivered \(item.event.summary)."
        } catch {
            var updated = item
            updated.attemptCount += 1
            updated.lastError = error.localizedDescription

            if updated.attemptCount >= 5 {
                queue.remove(at: index)
                appendRecord(
                    DeliveryRecord(
                        integrationID: target.id,
                        eventID: item.event.id,
                        status: .failed,
                        destination: destinationLabel(for: target),
                        summary: item.event.summary,
                        failureReason: error.localizedDescription,
                        attemptCount: updated.attemptCount
                    )
                )
            } else {
                let backoff = min(pow(2, Double(updated.attemptCount)) * 30, 3600)
                updated.nextAttemptAt = Date().addingTimeInterval(backoff)
                queue[index] = updated
                appendRecord(
                    DeliveryRecord(
                        integrationID: target.id,
                        eventID: item.event.id,
                        status: .retrying,
                        destination: destinationLabel(for: target),
                        summary: item.event.summary,
                        failureReason: error.localizedDescription,
                        attemptCount: updated.attemptCount
                    )
                )
            }

            persistQueue()
            statusMessage = error.localizedDescription
        }
    }

    private func deliver(_ item: QueuedDelivery, to target: IntegrationTarget) async throws {
        let event = item.event
        switch target.configuration {
        case .webhook(let configuration):
            guard let reference = configuration.credentialReference else {
                throw IntegrationError.missingSecret
            }
            let webhookURLString = try IntegrationSecretStore.secret(reference: reference)
            try await HTTPIntegrationClient.sendJSON(
                payload: IntegrationEventPayload(event: event),
                to: webhookURLString,
                headers: configuration.additionalHeaders,
                timeoutSeconds: configuration.timeoutSeconds
            )
        case .slack(let configuration):
            guard let reference = configuration.credentialReference else {
                throw IntegrationError.missingSecret
            }
            let webhookURLString = try IntegrationSecretStore.secret(reference: reference)
            try await HTTPIntegrationClient.sendJSON(
                payload: SlackPayload(event: event),
                to: webhookURLString,
                headers: [:],
                timeoutSeconds: 15
            )
        case .s3(let configuration):
            guard let reference = configuration.credentialReference else {
                throw IntegrationError.missingSecret
            }
            let secretAccessKey = try IntegrationSecretStore.secret(reference: reference)
            let object = try Self.s3Object(for: item, configuration: configuration)
            let request = try S3UploadClient.request(
                for: object,
                configuration: configuration,
                credentials: AWSSigV4.Credentials(
                    accessKeyID: configuration.accessKeyID,
                    secretAccessKey: secretAccessKey
                ),
                now: Date()
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try S3UploadClient.validate(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: data
            )
        case .email(let configuration):
            guard let reference = configuration.credentialReference else {
                throw IntegrationError.missingSecret
            }
            let password = try IntegrationSecretStore.secret(reference: reference)
            try await SMTPClient.send(
                event: event,
                configuration: configuration,
                password: password
            )
        }
    }

    private func appendRecord(_ record: DeliveryRecord) {
        deliveryRecords.insert(record, at: 0)
        deliveryRecords = Array(deliveryRecords.prefix(250))
        persistRecords()
    }

    private func persistTargets() {
        Self.save(targets, key: StorageKey.targets, defaults: defaults)
    }

    private func persistRecords() {
        Self.save(deliveryRecords, key: StorageKey.records, defaults: defaults)
    }

    private func persistQueue() {
        Self.save(queue, key: StorageKey.queue, defaults: defaults)
    }

    /// The object to upload.
    ///
    /// An export entry names its format and renders the domain's latest stored
    /// report in it. Anything else — a test delivery, or an event on a target
    /// with no report to find — uploads the event as JSON, which is what makes
    /// the test action prove the endpoint, the signature and the bucket policy
    /// without needing a lookup first.
    ///
    /// The key is `{prefix}/{domain}/{iso8601}.{ext}`, the prefix coming from
    /// the configuration.
    private static func s3Object(
        for item: QueuedDelivery,
        configuration: S3IntegrationConfiguration
    ) throws -> S3UploadClient.Object {
        let event = item.event
        let domain = event.domain.isEmpty ? "unknown" : event.domain
        let timestamp = Self.objectTimestampFormatter.string(from: event.timestamp)
        let report = Self.latestReport(for: domain)

        if let export = item.export, let report {
            return S3UploadClient.Object(
                key: "\(domain)/\(timestamp).\(export.format.fileExtension)",
                body: try DomainReportExporter.data(for: report, format: export.format),
                contentType: export.format.mimeType
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let body: Data
        if let report, let encoded = try? encoder.encode(report) {
            body = encoded
        } else {
            body = (try? encoder.encode(IntegrationEventPayload(event: event))) ?? Data()
        }
        return S3UploadClient.Object(
            key: "\(domain)/\(timestamp).json",
            body: body,
            contentType: DomainExportFormat.json.mimeType
        )
    }

    private static func latestReport(for domain: String) -> DomainReport? {
        guard let snapshot = MonitoringStorage.loadHistoryEntries()
            .first(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame })?
            .snapshot
        else {
            return nil
        }
        return DomainReportBuilder().build(from: snapshot)
    }

    private static let objectTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func deleteSecrets(for target: IntegrationTarget) {
        switch target.configuration {
        case .webhook(let configuration):
            if let reference = configuration.credentialReference {
                try? IntegrationSecretStore.delete(reference: reference)
            }
        case .slack(let configuration):
            if let reference = configuration.credentialReference {
                try? IntegrationSecretStore.delete(reference: reference)
            }
        case .email(let configuration):
            if let reference = configuration.credentialReference {
                try? IntegrationSecretStore.delete(reference: reference)
            }
        case .s3(let configuration):
            if let reference = configuration.credentialReference {
                try? IntegrationSecretStore.delete(reference: reference)
            }
        }
    }

    private func destinationLabel(for target: IntegrationTarget) -> String {
        switch target.configuration {
        case .webhook(let configuration):
            return configuration.endpointDisplayHost.isEmpty ? target.name : configuration.endpointDisplayHost
        case .slack(let configuration):
            return configuration.destinationLabel
        case .email(let configuration):
            return configuration.recipientAddresses.joined(separator: ", ")
        case .s3(let configuration):
            return configuration.bucket.isEmpty ? target.name : configuration.bucket
        }
    }

    private func filterMismatchReason(for event: MonitoringEvent, target: IntegrationTarget) -> String? {
        let filters = target.filters

        if event.severity < filters.minimumSeverity {
            return "Filtered by severity. Event was \(event.severity.title), target requires \(filters.minimumSeverity.title)."
        }

        if !filters.eventTypes.isEmpty, !filters.eventTypes.contains(event.type) {
            return "Filtered by event type. Event was \(event.type.title)."
        }

        if !filters.domains.isEmpty, !filters.domains.map({ $0.lowercased() }).contains(event.domain.lowercased()) {
            return "Filtered by domain. Event was for \(event.domain)."
        }

        return nil
    }

    private static func hostLabel(from string: String) -> String {
        URL(string: string)?.host ?? "Configured"
    }

    private static let disabledTargetReason = "This integration is disabled."

    private static func secretReference(for integrationID: UUID, suffix: String) -> String {
        "integration.\(integrationID.uuidString).\(suffix)"
    }

    private static func validateHTTPS(_ string: String) throws {
        guard let url = URL(string: string) else {
            throw IntegrationError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw IntegrationError.insecureURL
        }
    }

    private static func loadTargets(defaults: UserDefaults) -> [IntegrationTarget] {
        load([IntegrationTarget].self, key: StorageKey.targets, defaults: defaults) ?? []
    }

    private static func loadRecords(defaults: UserDefaults) -> [DeliveryRecord] {
        load([DeliveryRecord].self, key: StorageKey.records, defaults: defaults) ?? []
    }

    private static func loadQueue(defaults: UserDefaults) -> [QueuedDelivery] {
        load([QueuedDelivery].self, key: StorageKey.queue, defaults: defaults) ?? []
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private enum StorageKey {
        static let targets = "integrations.targets"
        static let records = "integrations.records"
        static let queue = "integrations.queue"
    }
}

private struct IntegrationEventPayload: Encodable {
    let eventType: String
    let domain: String
    let timestamp: Date
    let severity: String
    let summary: String
    let details: [String: String]

    init(event: MonitoringEvent) {
        self.eventType = event.type.rawValue
        self.domain = event.domain
        self.timestamp = event.timestamp
        self.severity = event.severity.rawValue
        self.summary = event.summary
        self.details = event.details
    }
}

private struct SlackPayload: Encodable {
    let text: String
    let blocks: [SlackBlock]

    init(event: MonitoringEvent) {
        let title = "\(event.severity.title.uppercased()) • \(event.domain)"
        let detailLines = event.details
            .sorted { $0.key < $1.key }
            .prefix(6)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        self.text = "\(title) — \(event.summary)"
        self.blocks = [
            SlackBlock(
                type: "section",
                text: .init(type: "mrkdwn", text: "*\(title)*\n\(event.summary)")
            ),
            SlackBlock(
                type: "section",
                text: .init(
                    type: "mrkdwn",
                    text: "*Event*: \(event.type.title)\n*Timestamp*: \(event.timestamp.formatted(date: .abbreviated, time: .shortened))"
                )
            ),
            SlackBlock(
                type: "section",
                text: .init(type: "mrkdwn", text: detailLines.isEmpty ? "_No extra details_" : detailLines)
            )
        ]
    }
}

private struct SlackBlock: Encodable {
    let type: String
    let text: SlackText
}

private struct SlackText: Encodable {
    let type: String
    let text: String
}

private enum IntegrationError: LocalizedError {
    case invalidURL
    case insecureURL
    case missingSecret
    case invalidResponse(Int)
    case invalidSMTPPort
    case insecureCredentials
    case smtp(String)
    case streamClosed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The integration URL is invalid."
        case .insecureURL:
            return "The integration URL must use https. A webhook URL is itself a secret, so http would send it in cleartext."
        case .missingSecret:
            return "This integration is missing a saved secret."
        case .invalidResponse(let statusCode):
            return "The remote endpoint returned \(statusCode)."
        case .invalidSMTPPort:
            return "The SMTP port is invalid."
        case .insecureCredentials:
            return "SMTP credentials cannot be sent over an unencrypted connection. Use Direct TLS, usually on port 465."
        case .smtp(let message):
            return message
        case .streamClosed:
            return "The SMTP connection closed unexpectedly."
        }
    }
}

private enum HTTPIntegrationClient {
    static func sendJSON<T: Encodable>(
        payload: T,
        to urlString: String,
        headers: [String: String],
        timeoutSeconds: Double
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw IntegrationError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw IntegrationError.insecureURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntegrationError.invalidResponse(-1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw IntegrationError.invalidResponse(httpResponse.statusCode)
        }
    }
}

private enum IntegrationSecretStore {
    static func save(secret: String, reference: String) throws {
        guard GenericPasswordKeychain.save(secret, reference: reference) else {
            throw IntegrationError.smtp("Could not save integration secret.")
        }
    }

    static func secret(reference: String) throws -> String {
        guard let secret = GenericPasswordKeychain.secret(reference: reference) else {
            throw IntegrationError.missingSecret
        }
        return secret
    }

    static func delete(reference: String) throws {
        GenericPasswordKeychain.delete(reference: reference)
    }
}

/// Message construction rules the SMTP wire format imposes. Internal so the
/// tests can reach them; `SMTPClient` itself is file-private.
enum SMTPMessage {
    /// `nil` when a value cannot appear in a header. A bare CR or LF ends the
    /// header line, and whatever follows is read as further headers — so a
    /// domain or address carrying one could add a Bcc the user never wrote.
    static func validatedHeaderValue(_ value: String) -> String? {
        value.rangeOfCharacter(from: .newlines) == nil ? value : nil
    }

    /// RFC 5321 section 4.5.2. A body line of "." alone ends the DATA command,
    /// after which the rest of the message is read as SMTP commands, so every
    /// line beginning with "." is sent doubled.
    static func dotStuffed(_ body: String) -> String {
        body
            .components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
    }
}

private enum SMTPClient {
    static func send(
        event: MonitoringEvent,
        configuration: EmailIntegrationConfiguration,
        password: String
    ) async throws {
        // `UInt16(_:)` traps above 65535, which the editor's port field allows.
        guard let portNumber = UInt16(exactly: configuration.port),
              let port = NWEndpoint.Port(rawValue: portNumber) else {
            throw IntegrationError.invalidSMTPPort
        }

        // AUTH LOGIN sends the username and password base64-encoded, which is
        // not encryption. Without TLS from the first byte they would go out in
        // the clear, so refuse before the connection opens. STARTTLS is not an
        // option here: NWConnection cannot upgrade an established connection.
        guard configuration.username.isEmpty || configuration.securityMode == .directTLS else {
            throw IntegrationError.insecureCredentials
        }

        let parameters: NWParameters = {
            switch configuration.securityMode {
            case .plain:
                return .tcp
            case .directTLS:
                let tls = NWProtocolTLS.Options()
                return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            }
        }()

        let channel = SMTPChannel(host: configuration.smtpHost, port: port, parameters: parameters)
        try await channel.start()
        _ = try await channel.readResponse(expecting: [220])
        _ = try await channel.sendCommand("EHLO domaindig.local", expecting: [250])

        if !configuration.username.isEmpty {
            _ = try await channel.sendCommand("AUTH LOGIN", expecting: [334])
            _ = try await channel.sendCommand(Data(configuration.username.utf8).base64EncodedString(), expecting: [334])
            _ = try await channel.sendCommand(Data(password.utf8).base64EncodedString(), expecting: [235])
        }

        _ = try await channel.sendCommand("MAIL FROM:<\(configuration.senderAddress)>", expecting: [250])
        for recipient in configuration.recipientAddresses {
            _ = try await channel.sendCommand("RCPT TO:<\(recipient)>", expecting: [250, 251])
        }
        _ = try await channel.sendCommand("DATA", expecting: [354])

        let detailLines = event.details
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        let recipientList = configuration.recipientAddresses.joined(separator: ", ")
        let subject = "[DomainDig] \(event.severity.title) \(event.domain) \(event.type.title)"
        guard SMTPMessage.validatedHeaderValue(configuration.senderAddress) != nil,
              SMTPMessage.validatedHeaderValue(recipientList) != nil,
              SMTPMessage.validatedHeaderValue(subject) != nil else {
            throw IntegrationError.smtp("The message could not be built: an address or the domain contains a line break.")
        }

        let body = [
            "From: DomainDig <\(configuration.senderAddress)>",
            "To: \(recipientList)",
            "Subject: \(subject)",
            "Date: \(DateFormatter.rfc2822.string(from: Date()))",
            "",
            event.summary,
            "",
            "Domain: \(event.domain)",
            "Severity: \(event.severity.title)",
            "Event: \(event.type.title)",
            "Timestamp: \(event.timestamp.formatted(date: .abbreviated, time: .shortened))",
            detailLines
        ]
        .joined(separator: "\r\n")

        try await channel.sendRaw(SMTPMessage.dotStuffed(body) + "\r\n.\r\n")
        _ = try await channel.readResponse(expecting: [250])
        _ = try await channel.sendCommand("QUIT", expecting: [221])
        await channel.cancel()
    }
}

/// An actor, not a MainActor class. The previous shape inherited the project's
/// MainActor default while running its receive loop on a background dispatch
/// queue, so `parsedLines`/`lineWaiters`/`receiveBuffer` were declared
/// main-actor-protected and mutated off it — concurrent mutation while resuming
/// a `CheckedContinuation` can double-resume, which traps. The actor serialises
/// all of it and forces the Network callbacks to hop in explicitly. (Issue #27.)
private actor SMTPChannel {
    private let connection: NWConnection
    private var parsedLines: [String] = []
    private var lineWaiters: [CheckedContinuation<String, Error>] = []
    private var receiveBuffer = Data()

    init(host: String, port: NWEndpoint.Port, parameters: NWParameters) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The state handler can fire `.ready` and later `.failed` (or
            // `.failed` twice); resuming a continuation twice traps. The lock
            // also keeps the closure Sendable-clean without touching actor state
            // from the connection's queue.
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                guard let outcome = Self.startOutcome(for: state) else { return }
                let isFirst = hasResumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if isFirst { continuation.resume(with: outcome) }
            }
            connection.start(queue: .global(qos: .utility))
        }
        // Started from the actor once the connection is ready, replacing the old
        // dispatch-queue hop. TCP buffers anything that arrives in the gap.
        startReceiveLoop()
    }

    /// How a connection state settles `start()`: ready succeeds, failure or
    /// cancellation throws, and anything else is still in progress.
    private static func startOutcome(for state: NWConnection.State) -> Result<Void, Error>? {
        switch state {
        case .ready:
            return .success(())
        case .failed(let error):
            return .failure(error)
        case .cancelled:
            return .failure(IntegrationError.streamClosed)
        default:
            return nil
        }
    }

    func cancel() {
        connection.cancel()
    }

    func sendCommand(_ command: String, expecting codes: Set<Int>) async throws -> String {
        try await sendRaw(command + "\r\n")
        return try await readResponse(expecting: codes)
    }

    func sendCommand(_ command: String, expecting codes: [Int]) async throws -> String {
        try await sendCommand(command, expecting: Set(codes))
    }

    func sendRaw(_ string: String) async throws {
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readResponse(expecting codes: Set<Int>) async throws -> String {
        var lines: [String] = []

        while true {
            let line = try await readLine()
            lines.append(line)

            guard line.count >= 4,
                  let code = Int(line.prefix(3)) else {
                continue
            }

            let delimiterIndex = line.index(line.startIndex, offsetBy: 3)
            if line[delimiterIndex] == " " {
                guard codes.contains(code) else {
                    throw IntegrationError.smtp(line)
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    private func readLine() async throws -> String {
        if !parsedLines.isEmpty {
            return parsedLines.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            lineWaiters.append(continuation)
        }
    }

    private func startReceiveLoop() {
        // The completion runs on the connection's queue; hop back onto the
        // actor before touching any state.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: Error?) {
        if let error {
            failWaiters(with: error)
            return
        }

        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            flushBuffer()
        }

        if isComplete {
            failWaiters(with: IntegrationError.streamClosed)
            return
        }

        startReceiveLoop()
    }

    private func flushBuffer() {
        let delimiter = Data("\r\n".utf8)
        while let range = receiveBuffer.range(of: delimiter) {
            let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if !lineWaiters.isEmpty {
                let continuation = lineWaiters.removeFirst()
                continuation.resume(returning: line)
            } else {
                parsedLines.append(line)
            }
        }
    }

    private func failWaiters(with error: Error) {
        let waiters = lineWaiters
        lineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

private extension DateFormatter {
    static let rfc2822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

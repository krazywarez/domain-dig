import Foundation
import Network
import Observation
import Security

private enum LocalAPIServerError: LocalizedError {
    case missingSecret
    case secretPersistenceFailed
    case serverStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSecret:
            return "Local API token is unavailable."
        case .secretPersistenceFailed:
            return "Could not store the Local API token in Keychain."
        case .serverStartFailed(let message):
            return message
        }
    }
}

private final class ListenerResumeState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var hasResumed = false

    nonisolated func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

@MainActor
@Observable
final class LocalAPIService {
    static let shared = LocalAPIService()

    private static let configDefaultsKey = "localAPI.config"
    private static let logsDefaultsKey = "localAPI.requestLogs"
    private static let maxRequestLogs = 120
    private(set) var config: LocalAPIConfig
    private(set) var requestLogs: [APIRequestLog]
    private(set) var isRunning = false
    private(set) var boundPort: Int?
    private(set) var statusMessage: String?

    private var server: LocalAPIServer?

    private init() {
        config = Self.loadConfig()
        requestLogs = Self.loadRequestLogs()
    }

    var address: String {
        "http://127.0.0.1:\(boundPort ?? config.port)"
    }

    var maskedToken: String {
        guard !config.token.isEmpty else { return "Unavailable" }
        let suffix = String(config.token.suffix(8))
        return "••••••••\(suffix)"
    }

    func refresh() {
        config = Self.loadConfig()
        requestLogs = Self.loadRequestLogs()

        Task {
            if config.isEnabled {
                await startServerIfNeeded()
            } else {
                stopServer()
            }
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        config.isEnabled = isEnabled
        persistConfig()

        Task {
            if isEnabled {
                await startServer(forceRestart: true)
            } else {
                stopServer()
            }
        }
    }

    func setPort(_ port: Int) {
        let sanitizedPort = Self.sanitizedPort(port)
        guard config.port != sanitizedPort else { return }
        config.port = sanitizedPort
        persistConfig()

        Task {
            guard config.isEnabled else { return }
            await startServer(forceRestart: true)
        }
    }

    func setRequestLoggingEnabled(_ isEnabled: Bool) {
        config.requestLoggingEnabled = isEnabled
        persistConfig()
    }

    func rotateToken() {
        config.token = Self.generateToken()
        persistConfig()

        Task {
            guard config.isEnabled else { return }
            await startServer(forceRestart: true)
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        boundPort = nil
        if config.isEnabled {
            statusMessage = "Stopped"
        } else {
            statusMessage = "Disabled"
        }
    }

    func clearRequestLogs() {
        requestLogs.removeAll()
        Self.saveRequestLogs([])
    }

    func copyToken() {
        guard !config.token.isEmpty else { return }
        AppClipboard.copy(config.token)
    }

    func copyCurlCommand() {
        guard !config.token.isEmpty else { return }
        AppClipboard.copy("curl -H \"Authorization: Bearer \(config.token)\" \(address)/portfolio")
    }

    func localSecretReferences() -> [String] {
        [LocalAPISecretStore.reference]
    }

    func resetAfterLocalWipe() {
        stopServer()
        config = LocalAPIConfig(token: Self.generateToken())
        requestLogs = []
        persistConfig()
        clearRequestLogs()
    }

    private func startServerIfNeeded() async {
        guard config.isEnabled else {
            stopServer()
            return
        }
        guard server == nil else { return }
        await startServer(forceRestart: false)
    }

    private func startServer(forceRestart: Bool) async {
        if forceRestart {
            stopServer()
        }

        guard config.isEnabled else {
            stopServer()
            return
        }

        let token = config.token.isEmpty ? Self.generateToken() : config.token
        if token != config.token {
            config.token = token
            persistConfig()
        }

        let server = LocalAPIServer(
            port: Self.sanitizedPort(config.port),
            token: token,
            requestLogger: { [weak self] log in
                guard let self else { return }
                Task { @MainActor in
                    self.record(log)
                }
            },
            stateLogger: { [weak self] stateMessage in
                guard let self else { return }
                Task { @MainActor in
                    self.statusMessage = stateMessage
                }
            }
        )

        do {
            let activePort = try await server.start()
            self.server = server
            boundPort = activePort
            isRunning = true
            statusMessage = "Listening on localhost:\(activePort)"
        } catch {
            self.server = nil
            boundPort = nil
            isRunning = false
            statusMessage = error.localizedDescription
        }
    }

    private func record(_ log: APIRequestLog) {
        guard config.requestLoggingEnabled else { return }
        requestLogs.insert(log, at: 0)
        requestLogs = Array(requestLogs.prefix(Self.maxRequestLogs))
        Self.saveRequestLogs(requestLogs)
    }

    private func persistConfig() {
        config.port = Self.sanitizedPort(config.port)
        if config.token.isEmpty {
            config.token = Self.generateToken()
        }

        Self.saveConfig(config)
    }

    private static func loadConfig(defaults: UserDefaults = .standard) -> LocalAPIConfig {
        let persisted: PersistedLocalAPIConfig
        if let data = defaults.data(forKey: configDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedLocalAPIConfig.self, from: data) {
            persisted = decoded
        } else {
            persisted = PersistedLocalAPIConfig()
        }

        let token = (try? LocalAPISecretStore.secret(reference: LocalAPISecretStore.reference)) ?? generateToken()
        if (try? LocalAPISecretStore.secret(reference: LocalAPISecretStore.reference)) == nil {
            try? LocalAPISecretStore.save(secret: token, reference: LocalAPISecretStore.reference)
        }

        return LocalAPIConfig(
            isEnabled: persisted.isEnabled,
            port: sanitizedPort(persisted.port),
            token: token,
            requestLoggingEnabled: persisted.requestLoggingEnabled
        )
    }

    private static func saveConfig(_ config: LocalAPIConfig, defaults: UserDefaults = .standard) {
        let persisted = PersistedLocalAPIConfig(
            isEnabled: config.isEnabled,
            port: sanitizedPort(config.port),
            requestLoggingEnabled: config.requestLoggingEnabled
        )

        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: configDefaultsKey)
        }

        try? LocalAPISecretStore.save(secret: config.token, reference: LocalAPISecretStore.reference)
    }

    private static func loadRequestLogs(defaults: UserDefaults = .standard) -> [APIRequestLog] {
        guard let data = defaults.data(forKey: logsDefaultsKey),
              let decoded = try? JSONDecoder().decode([APIRequestLog].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveRequestLogs(_ logs: [APIRequestLog], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(Array(logs.prefix(maxRequestLogs))) {
            defaults.set(data, forKey: logsDefaultsKey)
        }
    }

    private static func sanitizedPort(_ port: Int) -> Int {
        min(max(port, 1024), 65535)
    }

    private static func generateToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max) }
        let data = Data(bytes)
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct PersistedLocalAPIConfig: Codable {
        var isEnabled: Bool = false
        var port: Int = 47821
        var requestLoggingEnabled: Bool = true
    }

    private enum LocalAPISecretStore {
        static let reference = "DomainDig.LocalAPI.Token"

        static func save(secret: String, reference: String) throws {
            guard GenericPasswordKeychain.save(secret, reference: reference) else {
                throw LocalAPIServerError.secretPersistenceFailed
            }
        }

        static func secret(reference: String) throws -> String {
            guard let secret = GenericPasswordKeychain.secret(reference: reference) else {
                throw LocalAPIServerError.missingSecret
            }
            return secret
        }

        static func delete(reference: String) throws {
            GenericPasswordKeychain.delete(reference: reference)
        }
    }

}

private final class LocalAPIServer: @unchecked Sendable {
    private let port: Int
    private let token: String
    private let requestLogger: @Sendable (APIRequestLog) -> Void
    private let stateLogger: @Sendable (String) -> Void
    private let handler = LocalAPIRequestHandler()
    private let queue = DispatchQueue(label: "DomainDig.LocalAPIServer")

    private var listener: NWListener?

    init(
        port: Int,
        token: String,
        requestLogger: @escaping @Sendable (APIRequestLog) -> Void,
        stateLogger: @escaping @Sendable (String) -> Void
    ) {
        self.port = port
        self.token = token
        self.requestLogger = requestLogger
        self.stateLogger = stateLogger
    }

    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
            )
        } catch {
            stateLogger("Failed: \(error.localizedDescription)")
            throw LocalAPIServerError.serverStartFailed(
                "Could not start Local API on port \(port): \(error.localizedDescription)"
            )
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handle(connection: connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ListenerResumeState()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeState.beginResume() else { return }
                    continuation.resume(returning: Int(listener.port?.rawValue ?? UInt16(self.port)))
                case .failed(let error):
                    self.stateLogger("Failed: \(error.localizedDescription)")
                    guard resumeState.beginResume() else { return }
                    continuation.resume(throwing: LocalAPIServerError.serverStartFailed(error.localizedDescription))
                case .cancelled:
                    self.stateLogger("Stopped")
                default:
                    break
                }
            }

            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) async {
        connection.start(queue: queue)
        let startedAt = Date()

        do {
            let requestData = try await readCompleteRequest(from: connection)
            let request = try LocalAPIHTTPParser.parseRequest(from: requestData)
            let response = await handler.handle(request: request, expectedToken: token)
            let log = APIRequestLog(
                timestamp: startedAt,
                method: request.method,
                path: request.pathWithQuery,
                statusCode: response.statusCode,
                duration: Date().timeIntervalSince(startedAt)
            )
            requestLogger(log)
            try await send(response.serialized(), on: connection)
        } catch let error as LocalAPIHTTPParser.ParserError {
            let response = LocalAPIHTTPResponse.error(statusCode: 400, code: "bad_request", message: error.localizedDescription)
            let log = APIRequestLog(
                timestamp: startedAt,
                method: "INVALID",
                path: "/",
                statusCode: response.statusCode,
                duration: Date().timeIntervalSince(startedAt)
            )
            requestLogger(log)
            try? await send(response.serialized(), on: connection)
        } catch {
            let response = LocalAPIHTTPResponse.error(statusCode: 500, code: "internal_error", message: "The Local API request failed.")
            let log = APIRequestLog(
                timestamp: startedAt,
                method: "ERROR",
                path: "/",
                statusCode: response.statusCode,
                duration: Date().timeIntervalSince(startedAt)
            )
            requestLogger(log)
            try? await send(response.serialized(), on: connection)
        }

        connection.cancel()
    }

    private func readCompleteRequest(from connection: NWConnection, accumulated: Data = Data()) async throws -> Data {
        let chunk = try await receiveChunk(from: connection)
        let combined = accumulated + chunk.data

        if LocalAPIHTTPParser.isCompleteRequest(combined) || chunk.isComplete {
            return combined
        }

        return try await readCompleteRequest(from: connection, accumulated: combined)
    }

    private func receiveChunk(from connection: NWConnection) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

/// The `v1` routes. Matching is separated from execution so the table can be
/// exercised without reading the store or reaching the network, and so adding a
/// route cannot silently shadow an existing one.
enum LocalAPIRoute: Equatable {
    case portfolio
    case domains
    case domainDetails(String)
    case domainHistory(String)
    case events
    case monitoring
    case inspectFromBody
    case inspect(String)
    case setMonitoring(domain: String, enabled: Bool)

    static func match(method: String, pathComponents: [String]) -> LocalAPIRoute? {
        switch (method, pathComponents.first, pathComponents.count) {
        case ("GET", "portfolio", 1):
            return .portfolio
        case ("GET", "domains", 1):
            return .domains
        case ("GET", "domains", 2):
            return .domainDetails(pathComponents[1])
        case ("GET", "domains", 3) where pathComponents[2] == "history":
            return .domainHistory(pathComponents[1])
        case ("GET", "events", 1):
            return .events
        case ("GET", "monitoring", 1):
            return .monitoring
        case ("POST", "inspect", 1):
            return .inspectFromBody
        case ("POST", "inspect", 2):
            return .inspect(pathComponents[1])
        case ("POST", "monitoring", 3) where pathComponents[2] == "enable":
            return .setMonitoring(domain: pathComponents[1], enabled: true)
        case ("POST", "monitoring", 3) where pathComponents[2] == "disable":
            return .setMonitoring(domain: pathComponents[1], enabled: false)
        default:
            return nil
        }
    }
}

struct LocalAPIRequestHandler {
    private let encoder = LocalAPIContract.makeEncoder()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let inspectionService = DomainInspectionService()
    private let reportBuilder = DomainReportBuilder()

    func handle(request: LocalAPIHTTPRequest, expectedToken: String) async -> LocalAPIHTTPResponse {
        guard Self.isAuthorized(request: request, expectedToken: expectedToken) else {
            return .error(statusCode: 401, code: "unauthorized", message: "A valid local API token is required.")
        }

        guard let route = LocalAPIRoute.match(method: request.method, pathComponents: request.pathComponents) else {
            return .error(statusCode: 404, code: "not_found", message: "The requested Local API route does not exist.")
        }

        switch route {
        case .portfolio:
            return successResponse(PortfolioPayload(summary: buildPortfolioSummary()))
        case .domains:
            return successResponse(DomainListPayload(domains: DomainDataPortabilityService.loadTrackedDomains()))
        case let .domainDetails(domain):
            return domainDetailsResponse(for: domain)
        case let .domainHistory(domain):
            return successResponse(DomainHistoryPayload(domain: normalizedDomain(domain), history: historyEntries(for: domain)))
        case .events:
            return successResponse(RecentEventsPayload(events: recentEvents()))
        case .monitoring:
            return successResponse(monitoringPayload())
        case .inspectFromBody:
            return await inspectBodyResponse(request.body)
        case let .inspect(domain):
            return await inspectResponse(for: domain)
        case let .setMonitoring(domain, enabled):
            return await setMonitoring(enabled: enabled, for: domain)
        }
    }

    static func isAuthorized(request: LocalAPIHTTPRequest, expectedToken: String) -> Bool {
        guard !expectedToken.isEmpty else { return false }

        if request.headers["x-api-token"] == expectedToken {
            return true
        }

        if let authorization = request.headers["authorization"],
           authorization == "Bearer \(expectedToken)" {
            return true
        }

        return false
    }

    private func successResponse<Value: Encodable>(_ value: Value) -> LocalAPIHTTPResponse {
        let envelope = LocalAPIEnvelope(success: true, data: value, error: nil, version: LocalAPIContract.version)
        guard let body = try? encoder.encode(envelope) else {
            return .error(statusCode: 500, code: "encoding_failed", message: "Could not encode the Local API response.")
        }

        return LocalAPIHTTPResponse(statusCode: 200, body: body)
    }

    private func domainDetailsResponse(for domain: String) -> LocalAPIHTTPResponse {
        let normalized = normalizedDomain(domain)
        let trackedDomain = DomainDataPortabilityService.loadTrackedDomains().first {
            $0.domain.caseInsensitiveCompare(normalized) == .orderedSame
        }
        let history = historyEntries(for: normalized)
        let latestEntry = history.first

        guard trackedDomain != nil || latestEntry != nil else {
            return .error(statusCode: 404, code: "domain_not_found", message: "No local data exists for \(normalized).")
        }

        let latestReport = latestEntry.map { buildReport(for: $0, from: history) }
        return successResponse(
            DomainDetailPayload(
                domain: normalized,
                trackedDomain: trackedDomain,
                latestReport: latestReport
            )
        )
    }

    private func inspectBodyResponse(_ body: Data) async -> LocalAPIHTTPResponse {
        guard let payload = try? decoder.decode(InspectRequestPayload.self, from: body) else {
            return .error(statusCode: 400, code: "invalid_body", message: "Expected JSON body: {\"domain\":\"example.com\"}.")
        }

        return await inspectResponse(for: payload.domain)
    }

    private func inspectResponse(for domain: String) async -> LocalAPIHTTPResponse {
        let normalized = normalizedDomain(domain)
        guard !normalized.isEmpty else {
            return .error(statusCode: 400, code: "invalid_domain", message: "A valid domain is required.")
        }

        let previousSnapshot = latestHistoryEntry(for: normalized)?.snapshot
        let report = await inspectionService.inspect(domain: normalized, previousSnapshot: previousSnapshot)
        return successResponse(InspectResponsePayload(report: report))
    }

    private func setMonitoring(enabled: Bool, for domain: String) async -> LocalAPIHTTPResponse {
        let normalized = normalizedDomain(domain)
        guard !normalized.isEmpty else {
            return .error(statusCode: 400, code: "invalid_domain", message: "A valid domain is required.")
        }

        var trackedDomains = DomainDataPortabilityService.loadTrackedDomains()
        guard let index = trackedDomains.firstIndex(where: { $0.domain.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            return .error(statusCode: 404, code: "domain_not_found", message: "Tracked domain \(normalized) was not found.")
        }

        trackedDomains[index].monitoringEnabled = enabled
        trackedDomains[index].updatedAt = Date()
        DomainDataPortabilityService.saveTrackedDomains(trackedDomains)

        let sanitizedSettings = MonitoringStorage.sanitizeSettings(
            MonitoringStorage.loadSettings(),
            trackedDomains: trackedDomains
        )
        MonitoringStorage.saveSettings(sanitizedSettings)

        await MainActor.run {
            _ = DomainMonitoringScheduler.shared.syncSchedule()
        }

        return successResponse(
            MonitoringMutationPayload(
                domain: trackedDomains[index].domain,
                monitoringEnabled: trackedDomains[index].monitoringEnabled
            )
        )
    }

    private func buildPortfolioSummary() -> PortfolioSummary {
        let trackedDomains = DomainDataPortabilityService.loadTrackedDomains()
        let history = DomainDataPortabilityService.loadHistoryEntries()

        var healthyCount = 0
        var warningCount = 0
        var criticalCount = 0
        var changedLast24h = 0
        var unreachableCount = 0

        for trackedDomain in trackedDomains {
            guard let latestEntry = latestHistoryEntry(for: trackedDomain.domain, history: history) else { continue }
            let report = buildReport(for: latestEntry, from: history)

            switch report.health {
            case .healthy:
                healthyCount += 1
            case .warning:
                warningCount += 1
            case .critical:
                criticalCount += 1
            }

            if latestEntry.changeSummary?.hasChanges == true,
               Date().timeIntervalSince(latestEntry.timestamp) <= 24 * 60 * 60 {
                changedLast24h += 1
            }

            if report.network.reachabilityError != nil || report.lastMonitoringFailure != nil {
                unreachableCount += 1
            }
        }

        return PortfolioSummary(
            totalDomains: trackedDomains.count,
            healthyCount: healthyCount,
            warningCount: warningCount,
            criticalCount: criticalCount,
            changedLast24h: changedLast24h,
            expiringSoonCount: trackedDomains.filter { $0.certificateWarningLevel != .none }.count,
            unreachableCount: unreachableCount
        )
    }

    private func monitoringPayload() -> MonitoringPayload {
        let trackedDomains = DomainDataPortabilityService.loadTrackedDomains()
        let settings = MonitoringStorage.sanitizeSettings(MonitoringStorage.loadSettings(), trackedDomains: trackedDomains)

        return MonitoringPayload(
            isEnabled: settings.isEnabled,
            scope: settings.scope,
            alertsEnabled: settings.alertsEnabled,
            monitoredDomains: trackedDomains.map {
                MonitoringDomainPayload(
                    domain: $0.domain,
                    monitoringEnabled: $0.monitoringEnabled,
                    lastMonitoredAt: $0.lastMonitoredAt,
                    lastAlertAt: $0.lastAlertAt,
                    certificateWarningLevel: $0.certificateWarningLevel
                )
            }
        )
    }

    private func recentEvents() -> [RecentEventPayload] {
        MonitoringStorage.loadLogs()
            .prefix(25)
            .flatMap { log in
                log.checkedDomains.map { result in
                    RecentEventPayload(
                        timestamp: result.checkedAt,
                        domain: result.domain,
                        summary: result.summaryMessage,
                        status: result.errorMessage == nil ? "ok" : "error",
                        severity: result.alertSeverity?.title ?? "Info"
                    )
                }
            }
    }

    private func historyEntries(for domain: String) -> [HistoryEntry] {
        let normalized = normalizedDomain(domain)
        return DomainDataPortabilityService.loadHistoryEntries().filter {
            $0.domain.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func latestHistoryEntry(for domain: String, history: [HistoryEntry]? = nil) -> HistoryEntry? {
        let entries = history ?? DomainDataPortabilityService.loadHistoryEntries()
        let normalized = normalizedDomain(domain)
        return entries.first { $0.domain.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    private func buildReport(for entry: HistoryEntry, from history: [HistoryEntry]) -> DomainReport {
        let previousSnapshot = history
            .dropFirst(history.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 } ?? history.count)
            .first { $0.domain.caseInsensitiveCompare(entry.domain) == .orderedSame }?
            .snapshot
        return reportBuilder.build(from: entry, previousSnapshot: previousSnapshot)
    }

    private func normalizedDomain(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/")
            .first?
            .lowercased() ?? ""
    }
}

struct LocalAPIHTTPRequest {
    let method: String
    let path: String
    let queryItems: [URLQueryItem]
    let headers: [String: String]
    let body: Data

    var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }

    var pathWithQuery: String {
        guard !queryItems.isEmpty else { return path }
        let query = queryItems.compactMap { item in
            guard let value = item.value else { return item.name }
            return "\(item.name)=\(value)"
        }
        .joined(separator: "&")
        return "\(path)?\(query)"
    }
}

struct LocalAPIHTTPResponse {
    let statusCode: Int
    let body: Data

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    static func error(statusCode: Int, code: String, message: String) -> LocalAPIHTTPResponse {
        let payload = LocalAPIEnvelope<EmptyPayload>(
            success: false,
            data: nil,
            error: LocalAPIErrorPayload(code: code, message: message),
            version: LocalAPIContract.version
        )

        let body = (try? LocalAPIContract.makeEncoder().encode(payload)) ?? Data()
        return LocalAPIHTTPResponse(statusCode: statusCode, body: body)
    }

    func serialized() -> Data {
        var response = Data()
        response.append("HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n".data(using: .utf8) ?? Data())
        response.append("Content-Type: application/json\r\n".data(using: .utf8) ?? Data())
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8) ?? Data())
        response.append("Connection: close\r\n\r\n".data(using: .utf8) ?? Data())
        response.append(body)
        return response
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        default:
            return "Internal Server Error"
        }
    }
}

private enum LocalAPIHTTPParser {
    enum ParserError: LocalizedError {
        case invalidRequestLine
        case invalidPath

        var errorDescription: String? {
            switch self {
            case .invalidRequestLine:
                return "The HTTP request line is invalid."
            case .invalidPath:
                return "The HTTP request path is invalid."
            }
        }
    }

    static func isCompleteRequest(_ data: Data) -> Bool {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }

        let headerData = data[..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return false
        }

        let contentLength = headerString
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
            ?? 0

        let bodyLength = data.count - separatorRange.upperBound
        return bodyLength >= contentLength
    }

    static func parseRequest(from data: Data) throws -> LocalAPIHTTPRequest {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ParserError.invalidRequestLine
        }

        let headerData = data[..<separatorRange.lowerBound]
        let bodyData = data[separatorRange.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ParserError.invalidRequestLine
        }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            throw ParserError.invalidRequestLine
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw ParserError.invalidRequestLine
        }

        let method = String(requestParts[0]).uppercased()
        let rawPath = String(requestParts[1])
        guard let components = URLComponents(string: rawPath) else {
            throw ParserError.invalidPath
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        return LocalAPIHTTPRequest(
            method: method,
            path: components.path,
            queryItems: components.queryItems ?? [],
            headers: headers,
            body: Data(bodyData)
        )
    }
}

struct LocalAPIEnvelope<DataPayload: Encodable>: Encodable {
    let success: Bool
    let data: DataPayload?
    let error: LocalAPIErrorPayload?
    let version: String
}

struct LocalAPIErrorPayload: Encodable {
    let code: String
    let message: String
}

struct EmptyPayload: Encodable {}

struct PortfolioPayload: Encodable {
    let summary: PortfolioSummary
}

struct PortfolioSummary: Encodable {
    let totalDomains: Int
    let healthyCount: Int
    let warningCount: Int
    let criticalCount: Int
    let changedLast24h: Int
    let expiringSoonCount: Int
    let unreachableCount: Int
}

struct DomainListPayload: Encodable {
    let domains: [TrackedDomain]
}

struct DomainDetailPayload: Encodable {
    let domain: String
    let trackedDomain: TrackedDomain?
    let latestReport: DomainReport?
}

struct DomainHistoryPayload: Encodable {
    let domain: String
    let history: [HistoryEntry]
}

struct RecentEventsPayload: Encodable {
    let events: [RecentEventPayload]
}

struct RecentEventPayload: Encodable {
    let timestamp: Date
    let domain: String
    let summary: String
    let status: String
    let severity: String
}

struct MonitoringPayload: Encodable {
    let isEnabled: Bool
    let scope: MonitoringScope
    let alertsEnabled: Bool
    let monitoredDomains: [MonitoringDomainPayload]
}

struct MonitoringDomainPayload: Encodable {
    let domain: String
    let monitoringEnabled: Bool
    let lastMonitoredAt: Date?
    let lastAlertAt: Date?
    let certificateWarningLevel: CertificateWarningLevel
}

struct MonitoringMutationPayload: Encodable {
    let domain: String
    let monitoringEnabled: Bool
}

struct InspectRequestPayload: Decodable {
    let domain: String
}

struct InspectResponsePayload: Encodable {
    let report: DomainReport
}

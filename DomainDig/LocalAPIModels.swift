import Foundation

struct LocalAPIConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var port: Int
    var token: String
    var requestLoggingEnabled: Bool

    init(
        isEnabled: Bool = false,
        port: Int = 47821,
        token: String = "",
        requestLoggingEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.port = port
        self.token = token
        self.requestLoggingEnabled = requestLoggingEnabled
    }
}

struct APIRequestLog: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let method: String
    let path: String
    let statusCode: Int
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        timestamp: Date,
        method: String,
        path: String,
        statusCode: Int,
        duration: TimeInterval
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.duration = duration
    }
}

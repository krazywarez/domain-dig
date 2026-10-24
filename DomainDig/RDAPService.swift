import Foundation

/// The HTTP fetch behind an RDAP query, injectable so the status mapping can be
/// exercised without network.
protocol RDAPTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionRDAPTransport: RDAPTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum RDAPService {
    /// The registry's answer about `domain`, or nil when the registry did not
    /// give one.
    static func registrationStatus(
        for domain: String,
        transport: RDAPTransport = URLSessionRDAPTransport()
    ) async -> DomainAvailabilityStatus? {
        let normalizedDomain = normalize(domain)
        guard !normalizedDomain.isEmpty else { return nil }

        switch await fetchRDAPResponse(for: normalizedDomain, transport: transport) {
        case .found:
            return .registered
        case .notRegistered:
            return .available
        case .empty, .failed:
            return nil
        }
    }

    /// Whether an RDAP response came from a registry's own server rather than
    /// from the `rdap.org` bootstrap redirector.
    ///
    /// `rdap.org` answers 404 both for a domain its registry does not hold and
    /// for a TLD it knows no RDAP server for; only the first says anything about
    /// registration. `URLSession` follows the bootstrap redirect, so a response
    /// URL on another host is the registry's own answer.
    static func answeredByRegistry(responseURL: URL?) -> Bool {
        guard let host = responseURL?.host?.lowercased() else { return false }
        return host != bootstrapHost && !host.hasSuffix(".\(bootstrapHost)")
    }

    static func ownership(
        for domain: String,
        transport: RDAPTransport = URLSessionRDAPTransport()
    ) async -> ServiceResult<DomainOwnership> {
        let normalizedDomain = normalize(domain)
        guard !normalizedDomain.isEmpty else {
            return .empty("Unavailable")
        }

        switch await fetchRDAPResponse(for: normalizedDomain, transport: transport) {
        case let .found(response):
            let ownership = DomainOwnership(
                registrar: response.registrarName,
                registrant: response.registrantName,
                createdDate: response.createdDate,
                expirationDate: response.expirationDate,
                status: response.status,
                nameservers: response.nameservers,
                abuseEmail: response.abuseEmail
            )
            return .success(ownership)
        case .notRegistered:
            return .empty("Unavailable")
        case let .empty(message):
            return .empty(message)
        case let .failed(message):
            return .error(message)
        }
    }

    private static func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private let bootstrapHost = "rdap.org"

/// What a single RDAP fetch established.
private enum RDAPFetchOutcome {
    /// A domain record, from whichever server answered.
    case found(RDAPDomainResponse)
    /// The registry's own RDAP server reported no such domain.
    case notRegistered
    /// An answer that settles nothing: a non-domain record, or a 404 from the
    /// bootstrap redirector rather than from a registry.
    case empty(String)
    case failed(String)
}

private func fetchRDAPResponse(for domain: String, transport: RDAPTransport) async -> RDAPFetchOutcome {
    let startedAt = DomainDebugLog.signpostStart("RDAP.fetch", domain: domain)
    guard let url = URL(string: "https://\(bootstrapHost)/domain/\(domain)") else {
        return .failed("Unavailable")
    }

    do {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/rdap+json, application/json", forHTTPHeaderField: "Accept")
        DomainDebugLog.debug("RDAP.request url=\(url.absoluteString) timeout=8")

        let (data, response) = try await transport.fetch(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            DomainDebugLog.error("RDAP.badResponse domain=\(domain) response=nil")
            return .failed(URLError(.badServerResponse).localizedDescription)
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let rdapResponse = try decoder.decode(RDAPDomainResponse.self, from: data)
            guard rdapResponse.isDomainRecord else {
                DomainDebugLog.signpostEnd("RDAP.fetch", start: startedAt, domain: domain, extra: "status=200 nonDomainRecord")
                return .empty("Unavailable")
            }
            DomainDebugLog.signpostEnd("RDAP.fetch", start: startedAt, domain: domain, extra: "status=200 bytes=\(data.count)")
            return .found(rdapResponse)
        case 404:
            let fromRegistry = RDAPService.answeredByRegistry(responseURL: httpResponse.url)
            DomainDebugLog.signpostEnd("RDAP.fetch", start: startedAt, domain: domain, extra: "status=404 registry=\(fromRegistry)")
            return fromRegistry ? .notRegistered : .empty("Unavailable")
        default:
            DomainDebugLog.error("RDAP.httpError domain=\(domain) status=\(httpResponse.statusCode)")
            DomainDebugLog.signpostEnd("RDAP.fetch", start: startedAt, domain: domain, extra: "status=\(httpResponse.statusCode)")
            return .failed("Unavailable")
        }
    } catch {
        DomainDebugLog.error("RDAP.error domain=\(domain) error=\(error.localizedDescription)")
        DomainDebugLog.signpostEnd("RDAP.fetch", start: startedAt, domain: domain, extra: "error")
        return .failed(error.localizedDescription)
    }
}

private struct RDAPDomainResponse: Decodable, Sendable {
    let ldhName: String?
    let objectClassName: String?
    let unicodeName: String?
    let handle: String?
    let rawStatus: [String]?
    let rawNameservers: [RDAPNameserver]?
    let events: [RDAPEvent]?
    let entities: [RDAPEntity]?

    enum CodingKeys: String, CodingKey {
        case ldhName
        case objectClassName
        case unicodeName
        case handle
        case rawStatus = "status"
        case rawNameservers = "nameservers"
        case events
        case entities
    }

    var isDomainRecord: Bool {
        if ldhName?.isEmpty == false {
            return true
        }
        if objectClassName == "domain" {
            return true
        }
        return handle != nil && unicodeName != nil
    }

    var registrarName: String? {
        entities?.first(where: { $0.roles.contains("registrar") })?.bestDisplayName
    }

    var registrantName: String? {
        entities?.first(where: { $0.roles.contains("registrant") })?.bestDisplayName
    }

    var createdDate: Date? {
        eventDate(for: ["registration", "registered"])
    }

    var expirationDate: Date? {
        eventDate(for: ["expiration", "expiry", "expired"])
    }

    var abuseEmail: String? {
        entities?.first(where: { $0.roles.contains("abuse") })?.email
            ?? entities?.first(where: { $0.roles.contains("registrar") })?.abuseEntity?.email
    }

    var nameservers: [String] {
        let rawValues = rawNameservers?.compactMap { $0.ldhName ?? $0.unicodeName } ?? []
        return deduplicated(rawValues)
    }

    var status: [String] {
        deduplicated(rawStatus ?? [])
    }

    private func eventDate(for actions: [String]) -> Date? {
        let normalizedActions = Set(actions)
        return events?
            .first(where: { normalizedActions.contains($0.eventAction.lowercased()) })?
            .parsedDate
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

private struct RDAPNameserver: Decodable, Sendable {
    let ldhName: String?
    let unicodeName: String?
}

private struct RDAPEvent: Decodable, Sendable {
    let eventAction: String
    let eventDate: String

    var parsedDate: Date? {
        RDAPDateParser.parse(eventDate)
    }
}

private struct RDAPEntity: Decodable, Sendable {
    let roles: [String]
    let vcardArray: RDAPVCardArray?
    let entities: [RDAPEntity]?

    var bestDisplayName: String? {
        vcardArray?.fullName ?? vcardArray?.organization ?? vcardArray?.email
    }

    var email: String? {
        vcardArray?.email
    }

    var abuseEntity: RDAPEntity? {
        entities?.first(where: { $0.roles.contains("abuse") })
    }
}

private struct RDAPVCardArray: Decodable, Sendable {
    let values: [[RDAPJSONValue]]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        _ = try container.decode(String.self)
        values = try container.decode([[RDAPJSONValue]].self)
    }

    var fullName: String? {
        value(for: "fn")
    }

    var organization: String? {
        value(for: "org")
    }

    var email: String? {
        value(for: "email")
    }

    private func value(for key: String) -> String? {
        values.first(where: { $0.first?.stringValue?.lowercased() == key })?.last?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum RDAPJSONValue: Decodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return String(value)
        case .null:
            return nil
        }
    }
}

private enum RDAPDateParser {
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        iso8601WithFractional.date(from: value) ?? iso8601.date(from: value)
    }
}

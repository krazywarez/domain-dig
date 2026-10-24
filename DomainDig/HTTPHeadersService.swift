import Foundation

enum HTTPSecurityGrade: String {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    static func grade(for headers: [HTTPHeader]) -> HTTPSecurityGrade {
        let presentHeaderNames = Set(headers.map { $0.name.lowercased() })
        let presentCount = HTTPHeader.securityHeaders.intersection(presentHeaderNames).count

        switch presentCount {
        case 5:
            return .a
        case 4:
            return .b
        case 3:
            return .c
        case 2:
            return .d
        default:
            return .f
        }
    }
}

struct HTTPHeadersResult {
    let headers: [HTTPHeader]
    let statusCode: Int?
    let responseTimeMs: Int?
    let httpProtocol: String?
    let http3Advertised: Bool
}

struct HTTPHeadersService {
    static func fetch(domain: String) async -> ServiceResult<HTTPHeadersResult> {
        guard let url = DomainHostURL.https(domain) else {
            return .error("Not a valid domain name")
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let metricsDelegate = TaskMetricsDelegate()
        let startTime = Date()

        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: metricsDelegate)
            let responseTimeMs = max(0, Int(Date().timeIntervalSince(startTime) * 1000))

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error(URLError(.badServerResponse).localizedDescription)
            }

            let headers = httpResponse.allHeaderFields.compactMap { entry -> HTTPHeader? in
                guard let name = entry.key as? String,
                      let value = entry.value as? String else { return nil }
                return HTTPHeader(name: name, value: value)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

            let networkProtocolName = metricsDelegate.metrics?.transactionMetrics
                .compactMap { $0.networkProtocolName }
                .last
            let detectedProtocol = protocolLabel(for: networkProtocolName)
            let altSvcValue = headerValue(named: "alt-svc", in: httpResponse)
            let http3Advertised = altSvcValue?.localizedCaseInsensitiveContains("h3") == true
            let result = HTTPHeadersResult(
                headers: headers,
                statusCode: httpResponse.statusCode,
                responseTimeMs: responseTimeMs,
                httpProtocol: detectedProtocol,
                http3Advertised: http3Advertised
            )

            return headers.isEmpty ? .empty("No HTTP headers returned") : .success(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func protocolLabel(for networkProtocolName: String?) -> String? {
        guard let networkProtocolName else { return nil }

        let normalized = networkProtocolName.lowercased()
        if normalized == "h2" {
            return "HTTP/2"
        }
        if normalized == "h3" || normalized.hasPrefix("quic") {
            return "HTTP/3"
        }
        if normalized.hasPrefix("http/") {
            return normalized.uppercased()
        }

        return networkProtocolName.uppercased()
    }

    private static func headerValue(named name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            guard let headerName = key as? String else { return false }
            return headerName.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }
}

private final class TaskMetricsDelegate: NSObject, URLSessionTaskDelegate {
    // Written from the session's delegate queue, read only after the request
    // has completed — URLSession guarantees didFinishCollecting is delivered
    // before the task finishes, so the accesses are sequenced. (#27)
    nonisolated(unsafe) private(set) var metrics: URLSessionTaskMetrics?

    func urlSession(
        _ _: URLSession,
        task _: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        self.metrics = metrics
    }
}

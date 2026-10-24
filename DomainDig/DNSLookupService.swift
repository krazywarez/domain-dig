import Foundation

enum DNSResolverOption: String, CaseIterable, Identifiable {
    case cloudflare
    case google
    case quad9
    case custom

    static let userDefaultsKey = "dnsResolverURL"
    static let defaultURLString = "https://cloudflare-dns.com/dns-query"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .custom: return "Custom"
        }
    }

    var urlString: String? {
        switch self {
        case .cloudflare: return Self.defaultURLString
        case .google: return "https://dns.google/dns-query"
        case .quad9: return "https://dns.quad9.net/dns-query"
        case .custom: return nil
        }
    }

    static func option(for urlString: String) -> DNSResolverOption {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.allCases.first(where: { $0.urlString == trimmedURL }) ?? .custom
    }

    static func isValidCustomURL(_ urlString: String) -> Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.hasPrefix("https://") else {
            return false
        }
        return URL(string: trimmedURL) != nil
    }

    static func resolvedURLString(from storedValue: String?) -> String {
        guard let storedValue else {
            return defaultURLString
        }

        let trimmedURL = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return defaultURLString
        }

        return isValidCustomURL(trimmedURL) ? trimmedURL : defaultURLString
    }
}

/// A single record lookup, injectable so callers that branch on its result can
/// be exercised without network.
protocol DNSLookup {
    func lookup(domain: String, recordType: DNSRecordType) async throws -> [DNSRecord]
}

struct DNSLookupService {
    private static let internetClass = 1

    static func lookup(domain: String, recordType: DNSRecordType) async throws -> [DNSRecord] {
        try await lookup(
            domain: domain,
            recordType: recordType,
            resolverURLString: currentResolverURLString()
        )
    }

    static func lookup(
        domain: String,
        recordType: DNSRecordType,
        resolverURLString: String
    ) async throws -> [DNSRecord] {
        let response = try await lookupResponse(
            domain: domain,
            queryType: recordType.queryType,
            resolverURLString: resolverURLString
        )

        return response.answers
            .filter { $0.type == recordType.queryType }
            .map { answer in
                let value: String
                if recordType.usesRawDataValue {
                    value = answer.data
                } else {
                    value = answer.data.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                return DNSRecord(value: value, ttl: answer.ttl)
            }
    }

    static func lookupAll(domain: String) async -> ServiceResult<[DNSSection]> {
        typealias Result = (
            type: DNSRecordType,
            records: [DNSRecord],
            wildcard: [DNSRecord],
            dnssecSigned: Bool?,
            error: String?
        )

        let wildcardTypes: Set<DNSRecordType> = [.A, .AAAA, .MX, .TXT, .SRV, .CAA]
        let resolverURLString = currentResolverURLString()
        let dnssecSigned = try? await lookupDNSSECStatus(
            domain: domain,
            resolverURLString: resolverURLString
        )

        let sections = await withTaskGroup(of: Result.self, returning: [DNSSection].self) { group in
            for recordType in DNSRecordType.allCases {
                guard recordType != .PTR else {
                    continue
                }
                let shouldQueryWildcard = wildcardTypes.contains(recordType)
                group.addTask {
                    var apexRecords: [DNSRecord] = []
                    var wildcardRecords: [DNSRecord] = []
                    var lookupError: String?

                    do {
                        apexRecords = try await lookup(
                            domain: domain,
                            recordType: recordType,
                            resolverURLString: resolverURLString
                        )
                    } catch {
                        lookupError = error.localizedDescription
                    }

                    if shouldQueryWildcard && lookupError == nil {
                        do {
                            wildcardRecords = try await lookup(
                                domain: "*.\(domain)",
                                recordType: recordType,
                                resolverURLString: resolverURLString
                            )
                        } catch {
                            // Wildcard failure is non-fatal; just leave empty.
                        }
                    }

                    return (recordType, apexRecords, wildcardRecords, dnssecSigned, lookupError)
                }
            }

            var sections: [DNSSection] = []
            for await result in group {
                sections.append(DNSSection(
                    recordType: result.type,
                    records: result.records,
                    wildcardRecords: result.wildcard,
                    dnssecSigned: result.dnssecSigned,
                    error: result.error
                ))
            }

            let order = DNSRecordType.allCases
            return sections.sorted { a, b in
                (order.firstIndex(of: a.recordType) ?? 0) < (order.firstIndex(of: b.recordType) ?? 0)
            }
        }

        if sections.contains(where: { !$0.records.isEmpty || !$0.wildcardRecords.isEmpty || $0.error != nil }) {
            return .success(sections)
        }

        return .empty("No DNS records found")
    }

    private static func lookupResponse(
        domain: String,
        queryType: Int,
        resolverURLString: String,
        includeDNSSECData: Bool = false
    ) async throws -> DNSLookupResponse {
        let resolverURL = try validatedResolverURL(from: resolverURLString)
        var components = URLComponents(url: resolverURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: domain),
            URLQueryItem(name: "type", value: String(queryType))
        ]
        if includeDNSSECData {
            components.queryItems?.append(URLQueryItem(name: "do", value: "1"))
        }

        var request = URLRequest(url: components.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return try await lookupResponseViaRFC8484(
                domain: domain,
                queryType: queryType,
                resolverURL: resolverURL,
                includeDNSSECData: includeDNSSECData
            )
        }

        let dnsResponse = try JSONDecoder().decode(CloudflareDNSResponse.self, from: data)

        return DNSLookupResponse(
            answers: dnsResponse.answer ?? [],
            authenticatedData: dnsResponse.authenticatedData ?? false
        )
    }

    private static func lookupDNSSECStatus(
        domain: String,
        resolverURLString: String
    ) async throws -> Bool {
        // Query SOA with the DNSSEC OK bit set. The resolver validates the full
        // DNSSEC chain and reflects the result in the AD (Authenticated Data) bit
        // of the response flags. This is more reliable than querying DNSKEY directly,
        // because resolvers don't always set AD on DNSKEY queries and many zones
        // don't return DNSKEY records via DoH JSON.
        let response = try await lookupResponse(
            domain: domain,
            queryType: 6, // SOA
            resolverURLString: resolverURLString,
            includeDNSSECData: true
        )
        return response.authenticatedData
    }

    static func currentResolverURLString() -> String {
        let storedValue = UserDefaults.standard.string(forKey: DNSResolverOption.userDefaultsKey)
        return DNSResolverOption.resolvedURLString(from: storedValue)
    }

    static func currentResolverDisplayName() -> String {
        let resolverURLString = currentResolverURLString()
        let option = DNSResolverOption.option(for: resolverURLString)
        return option == .custom ? resolverURLString : option.title
    }

    private static func validatedResolverURL(from urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func lookupResponseViaRFC8484(
        domain: String,
        queryType: Int,
        resolverURL: URL,
        includeDNSSECData: Bool
    ) async throws -> DNSLookupResponse {
        let queryData = try buildDNSQueryMessage(
            domain: domain,
            queryType: queryType,
            dnssecOK: includeDNSSECData
        )
        let encodedQuery = base64URLEncodedString(for: queryData)

        var components = URLComponents(url: resolverURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "dns", value: encodedQuery)]

        var request = URLRequest(url: components.url!)
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try parseDNSMessage(data)
    }

    private static func buildDNSQueryMessage(domain: String, queryType: Int, dnssecOK: Bool = false) throws -> Data {
        let normalizedName = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = normalizedName.split(separator: ".")

        var data = Data()
        data.appendUInt16(UInt16.random(in: UInt16.min ... UInt16.max))
        data.appendUInt16(0x0100)
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(dnssecOK ? 1 : 0)

        for label in labels {
            guard let labelData = label.data(using: .utf8),
                  labelData.count <= 63 else {
                throw URLError(.badURL)
            }
            data.append(UInt8(labelData.count))
            data.append(labelData)
        }

        data.append(0)
        data.appendUInt16(UInt16(queryType))
        data.appendUInt16(UInt16(internetClass))

        if dnssecOK {
            data.appendUInt16(0)
            data.appendUInt16(1)
            data.appendUInt16(0)
            data.appendUInt16(0)
            data.appendUInt16(11)
            data.appendUInt16(10)
            data.appendUInt16(8_192)
            data.appendUInt16(32_768)
            data.appendUInt16(0)
        }

        return data
    }

    private static func base64URLEncodedString(for data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseDNSMessage(_ data: Data) throws -> DNSLookupResponse {
        guard data.count >= 12 else {
            throw URLError(.cannotParseResponse)
        }

        let flags = readUInt16(in: data, at: 2)
        let answerCount = Int(readUInt16(in: data, at: 6))
        let questionCount = Int(readUInt16(in: data, at: 4))
        var offset = 12

        for _ in 0 ..< questionCount {
            _ = try readDomainName(in: data, offset: &offset)
            offset += 4
        }

        var answers: [CloudflareDNSResponse.CloudflareDNSAnswer] = []
        for _ in 0 ..< answerCount {
            let name = try readDomainName(in: data, offset: &offset)
            let type = Int(readUInt16(in: data, at: offset))
            offset += 2
            _ = readUInt16(in: data, at: offset)
            offset += 2
            let ttl = Int(readUInt32(in: data, at: offset))
            offset += 4
            let dataLength = Int(readUInt16(in: data, at: offset))
            offset += 2

            guard offset + dataLength <= data.count else {
                throw URLError(.cannotParseResponse)
            }

            let recordDataOffset = offset
            let recordData = data.subdata(in: recordDataOffset ..< (recordDataOffset + dataLength))
            offset += dataLength

            let parsedValue = try parseRecordData(
                from: data,
                recordType: type,
                recordDataOffset: recordDataOffset,
                recordData: recordData
            )

            answers.append(.init(
                name: name,
                type: type,
                ttl: ttl,
                data: parsedValue
            ))
        }

        return DNSLookupResponse(
            answers: answers,
            authenticatedData: (flags & 0x0020) != 0
        )
    }

    private static func parseRecordData(
        from message: Data,
        recordType: Int,
        recordDataOffset: Int,
        recordData: Data
    ) throws -> String {
        switch recordType {
        case 1:
            guard recordData.count == 4 else { throw URLError(.cannotParseResponse) }
            return recordData.map(String.init).joined(separator: ".")
        case 2, 5:
            var offset = recordDataOffset
            return try readDomainName(in: message, offset: &offset)
        case 15:
            guard recordData.count >= 3 else { throw URLError(.cannotParseResponse) }
            let preference = readUInt16(in: recordData, at: 0)
            var exchangeOffset = recordDataOffset + 2
            let exchange = try readDomainName(in: message, offset: &exchangeOffset)
            return "\(preference) \(exchange)"
        case 16:
            return try parseTXTData(recordData)
        case 28:
            guard recordData.count == 16 else { throw URLError(.cannotParseResponse) }
            return stride(from: 0, to: 16, by: 2)
                .map { index in
                    String(format: "%x", readUInt16(in: recordData, at: index))
                }
                .joined(separator: ":")
        case 6:
            var offset = recordDataOffset
            let mname = try readDomainName(in: message, offset: &offset)
            let rname = try readDomainName(in: message, offset: &offset)
            let serial = readUInt32(in: message, at: offset)
            let refresh = readUInt32(in: message, at: offset + 4)
            let retry = readUInt32(in: message, at: offset + 8)
            let expire = readUInt32(in: message, at: offset + 12)
            let minimum = readUInt32(in: message, at: offset + 16)
            return "\(mname) \(rname) \(serial) \(refresh) \(retry) \(expire) \(minimum)"
        case 33:
            guard recordData.count >= 7 else { throw URLError(.cannotParseResponse) }
            let priority = readUInt16(in: recordData, at: 0)
            let weight = readUInt16(in: recordData, at: 2)
            let port = readUInt16(in: recordData, at: 4)
            var targetOffset = recordDataOffset + 6
            let target = try readDomainName(in: message, offset: &targetOffset)
            return "\(priority) \(weight) \(port) \(target)"
        case 43:
            guard recordData.count >= 4 else { throw URLError(.cannotParseResponse) }
            let keyTag = readUInt16(in: recordData, at: 0)
            let algorithm = recordData[2]
            let digestType = recordData[3]
            let digest = recordData.dropFirst(4).map { String(format: "%02X", $0) }.joined()
            return "\(keyTag) \(algorithm) \(digestType) \(digest)"
        case 46:
            return "RRSIG"
        case 257:
            guard recordData.count >= 2 else { throw URLError(.cannotParseResponse) }
            let flags = recordData[0]
            let tagLength = Int(recordData[1])
            guard recordData.count >= 2 + tagLength else {
                throw URLError(.cannotParseResponse)
            }
            let tagData = recordData.subdata(in: 2 ..< (2 + tagLength))
            let valueData = recordData.dropFirst(2 + tagLength)
            let tag = String(decoding: tagData, as: UTF8.self)
            let value = String(decoding: valueData, as: UTF8.self)
            return "\(flags) \(tag) \"\(value)\""
        default:
            return recordData.base64EncodedString()
        }
    }

    private static func parseTXTData(_ data: Data) throws -> String {
        var offset = 0
        var strings: [String] = []

        while offset < data.count {
            let count = Int(data[offset])
            offset += 1
            guard offset + count <= data.count else {
                throw URLError(.cannotParseResponse)
            }
            let stringData = data.subdata(in: offset ..< (offset + count))
            strings.append(String(decoding: stringData, as: UTF8.self))
            offset += count
        }

        return strings.joined()
    }

    private static func readDomainName(in data: Data, offset: inout Int) throws -> String {
        var labels: [String] = []
        var currentOffset = offset
        var jumped = false
        var seenOffsets = Set<Int>()

        while true {
            guard currentOffset < data.count else {
                throw URLError(.cannotParseResponse)
            }

            let length = Int(data[currentOffset])

            if length == 0 {
                if !jumped {
                    offset = currentOffset + 1
                }
                break
            }

            if length & 0xC0 == 0xC0 {
                guard currentOffset + 1 < data.count else {
                    throw URLError(.cannotParseResponse)
                }

                let pointer = ((length & 0x3F) << 8) | Int(data[currentOffset + 1])
                guard seenOffsets.insert(pointer).inserted else {
                    throw URLError(.cannotParseResponse)
                }

                if !jumped {
                    offset = currentOffset + 2
                }
                currentOffset = pointer
                jumped = true
                continue
            }

            let labelStart = currentOffset + 1
            let labelEnd = labelStart + length
            guard labelEnd <= data.count else {
                throw URLError(.cannotParseResponse)
            }

            let labelData = data.subdata(in: labelStart ..< labelEnd)
            labels.append(String(decoding: labelData, as: UTF8.self))
            currentOffset = labelEnd
        }

        return labels.joined(separator: ".")
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        let upper = UInt16(data[offset]) << 8
        let lower = UInt16(data[offset + 1])
        return upper | lower
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        let first = UInt32(data[offset]) << 24
        let second = UInt32(data[offset + 1]) << 16
        let third = UInt32(data[offset + 2]) << 8
        let fourth = UInt32(data[offset + 3])
        return first | second | third | fourth
    }
}

extension DNSLookupService: DNSLookup {
    func lookup(domain: String, recordType: DNSRecordType) async throws -> [DNSRecord] {
        try await Self.lookup(domain: domain, recordType: recordType)
    }
}

private struct DNSLookupResponse {
    let answers: [CloudflareDNSResponse.CloudflareDNSAnswer]
    let authenticatedData: Bool
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

import Foundation

struct DomainAvailabilityService {
    private static let suggestionTLDs = ["net", "io", "dev", "app", "co", "org"]

    static func check(domain: String) async -> DomainAvailabilityResult {
        let normalizedDomain = normalize(domain)
        guard !normalizedDomain.isEmpty else {
            return DomainAvailabilityResult(domain: domain, status: .unknown)
        }

        // RDAP is the registry's own record, so it settles both directions.
        if let registryStatus = await checkViaRDAP(domain: normalizedDomain) {
            return DomainAvailabilityResult(domain: normalizedDomain, status: registryStatus)
        }

        // Without a registry answer only "registered" is decidable: a name that
        // resolves is registered. Absence of records is not evidence of
        // availability, because the DoH layer drops the response code, so
        // NXDOMAIN and a resolver failure arrive here identically.
        let fallbackStatus = await checkViaDNSFallback(domain: normalizedDomain)
        return DomainAvailabilityResult(domain: normalizedDomain, status: fallbackStatus)
    }

    static func suggestions(for domain: String, limit: Int = 6) async -> [DomainSuggestionResult] {
        let normalizedDomain = normalize(domain)
        let candidates = suggestionCandidates(for: normalizedDomain, limit: limit)
        guard !candidates.isEmpty else { return [] }

        var results: [DomainSuggestionResult] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            let result = await check(domain: candidate)
            results.append(DomainSuggestionResult(domain: result.domain, status: result.status))
        }
        return results
    }

    private static func checkViaRDAP(domain: String) async -> DomainAvailabilityStatus? {
        let status = await RDAPService.registrationStatus(for: domain)
        return status
    }

    private static func checkViaDNSFallback(domain: String) async -> DomainAvailabilityStatus {
        do {
            let aRecords = try await DNSLookupService.lookup(domain: domain, recordType: .A)
            if !aRecords.isEmpty {
                return .registered
            }
        } catch {
            // No A record (or the lookup failed); fall through to the NS probe.
        }

        do {
            let nsRecords = try await DNSLookupService.lookup(domain: domain, recordType: .NS)
            if !nsRecords.isEmpty {
                return .registered
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private static func suggestionCandidates(for domain: String, limit: Int) -> [String] {
        let parts = domain.split(separator: ".")
        guard parts.count >= 2 else { return [] }

        let base = parts.dropLast().joined(separator: ".")
        let tld = String(parts.last ?? "")

        var candidates: [String] = []
        for suggestionTLD in suggestionTLDs where suggestionTLD != tld {
            candidates.append("\(base).\(suggestionTLD)")
            if candidates.count == limit {
                return candidates
            }
        }

        if !base.contains("-"), base.count >= 6, candidates.count < limit {
            let midpoint = base.index(base.startIndex, offsetBy: base.count / 2)
            let hyphenated = "\(base[..<midpoint])-\(base[midpoint...]).\(tld)"
            if hyphenated != domain {
                candidates.append(hyphenated)
            }
        }

        return Array(candidates.prefix(limit))
    }

    private static func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

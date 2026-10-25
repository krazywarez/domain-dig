import Foundation

/// How much of an inspection to run.
///
/// Opted out of the project's MainActor default isolation, along with
/// `InspectionScope` below: monitoring and the batch pipeline build a scope
/// from a background context.
nonisolated enum InspectionProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Registration, ownership, TLS, HSTS, HTTP, redirects and PTR: the
    /// sections that answer "what is this domain" without probing ports or
    /// enumerating hosts.
    case quick
    /// Every section.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick:
            return "Quick"
        case .full:
            return "Full"
        }
    }

    var detail: String {
        switch self {
        case .quick:
            return "DNS, registration, ownership, TLS and HTTP. Skips port scanning, reachability, subdomain discovery, IP geolocation and name suggestions."
        case .full:
            return "Every section."
        }
    }
}

/// What a single inspection is allowed to do.
///
/// This is a parameter of `inspectSnapshot` with no default value, so each of
/// the six call sites has to state its scope and none can inherit one silently.
nonisolated struct InspectionScope: Sendable, Equatable {
    var profile: InspectionProfile
    /// Whether the inspection may contact `rdap.org`, `crt.sh` and `ipapi.co`.
    var allowsThirdPartyEnrichment: Bool

    static let profileDefaultsKey = "inspection.profile"
    static let enrichmentDefaultsKey = "inspection.allowsThirdPartyEnrichment"

    /// Every section against every service. The Local API answers with this
    /// unless a request asks otherwise, so `v1` consumers see no change.
    static let full = InspectionScope(profile: .full, allowsThirdPartyEnrichment: true)

    /// The scope the user has chosen, for the app's own lookups and for
    /// monitoring. Both settings default on, as they behaved before they
    /// existed.
    static func current(defaults: UserDefaults = .standard) -> InspectionScope {
        let storedProfile = defaults.string(forKey: profileDefaultsKey)
        return InspectionScope(
            profile: storedProfile.flatMap(InspectionProfile.init(rawValue:)) ?? .full,
            allowsThirdPartyEnrichment: defaults.object(forKey: enrichmentDefaultsKey) as? Bool ?? true
        )
    }

    /// The scope a Local API request asks for.
    ///
    /// The profile defaults to Full, so a `v1` consumer that sends no `profile`
    /// gets what it always did. The enrichment setting is the device owner's
    /// consent decision rather than a per-request option, so it applies here
    /// too and a request cannot override it.
    ///
    /// Returns `nil` for a `profile` value that names no known profile, which
    /// the caller answers as a request error rather than silently running Full.
    static func requested(
        from queryItems: [URLQueryItem],
        defaults: UserDefaults = .standard
    ) -> InspectionScope? {
        let requested = queryItems.first { $0.name == "profile" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let profile: InspectionProfile
        if let requested, !requested.isEmpty {
            guard let parsed = InspectionProfile(rawValue: requested) else { return nil }
            profile = parsed
        } else {
            profile = .full
        }
        return InspectionScope(
            profile: profile,
            allowsThirdPartyEnrichment: current(defaults: defaults).allowsThirdPartyEnrichment
        )
    }

    /// Whether this scope runs `section`.
    ///
    /// `availability` always runs: declining enrichment drops its RDAP half,
    /// leaving the DNS fallback, which still recognises a domain that resolves.
    func runs(_ section: LookupSectionKind) -> Bool {
        switch section {
        case .dns, .availability, .ssl, .hsts, .httpHeaders, .emailSecurity, .ptr, .redirectChain:
            return true
        case .ownership:
            return allowsThirdPartyEnrichment
        case .reachability, .portScan:
            return profile == .full
        case .ipGeolocation, .subdomains, .suggestions:
            return profile == .full && allowsThirdPartyEnrichment
        }
    }

    /// Whether `DomainAvailabilityService` may ask RDAP, as opposed to deciding
    /// registration from DNS alone.
    var allowsRDAP: Bool { allowsThirdPartyEnrichment }

    /// What to show in place of a section this scope did not run.
    func skipReason(for section: LookupSectionKind) -> String? {
        guard !runs(section) else { return nil }
        if !allowsThirdPartyEnrichment, Self.needsThirdParty(section) {
            return "Not run: third-party enrichment is off in Settings."
        }
        return "Not run in the Quick profile."
    }

    private static func needsThirdParty(_ section: LookupSectionKind) -> Bool {
        switch section {
        case .ownership, .ipGeolocation, .subdomains, .suggestions:
            return true
        case .dns, .availability, .ssl, .hsts, .httpHeaders, .emailSecurity, .ptr, .redirectChain, .reachability, .portScan:
            return false
        }
    }
}

import Foundation

/// Shared builder/parser for the `domaindig://` URL scheme, used by the intents
/// and app (to open/route) and by the widget (to deep-link into a domain).
///
/// Lives in `Shared/` so it compiles into both the app and the widget target.
/// It relies only on Foundation and no actor isolation, so it is safe in the
/// widget extension (`APPLICATION_EXTENSION_API_ONLY`).
enum DomainDigDeepLink {
    static let scheme = "domaindig"

    enum Action: Equatable {
        case inspect(String)
        case watch(String)
        case detail(String)
        case sweep

        var host: String {
            switch self {
            case .inspect: return "inspect"
            case .watch: return "watch"
            case .detail: return "domain"
            case .sweep: return "sweep"
            }
        }

        /// The domain the action targets, if any. `.sweep` has no domain.
        var domain: String? {
            switch self {
            case let .inspect(domain), let .watch(domain), let .detail(domain):
                return domain
            case .sweep:
                return nil
            }
        }
    }

    static func url(for action: Action) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action.host
        if let domain = action.domain {
            components.queryItems = [URLQueryItem(name: "domain", value: domain)]
        }
        // The scheme and host are fixed and any domain is percent-encoded by
        // URLComponents, so this is always a valid URL.
        return components.url!
    }

    static func action(from url: URL) -> Action? {
        guard url.scheme == scheme else { return nil }

        if url.host() == "sweep" {
            return .sweep
        }

        let domain = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "domain" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A control character inside the value is not a domain, and it travels
        // on into stored rows and, from there, into mail headers. Refuse the
        // whole link rather than carry it.
        guard !domain.isEmpty,
              domain.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        switch url.host() {
        case "inspect": return .inspect(domain)
        case "watch": return .watch(domain)
        case "domain": return .detail(domain)
        default: return nil
        }
    }
}

import Foundation

/// Request URLs for an inspected host.
///
/// The inspected domain is free text, so it cannot be forced into a URL:
/// `URL(string: "https://exa mple.com")` is nil, and a section service that
/// built its request with `!` trapped on any host carrying a space, a tab or a
/// control character — reachable by typing `example .com`, or by separating
/// bulk input with spaces instead of commas or newlines.
enum DomainHostURL {
    static func https(_ host: String) -> URL? {
        url(scheme: "https", host: host)
    }

    static func http(_ host: String) -> URL? {
        url(scheme: "http", host: host)
    }

    /// `nil` when `host` cannot form a URL with a host component.
    static func url(scheme: String, host: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              trimmedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: "\(scheme)://\(trimmedHost)"),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

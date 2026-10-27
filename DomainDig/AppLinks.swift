import Foundation

/// Centralized external destinations, kept in one place so URLs and the App Store
/// identifier can be swapped without touching any view.
///
/// `documentation` points at the repository README for now; swap in a dedicated
/// docs site if one lands.
enum AppLinks {
    /// App Store numeric identifier; the listing/review/share URLs derive from it.
    static let appStoreID = "6760368004"

    static let sourceCode = url("https://github.com/krazywarez/domain-dig")
    static let documentation = url("https://github.com/krazywarez/domain-dig#readme")
    static let privacyPolicy = url("https://krz.sh/privacy/domain-dig/")
    static let supportEmail = "root@krz.sh"

    static var appStoreListing: URL { url("https://apps.apple.com/app/id\(appStoreID)") }
    static var writeReview: URL { url("https://apps.apple.com/app/id\(appStoreID)?action=write-review") }

    static var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Christian Cleberg"
    }

    /// Builds URLs from developer-controlled literals; a malformed literal is a
    /// programming error, surfaced loudly in development rather than force-unwrapped.
    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid AppLinks URL literal: \(string)")
        }
        return url
    }
}

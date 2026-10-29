import Foundation
import os

/// Nonisolated because nothing here needs the main actor: `enabled` is a
/// compile-time constant and `Logger` is `Sendable` and thread-safe. Without
/// this the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes it
/// main-actor-isolated, so a nonisolated caller — a UIKit completion handler,
/// say — cannot log the failure it was handed without hopping actors to write
/// one line. `AppIconController` had exactly that, as a Release-only warning
/// the Debug build did not show.
nonisolated enum DomainDebugLog {
#if DEBUG
    static let enabled = true
#else
    static let enabled = false
#endif
    private static let logger = Logger(subsystem: "co.krz.domain-dig", category: "Debug")

    static func debug(_ message: String) {
        guard enabled else { return }
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        guard enabled else { return }
        logger.error("\(message, privacy: .public)")
    }

    static func signpostStart(_ scope: String, domain: String? = nil) -> CFAbsoluteTime {
        let start = CFAbsoluteTimeGetCurrent()
        if let domain {
            debug("[START] \(scope) domain=\(domain)")
        } else {
            debug("[START] \(scope)")
        }
        return start
    }

    static func signpostEnd(_ scope: String, start: CFAbsoluteTime, domain: String? = nil, extra: String? = nil) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let suffix = extra.map { " \($0)" } ?? ""
        if let domain {
            debug("[END] \(scope) domain=\(domain) elapsedMs=\(elapsedMs)\(suffix)")
        } else {
            debug("[END] \(scope) elapsedMs=\(elapsedMs)\(suffix)")
        }
    }
}

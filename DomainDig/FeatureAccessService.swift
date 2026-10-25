import Foundation

enum FeatureTier: String, Codable, CaseIterable, Identifiable {
    case free
    case pro
    case proPlus = "dataPlus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free:
            return "Free"
        case .pro:
            return "Pro"
        case .proPlus:
            return "Pro+"
        }
    }
}

enum FeatureCapability: String, CaseIterable, Identifiable {
    case singleLookup
    case basicHistory
    case limitedTracking
    case workflows
    case batchOperations
    case automatedMonitoring
    case localAlerts
    case advancedExports
    case extendedSubdomains
    case sharedPortfolios
    case auditDepth
    case intelligenceDetail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleLookup:
            return "Single lookup"
        case .basicHistory:
            return "Basic history"
        case .limitedTracking:
            return "Limited tracking"
        case .workflows:
            return "Workflows"
        case .batchOperations:
            return "Batch operations"
        case .automatedMonitoring:
            return "Background monitoring"
        case .localAlerts:
            return "Local alerts"
        case .advancedExports:
            return "Advanced exports"
        case .extendedSubdomains:
            return "Extended subdomains"
        case .sharedPortfolios:
            return "Shared portfolios"
        case .auditDepth:
            return "Unlimited audits"
        case .intelligenceDetail:
            return "Intelligence detail"
        }
    }
}

struct FeatureEntitlements: Equatable {
    let tier: FeatureTier
    let capabilities: Set<FeatureCapability>
    let trackedDomainLimit: Int
    let workflowLimit: Int?
    let batchSizeLimit: Int?
    /// Concurrently open audit sessions; nil is unlimited.
    let activeAuditSessionLimit: Int?
    /// Snapshots kept per install, the retention dial D1 settled on. Not
    /// optional: every tier has a ceiling, and the store is not a place to
    /// accumulate without one.
    let historyRetentionLimit: Int
}

struct UpgradePromptContext: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let capability: FeatureCapability
}

enum FeatureAccessService {
    private static let effectivelyUnlimitedTrackedDomains = 5_000

    /// Reads the observable property rather than `PurchaseService.cachedTier`,
    /// the static over UserDefaults. SwiftUI records a dependency for any
    /// observable property read while a body evaluates, however deep in the
    /// call tree, so every `hasAccess` call site in a view now updates when a
    /// purchase lands. The nine `let _ = purchaseService.currentTier` discards
    /// that used to manufacture that dependency are gone with this.
    static var currentTier: FeatureTier {
        PurchaseService.shared.currentTier
    }

    static var entitlements: FeatureEntitlements {
        entitlements(for: currentTier)
    }

    static func entitlements(for tier: FeatureTier) -> FeatureEntitlements {
        switch tier {
        case .free:
            return FeatureEntitlements(
                tier: .free,
                capabilities: [.singleLookup, .basicHistory, .limitedTracking, .workflows, .batchOperations],
                trackedDomainLimit: 5,
                workflowLimit: 1,
                batchSizeLimit: 10,
                activeAuditSessionLimit: 1,
                historyRetentionLimit: 50
            )
        case .pro:
            return FeatureEntitlements(
                tier: .pro,
                capabilities: [
                    .singleLookup,
                    .basicHistory,
                    .limitedTracking,
                    .workflows,
                    .batchOperations,
                    .automatedMonitoring,
                    .localAlerts,
                    .advancedExports,
                    .extendedSubdomains
                ],
                trackedDomainLimit: effectivelyUnlimitedTrackedDomains,
                workflowLimit: nil,
                batchSizeLimit: nil,
                activeAuditSessionLimit: nil,
                historyRetentionLimit: 250
            )
        case .proPlus:
            return FeatureEntitlements(
                tier: .proPlus,
                capabilities: Set(FeatureCapability.allCases),
                trackedDomainLimit: effectivelyUnlimitedTrackedDomains,
                workflowLimit: nil,
                batchSizeLimit: nil,
                activeAuditSessionLimit: nil,
                historyRetentionLimit: 2_000
            )
        }
    }

    /// Snapshots this tier keeps. A downgrade lowers what the store may grow
    /// to; it never prunes what is already there (Review Focus #6).
    static var historyRetentionLimit: Int {
        entitlements.historyRetentionLimit
    }

    static func hasAccess(to capability: FeatureCapability) -> Bool {
        entitlements.capabilities.contains(capability)
    }

    static func canAddTrackedDomain(currentCount: Int) -> Bool {
        canAddTrackedDomain(currentCount: currentCount, tier: currentTier)
    }

    static func canAddTrackedDomain(currentCount: Int, tier: FeatureTier) -> Bool {
        currentCount < entitlements(for: tier).trackedDomainLimit
    }

    static func trackedDomainLimitMessage(currentCount: Int) -> String? {
        guard currentTier == .free else { return nil }
        if currentCount >= entitlements.trackedDomainLimit {
            return "Free includes up to \(entitlements.trackedDomainLimit) tracked domains. Available in Pro."
        }
        return "Free includes up to \(entitlements.trackedDomainLimit) tracked domains."
    }

    static func canCreateWorkflow(currentCount: Int) -> Bool {
        guard hasAccess(to: .workflows) else { return false }
        guard let limit = entitlements.workflowLimit else { return true }
        return currentCount < limit
    }

    static func canRunBatch(domainCount: Int) -> Bool {
        guard hasAccess(to: .batchOperations) else { return false }
        guard let limit = entitlements.batchSizeLimit else { return true }
        return domainCount <= limit
    }

    static func upgradeMessage(for capability: FeatureCapability) -> String {
        switch capability {
        case .workflows, .batchOperations, .automatedMonitoring, .localAlerts, .advancedExports,
             .extendedSubdomains:
            return "Available in Pro"
        case .sharedPortfolios, .auditDepth, .intelligenceDetail:
            return "Available in Pro+"
        case .limitedTracking:
            return "Tracking is limited on Free"
        case .singleLookup, .basicHistory:
            return "Included in Free"
        }
    }

    static func workflowLimitMessage(currentCount: Int) -> String? {
        guard let limit = entitlements.workflowLimit, currentCount >= limit else { return nil }
        return "Free includes up to \(limit) workflow."
    }

    static func batchLimitMessage(domainCount: Int) -> String? {
        guard let limit = entitlements.batchSizeLimit, domainCount > limit else { return nil }
        return "Free runs batches up to \(limit) domains."
    }

    static func workflowAllowanceSummary(currentCount: Int) -> String? {
        guard currentTier == .free, let limit = entitlements.workflowLimit else { return nil }
        if currentCount >= limit {
            return "Free includes up to \(limit) workflow. Available in Pro."
        }
        return "Free includes up to \(limit) workflow."
    }

    static func batchAllowanceSummary() -> String? {
        guard currentTier == .free, let limit = entitlements.batchSizeLimit else { return nil }
        return "Free runs batches up to \(limit) domains."
    }

    static func upgradePromptForTrackedDomains(currentCount: Int) -> UpgradePromptContext? {
        guard currentCount >= entitlements.trackedDomainLimit else { return nil }
        return UpgradePromptContext(
            title: "Available in Pro",
            message: "Free includes up to \(entitlements.trackedDomainLimit) tracked domains. You can keep your current watchlist, but adding more requires Pro.",
            capability: .limitedTracking
        )
    }

    static func upgradePromptForWorkflows(currentCount: Int) -> UpgradePromptContext? {
        guard let limit = entitlements.workflowLimit, currentCount >= limit else { return nil }
        return UpgradePromptContext(
            title: "Available in Pro",
            message: "Free includes up to \(limit) workflow. You can keep your current workflows, but creating more requires Pro.",
            capability: .workflows
        )
    }

    static func upgradePromptForBatch(domainCount: Int) -> UpgradePromptContext? {
        guard let limit = entitlements.batchSizeLimit, domainCount > limit else { return nil }
        return UpgradePromptContext(
            title: "Available in Pro",
            message: "Free runs batches up to \(limit) domains at a time. You can continue with smaller batches or upgrade to Pro.",
            capability: .batchOperations
        )
    }

    static func upgradePrompt(for capability: FeatureCapability) -> UpgradePromptContext {
        let title: String
        switch capability {
        case .sharedPortfolios, .auditDepth, .intelligenceDetail:
            title = "Available in Pro+"
        default:
            title = "Available in Pro"
        }
        return UpgradePromptContext(
            title: title,
            message: upgradeMessage(for: capability),
            capability: capability
        )
    }

    static func enabledFeatureLabels() -> [String] {
        FeatureCapability.allCases
            .filter { hasAccess(to: $0) }
            .map(\.title)
    }
}

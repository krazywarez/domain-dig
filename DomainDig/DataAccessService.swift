import Foundation

enum DataAccessService {
    static func hasAccess(to capability: DataCapability) -> Bool {
        FeatureAccessService.hasAccess(to: capability.feature)
    }
}

extension DataCapability {
    /// The plan feature that unlocks this data.
    var feature: FeatureCapability {
        switch self {
        case .ownershipHistory: .ownershipHistory
        case .dnsHistory: .dnsHistory
        case .extendedSubdomains: .extendedSubdomains
        case .domainPricing: .domainPricing
        case .reputation: .reputation
        }
    }
}

import XCTest
@testable import DomainDig

/// The tier table used to promise five capabilities that could not return data,
/// and they were Pro+'s only difference from Pro — so making the paywall honest
/// by deleting them would have left a paid tier granting nothing. These pin the
/// replacement table and that invariant.
final class FeatureAccessTests: XCTestCase {

    // MARK: Free

    func testFreeIncludesTheEverydayCapabilities() {
        let free = FeatureAccessService.entitlements(for: .free)

        XCTAssertTrue(free.capabilities.contains(.singleLookup))
        XCTAssertTrue(free.capabilities.contains(.basicHistory))
        XCTAssertTrue(free.capabilities.contains(.limitedTracking))
        XCTAssertTrue(free.capabilities.contains(.workflows))
        XCTAssertTrue(free.capabilities.contains(.batchOperations))
    }

    func testFreeExcludesThePaidCapabilities() {
        let free = FeatureAccessService.entitlements(for: .free)

        XCTAssertFalse(free.capabilities.contains(.automatedMonitoring))
        XCTAssertFalse(free.capabilities.contains(.localAlerts))
        XCTAssertFalse(free.capabilities.contains(.advancedExports))
        XCTAssertFalse(free.capabilities.contains(.extendedSubdomains))
        XCTAssertFalse(free.capabilities.contains(.sharedPortfolios))
        XCTAssertFalse(free.capabilities.contains(.auditDepth))
    }

    func testFreeKeepsItsAllowances() {
        let free = FeatureAccessService.entitlements(for: .free)

        XCTAssertEqual(free.trackedDomainLimit, 5)
        XCTAssertEqual(free.workflowLimit, 1)
        XCTAssertEqual(free.batchSizeLimit, 10)
        XCTAssertEqual(free.activeAuditSessionLimit, 1)
    }

    // MARK: Pro

    /// Extended subdomains moved down from Pro+: unlike the other four, it does
    /// return data a lower tier does not have — a live crt.sh query at a higher
    /// limit than the base lookup.
    func testProAddsMonitoringAlertsExportsAndExtendedSubdomains() {
        let pro = FeatureAccessService.entitlements(for: .pro)

        XCTAssertTrue(pro.capabilities.contains(.automatedMonitoring))
        XCTAssertTrue(pro.capabilities.contains(.localAlerts))
        XCTAssertTrue(pro.capabilities.contains(.advancedExports))
        XCTAssertTrue(pro.capabilities.contains(.extendedSubdomains))
    }

    func testProDoesNotIncludeTheProPlusCapabilities() {
        let pro = FeatureAccessService.entitlements(for: .pro)

        XCTAssertFalse(pro.capabilities.contains(.sharedPortfolios))
        XCTAssertFalse(pro.capabilities.contains(.auditDepth))
        XCTAssertFalse(pro.capabilities.contains(.intelligenceDetail))
    }

    func testProLiftsTheAllowances() {
        let pro = FeatureAccessService.entitlements(for: .pro)

        XCTAssertNil(pro.workflowLimit)
        XCTAssertNil(pro.batchSizeLimit)
        XCTAssertNil(pro.activeAuditSessionLimit)
        XCTAssertGreaterThan(pro.trackedDomainLimit, 1000)
    }

    // MARK: Pro+

    func testProPlusAddsSharedPortfoliosAuditDepthAndIntelligence() {
        let proPlus = FeatureAccessService.entitlements(for: .proPlus)

        XCTAssertTrue(proPlus.capabilities.contains(.sharedPortfolios))
        XCTAssertTrue(proPlus.capabilities.contains(.auditDepth))
        XCTAssertTrue(proPlus.capabilities.contains(.intelligenceDetail))
    }

    /// The intelligence breakdown was gated by a bare `currentTier != .proPlus`
    /// in two view bodies, which no audit of the capability table could see. It
    /// is a capability now so the table, the paywall and `enabledFeatureLabels`
    /// all agree, and so a test like this one can exist at all.
    func testIntelligenceDetailIsAProPlusCapability() {
        XCTAssertFalse(FeatureAccessService.entitlements(for: .free).capabilities.contains(.intelligenceDetail))
        XCTAssertFalse(FeatureAccessService.entitlements(for: .pro).capabilities.contains(.intelligenceDetail))
        XCTAssertTrue(FeatureAccessService.entitlements(for: .proPlus).capabilities.contains(.intelligenceDetail))
    }

    /// The finding this table replaces: Pro+ cost twice Pro and its only
    /// difference was five capabilities that returned nothing. A tier that
    /// grants no more than the one below it must not be sellable.
    func testProPlusGrantsStrictlyMoreThanPro() {
        let pro = FeatureAccessService.entitlements(for: .pro).capabilities
        let proPlus = FeatureAccessService.entitlements(for: .proPlus).capabilities

        XCTAssertTrue(pro.isSubset(of: proPlus))
        XCTAssertFalse(proPlus.subtracting(pro).isEmpty)
    }

    func testEachTierGrantsAtLeastTheOneBelowIt() {
        let free = FeatureAccessService.entitlements(for: .free).capabilities
        let pro = FeatureAccessService.entitlements(for: .pro).capabilities

        XCTAssertTrue(free.isSubset(of: pro))
    }

    // MARK: Nothing claims a capability that cannot produce data

    /// Pricing and reputation had no local fallback and no configured endpoint,
    /// so they were deleted rather than renamed. Their absence from the
    /// capability list is what stops the paywall advertising them again.
    func testNoCapabilityIsNamedForADeletedFeature() {
        let names = FeatureCapability.allCases.map(\.rawValue)

        XCTAssertFalse(names.contains("domainPricing"))
        XCTAssertFalse(names.contains("reputation"))
    }

    /// Ownership and DNS history derive from the user's own stored snapshots, so
    /// they are free features now and no longer gated at all.
    func testTheHistoryDerivationsAreNotGated() {
        let names = FeatureCapability.allCases.map(\.rawValue)

        XCTAssertFalse(names.contains("ownershipHistory"))
        XCTAssertFalse(names.contains("dnsHistory"))
    }

    // MARK: Downgrade safety

    /// A lapsed subscriber keeps data above the new ceiling. Nothing may refuse
    /// to read it: the limits gate adding, not holding.
    func testFreeTierStillReportsALimitWhenAlreadyOverIt() {
        let free = FeatureAccessService.entitlements(for: .free)

        XCTAssertFalse(FeatureAccessService.canAddTrackedDomain(currentCount: free.trackedDomainLimit, tier: .free))
        XCTAssertTrue(FeatureAccessService.canAddTrackedDomain(currentCount: 0, tier: .free))
        XCTAssertFalse(FeatureAccessService.canAddTrackedDomain(currentCount: 500, tier: .free))
        XCTAssertTrue(FeatureAccessService.canAddTrackedDomain(currentCount: 500, tier: .pro))
    }
}

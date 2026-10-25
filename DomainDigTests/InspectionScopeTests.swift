import XCTest
@testable import DomainDig

/// Section selection and the enrichment choice reach the inspection through
/// `inspectSnapshot`'s signature, so what each scope runs is a pure function
/// and these are what pin it. The inspection service itself takes a concrete
/// `LookupRuntime`, so there is no seam to assert the network calls through —
/// `DomainAvailabilityTests` covers the one service that can be stubbed.
final class InspectionScopeTests: XCTestCase {

    private var scratch: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "net.cleberg.DomainDig.tests.scope.\(UUID().uuidString)"
        scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        scratch.removePersistentDomain(forName: suiteName)
        scratch = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: What each scope runs

    func testFullWithEnrichmentRunsEverySection() {
        let scope = InspectionScope.full

        for section in LookupSectionKind.allCases {
            XCTAssertTrue(scope.runs(section), "full should run \(section.rawValue)")
            XCTAssertNil(scope.skipReason(for: section))
        }
    }

    func testQuickSkipsTheExpensiveSections() {
        let scope = InspectionScope(profile: .quick, allowsThirdPartyEnrichment: true)

        let skipped = LookupSectionKind.allCases.filter { !scope.runs($0) }

        XCTAssertEqual(
            Set(skipped),
            [.reachability, .portScan, .ipGeolocation, .subdomains, .suggestions]
        )
    }

    func testQuickStillRunsTheCoreSections() {
        let scope = InspectionScope(profile: .quick, allowsThirdPartyEnrichment: true)

        for section in [LookupSectionKind.dns, .availability, .ownership, .ssl, .hsts, .httpHeaders, .redirectChain, .ptr, .emailSecurity] {
            XCTAssertTrue(scope.runs(section), "quick should still run \(section.rawValue)")
        }
    }

    func testDecliningEnrichmentSkipsOnlyTheThirdPartySections() {
        let scope = InspectionScope(profile: .full, allowsThirdPartyEnrichment: false)

        let skipped = LookupSectionKind.allCases.filter { !scope.runs($0) }

        XCTAssertEqual(Set(skipped), [.ownership, .ipGeolocation, .subdomains, .suggestions])
    }

    /// Availability keeps running without enrichment: RDAP is only half of it,
    /// and the DNS fallback still recognises a domain that resolves.
    func testDecliningEnrichmentKeepsAvailabilityButDropsItsRDAPHalf() {
        let scope = InspectionScope(profile: .full, allowsThirdPartyEnrichment: false)

        XCTAssertTrue(scope.runs(.availability))
        XCTAssertFalse(scope.allowsRDAP)
        XCTAssertTrue(InspectionScope.full.allowsRDAP)
    }

    func testDecliningEnrichmentOnQuickSkipsTheUnionOfBoth() {
        let scope = InspectionScope(profile: .quick, allowsThirdPartyEnrichment: false)

        let skipped = LookupSectionKind.allCases.filter { !scope.runs($0) }

        XCTAssertEqual(
            Set(skipped),
            [.ownership, .reachability, .portScan, .ipGeolocation, .subdomains, .suggestions]
        )
    }

    // MARK: Skip reasons

    /// A skipped section shows why, so the UI does not read as a failed lookup.
    func testTheSkipReasonNamesTheProfileOrTheEnrichmentSetting() {
        let quick = InspectionScope(profile: .quick, allowsThirdPartyEnrichment: true)
        let declined = InspectionScope(profile: .full, allowsThirdPartyEnrichment: false)

        XCTAssertEqual(quick.skipReason(for: .portScan), "Not run in the Quick profile.")
        XCTAssertEqual(declined.skipReason(for: .ownership), "Not run: third-party enrichment is off in Settings.")
    }

    /// When both apply, the consent decision is the one worth reporting.
    func testEnrichmentOutranksTheProfileInTheSkipReason() {
        let scope = InspectionScope(profile: .quick, allowsThirdPartyEnrichment: false)

        XCTAssertEqual(scope.skipReason(for: .subdomains), "Not run: third-party enrichment is off in Settings.")
        XCTAssertEqual(scope.skipReason(for: .portScan), "Not run in the Quick profile.")
    }

    func testASectionThatRunsHasNoSkipReason() {
        XCTAssertNil(InspectionScope.full.skipReason(for: .dns))
        XCTAssertNil(InspectionScope(profile: .quick, allowsThirdPartyEnrichment: false).skipReason(for: .dns))
    }

    // MARK: The stored setting

    /// Both settings default on, which is how the app behaved before they
    /// existed.
    func testAnEmptyStoreReadsAsFullWithEnrichment() {
        XCTAssertEqual(InspectionScope.current(defaults: scratch), .full)
    }

    func testStoredValuesAreRead() {
        scratch.set(InspectionProfile.quick.rawValue, forKey: InspectionScope.profileDefaultsKey)
        scratch.set(false, forKey: InspectionScope.enrichmentDefaultsKey)

        XCTAssertEqual(
            InspectionScope.current(defaults: scratch),
            InspectionScope(profile: .quick, allowsThirdPartyEnrichment: false)
        )
    }

    /// A profile string the app does not know falls back to Full rather than
    /// quietly reducing what a lookup covers.
    func testAnUnknownStoredProfileFallsBackToFull() {
        scratch.set("exhaustive", forKey: InspectionScope.profileDefaultsKey)

        XCTAssertEqual(InspectionScope.current(defaults: scratch).profile, .full)
    }

    // MARK: The Local API's profile parameter

    private func apiProfile(_ queryItems: [URLQueryItem]) throws -> InspectionProfile {
        try XCTUnwrap(InspectionScope.requested(from: queryItems, defaults: scratch)).profile
    }

    /// A `v1` consumer sends no `profile`, so it has to keep getting Full.
    func testTheLocalAPIDefaultsToFullWithoutAProfileParameter() throws {
        XCTAssertEqual(try apiProfile([]), InspectionProfile.full)
        XCTAssertEqual(
            try apiProfile([URLQueryItem(name: "other", value: "quick")]),
            InspectionProfile.full
        )
    }

    func testTheLocalAPIReadsAnExplicitProfile() throws {
        XCTAssertEqual(
            try apiProfile([URLQueryItem(name: "profile", value: "quick")]),
            InspectionProfile.quick
        )
        XCTAssertEqual(
            try apiProfile([URLQueryItem(name: "profile", value: " FULL ")]),
            InspectionProfile.full
        )
    }

    /// An unrecognised profile is a request error rather than a silent Full, so
    /// a typo does not look like it worked.
    func testTheLocalAPIRejectsAnUnknownProfile() {
        XCTAssertNil(InspectionScope.requested(from: [URLQueryItem(name: "profile", value: "deep")], defaults: scratch))
    }

    func testAnEmptyProfileValueIsTreatedAsAbsent() throws {
        for value in ["", "   ", nil] {
            XCTAssertEqual(
                try apiProfile([URLQueryItem(name: "profile", value: value)]),
                InspectionProfile.full,
                "an empty profile should read as absent, not as an error"
            )
        }
    }

    /// The enrichment setting is the device owner's consent decision, so the
    /// Local API follows it and a request cannot turn it back on.
    func testTheLocalAPIFollowsTheStoredEnrichmentSetting() throws {
        scratch.set(false, forKey: InspectionScope.enrichmentDefaultsKey)

        let scope = try XCTUnwrap(
            InspectionScope.requested(
                from: [URLQueryItem(name: "profile", value: "full")],
                defaults: scratch
            )
        )

        XCTAssertEqual(scope.profile, InspectionProfile.full)
        XCTAssertFalse(scope.allowsThirdPartyEnrichment)
    }
}

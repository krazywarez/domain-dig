import XCTest
@testable import DomainDig

/// `run()` used to hand anything non-empty to 14 section services, which each
/// reported their own network error for input that was never a domain. These pin
/// the input-boundary validator that answers before the lookup starts.
final class DomainNameTests: XCTestCase {

    func testAcceptsAPlainHost() {
        XCTAssertEqual(DomainName.validate("example.com"), .success("example.com"))
    }

    func testLowercasesAndTrims() {
        XCTAssertEqual(DomainName.validate("  EXAMPLE.COM\n"), .success("example.com"))
    }

    func testStripsSchemeAndPath() {
        XCTAssertEqual(DomainName.validate("https://example.com/path?q=1"), .success("example.com"))
    }

    func testStripsAPort() {
        XCTAssertEqual(DomainName.validate("example.com:8443"), .success("example.com"))
    }

    func testStripsUserInfo() {
        XCTAssertEqual(DomainName.validate("user:pass@example.com"), .success("example.com"))
    }

    func testStripsAQueryWithNoPath() {
        XCTAssertEqual(DomainName.validate("example.com?q=1"), .success("example.com"))
    }

    func testRejectsASingleLabel() {
        XCTAssertEqual(DomainName.validate("localhost"), .failure(.singleLabel))
    }

    func testRejectsAnInteriorSpace() {
        XCTAssertEqual(DomainName.validate("exa mple.com"), .failure(.invalidCharacter(" ")))
    }

    /// `DomainHostURL` decodes escapes, so it reads `https://ex%20ample.com` as
    /// host `ex ample.com` and forms a URL no section service can resolve.
    func testRejectsAPercentEscape() {
        XCTAssertEqual(DomainName.validate("https://ex%20ample.com"), .failure(.invalidCharacter("%")))
    }

    func testRejectsAnEmptyLabel() {
        XCTAssertEqual(DomainName.validate("a..b.com"), .failure(.malformedLabel("")))
    }

    /// `-x.com` forms a URL, so `DomainHostURL` is not a substitute for these
    /// label rules — the invariant only runs the other way.
    func testRejectsALeadingHyphenLabel() {
        XCTAssertEqual(DomainName.validate("-x.com"), .failure(.malformedLabel("-x")))
    }

    func testRejectsALabelOver63Bytes() {
        let label = String(repeating: "a", count: 64)
        XCTAssertEqual(DomainName.validate("\(label).com"), .failure(.labelTooLong))
    }

    func testRejectsAHostOver253Bytes() {
        let label = String(repeating: "a", count: 63)
        let host = Array(repeating: label, count: 4).joined(separator: ".")
        XCTAssertEqual(DomainName.validate(host), .failure(.tooLong))
    }

    /// The limit applies to the IDNA-encoded label, so it turns on the encoded
    /// size rather than the typed one: these 40 distinct CJK characters encode
    /// to 83 bytes, while 40 repeats of one character encode to 46 and pass.
    func testMeasuresLengthOnPunycode() {
        let label = String((0..<40).compactMap { UnicodeScalar(UInt32(0x4E00 + $0 * 7)).map(Character.init) })
        XCTAssertEqual(DomainName.validate("\(label).com"), .failure(.labelTooLong))
        XCTAssertEqual(
            DomainName.validate("\(String(repeating: "域", count: 40)).com"),
            .success("\(String(repeating: "域", count: 40)).com")
        )
    }

    func testAcceptsAUnicodeHost() {
        XCTAssertEqual(DomainName.validate("münchen.de"), .success("münchen.de"))
    }

    func testAcceptsATrailingDot() {
        XCTAssertEqual(DomainName.validate("example.com."), .success("example.com"))
    }

    /// One-directional invariant: everything the validator accepts can be built
    /// into a request URL.
    func testAcceptedHostsFormARequestURL() {
        for host in ["example.com", "münchen.de", "a.b.c.example.com"] {
            guard case .success(let validated) = DomainName.validate(host) else {
                return XCTFail("\(host) should validate")
            }
            XCTAssertNotNil(DomainHostURL.https(validated))
        }
    }
}

/// The validator sits at the input boundary only. `normalizedDomain` is the key
/// that matches already-stored rows, so it stays lenient: routing it through the
/// validator would turn tracking and workflow lookups into no-ops for any stored
/// domain the rules reject.
@MainActor
final class DomainViewModelInputTests: XCTestCase {
    /// Shared and never released: deallocating a `DomainViewModel` runs its
    /// implicit main-actor-isolated deinit through the iOS 17 back-deployment
    /// shim, which aborts in the simulator. The app holds one for its whole
    /// lifetime, so nothing releases one there either.
    private static let viewModel = DomainViewModel()

    func testAnInvalidDomainDoesNotStartALookup() {
        let viewModel = Self.viewModel
        viewModel.domain = "localhost"

        viewModel.run()

        XCTAssertFalse(viewModel.hasRun)
        XCTAssertNotNil(viewModel.domainInputError)
    }

    func testAStoredSingleLabelDomainStillTracksAndMatchesWorkflows() {
        let viewModel = Self.viewModel
        viewModel.trackedDomains = []
        viewModel.workflows = [DomainWorkflow(name: "Internal", domains: ["localhost"])]

        XCTAssertTrue(viewModel.trackDomain(domain: "localhost", availabilityStatus: nil))
        XCTAssertEqual(viewModel.workflowsContaining(domain: "localhost").count, 1)
    }
}

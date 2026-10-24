import XCTest
@testable import DomainDig

/// The inspected domain is free text, and the section services used to force it
/// into a URL with `!`. These pin the two pure helpers that replaced that.
final class DomainHostURLTests: XCTestCase {

    func testBuildsHTTPSURLForAPlainHost() {
        XCTAssertEqual(DomainHostURL.https("example.com")?.absoluteString, "https://example.com")
    }

    func testBuildsHTTPURLForAPlainHost() {
        XCTAssertEqual(DomainHostURL.http("example.com")?.absoluteString, "http://example.com")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(DomainHostURL.https("  example.com\n")?.absoluteString, "https://example.com")
    }

    /// The crash this replaced: `URL(string: "https://exa mple.com")` is nil, so
    /// the force-unwrap trapped. Reachable by typing `example .com`, or by
    /// separating bulk input with spaces instead of commas or newlines.
    func testRejectsAnInteriorSpace() {
        XCTAssertNil(DomainHostURL.https("exa mple.com"))
    }

    func testRejectsAnInteriorTab() {
        XCTAssertNil(DomainHostURL.https("exa\tmple.com"))
    }

    func testRejectsAControlCharacter() {
        XCTAssertNil(DomainHostURL.https("exa\u{0}mple.com"))
    }

    func testRejectsInputWithNoHostComponent() {
        XCTAssertNil(DomainHostURL.https(""))
        XCTAssertNil(DomainHostURL.https("   "))
        XCTAssertNil(DomainHostURL.https("/"))
        XCTAssertNil(DomainHostURL.https(":443"))
    }

    func testEncodesAnInternationalizedHost() {
        XCTAssertEqual(DomainHostURL.https("münchen.de")?.host, "xn--mnchen-3ya.de")
    }
}

/// `rdap.org` answers 404 both for a domain its registry does not hold and for a
/// TLD it knows no RDAP server for. Only the first means "available", so the
/// availability check turns on which server answered.
final class RDAPRegistryOriginTests: XCTestCase {

    func testRegistryResponseCountsAsAnAnswer() {
        let url = URL(string: "https://rdap.verisign.com/com/v1/domain/example.com")
        XCTAssertTrue(RDAPService.answeredByRegistry(responseURL: url))
    }

    func testBootstrapResponseDoesNotCountAsAnAnswer() {
        let url = URL(string: "https://rdap.org/domain/example.invalidtld")
        XCTAssertFalse(RDAPService.answeredByRegistry(responseURL: url))
    }

    func testBootstrapSubdomainDoesNotCountAsAnAnswer() {
        let url = URL(string: "https://www.rdap.org/domain/example.invalidtld")
        XCTAssertFalse(RDAPService.answeredByRegistry(responseURL: url))
    }

    func testHostMatchIsCaseInsensitive() {
        let url = URL(string: "https://RDAP.ORG/domain/example.com")
        XCTAssertFalse(RDAPService.answeredByRegistry(responseURL: url))
    }

    func testMissingResponseURLDoesNotCountAsAnAnswer() {
        XCTAssertFalse(RDAPService.answeredByRegistry(responseURL: nil))
    }

    /// A host that merely ends in the bootstrap name is a different domain.
    func testLookalikeHostCountsAsAnAnswer() {
        let url = URL(string: "https://notrdap.org/domain/example.com")
        XCTAssertTrue(RDAPService.answeredByRegistry(responseURL: url))
    }
}

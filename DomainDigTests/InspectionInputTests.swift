import XCTest
@testable import DomainDig

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

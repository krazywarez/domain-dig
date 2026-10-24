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

    /// 40 CJK characters are 40 typed characters but over 63 bytes once IDNA
    /// encodes them, and the registry limit applies to the encoded form.
    func testMeasuresLengthOnPunycode() {
        let label = String(repeating: "域", count: 40)
        XCTAssertEqual(DomainName.validate("\(label).com"), .failure(.labelTooLong))
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

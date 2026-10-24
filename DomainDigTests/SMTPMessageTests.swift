import XCTest
@testable import DomainDig

/// The notification mail is assembled by joining lines with CRLF and sending
/// them raw, so values that reach it decide the wire format. Two things can go
/// wrong: a bare line break ends a header and lets the rest be read as more
/// headers, and a line of "." alone ends the DATA command and lets the rest be
/// read as SMTP commands. Both values are reachable — the inspected domain
/// arrives in the subject, and the event details carry arbitrary keys.
final class SMTPMessageTests: XCTestCase {

    // MARK: Header values

    func testAPlainValueIsAllowed() {
        XCTAssertEqual(SMTPMessage.validatedHeaderValue("example.com"), "example.com")
    }

    func testALineFeedIsRefused() {
        XCTAssertNil(SMTPMessage.validatedHeaderValue("example.com\nBcc: attacker@example.net"))
    }

    func testACarriageReturnIsRefused() {
        XCTAssertNil(SMTPMessage.validatedHeaderValue("example.com\r"))
    }

    func testACRLFPairIsRefused() {
        XCTAssertNil(SMTPMessage.validatedHeaderValue("a\r\nb"))
    }

    // MARK: Dot stuffing

    /// The case that ends the message early: a line holding nothing but a dot.
    func testALoneDotIsDoubled() {
        XCTAssertEqual(SMTPMessage.dotStuffed("before\r\n.\r\nafter"), "before\r\n..\r\nafter")
    }

    func testALineStartingWithADotIsDoubled() {
        XCTAssertEqual(SMTPMessage.dotStuffed("a\r\n.MAIL FROM:<x>"), "a\r\n..MAIL FROM:<x>")
    }

    func testTheFirstLineIsStuffedToo() {
        XCTAssertEqual(SMTPMessage.dotStuffed(".leading"), "..leading")
    }

    func testOrdinaryTextIsUnchanged() {
        let body = "Subject: fine\r\n\r\nA domain changed. Nothing to stuff."
        XCTAssertEqual(SMTPMessage.dotStuffed(body), body)
    }

    func testADotInsideALineIsNotTouched() {
        XCTAssertEqual(SMTPMessage.dotStuffed("example.com changed"), "example.com changed")
    }
}

/// The deep link is the one path into these values from outside the app.
final class DeepLinkSanitizingTests: XCTestCase {

    func testAPlainDomainIsAccepted() {
        let url = URL(string: "domaindig://inspect?domain=example.com")!
        XCTAssertEqual(DomainDigDeepLink.action(from: url), .inspect("example.com"))
    }

    func testAnEncodedLineBreakRefusesTheLink() {
        let url = URL(string: "domaindig://inspect?domain=example.com%0ABcc:%20attacker@example.net")!
        XCTAssertNil(DomainDigDeepLink.action(from: url))
    }

    /// A trailing break is trimmed before the check, which leaves a clean
    /// value — so the link is honoured rather than refused. Only an interior
    /// one survives trimming, and that is the case worth refusing.
    func testATrailingCarriageReturnIsTrimmed() {
        let url = URL(string: "domaindig://watch?domain=example.com%0D")!
        XCTAssertEqual(DomainDigDeepLink.action(from: url), .watch("example.com"))
    }

    func testAnInteriorCarriageReturnRefusesTheLink() {
        let url = URL(string: "domaindig://watch?domain=example%0D.com")!
        XCTAssertNil(DomainDigDeepLink.action(from: url))
    }

    func testAnEncodedNullRefusesTheLink() {
        let url = URL(string: "domaindig://domain?domain=example%00.com")!
        XCTAssertNil(DomainDigDeepLink.action(from: url))
    }
}

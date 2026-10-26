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

    /// C8: the probe used to look only at a label's first few characters, so
    /// an unencodable character sitting after them reported `.labelTooLong`
    /// instead of `.malformedLabel`.
    ///
    /// Calibrated on the character rather than hard-coded, because which
    /// scalars IDNA refuses is Foundation's business and moves between
    /// releases. If none of the candidates is refused, there is nothing to
    /// assert on this runtime.
    func testAnUnencodableCharacterIsMalformedWhereverItSitsInTheLabel() throws {
        let candidates = ["\u{200B}", "\u{FFFF}", "\u{2E2F}", "\u{1D173}"]
        guard let unencodable = candidates.first(where: { character in
            DomainName.validate("\(character).com") == .failure(.malformedLabel(character))
        }) else {
            throw XCTSkip("no IDNA-unencodable character among the candidates on this runtime")
        }

        // Far enough in that the old eight-character prefix probe missed it,
        // and short enough that the label cannot be over the byte limit.
        let label = String(repeating: "a", count: 20) + unencodable

        XCTAssertEqual(
            DomainName.validate("\(label).com"),
            .failure(.malformedLabel(label)),
            "an unencodable character past the probe length still makes the label malformed"
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
    /// On a scratch store: `trackDomain` persists, so on `.standard` this
    /// test wrote "localhost" into the store of whichever app shares the
    /// simulator.
    private static let viewModel = DomainViewModel(
        defaults: UserDefaults(suiteName: "net.cleberg.DomainDig.tests.input") ?? .standard
    )

    // MARK: Bulk input (U5)

    /// The defect: ten domains with two typos ran eight and said nothing about
    /// the other two.
    func testBulkInputKeepsTheValidEntriesAndNamesTheRest() {
        let parsed = Self.viewModel.parsedBulkInput(from: "example.com, not valid!!, apple.com")

        XCTAssertEqual(parsed.domains, ["example.com", "apple.com"])
        XCTAssertEqual(parsed.skipped, ["not", "valid!!"], "each rejected token is reported as typed")
        XCTAssertEqual(
            parsed.skippedMessage,
            "Skipped 2 entries that are not valid domains: not, valid!!."
        )
    }

    func testBulkInputDeduplicatesAndIgnoresBlankSeparators() {
        let parsed = Self.viewModel.parsedBulkInput(from: "example.com,\n\n  example.com ,\napple.com\n\n")

        XCTAssertEqual(parsed.domains, ["example.com", "apple.com"])
        XCTAssertTrue(parsed.skipped.isEmpty, "whitespace between entries is not an entry")
        XCTAssertNil(parsed.skippedMessage)
    }

    func testValidBulkInputReportsNothing() {
        let parsed = Self.viewModel.parsedBulkInput(from: "example.com\napple.com")

        XCTAssertEqual(parsed.domains.count, 2)
        XCTAssertNil(parsed.skippedMessage)
    }

    /// One bad entry reads as a sentence about that entry, not as a count.
    func testASingleSkippedEntryIsNamedInTheSingular() {
        let parsed = ParsedBulkInput(domains: ["example.com"], skipped: ["nope!"])

        XCTAssertEqual(parsed.skippedMessage, "Skipped nope!: not a valid domain.")
    }

    /// The worst case before this change: every entry invalid meant the button
    /// did nothing at all, with no explanation.
    func testAllEntriesInvalidSaysThereIsNothingToRun() {
        let many = ParsedBulkInput(domains: [], skipped: ["a!", "b!"])
        XCTAssertEqual(
            many.skippedMessage,
            "None of these is a valid domain, so there is nothing to run: a!, b!."
        )

        let one = ParsedBulkInput(domains: [], skipped: ["a!"])
        XCTAssertEqual(one.skippedMessage, "a! is not a valid domain, so there is nothing to run.")
    }

    /// A pasted list of typos names the first few and counts the rest, rather
    /// than becoming a wall of text.
    func testManySkippedEntriesAreTruncated() {
        let parsed = ParsedBulkInput(
            domains: ["example.com"],
            skipped: ["a!", "b!", "c!", "d!", "e!", "f!", "g!"]
        )

        XCTAssertEqual(
            parsed.skippedMessage,
            "Skipped 7 entries that are not valid domains: a!, b!, c!, d!, e! and 2 more."
        )
    }

    /// The whole point: running a bulk lookup leaves the message behind for the
    /// view to show.
    func testRunningABulkLookupReportsWhatItSkipped() {
        let viewModel = Self.viewModel
        viewModel.bulkInputError = nil
        viewModel.bulkInput = "example.com, localhost"

        viewModel.runBulkLookup()

        XCTAssertEqual(viewModel.bulkInputError, "Skipped localhost: not a valid domain.")
    }

    func testABulkLookupWithNothingValidStillReports() {
        let viewModel = Self.viewModel
        viewModel.bulkInputError = nil
        viewModel.bulkInput = "localhost"

        viewModel.runBulkLookup()

        XCTAssertEqual(
            viewModel.bulkInputError,
            "localhost is not a valid domain, so there is nothing to run."
        )
        XCTAssertFalse(viewModel.batchLookupRunning)
    }

    func testAValidBulkLookupLeavesNoMessage() {
        let viewModel = Self.viewModel
        viewModel.bulkInputError = "stale"
        viewModel.bulkInput = "example.com"

        viewModel.runBulkLookup()

        XCTAssertNil(viewModel.bulkInputError)
        viewModel.cancelBatchLookup()
    }

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

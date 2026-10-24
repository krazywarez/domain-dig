import XCTest
@testable import DomainDig

/// `LookupRuntime.execute` used to cache an enum of fourteen payload kinds and
/// re-derive the caller's type from it with a closure, trapping on
/// `fatalError` when the case did not match. It is generic over its value now,
/// so the mismatch cannot be expressed. These pin what the cache does instead,
/// which nothing covered when the trap was the only thing guarding it.
///
/// Every public method on the runtime reaches a live service, so `execute` is
/// the seam. The operations here are closures that count their own calls.
final class LookupCacheTests: XCTestCase {

    private func makeRuntime() -> LookupRuntime { LookupRuntime() }

    // MARK: Caching

    func testTheFirstCallIsLiveAndTheSecondIsCached() async {
        let runtime = makeRuntime()
        let calls = Counter()

        let first = await runtime.execute(key: .domain("example.com", .dns)) {
            await calls.increment()
            return 1
        }
        let second = await runtime.execute(key: .domain("example.com", .dns)) {
            await calls.increment()
            return 2
        }

        XCTAssertEqual(first.source, .live)
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.source, .cached)
        XCTAssertEqual(second.value, 1, "the cached call returned a fresh value")
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1, "the operation ran twice")
    }

    /// The key carries the section kind, so two sections of one domain are
    /// separate entries. Collapsing them is what would have made a payload of
    /// the wrong type reachable under the old design.
    func testTheSameDomainCachesEachSectionSeparately() async {
        let runtime = makeRuntime()

        let dns = await runtime.execute(key: .domain("example.com", .dns)) { "dns" }
        let ssl = await runtime.execute(key: .domain("example.com", .ssl)) { "ssl" }

        XCTAssertEqual(dns.value, "dns")
        XCTAssertEqual(ssl.value, "ssl")
        XCTAssertEqual(ssl.source, .live, "the ssl key read the dns entry")
    }

    func testDomainAndSubjectKeysDoNotCollide() async {
        let runtime = makeRuntime()

        let domain = await runtime.execute(key: .domain("x", .ptr)) { "domain" }
        let subject = await runtime.execute(key: .subject("x", .ptr)) { "subject" }

        XCTAssertEqual(domain.value, "domain")
        XCTAssertEqual(subject.value, "subject")
        XCTAssertEqual(subject.source, .live)
    }

    /// A cached value of another type is not returned as this one. Under the
    /// old design the equivalent check was the `extract` closure, and failing
    /// it after a live fetch is what reached the `fatalError`. Here it must
    /// simply fall through to a live fetch.
    func testAKeyHoldingAnotherTypeFallsThroughToALiveFetch() async {
        let runtime = makeRuntime()

        let stored = await runtime.execute(key: .domain("example.com", .dns)) { 42 }
        let reread = await runtime.execute(key: .domain("example.com", .dns)) { "a string" }

        XCTAssertEqual(stored.value, 42)
        XCTAssertEqual(reread.value, "a string")
        XCTAssertEqual(reread.source, .live)
    }

    // MARK: Clearing

    func testClearingTheCacheMakesTheNextCallLive() async {
        let runtime = makeRuntime()
        let calls = Counter()

        _ = await runtime.execute(key: .domain("example.com", .dns)) {
            await calls.increment()
            return 1
        }
        await runtime.clearCache()
        let afterClear = await runtime.execute(key: .domain("example.com", .dns)) {
            await calls.increment()
            return 2
        }

        XCTAssertEqual(afterClear.source, .live)
        XCTAssertEqual(afterClear.value, 2)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 2)
    }

    /// `clearCache()` cancels what is in flight, and both callers are
    /// user-initiated — the Clear Lookup Cache action and the full data wipe.
    /// The erased task `inFlight` holds is a wrapper around the real one, so
    /// cancelling the wrapper alone would leave the work running.
    func testClearingTheCacheCancelsWorkInFlight() async {
        let runtime = makeRuntime()
        let observed = CancellationProbe()

        let pending = Task {
            await runtime.execute(key: .domain("example.com", .subdomains)) { () -> Int in
                for _ in 0..<200 {
                    if Task.isCancelled {
                        await observed.record()
                        return -1
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return 0
            }
        }

        // Let the operation reach its loop before clearing.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await runtime.clearCache()
        _ = await pending.value

        let sawCancellation = await observed.wasCancelled
        XCTAssertTrue(
            sawCancellation,
            "the operation never saw cancellation, so clearCache() did not reach it"
        )
    }
}

/// `actor` rather than a captured `var`: the operations run off the test's
/// context and Swift 6 will not let them mutate shared state otherwise.
private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor CancellationProbe {
    private(set) var wasCancelled = false
    func record() { wasCancelled = true }
}

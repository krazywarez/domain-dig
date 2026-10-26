import XCTest
@testable import DomainDig

/// The Local API's routing and auth had no coverage: `LocalAPIContractTests`
/// pins the JSON shape of a response, not which request produces it. Matching
/// and authorisation are both pure, and `handle` answers 401 and 404 before it
/// reaches the store or the network, so all of that is reachable here. The
/// success paths moved to `LocalAPISuccessTests` once the handler took an
/// injected store; `/inspect` is still uncovered, because it runs a live
/// lookup.
final class LocalAPIRoutingTests: XCTestCase {

    // MARK: Every documented route

    func testGetRoutes() {
        XCTAssertEqual(LocalAPIRoute.match(method: "GET", pathComponents: ["portfolio"]), .portfolio)
        XCTAssertEqual(LocalAPIRoute.match(method: "GET", pathComponents: ["domains"]), .domains)
        XCTAssertEqual(LocalAPIRoute.match(method: "GET", pathComponents: ["events"]), .events)
        XCTAssertEqual(LocalAPIRoute.match(method: "GET", pathComponents: ["monitoring"]), .monitoring)
    }

    func testDomainScopedGetRoutesCarryTheDomain() {
        XCTAssertEqual(
            LocalAPIRoute.match(method: "GET", pathComponents: ["domains", "example.com"]),
            .domainDetails("example.com")
        )
        XCTAssertEqual(
            LocalAPIRoute.match(method: "GET", pathComponents: ["domains", "example.com", "history"]),
            .domainHistory("example.com")
        )
    }

    func testPostRoutes() {
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", pathComponents: ["inspect"]), .inspectFromBody)
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", pathComponents: ["inspect", "example.com"]),
            .inspect("example.com")
        )
    }

    func testMonitoringTogglesCarryBothDomainAndState() {
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", pathComponents: ["monitoring", "example.com", "enable"]),
            .setMonitoring(domain: "example.com", enabled: true)
        )
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", pathComponents: ["monitoring", "example.com", "disable"]),
            .setMonitoring(domain: "example.com", enabled: false)
        )
    }

    // MARK: What must not match

    /// The method is part of the route, not decoration: a read route must not
    /// answer a write and the reverse.
    func testTheMethodIsPartOfTheRoute() {
        XCTAssertNil(LocalAPIRoute.match(method: "POST", pathComponents: ["portfolio"]))
        XCTAssertNil(LocalAPIRoute.match(method: "GET", pathComponents: ["inspect"]))
        XCTAssertNil(LocalAPIRoute.match(method: "DELETE", pathComponents: ["domains", "example.com"]))
    }

    func testUnknownTrailingSegmentsDoNotMatch() {
        XCTAssertNil(LocalAPIRoute.match(method: "GET", pathComponents: ["domains", "example.com", "notes"]))
        XCTAssertNil(LocalAPIRoute.match(method: "POST", pathComponents: ["monitoring", "example.com", "pause"]))
    }

    func testUnknownAndEmptyPathsDoNotMatch() {
        XCTAssertNil(LocalAPIRoute.match(method: "GET", pathComponents: ["nope"]))
        XCTAssertNil(LocalAPIRoute.match(method: "GET", pathComponents: []))
        XCTAssertNil(LocalAPIRoute.match(method: "GET", pathComponents: ["portfolio", "extra"]))
    }

    // MARK: Authorisation

    func testEitherDocumentedHeaderAuthorises() {
        XCTAssertTrue(LocalAPIRequestHandler.isAuthorized(
            request: request(headers: ["x-api-token": "secret"]), expectedToken: "secret"
        ))
        XCTAssertTrue(LocalAPIRequestHandler.isAuthorized(
            request: request(headers: ["authorization": "Bearer secret"]), expectedToken: "secret"
        ))
    }

    func testAWrongOrMissingTokenIsRefused() {
        XCTAssertFalse(LocalAPIRequestHandler.isAuthorized(
            request: request(headers: ["x-api-token": "wrong"]), expectedToken: "secret"
        ))
        XCTAssertFalse(LocalAPIRequestHandler.isAuthorized(request: request(headers: [:]), expectedToken: "secret"))
        XCTAssertFalse(LocalAPIRequestHandler.isAuthorized(
            request: request(headers: ["authorization": "secret"]), expectedToken: "secret"
        ))
    }

    /// With no token configured the server must refuse everything rather than
    /// treat an absent credential as a match.
    func testAnUnconfiguredTokenRefusesEverything() {
        XCTAssertFalse(LocalAPIRequestHandler.isAuthorized(request: request(headers: [:]), expectedToken: ""))
        XCTAssertFalse(LocalAPIRequestHandler.isAuthorized(
            request: request(headers: ["x-api-token": ""]), expectedToken: ""
        ))
    }

    // MARK: The error envelopes the contract documents

    func testAnUnauthorisedRequestAnswers401InTheEnvelope() async throws {
        let response = await LocalAPIRequestHandler().handle(
            request: request(path: "/portfolio", headers: [:]), expectedToken: "secret"
        )

        XCTAssertEqual(response.statusCode, 401)
        let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
        XCTAssertFalse(envelope.success)
        XCTAssertEqual(envelope.version, "v1")
        XCTAssertEqual(envelope.error.code, "unauthorized")
    }

    func testAnUnknownRouteAnswers404InTheEnvelope() async throws {
        let response = await LocalAPIRequestHandler().handle(
            request: request(path: "/nope", headers: ["x-api-token": "secret"]), expectedToken: "secret"
        )

        XCTAssertEqual(response.statusCode, 404)
        let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
        XCTAssertFalse(envelope.success)
        XCTAssertEqual(envelope.version, "v1")
        XCTAssertEqual(envelope.error.code, "not_found")
    }

    // MARK: Helpers

    /// Header keys are lowercased by the request parser, which is why the
    /// handler looks them up in lower case.
    private func request(path: String = "/portfolio", headers: [String: String]) -> LocalAPIHTTPRequest {
        LocalAPIHTTPRequest(method: "GET", path: path, queryItems: [], headers: headers, body: Data())
    }
}

/// Decoded independently of the app's own envelope type, so the test asserts
/// the wire shape the contract promises rather than agreeing with itself.
private struct ErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }

    let success: Bool
    let version: String
    let error: Failure
}

import XCTest
@testable import DomainDig

/// `AWSSigV4Tests` pins the signature itself to AWS's published vectors, so
/// what is left to check here is that the client hands the signer the right
/// inputs — and, above all, that the URL it sends carries the same encoded
/// path the signature was computed over. If those two disagree the upload
/// fails as `SignatureDoesNotMatch`, which says nothing about why.
final class S3UploadClientTests: XCTestCase {

    private let credentials = AWSSigV4.Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )

    private let now = Date(timeIntervalSince1970: 1_369_353_600)

    private func configuration(
        endpoint: String = "https://s3.eu-central-1.amazonaws.com",
        region: String = "eu-central-1",
        bucket: String = "my-bucket",
        keyPrefix: String = "domaindig",
        usesPathStyle: Bool = false
    ) -> S3IntegrationConfiguration {
        S3IntegrationConfiguration(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            keyPrefix: keyPrefix,
            usesPathStyle: usesPathStyle,
            accessKeyID: credentials.accessKeyID,
            credentialReference: "ref"
        )
    }

    private func object(key: String = "example.com/2013-05-24T00:00:00Z.json") -> S3UploadClient.Object {
        S3UploadClient.Object(key: key, body: Data("{}".utf8), contentType: "application/json")
    }

    // MARK: Addressing

    func testVirtualHostedAddressingPutsTheBucketInTheHost() throws {
        let request = try S3UploadClient.request(
            for: object(),
            configuration: configuration(),
            credentials: credentials,
            now: now
        )

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://my-bucket.s3.eu-central-1.amazonaws.com/domaindig/example.com/2013-05-24T00%3A00%3A00Z.json"
        )
    }

    /// MinIO and R2 custom domains need the bucket in the path instead.
    func testPathStyleAddressingPutsTheBucketInThePath() throws {
        let request = try S3UploadClient.request(
            for: object(),
            configuration: configuration(endpoint: "https://minio.example.com", usesPathStyle: true),
            credentials: credentials,
            now: now
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://minio.example.com/my-bucket/domaindig/example.com/2013-05-24T00%3A00%3A00Z.json"
        )
    }

    /// A non-default port is part of the signed host header, because the
    /// server compares the header it received.
    func testANonDefaultPortReachesTheSignedHostHeader() throws {
        let request = try S3UploadClient.request(
            for: object(),
            configuration: configuration(endpoint: "https://minio.example.com:9000", usesPathStyle: true),
            credentials: credentials,
            now: now
        )

        XCTAssertEqual(request.url?.port, 9000)
        // Signed under the host:port form, which is what the signature below
        // has to have been computed over.
        let expected = AWSSigV4.authorizationHeader(
            for: AWSSigV4.Request(
                method: "PUT",
                path: "/my-bucket/domaindig/example.com/2013-05-24T00:00:00Z.json",
                headers: [
                    "Host": "minio.example.com:9000",
                    "Content-Type": "application/json",
                    "x-amz-content-sha256": AWSSigV4.sha256Hex(Data("{}".utf8)),
                    "x-amz-date": "20130524T000000Z"
                ],
                payloadSHA256: AWSSigV4.sha256Hex(Data("{}".utf8))
            ),
            scope: AWSSigV4.Scope(region: "eu-central-1", service: "s3", date: now),
            credentials: credentials
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
    }

    // MARK: The URL and the signature have to agree

    /// The invariant the whole client turns on: whatever encoding the URL
    /// carries is the encoding the signature covers. A space is the case
    /// `URLComponents` and SigV4 disagree about.
    func testTheSentPathIsExactlyThePathThatWasSigned() throws {
        let configuration = configuration(keyPrefix: "")
        let object = object(key: "a domain/with space.json")

        let request = try S3UploadClient.request(
            for: object,
            configuration: configuration,
            credentials: credentials,
            now: now
        )

        let signedPath = AWSSigV4.canonicalURI(for: "/a domain/with space.json")
        XCTAssertEqual(signedPath, "/a%20domain/with%20space.json")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://my-bucket.s3.eu-central-1.amazonaws.com\(signedPath)"
        )
    }

    func testTheContentHashHeaderIsTheHashOfTheBody() throws {
        let body = Data("some report".utf8)
        let request = try S3UploadClient.request(
            for: S3UploadClient.Object(key: "k.json", body: body, contentType: "application/json"),
            configuration: configuration(),
            credentials: credentials,
            now: now
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            AWSSigV4.sha256Hex(body)
        )
        XCTAssertEqual(request.httpBody, body)
    }

    /// `URLSession` sets Host from the URL, so the client must not also set it
    /// — a duplicate would be sent twice and break the signature.
    func testTheHostHeaderIsLeftToURLSession() throws {
        let request = try S3UploadClient.request(
            for: object(),
            configuration: configuration(),
            credentials: credentials,
            now: now
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Host"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
    }

    // MARK: Rejected configurations

    /// The one that matters: http would put the access key ID and the
    /// signature on the wire in the clear, and F3's NSAllowsArbitraryLoads
    /// means nothing else would stop it.
    func testAnHTTPEndpointIsRejected() {
        XCTAssertThrowsError(
            try S3UploadClient.request(
                for: object(),
                configuration: configuration(endpoint: "http://s3.example.com"),
                credentials: credentials,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .insecureEndpoint)
        }
    }

    func testAnEndpointWithNoHostIsRejected() {
        XCTAssertThrowsError(
            try S3UploadClient.request(
                for: object(),
                configuration: configuration(endpoint: "not a url"),
                credentials: credentials,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .invalidEndpoint)
        }
    }

    func testAMissingBucketIsRejected() {
        XCTAssertThrowsError(
            try S3UploadClient.request(
                for: object(),
                configuration: configuration(bucket: "   "),
                credentials: credentials,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .missingBucket)
        }
    }

    // MARK: Keys

    func testThePrefixIsJoinedWithoutDoubledSlashes() {
        let object = object(key: "/example.com/x.json")

        XCTAssertEqual(
            S3UploadClient.objectKey(for: object, configuration: configuration(keyPrefix: "domaindig/")),
            "domaindig/example.com/x.json"
        )
        XCTAssertEqual(
            S3UploadClient.objectKey(for: object, configuration: configuration(keyPrefix: "/reports/")),
            "reports/example.com/x.json"
        )
    }

    func testAnEmptyPrefixLeavesTheKeyAlone() {
        XCTAssertEqual(
            S3UploadClient.objectKey(for: object(key: "example.com/x.json"), configuration: configuration(keyPrefix: "  ")),
            "example.com/x.json"
        )
    }

    // MARK: Responses

    func testASuccessfulStatusPasses() {
        XCTAssertNoThrow(try S3UploadClient.validate(statusCode: 200, body: Data()))
        XCTAssertNoThrow(try S3UploadClient.validate(statusCode: 204, body: Data()))
    }

    func testAnErrorStatusCarriesTheServicesOwnErrorCode() {
        let body = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
            """.utf8)

        XCTAssertThrowsError(try S3UploadClient.validate(statusCode: 403, body: body)) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .rejected(statusCode: 403, message: "AccessDenied"))
        }
    }

    /// SigV4 refuses a request signed more than 15 minutes from server time,
    /// and the service's own message does not say the device's clock is the
    /// problem. This is the same device-clock failure D9 addresses in sync.
    func testASkewedClockIsReportedAsSuch() {
        let body = Data("<Error><Code>RequestTimeTooSkewed</Code></Error>".utf8)

        XCTAssertThrowsError(try S3UploadClient.validate(statusCode: 403, body: body)) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .clockSkew)
            XCTAssertTrue(
                error.localizedDescription.contains("clock"),
                "the message has to point at the clock, since the service's does not"
            )
        }
    }

    func testAnErrorWithNoParsableCodeStillReportsTheStatus() {
        XCTAssertThrowsError(try S3UploadClient.validate(statusCode: 500, body: Data("nope".utf8))) { error in
            XCTAssertEqual(error as? S3UploadClient.UploadError, .rejected(statusCode: 500, message: nil))
        }
    }

    func testErrorCodeParsing() {
        XCTAssertEqual(S3UploadClient.errorCode(in: Data("<Code>NoSuchBucket</Code>".utf8)), "NoSuchBucket")
        XCTAssertNil(S3UploadClient.errorCode(in: Data("<Code></Code>".utf8)))
        XCTAssertNil(S3UploadClient.errorCode(in: Data("<Other>x</Other>".utf8)))
        XCTAssertNil(S3UploadClient.errorCode(in: Data()))
    }

    // MARK: The configuration round-trips

    /// The target is persisted as JSON, so a new case in
    /// `IntegrationConfiguration` has to survive the trip.
    func testTheS3TargetRoundTripsThroughCoding() throws {
        let target = IntegrationTarget(
            type: .s3,
            name: "Backups",
            configuration: .s3(configuration(usesPathStyle: true))
        )

        let decoded = try JSONDecoder().decode(
            IntegrationTarget.self,
            from: try JSONEncoder().encode(target)
        )

        XCTAssertEqual(decoded, target)
        XCTAssertEqual(decoded.configuration.type, .s3)
        guard case .s3(let configuration) = decoded.configuration else {
            return XCTFail("expected an s3 configuration")
        }
        XCTAssertTrue(configuration.usesPathStyle)
        XCTAssertEqual(configuration.bucket, "my-bucket")
    }

    /// The secret is never part of the configuration — it lives in the
    /// Keychain and only the reference is stored.
    func testTheConfigurationCarriesNoSecret() throws {
        let encoded = try JSONEncoder().encode(configuration())
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains(credentials.secretAccessKey))
        XCTAssertTrue(json.contains(credentials.accessKeyID), "the key ID is not a secret and is shown in the editor")
    }
}

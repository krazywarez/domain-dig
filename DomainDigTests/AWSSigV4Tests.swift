import XCTest
@testable import DomainDig

/// AWS publishes four fully worked SigV4 examples for S3 — canonical request,
/// string to sign, signature and `Authorization` header, all exact — and says
/// they are there to check an implementation against. This pins every stage of
/// `AWSSigV4` to them.
///
/// It is worth pinning the intermediate stages and not only the signature: a
/// wrong canonical request and a wrong signing key both end as
/// `SignatureDoesNotMatch` from the server, and these tests say which.
///
/// Source: "Signature Calculations for the Authorization Header: Transferring
/// Payload in a Single Chunk (AWS Signature Version 4)", Amazon S3 developer
/// guide. Note the secret below ends `/bPxRfiCY…` — the S3 examples use a
/// slash where the generic SigV4 test suite uses a plus, and the signatures
/// differ accordingly.
final class AWSSigV4Tests: XCTestCase {

    private let credentials = AWSSigV4.Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )

    /// 20130524T000000Z — "Fri, 24 May 2013 00:00:00 GMT".
    private let scope = AWSSigV4.Scope(
        region: "us-east-1",
        service: "s3",
        date: Date(timeIntervalSince1970: 1_369_353_600)
    )

    private let host = "examplebucket.s3.amazonaws.com"

    // MARK: The timestamp the vectors are built on

    func testTheScopeFormatsTheExampleTimestamp() {
        XCTAssertEqual(scope.amzDate, "20130524T000000Z")
        XCTAssertEqual(scope.dateStamp, "20130524")
        XCTAssertEqual(scope.credentialScope, "20130524/us-east-1/s3/aws4_request")
    }

    // MARK: Example — GET Object

    private var getObjectRequest: AWSSigV4.Request {
        AWSSigV4.Request(
            method: "GET",
            path: "/test.txt",
            headers: [
                "Host": host,
                "Range": "bytes=0-9",
                "x-amz-content-sha256": AWSSigV4.emptyPayloadSHA256,
                "x-amz-date": "20130524T000000Z"
            ],
            payloadSHA256: AWSSigV4.emptyPayloadSHA256
        )
    }

    func testGetObjectCanonicalRequest() {
        XCTAssertEqual(
            AWSSigV4.canonicalRequest(for: getObjectRequest),
            """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;range;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        )
    }

    func testGetObjectStringToSign() {
        XCTAssertEqual(
            AWSSigV4.stringToSign(
                canonicalRequest: AWSSigV4.canonicalRequest(for: getObjectRequest),
                scope: scope
            ),
            """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
            """
        )
    }

    func testGetObjectAuthorizationHeader() {
        XCTAssertEqual(
            AWSSigV4.authorizationHeader(for: getObjectRequest, scope: scope, credentials: credentials),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    // MARK: Example — PUT Object

    /// The example that matters most here: an upload, with a signed payload and
    /// a `$` in the key that has to encode to `%24`.
    private var putObjectRequest: AWSSigV4.Request {
        AWSSigV4.Request(
            method: "PUT",
            path: "/test$file.text",
            headers: [
                "Date": "Fri, 24 May 2013 00:00:00 GMT",
                "Host": host,
                "x-amz-content-sha256": "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
                "x-amz-date": "20130524T000000Z",
                "x-amz-storage-class": "REDUCED_REDUNDANCY"
            ],
            payloadSHA256: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        )
    }

    /// The payload hash in the vector is the hash of this exact body, so it
    /// also pins `sha256Hex`.
    func testPutObjectPayloadHashMatchesTheExampleBody() {
        XCTAssertEqual(
            AWSSigV4.sha256Hex(Data("Welcome to Amazon S3.".utf8)),
            "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        )
    }

    func testPutObjectCanonicalRequest() {
        XCTAssertEqual(
            AWSSigV4.canonicalRequest(for: putObjectRequest),
            """
            PUT
            /test%24file.text

            date:Fri, 24 May 2013 00:00:00 GMT
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
            x-amz-date:20130524T000000Z
            x-amz-storage-class:REDUCED_REDUNDANCY

            date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
            44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
            """
        )
    }

    func testPutObjectStringToSign() {
        XCTAssertEqual(
            AWSSigV4.stringToSign(
                canonicalRequest: AWSSigV4.canonicalRequest(for: putObjectRequest),
                scope: scope
            ),
            """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d
            """
        )
    }

    func testPutObjectAuthorizationHeader() {
        XCTAssertEqual(
            AWSSigV4.authorizationHeader(for: putObjectRequest, scope: scope, credentials: credentials),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"
                + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        )
    }

    // MARK: Example — GET Bucket Lifecycle (a valueless query parameter)

    private var lifecycleRequest: AWSSigV4.Request {
        AWSSigV4.Request(
            method: "GET",
            path: "/",
            queryItems: [URLQueryItem(name: "lifecycle", value: nil)],
            headers: [
                "Host": host,
                "x-amz-content-sha256": AWSSigV4.emptyPayloadSHA256,
                "x-amz-date": "20130524T000000Z"
            ],
            payloadSHA256: AWSSigV4.emptyPayloadSHA256
        )
    }

    /// A subresource has no value, and canonicalises to `lifecycle=` rather
    /// than to a bare `lifecycle`.
    func testLifecycleCanonicalRequest() {
        XCTAssertEqual(
            AWSSigV4.canonicalRequest(for: lifecycleRequest),
            """
            GET
            /
            lifecycle=
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        )
    }

    func testLifecycleAuthorizationHeader() {
        XCTAssertEqual(
            AWSSigV4.authorizationHeader(for: lifecycleRequest, scope: scope, credentials: credentials),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date,"
                + "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
        )
    }

    // MARK: Example — List Objects (two query parameters)

    /// Declared out of order on purpose: the canonical form has to sort them.
    private var listObjectsRequest: AWSSigV4.Request {
        AWSSigV4.Request(
            method: "GET",
            path: "/",
            queryItems: [
                URLQueryItem(name: "prefix", value: "J"),
                URLQueryItem(name: "max-keys", value: "2")
            ],
            headers: [
                "Host": host,
                "x-amz-content-sha256": AWSSigV4.emptyPayloadSHA256,
                "x-amz-date": "20130524T000000Z"
            ],
            payloadSHA256: AWSSigV4.emptyPayloadSHA256
        )
    }

    func testListObjectsCanonicalRequest() {
        XCTAssertEqual(
            AWSSigV4.canonicalRequest(for: listObjectsRequest),
            """
            GET
            /
            max-keys=2&prefix=J
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        )
    }

    func testListObjectsAuthorizationHeader() {
        XCTAssertEqual(
            AWSSigV4.authorizationHeader(for: listObjectsRequest, scope: scope, credentials: credentials),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date,"
                + "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
        )
    }

    // MARK: The pieces the vectors do not reach

    func testTheEmptyPayloadConstantIsTheHashOfTheEmptyString() {
        XCTAssertEqual(AWSSigV4.sha256Hex(Data()), AWSSigV4.emptyPayloadSHA256)
    }

    /// SigV4's encoding is not `addingPercentEncoding`: everything outside the
    /// unreserved set goes, uppercase, and a space is `%20` not `+`.
    func testUriEncodeFollowsTheSigV4Rules() {
        XCTAssertEqual(AWSSigV4.uriEncode("AZaz09-._~", encodeSlash: true), "AZaz09-._~")
        XCTAssertEqual(AWSSigV4.uriEncode("a b", encodeSlash: true), "a%20b")
        XCTAssertEqual(AWSSigV4.uriEncode("a+b", encodeSlash: true), "a%2Bb")
        XCTAssertEqual(AWSSigV4.uriEncode("a=b&c", encodeSlash: true), "a%3Db%26c")
        XCTAssertEqual(AWSSigV4.uriEncode("$", encodeSlash: true), "%24")
    }

    func testUriEncodeKeepsKeySlashesButEncodesThemInQueryValues() {
        XCTAssertEqual(AWSSigV4.uriEncode("photos/Jan/sample.jpg", encodeSlash: false), "photos/Jan/sample.jpg")
        XCTAssertEqual(AWSSigV4.uriEncode("photos/Jan/sample.jpg", encodeSlash: true), "photos%2FJan%2Fsample.jpg")
    }

    /// Multi-byte characters encode per UTF-8 byte, not per character.
    func testUriEncodeEncodesEachUTF8Byte() {
        XCTAssertEqual(AWSSigV4.uriEncode("é", encodeSlash: true), "%C3%A9")
    }

    /// The path is deliberately not normalised: an object really can be called
    /// `a//b`, and collapsing the slashes would sign for a different key.
    func testCanonicalURIDoesNotNormalisePaths() {
        XCTAssertEqual(AWSSigV4.canonicalURI(for: "/my-object//example//photo.user"), "/my-object//example//photo.user")
        XCTAssertEqual(AWSSigV4.canonicalURI(for: "/a/../b"), "/a/../b")
    }

    func testCanonicalURIDefaultsToRootAndAddsTheLeadingSlash() {
        XCTAssertEqual(AWSSigV4.canonicalURI(for: ""), "/")
        XCTAssertEqual(AWSSigV4.canonicalURI(for: "key.json"), "/key.json")
    }

    func testAnEmptyQueryStringCanonicalisesToEmpty() {
        XCTAssertEqual(AWSSigV4.canonicalQueryString([]), "")
    }

    /// Repeated names sort by value once the names tie.
    func testRepeatedQueryNamesSortByValue() {
        XCTAssertEqual(
            AWSSigV4.canonicalQueryString([
                URLQueryItem(name: "a", value: "2"),
                URLQueryItem(name: "a", value: "1")
            ]),
            "a=1&a=2"
        )
    }

    /// Header names are matched case-insensitively by lowercasing, so a
    /// caller's capitalisation cannot change the signature.
    func testHeaderCaseDoesNotChangeTheSignature() {
        var shouting = getObjectRequest
        shouting.headers = [
            "HOST": host,
            "RANGE": "bytes=0-9",
            "X-Amz-Content-Sha256": AWSSigV4.emptyPayloadSHA256,
            "X-AMZ-DATE": "20130524T000000Z"
        ]

        XCTAssertEqual(
            AWSSigV4.authorizationHeader(for: shouting, scope: scope, credentials: credentials),
            AWSSigV4.authorizationHeader(for: getObjectRequest, scope: scope, credentials: credentials)
        )
    }

    /// Surrounding whitespace in a header value is trimmed before signing.
    func testHeaderValuesAreTrimmed() {
        XCTAssertEqual(
            AWSSigV4.canonicalHeaders(for: ["host": "  example.com  "]),
            "host:example.com\n"
        )
    }

    /// The signing key is derived per date, region and service, so the same
    /// secret signs differently in another region — the check that the chain is
    /// not collapsing to one HMAC.
    func testTheSigningKeyIsScopedToRegionAndService() {
        let other = AWSSigV4.Scope(region: "eu-west-1", service: "s3", date: scope.date)

        XCTAssertNotEqual(
            AWSSigV4.signature(stringToSign: "x", scope: scope, secretAccessKey: credentials.secretAccessKey),
            AWSSigV4.signature(stringToSign: "x", scope: other, secretAccessKey: credentials.secretAccessKey)
        )
    }
}

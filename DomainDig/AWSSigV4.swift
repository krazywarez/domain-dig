import CryptoKit
import Foundation

/// AWS Signature Version 4 request signing, for S3-compatible object storage.
///
/// Hand-rolled on CryptoKit, which the project already links, rather than
/// taking the AWS SDK for Swift and its dependency tree.
///
/// The stages below are the algorithm's own, exposed individually because each
/// one is pinned to AWS's published worked examples in `AWSSigV4Tests`. That is
/// worth doing here: the algorithm is fully specified and the vectors are
/// exact, so this is testable to certainty rather than to plausibility.
///
/// S3-specific, and the reason this is not a general signer: the URI path is
/// **not** normalised. A bucket may hold an object named `a//b`, and collapsing
/// the slashes would sign a request for a different object.
nonisolated struct AWSSigV4 {
    static let algorithm = "AWS4-HMAC-SHA256"

    /// `Hex(SHA256(""))`, the payload hash for a request with no body.
    static let emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Sent in place of a payload hash when the body is not to be hashed.
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    struct Credentials: Sendable, Equatable {
        let accessKeyID: String
        let secretAccessKey: String

        init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    /// One request to sign.
    struct Request: Sendable {
        /// `GET`, `PUT`, and so on.
        var method: String
        /// The path, unencoded and starting with `/`. Slashes within it are
        /// part of the object key and stay unencoded.
        var path: String
        var queryItems: [URLQueryItem]
        /// Header names in any case; signing lowercases them. `host` is
        /// required, and whichever `x-amz-*` headers the request will carry.
        var headers: [String: String]
        /// `Hex(SHA256(body))`, or `unsignedPayload`.
        var payloadSHA256: String

        init(
            method: String,
            path: String,
            queryItems: [URLQueryItem] = [],
            headers: [String: String],
            payloadSHA256: String
        ) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.headers = headers
            self.payloadSHA256 = payloadSHA256
        }
    }

    /// Where and when a signature is valid.
    struct Scope: Sendable, Equatable {
        var region: String
        var service: String
        var date: Date

        init(region: String, service: String = "s3", date: Date) {
            self.region = region
            self.service = service
            self.date = date
        }

        /// `20130524T000000Z`
        var amzDate: String { AWSSigV4.amzDateFormatter.string(from: date) }
        /// `20130524`
        var dateStamp: String { AWSSigV4.dateStampFormatter.string(from: date) }
        /// `20130524/us-east-1/s3/aws4_request`
        var credentialScope: String { "\(dateStamp)/\(region)/\(service)/aws4_request" }
    }

    // MARK: Signing

    /// The `Authorization` header value for `request`.
    static func authorizationHeader(
        for request: Request,
        scope: Scope,
        credentials: Credentials
    ) -> String {
        let canonical = canonicalRequest(for: request)
        let toSign = stringToSign(canonicalRequest: canonical, scope: scope)
        let signature = signature(stringToSign: toSign, scope: scope, secretAccessKey: credentials.secretAccessKey)
        // AWS's own S3 examples put no space after the commas; servers accept
        // either, and matching the documented form lets the tests pin the
        // whole header rather than only the signature.
        return "\(algorithm) "
            + "Credential=\(credentials.accessKeyID)/\(scope.credentialScope),"
            + "SignedHeaders=\(signedHeaders(for: request.headers)),"
            + "Signature=\(signature)"
    }

    static func signature(stringToSign: String, scope: Scope, secretAccessKey: String) -> String {
        let key = signingKey(secretAccessKey: secretAccessKey, scope: scope)
        return hex(hmac(Data(stringToSign.utf8), key: key))
    }

    /// `HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")`
    static func signingKey(secretAccessKey: String, scope: Scope) -> SymmetricKey {
        let initial = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        let dateKey = hmac(Data(scope.dateStamp.utf8), key: initial)
        let regionKey = hmac(Data(scope.region.utf8), key: SymmetricKey(data: dateKey))
        let serviceKey = hmac(Data(scope.service.utf8), key: SymmetricKey(data: regionKey))
        let signingKey = hmac(Data("aws4_request".utf8), key: SymmetricKey(data: serviceKey))
        return SymmetricKey(data: signingKey)
    }

    static func stringToSign(canonicalRequest: String, scope: Scope) -> String {
        [
            algorithm,
            scope.amzDate,
            scope.credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
    }

    // MARK: Canonicalisation

    static func canonicalRequest(for request: Request) -> String {
        [
            request.method.uppercased(),
            canonicalURI(for: request.path),
            canonicalQueryString(request.queryItems),
            canonicalHeaders(for: request.headers),
            signedHeaders(for: request.headers),
            request.payloadSHA256
        ].joined(separator: "\n")
    }

    /// The path, URI-encoded except for the slashes that separate key
    /// components. Not normalised: see the type's note.
    static func canonicalURI(for path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let prefixed = path.hasPrefix("/") ? path : "/" + path
        return uriEncode(prefixed, encodeSlash: false)
    }

    /// Parameters encoded individually, then sorted by name and value.
    static func canonicalQueryString(_ queryItems: [URLQueryItem]) -> String {
        var encoded: [(name: String, value: String)] = []
        for item in queryItems {
            encoded.append((
                name: uriEncode(item.name, encodeSlash: true),
                value: uriEncode(item.value ?? "", encodeSlash: true)
            ))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        return encoded.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// Each header as `name:value`, lowercased, sorted, and newline-terminated
    /// — including the last, which is what produces the blank line before the
    /// signed-header list.
    ///
    /// Values are trimmed at the ends only, which is what the S3
    /// specification calls for and what every published vector needs.
    static func canonicalHeaders(for headers: [String: String]) -> String {
        headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    static func signedHeaders(for headers: [String: String]) -> String {
        headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
    }

    /// Percent-encoding as SigV4 defines it, which is not what
    /// `addingPercentEncoding` produces: every byte outside the unreserved set
    /// is encoded, uppercase, and a space becomes `%20` rather than `+`.
    static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        var encoded = ""
        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/"):
                encoded += encodeSlash ? "%2F" : "/"
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    // MARK: Primitives

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

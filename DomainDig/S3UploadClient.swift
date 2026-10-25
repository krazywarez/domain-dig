import Foundation

/// Builds and sends a single signed `PUT` to an S3-compatible endpoint.
///
/// Request construction is separated from sending so it can be asserted
/// without a network: `request(for:…)` is pure, and the signature it carries is
/// the part that has to be exactly right.
nonisolated struct S3UploadClient {
    /// What to upload, and under what key.
    struct Object: Sendable, Equatable {
        /// The key within the bucket, without the configuration's prefix.
        var key: String
        var body: Data
        var contentType: String

        init(key: String, body: Data, contentType: String) {
            self.key = key
            self.body = body
            self.contentType = contentType
        }
    }

    enum UploadError: LocalizedError, Equatable {
        case invalidEndpoint
        case insecureEndpoint
        case missingBucket
        case rejected(statusCode: Int, message: String?)
        case clockSkew

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The bucket endpoint is not a valid URL."
            case .insecureEndpoint:
                return "The bucket endpoint must use https. Signing sends your access key ID in the clear over http, and the signature with it."
            case .missingBucket:
                return "The integration has no bucket name."
            case let .rejected(statusCode, message):
                if let message, !message.isEmpty {
                    return "The bucket rejected the upload (\(statusCode)): \(message)"
                }
                return "The bucket rejected the upload (\(statusCode))."
            case .clockSkew:
                // SigV4 refuses a request signed more than 15 minutes from the
                // server's clock, and the message it returns does not say that
                // the device is what is wrong.
                return "The bucket rejected the upload because this device's clock is more than 15 minutes from the server's. Check Settings → General → Date & Time."
            }
        }
    }

    /// The full object key, prefix included.
    static func objectKey(for object: Object, configuration: S3IntegrationConfiguration) -> String {
        let prefix = configuration.keyPrefix
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = object.key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? key : "\(prefix)/\(key)"
    }

    /// A signed `PUT` for `object`.
    ///
    /// The URL's path is set from the signer's own encoding rather than left to
    /// `URLComponents`, which percent-encodes to a different rule — if the two
    /// disagree the server computes a different canonical request and the
    /// upload fails as `SignatureDoesNotMatch`.
    static func request(
        for object: Object,
        configuration: S3IntegrationConfiguration,
        credentials: AWSSigV4.Credentials,
        now: Date
    ) throws -> URLRequest {
        let bucket = configuration.bucket.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty else { throw UploadError.missingBucket }

        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespaces)
        guard let endpointURL = URL(string: endpoint), let endpointHost = endpointURL.host else {
            throw UploadError.invalidEndpoint
        }
        guard endpointURL.scheme?.lowercased() == "https" else {
            throw UploadError.insecureEndpoint
        }

        let key = objectKey(for: object, configuration: configuration)
        let host = configuration.usesPathStyle ? endpointHost : "\(bucket).\(endpointHost)"
        let signedPath = configuration.usesPathStyle ? "/\(bucket)/\(key)" : "/\(key)"

        // The host header carries a non-default port, because the signature
        // covers the header and the server compares what it received.
        let hostHeader: String
        if let port = endpointURL.port, port != 443 {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = host
        }

        let scope = AWSSigV4.Scope(region: configuration.region, service: "s3", date: now)
        let payloadHash = AWSSigV4.sha256Hex(object.body)
        var headers = [
            "Host": hostHeader,
            "Content-Type": object.contentType,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": scope.amzDate
        ]

        let signed = AWSSigV4.Request(
            method: "PUT",
            path: signedPath,
            headers: headers,
            payloadSHA256: payloadHash
        )
        headers["Authorization"] = AWSSigV4.authorizationHeader(
            for: signed,
            scope: scope,
            credentials: credentials
        )

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = endpointURL.port
        components.percentEncodedPath = AWSSigV4.canonicalURI(for: signedPath)
        guard let url = components.url else { throw UploadError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = object.body
        // The host header is signed but set by URLSession from the URL, so it
        // is left out here; everything else goes on the request.
        for (name, value) in headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Classifies a response. S3-compatible services answer errors as XML, and
    /// the `Code` element is the part worth showing.
    static func validate(statusCode: Int, body: Data) throws {
        guard !(200...299).contains(statusCode) else { return }
        let code = errorCode(in: body)
        if code == "RequestTimeTooSkewed" {
            throw UploadError.clockSkew
        }
        throw UploadError.rejected(statusCode: statusCode, message: code)
    }

    /// The `<Code>` element of an S3 error document, if there is one.
    static func errorCode(in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8),
              let open = text.range(of: "<Code>"),
              let close = text.range(of: "</Code>"),
              open.upperBound <= close.lowerBound
        else {
            return nil
        }
        let code = text[open.upperBound..<close.lowerBound]
        return code.isEmpty ? nil : String(code)
    }
}

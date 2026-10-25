import Foundation

/// Validation for the inspected domain, applied at the two input boundaries:
/// `DomainViewModel.run()` and the bulk paste field.
///
/// Nothing downstream routes through this. `DomainViewModel.normalizedDomain` is
/// the key that matches already-stored rows, and the import and automation paths
/// accept whatever is already on disk, so tightening those would turn tracking,
/// workflow lookups and imports into silent no-ops for any stored domain these
/// rules reject.
///
/// The invariant runs one way: everything `validate` accepts can be built into a
/// request URL by `DomainHostURL`. The reverse does not hold — `-x.com` forms a
/// URL and is still rejected here.
enum DomainName {
    private static let maximumLabelBytes = 63
    private static let maximumHostBytes = 253

    /// The normalized host on success. A Unicode host is returned as typed; only
    /// the length limits are measured on its IDNA-encoded form.
    static func validate(_ raw: String) -> Result<String, DomainNameError> {
        let host = normalize(raw)
        guard !host.isEmpty else { return .failure(.empty) }

        // `%`-escapes are rejected rather than decoded: `DomainHostURL` reads
        // `https://ex%20ample.com` as host `ex ample.com`, so decoding here
        // would hand the sections a host with a space in it.
        if let invalid = host.first(where: { !isHostCharacter($0) }) {
            return .failure(.invalidCharacter(invalid))
        }

        let labels = host.components(separatedBy: ".")
        guard labels.count > 1 else { return .failure(.singleLabel) }

        if let malformed = labels.first(where: { $0.isEmpty || $0.first == "-" || $0.last == "-" }) {
            return .failure(.malformedLabel(malformed))
        }

        // The limits apply to the encoded host, which is what the section
        // services send, so they are measured on the punycode form.
        guard let encoded = DomainHostURL.https(host)?.host else {
            // `URL` refuses a host whose encoded label is over the limit
            // instead of reporting which label it was, so the two reasons are
            // told apart here: a label holding a character that will not encode
            // on its own is malformed, and anything else that will not encode is
            // too long.
            //
            // Probing per character rather than per prefix is what makes the
            // position irrelevant. The earlier version probed the label's first
            // few characters, so an unencodable character after them was
            // reported as merely too long.
            //
            // Not a complete IDNA characterisation: a label refused for a
            // combination its characters form, rather than for one of them,
            // still falls through to `.labelTooLong`. The input is rejected
            // either way and only the message differs.
            if let malformed = labels.first(where: { label in
                label.contains { !canEncode(String($0)) }
            }) {
                return .failure(.malformedLabel(malformed))
            }
            return .failure(.labelTooLong)
        }

        guard encoded.components(separatedBy: ".").allSatisfy({ $0.utf8.count <= maximumLabelBytes }) else {
            return .failure(.labelTooLong)
        }
        guard encoded.utf8.count <= maximumHostBytes else { return .failure(.tooLong) }

        return .success(host)
    }

    private static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let separator = host.range(of: "://"), isScheme(host[..<separator.lowerBound]) {
            host = String(host[separator.upperBound...])
        }

        // A query can follow the host with no path at all: `example.com?q=1`.
        host = String(host.prefix { $0 != "/" && $0 != "?" })

        if let userInfo = host.lastIndex(of: "@") {
            host = String(host[host.index(after: userInfo)...])
        }
        if let port = host.lastIndex(of: ":") {
            host = String(host[..<port])
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        // NFC so a decomposed "ü" measures the same as a precomposed one.
        return host.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func isScheme(_ candidate: Substring) -> Bool {
        guard let first = candidate.first, first.isASCII, first.isLetter else { return false }
        return candidate.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
    }

    /// Non-ASCII is left to IDNA; whatever it cannot encode fails the
    /// `DomainHostURL` guard in `validate`.
    private static func isHostCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return !character.isWhitespace }
        return character.isLetter || character.isNumber || character == "-" || character == "."
    }

    /// Whether `label` encodes at all, independent of length.
    ///
    /// An all-ASCII label always does, so only non-ASCII input reaches the
    /// probe. Callers pass a single character to ask whether that character is
    /// encodable anywhere in a label.
    private static func canEncode(_ label: String) -> Bool {
        guard label.contains(where: { !$0.isASCII }) else { return true }
        // The ASCII suffix keeps the probe a two-label host.
        return DomainHostURL.https("\(label).test") != nil
    }
}

enum DomainNameError: LocalizedError, Equatable {
    case empty
    case singleLabel
    case invalidCharacter(Character)
    case malformedLabel(String)
    case labelTooLong
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a domain to inspect."
        case .singleLabel:
            return "Enter a full domain, such as example.com."
        case .invalidCharacter(let character):
            if character.isWhitespace {
                return "A domain cannot contain spaces."
            }
            return "A domain cannot contain \(character)."
        case .malformedLabel(let label):
            if label.isEmpty {
                return "A domain cannot contain an empty part."
            }
            return "\(label) is not a valid part of a domain name."
        case .labelTooLong:
            return "Each part of a domain can be at most 63 bytes."
        case .tooLong:
            return "A domain can be at most 253 bytes."
        }
    }
}

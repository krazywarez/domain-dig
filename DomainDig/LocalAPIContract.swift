import Foundation

/// The versioned wire contract for the Local API.
///
/// External consumers — Shortcuts, scripts, and third-party integrations — depend
/// on the JSON this API produces: the response envelope, the field names of every
/// payload, and the encoding conventions. This type is the single source of truth
/// for the parts that must stay stable, and `LocalAPIContractTests` pins them so
/// an accidental rename or shape change fails CI instead of silently breaking a
/// consumer.
///
/// ## Compatibility policy
///
/// The `version` string reported in every envelope follows a semantic-version-style
/// promise:
///
/// - **Backward-compatible** changes keep `version` at `"v1"`: adding a new
///   endpoint, or adding a new field to a payload. Consumers must ignore unknown
///   fields, so additions never require a bump.
/// - **Breaking** changes require bumping `version` (and updating `Docs/local-api.md`
///   plus the contract tests): renaming or removing a field, changing a field's
///   type, or changing the meaning/units of an existing field.
///
/// See `Docs/local-api.md` for the full endpoint and schema reference.
enum LocalAPIContract {
    /// Wire-format version reported in every envelope's `version` field.
    static let version = "v1"

    /// The canonical encoder for every Local API response. ISO-8601 dates and
    /// sorted keys keep the output deterministic, which is what lets the contract
    /// tests pin the shape. Both the success and error paths route through this so
    /// the wire format can never drift between them.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

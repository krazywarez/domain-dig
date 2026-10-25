import Foundation

/// Two different questions, with two names.
///
/// Seven files used to declare a private `nilIfEmpty`, and one of them —
/// `DomainInsightEngine` — trimmed whitespace first while the rest did not, so
/// the same name meant two things and nothing could be shared (A14). Naming the
/// trimming one `nilIfBlank` separates them, which is what lets there be one
/// copy of each.
extension String {
    /// `nil` when there is nothing at all, keeping a string of spaces.
    ///
    /// For values already normalised upstream, where whitespace would be
    /// content rather than noise.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// `nil` when there is nothing but whitespace, and trimmed otherwise.
    ///
    /// For values straight from a text field or an imported row.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Array where Element == String {
    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}

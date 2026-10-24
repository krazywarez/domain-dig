import Foundation

enum DomainName {
    static func validate(_ raw: String) -> Result<String, DomainNameError> {
        .failure(.empty)
    }
}

enum DomainNameError: LocalizedError, Equatable {
    case empty
    case singleLabel
    case invalidCharacter(Character)
    case malformedLabel(String)
    case labelTooLong
    case tooLong
}

import Foundation

/// One inspection section's state as a single value.
///
/// Each section used to be three independent stored properties — a value, a
/// `*Loading` flag and a `*Error` string. There were 20 flags and 19 error
/// strings (A2), and nothing tied each trio together: a section could be left
/// loading forever because one of three assignments was missed, or report an
/// error while still claiming to load.
///
/// Deliberately **not** an exclusive `loaded | failed` enum, which is what A2
/// proposed. A section really can have both: the TLS card renders a stale
/// certificate next to a handshake error, and `AppStatusFactory.tls` takes
/// `sslInfo` and `error` together. An enum would have to drop one of them.
/// `SectionStateTests.testAnErrorAndAValueTogetherKeepBothReachable` pins that.
///
/// Whether a section is still moving. Declared outside `SectionState` so one
/// value can be applied across sections holding different value types.
enum SectionPhase {
    /// Not started, or cleared because a new lookup began.
    case idle
    /// In flight.
    case loading
    /// Finished, with a value, an error, or both.
    case settled
}

/// One inspection section's state as a single value: see `SectionPhase` above
/// for the phases. What this fixes is that the value, the phase and the error
/// travel together, so they are written as one or not at all.
struct SectionState<Value> {
    var phase: SectionPhase = .idle
    var value: Value?
    var error: String?

    var isLoading: Bool { phase == .loading }

    /// Finished moving, either way. `resultsLoaded` used to ask fifteen
    /// separate loading flags this question.
    var isSettled: Bool { phase == .settled }

    static var idle: Self { Self() }
    static var loading: Self { Self(phase: .loading) }

    /// Finished with whatever the lookup produced. Both arguments are optional
    /// because a snapshot carries them independently.
    static func settled(value: Value?, error: String? = nil) -> Self {
        Self(phase: .settled, value: value, error: error)
    }
}

extension SectionState where Value: ExpressibleByArrayLiteral {
    /// The value, or an empty collection — what the row builders want, rather
    /// than an optional they would immediately coalesce.
    var items: Value { value ?? [] }
}

#if DEBUG
import Foundation

/// Deterministic in-memory fixtures for the accessibility audit suite.
///
/// The dense rows (`WatchlistRowView`, `BatchResultRowView`) and the Dashboard
/// portfolio sections never render on a fresh simulator, so five phases of row
/// treatment shipped unverified by the automated audit. Driving the add-domain
/// UI instead was tried and rejected: typing raises the keyboard, which then
/// follows the audit onto later screens, and the added domains persist across
/// runs, contaminating every other test's baseline.
///
/// These are activated by the `DOMAIN_DIG_SEED_FIXTURES` launch argument
/// (DEBUG builds only, same pattern as `DOMAIN_DIG_FORCE_PRO_PLUS`) and are
/// **never persisted** — see `seedAuditFixturesIfRequested()`.
///
/// The set is chosen to exercise every row path: healthy/warning/critical
/// certificate badges, pinned, noted, changed, monitoring on/off, a
/// stress-length domain name, and every batch status including failure.
enum AuditFixtures {
    /// Clears the app's own store so an audit launch starts from a known
    /// state.
    ///
    /// The fixtures below are in-memory and never persist, but nothing stopped
    /// *other* state — whatever a previous run, a manual launch, or another
    /// test target left in the container — from reaching a screen the enforced
    /// suite audits as empty. That made the result depend on what ran before
    /// it: `testTrackedDomainsScreen` passes with one finding in isolation and
    /// reported an enforced `dynamicType` failure on `EditButton`, which only
    /// renders when the watchlist has rows, during a full `xcodebuild test`.
    ///
    /// Returns the store it cleared so a caller can thread it into whatever
    /// reads it first, which is what stops the reset being ordered after the
    /// read by accident.
    @discardableResult
    static func resetStoreIfRequested(_ defaults: UserDefaults = .standard) -> UserDefaults {
        guard ProcessInfo.processInfo.arguments.contains(resetStoreArgument) else {
            return defaults
        }
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        HistoryFileStore.removeAll(at: .default)
        return defaults
    }

    static let resetStoreArgument = "DOMAIN_DIG_RESET_STORE"

    static let launchArgument = "DOMAIN_DIG_SEED_FIXTURES"

    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Relative to launch so the recency-gated Dashboard sections (Recent
    /// Activity, Attention Required — both keyed to the last 24h) actually
    /// render. Label text varies run to run ("2 hr. ago"); the audit measures
    /// layout and traits, not string equality, so coverage wins.
    private static let now = Date()

    static var trackedDomains: [TrackedDomain] {
        [
            TrackedDomain(
                domain: "healthy.example",
                createdAt: now.addingTimeInterval(-86_400 * 30),
                updatedAt: now.addingTimeInterval(-3_600),
                isPinned: true,
                monitoringEnabled: true,
                lastKnownAvailability: .registered,
                certificateWarningLevel: .none,
                certificateDaysRemaining: 240,
                lastMonitoredAt: now.addingTimeInterval(-1_800)
            ),
            TrackedDomain(
                domain: "expiring.example",
                createdAt: now.addingTimeInterval(-86_400 * 90),
                updatedAt: now.addingTimeInterval(-7_200),
                monitoringEnabled: true,
                lastKnownAvailability: .registered,
                lastChangeSummary: DomainChangeSummary(
                    hasChanges: true,
                    changedSections: ["ssl"],
                    message: "Certificate is approaching expiry",
                    severity: .medium,
                    impactClassification: .warning,
                    generatedAt: now.addingTimeInterval(-7_200)
                ),
                lastChangeSeverity: .medium,
                certificateWarningLevel: .warning,
                certificateDaysRemaining: 12,
                lastMonitoredAt: now.addingTimeInterval(-7_200),
                lastAlertAt: now.addingTimeInterval(-7_000)
            ),
            TrackedDomain(
                domain: "broken.example",
                createdAt: now.addingTimeInterval(-86_400 * 7),
                updatedAt: now.addingTimeInterval(-600),
                note: "Production incident follow-up: certificate replaced?",
                monitoringEnabled: false,
                lastKnownAvailability: .registered,
                lastChangeSummary: DomainChangeSummary(
                    hasChanges: true,
                    changedSections: ["ssl", "dns"],
                    message: "TLS validation failed and NS records changed",
                    severity: .high,
                    impactClassification: .critical,
                    generatedAt: now.addingTimeInterval(-600)
                ),
                lastChangeSeverity: .high,
                certificateWarningLevel: .critical,
                certificateDaysRemaining: -3
            ),
            TrackedDomain(
                domain: "very-long-subdomain.observability.internal.staging.example",
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-60),
                monitoringEnabled: true,
                lastKnownAvailability: .unknown
            )
        ]
    }

    static var batchResults: [BatchLookupResult] {
        [
            BatchLookupResult(
                domain: "healthy.example",
                historyEntryID: nil,
                resultSource: .live,
                availability: .registered,
                primaryIP: "203.0.113.10",
                quickStatus: "Stable",
                summaryMessage: nil,
                changeSeverity: nil,
                changeClassification: nil,
                certificateWarningLevel: .none,
                riskScore: 12,
                riskLevel: .low,
                timestamp: now.addingTimeInterval(-120),
                status: .completed,
                errorMessage: nil
            ),
            BatchLookupResult(
                domain: "expiring.example",
                historyEntryID: nil,
                resultSource: .cached,
                availability: .registered,
                primaryIP: "203.0.113.11",
                quickStatus: "Changed",
                summaryMessage: "Certificate is approaching expiry",
                changeSeverity: .medium,
                changeClassification: .warning,
                certificateWarningLevel: .warning,
                riskScore: 41,
                riskLevel: .medium,
                timestamp: now.addingTimeInterval(-3_600),
                status: .completed,
                errorMessage: nil
            ),
            BatchLookupResult(
                domain: "broken.example",
                historyEntryID: nil,
                resultSource: .live,
                availability: .registered,
                primaryIP: "2001:db8::1f3:44",
                quickStatus: "Changed",
                summaryMessage: "TLS validation failed",
                changeSeverity: .high,
                changeClassification: .critical,
                certificateWarningLevel: .critical,
                riskScore: 78,
                riskLevel: .high,
                timestamp: now.addingTimeInterval(-60),
                status: .completed,
                errorMessage: nil
            ),
            BatchLookupResult(
                domain: "unreachable.example",
                historyEntryID: nil,
                resultSource: .live,
                availability: nil,
                primaryIP: nil,
                quickStatus: "Failed",
                summaryMessage: nil,
                changeSeverity: nil,
                changeClassification: nil,
                certificateWarningLevel: .none,
                riskScore: nil,
                riskLevel: nil,
                timestamp: now,
                status: .failed,
                errorMessage: "The lookup timed out before any records were returned"
            )
        ]
    }
}
#endif

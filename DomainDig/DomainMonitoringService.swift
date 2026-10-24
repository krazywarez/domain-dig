import Foundation
import UserNotifications
import CryptoKit

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

#if canImport(UIKit)
import UIKit
#endif

enum MonitoringStorage {
    static let settingsKey = "monitoring.settings"
    static let logsKey = "monitoring.logs"
    static let trackedDomainsKey = "trackedDomains"
    static let historyKey = "lookupHistory"
    static let maxLogs = 40

    static func loadSettings(defaults: UserDefaults = .standard) -> MonitoringSettings {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        return DomainDataPortabilityService.loadMonitoringSettings(defaults: defaults)
    }

    static func saveSettings(_ settings: MonitoringSettings, defaults: UserDefaults = .standard) {
        DomainDataPortabilityService.saveMonitoringSettings(settings, defaults: defaults)
    }

    static func loadLogs(defaults: UserDefaults = .standard) -> [MonitoringLog] {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        return DomainDataPortabilityService.loadMonitoringLogs(defaults: defaults)
    }

    static func saveLogs(_ logs: [MonitoringLog], defaults: UserDefaults = .standard) {
        DomainDataPortabilityService.saveMonitoringLogs(Array(logs.prefix(maxLogs)), defaults: defaults)
    }

    static func loadTrackedDomains(defaults: UserDefaults = .standard) -> [TrackedDomain] {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        return DomainDataPortabilityService.loadTrackedDomains(defaults: defaults)
    }

    static func saveTrackedDomains(_ domains: [TrackedDomain], defaults: UserDefaults = .standard) {
        DomainDataPortabilityService.saveTrackedDomains(domains, defaults: defaults)
    }

    static func loadHistoryEntries(defaults: UserDefaults = .standard) -> [HistoryEntry] {
        DataMigrationService.migrateIfNeeded(defaults: defaults)
        return DomainDataPortabilityService.loadHistoryEntries(defaults: defaults)
    }

    static func saveHistoryEntries(_ entries: [HistoryEntry]) {
        DomainDataPortabilityService.saveHistoryEntries(entries)
    }

    static func sanitizeSettings(_ settings: MonitoringSettings, trackedDomains: [TrackedDomain]) -> MonitoringSettings {
        let validIDs = Set(trackedDomains.map(\.id))
        var sanitized = settings
        sanitized.selectedDomainIDs = sanitized.selectedDomainIDs.filter { validIDs.contains($0) }
        return sanitized
    }

    static func monitoredDomains(settings: MonitoringSettings, trackedDomains: [TrackedDomain]) -> [TrackedDomain] {
        let sanitized = sanitizeSettings(settings, trackedDomains: trackedDomains)
        switch sanitized.scope {
        case .allTracked:
            return trackedDomains.filter(\.monitoringEnabled)
        case .selectedOnly:
            let selected = Set(sanitized.selectedDomainIDs)
            return trackedDomains.filter { selected.contains($0.id) && $0.monitoringEnabled }
        }
    }
}

struct MonitoringRunOutcome {
    let success: Bool
    let message: String
    let log: MonitoringLog?
}

@MainActor
final class DomainMonitoringScheduler {
    static let shared = DomainMonitoringScheduler()
    static let taskIdentifier = "net.cleberg.DomainDig.monitor.refresh"

    private var isRegistered = false

    private init() { /* Singleton; use the shared instance. */ }

    func registerBackgroundTask() {
        #if canImport(BackgroundTasks)
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: refreshTask)
        }
        #endif
    }

    func backgroundRefreshStatusDescription() -> String {
        #if canImport(UIKit)
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "Available"
        case .denied:
            return "Disabled in Settings"
        case .restricted:
            return "Restricted by the system"
        @unknown default:
            return "Unknown"
        }
        #else
        return "Unavailable on this platform"
        #endif
    }

    @discardableResult
    func syncSchedule() -> String? {
        #if canImport(BackgroundTasks)
        let settings = MonitoringStorage.loadSettings()
        guard settings.isEnabled, FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return nil
        }

        #if canImport(UIKit)
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return "Background refresh is unavailable."
        }
        #endif

        let trackedDomains = MonitoringStorage.loadTrackedDomains()
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: max(Self.nextScheduleInterval(settings: settings, trackedDomains: trackedDomains), 15 * 60)
        )

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return "Could not schedule monitoring."
        }
        #else
        return "Background monitoring is unavailable on this platform."
        #endif
    }

    static func nextScheduleInterval(
        settings: MonitoringSettings,
        trackedDomains: [TrackedDomain],
        now: Date = Date()
    ) -> TimeInterval {
        let monitored = MonitoringStorage.monitoredDomains(settings: settings, trackedDomains: trackedDomains)
        guard !monitored.isEmpty else {
            return settings.config.sanitizedBaseInterval
        }

        return monitored
            .map { trackedDomain in
                let state = normalizedMonitoringState(for: trackedDomain, settings: settings)
                guard let lastCheck = trackedDomain.monitoringState.lastCheck else {
                    return 0
                }
                return max(0, lastCheck.addingTimeInterval(state.currentInterval).timeIntervalSince(now))
            }
            .min() ?? settings.config.sanitizedBaseInterval
    }

    /// Whether a domain is due for a background check.
    static func isDue(
        trackedDomain: TrackedDomain,
        settings: MonitoringSettings,
        now: Date
    ) -> Bool {
        guard let lastCheck = trackedDomain.monitoringState.lastCheck else { return true }
        let state = normalizedMonitoringState(for: trackedDomain, settings: settings)
        return lastCheck.addingTimeInterval(state.currentInterval) <= now
    }

    /// How the interval and the stable-check counter move after one check, and
    /// whether this is a change not seen before.
    ///
    /// Separated from the alerting it used to sit inside, because a mistake
    /// here is silent in both directions: an interval that grows without bound
    /// stops monitoring, and one that never backs off hammers every domain on
    /// every wake. Note the middle case — an alert whose hash is unchanged
    /// moves neither the interval nor the counter.
    static func adapted(
        _ state: MonitoringState,
        changeHash: String?,
        settings: MonitoringSettings,
        now: Date
    ) -> (state: MonitoringState, isNewChange: Bool) {
        var state = state
        let baseInterval = settings.config.sanitizedBaseInterval

        guard let changeHash else {
            state.consecutiveStableChecks += 1
            state.currentInterval = settings.adaptiveEnabled
                ? max(baseInterval, min(settings.config.maxInterval, state.currentInterval * settings.sensitivity.intervalMultiplier))
                : baseInterval
            return (state, false)
        }

        guard state.lastChangeHash != changeHash else { return (state, false) }

        state.lastChangeHash = changeHash
        state.lastChangeDate = now
        state.consecutiveStableChecks = 0
        state.currentInterval = settings.adaptiveEnabled ? settings.sensitivity.minimumInterval : baseInterval
        return (state, true)
    }

    static func normalizedMonitoringState(
        for trackedDomain: TrackedDomain,
        settings: MonitoringSettings
    ) -> MonitoringState {
        var state = trackedDomain.monitoringState
        if state.currentInterval <= 0 {
            state.currentInterval = settings.config.sanitizedBaseInterval
        }
        return state
    }

#if canImport(BackgroundTasks)
    private func handleAppRefresh(task: BGAppRefreshTask) {
        _ = syncSchedule()

        task.run {
            await DomainMonitoringService.shared.performMonitoring(
                trigger: .background,
                requireEnabledSetting: true
            ).success
        }
    }
#endif
}

@MainActor
final class DomainMonitoringService {
    static let shared = DomainMonitoringService()

    private let inspectionService = DomainInspectionService()
    private let maxHistoryEntries = 250
    private let calendar = Calendar.current

    func performMonitoring(
        trigger: MonitoringRunTrigger,
        requireEnabledSetting: Bool
    ) async -> MonitoringRunOutcome {
        let trackedDomains = MonitoringStorage.loadTrackedDomains()
        var settings = MonitoringStorage.sanitizeSettings(MonitoringStorage.loadSettings(), trackedDomains: trackedDomains)
        MonitoringStorage.saveSettings(settings)

        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            if settings.isEnabled {
                settings.isEnabled = false
                MonitoringStorage.saveSettings(settings)
                await MainActor.run {
                    _ = DomainMonitoringScheduler.shared.syncSchedule()
                }
            }
            return MonitoringRunOutcome(success: false, message: "Monitoring requires Pro.", log: nil)
        }

        if requireEnabledSetting, !settings.isEnabled {
            return MonitoringRunOutcome(success: false, message: "Monitoring is disabled.", log: nil)
        }

        var history = MonitoringStorage.loadHistoryEntries()
        var mutableTrackedDomains = trackedDomains
        let monitoredDomains = MonitoringStorage.monitoredDomains(settings: settings, trackedDomains: mutableTrackedDomains)

        guard !monitoredDomains.isEmpty else {
            let log = MonitoringLog(
                timestamp: Date(),
                trigger: trigger,
                domainsChecked: 0,
                changesFound: 0,
                alertsTriggered: 0,
                checkedDomains: [],
                errors: ["No tracked domains are configured for monitoring."]
            )
            saveLog(log)
            return MonitoringRunOutcome(success: false, message: "No domains selected for monitoring.", log: log)
        }

        let eligibleDomains = monitoredDomains.filter { trackedDomain in
            shouldInspect(trackedDomain: trackedDomain, trigger: trigger, settings: settings)
        }

        guard !eligibleDomains.isEmpty else {
            let log = MonitoringLog(
                timestamp: Date(),
                trigger: trigger,
                domainsChecked: 0,
                changesFound: 0,
                alertsTriggered: 0,
                checkedDomains: [],
                errors: []
            )
            saveLog(log)
            return MonitoringRunOutcome(success: true, message: "No domains are due for monitoring.", log: log)
        }

        let notificationsAuthorized: Bool
        if settings.alertsEnabled {
            notificationsAuthorized = await LocalNotificationService.shared.isAuthorizedForAlerts()
        } else {
            notificationsAuthorized = false
        }
        var results: [MonitoringDomainResult] = []
        var errors: [String] = []
        var alertsTriggered = 0
        let now = Date()

        for trackedDomain in eligibleDomains {
            guard !Task.isCancelled else {
                return MonitoringRunOutcome(success: false, message: "Monitoring cancelled.", log: nil)
            }

            let previousSnapshot = latestSnapshot(for: trackedDomain, history: history)
            let inspectedSnapshot = await inspectionService.inspectSnapshot(
                domain: trackedDomain.domain,
                previousSnapshot: previousSnapshot
            )
            let snapshot = inspectedSnapshot.resolvedAfterFallback(to: previousSnapshot)
            // When the fallback fires, `snapshot` *is* `previousSnapshot`, so
            // every comparison below is old-against-old and would otherwise
            // report "No meaningful changes" for a domain we never reached.
            let unreachableReason = (previousSnapshot != nil && inspectedSnapshot.needsFallback)
                ? Self.firstErrorMessage(in: inspectedSnapshot)
                : nil
            let savedEntry: HistoryEntry?
            if snapshot.statusMessage == nil {
                savedEntry = persistSnapshot(
                    snapshot,
                    trackedDomainID: trackedDomain.id,
                    trackedDomains: &mutableTrackedDomains,
                    history: &history
                )
            } else {
                savedEntry = history.first(where: { $0.id == snapshot.historyEntryID })
            }

            let alertDescriptor = alertDescriptor(
                previousSnapshot: previousSnapshot,
                snapshot: snapshot,
                entry: savedEntry,
                sensitivity: settings.sensitivity
            )

            if let index = mutableTrackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) {
                mutableTrackedDomains[index].lastMonitoredAt = now
                let outcome = await processAdaptiveMonitoringState(
                    trackedDomain: mutableTrackedDomains[index],
                    snapshot: snapshot,
                    previousSnapshot: previousSnapshot,
                    alertDescriptor: alertDescriptor,
                    settings: settings,
                    notificationsAuthorized: notificationsAuthorized,
                    now: now
                )
                mutableTrackedDomains[index] = outcome.trackedDomain
                alertsTriggered += outcome.alertsTriggered
            }

            let result = MonitoringDomainResult(
                domain: trackedDomain.domain,
                historyEntryID: savedEntry?.id ?? snapshot.historyEntryID,
                checkedAt: now,
                didChange: alertDescriptor != nil,
                summaryMessage: unreachableReason.map { "Could not check — kept the previous result. \($0)" }
                    ?? snapshot.statusMessage
                    ?? alertDescriptor?.message
                    ?? savedEntry?.changeSummary?.message
                    ?? "No meaningful changes",
                alertSeverity: alertDescriptor?.severity,
                certificateWarningLevel: DomainDiffService.certificateWarningLevel(for: snapshot),
                resultSource: snapshot.resultSource,
                errorMessage: snapshot.statusMessage,
                unreachableReason: unreachableReason
            )
            results.append(result)

            if let errorMessage = result.errorMessage {
                errors.append("\(trackedDomain.domain): \(errorMessage)")
            }
        }

        MonitoringStorage.saveTrackedDomains(mutableTrackedDomains)
        MonitoringStorage.saveHistoryEntries(history)

        let log = MonitoringLog(
            timestamp: Date(),
            trigger: trigger,
            domainsChecked: results.count,
            changesFound: results.filter(\.didChange).count,
            alertsTriggered: alertsTriggered,
            checkedDomains: results.sorted {
                $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
            },
            errors: errors
        )
        saveLog(log)
        let outboundEvents = monitoringEvents(from: log)
        if outboundEvents.isEmpty {
            IntegrationService.shared.recordNoOutboundEvents(for: log.summary)
        } else {
            IntegrationService.shared.enqueue(events: outboundEvents)
        }

        return MonitoringRunOutcome(
            success: errors.count < results.count,
            message: log.summary,
            log: log
        )
    }

    private func saveLog(_ log: MonitoringLog) {
        var logs = MonitoringStorage.loadLogs()
        logs.insert(log, at: 0)
        MonitoringStorage.saveLogs(logs)
    }

    private func monitoringEvents(from log: MonitoringLog) -> [MonitoringEvent] {
        var events: [MonitoringEvent] = log.checkedDomains.compactMap { result in
            if let errorMessage = result.errorMessage {
                return MonitoringEvent(
                    type: .monitoringFailure,
                    severity: .critical,
                    domain: result.domain,
                    timestamp: result.checkedAt,
                    summary: errorMessage,
                    details: [
                        "trigger": log.trigger.rawValue,
                        "resultSource": result.resultSource.rawValue
                    ]
                )
            }

            if let unreachableReason = result.unreachableReason {
                return MonitoringEvent(
                    type: .monitoringFailure,
                    severity: .warning,
                    domain: result.domain,
                    timestamp: result.checkedAt,
                    summary: result.summaryMessage,
                    details: [
                        "reason": unreachableReason,
                        "trigger": log.trigger.rawValue,
                        "resultSource": result.resultSource.rawValue
                    ]
                )
            }

            if result.certificateWarningLevel == .critical {
                return MonitoringEvent(
                    type: .certificateExpiring,
                    severity: .critical,
                    domain: result.domain,
                    timestamp: result.checkedAt,
                    summary: result.summaryMessage,
                    details: [
                        "certificateWarningLevel": result.certificateWarningLevel.rawValue,
                        "trigger": log.trigger.rawValue
                    ]
                )
            }

            guard let alertSeverity = result.alertSeverity else {
                return nil
            }

            return MonitoringEvent(
                type: eventType(for: result.summaryMessage),
                severity: EventSeverity(monitoringSeverity: alertSeverity),
                domain: result.domain,
                timestamp: result.checkedAt,
                summary: result.summaryMessage,
                details: [
                    "alertSeverity": alertSeverity.title,
                    "certificateWarningLevel": result.certificateWarningLevel.rawValue,
                    "resultSource": result.resultSource.rawValue,
                    "trigger": log.trigger.rawValue
                ]
            )
        }

        if !log.errors.isEmpty {
            events.append(
                MonitoringEvent(
                    type: .monitoringFailure,
                    severity: .critical,
                    domain: "portfolio",
                    timestamp: log.timestamp,
                    summary: "Monitoring run completed with errors",
                    details: [
                        "errors": log.errors.joined(separator: " | "),
                        "trigger": log.trigger.rawValue
                    ]
                )
            )
        }

        return events
    }

    private func eventType(for summary: String) -> MonitoringEventType {
        let normalized = summary.lowercased()
        if normalized.contains("dns") {
            return .dnsChanged
        }
        if normalized.contains("certificate") {
            return .certificateUpdated
        }
        if normalized.contains("redirect") {
            return .redirectChanged
        }
        if normalized.contains("header") {
            return .headersChanged
        }
        return .changeDetected
    }

    private func latestSnapshot(for trackedDomain: TrackedDomain, history: [HistoryEntry]) -> LookupSnapshot? {
        history.first(where: { entry in
            if let trackedDomainID = entry.trackedDomainID {
                return trackedDomainID == trackedDomain.id
            }
            return entry.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame
        })?.snapshot
    }

    private func persistSnapshot(
        _ snapshot: LookupSnapshot,
        trackedDomainID: UUID,
        trackedDomains: inout [TrackedDomain],
        history: inout [HistoryEntry]
    ) -> HistoryEntry? {
        let previousSnapshot = latestSnapshot(
            for: trackedDomains.first(where: { $0.id == trackedDomainID }) ?? TrackedDomain(domain: snapshot.domain),
            history: history
        )
        let analysis = DomainInsightEngine.analyze(snapshot: snapshot, previousSnapshot: previousSnapshot)
        let changeSummary = previousSnapshot.map {
            DomainDiffService.summary(
                from: $0,
                to: snapshot,
                generatedAt: snapshot.timestamp,
                riskAssessment: analysis.riskAssessment,
                insights: analysis.insights
            )
        }

        let entry = HistoryEntry(
            identity: HistoryEntry.Identity(
                domain: snapshot.domain,
                timestamp: snapshot.timestamp,
                trackedDomainID: trackedDomainID,
                note: trackedDomains.first(where: { $0.id == trackedDomainID })?.note
            ),
            inspection: .init(snapshot: snapshot),
            registration: HistoryEntry.Registration(
                ownership: snapshot.ownership,
                ownershipHistory: snapshot.ownershipHistory,
                domainPricing: snapshot.domainPricing
            ),
            intelligence: HistoryEntry.Intelligence(
                reputation: snapshot.reputation
            ),
            provenance: .init(snapshot: snapshot),
            summary: HistoryEntry.Summary(
                primaryIP: Self.primaryIPAddress(from: snapshot),
                finalRedirectURL: snapshot.redirectChain.last?.url,
                tlsStatusSummary: Self.tlsSummary(from: snapshot),
                emailSecuritySummary: Self.emailSummary(from: snapshot),
                httpGradeSummary: snapshot.httpSecurityGrade ?? snapshot.httpHeadersError,
                changeSummary: changeSummary
            ),
            failures: .init(snapshot: snapshot)
        )

        history.insert(entry, at: 0)
        if history.count > maxHistoryEntries {
            history = Array(history.prefix(maxHistoryEntries))
        }

        if let index = trackedDomains.firstIndex(where: { $0.id == trackedDomainID }) {
            trackedDomains[index].lastSnapshotID = entry.id
            trackedDomains[index].lastKnownAvailability = snapshot.availabilityResult?.status
            trackedDomains[index].updatedAt = snapshot.timestamp
            trackedDomains[index].lastChangeSummary = changeSummary
            trackedDomains[index].lastChangeSeverity = changeSummary?.severity
            trackedDomains[index].certificateWarningLevel = DomainDiffService.certificateWarningLevel(for: snapshot)
            trackedDomains[index].certificateDaysRemaining = snapshot.sslInfo?.daysUntilExpiry
        }

        return entry
    }

    private func shouldInspect(
        trackedDomain: TrackedDomain,
        trigger: MonitoringRunTrigger,
        settings: MonitoringSettings
    ) -> Bool {
        guard trigger == .background else { return true }
        return DomainMonitoringScheduler.isDue(trackedDomain: trackedDomain, settings: settings, now: Date())
    }

    private func processAdaptiveMonitoringState(
        trackedDomain: TrackedDomain,
        snapshot _: LookupSnapshot,
        previousSnapshot _: LookupSnapshot?,
        alertDescriptor: MonitoringAlertDescriptor?,
        settings: MonitoringSettings,
        notificationsAuthorized: Bool,
        now: Date
    ) async -> (trackedDomain: TrackedDomain, alertsTriggered: Int) {
        var updated = trackedDomain
        let isQuiet = settings.quietHours?.contains(now, calendar: calendar) == true
        var alertsTriggered = 0

        let (adaptedState, isNewChange) = DomainMonitoringScheduler.adapted(
            DomainMonitoringScheduler.normalizedMonitoringState(for: trackedDomain, settings: settings),
            changeHash: alertDescriptor?.changeHash,
            settings: settings,
            now: now
        )
        var state = adaptedState

        if isNewChange,
           let alertDescriptor,
           settings.alertsEnabled,
           alertDescriptor.severity >= settings.alertFilter.minimumSeverity {
            alertsTriggered += await raiseAlert(
                alertDescriptor,
                for: &updated,
                state: &state,
                deferred: isQuiet || !notificationsAuthorized,
                now: now
            )
        }

        if !isQuiet,
           settings.alertsEnabled,
           notificationsAuthorized,
           !updated.pendingMonitoringAlerts.isEmpty,
           alertDescriptor == nil {
            await LocalNotificationService.shared.notifyMonitoringSummary(
                domain: trackedDomain.domain,
                alerts: updated.pendingMonitoringAlerts
            )
            alertsTriggered += 1
            updated.pendingMonitoringAlerts = []
            updated.lastAlertAt = now
            state.lastAlertDate = now
        }

        state.lastCheck = now
        updated.monitoringState = state
        return (updated, alertsTriggered)
    }

    /// Queues the alert while notifications are deferred; otherwise notifies, folding in
    /// any queued alerts, and returns the number of notifications sent.
    private func raiseAlert(
        _ alertDescriptor: MonitoringAlertDescriptor,
        for updated: inout TrackedDomain,
        state: inout MonitoringState,
        deferred: Bool,
        now: Date
    ) async -> Int {
        let pendingAlert = MonitoringPendingAlert(
            detectedAt: now,
            message: alertDescriptor.message,
            severity: alertDescriptor.severity,
            changeHash: alertDescriptor.changeHash
        )
        let pendingAlerts = deduplicatedPendingAlerts(updated.pendingMonitoringAlerts + [pendingAlert])
        if deferred {
            updated.pendingMonitoringAlerts = pendingAlerts
            return 0
        }

        if pendingAlerts.count > 1 {
            await LocalNotificationService.shared.notifyMonitoringSummary(
                domain: updated.domain,
                alerts: pendingAlerts
            )
        } else {
            await LocalNotificationService.shared.notifyMonitoringAlert(
                domain: updated.domain,
                message: alertDescriptor.message,
                severity: alertDescriptor.severity
            )
        }
        updated.pendingMonitoringAlerts = []
        updated.lastAlertAt = now
        state.lastAlertDate = now
        return 1
    }

    private func deduplicatedPendingAlerts(_ alerts: [MonitoringPendingAlert]) -> [MonitoringPendingAlert] {
        var uniqueByHash: [String: MonitoringPendingAlert] = [:]
        for alert in alerts {
            if let existing = uniqueByHash[alert.changeHash] {
                uniqueByHash[alert.changeHash] = existing.detectedAt >= alert.detectedAt ? existing : alert
            } else {
                uniqueByHash[alert.changeHash] = alert
            }
        }
        return uniqueByHash.values.sorted { $0.detectedAt < $1.detectedAt }
    }

    private struct MonitoringAlertDescriptor {
        let severity: MonitoringAlertSeverity
        let message: String
        let changeHash: String
    }

    private struct HeaderFingerprint: Encodable, Equatable {
        let name: String
        let value: String
    }

    private func alertDescriptor(
        previousSnapshot: LookupSnapshot?,
        snapshot: LookupSnapshot,
        entry: HistoryEntry?,
        sensitivity: MonitoringSensitivity
    ) -> MonitoringAlertDescriptor? {
        guard let previousSnapshot else { return nil }
        let previousHash = monitoringHash(for: previousSnapshot, sensitivity: sensitivity)
        let currentHash = monitoringHash(for: snapshot, sensitivity: sensitivity)
        guard previousHash != currentHash else { return nil }

        let changedLabels = Set(
            DomainDiffService.diff(from: previousSnapshot, to: snapshot)
                .flatMap(\.items)
                .filter(\.hasChanges)
                .map(\.label)
        )

        if changedLabels.contains("Nameservers") || changedLabels.contains(where: { $0.hasSuffix("Records") }) {
            return MonitoringAlertDescriptor(severity: .warning, message: "DNS records changed", changeHash: currentHash)
        }

        let oldCertificateLevel = DomainDiffService.certificateWarningLevel(for: previousSnapshot)
        let newCertificateLevel = DomainDiffService.certificateWarningLevel(for: snapshot)
        if snapshot.sslInfo?.issuer != previousSnapshot.sslInfo?.issuer
            || snapshot.sslInfo?.validUntil != previousSnapshot.sslInfo?.validUntil
            || (newCertificateLevel != .none && newCertificateLevel != oldCertificateLevel) {
            return MonitoringAlertDescriptor(severity: .warning, message: "Certificate updated", changeHash: currentHash)
        }

        if sensitivity != .low,
           previousSnapshot.redirectChain.map(\.url) != snapshot.redirectChain.map(\.url)
            || previousSnapshot.redirectChain.map(\.statusCode) != snapshot.redirectChain.map(\.statusCode) {
            return MonitoringAlertDescriptor(severity: .warning, message: "Redirect chain changed", changeHash: currentHash)
        }

        if sensitivity != .low,
           filteredHTTPHeaders(previousSnapshot.httpHeaders, sensitivity: sensitivity)
            != filteredHTTPHeaders(snapshot.httpHeaders, sensitivity: sensitivity) {
            return MonitoringAlertDescriptor(severity: .info, message: "HTTP headers changed", changeHash: currentHash)
        }

        if sensitivity == .high,
           entry?.changeSummary?.hasChanges == true,
           let message = entry?.changeSummary?.message {
            return MonitoringAlertDescriptor(severity: .info, message: message, changeHash: currentHash)
        }

        return nil
    }

    private func monitoringHash(for snapshot: LookupSnapshot, sensitivity: MonitoringSensitivity) -> String {
        struct DNSRecordPayload: Encodable {
            let type: String
            let records: [String]
            let wildcardRecords: [String]
        }

        struct CertificatePayload: Encodable {
            let issuer: String?
            let commonName: String?
            let validUntil: Date?
        }

        struct RedirectPayload: Encodable {
            let url: String
            let statusCode: Int
        }

        struct HeaderPayload: Encodable {
            let name: String
            let value: String
        }

        struct MonitoringHashPayload: Encodable {
            let dns: [DNSRecordPayload]
            let certificate: CertificatePayload
            let headers: [HeaderPayload]
            let redirects: [RedirectPayload]
        }

        let payload = MonitoringHashPayload(
            dns: snapshot.dnsSections
                .sorted { $0.recordType.rawValue < $1.recordType.rawValue }
                .map { section in
                    DNSRecordPayload(
                        type: section.recordType.rawValue,
                        records: section.records
                            .sorted { lhs, rhs in
                                lhs.value == rhs.value ? lhs.ttl < rhs.ttl : lhs.value < rhs.value
                            }
                            .map { "\($0.value)|\($0.ttl)" },
                        wildcardRecords: section.wildcardRecords
                            .sorted { lhs, rhs in
                                lhs.value == rhs.value ? lhs.ttl < rhs.ttl : lhs.value < rhs.value
                            }
                            .map { "\($0.value)|\($0.ttl)" }
                    )
                },
            certificate: CertificatePayload(
                issuer: snapshot.sslInfo?.issuer,
                commonName: snapshot.sslInfo?.commonName,
                validUntil: snapshot.sslInfo?.validUntil
            ),
            headers: filteredHTTPHeaders(snapshot.httpHeaders, sensitivity: sensitivity).map {
                HeaderPayload(name: $0.name, value: $0.value)
            },
            redirects: sensitivity == .low ? [] : snapshot.redirectChain.map {
                RedirectPayload(url: $0.url, statusCode: $0.statusCode)
            }
        )

        let encoder = JSONEncoder()
        if #available(iOS 11.0, macOS 10.13, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func filteredHTTPHeaders(
        _ headers: [HTTPHeader],
        sensitivity: MonitoringSensitivity
    ) -> [HeaderFingerprint] {
        let mediumHeaderNames: Set<String> = [
            "cache-control",
            "content-security-policy",
            "location",
            "permissions-policy",
            "referrer-policy",
            "server",
            "strict-transport-security",
            "x-content-type-options",
            "x-frame-options"
        ]

        return headers
            .filter { header in
                switch sensitivity {
                case .low:
                    return false
                case .medium:
                    return mediumHeaderNames.contains(header.name.lowercased())
                case .high:
                    return true
                }
            }
            .map { HeaderFingerprint(name: $0.name.lowercased(), value: $0.value) }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
            }
    }

    /// First reported error on a snapshot, used to explain a fallback. Mirrors
    /// the ordering `LookupSnapshot.needsFallback` inspects.
    private static func firstErrorMessage(in snapshot: LookupSnapshot) -> String {
        [
            snapshot.dnsError,
            snapshot.httpHeadersError,
            snapshot.sslError,
            snapshot.ownershipError,
            snapshot.subdomainsError,
            snapshot.redirectChainError,
            snapshot.ipGeolocationError
        ]
        .compactMap { $0 }
        .first ?? "The lookup could not reach the domain."
    }

    private static func primaryIPAddress(from snapshot: LookupSnapshot) -> String? {
        snapshot.dnsSections.first(where: { $0.recordType == .A })?.records.first?.value
    }

    private static func tlsSummary(from snapshot: LookupSnapshot) -> String? {
        guard let sslInfo = snapshot.sslInfo else { return snapshot.sslError }
        switch DomainDiffService.certificateWarningLevel(for: snapshot) {
        case .critical:
            return "Critical (\(sslInfo.daysUntilExpiry)d)"
        case .warning:
            return "Warning (\(sslInfo.daysUntilExpiry)d)"
        case .none:
            return "Healthy (\(sslInfo.daysUntilExpiry)d)"
        }
    }

    private static func emailSummary(from snapshot: LookupSnapshot) -> String? {
        if let emailSecurity = snapshot.emailSecurity {
            return [
                "spf:\(emailSecurity.spf.found)",
                "dmarc:\(emailSecurity.dmarc.found)",
                "dkim:\(emailSecurity.dkim.found)",
                "bimi:\(emailSecurity.bimi.found)",
                "mta-sts:\(emailSecurity.mtaSts?.txtFound == true)"
            ].joined(separator: "|")
        }
        return snapshot.emailSecurityError
    }
}

#if canImport(BackgroundTasks)
extension BGAppRefreshTask {
    /// Runs `work` for this refresh, completing the task with whether it succeeded, and cancels it
    /// when the system ends the task early.
    @MainActor
    func run(_ work: @escaping @MainActor () async -> Bool) {
        let worker = Task {
            setTaskCompleted(success: await work())
        }
        expirationHandler = {
            worker.cancel()
        }
    }
}
#endif

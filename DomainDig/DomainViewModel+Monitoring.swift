import Foundation
import SwiftUI
import UserNotifications

/// Monitoring configuration surface of `DomainViewModel`: notification
/// authorization, the monitoring settings mutators (scope, interval, adaptivity,
/// sensitivity, quiet hours, alert filter/toggle, per-domain selection), the
/// manual run, and the per-domain status labels.
///
/// Settings mutations persist through `persistMonitoringSettings(...)` and
/// `sanitizeMonitoringSelection()`, which remain on the main type because the
/// tracked-domain lifecycle (add/delete/clear) calls them too.
extension DomainViewModel {
    func refreshMonitoringAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        monitoringNotificationStatus = settings.authorizationStatus
    }

    func setMonitoringEnabled(_ isEnabled: Bool) {
        guard !isEnabled || FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            monitoringSettings.isEnabled = false
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }

        monitoringSettings.isEnabled = isEnabled
        persistMonitoringSettings(localActivationConfirmed: isEnabled)
        monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
    }

    func setMonitoringScope(_ scope: MonitoringScope) {
        monitoringSettings.scope = scope
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
    }

    func setMonitoringBaseInterval(_ baseInterval: MonitoringBaseInterval) {
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        monitoringSettings.baseInterval = baseInterval.interval
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
        monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
    }

    func setMonitoringAdaptiveEnabled(_ isEnabled: Bool) {
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        monitoringSettings.adaptiveEnabled = isEnabled
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
        monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
    }

    func setMonitoringSensitivity(_ sensitivity: MonitoringSensitivity) {
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        monitoringSettings.sensitivity = sensitivity
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
        monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
    }

    func setMonitoringQuietHours(startHour: Int, endHour: Int, isEnabled: Bool) {
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        monitoringSettings.quietHours = isEnabled ? QuietHours(startHour: startHour, endHour: endHour) : nil
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
    }

    func setMonitoringAlertFilter(_ filter: MonitoringAlertFilter) {
        guard FeatureAccessService.hasAccess(to: .localAlerts) else {
            monitoringSettings.alertsEnabled = false
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .localAlerts)
            return
        }
        monitoringSettings.alertFilter = filter
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
    }

    func setMonitoringAlertsEnabled(_ isEnabled: Bool) {
        guard !isEnabled || FeatureAccessService.hasAccess(to: .localAlerts) else {
            monitoringSettings.alertsEnabled = false
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .localAlerts)
            return
        }
        monitoringSettings.alertsEnabled = isEnabled
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
    }

    func setMonitoringSelection(for trackedDomain: TrackedDomain, isSelected: Bool) {
        if isSelected {
            if !monitoringSettings.selectedDomainIDs.contains(trackedDomain.id) {
                monitoringSettings.selectedDomainIDs.append(trackedDomain.id)
            }
        } else {
            monitoringSettings.selectedDomainIDs.removeAll { $0 == trackedDomain.id }
        }
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
    }

    func toggleMonitoring(for trackedDomain: TrackedDomain) {
        guard canEdit(trackedDomain) else { return }
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        guard let index = trackedDomains.firstIndex(where: { $0.id == trackedDomain.id }) else { return }
        trackedDomains[index].monitoringEnabled.toggle()
        trackedDomains[index].updatedAt = Date()
        MonitoringStorage.saveTrackedDomains(trackedDomains, defaults: defaults)
        CloudSyncService.shared.scheduleSyncIfNeeded()
        sanitizeMonitoringSelection()
    }

    func requestMonitoringNotificationAuthorization() async {
        let granted = await LocalNotificationService.shared.requestAuthorizationIfNeeded()
        monitoringSettings.alertsEnabled = granted
        persistMonitoringSettings(localActivationConfirmed: monitoringSettings.isEnabled)
        await refreshMonitoringAuthorizationStatus()
    }

    func runMonitoringNow() {
        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            upgradePrompt = FeatureAccessService.upgradePrompt(for: .automatedMonitoring)
            return
        }
        guard !monitoringRunInProgress else { return }

        monitoringRunInProgress = true
        monitoringStatusMessage = nil

        Task { [weak self] in
            guard let self else { return }
            let outcome = await DomainMonitoringService.shared.performMonitoring(
                trigger: .manual,
                requireEnabledSetting: false
            )
            await MainActor.run {
                self.refreshMonitoringState()
                self.monitoringRunInProgress = false
                self.monitoringStatusMessage = outcome.message
            }
        }
    }

    func monitoringIntervalLabel(for trackedDomain: TrackedDomain) -> String {
        let state = DomainMonitoringScheduler.normalizedMonitoringState(for: trackedDomain, settings: monitoringSettings)
        return Self.intervalLabel(for: state.currentInterval)
    }

    func monitoringStatusLabel(for trackedDomain: TrackedDomain) -> String {
        let state = trackedDomain.monitoringState
        if let lastChangeDate = state.lastChangeDate,
           Date().timeIntervalSince(lastChangeDate) <= 6 * 60 * 60 {
            return "Recently Changed"
        }
        if state.consecutiveStableChecks >= 2 {
            return "Stable"
        }
        return trackedDomain.monitoringEnabled ? "Active" : "Paused"
    }

    private static func intervalLabel(for interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: interval) ?? "Unknown"
    }
}

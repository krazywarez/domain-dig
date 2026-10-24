//
//  DomainDigApp.swift
//  DomainDig
//
//  Created by cmc on 2026-03-10.
//

import SwiftUI

@main
struct DomainDigApp: App {
    @UIApplicationDelegateAdaptor(DomainDigAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppDensity.userDefaultsKey) private var density = AppDensity.compact.rawValue
    @AppStorage(AppAppearance.userDefaultsKey) private var appearance = AppAppearance.system.rawValue
    @State private var viewModel = DomainViewModel()
    @State private var purchaseService = PurchaseService.shared
    @State private var cloudSyncService = CloudSyncService.shared
    @State private var localAPIService = LocalAPIService.shared

    init() {
        LocalNotificationService.shared.configureForegroundPresentation()
        DomainMonitoringScheduler.shared.registerBackgroundTask()
        ScheduledReportScheduler.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel)
                .environment(\.appDensity, AppDensity(rawValue: density) ?? .compact)
                // The single place appearance is applied. Keep it that way.
                .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
                .task {
                    #if DEBUG
                    viewModel.seedAuditFixturesIfRequested()
                    #endif
                    await refreshAfterBecomingActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApplyChanges)) { _ in
                    viewModel.refreshPersistedData()
                    viewModel.monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
                    IntegrationService.shared.refresh()
                }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { await refreshAfterBecomingActive() }
        }
    }

    /// Everything that must re-run whenever the app becomes active.
    ///
    /// Launch and foreground carried near-duplicates of this, and the
    /// foreground copy left out `refreshEntitlements()` — so a purchase or
    /// cancellation made outside the app was not picked up until the next cold
    /// launch.
    private func refreshAfterBecomingActive() async {
        await purchaseService.refreshEntitlements()
        viewModel.refreshMonitoringState()
        await viewModel.refreshMonitoringAuthorizationStatus()
        await cloudSyncService.refreshAvailability()
        localAPIService.refresh()
        cloudSyncService.scheduleSyncIfNeeded(trigger: .launch)
        viewModel.monitoringStatusMessage = DomainMonitoringScheduler.shared.syncSchedule()
        ScheduledReportScheduler.shared.syncSchedule()
        IntegrationService.shared.processQueueNow()
        viewModel.refreshWidgetData()
        consumeShareInbox()
    }

    /// Picks up a domain shared via the share extension and routes it into an
    /// inspection through the intent router (consumed by `RootTabView`).
    private func consumeShareInbox() {
        guard let domain = DomainDigShareInbox.consume() else { return }
        DomainDigIntentRouter.shared.pendingAction = .inspect(domain)
    }
}

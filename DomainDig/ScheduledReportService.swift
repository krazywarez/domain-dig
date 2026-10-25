import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

#if canImport(UIKit)
import UIKit
#endif

enum ScheduledReportCadence: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var interval: TimeInterval {
        switch self {
        case .daily: return 86400
        case .weekly: return 7 * 86400
        }
    }
}

struct ScheduledReportSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var cadence: ScheduledReportCadence = .weekly
    var format: DomainExportFormat = .markdown
    var lastGeneratedAt: Date?
}

struct ScheduledReportLog: Codable, Identifiable, Equatable {
    var id = UUID()
    let generatedAt: Date
    let domainCount: Int
    let format: DomainExportFormat
    let fileName: String
}

/// Local, UserDefaults-backed persistence for scheduled-report settings and
/// generation history. Deliberately not part of `DomainDataPortabilityService`
/// backup/restore: this is local automation configuration, not user-authored
/// content like tracked domains or audit sessions.
enum ScheduledReportStorage {
    private static let settingsKey = "scheduledReport.settings"
    private static let logsKey = "scheduledReport.logs"
    static let maxLogs = 20

    static func loadSettings() -> ScheduledReportSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ScheduledReportSettings.self, from: data)
        else { return ScheduledReportSettings() }
        return settings
    }

    static func saveSettings(_ settings: ScheduledReportSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func loadLogs() -> [ScheduledReportLog] {
        guard let data = UserDefaults.standard.data(forKey: logsKey),
              let logs = try? JSONDecoder().decode([ScheduledReportLog].self, from: data)
        else { return [] }
        return logs
    }

    static func saveLogs(_ logs: [ScheduledReportLog]) {
        guard let data = try? JSONEncoder().encode(Array(logs.prefix(maxLogs))) else { return }
        UserDefaults.standard.set(data, forKey: logsKey)
    }

    static var reportsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScheduledReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

struct ScheduledReportOutcome {
    let success: Bool
    let message: String
    let log: ScheduledReportLog?
}

/// Generates a bundled report for all tracked domains and writes it to disk.
/// Mirrors `DomainMonitoringService`'s headless, storage-backed design so it
/// can run from a background task without a live view model.
@MainActor
final class ScheduledReportService {
    static let shared = ScheduledReportService()

    private init() { /* Singleton; use the shared instance. */ }

    @discardableResult
    func generateReport(trigger _: MonitoringRunTrigger, requireEnabledSetting: Bool) async -> ScheduledReportOutcome {
        var settings = ScheduledReportStorage.loadSettings()

        guard FeatureAccessService.hasAccess(to: .automatedMonitoring) else {
            if settings.isEnabled {
                settings.isEnabled = false
                ScheduledReportStorage.saveSettings(settings)
                ScheduledReportScheduler.shared.syncSchedule()
            }
            return ScheduledReportOutcome(success: false, message: "Scheduled reports require Pro.", log: nil)
        }

        if requireEnabledSetting, !settings.isEnabled {
            return ScheduledReportOutcome(success: false, message: "Scheduled reports are disabled.", log: nil)
        }

        let trackedDomains = DomainDataPortabilityService.loadTrackedDomains()
        guard !trackedDomains.isEmpty else {
            return ScheduledReportOutcome(success: false, message: "No tracked domains to report on.", log: nil)
        }

        let history = DomainDataPortabilityService.loadHistoryEntries(historyLocation: .default)
        let builder = DomainReportBuilder()
        let reports = trackedDomains.compactMap { trackedDomain -> DomainReport? in
            let entry = history.first { entry in
                if let trackedDomainID = entry.trackedDomainID {
                    return trackedDomainID == trackedDomain.id
                }
                return entry.domain.caseInsensitiveCompare(trackedDomain.domain) == .orderedSame
            }
            guard let entry else { return nil }
            return builder.build(from: entry, historyEntries: history)
        }

        guard !reports.isEmpty else {
            return ScheduledReportOutcome(success: false, message: "No history available for tracked domains yet.", log: nil)
        }

        guard let data = try? DomainReportExporter.data(for: reports, format: settings.format, title: "Scheduled Watchlist Report") else {
            return ScheduledReportOutcome(success: false, message: "Report generation failed.", log: nil)
        }

        let generatedAt = Date()
        let fileName = "\(Self.fileTimestampFormatter.string(from: generatedAt))_scheduled-report.\(settings.format.fileExtension)"
        let fileURL = ScheduledReportStorage.reportsDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return ScheduledReportOutcome(success: false, message: "Could not save report to disk.", log: nil)
        }

        let log = ScheduledReportLog(generatedAt: generatedAt, domainCount: reports.count, format: settings.format, fileName: fileName)
        var logs = ScheduledReportStorage.loadLogs()
        logs.insert(log, at: 0)
        ScheduledReportStorage.saveLogs(logs)

        settings.lastGeneratedAt = generatedAt
        ScheduledReportStorage.saveSettings(settings)

        await LocalNotificationService.shared.notifyScheduledReportReady(domainCount: reports.count)
        IntegrationService.shared.enqueueExports(
            domains: reports.map(\.domain),
            trigger: .scheduled
        )

        return ScheduledReportOutcome(success: true, message: "Report generated for \(reports.count) domains.", log: log)
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

/// Background scheduling for report generation, mirroring
/// `DomainMonitoringScheduler`'s BGTaskScheduler-based approach with its own
/// task identifier and cadence.
@MainActor
final class ScheduledReportScheduler {
    static let shared = ScheduledReportScheduler()
    static let taskIdentifier = "net.cleberg.DomainDig.report.schedule"

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

    @discardableResult
    func syncSchedule() -> String? {
        #if canImport(BackgroundTasks)
        let settings = ScheduledReportStorage.loadSettings()
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

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        let baseDate = settings.lastGeneratedAt ?? Date()
        request.earliestBeginDate = max(
            baseDate.addingTimeInterval(settings.cadence.interval),
            Date(timeIntervalSinceNow: 15 * 60)
        )

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return "Could not schedule reports."
        }
        #else
        return "Scheduled reports are unavailable on this platform."
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handleAppRefresh(task: BGAppRefreshTask) {
        _ = syncSchedule()

        task.run {
            await ScheduledReportService.shared.generateReport(trigger: .background, requireEnabledSetting: true).success
        }
    }
    #endif
}

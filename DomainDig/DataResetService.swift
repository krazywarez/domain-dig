import Foundation
import Security

enum DataResetService {
    enum ResetError: LocalizedError {
        case missingBundleIdentifier

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier:
                "DomainDig could not determine its local storage identifier."
            }
        }
    }

    static func wipeAllLocalData(viewModel: DomainViewModel) async throws {
        let secretReferences = await MainActor.run {
            IntegrationService.shared.localSecretReferences() + LocalAPIService.shared.localSecretReferences()
        }

        try await Task.detached(priority: .userInitiated) {
            try performPersistentWipe(secretReferences: secretReferences)
        }.value

        await LookupRuntime.shared.clearCache()
        await LocalNotificationService.shared.clearAllNotifications()

        await MainActor.run {
            IntegrationService.shared.resetAfterLocalWipe()
            LocalAPIService.shared.resetAfterLocalWipe()
            CloudSyncService.shared.resetLocalStateAfterWipe()
            PurchaseService.shared.resetCachedStateAfterLocalWipe()
            _ = DomainMonitoringScheduler.shared.syncSchedule()
        }

        await viewModel.applyLocalDataReset()
    }

    private nonisolated static func performPersistentWipe(secretReferences: [String]) throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw ResetError.missingBundleIdentifier
        }

        for reference in secretReferences {
            deleteIntegrationSecret(reference: reference)
        }

        try removeTemporaryFiles()

        // History is a directory in Application Support since the v2 store
        // migration, so clearing the `UserDefaults` domain no longer reaches
        // it. A reset that left it behind would leave the user's snapshots on
        // the device after they asked for everything to go.
        HistoryFileStore.removeAll()

        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.synchronize()
    }

    private nonisolated static func removeTemporaryFiles() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
        let urls = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func deleteIntegrationSecret(reference: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: reference
        ]

        SecItemDelete(query as CFDictionary)
    }
}
